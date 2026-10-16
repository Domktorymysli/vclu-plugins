--[[
    Spotify Plugin dla vCLU

    Fabryka kont Spotify sterowanych przez Web API (wymaga Spotify Premium).

    Użycie:
        local spotify = Plugin.getPlugin("@vclu/spotify")

        local sp = spotify:create({
            id = "spotify",
            clientId = "...",
            clientSecret = "...",
        })

        -- jednorazowo: otwórz sp:authUrl() w przeglądarce, skopiuj ?code=...
        -- sp:authorize("AQB...")  -- refresh token trafia do KV

        sp:play()
        sp:play({ uri = "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", device = "Salon" })
        sp:pause()
        sp:next()
        sp:setVolume(30)
]]

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local plugin = Plugin:new("spotify", {
    name = "Spotify",
    version = "0.1.0",
    description = "Factory for Spotify accounts controlled through the Web API"
})

local API = "https://api.spotify.com/v1"
local ACCOUNTS = "https://accounts.spotify.com"
local DEFAULT_REDIRECT = "http://127.0.0.1:8888/callback"
local SCOPES = "user-read-playback-state user-modify-playback-state user-read-currently-playing"

--------------------------------------------------------------------------------
-- SPOTIFY ACCOUNT CLASS
--------------------------------------------------------------------------------

-- Method table copied onto each instance. The plugin sandbox exposes no
-- setmetatable, so inheritance through __index is not available here.
local SpotifyAccount = {}

function SpotifyAccount:new(options)
    local obj = {
        _id = options.id or "spotify",
        _name = options.name or "Spotify",
        _clientId = options.clientId,
        _clientSecret = options.clientSecret,
        _redirectUri = options.redirectUri or DEFAULT_REDIRECT,
        _refreshToken = options.refreshToken,
        _accessToken = nil,
        _tokenExpires = 0,
        _playing = false,
        _track = nil,
        _volume = nil,
        _device = nil,
        _online = false,
        _lastError = nil,
        _pollInterval = options.pollInterval or 15,
        _poller = nil
    }
    for name, fn in pairs(SpotifyAccount) do obj[name] = fn end

    -- KV keeps the refresh token across restarts; an explicit option wins.
    if not obj._refreshToken then
        obj._refreshToken = plugin:kvGet(obj:_kvKey(), nil)
    end

    if options.polling ~= false then
        obj:_startPolling()
    end

    return obj
end

function SpotifyAccount:_kvKey()
    return "refresh_token:" .. self._id
end

--------------------------------------------------------------------------------
-- AUTHORIZATION
--------------------------------------------------------------------------------

--- URL to open once in a browser to grant access.
function SpotifyAccount:authUrl()
    return plugin:url(ACCOUNTS .. "/authorize", {
        client_id = self._clientId,
        response_type = "code",
        redirect_uri = self._redirectUri,
        scope = SCOPES
    })
end

--- Exchange the one-time code from the redirect for a refresh token.
function SpotifyAccount:authorize(code, callback)
    self:_tokenRequest({
        grant_type = "authorization_code",
        code = code,
        redirect_uri = self._redirectUri
    }, function(ok, err)
        if ok then plugin:log("info", self._name .. ": authorized") end
        if callback then callback(ok, err) end
    end)
end

function SpotifyAccount:isAuthorized()
    return self._refreshToken ~= nil
end

function SpotifyAccount:_tokenRequest(form, callback)
    plugin:httpRequest({
        method = "POST",
        url = ACCOUNTS .. "/api/token",
        headers = { Authorization = plugin:basicAuth(self._clientId, self._clientSecret) },
        form = form,
        timeout = 10000
    }, function(resp)
        if resp.err or not (resp.json and resp.json.access_token) then
            local err = "token request failed: " .. (resp.err or "no access_token")
            self._lastError = err
            plugin:log("warn", self._name .. ": " .. err)
            callback(false, err)
            return
        end

        local json = resp.json
        self._accessToken = json.access_token
        -- Refresh a minute early so a request never races the expiry.
        self._tokenExpires = os.time() + (json.expires_in or 3600) - 60
        if json.refresh_token and json.refresh_token ~= self._refreshToken then
            self._refreshToken = json.refresh_token
            plugin:kvSet(self:_kvKey(), json.refresh_token, { secure = true })
        end
        callback(true, nil)
    end)
