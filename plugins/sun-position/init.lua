--- Sun Position & Astronomy Plugin for vCLU
-- Calculates sun position, sunrise/sunset times, and moon phases
-- @module plugins.sun-position

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local sun = Plugin:new("sun-position", {
    name = "Sun Position & Astronomy",
    version = "2.0.0",
    description = "Sun position, sunrise/sunset, moon phases"
})

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

local RAD = math.pi / 180
local DEG = 180 / math.pi
local ZENITH = 90.833
local SYNODIC_MONTH = 29.53058867
local KNOWN_NEW_MOON = 947182440

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local state = {
    ready = false,
    lastUpdate = 0,
    -- Sun times (minutes from midnight)
    sunrise = 0,
    sunset = 0,
    solarNoon = 0,
    dayLength = 0,
    -- Sun times as HH:MM strings
    sunriseTime = "00:00",
    sunsetTime = "00:00",
    solarNoonTime = "00:00",
    -- Sun position
    azimuth = 0,
    elevation = 0,
    zenith = 0,
    -- Day/night
    isDaytime = false,
    isTwilight = false,
    -- Moon
    moonPhase = 0,
    moonPhaseName = "",
    moonIllumination = 0,
    moonAge = 0,
    -- Config
    latitude = 0,
    longitude = 0
}

local timers = {
    update = nil,
    sunrise = nil,
    sunset = nil,
    noon = nil,
    midnight = nil
}

--------------------------------------------------------------------------------
-- ASTRONOMICAL CALCULATIONS
--------------------------------------------------------------------------------

local function dayOfYear(timestamp)
    local t = os.date("*t", timestamp)
    local jan1 = os.time({year = t.year, month = 1, day = 1, hour = 0})
    return math.floor((timestamp - jan1) / 86400) + 1
end

local function calculateSunTimes(lat, lon, timestamp, tzOffset)
    local t = os.date("*t", timestamp)
    local doy = dayOfYear(timestamp)

    local gamma = (2 * math.pi / 365) * (doy - 1 + (t.hour - 12) / 24)

    local eqTime = 229.18 * (0.000075 + 0.001868 * math.cos(gamma)
        - 0.032077 * math.sin(gamma)
        - 0.014615 * math.cos(2 * gamma)
        - 0.040849 * math.sin(2 * gamma))

    local decl = 0.006918 - 0.399912 * math.cos(gamma)
        + 0.070257 * math.sin(gamma)
        - 0.006758 * math.cos(2 * gamma)
        + 0.000907 * math.sin(2 * gamma)
        - 0.002697 * math.cos(3 * gamma)
        + 0.00148 * math.sin(3 * gamma)

    local latRad = lat * RAD
    local cosHA = (math.cos(ZENITH * RAD) / (math.cos(latRad) * math.cos(decl)))
        - math.tan(latRad) * math.tan(decl)

    if cosHA > 1 then
        return nil, nil, 720
    elseif cosHA < -1 then
        return 0, 1440, 720
    end

    local haRad = math.acos(cosHA)
    local haDeg = haRad * DEG

    local solarNoon = 720 - (4 * lon) - eqTime + (tzOffset * 60)
    local sunrise = solarNoon - (haDeg * 4)
    local sunset = solarNoon + (haDeg * 4)

    return sunrise, sunset, solarNoon
end

local function calculateSunPosition(lat, lon, timestamp, tzOffset)
    local t = os.date("*t", timestamp)
    local doy = dayOfYear(timestamp)

    local gamma = (2 * math.pi / 365) * (doy - 1 + (t.hour - 12) / 24)

    local eqTime = 229.18 * (0.000075 + 0.001868 * math.cos(gamma)
        - 0.032077 * math.sin(gamma)
        - 0.014615 * math.cos(2 * gamma)
        - 0.040849 * math.sin(2 * gamma))

    local decl = 0.006918 - 0.399912 * math.cos(gamma)
        + 0.070257 * math.sin(gamma)
        - 0.006758 * math.cos(2 * gamma)
        + 0.000907 * math.sin(2 * gamma)
        - 0.002697 * math.cos(3 * gamma)
        + 0.00148 * math.sin(3 * gamma)

    local timeOffset = eqTime + (4 * lon) - (60 * tzOffset)
    local tst = t.hour * 60 + t.min + t.sec / 60 + timeOffset
    local ha = (tst / 4) - 180

    local latRad = lat * RAD
    local haRad = ha * RAD

    local cosZenith = math.sin(latRad) * math.sin(decl)
        + math.cos(latRad) * math.cos(decl) * math.cos(haRad)
    local zenithRad = math.acos(math.max(-1, math.min(1, cosZenith)))
    local zenithDeg = zenithRad * DEG

    local elevation = 90 - zenithDeg

    local azimuth
    if cosZenith > 0.99999 then
        azimuth = 180
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

