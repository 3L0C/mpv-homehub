--[[
--  Core search client.
--
--  Provides search functionality for filtering and navigating items.
--  Hybrid pattern: encapsulates async input prompt and keybind management,
--  while emitting events for UI coordination.
--
--  Components create their own search client instances with custom event namespaces:
--      local search = require 'src.core.search'
--      local client = search.new({
--          events = { results = 'search.text.results', ... },
--          keybinds = { next_result = {'n'}, ... }  -- optional
--      })
--
--      -- Client handles prompt, keybinds, and emits events defined at creation
--      local activated = client:execute(items)
--]]

local mp = require 'mp'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local log = require 'src.core.log'
local options = require 'src.core.options'

---@class search
local search = {}

-- Global lock to prevent concurrent searches
local active_client = nil

---Generate a unique identifier for internal events
---@return string
local function generate_internal_id()
    -- Use current time in microseconds for uniqueness
    return tostring(mp.get_time())
end

---@class SearchClientState
---@field active boolean Whether a search is currently in progress
---@field query string|nil Current search query text
---@field original_items Item[] Full unfiltered item list being searched
---@field filtered_items Item[] Current filtered results
---@field match_indices number[] Mapping from filtered index to original index
---@field current_position number Current position in filtered list (1-indexed)

---@class SearchClientInternal
---@field next string Internal event for next navigation
---@field prev string Internal event for prev navigation
---@field select string Internal event for selection
---@field cancel string Internal event for cancellation

---@class SearchClient
---@field private state SearchClientState
---@field private config SearchClientConfig
---@field private events SearchClientEventMap
---@field private _internal SearchClientInternal
---@field private _internal_id string Unique identifier for this client
---@field private _active_coroutine thread|nil Currently running search coroutine
local SearchClient = {}
SearchClient.__index = SearchClient

---Create a new search client instance.
---@param config SearchClientConfig Configuration
---@return SearchClient
function search.new(config)
    if not config or not config.events then
        error('search.new() requires config.events map')
    end

    -- Validate required events
    local required_events = {
        'results',
        'position_changed',
        'completed',
        'cancelled',
        'no_results'
    }

    for _, event_name in ipairs(required_events) do
        if not config.events[event_name] then
            error('search.new() missing required event: ' .. event_name)
        end
    end

    local internal_id = generate_internal_id()

    -- Get keybind config from options or use provided overrides
    local default_keybinds = {
        next_result = {'n'},
        prev_result = {'N'},
        select_result = {'ENTER'},
        cancel = {'ESC'},
    }
    local global_keybinds = options.search.keybinds or {}

    local keybinds = config.keybinds or global_keybinds
    local merged_keybinds = {
        next_result = keybinds.next_result or default_keybinds.next_result,
        prev_result = keybinds.prev_result or default_keybinds.prev_result,
        select_result = keybinds.select_result or default_keybinds.select_result,
        cancel = keybinds.cancel or default_keybinds.cancel,
    }

    local client = setmetatable({
        state = {
            active = false,
            query = nil,
            original_items = {},
            filtered_items = {},
            match_indices = {},
            current_position = 1,
        },
        config = {
            case_sensitive = config.case_sensitive or false,
            search_fields = config.search_fields or {'primary_text', 'secondary_text'},
            keybinds = merged_keybinds,
        },
        events = config.events,
        _internal = {
            next = 'search.internal.' .. internal_id .. '.next',
            prev = 'search.internal.' .. internal_id .. '.prev',
            select = 'search.internal.' .. internal_id .. '.select',
            cancel = 'search.internal.' .. internal_id .. '.cancel',
        },
        _internal_id = internal_id,
        _active_coroutine = nil,
    }, SearchClient)

    -- Register internal event handlers
    events.on('search.internal.' .. internal_id .. '.next', function(_, _)
        client:_handle_next()
    end, 'search_client_' .. internal_id)

    events.on('search.internal.' .. internal_id .. '.prev', function(_, _)
        client:_handle_prev()
    end, 'search_client_' .. internal_id)

    events.on('search.internal.' .. internal_id .. '.select', function(_, _)
        client:_handle_select()
    end, 'search_client_' .. internal_id)

    events.on('search.internal.' .. internal_id .. '.cancel', function(_, _)
        client:_handle_cancel()
    end, 'search_client_' .. internal_id)

    return client
end

---Emit an event using the client's custom namespace
---@param event_map SearchClientEventMap
---@param event_name string Event name from event map
---@param data table Event data
local function emit_event(event_map, event_name, data)
    local event = event_map[event_name]
    if event then
        events.emit(event, data)
    end
end

