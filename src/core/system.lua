--[[
    System manager
--]]

local mp = require 'mp'
local utils = require 'mp.utils'
local events = require 'src.core.events'

---@class system
local system = {
    --sets the version for the HomeHub API
    API_VERSION = '1.0.0',

    ---@type 'windows'|'darwin'|'linux'|'android'|'freebsd'|'other'|string|nil
    PLATFORM = mp.get_property_native('platform') or 'other',
}

---@alias handlers table<string,ListenerCB>
local handlers = {
    ['system.ready'] = function(_, _)
        events.emit('msg.debug.system', {
            msg = 'Ready!'
        })
    end
}

---Main handler for the system.
---@param event_name string
---@param data Data
local function handler(event_name, data)
    local handle = handlers[event_name]
    if type(handle) ~= 'function' then
        events.emit('msg.warn.system',{
            msg = { 'Got unhandled event:', event_name },
        })
    else
        local success, err = pcall(handle, event_name, data)
        if not success then events.emit('msg.warn.system', {err}) end
        events.emit('msg.debug.system', {
            msg = ("Handled event '%s' with data '%s'."):format(event_name, utils.to_string(data))
        })
    end
end

function system.init()
    --minimum mpv version checks
    assert(mp.create_osd_overlay, 'HomeHub requires minimum mpv version v0.33')
    events.on('system.*', handler, 'system')
    events.emit('system.ready')
end

return system
