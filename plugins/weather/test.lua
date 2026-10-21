--- Tests for the weather plugin: current weather icon and the 5-day forecast.
--
-- Run from the repository root:
--   lua plugins/weather/test.lua
--
-- No request leaves the machine: HTTP answers come from the tables below.

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

local T0 = 1792800000      -- 2026-10-24 00:00 UTC
local DST_END = 1792890000 -- 2026-10-25 01:00 UTC, Warsaw goes from +2 to +1

-- /data/2.5/forecast for Warsaw, fetched on 2026-10-23 evening (city.timezone
-- is still +7200). Rows: UTC hour, temp, condition id, pod, pop, rain, snow.
local ROWS = {
    -- 2026-10-24: sunny noon, fog in the morning
    { 0, 6.1, 800, "n", 0, 0 }, { 3, 5.2, 800, "n", 0, 0 }, { 6, 5.0, 701, "d", 0, 0 },
    { 9, 11.4, 800, "d", 0, 0 }, { 12, 14.8, 803, "d", 0, 0 }, { 15, 12.9, 802, "d", 0.05, 0 },
    { 18, 9.3, 801, "n", 0, 0 }, { 21, 7.7, 800, "n", 0, 0 },
    -- 2026-10-25: DST ends at 01:00 UTC; 09 UTC is 10:00 local, 12 UTC is 13:00
    { 0, 6.9, 802, "n", 0, 0 }, { 3, 6.0, 803, "n", 0, 0 }, { 6, 6.4, 803, "d", 0, 0 },
    { 9, 10.2, 801, "d", 0.1, 0 }, { 12, 12.6, 804, "d", 0.1, 0 }, { 15, 11.1, 804, "d", 0.15, 0 },
    { 18, 9.0, 804, "n", 0.2, 0 }, { 21, 8.4, 804, "n", 0.2, 0 },
    -- 2026-10-26: rain in the afternoon
    { 0, 8.1, 804, "n", 0.1, 0 }, { 3, 7.6, 804, "n", 0.1, 0 }, { 6, 7.9, 804, "d", 0.2, 0 },
    { 9, 10.5, 803, "d", 0.3, 0 }, { 12, 11.8, 803, "d", 0.4, 0 }, { 15, 10.4, 501, "d", 0.8, 1.2 },
    { 18, 9.1, 500, "n", 0.6, 0.4 }, { 21, 8.7, 500, "n", 0.5, 0.3 },
    -- 2026-10-27: heavy rain at night, drizzle by day
    { 0, 8.2, 501, "n", 0.9, 2.1 }, { 3, 7.8, 502, "n", 1, 5.0 }, { 6, 7.5, 804, "d", 0.7, 0 },
    { 9, 8.9, 300, "d", 0.5, 0.2 }, { 12, 9.6, 804, "d", 0.3, 0 }, { 15, 9.0, 804, "d", 0.2, 0 },
    { 18, 6.5, 803, "n", 0.1, 0 }, { 21, 4.9, 802, "n", 0, 0 },
    -- 2026-10-28: wet snow in the morning
    { 0, 2.3, 804, "n", 0.2, 0 }, { 3, 0.8, 804, "n", 0.25, 0 }, { 6, 0.4, 600, "d", 0.3, 0, 0.5 },
    { 9, 2.1, 804, "d", 0.2, 0 }, { 12, 3.6, 804, "d", 0.1, 0 }, { 15, 3.0, 803, "d", 0, 0 },
    { 18, 1.2, 800, "n", 0, 0 }, { 21, -0.4, 800, "n", 0, 0 },
}

local MAIN = { [200] = "Thunderstorm", [300] = "Drizzle", [500] = "Rain", [501] = "Rain",
               [502] = "Rain", [600] = "Snow", [701] = "Mist", [800] = "Clear" }

