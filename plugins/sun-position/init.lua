--- Sun Position & Astronomy Plugin for vCLU
-- Calculates sun position, sunrise/sunset times, and moon phases
-- @module plugins.sun-position

local sun = Plugin:new("sun-position", {
    name = "Sun Position & Astronomy",
    version = "1.0.0",
    description = "Sun position, sunrise/sunset, moon phases"
})

-- ============================================
-- CONSTANTS
-- ============================================

local RAD = math.pi / 180
local DEG = 180 / math.pi
local ZENITH = 90.833  -- Official zenith for sunrise/sunset (includes refraction)

-- ============================================
-- INTERNAL STATE
-- ============================================

local data = {
    -- Sun times (minutes from midnight, local time)
    sunrise = 0,
    sunset = 0,
    solarNoon = 0,
    dayLength = 0,      -- minutes

    -- Sun times as HH:MM strings
    sunriseTime = "00:00",
    sunsetTime = "00:00",
    solarNoonTime = "00:00",

    -- Sun position
    azimuth = 0,        -- degrees from North (0-360)
    elevation = 0,      -- degrees above horizon (-90 to 90)
    zenith = 0,         -- degrees from zenith (0-180)

    -- Day/night
    isDaytime = false,
    isTwilight = false, -- Civil twilight

    -- Moon
    moonPhase = 0,          -- 0-1 (0=new, 0.5=full)
    moonPhaseName = "",     -- "New Moon", "Full Moon", etc.
    moonIllumination = 0,   -- 0-100%
    moonAge = 0,            -- Days since new moon

    -- Meta
    lastCalculation = 0,
    latitude = 0,
    longitude = 0
}

local timers = {
    update = nil,
    sunrise = nil,
    sunset = nil,
    noon = nil
}

-- ============================================
-- ASTRONOMICAL CALCULATIONS
-- ============================================

--- Calculate Julian Day from Unix timestamp
local function toJulianDay(timestamp)
    return (timestamp / 86400) + 2440587.5
end

--- Calculate day of year (1-366)
local function dayOfYear(timestamp)
    local t = os.date("*t", timestamp)
    local jan1 = os.time({year = t.year, month = 1, day = 1, hour = 0})
    return math.floor((timestamp - jan1) / 86400) + 1
end

--- Calculate sunrise/sunset times
-- Based on NOAA Solar Calculator algorithms
-- @param lat Latitude in degrees
-- @param lon Longitude in degrees
-- @param timestamp Unix timestamp
-- @param tzOffset Timezone offset in hours
-- @return sunrise, sunset, solarNoon (minutes from midnight)
local function calculateSunTimes(lat, lon, timestamp, tzOffset)
    local t = os.date("*t", timestamp)
    local doy = dayOfYear(timestamp)

    -- Fractional year (radians)
    local gamma = (2 * math.pi / 365) * (doy - 1 + (t.hour - 12) / 24)

    -- Equation of time (minutes)
    local eqTime = 229.18 * (0.000075 + 0.001868 * math.cos(gamma)
        - 0.032077 * math.sin(gamma)
        - 0.014615 * math.cos(2 * gamma)
        - 0.040849 * math.sin(2 * gamma))

    -- Solar declination (radians)
    local decl = 0.006918 - 0.399912 * math.cos(gamma)
        + 0.070257 * math.sin(gamma)
        - 0.006758 * math.cos(2 * gamma)
        + 0.000907 * math.sin(2 * gamma)
        - 0.002697 * math.cos(3 * gamma)
        + 0.00148 * math.sin(3 * gamma)

    -- Hour angle for sunrise/sunset
    local latRad = lat * RAD
    local cosHA = (math.cos(ZENITH * RAD) / (math.cos(latRad) * math.cos(decl)))
        - math.tan(latRad) * math.tan(decl)

    -- Check for polar day/night
    if cosHA > 1 then
        -- Polar night - sun never rises
        return nil, nil, 720  -- Return noon only
    elseif cosHA < -1 then
        -- Polar day - sun never sets
        return 0, 1440, 720
    end

    local haRad = math.acos(cosHA)
    local haDeg = haRad * DEG

    -- Solar noon (minutes from midnight, local time)
    local solarNoon = 720 - (4 * lon) - eqTime + (tzOffset * 60)

    -- Sunrise and sunset
    local sunrise = solarNoon - (haDeg * 4)
    local sunset = solarNoon + (haDeg * 4)

    return sunrise, sunset, solarNoon
end

