--[[
--  Text renderer view.
--  Pure presentation component for displaying structured text content in mpv
--]]

local mp       = require 'mp'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local options  = require 'src.core.options'

---@class text_renderer: View
local text_renderer = {}

-- Base font size following `mpv-file-browser` pattern
local BASE_FONT_SIZE = 25

-- ASS alignment matrix (from `mpv-file-browser`)
local ASS_ALIGNMENT_MATRIX = {
    top =       {left = 7, center = 8, right = 9},
    center =    {left = 4, center = 5, right = 6},
    bottom =    {left = 1, center = 2, right = 3},
}

local renderer_state = {
    -- Lifecycle
    active = false,
    initialized = false,

    -- Content state
    ---@type Item[]
    display_items = {},
    empty_text = 'No items available.',

    -- Navigation state
    cursor_position = 1,
    ---@type Set<number>
    selection_state = {},

    -- Dynamic geometry (inspired by `mpv-gallery-view`)
    geometry = {
        screen_width = 1920,
        screen_height = 1080,
        line_height = BASE_FONT_SIZE * 1.2,  -- 20% spacing like gallery-view
        available_height = 0,                -- Usable screen area for text
        margin_top = 0,                      -- Top margin for centering
        margin_bottom = 0,                   -- Bottom margin
        max_items = 20,                      -- Maximum displayable items (dynamic)
        ok = false,                          -- Whether geometry is properly initialized
    },

    -- Viewport calculation (enhanced from file-browser)
    view_window = {
        start = 1,              -- First visible item index
        finish = 0,             -- Last visible item index
        overflow = false,       -- Whether content exceeds viewport
    },

    -- ASS rendering
    ---@type OSDOverlay
    overlay = nil,
    needs_update = true,
    ---@type string[]
    string_buffer = {},

    -- Styling - pre-calculated ASS style strings
    style = {
        global = '',            -- Global alignment/base style
        body = '',              -- Normal item text
        selected = '',          -- Selected item highlight
        cursor = '',            -- Cursor icon/marker
        multiselect = '',       -- Multi-selected items
        accent = '',            -- Accent/highlight color
        secondary = '',         -- Secondary text color
        warning = '',           -- Warning/escape character style
    },
}

