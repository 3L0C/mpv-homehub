--[[
    Options management
--]]

local opt = require 'mp.options'

---@class options
local o = {
    -- directory to load external modules - currently only user-input-module
    module_directory = '~~/script-modules',

    -- default ui view
    ---@type 'text'|'gallery'
    ui_default_view = 'text',
}

function o.init()
    opt.read_options(o, 'homehub')
end

return o
