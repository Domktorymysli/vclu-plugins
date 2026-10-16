--- Tests for the musiccast plugin.
--
-- Run from the repository root:
--   lua plugins/musiccast/test.lua

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

local function ok(json) return { status = 200, ok = true, json = json } end

-- YXC answers every call with response_code; 0 is success.
local env = harness.install({
    http = function(req)
        local url = tostring(req.url)
        if url:find("192%.168%.0%.99") then
            return { status = 0, ok = false, err = "connection refused" }
        end
        if url:find("/getStatus$") then
            return ok({ response_code = 0, power = "on", volume = 80, max_volume = 160,
                        mute = false, input = "net_radio" })
        end
        if url:find("/netusb/getPlayInfo$") then
            return ok({ response_code = 0, playback = "play", artist = "Trójka",
                        track = "Audycja", album = "", input = "net_radio" })
        end
        if url:find("/setInput$") and req.query.input == "nonsense" then
            return ok({ response_code = 4 })
        end
        return ok({ response_code = 0 })
    end
})

local plugin = dofile(here .. "/init.lua")

--------------------------------------------------------------------------------
-- FACTORY
--------------------------------------------------------------------------------

check("create without ip is an error", not pcall(function() plugin:create({}) end))

local salon = plugin:create({ id = "salon", ip = "192.168.0.40", name = "Amplituner" })
local kuchnia = plugin:create("192.168.0.41")
check("two independent devices", #plugin:getDevices() == 2)
check("a bare ip string works and becomes the id", kuchnia:getId() == "192.168.0.41")
check("duplicate id returns the same device",
      plugin:create({ id = "salon", ip = "192.168.0.42" }) == salon)
check("polling is on by default", env.pollers["poll_salon"] ~= nil)

for _, name in ipairs({ "on", "off", "toggle", "setVolume", "setMute", "setInput",
                        "play", "pause", "next", "recallPreset", "refresh",
                        "getState", "volumeControl" }) do
    check("method " .. name .. " is on the instance", type(rawget(salon, name)) == "function")
end
local src = io.open(here .. "/init.lua"):read("a")
check("plugin does not call setmetatable", src:find("setmetatable%s*%(") == nil)

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local tracks = {}
salon:onTrack(function(t) tracks[#tracks + 1] = t end)

env.tick("poll_salon")
check("refresh reads power", salon:isOn() == true)
check("volume is a percent of max_volume", salon:getVolume() == 50)
check("refresh reads input", salon:getInput() == "net_radio")
check("refresh reads the play info", salon:getTrack().artist == "Trójka")
check("a new track fires OnTrack", #tracks == 1)
check("a reachable device is online", salon:isOnline())

--------------------------------------------------------------------------------
-- COMMANDS
--------------------------------------------------------------------------------

local function last() return env.http[#env.http] end

local changes = {}
salon:onChange(function(new) changes[#changes + 1] = new end)

salon:off()
check("off sends standby to the zone",
      last().url:find("/v1/main/setPower$") and last().query.power == "standby")
check("off flips the state and fires OnChange", salon:isOn() == false and changes[#changes] == 0)

salon:setVolume(25)
check("setVolume scales to the device range", last().query.volume == 40)

salon:recallPreset(3)
check("recallPreset names the zone", last().url:find("netusb/recallPreset$")
      and last().query.zone == "main" and last().query.num == 3)

salon:play()
check("play goes through netusb", last().query.playback == "play")

local refused
salon:setInput("nonsense", function(_, err) refused = err end)
check("a YXC error code is reported", refused and refused:find("invalid parameter"))
check("a refused parameter keeps the device online", salon:isOnline())

local zone2 = plugin:create({ id = "taras", ip = "192.168.0.40", zone = "zone2", polling = false })
zone2:on()
check("a second zone talks to its own path", last().url:find("/v1/zone2/setPower$"))

local dead = plugin:create({ id = "martwy", ip = "192.168.0.99", polling = false })
dead:refresh()
check("an unreachable device is offline", dead:isOnline() == false)

--------------------------------------------------------------------------------
-- EXPOSE AND CLEANUP
--------------------------------------------------------------------------------

salon:set(0, 1)
check("expose set(1) powers on", salon:get(0) == 1)
local vol = salon:volumeControl()
vol:set(0, 100)
check("the volume control sets the full range", last().query.volume == 160)
check("the volume control reads a percent", vol:get(0) == 100)

plugin._cleanup()
check("cleanup empties the device list", #plugin:getDevices() == 0)

os.exit(harness.report())
