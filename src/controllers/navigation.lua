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
---@alias NavIDTable table<NavID,NavState>
---@alias NavCtxTable table<NavCtxID,NavID[]>
---@alias NavCtxStack NavCtxID[]
---
---@class NavCtxChangedData
---@field old_ctx NavCtxID
---@field new_ctx NavCtxID
---@field nav_id NavID
---
---@class NavCtxCleanupData
---@field ctx_id NavCtxID
---
---@alias NavCtxCleanedData NavCtxChangedData
---
---@alias NavCtxPopData NavCtxCleanupData
---
---@alias NavCtxPoppedData NavCtxChangedData
---
---@class NavCtxPushData
---@field ctx_id NavCtxID
---@field nav_id NavID
---
---@alias NavCtxPushedData NavCtxChangedData
---
---@class NavSelectedData
---@field ctx_id NavCtxID
---@field nav_id NavID
---@field position number
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
---@field position number (0 = preserve/default, >0 = specific position)

---@type NavIDTable
local nav_id_table = {}
---@type NavCtxTable
local nav_ctx_table = {}
---@type NavCtxStack
local nav_ctx_stack = {}

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
    nav_id_table[nav_id] = nil

    -- Remove from all contexts
    for ctx_id, nav_id_array in pairs(nav_ctx_table) do
        for i = #nav_id_array, 1, -1 do
            if nav_id_array[i] == nav_id then
                table.remove(nav_id_array, i)
            end
        end
        -- If context becomes empty, remove it from stack
        if #nav_id_array == 0 then
            for j = #nav_ctx_stack, 1, -1 do
                if nav_ctx_stack[j] == ctx_id then
                    table.remove(nav_ctx_stack, j)
                end
            end
            -- Also remove the empty context
            nav_ctx_table[ctx_id] = nil
        end
    end

    events.emit('nav.state_corrupted', { nav_id = nav_id })
end

---Assert the nav_stack is valid.
---@return boolean
local function assert_nav_ctx_stack()
    if #nav_ctx_stack == 0 then
        events.emit('msg.warn.navigation', { msg = { 'Navigation stack is empty' } })
        return false
    end
    return true
end

