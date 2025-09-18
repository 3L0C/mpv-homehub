--[[
--  Options management
--]]

local opt = require 'mp.options'

---@class options
local options = {
    -- directory to load external modules - currently only user-input-module
    module_directory = '~~/script-modules',

    -- default ui view
    ---@type 'text'|'gallery'
    ui_default_view = 'text',
}

function options.init()
    -- read user configuration
    opt.read_options(options, 'homehub')
end

return options
