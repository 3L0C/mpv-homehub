--[[
    Event system and observers
--]]

local logger = require 'src.core.logger'

---@alias Data table<unknown,unknown>
---@alias ListenerCB fun(event_name: string, data?: Data)

---@class LoggerData
---@field msg string[]|string
---@field separator? string

---@class Listener
---@field callback ListenerCB
---@field component string Registered component name.

---@class TrackedListener
---@field type 'wildcard'|'event'
---@field identifier string For wildcard or event type
---@field listener Listener

---@class events
local events = {
    ---@type table<string,Listener[]>
    listeners = {},
    ---@type table<string,Listener[]>
    wildcards = {},
    ---@type table<string,TrackedListener[]>
    components = {},
    debug_mode = false,
    ---@type ListenerCB
    logger = logger.log,
}

---Initialize the event system
function events.init()
    events.listeners = {}
    events.wildcards = {}
    events.components = {}
    events.logger = logger.log

    events.logger('msg.info.events', {
        msg = 'Event system initialized'
    })
end

---Register a component for lifecycle tracking
---@param component_name string
function events.register_component(component_name)
    if not events.components[component_name] then
        ---@type TrackedListener[]
        events.components[component_name] = {}
        events.logger('msg.info.events', {
            msg = {'Registered component:', component_name},
        })
    end
end

---Add event listener.
---Will register the component if not yet tracked.
---@param event_name string
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

        if not events.wildcards[namespace] then
            events.wildcards[namespace] = {}
        end
        table.insert(events.wildcards[namespace], listener)

        -- Track for component cleanup
        table.insert(events.components[component_name], {
            type = 'wildcard',
            identifier = namespace,
            listener = listener,
        })

    else
        -- Regular event listener
        if not events.listeners[event_name] then
            events.listeners[event_name] = {}
        end
        table.insert(events.listeners[event_name], listener)

        -- Track for component cleanup
        table.insert(events.components[component_name], {
            type = 'event',
            identifier = event_name,
            listener = listener,
        })
    end

    events.logger('msg.info.events', {
        msg = {'Added listener for', event_name, 'from component', component_name},
    })
end

---Remove event listener(s)
---@param event_name string
---@param callback ListenerCB
---@param component_name? string
---@return nil
function events.off(event_name, callback, component_name)
    if not callback and not component_name then
        -- Remove all listeners for this event
        events.listeners[event_name] = nil
        events.logger('msg.info.events', {
            msg = {'Removed all listeners for', event_name},
        })
        return
    end

    local listeners_list = events.listeners[event_name]
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
            events.logger('msg.info.events', {
                msg = {'Removed listener for', event_name, 'from component', listener.component},
            })
        end
    end
end

---Emit an event
---@param event_name string
---@param data? table<unknown,unknown>
---@return number Listeners called.
function events.emit(event_name, data)
    events.logger('msg.info.events', {
        msg = {'Emitting event:', event_name, 'with data:', data and 'present' or 'none'},
    })

    local listeners_called = 0

    -- Call direct listeners
    local direct_listeners = events.listeners[event_name]
    if direct_listeners then
        for _, listener in ipairs(direct_listeners) do
            listeners_called = listeners_called + 1
            local success, err = pcall(listener.callback, event_name, data)
            if not success then
                events.logger('msg.error.events', {msg = {
                    '[Events] Error in listener for', event_name,
                    'from component', listener.component, ':', err
                }})
            end
        end
    end

    -- Call wildcard listeners
    for namespace, wildcard_listeners in pairs(events.wildcards) do
        if event_name:match('^' .. namespace:gsub('%.', '%.') .. '%.') then
            for _, listener in ipairs(wildcard_listeners) do
                listeners_called = listeners_called + 1
                local success, err = pcall(listener.callback, event_name, data)
                if not success then
                    events.logger('msg.error.events', {msg = {
                        'Error in wildcard listener for', namespace,
                        'from component', listener.component, ':', err
                    }})
                end
            end
        end
    end

    events.logger('msg.info.events', {
        msg = {'Called', listeners_called, 'listeners for', event_name},
    })

    return listeners_called
end

---Remove all listeners for a component
---@param component_name string
---@return nil
function events.cleanup_component(component_name)
    local component_listeners = events.components[component_name]
    if not component_listeners then
        events.logger('msg.verbose.events', {
            msg = {'No listeners found for component', component_name},
        })
        return
    end

    local removed_count = 0

    -- Remove each listener tracked for this component
    for _, tracked_listener in ipairs(component_listeners) do
        if tracked_listener.type == 'event' then
            -- Remove from regular listeners
            local event_listeners = events.listeners[tracked_listener.identifier]
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
            local wildcard_listeners = events.wildcards[tracked_listener.identifier]
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
    events.components[component_name] = nil

    events.logger('msg.info.events', {
        msg = {'Cleaned up', removed_count, 'listeners for component', component_name},
    })
end

---Get debugging information
function events.get_debug_info()
    local info = {
        total_events = 0,
        total_listeners = 0,
        total_wildcards = 0,
        components = {}
    }

    -- Count regular listeners
    for _, listeners_list in pairs(events.listeners) do
        info.total_events = info.total_events + 1
        info.total_listeners = info.total_listeners + #listeners_list
    end

    -- Count wildcard listeners
    for _, listeners_list in pairs(events.wildcards) do
        info.total_wildcards = info.total_wildcards + #listeners_list
    end

    -- Count by component
    for component_name, tracked_listeners in pairs(events.components) do
        info.components[component_name] = #tracked_listeners
    end

    return info
end

---Utility function to check if anyone is listening to an event
---@param event_name string
---@return boolean
function events.has_listeners(event_name)
    -- Check direct listeners
    if events.listeners[event_name] and #events.listeners[event_name] > 0 then
        return true
    end

    -- Check wildcard listeners
    for namespace, listeners_list in pairs(events.wildcards) do
        if event_name:match('^' .. namespace:gsub('%.', '%.') .. '%.') and #listeners_list > 0 then
            return true
        end
    end

    return false
end

return events
