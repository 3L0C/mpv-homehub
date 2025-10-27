--[[
--  Options management
--]]

local opt = require 'mp.options'

local hh_utils = require 'src.core.utils'
local log = require 'src.core.log'

---@class options
local options = {
    -- directory to load external modules - currently only user-input-module
    module_directory = '~~/script-modules',

    -- default ui mode
    ---@type UiMode
    ui_default_mode = 'text',
    ---@type boolean
    ui_autostart = false,

    -- Keybinds file path
    keybinds_file = '~~/script-opts/homehub-keybinds.json',
    ---@type KeybindConfig
    keybinds = nil,

    -- ASS configuration

    -- Font settings
    font_name_body = 'mpv-osd-symbols',
    font_color_header = 'cccccc',
    font_color_body = 'ffffff',
    font_color_footer = '888888',
    font_color_cursor = '00ccff',
    font_color_selected = '00ff00',
    font_color_multiselect = 'fcad88',
    font_color_accent = '00ff00',
    font_color_secondary = 'aaaaaa',
    font_color_warning = '413eff',

    -- Cursor and selection markers
    normal_icon = '○',
    selected_icon = '◉',
    cursor_icon = '▶',
    cursor_selected_icon = '➤',

    -- Alignment
    align_x = 'left',
    align_y = 'top',

    -- Layout
    scaling_factor_body = 1,
    screen_margin_ratio = 0.05,  -- 5% margins on top/bottom like gallery-view's 90%

    -- Adapter configuration
    adapter_config_file = '~~/script-opts/homehub-adapters.json',

    -- Search configuration
    search_case_sensitive = false,
    search_show_match_count = true,
    search_fields = 'primary_text,secondary_text',
}

function options.init()
    -- read user configuration
    opt.read_options(options, 'homehub')

    local keybind_table, err = hh_utils.read_json_file(options.keybinds_file)
    if not keybind_table then
        log.warn('options', {
            'Unable to load keybind configuration, using defaults:', err
        })
    end

    options.keybinds = keybind_table or {}

    -- Parse search configuration
    options.search = {
        case_sensitive = options.search_case_sensitive,
        show_match_count = options.search_show_match_count,
        search_fields = {},
        keybinds = keybind_table and keybind_table.search or {},
    }

    -- Parse search_fields from comma-separated string to table
    for field in options.search_fields:gmatch('[^,]+') do
        table.insert(options.search.search_fields, field:match('^%s*(.-)%s*$')) -- trim whitespace
    end

    -- Defaults if empty
    if #options.search.search_fields == 0 then
        options.search.search_fields = {'primary_text', 'secondary_text'}
    end
end

return options
