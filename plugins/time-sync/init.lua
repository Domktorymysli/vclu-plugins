--- Time Sync Plugin for vCLU
-- Synchronizes time from WorldTimeAPI
-- @module plugins.time-sync

local timeSync = Plugin:new("time-sync", {
    name = "Time Sync",
    version = "1.0.0",
    description = "Time synchronization from internet"
})

-- Internal state
local data = {
    syncedTimestamp = 0,    -- Unix timestamp from server at sync moment
    localAtSync = 0,        -- Local os.time() at sync moment (for clock calculation)
    datetime = "",          -- ISO 8601 datetime (at sync moment)
    timezone = "",          -- Current timezone
    utcOffset = "",         -- UTC offset string (+01:00)
    offsetSeconds = 0,      -- UTC offset in seconds
    dayOfWeek = 0,          -- 0=Sunday, 6=Saturday
    dayOfYear = 0,
    weekNumber = 0,
    dst = false,            -- Daylight saving time
    lastSync = 0,           -- Last successful sync timestamp
    syncCount = 0,          -- Number of successful syncs
    drift = 0,              -- Detected drift in seconds (server - local)
    error = nil             -- Last error message
}

--- Calculate current timestamp (ticks like a clock)
-- @return number Current Unix timestamp
local function getCurrentTimestamp()
    if data.syncedTimestamp == 0 then
        return os.time()  -- Fallback to local time if not synced yet
    end
    -- syncedTimestamp + elapsed time since sync
    local elapsed = os.time() - data.localAtSync
    return data.syncedTimestamp + elapsed
end

local refreshTimerId = nil

-- ============================================
-- PRIVATE METHODS
-- ============================================

local function buildUrl(timezone)
    -- WorldTimeAPI endpoint
    -- Example: http://worldtimeapi.org/api/timezone/Europe/Warsaw
    return "http://worldtimeapi.org/api/timezone/" .. (timezone or "Europe/Warsaw")
end

local function parseResponse(body)
    local json = JSON:decode(body)

    if not json then
        return nil, "Failed to parse JSON"
    end

    if json.error then
        return nil, json.error
    end

    if not json.unixtime then
        return nil, "Invalid response: missing unixtime"
    end

    return {
        timestamp = json.unixtime,
        datetime = json.datetime or "",
        timezone = json.timezone or "",
        utcOffset = json.utc_offset or "",
        offsetSeconds = json.raw_offset or 0,
        dayOfWeek = json.day_of_week or 0,
        dayOfYear = json.day_of_year or 0,
        weekNumber = json.week_number or 0,
        dst = json.dst or false,
        dstOffset = json.dst_offset or 0,
        abbreviation = json.abbreviation or ""
    }
end

local function updateData(newData)
    local oldSyncedTimestamp = data.syncedTimestamp
    local localNow = os.time()

    -- Calculate drift (difference between server time and local time)
    local drift = newData.timestamp - localNow

    -- Update internal state
    data.syncedTimestamp = newData.timestamp
    data.localAtSync = localNow  -- Remember local time at sync for clock calculation
    data.datetime = newData.datetime
    data.timezone = newData.timezone
    data.utcOffset = newData.utcOffset
    data.offsetSeconds = newData.offsetSeconds
    data.dayOfWeek = newData.dayOfWeek
    data.dayOfYear = newData.dayOfYear
    data.weekNumber = newData.weekNumber
    data.dst = newData.dst
    data.lastSync = localNow
    data.syncCount = data.syncCount + 1
    data.drift = drift
    data.error = nil

    timeSync:log("info", string.format(
        "Time synced: %s (%s, UTC%s), drift: %+ds",
        newData.datetime:sub(1, 19),  -- Trim to YYYY-MM-DDTHH:MM:SS
        newData.timezone,
        newData.utcOffset,
        drift
    ))

    -- Update registry object
    timeSync:createObject("current", {
        timestamp = data.syncedTimestamp,
        datetime = data.datetime,
        timezone = data.timezone,
        utcOffset = data.utcOffset,
        dayOfWeek = data.dayOfWeek,
        weekNumber = data.weekNumber,
        dst = data.dst,
        drift = data.drift,
        lastSync = data.lastSync
    })

    -- Emit sync event
    timeSync:emit("time:synced", {
        timestamp = data.syncedTimestamp,
        datetime = data.datetime,
        timezone = data.timezone,
        drift = drift
    })

    -- Emit hour change event (useful for automations)
    if oldSyncedTimestamp > 0 then
        local oldHour = os.date("*t", oldSyncedTimestamp).hour
        local newHour = os.date("*t", newData.timestamp).hour
        if oldHour ~= newHour then
            timeSync:emit("time:hourChanged", {
                hour = newHour,
                timestamp = newData.timestamp
            })
        end
    end
