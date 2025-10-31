--[[
--  Jellyfin adapter
--]]

local mp = require 'mp'
local utils = require 'mp.utils'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local log = require 'src.core.log'

local adapter_manager = require 'src.models.base.adapter'
local JellyfinClient = require 'src.models.adapters.jellyfin.client'

local API_VERSION = adapter_manager.get_api_version()

---@class Adapter
local adapter = {
    api_version = API_VERSION,
}

---@class JellyfinAdapterState
---@field config JellyfinConfig
---@field auth_in_progress boolean
---@field authenticated boolean
---@field auth_failed boolean
---@field current_items JellyfinItem[]
---@field parent_item JellyfinItem?
---@field timer MPTimer? Cache update timer
local jf_state = {}

---@type JellyfinClient
local jf_client

---@type AdapterAPI
local jf_api

---@type JellyfinItem
local jf_root_item = { Name = 'Libraries', Type = 'Root', Id = '' }

---Cache strategy:
--- - Keyed by item_id (decoded from nav_id)
--- - Stores raw Jellyfin items + transformed Items + parent metadata
--- - Updated periodically if update_cache config is set
--- - Bypassed when force=true in request
--- - Invalidated on fetch errors
---@class JellyfinCacheData
---@field jf_items JellyfinItem[]
---@field items Item[]
---@field parent_item JellyfinItem
---
---@alias JellyfinCache table<NavID, JellyfinCacheData>
---
---@type JellyfinCache
local jf_cache = {}

---Validate adapter configuration
---@param config AdapterConfig
---@return JellyfinConfig? jellyfin_config
---@return string? error_msg
local function validate_config(config)
    if not config then
        return nil, 'config is nil'
    end

    if type(config.id) ~= 'string' then
        return nil, 'missing or invalid id field'
    end

    if config.type ~= 'jellyfin' then
        return nil, 'type mismatch: expected "jellyfin", got "' .. tostring(config.type) .. '"'
    end

    if type(config.url) ~= 'string' then
        return nil, ("missing or invalid url field - type: '%s' value: '%s'"):format(
            type(config.url), tostring(config.url)
        )
    end

    return config --[[@as JellyfinConfig]]
end

---Validate user settings. If success is true, but msg is not nil, issue msg as a warning.
---@return boolean success
---@return string? msg
local function validate_user_settings()

    -- 'loop-file' can cause reporting issues
    local loop_file = mp.get_property('loop-file')
    if loop_file ~= 'no' then
        return true,
            ("Option '%s' set to '%s' - use 'no' to avoid reporting issues"):format(
                'loop-file', utils.to_string(loop_file)
            )
    end

    return true, nil
end

---Authenticate with the Jellyfin server
---@param adapter_id AdapterID 
---@return boolean success
local function authenticate(adapter_id)
    if jf_state.auth_in_progress then
        return false
    end

    if jf_state.authenticated then
        return true
    end

    jf_state.auth_in_progress = true

    log.info(adapter_id, {
        'Connecting to', jf_state.config.url
    })

    -- Authenticate using the Jellyfin client
    local success, err = jf_client:authenticate(
        jf_state.config.username or '',
        jf_state.config.password or ''
    )

    jf_state.auth_in_progress = false

    if success then
        jf_state.authenticated = true
        jf_state.auth_failed = false

        log.info(adapter_id, {
            'Successfully authenticated with Jellyfin server'
        })

        return true
    else
        jf_state.auth_failed = true

        log.error(adapter_id, {
            'Failed to authenticate with Jellyfin server:', err or 'unknown error'
        })

        return false
    end
end

---Check if request has been cached
---@param nav_id NavID
---@return boolean success
local function is_request_cached(nav_id)
    return jf_cache[hh_utils.decode_nav_id(nav_id).rest] ~= nil
end

