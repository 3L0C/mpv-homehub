--[[
--  Text UI controller.
--]]

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local options = require 'src.core.options'

---@class ui_text: Controller
local ui_text = {}

local text_state = {
    ---@type boolean
    active = false,
    ---@type boolean
    visible = false,
    ---@type boolean
    needs_render = true,
    ---@type boolean
    keybinds_active = false,
}

---Bind the default navigation keys.
local function bind_keys()
    if text_state.keybinds_active then return end

    local keys = options.ui_text_keys
    hh_utils.bind_keys(keys.up, 'nav.up')
    hh_utils.bind_keys(keys.down, 'nav.down')
    hh_utils.bind_keys(keys.back, 'nav.back')
    hh_utils.bind_keys(keys.select, 'nav.select')
    hh_utils.bind_keys(keys.multiselect, 'nav.multiselect')

    text_state.keybinds_active = true
end

local function unbind_keys()
    if not text_state.keybinds_active then return end

    local keys = options.ui_text_keys
    hh_utils.unbind_keys(keys.up)
    hh_utils.unbind_keys(keys.down)
    hh_utils.unbind_keys(keys.back)
    hh_utils.unbind_keys(keys.select)
    hh_utils.unbind_keys(keys.multiselect)

    text_state.keybinds_active = false
end

---@type HandlerTable
local handlers = {

    -- UI Lifecycle

    ['ui.text.activate'] = function(_, _)
        text_state.active = true
        text_state.visible = true
        bind_keys()
        events.emit('nav.context_push', {
            ctx_id = 'text',
        } --[[@as NavCtxPushData]])
        -- TODO emit 'nav.navigate_to' once the content/adapter controllers are setup.
        events.emit('ui.activated_mode', { mode = 'text' } --[[@as UiModeData]])
    end,

    ['ui.text.deactivate'] = function(_, _)
        text_state.active = false
        text_state.visible = false
        unbind_keys()
        events.emit('ui.deactivated_mode', { mode = 'text' } --[[@as UiModeData]])
    end,

    ['ui.text.show'] = function(_, _)

    end,

    ['ui.text.hide'] = function(_, _)

    end,
}

---Main text ui event handler.
---@param event_name EventName
---@param data EventData
local function handler(event_name, data)
    hh_utils.handler_template(event_name, data, handlers, 'ui_text')
end

function ui_text.init()
    for event in pairs(handlers) do
        events.on(event, handler, 'ui_text')
    end

    events.on('sys.prep', function()
        events.emit('ui.register_mode', { mode = 'text' } --[[@as UiModeData]])
    end, 'ui_text')
end

function ui_text.cleanup()
    if text_state.active then
        events.emit('ui.deactivate_mode', {
            mode = 'text'
        } --[[@as UiModeData]])
    end
end

return ui_text