end

local function sync()
    local config = timeSync.config
    local url = buildUrl(config.timezone)

    timeSync:log("debug", "Syncing time from: " .. url)

    timeSync:httpGet(url, function(response, err)
        if err then
            data.error = tostring(err)
            timeSync:log("error", "Time sync failed: " .. data.error)
            timeSync:emit("time:error", { error = data.error })
            return
        end

        if not response or response.status ~= 200 then
            data.error = "HTTP " .. tostring(response and response.status or "no response")
            timeSync:log("error", "Time API error: " .. data.error)
            timeSync:emit("time:error", { error = data.error })
            return
        end

        local newData, parseErr = parseResponse(response.body)

        if not newData then
            data.error = parseErr or "Parse error"
            timeSync:log("error", "Failed to parse time data: " .. data.error)
            timeSync:emit("time:error", { error = data.error })
            return
        end

        updateData(newData)
    end)
end

-- ============================================
-- INITIALIZATION
-- ============================================

timeSync:onInit(function(config)
    -- Set defaults
    config.timezone = config.timezone or "Europe/Warsaw"
    config.interval = tonumber(config.interval) or 3600
    config.autoSync = config.autoSync ~= false  -- default true

    timeSync:log("info", string.format(
        "Initializing: timezone=%s, interval=%ds",
        config.timezone,
        config.interval
    ))

    -- Setup refresh timer
    local intervalMs = config.interval * 1000
    refreshTimerId = timeSync:setInterval(intervalMs, sync)

    -- Initial sync after short delay (if autoSync enabled)
    if config.autoSync then
        timeSync:setTimeout(1000, sync)
    end
end)

timeSync:onCleanup(function()
    if refreshTimerId then
        timeSync:clearTimer(refreshTimerId)
    end
    timeSync:log("info", "Time sync stopped")
end)

-- ============================================
-- PUBLIC API
-- ============================================

--- Get current Unix timestamp (ticks like a clock, adjusted for drift)
-- @return number Unix timestamp
function timeSync:getTimestamp()
    return getCurrentTimestamp()
end

--- Get current datetime as ISO 8601 string
-- @return string ISO 8601 datetime
function timeSync:getDatetime()
    return data.datetime
end

--- Get current timezone
-- @return string IANA timezone name
function timeSync:getTimezone()
    return data.timezone
end

--- Get UTC offset string
-- @return string UTC offset (e.g., "+01:00")
function timeSync:getUtcOffset()
    return data.utcOffset
end

--- Get day of week (0=Sunday, 6=Saturday)
-- @return number Day of week
function timeSync:getDayOfWeek()
    return data.dayOfWeek
end

--- Get week number
-- @return number Week number (1-52)
function timeSync:getWeekNumber()
    return data.weekNumber
end

--- Check if daylight saving time is active
-- @return boolean DST active
function timeSync:isDst()
    return data.dst
end

--- Get last sync timestamp
-- @return number Unix timestamp of last sync
function timeSync:getLastSync()
    return data.lastSync
end

--- Get sync count
-- @return number Number of successful syncs
function timeSync:getSyncCount()
    return data.syncCount
end

--- Get last error message
-- @return string|nil Error message or nil
function timeSync:getError()
    return data.error
