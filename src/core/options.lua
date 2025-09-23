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
}

function options.init()
    -- read user configuration
    opt.read_options(options, 'homehub')
end

return options
