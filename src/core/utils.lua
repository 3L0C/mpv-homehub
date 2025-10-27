--[[
--  Utility functions
--]]

local mp = require 'mp'
local utils = require 'mp.utils'

local events = require 'src.core.events'
local log = require 'src.core.log'

---@class hh_utils
---@field separator string
local hh_utils = {
    separator = '────────────────────────────────',
}

---Coroutine utilities namespace
hh_utils.coroutine = {}

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

--------------------
-- Search validation
--------------------

---Is `data` SearchResultsData object
---@param data SearchResultsData|EventData
---@return boolean
function hh_utils.is_search_results(data)
    return type(data) == 'table'
        and type(data.query) == 'string'
        and type(data.filtered_items) == 'table'
        and type(data.match_indices) == 'table'
        and type(data.total_matches) == 'number'
        and type(data.current_position) == 'number'
        and type(data.current_item) == 'table'
        and type(data.current_original_index) == 'number'
end

---Is `data` a SearchPositionChangedData object
---@param data SearchPositionChangedData|EventData
---@return boolean
function hh_utils.is_search_pos_changed(data)
    return type(data) == 'table'
        and type(data.position) == 'number'
        and type(data.total) == 'number'
        and type(data.current_item) == 'table'
        and type(data.current_original_index) == 'number'
end

---Is `data` a SearchCompletedData object
---@param data SearchCompletedData|EventData
---@return boolean
function hh_utils.is_search_completed(data)
    return type(data) == 'table'
        and type(data.query) == 'string'
        and type(data.selected_index) == 'number'
end

---Is `data` a SearchCancelledData object
---@param data SearchCancelledData|EventData
---@return boolean
function hh_utils.is_search_cancelled(data)
    return type(data) == 'table'
        and type(data.query or '') == 'string'
end

---Is `data` a SearchNoResultsData object
---@param data SearchNoResultsData|EventData
---@return boolean
function hh_utils.is_search_no_results(data)
    return type(data) == 'table'
        and type(data.query) == 'string'
end

---------------------
-- Adapter validation
---------------------

---Is `data` an AdapterRequestData object
---@param data AdapterRequestData|EventData
---@return boolean
function hh_utils.is_adapter_request(data)
    return type(data) == 'table'
        and type(data.ctx_id) == 'string'
        and type(data.nav_id) == 'string'
        and type(data.adapter_id) == 'string'
end

---Is `data` an AdapterNavToData object
---@param data AdapterNavToData|EventData
---@return boolean
function hh_utils.is_adapter_nav_to(data)
    return type(data) == 'table'
        and type(data.ctx_id) == 'string'
        and type(data.nav_id) == 'string'
        and type(data.adapter_id) == 'string'
        and type(data.selection) == 'number'
end

---Is `map` a valid event map.
---@param map? AdapterEventMap
---@return boolean
function hh_utils.is_event_map(map)
    return type(map) == 'table'
        and type(map.request) == 'string'
        and type(map.navigate_to) == 'string'
        and type(map.next) == 'string'
        and type(map.prev) == 'string'
end

---Is `capabilities` a valid AdapterCapabilities object.
---@param capabilities? AdapterCapabilities
---@return boolean
function hh_utils.is_adapter_capabilities(capabilities)
    return type(capabilities) == 'table'
        and type(capabilities.supports_search) == 'boolean'
        and type(capabilities.supports_thumbnails) == 'boolean'
        and type(capabilities.media_types) == 'table'
end

---Is `data` received during `content.register_adapter` event valid.
---@param data? AdapterAPI
function hh_utils.is_adapter_api(data)
    return type(data) == 'table'
        and type(data.adapter_id) == 'string'
        and type(data.adapter_type) == 'string'
        and hh_utils.is_event_map(data.events)
        and hh_utils.is_adapter_capabilities(data.capabilities)
end

---------------------
-- Content validation
---------------------

---Is `data` received during `content.loaded` event.
---@param data? ContentLoadedData
---@return boolean
function hh_utils.is_content_loaded(data)
    return  type(data) == 'table'
        and type(data.ctx_id) == 'string'
        and type(data.nav_id) == 'string'
        and type(data.items) == 'table'
        and type(data.adapter_name) == 'string'
        and type(data.content_title) == 'string'
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

------------------------
-- Navigation validation
------------------------

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

---Wrapper for `log.error(...)` when data is invalid.
---@param event_name EventName
---@param data EventData|nil
---@param controller string
function hh_utils.emit_data_error(event_name, data, controller)
    log.error(controller, {
        ("Received invalid data to '%s' request:"):format(event_name),
        utils.to_string(data)
    })
end

---Concatenate two arrays into a new array.
---@generic T
---@param array1 T[]
---@param array2 T[]
---@return T[]
function hh_utils.table_concat(array1, array2)
    local result = {}
    for _, v in ipairs(array1) do
        table.insert(result, v)
    end
    for _, v in ipairs(array2) do
        table.insert(result, v)
    end
    return result
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
        log.error('hh_utils', {
            'Expected a list of key strings, got:', utils.to_string(keys)
        })
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

