--[[
--  Text renderer view with layout zones.
--  Pure presentation component for displaying structured text content in mpv
--
--  Supports both simple lists and zoned layouts (header/body/footer)
--]]

local mp = require 'mp'

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
    detail = {
        height = 0,             -- Dynamic height based on cursor item's hint
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
        detail_height = 0,       -- Reserved lines for detail (cursor item's hint)
        footer_height = 0,       -- Reserved lines for footer

        -- Character limits per zone (calculated from OSD width)
        char_limits = {
            header = 100,
            body = 100,
            hint = 100,
            footer = 100,
        },

        -- Margins
        margin_top = 0,          -- Top margin for centering
        margin_bottom = 0,       -- Bottom margin

        -- Virtual resolution
        virtual_height = 720,    -- ASS virtual height
        virtual_width = 1280,    -- ASS virtual width (calculated from aspect ratio)

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
        hint = '',              -- Hint/detail style (smaller font)
        selected = '',          -- Selected item highlight
        cursor = '',            -- Cursor icon/marker
        multiselect = '',       -- Multi-selected items
        accent = '',            -- Accent/highlight color
        secondary = '',         -- Secondary text color
        warning = '',           -- Warning/escape character style
    },
}

---Truncate text to fit character limit with ellipsis
---@param text string
---@param limit number
---@return string
local function truncate_text(text, limit)
    if not text then return '' end
    if #text <= limit then return text end

    -- Truncate and add ellipsis
    return text:sub(1, math.max(1, limit - 1)) .. '…'
end

---Get text and style from a Line (string or StyledString)
---@param line Line
---@return string text
---@return StyleVariant? style
local function get_text_and_style(line)
    if type(line) == 'string' then
        return line, nil
    elseif type(line) == 'table' and line.text then
        return line.text, line.style
    end
    return '', nil
end

---Get ASS style string for a style variant
---@param variant StyleVariant
---@return string
local function get_style_for_variant(variant)
    if variant == 'accent' then
        return renderer_state.style.accent
    elseif variant == 'secondary' or variant == 'muted' then
        return renderer_state.style.secondary
    elseif variant == 'header' then
        return renderer_state.style.header
    end
    return ''
end

---Concatenate lines with separator, handling StyledString
---@param lines Line[]
---@param separator string
---@return string concatenated_text
local function concatenate_lines(lines, separator)
    local parts = {}
    for _, line in ipairs(lines) do
        local text, _ = get_text_and_style(line)
        if text and #text > 0 then
            table.insert(parts, text)
        end
    end
    return table.concat(parts, separator)
end