---Emit 'content.loaded' with cached data
---@param ctx_id NavCtxID
---@param nav_id NavID
local function handle_cached_request(ctx_id, nav_id)
    local jf_cache_data = jf_cache[hh_utils.decode_nav_id(nav_id).rest]

    log.info(jf_api.adapter_id, {
        'Returning cached data.'
    })

    -- Update current pointers
    jf_state.current_items = jf_cache_data.jf_items
    jf_state.parent_item = jf_cache_data.parent_item

    events.emit('content.loaded', {
        ctx_id = ctx_id,
        nav_id = nav_id,
        items = jf_cache_data.items,
        adapter_name = jf_api.adapter_name,
        content_title = jf_cache_data.parent_item.Name,
    } --[[@as ContentLoadedData]])
end

---Cache the current request data.
---@param nav_id NavID
---@param jf_items JellyfinItem[]
---@param items Item[]
---@param parent_item JellyfinItem
local function cache_request_data(nav_id, jf_items, items, parent_item)
    jf_cache[hh_utils.decode_nav_id(nav_id).rest] = {
        jf_items = jf_items,
        items = items,
        parent_item = parent_item,
    }
end

---Construct an Item from `jf_item`.
---@param jf_item JellyfinItem
---@return Item
local function jf_item_to_item(jf_item)
    local hint = nil

    if type(jf_item.Overview) == 'string' and jf_item.Overview ~= '' then
        hint = jf_item.Overview
    end

    return {
        lines = {
            jf_item.Name or 'Unknown',
        },
        hint = hint,
    } --[[@as Item]]
end

---Handle cache update
local function handle_cache_update()
    log.debug(jf_api.adapter_id, {
        'Updating cache.',
    })

    if not authenticate(jf_api.adapter_id) then
        log.warn(jf_api.adapter_id, {
            'Not authenticated - unable to update cache.'
        })
        return
    end

    for item_id in pairs(jf_cache) do
        -- Fetch content from Jellyfin
        local jf_items, err
        if item_id == '' then
            -- Root request - fetch libraries
            jf_items, err = jf_client:get_views()
        else
            -- Fetch items in this library/folder
            jf_items, err = jf_client:get_items(item_id)
        end

        if err then
            log.error(jf_api.adapter_id, {
                'Failed to update content:', err,
            })
            jf_cache[item_id] = nil -- invalidate cache
        else
            ---@type JellyfinItem?
            local item = nil
            if item_id ~= '' then
                item, err = jf_client:get_item(item_id)
            end

            if not item then
                log.warn(jf_api.adapter_id, {
                    'Could not get item for nav_id:', item_id or 'NONE'
                })
                item = jf_root_item
            end

            -- Cache the fetched data
            jf_items = jf_items or {}

            -- Transform Jellyfin items to HomeHub Item format
            local items = {}
            for _, jf_item in ipairs(jf_items) do
                table.insert(items, jf_item_to_item(jf_item))
            end

            cache_request_data(hh_utils.encode_nav_id(jf_api.adapter_id, item_id), jf_items, items, item)

            log.info(jf_api.adapter_id, {
                'Updated cache for item_id:', item_id
            })
        end
    end
end

