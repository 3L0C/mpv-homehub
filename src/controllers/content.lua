--[[
--  Content controller.
--]]

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'

---@class content: Controller
local content = {}

local content_state = {
    -- Registered adapters
    ---@type table<AdapterID,AdapterAPI>
    adapter_apis = {},

    -- Active adapters
    ---@type Set<AdapterID>
    active_adapters = {},
}

---Get adapter API by adapter_id.
---@param adapter_id AdapterID
---@return AdapterAPI?
local function get_adapter_api(adapter_id)
    -- The adapter_id might be the specific instance (e.g., 'jellyfin_main')
    -- or the adapter type (e.g., 'jellyfin')
    return content_state.adapter_apis[adapter_id]
end

---Get active adapter ids.
---@return AdapterID[]
local function get_active_adapter_ids()
    ---@type AdapterID[]
    local ids = {}

    for id, is_active in pairs(content_state.active_adapters) do
        if is_active then
            table.insert(ids, id)
        end
    end

    return ids
end

---Request root content from an adapter.
---@param ctx_id NavCtxID
---@param adapter_id AdapterID
local function handle_adapter_root_request(ctx_id, adapter_id)
    local api = get_adapter_api(adapter_id)
    if not api then
        events.emit('content.error', {
            ctx_id = ctx_id,
            nav_id = '',
            msg = 'Adapter API not found: ' .. adapter_id,
            adapter_id = adapter_id,
            error_type = 'internal',
            recoverable = false,
        } --[[@as ContentErrorData]])
        return
    end

    events.emit('msg.debug.content', { msg = {
        'Single adapter - requesting root content from:', adapter_id
    } })

    events.emit('content.loading', {
        ctx_id = ctx_id,
        nav_id = '',
        adapter_id = adapter_id,
    } --[[@as ContentLoadingData]])

    events.emit(api.events.request, {
        ctx_id = ctx_id,
        nav_id = '',
        adapter_id = adapter_id,
    } --[[@as AdapterRequestData]])
end


---Request root content from all active adapters.
---@param ctx_id NavCtxID
local function handle_root_request(ctx_id)
    local adapter_ids = get_active_adapter_ids()

    if #adapter_ids == 0 then
        events.emit('msg.warn.content', { msg = {
            'Unable to access root content, no active adapters.'
        } })
        return
    elseif #adapter_ids == 1 then
        handle_adapter_root_request(ctx_id, adapter_ids[1])
        return
    end

    ---@type Item[]
    local items = {}
    for _, adapter_id in ipairs(adapter_ids) do
        local api = get_adapter_api(adapter_id)
        if not api then
            events.emit('msg.error.content', { msg = {
                'Active adapter with no api:', adapter_id,
            } })
            content_state.active_adapters[adapter_id] = false
        else
            table.insert(items, {
                primary_text = api.adapter_name,
                secondary_text = api.adapter_type,
                -- Could add icons an such later...
            } --[[@as Item]])
        end
    end

    if #items == 0 then
        return
    elseif #items == 1 then
        -- This should not create an infinite recursion because we deactivated
        -- adapters with no api. This should leave us with a single adapter_id
        -- when we next call `get_active_adapter_ids()`.
        adapter_ids = get_active_adapter_ids()
        if #adapter_ids == 1 then
            handle_root_request(ctx_id)
        end
        return
    end

    events.emit('content.loaded', {
        ctx_id = ctx_id,
        nav_id = '',
        items = items,
    } --[[@as ContentLoadedData]])
end

---Request root content from specific adapter (user selected from menu).
---@param ctx_id NavCtxID
---@param selection number
local function handle_adapter_selection(ctx_id, selection)
    local adapter_ids = get_active_adapter_ids()

    if selection < 1 or selection > #adapter_ids then
        events.emit('content.error', {
            ctx_id = ctx_id,
            nav_id = '',
            msg = 'Invalid adapter selection: ' .. selection,
            adapter_id = '',
            error_type = 'invalid_request',
            recoverable = false,
        } --[[@as ContentErrorData]])
        return
    end

    local adapter_id = adapter_ids[selection]
    local api = get_adapter_api(adapter_id)

    if not api then
        events.emit('content.error', {
            ctx_id = ctx_id,
            nav_id = '',
            msg = 'Selected adapter not found: ' .. adapter_id,
            adapter_id = adapter_id,
            error_type = 'internal',
            recoverable = false,
        } --[[@as ContentErrorData]])
        return
    end

    events.emit('msg.debug.content', { msg = {
        'User selected adapter:', adapter_id,
    } })

    events.emit('content.loading', {
        ctx_id = ctx_id,
        nav_id = hh_utils.encode_content_nav_id(adapter_id, ''),
        adapter_id = adapter_id,
    } --[[@as ContentLoadingData]])

    events.emit(api.events.request, {
        ctx_id = ctx_id,
        nav_id = '',
        adapter_id = adapter_id,
    } --[[@as AdapterRequestData]])
