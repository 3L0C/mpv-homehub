--[[
--  UI coordinator.
--]]

local utils = require 'mp.utils'

local events = require "src.core.events"
local hh_utils = require 'src.core.utils'
local options = require "src.core.options"

---@class ui: Controller
local ui = {}

local ui_state = {
    -- Main UI state
    active = false,
    ---@type Set<UiMode>
    registered_modes = {},
    ---@type UiMode
    active_mode = nil,
    ---@type UiMode
    default_mode = nil,

    -- Overlay state
    ---@type Set<UiOverlay>
    registered_overlays = {},
    ---@type UiOverlay[]
    overlay_stack = {},

    -- Transition state
    transitioning = false,
}

---Bind UI keys
local function bind_keys()
end

---Unbind UI keys
local function unbind_keys()
end

---Initialize `ui_state`.
local function reset_ui_state()
    ui_state = {
        active = false,
        registered_modes = {},
        active_mode = nil,
        default_mode = nil,
        registered_overlays = {},
        overlay_stack = {},
        transitioning = false,
    }
end

---Test if `mode` is a valid, non-nil UiMode.
---@param mode any
---@return boolean
local function is_registered_mode(mode)
    return type(mode) == 'string' and ui_state.registered_modes[mode] or false
end

---Deactivate `ui_state.active_mode`
---@return boolean
local function deactivate_mode()
    if not ui_state.active then return true end

    if not ui_state.active_mode then
        events.emit('msg.error.ui', { msg = {
            'Internal error: UI is active, but no mode is set...'
        } })
        return false
    end

    ui_state.transitioning = true
    events.emit('ui.' .. ui_state.active_mode .. '.deactivate')
    if ui_state.transitioning then
        events.emit('msg.error.ui', { msg = {
            ("UI deactivation request to '%s' mode was not honored."):format(ui_state.active_mode)
        } })
        ui_state.transitioning = false
        return false
    end

    ui_state.active = false
    ui_state.active_mode = nil
    return true
end

---Activate `mode`.
---@param mode UiMode
local function activate_mode(mode)
    -- Only activate if mode is valid
    if not is_registered_mode(mode) then
        events.emit('msg.error.ui', { msg = {
            "Ignoring activation request for unrecognized UI mode:", utils.to_string(mode)
        } })
        return
    end

    -- Mode is already active. Do nothing.
    if ui_state.active and ui_state.active_mode == mode then return end

    -- Exit if unable to deactivate current mode
    if ui_state.active and not deactivate_mode() then
        return
    else
        ui_state.active = true
    end

    -- Activate requested mode
    ui_state.transitioning = true
    events.emit('ui.' .. mode .. '.activate')

    if ui_state.transitioning then
        events.emit('msg.error.ui', { msg = {
            ("UI activation request to '%s' mode was not honored."):format(mode),
        } })
        ui_state.transitioning = false
        return
    end

    if ui_state.active_mode ~= mode then
        -- Should never have `ui_state.transitioning == false` but `ui_state.active_mode ~= mode`.
        -- This would only happen if `'ui.activated_mode'` contains an internal error.
        events.emit('msg.error.ui', { msg = {
            ("UI activation request to '%s' mode encountered internal error."):format(mode),
        } })
    end
end

---Start the user's preferred UI mode if they have enabled autostart.
local function open_at_start()
    if options.ui_autostart then
        activate_mode(options.ui_default_mode)
    end
end

---Validate a mode event before mutating state.
---@param event_name EventName
---@param data UiModeData|EventData|nil
---@return UiMode|nil
local function validate_mode(event_name, data)
    if not data or not data.mode then
        hh_utils.emit_data_error(event_name, data, 'ui')
        return nil
    end

    if not is_registered_mode(data.mode) then
        events.emit('msg.error.ui', { msg = {
            'Got invalid ui mode:', utils.to_string(data.mode)
        } })
        return nil
    end

    return data.mode
end

