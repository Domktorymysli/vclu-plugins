--- Tests for the musiccast plugin.
--
-- Run from the repository root:
--   lua plugins/musiccast/test.lua

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

local function ok(json) return { status = 200, ok = true, json = json } end

-- getPlayInfo answered for 192.168.0.50; the artwork tests swap it.
local playInfo = {}

-- YXC answers every call with response_code; 0 is success.
local env = harness.install({
    http = function(req)
        local url = tostring(req.url)
        if url:find("192%.168%.0%.99") then
            return { err = "connection refused" }
        end
        if url:find("192%.168%.0%.98") then
            return { status = 500 }
        end
        if url:find("/getStatus$") then
            return ok({ response_code = 0, power = "on", volume = 80, max_volume = 160,
                        mute = false, input = "net_radio" })
        end
        if url:find("192%.168%.0%.50/.*/netusb/getPlayInfo$") then
            return ok(playInfo)
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
                        "getState" }) do
    check("method " .. name .. " is on the instance", type(rawget(salon, name)) == "function")
end
local src = io.open(here .. "/init.lua"):read("a")
check("plugin does not call setmetatable", src:find("setmetatable%s*%(") == nil)

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

env.tick("poll_salon")
check("refresh reads power", salon:isOn() == true)
check("volume is a percent of max_volume", salon:getVolume() == 50)
check("refresh reads input", salon:getInput() == "net_radio")
check("refresh reads the play info", salon:getTrack().artist == "Trójka")
check("a reachable device is online", salon:isOnline())

--------------------------------------------------------------------------------
-- COMMANDS
--------------------------------------------------------------------------------