---Assert the nav_ctx is valid.
---@return boolean
local function assert_nav_ctx_table()
    local top = nav_ctx_stack[#nav_ctx_stack]
    if not nav_ctx_table[top] or #nav_ctx_table[top] == 0 then
        events.emit('msg.warn.navigation', { msg = { 'Navigation context is empty:', top } })
        return false
    end
    return true
end

---Get the current navigation state from `nav_table`.
---@return NavState|nil
local function get_current_state()
    if not assert_nav_ctx_stack() then return nil end
    if not assert_nav_ctx_table() then return nil end

    local ctx = nav_ctx_stack[#nav_ctx_stack]
    local nav_id = nav_ctx_table[ctx][#nav_ctx_table[ctx]]
    local nav_state = nav_id_table[nav_id]

    if not is_valid_state(nav_state) then
        cleanup_corrupted_state(nav_id)
        return nil
    end

    return nav_state
end

---Get the current context id from `nav_ctx_stack`.
---@return NavCtxID
local function get_current_ctx_id()
    if not assert_nav_ctx_stack() then return '' end
    return nav_ctx_stack[#nav_ctx_stack]
end

---Get the current navigation id from `nav_ctx_table`.
---@return NavID
local function get_current_nav_id()
    if not assert_nav_ctx_stack() then return '' end
    if not assert_nav_ctx_table() then return '' end

    local ctx_id = nav_ctx_stack[#nav_ctx_stack]
    local nav_hist = nav_ctx_table[ctx_id]
    return nav_hist[#nav_hist] or ''
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
        nav_id = get_current_nav_id(),
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
        and type(data.columns) == 'number'
        and type(data.position) == 'number'
        and type(data.total_items) == 'number'
        and data.columns >= 1
        and data.position >= 0
        and data.total_items >= 0
        and (data.total_items == 0 or data.position <= data.total_items)
end

---Test if `ctx_id` is the current context.
---If we are not in a context, insert `ctx_id` and return true.
---@param ctx_id NavCtxID
---@return boolean
local function in_context(ctx_id)
    return nav_ctx_stack[#nav_ctx_stack] == ctx_id
end

---Wrapper for `events.emit('msg.error.navigation')` when data is invalid.
---@param event_name EventName
---@param data EventData|nil
local function emit_data_error(event_name, data)
    events.emit('msg.error.navigation', { msg = {
        ("Received invalid data to '%s' request:"):format(event_name),
        utils.to_string(data)
    } })
end

---Helper to emit a selection type event.
---@param selection_type 'nav.selected'|'nav.multiselected'
local function emit_select_type_event(selection_type)
    local state = get_current_state()
    if not state then return end

    events.emit(selection_type, {
        ctx_id = get_current_ctx_id(),
        nav_id = get_current_nav_id(),
        position = state.position,
    } --[[@as NavSelectedData]])
end

---If `ctx_id` is the current context, delete it from the stack, and tables.
---@param event_name EventName
---@param ctx_id NavCtxID
---@return boolean
local function delete_current_context(event_name, ctx_id)
    if #nav_ctx_stack == 0 then
        events.emit('msg.warn.navigation', { msg = {
            ("Cannot delete context '%s', no context established."):format(ctx_id)
        } })
        return false
    end

    if not in_context(ctx_id) then
        events.emit('msg.error.navigation', { msg = {
            ("Current context does not match '%s' request:"):format(event_name),
            nav_ctx_stack[#nav_ctx_stack], ctx_id
        } })
        return false
    end

    -- Delete the current ctx from the stack.
    local old_ctx = table.remove(nav_ctx_stack)

    -- Clean up the relevant references in the nav_id_table
    if nav_ctx_table[old_ctx] then
        for _, nav_id in ipairs(nav_ctx_table[old_ctx]) do
            nav_id_table[nav_id] = nil
        end
        nav_ctx_table[old_ctx] = nil
    end

    return true
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

        if #nav_ctx_stack == 0 or not nav_ctx_table[data.ctx_id] then
            events.emit('msg.error.navigation', { msg = {
                "Cannot navigate - context not initialized:", data.ctx_id,
                "Use 'nav.context_push' first."
            } })
            return
        end

        if not in_context(data.ctx_id) then
            events.emit('msg.error.navigation', { msg = {
                "Received 'nav.navigate_to' request for context different from the current one:",
                data.ctx_id, nav_ctx_stack[#nav_ctx_stack]
            } })
            return
        end

        local nav_hist = nav_ctx_table[data.ctx_id]

        local old_state = nav_id_table[data.nav_id]
        if not is_valid_state(old_state) then
            events.emit('msg.warn.navigation', { msg = {
                'Found corrupted navigation state for', data.nav_id, '- resetting.'
            } })
            old_state = {
                columns = 1,
                position = data.position == 0 and 1 or data.position,
                total_items = 0,
            }
        end

        ---@type NavState
        local new_state = {
            columns = data.columns,
            position = data.position == 0 and 1 or data.position,
            total_items = data.total_items,
        }
        if data.position == 0
        and old_state.position <= new_state.total_items
        then
            new_state.position = old_state.position
        end

        table.insert(nav_hist, data.nav_id)
        nav_id_table[data.nav_id] = new_state

        events.emit('nav.navigated_to', {
            ctx_id = data.ctx_id,
            nav_id = data.nav_id,
            columns = new_state.columns,
            position = new_state.position,
            total_items = new_state.total_items,
        } --[[@as NavToData]])
    end,

    ['nav.back'] = function(_, _)
        if #nav_ctx_stack == 0 then
            events.emit('msg.warn.navigation', { msg = {
                "Got 'nav.back' event, outside any navigation context."
            } })
            return
        end

        local ctx_id = nav_ctx_stack[#nav_ctx_stack]
        local nav_hist = nav_ctx_table[ctx_id]

        if not nav_hist or #nav_hist == 0 then
            -- 'nav.back' received before 'nav.navigate_to' received.
            events.emit('msg.error.navigation', { msg = {
                ("Got 'nav.back' in context '%s' with no history."):format(ctx_id)
            } })
            -- Cleanup the invalid context.
            events.emit('nav.context_cleanup', { ctx_id = ctx_id })
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
        local nav_state = nav_id_table[nav_id]
        if not nav_state or not is_valid_state(nav_state) then
            events.emit('msg.error.navigation', { msg = {
                ("Tried navigating back to '%s', but state is corrupted:"):format(nav_id),
                utils.to_string(nav_state)
            } })

            -- Cleanup the corrupted state
            nav_id_table[nav_id] = nil

            -- Remove the current nav_id from the history
            table.remove(nav_hist)

            -- Check if the corrupted nav_id is the root.
            if #nav_hist == 1 then
                events.emit('nav.context_cleanup', { ctx_id = ctx_id } --[[@as NavCtxCleanupData]])
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

    ---Context changed. Update current context, and inform listeners of the change.
    ---@param event_name EventName
    ---@param data NavCtxPushData|EventData|nil
    ['nav.context_push'] = function(event_name, data)
        if not data or not data.ctx_id or not data.nav_id then
            emit_data_error(event_name, data)
            return
        end

        if #nav_ctx_stack == 0 then nav_ctx_stack = {} end
        if nav_ctx_stack[#nav_ctx_stack] == data.ctx_id then
            if get_current_nav_id() == data.nav_id then
                events.emit('msg.warn.navigation', { msg = {
                    "Ignoring redundant context push - already in context:",
                    data.ctx_id
                } })
            else
                events.emit('msg.warn.navigation', { msg = {
                    ("Ignoring 'nav.context_push' request - already in context '%s', with different nav_id '%s'."):format(
                        data.ctx_id, get_current_nav_id()
                    ),
                    "Use 'nav.navigate_to' instead."
                } })
            end
            return
        end

        local old_ctx = nav_ctx_stack[#nav_ctx_stack]
        table.insert(nav_ctx_stack, data.ctx_id)

        events.emit('nav.context_pushed', {
            old_ctx = old_ctx or '',
            new_ctx = data.ctx_id,
            nav_id = data.nav_id,
        } --[[@as NavCtxPushedData]])
    end,

    ---Remove the current context from the stack.
    ---@param event_name EventName
    ---@param data NavCtxPopData|EventData|nil
    ['nav.context_pop'] = function(event_name, data)
        if not data or not data.ctx_id then
            emit_data_error(event_name, data)
            return
        end

        if not delete_current_context(event_name, data.ctx_id) then
            events.emit('msg.error.navigation', { msg = {
                "Unable to pop context:", data.ctx_id
            } })
            return
        end

        events.emit('nav.context_popped', {
            old_ctx = data.ctx_id,
            new_ctx = nav_ctx_stack[#nav_ctx_stack] or '',
            nav_id = get_current_nav_id()
        } --[[@as NavCtxPoppedData]])
    end,

    ---@param event_name EventName
    ---@param data NavCtxCleanupData|EventData|nil
    ['nav.context_cleanup'] = function(event_name, data)
        if not data or not data.ctx_id then
            emit_data_error(event_name, data)
            return
        end

        if not delete_current_context(event_name, data.ctx_id) then
            events.emit('msg.error.navigation', { msg = {
                "Unable to cleanup context:", data.ctx_id
            } })
            return
        end

        events.emit('nav.context_cleaned', {
            old_ctx = data.ctx_id,
            new_ctx = nav_ctx_stack[#nav_ctx_stack] or '',
            nav_id = get_current_nav_id()
        } --[[@as NavCtxCleanedData]])
    end,

    -- Selection events

    ['nav.select'] = function(_, _) emit_select_type_event('nav.selected') end,
    ['nav.multiselect'] = function(_, _) emit_select_type_event('nav.multiselected') end,
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
