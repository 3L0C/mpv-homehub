--[[
--  Text UI controller.
--]]

local mp = require 'mp'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local log = require 'src.core.log'
local options = require 'src.core.options'
local search = require 'src.core.search'

---@class ui_text: Controller
local ui_text = {}

---@class TextState
---@field id NavCtxID
---@field active boolean
---@field visible boolean
---@field needs_render boolean
---@field keybinds TextKeyTable
---@field keybinds_active boolean
---@field keybinds_set boolean
---@field cursor_pos number
---@field current_header TextRendererZone?
---@field current_items Item[]
---@field breadcrumb string[]
---@field search_events SearchClientEventMap
---@field search_results Item[]?
local text_state = {
    id = 'text',
    active = false,
    visible = false,
    needs_render = true,
    keybinds = {},
    keybinds_active = false,
    keybinds_set = false,
    cursor_pos = 1,
    current_header = nil,
    current_items = {},
    breadcrumb = {},
    search_events = {
        results = 'search.text.results',
        cancelled = 'search.text.cancelled',
        completed = 'search.text.completed',
        no_results = 'search.text.no_results',
        position_changed = 'search.text.position_changed',
    },
    search_results = nil,
}

local search_client

---Set the keybind table to user defined keys or defaults
local function set_keybind_table()
    if text_state.keybinds_set then return end

    ---@type TextKeyTable
    local text_keybind_table = options.keybinds and options.keybinds.text or {}

    text_state.keybinds = {
        up = text_keybind_table.up or {'UP'},
        down = text_keybind_table.down or {'DOWN'},
        back = text_keybind_table.back or {'LEFT'},
        select = text_keybind_table.select or {'RIGHT', 'ENTER'},
        multiselect = text_keybind_table.multiselect or {'CTRL+ENTER', 'SPACE'},
        page_up = text_keybind_table.page_up or {'PGUP', 'CTRL+UP'},
        page_down = text_keybind_table.page_down or {'PGDWN', 'CTRL+DOWN'},
        search = text_keybind_table.search or {'/'},
        help = text_keybind_table.help or {'?'},
        toggle = text_keybind_table.toggle or {'CTRL+j', 'MENU'},
    }

    text_state.keybinds_set = true
end

---Bind the default navigation keys.
---@return boolean False if unable to bind keys.
local function bind_keys()
    if text_state.keybinds_active then return true end

    hh_utils.bind_keys(
        text_state.keybinds.up,
        'nav.up',
        'ui_text.active',
        nil,
        { repeatable = true }
    )
    hh_utils.bind_keys(
        text_state.keybinds.down,
        'nav.down',
        'ui_text.active',
        nil,
        { repeatable = true}
    )
    hh_utils.bind_keys(
        text_state.keybinds.back,
        'nav.back',
        'ui_text.active',
        nil,
        { repeatable = true}
    )
    hh_utils.bind_keys(
        text_state.keybinds.select,
        'nav.select',
        'ui_text.active'
    )
    hh_utils.bind_keys(
        text_state.keybinds.multiselect,
        'nav.multiselect',
        'ui_text.active'
    )
    hh_utils.bind_keys(
        text_state.keybinds.search,
        'search.text.activate',
        'ui_text.active'
    )
    -- TODO: implement actual events for these keys
    -- hh_utils.bind_keys(text_state.keys.page_up, '', 'ui_text')
    -- hh_utils.bind_keys(text_state.keys.page_down, '', 'ui_text')
    -- hh_utils.bind_keys(text_state.keys.search, '', 'ui_text')
    -- hh_utils.bind_keys(text_state.keys.help, '', 'ui_text')

    text_state.keybinds_active = true
    return true
end

local function unbind_keys()
    if not text_state.keybinds_active then return end

    events.emit('input.unbind_group', { group = 'ui_text.active' })

    text_state.keybinds_active = false
end

