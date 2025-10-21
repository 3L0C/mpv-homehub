--[[
--  Utility functions
--]]

local mp = require 'mp'
local utils = require 'mp.utils'

local events = require 'src.core.events'

---@alias HandlerTable table<EventName,ListenerCB>

---@class hh_utils
local hh_utils = {}

---Read and parse JSON file at the given path.
---@param file_path string Path to JSON file (supports mpv path expansion like ~~/)
---@return table? data Parsed JSON data (nil on failure)
---@return string? error Error message if read/parse failed
function hh_utils.read_json_file(file_path)
    local expanded_path = mp.command_native({'expand-path', file_path}) --[[@as string]]

    local file, io_err = io.open(expanded_path, 'r')
    if not file then
        return nil, ("Could not open file '%s': %s"):format(file_path, io_err)
    end

    local content = file:read('*a')
    file:close()

    local data = utils.parse_json(content)
    if not data then
        return nil, ("Invalid JSON syntax in '%s'"):format(file_path)
    end

    if type(data) ~= 'table' then
        return nil, ("Expected JSON object or array in '%s', got %s"):format(
            file_path,
            type(data)
        )
    end

    return data, nil
end

---Validate data and emit error if invalid
---@param event_name EventName
---@param data EventData|nil
---@param validator fun(data: any): boolean
---@param controller string
---@return boolean valid
function hh_utils.validate_data(event_name, data, validator, controller)
    if not validator(data) then
        hh_utils.emit_data_error(event_name, data, controller)
        return false
    end
    return true
end

---Is `data` received during `content.loaded` event.
---@param data ContentLoadedData|EventData
---@return boolean
function hh_utils.is_content_loaded(data)
    return  type(data) == 'table'
        and type(data.ctx_id) == 'string'
        and type(data.nav_id) == 'string'
        and type(data.items) == 'table'
end

---Encode `prefix` and `rest` into a valid nav_id.
---Format: "prefix://rest"
---@param prefix string
---@param rest string
---@return NavID
function hh_utils.encode_nav_id(prefix, rest)
    return prefix .. '://' .. (rest or '')
end

---Decode nav_id into `prefix` and `rest`.
---Format: "prefix://rest"
---@param nav_id NavID
---@return NavIDParts
function hh_utils.decode_nav_id(nav_id)
    if not nav_id or nav_id == '' then
        return {
            prefix = '',
            rest = '',
        } --[[@as NavIDParts]]
    end
    local prefix, rest = nav_id:match('^(.-)://(.*)$')
    return {
        prefix = prefix or '',
        rest = rest or '',
    } --[[@as NavIDParts]]
end

---Is `data` valid NavSelectedData type.
---@param data any
---@return boolean
function hh_utils.is_nav_selected(data)
    return type(data) == 'table'
        and type(data.ctx_id) == 'string'
        and type(data.nav_id) == 'string'
        and type(data.position) == 'number'
end

---Is `data` valid NavNavigateToData type.
---@param data any
---@return boolean
function hh_utils.is_nav_navigate_to(data)
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

---Is `data` valid NavNavigateToData type.
---@param data any
---@return boolean
function hh_utils.is_nav_navigated_to(data)
    return type(data) == 'table'
        and type(data.ctx_id) == 'string'
        and type(data.nav_id) == 'string'
        and type(data.columns) == 'number'
        and type(data.position) == 'number'
        and type(data.total_items) == 'number'
        and type(data.trigger) == 'string'
        and data.columns >= 1
        and data.position >= 1
        and data.total_items >= 0
        and (data.total_items == 0 or data.position <= data.total_items)
end

---Wrapper for `events.emit('msg.error.controller')` when data is invalid.
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
---@param group_name InputGroup 
---@param ctx? InputCtx
---@param flags? InputFlags
---@return boolean
function hh_utils.bind_keys(keys, event_name, group_name, ctx, flags)
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
            group = group_name,
            ctx = ctx or {},
            flags = flags or {},
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
        events.emit('msg.debug.' .. component, { msg = {
            ("Got event '%s' with data '%s'."):format(event_name, utils.to_string(data))
        } })
        local success, err = pcall(fn, event_name, data)
        if not success then
            events.emit('msg.error.' .. component, { msg = err })
        else
            events.emit('msg.trace.' .. component, { msg = {
                ("Successfully handled event '%s'."):format(event_name)
            } })
        end
    end
end

return hh_utils
