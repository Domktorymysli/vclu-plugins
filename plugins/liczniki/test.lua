--- Tests for the liczniki plugin.
--
-- Run from the repository root:
--   lua plugins/liczniki/test.lua

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

-- as plugin.json declares it
local S = { type = "string" }
local env = harness.install({ dashboards = { odczyty = "Liczniki" }, actions = {
    add_reading = { params = { meter = { type = "string", required = true }, value = { type = "number", required = true }, date = S } },
    status = {},
    add_meter = { params = { name = { type = "string", required = true }, unit = S } },
    remove_reading = { params = { meter = { type = "string", required = true }, date = S }, confirm = true },
} })

local function at(date, hour)
    return datetime.parse(date).timestamp + (hour or 0) * 3600
end
env.now = at("2026-11-27", 18)

local plugin = dofile(here .. "/init.lua")
plugin._init({})
local DASH = "liczniki_odczyty"
local function dash() return env.dashboards[DASH] end

check("no setmetatable", io.open(here .. "/init.lua"):read("a"):find("setmetatable%s*%(") == nil)
check("no globals", rawget(_G, "dateOf") == nil and rawget(_G, "dayOf2") == nil and rawget(_G, "buildDashboard") == nil)
check("starts without meters", #plugin:meters() == 0 and plugin:status().text == "Nie ma jeszcze liczników.")
check("the dashboard has the meters list", dash().built and dash().widgets.meters ~= nil)

--------------------------------------------------------------------------------
-- Meters
--------------------------------------------------------------------------------

local gaz = plugin:addMeter("Gaz")
check("a known name brings its unit and icon", gaz.id == "gaz" and gaz.unit == "m³" and gaz.icon == "fire")
local ogrod = plugin:addMeter("Woda ogród m3")
check("a unit at the end of the name", ogrod.id == "woda_ogrod" and ogrod.name == "Woda ogród" and ogrod.unit == "m³")
local garaz = plugin:addMeter("Podlicznik garaż", "kwh")
check("a unit given apart", garaz.unit == "kWh" and garaz.icon == "lightning-charge")
local inny = plugin:addMeter("Licznik ciepłej wody")
check("a hot water meter is water", inny.unit == "m³" and inny.icon == "droplet")
plugin:removeMeter("licznik")
local _, err = plugin:addMeter("GAZ")
check("the same name twice is refused", err == "licznik „Gaz” już jest")
_, err = plugin:addMeter("  ")
check("an empty name is refused", err == "podaj nazwę licznika")
check("meters in order", #plugin:meters() == 3 and plugin:meters()[2].name == "Woda ogród")

--------------------------------------------------------------------------------
-- Readings
--------------------------------------------------------------------------------

local r = plugin:addReading("gaz", "1000", "2026-09-01")
check("the first reading", r and r.used == nil and r.text == "Gaz: 1000 m³ z 01.09.2026.")
r = plugin:addReading("Gaz", "1100,0", "1.10.2026")
check("the next one says the usage", r.used == 100 and r.days == 30
    and r.text == "Gaz: 1100,0 m³ z 01.10.2026. Od 01.09.2026: 100,0 m³ (3,33 m³ dziennie).")
_, err = plugin:addReading("gaz", 1050, "2026-10-20")
check("a reading below an earlier one is refused", err == "odczyt 1050,0 m³ jest mniejszy niż 1100,0 m³ z 01.10.2026")
_, err = plugin:addReading("gaz", 1150, "2026-09-15")
check("a reading above a later one is refused", err == "odczyt 1150,0 m³ jest większy niż późniejszy 1100,0 m³ z 01.10.2026")
r = plugin:addReading("gaz", 1050, "15.09")
check("a reading between two goes in between", r and plugin:readings("gaz")[2].v == 1050 and plugin:readings("gaz")[2].date == "2026-09-15")
r = plugin:addReading("gaz", 1040, "2026-09-15")
check("the same day replaces", r.replaced and #plugin:readings("gaz") == 3 and plugin:readings("gaz")[2].v == 1040)
r = plugin:addReading("gaz", 1170.25)
check("without a date it is today, at the time typed", r.date == "2026-11-27" and plugin:readings("gaz")[4].t == env.now
    and r.text:find("^Gaz: 1170,25 m³%.") ~= nil)
check("decimals follow what was typed", plugin:meters()[1].last.v == 1170.25)

_, err = plugin:addReading("gaz", "dużo")
check("not a number", err == "odczyt to liczba, np. 1234,5")
_, err = plugin:addReading("gaz", 1200, "2026-12-01")
check("a future date is refused", err == "data 01.12.2026 jest w przyszłości")
_, err = plugin:addReading("gaz", 1200, "31.02")
check("a day that does not exist", err == "nie ma takiego dnia: 31.02")
_, err = plugin:addReading("gaz", 1200, "jutro")
check("a date it does not understand", err:find("nie rozumiem daty") == 1)
_, err = plugin:addReading("gaz", 1200, "20.11.202")
check("a year of 3 digits", err ~= nil and err:find("nie rozumiem daty") == 1)
_, err = plugin:addReading("???", 5)
check("text without letters matches no meter", err ~= nil and err:find("nie ma licznika") == 1)
_, err = plugin:addReading("prąd", 5)
check("an unknown meter names the meters", err == "nie ma licznika „prąd” (są: Gaz, Woda ogród, Podlicznik garaż)")
_, err = plugin:addReading("wo", 200)
check("a prefix finds the only meter", err == nil)
check("a word of the name too", plugin:readings("garaż") ~= nil)
check("wczoraj", plugin:addReading("garaz", 10, "wczoraj").date == "2026-11-26")
check("20.12 typed in November is last December", plugin:addReading("garaz", 1, "20.12").date == "2025-12-20")

--------------------------------------------------------------------------------
-- Usage per day and the bars
--------------------------------------------------------------------------------

local bars = dash().widgets.gaz_month
check("a section per meter with its bars", bars and bars.opts.bucket == "1mo" and bars.opts.agg == "sum" and bars.opts.compare)
local samples = bars.source()
local sum, sep, oct = 0, 0, 0
for _, s in ipairs(samples) do
    sum = sum + s.v
    local d = datetime.fromTimestamp(s.t).date
    if d:sub(1, 7) == "2026-09" then sep = sep + s.v end
    if d:sub(1, 7) == "2026-10" then oct = oct + s.v end
end
local function near(a, b) return math.abs(a - b) < 1e-6 end
check("the days add up to the readings", near(sum, 170.25))
-- 12:00 on 1.09 to 12:00 on 15.09 is 40 m³, then 60 m³ to 12:00 on 1.10: 29.5 days of September
check("a month gets its share of the readings around it", near(sep, 40 + 60 * 15.5 / 16) and near(oct, 60 * 0.5 / 16 + 70.25 * (30.5 / (57 + 6 / 24))))
check("no day after the last reading", datetime.fromTimestamp(samples[#samples].t).date == "2026-11-27")

plugin:addReading("woda", 100, "2025-11-01")
plugin:addReading("woda", 130, "2025-12-01")
local cmp = dash().widgets.woda_ogrod_month.opts.compare()
check("compare is the same days a year later", #cmp > 0 and datetime.fromTimestamp(cmp[1].t).date:sub(1, 7) == "2026-11")

--------------------------------------------------------------------------------
-- Status, actions
--------------------------------------------------------------------------------

local st = plugin:status()
check("status per meter", #st.meters == 3 and st.meters[1].last.date == "2026-11-27" and st.meters[1].lastMonth ~= nil)
check("status sentence", st.text:find("^Gaz: 1170,25 m³ z 27%.11%.2026, średnio ") ~= nil)

r = env.callAction("add_reading", { meter = "garaż", value = 12.5 })
check("add_reading from an agent", r and r.value == 12.5 and r.used == 2.5)
r, err = env.callAction("add_reading", { meter = "garaż", value = "12" })
check("value is a number", r == nil and err == "value is a number")
r = env.callAction("add_meter", { name = "Prąd" })
check("add_meter rebuilds the dashboard", r.meter.unit == "kWh" and dash().widgets.prad_readings ~= nil)
r, err = env.callAction("remove_reading", { meter = "garaż" })
check("remove_reading asks for confirmation", r == nil and err == "asks for confirmation")
r = env.callAction("remove_reading", { meter = "garaż" }, true)
check("remove_reading takes the last", r.text == "Usunięto odczyt Podlicznik garaż: 12,5 kWh z 27.11.2026.")
r = env.callAction("remove_reading", { meter = "garaż", date = "20.12.2025" }, true)
check("remove_reading of a date", r and #plugin:readings("garaz") == 1)

--------------------------------------------------------------------------------
-- Dashboard
--------------------------------------------------------------------------------

local list = dash().widgets.gaz_readings
local items = list.getItems()
check("readings newest first with the usage", items[1].label == "1170,25 m³" and items[1].note:find("^27%.11%.2026 · %+70,25 m³") ~= nil
    and items[4].note == "01.09.2026")
local msg = env.submit(DASH, "gaz_readings", "1180,5 ")
check("a reading typed on the dashboard", type(msg) == "string" and plugin:readings("gaz")[4].v == 1180.5)
local ok, e = env.submit(DASH, "gaz_readings", "1000 wczoraj")
check("a refused one says why", ok == false and e:find("mniejszy niż") ~= nil)
check("a reading with a date", env.submit(DASH, "gaz_readings", "1175 26.11") and plugin:readings("gaz")[4].v == 1175)
local n = #plugin:readings("gaz")
list.opts.onDelete(list.getItems()[1].id)
check("delete on the dashboard", #plugin:readings("gaz") == n - 1)

local meters = dash().widgets.meters
ok, e = pcall(meters.opts.onDelete, "gaz")
check("a meter with readings is not deleted from the dashboard", not ok and tostring(e):find("Najpierw usuń odczyty") and #plugin:meters() == 4)
check("a meter without them is", meters.opts.onDelete("prad") and #plugin:meters() == 3 and dash().widgets.prad_readings == nil)
check("a meter added on the dashboard", env.submit(DASH, "meters", "Ciepło"):find("^Dodano Ciepło") and dash().widgets.cieplo_readings)
check("meters list notes", meters.getItems()[1].note == "4 odczyty" and meters.getItems()[4].note == "bez odczytów")

--------------------------------------------------------------------------------
-- Kept in the store
--------------------------------------------------------------------------------

local before = plugin:status().text
plugin._init({})
check("restored after a restart", plugin:status().text == before and #plugin:readings("gaz") == 4)

os.exit(harness.report())
