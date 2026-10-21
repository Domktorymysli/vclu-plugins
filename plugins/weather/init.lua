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

-- Forecast: fetched only once someone asks for it, then every 30 minutes.
local FORECAST_INTERVAL = 30 * 60
local forecast = nil
local forecastPoller = nil
local settings = nil

--------------------------------------------------------------------------------
-- ICONS
--------------------------------------------------------------------------------

--- Bootstrap Icons name for an OWM condition id; night variants for clear sky.
local function iconFor(id, night)
    id = tonumber(id) or 0
    if id >= 200 and id < 300 then
        if id >= 210 and id <= 221 then return "cloud-lightning" end
        return "cloud-lightning-rain"
    elseif id >= 300 and id < 400 then return "cloud-drizzle"
    elseif id == 511 or (id >= 611 and id <= 616) then return "cloud-sleet"
    elseif id >= 502 and id <= 504 or id == 522 then return "cloud-rain-heavy"
    elseif id >= 500 and id < 600 then return "cloud-rain"
    elseif id >= 600 and id < 700 then return "cloud-snow"
    elseif id == 701 or id == 741 then return "cloud-fog2"
    elseif id == 771 then return "wind"
    elseif id == 781 then return "tornado"
    elseif id >= 700 and id < 800 then return "cloud-haze2"
    elseif id == 800 then return night and "moon" or "sun"
    elseif id == 801 or id == 802 then return night and "cloud-moon" or "cloud-sun"
    elseif id == 804 then return "clouds"
    end
    return "cloud"
end

-- How much a step should win the day's icon over the midday one. Rain or snow
-- counts only when likely and not trace (pop >= 0.4, >= 0.3 mm); thunder always.
local function severity(id, pop, rain)
    id = tonumber(id) or 0
    if id >= 200 and id < 300 then return 5 end
    if pop < 0.4 or rain < 0.3 then return 0 end
    if (id >= 600 and id < 700) or id == 511 or (id >= 502 and id <= 504) or id == 522 then return 4 end
    if id >= 500 and id < 600 then return 3 end
    if id >= 300 and id < 400 then return 2 end
    return 0
end

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function round(x, places)
    local m = 10 ^ (places or 0)
    return math.floor(x * m + 0.5) / m
end

local function precip(t)
    return t and tonumber(t["3h"]) or 0
end

--- Local date ("YYYY-MM-DD") and hour of a timestamp. The house's zone from
-- datetime.setTimezone when the runtime gives plugins datetime; else the
-- city's UTC offset from OWM, which is fixed and misses a DST change.
local function localTime(ts, offset)
    if datetime and datetime.timezone and datetime.timezone() ~= "" then
        local t = datetime.fromTimestamp(ts)
        return t.date, t.hour
    end
    local t = os.date("!*t", math.floor(ts + (offset or 0)))
    return string.format("%04d-%02d-%02d", t.year, t.month, t.day), t.hour
end

--- /data/2.5/forecast (3 h steps) -> { days, hours, updated }.
local function parseForecast(json)
    if not json or type(json.list) ~= "table" then
        return nil, "Invalid response: missing list"
    end
    local offset = json.city and tonumber(json.city.timezone) or 0
    local days, hours, byDate = {}, {}, {}

    for _, step in ipairs(json.list) do
        local ts = tonumber(step.dt)
        local temp = step.main and tonumber(step.main.temp)
        if ts and temp then
            local w = step.weather and step.weather[1] or {}
            local rain = precip(step.rain) + precip(step.snow)
            hours[#hours + 1] = {
                at = ts, temp = temp, rain = rain,
                icon = iconFor(w.id, step.sys and step.sys.pod == "n")
            }

            local date, hour = localTime(ts, offset)
            local day = byDate[date]
            if not day then
                day = { date = date, min = temp, max = temp, rain = 0, pop = 0 }
                byDate[date] = day
                days[#days + 1] = day
            end
            day.min = math.min(day.min, temp)
            day.max = math.max(day.max, temp)
            day.rain = day.rain + rain
            local pop = tonumber(step.pop) or 0
            day.pop = math.max(day.pop, pop)

            -- Icon: a daytime step first, the worst weather, then nearest noon.
            local rank = ((hour >= 6 and hour <= 20) and 1000 or 0)
                + severity(w.id, pop, rain) * 100 - math.abs(hour - 12)
            if not day._rank or rank > day._rank then
                day._rank = rank
                day.icon = iconFor(w.id, false)
            end
        end
    end

    for _, day in ipairs(days) do
        day._rank = nil
        day.rain = round(day.rain, 2)
    end
    return { days = days, hours = hours, updated = os.time() }
end

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
        icon = json.weather and json.weather[1] and iconFor(json.weather[1].id,
            tostring(json.weather[1].icon or ""):sub(-1) == "n") or "",
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
    settings = { apiKey = config.apiKey, city = city, units = units }

    -- Create initial registry object
    weather:upsertObject("current", {
        ready = false,
        temp = 0,
        humidity = 0,
        condition = "",
        icon = "",
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
                    done(nil, resp.err)
                    return
                end

                local data, parseErr = parseResponse(resp.json)
                if not data then
                    done(nil, parseErr or "Parse error")
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
                    icon = data.icon,
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
    if forecastPoller then
        forecastPoller:stop()
        forecastPoller = nil
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
        icon = state.icon,
        windSpeed = state.windSpeed,
        windDeg = state.windDeg,
        clouds = state.clouds,
        rain = state.rain,
        city = state.city,
        lastUpdate = state.lastUpdate,
        lastError = state.lastError
    }
end

local function startForecast()
    if forecastPoller or not settings then return end
    forecastPoller = weather:poller("forecast", {
        interval = FORECAST_INTERVAL * 1000,
        immediate = true,
        timeout = 10000,
        retry = { maxAttempts = 3, backoff = 2000 },

        onTick = function(done)
            local url = weather:url("https://api.openweathermap.org/data/2.5/forecast", {
                appid = settings.apiKey,
                q = settings.city,
                units = settings.units
            })
            weather:httpRequest({ url = url, timeout = 10000, parseJson = "success" }, function(resp)
                if resp.err then
                    done(nil, resp.err)
                    return
                end
                local data, parseErr = parseForecast(resp.json)
                if not data then
                    done(nil, parseErr or "Parse error")
                    return
                end
                forecast = data
                done()
            end)
        end,

        onError = function(err)
            weather:log("error", "Forecast fetch failed: " .. tostring(err))
        end
    })
    forecastPoller:start()
end

--- 5-day forecast, nil until the first fetch. The first call starts fetching.
function weather:getForecast()
    startForecast()
    return forecast
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
