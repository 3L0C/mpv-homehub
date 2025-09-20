--[[
--  Input controller
--]]

local mp = require "mp"
local utils = require 'mp.utils'

local events = require "src.core.events"

---@alias InputKey string
---@alias InputContext table<unknown,unknown>

---@class InputFlags
---@field repeatable boolean?
---@field scalable boolean?
---@field complex boolean?

---@class InputBind
---@field key InputKey
---@field event EventName
---@field name string
---@field ctx InputContext
---@field flags? InputFlags

---@class InputData
---@field key InputKey
---@field event EventName
---@field ctx InputContext
---@field flags InputFlags

--@class input: Controller
local input = {}

---@type table<InputKey,InputBind[]>
local binding_stack = {}

---Test if `key` and `event` are valid bind requests.
---@param key string
---@param event string
---@return boolean
local function is_valid_bind(key, event)
    return key ~= '' and event ~= ''
end

---Extract the fields from InputData
---@param data InputData
---@return InputKey key string
---@return EventName event string
---@return InputContext Event context
---@return InputFlags flags table
local function get_input_data(data)
    ---@type InputKey
    local key = ''
    ---@type EventName
    local event = ''
    ---@type InputContext
    local ctx = {}
    ---@type InputFlags
    local flags = {}

    if data.key and type(data.key) == 'string' then
        key = data.key
    end
    if data.event and type(data.event) == 'string' then
        event = data.event
    end
    if data.ctx and type(data.ctx) == 'table' then
        ctx = data.ctx
    end
    if data.flags and type(data.flags) == 'table' then
        flags = data.flags
    end

    return key, event, ctx, flags
end

---Bind keys to the input stack.
---@param _ string
---@param data InputData
local function bind(_, data)
    local key, event, ctx, flags = get_input_data(data)
    if not is_valid_bind(key, event) then
        events.emit('msg.error.input', { msg = {
            "Got invalid data in 'input.bind' request:", utils.to_string(data)
        } })
        return
    end

    if not binding_stack[key] then
        binding_stack[key] = {}
    end

    local stack = binding_stack[key]

    -- Remove previous bind
    local previous_bind = stack[#stack]
    if previous_bind then
        mp.remove_key_binding(previous_bind.name)
    end

    -- Push new event ont stack
    ---@type InputBind
    local new_bind = {
        key = key,
        event = event,
        name = 'homehub/' .. event:gsub('%.', '_') .. '_' .. key,
        ctx = ctx,
        flags = flags,
    }
    table.insert(binding_stack[key], new_bind)
    mp.add_forced_key_binding(
        key, new_bind.name, function() events.emit(new_bind.event, ctx) end, new_bind.flags
    )
end

---Removes binds from `#stack` to `to`.
---Helper function for `unbind` and `cleanup`.
---@param stack InputBind[] Stack to remove from.
---@param to? number Last bind in the stack to remove.
---                  If omitted, only removes the top bind.
local function unbind_to(stack, to)
    -- Nothing to unbind. End.
    if #stack == 0 then return end

    to = to or #stack
    to = to > 0 and to or 1
    if #stack < to then
        events.emit('msg.error.input', { msg = {
            'Got invalid unbind request: from', tostring(#stack),
            'to:', tostring(to)
        }})
    end

    -- Remove bindings
    repeat
        ---@type InputBind|nil
        local top_bind = table.remove(stack)
        if top_bind then mp.remove_key_binding(top_bind.name) end
    until #stack < to
end

---Removes top level bind, and restores next bind in the the stack if present.
---@param _ string
---@param data InputData
local function unbind(_, data)
    local key = get_input_data(data)
    if key == '' then
        events.emit('msg.error.input', { msg = {
            "Got invalid data in 'unbind' request:", utils.to_string(data)
        } })
        return
    end

    local stack = binding_stack[key]
    if not stack then return end

    unbind_to(binding_stack[key])

    -- Restore the previous bind
    local top_bind = stack[#stack]
    if top_bind then
        mp.add_forced_key_binding(
            key, top_bind.name,
            function() events.emit(top_bind.event, top_bind.ctx) end, top_bind.flags
        )
    end
end

---Initialization function. Set's up input listeners.
function input.init()
    binding_stack = {}
    events.on('input.bind', bind, 'input')
    events.on('input.unbind', unbind, 'input')
end

---Cleanup function. Unbinds everything.
function input.cleanup()
    for _, stack in pairs(binding_stack) do
        unbind_to(stack, 1)
    end
end

return input
