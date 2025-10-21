--[[
--  Options management
--]]

local opt = require 'mp.options'

---@class options
local options = {
    -- directory to load external modules - currently only user-input-module
    module_directory = '~~/script-modules',

    -- default ui mode
    ---@type UiMode
    ui_default_mode = 'text',
    ---@type boolean
    ui_autostart = false,

    -- UI keybinds
    ui_keybinds_file = '~~/script-opts/homehub-keybinds.json',

    -- ASS configuration

    -- Font settings
    font_name_body = 'mpv-osd-symbols',
    font_color_body = 'ffffff',
    font_color_cursor = '00ccff',
    font_color_selected = '00ff00',
    font_color_multiselect = 'fcad88',
    font_color_accent = '00ff00',
    font_color_secondary = 'aaaaaa',
    font_color_warning = '413eff',

    -- Cursor and selection markers
    cursor_icon = '▶',
    selection_icon = '◉',

    -- Alignment
    align_x = 'left',
    align_y = 'top',

    -- Layout
    scaling_factor_body = 1,
    screen_margin_ratio = 0.05,  -- 5% margins on top/bottom like gallery-view's 90%

    -- Adapter configuration
    adapter_config_file = '~~/script-opts/homehub-adapters.json',
}

function options.init()
    -- read user configuration
    opt.read_options(options, 'homehub')
end

return options
