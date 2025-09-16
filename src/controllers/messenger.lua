--[[
    Message interface for the system
--]]

local events = require 'src.core.events'
local logger = require 'src.core.logger'

---@class messenger
local messenger = {}

function messenger.init()
    events.on('msg.*', logger.log, 'messenger')
end

return messenger