local function calculateMoonPhase(timestamp)
    local daysSinceNew = (timestamp - KNOWN_NEW_MOON) / 86400
    local phase = (daysSinceNew % SYNODIC_MONTH) / SYNODIC_MONTH
    local age = phase * SYNODIC_MONTH
    local illumination = (1 - math.cos(phase * 2 * math.pi)) / 2 * 100

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

local function minutesToTime(minutes)
    if not minutes then return "--:--" end
    minutes = math.floor(minutes + 0.5)
    if minutes < 0 then minutes = minutes + 1440 end
    if minutes >= 1440 then minutes = minutes - 1440 end
    local h = math.floor(minutes / 60)
    local m = minutes % 60
    return string.format("%02d:%02d", h, m)
end

local function currentMinutes()
    local t = os.date("*t")
    return t.hour * 60 + t.min
end

--------------------------------------------------------------------------------
-- UPDATE FUNCTIONS
--------------------------------------------------------------------------------

local function updateCalculations()
    local config = sun.config
    local now = os.time()

    state.latitude = config.latitude
    state.longitude = config.longitude

    local sunrise, sunset, solarNoon = calculateSunTimes(
        config.latitude, config.longitude, now, config.timezoneOffset or 1
    )

    if sunrise then
        state.sunrise = sunrise
        state.sunset = sunset
        state.solarNoon = solarNoon
        state.dayLength = sunset - sunrise
        state.sunriseTime = minutesToTime(sunrise)
        state.sunsetTime = minutesToTime(sunset)
        state.solarNoonTime = minutesToTime(solarNoon)
    end

    local azimuth, elevation = calculateSunPosition(
        config.latitude, config.longitude, now, config.timezoneOffset or 1
    )
    state.azimuth = math.floor(azimuth * 10) / 10
    state.elevation = math.floor(elevation * 10) / 10
    state.zenith = 90 - state.elevation

    local nowMins = currentMinutes()
    state.isDaytime = sunrise and sunset and nowMins >= sunrise and nowMins < sunset
    state.isTwilight = elevation >= -6 and elevation < 0

    local phase, illum, age, phaseName = calculateMoonPhase(now)
    state.moonPhase = math.floor(phase * 1000) / 1000
    state.moonIllumination = math.floor(illum)
    state.moonAge = math.floor(age * 10) / 10
    state.moonPhaseName = phaseName

    state.ready = true
    state.lastUpdate = now

    -- Update registry
    sun:updateObject("sun", {
        ready = true,
        sunrise = state.sunriseTime,
        sunset = state.sunsetTime,
        solarNoon = state.solarNoonTime,
        dayLength = math.floor(state.dayLength),
        azimuth = state.azimuth,
        elevation = state.elevation,
        isDaytime = state.isDaytime
    })

    sun:updateObject("moon", {
        phase = state.moonPhase,
        phaseName = state.moonPhaseName,
        illumination = state.moonIllumination,
        age = state.moonAge
    })

    -- Emit position update (throttled to avoid spam)
    sun:emit("sun:position", {
        azimuth = state.azimuth,
        elevation = state.elevation,
        isDaytime = state.isDaytime
    }, { throttle = 60000 })
end

local function scheduleEvents()
    local config = sun.config
    local nowMins = currentMinutes()

    local sunriseOffset = sun:coerceNumber(config.sunriseOffset, 0)
    local sunsetOffset = sun:coerceNumber(config.sunsetOffset, 0)

    -- Clear existing timers
    if timers.sunrise then sun:clearTimer(timers.sunrise) end
    if timers.sunset then sun:clearTimer(timers.sunset) end
    if timers.noon then sun:clearTimer(timers.noon) end

    -- Schedule sunrise event
    if state.sunrise then
        local sunriseMins = state.sunrise + sunriseOffset
        if sunriseMins > nowMins then
            local delayMs = (sunriseMins - nowMins) * 60 * 1000
            timers.sunrise = sun:setTimeout(delayMs, function()
                sun:log("info", "Sunrise event triggered")
                sun:emit("sun:rise", {
                    time = state.sunriseTime,
                    azimuth = state.azimuth,
                    elevation = state.elevation
                })
            end)
            sun:log("debug", "Sunrise in " .. math.floor(delayMs / 60000) .. " minutes")
        end
    end

    -- Schedule sunset event
    if state.sunset then
        local sunsetMins = state.sunset + sunsetOffset
        if sunsetMins > nowMins then
            local delayMs = (sunsetMins - nowMins) * 60 * 1000
            timers.sunset = sun:setTimeout(delayMs, function()
                sun:log("info", "Sunset event triggered")
                sun:emit("sun:set", {
                    time = state.sunsetTime,
                    azimuth = state.azimuth,
                    elevation = state.elevation
                })
            end)
            sun:log("debug", "Sunset in " .. math.floor(delayMs / 60000) .. " minutes")
        end
    end

    -- Schedule solar noon event
    if state.solarNoon and state.solarNoon > nowMins then
        local delayMs = (state.solarNoon - nowMins) * 60 * 1000
        timers.noon = sun:setTimeout(delayMs, function()
            sun:log("info", "Solar noon event triggered")
            sun:emit("sun:noon", {
                time = state.solarNoonTime,
                elevation = state.elevation
            })
        end)
    end
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

