--[[
    Tasmota for vclu: relays and power meters over Tasmota's HTTP API.

    The wizard (Plugins → Configure) finds the devices on the network and writes the module
    with the calls below. By hand:

        local tasmota = Plugin.getPlugin("@vclu/tasmota")
        local plug = tasmota:device({ ip = "192.168.1.50" })
        local lamp = plug:relay(1)
        expose(lamp, "light", { path = "tasmota.lampa", name = "Lampa", area = "Salon" })
        expose(plug:power(), "number", { path = "tasmota.lampa_moc", name = "Lampa moc",
            readonly = true, unit = "W", device_class = "power", state_class = "measurement" })
]]

local plugin = Plugin:new("tasmota", {
    name = "Tasmota",
    version = "1.0.0",
    description = "Tasmota relays and power meters over HTTP"
})

local MAX_RELAYS = 8
local SCAN_PARALLEL = 32
local SCAN_TIMEOUT = 1500

local settings = { interval = 10 }
local devices = {} -- ip -> device

--------------------------------------------------------------------------------
-- HTTP
--------------------------------------------------------------------------------

local function encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- cb(json, err, needsPassword); the password is the plugin's secret and never leaves this
-- function. anonymous: without it, for an address not yet known to be a Tasmota.
local function command(ip, cmnd, cb, timeout, anonymous)
    local url = "http://" .. ip .. "/cm?cmnd=" .. encode(cmnd)
    local password = not anonymous and plugin:secret("password")
    if password and password ~= "" then
        url = url .. "&user=admin&password=" .. encode(password)
    end
    plugin:httpRequest({ url = url, timeout = timeout or 5000, parseJson = "success" }, function(resp)
        local warning = type(resp.json) == "table" and resp.json.WARNING
        if resp.status == 401 or (warning and tostring(warning):find("Need user", 1, true)) then
            cb(nil, "wrong or missing password", true)
        elseif resp.err then
            cb(nil, resp.err)
        elseif type(resp.json) ~= "table" then
            cb(nil, "not a Tasmota answer")
        elseif warning then
            cb(nil, tostring(warning))
        else
            cb(resp.json)
        end
    end)
end

-- "ON"/"OFF" of relay n from a Power or Status 11 answer; a one-relay device answers POWER
local function powerOf(t, n)
    local v = t["POWER" .. n]
    if v == nil and n == 1 then v = t.POWER end
    if v == "ON" then return 1 end
    if v == "OFF" then return 0 end
    return nil
end

local function relayCount(sts)
    local n = 0
    for i = 1, MAX_RELAYS do
        if sts["POWER" .. i] ~= nil then n = i end
    end
    if n == 0 and sts.POWER ~= nil then n = 1 end
    return n
end

-- ENERGY.Power is a number, or a list on a device that measures each channel
local function wattsOf(energy)
    local p = type(energy) == "table" and energy.Power
    if type(p) == "number" then return p end
    if type(p) == "table" then
        local sum = 0
        for _, w in ipairs(p) do sum = sum + (tonumber(w) or 0) end
        return sum
    end
    return nil
end

--------------------------------------------------------------------------------
-- Objects for expose: get, set, onChange returning an unsubscribe
--------------------------------------------------------------------------------

