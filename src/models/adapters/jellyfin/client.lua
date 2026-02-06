--[[
--  Jellyfin API client
--  Provides Jellyfin-specific API wrapper using generic HTTP client
--]]

local mp = require 'mp'
local utils = require 'mp.utils'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local http = require 'src.core.http'
local log = require 'src.core.log'
local options = require 'src.core.options'

---@class PlaybackState
---@field is_playing boolean
---@field current_item JellyfinItem?
---@field play_session_id string?
---@field auto_play_next boolean
---@field manual_stop boolean Track if user manually stopped playback
---@field position_ticks number Playback position in milliseconds
---
---@class JellyfinClient
---@field base_url string
---@field user_id string?
---@field access_token string?
---@field timer MPTimer
---@field adapter_id AdapterID
---@field events AdapterEventMap
---@field keys_are_bound boolean
---@field playback_handlers_configured boolean
---@field keybind_handlers_configured boolean
---@field device_id string
---@field client_name string
---@field client_version string
---@field playback_state PlaybackState
---@field view_limit number
---@field views JellyfinViews
---@field completion_thresh number
local JellyfinClient = {}
JellyfinClient.__index = JellyfinClient

-- Virtual folders are synthetic entries that appear in the root view
-- but fetch their contents from special Jellyfin API endpoints.
-- They use IDs prefixed/suffixed with colons to avoid conflicts.
---@alias VirtualID string
---@type table<string, VirtualID>
local VIRTUAL_IDS = {
    CONTINUE_WATCHING = ':VirtualContinueWatching:',
    NEXT_UP = ':VirtualNextUp:',
    LATEST = ':VirtualLatest:',
}

---@type table<string, JellyfinItem>
local VIRTUAL_ITEMS = {
    CONTINUE_WATCHING = {
        Id = VIRTUAL_IDS.CONTINUE_WATCHING,
        Name = 'Continue Watching',
        Type = 'Folder',
        IsVirtualFolder = true,
        VirtualType = 'continue_watching',
    },
    NEXT_UP = {
        Id = VIRTUAL_IDS.NEXT_UP,
        Name = 'Next Up',
        Type = 'Folder',
        IsVirtualFolder = true,
        VirtualType = 'next_up',
    },
    LATEST = {
        Id = VIRTUAL_IDS.LATEST,
        Name = 'Latest',
        Type = 'Folder',
        IsVirtualFolder = true,
        VirtualType = 'latest',
    },
}

---Create a new Jellyfin client
---@param config JellyfinConfig
---@param api AdapterAPI
---@return JellyfinClient
function JellyfinClient.new(config, api)
    local self = setmetatable({}, JellyfinClient)

    self.base_url = config.url
    self.user_id = nil
    self.access_token = nil
    self.timer = nil
    self.adapter_id = api.adapter_id
    self.events = api.events
    self.keys_are_bound = false
    self.playback_handlers_configured = false
    self.keybind_handlers_configured = false
    self.view_limit = config.view_limit or 25
    self.views = config.views or {}
    self.completion_thresh = config.completion_thresh or 0.95

    -- Device info for authentication
    self.device_id = 'mpv-homehub-1'
    self.client_name = 'mpv-homehub'
    self.client_version = '0.1.0'

    -- Initialize playback state
    self.playback_state = {
        is_playing = false,
        current_item = nil,
        play_session_id = nil,
        auto_play_next = config.auto_play_next ~= false,
        manual_stop = false,
        position_ticks = 0,
    }

    self:setup_playback_handlers()
    self:setup_keybind_handlers()

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

    local request_opts = {
        headers = {
            Authorization = self:get_auth_header(),
        },
    }

    return http.request_json(method, url, data, request_opts)
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
        return false, 'Authentication request failed: ' .. (err or 'unknown error')
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
---@return JellyfinItem[]? items Array of library items, or nil on error
---@return string? error Error message if request failed
function JellyfinClient:get_views()
    if not self.user_id then
        return nil, 'not authenticated'
    end

    ---@type JellyfinItem[]
    local items = {}
    local views = self.views

    if views.libraries ~= false then
        local response, err = self:request('GET', '/Users/' .. self.user_id .. '/Views')

        if not response or err then
            return nil, err
        end

        items = response.Items
    end

    if views.continue_watching ~= false then
        table.insert(items, VIRTUAL_ITEMS.CONTINUE_WATCHING)
    end

    if views.next_up ~= false then
        table.insert(items, VIRTUAL_ITEMS.NEXT_UP)
    end

    if views.latest ~= false then
        table.insert(items, VIRTUAL_ITEMS.LATEST)
    end

    return items, nil
