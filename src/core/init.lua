--[[
    Initialization and module loading
--]]

-- System initialization and module loading
local options = require 'src.core.options'
local system = require 'src.core.system'
local events = require 'src.core.events'

-- Load MVC components
---@class controllers
local controllers = {
    auth = require 'src.controllers.auth',
    input = require 'src.controllers.input',
    media = require 'src.controllers.media',
    messenger = require 'src.controllers.messenger',
    navigation = require 'src.controllers.navigation',
    search = require 'src.controllers.search',
    view = require 'src.controllers.view',
}

---@class views
local views = {
    gallery = require 'src.views.gallery.grid',
    text = require 'src.views.text.browser',
}

-- Load adapters
local adapter_manager = require 'src.models.base.adapter'

return {
    start = function()
        -- Initialize system
        options.init()
        events.init()

        -- Initialize controllers
        for _, controller in pairs(controllers) do
            controller.init()
        end

        -- Load configured adapters
        adapter_manager.load_adapters()

        -- Setup views
        for _, view in pairs(views) do
            view.init()
        end

        -- Ready!
        system.init()
    end
}
