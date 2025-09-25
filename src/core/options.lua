--[[
--  Options management
--]]

local opt = require 'mp.options'

---@class DefaultKeyTable
---@field up string[]
---@field down string[]
---@field left string[]
---@field right string[]
---@field search string[]
---@field help string[]
---@field back string[]
---@field select string[]
---@field multiselect string[]
---@field page_up string[]
---@field page_down string[]

---@class options
local options = {
    -- directory to load external modules - currently only user-input-module
    module_directory = '~~/script-modules',

    -- default ui mode
    ---@type UiMode
    ui_default_mode = 'text',
    ---@type boolean
    ui_autostart = false,

    -- default ui text mode keys
    -- TODO refactor this into individual key value pairs so mpv can use `read_options`.
    -- value would be a comma separated list of keys. Need util function to split/convert.
    ---@type DefaultKeyTable
    ui_text_keys = {
        up = {
            'UP',
        },
        down = {
            'DOWN',
        },
        -- no concept of 'left'|'right' in a single column list, use back|select instead...
        left = {
            '',
        },
        right = {
            '',
        },
        search = {
            '/',
        },
        help = {
            '?',
        },
        back = {
            'LEFT',
        },
        select = {
            'RIGHT',
            'ENTER',
        },
        multiselect = {
            'CTRL+ENTER',
            'SPACE',
        },
        page_up = {
            'PGUP',
            'CTRL+UP'
        },
        page_down = {
            'PGDWN',
            'CTRL+DOWN'
        },
    },

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
}

function options.init()
    -- read user configuration
    opt.read_options(options, 'homehub')
end

return options