end

---Route content request to the appropriate adapter.
---@param ctx_id NavCtxID
---@param nav_id string
---@param selection number
local function handle_navigation_request(ctx_id, nav_id, selection)
    local adapter_id, adapter_nav_id = hh_utils.decode_content_nav_id(nav_id)

    if adapter_id == '' then
        events.emit('content.error', {
            ctx_id = ctx_id,
            nav_id = nav_id,
            msg = 'Invalid nav_id format (expected adapter_id://location)',
            adapter_id = '',
            error_type = 'invalid_request',
            recoverable = false,
        } --[[@as ContentErrorData]])
        return
    end

    local api = get_adapter_api(adapter_id)
    if not api then
        events.emit('content.error', {
            ctx_id = ctx_id,
            nav_id = nav_id,
            msg = 'Adapter not available: ' .. adapter_id,
            adapter_id = adapter_id,
            error_type = 'adapter_not_found',
            recoverable = false,
        } --[[@as ContentErrorData]])
        return
    end

    events.emit('msg.debug.content', { msg = {
        'Routing request to:', adapter_id, 'location:', adapter_nav_id
    } })

    events.emit('content.loading', {
        ctx_id = ctx_id,
        nav_id = nav_id,
        adapter_id = adapter_id,
    } --[[@as ContentLoadingData]])

    events.emit(api.events.navigate_to, {
        ctx_id = ctx_id,
        nav_id = adapter_nav_id,
        selection = selection,
    } --[[@as AdapterNavToData]])
end

---@type HandlerTable
local handlers = {

    -- Content requests from UI

    ---@param event_name EventName
    ---@param data ContentRequestData|EventData|nil
    ['content.request'] = function(event_name, data)
        if not data or not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'content')
            return
        end

        if not data.nav_id or data.nav_id == '' then
            if not data.selection or data.selection == 0 then
                handle_root_request(data.ctx_id)
            else
                handle_adapter_selection(data.ctx_id, data.selection)
            end
        else
            -- Navigate to specific location
            -- TODO: handle missing selection
            handle_navigation_request(data.ctx_id, data.nav_id, data.selection or 1)
        end
    end,

    -- Adapter registration and lifecycle events
    -- (Called by adapters, not by content controller)

    ---@param event_name EventName
    ---@param data AdapterAPI|EventData|nil
    ['content.register_adapter'] = function(event_name, data)
        if not data
            or not data.adapter_id
            or not data.adapter_type
            or not data.events
            or not data.capabilities
        then
            hh_utils.emit_data_error(event_name, data, 'content')
            return
        end

        content_state.adapter_apis[data.adapter_id] = data

        events.emit('msg.info.content', { msg = {
            'Registered adapter:', data.adapter_id, '(type:', data.adapter_type, ')'
        } })
    end,

    ---@param event_name EventName
    ---@param data AdapterAPI|EventData|nil
    ['content.adapter_activate'] = function(event_name, data)
        if not data or not data.adapter_id then
            hh_utils.emit_data_error(event_name, data, 'content')
            return
        end

        events.emit('msg.info.content', { msg = {
            'Adapter ready:', data.adapter_id
        } })

        -- Set as active
        content_state.active_adapters[data.adapter_id] = true
    end,

    ---@param event_name EventName
    ---@param data AdapterAPI|EventData|nil
    ['content.adapter_deactivate'] = function (event_name, data)
        if not data or not data.adapter_id then
            hh_utils.emit_data_error(event_name, data, 'content')
            return
        end

        if content_state.active_adapters[data.adapter_id] then
            events.emit('msg.info.content', { msg = {
                'Deactivating adapter:', data.adapter_id
            } })
            content_state.active_adapters[data.adapter_id] = false
        else
            events.emit('msg.warn.content', { msg = {
                'Deactivation request for inactive adapter:', data.adapter_id
            } })
        end
    end,

    ---@param event_name EventName
    ---@param data AdapterErrorData|EventData|nil
    ['content.adapter_error'] = function (event_name, data)
        if not data or not data.adapter_id then
            hh_utils.emit_data_error(event_name, data, 'content')
            return
        end

        events.emit('msg.error.content', { msg = {
            'Adapter error:', data.adapter_id, '-', data.error or 'Unknown error'
        } })
    end,
}

---Main content event handler.
---@param event_name EventName
---@param data EventData
local function handler(event_name, data)
    hh_utils.handler_template(event_name, data, handlers, 'content')
end

function content.init()
    for event in pairs(handlers) do
        events.on(event, handler, 'content')
    end

    events.emit('msg.info.content', { msg = {
        'Content controller initialized.'
    } })
end

function content.cleanup()
    events.cleanup_component('content')
end

return content