end

function SpotifyAccount:_withToken(callback)
    if self._accessToken and os.time() < self._tokenExpires then
        callback(true, nil)
        return
    end
    if not self._refreshToken then
        callback(false, "not authorized, call authorize(code) first")
        return
    end
    self:_tokenRequest({
        grant_type = "refresh_token",
        refresh_token = self._refreshToken
    }, callback)
end

--------------------------------------------------------------------------------
-- WEB API
--------------------------------------------------------------------------------

-- Calls the Web API; a 401 drops the cached token and retries once.
function SpotifyAccount:_api(method, path, opts, callback, retried)
    opts = opts or {}
    self:_withToken(function(ok, err)
        if not ok then
            if callback then callback(nil, err) end
            return
        end

        plugin:httpRequest({
            method = method,
            url = API .. path,
            query = opts.query,
            json = opts.json,
            headers = { Authorization = plugin:bearerAuth(self._accessToken) },
            timeout = 10000
        }, function(resp)
            if resp.status == 401 and not retried then
                self._accessToken = nil
                self:_api(method, path, opts, callback, true)
                return
            end
            if resp.err then
                local msg = resp.err
                if resp.status == 404 then msg = "no active device" end
                self._lastError = msg
                if callback then callback(nil, msg) end
                return
            end
            self._online = true
            self._lastError = nil
            -- 204 means success without a body (or nothing playing).
            if callback then callback(resp.json or {}, nil) end
        end)
    end)
end

