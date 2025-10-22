--[[
--  Low level logging interface for HomeHub
--]]

local msg = require 'mp.msg'
local utils = require 'mp.utils'

---@alias LoggerFun fun(message: string)
---@alias LoggerHandler table<string,LoggerFun>

---@class logger
local logger = {
    ---@type LoggerHandler
    handlers = {
        ['debug'] = function(message) msg.debug(message) end,
        ['error'] = function(message) msg.error(message) end,
        ['fatal'] = function(message) msg.fatal(message) end,
        ['trace'] = function(message) msg.trace(message) end,
        ['info'] = function(message) msg.info(message) end,
        ['warn'] = function(message) msg.warn(message) end,
        ['verbose'] = function(message) msg.verbose(message) end,
    }
}

---Main event handler.
---@param event_name string
---@param data MessengerData
function logger.log(event_name, data)
    if not event_name:match('^msg%.') then
        msg.error('[Logger] Got unrecognized event:', event_name, 'data:', utils.to_string(data))
        return
    end

    if not data.msg then
        msg.error('[Logger] Got invalid event data:', utils.to_string(data))
        return
    end

    local level, component = event_name:match('^msg%.([^%.]+)%.?(.*)$')
    component = component ~= '' and component or 'unknown'

    ---@type string
    local message = ('[%s] '):format(component)

    if type(data.msg) == 'string' then
        message = message .. data.msg
    elseif type(data.msg) == 'table' then
        message =  message .. table.concat(data.msg --[=[@as string[]]=], data.separator or ' ')
    else
        msg.error('[Logger] Invalid msg field type:',
                  type(data.msg),
                  'expected string or array of strings')
        return
    end

    local fn = logger.handlers[level]
    if not fn or type(fn) ~= 'function' then
        msg.error('[Logger] Got invalid message level:', level)
        return
    end

    local success, err = pcall(fn, message)
    if not success then
        msg.error('[Logger] Handler error for level', level, ':', err)
    end
end

return logger
