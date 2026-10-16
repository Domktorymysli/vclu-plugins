--[[
    Yamaha MusicCast Plugin dla vCLU

    Fabryka obiektów sterujących urządzeniami MusicCast przez lokalne API
    Yamaha Extended Control (HTTP, bez chmury i bez logowania).

    Użycie:
        local musiccast = Plugin.getPlugin("@vclu/musiccast")

        local salon = musiccast:create({ id = "salon", ip = "192.168.0.40", name = "Amplituner" })

        salon:on()
        salon:setInput("net_radio")
        salon:setVolume(35)          -- procent zakresu urządzenia
        salon:recallPreset(1)
        salon:play()
        salon:off()

        expose(salon, "switch", { name = "Amplituner" })
        expose(salon:volumeControl(), "number", { id = "salon_volume", name = "Głośność salon" })
]]

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local plugin = Plugin:new("musiccast", {
    name = "Yamaha MusicCast",
    version = "0.1.0",
    description = "Factory for Yamaha MusicCast devices over the local YXC API"
})

-- YXC response_code values worth naming in logs.
local RESPONSE_CODES = {
    [1] = "initializing", [2] = "internal error", [3] = "invalid request",
    [4] = "invalid parameter", [5] = "guarded", [6] = "time out",
    [99] = "firmware updating"
}

--------------------------------------------------------------------------------
-- MUSICCAST DEVICE CLASS
--------------------------------------------------------------------------------

-- Method table copied onto each instance. The plugin sandbox exposes no
-- setmetatable, so inheritance through __index is not available here.
local MusicCast = {}

function MusicCast:new(options)
    local obj = {
        _type = "switch",
        _id = options.id or options.ip,
        _name = options.name or "MusicCast",
        _ip = options.ip,
        _zone = options.zone or "main",
        _power = false,
        _volume = 0,
        _maxVolume = 100,
        _mute = false,
        _input = nil,
        _playback = nil,
        _track = nil,
        _online = false,
        _lastError = nil,
        _eventHandlers = {},
        _pollInterval = options.pollInterval or 10,
        _poller = nil
    }
    for name, fn in pairs(MusicCast) do obj[name] = fn end

    if options.polling ~= false and obj._ip then
        obj:_startPolling()
    end

    return obj
end

--------------------------------------------------------------------------------
-- HTTP
--------------------------------------------------------------------------------

function MusicCast:_call(path, query, callback)
    plugin:httpRequest({
        url = "http://" .. self._ip .. "/YamahaExtendedControl/v1/" .. path,
        query = query,
        timeout = 5000
    }, function(resp)
        local json = resp.json
        local err = resp.err
        if not err and not resp.ok then err = "HTTP " .. tostring(resp.status) end
        if not err and (not json or json.response_code ~= 0) then
            local code = json and json.response_code
            err = "YXC error " .. tostring(code) .. " (" .. (RESPONSE_CODES[code] or "unknown") .. ")"
        end

        if err then
            self._lastError = err
            -- A refused parameter still means the device answered.
            if not json then self._online = false end
            plugin:log("warn", self._name .. ": " .. path .. " - " .. err)
            if callback then callback(nil, err) end
            return
        end

        self._online = true
        self._lastError = nil
        if callback then callback(json, nil) end
    end)
end

function MusicCast:_zoneCall(method, query, callback)
    self:_call(self._zone .. "/" .. method, query, callback)
end

function MusicCast:_updateStatus(json)
    local wasOn = self._power
    self._power = json.power == "on"
    if json.max_volume then self._maxVolume = json.max_volume end
    if json.volume then self._volume = json.volume end
    if json.mute ~= nil then self._mute = json.mute end
    if json.input then self._input = json.input end

    if self._power ~= wasOn then
        self:emit("OnChange", self._power and 1 or 0, wasOn and 1 or 0)
    end
end

function MusicCast:_updatePlayInfo(json)
    self._playback = json.playback
    local old = self._track and (self._track.artist .. "/" .. self._track.title)
    self._track = {
        artist = json.artist or "",
        title = json.track or "",
        album = json.album or "",
        input = json.input
    }
    local new = self._track.artist .. "/" .. self._track.title
    if new ~= old and new ~= "/" then
        self:emit("OnTrack", self._track)
    end
end

function MusicCast:_startPolling()
    if self._poller then return end

    self._poller = plugin:poller("poll_" .. self._id, {
        interval = self._pollInterval * 1000,
        immediate = true,
        timeout = 10000,

        onTick = function(done)
            self:refresh(function(_, err) done(err) end)
        end,

        onError = function(err)
            self._online = false
            plugin:log("warn", self._name .. ": poll failed - " .. tostring(err))
        end
    })

    self._poller:start()
end

function MusicCast:_stopPolling()
    if self._poller then
        self._poller:stop()
        self._poller = nil
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API - Zone
--------------------------------------------------------------------------------

function MusicCast:on(callback)
    self:_zoneCall("setPower", { power = "on" }, function(json, err)
        if not err then self:_updateStatus({ power = "on" }) end
        if callback then callback(json, err) end
    end)
end

function MusicCast:off(callback)
    self:_zoneCall("setPower", { power = "standby" }, function(json, err)
        if not err then self:_updateStatus({ power = "standby" }) end
        if callback then callback(json, err) end
    end)
end

function MusicCast:toggle(callback)
    if self._power then self:off(callback) else self:on(callback) end
end

--- Volume as a percent of the device range (max_volume differs per model).
function MusicCast:setVolume(percent, callback)
    percent = math.max(0, math.min(100, tonumber(percent) or 0))
    local raw = math.floor(percent * self._maxVolume / 100 + 0.5)
    self:_zoneCall("setVolume", { volume = raw }, function(json, err)
        if not err then self._volume = raw end
        if callback then callback(json, err) end
    end)