---Handle content request from content controller
---@param event_name EventName
---@param data AdapterRequestData|EventData
local function handle_request(event_name, data)
    if not hh_utils.validate_data(
        event_name, data, hh_utils.is_adapter_request, jf_api.adapter_id
    ) then
        return
    end

    local adapter_id = jf_api.adapter_id
    local nav_id = hh_utils.encode_nav_id(adapter_id, data.nav_id)

    -- Lazy authentication
    if not jf_state.authenticated then
        events.emit('content.loading', {
            ctx_id = data.ctx_id,
            nav_id = nav_id,
            adapter_id = adapter_id,
        } --[[@as ContentLoadingData]])

        if not authenticate(adapter_id) then
            events.emit('content.error', {
                ctx_id = data.ctx_id,
                nav_id = nav_id,
                msg = 'Failed to connect to Jellyfin server',
                adapter_id = adapter_id,
                error_type = 'authentication_failed',
                recoverable = true,
            } --[[@as ContentErrorData]])
            return
        end
    end

    log.debug(adapter_id, {
        'Handling request for nav_id:', nav_id
    })

    if not data.force and is_request_cached(nav_id) then
        handle_cached_request(data.ctx_id, nav_id)
        return
    end

    -- Fetch content from Jellyfin
    local jellyfin_items, err
    if data.nav_id == '' then
        -- Root request - fetch libraries
        jellyfin_items, err = jf_client:get_views()
    else
        -- Fetch items in this library/folder
        jellyfin_items, err = jf_client:get_items(data.nav_id)
    end

    if err then
        events.emit('content.error', {
            ctx_id = data.ctx_id,
            nav_id = nav_id,
            msg = 'Failed to fetch content: ' .. err,
            adapter_id = adapter_id,
            error_type = 'fetch_failed',
            recoverable = true,
        } --[[@as ContentErrorData]])
        return
    end

    ---@type JellyfinItem?
    local item = jf_root_item
    if data.nav_id ~= '' then
        item, err = jf_client:get_item(data.nav_id)
    end

    if not item then
        log.warn(jf_api.adapter_id, {
            'Could not get item for nav_id:', data.nav_id or 'NONE'
        })
        item = jf_root_item
    end

    -- Cache the fetched data
    jellyfin_items = jellyfin_items or {}
    jf_state.current_items = jellyfin_items
    jf_state.parent_item = item

    -- Transform Jellyfin items to HomeHub Item format
    local items = {}
    for _, jf_item in ipairs(jellyfin_items) do
        table.insert(items, jf_item_to_item(jf_item))
    end

    cache_request_data(nav_id, jellyfin_items, items, item)

    events.emit('content.loaded', {
        ctx_id = data.ctx_id,
        nav_id = nav_id,
        items = items,
        adapter_name = jf_api.adapter_name,
        content_title = jf_state.parent_item.Name,
    } --[[@as ContentLoadedData]])
end

---Handle content navigation request from content controller
---@param event_name EventName
---@param data AdapterNavToData|EventData
local function handle_navigate_to(event_name, data)
    if not hh_utils.validate_data(
        event_name, data, hh_utils.is_adapter_nav_to, jf_api.adapter_id
    ) then
        return
    end

    local adapter_id = jf_api.adapter_id

    log.debug(adapter_id, {
        'Navigating to:', data.nav_id, 'selection:', tostring(data.selection)
    })

    -- Get the selected item from cached current_items
    if data.selection < 1 or data.selection > #jf_state.current_items then
        events.emit('content.error', {
            ctx_id = data.ctx_id,
            nav_id = data.nav_id,
            msg = 'Invalid selection: ' .. data.selection,
            adapter_id = adapter_id,
            error_type = 'invalid_selection',
            recoverable = false,
        } --[[@as ContentErrorData]])
        return
    end

    local selected_item = jf_state.current_items[data.selection]
    local nav_id = hh_utils.encode_nav_id(adapter_id, selected_item.Id)

    if selected_item.IsFolder or selected_item.IsVirtualFolder then
        -- Navigate into folder - fetch children
        events.emit('content.loading', {
            ctx_id = data.ctx_id,
            nav_id = nav_id,
            adapter_id = adapter_id,
        } --[[@as ContentLoadingData]])

        if is_request_cached(nav_id) then
            handle_cached_request(data.ctx_id, nav_id)
            return
        end

        local children, err = jf_client:get_items(selected_item.Id)

        if err then
            events.emit('content.error', {
                ctx_id = data.ctx_id,
                nav_id = nav_id,
                msg = 'Failed to fetch folder contents: ' .. err,
                adapter_id = adapter_id,
                error_type = 'fetch_failed',
                recoverable = true,
            } --[[@as ContentErrorData]])
            return
        end

        -- Cache items
        children = children or {}
        jf_state.current_items = children
        jf_state.parent_item = selected_item

        -- Transform and emit
        local items = {}
        for _, jf_item in ipairs(children) do
            table.insert(items, jf_item_to_item(jf_item))
        end

        cache_request_data(nav_id, children, items, selected_item)

        events.emit('content.loaded', {
            ctx_id = data.ctx_id,
            nav_id = nav_id,
            items = items,
            adapter_name = jf_api.adapter_name,
            content_title = jf_state.parent_item and jf_state.parent_item.Name or 'unknown'
        } --[[@as ContentLoadedData]])
    else
        -- Play the file
        log.info(adapter_id, {
            'Playing:', selected_item.Name
        })

        -- Hide UI
        events.emit('ui.hide')

        -- Play via client
        local success, err = jf_client:play(selected_item)

        if not success then
            log.error(adapter_id, {
                'Playback failed:', err or 'unknown error'
            })

            -- Restore UI on error
            events.emit('ui.show')
        end
    end
