--- Telegram Notifications Plugin for vCLU
-- Send and receive messages via Telegram Bot API
-- @module plugins.telegram

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local telegram = Plugin:new("telegram", {
    name = "Telegram Notifications",
    version = "2.1.0",
    description = "Telegram Bot - send and receive messages"
})

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

local DEFAULT_API_BASE = "https://api.telegram.org/bot"

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local state = {
    ready = false,
    lastUpdate = 0,
    lastError = nil,
    botUsername = "",
    -- Stats
    messagesSent = 0,
    messagesReceived = 0,
    lastMessageTime = 0
}

local apiBase = DEFAULT_API_BASE
local pollingOffset = 0
local updatePoller = nil

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function apiRequest(method, params, callback)
    local url = apiBase .. telegram.config.botToken .. "/" .. method

    telegram:httpRequest({
        method = "POST",
        url = url,
        form = params,
        timeout = 10000,
        parseJson = "always",
        log = { redact = true }
    }, function(resp)
        if resp.err then
            state.lastError = resp.err
            telegram:log("error", "API error: " .. tostring(resp.err))
            telegram:emit("telegram:error", { error = resp.err, method = method })
            if callback then callback(nil, resp.err) end
            return
        end

        local json = resp.json
        if not json then
            local err = "Invalid JSON response"
            state.lastError = err
            if callback then callback(nil, err) end
            return
        end

        if json.ok then
            if callback then callback(json.result, nil) end
        else
            local err = json.description or "Unknown error"
            state.lastError = err
            telegram:log("error", "Telegram API: " .. err)
            telegram:emit("telegram:error", { error = err, method = method })
            if callback then callback(nil, err) end
        end
    end)
end

local function processUpdate(update)
    if update.message then
        local msg = update.message
        local data = {
            messageId = msg.message_id,
            chatId = msg.chat and msg.chat.id,
            chatType = msg.chat and msg.chat.type,
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

        if msg.text and msg.text:sub(1, 1) == "/" then
            local command = msg.text:match("^(/[%w_]+)")
            local args = msg.text:match("^/[%w_]+%s+(.+)$")
            data.command = command
            data.args = args

            telegram:log("debug", "Command: " .. command .. " from " .. (data.from.username or tostring(data.from.id)))
            telegram:emit("telegram:command", data)
        end

        state.messagesReceived = state.messagesReceived + 1
        telegram:log("debug", "Message from " .. (data.from.username or tostring(data.from.id)) .. ": " .. (msg.text or "[non-text]"):sub(1, 50))
        telegram:emit("telegram:message", data)
    end

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

        telegram:log("debug", "Callback: " .. (cb.data or ""))
        telegram:emit("telegram:callback", data)
    end
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

telegram:onInit(function(config)
    if not config.botToken or config.botToken == "" then
        telegram:log("error", "botToken is required")
        return
    end

    local parseMode = telegram:coerceString(config.defaultParseMode, "HTML")
    local enablePolling = telegram:coerceBool(config.enablePolling, true)
    local pollingInterval = telegram:coerceNumber(config.pollingInterval, 5)

    -- Restore polling offset from persistent storage
    pollingOffset = telegram:kvGet("polling_offset", 0)
    if pollingOffset > 0 then
        telegram:log("info", "Restored polling offset: " .. pollingOffset)
    end

    -- Setup proxy if configured
    if config.proxyUrl and config.proxyUrl ~= "" then
        local proxyBase = config.proxyUrl
        if not proxyBase:match("/$") then
            proxyBase = proxyBase .. "/"
        end
        if not proxyBase:match("/bot$") then
            proxyBase = proxyBase .. "bot"
        end
        apiBase = proxyBase
        telegram:logSafe("info", "Using proxy", { url = config.proxyUrl })
    else
        apiBase = DEFAULT_API_BASE
    end

    telegram:log("info", "Initializing" .. (config.chatId and (" with chat_id: " .. config.chatId) or ""))

    -- Test connection
    apiRequest("getMe", {}, function(result, err)
        if result then
            state.ready = true
            state.botUsername = result.username or ""
            telegram:log("info", "Bot connected: @" .. state.botUsername)

            -- Start polling if enabled
            if enablePolling then
                updatePoller = telegram:poller("updates", {
                    interval = pollingInterval * 1000,
                    immediate = true,
                    timeout = pollingInterval * 1000 + 5000,

                    onTick = function(done)
                        apiRequest("getUpdates", {
                            offset = pollingOffset,
                            timeout = 0,
                            allowed_updates = "message,callback_query"
                        }, function(updates, err)
                            if err then
                                done(err)
                                return
                            end

                            if updates and #updates > 0 then
                                local prevOffset = pollingOffset
                                for _, update in ipairs(updates) do
                                    if update.update_id >= pollingOffset then
                                        pollingOffset = update.update_id + 1
                                    end
                                    local ok, procErr = pcall(processUpdate, update)
                                    if not ok then
                                        telegram:log("error", "Update processing error: " .. tostring(procErr))
                                    end
                                end
                                -- Persist offset if changed
                                if pollingOffset ~= prevOffset then
                                    telegram:kvSet("polling_offset", pollingOffset)
                                end
                            end

                            done()
                        end)
                    end,

                    onError = function(err, stats)
                        telegram:log("warn", "Polling error: " .. tostring(err))
                    end
                })

                updatePoller:start()
                telegram:log("info", "Polling started (interval: " .. pollingInterval .. "s)")
            end
        else
            telegram:log("error", "Failed to connect: " .. tostring(err))
        end
    end)
end)

telegram:onCleanup(function()
    if updatePoller then
        updatePoller:stop()
    end
    telegram:log("info", "Telegram plugin stopped")
end)

--------------------------------------------------------------------------------
-- PUBLIC API - SENDING
--------------------------------------------------------------------------------

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
            state.messagesSent = state.messagesSent + 1
            state.lastMessageTime = os.time()
            telegram:log("debug", "Sent: " .. text:sub(1, 50))
            telegram:emit("telegram:sent", { text = text, messageId = result.message_id })
        end
        if callback then callback(result, err) end
    end)