local function forecastJson(rows, timezone)
    local list = {}
    for i, r in ipairs(rows) do
        local dt = T0 + (i - 1) * 3 * 3600
        local step = {
            dt = dt,
            main = { temp = r[2], feels_like = r[2] - 2, temp_min = r[2], temp_max = r[2],
                     pressure = 1012, sea_level = 1012, grnd_level = 1003, humidity = 80, temp_kf = 0 },
            weather = { { id = r[3], main = MAIN[r[3]] or "Clouds", description = "", icon = "04" .. r[4] } },
            clouds = { all = r[3] >= 803 and 90 or 20 },
            wind = { speed = 3.4, deg = 240, gust = 6.1 },
            visibility = 10000,
            pop = r[5],
            sys = { pod = r[4] },
            dt_txt = os.date("!%Y-%m-%d %H:%M:%S", dt)
        }
        if r[6] > 0 then step.rain = { ["3h"] = r[6] } end
        if r[7] then step.snow = { ["3h"] = r[7] } end
        list[#list + 1] = step
    end
    return {
        cod = "200", message = 0, cnt = #list, list = list,
        city = { id = 756135, name = "Warsaw", coord = { lat = 52.2298, lon = 21.0118 },
                 country = "PL", population = 1000000, timezone = timezone or 7200,
                 sunrise = 1792820000, sunset = 1792856000 }
    }
end

local answers = {
    forecast = { status = 200, json = forecastJson(ROWS) },
    weather = { status = 200, json = {
        coord = { lon = 21.01, lat = 52.23 },
        weather = { { id = 500, main = "Rain", description = "light rain", icon = "10n" } },
        main = { temp = 7.3, feels_like = 4.9, pressure = 1009, humidity = 91 },
        wind = { speed = 4.1, deg = 250 }, clouds = { all = 100 }, rain = { ["1h"] = 0.4 },
        dt = 1792790000, timezone = 7200, name = "Warsaw", cod = 200
    } }
}

local env = harness.install({
    http = function(req)
        local url = tostring(req.url)
        if url:find("api%.openweathermap%.org/data/2%.5/forecast") then return answers.forecast end
        if url:find("api%.openweathermap%.org/data/2%.5/weather") then return answers.weather end
        return { err = "unexpected request " .. url }
    end
})

local weather = dofile(here .. "/init.lua")

-- Europe/Warsaw as datetime.fromTimestamp sees it, for the end of October 2026.
local function warsawDatetime()
    return {
        timezone = function() return "Europe/Warsaw" end,
        fromTimestamp = function(ts)
            local t = os.date("!*t", ts + (ts < DST_END and 7200 or 3600))
            return { date = string.format("%04d-%02d-%02d", t.year, t.month, t.day), hour = t.hour }
        end
    }
end

--------------------------------------------------------------------------------
-- STARTING ON DEMAND
--------------------------------------------------------------------------------

check("no forecast before init", weather:getForecast() == nil)
check("no forecast poller before init", env.pollers["forecast"] == nil)

local config = { apiKey = "test-key", city = "Warsaw", units = "metric" }
weather.config = config
weather._init(config)
check("init does not start the forecast", env.pollers["forecast"] == nil)

check("the first call returns nil", weather:getForecast() == nil)
local fp = env.pollers["forecast"]
check("the first call starts the forecast poller", fp ~= nil and fp.started)
weather:getForecast()
check("a second call keeps the same poller", env.pollers["forecast"] == fp)

--------------------------------------------------------------------------------
-- DAYS IN THE HOUSE'S ZONE (datetime.setTimezone("Europe/Warsaw"))
--------------------------------------------------------------------------------

_G.datetime = warsawDatetime()
local ticked, got = env.tick("forecast")
check("the forecast tick succeeds", ticked and got and got.err == nil)

local req = env.http[#env.http]
check("the forecast comes from /data/2.5/forecast", req.url:find("^https://api%.openweathermap%.org/data/2%.5/forecast%?"))
check("with the configured city, units and key",
      req.url:find("q=Warsaw") and req.url:find("units=metric") and req.url:find("appid=test%-key"))

local f = weather:getForecast()
check("getForecast returns the forecast", type(f) == "table")
check("updated is a timestamp", type(f.updated) == "number" and f.updated > 0)
check("40 hourly steps", #f.hours == 40)
check("a step has at, temp, rain and icon", f.hours[1].at == T0 and f.hours[1].temp == 6.1
      and f.hours[1].rain == 0 and f.hours[1].icon == "moon")
check("steps are 3 h apart", f.hours[40].at == T0 + 39 * 3 * 3600)
check("a step's rain is rain plus snow", f.hours[23].rain == 0.4 and f.hours[35].rain == 0.5)
check("night and day icons per step", f.hours[2].icon == "moon" and f.hours[4].icon == "sun"
      and f.hours[3].icon == "cloud-fog2" and f.hours[7].icon == "cloud-moon")

local dates = {}
for i, d in ipairs(f.days) do dates[i] = d.date end
check("five local days", table.concat(dates, ",") == "2026-10-24,2026-10-25,2026-10-26,2026-10-27,2026-10-28")

local function day(date)
    for _, d in ipairs(f.days) do if d.date == date then return d end end
end
local d24, d25, d26, d27, d28 = day("2026-10-24"), day("2026-10-25"), day("2026-10-26"),
    day("2026-10-27"), day("2026-10-28")

check("min and max of the day's steps", d24.min == 5.0 and d24.max == 14.8)
check("a dry day has no rain", d24.rain == 0 and d24.pop == 0.05)
check("a sunny noon wins over morning fog", d24.icon == "sun")
check("after the DST change the noon step is 12 UTC (13:00 CET)", d25.icon == "clouds")
check("the DST day keeps its 8 steps", d25.min == 6.0 and d25.max == 12.6)
check("rain is summed over the day", d26.rain == 1.9)
check("pop is the day's highest", d26.pop == 0.8)
check("afternoon rain wins over a cloudy noon", d26.icon == "cloud-rain")
check("night rain counts in the sum", d27.rain == 7.3 and d27.pop == 1)
check("daytime weather sets the icon, not the night", d27.icon == "cloud-drizzle")
check("snow counts as precipitation", d28.rain == 0.5 and d28.icon == "cloud-snow")
check("a frosty night is the minimum", d28.min == -0.4)
check("days carry only the documented fields", (function()
    for k in pairs(d24) do
        if not ({ date = 1, icon = 1, min = 1, max = 1, rain = 1, pop = 1 })[k] then return false end
    end
    return true
end)())

--------------------------------------------------------------------------------
-- WITHOUT datetime: the city's offset from OWM
--------------------------------------------------------------------------------

_G.datetime = { timezone = function() return "" end, fromTimestamp = function() error("unused") end }
env.tick("forecast")
f = weather:getForecast()
dates = {}
for i, d in ipairs(f.days) do dates[i] = d.date end
check("no zone set: the same days from city.timezone",
      table.concat(dates, ",") == "2026-10-24,2026-10-25,2026-10-26,2026-10-27,2026-10-28")
check("a fixed offset misses the DST change: noon is still 09 UTC", f.days[2].icon == "cloud-sun")

_G.datetime = nil
answers.forecast = { status = 200, json = forecastJson({
    { 0, 1, 800, "n", 0, 0 }, { 3, 1, 800, "n", 0, 0 }, { 6, 1, 800, "d", 0, 0 },
    { 9, 1, 800, "d", 0, 0 }, { 12, 1, 800, "d", 0, 0 }, { 15, 1, 800, "d", 0, 0 },
    { 18, 1, 800, "n", 0, 0 }, { 21, 2, 800, "n", 0, 0 }
}, 10800) }
env.tick("forecast")
f = weather:getForecast()
check("at +3 h the 21 UTC step is the next local day",
      #f.days == 2 and f.days[2].date == "2026-10-25" and f.days[2].min == 2)

--------------------------------------------------------------------------------
-- ERRORS
--------------------------------------------------------------------------------

answers.forecast = { err = "connection refused" }
local _, failed = env.tick("forecast")
check("a refused request is done(nil, err)", failed.data == nil and failed.err == "connection refused")
check("the last forecast is kept", weather:getForecast() == f)

answers.forecast = { status = 401, json = { cod = 401, message = "Invalid API key" } }
_, failed = env.tick("forecast")
check("an HTTP error is done(nil, err)", failed.err == "HTTP 401")

answers.forecast = { status = 200, json = { cod = "200" } }
_, failed = env.tick("forecast")
check("a reply without list is done(nil, err)", failed.data == nil and failed.err:find("missing list"))

--------------------------------------------------------------------------------
-- CURRENT WEATHER ICON
--------------------------------------------------------------------------------

env.tick("fetch")
check("current weather gets a Bootstrap icon", weather:getData().icon == "cloud-rain")
check("and so does the registry object", env.objects["current"].icon == "cloud-rain")
check("existing fields stay", weather:getData().temp == 7.3 and weather:getCondition() == "Rain")

answers.weather.json.weather = { { id = 800, main = "Clear", description = "clear sky", icon = "01n" } }
env.tick("fetch")
check("a clear night is the moon", weather:getData().icon == "moon")

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------

weather._cleanup()
check("cleanup stops the forecast poller", fp.started == false)

os.exit(harness.report())
