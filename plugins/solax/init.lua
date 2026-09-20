--- SolaX Inverter Plugin for vCLU
-- Local monitoring of a SolaX inverter via its WiFi dongle (Solarman LSW-3 / "Pocket WiFi").
--
-- The dongle serves a legacy status page at /status.html containing JS variables
-- like:  var webdata_now_p = "2150";  var webdata_today_e = "29.94";
-- This plugin scrapes that page over HTTP (Basic Auth) and exposes the values as
-- read-only sensors. 100% Lua — no cloud, no Go core changes, no Modbus.
--
-- @module plugins.solax
--
-- ## Expose API Usage (in user.lua)
--
-- ```lua
-- local solax = Plugin.getPlugin("@vclu/solax")
--
-- expose(solax:get("power"), "number", { name = "Falownik moc", area = "Fotowoltaika", unit = "W" })
-- expose(solax:get("today"), "number", { name = "Produkcja dziś", area = "Fotowoltaika", unit = "kWh" })
-- expose(solax:get("total"), "number", { name = "Produkcja łącznie", area = "Fotowoltaika", unit = "kWh" })
-- expose(solax:get("online"), "binary_sensor", { name = "Falownik online", area = "Fotowoltaika" })
-- ```
--
-- ## Available Sensors
--
-- | ID     | Unit | Description                         |
-- |--------|------|-------------------------------------|
-- | power  | W    | Moc AC chwilowa (webdata_now_p)     |
-- | today  | kWh  | Produkcja dziś (webdata_today_e)    |
-- | total  | kWh  | Produkcja łącznie (webdata_total_e) |
-- | online | 0/1  | Czy ostatni odczyt się powiódł      |

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local solax = Plugin:new("solax", {
    name = "SolaX Inverter",
    version = "1.0.0",
    description = "SolaX inverter local monitoring via Solarman LSW-3 WiFi dongle (status.html scrape)"
})

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local state = {
    ready = false,
    online = false,
    lastUpdate = 0,
    lastError = nil,
    power = 0, -- W  (now_p)
    today = 0, -- kWh (today_e)
    total = 0, -- kWh (total_e)
    sn = "",   -- inverter serial (webdata_sn)
    pvType = "",
    firmware = "" -- webdata_msvn
}

local poller = nil

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

-- Extract a numeric value from `var webdata_<name> = "<value>";`
-- Returns nil for missing or non-numeric (e.g. "---" at night).
local function numField(body, name)
    local raw = body:match('webdata_' .. name .. '%s*=%s*"%s*([%d%.%-]*)')
    return raw and tonumber(raw) or nil
end