local function newValue(owner)
    local obj = { _owner = owner, _value = nil, _cbs = {} }

    function obj:get() return self._value end
    function obj:getValue() return self._value end
    function obj:isOnline() return self._owner._online end
    function obj:onChange(cb)
        local cbs = self._cbs
        cbs[#cbs + 1] = cb
        return function()
            for i, c in ipairs(cbs) do
                if c == cb then table.remove(cbs, i) return end
            end
        end
    end
    function obj:_update(v)
        if v == nil or v == self._value then return end
        local old = self._value
        self._value = v
        for _, cb in ipairs(self._cbs) do
            local ok, err = pcall(cb, v, old)
            if not ok then plugin:log("warn", self._owner._ip .. ": onChange: " .. tostring(err)) end
        end
    end
    return obj
end

local function newRelay(dev, n)
    local relay = newValue(dev)
    relay._n = n

    local function send(cmnd)
        command(dev._ip, "Power" .. n .. " " .. cmnd, function(json, err)
            if not json then
                plugin:log("warn", dev._ip .. ": Power" .. n .. " " .. cmnd .. ": " .. tostring(err))
                return
            end
            dev._online = true
            relay:_update(powerOf(json, n))
        end)
    end

    function relay:switchOn() send("ON") end
    function relay:switchOff() send("OFF") end
    function relay:toggle() send("TOGGLE") end
    function relay:isOn() return self._value == 1 end
    function relay:set(_, v)
        if v == 1 or v == true or v == "ON" then send("ON") else send("OFF") end
    end
    return relay
end

--------------------------------------------------------------------------------
-- Device: one poller per address, for all of its relays and its power meter
--------------------------------------------------------------------------------

local function newDevice(opts)
    local dev = {
        _ip = opts.ip,
        _interval = tonumber(opts.interval) or settings.interval,
        _relays = {},
        _power = nil,
        _online = false,
        _poller = nil,
    }

    function dev:relay(n)
        n = tonumber(n) or 1
        if n < 1 or n > MAX_RELAYS or n % 1 ~= 0 then
            error("relay(n): n is 1 to " .. MAX_RELAYS, 2)
        end
        if not self._relays[n] then self._relays[n] = newRelay(self, n) end
        return self._relays[n]
    end

    function dev:power()
        if not self._power then self._power = newValue(self) end
        return self._power
    end

    function dev:isOnline() return self._online end
    function dev:refresh() if self._poller then self._poller:poll() end end

    function dev:_read(done)
        command(self._ip, "Status 11", function(json, err)
            if not json then
                self._online = false
                done(nil, err)
                return
            end
            self._online = true
            local sts = json.StatusSTS or {}
            for n, relay in pairs(self._relays) do relay:_update(powerOf(sts, n)) end
            if not self._power then
                done()
                return
            end
            command(self._ip, "Status 10", function(sns, err2)
                if sns then self._power:_update(wattsOf((sns.StatusSNS or {}).ENERGY)) end
                done(nil, err2)
            end)
        end)
    end

    dev._poller = plugin:poller("tasmota_" .. opts.ip:gsub("[^%w]", "_"), {
        interval = dev._interval * 1000,
        immediate = true,
        timeout = 12000,
        onTick = function(done) dev:_read(done) end,
        onError = function(err)
            plugin:log("warn", dev._ip .. ": no answer (" .. tostring(err) .. ")")
        end,
    })
    dev._poller:start()
    return dev
end

--- A Tasmota device at opts.ip; the same address gives the same device.
-- @param opts table { ip, interval (s, default from the wizard) }
function plugin:device(opts)
    if type(opts) == "string" then opts = { ip = opts } end
    if type(opts) ~= "table" or type(opts.ip) ~= "string" or not opts.ip:match("^[%w%.:%-]+$") then
        error("device({ ip = \"192.168.1.50\" }): ip is an address", 2)
    end
    if not devices[opts.ip] then devices[opts.ip] = newDevice(opts) end
    return devices[opts.ip]
end

function plugin:getDevices()
    local list = {}
    for _, d in pairs(devices) do list[#list + 1] = d end
    return list
end

plugin:onInit(function(cfg)
    settings.interval = plugin:coerceNumber(cfg.interval, 10)
end)

plugin:onCleanup(function()
    for _, d in pairs(devices) do d._poller:stop() end
    devices = {}
end)

--------------------------------------------------------------------------------
-- Wizard step 2: find the devices in a /24 network
--------------------------------------------------------------------------------

local function slug(s)
    return (tostring(s):lower():gsub("[^%w]", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", ""))
end

local function rowsOf(ip, json)
    local st, net, sts = json.Status or {}, json.StatusNET or {}, json.StatusSTS or {}
    local n = relayCount(sts)
    if n == 0 then return {} end
    local base = slug(net.Hostname or st.Topic or ip)
    local names = type(st.FriendlyName) == "table" and st.FriendlyName or {}
    local metered = type(json.StatusSNS) == "table" and json.StatusSNS.ENERGY ~= nil
    local rows = {}
    for i = 1, n do
        rows[#rows + 1] = {
            id = n > 1 and (base .. "_" .. i) or base,
            ip = ip,
            relay = i,
            name = names[i] or st.DeviceName or base,
            expose = "switch",
            power = metered and i == 1,
        }
    end
    return rows
end

plugin:discover(function(cfg, done)
    local a, b, c = tostring(cfg.subnet or ""):match("^%s*(%d+)%.(%d+)%.(%d+)%.%d+/24%s*$")
    if not a then
        a, b, c = tostring(cfg.subnet or ""):match("^%s*(%d+)%.(%d+)%.(%d+)%s*$")
    end
    if not a then
        done(nil, "the network is a /24, e.g. 192.168.1.0/24")
        return
    end
    local prefix = a .. "." .. b .. "." .. c .. "."
    local rows, nextHost, pending = {}, 1, 0

    local function launch()
        while pending < SCAN_PARALLEL and nextHost <= 254 do
            local ip = prefix .. nextHost
            nextHost = nextHost + 1
            pending = pending + 1
            local function found(json)
                pending = pending - 1
                if json and (json.Status or json.StatusNET) then
                    for _, row in ipairs(rowsOf(ip, json)) do rows[#rows + 1] = row end
                end
                if nextHost > 254 and pending == 0 then
                    table.sort(rows, function(x, y) return x.id < y.id end)
                    done(rows)
                else
                    launch()
                end
            end
            -- the password goes only to an address that answered as a Tasmota asking for it
            command(ip, "Status 0", function(json, _, needsPassword)
                if needsPassword then
                    command(ip, "Status 0", found, SCAN_TIMEOUT)
                else
                    found(json)
                end
            end, SCAN_TIMEOUT, true)
        end
    end
    launch()
end)

--------------------------------------------------------------------------------
-- Wizard step 3: the module
--------------------------------------------------------------------------------

local BIND_HELPER = [[
-- Keeps a relay and a Grenton DOUT (or a VirtualSwitch) the same, both ways.
-- At the start the object decides: the relay follows it after its first reading.
local function bind(relay, path)
    local obj = _:get(path)
    if not obj then
        Logger:warn("Tasmota: no object " .. path .. " to bind")
        return
    end
    local function apply(target, v)
        if v == 1 then target:switchOn() else target:switchOff() end
    end
    obj:onChange(function(v)
        if relay:getValue() ~= nil and relay:getValue() ~= v then apply(relay, v) end
    end)
    relay:onChange(function(v, old)
        local want = obj:getValue()
        if old == nil then
            if want ~= nil and want ~= v then apply(relay, want) end
        elseif want ~= v then
            apply(obj, v)
        end
    end)
end
]]

local function q(s) return string.format("%q", tostring(s)) end

plugin:moduleCode(function(cfg, rows)
    local out = {
        "local tasmota = Plugin.getPlugin(" .. q(plugin.id) .. ")",
        "if not tasmota then return end",
        "",
    }
    local binds = false
    for _, r in ipairs(rows) do
        if r.bind and r.bind ~= "" then binds = true end
    end
    if binds then out[#out + 1] = BIND_HELPER end

    local devVar, devCount, widgets, seen, metered = {}, 0, {}, {}, {}
    for i, r in ipairs(rows) do
        local id = slug(r.id)
        if id == "" or seen[id] then id = id .. "_" .. i end
        seen[id] = true
        if not devVar[r.ip] then
            devCount = devCount + 1
            devVar[r.ip] = "dev" .. devCount
            out[#out + 1] = string.format("local %s = tasmota:device({ ip = %s })", devVar[r.ip], q(r.ip))
        end
        local v = "relay" .. i
        local area = (r.area and r.area ~= "") and (", area = " .. q(r.area)) or ""
        out[#out + 1] = string.format("local %s = %s:relay(%d) -- %s", v, devVar[r.ip], tonumber(r.relay) or 1, (tostring(r.name):gsub("%s+", " ")))
        if r.expose == "switch" or r.expose == "light" then
            out[#out + 1] = string.format("expose(%s, %q, { path = %s, name = %s%s })", v, r.expose, q("tasmota." .. id), q(r.name), area)
        end
        if r.bind and r.bind ~= "" then
            out[#out + 1] = string.format("bind(%s, %s)", v, q(r.bind))
        end
        local w = { id = id, name = r.name, area = r.area, relay = v, icon = r.expose == "light" and "lightbulb" or "plug" }
        -- a device has one meter: it goes with the first of its relays that asks for it
        if r.power and not metered[r.ip] then
            metered[r.ip] = true
            w.power = v .. "_power"
            out[#out + 1] = string.format("local %s = %s:power()", w.power, devVar[r.ip])
            out[#out + 1] = string.format(
                "expose(%s, \"number\", { path = %s, name = %s, readonly = true, unit = \"W\", device_class = \"power\", state_class = \"measurement\"%s })",
                w.power, q("tasmota." .. id .. "_power"), q(r.name .. " moc"), area)
        end
        widgets[#widgets + 1] = w
        out[#out + 1] = ""
    end

    if cfg.dashboard and #widgets > 0 then
        local name = (cfg.dashboardName and cfg.dashboardName ~= "") and cfg.dashboardName or "Tasmota"
        out[#out + 1] = string.format("Dashboard.new(%s)", q(slug(name) ~= "" and slug(name) or "tasmota"))
        out[#out + 1] = string.format("  :name(%s)", q(name))
        out[#out + 1] = "  :icon('plug')"
        out[#out + 1] = string.format("  :auth(%s)", q(cfg.dashboardAuth or "session"))
        out[#out + 1] = "  :poll(5)"
        -- one section per room, in the order of the list
        local sections, order = {}, {}
        for _, w in ipairs(widgets) do
            local room = (w.area and w.area ~= "") and w.area or name
            if not sections[room] then sections[room] = {} order[#order + 1] = room end
            table.insert(sections[room], w)
        end
        for _, room in ipairs(order) do
            out[#out + 1] = string.format("  :section(%s, 'plug')", q(room))
            for _, w in ipairs(sections[room]) do
                out[#out + 1] = string.format(
                    "    :toggle(%s, %s, %s, function() return %s:getValue() end, function(v) if v then %s:switchOn() else %s:switchOff() end end)",
                    q("tasmota_" .. w.id), q(w.name), q(w.icon), w.relay, w.relay, w.relay)
                if w.power then
                    out[#out + 1] = string.format(
                        "    :status(%s, %s, 'lightning', function() return %s:getValue() end, 'W', { decimals = 0 })",
                        q("tasmota_" .. w.id .. "_power"), q(w.name .. " moc"), w.power)
                end
            end
        end
        out[#out + 1] = "  :build()"
    end
    return table.concat(out, "\n")
end)

return plugin