sun:onInit(function(config)
    if not config.latitude or not config.longitude then
        sun:log("error", "latitude and longitude are required")
        return
    end

    config.timezoneOffset = sun:coerceNumber(config.timezoneOffset, 1)

    sun:log("info", string.format(
        "Initializing: lat=%.4f, lon=%.4f, tz=UTC%+d",
        config.latitude, config.longitude, config.timezoneOffset
    ))

    -- Create initial registry objects
    sun:upsertObject("sun", {
        ready = false,
        sunrise = "00:00",
        sunset = "00:00",
        solarNoon = "00:00",
        dayLength = 0,
        azimuth = 0,
        elevation = 0,
        isDaytime = false
    })

    sun:upsertObject("moon", {
        phase = 0,
        phaseName = "",
        illumination = 0,
        age = 0
    })

    -- Initial calculation
    updateCalculations()
    scheduleEvents()

    sun:log("info", string.format(
        "Today: sunrise=%s, sunset=%s, day=%dmin, moon=%s (%.0f%%)",
        state.sunriseTime, state.sunsetTime, state.dayLength,
        state.moonPhaseName, state.moonIllumination
    ))

    -- Update position every 10 minutes
    timers.update = sun:setInterval(600000, function()
        updateCalculations()
    end)

    -- Reschedule events at midnight
    local t = os.date("*t")
    local minsToMidnight = (24 * 60) - (t.hour * 60 + t.min) + 1
    timers.midnight = sun:setTimeout(minsToMidnight * 60 * 1000, function()
        sun:log("info", "New day - recalculating")
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

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

function sun:getSunrise()
    return state.sunriseTime
end

function sun:getSunset()
    return state.sunsetTime
end

function sun:getSolarNoon()
    return state.solarNoonTime
end

function sun:getDayLength()
    return state.dayLength
end

function sun:getDayLengthFormatted()
    local h = math.floor(state.dayLength / 60)
    local m = math.floor(state.dayLength % 60)
    return string.format("%d:%02d", h, m)
end

function sun:getAzimuth()
    return state.azimuth
end

function sun:getElevation()
    return state.elevation
end

function sun:getPosition()
    return {
        azimuth = state.azimuth,
        elevation = state.elevation,
        zenith = state.zenith
    }
end

function sun:isDaytime()
    return state.isDaytime
end

function sun:isNighttime()
    return not state.isDaytime
end

function sun:isTwilight()
    return state.isTwilight
end

function sun:getMoonPhase()
    return state.moonPhase
end

function sun:getMoonPhaseName()
    return state.moonPhaseName
end

function sun:getMoonIllumination()
    return state.moonIllumination
end

function sun:getMoonAge()
    return state.moonAge
end

function sun:getMoon()
    return {
        phase = state.moonPhase,
        phaseName = state.moonPhaseName,
        illumination = state.moonIllumination,
        age = state.moonAge
    }
end

function sun:isReady()
    return state.ready
end

function sun:getData()
    return {
        ready = state.ready,
        sunrise = state.sunriseTime,
        sunset = state.sunsetTime,
        solarNoon = state.solarNoonTime,
        dayLength = state.dayLength,
        azimuth = state.azimuth,
        elevation = state.elevation,
        isDaytime = state.isDaytime,
        isTwilight = state.isTwilight,
        moonPhase = state.moonPhase,
        moonPhaseName = state.moonPhaseName,
        moonIllumination = state.moonIllumination,
        lastUpdate = state.lastUpdate
    }
end

function sun:isAzimuthBetween(minAzimuth, maxAzimuth)
    if minAzimuth <= maxAzimuth then
        return state.azimuth >= minAzimuth and state.azimuth <= maxAzimuth
    else
        return state.azimuth >= minAzimuth or state.azimuth <= maxAzimuth
    end
end

function sun:isElevationAbove(minElevation)
    return state.elevation >= minElevation
end

function sun:getMinutesToSunrise()
    local nowMins = currentMinutes()
    return math.floor(state.sunrise - nowMins)
end

function sun:getMinutesToSunset()
    local nowMins = currentMinutes()
    return math.floor(state.sunset - nowMins)
end

function sun:refresh()
    updateCalculations()
    scheduleEvents()
end

return sun
