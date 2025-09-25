--[[
--  Content controller.
--]]

---@class content: Controller
local content = {}

---@class ContentRequestData
---@field ctx_id NavCtxID
---@field location NavID
---
---@class ContentLoadingData
---@field ctx_id NavCtxID
---
---@class ContentLoadedData
---@field ctx_id NavCtxID
---@field items TextItem[]
---
---@class ContentErrorData
---@field ctx_id NavCtxID
---@field msg string

function content.init()
end

function content.cleanup()
end

return content
