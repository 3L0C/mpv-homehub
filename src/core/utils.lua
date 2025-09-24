--[[
--  Utility functions
--]]

local utils = require 'mp.utils'

local events = require 'src.core.events'

---@alias HandlerTable table<EventName,ListenerCB>

---@class hh_utils
local hh_utils = {}

---Key bind helper.
---@param keys string[]
---@param event_name EventName
---@param ctx? InputCtx
---@param flags? InputFlags
---@return boolean
function hh_utils.bind_keys(keys, event_name, ctx, flags)
    if type(keys) ~= 'table' then
        events.emit('msg.error.hh_utils', { msg = {
            'Expected a list of key strings, got:', utils.to_string(keys)
        } })
        return false
    end

    for _, key in ipairs(keys) do
        events.emit('input.bind', {
            key = key,
            event = event_name,
            ctx = ctx or {},
            flags = flags or {},
        } --[[@as InputData]])
    end

    return true
end

---Key unbind helper.
---@param keys string[]
---@return boolean
function hh_utils.unbind_keys(keys)
    if type(keys) ~= 'table' then
        events.emit('msg.error.hh_utils', { msg = {
            'Expected a list of key strings, got:', utils.to_string(keys)
        } })
        return false
    end

    for _, key in ipairs(keys) do
        events.emit('input.unbind', {
            key = key,
            event = '',
            ctx = {},
            flags = {},
        } --[[@as InputData]])
    end

    return true
end

---Handler template for various controllers.
---@param event_name EventName
---@param data EventData
---@param handlers HandlerTable
---@param component ComponentName
function hh_utils.handler_template(event_name, data, handlers, component)
    local fn = handlers[event_name]
    if type(fn) ~= 'function' then
        events.emit('msg.warn.' .. component, { msg = {
            'Got unhandled event:', event_name
        } })
    else
        local success, err = pcall(fn, event_name, data)
        if not success then
            events.emit('msg.error.' .. component, {msg = err})
        else
            events.emit('msg.debug.' .. component, { msg = {
                ("Handled event '%s' with data '%s'."):format(event_name, utils.to_string(data))
            } })
        end
    end
end

return hh_utils
