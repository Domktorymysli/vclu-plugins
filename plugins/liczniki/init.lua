--[[
    Liczniki for vclu: meters read by hand (gas, water, a sub-meter, electricity...), their
    readings and a chart of the usage per month, kept in the plugin's KV store. Needs no permissions.

    Dashboard /d/liczniki_odczyty, declared in plugin.json, behind login. Who else opens it is the
    user's: Plugin.getPlugin("@vclu/liczniki"):dashboard("odczyty"):auth(...) in a module.
    Actions for agents and voice: add_reading, status, add_meter, remove_reading, export (CSV).
    From a module:

        local liczniki = Plugin.getPlugin("@vclu/liczniki")
        liczniki:addMeter("Gaz m³")
        liczniki:addReading("gaz", 1234.5)              -- today
        liczniki:addReading("gaz", 1201, "2026-10-20")
        local off = liczniki:onReading(function(meter, r) Logger:info(meter.name .. " " .. r.v) end)
]]

local plugin = Plugin:new("liczniki", {
    name = "Liczniki",
    version = "1.0.0",
    description = "Meters read by hand: readings and usage per month"
})
-- vclu 1.12 does not read "requires" in plugin.json: say what is missing instead of failing later
if type(plugin.has) ~= "function" then
    error("@vclu/liczniki needs vclu 1.13 or newer", 0)
end

local MAX_METERS = 20
local MAX_READINGS = 3000   -- per meter: eight years of daily readings
local MAX_NAME = 40         -- characters
local DAY = 86400
local KEEP_DAYS = 2 * 366 + 31   -- of the daily series: a year of bars and the year before for compare

-- Changed in place, never reassigned: gopher-lua can lose a reassigned upvalue after a pcall
local meters = {}           -- { id, name, unit, icon, decimals }, in the order they were added
local readings = {}         -- meter id -> { {t, v}, ... } sorted by t
local listeners = {}
local memo = {}             -- meter id -> { key, days, shifted }: the daily series, until a change
local state = { version = 0 }
local ui = {}               -- ui.build(): the dashboard, again after a meter is added or removed

local function clear(t)
    for k in pairs(t) do t[k] = nil end
end

--------------------------------------------------------------------------------
-- Text: names, keys for matching, numbers, dates
--------------------------------------------------------------------------------

-- Cut to n characters without splitting a UTF-8 sequence
local function cut(s, n)
    local chars = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 128 or b >= 192 then
            chars = chars + 1
            if chars > n then return s:sub(1, i - 1) end
        end
    end
    return s
end

