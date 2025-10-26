---@meta _

---HTTP request options
---@class HttpRequestOptions
---@field headers table<string, string>? HTTP headers to include in request
---@field body string? Request body (for POST/PUT requests)
---@field timeout number? Request timeout in seconds
---@field follow_redirects boolean? Follow HTTP redirects (default: true)
---@field include_headers boolean? Include response headers in result (default: false)

---HTTP response object
---@class HttpResponse
---@field status number HTTP status code (e.g., 200, 404, 500)
---@field body string Raw response body as string
---@field headers table<string, string> Response headers (only if include_headers was true)
