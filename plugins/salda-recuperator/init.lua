--- Salda Recuperator Plugin for vCLU
-- Integration with Salda heat recovery ventilation system
-- @module plugins.salda-recuperator

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local salda = Plugin:new("salda-recuperator", {
    name = "Salda Recuperator",
    version = "2.0.0",
    description = "Salda recuperator integration"
})

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local state = {
    ready = false,
    lastUpdate = 0,
    lastError = nil,
    -- Temperatures
    supplyAir = 0,
    exhaustAir = 0,
    extractAir = 0,
    outsideAir = 0,
    -- Other
    humidity = 0,
    supplyFanSpeed = 0,
    extractFanSpeed = 0,
    fanSpeed = 0,
    temperature = 0
}

local poller = nil
local authHeader = nil

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function parseTemp(raw)
    local num = tonumber(raw)
    if not num then return 0 end
    return math.floor(num / 10 * 100) / 100
end

local function parsePercent(raw)
    local num = tonumber(raw)
    if not num then return 0 end
    return math.floor(num) / 100
end

local function parseFanSpeed(raw)
    local speed = tonumber(raw) or 0
    if speed == 0 then return 0 end
    if speed == 30 then return 1 end
    if speed == 60 then return 2 end
    if speed == 80 then return 3 end
    if speed >= 100 then return 4 end
    return 0
end

local function fanLevelToRaw(level)
    if level == 0 then return 0 end
    if level == 1 then return 30 end
    if level == 2 then return 60 end
    if level == 3 then return 80 end
    if level == 4 then return 100 end
    return 30
end

local function normalizeIp(ip)
    ip = ip:gsub("^https?://", "")
    ip = ip:gsub("/$", "")
    return ip
end

local function parseDataResponse(body)
    local parts = {}
    for part in string.gmatch(body, "[^;]+") do
        table.insert(parts, part)
    end
    return parts
end

local function request(func, callback)
    local config = salda.config
    local ip = normalizeIp(config.ip)
    local url = "http://" .. ip .. "/" .. func

    salda:httpRequest({
        method = "GET",
        url = url,
        headers = { ["Authorization"] = authHeader },
        timeout = 5000,
        log = { redact = true }
    }, function(resp)
        if resp.err then
            callback(nil, resp.err)
            return
        end
        if resp.status ~= 200 then
            callback(nil, "HTTP " .. tostring(resp.status))
            return
        end
        callback(resp.body, nil)
    end)
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

salda:onInit(function(config)
    if not config.ip or config.ip == "" then
        salda:log("error", "ip is required")
        return
    end
    if not config.login or config.login == "" then
        salda:log("error", "login is required")
        return
    end

    local interval = salda:coerceNumber(config.interval, 60)
    local password = salda:coerceString(config.password, "")

    -- Build auth header
    authHeader = salda:basicAuth(config.login, password)

    salda:log("info", string.format("Initializing: ip=%s, interval=%ds", config.ip, interval))

    -- Create initial registry object
    salda:upsertObject("data", {
        ready = false,
        supplyAir = 0,
        exhaustAir = 0,
        extractAir = 0,
        outsideAir = 0,
        humidity = 0,
        fanSpeed = 0,
        temperature = 0,
        lastUpdate = 0
    })

    -- Create poller
    poller = salda:poller("fetch", {
        interval = interval * 1000,
        immediate = true,
        timeout = 15000,
        retry = { maxAttempts = 2, backoff = 2000 },

        onTick = function(done)
            -- Fetch main data
            request("FUNC(4,1,4,0,24)", function(body, err)
                if err then
                    done(err)
                    return
                end

                local parts = parseDataResponse(body)
                if #parts < 17 then
                    done("Invalid data response")
                    return
                end

                -- Fetch temperature setpoint
                request("FUNC(4,1,3,0,111)", function(tempBody, tempErr)
                    local tempSetpoint = 0
                    if not tempErr and tempBody then
                        local tempParts = parseDataResponse(tempBody)
                        if #tempParts >= 2 then
                            tempSetpoint = tonumber(tempParts[2]) or 0
                        end
                    end

                    local data = {
                        supplyAir = parseTemp(parts[1]),
                        exhaustAir = parseTemp(parts[7]),
                        extractAir = parseTemp(parts[7]),
                        outsideAir = parseTemp(parts[10]),
                        humidity = parsePercent(parts[14]),
                        supplyFanSpeed = tonumber(parts[16]) or 0,
                        extractFanSpeed = tonumber(parts[17]) or 0,
                        fanSpeed = parseFanSpeed(parts[16]),
                        temperature = tempSetpoint
                    }

                    -- Check for changes
                    local changed = state.supplyAir ~= data.supplyAir or
                                    state.outsideAir ~= data.outsideAir or
                                    state.fanSpeed ~= data.fanSpeed or
                                    state.temperature ~= data.temperature

                    -- Update state
                    state.ready = true
                    state.lastUpdate = os.time()
                    state.lastError = nil
                    state.supplyAir = data.supplyAir
                    state.exhaustAir = data.exhaustAir
                    state.extractAir = data.extractAir
                    state.outsideAir = data.outsideAir
                    state.humidity = data.humidity
                    state.supplyFanSpeed = data.supplyFanSpeed
                    state.extractFanSpeed = data.extractFanSpeed
                    state.fanSpeed = data.fanSpeed
                    state.temperature = data.temperature

                    -- Update registry
                    salda:updateObject("data", {
                        ready = true,
                        supplyAir = data.supplyAir,
                        exhaustAir = data.exhaustAir,
                        extractAir = data.extractAir,
                        outsideAir = data.outsideAir,
                        humidity = data.humidity,
                        fanSpeed = data.fanSpeed,
                        temperature = data.temperature,
                        lastUpdate = state.lastUpdate
                    })

                    salda:log("info", string.format(
                        "Data: supply=%.1f°C, outside=%.1f°C, humidity=%.0f%%, fan=%d, setpoint=%d°C",
                        data.supplyAir, data.outsideAir, data.humidity * 100, data.fanSpeed, data.temperature
                    ))

                    -- Emit event
                    if changed then
                        salda:emit("salda:updated", {
                            supplyAir = data.supplyAir,
                            outsideAir = data.outsideAir,
                            humidity = data.humidity,
                            fanSpeed = data.fanSpeed,
                            temperature = data.temperature
                        }, { throttle = 30000 })
                    end

                    done()
                end)
            end)
        end,

        onError = function(err, stats)
            state.lastError = err
            salda:log("error", "Fetch failed: " .. tostring(err))
            salda:emit("salda:error", { error = err })
        end
    })

    poller:start()
end)