end

---Add series context to episode names
---@param items JellyfinItem[]?
---@return JellyfinItem[]?
local function add_series_context(items)
    if not items then return items end

    local result = {}
    for _, item in ipairs(items) do
        -- Shallow copy
        local transformed = {}
        for k, v in pairs(item) do
            transformed[k] = v
        end

        -- Add series name for episodes
        if item.Type == 'Episode' and item.SeriesName then
            transformed.Name = item.SeriesName .. ' - ' .. (item.Name or 'Unknown')
        end

        table.insert(result, transformed)
    end

    return result
end

---Get continue watching items
---@return JellyfinItem[]? items
---@return string? error
function JellyfinClient:get_continue_watching_items()
    if not self.user_id then
        return nil, 'not authenticated'
    end

    local query_string = http.build_query({
        fields = {
            'PrimaryImageAspectRatio',
            'Overview',
            'MediaSources',
        },
    })

    local path = '/Users/' .. self.user_id .. '/Items/Resume?' .. query_string
    local response, err = self:request('GET', path)
    if err then
        return nil, err
    end

    local items = response and response.Items
    return add_series_context(items) or {}, nil
end

---Get next up episodes
---@return JellyfinItem[]? items
---@return string? error
function JellyfinClient:get_next_up_items()
    if not self.user_id then
        return nil, 'not authenticated'
    end

    local query_string = http.build_query({
        userId = self.user_id,
        limit = self.view_limit,
        fields = {
            'PrimaryImageAspectRatio',
            'Overview',
            'MediaSources',
        },
    })

    local response, err = self:request('GET', '/Shows/NextUp?' .. query_string)

    if err then
        return nil, err
    end

    local items = response and response.Items
    return add_series_context(items) or {}, nil
end

---Get recently added items
---@return JellyfinItem[]? items
---@return string? error
function JellyfinClient:get_latest_items()
    if not self.user_id then
        return nil, 'not authenticated'
    end

    local query_string = http.build_query({
        limit = self.view_limit,
        fields = {
            'PrimaryImageAspectRatio',
            'Overview',
            'MediaSources',
        },
    })
    local path = '/Users/' .. self.user_id .. '/Items/Latest?' .. query_string
    local response, err = self:request('GET', path)

    if err then
        return nil, err
    end

    -- Latest endpoint returns items directly, not wrapped
    return response or {}, nil
end

---Get items from a virtual folder
---@param virtual_id VirtualID
---@return JellyfinItem[]? items Array of items, or nil on error
---@return string? error Error message if request failed
function JellyfinClient:get_virtual_items(virtual_id)
    if not self.user_id then
        return nil, 'not authenticated'
    end

    if not virtual_id then
        return nil, 'virtual_id is nil'
    end

    if virtual_id == VIRTUAL_IDS.CONTINUE_WATCHING then
        return self:get_continue_watching_items()
    elseif virtual_id == VIRTUAL_IDS.NEXT_UP then
        return self:get_next_up_items()
    elseif virtual_id == VIRTUAL_IDS.LATEST then
        return self:get_latest_items()
    else
        return nil, 'Unrecognized virtual id: ' .. virtual_id
    end
end

---Test if `id` is a virtual id
---@param id string
---@return boolean success True if `id` is a virtual id
local function is_virtual_id(id)
    return VIRTUAL_IDS.CONTINUE_WATCHING == id
        or VIRTUAL_IDS.NEXT_UP == id
        or VIRTUAL_IDS.LATEST == id
end

