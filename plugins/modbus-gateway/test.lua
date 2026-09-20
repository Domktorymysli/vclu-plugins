--- Tests for the modbus-gateway plugin.
--
-- Run from the repository root:
--   lua plugins/modbus-gateway/test.lua
--
-- Covers what the factory rework has to get right: gateways are independent,
-- ids cannot collide, and nothing a second gateway does disturbs the first.

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

local env = harness.install()
local plugin = dofile(here .. "/init.lua")

--------------------------------------------------------------------------------
-- INDEPENDENT GATEWAYS
--------------------------------------------------------------------------------

local garaz = plugin:create({
    id = "garaz", host = "192.168.0.9", port = 4196,
    devices = { { id = "pralnia", unit = 3 }, { id = "klima", unit = 2 } }
})
local kotlownia = plugin:create({
    id = "kotlownia", host = "192.168.0.14",
    devices = { { id = "kociol", unit = 1 } }
})

check("two gateways registered", #plugin:getGateways() == 2)
check("settings stay per gateway", garaz.host == "192.168.0.9" and garaz.port == 4196
      and kotlownia.host == "192.168.0.14" and kotlownia.port == 502)
check("lookup by id", plugin:gateway("garaz") == garaz)
check("device sensors registered", env.sensors["pralnia_power"] ~= nil
      and env.sensors["kociol_voltage"] ~= nil)
check("one poller per gateway", env.pollers["read_garaz"] ~= nil
      and env.pollers["read_kotlownia"] ~= nil)
check("pollers started", env.pollers["read_garaz"].started
      and env.pollers["read_kotlownia"].started)

--------------------------------------------------------------------------------
-- ARGUMENT HANDLING
--------------------------------------------------------------------------------

check("gateway needs a host", plugin:create({ id = "nohost", devices = { 1 } }) == nil)
check("duplicate gateway id refused",
      plugin:create({ id = "garaz", host = "10.0.0.1", devices = { 1 } }) == nil)

local bare = plugin:create({ id = "bare", host = "10.0.0.3", devices = { 5, 6 } })
check("a bare unit address is a device",
      bare ~= nil and bare.devices[1].id == "meter5" and bare.devices[2].id == "meter6")

local idle = plugin:create({ id = "idle", host = "10.0.0.4", devices = { 7 }, autostart = false })
check("autostart=false leaves the poller stopped",
      idle ~= nil and env.pollers["read_idle"].started == false)

--------------------------------------------------------------------------------
-- ID COLLISIONS
--
-- Sensor ids are one flat namespace shared by every gateway, so a clash would
-- let one getter silently replace another. Nothing may be overwritten.
--------------------------------------------------------------------------------

local third = plugin:create({
    id = "third", host = "10.0.0.2",
    devices = { { id = "pralnia", unit = 9 }, { id = "healthy", unit = 8 } }
})
check("device id taken by another gateway is skipped",
      third ~= nil and #third.devices == 1 and third.devices[1].id == "healthy")

check("gateway sensor is namespaced", env.sensors["gateway_garaz_online"] ~= nil)
check("gateway does not claim the bare <id>_online", env.sensors["garaz_online"] == nil)

-- A gateway named after an existing device used to overwrite that device's
-- own _online sensor, because both landed on "<name>_online".
local deviceGetter = env.sensors["pralnia_online"]._getter
local named = plugin:create({
    id = "pralnia", host = "10.0.0.5",
    devices = { { id = "bojler", unit = 4 } }
})
check("gateway may be named after a device", named ~= nil)
check("that device's sensor is untouched", env.sensors["pralnia_online"]._getter == deviceGetter)
check("gateway got its own namespaced sensor", env.sensors["gateway_pralnia_online"] ~= nil)

-- The mirror case: a device aimed straight at a gateway's sensor id.
local sneaky = plugin:create({
    id = "sneaky", host = "10.0.0.6",
    devices = { { id = "gateway_garaz", unit = 10 }, { id = "fine", unit = 11 } }
})
check("device colliding with a gateway sensor is skipped",
      sneaky ~= nil and #sneaky.devices == 1 and sneaky.devices[1].id == "fine")

check("no sensor was ever overwritten", #env.clobbered == 0)
if #env.clobbered > 0 then
    print("       overwritten: " .. table.concat(env.clobbered, ", "))
end

--------------------------------------------------------------------------------
-- READ CYCLE
--
-- The throttle key defaults to the plugin id plus event name, so without an
-- explicit key the first gateway would mute every other one for 30 seconds.
--------------------------------------------------------------------------------

env.clearEmits()
env.tick("read_garaz")
env.tick("read_kotlownia")

local updated = env.emitsOf("modbus:updated")
check("both cycles emitted modbus:updated", #updated == 2)
check("throttle key is the gateway id",
      #updated == 2 and updated[1].opts and updated[1].opts.key == "garaz"
      and updated[2].opts and updated[2].opts.key == "kotlownia")
check("values reached the device state", garaz:getValue("pralnia", "voltage") ~= nil)
check("gateway reports online", garaz:isOnline() == true)

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------

plugin._cleanup()
check("cleanup stopped the pollers", env.pollers["read_garaz"].started == false)
check("cleanup emptied the registry", #plugin:getGateways() == 0)

local reborn = plugin:create({
    id = "garaz", host = "10.0.0.7",
    devices = { { id = "pralnia", unit = 3 } }
})
check("ids are free again after cleanup", reborn ~= nil and #reborn.devices == 1)

os.exit(harness.report())