local function trim(s)
    return (tostring(s or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local FOLD = {
    ["ą"] = "a", ["ć"] = "c", ["ę"] = "e", ["ł"] = "l", ["ń"] = "n", ["ó"] = "o", ["ś"] = "s", ["ź"] = "z", ["ż"] = "z",
    ["Ą"] = "a", ["Ć"] = "c", ["Ę"] = "e", ["Ł"] = "l", ["Ń"] = "n", ["Ó"] = "o", ["Ś"] = "s", ["Ź"] = "z", ["Ż"] = "z",
}

-- Case and Polish diacritics do not matter: "Prąd" is "prad"
local function key(s)
    return (trim(s):gsub("[\195\196\197][\128-\191]", FOLD):lower())
end

-- "Prąd – garaż" -> "prad_garaz"
local function slug(s)
    return (key(s):gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", ""):sub(1, 32))
end

-- Units the name can end with, as they are shown
local UNITS = { m3 = "m³", ["m³"] = "m³", kwh = "kWh", mwh = "MWh", gj = "GJ", l = "l", litr = "l", litry = "l",
    kg = "kg", t = "t", h = "h", mth = "mth" }

-- What a name says without a unit: the unit and the icon
-- (the start of a word, in this order: "Podlicznik pompa ciepła" is kWh, "Ciepła woda" m³)
local KINDS = {
    { "gaz", "m³", "fire" }, { "wod", "m³", "droplet" },
    { "prad", "kWh", "lightning-charge" }, { "energ", "kWh", "lightning-charge" }, { "podlicznik", "kWh", "lightning-charge" },
    { "pv", "kWh", "sun" }, { "fotowolt", "kWh", "sun" }, { "ciepl", "GJ", "thermometer-half" },
    { "olej", "l", "fuel-pump" }, { "pellet", "kg", "fire" },
}

local function kindOf(name, unit)
    local words = " " .. (key(name):gsub("[^a-z0-9]+", " "))
    for _, kind in ipairs(KINDS) do
        if words:find(" " .. kind[1], 1, true) then return unit or kind[2], kind[3] end
    end
    if unit == "kWh" or unit == "MWh" then return unit, "lightning-charge" end
    return unit or "", "speedometer2"
end

-- "1234,5" or "1234.5" -> 1234.5 and its decimals; nil when it is not a number
local function parseNumber(s)
    s = tostring(s or ""):gsub(",", ".")
    if not s:match("^%d+%.?%d*$") then return nil end
    local frac = s:match("%.(%d+)$")
    return tonumber(s), frac and #frac or 0
end

-- 1 odczyt, 2 odczyty, 5 odczytów
local function readingsCount(n)
    local few = n % 10 >= 2 and n % 10 <= 4 and (n % 100 < 12 or n % 100 > 14)
    return n .. (n == 1 and " odczyt" or few and " odczyty" or " odczytów")
end

local function fmt(v, decimals)
    local s = string.format("%." .. (decimals or 0) .. "f", v)
    return (s:gsub("%.", ","))
end

-- A day in the house's zone: its midnight (unix s) and "YYYY-MM-DD"
local function dayOf(ts)
    local d = datetime.fromTimestamp(ts).date
    return datetime.parse(d).timestamp, d
end

-- The date of a reading's time
local function dateOf(ts)
    local _, d = dayOf(ts)
    return d
end

local function nextDay(dayStart)
    return (dayOf(dayStart + DAY + 3 * 3600))   -- a DST day is 23 or 25 h
end

local function now()
    return datetime.now().timestamp
end

local function plDate(d)
    local y, m, dd = d:match("^(%d+)-(%d+)-(%d+)$")
    return dd .. "." .. m .. "." .. y
end

-- "dzisiaj", "wczoraj", "20.11", "20.11.2026", "2026-11-20" -> "YYYY-MM-DD"; nil, error
local function parseDate(s)
    local today = datetime.now()
    s = key(s)
    if s == "" or s == "dzisiaj" or s == "dzis" then return today.date end
    if s == "wczoraj" then
        local _, d = dayOf(dayOf(today.timestamp) - 12 * 3600)
        return d
    end
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
    if not y then
        d, m, y = s:match("^(%d%d?)%.(%d%d?)%.?(%d*)$")
        if y == "" then y = nil end
        if y and #y == 2 then y = "20" .. y end
    end
    if not d or (y and #y ~= 4) then return nil, "nie rozumiem daty „" .. s .. "”: podaj np. 20.11 albo 2026-11-20" end
    local guess = not y
    y = tonumber(y) or today.year
    local date = string.format("%04d-%02d-%02d", y, tonumber(m), tonumber(d))
    if not datetime.parse(date) then return nil, "nie ma takiego dnia: " .. s end
    -- "20.12" typed in January is last December
    if guess and date > today.date then date = string.format("%04d", y - 1) .. date:sub(5) end
    if date > today.date then return nil, "data " .. plDate(date) .. " jest w przyszłości" end
    return date
end

--------------------------------------------------------------------------------
-- Meters and readings
--------------------------------------------------------------------------------

-- true, or nil and why the store refused it (it is full: 1 MiB for the plugin)
local function save(id)
    state.version = state.version + 1
    local ok, err = true, nil
    if id then ok, err = plugin:kvSet("r_" .. id, readings[id] or {}) end
    if ok then ok, err = plugin:kvSet("meters", meters) end
    if ok then return true end
    plugin:log("warn", "kv: " .. tostring(err))
    return nil, "nie udało się zapisać (" .. tostring(err) .. ")"
end

local function restore()
    clear(meters)
    clear(readings)
    clear(memo)
    local saved = plugin:kvGet("meters", {})
    for _, m in ipairs(type(saved) == "table" and saved or {}) do
        if type(m) == "table" and type(m.id) == "string" and type(m.name) == "string" then
            local unit, icon = kindOf(m.name, m.unit)
            meters[#meters + 1] = { id = m.id, name = m.name, unit = unit, icon = m.icon or icon,
                decimals = math.floor(tonumber(m.decimals) or 0) }
            local list = {}
            for _, r in ipairs(plugin:kvGet("r_" .. m.id, {}) or {}) do
                if type(r) == "table" and tonumber(r.t) and tonumber(r.v) then
                    list[#list + 1] = { t = tonumber(r.t), v = tonumber(r.v) }
                end
            end
            table.sort(list, function(a, b) return a.t < b.t end)
            readings[m.id] = list
        end
    end
end

local function copyMeter(m)
    return { id = m.id, name = m.name, unit = m.unit, icon = m.icon }
end

local function names(list)
    local out = {}
    for i, m in ipairs(list) do out[i] = m.name end
    return table.concat(out, ", ")
end

-- A meter by id or name: the same (case and diacritics aside), else the only one with a word
-- starting with it ("garaż" is "Podlicznik garaż")
local function find(text)
    if type(text) ~= "string" or trim(text) == "" then return nil, "podaj licznik" end
    local k, s = key(text), slug(text)
    for _, m in ipairs(meters) do
        if m.id == s or key(m.name) == k then return m end
    end
    local hits = {}
    for _, m in ipairs(meters) do
        if (" " .. key(m.name)):find(" " .. k, 1, true) or (s ~= "" and m.id:sub(1, #s) == s) then hits[#hits + 1] = m end
    end
    if #hits == 1 then return hits[1] end
    if #hits > 1 then return nil, "„" .. text .. "” pasuje do kilku liczników: " .. names(hits) end
    if #meters == 0 then return nil, "nie ma jeszcze liczników: dodaj np. „Gaz m³”" end
    return nil, "nie ma licznika „" .. text .. "” (są: " .. names(meters) .. ")"
end

--- Add a meter: "Gaz", "Gaz m³", "Podlicznik garaż kWh". A name it knows (gaz, woda, prąd,
-- ciepło...) brings its unit; a unit at the end overrides it. The dashboard gets its section.
-- @return table the meter { id, name, unit, icon } or nil, error
function plugin:addMeter(text, unit)
    if type(text) ~= "string" then return nil, "podaj nazwę licznika" end
    local name = trim(text)
    if unit == nil then
        local head, last = name:match("^(.-)%s+(%S+)$")
        if head and UNITS[key(last)] then
            name, unit = head, UNITS[key(last)]
        end
    elseif type(unit) ~= "string" then
        return nil, "jednostka to tekst, np. m³"
    else
        unit = UNITS[key(unit)] or trim(unit)
    end
    name = trim(cut(name, MAX_NAME))
    local id = slug(name)
    if id == "" then return nil, "podaj nazwę licznika" end
    for _, m in ipairs(meters) do
        if m.id == id or key(m.name) == key(name) then return nil, "licznik „" .. m.name .. "” już jest" end
    end
    if #meters >= MAX_METERS then return nil, "najwyżej " .. MAX_METERS .. " liczników" end
    local u, icon = kindOf(name, unit)
    local m = { id = id, name = name, unit = u, icon = icon, decimals = 0 }
    meters[#meters + 1] = m
    readings[id] = {}
    local saved, serr = save(id)
    if not saved then
        meters[#meters] = nil
        readings[id] = nil
        return nil, serr
    end
    ui.build()
    return copyMeter(m)
end

--- Remove a meter with its readings. @return true or nil, error
function plugin:removeMeter(text)
    local m, err = find(text)
    if not m then return nil, err end
    for i, x in ipairs(meters) do
        if x == m then table.remove(meters, i) break end
    end
    readings[m.id] = nil
    memo[m.id] = nil
    plugin:kvDelete("r_" .. m.id)
    save()
    ui.build()
    return true
end

local function unitOf(m)
    return m.unit ~= "" and (" " .. m.unit) or ""
end

local function show(m, v)
    return fmt(v, m.decimals) .. unitOf(m)
end

--- Add a reading: value (a number, or text "1234,5") on date ("YYYY-MM-DD", "20.11", "wczoraj";
-- default today). A second reading of the same day replaces the first. A counter only grows:
-- a value below an earlier reading, or above a later one, is refused.
-- @return table { meter, date, value, used, days, replaced, text } or nil, error
function plugin:addReading(meterText, value, date)
    local m, err = find(meterText)
    if not m then return nil, err end
    local v, decimals
    if type(value) == "number" and value >= 0 and value - value == 0 then
        v = value
        decimals = #(tostring(value):match("%.(%d+)$") or "")
    else
        v, decimals = parseNumber(trim(value))
    end
    if not v then return nil, "odczyt to liczba, np. 1234,5" end
    local d
    d, err = parseDate(date)
    if not d then return nil, err end

    local today = datetime.now()
    -- today's reading is at the time it is typed; an earlier day's at noon
    local dayStart = datetime.parse(d).timestamp
    local t = d == today.date and today.timestamp or dayStart + 12 * 3600
    local list = readings[m.id]
    local dayEnd = nextDay(dayStart)
    local replaced, at = false, #list + 1
    for i, r in ipairs(list) do
        if r.t >= dayStart and r.t < dayEnd then
            replaced, at = true, i
            break
        elseif r.t > t then
            at = i
            break
        end
    end
    local prev = list[at - 1]
    local nxt = list[replaced and at + 1 or at]
    if prev and v < prev.v then
        return nil, "odczyt " .. show(m, v) .. " jest mniejszy niż " .. show(m, prev.v) .. " z " .. plDate(dateOf(prev.t))
    end
    if nxt and v > nxt.v then
        return nil, "odczyt " .. show(m, v) .. " jest większy niż późniejszy " .. show(m, nxt.v) .. " z " .. plDate(dateOf(nxt.t))
    end
    if not replaced and #list >= MAX_READINGS then return nil, "najwyżej " .. MAX_READINGS .. " odczytów licznika" end

    local r, old, oldDecimals = { t = t, v = v }, list[at], m.decimals
    if replaced then list[at] = r else table.insert(list, at, r) end
    if decimals > m.decimals then m.decimals = math.min(3, decimals) end
    memo[m.id] = nil
    local saved, serr = save(m.id)
    if not saved then
        if replaced then list[at] = old else table.remove(list, at) end
        m.decimals = oldDecimals
        return nil, serr
    end

    local out = { meter = copyMeter(m), date = d, value = v, replaced = replaced }
    local parts = { m.name .. ": " .. show(m, v) .. (d == today.date and "" or (" z " .. plDate(d))) .. "." }
    if prev then
        out.used = v - prev.v
        out.days = math.max(1, math.floor((t - prev.t) / DAY + 0.5))
        parts[#parts + 1] = "Od " .. plDate(dateOf(prev.t)) .. ": " .. show(m, out.used)
            .. " (" .. fmt(out.used / out.days, math.min(3, m.decimals + 1)) .. unitOf(m) .. " dziennie)."
    end
    if replaced then parts[#parts + 1] = "Poprzedni odczyt z tego dnia zastąpiony." end
    out.text = table.concat(parts, " ")

    for _, cb in ipairs(listeners) do
        local ok, e = pcall(cb, copyMeter(m), { date = d, v = v, t = t })
        if not ok then plugin:log("warn", "onReading: " .. tostring(e)) end
    end
    return out
end

--- Remove a meter's reading of a date (default: the last one). @return table { text } or nil, error
function plugin:removeReading(meterText, date)
    local m, err = find(meterText)
    if not m then return nil, err end
    local list = readings[m.id]
    if #list == 0 then return nil, m.name .. " nie ma odczytów" end
    local at = #list
    if date ~= nil and trim(date) ~= "" then
        local d
        d, err = parseDate(date)
        if not d then return nil, err end
        at = nil
        for i, r in ipairs(list) do
            if dateOf(r.t) == d then at = i end
        end
        if not at then return nil, m.name .. " nie ma odczytu z " .. plDate(d) end
    end
    local r = table.remove(list, at)
    memo[m.id] = nil
    save(m.id)
    return { text = "Usunięto odczyt " .. m.name .. ": " .. show(m, r.v) .. " z " .. plDate(dateOf(r.t)) .. "." }
end

--- The meters: { {id, name, unit, icon, readings, last = {date, v}} }
function plugin:meters()
    local out = {}
    for i, m in ipairs(meters) do
        local list = readings[m.id]
        local c = copyMeter(m)
        c.readings = #list
        if #list > 0 then c.last = { date = dateOf(list[#list].t), v = list[#list].v } end
        out[i] = c
    end
    return out
end

--- A meter's readings, oldest first: { {date, t, v} }
function plugin:readings(meterText)
    local m, err = find(meterText)
    if not m then return nil, err end
    local out = {}
    for i, r in ipairs(readings[m.id]) do out[i] = { date = dateOf(r.t), t = r.t, v = r.v } end
    return out
end

local function csvField(s)
    s = tostring(s)
    if s:find('[;"\n]') then return '"' .. s:gsub('"', '""') .. '"' end
    return s
end

--- The readings as CSV for a spreadsheet (";" and a decimal comma, as Excel in Polish reads it):
-- licznik;data;stan;jednostka;zużycie, the usage since the meter's previous reading.
-- meterText: one meter, default all of them. @return string, rows or nil, error
function plugin:csv(meterText)
    local list = meters
    if meterText ~= nil and trim(meterText) ~= "" then
        local m, err = find(meterText)
        if not m then return nil, err end
        list = { m }
    end
    local lines = { "licznik;data;stan;jednostka;zużycie" }
    for _, m in ipairs(list) do
        local prev
        for _, r in ipairs(readings[m.id]) do
            lines[#lines + 1] = table.concat({ csvField(m.name), dateOf(r.t), fmt(r.v, m.decimals), csvField(m.unit),
                prev and fmt(r.v - prev.v, m.decimals) or "" }, ";")
            prev = r
        end
    end
    return table.concat(lines, "\n") .. "\n", #lines - 1
end

--- cb(meter, reading) after every new reading. Returns a function that unsubscribes.
function plugin:onReading(cb)
    if type(cb) ~= "function" then error("onReading(fn): fn is a function", 2) end
    listeners[#listeners + 1] = cb
    return function()
        for i, c in ipairs(listeners) do
            if c == cb then table.remove(listeners, i) return end
        end
    end
end

--------------------------------------------------------------------------------
-- Usage per day: between two readings spread evenly over the days they span
--------------------------------------------------------------------------------

-- { {day = midnight, v = used} } for the days readings cover, the last KEEP_DAYS
local function daily(m)
    local today = dayOf(now())
    local cached = memo[m.id]
    if cached and cached.key == today then return cached.days end
    local list = readings[m.id]
    local since = today - KEEP_DAYS * DAY
    local byDay, order = {}, {}
    for i = 2, #list do
        local a, b = list[i - 1], list[i]
        if b.t > since and b.t > a.t then
            local rate = (b.v - a.v) / (b.t - a.t)
            local day = dayOf(math.max(a.t, since))
            while day < b.t do
                local nxt = nextDay(day)
                local from, to = math.max(a.t, day), math.min(b.t, nxt)
                if to > from then
                    if not byDay[day] then
                        byDay[day] = 0
                        order[#order + 1] = day
                    end
                    byDay[day] = byDay[day] + rate * (to - from)
                end
                day = nxt
            end
        end
    end
    local days = {}
    for i, day in ipairs(order) do days[i] = { day = day, v = byDay[day] } end
    memo[m.id] = { key = today, days = days }
    return days
end

-- Bar samples: one at each day's noon
local function samples(m)
    local out = {}
    for i, d in ipairs(daily(m)) do out[i] = { t = d.day + 12 * 3600, v = d.v } end
    return out
end

-- The same days a year later, for a bar beside each month of this year; 29 February goes to the 28th
local function yearBefore(m)
    local cached = memo[m.id]
    if cached and cached.shifted then return cached.shifted end
    local out = {}
    for _, d in ipairs(daily(m)) do
        local _, date = dayOf(d.day + 12 * 3600)
        local y, md = date:match("^(%d+)(%-.+)$")
        if md == "-02-29" then md = "-02-28" end
        local later = datetime.parse(string.format("%04d", tonumber(y) + 1) .. md)
        if later then out[#out + 1] = { t = later.timestamp + 12 * 3600, v = d.v } end
    end
    memo[m.id].shifted = out
    return out
end

-- Used between from and to (unix s), from the daily series; nil without readings around it
local function usedBetween(m, from, to)
    local sum, any = 0, false
    for _, d in ipairs(daily(m)) do
        if d.day >= from and d.day < to then
            sum = sum + d.v
            any = true
        end
    end
    return any and sum or nil
end

local function monthStart(ts)
    local d = datetime.fromTimestamp(ts).date
    return datetime.parse(d:sub(1, 8) .. "01").timestamp
end

-- What a meter's summary says: last reading, per day, this and the last month
local function summary(m)
    local list = readings[m.id]
    local s = { id = m.id, name = m.name, unit = m.unit, readings = #list }
    if #list == 0 then
        s.text = m.name .. ": brak odczytów."
        return s
    end
    local last = list[#list]
    s.last = { date = dateOf(last.t), v = last.v }
    -- per day over the last 30 days of readings, or the two last ones
    local first
    for i = #list - 1, 1, -1 do
        first = list[i]
        if last.t - list[i].t >= 30 * DAY then break end
    end
    if first then
        s.perDay = (last.v - first.v) / math.max(1, (last.t - first.t) / DAY)
    end
    local thisMonth = monthStart(now())
    local lastMonth = monthStart(thisMonth - DAY)
    s.lastMonth = usedBetween(m, lastMonth, thisMonth)
    local parts = { m.name .. ": " .. show(m, last.v) .. " z " .. plDate(s.last.date) }
    if s.perDay then parts[#parts + 1] = "średnio " .. fmt(s.perDay, math.min(3, m.decimals + 1)) .. unitOf(m) .. " dziennie" end
    if s.lastMonth then parts[#parts + 1] = "w poprzednim miesiącu " .. show(m, s.lastMonth) end
    s.text = table.concat(parts, ", ") .. "."
    return s
end

--- Each meter's last reading, usage per day and in the last month, with a sentence (text)
function plugin:status()
    local out, texts = {}, {}
    for i, m in ipairs(meters) do
        out[i] = summary(m)
        texts[i] = out[i].text
    end
    return { meters = out, text = #out == 0 and "Nie ma jeszcze liczników." or table.concat(texts, " ") }
end

--------------------------------------------------------------------------------
-- Actions for agents and voice assistants
--------------------------------------------------------------------------------

local function action(name, fn)
    if type(plugin.action) == "function" then plugin:action(name, fn) end
end

action("add_reading", function(p)
    p = type(p) == "table" and p or {}
    return plugin:addReading(p.meter, p.value, p.date)
end)

action("status", function()
    return plugin:status()
end)

action("add_meter", function(p)
    p = type(p) == "table" and p or {}
    local m, err = plugin:addMeter(p.name, p.unit)
    if not m then return nil, err end
    return { meter = m, text = "Dodano licznik " .. m.name .. unitOf(m) .. "." }
end)

action("export", function(p)
    p = type(p) == "table" and p or {}
    local csv, rows = plugin:csv(p.meter)
    if not csv then return nil, rows end
    return { csv = csv, rows = rows, text = "Eksport CSV: " .. readingsCount(rows) .. "." }
end)

-- "confirm": true in plugin.json: vclu runs it only once the user confirmed
action("remove_reading", function(p)
    p = type(p) == "table" and p or {}
    return plugin:removeReading(p.meter, p.date)
end)

--------------------------------------------------------------------------------
-- Dashboard: a section per meter, and one to add and remove meters
--------------------------------------------------------------------------------

local REFRESH = "Odśwież stronę, żeby zobaczyć zmianę."

function ui.build()
    if type(plugin.dashboard) ~= "function" then
        plugin:log("warn", "this vclu has no plugin dashboards")
        return
    end
    local dash = plugin:dashboard("odczyty"):icon("speedometer2"):auth("session"):poll(10)
    -- bars from a plugin's own samples: vclu 1.14; before it the readings without the chart
    local chart = plugin:has("widget:bars")
    for _, m in ipairs(meters) do
        local id = m.id
        dash:section(m.name, m.icon)
            :status(id .. "_last", "Ostatni odczyt", m.icon, function()
                local list = readings[id] or {}
                if #list == 0 then return "—" end
                return show(m, list[#list].v) .. " · " .. plDate(dateOf(list[#list].t))
            end)
            :status(id .. "_day", "Średnio dziennie", "calendar-day", function()
                local s = readings[id] and summary(m)
                if not s or not s.perDay then return "—" end
                return fmt(s.perDay, math.min(3, m.decimals + 1))
            end, m.unit)
        if chart then
            dash:bars(id .. "_month", "Zużycie miesięcznie", function() return samples(m) end, {
                range = "365d", bucket = "1mo", agg = "sum", unit = m.unit, decimals = 1,
                compare = function() return yearBefore(m) end, compareLabel = "rok wcześniej", refresh = 300,
            })
        end
        dash:list(id .. "_readings", "Odczyty", function()
            local list, out = readings[id] or {}, {}
            for i = #list, 1, -1 do
                local r, prev = list[i], list[i - 1]
                local note = plDate(dateOf(r.t))
                if prev then note = note .. " · +" .. show(m, r.v - prev.v) end
                out[#out + 1] = { id = tostring(r.t), label = show(m, r.v), note = note }
            end
            return out
        end, {
            icon = "list-ol",
            placeholder = "1234,5 albo 1234,5 20.11",
            empty = "Brak odczytów: wpisz stan licznika",
            maxItems = 50,
            onAdd = function(text)
                local value, date = trim(text):match("^(%S+)%s*(.*)$")
                local r, err = plugin:addReading(id, value, date)
                if not r then return false, err end
                return r.text
            end,
            onDelete = function(rid)
                local list = readings[id] or {}
                for i, r in ipairs(list) do
                    if tostring(r.t) == tostring(rid) then
                        table.remove(list, i)
                        memo[id] = nil
                        save(id)
                        return "Usunięto odczyt " .. show(m, r.v) .. " z " .. plDate(dateOf(r.t))
                    end
                end
                error("nie ma takiego odczytu", 0)
            end,
        })
    end
    dash:section("Liczniki", "speedometer2")
        :list("meters", "Liczniki", function()
            local out = {}
            for i, m in ipairs(meters) do
                local n = #(readings[m.id] or {})
                out[i] = { id = m.id, label = m.name .. unitOf(m), note = n == 0 and "bez odczytów" or readingsCount(n) }
            end
            return out
        end, {
            icon = "speedometer2",
            placeholder = "Gaz, Woda m³, Podlicznik garaż kWh",
            empty = "Dodaj pierwszy licznik, np. Gaz",
            onAdd = function(text)
                local m, err = plugin:addMeter(text)
                if not m then return false, err end
                return "Dodano " .. m.name .. ". " .. REFRESH
            end,
            -- a meter goes only without readings: those are removed one by one, or by the agent
            onDelete = function(mid)
                if #(readings[mid] or {}) > 0 then
                    error("Najpierw usuń odczyty tego licznika", 0)
                end
                plugin:removeMeter(mid)
                return REFRESH
            end,
        })
        :build()
end

plugin:onInit(function()
    restore()
    ui.build()
    local n = 0
    for _, list in pairs(readings) do n = n + #list end
    plugin:log("info", #meters .. " meters, " .. n .. " readings")
end)

plugin:onCleanup(function()
    clear(listeners)
end)

return plugin
