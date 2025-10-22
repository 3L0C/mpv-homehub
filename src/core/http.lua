--[[
--  Generic HTTP client using curl subprocess
--  Provides low-level HTTP request functionality for adapters
--]]

local mp = require 'mp'
local utils = require 'mp.utils'

local events = require 'src.core.events'

---@class http
local http = {}

---Make a synchronous HTTP request using curl
---@param method string HTTP method (GET, POST, PUT, DELETE, etc.)
---@param url string Full URL to request
---@param options? HttpRequestOptions Request options
---@return HttpResponse? response Response object, or nil on error
---@return string? error Error message if request failed
function http.request(method, url, options)
    options = options or {}

    local args = { 'curl', '-X', method, url }

    -- Add headers
    if options.headers then
        for key, value in pairs(options.headers) do
            table.insert(args, '-H')
            table.insert(args, key .. ': ' .. value)
        end
    end

    -- Add body for POST/PUT requests
    if options.body then
        table.insert(args, '-d')
        table.insert(args, options.body)
    end

    -- Add timeout if specified
    if options.timeout then
        table.insert(args, '--max-time')
        table.insert(args, tostring(options.timeout))
    end

    -- Follow redirects by default
    if options.follow_redirects ~= false then
        table.insert(args, '-L')
    end

    -- Silent mode (no progress bar)
    table.insert(args, '-s')

    -- Include response headers if requested
    if options.include_headers then
        table.insert(args, '-i')
    end

    local result = mp.command_native({
        name = 'subprocess',
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
        args = args,
    })

    events.emit('msg.trace.http', { msg = {
        'Result:', utils.to_string(result)
    } })

    if not result then
        return nil, 'subprocess command returned nil'
    end

    if result.status ~= 0 then
        local error_msg = result.stderr or ('curl failed with status: ' .. tostring(result.status))
        return nil, error_msg
    end

    local response = {
        status = result.status,
        body = result.stdout or '',
        headers = {},
    }

    return response, nil
end

---Make a GET request
---@param url string
---@param options? HttpRequestOptions
---@return HttpResponse? response
---@return string? error
function http.get(url, options)
    return http.request('GET', url, options)
end

---Make a POST request
---@param url string
---@param body string Request body
---@param options? HttpRequestOptions
---@return HttpResponse? response
---@return string? error
function http.post(url, body, options)
    options = options or {}
    options.body = body
    return http.request('POST', url, options)
end

---Make a PUT request
---@param url string
---@param body string Request body
---@param options? HttpRequestOptions
---@return HttpResponse? response
---@return string? error
function http.put(url, body, options)
    options = options or {}
    options.body = body
    return http.request('PUT', url, options)
end

---Make a DELETE request
---@param url string
---@param options? HttpRequestOptions
---@return HttpResponse? response
---@return string? error
function http.delete(url, options)
    return http.request('DELETE', url, options)
end

---Make a JSON request and parse response
---@param method string HTTP method
---@param url string Full URL
---@param data? table Data to encode as JSON body
---@param options? HttpRequestOptions Additional options
---@return table? json Parsed JSON response, or nil on error
---@return string? error Error message if request failed
function http.request_json(method, url, data, options)
    options = options or {}
    options.headers = options.headers or {}

    -- Set JSON headers
    options.headers['Accept'] = 'application/json'

    if data then
        options.headers['Content-Type'] = 'application/json'
        options.body = utils.format_json(data)
    end

    local response, err = http.request(method, url, options)

    if err then
        return nil, err
    end

    -- response could be nil if http.request failed
    if not response then
        return nil, 'no response from request'
    end

    if not response.body or response.body == '' then
        return nil, 'empty response body'
    end

    local json = utils.parse_json(response.body)
    if not json then
        return nil, 'failed to parse JSON response'
    end

    return json, nil
end

---Make a GET request expecting JSON response
---@param url string
---@param options? HttpRequestOptions
---@return table? json
---@return string? error
function http.get_json(url, options)
    return http.request_json('GET', url, nil, options)
end

---Make a POST request with JSON data expecting JSON response
---@param url string
---@param data table Data to encode as JSON
---@param options? HttpRequestOptions
---@return table? json
---@return string? error
function http.post_json(url, data, options)
    return http.request_json('POST', url, data, options)
end

---Build query string from parameters
---Handles string, number, boolean, and array values
---Arrays are joined with commas (e.g., sortBy=Name,Date)
---@param params table<string, string|number|boolean|table>
---@return string query_string
function http.build_query(params)
    local parts = {}
    for key, value in pairs(params) do
        local encoded_value
        if type(value) == 'table' then
            -- Join array values with commas
            local string_values = {}
            for _, v in ipairs(value) do
                table.insert(string_values, tostring(v))
            end
            encoded_value = table.concat(string_values, ',')
        else
            encoded_value = tostring(value)
        end
        table.insert(parts, key .. '=' .. encoded_value)
    end
    return table.concat(parts, '&')
end

---URL encode a string
---@param str string
---@return string encoded
function http.urlencode(str)
    str = string.gsub(str, '\n', '\r\n')
    str = string.gsub(str, '([^%w%-%.%_%~ ])', function(c)
        return string.format('%%%02X', string.byte(c))
    end)
    str = string.gsub(str, ' ', '+')
    return str
end

return http
