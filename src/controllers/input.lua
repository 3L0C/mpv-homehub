--[[
    Input controller
]]

local mp = require "mp"
local utils = require 'mp.utils'

local events = require "src.core.events"

---@class input
local input = {}

---@class KeybindFlags
---@field repeatable boolean?
---@field scalable boolean?
---@field complex boolean?
---
---@class InputBind
---@field event string
---@field name string
---@field flags? KeybindFlags

---@alias binding_stack table<string,InputBind[]>
local binding_stack = {}

---@class InputData
---@field key? string
---@field event? string
---@field flags? KeybindFlags

---Test if `key` and `event` are valid bind requests.
---@param key string
---@param event string
---@return boolean
local function is_valid_bind(key, event)
    return key ~= '' and event ~= ''
end

---Extract the fields from InputData
---@param data InputData
---@return string key string
---@return string event string
---@return KeybindFlags flags table
local function get_input_data(data)
    ---@type string
    local key = ''
    ---@type string
    local event = ''
    ---@type KeybindFlags
    local flags = {}

    if data.key and type(data.key) == 'string' then
        key = data.key --[[@as string]]
    end
    if data.event and type(data.event) == 'string' then
        event = data.event --[[@as string]]
    end
    if data.flags and type(data.flags) == 'table' then
        flags = data.flags --[[@as KeybindFlags]]
    end

    return key, event, flags
end

---Bind keys to the input stack.
---@param _ string
---@param data InputData
local function bind(_, data)
    local key, event, flags = get_input_data(data)
    if not is_valid_bind(key, event) then
        events.emit('msg.error.input', {
            msg = {"Got invalid data in 'bind' request:", utils.to_string(data)}
        })
        return
    end

    if not binding_stack[key] then
        binding_stack[key] = {}
    end

    ---@type InputBind[]
    local stack = binding_stack[key]

    -- Remove previous bind
    local previous_bind = stack[#stack]
    if previous_bind then
        mp.remove_key_binding(previous_bind.name)
    end

    -- Push new event ont stack
    ---@type InputBind
    local new_bind = {
        event = event,
        name = 'homehub/' .. event:gsub('%.', '_') .. '_' .. key,
        flags = flags,
    }
    table.insert(binding_stack[key], new_bind)
    mp.add_forced_key_binding(
        key, new_bind.name, function() events.emit(new_bind.event) end, new_bind.flags
    )
end

---Removes top level bind, and restores next bind in the the stack if present.
---@param _ string
---@param data InputData
local function unbind(_, data)
    local key = get_input_data(data)
    if key == '' then
        events.emit('msg.error.input', {
            msg = {"Got invalid data in 'unbind' request:", utils.to_string(data)}
        })
        return
    end

    ---@type InputBind[]|nil
    local stack = binding_stack[key]

    -- Key is not bound. End.
    if not stack then return end

    -- Remove the last bind
    ---@type InputBind|nil
    local last_bind = table.remove(stack)
    if last_bind then mp.remove_key_binding(last_bind.name) end

    -- Restore the previous bind
    local previous_bind = stack[#stack]
    if previous_bind then
        mp.add_forced_key_binding(
            key, previous_bind.name,
            function() events.emit(previous_bind.event) end, previous_bind.flags
        )
    end
end

---Initialization function. Set's up input listeners.
function input.init()
    binding_stack = {}
    events.on('input.bind', bind, 'input')
    events.on('input.unbind', unbind, 'input')
end

return input