---Dynamic geometry calculation (inspired by `mpv-gallery-view`).
---https://github.com/occivink/mpv-gallery-view
---Calculates maximum displayable items based on screen dimensions.
local function compute_text_geometry()
    local g = renderer_state.geometry

    -- Update line height based on current font size
    g.line_height = options.scaling_factor_body * BASE_FONT_SIZE * 1.2

    -- Calculate available height with margins (like gallery-view's 90% approach)
    local margin_ratio = options.screen_margin_ratio
    local total_margin = g.screen_height * margin_ratio * 2 -- Top + bottom
    g.available_height = math.max(g.line_height, g.screen_height - total_margin)

    -- Calculate maximum displayable items
    local max_items = math.floor(g.available_height / g.line_height)
    g.max_items = math.max(1, max_items)

    -- Calculate centering margins (like gallery-view's effective_spacing)
    local used_height = g.max_items * g.line_height
    local remaining_height = g.screen_height - used_height
    g.margin_top = math.max(0, remaining_height / 2)
    g.margin_bottom = remaining_height - g.margin_top

    g.ok = true

    events.emit('msg.debug.text_renderer', { msg = {
        'Computed geometry:',
        'srceen=' .. g.screen_width .. 'x' .. g.screen_height,
        'max_items=' .. g.max_items,
        'line_height=' .. g.line_height,
        'margin_top=' .. g.margin_top,
    } })
end

---Enhanced viewport calculation (based on `mpv-file-browser` + centering from `mpv-gallery-view`)
---@return number start_index
---@return number end_index
---@return boolean has_overflow
local function calculate_view_window()
    local item_count = #renderer_state.display_items
    local max_displayable = renderer_state.geometry.max_items

    if item_count == 0 then
        return 1, 0, false
    end

    local cursor_pos = renderer_state.cursor_position
    local start_pos = 1
    local end_pos = math.min(item_count, max_displayable)

    -- Selection-centered viewport calculation (from `mpv-file-browser`)
    if item_count > max_displayable then
        local mid_point = math.ceil(max_displayable / 2) + 1

        if cursor_pos + mid_point > max_displayable then
            local offset = cursor_pos - max_displayable + mid_point

            -- Prevent overshoot beyond end of list
            if max_displayable + offset > item_count then
                offset = offset - ((max_displayable + offset) - item_count)
            end

            start_pos = math.max(1, 1 + offset)
            end_pos = math.min(item_count, start_pos + max_displayable - 1)
        end
    end

    local has_overflow = item_count > max_displayable

    -- Store in view_window for status reporting
    renderer_state.view_window.start = start_pos
    renderer_state.view_window.finish = end_pos
    renderer_state.view_window.overflow = has_overflow

    return start_pos, end_pos, has_overflow
end

---Initialize ASS style strings (enhanced from `mpv-file-browser`)
local function initialize_styles()
    -- Get alignment values (file-browser pattern)
    local align_x = options.align_x == 'auto'
        and mp.get_property('osd-align-x', 'left')
        or options.align_x
    local align_y = options.align_y == 'auto'
        and mp.get_property('osd-align-y', 'top')
        or options.align_y

    local style = renderer_state.style

    -- Global alignment style
    style.global = ([[{\an%d}]]):format(ASS_ALIGNMENT_MATRIX[align_y][align_x])

    -- Body text style (file-browser pattern)
    style.body = ([[{\r\q2\fs%d\fn%s\c&H%s&}]]):format(
        options.scaling_factor_body * BASE_FONT_SIZE,
        options.font_name_body,
        options.font_color_body
    )

    -- Cursor style
    style.cursor = ([[{\fn%s\c&H%s&}]]):format(
        options.font_name_body,
        options.font_color_cursor
    )

    -- Selected item style
    style.selected = ([[{\c&H%s&}]]):format(options.font_color_selected)

    -- Multiselect style
    style.multiselect = ([[{\c&H%s&}]]):format(options.font_color_multiselect)

    -- Accent and secondary styles
    style.accent = ([[{\c&H%s&}]]):format(options.font_color_accent)
    style.secondary = ([[{\c&H%s&}]]):format(options.font_color_secondary)

    -- Warning style for escaped characters (from file-browser)
    style.warning = ([[{\c&H%s&}]]):format(options.font_color_warning)
end

---Initialize MPV overlay system with proper error handling
local function initialize_overlay()
    if renderer_state.overlay then
        renderer_state.overlay:remove()
    end

    renderer_state.overlay = mp.create_osd_overlay("ass-events")
    renderer_state.overlay.res_y = 720 -- Standard resolution base
    renderer_state.initialized = true

    events.emit('msg.debug.text_renderer', {
        msg = 'MPV overlay initialized'
    })
end

---Append strings to the ASS buffer (file-browser pattern)
---@param ... string
local function append_to_buffer(...)
    for i = 1, select("#", ...) do
        local str = select(i, ...)
        if str then
            table.insert(renderer_state.string_buffer, str)
        end
    end
end

---Add newline to ASS buffer
local function append_newline()
    table.insert(renderer_state.string_buffer, '\\N')
end

---Clear and flush string buffer to overlay
local function flush_buffer()
    if renderer_state.overlay then
        renderer_state.overlay.data = table.concat(renderer_state.string_buffer, '')
        renderer_state.string_buffer = {}
    end
end

---Update overlay display with error handling
local function draw_overlay()
    if renderer_state.overlay then
        renderer_state.overlay:update()
    end
end

---Remove overlay from display
local function remove_overlay()
    if renderer_state.overlay then
        renderer_state.overlay:remove()
    end
end

---Render cursor for given item position
---@param position number
local function render_cursor(position)
    local style = renderer_state.display_items[position].style_variant or 'default'

    if style ~= 'default' then
        append_to_buffer('\\h\\h\\h')
    elseif position == renderer_state.cursor_position then
        if renderer_state.selection_state[position] then
            append_to_buffer(renderer_state.style.cursor, options.cursor_selected_icon, '\\h')
        else
            append_to_buffer(renderer_state.style.cursor, options.cursor_icon, '\\h')
        end
    else
        if renderer_state.selection_state[position] then
            append_to_buffer(options.selected_icon, '\\h')
        else
            append_to_buffer(options.normal_icon, '\\h')
        end
    end
end

---Render a single display item with enhanced styling support
---@param item Item
---@param position number
local function render_item(item, position)
    -- Apply base body style
    append_to_buffer(renderer_state.style.body)

    -- Render cursor (left alignment assumed for Phase 1)
    render_cursor(position)

    -- Apply item-specific styling
    local item_style = ''
    local multiselect_count = 0
    for _ in pairs(renderer_state.selection_state) do multiselect_count = multiselect_count + 1 end

    if renderer_state.selection_state[position] then
        if multiselect_count > 1 then
            item_style = renderer_state.style.multiselect
        else
            item_style = renderer_state.style.selected
        end
        append_to_buffer(item_style)
    end

    -- Handle style variants (Phase 1 basic support)
    if item.style_variant then
        if item.style_variant == 'accent' then
            append_to_buffer(renderer_state.style.accent)
        elseif item.style_variant == 'secondary' or item.style_variant == 'muted' then
            append_to_buffer(renderer_state.style.secondary)
        end
    end

    -- Render primary text with proper ASS escaping
    local display_text = item.primary_text or 'Untitled'
    local escaped_text = hh_utils.ass_escape(display_text, renderer_state.style.warning .. '⊠' .. item_style)
    append_to_buffer(escaped_text, '\\h')

    -- Add newline for next item
    append_newline()
end

---Generate ASS content and update overlay with enhanced error handling
local function generate_and_display_ass()
    if not renderer_state.active or not renderer_state.initialized then
        return
    end

    -- Ensure geometry is calculated
    if not renderer_state.geometry.ok then
        compute_text_geometry()
    end

    -- Clear buffer
    renderer_state.string_buffer = {}

    -- Add global alignment style
    append_to_buffer(renderer_state.style.global)

    -- Handle empty content
    if #renderer_state.display_items == 0 then
        append_to_buffer(renderer_state.style.body, hh_utils.ass_escape(renderer_state.empty_text))
        flush_buffer()
        draw_overlay()

        -- Emit status event
        events.emit('text_renderer.updated', {
            visible_items = 0,
            cursor_pos = 0,
            view_start = 0,
            view_end = 0,
            has_overflow = false
        })
        return
    end

    -- Calculate viewport with enhanced algorithm
    local view_start, view_end, has_overflow = calculate_view_window()

    -- Render visible items
    for i = view_start, view_end do
        local item = renderer_state.display_items[i]
        render_item(item, i)
    end

    -- Flush buffer and draw
    flush_buffer()
    draw_overlay()

    -- Emit completion status with enhanced information
    events.emit('text_renderer.updated', {
        visible_items = view_end - view_start + 1,
        cursor_pos = renderer_state.cursor_position,
        view_start = view_start,
        view_end = view_end,
        has_overflow = has_overflow,
        geometry = {
            max_items = renderer_state.geometry.max_items,
            line_height = renderer_state.geometry.line_height,
            screen_height = renderer_state.geometry.screen_height
        }
    })

    -- Reset update flag
    renderer_state.needs_update = false

    events.emit('msg.debug.text_renderer', {
        msg = {'Rendered', view_end - view_start + 1, 'of', #renderer_state.display_items, 'items'}
    })
end

---Handle screen resize with dynamic geometry recalculation
---@param width number
---@param height number
local function handle_screen_resize(width, height)
    local old_max_items = renderer_state.geometry.max_items

    -- Update screen dimensions
    renderer_state.geometry.screen_width = width
    renderer_state.geometry.screen_height = height

    -- Recalculate geometry
    compute_text_geometry()

    -- Check if viewport capacity changed
    if old_max_items ~= renderer_state.geometry.max_items then
        renderer_state.needs_update = true

        events.emit('msg.info.text_renderer', {
            msg = {
                'Geometry changed:',
                old_max_items .. ' -> ' .. renderer_state.geometry.max_items .. ' max items'
            }
        })

        -- Emit viewport changed event
        events.emit('text_renderer.viewport_changed', {
            max_visible_items = renderer_state.geometry.max_items,
            viewport_height = renderer_state.geometry.available_height,
            line_height = renderer_state.geometry.line_height,
            old_max_items = old_max_items
        })
    end
end

---Event handlers following HomeHub pattern with enhanced functionality
---@type HandlerTable
local handlers = {

    ---Main render request handler with enhanced validation
    ---@param _ EventName
    ---@param data TextRendererRenderData|EventData|nil
    ['text_renderer.render'] = function(_, data)
        if not data then
            events.emit('msg.warn.text_renderer', {
                msg = 'Received render request with no data'
            })
            return
        end

        -- Update content if provided
        if data.items then
            if type(data.items) ~= 'table' then
                events.emit('msg.error.text_renderer', {
                    msg = 'Items must be a table/array'
                })
                return
            end
            renderer_state.display_items = data.items
            renderer_state.needs_update = true
        end

        -- Update cursor position if provided with validation
        if data.cursor_pos and type(data.cursor_pos) == 'number' then
            local new_pos = math.max(1, math.min(data.cursor_pos, math.max(1, #renderer_state.display_items)))
            if new_pos ~= renderer_state.cursor_position then
                renderer_state.cursor_position = new_pos
                renderer_state.needs_update = true
            end
        end

        -- Update selection state if provided
        if data.selection then
            if type(data.selection) == 'table' then
                renderer_state.selection_state = data.selection
                renderer_state.needs_update = true
            else
                events.emit('msg.warn.text_renderer', {
                    msg = 'Selection state must be a table'
                })
            end
        end

        -- Force update if requested
        if data.force_update then
            renderer_state.needs_update = true
        end

        -- Force show if requested
        if data.force_show then
            renderer_state.active = true
        end

        -- Render if update needed
        if renderer_state.needs_update then
            generate_and_display_ass()
        end
    end,

    ---Make overlay visible
    ['text_renderer.show'] = function(_, _)
        renderer_state.active = true
        if renderer_state.initialized then
            renderer_state.needs_update = true
            generate_and_display_ass()
        end
        events.emit('msg.debug.text_renderer', { msg = 'Renderer activated' })
    end,

    ---Hide overlay but preserve state
    ['text_renderer.hide'] = function(_, _)
        renderer_state.active = false
        if renderer_state.overlay then
            remove_overlay()
        end
        events.emit('msg.debug.text_renderer', { msg = 'Renderer hidden' })
    end,

    ---Clear content and hide
    ['text_renderer.clear'] = function(_, _)
        renderer_state.display_items = {}
        renderer_state.cursor_position = 1
        renderer_state.selection_state = {}
        renderer_state.active = false
        if renderer_state.overlay then
            remove_overlay()
        end
        events.emit('msg.debug.text_renderer', { msg = 'Renderer cleared' })
    end,

    ---Handle screen resize with enhanced geometry calculation
    ---@param _ EventName
    ---@param data RendererResizeData|EventData|nil
    ['text_renderer.resize'] = function(_, data)
        if data and data.screen_width and data.screen_height then
            handle_screen_resize(data.screen_width, data.screen_height)

            -- Re-render if active
            if renderer_state.active then
                generate_and_display_ass()
            end
        else
            events.emit('msg.warn.text_renderer', {
                msg = 'Resize event missing screen dimensions'
            })
        end
    end,

    ---Get current geometry information (debugging/integration helper)
    ['text_renderer.get_geometry'] = function(_, _)
        events.emit('text_renderer.geometry_info', {
            geometry = renderer_state.geometry,
            view_window = renderer_state.view_window,
            item_count = #renderer_state.display_items,
            active = renderer_state.active
        })
    end,
}

---Main handler using HomeHub template pattern
---@param event_name EventName
---@param data EventData
local function handler(event_name, data)
    hh_utils.handler_template(event_name, data, handlers, 'text_renderer')
end

---Initialize text renderer with enhanced setup
function text_renderer.init()
    events.emit('msg.debug.text_renderer', { msg = 'Initializing enhanced text renderer...' })

    -- Initialize geometry from current screen size
    local screen_width = mp.get_property_number('osd-width') or 1920
    local screen_height = mp.get_property_number('osd-height') or 1080
    renderer_state.geometry.screen_width = screen_width
    renderer_state.geometry.screen_height = screen_height

    -- Compute initial geometry
    compute_text_geometry()

    -- Initialize styles
    initialize_styles()

    -- Initialize overlay system
    initialize_overlay()

    -- Register event handlers
    for event in pairs(handlers) do
        events.on(event, handler, 'text_renderer')
    end

    -- Listen for cleanup
    events.on('sys.cleanup', text_renderer.cleanup, 'text_renderer')

    -- Set up screen size change monitoring
    mp.observe_property('osd-width', 'number', function(_, width)
        if width then
            handle_screen_resize(width, renderer_state.geometry.screen_height)
        end
    end)

    mp.observe_property('osd-height', 'number', function(_, height)
        if height then
            handle_screen_resize(renderer_state.geometry.screen_width, height)
        end
    end)

    events.emit('msg.info.text_renderer', {
        msg = {
            'Enhanced text renderer initialized',
            'Max items: ' .. renderer_state.geometry.max_items,
            'Screen: ' .. screen_width .. 'x' .. screen_height
        }
    })
end

---Cleanup text renderer with enhanced cleanup
function text_renderer.cleanup()
    -- Remove overlay
    if renderer_state.overlay then
        remove_overlay()
        renderer_state.overlay = nil
    end

    -- Reset state
    renderer_state.active = false
    renderer_state.initialized = false
    renderer_state.display_items = {}
    renderer_state.string_buffer = {}
    renderer_state.geometry.ok = false

    -- Cleanup event listeners
    events.cleanup_component('text_renderer')

    events.emit('msg.info.text_renderer', { msg = 'Enhanced text renderer cleaned up' })
end

return text_renderer
