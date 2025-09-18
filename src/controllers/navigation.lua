--[[
--  Navigation controller
--]]

local utils = require 'mp.utils'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'

---@class navigation: Controller
local navigation = {}

---@class NavState
---@field columns number Columns in the list.
---@field position number Current position in the list.
---@field total_items number Total items in the list.
---
---@alias NavID string
---@alias NavCtxID string
---@alias NavTable table<NavID,NavState>
---@alias NavCtx table<NavCtxID,NavID[]>
---@alias NavStack NavCtxID[]
---
---@class NavCtxChangedData
---@field old_ctx NavCtxID
---@field new_ctx NavCtxID
---@field nav_id NavID
---
---@class NavCtxCleanupData
---@field reason 'error'|'cleanup'
---
---@class NavCtxPoppedData
---@field popped_ctx NavCtxID
---@field reason 'error'|'cleanup'|'unknown'
---
---@class NavToData: NavState
---@field ctx_id NavCtxID
---@field nav_id NavID
---
---@class NavPosChangedData
---@field nav_id NavID
---@field pos number
---@field old_pos number
---@field columns number
---@field total_items number
---
---@class NavToData: NavState
---@field ctx_id NavCtxID
---@field nav_id NavID

---@type NavTable
local nav_table = {}
---@type NavCtx
local nav_ctx = {}
---@type NavStack
local nav_stack = {}

---Validates a navigation state object.
---@param state any
---@return boolean
local function is_valid_state(state)
    return type(state) == 'table'
        and type(state.columns) == 'number'
        and type(state.position) == 'number'
        and type(state.total_items) == 'number'
        and state.columns >= 1
        and state.position >= 1
        and state.total_items >= 0
        and (state.total_items == 0 or state.position <= state.total_items)
end

---Cleans up corrupted navigation state.
---@param nav_id NavID
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

---Assert the nav_stack is valid.
---@return boolean
local function assert_nav_stack()
    if #nav_stack == 0 then
        events.emit('msg.warn.navigation', { msg = { 'Navigation stack is empty' } })
        return false
    end
    return true
end