--- Calculate current sun position (azimuth and elevation)
-- @param lat Latitude in degrees
-- @param lon Longitude in degrees
-- @param timestamp Unix timestamp
-- @param tzOffset Timezone offset in hours
-- @return azimuth (0-360), elevation (-90 to 90)
local function calculateSunPosition(lat, lon, timestamp, tzOffset)
    local t = os.date("*t", timestamp)
    local doy = dayOfYear(timestamp)

    -- Fractional year (radians)
    local gamma = (2 * math.pi / 365) * (doy - 1 + (t.hour - 12) / 24)

    -- Equation of time (minutes)
    local eqTime = 229.18 * (0.000075 + 0.001868 * math.cos(gamma)
        - 0.032077 * math.sin(gamma)
        - 0.014615 * math.cos(2 * gamma)
        - 0.040849 * math.sin(2 * gamma))

    -- Solar declination (radians)
    local decl = 0.006918 - 0.399912 * math.cos(gamma)
        + 0.070257 * math.sin(gamma)
        - 0.006758 * math.cos(2 * gamma)
        + 0.000907 * math.sin(2 * gamma)
        - 0.002697 * math.cos(3 * gamma)
        + 0.00148 * math.sin(3 * gamma)

    -- Time offset (minutes)
    local timeOffset = eqTime + (4 * lon) - (60 * tzOffset)

    -- True solar time (minutes)
    local tst = t.hour * 60 + t.min + t.sec / 60 + timeOffset

    -- Solar hour angle (degrees)
    local ha = (tst / 4) - 180

    -- Convert to radians
    local latRad = lat * RAD
    local haRad = ha * RAD

    -- Solar zenith angle
    local cosZenith = math.sin(latRad) * math.sin(decl)
        + math.cos(latRad) * math.cos(decl) * math.cos(haRad)
    local zenithRad = math.acos(math.max(-1, math.min(1, cosZenith)))
    local zenith = zenithRad * DEG

    -- Solar elevation
    local elevation = 90 - zenith

    -- Solar azimuth
    local azimuth
    if cosZenith > 0.99999 then
        azimuth = 180  -- Sun at zenith
    else
        local cosAzimuth = (math.sin(latRad) * cosZenith - math.sin(decl))
            / (math.cos(latRad) * math.sin(zenithRad))
        cosAzimuth = math.max(-1, math.min(1, cosAzimuth))
        azimuth = math.acos(cosAzimuth) * DEG

        if ha > 0 then
            azimuth = 360 - azimuth
        end
    end

    return azimuth, elevation
end

--- Calculate moon phase
-- @param timestamp Unix timestamp
-- @return phase (0-1), illumination (0-100), age (days), phaseName
local function calculateMoonPhase(timestamp)
    -- Synodic month = 29.53058867 days
    local SYNODIC_MONTH = 29.53058867

    -- Known new moon: January 6, 2000, 18:14 UTC
    local KNOWN_NEW_MOON = 947182440

    -- Days since known new moon
    local daysSinceNew = (timestamp - KNOWN_NEW_MOON) / 86400

    -- Current position in cycle (0-1)
    local phase = (daysSinceNew % SYNODIC_MONTH) / SYNODIC_MONTH

    -- Age in days
    local age = phase * SYNODIC_MONTH

    -- Illumination (approximate, using cosine)
    local illumination = (1 - math.cos(phase * 2 * math.pi)) / 2 * 100

    -- Phase name
    local phaseName
    if phase < 0.0625 then
        phaseName = "New Moon"
    elseif phase < 0.1875 then
        phaseName = "Waxing Crescent"
    elseif phase < 0.3125 then
        phaseName = "First Quarter"
    elseif phase < 0.4375 then
        phaseName = "Waxing Gibbous"
    elseif phase < 0.5625 then
        phaseName = "Full Moon"
    elseif phase < 0.6875 then
        phaseName = "Waning Gibbous"
    elseif phase < 0.8125 then
        phaseName = "Last Quarter"
    elseif phase < 0.9375 then
        phaseName = "Waning Crescent"
    else
        phaseName = "New Moon"
    end

    return phase, illumination, age, phaseName
end

--- Format minutes from midnight to HH:MM string
local function minutesToTime(minutes)
    if not minutes then return "--:--" end
    minutes = math.floor(minutes + 0.5)
    if minutes < 0 then minutes = minutes + 1440 end
    if minutes >= 1440 then minutes = minutes - 1440 end
    local h = math.floor(minutes / 60)
    local m = minutes % 60
    return string.format("%02d:%02d", h, m)
end

--- Get current minutes from midnight
local function currentMinutes()
    local t = os.date("*t")
    return t.hour * 60 + t.min
end

-- ============================================
-- UPDATE FUNCTIONS
-- ============================================

