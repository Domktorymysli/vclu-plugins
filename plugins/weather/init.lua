--- Weather Plugin for vCLU
-- Fetches weather data from OpenWeatherMap API
-- @module plugins.weather

-- Create plugin instance using Plugin API
local weather = Plugin:new("weather", {
    name = "Weather Plugin",
    version = "1.0.0",
    description = "Weather data from OpenWeatherMap"
})

-- Internal data storage
local data = {}
local refreshTimerId = nil

-- ============================================
-- PRIVATE METHODS
-- ============================================

local function buildUrl(config)
    local base = "https://api.openweathermap.org/data/2.5/weather"
    local params = {
        "appid=" .. (config.apiKey or ""),
        "units=" .. (config.units or "metric"),
        "q=" .. (config.city or "Warsaw")
    }
    return base .. "?" .. table.concat(params, "&")
end

local function parseResponse(body)
    local jsonData = JSON:decode(body)

    if not jsonData or not jsonData.main then
        return nil
    end

    return {
        temp = jsonData.main.temp,
        feels_like = jsonData.main.feels_like,
        humidity = jsonData.main.humidity,
        pressure = jsonData.main.pressure,
        condition = jsonData.weather and jsonData.weather[1] and jsonData.weather[1].main or "Unknown",
        description = jsonData.weather and jsonData.weather[1] and jsonData.weather[1].description or "",
        icon = jsonData.weather and jsonData.weather[1] and jsonData.weather[1].icon or "",
        wind = {
            speed = jsonData.wind and jsonData.wind.speed or 0,
            deg = jsonData.wind and jsonData.wind.deg or 0
        },
        clouds = jsonData.clouds and jsonData.clouds.all or 0,
        rain = jsonData.rain and jsonData.rain["1h"] or 0,
        timestamp = os.time(),
        city = jsonData.name
    }
end

local function processData(newData)
    local oldData = data
    data = newData

    weather:log("info", string.format(
        "Weather updated: %s, %.1f deg, %d%% humidity",
        newData.condition,
        newData.temp,
        newData.humidity
    ))

    -- Emit change event
    if oldData.temp ~= newData.temp or oldData.condition ~= newData.condition then
        weather:emit("weather:changed", {
            temp = newData.temp,
            condition = newData.condition,
            humidity = newData.humidity
        })
    end

    -- Rain alert
    if newData.rain > 0 and (not oldData.rain or oldData.rain == 0) then
        weather:emit("weather:rain", {
            rain = newData.rain,
            condition = newData.condition
        })
        weather:log("warn", "Rain alert: " .. newData.rain .. " mm/h")
    end

    -- Create/update registry object
    weather:createObject("current", {
        temp = newData.temp,
        humidity = newData.humidity,
        condition = newData.condition,
        pressure = newData.pressure,
        wind = newData.wind.speed,
        rain = newData.rain,
        clouds = newData.clouds,
        city = newData.city,
        updated = newData.timestamp
    })
end

local function refresh()
    local config = weather.config
    local url = buildUrl(config)

    weather:log("debug", "Fetching weather from: " .. url)

    -- Use plugin's httpGet API (async with callback)
    weather:httpGet(url, function(response, err)
        if err then
            weather:log("error", "Weather fetch failed: " .. tostring(err))
            return
        end

        if not response or response.status ~= 200 then
            weather:log("error", "Weather API error: " .. tostring(response and response.status or "no response"))
            return
        end

        local ok, newData = pcall(function()
            return parseResponse(response.body)
        end)

        if ok and newData then
            processData(newData)
        else
            weather:log("error", "Failed to parse weather data")
        end
    end)
end

-- ============================================
-- INITIALIZATION
-- ============================================

weather:onInit(function(config)
    -- Validate config
    if not config.apiKey or config.apiKey == "" then
        weather:log("error", "Weather plugin requires apiKey configuration")
        return
    end

    weather:log("info", "Initializing for city: " .. (config.city or "Warsaw"))

    -- Setup refresh timer (default: every hour)
    local intervalMs = (config.interval or 3600) * 1000
    refreshTimerId = weather:setInterval(intervalMs, refresh)

    -- Initial fetch after short delay
    weather:setTimeout(1000, refresh)
end)

weather:onCleanup(function()
    if refreshTimerId then
        weather:clearTimer(refreshTimerId)
    end
    weather:log("info", "Weather plugin stopped")
end)

-- ============================================
-- PUBLIC API (accessible via Plugin.get("weather"))
-- ============================================

--- Get current temperature
function weather:getTemperature()
    return data.temp
end

--- Get current weather condition
function weather:getCondition()
    return data.condition
end

--- Get current humidity
function weather:getHumidity()
    return data.humidity
end

--- Get wind speed
function weather:getWind()
    return data.wind and data.wind.speed or 0
end

--- Get feels like temperature
function weather:getFeelsLike()
    return data.feels_like
end

--- Get atmospheric pressure
function weather:getPressure()
    return data.pressure
end

--- Get cloud coverage
function weather:getClouds()
    return data.clouds
end

--- Get rain amount (last hour)
function weather:getRain()
    return data.rain or 0
end

--- Get all weather data
function weather:getData()
    return data
end

--- Force refresh weather data
function weather:refresh()
    refresh()
end

return weather
