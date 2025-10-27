--[[
--  Input controller
--]]

local mp = require "mp"
local utils = require 'mp.utils'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local log = require 'src.core.log'

--@class input: Controller
local input = {}

---@type table<InputKey,InputBind[]>
local binding_stack = {}

---@type table<InputGroup, table<InputKey, boolean>>
local group_registry = {}

---Test if `key` and `event` are valid bind requests.
---@param key string
---@param event string
---@param group string 
---@return boolean
local function is_valid_bind(key, event, group)
    return key ~= '' and event ~= '' and group ~= ''
end

---Extract the fields from InputData
---@param data InputData
---@return InputKey key string
---@return EventName event string
---@return InputGroup group string
---@return InputCtx Event context
---@return InputFlags flags table
local function get_input_data(data)
    ---@type InputKey
    local key = ''
    ---@type EventName
    local event = ''
    ---@type InputGroup
    local group = ''
    ---@type InputCtx
    local ctx = {}
    ---@type InputFlags
    local flags = {}

    if data.key and type(data.key) == 'string' then
        key = data.key
    end
    if data.event and type(data.event) == 'string' then
        event = data.event
    end
    if data.group and type(data.group) == 'string' then
        group = data.group
    end
    if data.ctx and type(data.ctx) == 'table' then
        ctx = data.ctx
    end
    if data.flags and type(data.flags) == 'table' then
        flags = data.flags
    end

    return key, event, group, ctx, flags
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
        log.error('input', {
            'Got invalid unbind request: from', tostring(#stack),
            'to:', tostring(to)
        })
    end

    -- Remove bindings
    repeat
        ---@type InputBind?
        local top_bind = table.remove(stack)
        if top_bind then mp.remove_key_binding(top_bind.name) end
    until #stack < to
end

---Remove all bindings for a specific group from a key's stack.
---@param key InputKey
---@param group InputGroup
local function unbind_group_from_key(key, group)
    local stack = binding_stack[key]
    if not stack then return end
    if #stack == 0 then return end

    -- Find and remove all bindings from this group
    local i = 1
    while i <= #stack do
        if stack[i].group == group then
            mp.remove_key_binding(stack[i].name)
            table.remove(stack, i)
            -- Don't increment i, as we just shifted the array
        else
            i = i + 1
        end
    end

    -- Restore the top binding if one exists
    local top_bind = stack[#stack]
    if top_bind then
        mp.add_forced_key_binding(
            key, top_bind.name,
            function() events.emit(top_bind.event, top_bind.ctx) end,
            top_bind.flags
        )
    end
end

---@type HandlerTable
local handlers = {

    ---Bind keys to the input stack.
    ---@param _ EventName
    ---@param data InputData
    ['input.bind'] = function(_, data)
        local key, event, group, ctx, flags = get_input_data(data)
        if not is_valid_bind(key, event, group) then
            log.error('input', {
                "Got invalid data in 'input.bind' request:", utils.to_string(data)
            })
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

        -- Push new event onto stack
        ---@type InputBind
        local new_bind = {
            key = key,
            event = event,
            group = group,
            name = 'homehub/' .. event:gsub('%.', '_') .. '_' .. key,
            ctx = ctx,
            flags = flags,
        }

        table.insert(binding_stack[key], new_bind)

        -- Track in group registry
        if not group_registry[group] then
            group_registry[group] = {}
        end
        group_registry[group][key] = true

        mp.add_forced_key_binding(
            key, new_bind.name,
            function() events.emit(new_bind.event, ctx) end,
            new_bind.flags
        )
    end,

    ---Unbind all keys belonging to a group.
    ---@param event_name EventName
    ---@param data InputUnbindData
    ['input.unbind_group'] = function(event_name, data)
        if not data or not data.group or type(data.group) ~= 'string' then
            hh_utils.emit_data_error(event_name, data, 'input')
            return
        end

        local group = data.group
        local keys_in_group = group_registry[group]

        if not keys_in_group then
            log.debug('input', {
                'No bindings found for group:', group
            })
            return
        end

        -- Unbind all keys in this group
        for key, _ in pairs(keys_in_group) do
            unbind_group_from_key(key, group)
        end

        -- Clear group registry
        group_registry[group] = nil
    end,

    ---Removes top level bind, and restores next bind in the the stack if present.
    ---@param _ EventName
    ---@param data InputData
    ['input.unbind'] = function(_, data)
        local key = get_input_data(data)
        if key == '' then
            log.error('input', {
                "Got invalid data in 'unbind' request:", utils.to_string(data)
            })
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
    end,
}

---Main input handler.
---@param event_name EventName
---@param data EventData
local function handler(event_name, data)
    hh_utils.handler_template(event_name, data, handlers, 'input')
end

---Initialization function. Set's up input listeners.
function input.init()
    binding_stack = {}
    for event in pairs(handlers) do
        events.on(event, handler, 'input')
    end
end

---Cleanup function. Unbinds everything.
function input.cleanup()
    for _, stack in pairs(binding_stack) do
        unbind_to(stack, 1)
    end
end

return input