---Get items in a library or folder
---@param parent_id? string Parent item ID (nil for root libraries)
---@param params? table Additional query parameters (sortBy, sortOrder, etc.)
---@return JellyfinItem[]? items Array of items, or nil on error
---@return string? error Error message if request failed
function JellyfinClient:get_items(parent_id, params)
    if not self.user_id then
        return nil, 'not authenticated'
    end

    if is_virtual_id(parent_id or '') then
        return self:get_virtual_items(parent_id or '')
    end

    -- Build query parameters with sensible defaults
    local query_params = {
        userId = self.user_id,
        enableImageTypes = 'Primary',
        imageTypeLimit = '1',
        fields = {
            'PrimaryImageAspectRatio',
            'Overview',
            'MediaSources',
            'ProductionYear'
        },
        -- Default sorting goal: Sort series name > season number > episode number
        sortBy = {
            'SortName',
            'ParentIndexNumber',
            'IndexNumber',
        },
        sortOrder = 'Ascending',
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
---@return JellyfinItem? item Item details, or nil on error
---@return string? error Error message if request failed
function JellyfinClient:get_item(item_id)
    if not self.user_id then
        return nil, 'not authenticated'
    end

    if is_virtual_id(item_id) then
        for _, item in pairs(VIRTUAL_ITEMS) do
            if item.Id == item_id then
                return item
            end
        end
    end

    local path = '/Items/' .. item_id .. '?' .. http.build_query({ userId = self.user_id })
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

    log.info('jellyfin_client', {
        'Marking item played:', item_id
    })

    local query_string = http.build_query({
        userId = self.user_id,
    })
    local path = '/UserPlayedItems/' .. item_id .. '?' .. query_string
    local _, err = self:request('POST', path)

    if err then
        return false, err
    end

    return true, nil
end

---Mark item as played if playback completion exceeds threshold
---Only marks on natural completion (eof), user stop, or quit - not on errors
---@param reason 'eof'|'stop'|'quit'|'error'|'redirect'|'unknown'
---@param jf_item JellyfinItem
function JellyfinClient:mark_played_if(reason, jf_item)
    log.debug('jellyfin_client', {
        ("mark_played_if(reason: '%s', jf_item.RunTimeTicks: '%d', self.position_ticks: '%d')"):format(
            reason, jf_item.RunTimeTicks or 0, self.playback_state.position_ticks or 0
        )
    })

    -- Only mark on intentional completion
    if reason ~= 'eof' and reason ~= 'stop' and reason ~= 'quit' then
        return
    end

    -- Validate runtime data
    if type(jf_item.RunTimeTicks) ~= 'number' or jf_item.RunTimeTicks <= 0 then
        return
    end

    if type(self.playback_state.position_ticks) ~= 'number' or self.playback_state.position_ticks < 0 then
        return
    end

    -- Mark played if threshold met
    local percent_complete = self.playback_state.position_ticks / jf_item.RunTimeTicks
    if percent_complete >= self.completion_thresh then
        self:mark_played(jf_item.Id)
    end
end

---Get stream URL for a media item
---@param item JellyfinItem
---@return string url Direct stream URL
function JellyfinClient:get_stream_url(item)
    local url = table.concat({
        self.base_url, '/Videos/', item.Id,
        '/stream?static=true',
    }, '')

    return url
end

---Check if client is authenticated
---@return boolean
function JellyfinClient:is_authenticated()
    return self.user_id ~= nil and self.access_token ~= nil
end

---Get next episode for a series
---Fetches all episodes in the season and finds the one after the current episode
---@param current_episode JellyfinItem The current episode to find the next one for
---@return JellyfinItem? next_item The next episode, or nil if none
---@return string? error Error message if request failed
function JellyfinClient:get_next_episode(current_episode)
    if not self.user_id then
        return nil, 'not authenticated'
    end

    if current_episode.Type ~= 'Episode' then
        return nil, 'Item is not an episode'
    end

    local season_id = current_episode.SeasonId
    local current_index = current_episode.IndexNumber

    if not season_id or not current_index then
        return nil, 'Episode missing season or index information'
    end

    -- Get all episodes in the season
    local query_params = {
        userId = self.user_id,
        parentId = season_id,
        fields = 'PrimaryImageAspectRatio,Overview,MediaSources,ProductionYear',
        sortBy = 'IndexNumber',
        sortOrder = 'Ascending',
    }

    local query_string = http.build_query(query_params)
    local response, err = self:request('GET', '/Users/' .. self.user_id .. '/Items?' .. query_string)

    if not response or err then
        return nil, err
    end

    -- Find the next episode
    if response.Items then
        for i, episode in ipairs(response.Items) do
            if episode.Id == current_episode.Id and i < #response.Items then
                return response.Items[i + 1], nil
            end
        end
    end

    -- If we're at the last episode of the season, try to get first episode of next season
    -- First get all seasons
    local seasons_params = {
        userId = self.user_id,
        parentId = current_episode.SeriesId,
        includeItemTypes = 'Season',
        fields = 'IndexNumber',
        sortBy = 'IndexNumber',
        sortOrder = 'Ascending',
    }

    local seasons_query = http.build_query(seasons_params)
    local seasons_response, seasons_err = self:request('GET', '/Users/' .. self.user_id .. '/Items?' .. seasons_query)

    if not seasons_response or seasons_err then
        return nil, nil -- End of series, not an error
    end

    -- Find the next season
    local current_season_index = current_episode.ParentIndexNumber
    local next_season_id = nil

    if seasons_response.Items and current_season_index then
        for _, season in ipairs(seasons_response.Items) do
            if season.IndexNumber and season.IndexNumber == current_season_index + 1 then
                next_season_id = season.Id
                break
            end
        end
    end

    if not next_season_id then
        return nil, nil -- No next season
    end

    -- Get first episode of next season
    local next_season_params = {
        userId = self.user_id,
        parentId = next_season_id,
        fields = 'PrimaryImageAspectRatio,Overview,MediaSources',
        sortBy = 'IndexNumber',
        sortOrder = 'Ascending',
        limit = '1',
    }

    local next_season_query = http.build_query(next_season_params)
    local next_season_response, next_season_err = self:request('GET',
        '/Users/' .. self.user_id .. '/Items?' .. next_season_query)

    if not next_season_response or next_season_err then
        return nil, next_season_err
    end

    if next_season_response.Items and #next_season_response.Items > 0 then
        return next_season_response.Items[1], nil
    end

    return nil, nil -- No episodes in next season
end

---Get previous episode for a series
---Fetches all episodes in the season and finds the one before the current episode
---@param current_episode JellyfinItem The current episode ID to find the previous one for
---@return JellyfinItem? prev_item The previous episode, or nil if none
---@return string? error Error message if request failed
function JellyfinClient:get_prev_episode(current_episode)
    if not self.user_id then
        return nil, 'not authenticated'
    end

    if current_episode.Type ~= 'Episode' then
        return nil, 'Item is not an episode'
    end

    local season_id = current_episode.SeasonId
    local current_index = current_episode.IndexNumber

    if not season_id or not current_index then
        return nil, 'Episode missing season or index information'
    end

    -- Get all episodes in the season
    local query_params = {
        userId = self.user_id,
        parentId = season_id,
        fields = 'PrimaryImageAspectRatio,Overview,MediaSources,ProductionYear',
        sortBy = 'IndexNumber',
        sortOrder = 'Ascending',
    }

    local query_string = http.build_query(query_params)
    local response, err = self:request('GET', '/Users/' .. self.user_id .. '/Items?' .. query_string)

    if not response or err then
        return nil, err
    end

    -- Find the previous episode
    if response.Items then
        for i, episode in ipairs(response.Items) do
            if episode.Id == current_episode.Id and i > 1 then
                return response.Items[i - 1], nil
            end
        end
    end

    -- No previous episode (either first episode or not found)
    return nil, nil
end

---Generate a simple play session ID
---@return string
local function generate_play_session_id()
    return os.date('%Y%m%d%H%M%S') .. math.random(1000, 9999)
end

---Report playback start to Jellyfin server
---@param item JellyfinItem
---@return boolean success
---@return string? error
function JellyfinClient:report_playback_start(item)
    if not self.playback_state.play_session_id then
        self.playback_state.play_session_id = generate_play_session_id()
    end

    local data = {
        ItemId = item.Id,
        PlaySessionId = self.playback_state.play_session_id,
        CanSeek = true,
        PlayMethod = 'DirectStream',
        PlaybackStartTimeTicks = self.playback_state.position_ticks,
    }

    local _, err = self:request('POST', '/Sessions/Playing', data)
    return err == nil, err
end

---Report playback stop to Jellyfin server
---@param item_id string
---@return boolean success
---@return string? error
function JellyfinClient:report_playback_stop(item_id)
    if not self.playback_state.play_session_id then
        return true, nil
    end

    local data = {
        ItemId = item_id,
        PlaySessionId = self.playback_state.play_session_id,
        PositionTicks = self.playback_state.position_ticks,
    }

    local _, err = self:request('POST', '/Sessions/Playing/Stopped', data)
    self.playback_state.play_session_id = nil

    return err == nil, err
end

---Report playback progress to Jellyfin server
---@param item_id string
---@param position_ticks number
---@param is_paused boolean
---@return boolean success
---@return string? error
function JellyfinClient:report_playback_progress(item_id, position_ticks, is_paused)
    if not self.playback_state.play_session_id then
        return false, 'no active play session'
    end

    local data = {
        ItemId = item_id,
        PlaySessionId = self.playback_state.play_session_id,
        PositionTicks = position_ticks,
        IsPaused = is_paused,
    }

    local _, err = self:request('POST', '/Sessions/Playing/Progress', data)
    return err == nil, err
end

---Handles series progression logic
---@param current_episode JellyfinItem The current episode
function JellyfinClient:play_next(current_episode)
    local next_episode, err = self:get_next_episode(current_episode)

    if next_episode then
        -- Small delay before starting next episode
        local success, play_err = self:play(next_episode)
        if success then
            self.playback_state.current_item = next_episode
            mp.osd_message('Playing next: ' .. (next_episode.Name or 'Unknown'))
        else
            mp.osd_message('Failed to play next episode: ' .. (play_err or 'unknown error'))
        end
    elseif err then
        -- Error fetching next episode - just log it
        log.warn('jellyfin_client', {
            'Failed to fetch the next episode:', err
        })
    end
end

---Handles series regression logic
function JellyfinClient:play_prev()
    local prev_episode, err = self:get_prev_episode(self.playback_state.current_item)

    if prev_episode then
        -- Small delay before starting previous episode
        mp.add_timeout(0.25, function()
            local success, play_err = self:play(prev_episode)
            if success then
                mp.osd_message('Playing prev: ' .. (prev_episode.Name or 'Unknown'))
            else
                mp.osd_message('Failed to play next episode: ' .. (play_err or 'unknown error'))
            end
        end)
    elseif err then
        -- Error fetching next episode - just log it
        log.warn('jellyfin_client', {
            'Failed to fetch the next episode:', err
        })
    end
end

---Bind client keys
function JellyfinClient:bind_keys()
    if not options.keybinds or not options.keybinds.global then return end
    if self.keys_are_bound then return end

    self.keys_are_bound = true
    local keybind_table = options.keybinds.global

    hh_utils.bind_keys(keybind_table.next, self.adapter_id .. '.next', self.adapter_id .. '.client')
    hh_utils.bind_keys(keybind_table.prev, self.adapter_id .. '.prev', self.adapter_id .. '.client')
end

---Unbind client keys
function JellyfinClient:unbind_keys()
    if not options.keybinds or not options.keybinds.global then return end
    if not self.keys_are_bound then return end

    self.keys_are_bound = false
    events.emit('input.unbind_group', { group = self.adapter_id .. '.client' })
end

---Handle file loaded event from mpv
---@param self JellyfinClient
local function on_file_loaded(self)
    if not self.playback_state.is_playing or not self.playback_state.current_item then
        return
    end

    local item = self.playback_state.current_item

    if not item then
        -- TODO: proper error handling
        return
    end

    log.info('jellyfin_client', {
        'Item loaded - Name:', item.Name, 'ID:', tostring(item.Id)
    })

    -- Seek to last playback position
    if self.playback_state.position_ticks > 0 then
        local target = self.playback_state.position_ticks / 10000000
        mp.commandv('seek', tostring(target), 'absolute')
    end

    -- Report to Jellyfin
    self:report_playback_start(item)

    -- Add external subtitles if available
    if item.MediaSources then
        for _, source in ipairs(item.MediaSources) do
            log.trace('jellyfin_client', {
                'Source:', utils.to_string(source)
            })
            if source.Id == item.Id and source.MediaStreams then
                for _, stream in ipairs(source.MediaStreams) do
                    log.trace('jellyfin_client', {
                        'Stream:', utils.to_string(stream)
                    })
                    if stream.IsTextSubtitleStream and stream.IsExternal and stream.Path then
                        local ext = stream.Path:match('.+%.([^.]+)$') or 'srt'
                        local sub_url = self.base_url .. '/Videos/' .. item.Id
                            .. '/' .. source.Id .. '/Subtitles/' .. tostring(stream.Index)
                            .. '/Stream.' .. ext

                        mp.commandv('sub-add', sub_url, 'auto',
                            stream.DisplayTitle or stream.Language or '',
                            stream.Language or '')
                    end
                end
                break
            end
        end
    end
end

---Handle end file event from mpv
---@param self JellyfinClient
---@param data table Event data with reason
local function on_end_file(self, data)
    if not self.playback_state.is_playing or not self.playback_state.current_item then
        return
    end

    local item = self.playback_state.current_item

    if not item then
        -- TODO: proper error handling
        return
    end

    log.info('jellyfin_client', {
        'Item ended - Name:', item.Name, 'ID:', tostring(item.Id)
    })

    -- Report stop to Jellyfin
    self:report_playback_stop(item.Id)
    self:mark_played_if(data.reason, item)

    -- Check if we should auto-play next episode
    local should_play_next = false
    if self.playback_state.auto_play_next
        and data.reason == 'eof'
        and not self.playback_state.manual_stop
        and item.Type == 'Episode'
        and item.SeriesId then
        should_play_next = true
    end

    -- Try to play next episode if conditions are met
    if should_play_next then
        self:play_next(item)
    elseif data.reason == 'eof' or data.reason == 'quit' then
        self:unbind_keys()

        -- Clear current playback state
        self.playback_state.is_playing = false
        self.playback_state.current_item = nil
        self.playback_state.manual_stop = false
    end
end

---Periodic progress reporting
---@param self JellyfinClient
local function periodic_progress_report(self)
    if not self.playback_state.is_playing or not self.playback_state.current_item then
        return
    end

    local time_pos = mp.get_property_number('time-pos')
    local paused = mp.get_property_bool('pause')

    if time_pos then
        self.playback_state.position_ticks = math.floor(time_pos * 10000000)
        self:report_playback_progress(
            self.playback_state.current_item.Id,
            self.playback_state.position_ticks,
            paused or false
        )
    end
end

---Setup playback event handlers (call once during client initialization)
function JellyfinClient:setup_playback_handlers()
    if self.playback_handlers_configured then return end

    -- Register mpv event handlers
    mp.register_event('file-loaded', function()
        on_file_loaded(self)
    end)

    mp.register_event('end-file', function(data)
        on_end_file(self, data)
    end)

    -- Periodic progress reporting every 5 seconds
    self.timer = mp.add_periodic_timer(5, function()
        periodic_progress_report(self)
    end)

    self.playback_handlers_configured = true
end

---Handle user next request
---@param self JellyfinClient
local function on_next(self)
    if self.playback_state.is_playing then
        self:play_next(self.playback_state.current_item)
    end
end

---Handle user previous request
---@param self JellyfinClient
local function on_prev(self)
    if self.playback_state.is_playing then
        self:play_prev()
    end
end

---Setup keybind event handlers (call once during client initialization)
function JellyfinClient:setup_keybind_handlers()
    if self.keybind_handlers_configured then return end

    events.on(self.events.next, function(_, _)
        on_next(self)
    end, self.adapter_id .. '_client')

    events.on(self.events.prev, function(_, _)
        on_prev(self)
    end, self.adapter_id .. '_client')

    self.keybind_handlers_configured = true
end

---Return title formatted based on contents of item
---@param item JellyfinItem The item used to derive the title
---@return string title The formated title
local function format_title(item)
    local title = item.EpisodeTitle or item.Name or 'Unknown'
    if item.SeriesName then
        local s = item.ParentIndexNumber or '?'
        local e = item.IndexNumber or '?'
        title = ('%s - S%s:E%s - %s'):format(
            item.SeriesName,
            s,
            e,
            title
        )
    end
    if item.ProductionYear then
        title = title .. ' (' .. item.ProductionYear .. ')'
    end

    return title
end

---Play a Jellyfin item
---@param item JellyfinItem The item to play
---@return boolean success
---@return string? error
function JellyfinClient:play(item)
    -- Get stream URL
    local stream_url = self:get_stream_url(item)

    -- Store current item
    self.playback_state.current_item = item
    self.playback_state.is_playing = true
    self.playback_state.position_ticks = item.UserData and item.UserData.PlaybackPositionTicks or 0

    -- Clear playlist and load file
    mp.commandv('playlist-clear')
    mp.commandv('loadfile', stream_url)

    -- Set media title
    mp.set_property('force-media-title', format_title(item))

    log.info('jellyfin_client', {
        'Playing item - Name:', item.Name, 'ID:', item.Id
    })

    if type(self.events.sync) == 'string' then
        events.emit(self.events.sync, {
            adapter_id = self.adapter_id,
            data = {
                item_id = item.Id,
                state = 'playing',
            } --[[@as JellyfinSyncData]]
        } --[[@as AdapterSyncData]])
    end

    -- Bind keys
    self:bind_keys()

    return true, nil
end

---Stop current playback
---@return boolean success
function JellyfinClient:stop_playback()
    if not self.playback_state.is_playing then
        return true
    end

    -- Mark as manual stop to prevent auto-play next
    self.playback_state.manual_stop = true

    mp.commandv('stop')
    self.playback_state.is_playing = false
    self.playback_state.current_item = nil

    return true
end

---Check if currently playing
---@return boolean
function JellyfinClient:is_playing()
    return self.playback_state.is_playing
end

---Get current playing item
---@return JellyfinItem?
function JellyfinClient:get_current_item()
    return self.playback_state.current_item
end

return JellyfinClient