-- Extract a trimmed string field.
local function strField(body, name)
    local raw = body:match('webdata_' .. name .. '%s*=%s*"([^"]*)"')
    if not raw then return nil end
    return (raw:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parseStatusPage(body)
    if not body or body == "" then
        return nil, "empty body"
    end
    -- A valid status page always carries the serial-number field.
    if not body:find("webdata_sn") then
        return nil, "unexpected page (no webdata_sn)"
    end
    return {
        power = numField(body, "now_p"),
        today = numField(body, "today_e"),
        total = numField(body, "total_e"),
        sn = strField(body, "sn") or "",
        pvType = strField(body, "pv_type") or "",
        firmware = strField(body, "msvn") or ""
    }
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

solax:onInit(function(config)
    local host = solax:coerceString(config.host, "")
    if host == "" then
        solax:log("error", "host is required (e.g. http://192.168.0.132)")
        return
    end
    -- Normalise: ensure scheme + strip trailing slash.
    if not host:find("^https?://") then host = "http://" .. host end
    host = host:gsub("/$", "")

    local user = solax:coerceString(config.user, "admin")
    local pass = solax:coerceString(config.pass, "admin")
    local interval = solax:coerceNumber(config.interval, 30)
    local statusUrl = host .. "/status.html"
    local authHeader = solax:basicAuth(user, pass)

    solax:logSafe("info", "Initializing", { host = host, interval = interval })

    -- Registry object (full snapshot, for scripting / debugging).
    solax:upsertObject("inverter", {
        ready = false, online = false,
        power = 0, today = 0, total = 0,
        sn = "", pvType = "", firmware = "",
        lastUpdate = 0
    })

    ---------------------------------------------------------------------------
    -- SENSORS (for expose API)
    ---------------------------------------------------------------------------
    solax:sensor("power", function() return state.power end)
    solax:sensor("today", function() return state.today end)
    solax:sensor("total", function() return state.total end)
    solax:sensor("online", function() return state.online and 1 or 0 end)

    local function notify(id)
        local s = solax:get(id)
        if s and s.emit then s:emit("OnChange", s:get()) end
    end

    ---------------------------------------------------------------------------
    -- POLLER
    ---------------------------------------------------------------------------
    poller = solax:poller("fetch", {
        interval = interval * 1000,
        immediate = true,
        timeout = 15000,
        retry = { attempts = 2, backoff = 2000 },

        onTick = function(done)
            solax:httpRequest({
                url = statusUrl,
                method = "GET",
                timeout = 10000,
                parseJson = "never", -- status.html is HTML, not JSON
                headers = { Authorization = authHeader },
                log = { redact = true }
            }, function(resp)
                if not resp or not resp.ok then
                    state.online = false
                    notify("online")
                    done("HTTP " .. tostring(resp and resp.status or "no response"))
                    return
                end

                local data, parseErr = parseStatusPage(resp.body)
                if not data then
                    state.online = false
                    notify("online")
                    done(parseErr or "parse error")
                    return
                end

                local changed = state.power ~= (data.power or state.power)
                    or state.total ~= (data.total or state.total)
                    or not state.online

                -- Keep last known reading when a field is "---" (night / off).
                state.ready = true
                state.online = true
                state.lastUpdate = os.time()
                state.lastError = nil
                if data.power then state.power = data.power end
                if data.today then state.today = data.today end
                if data.total then state.total = data.total end
                state.sn = data.sn
                state.pvType = data.pvType
                state.firmware = data.firmware

                solax:updateObject("inverter", {
                    ready = true, online = true,
                    power = state.power, today = state.today, total = state.total,
                    sn = state.sn, pvType = state.pvType, firmware = state.firmware,
                    lastUpdate = state.lastUpdate
                })

                solax:log("info", string.format(
                    "Power: %.0fW, Today: %.2fkWh, Total: %.1fkWh (SN %s)",
                    state.power, state.today, state.total, state.sn
                ))

                notify("power")
                notify("today")
                notify("total")
                notify("online")

                if changed then
                    solax:emit("solax:updated", {
                        power = state.power, today = state.today, total = state.total
                    }, { throttle = 30000 })
                end

                done()
            end)
        end,

        onError = function(err, stats)
            state.online = false
            state.lastError = err
            solax:log("warn", "Fetch failed: " .. tostring(err))
            solax:emit("solax:error", { error = err })
        end
    })

    poller:start()
end)

solax:onCleanup(function()
    if poller then poller:stop() end
    solax:log("info", "SolaX plugin stopped")
end)

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

function solax:isReady() return state.ready end
function solax:isOnline() return state.online end
function solax:getPower() return state.power end
function solax:getToday() return state.today end
function solax:getTotal() return state.total end
function solax:getSerial() return state.sn end
function solax:getFirmware() return state.firmware end
function solax:getLastError() return state.lastError end
function solax:getLastUpdate() return state.lastUpdate end

function solax:getData()
    return {
        ready = state.ready, online = state.online,
        power = state.power, today = state.today, total = state.total,
        sn = state.sn, pvType = state.pvType, firmware = state.firmware,
        lastUpdate = state.lastUpdate, lastError = state.lastError
    }
end

function solax:refresh()
    if poller then poller:poll() end
end

function solax:getStats()
    if poller then return poller:stats() end
    return {}
end

return solax