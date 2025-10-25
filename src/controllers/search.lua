--[[
--  Search UI overlay
--
--  Provides incremental search functionality for filtering and navigating items.
--  Works as a UI overlay that can be pushed onto any UI mode.
--  Uses mp.input for text entry and displays filtered results.
--]]

local mp = require 'mp'
local utils = require 'mp.utils'

local events = require 'src.core.events'
local hh_utils = require 'src.core.utils'
local options = require 'src.core.options'

---@class ui_search: Controller
local ui_search = {}

---@class SearchState
---@field id UiOverlay Overlay identifier
---@field active boolean Whether overlay is currently active
---@field visible boolean Whether overlay is currently visible
---@field active_coroutine thread|nil Currently running search coroutine
---@field parent_ctx_id NavCtxID Context that initiated search
---@field original_items Item[] Full unfiltered item list
---@field filtered_items Item[] Current filtered results
---@field match_indices number[] Mapping from filtered index to original index
---@field original_position number Cursor position before search
---@field current_position number Current position in filtered list (1-indexed)
---@field case_sensitive boolean Whether search is case-sensitive
---@field search_fields string[] Which Item fields to search
---@field keybinds_active boolean Whether result navigation keys are bound
local search_state = {
    id = 'search',
    active = false,
    visible = false,
    active_coroutine = nil,
    -- parent_ctx_id = '',
    original_items = {},
    filtered_items = {},
    match_indices = {},
    original_position = 1,
    current_position = 1,
    case_sensitive = false,
    search_fields = {'primary_text', 'secondary_text'},
    keybinds_active = false,
}

---Set search configuration from options.
local function configure_search()
    if options.search then
        search_state.case_sensitive = options.search.case_sensitive or false
        search_state.search_fields = options.search.search_fields or {'primary_text', 'secondary_text'}
    end
end

---Check if an item matches the search query.
---@param item Item
---@param query string Normalized query string
---@return boolean
local function item_matches_query(item, query)
    for _, field in ipairs(search_state.search_fields) do
        local field_value = item[field]
        if field_value and type(field_value) == 'string' then
            local normalized_value = search_state.case_sensitive
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
---@param items Item[]
---@param query string
---@return Item[] filtered_items
---@return number[] match_indices Indices in original item list
local function filter_items(items, query)
    local filtered = {}
    local indices = {}

    local normalized_query = search_state.case_sensitive and query or query:lower()

    for i, item in ipairs(items) do
        if item_matches_query(item, normalized_query) then
            table.insert(filtered, item)
            table.insert(indices, i)
        end
    end

    return filtered, indices
end

