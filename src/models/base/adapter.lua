--[[
--  Adapter manager - loads and initializes content provider adapters
--]]

local mp = require 'mp'
local msg = require 'mp.msg'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local options = require 'src.core.options'

---@class adapter_manager
local adapter_manager = {}

---API version for adapters
local API_VERSION = '1.0.0'
local API_MAJOR, API_MINOR, API_PATCH = API_VERSION:match('(%d+)%.(%d+)%.(%d+)')
API_MAJOR, API_MINOR, API_PATCH = tonumber(API_MAJOR), tonumber(API_MINOR), tonumber(API_PATCH)

---Loaded adapter instances
---@type table<AdapterID, Adapter>
local loaded_adapters = {}

---Prints an error message and a stack trace.
---Can be passed directly to xpcall.
---@param errmsg string
---@param co? thread A coroutine to grab the stack trace from.
local function adapter_traceback(errmsg, co)
    if co then
        msg.warn(debug.traceback(co))
    else
        msg.warn(debug.traceback("", 2))
    end
    msg.error(errmsg)
end

---Create a prototypally inherited table
---@generic T: table
---@param t T
---@return T
local function redirect_table(t)
    return setmetatable({}, { __index = t })
end

---Check if adapter has valid API version
---@param adapter_module Adapter
---@param adapter_id AdapterID
---@return boolean
local function check_api_version(adapter_module, adapter_id)
    local version = adapter_module.api_version
    if type(version) ~= 'string' then
        events.emit('msg.error.adapter', { msg = {
            adapter_id .. ': field `api_version` must be a string, got', type(version)
        } })
        return false
    end

    local major, minor = version:match('(%d+)%.(%d+)')
    major, minor = tonumber(major), tonumber(minor)

    if not major or not minor then
        events.emit('msg.error.adapter', { msg = {
            ('%s: invalid version number, expected v%d.%d.x got v%s'):format(
                adapter_id, API_MAJOR, API_MINOR, version
            )
        } })
        return false
    elseif major ~= API_MAJOR then
        events.emit('msg.error.adapter', { msg = {
            ('%s: has wrong major version, expected v%d.x.x, got v%s'):format(
                adapter_id, API_MAJOR, version
            )
        } })
        return false
    elseif minor > API_MINOR then
        events.emit('msg.warn.adapter', { msg = {
            ('%s: has newer minor version than API, expected v%d.%d.x, got v%s'):format(
                adapter_id, API_MAJOR, API_MINOR, version
            )
        } })
    end

    return true
end

---Create sandboxed environment for adapter
---@param adapter_id AdapterID
---@return table
local function create_adapter_environment(adapter_id)
    local env = redirect_table(_G)
    ---@diagnostic disable-next-line inject-field
    env._G = env 

    -- Redirect package to prevent pollution
    ---@diagnostic disable-next-line inject-field
    env.package = redirect_table(env.package)
    env.package.loaded = redirect_table(env.package.loaded)

    -- Create namespaced message module
    local name_tag = ('[%s]'):format(adapter_id)
    local msg_module = {
        log = function(level, ...) msg.log(level, name_tag, ...) end,
        fatal = function(...) return msg.fatal(name_tag, ...) end,
        error = function(...) return msg.error(name_tag, ...) end,
        warn = function(...) return msg.warn(name_tag, ...) end,
        info = function(...) return msg.info(name_tag, ...) end,
        verbose = function(...) return msg.verbose(name_tag, ...) end,
        debug = function(...) return msg.debug(name_tag, ...) end,
        trace = function(...) return msg.trace(name_tag, ...) end,
    }
    ---@diagnostic disable-next-line inject-field
    env.print = msg_module.info
    ---@diagnostic disable-next-line inject-field
    env.require = function(module)
        if module == 'mp.msg' then return msg_module end
        return require(module)
    end

    return env
end

---Load adapter from file path
---@param file_path string
---@param adapter_id AdapterID
---@return table? adapter_module
local function load_adapter_file(file_path, adapter_id)
    local env = create_adapter_environment(adapter_id)

    ---@type function?, string?
    local chunk, err
    ---@diagnostic disable-next-line deprecated
    if setfenv then
        chunk, err = loadfile(file_path)
        if not chunk then
            events.emit('msg.error.adapter', { msg = {
                'Failed to load adapter file:', err
            } })
            return nil
        end
        ---@diagnostic disable-next-line deprecated
        setfenv(chunk, env)
    else
        chunk, err = loadfile(file_path, 'bt', env)
        if not chunk then
            events.emit('msg.error.adapter', { msg = {
                'Failed to load adapter file:', err
            } })
            return nil
        end
    end

    local success, result = xpcall(chunk, adapter_traceback)
    return success and result or nil
end

---Validate adapter configuration
---@param config AdapterConfig
---@return boolean valid
---@return string? error_msg
local function validate_config(config)
    if not config.id or type(config.id) ~= 'string' then
        return false, 'missing or invalid id field'
    end

    if not config.display_name or type(config.display_name) ~= 'string' then
        return false, 'missing or invalid display_name field'
    end

    return true
