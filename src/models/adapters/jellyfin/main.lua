--[[
--  Jellyfin adapter
--]]

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'

local adapter_manager = require 'src.models.base.adapter'
local JellyfinClient = require 'src.models.adapters.jellyfin.client'

local API_VERSION = adapter_manager.get_api_version()

---@class Adapter
local adapter = {
    api_version = API_VERSION,
}

---@class JellyfinAdapterState: AdapterState
---@field api_client JellyfinClient?
---@field current_items JellyfinItem[]
---@field parent_item? JellyfinItem
---
---Registry of adapter instances
---@type table<AdapterID, JellyfinAdapterState>
local instances = {}

---Get or create instance state
---@param adapter_id AdapterID
---@return JellyfinAdapterState state
local function get_instance(adapter_id)
    if not instances[adapter_id] then
        instances[adapter_id] = {
            config = nil,
            auth_in_progress = false,
            authenticated = false,
            auth_failed = false,
            api_client = nil,
            current_items = {},
            parent_item = nil,
            api = {
                adapter_id = adapter_id,
                adapter_name = 'Jellyfin',
                adapter_type = 'jellyfin',
                events = {
                    request = adapter_id .. '.request',
                    navigate_to = adapter_id .. '.navigate_to',
                    next = adapter_id .. '.next',
                    prev = adapter_id .. '.prev',
                    search = adapter_id .. '.search',
                    action = adapter_id .. '.action',
                    status = adapter_id .. '.status',
                    error = adapter_id .. '.error',
                    sync = adapter_id .. '.sync',
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
        }
    end
    return instances[adapter_id]
end

---Validate adapter configuration
---@param config AdapterConfig
---@return boolean valid
---@return string? error_msg
local function validate_config(config)
    if not config then
        return false, 'config is nil'
    end

    if type(config.id) ~= 'string' then
        return false, 'missing or invalid id field'
    end

    if config.type ~= 'jellyfin' then
        return false, 'type mismatch: expected "jellyfin", got "' .. tostring(config.type) .. '"'
    end

    if type(config.url) ~= 'string' then
        return false, ("missing or invalid url field - type: '%s' value: '%s'"):format(
            type(config.url), tostring(config.url)
        )
    end

    return true
end

---Authenticate with the Jellyfin server
---@param adapter_id AdapterID 
---@return boolean success
local function authenticate(adapter_id)
    local state = get_instance(adapter_id)

    if state.auth_in_progress then
        return false
    end

    if state.authenticated then
        return true
    end

    state.auth_in_progress = true

    events.emit('msg.info.' .. adapter_id, { msg = {
        'Connecting to', state.config.url
    } })

    -- Authenticate using the Jellyfin client
    local success, err = state.api_client:authenticate(
        state.config.username or '',
        state.config.password or ''
    )

    state.auth_in_progress = false

    if success then
        state.authenticated = true
        state.auth_failed = false

        events.emit('msg.info.' .. adapter_id, { msg = {
            'Successfully authenticated with Jellyfin server'
        } })

        return true
    else
        state.auth_failed = true

        events.emit('msg.error.' .. adapter_id, { msg = {
            'Failed to authenticate with Jellyfin server:', err or 'unknown error'
        } })

        return false
    end
end

---Handle content request from content controller
---@param event_name EventName
---@param data AdapterRequestData|EventData|nil
local function handle_request(event_name, data)
    if not data or not data.ctx_id or not data.nav_id or not data.adapter_id then
        hh_utils.emit_data_error(event_name, data, 'jellyfin')
        return
    end

    local state = get_instance(data.adapter_id)
    local adapter_id = state.api.adapter_id
    local nav_id = hh_utils.encode_nav_id(adapter_id, data.nav_id)

    -- Lazy authentication
    if not state.authenticated then
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

    events.emit('msg.debug.' .. adapter_id, { msg = {
        'Handling request for nav_id:', nav_id
    } })

    -- Fetch content from Jellyfin
    local jellyfin_items, err
    if data.nav_id == '' then
        -- Root request - fetch libraries
        jellyfin_items, err = state.api_client:get_views()
    else
        -- Fetch items in this library/folder
        jellyfin_items, err = state.api_client:get_items(data.nav_id)
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
        item, err = state.api_client:get_item(data.nav_id)
    end

    if not item then
        events.emit('msg.warn.' .. state.api.adapter_id, { msg = {
            'Could not get item for nav_id:', data.nav_id or 'NONE'
        } })
        item = { Name = 'Libraries', Type = 'Root', Id = '' }
    end

    -- Cache the fetched items
    state.current_items = jellyfin_items or {}
    state.parent_item = item

    -- Transform Jellyfin items to HomeHub Item format
    local items = {}
    for _, jf_item in ipairs(jellyfin_items or {}) do
        table.insert(items, {
            primary_text = jf_item.Name or 'Unknown',
            secondary_text = jf_item.Type or '',
        } --[[@as Item]])
    end

    events.emit('content.loaded', {
        ctx_id = data.ctx_id,
        nav_id = nav_id,
        items = items,
        adapter_name = state.api.adapter_name,
        content_title = state.parent_item.Name,
    } --[[@as ContentLoadedData]])
end

---Handle content navigation request from content controller
---@param event_name EventName
---@param data AdapterNavToData|EventData|nil
local function handle_navigate_to(event_name, data)
    if not data or not data.ctx_id or not data.nav_id or not data.adapter_id or not data.selection then
        hh_utils.emit_data_error(event_name, data, 'jellyfin')
        return
    end

    local state = get_instance(data.adapter_id)
    local adapter_id = state.api.adapter_id

    events.emit('msg.debug.' .. adapter_id, { msg = {
        'Navigating to:', data.nav_id, 'selection:', data.selection
    } })

    -- Get the selected item from cached current_items
    if data.selection < 1 or data.selection > #state.current_items then
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

    local selected_item = state.current_items[data.selection]
    local nav_id = hh_utils.encode_nav_id(adapter_id, selected_item.Id)

    if selected_item.IsFolder then
        -- Navigate into folder - fetch children
        events.emit('content.loading', {
            ctx_id = data.ctx_id,
            nav_id = nav_id,
            adapter_id = adapter_id,
        } --[[@as ContentLoadingData]])

        local children, err = state.api_client:get_items(selected_item.Id)

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
        state.current_items = children or {}
        state.parent_item = selected_item

        -- Transform and emit
        local items = {}
        for _, jf_item in ipairs(state.current_items) do
            table.insert(items, {
                primary_text = jf_item.Name or 'Unknown',
                secondary_text = jf_item.Type or '',
            } --[[@as Item]])
        end

        events.emit('content.loaded', {
            ctx_id = data.ctx_id,
            nav_id = nav_id,
            items = items,
            adapter_name = state.api.adapter_name,
            content_title = state.parent_item and state.parent_item.Name or 'unknown'
        } --[[@as ContentLoadedData]])
    else
        -- Play the file
        events.emit('msg.info.' .. adapter_id, { msg = {
            'Playing:', selected_item.Name
        } })

        -- Hide UI
        events.emit('ui.hide')

        -- Play via client
        local success, err = state.api_client:play(selected_item)

        if not success then
            events.emit('msg.error.' .. adapter_id, { msg = {
                'Playback failed:', err or 'unknown error'
            } })

            -- Restore UI on error
            events.emit('ui.show')
        end
    end
end

---Handle sync request from client
---@param event_name EventName
---@param data AdapterSyncData|EventData|nil
local function handle_sync(event_name, data)
    if not data or not data.adapter_id or type(data.data) ~= 'table' then
        hh_utils.emit_data_error(event_name, data, 'jellyfin')
        return
    end

    local state = get_instance(data.adapter_id)
    local sync_data = data.data --[[@as JellyfinSyncData]]

    if sync_data.state == 'playing' then
        for i, item in ipairs(state.current_items) do
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
    local valid, err = validate_config(config)
    if not valid then
        events.emit('msg.error.jellyfin', { msg = {
            'Jellyfin adapter validation failed:', err
        } })
        return false
    end

    -- Create instance state
    local state = get_instance(config.id)
    state.config = config

    -- Get auto_play_next setting (defaults to true if not specified)
    local auto_play_next = config.auto_play_next ~= false

    -- Update API with config values
    local api = state.api
    api.adapter_name = config.display_name or api.adapter_name

    -- Initialize Jellyfin API client
    state.api_client = JellyfinClient.new(config.url, api.events, api.adapter_id, auto_play_next)

    -- Register event handlers
    events.on(api.events.request, handle_request, api.adapter_id)
    events.on(api.events.navigate_to, handle_navigate_to, api.adapter_id)
    events.on(api.events.sync, handle_sync, api.adapter_id)

    -- Register with content controller
    events.emit('content.register_adapter', api)

    events.emit('msg.info.' .. api.adapter_id, { msg = {
        'Jellyfin adapter initialized (authentication deferred)'
    } })

    return true
end

---Cleanup all adapter instances
function adapter.cleanup()
    for adapter_id, state in pairs(instances) do
        events.cleanup_component(adapter_id)

        if state.authenticated then
            events.emit('msg.info.' .. adapter_id, { msg = {
                'Disconnecting from Jellyfin server'
            } })

            -- Stop any active playback
            if state.api_client and state.api_client:is_playing() then
                state.api_client:stop_playback()
            end
        end

        events.emit('msg.debug.' .. adapter_id, { msg = {
            'Jellyfin instance cleaned up'
        } })
    end

    -- Clear instance registry
    instances = {}
end

return adapter