salda:onCleanup(function()
    if poller then
        poller:stop()
    end
    salda:log("info", "Salda plugin stopped")
end)

--------------------------------------------------------------------------------
-- PUBLIC API - GETTERS
--------------------------------------------------------------------------------

function salda:getSupplyAir()
    return state.supplyAir
end

function salda:getExhaustAir()
    return state.exhaustAir
end

function salda:getExtractAir()
    return state.extractAir
end

function salda:getOutsideAir()
    return state.outsideAir
end

function salda:getHumidity()
    return state.humidity
end

function salda:getHumidityPercent()
    return math.floor(state.humidity * 100)
end

function salda:getFanSpeed()
    return state.fanSpeed
end

function salda:getTemperature()
    return state.temperature
end

function salda:getLastUpdate()
    return state.lastUpdate
end

function salda:isReady()
    return state.ready
end

function salda:getLastError()
    return state.lastError
end

function salda:getData()
    return {
        ready = state.ready,
        supplyAir = state.supplyAir,
        exhaustAir = state.exhaustAir,
        extractAir = state.extractAir,
        outsideAir = state.outsideAir,
        humidity = state.humidity,
        humidityPercent = math.floor(state.humidity * 100),
        fanSpeed = state.fanSpeed,
        temperature = state.temperature,
        lastUpdate = state.lastUpdate,
        lastError = state.lastError
    }
end

--------------------------------------------------------------------------------
-- PUBLIC API - SETTERS
--------------------------------------------------------------------------------

function salda:setTemperature(temp)
    temp = math.max(15, math.min(30, salda:coerceNumber(temp, 22)))

    salda:log("info", "Setting temperature to: " .. temp)

    request("FUNC(4,1,6,1," .. temp .. ")", function(body, err)
        if err then
            salda:log("error", "Set temperature failed: " .. tostring(err))
            return
        end

        state.temperature = temp
        salda:log("info", "Temperature set to: " .. temp)

        -- Refresh after change
        if poller then
            salda:setTimeout(1000, function()
                poller:poll()
            end)
        end
    end)
end

function salda:setFanSpeed(level)
    level = math.max(0, math.min(4, salda:coerceNumber(level, 1)))
    local rawSpeed = fanLevelToRaw(level)

    salda:log("info", "Setting fan speed to level " .. level .. " (raw: " .. rawSpeed .. ")")

    request("FUNC(4,1,6,0," .. rawSpeed .. ")", function(body, err)
        if err then
            salda:log("error", "Set fan speed failed: " .. tostring(err))
            return
        end

        state.fanSpeed = level
        salda:log("info", "Fan speed set to level: " .. level)

        -- Refresh after change
        if poller then
            salda:setTimeout(1000, function()
                poller:poll()
            end)
        end
    end)
end

function salda:refresh()
    if poller then
        poller:poll()
    end
end

function salda:getStats()
    if poller then
        return poller:stats()
    end
    return {}
end

return salda