---Assert the nav_ctx is valid.
---@return boolean
local function assert_nav_ctx()
    local top = nav_stack[#nav_stack]
    if not nav_ctx[top] or #nav_ctx[top] == 0 then
        events.emit('msg.warn.navigation', { msg = { 'Navigation context is empty:', top } })
        return false
    end
    return true
end

---Get the current navigation state from `nav_table`.
---@return NavState|nil
local function get_current_state()
    if not assert_nav_stack() then return nil end
    if not assert_nav_ctx() then return nil end

    local ctx = nav_stack[#nav_stack]
    local nav_id = nav_ctx[ctx][#nav_ctx[ctx]]
    local nav_state = nav_table[nav_id]

    if not is_valid_state(nav_state) then
        cleanup_corrupted_state(nav_id)
        return nil
    end

    return nav_state
end

---Get the current navigation id from `nav_ctx`.
---@return NavID|nil
local function get_current_nav_id()
    if not assert_nav_stack() then return nil end
    if not assert_nav_ctx() then return nil end

    local ctx_id = nav_stack[#nav_stack]
    local nav_hist = nav_ctx[ctx_id]
    return nav_hist[#nav_hist]
end

---Get the position wrapped.
---@param state NavState
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
---@param state NavState
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
        nav_id = get_current_nav_id() or '<unknown>',
        pos = state.position,
        old_pos = old_position,
        columns = state.columns,
        total_items = state.total_items,
    } --[[@as NavPosChangedData]])
end

---Get valid NavToData for `nav.navigate_to` request.
---@param data NavToData|EventData|nil
---@return boolean
local function is_valid_nav_to_data(data)
    return type(data) == 'table'
        and type(data.ctx_id) == 'string'
        and type(data.nav_id) == 'string'
        and is_valid_state(data)
end

---Test if `ctx_id` is the current context.
---If we are not in a context, insert `ctx_id` and return true.
---@param ctx_id NavCtxID
---@return boolean
local function in_context(ctx_id)
    return nav_stack[#nav_stack] == ctx_id
end

---Wrapper for `events.emit('msg.error.navigation')` when data is invalid.
---@param event_name EventName
---@param data EventData
local function emit_data_error(event_name, data)
    events.emit('msg.error.navigation', { msg = {
        ("Received invalid data to '%s' request:"):format(event_name),
        utils.to_string(data)
    } })
end

---@type HandlerTable
local handlers = {
    -- Movement events
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

    -- History events

    ---@param event_name EventName
    ---@param data NavToData|EventData|nil
    ['nav.navigate_to'] = function(event_name, data)
        if not data then
            events.emit('msg.error.navigation', { msg = {
                "Received empty data to 'nav.navigate_to' request."
            } })
            return
        end

        if not is_valid_nav_to_data(data) then
            emit_data_error(event_name, data)
            return
        end

        if #nav_stack == 0 then table.insert(nav_stack, data.ctx_id) end

        if not in_context(data.ctx_id) then
            events.emit('msg.error.navigation', { msg = {
                "Received 'nav.navigate_to' request for context different from the current one:",
                data.ctx_id, nav_stack[#nav_stack]
            } })
            return
        end

        -- Create context history if it doesn't exist
        if not nav_ctx[data.ctx_id] then nav_ctx[data.ctx_id] = {} end

        local nav_hist = nav_ctx[data.ctx_id]

        local old_state = nav_table[data.nav_id]
        if not is_valid_state(old_state) then
            events.emit('msg.warn.navigation', { msg = {
                'Found corrupted navigation state for', data.nav_id, '- resetting.'
            } })
            old_state = {
                columns = 1,
                position = data.position,
                total_items = 0,
            }
        end

        ---@type NavState
        local new_state = {
            columns = data.columns,
            position = data.position,
            total_items = data.total_items,
        }
        if old_state.position ~= new_state.position
        and old_state.position <= new_state.total_items
        then
            new_state.position = old_state.position
        end

        table.insert(nav_hist, data.nav_id)
        nav_table[data.nav_id] = new_state

        events.emit('nav.navigated_to', {
            ctx_id = data.ctx_id,
            nav_id = data.nav_id,
            columns = new_state.columns,
            position = new_state.position,
            total_items = new_state.total_items,
        } --[[@as NavToData]])
    end,

    ['nav.back'] = function(_, _)
        if #nav_stack == 0 then
            events.emit('msg.warn.navigation', { msg = {
                "Got 'nav.back' event, outside any navigation context."
            } })
            return
        end

        local ctx_id = nav_stack[#nav_stack]
        local nav_hist = nav_ctx[ctx_id]

        if not nav_hist or #nav_hist == 0 then
            -- 'nav.back' received before 'nav.navigate_to' received.
            events.emit('msg.error.navigation', { msg = {
                ("Got 'nav.back' in context '%s' with no history."):format(ctx_id)
            } })
            -- Cleanup the invalid context.
            events.emit('nav.context_pop', { reason = 'error' })
            return
        elseif #nav_hist == 1 then
            events.emit('msg.debug.navigation', { msg = {
                ("Ignoring 'nav.back' in context '%s' - already at root."):format(ctx_id)
            } })
            return
        end

        -- Remove current nav_id, get the previous one.
        local nav_id = nav_hist[#nav_hist - 1]

        -- Ensure we are moving back to a valid state.
        local nav_state = nav_table[nav_id]
        if not nav_state or not is_valid_state(nav_state) then
            events.emit('msg.error.navigation', { msg = {
                ("Tried navigating back to '%s', but state is corrupted:"):format(nav_id),
                utils.to_string(nav_state)
            } })

            -- Cleanup the corrupted state
            nav_table[nav_id] = nil

            -- Remove the current nav_id from the history
            table.remove(nav_hist)

            -- Check if the corrupted nav_id is the root.
            if #nav_hist == 1 then
                events.emit('nav.context_pop', { reason = 'error' } --[[@as NavCtxCleanupData]])
                return
            end

            -- Recursive call to try the next state back
            events.emit('nav.back')
            return
        end

        table.remove(nav_hist)
        events.emit('nav.navigated_to', {
            ctx_id = ctx_id,
            nav_id = nav_id,
            columns = nav_state.columns,
            position = nav_state.position,
            total_items = nav_state.total_items,
        } --[[@as NavToData]])
    end,

    -- Context events

    ---@param event_name EventName
    ---@param data NavCtxCleanupData|EventData|nil
    ['nav.context_cleanup'] = function(event_name, data)
        if not data or not data.reason then
            emit_data_error(event_name, data --[[@as EventData]])
            return
        end

        if #nav_stack == 0 then
            events.emit('msg.warn.navigation', { msg = {
                'Cannot pop context - stack is empty.'
            } })
            return
        end

        -- Pop the stale context
        local old_ctx = table.remove(nav_stack)
        local reason = data.reason or 'unknown'

        -- Clean up the popped context
        if nav_ctx[old_ctx] then
            for _, nav_id in ipairs(nav_ctx[old_ctx]) do
                nav_table[nav_id] = nil
            end
            nav_ctx[old_ctx] = nil
        end

        events.emit('nav.context_popped', {
            popped_ctx = old_ctx,
            reason = reason,
        } --[[@as NavCtxPoppedData]])

        if #nav_stack == 0 then
            events.emit('msg.warn.navigation', { msg = {
                'All navigation contexts have been popped - no active context.'
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
    for event in pairs(handlers) do
        events.on(event, handler, 'navigation')
    end
    events.on('sys.cleanup', navigation.cleanup, 'navigation')
end

function navigation.cleanup()
    events.cleanup_component('navigation')
end

return navigation
