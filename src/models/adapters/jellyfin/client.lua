--[[
--  Jellyfin API client
--  Provides Jellyfin-specific API wrapper using generic HTTP client
--]]

local http = require 'src.core.http'

---@class JellyfinClient
---@field base_url string
---@field user_id string?
---@field access_token string?
---@field device_id string
---@field client_name string
---@field client_version string
local JellyfinClient = {}
JellyfinClient.__index = JellyfinClient

---Create a new Jellyfin client
---@param base_url string Base URL of Jellyfin server (e.g., "https://jellyfin.example.com")
---@return JellyfinClient
function JellyfinClient.new(base_url)
    local self = setmetatable({}, JellyfinClient)

    self.base_url = base_url
    self.user_id = nil
    self.access_token = nil

    -- Device info for authentication
    self.device_id = 'mpv-homehub-1'
    self.client_name = 'mpv-homehub'
    self.client_version = '0.1.0'

    return self
end

---Build authorization header value
---@return string
function JellyfinClient:get_auth_header()
    if self.access_token then
        return 'MediaBrowser Token="' .. self.access_token .. '"'
    else
        return string.format(
            'MediaBrowser Client="%s", Device="%s", DeviceId="%s", Version="%s"',
            self.client_name,
            self.client_name,
            self.device_id,
            self.client_version
        )
    end
end

---Make a Jellyfin API request
---@param method string HTTP method
---@param path string API path (e.g., "/Users/Me")
---@param data? table Data to send as JSON body
---@return table? response Parsed JSON response, or nil on error
---@return string? error Error message if request failed
function JellyfinClient:request(method, path, data)
    local url = self.base_url .. path

    local options = {
        headers = {
            Authorization = self:get_auth_header(),
        },
    }

    return http.request_json(method, url, data, options)
end

---Authenticate with username and password
---@param username string
---@param password string
---@return boolean success
---@return string? error Error message if authentication failed
function JellyfinClient:authenticate(username, password)
    local data = {
        Username = username,
        Pw = password,
    }

    local response, err = self:request('POST', '/Users/AuthenticateByName', data)

    if not response or err then
        return false, 'Authentication request failed: ' .. err
    end

    if not response.User or not response.AccessToken then
        return false, 'Invalid response from server'
    end

    self.user_id = response.User.Id
    self.access_token = response.AccessToken

    return true, nil
end

---Get server information (no authentication required)
---@return table? info Server info, or nil on error
---@return string? error Error message if request failed
function JellyfinClient:get_server_info()
    return self:request('GET', '/System/Info/Public')
end

---Get user's media libraries/views
---@return JellyfinItem? items Array of library items, or nil on error
---@return string? error Error message if request failed
function JellyfinClient:get_views()
    if not self.user_id then
        return nil, 'not authenticated'
    end

    local response, err = self:request('GET', '/Users/' .. self.user_id .. '/Views')

    if not response or err then
        return nil, err
    end

    return response.Items, nil
end

---Get items in a library or folder
---@param parent_id? string Parent item ID (nil for root libraries)
---@param params? table Additional query parameters
---@return table? items Array of items, or nil on error
---@return string? error Error message if request failed
function JellyfinClient:get_items(parent_id, params)
    if not self.user_id then
        return nil, 'not authenticated'
    end

    -- Build query parameters
    local query_params = {
        userId = self.user_id,
        enableImageTypes = 'Primary',
        imageTypeLimit = '1',
        fields = 'PrimaryImageAspectRatio,Overview,MediaSources',
    }

    if parent_id then
        query_params.parentId = parent_id
    end

    -- Merge additional params
    if params then
        for k, v in pairs(params) do
            query_params[k] = v
        end
    end

    local query_string = http.build_query(query_params)
    local response, err = self:request('GET', '/Items?' .. query_string)

    if not response or err then
        return nil, err
    end

    return response.Items, nil
end

---Get item details by ID
---@param item_id string
---@return table? item Item details, or nil on error
---@return string? error Error message if request failed
function JellyfinClient:get_item(item_id)
    if not self.user_id then
        return nil, 'not authenticated'
    end

    local path = '/Users/' .. self.user_id .. '/Items/' .. item_id
    return self:request('GET', path)
end

---Mark item as played
---@param item_id string
---@return boolean success
---@return string? error Error message if request failed
function JellyfinClient:mark_played(item_id)
    if not self.user_id then
        return false, 'not authenticated'
    end

    local path = '/Users/' .. self.user_id .. '/PlayedItems/' .. item_id
    local _, err = self:request('POST', path)

    if err then
        return false, err
    end

    return true, nil
end

---Get stream URL for a media item
---@param item_id string
---@return string url Direct stream URL
function JellyfinClient:get_stream_url(item_id)
    return self.base_url .. '/Videos/' .. item_id .. '/stream?static=true'
end

---Check if client is authenticated
---@return boolean
function JellyfinClient:is_authenticated()
    return self.user_id ~= nil and self.access_token ~= nil
end

return JellyfinClient
