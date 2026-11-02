--- Tests for the pse-rce plugin.
--
-- Run from the repository root:
--   lua plugins/pse-rce/test.lua

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

-- UTC epoch of a date and time, for the fake clock: plain arithmetic,
-- so the time zone of the machine running the tests does not matter
local function utc(y, mo, d, h, mi)
    if mo <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * ((mo + 9) % 12) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + h * 3600 + (mi or 0) * 60
end

local clock = utc(2026, 11, 2, 9, 0) -- 10:00 in Poland (CET)
local realTime = os.time
os.time = function(t)
    if t then return realTime(t) end
    return clock
end

-- A day of 96 quarter-hours as PSE gives it: hour h (local) costs base + h * 10,
-- except the listed hours. Local midnight is at utcMidnight.
local function day(date, utcMidnight, base, special, quarters)
    local rows = {}
    for q = 0, (quarters or 96) - 1 do
        local localHour = math.floor(q / 4)
        local price = (special and special[localHour]) or (base + localHour * 10)
        local endTs = utcMidnight + (q + 1) * 900
        local startTs = endTs - 900
        rows[#rows + 1] = {
            dtime_utc = os.date("!%Y-%m-%d %H:%M:%S", endTs),
            period_utc = os.date("!%H:%M", startTs) .. " - " .. os.date("!%H:%M", endTs),
            rce_pln = price,
            business_date = date
        }
    end
    return rows
end

local published = {
    ["2026-11-02"] = day("2026-11-02", utc(2026, 11, 1, 23), 400, { [3] = 100, [4] = 120, [5] = 110, [14] = 50, [19] = 900 }),
}
local requests = {}

