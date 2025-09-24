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
    }
}

function options.init()
    -- read user configuration
    opt.read_options(options, 'homehub')
end

return options
