--[[
--  Logging interface for HomeHub
--]]

local msg = require 'mp.msg'
local utils = require 'mp.utils'

---@alias LogLevel 'debug'|'error'|'fatal'|'trace'|'info'|'warn'|'verbose'

---@class log
local log = {}

---Format a log message with component prefix
---@param component string Component name (e.g., 'content', 'navigation', 'search')
---@param message string|string[] Message string or array of strings to concatenate
---@param separator string? Separator for string arrays (default: ' ')
---@return string formatted_message
local function format_message(component, message, separator)
    local prefix = ('[%s] '):format(component)

    if type(message) == 'string' then
        return prefix .. message
    elseif type(message) == 'table' then
        return prefix .. table.concat(message, separator or ' ')
    else
        msg.error('[log] Invalid message type:', type(message), 'expected string or string[]')
        return prefix .. utils.to_string(message)
    end
end

---Internal logging function
---@param level LogLevel
---@param component string
---@param message string|string[]
---@param separator string?
local function do_log(level, component, message, separator)
    local formatted = format_message(component, message, separator)

    local success, err = pcall(msg[level], formatted)
    if not success then
        msg.error('[log] Handler error for level', level, ':', err)
    end
end

---@param component string Component name
---@param message string|string[] Log message
---@param separator string? Separator for arrays (default: ' ')
function log.debug(component, message, separator)
    do_log('debug', component, message, separator)
end

---@param component string Component name
---@param message string|string[] Log message
---@param separator string? Separator for arrays (default: ' ')
function log.error(component, message, separator)
    do_log('error', component, message, separator)
end

---@param component string Component name
---@param message string|string[] Log message
---@param separator string? Separator for arrays (default: ' ')
function log.fatal(component, message, separator)
    do_log('fatal', component, message, separator)
end

---@param component string Component name
---@param message string|string[] Log message
---@param separator string? Separator for arrays (default: ' ')
function log.trace(component, message, separator)
    do_log('trace', component, message, separator)
end

---@param component string Component name
---@param message string|string[] Log message
---@param separator string? Separator for arrays (default: ' ')
function log.info(component, message, separator)
    do_log('info', component, message, separator)
end

---@param component string Component name
---@param message string|string[] Log message
---@param separator string? Separator for arrays (default: ' ')
function log.warn(component, message, separator)
    do_log('warn', component, message, separator)
end

---@param component string Component name
---@param message string|string[] Log message
---@param separator string? Separator for arrays (default: ' ')
function log.verbose(component, message, separator)
    do_log('verbose', component, message, separator)
end

return log
