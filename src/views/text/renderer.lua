--[[
--  Text renderer view with layout zones.
--  Pure presentation component for displaying structured text content in mpv
--
--  Supports both simple lists and zoned layouts (header/body/footer)
--]]

local mp       = require 'mp'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local log = require 'src.core.log'
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

    -- Layout zones
    header = {
        items = {},             -- Header items (non-navigable)
        item_count = 0,         -- Computed height in lines
        style = 'compact',      -- Layout style
    },
    body = {
        items = {},             -- Main content (navigable)
        cursor_position = 1,    -- Cursor position within body
        selection_state = {},   -- Selection state for body items
        empty_text = 'No items available.',
    },
    footer = {
        items = {},             -- Footer items (non-navigable)
        item_count = 0,         -- Computed height in lines
        style = 'compact',      -- Layout style
    },

    -- Dynamic geometry (inspired by `mpv-gallery-view`)
    geometry = {
        screen_width = 1920,
        screen_height = 1080,
        line_height = BASE_FONT_SIZE * 1.2,  -- 20% spacing like gallery-view

        -- Zone heights (in lines)
        header_height = 0,       -- Reserved lines for header
        body_height = 0,         -- Available lines for body
        footer_height = 0,       -- Reserved lines for footer

        -- Margins
        margin_top = 0,          -- Top margin for centering
        margin_bottom = 0,       -- Bottom margin

        -- Virtual resolution
        virtual_height = 720,    -- ASS virtual height

        ok = false,              -- Whether geometry is properly initialized
    },

    -- Viewport calculation (enhanced from file-browser)
    view_window = {
        start = 1,              -- First visible body item index
        finish = 0,             -- Last visible body item index
        overflow = false,       -- Whether body content exceeds viewport
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
        header = '',            -- Header style
        footer = '',            -- Footer style
        selected = '',          -- Selected item highlight
        cursor = '',            -- Cursor icon/marker
        multiselect = '',       -- Multi-selected items
        accent = '',            -- Accent/highlight color
        secondary = '',         -- Secondary text color
        warning = '',           -- Warning/escape character style
    },
}

---Calculate zone heights and update geometry
local function calculate_zone_heights()
    local g = renderer_state.geometry

    -- Calculate header height (1 line per item, with extra spacing for 'spacious')
    local header_lines = 0
    if #renderer_state.header.items > 0 then
        header_lines = #renderer_state.header.items
        if renderer_state.header.style == 'spacious' then
            header_lines = header_lines + 1  -- Add blank line after header
        end
    end

    -- Calculate footer height
    local footer_lines = 0
    if #renderer_state.footer.items > 0 then
        footer_lines = #renderer_state.footer.items
        if renderer_state.footer.style == 'spacious' then
            footer_lines = footer_lines + 1  -- Add blank line before footer
        end
    end

    g.header_height = header_lines
    g.footer_height = footer_lines

    -- Calculate remaining height for body
    local virtual_height = g.virtual_height
    local margin_ratio = options.screen_margin_ratio
    local total_margin = virtual_height * margin_ratio * 2 -- Top + bottom
    local available_height = math.max(g.line_height, virtual_height - total_margin)

    -- Subtract zone heights from available height
    local reserved_height = (header_lines + footer_lines) * g.line_height
    local body_available = math.max(g.line_height, available_height - reserved_height)

    -- Calculate maximum displayable body items
    local max_body_items = math.floor(body_available / g.line_height)
    g.body_height = math.max(1, max_body_items)

    -- Calculate centering margins
    local total_used_height = (header_lines + g.body_height + footer_lines) * g.line_height
    local remaining_height = virtual_height - total_used_height
    g.margin_top = math.max(0, remaining_height / 2)
    g.margin_bottom = remaining_height - g.margin_top
end