local function last() return env.http[#env.http] end

salon:off()
check("off sends standby to the zone",
      last().url:find("/v1/main/setPower$") and last().query.power == "standby")
check("off flips the state", salon:isOn() == false)

salon:setVolume(25)
check("setVolume scales to the device range", last().query.volume == 40)

salon:recallPreset(3)
check("recallPreset names the zone", last().url:find("netusb/recallPreset$")
      and last().query.zone == "main" and last().query.num == 3)

salon:play()
check("play goes through netusb", last().query.playback == "play")

check("play sets the playback state at once", salon:getState().playback == "play")
salon:pause()
check("pause sets it to pause", salon:getState().playback == "pause")
salon:stop()
check("stop sets it to stop", salon:getState().playback == "stop")

salon:setMute(true)
check("setMute sets mute on success", salon:isMuted() == true)
salon:setMute(false)
check("and clears it", salon:isMuted() == false)
salon:on()
check("on sets power on success", salon:isOn() == true)

local before = #env.http
salon:next()
check("next schedules one play info read", env.pendingTimers() == 1 and #env.http == before + 1)
salon:previous()
check("a second skip reuses the pending read", env.pendingTimers() == 1)
check("the delay is about a second", (function()
    for _, t in pairs(env.timers) do return t.ms == 1000 end
end)())
check("next does not invent a playback state", salon:getState().playback == "stop")
env.runTimers()
check("the timer reads getPlayInfo", env.http[#env.http].url:find("/netusb/getPlayInfo$"))
check("and updates the track and playback", salon:getTrack().artist == "Trójka"
      and salon:getState().playback == "play")

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
-- ARTWORK
--
-- Recorded shapes of getPlayInfo. The receiver serves the cover from one path
-- for every track; Spotify and some services hand out an absolute URL.
--------------------------------------------------------------------------------

local PLAYINFO = {
    net_radio = {
        response_code = 0, input = "net_radio", playback = "play", ["repeat"] = "off",
        shuffle = "off", play_time = 0, total_time = 0,
        artist = "", album = "Polskie Radio Trójka", track = "Lista Przebojów",
        albumart_url = "/YamahaRemoteControl/AlbumART/AlbumART3121.jpg",
        albumart_id = 3121, usb_devicetype = "unknown", auto_stopped = false, attribute = 1
    },
    spotify = {
        response_code = 0, input = "spotify", playback = "play", ["repeat"] = "all",
        shuffle = "on", play_time = 74, total_time = 241,
        artist = "Daft Punk", album = "Discovery", track = "One More Time",
        albumart_url = "/YamahaRemoteControl/AlbumART/AlbumART.jpg",
        albumart_id = 5501, usb_devicetype = "unknown", auto_stopped = false, attribute = 4294967295
    },
    server = {
        response_code = 0, input = "server", playback = "play", ["repeat"] = "off",
        shuffle = "off", play_time = 12, total_time = 305,
        artist = "Kult", album = "Spokojnie", track = "Arahja",
        albumart_url = "YamahaRemoteControl/AlbumART/AlbumART.jpg",
        albumart_id = 7, usb_devicetype = "unknown", auto_stopped = false, attribute = 1
    },
    bluetooth = {
        response_code = 0, input = "bluetooth", playback = "stop",
        artist = "", album = "", track = "", albumart_url = "", albumart_id = 0
    },
    deezer = {
        response_code = 0, input = "deezer", playback = "play",
        artist = "Kult", album = "Spokojnie", track = "Arahja",
        albumart_url = "https://e-cdns-images.dzcdn.net/images/cover/abc123/500x500.jpg"
    }
}

local box = plugin:create({ id = "box", ip = "192.168.0.50", polling = false })
local function artworkFor(name)
    playInfo = PLAYINFO[name]
    box:refresh()
    return box:getTrack().artwork
end

local radio = artworkFor("net_radio")
check("a device path becomes an absolute URL on the device",
      radio and radio:find("^http://192%.168%.0%.50/YamahaRemoteControl/AlbumART/AlbumART3121%.jpg%?t=%x+$"))
check("getState carries the artwork", box:getState().track.artwork == radio)

local spotify = artworkFor("spotify")
check("spotify cover is served from the device", spotify and spotify:find("^http://192%.168%.0%.50/YamahaRemoteControl/AlbumART/AlbumART%.jpg%?t="))
check("the same track keeps the same URL across polls", artworkFor("spotify") == spotify)

local server = artworkFor("server")
check("a path without a leading slash still gets one", server and server:find("^http://192%.168%.0%.50/YamahaRemoteControl/"))
check("another track on the same path gets another URL", server ~= spotify)

check("an empty albumart_url is no artwork", artworkFor("bluetooth") == nil)
check("the track is still read without artwork", box:getTrack().input == "bluetooth")

check("an absolute URL is kept as is",
      artworkFor("deezer") == "https://e-cdns-images.dzcdn.net/images/cover/abc123/500x500.jpg")

local function artworkOf(path)
    playInfo = { response_code = 0, input = "server", playback = "play",
                 artist = "A", track = "B", album = "C", albumart_url = path }
    box:refresh()
    return box:getTrack().artwork
end
local spaced = artworkOf("/YamahaRemoteControl/AlbumART/Okładka płyty.jpg")
check("spaces and non-ASCII bytes are percent-encoded",
      spaced and spaced:find("^http://192%.168%.0%.50/YamahaRemoteControl/AlbumART/Ok%%C5%%82adka%%20p%%C5%%82yty%.jpg%?t=%x+$"))
local encoded = artworkOf("/art/My%20Cover%2Fx.jpg")
check("an existing %XX is kept", encoded and encoded:find("^http://192%.168%.0%.50/art/My%%20Cover%%2Fx%.jpg%?t="))
local lone = artworkOf("/art/100%.jpg")
check("a lone % is encoded", lone and lone:find("/art/100%%25%.jpg%?t="))
local queried = artworkOf("/art/cover.jpg?id=7&size=l")
check("an existing query is kept and the buster follows with &",
      queried and queried:find("^http://192%.168%.0%.50/art/cover%.jpg%?id=7&size=l&t=%x+$"))
local fragment = artworkOf("/art/cover.jpg#top")
check("a fragment is dropped, the buster is the last part",
      fragment and fragment:find("^http://192%.168%.0%.50/art/cover%.jpg%?t=%x+$"))
check("a fragment after a query is dropped too",
      artworkOf("/art/cover.jpg?id=7#x"):find("%?id=7&t=%x+$") ~= nil)

playInfo = { response_code = 0, input = "net_radio", playback = "play" }
box:refresh()
check("a reply without albumart_url is no artwork", box:getTrack().artwork == nil)

--------------------------------------------------------------------------------
-- NOT EXPOSABLE AND CLEANUP
--
-- HA has its own MusicCast integration. An onChange without an unsubscribe
-- return would break expose(), so the device offers none.
--------------------------------------------------------------------------------

salon:setVolume(100)
check("full volume is the top of the device range", last().query.volume == 160)
check("the device offers no onChange", salon.onChange == nil)

local sick = plugin:create({ id = "chory", ip = "192.168.0.98", polling = false })
local broken
sick:refresh(function(_, err) broken = err end)
check("an HTTP error passes through", broken == "HTTP 500")

sick._playback, sick._volume, sick._mute, sick._power = "play", 40, false, true
sick:pause()
sick:setVolume(80)
sick:setMute(true)
sick:off()
check("failed commands change no state", sick:getState().playback == "play"
      and sick._volume == 40 and sick:isMuted() == false and sick:isOn() == true)
sick:next()
check("a failed skip schedules no read", env.pendingTimers() == 0)

salon:next()
check("a read is pending before cleanup", env.pendingTimers() == 1)

plugin._cleanup()
check("cleanup empties the device list", #plugin:getDevices() == 0)
check("cleanup cancels a pending play info read", env.pendingTimers() == 0)

os.exit(harness.report())
