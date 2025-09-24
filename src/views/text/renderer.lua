--[[
--  Text renderer view.
--]]

---@class text_renderer: View
local text_renderer = {}

local renderer_state = {
    -- Lifecycle
    active = false,
    initialized = false,

    -- Content state
    display_items = {},
    empty_text = 'No items available.',

    -- Navigation state
    cursor_position = 1,
    selection_state = {},

    -- Viewport calculation
    view_window = {
        start = 1,
        finish = 0,
        overflow = false,
        max_items = 0,
    },

    -- ASS rendering
    overlay = nil,
    needs_update = false,
    string_buffer = {},

    -- Styling
    style = {
        global = '',            -- Global alignment/base style
        header = '',            -- Header formatting
        body = '',              -- Normal item text
        selected = '',          -- Selected item highlight
        cursor = '',            -- Cursor icon/marker
        multiselect = '',       -- Multi-selected items
        wrappers = '',          -- Top/bottom overflow indicators
        accent = '',            -- Accent/highlight color
        secondary = '',         -- Secondary text color
    },
}

function text_renderer.init()
end

function text_renderer.cleanup()
end

return text_renderer
