--- Tests for the tasmota-switch plugin.
--
-- Run from the repository root:
--   lua plugins/tasmota-switch/test.lua
--
-- The plugin is a factory: every create() call is an independent switch, and
-- the methods have to be reachable on each one.

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

-- Tasmota answers Power queries with {"POWER":"ON"}.
local env = harness.install({
    http = function(reqOpts)
        if tostring(reqOpts.url):find("Power") then
            return { code = 200, json = { POWER = "ON" } }
        end
        return { code = 200, json = {} }
    end
})

local plugin = dofile(here .. "/init.lua")

--------------------------------------------------------------------------------
-- FACTORY
--------------------------------------------------------------------------------

local lamp = plugin:create({ id = "biurko", name = "Lampka Biurko", ip = "192.168.1.100" })
local fan = plugin:create({ id = "wentylator", name = "Wentylator", ip = "192.168.1.101" })

check("create returns an object", type(lamp) == "table")
check("two independent switches", #plugin:getDevices() == 2)
check("each keeps its own ip", lamp._ip == "192.168.1.100" and fan._ip == "192.168.1.101")
check("a bare ip string works", plugin:create("192.168.1.102") ~= nil)

--------------------------------------------------------------------------------
-- METHODS REACH THE INSTANCE
--
-- The plugin sandbox exposes a named allowlist of globals and setmetatable is
-- not on it, so a metatable-based class loses every method on a real runtime
-- while looking fine in plain Lua.
--------------------------------------------------------------------------------

for _, name in ipairs({ "on", "off", "toggle", "refresh", "isOn", "isOnline",
                        "getValue", "getState", "getId", "setName" }) do
    check("method " .. name .. " is on the instance", type(rawget(lamp, name)) == "function")
end

local src = io.open(here .. "/init.lua"):read("a")
check("plugin does not call setmetatable", src:find("setmetatable%s*%(") == nil)

--------------------------------------------------------------------------------
-- BEHAVIOUR
--------------------------------------------------------------------------------

local before = #env.http
lamp:on()
check("on() issues an HTTP command", #env.http > before)
check("the command goes to the right host",
      tostring(env.http[#env.http].url):find("192%.168%.1%.100") ~= nil)

lamp:refresh()
check("refresh() reads the state back", lamp:isOn() == true)
check("a reachable switch is online", lamp:isOnline() == true)

check("getId returns the configured id", lamp:getId() == "biurko")
lamp:setName("Nowa nazwa")
check("setName sticks", lamp._name == "Nowa nazwa")

--------------------------------------------------------------------------------
-- POLLING AND CLEANUP
--------------------------------------------------------------------------------

check("polling is on by default", env.pollers["poll_192.168.1.100"] ~= nil)
local quiet = plugin:create({ id = "cichy", ip = "192.168.1.103", polling = false })
check("polling can be turned off",
      quiet ~= nil and env.pollers["poll_192.168.1.103"] == nil)

plugin._cleanup()
check("cleanup empties the device list", #plugin:getDevices() == 0)

os.exit(harness.report())
