--- Tests for the solax plugin.
--
-- Run from the repository root:
--   lua plugins/solax/test.lua
--
-- The dongle prints today_e as "<int>.<hundredths>" without zero padding:
-- 8.09 kWh comes as "8.9", 0.07 kWh as "0.7".

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

local page = nil

local function statusPage(today, total)
    return 'var webdata_sn = "SF4ES006L94585  ";\n'
        .. 'var webdata_now_p = "330";\n'
        .. 'var webdata_today_e = "' .. today .. '";\n'
        .. 'var webdata_total_e = "' .. total .. '";\n'
end

local env = harness.install({
    http = function() return { status = 200, body = page } end
})

local plugin = dofile(here .. "/init.lua")
plugin._init({ host = "http://192.168.0.132" })

local function today(raw, total)
    page = statusPage(raw, total or "39970.0")
    env.tick("fetch")
    return env.sensors["today"].get()
end

local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end

check("two digits after the dot are hundredths", near(today("6.54"), 6.54))
check("one digit after the dot is hundredths too", near(today("8.9"), 8.09))
check("0.7 is 0.07 kWh", near(today("0.7"), 0.07))
check("a round tenth keeps its zero", near(today("7.70"), 7.70))
check("a whole number stays whole", near(today("12"), 12))
today("1.5", "39970.5")
check("total_e keeps one decimal as tenths", near(env.sensors["total"].get(), 39970.5))

local before = today("23.29")
check("--- at night keeps the last reading", near(today("---"), before))

os.exit(harness.report())
