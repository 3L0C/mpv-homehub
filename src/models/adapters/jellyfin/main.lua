--[[
--  Jellyfin adapter
--]]

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
local jellyfin_state = {}

---@type JellyfinClient
local jellyfin_client

---@type AdapterAPI
local jellyfin_api

---@type JellyfinItem
local jellyfin_root_item = { Name = 'Libraries', Type = 'Root', Id = '' }

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

---Authenticate with the Jellyfin server
---@param adapter_id AdapterID 
---@return boolean success
local function authenticate(adapter_id)
    if jellyfin_state.auth_in_progress then
        return false
    end

    if jellyfin_state.authenticated then
        return true
    end

    jellyfin_state.auth_in_progress = true

    log.info(adapter_id, {
        'Connecting to', jellyfin_state.config.url
    })

    -- Authenticate using the Jellyfin client
    local success, err = jellyfin_client:authenticate(
        jellyfin_state.config.username or '',
        jellyfin_state.config.password or ''
    )

    jellyfin_state.auth_in_progress = false

    if success then
        jellyfin_state.authenticated = true
        jellyfin_state.auth_failed = false

        log.info(adapter_id, {
            'Successfully authenticated with Jellyfin server'
        })

        return true
    else
        jellyfin_state.auth_failed = true

        log.error(adapter_id, {
            'Failed to authenticate with Jellyfin server:', err or 'unknown error'
        })

        return false
    end
end

---Construct an Item from `jf_item`.
---@param jf_item JellyfinItem
---@return Item
local function jf_item_to_item(jf_item)
    return {
        primary_text = jf_item.Name or 'Unknown',
        secondary_text = jf_item.Type or '',
    }
end

---Handle content request from content controller
---@param event_name EventName
---@param data AdapterRequestData|EventData
local function handle_request(event_name, data)
    if not hh_utils.validate_data(
        event_name, data, hh_utils.is_adapter_request, jellyfin_api.adapter_id
    ) then
        return
    end

    local adapter_id = jellyfin_api.adapter_id
    local nav_id = hh_utils.encode_nav_id(adapter_id, data.nav_id)

    -- Lazy authentication
    if not jellyfin_state.authenticated then
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

    -- Fetch content from Jellyfin
    local jellyfin_items, err
    if data.nav_id == '' then
        -- Root request - fetch libraries
        jellyfin_items, err = jellyfin_client:get_views()
    else
        -- Fetch items in this library/folder
        jellyfin_items, err = jellyfin_client:get_items(data.nav_id)
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
    local item = nil
    if data.nav_id ~= '' then
        item, err = jellyfin_client:get_item(data.nav_id)
    end

    if not item then
        log.warn(jellyfin_api.adapter_id, {
            'Could not get item for nav_id:', data.nav_id or 'NONE'
        })
        item = jellyfin_root_item
    end

    -- Cache the fetched items
    jellyfin_state.current_items = jellyfin_items or {}
    jellyfin_state.parent_item = item

    -- Transform Jellyfin items to HomeHub Item format
    local items = {}
    for _, jf_item in ipairs(jellyfin_items or {}) do
        table.insert(items, jf_item_to_item(jf_item))
    end

    events.emit('content.loaded', {
        ctx_id = data.ctx_id,
        nav_id = nav_id,
        items = items,
        adapter_name = jellyfin_api.adapter_name,
        content_title = jellyfin_state.parent_item.Name,
    } --[[@as ContentLoadedData]])
end

