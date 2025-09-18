--[[
--  Navigation controller
--]]

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'

---@class navigation: Controller
local navigation = {}

---@class NavigationState
---@field position number Current position in the list.
---@field total_items number Total items in the list.
---@field columns number Columns in the list.
---
---@alias NavigationID string
---@alias NavigationCtxID string
---@alias NavigationTable table<NavigationID,NavigationState>
---@alias NavigationCtx table<NavigationCtxID,NavigationID[]>
---@alias NavigationStack NavigationCtxID[]

---@type NavigationTable
local nav_table = {}
---@type NavigationCtx
local nav_ctx = {}
---@type NavigationStack
local nav_stack = {}

---Validates a navigation state object.
---@param state any
---@return boolean
local function is_valid_state(state)
    return type(state) == 'table'
        and type(state.position) == 'number'
        and type(state.total_items) == 'number'
        and type(state.columns) == 'number'
        and state.position >= 1
        and state.total_items >= 0
        and state.columns >= 1
end

---Cleans up corrupted navigation state.
---@param nav_id NavigationID
local function cleanup_corrupted_state(nav_id)
    events.emit('msg.warn.navigation', { msg = {
        'Cleaning up corrupted navigation state:', nav_id
    } })

    -- Remove from nav_table
    nav_table[nav_id] = nil

    -- Remove from all contexts
    for ctx_id, nav_id_array in pairs(nav_ctx) do
        for i = #nav_id_array, 1, -1 do
            if nav_id_array[i] == nav_id then
                table.remove(nav_id_array, i)
            end
        end
        -- If context becomes empty, remove it from stack
        if #nav_id_array == 0 then
            for j = #nav_stack, 1, -1 do
                if nav_stack[j] == ctx_id then
                    table.remove(nav_stack, j)
                end
            end
            -- Also remove the empty context
            nav_ctx[ctx_id] = nil
        end
    end

    events.emit('nav.state_corrupted', { nav_id = nav_id })
end

---Get the current navigation state from `nav_table`.
---@return NavigationState|nil
local function get_current_state()
    if #nav_stack == 0 then
        events.emit('msg.warn.navigation', { msg = { 'Navigation stack is empty' } })
        return nil
    end

    local top = nav_stack[#nav_stack]
    if not nav_ctx[top] or #nav_ctx[top] == 0 then
        events.emit('msg.warn.navigation', { msg = { 'Navigation context is empty:', top } })
        return nil
    end

    local id = nav_ctx[top][#nav_ctx[top]]
    local state = nav_table[id]

    if not is_valid_state(state) then
        cleanup_corrupted_state(id)
        return nil
    end

    return state
end

---Get the position wrapped.
---@param state NavigationState
---@param inc number
---@return number
local function get_position_wrap(state, inc)
    local total = state.total_items
    if total == 0 then return 1 end

    local new_pos = ((state.position - 1 + inc) % total) + 1
    return new_pos
end

---Safely executes navigation with error handling.
---@param direction string
---@param state NavigationState
---@param increment number
local function safe_navigate(direction, state, increment)
    if state.total_items == 0 then
        events.emit('msg.debug.navigation', { msg = {
            'Cannot navigate', direction, '- no items in list'
        } })
        return
    end

    local old_position = state.position
    state.position = get_position_wrap(state, increment)

    events.emit('nav.pos_changed', {
        pos = state.position,
        old_pos = old_position,
        total = state.total_items
    })
end

---@type HandlerTable
local handlers = {
    ['nav.up'] = function(_, _)
        local state = get_current_state()
        if not state then return end

        safe_navigate('up', state, -state.columns)
    end,

    ['nav.down'] = function(_, _)
        local state = get_current_state()
        if not state then return end

        safe_navigate('down', state, state.columns)
    end,

    ['nav.left'] = function(_, _)
        local state = get_current_state()
        if not state then return end

        if state.columns > 1 then
            safe_navigate('left', state, -1)
        else
            events.emit('msg.debug.navigation', { msg = {
                "Ignoring 'nav.left' - single column context"
            } })
        end
    end,

    ['nav.right'] = function(_, _)
        local state = get_current_state()
        if not state then return end

        if state.columns > 1 then
            safe_navigate('right', state, 1)
        else
            events.emit('msg.debug.navigation', { msg = {
                "Ignoring 'nav.right' - single column context"
            } })
        end
    end,
}

---Main navigation event handler.
---@param event_name EventName
---@param data EventData
local function handler(event_name, data)
    hh_utils.handler_template(event_name, data, handlers, 'navigation')
end

function navigation.init()
    events.on('nav.*', handler, 'navigation')
    events.on('sys.cleanup', navigation.cleanup, 'navigation')
end

function navigation.cleanup()
    events.cleanup_component('navigation')
end

return navigation