---Render the current search results using zoned layout.
local function render_search_results()
    if not search_state.visible then return end

    local show_count = options.search and options.search.show_match_count
    show_count = show_count == nil and true or show_count

    if show_count and #search_state.filtered_items > 0 then
        events.emit('text_renderer.render', {
            header = {
                items = {
                    {
                        primary_text = string.format('Search Results: %d / %d matches',
                            search_state.current_position,
                            #search_state.filtered_items),
                        style_variant = 'accent',
                    },
                    {
                        primary_text = '────────────────────────────────',
                        style_variant = 'secondary',
                    },
                },
                style = 'compact',  -- or 'spacious' for extra spacing
            },
            body = {
                items = search_state.filtered_items,
            },
            cursor_pos = search_state.current_position,
        })
    else
        -- No header, just body
        events.emit('text_renderer.render', {
            body = {
                items = search_state.filtered_items,
            },
            cursor_pos = search_state.current_position,
        })
    end

end

---Bind keys for navigating search results.
local function bind_result_navigation_keys()
    if search_state.keybinds_active then return end

    local keybinds = options.search and options.search.keybinds or {}

    hh_utils.bind_keys(
        keybinds.next_result or {'n'},
        'search.next_result',
        'search.active'
    )
    hh_utils.bind_keys(
        keybinds.prev_result or {'N'},
        'search.prev_result',
        'search.active'
    )
    hh_utils.bind_keys(
        keybinds.select_result or {'ENTER'},
        'search.select_result',
        'search.active'
    )
    hh_utils.bind_keys(
        keybinds.cancel or {'ESC'},
        'search.cancel',
        'search.active'
    )

    search_state.keybinds_active = true
end

---Unbind result navigation keys.
local function unbind_result_navigation_keys()
    if not search_state.keybinds_active then return end

    events.emit('input.unbind_group', { group = 'search.active' })
    search_state.keybinds_active = false
end

---Navigate within filtered results.
---@param direction number 1 for next, -1 for prev
local function navigate_results(direction)
    if #search_state.filtered_items == 0 then return end

    search_state.current_position = search_state.current_position + direction

    -- Wrap around
    if search_state.current_position < 1 then
        search_state.current_position = #search_state.filtered_items
    elseif search_state.current_position > #search_state.filtered_items then
        search_state.current_position = 1
    end

    render_search_results()
end

---Complete search with selection.
local function complete_search()
    if #search_state.filtered_items == 0 then return end

    -- Map filtered position to original position
    local original_index = search_state.match_indices[search_state.current_position]

    events.emit('msg.debug.ui_search', { msg = {
        'Search complete - selected item at original index:', original_index
    }})

    -- Pop overlay
    events.emit('ui.pop_overlay', { overlay = search_state.id })

    -- -- Update navigation to selected item
    -- events.emit('nav.set_state', {
    --     ctx_id = search_state.parent_ctx_id,
    --     position = original_index,
    -- })

    -- Trigger selection
    events.emit('nav.select')
end

---Cancel search and restore original position.
local function cancel_search()
    events.emit('msg.debug.ui_search', { msg = { 'Search cancelled' }})

    -- -- Restore original position
    -- events.emit('nav.set_state', {
    --     ctx_id = search_state.parent_ctx_id,
    --     position = search_state.original_position,
    -- })

    -- Pop overlay
    events.emit('ui.pop_overlay', { overlay = search_state.id })
end

---Cycle through search results, allowing user to navigate with n/N keys.
---@async
local function cycle_search_results()
    search_state.active_coroutine = coroutine.running()

    -- Bind keys for navigating results
    bind_result_navigation_keys()

    -- Initial render
    render_search_results()

    while true do
        -- Yield and wait for action
        local action = coroutine.yield()

        if action == 'next' then
            navigate_results(1)
        elseif action == 'prev' then
            navigate_results(-1)
        elseif action == 'select' then
            complete_search()
            break
        elseif action == 'cancel' then
            cancel_search()
            break
        end
    end

    -- Cleanup
    unbind_result_navigation_keys()
    search_state.active_coroutine = nil
end

---Main search coroutine - prompts for input and filters items.
---@async
local function search_coroutine()
    search_state.active_coroutine = coroutine.running()

    -- Get current items and position
    local items = search_state.original_items

    if not items or #items == 0 then
        events.emit('msg.warn.ui_search', { msg = {
            'No items available to search'
        }})
        events.emit('ui.pop_overlay', { overlay = search_state.id })
        search_state.active_coroutine = nil
        return
    end

    events.emit('text_renderer.render', {
        items = items,
        cursor_pos = search_state.original_position,
        force_show = true,
    } --[[@as TextRendererRenderData]])

    -- search_state.parent_ctx_id = ctx_id
    -- search_state.original_items = items
    -- search_state.original_position = position

    -- Check if mp.input is available
    local input_loaded, input = pcall(require, 'mp.input')
    if not input_loaded then
        events.emit('msg.error.ui_search', { msg = {
            'mp.input module not available - search requires mpv 0.34+',
            'Please update mpv or disable search feature'
        }})
        events.emit('ui.pop_overlay', { overlay = search_state.id })
        search_state.active_coroutine = nil
        return
    end

    events.emit('msg.debug.ui_search', { msg = {
        'Starting search',
        'Item count:', #items,
        -- 'Original position:', position
    }})

    -- Prompt for search query
    input.get({
        prompt = "Search: ",
        id = "homehub/search",
        default_text = "",
        submit = hh_utils.coroutine.callback(),
    })

    -- Wait for user input
    local query, err = coroutine.yield()
    input.terminate()

    -- Handle cancellation
    if not query then
        events.emit('msg.debug.ui_search', { msg = { 'Search cancelled:', err }})
        events.emit('ui.pop_overlay', { overlay = search_state.id })
        search_state.active_coroutine = nil
        return
    end

    events.emit('msg.debug.ui_search', { msg = {
        'Searching for:', query
    }})

    -- Filter items
    local filtered, indices = filter_items(items, query)

    -- Check results
    if #filtered == 0 then
        events.emit('msg.warn.ui_search', { msg = {
            'No matches found for: "' .. query .. '"'
        }})
        events.emit('ui.pop_overlay', { overlay = search_state.id })
        search_state.active_coroutine = nil
        return
    end

    events.emit('msg.info.ui_search', { msg = {
        string.format('Found %d match%s for: "%s"',
            #filtered,
            #filtered == 1 and '' or 'es',
            query)
    }})

    -- Store filtered results
    search_state.filtered_items = filtered
    search_state.match_indices = indices
    search_state.current_position = 1

    -- Start result cycling
    hh_utils.coroutine.run(cycle_search_results)
end

---@type HandlerTable
local handlers = {

    -- UI Overlay lifecycle

    ['ui.search.activate'] = function(_, _)
        search_state.active = true
        search_state.visible = true

        events.emit('msg.debug.ui_search', { msg = { 'Search overlay activated' }})

        -- Start search coroutine
        hh_utils.coroutine.run(search_coroutine)
    end,

    ['ui.search.deactivate'] = function(_, _)
        -- Cancel any active search
        if search_state.active_coroutine then
            search_state.active_coroutine = nil
        end

        unbind_result_navigation_keys()

        search_state.active = false
        search_state.visible = false
        search_state.filtered_items = {}
        search_state.match_indices = {}

        events.emit('msg.debug.ui_search', { msg = { 'Search overlay deactivated' }})
    end,

    ['ui.search.show'] = function(_, _)
        search_state.visible = true
        render_search_results()
    end,

    ['ui.search.hide'] = function(_, _)
        search_state.visible = false
        events.emit('text_renderer.hide')
    end,

    -- Result navigation actions

    ['search.next_result'] = function(_, _)
        if search_state.active_coroutine then
            hh_utils.coroutine.resume_err(search_state.active_coroutine, 'next')
        end
    end,

    ['search.prev_result'] = function(_, _)
        if search_state.active_coroutine then
            hh_utils.coroutine.resume_err(search_state.active_coroutine, 'prev')
        end
    end,

    ['search.select_result'] = function(_, _)
        if search_state.active_coroutine then
            hh_utils.coroutine.resume_err(search_state.active_coroutine, 'select')
        end
    end,

    ['search.cancel'] = function(_, _)
        if search_state.active_coroutine then
            hh_utils.coroutine.resume_err(search_state.active_coroutine, 'cancel')
        end
    end,

    -- Nav monitoring to cache data

    ---@param event_name EventName
    ---@param data NavPositionChangedData|EventData
    ['nav.pos_changed'] = function(event_name, data)
        if not data or type(data.position) ~= 'number' then
            hh_utils.emit_data_error(event_name, data, 'search')
            return
        end

        search_state.original_position = data.position
    end,

    -- Content monitoring to cache data

    ---@param event_name EventName
    ---@param data ContentLoadedData|EventData
    ['content.loaded'] = function(event_name, data)
        if not hh_utils.validate_data(event_name, data, hh_utils.is_content_loaded, 'ui_search') then
            return
        end

        -- Cache items for search
        search_state.original_items = data.items
    end,

    ['content.loading'] = function(_, _)
        -- Clear cached items when content changes
        if not search_state.active then
            search_state.original_items = {}
        end
    end,
}

---Main search event handler.
---@param event_name EventName
---@param data EventData
local function handler(event_name, data)
    hh_utils.handler_template(event_name, data, handlers, 'ui_search')
end

function ui_search.init()
    -- Configure search from options
    configure_search()

    -- Register as UI overlay
    events.emit('ui.register_overlay', { overlay = search_state.id })

    -- Register event handlers
    for event in pairs(handlers) do
        events.on(event, handler, 'ui_search')
    end

    events.on('sys.cleanup', ui_search.cleanup, 'ui_search')

    events.emit('msg.info.ui_search', { msg = {
        'Search overlay initialized',
        'Case sensitive:', search_state.case_sensitive,
        'Search fields:', table.concat(search_state.search_fields, ', ')
    }})
end

function ui_search.cleanup()
    -- Cancel any active search
    if search_state.active_coroutine then
        search_state.active_coroutine = nil
    end

    -- Unbind any active keys
    unbind_result_navigation_keys()

    -- Unregister overlay
    events.emit('ui.unregister_overlay', { overlay = search_state.id })

    -- Cleanup event listeners
    events.cleanup_component('ui_search')
end

return ui_search