---Handle content navigation request from content controller
---@param event_name EventName
---@param data AdapterNavToData|EventData
local function handle_navigate_to(event_name, data)
    if not hh_utils.validate_data(
        event_name, data, hh_utils.is_adapter_nav_to, jellyfin_api.adapter_id
    ) then
        return
    end

    local adapter_id = jellyfin_api.adapter_id

    log.debug(adapter_id, {
        'Navigating to:', data.nav_id, 'selection:', tostring(data.selection)
    })

    -- Get the selected item from cached current_items
    if data.selection < 1 or data.selection > #jellyfin_state.current_items then
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

    local selected_item = jellyfin_state.current_items[data.selection]
    local nav_id = hh_utils.encode_nav_id(adapter_id, selected_item.Id)

    if selected_item.IsFolder or selected_item.IsVirtualFolder then
        -- Navigate into folder - fetch children
        events.emit('content.loading', {
            ctx_id = data.ctx_id,
            nav_id = nav_id,
            adapter_id = adapter_id,
        } --[[@as ContentLoadingData]])

        local children, err = jellyfin_client:get_items(selected_item.Id)

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
        jellyfin_state.current_items = children or {}
        jellyfin_state.parent_item = selected_item

        -- Transform and emit
        local items = {}
        for _, jf_item in ipairs(jellyfin_state.current_items) do
            table.insert(items, jf_item_to_item(jf_item))
        end

        events.emit('content.loaded', {
            ctx_id = data.ctx_id,
            nav_id = nav_id,
            items = items,
            adapter_name = jellyfin_api.adapter_name,
            content_title = jellyfin_state.parent_item and jellyfin_state.parent_item.Name or 'unknown'
        } --[[@as ContentLoadedData]])
    else
        -- Play the file
        log.info(adapter_id, {
            'Playing:', selected_item.Name
        })

        -- Hide UI
        events.emit('ui.hide')

        -- Play via client
        local success, err = jellyfin_client:play(selected_item)

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
        hh_utils.emit_data_error(event_name, data, jellyfin_api.adapter_id)
        return
    end

    ---@type JellyfinSyncData
    local sync_data = data.data

    if sync_data.state == 'playing' then
        for i, item in ipairs(jellyfin_state.current_items) do
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
    local jellyfin_config, err = validate_config(config)
    if not jellyfin_config then
        log.error('jellyfin', {
            'Jellyfin adapter validation failed: ' .. err,
            'Config: ' .. utils.to_string(config)
        }, '\n')
        return false
    end

    -- Define adapter api
    jellyfin_api = {
        adapter_id = jellyfin_config.id,
        adapter_name = jellyfin_config.display_name or 'Jellyfin',
        adapter_type = 'jellyfin',
        events = {
            request = jellyfin_config.id .. '.request',
            navigate_to = jellyfin_config.id .. '.navigate_to',
            next = jellyfin_config.id .. '.next',
            prev = jellyfin_config.id .. '.prev',
            search = jellyfin_config.id .. '.search',
            action = jellyfin_config.id .. '.action',
            status = jellyfin_config.id .. '.status',
            error = jellyfin_config.id .. '.error',
            sync = jellyfin_config.id .. '.sync',
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
    jellyfin_state = {
        config = jellyfin_config,
        auth_in_progress = false,
        authenticated = false,
        auth_failed = false,
        current_items = {},
        parent_item = nil,
    }

    jellyfin_client = JellyfinClient.new(jellyfin_config, jellyfin_api)

    -- Register event handlers
    events.on(jellyfin_api.events.request, handle_request, jellyfin_api.adapter_id)
    events.on(jellyfin_api.events.navigate_to, handle_navigate_to, jellyfin_api.adapter_id)
    events.on(jellyfin_api.events.sync, handle_sync, jellyfin_api.adapter_id)

    -- Register with content controller
    events.emit('content.register_adapter', jellyfin_api)

    log.info(jellyfin_api.adapter_id, {
        'Jellyfin adapter initialized (authentication deferred)'
    })

    return true
end

---Cleanup all adapter instances
function adapter.cleanup()
    events.cleanup_component(jellyfin_api.adapter_id)

    if jellyfin_state.authenticated then
        log.info(jellyfin_api.adapter_id, {
            'Disconnecting from Jellyfin server'
        })

        -- Stop any active playback
        if jellyfin_client:is_playing() then
            jellyfin_client:stop_playback()
        end
    end

    log.debug(jellyfin_api.adapter_id, {
        'Jellyfin instance cleaned up'
    })
end

return adapter
