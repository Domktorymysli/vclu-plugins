--- Time Sync Plugin for vCLU
-- Synchronizes time from WorldTimeAPI
-- @module plugins.time-sync

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local timeSync = Plugin:new("time-sync", {
    name = "Time Sync",
    version = "2.0.0",
    description = "Time synchronization from internet"
})

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local state = {
    ready = false,
    lastUpdate = 0,
    lastError = nil,
    -- Time data
    syncedTimestamp = 0,
    localAtSync = 0,
    datetime = "",
    timezone = "",
    utcOffset = "",
    offsetSeconds = 0,
    dayOfWeek = 0,
    dayOfYear = 0,
    weekNumber = 0,
    dst = false,
    syncCount = 0,
    drift = 0
}

local poller = nil

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function getCurrentTimestamp()
    if state.syncedTimestamp == 0 then
        return os.time()
    end
    local elapsed = os.time() - state.localAtSync
    return state.syncedTimestamp + elapsed
end

local function parseResponse(json)
    if not json then
        return nil, "Invalid JSON"
    end
    if json.error then
        return nil, json.error
    end
    if not json.unixtime then
        return nil, "Missing unixtime"
    end

    return {
        timestamp = timeSync:coerceNumber(json.unixtime, 0),
        datetime = timeSync:coerceString(json.datetime, ""),
        timezone = timeSync:coerceString(json.timezone, ""),
        utcOffset = timeSync:coerceString(json.utc_offset, ""),
        offsetSeconds = timeSync:coerceNumber(json.raw_offset, 0),
        dayOfWeek = timeSync:coerceNumber(json.day_of_week, 0),
        dayOfYear = timeSync:coerceNumber(json.day_of_year, 0),
        weekNumber = timeSync:coerceNumber(json.week_number, 0),
        dst = timeSync:coerceBool(json.dst, false),
        dstOffset = timeSync:coerceNumber(json.dst_offset, 0),
        abbreviation = timeSync:coerceString(json.abbreviation, "")
    }
end

local function currentMinutes()
    local t = os.date("*t", getCurrentTimestamp())
    return t.hour * 60 + t.min
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