---Check if an item matches the search query.
---@param config SearchClientConfig
---@param item Item
---@param query string Normalized query string
---@return boolean
local function item_matches_query(config, item, query)
    for _, field in ipairs(config.search_fields) do
        local field_value = item[field]
        if field_value and type(field_value) == 'string' then
            local normalized_value = config.case_sensitive
                and field_value
                or field_value:lower()

            if normalized_value:find(query, 1, true) then
                return true
            end
        end
    end

    return false
end

---Filter items based on search query.
---@param config SearchClientConfig
---@param items Item[]
---@param query string
---@return Item[] filtered_items
---@return number[] match_indices Indices in original item list
local function filter_items(config, items, query)
    local filtered = {}
    local indices = {}

    local normalized_query = config.case_sensitive and query or query:lower()

    for i, item in ipairs(items) do
        if item_matches_query(config, item, normalized_query) then
            table.insert(filtered, item)
            table.insert(indices, i)
        end
    end

    return filtered, indices
end

---Bind navigation keybinds
function SearchClient:_bind_navigation_keys()
    hh_utils.bind_keys(
        self.config.keybinds.next_result,
        self._internal.next,
        'search.active'
    )

    hh_utils.bind_keys(
        self.config.keybinds.prev_result,
        self._internal.prev,
        'search.active'
    )

    hh_utils.bind_keys(
        self.config.keybinds.select_result,
        self._internal.select,
        'search.active'
    )

    hh_utils.bind_keys(
        self.config.keybinds.cancel,
        self._internal.cancel,
        'search.active'
    )

    log.verbose('search', {
        'Bound navigation keys'
    })
end

---Unbind navigation keybinds
function SearchClient:_unbind_navigation_keys()
    events.emit('input.unbind_group', { group = 'search.active' })
    log.verbose('search', {
        'Unbound navigation keys'
    })
end

---Release lock and cleanup
---@param self SearchClient
local function release_lock(self)
    if active_client == self then
        active_client = nil
        log.verbose('search', {
            'Released global lock'
        })
    end
end

---Navigate within filtered results
---@param direction number 1 for next, -1 for prev
function SearchClient:_navigate_results(direction)
    if not self.state.active or #self.state.filtered_items == 0 then
        return
    end

    direction = direction >= 0 and 1 or -1
    self.state.current_position = self.state.current_position + direction

    -- Wrap around
    if self.state.current_position > #self.state.filtered_items then
        self.state.current_position = 1
    elseif self.state.current_position < 1 then
        self.state.current_position = #self.state.filtered_items
    end

    emit_event(self.events, 'position_changed', {
        position = self.state.current_position,
        total = #self.state.filtered_items,
        current_item = self.state.filtered_items[self.state.current_position],
        current_original_index = self.state.match_indices[self.state.current_position],
    })
end

function SearchClient:_complete_search()
    if not self.state.active or #self.state.filtered_items == 0 then
        return
    end

    local selected_index = self.state.match_indices[self.state.current_position]
    local query = self.state.query

    log.verbose('search', {
        'Search completed - selected index: ' .. selected_index
    })

    emit_event(self.events, 'completed', {
        query = query,
        selected_index = selected_index,
    })
end

function SearchClient:_cancel_search()
    if not self.state.active then return end

    local query = self.state.query

    log.verbose('search', {
        'Search cancelled by user'
    })

    emit_event(self.events, 'cancelled', {
        query = query,
    })
end

---Cycle through search results, allowing user navigation
---@async
function SearchClient:_cycle_search_results()
    self._active_coroutine = coroutine.running()

    -- Bind keys for navigating results
    self:_bind_navigation_keys()

    while true do
        -- Wait for action
        local action = coroutine.yield()

        if action == 'next' then
            self:_navigate_results(1)
        elseif action == 'prev' then
            self:_navigate_results(-1)
        elseif action == 'select' then
            self:_complete_search()
        elseif action == 'cancel' then
            self:_cancel_search()
            break
        end
    end

    self:_cleanup(false)
end

