--- Salda Recuperator Plugin for vCLU
-- Integration with Salda heat recovery ventilation system
-- @module plugins.salda-recuperator

local salda = Plugin:new("salda-recuperator", {
    name = "Salda Recuperator",
    version = "1.0.0",
    description = "Salda recuperator integration"
})

-- Internal state
local data = {
    supplyAir = 0,        -- Temperatura nawiewu
    exhaustAir = 0,       -- Temperatura wywiewu
    extractAir = 0,       -- Temperatura wyciągu
    outsideAir = 0,       -- Temperatura zewnętrzna
    humidity = 0,         -- Wilgotność (%)
    supplyFanSpeed = 0,   -- Prędkość wentylatora nawiewu (raw)
    extractFanSpeed = 0,  -- Prędkość wentylatora wyciągu (raw)
    fanSpeed = 0,         -- Prędkość wentylatora (1-4)
    temperature = 0,      -- Temperatura zadana
    lastUpdate = 0,
    error = nil
}

local refreshTimerId = nil

-- ============================================
-- HELPERS
-- ============================================

--- Parse temperature from raw value (divide by 10)
local function parseTemp(raw)
    local num = tonumber(raw)
    if not num then return 0 end
    return math.floor(num / 10 * 100) / 100  -- Round to 2 decimals
end

--- Parse humidity from raw value (divide by 100)
local function parsePercent(raw)
    local num = tonumber(raw)
    if not num then return 0 end
    return math.floor(num) / 100  -- 0.0 - 1.0
end

--- Convert raw fan speed to level (0-4)
local function parseFanSpeed(raw)
    local speed = tonumber(raw) or 0
    if speed == 0 then return 0 end
    if speed == 30 then return 1 end
    if speed == 60 then return 2 end
    if speed == 80 then return 3 end
    if speed >= 100 then return 4 end
    return 0
end

--- Convert fan level (1-4) to raw value for setting
local function fanLevelToRaw(level)
    if level == 0 then return 0 end
    if level == 1 then return 30 end
    if level == 2 then return 60 end
    if level == 3 then return 80 end
    if level == 4 then return 100 end
    return 30  -- default
end

--- Build Basic Auth header
local function buildAuthHeader(login, password)
    -- Base64 encode login:password
    local credentials = login .. ":" .. password
    -- Simple base64 encoding for ASCII
    local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local result = {}
    local pad = (3 - #credentials % 3) % 3
    credentials = credentials .. string.rep("\0", pad)

    for i = 1, #credentials, 3 do
        local a, b, c = credentials:byte(i, i + 2)
        local n = a * 65536 + b * 256 + c
        table.insert(result, b64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1))
        table.insert(result, b64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
        table.insert(result, b64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1))
        table.insert(result, b64:sub(n % 64 + 1, n % 64 + 1))
    end

    local encoded = table.concat(result)
    if pad > 0 then
        encoded = encoded:sub(1, -pad - 1) .. string.rep("=", pad)
    end

    return "Basic " .. encoded
end

--- Make HTTP request to recuperator
local function request(func, callback)
    local config = salda.config
    local url = "http://" .. config.ip .. "/" .. func
    local authHeader = buildAuthHeader(config.login, config.password)

    -- Use plugin's httpRequest with custom headers
    salda:httpRequest({
        method = "GET",
        url = url,
        headers = {
            ["Authorization"] = authHeader
        },
        timeout = 5000
    }, function(response, err)
        if err then
            callback(nil, err)
            return
        end
        if not response or response.status ~= 200 then
            callback(nil, "HTTP " .. tostring(response and response.status or "error"))
            return
        end
        callback(response.body, nil)
    end)
end

--- Parse data response (semicolon-separated values)
local function parseDataResponse(body)
    local parts = {}
    for part in string.gmatch(body, "[^;]+") do
        table.insert(parts, part)
    end
    return parts
end

-- ============================================
-- API FUNCTIONS
-- ============================================

--- Fetch all data from recuperator
local function fetchData(callback)
    request("FUNC(4,1,4,0,24)", function(body, err)
        if err then
            if callback then callback(nil, err) end
            return
        end

        local parts = parseDataResponse(body)
        if #parts < 17 then
            if callback then callback(nil, "Invalid data response") end
            return
        end

        -- Now fetch temperature setpoint
        request("FUNC(4,1,3,0,111)", function(tempBody, tempErr)
            local tempSetpoint = 0
            if not tempErr and tempBody then
                local tempParts = parseDataResponse(tempBody)
                if #tempParts >= 2 then
                    tempSetpoint = tonumber(tempParts[2]) or 0
                end
            end

            local newData = {
                supplyAir = parseTemp(parts[1]),
                exhaustAir = parseTemp(parts[7]),
                extractAir = parseTemp(parts[7]),
                outsideAir = parseTemp(parts[10]),
                humidity = parsePercent(parts[14]),
                supplyFanSpeed = tonumber(parts[16]) or 0,
                extractFanSpeed = tonumber(parts[17]) or 0,
                fanSpeed = parseFanSpeed(parts[16]),
                temperature = tempSetpoint,
                lastUpdate = os.time()
            }

            if callback then callback(newData, nil) end
        end)
    end)
end