---Format breadcrumb showing only last N components
---@param trail string[]
---@param max_tail? number How many trailing components to show (default: 3)
---@return string
local function format_breadcrumb(trail, max_tail)
    max_tail = max_tail or 3
    local count = #trail

    -- If trail fits within limit, show it all
    if count <= max_tail then
        return table.concat(trail, ' / ')
    end

    -- Build tail: ... / component / component
    local parts = {'...'}
    for i = count - max_tail + 1, count do
        table.insert(parts, trail[i])
    end

    return table.concat(parts, ' / ')
end

---@return string breadcrumb
local function get_breadcrumb()
    return format_breadcrumb(text_state.breadcrumb)
end

---@param crumb string
local function push_crumb(crumb)
    table.insert(text_state.breadcrumb, crumb)
end

---@return string? crumb
local function pop_crumb()
    return table.remove(text_state.breadcrumb)
end

---Render cached content
---@param force_show boolean?
local function render_cached_content(force_show)
    events.emit('text_renderer.render', {
        header = text_state.current_header,
        body = {
            items = text_state.current_items,
        },
        footer = {
            items = {
                {
                    primary_text = '/ - Search, ? - Help',
                },
            },
            style = 'spacious',
        },
        cursor_pos = text_state.cursor_pos,
        force_show = force_show,
    } --[[@as TextRendererRenderData]])
end

---Render search results
---@param data SearchResultsData
local function render_search_results(data)
    if not search_client:is_active() then
        log.warn('text', {'Trying to render search results while client is inactive.'})
        return
    end

    text_state.search_results = data.filtered_items

    if options.search.show_match_count then
        events.emit('text_renderer.render', {
            header = {
                items = {
                    {
                        primary_text = ('Search Results: %d / %d match%s'):format(
                            data.current_position,
                            data.total_matches,
                            data.total_matches == 1 and '' or 'es'
                        ),
                        style_variant = 'accent',
                    },
                    {
                        primary_text = hh_utils.separator,
                        style_variant = 'secondary',
                    },
                },
                style = 'compact',
            },
            body = {
                items = text_state.search_results,
            },
            cursor_pos = data.current_position,
            force_show = true,
        } --[[@as TextRendererRenderData]])
    else
        events.emit('text_renderer.render', {
            body = {
                items = text_state.search_results,
            },
            cursor_pos = data.current_position,
            force_show = true,
        } --[[@as TextRendererRenderData]])
    end
end