---Factory for mode registration handlers.
---@param on_success fun(mode: UiMode)
---@return ListenerCB
local function make_mode_registration_handler(on_success)
    ---@param event_name EventName
    ---@param data UiModeData|EventData|nil
    return function(event_name, data)
        if not data or not data.mode or type(data.mode) ~= 'string' then
            hh_utils.emit_data_error(event_name, data, 'ui')
            return nil
        end

        on_success(data.mode)
    end
end

---Validate a mode transition event before mutating state.
---@param event_name EventName
---@param data UiModeData|EventData|nil
---@return UiMode|nil
local function validate_mode_transition(event_name, data)
    local mode = validate_mode(event_name, data)

    if mode and not ui_state.transitioning then
        events.emit('msg.error.ui', { msg = {
            ("Got '%s' event outside of transitioning state:"):format(event_name),
            mode
        } })
        return nil
    end

    return mode
end

---Factory for mode transition handlers.
---@param on_success fun(mode: UiMode)
---@return ListenerCB
local function make_mode_transition_handler(on_success)
    return function(event_name, data)
        local mode = validate_mode_transition(event_name, data)
        if not mode then return end

        on_success(mode)
        ui_state.transitioning = false
    end
end

---Validate overlay data before mutating state.
---@param event_name EventName
---@param data UiOverlayData|EventData|nil
---@return UiOverlay|nil
local function validate_overlay(event_name, data)
    if not data or not data.overlay then
        hh_utils.emit_data_error(event_name, data, 'ui')
        return nil
    end

    if type(data.overlay) ~= 'string' then
        events.emit('msg.error.ui', { msg = {
            ("Got non-string overlay in event '%s':"):format(event_name),
            utils.to_string(data.overlay)
        } })
        return nil
    end

    return data.overlay
end

---Factory for overlay registration handlers.
---@param on_success fun(mode: UiOverlay)
---@return ListenerCB
local function make_overlay_registration_handler(on_success)
    return function(event_name, data)
        local overlay = validate_overlay(event_name, data)
        if not overlay then return end

        on_success(overlay)
    end
end

---Factory for overlay stack handlers.
---@param on_success fun(mode: UiOverlay)
---@return ListenerCB
local function make_overlay_stack_handler(on_success)
    return function(event_name, data)
        local overlay = validate_overlay(event_name, data)
        if not overlay then return end

        if not ui_state.active then
            events.emit('msg.warn.ui', { msg = {
                ("Ignoring '%s' request - no main UI active:"):format(event_name),
                overlay
            } })
            return
        end

        if not ui_state.registered_overlays[overlay] then
            events.emit('msg.error.ui', { msg = {
                ("Got unregistered overlay in '%s' request:"):format(event_name),
                overlay
            } })
            return
        end

        on_success(overlay)
    end
end

