--[[
--  Jellyfin adapter
--]]

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'

local adapter_manager = require 'src.models.base.adapter'

local API_VERSION = adapter_manager.get_api_version()

---@class Adapter
local adapter = {
    api_version = API_VERSION,
}

---Adapter state
local state = {
    ---@type AdapterConfig
    config = nil,
    ---@type AdapterID
    adapter_id = 'jellyfin',
    -- Jellyfin specific state
}

---@type AdapterAPI
local api = {
    adapter_id = state.adapter_id,
    adapter_name = 'Jellyfin',
    adapter_type = 'jellyfin',

    ---@type AdapterEventMap
    events = {
        request = 'jellyfin.request',
        back = 'jellyfin.back',
        navigate_to = 'jellyfin.navigate_to',
        search = 'jellyfin.search',
        action = nil,
        status = nil,
        error = nil,
    },

    ---@type AdapterCapabilities
    capabilities = {
        supports_search = true,
        supports_thumbnails = true,
        media_types = {
            'video',
            'audio',
            'other',
        }
    }
}

---Event handler table
---@type HandlerTable
local handlers = {
    ['jellyfin.back'] = function(event_name, data)
        
    end
}