function SpotifyAccount:_updateState(json)
    if not json or not json.device then
        self._playing = false
        self._device = nil
    else
        self._playing = json.is_playing == true
        self._device = json.device.name
        self._volume = json.device.volume_percent
        local item = json.item
        if item then
            local artists = {}
            for _, a in ipairs(item.artists or {}) do artists[#artists + 1] = a.name end
            self._track = {
                uri = item.uri,
                title = item.name,
                artist = table.concat(artists, ", "),
                album = item.album and item.album.name
            }
        end
    end
end

function SpotifyAccount:_startPolling()
    if self._poller then return end

    self._poller = plugin:poller("poll_" .. self._id, {
        interval = self._pollInterval * 1000,
        immediate = true,
        timeout = 15000,

        onTick = function(done)
            if not self._refreshToken then
                done()
                return
            end
            self:refresh(function(_, err) done(nil, err) end)
        end,

        onError = function(err)
            self._online = false
            plugin:log("warn", self._name .. ": poll failed - " .. tostring(err))
        end
    })

    self._poller:start()
end

function SpotifyAccount:_stopPolling()
    if self._poller then
        self._poller:stop()
        self._poller = nil
    end
end

-- Resolves a device name to its id; plain ids pass through.
function SpotifyAccount:_resolveDevice(device, callback)
    if not device then
        callback(nil, nil)
        return
    end
    self:devices(function(list, err)
        if err then
            callback(nil, err)
            return
        end
        for _, d in ipairs(list) do
            if d.id == device or d.name == device then
                callback(d.id, nil)
                return
            end
        end
        callback(nil, "device not found: " .. tostring(device))
    end)
end

--------------------------------------------------------------------------------
-- PUBLIC API - Playback
--------------------------------------------------------------------------------

--- Start or resume playback.
-- @param opts table|string|nil { uri, device } or a bare uri
function SpotifyAccount:play(opts, callback)
    if type(opts) == "string" then opts = { uri = opts } end
    opts = opts or {}

    local body = nil
    if opts.uri then
        -- Tracks go as a list, albums/playlists/artists as a context.
        if opts.uri:find("^spotify:track:") then
            body = { uris = { opts.uri } }
        else
            body = { context_uri = opts.uri }
        end
    end

    self:_resolveDevice(opts.device, function(deviceId, err)
        if err then
            plugin:log("warn", self._name .. ": " .. err)
            if callback then callback(nil, err) end
            return
        end
        self:_api("PUT", "/me/player/play", {
            query = deviceId and { device_id = deviceId } or nil,
            json = body
        }, function(json, apiErr)
            if not apiErr then self._playing = true end
            if callback then callback(json, apiErr) end
        end)
    end)
end

function SpotifyAccount:pause(callback)
    self:_api("PUT", "/me/player/pause", nil, function(json, err)
        if not err then self._playing = false end
        if callback then callback(json, err) end
    end)
end

function SpotifyAccount:toggle(callback)
    if self._playing then self:pause(callback) else self:play(nil, callback) end
end

function SpotifyAccount:next(callback)
    self:_api("POST", "/me/player/next", nil, callback)
end

function SpotifyAccount:previous(callback)
    self:_api("POST", "/me/player/previous", nil, callback)
end

function SpotifyAccount:setVolume(percent, callback)
    percent = math.max(0, math.min(100, math.floor(tonumber(percent) or 0)))
    self:_api("PUT", "/me/player/volume", { query = { volume_percent = percent } }, function(json, err)
        if not err then self._volume = percent end
        if callback then callback(json, err) end
    end)
end

--- Move playback to another device (name or id).
function SpotifyAccount:transfer(device, play, callback)
    self:_resolveDevice(device, function(deviceId, err)
        if err then
            if callback then callback(nil, err) end
            return
        end
        self:_api("PUT", "/me/player", {
            json = { device_ids = { deviceId }, play = play ~= false }
        }, callback)
    end)
end

--- List Spotify Connect devices: { {id, name, type, is_active, volume_percent}, ... }
function SpotifyAccount:devices(callback)
    self:_api("GET", "/me/player/devices", nil, function(json, err)
        callback(json and json.devices or {}, err)
    end)
end

function SpotifyAccount:refresh(callback)
    self:_api("GET", "/me/player", nil, function(json, err)
        if not err then self:_updateState(json) end
        if callback then callback(json, err) end
    end)
end

--------------------------------------------------------------------------------
-- PUBLIC API - State
--------------------------------------------------------------------------------

function SpotifyAccount:getId() return self._id end
function SpotifyAccount:isPlaying() return self._playing end
function SpotifyAccount:isOnline() return self._online end
function SpotifyAccount:getTrack() return self._track end
function SpotifyAccount:getVolume() return self._volume end
function SpotifyAccount:getDevice() return self._device end

function SpotifyAccount:getState()
    return {
        id = self._id,
        name = self._name,
        authorized = self._refreshToken ~= nil,
        playing = self._playing,
        track = self._track,
        volume = self._volume,
        device = self._device,
        online = self._online,
        lastError = self._lastError
    }
end

--------------------------------------------------------------------------------
-- PLUGIN FACTORY
--------------------------------------------------------------------------------

local accounts = {}

plugin:onInit(function(config)
    plugin:log("info", "Spotify factory ready")
end)

plugin:onCleanup(function()
    for _, account in pairs(accounts) do
        account:_stopPolling()
    end
    accounts = {}
    plugin:log("info", "Spotify cleanup")
end)

--- Create a Spotify account object
-- @param options table { id, name, clientId, clientSecret, redirectUri, refreshToken, polling, pollInterval }
-- @return SpotifyAccount
function plugin:create(options)
    options = options or {}
    if not options.clientId or not options.clientSecret then
        error("spotify:create needs clientId and clientSecret")
    end
    local id = options.id or "spotify"
    for _, a in ipairs(accounts) do
        if a._id == id then
            plugin:log("error", "Spotify: duplicate id '" .. id .. "', returning the existing account")
            return a
        end
    end

    local account = SpotifyAccount:new(options)
    table.insert(accounts, account)

    plugin:log("info", "Created: " .. account._name ..
        (account._refreshToken and "" or " (not authorized, open authUrl())"))

    return account
end

function plugin:getAccounts()
    return accounts
end

return plugin