end

---Get file path for adapter
---@param config AdapterConfig
---@return string? file_path
local function get_adapter_file_path(config)
    -- External adapter with explicit file_path
    if config.file_path then
        return mp.command_native({'expand-path', config.file_path})
    end

    -- External adapter with implied location
    if config.external then
        return mp.command_native({'expand-path', '~~/script-opts/homehub/' .. config.id .. '.lua'})
    end

    -- Internal adapter - construct path from script directory
    local script_dir = mp.get_script_directory()
    if not script_dir then
        events.emit('msg.error.adapter', { msg = {
            'Cannot load adapter - script not running as directory script'
        } })
        return nil
    end

    return script_dir .. '/src/models/adapters/' .. config.type .. '/main.lua'
end

---Load a specific adapter
---@param config AdapterConfig
---@return boolean success
local function load_adapter(config)
    -- Validate configuration
    local valid, err = validate_config(config)
    if not valid then
        events.emit('msg.error.adapter', { msg = {
            'Invalid adapter config for', tostring(config.id or 'unknown'), ':', err
        } })
        return false
    end

    if not config.enabled then
        events.emit('msg.verbose.adapter', { msg = {
            'Skipping disabled adapter:', config.id
        } })
        return true
    end

    -- Check if already loaded
    if loaded_adapters[config.id] then
        events.emit('msg.warn.adapter', { msg = {
            'Adapter already loaded:', config.id
        } })
        return true
    end

    -- Get file path
    local file_path = get_adapter_file_path(config)
    if not file_path then
        events.emit('msg.error.adapter', { msg = {
            'Could not determine file path for adapter:', config.id
        } })
        return false
    end

    -- Load the adapter file in sandboxed environment
    events.emit('msg.verbose.adapter', { msg = {
        'Loading adapter:', config.id, 'from', file_path
    } })

    local adapter_module = load_adapter_file(file_path, config.id)
    if not adapter_module then
        return false
    end

    -- Check API version
    if not check_api_version(adapter_module, config.id) then
        events.emit('msg.error.adapter', { msg = {
            'Aborting load of adapter', config.id, 'due to version mismatch'
        } })
        return false
    end

    -- Verify the module has an init function
    if type(adapter_module.init) ~= 'function' then
        events.emit('msg.error.adapter', { msg = {
            'Adapter', config.id, 'missing init function'
        } })
        return false
    end

    -- Initialize the adapter
    events.emit('msg.verbose.adapter', { msg = {
        'Initializing adapter:', config.id, '(type:', config.type, ')'
    } })

    local success, result = xpcall(
        function() return adapter_module.init(config) end,
        adapter_traceback
    )

    if not success then
        events.emit('msg.error.adapter', { msg = {
            'Failed to initialize adapter', config.id, ':', tostring(result)
        } })
        return false
    end

    -- Check if init failed
    if result == false then
        events.emit('msg.error.adapter', { msg = {
            'Adapter', config.id, 'initialization failed.'
        } })
        return false
    end

    -- Store the adapter instance
    loaded_adapters[config.id] = adapter_module

    events.emit('msg.info.adapter', { msg = {
        'Successfully loaded adapter:', config.id
    } })

    return true
end

---Load all configured adapters from options
function adapter_manager.load_adapters()
    if not options.adapter_config_file then
        events.emit('msg.warn.adapter', { msg = {
            'No defined adapter configuration file.'
        } })
        return
    end

    if type(options.adapter_config_file) ~= 'string' then
        events.emit('msg.error.adapter', { msg = {
            'Expected `adapter_config_file` to be a string, got:', type(options.adapter_config_file)
        } })
        return
    end

    ---@type AdapterConfig[]?, string?
    local adapter_configs, err = hh_utils.read_json_file(options.adapter_config_file)
    if not adapter_configs then
        events.emit('msg.error.adapter', { msg = {
            'Failed to load adapter configuration:', err
        } })
        return
    end

    for _, config in ipairs(adapter_configs) do
        load_adapter(config)
    end
end

---Get adapter manager API version
---@return string
function adapter_manager.get_api_version()
    return API_VERSION
end

---Get all loaded adapter IDs
---@return AdapterID[]
function adapter_manager.get_loaded_adapter_ids()
    local ids = {}

    for id in pairs(loaded_adapters) do
        table.insert(ids, id)
    end

    return ids
end

---Cleanup all loaded adapters
function adapter_manager.cleanup()
    for adapter_id, adapter in pairs(loaded_adapters) do
        if type(adapter.cleanup) == 'function' then
            events.emit('msg.verbose.adapter', { msg = {
                'Cleaning up adapter:', adapter_id
            } })

            -- Use pcall to ensure one failing cleanup doesn't break others
            local success, err = pcall(adapter.cleanup)
            if not success then
                events.emit('msg.error.adapter', { msg = {
                    'Error cleaning up adapter', adapter_id, ':', tostring(err)
                } })
            end
        end
    end
    loaded_adapters = {}

    events.emit('msg.debug.adapter', { msg = {
        'Adapter manager cleanup complete'
    } })
end

return adapter_manager