local env = harness.install({
    http = function(req)
        local date = tostring(req.url):match("%%27(%d+%-%d+%-%d+)%%27")
        requests[#requests + 1] = date
        if date == "2026-01-01" then return { status = 503 } end
        if date == "2026-02-02" then return { status = 200 } end
        return { status = 200, json = { value = published[date] or {} } }
    end
})

local plugin = dofile(here .. "/init.lua")

--------------------------------------------------------------------------------
-- FACTORY
--------------------------------------------------------------------------------

local ceny = plugin:create({ id = "rce", extra = 0.5, vat = 0.23 })
check("create returns an instance with its id", ceny:getId() == "rce")
check("duplicate id returns the same instance", plugin:create({ id = "rce" }) == ceny)
check("a non-number option is an error", not pcall(function() plugin:create({ id = "x", vat = "23" }) end))
check("polling is on by default", env.pollers["rce_rce"] ~= nil)
check("the price sensor is registered", env.sensors["rce_price"] ~= nil)

for _, name in ipairs({ "now", "price", "rce", "slots", "hours", "cheapest", "expensive",
                        "isCheap", "isExpensive", "on", "sensor", "refresh", "getState" }) do
    check("method " .. name .. " is on the instance", type(rawget(ceny, name)) == "function")
end
local src = io.open(here .. "/init.lua"):read("a")
check("plugin does not call setmetatable", src:find("setmetatable%s*%(") == nil)

--------------------------------------------------------------------------------
-- FETCH
--------------------------------------------------------------------------------

local gotPrices = {}
ceny:on("prices", function(date, hours) gotPrices[#gotPrices + 1] = { date = date, n = #hours } end)

env.tick("rce_rce")
check("before 13:00 only today is asked for", #requests == 1 and requests[1] == "2026-11-02")
check("the prices event names the day and its 24 hours",
      #gotPrices == 1 and gotPrices[1].date == "2026-11-02" and gotPrices[1].n == 24)
check("96 quarter-hours today", #ceny:slots("today") == 96)
check("prices are kept in KV", type(env.kv["days:rce"]) == "table" and env.kv["days:rce"]["2026-11-02"] ~= nil)

-- 10:00 local costs 400 + 10 * 10 = 500 zł/MWh
check("rce now in zł/MWh", ceny:rce() == 500)
check("price now: (0.5 + 0.5) * 1.23", ceny:now() == 1.23)
check("the sensor gives the price now", env.sensors["rce_price"]:get() == 1.23)
check("a moment with no data is nil", ceny:price(utc(2026, 11, 5, 12)) == nil)

env.tick("rce_rce")
check("a day already here is not asked for again", #requests == 1)

clock = utc(2026, 11, 2, 12, 30) -- 13:30 local
env.tick("rce_rce")
check("from 13:00 tomorrow is asked for", requests[#requests] == "2026-11-03")
check("tomorrow not published yet", not ceny:hasTomorrow())
local asked = #requests
clock = clock + 300
env.tick("rce_rce")
check("an unpublished day waits before it is asked again", #requests == asked)

published["2026-11-03"] = day("2026-11-03", utc(2026, 11, 2, 23), 300)
clock = clock + 600
env.tick("rce_rce")
check("tomorrow comes after the retry", ceny:hasTomorrow())
check("the prices event fired for tomorrow", gotPrices[#gotPrices].date == "2026-11-03")

--------------------------------------------------------------------------------
-- CHEAPEST AND MOST EXPENSIVE
--------------------------------------------------------------------------------

clock = utc(2026, 11, 2, 9, 0) -- 10:00 local again
local c = ceny:cheapest(2, { to = utc(2026, 11, 2, 23) })
check("two cheapest hours from now today: 10:00 at 500, then 14:00 at 50",
      c and #c == 2 and c[1].rce == 500 and c[2].rce == 50)
check("they come in time order", c[1].from < c[2].from)
check("each hour carries its price: (0.05 + 0.5) * 1.23", c[2].price == 0.6765)

local block = ceny:cheapest(3, { from = utc(2026, 11, 1, 23), to = utc(2026, 11, 2, 23), block = true })
check("cheapest block of 3 is 03:00-06:00 local", block and block[1].rce == 100 and block[3].rce == 110
      and block[1].from == utc(2026, 11, 2, 2) and block[3].to == utc(2026, 11, 2, 5))

local e = ceny:expensive(1, { to = utc(2026, 11, 2, 23) })
check("most expensive hour today is 19:00 at 900", e and e[1].rce == 900)
check("more hours than known is nil", ceny:cheapest(100) == nil)

--------------------------------------------------------------------------------
-- HOUR EVENTS
--------------------------------------------------------------------------------

local cheap, expensive, prices = {}, {}, {}
ceny:on("cheap", function(h) cheap[#cheap + 1] = h end)
ceny:on("expensive", function(h) expensive[#expensive + 1] = h end)
local off = ceny:on("price", function(p) prices[#prices + 1] = p end)

clock = utc(2026, 11, 2, 12, 0) -- 13:00 local
env.tick("rce_rce")
clock = utc(2026, 11, 2, 13, 0) -- 14:00 local, the cheapest hour
env.tick("rce_rce")
check("a cheap hour fires cheap", #cheap == 1 and cheap[1].rce == 50)
check("isCheap at a cheap hour", ceny:isCheap())
check("the price event fired on the new quarter", #prices >= 1 and prices[#prices] == ceny:now())

clock = utc(2026, 11, 2, 13, 5)
env.tick("rce_rce")
check("the same hour does not fire again", #cheap == 1)

clock = utc(2026, 11, 2, 18, 0) -- 19:00 local
env.tick("rce_rce")
check("an expensive hour fires expensive", #expensive == 1 and expensive[1].rce == 900)
check("isExpensive at an expensive hour", ceny:isExpensive())

-- the same price in the next quarter of the hour is no price event
local before = #prices
clock = utc(2026, 11, 2, 18, 15)
env.tick("rce_rce")
check("an unchanged price is no price event", #prices == before)

off()
clock = utc(2026, 11, 2, 19, 0) -- 20:00 local, another price
env.tick("rce_rce")
check("on() returns a function that removes the handler", #prices == before)
check("an unknown event is an error", not pcall(function() ceny:on("nonsense", function() end) end))

--------------------------------------------------------------------------------
-- RESTORE, DST, ERRORS
--------------------------------------------------------------------------------

local again = plugin:create({ id = "rce2", polling = false })
check("a second instance has its own sensor", env.sensors["rce2_price"] ~= nil)
env.kv["days:rce3"] = env.kv["days:rce"]
local restored = plugin:create({ id = "rce3", polling = false })
check("prices come back from KV after a reload", restored:rce() == ceny:rce())
check("restored prices take the new instance's extras", restored:now() == restored:rce() / 1000)

-- 2026-10-25: 100 quarter-hours (the clock goes back), local midnight 22:00 UTC
published["2026-10-25"] = day("2026-10-25", utc(2026, 10, 24, 22), 200, nil, 100)
clock = utc(2026, 10, 25, 1, 30) -- the repeated 02:30 local
local dst = plugin:create({ id = "dst" })
env.tick("rce_dst")
check("a 25-hour day has 100 quarter-hours", #dst:slots("2026-10-25") == 100)
check("a 25-hour day has 25 hours", #dst:hours("2026-10-25") == 25)

clock = utc(2026, 1, 1, 9)
local broken = plugin:create({ id = "broken" })
env.tick("rce_broken")
check("an HTTP error is kept in the state", broken:getState().lastError == "HTTP 503")
check("no prices after an error", broken:now() == nil)

--------------------------------------------------------------------------------
-- REVIEW FIXES: failing handler, tomorrow across DST, bad JSON, 23-hour day
--------------------------------------------------------------------------------

-- a handler that raises must not stop the tick from finishing
published["2026-06-01"] = day("2026-06-01", utc(2026, 5, 31, 22), 300)
clock = utc(2026, 6, 1, 8)
local loud = plugin:create({ id = "loud" })
loud:on("prices", function() error("boom") end)
local _, got = env.tick("rce_loud")
check("a failing prices handler does not stop the tick", got ~= nil)
check("the prices still came", loud:rce() == 300 + 10 * 10)

-- 2027-03-27 23:30 CET: tomorrow is 03-28 (a 23-hour day), not 03-29
requests = {}
clock = utc(2027, 3, 27, 22, 30)
local spring = plugin:create({ id = "spring" })
env.tick("rce_spring")
check("tomorrow before the spring clock change is the next calendar day",
      requests[#requests] == "2027-03-28")

-- 2026-10-25 00:30 CEST (Oct 24 22:30 UTC): tomorrow is 10-26, today 10-25
requests = {}
clock = utc(2026, 10, 24, 22, 30)
local autumn = plugin:create({ id = "autumn" })
env.tick("rce_autumn")
check("on the autumn change day today is asked for", requests[1] == "2026-10-25")

-- a 200 without JSON is an error, not "not published yet"
clock = utc(2026, 2, 2, 9)
local nojson = plugin:create({ id = "nojson" })
env.tick("rce_nojson")
check("an answer without JSON is kept as an error",
      nojson:getState().lastError ~= nil and nojson:getState().lastError:find("JSON") ~= nil)

-- 2026-03-29: 92 quarter-hours, local midnight 23:00 UTC the day before
published["2026-03-29"] = day("2026-03-29", utc(2026, 3, 28, 23), 200, nil, 92)
clock = utc(2026, 3, 29, 9)
local short = plugin:create({ id = "short" })
env.tick("rce_short")
check("a 23-hour day has 92 quarter-hours", #short:slots("2026-03-29") == 92)
check("a 23-hour day has 23 hours", #short:hours("2026-03-29") == 23)

--------------------------------------------------------------------------------
-- PR REVIEW: tomorrow on the autumn change day, blocks, cleanup, notify,
-- handlers removing themselves, option checks, refresh, tick errors
--------------------------------------------------------------------------------

-- 2026-10-25 00:30 CEST (Oct 24 22:30 UTC): +24 h would still be 10-25
published["2026-10-26"] = day("2026-10-26", utc(2026, 10, 25, 23), 250)
clock = utc(2026, 10, 25, 13) -- 14:00 CET: today and tomorrow come
local fall = plugin:create({ id = "fall" })
env.tick("rce_fall")
clock = utc(2026, 10, 24, 22, 30)
check("tomorrow at 00:30 on the autumn change day is 10-26",
      fall:hasTomorrow() and #fall:slots("tomorrow") == 96)

-- cheapest block across midnight, and never across a missing day
published["2026-12-01"] = day("2026-12-01", utc(2026, 11, 30, 23), 500, { [23] = 10 })
published["2026-12-02"] = day("2026-12-02", utc(2026, 12, 1, 23), 500, { [0] = 20 })
clock = utc(2026, 12, 1, 13) -- 14:00 CET on 12-01
local mid = plugin:create({ id = "mid" })
env.tick("rce_mid")
local b2 = mid:cheapest(2, { block = true })
check("a block of 2 can run across midnight",
      b2 and b2[1].rce == 10 and b2[2].rce == 20 and b2[2].from == utc(2026, 12, 1, 23))
-- 12-01 and 12-04 known, 12-02 and 12-03 not: 23:00 on 12-01 (10) and
-- 00:00 on 12-04 (20) sit next to each other in the list, but not in time
published["2026-12-04"] = day("2026-12-04", utc(2026, 12, 3, 23), 500, { [0] = 20 })
clock = utc(2026, 12, 3, 13) -- 14:00 CET on 12-03: tomorrow 12-04 comes
local src = plugin:create({ id = "src4" })
env.tick("rce_src4")
env.kv["days:gap"] = {
    ["2026-12-01"] = env.kv["days:mid"]["2026-12-01"],
    ["2026-12-04"] = env.kv["days:src4"]["2026-12-04"],
}
local g = plugin:create({ id = "gap", polling = false })
local gb = g:cheapest(2, { block = true, from = utc(2026, 12, 1, 12) })
check("a block never joins hours across a missing day",
      gb and gb[1].rce == 20 and gb[2].from == gb[1].to)

-- sensor notify on a new quarter
local notified = 0
env.sensors["rce_price"]._notify = function() notified = notified + 1 end
clock = utc(2026, 11, 2, 19, 15)
ceny._days["2026-11-02"] = ceny._days["2026-11-02"] -- still loaded
env.tick("rce_rce")
check("the price sensor is notified on a new quarter", notified == 1)

-- a handler that removes itself does not make the next one miss the event
local seen = {}
local offSelf
offSelf = ceny:on("expensive", function() seen[#seen + 1] = "a"; offSelf() end)
ceny:on("expensive", function() seen[#seen + 1] = "b" end)
ceny:_fire("expensive", {})
check("a handler removing itself does not skip the next", #seen == 2 and seen[2] == "b")

-- option checks
check("a numeric id is an error", not pcall(function() plugin:create({ id = 5 }) end))
check("fractional cheapHours is an error",
      not pcall(function() plugin:create({ id = "f", cheapHours = 2.5 }) end))
check("negative expensiveHours is an error",
      not pcall(function() plugin:create({ id = "n", expensiveHours = -1 }) end))

-- refresh asks again at once for what is missing
requests = {}
clock = utc(2026, 12, 4, 12, 30) -- 13:30 CET on 12-04, 12-05 not published
local fresh = plugin:create({ id = "fresh" })
env.tick("rce_fresh")
local n1 = #requests
env.tick("rce_fresh")
check("a missing day waits for the retry", #requests == n1)
fresh:refresh()
check("refresh asks for the missing day at once", #requests > n1)

-- a failed request reaches the poller as an error, a pending day does not
clock = utc(2026, 1, 1, 9)
local broken2 = plugin:create({ id = "broken2" })
local _, failed = env.tick("rce_broken2")
check("an HTTP error is passed to the poller", failed and failed.err == "HTTP 503")
clock = utc(2026, 11, 2, 9)
local ok2 = plugin:create({ id = "ok2" })
local _, fine = env.tick("rce_ok2")
check("a successful tick has no error", fine and fine.err == nil)

-- cleanup stops every poller
plugin._cleanup()
check("cleanup stops the pollers", env.pollers["rce_rce"].started == false
      and env.pollers["rce_fall"].started == false)

os.time = realTime
os.exit(harness.report())
