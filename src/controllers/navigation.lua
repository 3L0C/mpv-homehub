--[[
--  Navigation controller
--]]

local utils = require 'mp.utils'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local log = require 'src.core.log'

---@class navigation: Controller
local navigation = {}

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
    log.warn('navigation', {
        'Cleaning up corrupted navigation state:', hh_utils.decode_nav_id(nav_id).rest
    })

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

    events.emit('nav.state_corrupted', { nav_id = hh_utils.decode_nav_id(nav_id).rest })
end

---Assert the nav_stack is valid.
---@return boolean
local function assert_nav_ctx_stack()
    if #nav_ctx_stack == 0 then
        log.warn('navigation', {
             'Navigation stack is empty'
        })
        return false
    end
    return true
end

---Assert the nav_ctx is valid.
---@return boolean
local function assert_nav_ctx_table()
    local top = nav_ctx_stack[#nav_ctx_stack]
    if not nav_ctx_table[top] or #nav_ctx_table[top] == 0 then
        log.warn('navigation', {
             'Navigation context is empty:', top
        })
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
        log.debug('navigation', {
            'Cannot navigate', direction, '- no items in list'
        })
        return
    end

    local old_position = state.position
    state.position = get_position_wrap(state, increment)

    events.emit('nav.pos_changed', {
        ctx_id = get_current_ctx_id(),
        position = state.position,
        old_position = old_position,
    } --[[@as NavPositionChangedData]])
end

---Test if `ctx_id` is the current context.
---If we are not in a context, insert `ctx_id` and return true.
---@param ctx_id NavCtxID
---@return boolean
local function in_context(ctx_id)
    return nav_ctx_stack[#nav_ctx_stack] == ctx_id
end

---Helper to emit a selection type event.
---@param selection_type 'nav.selected'|'nav.multiselected'
local function emit_select_type_event(selection_type)
    local state = get_current_state()
    if not state then return end

    events.emit(selection_type, {
        ctx_id = get_current_ctx_id(),
        nav_id = hh_utils.decode_nav_id(get_current_nav_id()).rest,
        position = state.position,
    } --[[@as NavSelectedData]])
end

---If `ctx_id` is the current context, delete it from the stack, and tables.
---@param event_name EventName
---@param ctx_id NavCtxID
---@return boolean
local function delete_current_context(event_name, ctx_id)
    if #nav_ctx_stack == 0 then
        log.warn('navigation', {
            ("Cannot delete context '%s', no context established."):format(ctx_id)
        })
        return false
    end

    if not in_context(ctx_id) then
        log.error('navigation', {
            ("Current context does not match '%s' request:"):format(event_name),
            nav_ctx_stack[#nav_ctx_stack], ctx_id
        })
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
            log.debug('navigation', {
                "Ignoring 'nav.left' - single column context"
            })
        end
    end,

    ['nav.right'] = function(_, _)
        local state = get_current_state()
        if not state then return end

        if state.columns > 1 then
            safe_navigate('right', state, 1)
        else
            log.debug('navigation', {
                "Ignoring 'nav.right' - single column context"
            })
        end
    end,

    -- History events

    ---@param event_name EventName
    ---@param data NavNavigateToData|EventData
    ['nav.navigate_to'] = function(event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_nav_navigate_to, 'navigation') then
            return
        end

        if #nav_ctx_stack == 0 or not nav_ctx_table[data.ctx_id] then
            log.error('navigation', {
                "Cannot navigate - context not initialized:", data.ctx_id,
                "Use 'nav.context_push' first."
            })
            return
        end

        if not in_context(data.ctx_id) then
            log.error('navigation', {
                "Received 'nav.navigate_to' request for context different from the current one:",
                data.ctx_id, nav_ctx_stack[#nav_ctx_stack]
            })
            return
        end

        local nav_hist = nav_ctx_table[data.ctx_id]
        local nav_id = hh_utils.encode_nav_id(data.ctx_id, data.nav_id)

        local old_state = nav_id_table[nav_id] or {
            columns = 1,
            position = data.position == 0 and 1 or data.position,
            total_items = 0,
        } --[[@as NavState]]

        if not is_valid_state(old_state) then
            log.warn('navigation', {
                'Found corrupted navigation state for', nav_id, '- resetting.'
            })
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
        if data.position == 0 and old_state.position <= new_state.total_items then
            new_state.position = old_state.position
        end

        if nav_hist[#nav_hist] ~= nav_id then
            table.insert(nav_hist, nav_id)
        end
        nav_id_table[nav_id] = new_state

        events.emit('nav.navigated_to', {
            ctx_id = data.ctx_id,
            nav_id = data.nav_id,
            columns = new_state.columns,
            position = new_state.position,
            total_items = new_state.total_items,
            trigger = 'navigate_to',
        } --[[@as NavNavigatedToData]])
    end,

    ['nav.back'] = function(_, _)
        if #nav_ctx_stack == 0 then
            log.warn('navigation', {
                "Got 'nav.back' event, outside any navigation context."
            })
            return
        end

        local ctx_id = get_current_ctx_id()
        local nav_hist = nav_ctx_table[ctx_id]

        if not nav_hist or #nav_hist == 0 then
            -- 'nav.back' received before 'nav.navigate_to' received.
            log.error('navigation', {
                ("Got 'nav.back' in context '%s' with no history."):format(ctx_id)
            })
            -- Cleanup the invalid context.
            events.emit('nav.context_cleanup', { ctx_id = ctx_id })
            return
        elseif #nav_hist == 1 then
            log.debug('navigation', {
                ("Ignoring 'nav.back' in context '%s' - already at root."):format(ctx_id)
            })
            return
        end

        -- Remove current nav_id, get the previous one.
        local nav_id = nav_hist[#nav_hist - 1]

        -- Ensure we are moving back to a valid state.
        local nav_state = nav_id_table[nav_id]
        if not nav_state or not is_valid_state(nav_state) then
            log.error('navigation', {
                ("Tried navigating back to '%s', but state is corrupted:"):format(nav_id),
                utils.to_string(nav_state)
            })

            -- Cleanup the corrupted state
            nav_id_table[nav_id] = nil

            -- Remove the current nav_id from the history
            table.remove(nav_hist)

            -- Check if the corrupted nav_id is the root.
            if #nav_hist == 1 then
                events.emit('nav.context_cleanup', { ctx_id = ctx_id } --[[@as NavContextCleanupData]])
                return
            end

            -- Recursive call to try the next state back
            events.emit('nav.back')
            return
        end

        table.remove(nav_hist)
        events.emit('nav.navigated_to', {
            ctx_id = ctx_id,
            nav_id = hh_utils.decode_nav_id(nav_id).rest,
            columns = nav_state.columns,
            position = nav_state.position,
            total_items = nav_state.total_items,
            trigger = 'back',
        } --[[@as NavNavigatedToData]])
    end,

    -- Context events

    ---Context changed. Update current context, and inform listeners of the change.
    ---@param event_name EventName
    ---@param data NavContextPushData|EventData
    ['nav.context_push'] = function(event_name, data)
        if not data or not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'navigation')
            return
        end

        if #nav_ctx_stack == 0 then nav_ctx_stack = {} end
        if nav_ctx_stack[#nav_ctx_stack] == data.ctx_id then
            log.warn('navigation', {
                "Ignoring redundant context push - already in context:", data.ctx_id
            })
            return
        end

        -- Push to the context stack
        local old_ctx = nav_ctx_stack[#nav_ctx_stack]
        table.insert(nav_ctx_stack, data.ctx_id)

        -- Create an empty navigation stack in the context table
        nav_ctx_table[data.ctx_id] = {}

        events.emit('nav.context_pushed', {
            old_ctx = old_ctx or '',
            new_ctx = data.ctx_id,
        } --[[@as NavContextChangedData]])
    end,

    ---Remove the current context from the stack.
    ---@param event_name EventName
    ---@param data NavContextPopData|EventData|nil
    ['nav.context_pop'] = function(event_name, data)
        if not data or not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'navigation')
            return
        end

        if not delete_current_context(event_name, data.ctx_id) then
            log.error('navigation', {
                "Unable to pop context:", data.ctx_id
            })
            return
        end

        events.emit('nav.context_popped', {
            old_ctx = data.ctx_id,
            new_ctx = nav_ctx_stack[#nav_ctx_stack] or '',
        } --[[@as NavContextChangedData]])
    end,

    ---@param event_name EventName
    ---@param data NavContextCleanupData|EventData|nil
    ['nav.context_cleanup'] = function(event_name, data)
        if not data or not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'navigation')
            return
        end

        if not delete_current_context(event_name, data.ctx_id) then
            log.error('navigation', {
                "Unable to cleanup context:", data.ctx_id
            })
            return
        end

        events.emit('nav.context_cleaned', {
            old_ctx = data.ctx_id,
            new_ctx = nav_ctx_stack[#nav_ctx_stack] or '',
        } --[[@as NavContextChangedData]])
    end,

    -- Selection events

    ['nav.select'] = function(_, _) emit_select_type_event('nav.selected') end,
    ['nav.multiselect'] = function(_, _) emit_select_type_event('nav.multiselected') end,

    -- Direct navigation

    ---Set the state for the current nav_id of data.ctx_id
    ---@param event_name EventName
    ---@param data NavSetStateData|EventData
    ['nav.set_state'] = function(event_name, data)
        if not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'navigation')
            return
        end

        local state = get_current_state()
        local ctx_id = get_current_ctx_id()

        if data.ctx_id ~= ctx_id then
            local nav_id_stack = nav_ctx_table[data.ctx_id]

            if not nav_id_stack or #nav_id_stack == 0 then
                log.error('navigation', {
                    'Uninitialized context:', data.ctx_id
                })
                return
            end

            local nav_id = nav_id_stack[#nav_id_stack]
            ctx_id = data.ctx_id
            state = nav_id_table[nav_id]
        end

        if not state then
            log.error('navigation', {
                'Uninitialized context:', data.ctx_id
            })
            return
        end

        if type(data.position) == 'number' then
            local old_pos = state.position
            state.position = data.position
            events.emit('nav.pos_changed', {
                ctx_id = data.ctx_id,
                old_position = old_pos,
                position = data.position
            } --[[@as NavPositionChangedData]])
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