end

function telegram:sendMessage(text, options, callback)
    self:send(text, options, callback)
end

function telegram:reply(originalMsg, text, callback)
    self:send(text, {
        chatId = originalMsg.chatId,
        replyTo = originalMsg.messageId
    }, callback)
end

function telegram:sendSilent(text, options, callback)
    options = options or {}
    options.silent = true
    self:send(text, options, callback)
end

function telegram:alert(title, message, callback)
    local text = "<b>" .. title .. "</b>\n" .. message
    self:send(text, { parseMode = "HTML" }, callback)
end

function telegram:warning(message, callback)
    self:alert("Warning", message, callback)
end

function telegram:error(message, callback)
    self:alert("Error", message, callback)
end

function telegram:success(message, callback)
    self:alert("Success", message, callback)
end

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
            state.messagesSent = state.messagesSent + 1
            state.lastMessageTime = os.time()
            telegram:emit("telegram:sent", { type = "photo", messageId = result.message_id })
        end
        if callback then callback(result, err) end
    end)
end

function telegram:sendLocation(latitude, longitude, options, callback)
    options = options or {}

    local params = {
        chat_id = options.chatId or self.config.chatId,
        latitude = tostring(latitude),
        longitude = tostring(longitude)
    }

    apiRequest("sendLocation", params, function(result, err)
        if result then
            state.messagesSent = state.messagesSent + 1
            state.lastMessageTime = os.time()
        end
        if callback then callback(result, err) end
    end)
end

function telegram:sendDocument(documentUrl, options, callback)
    options = options or {}

    local params = {
        chat_id = options.chatId or self.config.chatId,
        document = documentUrl,
        caption = options.caption
    }

    apiRequest("sendDocument", params, callback)
end

function telegram:sendTyping(chatId, callback)
    local params = {
        chat_id = chatId or self.config.chatId,
        action = "typing"
    }
    apiRequest("sendChatAction", params, callback)
end

function telegram:answerCallback(callbackId, options, callback)
    options = options or {}

    local params = {
        callback_query_id = callbackId,
        text = options.text,
        show_alert = options.showAlert and "true" or nil
    }

    apiRequest("answerCallbackQuery", params, callback)
end

--------------------------------------------------------------------------------
-- PUBLIC API - POLLING CONTROL
--------------------------------------------------------------------------------

function telegram:startPolling()
    if updatePoller then
        updatePoller:start()
    end
end

function telegram:stopPolling()
    if updatePoller then
        updatePoller:stop()
    end
end

function telegram:isPolling()
    return updatePoller and updatePoller:stats().running or false
end

function telegram:setPollingInterval(seconds)
    if updatePoller then
        updatePoller:stop()
        -- Recreate poller with new interval would require re-init
        telegram:log("warn", "Changing interval requires plugin restart")
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API - INFO
--------------------------------------------------------------------------------

function telegram:getMe(callback)
    apiRequest("getMe", {}, callback)
end

function telegram:isReady()
    return state.ready
end

function telegram:getLastError()
    return state.lastError
end

function telegram:getBotUsername()
    return state.botUsername
end

function telegram:getStats()
    return {
        ready = state.ready,
        messagesSent = state.messagesSent,
        messagesReceived = state.messagesReceived,
        lastMessageTime = state.lastMessageTime,
        lastError = state.lastError,
        pollingEnabled = self:isPolling(),
        botUsername = state.botUsername
    }
end

function telegram:setChatId(chatId)
    self.config.chatId = chatId
end

return telegram
