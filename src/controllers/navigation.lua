--[[
--  Navigation controller
--]]

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'

---@class navigation: Controller
local navigation = {}

---@class NavigationState
---@field position number Current position in the list.
---@field total_items number Total items in the list.
---@field columns number Columns in the list.
---@field rows number Rows in the list.
---
---@alias NavigationID string
---@alias NavigationCtxID string
---@alias NavigationTable table<NavigationID,NavigationState>
---@alias NavigationCtx table<NavigationCtxID,NavigationID[]>
---@alias NavigationStack NavigationCtxID[]

---@type NavigationTable
local nav_table = {}
---@type NavigationCtx
local nav_ctx = {}
---@type NavigationStack
local nav_stack = {}

---@type HandlerTable
local handlers = {
    ['nav.up'] = function(_, _)
    end,
}

---Main navigation event handler.
---@param event_name EventName
---@param data EventData
local function handler(event_name, data)
    hh_utils.handler_template(event_name, data, handlers, 'navigation')
end

function navigation.init()
    events.on('nav.*', handler, 'navigation')
    events.on('sys.cleanup', navigation.cleanup, 'navigation')
end

function navigation.cleanup()
    events.cleanup_component('navigation')
end

return navigation