---Calculate zone heights and update geometry
local function calculate_zone_heights()
    local g = renderer_state.geometry

    -- Calculate header height (accounting for multi-line items)
    local header_lines = 0
    if #renderer_state.header.items > 0 then
        for _, item in ipairs(renderer_state.header.items) do
            if item.lines then
                header_lines = #item.lines
            else
                header_lines = header_lines + 1
            end
        end
        if renderer_state.header.style == 'spacious' then
            header_lines = header_lines + 1  -- Add blank line after header
        end
        -- Add separator line
        header_lines = header_lines + 1
    end

    -- Calculate footer height (accounting for multi-line items)
    local footer_lines = 0
    if #renderer_state.footer.items > 0 then
        for _, item in ipairs(renderer_state.footer.items) do
            if item.lines then
                footer_lines = #item.lines
            else
                footer_lines = footer_lines + 1
            end
        end
        if renderer_state.footer.style == 'spacious' then
            footer_lines = footer_lines + 1  -- Add blank line before footer
        end
    end

    -- Calculate detail height (cursor-dependent, single line + separator)
    local detail_lines = 0
    local cursor_item = renderer_state.body.items[renderer_state.body.cursor_position]
    if cursor_item and cursor_item.hint then
        detail_lines = 2  -- separator + hint line
    end

    g.header_height = header_lines
    g.detail_height = detail_lines
    g.footer_height = footer_lines

    -- Calculate remaining height for body
    local virtual_height = g.virtual_height
    local margin_ratio = options.screen_margin_ratio
    local total_margin = virtual_height * margin_ratio * 2 -- Top + bottom
    local available_height = math.max(g.line_height, virtual_height - total_margin)

    -- Subtract zone heights from available height
    local reserved_height = (header_lines + detail_lines + footer_lines) * g.line_height
    local body_available = math.max(g.line_height, available_height - reserved_height)

    -- Calculate maximum displayable body items (body always shows 1 line per item)
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

    -- Calculate virtual width from aspect ratio
    -- This ensures we work entirely in virtual coordinate space
    local aspect_ratio = g.screen_width / g.screen_height
    local virtual_width = g.virtual_height * aspect_ratio
    g.virtual_width = virtual_width  -- Store for future use

    -- Calculate character limits using VIRTUAL width (not actual screen pixels)
    -- Using console.lua's formula: multiplier * width / font_size
    -- Important: Both width and font_size must be in the same coordinate system (virtual units)

    -- Define scaling factors for each zone (must match initialize_styles())
    local HEADER_SCALE = 1.1   -- 10% larger font
    local BODY_SCALE = 1.0     -- Base font size
    local FOOTER_SCALE = 0.9   -- 10% smaller font
    local hint_font_scale = options.font_size_hint or 0.75  -- 25% smaller by default

    -- Calculate base font size for body
    local body_font_size = options.scaling_factor_body * BASE_FONT_SIZE

    -- Calculate character limits for each zone based on their actual font sizes
    -- Larger fonts = fewer characters, smaller fonts = more characters
    local header_font_size = body_font_size * HEADER_SCALE
    local footer_font_size = body_font_size * FOOTER_SCALE
    local hint_font_size = body_font_size * hint_font_scale

    -- Use configurable character width multiplier
    -- Default is 5 (from console.lua), but users can adjust (e.g., 3-4 for narrow/wide fonts)
    local char_multiplier = options.char_width_multiplier or 5

    -- Base calculation: multiplier * virtual_width / font_size * 0.9 safety factor
    local safety_factor = 0.9

    local base_char_limit = math.floor(char_multiplier * virtual_width / body_font_size * safety_factor)
    local header_char_limit = math.floor(char_multiplier * virtual_width / header_font_size * safety_factor)
    local footer_char_limit = math.floor(char_multiplier * virtual_width / footer_font_size * safety_factor)
    local hint_char_limit = math.floor(char_multiplier * virtual_width / hint_font_size * safety_factor)

    -- Account for margins (same ratio for all zones)
    local margin_chars_body = math.floor(base_char_limit * options.screen_margin_ratio * 2)
    local margin_chars_header = math.floor(header_char_limit * options.screen_margin_ratio * 2)
    local margin_chars_footer = math.floor(footer_char_limit * options.screen_margin_ratio * 2)
    local margin_chars_hint = math.floor(hint_char_limit * options.screen_margin_ratio * 2)

    -- Body needs additional space for cursor icon (approximately 2 characters)
    local icon_width = 2
    g.char_limits.body = math.max(20, base_char_limit - icon_width - margin_chars_body)
    g.char_limits.header = math.max(30, header_char_limit - margin_chars_header)
    g.char_limits.footer = math.max(30, footer_char_limit - margin_chars_footer)
    g.char_limits.hint = math.max(30, hint_char_limit - margin_chars_hint)

    -- Calculate zone heights
    calculate_zone_heights()

    g.ok = true

    log.debug('text_renderer', {
        'Computed geometry:',
        'screen=' .. g.screen_width .. 'x' .. g.screen_height,
        'virtual=' .. g.virtual_width .. 'x' .. g.virtual_height,
        'aspect=' .. string.format('%.3f', aspect_ratio),
        'header=' .. g.header_height,
        'body=' .. g.body_height,
        'detail=' .. g.detail_height,
        'footer=' .. g.footer_height,
        'line_height=' .. g.line_height,
        'char_limits: header=' .. g.char_limits.header .. ', body=' .. g.char_limits.body .. ', footer=' .. g.char_limits.footer .. ', hint=' .. g.char_limits.hint,
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

    -- Hint/detail style (smaller font for information density)
    local hint_font_scale = options.font_size_hint or 0.75
    style.hint = ([[{\r\q2\fs%d\fn%s\c&H%s&}]]):format(
        math.floor(options.scaling_factor_body * BASE_FONT_SIZE * hint_font_scale),
        options.font_name_body,
        options.font_color_hint or options.font_color_secondary
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

---Render a zone item (header or footer) with multi-line support
---@param item Item
---@param zone_style string ASS style string for the zone
---@param char_limit number Character limit for this zone
local function render_zone_item(item, zone_style, char_limit)
    -- Render prefix icon on first line only
    local prefix = item.prefix_icon and (item.prefix_icon .. '\\h') or ''
    local prefix_width = item.prefix_icon and 2 or 0  -- Approximate icon width in characters

    -- Render each line
    for i, line in ipairs(item.lines) do
        append_to_buffer(zone_style)

        -- Add prefix to first line
        if i == 1 then
            append_to_buffer(prefix)
        else
            -- Indent continuation lines
            append_to_buffer('  ')
        end

        -- Get text and line-specific style
        local text, line_style = get_text_and_style(line)

        -- Apply item-level style variant (overrides line style)
        if item.style_variant then
            append_to_buffer(get_style_for_variant(item.style_variant))
        elseif line_style then
            -- Apply line-specific style if no item-level override
            append_to_buffer(get_style_for_variant(line_style))
        end

        -- Truncate text to fit character limit (accounting for prefix/indent)
        local effective_limit = char_limit - (i == 1 and prefix_width or 2)
        local truncated = truncate_text(text, effective_limit)
        local escaped = hh_utils.ass_escape(truncated, renderer_state.style.warning .. '…' .. zone_style)
        append_to_buffer(escaped)

        append_newline()
    end
end

---Render a single body item with line concatenation support
---@param item Item
---@param position number Position in body items
local function render_body_item(item, position)
    -- Apply base body style
    append_to_buffer(renderer_state.style.body)

    -- Render cursor
    render_cursor(position)

    -- Apply selection styling
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

    -- Apply item-level style variant
    if item.style_variant then
        append_to_buffer(get_style_for_variant(item.style_variant))
    end

    -- Render prefix icon
    if item.prefix_icon then
        append_to_buffer(item.prefix_icon, '\\h')
    end

    -- Handle legacy items with primary_text
    local display_text

    -- Concatenate lines with separator
    local separator = item.concat_separator or ' - '
    display_text = concatenate_lines(item.lines, separator)

    -- Truncate to fit character limit
    local char_limit = renderer_state.geometry.char_limits.body
    display_text = truncate_text(display_text, char_limit)

    -- Escape and render
    local escaped_text = hh_utils.ass_escape(display_text, renderer_state.style.warning .. '…' .. item_style)
    append_to_buffer(escaped_text, '\\h')

    -- Add newline for next item
    append_newline()
end

---Render the header zone with auto-separator
local function render_header()
    if #renderer_state.header.items == 0 then
        return
    end

    for _, item in ipairs(renderer_state.header.items) do
        render_zone_item(item, renderer_state.style.header, renderer_state.geometry.char_limits.header)
    end

    -- Add spacing for spacious layout
    if renderer_state.header.style == 'spacious' then
        append_newline()
    end

    -- Auto-separator if body exists
    if #renderer_state.body.items > 0 then
        append_to_buffer(renderer_state.style.secondary, hh_utils.separator)
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

---Render the detail zone (hint from cursor item)
local function render_detail()
    local cursor_item = renderer_state.body.items[renderer_state.body.cursor_position]
    if not cursor_item or not cursor_item.hint then
        return
    end

    -- Auto-separator before detail
    append_to_buffer(renderer_state.style.secondary, hh_utils.separator)
    append_newline()

    -- Render hint with smaller font (single line, truncated)
    append_to_buffer(renderer_state.style.hint)
    local truncated = truncate_text(cursor_item.hint, renderer_state.geometry.char_limits.hint)
    local escaped = hh_utils.ass_escape(truncated, renderer_state.style.warning .. '…' .. renderer_state.style.hint)
    append_to_buffer(escaped)
    append_newline()
end

---Render the footer zone with conditional auto-separator
local function render_footer()
    if #renderer_state.footer.items == 0 then
        return
    end

    -- Add spacing for spacious layout
    if renderer_state.footer.style ~= 'compact' then
        append_newline()
    end

    -- Auto-separator if no detail was rendered (detail adds its own separator)
    local cursor_item = renderer_state.body.items[renderer_state.body.cursor_position]
    if not cursor_item or not cursor_item.hint then
        append_to_buffer(renderer_state.style.secondary, hh_utils.separator)
        append_newline()
    end

    for _, item in ipairs(renderer_state.footer.items) do
        render_zone_item(item, renderer_state.style.footer, renderer_state.geometry.char_limits.footer)
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

    -- Render detail zone (hint from cursor item)
    render_detail()

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
            detail_height = renderer_state.geometry.detail_height,
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
        'detail=' .. renderer_state.geometry.detail_height,
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