---Dynamic geometry calculation with layout zones
---https://github.com/occivink/mpv-gallery-view
---Calculates maximum displayable items based on screen dimensions and zone layouts.
---IMPORTANT: Uses virtual resolution (res_y) for ASS coordinate space calculations.
local function compute_text_geometry()
    local g = renderer_state.geometry

    -- Update line height based on current font size
    g.line_height = options.scaling_factor_body * BASE_FONT_SIZE * 1.2

    -- Use virtual resolution for calculations (since overlay uses res_y = 720)
    -- All ASS rendering happens in this virtual space, NOT actual screen pixels
    g.virtual_height = renderer_state.overlay and renderer_state.overlay.res_y or 720

    -- Calculate zone heights
    calculate_zone_heights()

    g.ok = true

    log.debug('text_renderer', {
        'Computed geometry:',
        'screen=' .. g.screen_width .. 'x' .. g.screen_height,
        'virtual=' .. g.virtual_height,
        'header=' .. g.header_height,
        'body=' .. g.body_height,
        'footer=' .. g.footer_height,
        'line_height=' .. g.line_height,
        'margin_top=' .. g.margin_top,
    })
end

---Enhanced viewport calculation for body zone
---@return number start_index
---@return number end_index
---@return boolean has_overflow
local function calculate_view_window()
    local item_count = #renderer_state.body.items
    local max_displayable = renderer_state.geometry.body_height

    if item_count == 0 then
        return 1, 0, false
    end

    local cursor_pos = renderer_state.body.cursor_position
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

    -- Header style (slightly larger, bold)
    style.header = ([[{\r\q2\b1\fs%d\fn%s\c&H%s&}]]):format(
        math.floor(options.scaling_factor_body * BASE_FONT_SIZE * 1.1),
        options.font_name_body,
        options.font_color_header
    )

    -- Footer style (smaller, secondary color)
    style.footer = ([[{\r\q2\fs%d\fn%s\c&H%s&}]]):format(
        math.floor(options.scaling_factor_body * BASE_FONT_SIZE * 0.9),
        options.font_name_body,
        options.font_color_footer
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

    log.debug('text_renderer', {
         'MPV overlay initialized'
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

---Render cursor for given body item position
---@param position number Position in body items
local function render_cursor(position)
    if position == renderer_state.body.cursor_position then
        if renderer_state.body.selection_state[position] then
            append_to_buffer(renderer_state.style.cursor, options.cursor_selected_icon, '\\h')
        else
            append_to_buffer(renderer_state.style.cursor, options.cursor_icon, '\\h')
        end
    else
        if renderer_state.body.selection_state[position] then
            append_to_buffer(options.selected_icon, '\\h')
        else
            append_to_buffer(options.normal_icon, '\\h')
        end
    end
end

---Render a zone item (header or footer)
---@param item Item
---@param zone_style string ASS style string for the zone
local function render_zone_item(item, zone_style)
    -- Apply zone style
    append_to_buffer(zone_style)

    -- Apply item-specific styling if present
    if item.style_variant then
        if item.style_variant == 'accent' then
            append_to_buffer(renderer_state.style.accent)
        elseif item.style_variant == 'secondary' or item.style_variant == 'muted' then
            append_to_buffer(renderer_state.style.secondary)
        end
    end

    -- Render text with proper ASS escaping
    local display_text = item.primary_text or ''
    local escaped_text = hh_utils.ass_escape(display_text, renderer_state.style.warning .. '…' .. zone_style)
    append_to_buffer(escaped_text)

    -- Add newline
    append_newline()
end

---Render a single body item with enhanced styling support
---@param item Item
---@param position number Position in body items
local function render_body_item(item, position)
    -- Apply base body style
    append_to_buffer(renderer_state.style.body)

    -- Render cursor
    render_cursor(position)

    -- Apply item-specific styling
    local item_style = ''
    local multiselect_count = 0
    for _ in pairs(renderer_state.body.selection_state) do multiselect_count = multiselect_count + 1 end

    if renderer_state.body.selection_state[position] then
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
    local escaped_text = hh_utils.ass_escape(display_text, renderer_state.style.warning .. '…' .. item_style)
    append_to_buffer(escaped_text, '\\h')

    -- Add newline for next item
    append_newline()
end

---Render the header zone
local function render_header()
    if #renderer_state.header.items == 0 then
        return
    end

    for _, item in ipairs(renderer_state.header.items) do
        render_zone_item(item, renderer_state.style.header)
    end

    -- Add spacing for spacious layout
    if renderer_state.header.style == 'spacious' then
        append_newline()
    end
end

---Render the body zone
---@param view_start number
---@param view_end number
local function render_body(view_start, view_end)
    if #renderer_state.body.items == 0 then
        -- Show empty text
        append_to_buffer(renderer_state.style.body, hh_utils.ass_escape(renderer_state.body.empty_text))
        append_newline()
        return
    end

    -- Render visible body items
    for i = view_start, view_end do
        local item = renderer_state.body.items[i]
        render_body_item(item, i)
    end
end

---Render the footer zone
local function render_footer()
    if #renderer_state.footer.items == 0 then
        return
    end

    -- Add spacing for spacious layout
    if renderer_state.footer.style == 'spacious' then
        append_newline()
    end

    for _, item in ipairs(renderer_state.footer.items) do
        render_zone_item(item, renderer_state.style.footer)
    end
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

    -- Render header zone
    render_header()

    -- Calculate viewport for body
    local view_start, view_end, has_overflow = calculate_view_window()

    -- Render body zone
    render_body(view_start, view_end)

    -- Render footer zone
    render_footer()

    -- Flush buffer and draw
    flush_buffer()
    draw_overlay()

    -- Emit completion status with enhanced information
    events.emit('text_renderer.updated', {
        visible_items = view_end - view_start + 1,
        cursor_pos = renderer_state.body.cursor_position,
        view_start = view_start,
        view_end = view_end,
        has_overflow = has_overflow,
        geometry = {
            body_height = renderer_state.geometry.body_height,
            header_height = renderer_state.geometry.header_height,
            footer_height = renderer_state.geometry.footer_height,
            line_height = renderer_state.geometry.line_height,
            virtual_height = renderer_state.geometry.virtual_height,
        }
    })

    -- Reset update flag
    renderer_state.needs_update = false

    log.debug('text_renderer', {
        'Rendered:',
        'header=' .. #renderer_state.header.items,
        'body=' .. (view_end - view_start + 1) .. '/' .. #renderer_state.body.items,
        'footer=' .. #renderer_state.footer.items
    })
end

---Handle screen resize with dynamic geometry recalculation
---@param width number
---@param height number
local function handle_screen_resize(width, height)
    local old_body_height = renderer_state.geometry.body_height

    -- Update screen dimensions
    renderer_state.geometry.screen_width = width
    renderer_state.geometry.screen_height = height

    -- Recalculate geometry
    compute_text_geometry()

    -- Check if viewport capacity changed
    if old_body_height ~= renderer_state.geometry.body_height then
        renderer_state.needs_update = true

        log.info('text_renderer', {
            'Geometry changed:',
            old_body_height .. ' -> ' .. renderer_state.geometry.body_height .. ' body items'
        })

        -- Emit viewport changed event
        events.emit('text_renderer.viewport_changed', {
            max_visible_items = renderer_state.geometry.body_height,
            header_height = renderer_state.geometry.header_height,
            footer_height = renderer_state.geometry.footer_height,
            line_height = renderer_state.geometry.line_height,
            old_max_items = old_body_height
        })
    end
end

---Event handlers following HomeHub pattern with enhanced functionality
---@type HandlerTable
local handlers = {

    ---Main render request handler with zone support and backward compatibility
    ---@param _ EventName
    ---@param data TextRendererRenderData|EventData|nil
    ['text_renderer.render'] = function(_, data)
        if not data then
            log.warn('text_renderer', {
                'Received render request with no data'
            })
            return
        end

        local needs_geometry_update = false

        -- Handle zoned layout mode (new API)
        if data.header or data.body or data.footer then
            -- Update header zone
            if data.header then
                if type(data.header.items) ~= 'table' then
                    log.error('text_renderer', {
                         'Header items must be a table/array'
                    })
                    return
                end
                renderer_state.header.items = data.header.items
                renderer_state.header.style = data.header.style or 'compact'
                needs_geometry_update = true
            end

            -- Update body zone
            if data.body then
                if type(data.body.items) ~= 'table' then
                    log.error('text_renderer', {
                         'Body items must be a table/array'
                    })
                    return
                end
                renderer_state.body.items = data.body.items
                needs_geometry_update = true
            end

            -- Update footer zone
            if data.footer then
                if type(data.footer.items) ~= 'table' then
                    log.error('text_renderer', {
                        'Footer items must be a table/array'
                    })
                    return
                end
                renderer_state.footer.items = data.footer.items
                renderer_state.footer.style = data.footer.style or 'compact'
                needs_geometry_update = true
            end

        -- Handle simple mode (backward compatible)
        elseif data.items then
            if type(data.items) ~= 'table' then
                log.error('text_renderer', {
                    'Items must be a table/array'
                })
                return
            end
            -- Map simple mode to body zone
            renderer_state.body.items = data.items
            renderer_state.header.items = {}
            renderer_state.footer.items = {}
            needs_geometry_update = true
        end

        -- Update cursor position if provided with validation
        if data.cursor_pos and type(data.cursor_pos) == 'number' then
            local new_pos = math.max(1, math.min(data.cursor_pos, math.max(1, #renderer_state.body.items)))
            if new_pos ~= renderer_state.body.cursor_position then
                renderer_state.body.cursor_position = new_pos
                renderer_state.needs_update = true
            end
        end

        -- Update selection state if provided
        if data.selection then
            if type(data.selection) == 'table' then
                renderer_state.body.selection_state = data.selection
                renderer_state.needs_update = true
            else
                log.warn('text_renderer', {
                    'Selection state must be a table'
                })
            end
        end

        -- Recalculate geometry if zones changed
        if needs_geometry_update then
            compute_text_geometry()
            renderer_state.needs_update = true
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
        log.debug('text_renderer', {
            'Renderer activated'
        })
    end,

    ---Hide overlay but preserve state
    ['text_renderer.hide'] = function(_, _)
        renderer_state.active = false
        if renderer_state.overlay then
            remove_overlay()
        end
        log.debug('text_renderer', {
            'Renderer hidden'
        })
    end,

    ---Clear content and hide
    ['text_renderer.clear'] = function(_, _)
        renderer_state.header.items = {}
        renderer_state.body.items = {}
        renderer_state.footer.items = {}
        renderer_state.body.cursor_position = 1
        renderer_state.body.selection_state = {}
        renderer_state.active = false
        if renderer_state.overlay then
            remove_overlay()
        end
        log.debug('text_renderer', {
            'Renderer cleared'
        })
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
            log.warn('text_renderer', {
                'Resize event missing screen dimensions'
            })
        end
    end,

    ---Get current geometry information (debugging/integration helper)
    ['text_renderer.get_geometry'] = function(_, _)
        events.emit('text_renderer.geometry_info', {
            geometry = renderer_state.geometry,
            view_window = renderer_state.view_window,
            body_item_count = #renderer_state.body.items,
            header_item_count = #renderer_state.header.items,
            footer_item_count = #renderer_state.footer.items,
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
    log.debug('text_renderer', {
        'Initializing enhanced text renderer with layout zones...'
    })

    -- Initialize geometry from current screen size
    local screen_width = mp.get_property_number('osd-width') or 1920
    local screen_height = mp.get_property_number('osd-height') or 1080
    renderer_state.geometry.screen_width = screen_width
    renderer_state.geometry.screen_height = screen_height

    -- Initialize overlay system FIRST (needed for virtual resolution in geometry calculations)
    initialize_overlay()

    -- Compute initial geometry (now that overlay exists)
    compute_text_geometry()

    -- Initialize styles
    initialize_styles()

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

    log.info('text_renderer', {
        'Enhanced text renderer with zones initialized',
        'Body capacity: ' .. renderer_state.geometry.body_height .. ' items',
        'Screen: ' .. screen_width .. 'x' .. screen_height
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
    renderer_state.header.items = {}
    renderer_state.body.items = {}
    renderer_state.footer.items = {}
    renderer_state.string_buffer = {}
    renderer_state.geometry.ok = false

    -- Cleanup event listeners
    events.cleanup_component('text_renderer')

    log.info('text_renderer', {
        'Enhanced text renderer cleaned up'
    })
end

return text_renderer