end

function MusicCast:volumeUp(callback)
    self:_zoneCall("setVolume", { volume = "up" }, callback)
end

function MusicCast:volumeDown(callback)
    self:_zoneCall("setVolume", { volume = "down" }, callback)
end

function MusicCast:setMute(enabled, callback)
    self:_zoneCall("setMute", { enable = enabled and "true" or "false" }, function(json, err)
        if not err then self._mute = enabled and true or false end
        if callback then callback(json, err) end
    end)
end

--- Switch input: net_radio, spotify, airplay, bluetooth, server, hdmi1, ...
function MusicCast:setInput(input, callback)
    self:_zoneCall("setInput", { input = input }, function(json, err)
        if not err then self._input = input end
        if callback then callback(json, err) end
    end)
end

--------------------------------------------------------------------------------
-- PUBLIC API - Network playback (netusb)
--------------------------------------------------------------------------------

function MusicCast:_setPlayback(action, callback)
    self:_call("netusb/setPlayback", { playback = action }, callback)
end

function MusicCast:play(callback) self:_setPlayback("play", callback) end
function MusicCast:pause(callback) self:_setPlayback("pause", callback) end
function MusicCast:stop(callback) self:_setPlayback("stop", callback) end
function MusicCast:next(callback) self:_setPlayback("next", callback) end
function MusicCast:previous(callback) self:_setPlayback("previous", callback) end

--- Play a favourite saved in the MusicCast app (1-based).
function MusicCast:recallPreset(num, callback)
    self:_call("netusb/recallPreset", { zone = self._zone, num = num }, callback)
end

function MusicCast:refresh(callback)
    self:_zoneCall("getStatus", nil, function(json, err)
        if err then
            if callback then callback(nil, err) end
            return
        end
        self:_updateStatus(json)
        self:_call("netusb/getPlayInfo", nil, function(info, infoErr)
            if info then self:_updatePlayInfo(info) end
            if callback then callback(self:getState(), nil) end
        end)
    end)
end

--------------------------------------------------------------------------------
-- PUBLIC API - State
--------------------------------------------------------------------------------

function MusicCast:getId() return self._id end
function MusicCast:isOn() return self._power end
function MusicCast:isOnline() return self._online end
function MusicCast:isMuted() return self._mute end
function MusicCast:getInput() return self._input end
function MusicCast:getTrack() return self._track end

function MusicCast:getVolume()
    if self._maxVolume <= 0 then return 0 end
    return math.floor(self._volume * 100 / self._maxVolume + 0.5)
end

function MusicCast:getState()
    return {
        id = self._id,
        name = self._name,
        ip = self._ip,
        zone = self._zone,
        power = self._power,
        volume = self:getVolume(),
        mute = self._mute,
        input = self._input,
        playback = self._playback,
        track = self._track,
        online = self._online,
        lastError = self._lastError
    }
end

--------------------------------------------------------------------------------
-- EXPOSE INTERFACE (switch: power)
--------------------------------------------------------------------------------

function MusicCast:get(feature)
    return self._power and 1 or 0
end

function MusicCast:set(feature, value)
    if value == 1 or value == true or value == "ON" then
        self:on()
    else
        self:off()
    end
end

function MusicCast:switchOn() self:on() end
function MusicCast:switchOff() self:off() end

--- Separate object for expose(..., "number"): volume 0-100.
function MusicCast:volumeControl()
    local device = self
    return {
        get = function(_, feature) return device:getVolume() end,
        set = function(_, feature, value) device:setVolume(value) end,
        getValue = function() return device:getVolume() end
    }
end

--------------------------------------------------------------------------------
-- EVENT SYSTEM
--------------------------------------------------------------------------------

function MusicCast:on_event(event, callback)
    if not self._eventHandlers[event] then
        self._eventHandlers[event] = {}
    end
    table.insert(self._eventHandlers[event], callback)
    return self
end

function MusicCast:emit(event, ...)
    local handlers = self._eventHandlers[event]
    if handlers then
        for _, cb in ipairs(handlers) do
            pcall(cb, ...)
        end
    end
end

function MusicCast:onChange(callback)
    return self:on_event("OnChange", callback)
end

function MusicCast:onTrack(callback)
    return self:on_event("OnTrack", callback)
end

--------------------------------------------------------------------------------
-- PLUGIN FACTORY
--------------------------------------------------------------------------------

local devices = {}

plugin:onInit(function(config)
    plugin:log("info", "MusicCast factory ready")
end)

plugin:onCleanup(function()
    for _, device in pairs(devices) do
        device:_stopPolling()
    end
    devices = {}
    plugin:log("info", "MusicCast cleanup")
end)

--- Create a MusicCast device object
-- @param options table|string { id, ip, name, zone, polling, pollInterval } or a bare ip
-- @return MusicCast
function plugin:create(options)
    if type(options) == "string" then
        options = { ip = options }
    end
    options = options or {}
    if not options.ip then
        error("musiccast:create needs ip")
    end
    local id = options.id or options.ip
    for _, d in ipairs(devices) do
        if d._id == id then
            plugin:log("error", "MusicCast: duplicate id '" .. id .. "', returning the existing device")
            return d
        end
    end

    local device = MusicCast:new(options)
    table.insert(devices, device)

    plugin:log("info", "Created: " .. device._name .. " @ " .. device._ip .. " zone " .. device._zone)

    return device
end

function plugin:getDevices()
    return devices
end

return plugin