timeSync:onInit(function(config)
    local timezone = timeSync:coerceString(config.timezone, "Europe/Warsaw")
    local interval = timeSync:coerceNumber(config.interval, 3600)
    local autoSync = timeSync:coerceBool(config.autoSync, true)

    timeSync:log("info", string.format(
        "Initializing: timezone=%s, interval=%ds",
        timezone, interval
    ))

    -- Create initial registry object
    timeSync:upsertObject("current", {
        ready = false,
        timestamp = 0,
        datetime = "",
        timezone = timezone,
        utcOffset = "",
        dayOfWeek = 0,
        weekNumber = 0,
        dst = false,
        drift = 0,
        lastSync = 0
    })

    -- Create poller
    poller = timeSync:poller("sync", {
        interval = interval * 1000,
        immediate = autoSync,
        timeout = 15000,
        retry = { maxAttempts = 3, backoff = 2000 },

        onTick = function(done)
            local url = "http://worldtimeapi.org/api/timezone/" .. timezone

            timeSync:httpRequest({
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

                local localNow = os.time()
                local drift = data.timestamp - localNow
                local oldHour = state.syncedTimestamp > 0
                    and os.date("*t", state.syncedTimestamp).hour or -1

                -- Update state
                state.ready = true
                state.lastUpdate = localNow
                state.lastError = nil
                state.syncedTimestamp = data.timestamp
                state.localAtSync = localNow
                state.datetime = data.datetime
                state.timezone = data.timezone
                state.utcOffset = data.utcOffset
                state.offsetSeconds = data.offsetSeconds
                state.dayOfWeek = data.dayOfWeek
                state.dayOfYear = data.dayOfYear
                state.weekNumber = data.weekNumber
                state.dst = data.dst
                state.syncCount = state.syncCount + 1
                state.drift = drift

                -- Update registry
                timeSync:updateObject("current", {
                    ready = true,
                    timestamp = state.syncedTimestamp,
                    datetime = state.datetime,
                    timezone = state.timezone,
                    utcOffset = state.utcOffset,
                    dayOfWeek = state.dayOfWeek,
                    weekNumber = state.weekNumber,
                    dst = state.dst,
                    drift = state.drift,
                    lastSync = state.lastUpdate
                })

                timeSync:log("info", string.format(
                    "Synced: %s (%s, UTC%s), drift: %+ds",
                    data.datetime:sub(1, 19),
                    data.timezone,
                    data.utcOffset,
                    drift
                ))

                -- Emit events
                timeSync:emit("time:synced", {
                    timestamp = state.syncedTimestamp,
                    datetime = state.datetime,
                    timezone = state.timezone,
                    drift = drift
                }, { throttle = 60000 })

                -- Hour change event
                local newHour = os.date("*t", data.timestamp).hour
                if oldHour >= 0 and oldHour ~= newHour then
                    timeSync:emit("time:hourChanged", {
                        hour = newHour,
                        timestamp = data.timestamp
                    })
                end

                done()
            end)
        end,

        onError = function(err, stats)
            state.lastError = err
            timeSync:log("error", "Sync failed: " .. tostring(err))
            timeSync:emit("time:error", { error = err })
        end
    })

    poller:start()
end)

timeSync:onCleanup(function()
    if poller then
        poller:stop()
    end
    timeSync:log("info", "Time sync stopped")
end)

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

function timeSync:getTimestamp()
    return getCurrentTimestamp()
end

function timeSync:getDatetime()
    return state.datetime
end

function timeSync:getTimezone()
    return state.timezone
end

function timeSync:getUtcOffset()
    return state.utcOffset
end

function timeSync:getDayOfWeek()
    return state.dayOfWeek
end

function timeSync:getWeekNumber()
    return state.weekNumber
end

function timeSync:isDst()
    return state.dst
end

function timeSync:getLastSync()
    return state.lastUpdate
end

function timeSync:getSyncCount()
    return state.syncCount
end

function timeSync:getDrift()
    return state.drift
end

function timeSync:isReady()
    return state.ready
end

function timeSync:getLastError()
    return state.lastError
end

function timeSync:getData()
    return {
        ready = state.ready,
        timestamp = getCurrentTimestamp(),
        syncedTimestamp = state.syncedTimestamp,
        datetime = state.datetime,
        timezone = state.timezone,
        utcOffset = state.utcOffset,
        offsetSeconds = state.offsetSeconds,
        dayOfWeek = state.dayOfWeek,
        dayOfYear = state.dayOfYear,
        weekNumber = state.weekNumber,
        dst = state.dst,
        lastSync = state.lastUpdate,
        syncCount = state.syncCount,
        drift = state.drift,
        lastError = state.lastError
    }
end

function timeSync:getFormatted(format)
    if state.syncedTimestamp == 0 then
        return "--:--:--"
    end
    return os.date(format or "%H:%M:%S", getCurrentTimestamp())
end

function timeSync:getFormattedDate(format)
    if state.syncedTimestamp == 0 then
        return "----/--/--"
    end
    return os.date(format or "%Y-%m-%d", getCurrentTimestamp())
end

function timeSync:getHour()
    if state.syncedTimestamp == 0 then return 0 end
    return tonumber(os.date("%H", getCurrentTimestamp())) or 0
end

function timeSync:getMinute()
    if state.syncedTimestamp == 0 then return 0 end
    return tonumber(os.date("%M", getCurrentTimestamp())) or 0
end

function timeSync:getSecond()
    if state.syncedTimestamp == 0 then return 0 end
    return tonumber(os.date("%S", getCurrentTimestamp())) or 0
end

function timeSync:isBetween(startHour, startMin, endHour, endMin)
    if state.syncedTimestamp == 0 then return false end

    local nowMins = currentMinutes()
    local startMins = startHour * 60 + (startMin or 0)
    local endMins = endHour * 60 + (endMin or 0)

    if startMins <= endMins then
        return nowMins >= startMins and nowMins < endMins
    else
        return nowMins >= startMins or nowMins < endMins
    end
end

function timeSync:isWeekday()
    return state.dayOfWeek >= 1 and state.dayOfWeek <= 5
end

function timeSync:isWeekend()
    return state.dayOfWeek == 0 or state.dayOfWeek == 6
end

function timeSync:sync()
    if poller then
        poller:poll()
    end
end

function timeSync:setTimezone(timezone)
    timeSync.config.timezone = timezone
    timeSync:log("info", "Timezone changed to: " .. timezone)
    self:sync()
end

function timeSync:getStats()
    if poller then
        return poller:stats()
    end
    return {}
end

return timeSync
