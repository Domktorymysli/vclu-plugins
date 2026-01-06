--- Weather Plugin for vCLU
-- Fetches weather data from OpenWeatherMap API
-- @module plugins.weather

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local weather = Plugin:new("weather", {
    name = "Weather Plugin",
    version = "2.0.0",
    description = "Weather data from OpenWeatherMap"
})

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local state = {
    ready = false,
    lastUpdate = 0,
    lastError = nil,
    -- Weather data
    temp = 0,
    feelsLike = 0,
    humidity = 0,
    pressure = 0,
    condition = "",
    description = "",
    icon = "",
    windSpeed = 0,
    windDeg = 0,
    clouds = 0,
    rain = 0,
    city = ""
}

local poller = nil

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function parseResponse(json)
    if not json or not json.main then
        return nil, "Invalid response: missing main"
    end

    return {
        temp = weather:coerceNumber(json.main.temp, 0),
        feelsLike = weather:coerceNumber(json.main.feels_like, 0),
        humidity = weather:coerceNumber(json.main.humidity, 0),
        pressure = weather:coerceNumber(json.main.pressure, 0),
        condition = json.weather and json.weather[1] and json.weather[1].main or "Unknown",
        description = json.weather and json.weather[1] and json.weather[1].description or "",
        icon = json.weather and json.weather[1] and json.weather[1].icon or "",
        windSpeed = json.wind and weather:coerceNumber(json.wind.speed, 0) or 0,
        windDeg = json.wind and weather:coerceNumber(json.wind.deg, 0) or 0,
        clouds = json.clouds and weather:coerceNumber(json.clouds.all, 0) or 0,
        rain = json.rain and weather:coerceNumber(json.rain["1h"], 0) or 0,
        city = weather:coerceString(json.name, "")
    }
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

weather:onInit(function(config)
    -- Config validation
    if not config.apiKey or config.apiKey == "" then
        weather:log("error", "apiKey is required")
        return
    end

    local city = weather:coerceString(config.city, "Warsaw")
    local units = weather:coerceString(config.units, "metric")
    local interval = weather:coerceNumber(config.interval, 3600)

    weather:log("info", "Initializing for city: " .. city)

    -- Create initial registry object
    weather:upsertObject("current", {
        ready = false,
        temp = 0,
        humidity = 0,
        condition = "",
        pressure = 0,
        wind = 0,
        rain = 0,
        clouds = 0,
        city = city,
        updated = 0
    })

    -- Create poller
    poller = weather:poller("fetch", {
        interval = interval * 1000,
        immediate = true,
        timeout = 10000,
        retry = { maxAttempts = 3, backoff = 2000 },

        onTick = function(done)
            local url = weather:url("https://api.openweathermap.org/data/2.5/weather", {
                appid = config.apiKey,
                q = city,
                units = units
            })

            weather:httpRequest({
                url = url,
                timeout = 10000,
                parseJson = "success"
            }, function(resp)
                if resp.err then
                    done(resp.err)
                    return
                end

                local data, parseErr = parseResponse(resp.json)
                if not data then
                    done(parseErr or "Parse error")
                    return
                end

                -- Check for significant changes
                local tempChanged = math.abs(state.temp - data.temp) >= 0.5
                local conditionChanged = state.condition ~= data.condition
                local rainStarted = data.rain > 0 and state.rain == 0

                -- Update state
                state.ready = true
                state.lastUpdate = os.time()
                state.lastError = nil
                state.temp = data.temp
                state.feelsLike = data.feelsLike
                state.humidity = data.humidity
                state.pressure = data.pressure
                state.condition = data.condition
                state.description = data.description
                state.icon = data.icon
                state.windSpeed = data.windSpeed
                state.windDeg = data.windDeg
                state.clouds = data.clouds
                state.rain = data.rain
                state.city = data.city

                -- Update registry
                weather:updateObject("current", {
                    ready = true,
                    temp = data.temp,
                    humidity = data.humidity,
                    condition = data.condition,
                    pressure = data.pressure,
                    wind = data.windSpeed,
                    rain = data.rain,
                    clouds = data.clouds,
                    city = data.city,
                    updated = state.lastUpdate
                })

                weather:log("info", string.format(
                    "Weather: %s, %.1f°C, %d%% humidity",
                    data.condition, data.temp, data.humidity
                ))

                -- Emit events with throttling
                if tempChanged or conditionChanged then
                    weather:emit("weather:changed", {
                        temp = data.temp,
                        condition = data.condition,
                        humidity = data.humidity
                    }, { throttle = 60000 })
                end

                if rainStarted then
                    weather:emit("weather:rain", {
                        rain = data.rain,
                        condition = data.condition
                    })
                    weather:log("warn", "Rain alert: " .. data.rain .. " mm/h")
                end

                done()
            end)
        end,

        onError = function(err, stats)
            state.lastError = err
            weather:log("error", "Fetch failed: " .. tostring(err))
            weather:emit("weather:error", { error = err })
        end
    })

    poller:start()
end)

weather:onCleanup(function()
    if poller then
        poller:stop()
    end
    weather:log("info", "Weather plugin stopped")
end)

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

function weather:getTemperature()
    return state.temp
end

function weather:getCondition()
    return state.condition
end

function weather:getHumidity()
    return state.humidity
end

function weather:getWind()
    return state.windSpeed
end

function weather:getFeelsLike()
    return state.feelsLike
end

function weather:getPressure()
    return state.pressure
end

function weather:getClouds()
    return state.clouds
end

function weather:getRain()
    return state.rain
end

function weather:isReady()
    return state.ready
end

function weather:getLastError()
    return state.lastError
end

function weather:getData()
    return {
        ready = state.ready,
        temp = state.temp,
        feelsLike = state.feelsLike,
        humidity = state.humidity,
        pressure = state.pressure,
        condition = state.condition,
        description = state.description,
        windSpeed = state.windSpeed,
        windDeg = state.windDeg,
        clouds = state.clouds,
        rain = state.rain,
        city = state.city,
        lastUpdate = state.lastUpdate,
        lastError = state.lastError
    }
end

function weather:refresh()
    if poller then
        poller:poll()
    end
end

function weather:getStats()
    if poller then
        return poller:stats()
    end
    return {}
end

return weather
