--- Telegram Notifications Plugin for vCLU
-- Send and receive messages via Telegram Bot API
-- @module plugins.telegram

local telegram = Plugin:new("telegram", {
    name = "Telegram Notifications",
    version = "1.2.0",
    description = "Telegram Bot - send and receive messages"
})

-- ============================================
-- CONSTANTS
-- ============================================

local DEFAULT_API_BASE = "https://api.telegram.org/bot"
local apiBase = DEFAULT_API_BASE  -- Will be set in onInit based on proxyUrl config

-- ============================================
-- INTERNAL STATE
-- ============================================

local stats = {
    messagesSent = 0,
    messagesReceived = 0,
    lastMessageTime = 0,
    lastError = nil
}

local polling = {
    enabled = false,
    offset = 0,
    timer = nil,
    interval = 5000  -- 5 seconds default
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
    return apiBase .. config.botToken .. "/" .. method
end

--- Make API request
local function apiRequest(method, params, callback)
    local url = buildUrl(method)

    -- Build query string for GET or body for POST
    local body = {}
    for k, v in pairs(params or {}) do
        if v ~= nil then
            table.insert(body, k .. "=" .. urlEncode(tostring(v)))
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

--- Process incoming update
local function processUpdate(update)
    -- Handle message
    if update.message then
        local msg = update.message
        local data = {
            messageId = msg.message_id,
            chatId = msg.chat and msg.chat.id,
            chatType = msg.chat and msg.chat.type,  -- private, group, supergroup, channel
            from = {
                id = msg.from and msg.from.id,
                username = msg.from and msg.from.username,
                firstName = msg.from and msg.from.first_name,
                lastName = msg.from and msg.from.last_name,
                isBot = msg.from and msg.from.is_bot
            },
            text = msg.text,
            date = msg.date,
            replyTo = msg.reply_to_message and msg.reply_to_message.message_id
        }

        -- Check if it's a command
        if msg.text and msg.text:sub(1, 1) == "/" then
            local command = msg.text:match("^(/[%w_]+)")
            local args = msg.text:match("^/[%w_]+%s+(.+)$")
            data.command = command
            data.args = args

            telegram:log("debug", "Command received: " .. command .. " from " .. (data.from.username or data.from.id))
            telegram:emit("telegram:command", data)
        end

        stats.messagesReceived = stats.messagesReceived + 1
        telegram:log("debug", "Message received from " .. (data.from.username or tostring(data.from.id)) .. ": " .. (msg.text or "[non-text]"):sub(1, 50))
        telegram:emit("telegram:message", data)
    end

    -- Handle callback query (inline button press)
    if update.callback_query then
        local cb = update.callback_query
        local data = {
            callbackId = cb.id,
            messageId = cb.message and cb.message.message_id,
            chatId = cb.message and cb.message.chat and cb.message.chat.id,
            from = {
                id = cb.from and cb.from.id,
                username = cb.from and cb.from.username,
                firstName = cb.from and cb.from.first_name
            },
            data = cb.data
        }

        telegram:log("debug", "Callback received: " .. (cb.data or ""))
        telegram:emit("telegram:callback", data)
    end
end

--- Poll for updates
local function pollUpdates()
    if not polling.enabled then return end

    local params = {
        offset = polling.offset,
        timeout = 0,  -- Non-blocking for now
        allowed_updates = "message,callback_query"
    }

    apiRequest("getUpdates", params, function(updates, err)
        if err then
            -- Schedule next poll even on error
            if polling.enabled then
                polling.timer = telegram:setTimeout(polling.interval, pollUpdates)
            end
            return
        end

        if updates and #updates > 0 then
            for _, update in ipairs(updates) do
                -- Update offset to acknowledge this update
                if update.update_id >= polling.offset then
                    polling.offset = update.update_id + 1
                end

                -- Process the update
                local ok, err = pcall(processUpdate, update)
                if not ok then
                    telegram:log("error", "Error processing update: " .. tostring(err))
                end
            end
        end

        -- Schedule next poll
        if polling.enabled then
            polling.timer = telegram:setTimeout(polling.interval, pollUpdates)
        end
    end)
end

--- Start polling
local function startPolling()
    if polling.enabled then return end

    polling.enabled = true
    telegram:log("info", "Starting message polling (interval: " .. polling.interval .. "ms)")
    pollUpdates()
end

--- Stop polling
local function stopPolling()
    polling.enabled = false
    if polling.timer then
        telegram:clearTimer(polling.timer)
        polling.timer = nil
    end
    telegram:log("info", "Message polling stopped")
end

-- ============================================
-- INITIALIZATION
-- ============================================

telegram:onInit(function(config)
    if not config.botToken or config.botToken == "" then
        telegram:log("error", "Bot token is required")
        return
    end

    config.defaultParseMode = config.defaultParseMode or "HTML"
    config.enablePolling = config.enablePolling ~= false  -- Default: true
    config.pollingInterval = tonumber(config.pollingInterval) or 5

    polling.interval = config.pollingInterval * 1000  -- Convert to ms

    -- Setup proxy if configured
    if config.proxyUrl and config.proxyUrl ~= "" then
        -- Ensure proxy URL ends with /bot (so token can be appended)
        local proxyBase = config.proxyUrl
        if not proxyBase:match("/$") then
            proxyBase = proxyBase .. "/"
        end
        if not proxyBase:match("/bot$") then
            proxyBase = proxyBase .. "bot"
        end
        apiBase = proxyBase
        telegram:log("info", "Using proxy: " .. config.proxyUrl:gsub("://[^:]+:[^@]+@", "://***:***@"))
    else
        apiBase = DEFAULT_API_BASE
    end

    telegram:log("info", "Initialized" .. (config.chatId and (" with chat_id: " .. config.chatId) or ""))

    -- Test connection by getting bot info
    apiRequest("getMe", {}, function(result, err)
        if result then
            telegram:log("info", "Bot connected: @" .. (result.username or "unknown"))

            -- Start polling if enabled
            if config.enablePolling then
                startPolling()
            end
        else
            telegram:log("error", "Failed to connect to bot")
        end
    end)
end)

telegram:onCleanup(function()
    stopPolling()
    telegram:log("info", "Telegram plugin stopped")
end)

-- ============================================
-- PUBLIC API - SENDING
-- ============================================

--- Send a text message
-- @param text string Message text
-- @param options table Optional: {chatId, parseMode, disableNotification, replyToMessageId}
-- @param callback function Optional callback(result, error)
function telegram:send(text, options, callback)
    options = options or {}

    local chatId = options.chatId or self.config.chatId
    if not chatId then
        telegram:log("error", "No chat ID specified")
        if callback then callback(nil, "No chat ID") end
        return
    end

    local params = {
        chat_id = chatId,
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

--- Reply to a message
-- @param originalMsg table The received message data (from telegram:message event)
-- @param text string Reply text
-- @param callback function Optional callback
function telegram:reply(originalMsg, text, callback)
    self:send(text, {
        chatId = originalMsg.chatId,
        replyTo = originalMsg.messageId
    }, callback)
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
-- @param chatId number Optional chat ID
-- @param callback function Optional callback
function telegram:sendTyping(chatId, callback)
    local params = {
        chat_id = chatId or self.config.chatId,
        action = "typing"
    }

    apiRequest("sendChatAction", params, callback)
end

--- Answer callback query (for inline buttons)
-- @param callbackId string Callback query ID
-- @param options table Optional: {text, showAlert}
-- @param callback function Optional callback
function telegram:answerCallback(callbackId, options, callback)
    options = options or {}

    local params = {
        callback_query_id = callbackId,
        text = options.text,
        show_alert = options.showAlert and "true" or nil
    }

    apiRequest("answerCallbackQuery", params, callback)
end

-- ============================================
-- PUBLIC API - POLLING CONTROL
-- ============================================

--- Start message polling
function telegram:startPolling()
    startPolling()
end

--- Stop message polling
function telegram:stopPolling()
    stopPolling()
end

--- Check if polling is active
function telegram:isPolling()
    return polling.enabled
end

--- Set polling interval
-- @param seconds number Interval in seconds
function telegram:setPollingInterval(seconds)
    polling.interval = seconds * 1000
end

-- ============================================
-- PUBLIC API - INFO
-- ============================================

--- Get bot info
-- @param callback function Callback(result, error)
function telegram:getMe(callback)
    apiRequest("getMe", {}, callback)
end

--- Get stats
function telegram:getStats()
    return {
        messagesSent = stats.messagesSent,
        messagesReceived = stats.messagesReceived,
        lastMessageTime = stats.lastMessageTime,
        lastError = stats.lastError,
        pollingEnabled = polling.enabled
    }
end

--- Set chat ID (for switching recipients)
function telegram:setChatId(chatId)
    self.config.chatId = chatId
end

return telegram