end

--- Get drift (difference between server and local time in seconds)
-- @return number Drift in seconds (positive = server ahead, negative = server behind)
function timeSync:getDrift()
    return data.drift
end

--- Get all time data (with current computed timestamp)
-- @return table All time data
function timeSync:getData()
    return {
        timestamp = getCurrentTimestamp(),  -- Current time (ticks)
        syncedTimestamp = data.syncedTimestamp,  -- Time at last sync
        datetime = data.datetime,
        timezone = data.timezone,
        utcOffset = data.utcOffset,
        offsetSeconds = data.offsetSeconds,
        dayOfWeek = data.dayOfWeek,
        dayOfYear = data.dayOfYear,
        weekNumber = data.weekNumber,
        dst = data.dst,
        lastSync = data.lastSync,
        syncCount = data.syncCount,
        drift = data.drift,
        error = data.error
    }
end

--- Get formatted time string (current time, ticks like a clock)
-- @param format string Optional format (default: "%H:%M:%S")
-- @return string Formatted time
function timeSync:getFormatted(format)
    if data.syncedTimestamp == 0 then
        return "--:--:--"
    end
    return os.date(format or "%H:%M:%S", getCurrentTimestamp())
end

--- Get formatted date string (current date, ticks like a clock)
-- @param format string Optional format (default: "%Y-%m-%d")
-- @return string Formatted date
function timeSync:getFormattedDate(format)
    if data.syncedTimestamp == 0 then
        return "----/--/--"
    end
    return os.date(format or "%Y-%m-%d", getCurrentTimestamp())
end

--- Get current hour (0-23, ticks like a clock)
-- @return number Hour
function timeSync:getHour()
    if data.syncedTimestamp == 0 then return 0 end
    return tonumber(os.date("%H", getCurrentTimestamp())) or 0
end

--- Get current minute (0-59, ticks like a clock)
-- @return number Minute
function timeSync:getMinute()
    if data.syncedTimestamp == 0 then return 0 end
    return tonumber(os.date("%M", getCurrentTimestamp())) or 0
end

--- Get current second (0-59, ticks like a clock)
-- @return number Second
function timeSync:getSecond()
    if data.syncedTimestamp == 0 then return 0 end
    return tonumber(os.date("%S", getCurrentTimestamp())) or 0
end

--- Check if current time is between two times (for automations)
-- @param startHour number Start hour (0-23)
-- @param startMin number Start minute (0-59)
-- @param endHour number End hour (0-23)
-- @param endMin number End minute (0-59)
-- @return boolean True if current time is in range
function timeSync:isBetween(startHour, startMin, endHour, endMin)
    if data.timestamp == 0 then return false end

    local currentMins = self:getHour() * 60 + self:getMinute()
    local startMins = startHour * 60 + (startMin or 0)
    local endMins = endHour * 60 + (endMin or 0)

    if startMins <= endMins then
        -- Normal range (e.g., 08:00 - 22:00)
        return currentMins >= startMins and currentMins < endMins
    else
        -- Overnight range (e.g., 22:00 - 06:00)
        return currentMins >= startMins or currentMins < endMins
    end
end

--- Check if today is a weekday (Monday-Friday)
-- @return boolean True if weekday
function timeSync:isWeekday()
    -- dayOfWeek: 0=Sunday, 1=Monday, ..., 6=Saturday
    return data.dayOfWeek >= 1 and data.dayOfWeek <= 5
end

--- Check if today is weekend (Saturday or Sunday)
-- @return boolean True if weekend
function timeSync:isWeekend()
    return data.dayOfWeek == 0 or data.dayOfWeek == 6
end

--- Force time sync
function timeSync:sync()
    sync()
end

--- Change timezone and resync
-- @param timezone string IANA timezone name
function timeSync:setTimezone(timezone)
    timeSync.config.timezone = timezone
    timeSync:log("info", "Timezone changed to: " .. timezone)
    sync()
end

return timeSync