---@alias HandlerTable table<EventName,ListenerCB>
---
---Handler template for various controllers.
---@param event_name EventName
---@param data EventData
---@param handlers HandlerTable
---@param component ComponentName
function hh_utils.handler_template(event_name, data, handlers, component)
    local fn = handlers[event_name]

    if type(fn) ~= 'function' then
        log.warn(component, {
            'Got unhandled event:', event_name
        })
    else
        if log.log_level >= log.log_levels.trace then
            log.trace(component, {
                ("Got event '%s' with data: %s"):format(event_name, utils.to_string(data))
            })
        else
            log.debug(component, {
                'Handling event:', event_name
            })
        end

        local success, err = pcall(fn, event_name, data)
        if not success then
            log.error(component, err or 'unknown')
        else
            log.trace(component, {
                'Successfully handled event:', event_name
            })
        end
    end
end

-- ============================================================================
-- Coroutine Utilities
-- ============================================================================
-- These utilities are adapted from mpv-file-browser's coroutine helpers
-- https://github.com/CogentRedTester/mpv-file-browser/blob/master/modules/utils.lua

---Prints an error message and stack trace.
---Can be passed directly to xpcall or used for coroutine error handling.
---@param errmsg string Error message
---@param co? thread Optional coroutine to grab stack trace from
function hh_utils.traceback(errmsg, co)
    local msg = require 'mp.msg'
    if co then
        msg.warn(debug.traceback(co))
    else
        msg.warn(debug.traceback("", 2))
    end
    msg.error(errmsg)
end

---Resumes a coroutine and prints an error if it was not successful.
---Similar to coroutine.resume but with automatic error handling.
---@param co thread Coroutine to resume
---@param ... any Arguments to pass to the coroutine
---@return boolean success Whether the coroutine resumed successfully
function hh_utils.coroutine.resume_err(co, ...)
    local success, err = coroutine.resume(co, ...)
    if not success then
        hh_utils.traceback(err, co)
    end
    return success
end

---Throws an error if not run from within a coroutine.
---In lua 5.1 there is only one return value which will be nil if run from the main thread.
---In lua 5.2+ main will be true if running from the main thread.
---@param err? string Optional error message
---@return thread co The current coroutine
function hh_utils.coroutine.assert(err)
    local co, main = coroutine.running()
    assert(not main and co, err or "error - function must be executed from within a coroutine")
    return co
end

---Creates a callback function to resume the current coroutine.
---This is useful for async operations that need to resume the coroutine when complete.
---@param time_limit? number Optional timeout in seconds
---@return fun(...) callback Function that resumes the coroutine with the given arguments
function hh_utils.coroutine.callback(time_limit)
    local co = hh_utils.coroutine.assert("cannot create a coroutine callback for the main thread")
    local timer = time_limit and mp.add_timeout(time_limit, function()
        log.debug('coroutine', {
             'Time limit on callback expired'
        })
        hh_utils.coroutine.resume_err(co, false)
    end)

    local function fn(...)
        if timer then
            if not timer:is_enabled() then return
            else timer:kill() end
            return hh_utils.coroutine.resume_err(co, true, ...)
        end
        return hh_utils.coroutine.resume_err(co, ...)
    end
    return fn
end

---Puts the current coroutine to sleep for the given number of seconds.
---@async
---@param seconds number Duration to sleep in seconds
function hh_utils.coroutine.sleep(seconds)
    mp.add_timeout(seconds, hh_utils.coroutine.callback())
    coroutine.yield()
end

---Runs the given function in a new coroutine immediately.
---This is for triggering an async event in a coroutine.
---@param fn async fun(...) Async function to run
---@param ... any Arguments to pass to the function
---@return thread co The created coroutine
function hh_utils.coroutine.run(fn, ...)
    local co = coroutine.create(fn)
    hh_utils.coroutine.resume_err(co, ...)
    return co
end

---Runs the given function in a new coroutine on the next tick.
---Does not run the coroutine immediately, instead queues it to run when the thread is next idle.
---Returns the coroutine object so the caller can act on it before it runs.
---@param fn async fun(...) Async function to run
---@param ... any Arguments to pass to the function
---@return thread co The created coroutine
function hh_utils.coroutine.queue(fn, ...)
    local co = coroutine.create(fn)
    local args = table.pack(...)
    mp.add_timeout(0, function()
        hh_utils.coroutine.resume_err(co, table.unpack(args, 1, args.n))
    end)
    return co
end

---Implements table.pack for Lua 5.1 compatibility.
---In Lua 5.2+ this is built-in.
if not table.pack then
    table.unpack = unpack ---@diagnostic disable-line deprecated
    ---@diagnostic disable-next-line: duplicate-set-field
    function table.pack(...)
        return {n = select("#", ...), ...}
    end
end

return hh_utils