---Main search coroutine - prompts for input and filters items.
---@async
---@param items Item[]
function SearchClient:_search_coroutine(items)
    local co = hh_utils.coroutine.assert("cannot create a coroutine callback for the main thread")
    self._active_coroutine = co

    -- Check if mp.input is available
    local input_loaded, input = pcall(require, 'mp.input')
    if not input_loaded then
        log.error('search', {
            'mp.input module not available - search requires mpv 0.34+'
        })
        self:_cleanup(true)
        return
    end

    log.verbose('search', {
        'Starting search coroutine'
    })

    -- Prompt for search query
    input.get({
        prompt = "Search: ",
        id = "homehub/search/" .. self._internal_id,
        default_text = "",
        submit = function(text)
            hh_utils.coroutine.resume_err(co, true, text)  -- Submitted
        end,
        closed = function(text)
            hh_utils.coroutine.resume_err(co, false, text)  -- Cancelled
        end,
    })

    -- Wait for user input
    local submitted, query = coroutine.yield()
    input.terminate()

    -- Handle cancellation
    if not submitted then
        log.verbose('search', {
            'User cancelled input prompt'
        })
        emit_event(self.events, 'cancelled', { query = nil })
        self:_cleanup(true)
        return
    end

    -- Validate query
    if not query or query == '' then
        log.verbose('search', {
            'Empty search query'
        })
        emit_event(self.events, 'cancelled', { query = '' })
        self:_cleanup(true)
        return
    end

    log.verbose('search', {
        'Searching for: "' .. query .. '"'
    })

    -- Store query
    self.state.query = query
    self.state.original_items = items

    -- Filter items
    local filtered, indices = filter_items(self.config, items, query)

    -- Check results
    if #filtered == 0 then
        log.warn('search', {
            'No matches found for: "' .. query .. '"'
        })
        emit_event(self.events, 'no_results', {
            query = query,
        })
        self:_cleanup(true)
        return
    end

    -- Store filtered results
    self.state.filtered_items = filtered
    self.state.match_indices = indices
    self.state.current_position = 1

    log.info('search', {
        ('Found %d match%s for: "%s"'):format(
            #filtered,
            #filtered == 1 and '' or 'es',
            query
        )
    })

    -- Emit results event
    emit_event(self.events, 'results', {
        query = query,
        filtered_items = filtered,
        match_indices = indices,
        total_matches = #filtered,
        current_position = 1,
        current_item = filtered[1],
        current_original_index = indices[1],
    })

    hh_utils.coroutine.run(function()
        self:_cycle_search_results()
    end)
end

---Execute search on provided items.
---Acquires global lock, binds keybinds, prompts user for query.
---Returns true if activated, false if blocked by another active search.
---@param items Item[] Items to search through
---@return boolean activated True if search was activated, false if blocked
function SearchClient:execute(items)
    -- Check for global lock
    if active_client and active_client ~= self then
        log.warn('search', {
            'Search activation blocked - another search is active'
        })
        return false
    end

    -- Validate items
    if not items or #items == 0 then
        log.warn('search', {
            'No items provided for search'
        })
        return false
    end

    -- Acquire lock
    active_client = self
    self.state.active = true

    log.verbose('search', {
        'Activated search client'
    })

    -- Start search coroutine
    hh_utils.coroutine.run(function()
        self:_search_coroutine(items)
    end)

    return true
end

---Internal handler for next navigation
function SearchClient:_handle_next()
    if self._active_coroutine then
        hh_utils.coroutine.resume_err(self._active_coroutine, 'next')
    end
end

---Internal handler for prev navigation
function SearchClient:_handle_prev()
    if self._active_coroutine then
        hh_utils.coroutine.resume_err(self._active_coroutine, 'prev')
    end
end

---Internal handler for selection
function SearchClient:_handle_select()
    if self._active_coroutine then
        hh_utils.coroutine.resume_err(self._active_coroutine, 'select')
    end
end

---Internal handler for cancellation
function SearchClient:_handle_cancel()
    if self._active_coroutine then
        hh_utils.coroutine.resume_err(self._active_coroutine, 'cancel')
    end
end

---Internal cleanup method
---@param skip_unbind boolean Skip unbinding keys (already unbound or never bound)
function SearchClient:_cleanup(skip_unbind)
    -- Unbind keys if they were bound
    if not skip_unbind then
        self:_unbind_navigation_keys()
    end

    -- Clear state
    self.state.active = false
    self.state.query = nil
    self.state.original_items = {}
    self.state.filtered_items = {}
    self.state.match_indices = {}
    self.state.current_position = 1
    self._active_coroutine = nil

    -- Release lock
    release_lock(self)
end

---Cancel active search (public API for manual cancellation)
function SearchClient:cancel()
    self:_handle_cancel()
end

---Check if search is currently active.
---@return boolean
function SearchClient:is_active()
    return self.state.active
end

---Get current query string.
---Returns nil if no active search.
---@return string|nil
function SearchClient:get_query()
    return self.state.query
end

---Get current position info.
---Returns nil if no active search.
---@return SearchPosition|nil
function SearchClient:get_current()
    if not self.state.active or #self.state.filtered_items == 0 then
        return nil
    end

    return {
        position = self.state.current_position,
        total = #self.state.filtered_items,
        current_item = self.state.filtered_items[self.state.current_position],
        current_original_index = self.state.match_indices[self.state.current_position],
    }
end

---Cleanup client and unregister event listeners
function SearchClient:cleanup()
    -- Cancel any active search
    if self.state.active then
        self:_cleanup(false)
    end

    -- Unregister internal event handlers
    events.cleanup_component('search_client_' .. self._internal_id)

    log.verbose('search', {
        'Cleaned up search client'
    })
end

return search
