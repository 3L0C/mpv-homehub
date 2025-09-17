--[[
--  Message interface for the system
--]]

local events = require 'src.core.events'
local logger = require 'src.core.logger'

---@class messenger: Controller
local messenger = {}

function messenger.init()
    events.on('msg.*', logger.log, 'messenger')
end

function messenger.cleanup()
    -- no-op
end

return messenger
