--- Weather Plugin for vCLU
-- Fetches weather data from OpenWeatherMap API
-- @module plugins.weather

local Plugin = {
    _type = "plugin",
    _id = "weather",
    _version = "1.0.0"
}

-- ============================================
-- LIFECYCLE
-- ============================================

--- Initialize the plugin
-- @param config table Plugin configuration
-- @param api table Plugin API
-- @return boolean Success
function Plugin:init(config, api)
    self.config = config
    self.api = api
    self.data = {}

    -- Validate config
    if not config.apiKey or config.apiKey == "" then
        api.log:error("Weather plugin requires apiKey (set OPENWEATHERMAP_API_KEY env)")
        return false
    end

    -- Register in global registry
    api.registry:register("weather", self)

    -- Setup refresh timer
    local intervalMs = (config.interval or 3600) * 1000
    self.timerId = api.timer:setInterval(function()
        self:refresh()
    end, intervalMs)

    -- Initial fetch
    self:refresh()

    api.log:info("Weather plugin initialized for " .. (config.city or "Warsaw"))
    return true
end

--- Destroy the plugin
function Plugin:destroy()
    if self.timerId then
        self.api.timer:clear(self.timerId)
    end
    self.api.registry:unregister("weather")
    self.api.log:info("Weather plugin destroyed")
end

-- ============================================
-- PUBLIC API
-- ============================================

--- Get current temperature
-- @return number Temperature in configured units
function Plugin:getTemperature()
    return self.data.temp
end

--- Get current weather condition
-- @return string Condition (Clear, Clouds, Rain, Snow, etc.)
function Plugin:getCondition()
    return self.data.condition
end

--- Get current humidity
-- @return number Humidity percentage (0-100)
function Plugin:getHumidity()
    return self.data.humidity
end

--- Get wind speed
-- @return number Wind speed in m/s or mph
function Plugin:getWind()
    return self.data.wind and self.data.wind.speed or 0
end

--- Get feels like temperature
-- @return number Feels like temperature
function Plugin:getFeelsLike()
    return self.data.feels_like
end

--- Get atmospheric pressure
-- @return number Pressure in hPa
function Plugin:getPressure()
    return self.data.pressure
end

--- Get cloud coverage
-- @return number Cloud percentage (0-100)
function Plugin:getClouds()
    return self.data.clouds
end

--- Get rain amount (last hour)
-- @return number Rain in mm
function Plugin:getRain()
    return self.data.rain or 0
end

--- Get all weather data
-- @return table Complete weather data
function Plugin:getData()
    return self.data
end

--- Force refresh weather data
function Plugin:refresh()
    local url = self:_buildUrl()

    self.api.http:get(url, function(response, err)
        if err then
            self.api.log:error("Weather fetch failed: " .. tostring(err))
            return
        end

        if response.status ~= 200 then
            self.api.log:error("Weather API error: " .. tostring(response.status))
            return
        end

        local ok, newData = pcall(function()
            return self:_parseResponse(response.body)
        end)

        if ok and newData then
            self:_processData(newData)
        else
            self.api.log:error("Failed to parse weather data")
        end
    end)
end

-- ============================================
-- PRIVATE METHODS
-- ============================================

function Plugin:_buildUrl()
    local base = "https://api.openweathermap.org/data/2.5/weather"
    local params = {
        "appid=" .. self.config.apiKey,
        "units=" .. (self.config.units or "metric"),
        "q=" .. (self.config.city or "Warsaw")
    }
    return base .. "?" .. table.concat(params, "&")
end

function Plugin:_parseResponse(body)
    local data = self.api.json:decode(body)

    if not data or not data.main then
        return nil
    end

    return {
        temp = data.main.temp,
        feels_like = data.main.feels_like,
        humidity = data.main.humidity,
        pressure = data.main.pressure,
        condition = data.weather and data.weather[1] and data.weather[1].main or "Unknown",
        description = data.weather and data.weather[1] and data.weather[1].description or "",
        icon = data.weather and data.weather[1] and data.weather[1].icon or "",
        wind = {
            speed = data.wind and data.wind.speed or 0,
            deg = data.wind and data.wind.deg or 0
        },
        clouds = data.clouds and data.clouds.all or 0,
        rain = data.rain and data.rain["1h"] or 0,
        timestamp = os.time(),
        city = data.name
    }
end

function Plugin:_processData(newData)
    local oldData = self.data
    self.data = newData

    self.api.log:info(string.format(
        "Weather updated: %s, %.1f°C, %d%% humidity",
        newData.condition,
        newData.temp,
        newData.humidity
    ))

    -- Emit change event
    if oldData.temp ~= newData.temp or oldData.condition ~= newData.condition then
        self.api.events:emit("weather.OnWeatherChange", {
            temp = newData.temp,
            condition = newData.condition,
            humidity = newData.humidity
        })
    end

    -- Rain alert
    if newData.rain > 0 and (not oldData.rain or oldData.rain == 0) then
        self.api.events:emit("weather.OnRainAlert", {
            rain = newData.rain,
            condition = newData.condition
        })
        self.api.log:warn("Rain alert: " .. newData.rain .. " mm/h")
    end
end

return Plugin
