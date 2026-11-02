--[[
    Ceny energii RCE (PSE) dla vCLU

    Fabryka obiektów z rynkową ceną energii (RCE) z publicznego API PSE:
    ceny na dziś i jutro co 15 minut, bez klucza i bez logowania.
    Na jutro PSE publikuje je około 14:00.

    Użycie:
        local rce = Plugin.getPlugin("@vclu/pse-rce")

        local ceny = rce:create({ id = "rce" })

        ceny:now()                        -- RCE teraz w zł/kWh
        ceny:cheapest(3)                  -- 3 godziny z najniższą RCE od teraz
        ceny:cheapest(2, { block = true }) -- 2 godziny pod rząd z najniższą RCE
        ceny:on("cheap", function(h) ... end)

]]

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local plugin = Plugin:new("pse-rce", {
    name = "Ceny energii RCE (PSE)",
    version = "0.1.0",
    description = "Factory for PSE market energy prices (RCE)"
})

local API = "https://api.raporty.pse.pl/api/rce-pln"
local TICK_S = 60          -- how often the price and the hour are checked
local RETRY_S = 10 * 60    -- a day that did not come is asked again after this
local TOMORROW_FROM = 13   -- local hour from which tomorrow is asked for
local KEEP_DAYS = 3        -- today and the days before it kept (tomorrow too)
local EVENTS = { prices = true, price = true, cheap = true, expensive = true }

