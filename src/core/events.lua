--[[
--  Event system and observers
--]]

local log = require 'src.core.log'

---@type EventState
local state = {
    listeners = {},
    wildcards = {},
    components = {},
}

---@class events: Controller
local events = {}

---Initialize the event system
function events.init()
    state.listeners = {}
    state.wildcards = {}
    state.components = {}

    log.debug('events', 'Event system initialized')
end

---Register a component for lifecycle tracking
---@param component_name string
function events.register_component(component_name)
    if not state.components[component_name] then
        ---@type TrackedListener[]
        state.components[component_name] = {}
        log.trace('events', {'Registered component:', component_name})
    end
end

---Add event listener.
---Will register the component if not yet tracked.
---@param event_name EventName
---@param callback ListenerCB
---@param component_name? string
---@return nil
function events.on(event_name, callback, component_name)
    if type(callback) ~= 'function' then
        error('Event callback must be a function')
    end

    component_name = component_name or 'anonymous'

    -- Register component if not already registered
    if component_name ~= 'anonymous' then events.register_component(component_name) end

    ---@type Listener
    local listener = {
        callback = callback,
        component = component_name
    }

    -- Check if it's a wildcard pattern (ends with .*)
    if event_name:match('%.%*$') then
        local namespace = event_name:gsub('%.%*$', '')

        if not state.wildcards[namespace] then
            state.wildcards[namespace] = {}
        end
        table.insert(state.wildcards[namespace], listener)

        -- Track for component cleanup
        table.insert(state.components[component_name], {
            type = 'wildcard',
            identifier = namespace,
            listener = listener,
        })

    else
        -- Regular event listener
        if not state.listeners[event_name] then
            state.listeners[event_name] = {}
        end
        table.insert(state.listeners[event_name], listener)

        -- Track for component cleanup
        table.insert(state.components[component_name], {
            type = 'event',
            identifier = event_name,
            listener = listener,
        })
    end

    log.trace('events', {'Added listener for', event_name, 'from component', component_name})
end

---Remove event listener(s)
---@param event_name EventName
---@param callback ListenerCB
---@param component_name? string
---@return nil
function events.off(event_name, callback, component_name)
    if not callback and not component_name then
        -- Remove all listeners for this event
        state.listeners[event_name] = nil
        log.trace('events', {'Removed all listeners for', event_name})
        return
    end

    local listeners_list = state.listeners[event_name]
    if not listeners_list then return end

    -- Remove specific listeners
    for i = #listeners_list, 1, -1 do
        local listener = listeners_list[i]
        local should_remove = false

        if callback and component_name then
            should_remove = (listener.callback == callback and listener.component == component_name)
        elseif callback then
            should_remove = (listener.callback == callback)
        elseif component_name then
            should_remove = (listener.component == component_name)
        end

        if should_remove then
            table.remove(listeners_list, i)
            log.trace('events', {'Removed listener for', event_name, 'from component', listener.component})
        end
    end
end

---Emit an event
---@param event_name EventName
---@param data? EventData
---@return number Listeners called.
function events.emit(event_name, data)
    log.trace('events', {'Emitting event:', event_name, 'with data:', data and 'present' or 'none'})

    local listeners_called = 0

    -- Call direct listeners
    local direct_listeners = state.listeners[event_name]
    if direct_listeners then
        for _, listener in ipairs(direct_listeners) do
            listeners_called = listeners_called + 1
            local success, err = pcall(listener.callback, event_name, data or {})
            if not success then
                log.error('events', {
                    'Error in listener for', event_name,
                    'from component', listener.component, ':', err
                })
            end
        end
    end

    -- Call wildcard listeners
    for namespace, wildcard_listeners in pairs(state.wildcards) do
        if event_name:match('^' .. namespace:gsub('%.', '%.') .. '%.') then
            for _, listener in ipairs(wildcard_listeners) do
                listeners_called = listeners_called + 1
                local success, err = pcall(listener.callback, event_name, data)
                if not success then
                    log.error('events', {
                        'Error in wildcard listener for', namespace,
                        'from component', listener.component, ':', err
                    })
                end
            end
        end
    end

    log.trace('events', {
        'Called', tostring(listeners_called), 'listeners for', event_name
    })

    return listeners_called
end

---Remove all listeners for a component
---@param component_name string
---@return nil
function events.cleanup_component(component_name)
    local component_listeners = state.components[component_name]
    if not component_listeners then
        log.verbose('events', {
            'No listeners found for component', component_name
        })
        return
    end

    local removed_count = 0

    -- Remove each listener tracked for this component
    for _, tracked_listener in ipairs(component_listeners) do
        if tracked_listener.type == 'event' then
            -- Remove from regular listeners
            local event_listeners = state.listeners[tracked_listener.identifier]
            if event_listeners then
                for i = #event_listeners, 1, -1 do
                    if event_listeners[i] == tracked_listener.listener then
                        table.remove(event_listeners, i)
                        removed_count = removed_count + 1
                        break
                    end
                end
            end
        elseif tracked_listener.type == 'wildcard' then
            -- Remove from wildcard listeners
            local wildcard_listeners = state.wildcards[tracked_listener.identifier]
            if wildcard_listeners then
                for i = #wildcard_listeners, 1, -1 do
                    if wildcard_listeners[i] == tracked_listener.listener then
                        table.remove(wildcard_listeners, i)
                        removed_count = removed_count + 1
                        break
                    end
                end
            end
        end
    end

    -- Clear component tracking
    state.components[component_name] = nil

    log.trace('events', {
        'Cleaned up', tostring(removed_count), 'listeners for component', component_name
    })
end

---Utility function to check if anyone is listening to an event
---@param event_name EventName
---@return boolean
function events.has_listeners(event_name)
    -- Check direct listeners
    if state.listeners[event_name] and #state.listeners[event_name] > 0 then
        return true
    end

    -- Check wildcard listeners
    for namespace, listeners_list in pairs(state.wildcards) do
        if event_name:match('^' .. namespace:gsub('%.', '%.') .. '%.') and #listeners_list > 0 then
            return true
        end
    end

    return false
end

return events