---@type HandlerTable
local handlers = {

    -- UI Lifecycle

    ['ui.text.activate'] = function(_, _)
        text_state.active = true
        text_state.visible = true
        text_state.breadcrumb = {}
        bind_keys()
        events.emit('text_renderer.show')
        events.emit('nav.context_push', { ctx_id = text_state.id } --[[@as NavContextPushData]])
        events.emit('content.request', {
            ctx_id = text_state.id,
            nav_id = ''
        } --[[@as ContentRequestData]])
        events.emit('ui.activated_mode', { mode = text_state.id } --[[@as UiModeData]])
    end,

    ['ui.text.deactivate'] = function(_, _)
        text_state.active = false
        text_state.visible = false
        text_state.breadcrumb = {}
        events.emit('text_renderer.hide')
        unbind_keys()
        events.emit('nav.context_pop', { ctx_id = text_state.id } --[[@as NavContextPopData]])
        events.emit('ui.deactivated_mode', { mode = text_state.id } --[[@as UiModeData]])
    end,

    ['ui.text.show'] = function(_, _)
        bind_keys()
        render_cached_content(true)
    end,

    ['ui.text.hide'] = function(_, _)
        unbind_keys()
        events.emit('text_renderer.clear')
    end,

    -- Navigation events

    ---@param event_name EventName
    ---@param data NavContextChangedData|EventData
    ['nav.context_pushed'] = function(event_name, data)
        if not data or not data.old_ctx or not data.new_ctx then
            hh_utils.emit_data_error(event_name, data, 'ui_text')
            return
        end

        if data.new_ctx == text_state.id then
            if text_state.active and text_state.visible then
                -- Got our own context push event. Nothing to do.
            else
                -- Someone is using the text_state.id context besides us...
                log.warn('ui_text', {
                    ("Navigation context id '%s' pushed by another actor..."):format(text_state.id)
                })
            end
        elseif data.old_ctx == text_state.id then
            -- New context pushed
            if text_state.visible then
                -- New context but we are still visible for some reason...
                log.warn('ui_text', {
                    "Possibly overlapping ui after 'nav.context_push'. Emit 'ui.text.hide' first."
                })
            end
        end
    end,

    ---@param event_name EventName
    ---@param data NavNavigatedToData|EventData
    ['nav.navigated_to'] = function(event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_nav_navigated_to, 'ui_text') then
            return
        end

        -- Not our navigation request
        if data.ctx_id ~= text_state.id then return end

        if data.trigger == 'back' then
            -- Update breadcrumb
            pop_crumb() -- Current crumb
            pop_crumb() -- Parent crumb

            -- Load previous data
            events.emit('content.request', {
                ctx_id = text_state.id,
                nav_id = data.nav_id,
            } --[[@as ContentRequestData]])
        end

        -- Update cursor if needed
        if text_state.cursor_pos ~= data.position then
            events.emit('nav.pos_changed', {
                ctx_id = data.ctx_id,
                position = data.position,
                old_position = text_state.cursor_pos,
            } --[[@as NavPositionChangedData]])
        end
    end,

    ---@param event_name EventName
    ---@param data NavPositionChangedData|EventData
    ['nav.pos_changed'] = function(event_name, data)
        if not data or not data.position or not data.old_position or not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'ui_text')
            return
        end

        if data.ctx_id ~= text_state.id then return end

        text_state.cursor_pos = data.position

        events.emit('text_renderer.render', {
            cursor_pos = text_state.cursor_pos,
        } --[[@as TextRendererRenderData]])
    end,

    ---@param event_name EventName
    ---@param data NavSelectedData|EventData
    ['nav.selected'] = function(event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_nav_selected, 'ui_text') then
            return
        end

        events.emit('content.navigate_to', {
            ctx_id = data.ctx_id,
            nav_id = data.nav_id,
            selection = data.position,
        } --[[@as ContentNavToData]])
    end,

    -- Search events

    ---Activate search on current items
    ['search.text.activate'] = function(_, _)
        if not text_state.active then return end

        if search_client:execute(text_state.current_items) then
            log.warn('ui_text', {
                'Could not start search.'
            })
        end
    end,

    ---@param event_name EventName
    ---@param data SearchResultsData|EventData
    [text_state.search_events.results] = function (event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_search_results, 'text') then
            return
        end

        events.emit('ui.text.hide')
        render_search_results(data)
    end,

    ---@param event_name EventName
    ---@param data SearchCancelledData|EventData
    [text_state.search_events.cancelled] = function(event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_search_cancelled, 'text') then
            return
        end

        events.emit('ui.text.show')
    end,

    ---@param event_name EventName
    ---@param data SearchCompletedData|EventData
    [text_state.search_events.completed] = function(event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_search_completed, 'text') then
            return
        end

        events.emit('ui.text.show')
        events.emit('nav.set_state', {
            ctx_id = text_state.id,
            position = data.selected_index,
        } --[[@as NavSetStateData]])
        events.emit('nav.select')
    end,

    ---@param event_name EventName
    ---@param data SearchNoResultsData|EventData
    [text_state.search_events.no_results] = function(event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_search_no_results, 'text') then
            return
        end

        render_cached_content(true)
        events.emit('text_renderer.render', {
            header = {
                items = {
                    {
                        primary_text = ('No results for query: "%s"'):format(data.query),
                        style_variant = 'accent',
                    },
                    {
                        primary_text = hh_utils.separator,
                        style_variant = 'secondary',
                    },
                },
            },
        } --[[@as TextRendererRenderData]])

        mp.add_timeout(3, function()
            render_cached_content()
        end)
    end,

    ---@param event_name EventName
    ---@param data SearchPositionChangedData|EventData
    [text_state.search_events.position_changed] = function(event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_search_pos_changed, 'text') then
            return
        end

        events.emit('text_renderer.render', {
            header = {
                items = {
                    {
                        primary_text = ('Search Results: %d / %d match%s'):format(
                            data.position,
                            data.total,
                            data.total == 1 and '' or 'es'
                        ),
                        style_variant = 'accent',
                    },
                    {
                        primary_text = hh_utils.separator,
                        style_variant = 'secondary',
                    },
                },
                style = 'compact',
            },
            cursor_pos = data.position,
        } --[[@as TextRendererRenderData]])
    end,

    -- Content events

    ---@param event_name EventName
    ---@param data ContentLoadedData|EventData
    ['content.loaded'] = function(event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_content_loaded, 'ui_text') then
            return
        end

        if data.ctx_id ~= text_state.id then return end

        text_state.current_items = data.items

        events.emit('nav.navigate_to', {
            ctx_id = text_state.id,
            nav_id = data.nav_id,
            columns = 1,
            position = 0,
            total_items = #data.items,
        } --[[@as NavNavigateToData]])

        if data.content_title ~= '' then
            push_crumb(data.content_title)
        end

        local header_text = data.adapter_name

        if #text_state.breadcrumb ~= 0 then
            header_text = header_text .. ': ' .. get_breadcrumb()
        end

        -- Cache header
        text_state.current_header = {
            items = {
                {
                    primary_text = header_text,
                    style_variant = 'header',
                },
                {
                    primary_text = hh_utils.separator,
                    style_variant = 'secondary',
                },
            },
            style = 'compact',
        }

        render_cached_content()
    end,

    ---@param event_name EventName
    ---@param data ContentLoadingData|EventData|nil
    ['content.loading'] = function(event_name, data)
        if not data or not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'ui_text')
            return
        end

        if data.ctx_id ~= text_state.id then return end

        text_state.current_items = {}

        events.emit('text_renderer.render', {
            header = text_state.current_header,
            body = {
                items = {
                    {
                        primary_text = 'Loading...',
                    },
                },
            },
            footer = {
                items = {
                    {
                        primary_text = '/ - Search, ? - Help',
                    },
                },
                style = 'spacious',
            },
        } --[[@as TextRendererRenderData]])
    end,

    ---@param event_name EventName
    ---@param data ContentErrorData|EventData|nil
    ['content.error'] = function(event_name, data)
        if not data or not data.ctx_id then
            hh_utils.emit_data_error(event_name, data, 'ui_text')
            return
        end

        if data.ctx_id ~= text_state.id then return end

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

---Setup once System is prepped
local function on_prep()
    -- Define keytable and bind toggle key
    set_keybind_table()
    hh_utils.bind_keys(text_state.keybinds.toggle, 'ui.toggle', 'ui_text.global', {
        mode = text_state.id
    })

    search_client = search.new({
        case_sensitive = options.search.case_sensitive,
        search_fields = options.search.search_fields,
        events = {
            results = text_state.search_events.results,
            cancelled = text_state.search_events.cancelled,
            completed = text_state.search_events.completed,
            no_results = text_state.search_events.no_results,
            position_changed = text_state.search_events.position_changed,
        }
    })

    events.emit('ui.register_mode', { mode = text_state.id } --[[@as UiModeData]])
end

function ui_text.init()
    for event in pairs(handlers) do
        events.on(event, handler, 'ui_text')
    end

    events.on('sys.prep', on_prep, 'ui_text')
end

function ui_text.cleanup()
    if text_state.active then
        events.emit('ui.deactivate_mode', {
            mode = text_state.id
        } --[[@as UiModeData]])
    end
    events.emit('input.unbind_group', { group = 'ui_text.global' })
end

return ui_text