--- Update internal data and emit events
local function updateData(newData)
    local changed = data.supplyAir ~= newData.supplyAir or
                    data.outsideAir ~= newData.outsideAir or
                    data.fanSpeed ~= newData.fanSpeed or
                    data.temperature ~= newData.temperature

    -- Update state
    data.supplyAir = newData.supplyAir
    data.exhaustAir = newData.exhaustAir
    data.extractAir = newData.extractAir
    data.outsideAir = newData.outsideAir
    data.humidity = newData.humidity
    data.supplyFanSpeed = newData.supplyFanSpeed
    data.extractFanSpeed = newData.extractFanSpeed
    data.fanSpeed = newData.fanSpeed
    data.temperature = newData.temperature
    data.lastUpdate = newData.lastUpdate
    data.error = nil

    salda:log("info", string.format(
        "Data updated: supply=%.1f°C, outside=%.1f°C, humidity=%.0f%%, fan=%d, setpoint=%d°C",
        data.supplyAir, data.outsideAir, data.humidity * 100, data.fanSpeed, data.temperature
    ))

    -- Update registry
    salda:createObject("data", {
        supplyAir = data.supplyAir,
        exhaustAir = data.exhaustAir,
        extractAir = data.extractAir,
        outsideAir = data.outsideAir,
        humidity = data.humidity,
        fanSpeed = data.fanSpeed,
        temperature = data.temperature,
        lastUpdate = data.lastUpdate
    })

    -- Emit event
    if changed then
        salda:emit("salda:updated", {
            supplyAir = data.supplyAir,
            outsideAir = data.outsideAir,
            humidity = data.humidity,
            fanSpeed = data.fanSpeed,
            temperature = data.temperature
        })
    end
end

--- Refresh data from recuperator
local function refresh()
    fetchData(function(newData, err)
        if err then
            data.error = err
            salda:log("error", "Fetch failed: " .. tostring(err))
            salda:emit("salda:error", { error = err })
            return
        end
        updateData(newData)
    end)
end

-- ============================================
-- INITIALIZATION
-- ============================================

salda:onInit(function(config)
    if not config.ip or config.ip == "" then
        salda:log("error", "IP address is required")
        return
    end

    if not config.login or config.login == "" then
        salda:log("error", "Login is required")
        return
    end

    config.interval = tonumber(config.interval) or 60

    salda:log("info", string.format(
        "Initializing: ip=%s, interval=%ds",
        config.ip,
        config.interval
    ))

    -- Setup refresh timer
    if config.interval > 0 then
        local intervalMs = config.interval * 1000
        refreshTimerId = salda:setInterval(intervalMs, refresh)
    end

    -- Initial fetch after short delay
    salda:setTimeout(2000, refresh)
end)

salda:onCleanup(function()
    if refreshTimerId then
        salda:clearTimer(refreshTimerId)
    end
    salda:log("info", "Salda plugin stopped")
end)

-- ============================================
-- PUBLIC API
-- ============================================

--- Get supply air temperature (nawiew)
function salda:getSupplyAir()
    return data.supplyAir
end

--- Get exhaust air temperature (wywiew)
function salda:getExhaustAir()
    return data.exhaustAir
end

--- Get extract air temperature (wyciąg)
function salda:getExtractAir()
    return data.extractAir
end

--- Get outside air temperature
function salda:getOutsideAir()
    return data.outsideAir
end

--- Get humidity (0.0 - 1.0)
function salda:getHumidity()
    return data.humidity
end

--- Get humidity as percentage (0-100)
function salda:getHumidityPercent()
    return math.floor(data.humidity * 100)
end

--- Get current fan speed level (0-4)
function salda:getFanSpeed()
    return data.fanSpeed
end

--- Get temperature setpoint
function salda:getTemperature()
    return data.temperature
end

--- Get last update timestamp
function salda:getLastUpdate()
    return data.lastUpdate
end

--- Get last error
function salda:getError()
    return data.error
end

--- Get all data
function salda:getData()
    return {
        supplyAir = data.supplyAir,
        exhaustAir = data.exhaustAir,
        extractAir = data.extractAir,
        outsideAir = data.outsideAir,
        humidity = data.humidity,
        humidityPercent = math.floor(data.humidity * 100),
        fanSpeed = data.fanSpeed,
        temperature = data.temperature,
        lastUpdate = data.lastUpdate,
        error = data.error
    }
end

--- Set temperature setpoint
-- @param temp number Temperature in Celsius (15-30)
function salda:setTemperature(temp)
    temp = math.max(15, math.min(30, tonumber(temp) or 22))

    salda:log("info", "Setting temperature to: " .. temp)

    request("FUNC(4,1,6,1," .. temp .. ")", function(body, err)
        if err then
            salda:log("error", "Set temperature failed: " .. tostring(err))
            return
        end

        data.temperature = temp
        salda:log("info", "Temperature set to: " .. temp)

        -- Refresh data after change
        salda:setTimeout(1000, refresh)
    end)
end

--- Set fan speed level
-- @param level number Fan level (0=off, 1=low, 2=medium, 3=high, 4=max)
function salda:setFanSpeed(level)
    level = math.max(0, math.min(4, tonumber(level) or 1))
    local rawSpeed = fanLevelToRaw(level)

    salda:log("info", "Setting fan speed to level " .. level .. " (raw: " .. rawSpeed .. ")")

    request("FUNC(4,1,6,0," .. rawSpeed .. ")", function(body, err)
        if err then
            salda:log("error", "Set fan speed failed: " .. tostring(err))
            return
        end

        data.fanSpeed = level
        salda:log("info", "Fan speed set to level: " .. level)

        -- Refresh data after change
        salda:setTimeout(1000, refresh)
    end)
end

--- Force refresh data
function salda:refresh()
    refresh()
end

return salda