--- Update all calculations
local function updateCalculations()
    local config = sun.config
    local now = os.time()

    data.latitude = config.latitude
    data.longitude = config.longitude

    -- Calculate sun times
    local sunrise, sunset, solarNoon = calculateSunTimes(
        config.latitude, config.longitude, now, config.timezoneOffset or 1
    )

    if sunrise then
        data.sunrise = sunrise
        data.sunset = sunset
        data.solarNoon = solarNoon
        data.dayLength = sunset - sunrise
        data.sunriseTime = minutesToTime(sunrise)
        data.sunsetTime = minutesToTime(sunset)
        data.solarNoonTime = minutesToTime(solarNoon)
    end

    -- Calculate sun position
    local azimuth, elevation = calculateSunPosition(
        config.latitude, config.longitude, now, config.timezoneOffset or 1
    )
    data.azimuth = math.floor(azimuth * 10) / 10
    data.elevation = math.floor(elevation * 10) / 10
    data.zenith = 90 - data.elevation

    -- Day/night status
    local nowMins = currentMinutes()
    data.isDaytime = sunrise and sunset and nowMins >= sunrise and nowMins < sunset
    data.isTwilight = elevation >= -6 and elevation < 0

    -- Calculate moon phase
    local phase, illum, age, phaseName = calculateMoonPhase(now)
    data.moonPhase = math.floor(phase * 1000) / 1000
    data.moonIllumination = math.floor(illum)
    data.moonAge = math.floor(age * 10) / 10
    data.moonPhaseName = phaseName

    data.lastCalculation = now

    -- Update registry
    sun:createObject("sun", {
        sunrise = data.sunriseTime,
        sunset = data.sunsetTime,
        solarNoon = data.solarNoonTime,
        dayLength = math.floor(data.dayLength),
        azimuth = data.azimuth,
        elevation = data.elevation,
        isDaytime = data.isDaytime
    })

    sun:createObject("moon", {
        phase = data.moonPhase,
        phaseName = data.moonPhaseName,
        illumination = data.moonIllumination,
        age = data.moonAge
    })

    -- Emit position update
    sun:emit("sun:position", {
        azimuth = data.azimuth,
        elevation = data.elevation,
        isDaytime = data.isDaytime
    })
end

--- Schedule sunrise/sunset events for today
local function scheduleEvents()
    local config = sun.config
    local t = os.date("*t")
    local nowMins = currentMinutes()

    local sunriseOffset = tonumber(config.sunriseOffset) or 0
    local sunsetOffset = tonumber(config.sunsetOffset) or 0

    -- Clear existing timers
    if timers.sunrise then sun:clearTimer(timers.sunrise) end
    if timers.sunset then sun:clearTimer(timers.sunset) end
    if timers.noon then sun:clearTimer(timers.noon) end

    -- Schedule sunrise event
    if data.sunrise then
        local sunriseMins = data.sunrise + sunriseOffset
        if sunriseMins > nowMins then
            local delayMs = (sunriseMins - nowMins) * 60 * 1000
            timers.sunrise = sun:setTimeout(delayMs, function()
                sun:log("info", "Sunrise event triggered")
                sun:emit("sun:rise", {
                    time = data.sunriseTime,
                    azimuth = data.azimuth,
                    elevation = data.elevation
                })
            end)
            sun:log("debug", "Sunrise event scheduled in " .. math.floor(delayMs / 60000) .. " minutes")
        end
    end

    -- Schedule sunset event
    if data.sunset then
        local sunsetMins = data.sunset + sunsetOffset
        if sunsetMins > nowMins then
            local delayMs = (sunsetMins - nowMins) * 60 * 1000
            timers.sunset = sun:setTimeout(delayMs, function()
                sun:log("info", "Sunset event triggered")
                sun:emit("sun:set", {
                    time = data.sunsetTime,
                    azimuth = data.azimuth,
                    elevation = data.elevation
                })
            end)
            sun:log("debug", "Sunset event scheduled in " .. math.floor(delayMs / 60000) .. " minutes")
        end
    end

    -- Schedule solar noon event
    if data.solarNoon and data.solarNoon > nowMins then
        local delayMs = (data.solarNoon - nowMins) * 60 * 1000
        timers.noon = sun:setTimeout(delayMs, function()
            sun:log("info", "Solar noon event triggered")
            sun:emit("sun:noon", {
                time = data.solarNoonTime,
                elevation = data.elevation
            })
        end)
    end
end

-- ============================================
-- INITIALIZATION
-- ============================================

