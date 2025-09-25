--[[
--  Utility functions
--]]

local utils = require 'mp.utils'

local events = require 'src.core.events'

---@alias HandlerTable table<EventName,ListenerCB>

---@class hh_utils
local hh_utils = {}

---Get valid NavToData for `nav.navigate_to` request.
---@param data any
---@return boolean
function hh_utils.is_valid_nav_to_data(data)
    return type(data) == 'table'
        and type(data.ctx_id) == 'string'
        and type(data.nav_id) == 'string'
        and type(data.columns) == 'number'
        and type(data.position) == 'number'
        and type(data.total_items) == 'number'
        and data.columns >= 1
        and data.position >= 0
        and data.total_items >= 0
        and (data.total_items == 0 or data.position <= data.total_items)
end

---Wrapper for `events.emit('msg.error.navigation')` when data is invalid.
---@param event_name EventName
---@param data EventData|nil
---@param controller string
function hh_utils.emit_data_error(event_name, data, controller)
    events.emit('msg.error.' .. controller, { msg = {
        ("Received invalid data to '%s' request:"):format(event_name),
        utils.to_string(data)
    } })
end

---Formats strings for ass handling.
---This function is taken from the `mpv-file-browser` project.
---https://github.com/CogentRedTester/mpv-file-browser/blob/master/modules/utils.lua#L245
---@param str string
---@param replace_newline? true|string
---@return string
function hh_utils.ass_escape(str, replace_newline)
    if not str then return '' end

    if replace_newline == true then
        replace_newline = "\\\239\187\191n"
    end

    -- Escape the invalid single characters
    str = string.gsub(str, '[\\{}\n]', {
        -- There is no escape for '\' in ASS (I think?) but '\' is used verbatim if
        -- it isn't followed by a recognised character, so add a zero-width
        -- non-breaking space
        ['\\'] = '\\\239\187\191',
        ['{'] = '\\{',
        ['}'] = '\\}',
        -- Precede newlines with a ZWNBSP to prevent ASS's weird collapsing of
        -- consecutive newlines
        ['\n'] = '\239\187\191\\N',
    })

    -- Turn leading spaces into hard spaces to prevent ASS from stripping them
    str = str:gsub('\\N ', '\\N\\h')
    str = str:gsub('^ ', '\\h')

    if replace_newline then
        str = string.gsub(str, "\\N", replace_newline)
    end

    return str
end

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
