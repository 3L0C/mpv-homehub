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
        events.emit('text_renderer.show')
        events.emit('nav.context_push', { ctx_id = 'text' } --[[@as NavCtxPushData]])
        events.emit('content.request', {
            ctx_id = 'text',
            location = 'root',
        } --[[@as ContentRequestData]])
        events.emit('ui.activated_mode', { mode = 'text' } --[[@as UiModeData]])
    end,

    ['ui.text.deactivate'] = function(_, _)
        text_state.active = false
        text_state.visible = false
        events.emit('text_renderer.hide')
        unbind_keys()
        events.emit('nav.context_pop', { ctx_id = 'text' } --[[@as NavCtxPopData]])
        events.emit('ui.deactivated_mode', { mode = 'text' } --[[@as UiModeData]])
    end,

    ['ui.text.show'] = function(_, _)
        events.emit('text_renderer.show')
    end,

    ['ui.text.hide'] = function(_, _)
        events.emit('text_renderer.hide')
    end,

    -- Navigation events

    ---@param event_name EventName
    ---@param data NavCtxPushedData|EventData|nil
    ['nav.context_pushed'] = function(event_name, data)
        if not data or not data.old_ctx or not data.new_ctx then
            hh_utils.emit_data_error(event_name, data, 'ui_text')
            return
        end

        if data.new_ctx == 'text' then
            if text_state.active and text_state.visible then
                -- Got our own context push event. Nothing to do.
            else
                -- Someone is using the 'text' context besides us...
                events.emit('msg.warn.ui_text', { msg = {
                    "Navigation context id 'text' pushed by another actor..."
                } })
            end
        elseif data.old_ctx == 'text' then
            -- New context pushed
            if text_state.visible then
                -- New context but we are still visible for some reason...
                events.emit('msg.warn.ui_text', { msg = {
                    "Possibly overlapping ui after 'nav.context_push'. Emit 'ui.text.hide' first."
                } })
            end
        end
    end,

    ---@param event_name EventName
    ---@param data NavToData|EventData|nil
    ['nav.navigated_to'] = function(event_name, data)
        if not data or not hh_utils.is_valid_nav_to_data(data) then
            hh_utils.emit_data_error(event_name, data, 'ui_text')
            return
        end

        -- Not our navigation request
        if data.ctx_id ~= 'text' then return end

        events.emit('content.request', {
            ctx_id = 'text',
            location = data.nav_id,
        } --[[@as ContentRequestData]])
    end,

    ---@param event_name EventName
    ---@param data NavPosChangedData|EventData|nil
    ['nav.pos_changed'] = function(event_name, data)
        if not data or not data.pos or not data.old_pos or not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'ui_text')
            return
        end

        if data.ctx_id ~= 'text' then return end

        events.emit('text_renderer.render', {
            cursor_pos = data.pos,
        } --[[@as TextRendererRenderData]])
    end,

    -- Content events

    ---@param event_name EventName
    ---@param data ContentLoadedData|EventData|nil
    ['content.loaded'] = function(event_name, data)
        if not data then
            hh_utils.emit_data_error(event_name, data, 'ui_text')
            return
        end

        if data.ctx_id ~= 'text' then return end

        events.emit('text_renderer.render', data --[[@as TextRendererRenderData]])
    end,

    ---@param event_name EventName
    ---@param data ContentLoadingData|EventData|nil
    ['content.loading'] = function(event_name, data)
        if not data or not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'ui_text')
            return
        end

        if data.ctx_id ~= 'text' then return end

        events.emit('text_renderer.render', {
            items = {}
        } --[[@as TextRendererRenderData]])
    end,

    ---@param event_name EventName
    ---@param data ContentErrorData|EventData|nil
    ['content.error'] = function(event_name, data)
        if not data or not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'ui_text')
            return
        end

        if data.ctx_id ~= 'text' then return end

        events.emit('text_renderer.render', {
            items = {
                {
                    primary_text = data and data.msg or 'Error loading content...',
                    highlight = true,
                }
            }
        } --[[@as TextRendererRenderData]])
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