sun:onInit(function(config)
    if not config.latitude or not config.longitude then
        sun:log("error", "Latitude and longitude are required")
        return
    end

    config.timezoneOffset = tonumber(config.timezoneOffset) or 1

    sun:log("info", string.format(
        "Initializing: lat=%.4f, lon=%.4f, tz=UTC%+d",
        config.latitude, config.longitude, config.timezoneOffset
    ))

    -- Initial calculation
    updateCalculations()
    scheduleEvents()

    sun:log("info", string.format(
        "Today: sunrise=%s, sunset=%s, day=%dmin, moon=%s (%.0f%%)",
        data.sunriseTime, data.sunsetTime, data.dayLength,
        data.moonPhaseName, data.moonIllumination
    ))

    -- Update position every 10 minutes
    timers.update = sun:setInterval(600000, function()
        updateCalculations()
    end)

    -- Reschedule events at midnight
    local t = os.date("*t")
    local minsToMidnight = (24 * 60) - (t.hour * 60 + t.min) + 1
    sun:setTimeout(minsToMidnight * 60 * 1000, function()
        sun:log("info", "New day - recalculating sun times")
        updateCalculations()
        scheduleEvents()

        -- Set up daily recalculation
        sun:setInterval(86400000, function()
            updateCalculations()
            scheduleEvents()
        end)
    end)
end)

sun:onCleanup(function()
    for _, timer in pairs(timers) do
        if timer then sun:clearTimer(timer) end
    end
    sun:log("info", "Sun position plugin stopped")
end)

-- ============================================
-- PUBLIC API
-- ============================================

--- Get sunrise time as HH:MM string
function sun:getSunrise()
    return data.sunriseTime
end

--- Get sunset time as HH:MM string
function sun:getSunset()
    return data.sunsetTime
end

--- Get solar noon time as HH:MM string
function sun:getSolarNoon()
    return data.solarNoonTime
end

--- Get day length in minutes
function sun:getDayLength()
    return data.dayLength
end

--- Get day length as HH:MM string
function sun:getDayLengthFormatted()
    local h = math.floor(data.dayLength / 60)
    local m = math.floor(data.dayLength % 60)
    return string.format("%d:%02d", h, m)
end

--- Get sun azimuth (0-360, degrees from North)
function sun:getAzimuth()
    return data.azimuth
end

--- Get sun elevation (-90 to 90, degrees above horizon)
function sun:getElevation()
    return data.elevation
end

--- Get sun position as table
function sun:getPosition()
    return {
        azimuth = data.azimuth,
        elevation = data.elevation,
        zenith = data.zenith
    }
end

--- Check if it's currently daytime
function sun:isDaytime()
    return data.isDaytime
end

--- Check if it's currently nighttime
function sun:isNighttime()
    return not data.isDaytime
end

--- Check if it's twilight (sun between -6° and 0°)
function sun:isTwilight()
    return data.isTwilight
end

--- Get moon phase (0-1, 0=new, 0.5=full)
function sun:getMoonPhase()
    return data.moonPhase
end

--- Get moon phase name
function sun:getMoonPhaseName()
    return data.moonPhaseName
end

--- Get moon illumination percentage (0-100)
function sun:getMoonIllumination()
    return data.moonIllumination
end

--- Get moon age in days since new moon
function sun:getMoonAge()
    return data.moonAge
end

--- Get all moon data
function sun:getMoon()
    return {
        phase = data.moonPhase,
        phaseName = data.moonPhaseName,
        illumination = data.moonIllumination,
        age = data.moonAge
    }
end

--- Get all sun data
function sun:getData()
    return {
        sunrise = data.sunriseTime,
        sunset = data.sunsetTime,
        solarNoon = data.solarNoonTime,
        dayLength = data.dayLength,
        azimuth = data.azimuth,
        elevation = data.elevation,
        isDaytime = data.isDaytime,
        isTwilight = data.isTwilight,
        moonPhase = data.moonPhase,
        moonPhaseName = data.moonPhaseName,
        moonIllumination = data.moonIllumination
    }
end

--- Check if sun is in a specific azimuth range (for facade-specific automation)
-- @param minAzimuth number Minimum azimuth (degrees)
-- @param maxAzimuth number Maximum azimuth (degrees)
-- @return boolean True if sun is in range
function sun:isAzimuthBetween(minAzimuth, maxAzimuth)
    if minAzimuth <= maxAzimuth then
        return data.azimuth >= minAzimuth and data.azimuth <= maxAzimuth
    else
        -- Wraps around 360/0
        return data.azimuth >= minAzimuth or data.azimuth <= maxAzimuth
    end
end

--- Check if sun is above a specific elevation
-- @param minElevation number Minimum elevation (degrees)
-- @return boolean True if sun is above
function sun:isElevationAbove(minElevation)
    return data.elevation >= minElevation
end

--- Get minutes until sunrise (negative if already passed)
function sun:getMinutesToSunrise()
    local nowMins = currentMinutes()
    return math.floor(data.sunrise - nowMins)
end

--- Get minutes until sunset (negative if already passed)
function sun:getMinutesToSunset()
    local nowMins = currentMinutes()
    return math.floor(data.sunset - nowMins)
end

--- Force recalculation
function sun:refresh()
    updateCalculations()
    scheduleEvents()
end

return sun