end

---Handle sync request from client
---@param event_name EventName
---@param data AdapterSyncData|EventData
local function handle_sync(event_name, data)
    if type(data.adapter_id) ~= 'string' or type(data.data) ~= 'table' then
        hh_utils.emit_data_error(event_name, data, jf_api.adapter_id)
        return
    end

    ---@type JellyfinSyncData
    local sync_data = data.data

    if sync_data.state == 'playing' then
        for i, item in ipairs(jf_state.current_items) do
            if item.Id == sync_data.item_id then
                events.emit('ui.update', {
                    cursor_pos = i,
                } --[[@as UiUpdateData]])
            end
        end
    end
end

---Initialize the adapter
---@param config AdapterConfig
---@return boolean success
function adapter.init(config)
    -- Validate configuration
    local jf_config, err = validate_config(config)
    if not jf_config then
        log.error('jellyfin', {
            'Jellyfin adapter validation failed: ' .. err,
            'Config: ' .. utils.to_string(config)
        }, '\n')
        return false
    end

    local success, msg = validate_user_settings()
    if not success then
        log.error('jellyfin', {
            'User settings error:', msg
        })
        return false
    end

    if type(msg) == 'string' then
        log.warn('jellyfin', msg)
    end

    -- Define adapter api
    jf_api = {
        adapter_id = jf_config.id,
        adapter_name = jf_config.display_name or 'Jellyfin',
        adapter_type = 'jellyfin',
        events = {
            request = jf_config.id .. '.request',
            navigate_to = jf_config.id .. '.navigate_to',
            next = jf_config.id .. '.next',
            prev = jf_config.id .. '.prev',
            search = jf_config.id .. '.search',
            action = jf_config.id .. '.action',
            status = jf_config.id .. '.status',
            error = jf_config.id .. '.error',
            sync = jf_config.id .. '.sync',
        },
        capabilities = {
            supports_search = true,
            supports_thumbnails = true,
            media_types = {
                'video',
                'audio',
                'other',
            }
        }
    }

    -- Define jellyfin state
    jf_state = {
        config = jf_config,
        auth_in_progress = false,
        authenticated = false,
        auth_failed = false,
        current_items = {},
        parent_item = nil,
    }

    if jf_state.config.update_cache ~= nil and jf_state.config.update_cache ~= 0 then
        jf_state.timer = mp.add_periodic_timer(jf_state.config.update_cache, handle_cache_update)
    end

    jf_client = JellyfinClient.new(jf_config, jf_api)

    -- Register event handlers
    events.on(jf_api.events.request, handle_request, jf_api.adapter_id)
    events.on(jf_api.events.navigate_to, handle_navigate_to, jf_api.adapter_id)
    events.on(jf_api.events.sync, handle_sync, jf_api.adapter_id)

    -- Register with content controller
    events.emit('content.register_adapter', jf_api)

    log.info(jf_api.adapter_id, {
        'Jellyfin adapter initialized (authentication deferred)'
    })

    return true
end

---Cleanup all adapter instances
function adapter.cleanup()
    events.cleanup_component(jf_api.adapter_id)

    if jf_state.timer then
        jf_state.timer:kill()
    end

    if jf_state.authenticated then
        log.info(jf_api.adapter_id, {
            'Disconnecting from Jellyfin server'
        })

        -- Stop any active playback
        if jf_client:is_playing() then
            jf_client:stop_playback()
        end
    end

    log.debug(jf_api.adapter_id, {
        'Jellyfin instance cleaned up'
    })
end

return adapter
