--- Telegram Notifications Plugin for vCLU
-- Send notifications via Telegram Bot API
-- @module plugins.telegram

local telegram = Plugin:new("telegram", {
    name = "Telegram Notifications",
    version = "1.0.0",
    description = "Telegram Bot notifications"
})

-- ============================================
-- CONSTANTS
-- ============================================

local API_BASE = "https://api.telegram.org/bot"

-- ============================================
-- INTERNAL STATE
-- ============================================

local stats = {
    messagesSent = 0,
    lastMessageTime = 0,
    lastError = nil
}

-- ============================================
-- PRIVATE FUNCTIONS
-- ============================================

--- URL encode a string
local function urlEncode(str)
    if not str then return "" end
    str = tostring(str)
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w _%%%-%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub(" ", "+")
    return str
end

--- Build API URL
local function buildUrl(method)
    local config = telegram.config
    return API_BASE .. config.botToken .. "/" .. method
end

--- Make API request
local function apiRequest(method, params, callback)
    local url = buildUrl(method)

    -- Build query string for GET or body for POST
    local body = {}
    for k, v in pairs(params or {}) do
        if v ~= nil then
            table.insert(body, k .. "=" .. urlEncode(v))
        end
    end
    local queryString = table.concat(body, "&")

    -- Use POST for sendMessage (body can be large)
    telegram:httpRequest({
        method = "POST",
        url = url,
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded"
        },
        body = queryString,
        timeout = 10000
    }, function(response, err)
        if err then
            stats.lastError = err
            telegram:log("error", "API request failed: " .. tostring(err))
            telegram:emit("telegram:error", { error = err, method = method })
            if callback then callback(nil, err) end
            return
        end

        if not response or response.status ~= 200 then
            local errMsg = "HTTP " .. tostring(response and response.status or "error")
            stats.lastError = errMsg
            telegram:log("error", "API error: " .. errMsg)
            telegram:emit("telegram:error", { error = errMsg, method = method })
            if callback then callback(nil, errMsg) end
            return
        end

        -- Parse response
        local result = nil
        if response.body and response.body ~= "" then
            local ok, parsed = pcall(function() return JSON:decode(response.body) end)
            if ok then result = parsed end
        end

        if result and result.ok then
            if callback then callback(result.result, nil) end
        else
            local errMsg = result and result.description or "Unknown error"
            stats.lastError = errMsg
            telegram:log("error", "Telegram API error: " .. errMsg)
            telegram:emit("telegram:error", { error = errMsg, method = method })
            if callback then callback(nil, errMsg) end
        end
    end)
end

-- ============================================
-- INITIALIZATION
-- ============================================

telegram:onInit(function(config)
    if not config.botToken or config.botToken == "" then
        telegram:log("error", "Bot token is required")
        return
    end

    if not config.chatId or config.chatId == "" then
        telegram:log("error", "Chat ID is required")
        return
    end

    config.defaultParseMode = config.defaultParseMode or "HTML"

    telegram:log("info", "Initialized with chat_id: " .. config.chatId)

    -- Test connection by getting bot info
    apiRequest("getMe", {}, function(result, err)
        if result then
            telegram:log("info", "Bot connected: @" .. (result.username or "unknown"))
        end
    end)
end)

telegram:onCleanup(function()
    telegram:log("info", "Telegram plugin stopped")
end)

-- ============================================
-- PUBLIC API
-- ============================================

--- Send a text message
-- @param text string Message text
-- @param options table Optional: {chatId, parseMode, disableNotification, replyToMessageId}
-- @param callback function Optional callback(result, error)
function telegram:send(text, options, callback)
    options = options or {}

    local params = {
        chat_id = options.chatId or self.config.chatId,
        text = text,
        parse_mode = options.parseMode or self.config.defaultParseMode,
        disable_notification = options.silent and "true" or nil,
        reply_to_message_id = options.replyTo
    }

    apiRequest("sendMessage", params, function(result, err)
        if result then
            stats.messagesSent = stats.messagesSent + 1
            stats.lastMessageTime = os.time()
            telegram:log("debug", "Message sent: " .. text:sub(1, 50))
            telegram:emit("telegram:sent", { text = text, messageId = result.message_id })
        end
        if callback then callback(result, err) end
    end)
end

--- Send a message (alias for send)
function telegram:sendMessage(text, options, callback)
    self:send(text, options, callback)
end

--- Send a silent message (no notification sound)
function telegram:sendSilent(text, options, callback)
    options = options or {}
    options.silent = true
    self:send(text, options, callback)
end

--- Send an alert message (with notification)
-- @param title string Alert title
-- @param message string Alert message
-- @param callback function Optional callback
function telegram:alert(title, message, callback)
    local text = "<b>" .. title .. "</b>\n" .. message
    self:send(text, { parseMode = "HTML" }, callback)
end

--- Send a warning message
function telegram:warning(message, callback)
    self:alert("Warning", message, callback)
end

--- Send an error message
function telegram:error(message, callback)
    self:alert("Error", message, callback)
end

--- Send a success message
function telegram:success(message, callback)
    self:alert("Success", message, callback)
end

--- Send a photo
-- @param photoUrl string URL of the photo or file_id
-- @param options table Optional: {caption, chatId, parseMode}
-- @param callback function Optional callback
function telegram:sendPhoto(photoUrl, options, callback)
    options = options or {}

    local params = {
        chat_id = options.chatId or self.config.chatId,
        photo = photoUrl,
        caption = options.caption,
        parse_mode = options.parseMode or self.config.defaultParseMode
    }

    apiRequest("sendPhoto", params, function(result, err)
        if result then
            stats.messagesSent = stats.messagesSent + 1
            stats.lastMessageTime = os.time()
            telegram:emit("telegram:sent", { type = "photo", messageId = result.message_id })
        end
        if callback then callback(result, err) end
    end)
end

--- Send a location
-- @param latitude number Latitude
-- @param longitude number Longitude
-- @param options table Optional: {chatId}
-- @param callback function Optional callback
function telegram:sendLocation(latitude, longitude, options, callback)
    options = options or {}

    local params = {
        chat_id = options.chatId or self.config.chatId,
        latitude = tostring(latitude),
        longitude = tostring(longitude)
    }

    apiRequest("sendLocation", params, function(result, err)
        if result then
            stats.messagesSent = stats.messagesSent + 1
            stats.lastMessageTime = os.time()
        end
        if callback then callback(result, err) end
    end)
end

--- Send a document/file
-- @param documentUrl string URL of the document or file_id
-- @param options table Optional: {caption, chatId, filename}
-- @param callback function Optional callback
function telegram:sendDocument(documentUrl, options, callback)
    options = options or {}

    local params = {
        chat_id = options.chatId or self.config.chatId,
        document = documentUrl,
        caption = options.caption
    }

    apiRequest("sendDocument", params, callback)
end

--- Send typing indicator
-- @param callback function Optional callback
function telegram:sendTyping(callback)
    local params = {
        chat_id = self.config.chatId,
        action = "typing"
    }

    apiRequest("sendChatAction", params, callback)
end

--- Get bot info
-- @param callback function Callback(result, error)
function telegram:getMe(callback)
    apiRequest("getMe", {}, callback)
end

--- Get stats
function telegram:getStats()
    return {
        messagesSent = stats.messagesSent,
        lastMessageTime = stats.lastMessageTime,
        lastError = stats.lastError
    }
end

--- Set chat ID (for switching recipients)
function telegram:setChatId(chatId)
    self.config.chatId = chatId
end

return telegram
