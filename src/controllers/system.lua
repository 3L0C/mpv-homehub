--[[
--  System controller
--]]

local mp = require 'mp'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'

---@class system: Controller
local system = {
    --sets the version for the HomeHub API
    API_VERSION = '1.0.0',

    ---@type 'windows'|'darwin'|'linux'|'android'|'freebsd'|'other'|string|nil
    PLATFORM = mp.get_property_native('platform') or 'other',
}

---@type table<EventName,ListenerCB>
local handlers = {
    ['sys.ready'] = function(_, _)
        events.emit('msg.debug.system', {
            msg = 'Ready!'
        })
    end,
}

---Main handler for the system.
---@param event_name EventName
---@param data EventData
local function handler(event_name, data)
    hh_utils.handler_template(event_name, data, handlers, 'system')
end

function system.init()
    --minimum mpv version checks
    assert(mp.create_osd_overlay, 'HomeHub requires minimum mpv version v0.33')
    events.on('sys.*', handler, 'system')
    events.on('sys.cleanup', system.cleanup, 'system')
    events.emit('sys.ready')
end

function system.cleanup()
    events.cleanup_component('system')
end

return system
