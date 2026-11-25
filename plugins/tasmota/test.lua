--- Tests for the tasmota plugin.
--
-- Run from the repository root:
--   lua plugins/tasmota/test.lua
--
-- A fake network: 192.168.1.20 is a two-relay device with a power meter,
-- 192.168.1.30 a one-relay plug, everything else does not answer.

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

local state = { ["192.168.1.20"] = { "OFF", "ON" }, ["192.168.1.30"] = { "ON" } }

local function answer(ip, cmnd)
    local relays = state[ip]
    if cmnd == "Status 0" then
        local sts = {}
        if #relays == 1 then sts.POWER = relays[1]
        else for i, v in ipairs(relays) do sts["POWER" .. i] = v end end
        local json = {
            Status = { DeviceName = "Dev " .. ip, FriendlyName = #relays > 1 and { "Lampa", "Wentylator" } or { "Gniazdko" } },
            StatusNET = { Hostname = ip == "192.168.1.20" and "tasmota-AB12CD-1234" or "nous-a1t", IPAddress = ip },
            StatusSTS = sts,
        }
        if ip == "192.168.1.20" then json.StatusSNS = { ENERGY = { Power = { 12, 30 } } } end
        return json
    end
    if cmnd == "Status 11" then
        local sts = {}
        for i, v in ipairs(relays) do sts["POWER" .. i] = v end
        if #relays == 1 then sts = { POWER = relays[1] } end
        return { StatusSTS = sts }
    end
    if cmnd == "Status 10" then return { StatusSNS = { ENERGY = { Power = 42.5 } } } end
    local n, what = cmnd:match("^Power(%d) (%u+)$")
    if n then
        n = tonumber(n)
        if what == "TOGGLE" then what = relays[n] == "ON" and "OFF" or "ON" end
        relays[n] = what
        if #relays == 1 then return { POWER = what } end
        return { ["POWER" .. n] = what }
    end
end

local function decode(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local env = harness.install({
    http = function(req)
        local ip, cmnd = req.url:match("^http://([%d%.]+)/cm%?cmnd=([^&]*)")
        if not state[ip] then return { err = "timeout" } end
        return { status = 200, json = answer(ip, decode(cmnd)) }
    end
})

local plugin = dofile(here .. "/init.lua")
plugin._init({ interval = 10 })

--------------------------------------------------------------------------------
-- Discover
--------------------------------------------------------------------------------

local found, foundErr
plugin._discover({ subnet = "192.168.1.0/24" }, function(rows, err) found, foundErr = rows, err end)
check("discover answers", found ~= nil and foundErr == nil)
check("three relays on two devices", found and #found == 3)
local byId = {}
for _, r in ipairs(found or {}) do byId[r.id] = r end
check("a two-relay device gives a row per relay", byId["tasmota_ab12cd_1234_1"] and byId["tasmota_ab12cd_1234_2"]
    and byId["tasmota_ab12cd_1234_2"].relay == 2)
check("names come from FriendlyName", byId["tasmota_ab12cd_1234_2"].name == "Wentylator")
check("the meter goes with relay 1", byId["tasmota_ab12cd_1234_1"].power == true and byId["tasmota_ab12cd_1234_2"].power == false)
check("a one-relay plug", byId["nous_a1t"] and byId["nous_a1t"].relay == 1 and byId["nous_a1t"].ip == "192.168.1.30")
check("the whole /24 was asked", #env.http >= 254)

local _, badErr
plugin._discover({ subnet = "192.168.1.0/16" }, function(rows, err) badErr = err end)
check("a network other than /24 is refused", badErr ~= nil)

--------------------------------------------------------------------------------
-- Factory: one device per address, relays, power
--------------------------------------------------------------------------------

local dev = plugin:device({ ip = "192.168.1.20" })
check("same address, same device", plugin:device("192.168.1.20") == dev)
local r1, r2 = dev:relay(1), dev:relay(2)
check("same relay, same object", dev:relay(2) == r2)
check("relay out of range is an error", not pcall(dev.relay, dev, 9))
check("bad ip is an error", not pcall(plugin.device, plugin, { ip = "x y" }))
check("no setmetatable", io.open(here .. "/init.lua"):read("a"):find("setmetatable%s*%(") == nil)

local power = dev:power()
local seen = {}
local off = r2:onChange(function(v, old) seen[#seen + 1] = { v, old } end)
env.tick("tasmota_192_168_1_20")
check("the poller reads relays", r1:getValue() == 0 and r2:getValue() == 1)
check("and power", power:getValue() == 42.5)
check("first reading is a change from nil", seen[1] and seen[1][1] == 1 and seen[1][2] == nil)

r2:switchOff()
check("switchOff sends Power2 OFF and updates", state["192.168.1.20"][2] == "OFF" and r2:getValue() == 0)
check("onChange sees it", seen[2] and seen[2][1] == 0 and seen[2][2] == 1)
off()
r2:set(nil, 1)
check("set(_, 1) switches on", r2:isOn())
check("unsubscribed callback is quiet", #seen == 2)

-- the password is the plugin's secret and goes only to the device
env.secrets.password = "p@ss word"
r1:toggle()
local last = env.http[#env.http].url
check("password in the request", last:find("&user=admin&password=p%%40ss%%20word") ~= nil)
check("toggle", r1:getValue() == 1)
env.secrets.password = nil

--------------------------------------------------------------------------------
-- Module code: loads and runs against a stub runtime
--------------------------------------------------------------------------------

local rows = {
    { id = "tasmota_ab12cd_1234_1", ip = "192.168.1.20", relay = 1, name = "Lampa", area = "Salon",
      expose = "light", bind = "CLU221000002.DOU0001", power = true },
    { id = "tasmota_ab12cd_1234_2", ip = "192.168.1.20", relay = 2, name = 'Went"ylator\n]]', expose = "none",
      bind = "", power = true },
    { id = "nous_a1t", ip = "192.168.1.30", relay = 1, name = "Gniazdko", expose = "switch" },
}
local code = plugin._moduleCode({ dashboard = true, dashboardName = "Moje Tasmoty", dashboardAuth = "pin" }, rows)
check("one device per address", select(2, code:gsub("tasmota:device", "")) == 2)
check("one meter per device", select(2, code:gsub(":power%(%)", "")) == 1)
check("the bind helper only when something binds", code:find("local function bind") ~= nil)
check("dashboard", code:find('Dashboard.new%("moje_tasmoty"%)') ~= nil and code:find(':auth%("pin"%)') ~= nil)

-- run it: the DOUT, expose and Dashboard are stubs that record what the module did
local dout = { _v = 1, _cbs = {} }
function dout:getValue() return self._v end
function dout:onChange(cb) self._cbs[#self._cbs + 1] = cb end
function dout:switchOn() self._v = 1 for _, cb in ipairs(self._cbs) do cb(1) end end
function dout:switchOff() self._v = 0 for _, cb in ipairs(self._cbs) do cb(0) end end

local exposed, dash = {}, { widgets = {} }
local chain = {}
for _, m in ipairs({ "name", "icon", "auth", "poll", "section", "toggle", "status", "build" }) do
    chain[m] = function(self, ...) dash.widgets[#dash.widgets + 1] = { m, ... } return self end
end
local sandbox = {
    Plugin = { getPlugin = function(id) return id == plugin.id and plugin or nil end },
    _ = { get = function(_, p) return p == "CLU221000002.DOU0001" and dout or nil end },
    expose = function(obj, kind, o) exposed[#exposed + 1] = { obj = obj, kind = kind, opts = o } end,
    Dashboard = { new = function(id) dash.id = id return chain end },
    Logger = { warn = function() end },
    string = string, tostring = tostring,
}
local fn, loadErr = load(code, "module", "t", sandbox)
check("the module compiles", fn ~= nil)
if not fn then print(loadErr) print(code) end
local ok, runErr = pcall(fn)
check("the module runs", ok)
if not ok then print(runErr) print(code) end
check("two exposed relays and one meter", #exposed == 3 and exposed[1].kind == "light"
    and exposed[1].opts.path == "tasmota.tasmota_ab12cd_1234_1" and exposed[1].opts.area == "Salon")
local label
for _, w in ipairs(dash.widgets) do
    if w[1] == "toggle" and w[2] == "tasmota_tasmota_ab12cd_1234_2" then label = w[3] end
end
check("a quote and a newline in a name come out as typed", label == rows[2].name)

-- bind: at the start the DOUT (on) decides; then each follows the other
local lamp = plugin:device("192.168.1.20"):relay(1)
state["192.168.1.20"][1] = "OFF"
lamp._value = nil
env.tick("tasmota_192_168_1_20")
check("after the first reading the relay follows the DOUT", state["192.168.1.20"][1] == "ON" and lamp:getValue() == 1)
dout:switchOff()
check("the DOUT switches the relay", state["192.168.1.20"][1] == "OFF")
state["192.168.1.20"][1] = "ON"   -- someone pressed the button on the device
env.tick("tasmota_192_168_1_20")
check("the device switches the DOUT", dout:getValue() == 1)
check("dashboard has toggles and the meter", dash.id == "moje_tasmoty")

local plain = plugin._moduleCode({}, { rows[3] })
check("no bind helper and no dashboard when not asked", not plain:find("bind") and not plain:find("Dashboard"))

os.exit(harness.report())