--------------------------------------------------------------------------------
-- TIME (UTC epoch <-> Polish local time, without os.date's zone)
--------------------------------------------------------------------------------

-- Days since 1970-01-01 of a civil date (H. Hinnant's algorithm).
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function civilFromDays(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
        - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

-- 01:00 UTC of the last Sunday of a month: when Poland changes the clock.
local function lastSundayAt1(y, m)
    local nextMonth = m == 12 and daysFromCivil(y + 1, 1, 1) or daysFromCivil(y, m + 1, 1)
    local last = nextMonth - 1
    local weekday = (last + 4) % 7 -- 0 = Sunday (1970-01-01 was a Thursday)
    return (last - weekday) * 86400 + 3600
end

-- Offset of Polish time from UTC at a moment, in seconds.
local function plOffset(ts)
    local y = civilFromDays(math.floor(ts / 86400))
    if ts >= lastSundayAt1(y, 3) and ts < lastSundayAt1(y, 10) then return 7200 end
    return 3600
end

-- "YYYY-MM-DD" of the Polish day a moment falls in, moved by days
-- calendar days (not 24 h: a day with a clock change has 23 or 25).
local function plDateAdd(ts, days)
    local y, m, d = civilFromDays(math.floor((ts + plOffset(ts)) / 86400) + days)
    return string.format("%04d-%02d-%02d", y, m, d)
end

local function plDate(ts) return plDateAdd(ts, 0) end

local function plHour(ts)
    return math.floor(((ts + plOffset(ts)) % 86400) / 3600)
end

-- "YYYY-MM-DD HH:MM:SS" in UTC to an epoch.
local function parseUtc(s)
    local y, mo, d, h, mi, se = tostring(s):match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):?(%d*)")
    if not y then return nil end
    return daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + tonumber(h) * 3600 + tonumber(mi) * 60 + (tonumber(se) or 0)
end

-- Length of "23:45 - 24:00" in seconds (15 min, or 60 for older hourly data).
local function periodLength(p)
    local h1, m1, h2, m2 = tostring(p):match("(%d+):(%d+)%s*%-%s*(%d+):(%d+)")
    if not h1 then return 900 end
    local len = (tonumber(h2) * 60 + tonumber(m2)) - (tonumber(h1) * 60 + tonumber(m1))
    if len <= 0 then len = len + 24 * 60 end
    return len * 60
end

local function round(v, places)
    if v == nil then return nil end
    local f = 10 ^ places
    return math.floor(v * f + 0.5) / f
end

--------------------------------------------------------------------------------
-- PRICES CLASS
--------------------------------------------------------------------------------

-- Method table copied onto each instance. The plugin sandbox exposes no
-- setmetatable, so inheritance through __index is not available here.
local Prices = {}

function Prices:new(options)
    local obj = {
        _id = options.id or "rce",
        _extra = options.extra or 0,
        _vat = options.vat or 0,
        _multiplier = options.multiplier or 1,
        _cheapHours = options.cheapHours or 4,
        _expensiveHours = options.expensiveHours or 4,
        _days = {},       -- date -> { slots = { {from, to, rce}, ... }, hours = {...} }
        _tried = {},      -- date -> last request time
        _handlers = { prices = {}, price = {}, cheap = {}, expensive = {} },
        _slotFrom = nil,  -- start of the slot last checked
        _lastPrice = nil, -- price last announced by the price event
        _hourFrom = nil,  -- start of the hour whose events last ran
        _lastError = nil,
        _poller = nil,
        _sensor = nil
    }
    for name, fn in pairs(Prices) do obj[name] = fn end

    obj:_restore()
    obj._sensor = plugin:sensor(obj._id .. "_price", function() return obj:now() end)
    if options.polling ~= false then obj:_start() end
    return obj
end

--------------------------------------------------------------------------------
-- STORE
--------------------------------------------------------------------------------

-- Hourly averages of a day's slots, keyed in order of time.
local function toHours(slots)
    local hours, byStart = {}, {}
    for _, s in ipairs(slots) do
        local start = math.floor(s.from / 3600) * 3600
        local h = byStart[start]
        if not h then
            h = { from = start, to = start + 3600, sum = 0, n = 0 }
            byStart[start] = h
            hours[#hours + 1] = h
        end
        h.sum = h.sum + s.rce
        h.n = h.n + 1
    end
    for _, h in ipairs(hours) do
        h.rce = h.sum / h.n
        h.sum, h.n = nil, nil
    end
    table.sort(hours, function(a, b) return a.from < b.from end)
    return hours
end

-- The n hours of a day with the lowest (or highest) price, as a set of starts.
local function rankSet(hours, n, highest)
    local sorted = {}
    for i, h in ipairs(hours) do sorted[i] = h end
    table.sort(sorted, function(a, b)
        if highest then return a.rce > b.rce end
        return a.rce < b.rce
    end)
    local set = {}
    for i = 1, math.min(n, #sorted) do set[sorted[i].from] = true end
    return set
end

function Prices:_setDay(date, slots)
    table.sort(slots, function(a, b) return a.from < b.from end)
    local hours = toHours(slots)
    self._days[date] = {
        slots = slots,
        hours = hours,
        cheap = rankSet(hours, self._cheapHours, false),
        expensive = rankSet(hours, self._expensiveHours, true)
    }
end

function Prices:_restore()
    local saved = plugin:kvGet("days:" .. self._id, nil)
    if type(saved) ~= "table" then return end
    for date, list in pairs(saved) do
        local slots = {}
        for _, s in ipairs(list) do
            slots[#slots + 1] = { from = s[1], to = s[2], rce = s[3] }
        end
        if #slots > 0 then self:_setDay(date, slots) end
    end
    self:_prune()
end

function Prices:_save()
    local out = {}
    for date, day in pairs(self._days) do
        local list = {}
        for _, s in ipairs(day.slots) do list[#list + 1] = { s.from, s.to, s.rce } end
        out[date] = list
    end
    plugin:kvSet("days:" .. self._id, out)
end

-- Drops days older than KEEP_DAYS.
function Prices:_prune()
    local oldest = plDateAdd(os.time(), -(KEEP_DAYS - 1))
    for date in pairs(self._days) do
        if date < oldest then self._days[date] = nil end
    end
end

--------------------------------------------------------------------------------
-- FETCH
--------------------------------------------------------------------------------

function Prices:_fetch(date, callback)
    self._tried[date] = os.time()
    local url = API .. "?$filter=business_date%20eq%20%27" .. date .. "%27"
    plugin:httpRequest({ url = url, timeout = 15000, parseJson = "success" }, function(resp)
        if resp.err then
            self._lastError = resp.err
            plugin:log("warn", "RCE " .. date .. ": " .. tostring(resp.err))
            callback(resp.err)
            return
        end
        if type(resp.json) ~= "table" then
            self._lastError = "RCE " .. date .. ": no JSON in the answer"
            plugin:log("warn", self._lastError)
            callback(self._lastError)
            return
        end
        local rows = resp.json.value
        if type(rows) ~= "table" or #rows == 0 then
            -- not published yet (tomorrow before ~14:00): no error
            callback(nil)
            return
        end
        local slots = {}
        for _, r in ipairs(rows) do
            local to = parseUtc(r.dtime_utc)
            local price = tonumber(r.rce_pln)
            if to and price then
                slots[#slots + 1] = { from = to - periodLength(r.period_utc), to = to, rce = price }
            end
        end
        if #slots == 0 then
            self._lastError = "RCE " .. date .. ": no readable rows"
            plugin:log("warn", self._lastError)
            callback(self._lastError)
            return
        end
        self._lastError = nil
        self:_setDay(date, slots)
        self:_prune()
        self:_save()
        plugin:log("info", string.format("RCE %s: %d prices", date, #slots))
        self:_fire("prices", date, self:hours(date))
        callback(nil)
    end)
end

-- Asks for today, and from TOMORROW_FROM for tomorrow, until they come;
-- done(err) gets the last request error, nil when there was none.
function Prices:_fetchMissing(done)
    local now = os.time()
    local wanted = { plDate(now) }
    if plHour(now) >= TOMORROW_FROM then wanted[#wanted + 1] = plDateAdd(now, 1) end

    local pending = {}
    for _, date in ipairs(wanted) do
        local last = self._tried[date] or 0
        if not self._days[date] and now - last >= RETRY_S then pending[#pending + 1] = date end
    end
    if #pending == 0 then return done() end

    -- the count lives in a table: after an error caught by pcall (a
    -- user handler in _fire) gopher-lua can detach a captured local
    local wait = { left = #pending, err = nil }
    for _, date in ipairs(pending) do
        self:_fetch(date, function(err)
            if err then wait.err = err end
            wait.left = wait.left - 1
            if wait.left == 0 then done(wait.err) end
        end)
    end
end

--------------------------------------------------------------------------------
-- TICK: price changes and hour events
--------------------------------------------------------------------------------

function Prices:_slotAt(ts)
    local day = self._days[plDate(ts)]
    if not day then return nil end
    for _, s in ipairs(day.slots) do
        if ts >= s.from and ts < s.to then return s end
    end
    return nil
end

function Prices:_hourAt(ts)
    local day = self._days[plDate(ts)]
    if not day then return nil, nil end
    for _, h in ipairs(day.hours) do
        if ts >= h.from and ts < h.to then return h, day end
    end
    return nil, nil
end

function Prices:_check()
    local now = os.time()
    local slot = self:_slotAt(now)
    if slot and slot.from ~= self._slotFrom then
        self._slotFrom = slot.from
        if self._sensor and self._sensor._notify then self._sensor:_notify() end
        local price = self:now()
        if price ~= self._lastPrice then
            self._lastPrice = price
            self:_fire("price", price)
        end
    end

    local hour, day = self:_hourAt(now)
    if hour and hour.from ~= self._hourFrom then
        -- the first hour after a start or reload only sets the mark
        local first = self._hourFrom == nil
        self._hourFrom = hour.from
        if not first then
            if day.cheap[hour.from] then self:_fire("cheap", self:_view(hour)) end
            if day.expensive[hour.from] then self:_fire("expensive", self:_view(hour)) end
        end
    end
end

function Prices:_start()
    if self._poller then return end
    self._poller = plugin:poller("rce_" .. self._id, {
        interval = TICK_S * 1000,
        immediate = true,
        timeout = 30000,
        onTick = function(done)
            self:_fetchMissing(function(err)
                self:_check()
                -- a failed request shows in the poller stats; the price and
                -- the hour were checked anyway
                if err then done(nil, err) else done() end
            end)
        end,
        onError = function(err)
            plugin:log("warn", "RCE " .. self._id .. ": " .. tostring(err))
        end
    })
    self._poller:start()
end

function Prices:_stop()
    if self._poller then
        self._poller:stop()
        self._poller = nil
    end
end

function Prices:_fire(event, ...)
    -- a copy: a handler may remove itself (or another) while it runs
    local list = {}
    for i, fn in ipairs(self._handlers[event]) do list[i] = fn end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then plugin:log("error", "RCE " .. event .. " handler: " .. tostring(err)) end
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--- Price in zł/kWh from an RCE in zł/MWh: (rce / 1000 * multiplier + extra) * (1 + vat).
function Prices:toPrice(rce)
    if rce == nil then return nil end
    return round((rce / 1000 * self._multiplier + self._extra) * (1 + self._vat), 4)
end

function Prices:_view(item)
    return {
        from = item.from,
        to = item.to,
        rce = round(item.rce, 2),
        price = self:toPrice(item.rce)
    }
end

--- Price in zł/kWh at a moment (default now), with the extras; nil when unknown.
function Prices:price(at)
    local s = self:_slotAt(at or os.time())
    return s and self:toPrice(s.rce) or nil
end

function Prices:now() return self:price() end

--- RCE in zł/MWh at a moment (default now), as PSE gives it; nil when unknown.
function Prices:rce(at)
    local s = self:_slotAt(at or os.time())
    return s and s.rce or nil
end

local function dateOf(day)
    if day == nil or day == "today" then return plDate(os.time()) end
    if day == "tomorrow" then return plDateAdd(os.time(), 1) end
    return day
end

--- Quarter-hours of a day ("today", "tomorrow" or "YYYY-MM-DD"): { {from, to, rce, price}, ... }.
function Prices:slots(day)
    local d = self._days[dateOf(day)]
    local out = {}
    if not d then return out end
    for i, s in ipairs(d.slots) do out[i] = self:_view(s) end
    return out
end

--- Hourly averages of a day: { {from, to, rce, price}, ... }.
function Prices:hours(day)
    local d = self._days[dateOf(day)]
    local out = {}
    if not d then return out end
    for i, h in ipairs(d.hours) do out[i] = self:_view(h) end
    return out
end

function Prices:hasTomorrow()
    return self._days[plDateAdd(os.time(), 1)] ~= nil
end

-- Known hours ending after from and starting before to, in time order.
function Prices:_window(opts)
    local from = opts.from or os.time()
    local to = opts.to or math.huge
    local list = {}
    for _, d in pairs(self._days) do
        for _, h in ipairs(d.hours) do
            if h.to > from and h.from < to then list[#list + 1] = h end
        end
    end
    table.sort(list, function(a, b) return a.from < b.from end)
    return list
end

-- The n hours with the lowest (highest) price, or the n hours in a row with the
-- lowest (highest) average when opts.block; nil when fewer than n are known.
function Prices:_pick(n, opts, highest)
    opts = opts or {}
    n = n or 1
    local list = self:_window(opts)
    if #list < n then return nil end

    local function better(a, b)
        if highest then return a > b end
        return a < b
    end

    local chosen = {}
    if opts.block then
        local best, bestAt = nil, nil
        for i = 1, #list - n + 1 do
            local sum, joined = 0, true
            for j = i, i + n - 1 do
                sum = sum + list[j].rce
                if j > i and list[j].from ~= list[j - 1].to then joined = false end
            end
            if joined and (best == nil or better(sum, best)) then best, bestAt = sum, i end
        end
        if not bestAt then return nil end
        for j = bestAt, bestAt + n - 1 do chosen[#chosen + 1] = list[j] end
    else
        local sorted = {}
        for i, h in ipairs(list) do sorted[i] = h end
        table.sort(sorted, function(a, b) return better(a.rce, b.rce) end)
        for i = 1, n do chosen[i] = sorted[i] end
        table.sort(chosen, function(a, b) return a.from < b.from end)
    end

    local out = {}
    for i, h in ipairs(chosen) do out[i] = self:_view(h) end
    return out
end

--- The n cheapest hours from now (opts: from, to, block).
function Prices:cheapest(n, opts) return self:_pick(n, opts, false) end

--- The n most expensive hours from now (opts: from, to, block).
function Prices:expensive(n, opts) return self:_pick(n, opts, true) end

--- Whether the hour of a moment (default now) is one of the day's cheapHours cheapest.
function Prices:isCheap(at)
    local h, day = self:_hourAt(at or os.time())
    return h ~= nil and day.cheap[h.from] == true
end

--- Whether the hour of a moment is one of the day's expensiveHours most expensive.
function Prices:isExpensive(at)
    local h, day = self:_hourAt(at or os.time())
    return h ~= nil and day.expensive[h.from] == true
end

--- Calls fn on an event; returns a function that removes it.
-- prices(date, hours): a day's prices came; price(zł/kWh): the price changed
-- (every 15 min); cheap(hour) / expensive(hour): such an hour has begun.
function Prices:on(event, fn)
    if not EVENTS[event] then error("pse-rce: unknown event '" .. tostring(event) .. "'") end
    if type(fn) ~= "function" then error("pse-rce: on() needs a function") end
    local list = self._handlers[event]
    list[#list + 1] = fn
    return function()
        for i, f in ipairs(list) do
            if f == fn then
                table.remove(list, i)
                return
            end
        end
    end
end

--- Sensor with the price now in zł/kWh, for expose() and metrics.
function Prices:sensor() return self._sensor end

--- Ask PSE again for what is missing.
function Prices:refresh()
    self._tried = {}
    if self._poller then self._poller:poll() end
end

function Prices:getId() return self._id end

function Prices:getState()
    local days = {}
    for date in pairs(self._days) do days[#days + 1] = date end
    table.sort(days)
    return {
        id = self._id,
        price = self:now(),
        rce = self:rce(),
        days = days,
        tomorrow = self:hasTomorrow(),
        cheap = self:isCheap(),
        expensive = self:isExpensive(),
        lastError = self._lastError
    }
end

--------------------------------------------------------------------------------
-- PLUGIN FACTORY
--------------------------------------------------------------------------------

local instances = {}

plugin:onInit(function(config)
    plugin:log("info", "RCE factory ready")
end)

plugin:onCleanup(function()
    for _, p in ipairs(instances) do p:_stop() end
    instances = {}
    plugin:log("info", "RCE cleanup")
end)

--- Create a price object
-- @param options table { id, extra, vat, multiplier, cheapHours, expensiveHours, polling }
-- @return Prices
function plugin:create(options)
    options = options or {}
    if options.id ~= nil and (type(options.id) ~= "string" or options.id == "") then
        error("pse-rce:create: id must be a non-empty string")
    end
    local id = options.id or "rce"
    for _, p in ipairs(instances) do
        if p._id == id then
            plugin:log("error", "RCE: duplicate id '" .. id .. "', returning the existing one")
            return p
        end
    end
    for _, k in ipairs({ "extra", "vat", "multiplier", "cheapHours", "expensiveHours" }) do
        if options[k] ~= nil and type(options[k]) ~= "number" then
            error("pse-rce:create: " .. k .. " must be a number")
        end
    end
    for _, k in ipairs({ "cheapHours", "expensiveHours" }) do
        local n = options[k]
        if n ~= nil and (n < 0 or n ~= math.floor(n)) then
            error("pse-rce:create: " .. k .. " must be a whole number, 0 or more")
        end
    end

    local p = Prices:new(options)
    instances[#instances + 1] = p
    plugin:log("info", "Created: " .. id)
    return p
end

function plugin:getInstances()
    return instances
end

return plugin
