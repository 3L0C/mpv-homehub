--[[
--  Content controller.
--]]

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local log = require 'src.core.log'

---@class content: Controller
local content = {}

---@class ContentState
---@field adapter_apis table<AdapterID, AdapterAPI> Registered adapters
local content_state = {
    adapter_apis = {},
}

---Get adapter API by adapter_id.
---@param adapter_id AdapterID
---@return AdapterAPI?
local function get_adapter_api(adapter_id)
    return content_state.adapter_apis[adapter_id]
end

---Get registered adapter ids.
---@return AdapterID[]
local function get_registered_adapter_ids()
    ---@type AdapterID[]
    local ids = {}

    for id, api in pairs(content_state.adapter_apis) do
        if api then
            table.insert(ids, id)
        end
    end

    table.sort(ids)

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

    log.debug('content', {
        'Single adapter - requesting root content from:', adapter_id
    })

    events.emit(api.events.request, {
        ctx_id = ctx_id,
        nav_id = '',
        adapter_id = adapter_id,
    } --[[@as AdapterRequestData]])
end


---Request root content from all registered adapters.
---@param ctx_id NavCtxID
local function handle_root_request(ctx_id)
    local adapter_ids = get_registered_adapter_ids()

    if #adapter_ids == 0 then
        log.warn('content', {
            'Unable to access root content, no registered adapters.'
        })
        return
    elseif #adapter_ids == 1 then
        handle_adapter_root_request(ctx_id, adapter_ids[1])
        return
    end

    -- Multiple adapters - create menu
    ---@type Item[]
    local items = {}
    for _, adapter_id in ipairs(adapter_ids) do
        local api = get_adapter_api(adapter_id)
        if api then
            table.insert(items, {
                lines = {
                    api.adapter_name,
                    api.adapter_type,
                },
            } --[[@as Item]])
        end
    end

    if #items == 0 then
        log.warn('content', {
            'No valid adapters found for root menu.'
        })
        return
    elseif #items == 1 then
        -- Edge case: multiple adapter_ids but only one valid API
        -- Just go directly to that adapter
        handle_adapter_root_request(ctx_id, adapter_ids[1])
        return
    end

    events.emit('content.loaded', {
        ctx_id = ctx_id,
        nav_id = '',
        items = items,
        adapter_name = 'Adapters',
        content_title = '',
    } --[[@as ContentLoadedData]])
end

---Request root content from specific adapter (user selected from menu).
---@param ctx_id NavCtxID
---@param selection number
local function handle_adapter_selection(ctx_id, selection)
    local adapter_ids = get_registered_adapter_ids()

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

    log.debug('content', {
        'User selected adapter:', adapter_id,
    })

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
    local nav_id_parts = hh_utils.decode_nav_id(nav_id)
    local adapter_id, adapter_nav_id = nav_id_parts.prefix, nav_id_parts.rest

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

    log.debug('content', {
        'Routing request to:', adapter_id, 'location:', adapter_nav_id
    })

    events.emit(api.events.navigate_to, {
        ctx_id = ctx_id,
        nav_id = adapter_nav_id,
        adapter_id = api.adapter_id,
        selection = selection,
    } --[[@as AdapterNavToData]])
end

---@type HandlerTable
local handlers = {

    -- Content requests from Navigation controller

    ---@param event_name EventName
    ---@param data ContentRequestData|EventData
    ['content.request'] = function(event_name, data)
        if not data.ctx_id or not data.nav_id then
            hh_utils.emit_data_error(event_name, data, 'content')
            return
        end

        if data.nav_id == '' then
            handle_root_request(data.ctx_id)
            return
        end

        local nav_id_parts = hh_utils.decode_nav_id(data.nav_id)
        local adapter_id, adapter_nav_id = nav_id_parts.prefix, nav_id_parts.rest
        local api = get_adapter_api(adapter_id)
        if not api then
            events.emit('content.error', {
                ctx_id = data.ctx_id,
                nav_id = adapter_nav_id,
                msg = 'Adapter not available: ' .. adapter_id,
                adapter_id = adapter_id,
                error_type = 'adapter_not_found',
                recoverable = false,
            } --[[@as ContentErrorData]])
            return
        end

        events.emit(api.events.request, {
            ctx_id = data.ctx_id,
            nav_id = adapter_nav_id,
            force = data.force,
            adapter_id = adapter_id,
        } --[[@as AdapterRequestData]])
    end,

    ---@param event_name EventName
    ---@param data ContentNavToData|EventData
    ['content.navigate_to'] = function(event_name, data)
        if not data.ctx_id or not data.nav_id or not data.selection then
            hh_utils.emit_data_error(event_name, data, 'content')
            return
        end

        if data.nav_id == '' then
            handle_adapter_selection(data.ctx_id, data.selection)
        else
            handle_navigation_request(data.ctx_id, data.nav_id, data.selection)
        end
    end,

    -- Adapter registration and lifecycle events

    ---@param event_name EventName
    ---@param data AdapterAPI|EventData
    ['content.register_adapter'] = function(event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_adapter_api, 'content') then
            return
        end

        content_state.adapter_apis[data.adapter_id] = data

        log.info('content', {
            'Registered adapter:', data.adapter_id, '(type:', data.adapter_type, ')'
        })
    end,

    ---@param event_name EventName
    ---@param data AdapterAPI|EventData
    ['content.unregister_adapter'] = function(event_name, data)
        if not data.adapter_id then
            hh_utils.emit_data_error(event_name, data, 'content')
            return
        end

        if content_state.adapter_apis[data.adapter_id] then
            log.info('content', {
                'Unregistering adapter:', data.adapter_id
            })
            content_state.adapter_apis[data.adapter_id] = nil
        else
            log.warn('content', {
                'Unregister request for unknown adapter:', data.adapter_id
            })
        end
    end,

    ---@param event_name EventName
    ---@param data AdapterErrorData|EventData
    ['content.adapter_error'] = function(event_name, data)
        if not data.adapter_id then
            hh_utils.emit_data_error(event_name, data, 'content')
            return
        end

        log.error('content', {
            'Adapter error:', data.adapter_id, '-', data.error or 'Unknown error'
        })
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

    log.info('content', {
        'Content controller initialized.'
    })
end

function content.cleanup()
    events.cleanup_component('content')
end

return content
