--- Tests for the spotify plugin.
--
-- Run from the repository root:
--   lua plugins/spotify/test.lua

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

local function ok(json) return { status = json and 200 or 204, ok = true, json = json } end

-- A test can make the next player call answer 401 once.
local expireNext = false
local tokenCalls = 0

local env = harness.install({
    http = function(req)
        local url = tostring(req.url)
        if url:find("accounts.spotify.com/api/token") then
            tokenCalls = tokenCalls + 1
            local json = { access_token = "at" .. tokenCalls, expires_in = 3600 }
            if req.form.grant_type == "authorization_code" then json.refresh_token = "rt-new" end
            return ok(json)
        end
        if expireNext then
            expireNext = false
            return { status = 401, ok = false }
        end
        if url:find("/me/player/devices") then
            return ok({ devices = {
                { id = "dev-salon", name = "Salon", is_active = false },
                { id = "dev-kuchnia", name = "Kuchnia", is_active = true }
            } })
        end
        if url:find("/me/player$") and (req.method or "GET") == "GET" then
            return ok({
                is_playing = true,
                device = { name = "Kuchnia", volume_percent = 40 },
                item = { uri = "spotify:track:1", name = "Utwór", artists = { { name = "A" }, { name = "B" } },
                         album = { name = "Album" } }
            })
        end
        return ok(nil)
    end
})

local plugin = dofile(here .. "/init.lua")

--------------------------------------------------------------------------------
-- FACTORY AND AUTHORIZATION
--------------------------------------------------------------------------------

check("create without credentials is an error",
      not pcall(function() plugin:create({}) end))

local sp = plugin:create({ id = "dom", clientId = "cid", clientSecret = "sec", polling = false })
check("a new account is not authorized", sp:isAuthorized() == false)
check("authUrl carries client id and scopes",
      sp:authUrl():find("client_id=cid") and sp:authUrl():find("user%-modify%-playback%-state"))

local failed
sp:play(nil, function(_, err) failed = err end)
check("playing before authorize reports why", failed and failed:find("not authorized"))

sp:authorize("CODE")
check("authorize stores the refresh token in KV", env.kv["refresh_token:dom"] == "rt-new")
check("the token request uses basic auth",
      env.http[#env.http].headers.Authorization == "Basic cid:sec")

local again = plugin:create({ id = "dom2", clientId = "cid", clientSecret = "sec", polling = false })
check("a second id does not see the first token", again:isAuthorized() == false)
env.kv["refresh_token:dom2"] = "rt-old"
plugin._cleanup()
local restored = plugin:create({ id = "dom2", clientId = "cid", clientSecret = "sec", polling = false })
check("a restart picks the token up from KV", restored:isAuthorized())
check("duplicate id returns the same account",
      plugin:create({ id = "dom2", clientId = "x", clientSecret = "y", polling = false }) == restored)

for _, name in ipairs({ "play", "pause", "toggle", "next", "previous", "setVolume",
                        "transfer", "devices", "refresh", "getState", "authorize" }) do
    check("method " .. name .. " is on the instance", type(rawget(sp, name)) == "function")
end
local src = io.open(here .. "/init.lua"):read("a")
check("plugin does not call setmetatable", src:find("setmetatable%s*%(") == nil)

--------------------------------------------------------------------------------
-- PLAYBACK
--------------------------------------------------------------------------------

local changes = {}
sp:onChange(function(new) changes[#changes + 1] = new end)
local tracks = 0
sp:onTrack(function() tracks = tracks + 1 end)

sp:refresh()
check("refresh reads playing state", sp:isPlaying() == true)
check("refresh reads the track", sp:getTrack().artist == "A, B" and sp:getTrack().title == "Utwór")
check("refresh reads volume and device", sp:getVolume() == 40 and sp:getDevice() == "Kuchnia")
check("a new track fires OnTrack", tracks == 1)

sp:pause()
check("pause goes as PUT /me/player/pause",
      env.http[#env.http].method == "PUT" and env.http[#env.http].url:find("/me/player/pause$"))
check("pause flips the state and fires OnChange", sp:isPlaying() == false and changes[#changes] == 0)

sp:play({ uri = "spotify:playlist:abc", device = "Salon" })
local req = env.http[#env.http]
check("a playlist plays as a context", req.json.context_uri == "spotify:playlist:abc")
check("a device name resolves to its id", req.query.device_id == "dev-salon")
check("play flips the state", sp:isPlaying() == true)

sp:play("spotify:track:xyz")
check("a track plays as a uri list", env.http[#env.http].json.uris[1] == "spotify:track:xyz")

local unknown
sp:play({ device = "Garaż" }, function(_, err) unknown = err end)
check("an unknown device is an error", unknown and unknown:find("Garaż"))

sp:setVolume(150)
check("volume is clamped to 100", env.http[#env.http].query.volume_percent == 100)

local before = tokenCalls
expireNext = true
sp:next()
check("a 401 refreshes the token and retries", tokenCalls == before + 1
      and env.http[#env.http].url:find("/me/player/next$"))

--------------------------------------------------------------------------------
-- EXPOSE AND CLEANUP
--------------------------------------------------------------------------------

sp:set(0, 0)
check("expose set(0) pauses", sp:get(0) == 0)
sp:set(0, 1)
check("expose set(1) plays", sp:get(0) == 1)

local polled = plugin:create({ id = "polled", clientId = "c", clientSecret = "s" })
check("polling is on by default", env.pollers["poll_polled"] ~= nil)
plugin._cleanup()
check("cleanup empties the account list", #plugin:getAccounts() == 0)

os.exit(harness.report())
