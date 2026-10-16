--- Tests for the supla-power-meter plugin.
--
-- Run from the repository root:
--   lua plugins/supla-power-meter/test.lua
--
-- The energy sensors feed HA's Energy dashboard (total_increasing), where a
-- 0 followed by the real reading counts as a huge consumption. They must stay
-- nil until the meter reports and keep the last reading while it is offline.

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

local function phase(fwd, rev)
    return { voltage = 230, current = 1, powerActive = 200,
             totalForwardActiveEnergy = fwd, totalReverseActiveEnergy = rev }
end

-- What the direct link answers next; a test swaps it between ticks.
local reply

local env = harness.install({
    http = function() return reply end
})

local plugin = dofile(here .. "/init.lua")
local config = { directUrl = "http://127.0.0.1/direct/1/x/read" }
plugin.config = config
plugin._init(config)

local function sensor(id) return env.sensors[id].get() end

--------------------------------------------------------------------------------
-- BEFORE THE FIRST READING
--------------------------------------------------------------------------------

check("energy is nil before the first reading", sensor("energy") == nil)
check("reverse energy is nil before the first reading", sensor("reverseEnergy") == nil)
check("the getter still returns a number", plugin:getTotalEnergy() == 0)

-- The meter offline: Supla answers without phases.
reply = { status = 200, json = { connected = false } }
env.tick("fetch")
check("a reply without phases leaves energy nil", sensor("energy") == nil)

--------------------------------------------------------------------------------
-- REAL READING, THEN OFFLINE
--------------------------------------------------------------------------------

reply = { status = 200, json = { connected = true,
    phases = { phase(8000, 100), phase(8000, 100), phase(8192, 200) } } }
env.tick("fetch")
check("energy is the sum of the phases", sensor("energy") == 24192)
check("reverse energy is the sum of the phases", sensor("reverseEnergy") == 400)
check("power is read", sensor("power") == 600)

reply = { status = 200, json = { connected = false } }
env.tick("fetch")
check("offline keeps the last energy, not 0", sensor("energy") == 24192)
check("offline keeps the last reverse energy", sensor("reverseEnergy") == 400)
check("the getter keeps it too", plugin:getTotalEnergy() == 24192)
check("the registry keeps it too", env.objects["power"].totalEnergy == 24192)

reply = { err = "connection refused" }
env.tick("fetch")
check("a failed request keeps the last energy", sensor("energy") == 24192)

os.exit(harness.report())
