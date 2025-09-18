--[[
--  Utility functions
--]]

local utils = require 'mp.utils'

local events = require 'src.core.events'

---@alias HandlerTable table<EventName,ListenerCB>

---@class hh_utils
local hh_utils = {}

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