---@type HandlerTable
local handlers = {

    -- Mode events.

    ['ui.register_mode'] = make_mode_registration_handler(function(mode)
        ui_state.registered_modes[mode] = true
        events.emit('msg.debug.ui', { msg = {
            'Registered mode:', mode
        } })
    end),

    ['ui.unregister_mode'] = make_mode_registration_handler(function(mode)
        ui_state.registered_modes[mode] = false
        events.emit('msg.debug.ui', { msg = {
            'Unregistered mode:', mode
        } })
    end),

    ---@param event_name EventName
    ---@param data UiModeData|EventData|nil
    ['ui.activate_mode'] = function(event_name, data)
        local mode = validate_mode(event_name, data)
        if not mode then return end
        activate_mode(mode)
    end,

    ['ui.deactivate_mode'] = function(_, _)
        deactivate_mode()
    end,

    ---@param event_name EventName
    ---@param data UiModeData|EventData|nil
    ['ui.toggle_mode'] = function(event_name, data)
        local mode = validate_mode(event_name, data)
        if not mode then return end

        if ui_state.active_mode == mode then
            deactivate_mode()
        else
            activate_mode(mode)
        end
    end,

    -- Mode change completion events.
    ['ui.activated_mode'] = make_mode_transition_handler(function(mode)
        ui_state.active_mode = mode
    end),

    ['ui.deactivated_mode'] = make_mode_transition_handler(function(_)
        ui_state.active = false
        ui_state.active_mode = nil
    end),

    -- Overlay events

    ['ui.register_overlay'] = make_overlay_registration_handler(function(overlay)
        ui_state.registered_overlays[overlay] = true
        events.emit('msg.debug.ui', { msg = {
            'Registered overlay:', overlay
        } })
    end),

    ['ui.unregister_overlay'] = make_overlay_registration_handler(function(overlay)
        ui_state.registered_overlays[overlay] = false
        events.emit('msg.debug.ui', { msg = {
            'Unregistered overlay:', overlay
        } })
    end),

    ['ui.push_overlay'] = make_overlay_stack_handler(function(overlay)
        -- Main UI still showing.
        if #ui_state.overlay_stack == 0 then
            events.emit('ui.' .. ui_state.active_mode .. '.hide')
        else
            events.emit('ui.' .. ui_state.overlay_stack[#ui_state.overlay_stack] .. '.hide')
        end

        -- Push overlay onto the stack
        table.insert(ui_state.overlay_stack, overlay)

        -- Activate the overlay
        events.emit('ui.' .. overlay .. '.activate')
        events.emit('msg.debug.ui', { msg = {
            'Pushed overlay:', overlay, 'Stack:', table.concat(ui_state.overlay_stack, ', ')
        } })
    end),

    ['ui.pop_overlay'] = make_overlay_stack_handler(function(overlay)
        -- Is `overlay` the current overlay?
        if #ui_state.overlay_stack == 0 then
            events.emit('msg.warn.ui', { msg = {
                'Ignoring overlay pop request - no active overlays:', overlay
            } })
            return
        end

        if ui_state.overlay_stack[#ui_state.overlay_stack] ~= overlay then
            events.emit('msg.warn.ui', { msg = {
                'Ignoring overlay pop request - active overlay:', ui_state.overlay_stack[#ui_state.overlay_stack],
                'got overlay:', overlay
            } })
            return
        end

        -- Deactivate current overlay and pop it from the stack.
        events.emit('ui.' .. overlay .. '.deactivate')
        table.remove(ui_state.overlay_stack)

        events.emit('msg.debug.ui', { msg = {
            'Popped overlay:', overlay, 'Stack:', table.concat(ui_state.overlay_stack, ', ')
        } })

        -- Show main UI or previous overlay.
        if #ui_state.overlay_stack == 0 then
            events.emit('msg.debug.ui', { msg = {
                'Activating hidden UI mode:', ui_state.active_mode
            } })
            events.emit('ui.' .. ui_state.active_mode .. '.show')
        else
            events.emit('msg.debug.ui', { msg = {
                'Activating hidden overlay:', ui_state.overlay_stack[#ui_state.overlay_stack]
            } })
            events.emit('ui.' .. ui_state.overlay_stack[#ui_state.overlay_stack] .. '.show')
        end
    end),
}

---Main ui event handler.
---@param event_name EventName
---@param data EventData
local function handler(event_name, data)
    hh_utils.handler_template(event_name, data, handlers, 'ui')
end

function ui.init()
    events.on('sys.ready', open_at_start, 'ui')
    events.on('sys.cleanup', ui.cleanup, 'ui')
    for event in pairs(handlers) do
        events.on(event, handler, 'ui')
    end
    bind_keys()
end

function ui.cleanup()
    if not ui_state.active then return end

    for _, overlay in ipairs(ui_state.overlay_stack) do
        events.emit('ui.pop_overlay', { overlay = overlay })
    end

    events.emit('ui.deactivate_mode')
    reset_ui_state()
    unbind_keys()
end

return ui
