--[[
--  Initialization and module loading
--]]

-- System initialization and module loading
local options = require 'src.core.options'
local events = require 'src.core.events'
local system = require 'src.core.system'

-- Load MVC components
---@type table<string,Controller>
local controllers = {
    content = require 'src.controllers.content',
    input = require 'src.controllers.input',
    navigation = require 'src.controllers.navigation',
    text = require 'src.controllers.ui.text',
    ui = require 'src.controllers.ui.ui',
}

---@type table<string,View>
local views = {
    text_renderer = require 'src.views.text.renderer',
}

local adapter_manager = require 'src.models.base.adapter'

return {
    start = function()
        -- Initialize core
        options.init()
        events.init()

        -- Initialize controllers
        for _, controller in pairs(controllers) do
            controller.init()
        end

        -- Initialize views
        for _, view in pairs(views) do
            view.init()
        end

        -- Load configured adapters
        adapter_manager.load_adapters()

        -- Start HomeHub
        system.init()
    end
}
