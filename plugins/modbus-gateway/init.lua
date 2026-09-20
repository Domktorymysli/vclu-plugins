--- Modbus Gateway Plugin for vCLU
-- Reads Modbus RTU devices sitting behind an RS485-to-Ethernet gateway
-- (Waveshare RS485 TO ETH, USR-TCP232, Elfin EW11 ...) over Modbus TCP.
--
-- The gateway must run in "TCP Server" mode with "Modbus TCP to RTU" enabled,
-- and its serial settings must match the bus (SDM120M ships as 9600 8N1).
--
-- @module plugins.modbus-gateway
--
-- ## Expose API Usage (in user.lua)
--
-- ```lua
-- local mb = Plugin.get("@vclu/modbus-gateway")
--
-- expose(mb:get("pralka_power"),  "number", { name = "Pralka moc",  area = "Energia", unit = "W" })
-- expose(mb:get("pralka_energy"), "number", { name = "Pralka zużycie", area = "Energia", unit = "kWh" })
-- expose(mb:get("pralka_online"), "binary_sensor", { name = "Pralka licznik online", area = "Energia" })
-- ```
--
-- ## Sensors
--
-- One set per configured device, prefixed with the device id:
--
-- | Suffix      | Unit | Description                        |
-- |-------------|------|------------------------------------|
-- | _voltage    | V    | Napięcie                           |
-- | _current    | A    | Prąd                               |
-- | _power      | W    | Moc czynna                         |
-- | _apparent   | VA   | Moc pozorna                        |
-- | _reactive   | var  | Moc bierna                         |
-- | _pf         |      | Współczynnik mocy                  |
-- | _frequency  | Hz   | Częstotliwość                      |
-- | _energy     | kWh  | Energia pobrana                    |
-- | _exported   | kWh  | Energia oddana                     |
-- | _online     | 0/1  | Czy ostatni odczyt się powiódł     |
--
-- Plus a gateway-wide `online` sensor.

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local gateway = Plugin:new("modbus-gateway", {
    name = "Modbus Gateway",
    version = "1.0.0",
    description = "Odczyt urządzeń Modbus RTU przez bramkę RS485-Ethernet (Modbus TCP)"
})

--------------------------------------------------------------------------------
-- DEVICE PROFILES
--------------------------------------------------------------------------------

-- Register maps are split into blocks of contiguous registers, so a device is
-- read in a few transactions instead of one per field.
-- Eastron SDM120/SDM220/SDM230 all expose 32-bit big-endian floats via FC04.
local PROFILES = {
    sdm120 = {
        label = "Eastron SDM120 / VCX SDM120M",
        fc = Modbus.READ_INPUT,
        blocks = {
            { base = 0x0000, qty = 32 },
            { base = 0x0046, qty = 10 },
            { base = 0x0156, qty = 4 }
        },
        fields = {
            { id = "voltage",   addr = 0x0000, unit = "V" },
            { id = "current",   addr = 0x0006, unit = "A" },
            { id = "power",     addr = 0x000C, unit = "W" },
            { id = "apparent",  addr = 0x0012, unit = "VA" },
            { id = "reactive",  addr = 0x0018, unit = "var" },
            { id = "pf",        addr = 0x001E, unit = "" },
            { id = "frequency", addr = 0x0046, unit = "Hz" },
            { id = "energy",    addr = 0x0048, unit = "kWh" },
            { id = "exported",  addr = 0x004A, unit = "kWh" },
            { id = "total",     addr = 0x0156, unit = "kWh" }
        }
    }
}

-- SDM630 and friends share the layout for the fields we care about.
PROFILES.sdm220 = PROFILES.sdm120
PROFILES.sdm230 = PROFILES.sdm120

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local state = {
    ready = false,
    online = false,
    lastUpdate = 0,
    lastError = nil,
    devices = {} -- id -> { online, values = {}, lastError, blockMode }
}

local devices = {}  -- ordered list of configured devices
local settings = {} -- host, port, timeout
local poller = nil

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function profileFor(device)
    if device.registers then
        -- Custom map: { {id="temp", addr=0x0010, type="float"}, ... }
        return {
            label = "custom",
            fc = device.fc or Modbus.READ_INPUT,
            blocks = nil,
            fields = device.registers
        }
    end
    return PROFILES[device.profile or "sdm120"]
end

-- 16-bit fields occupy one register; reading two can run off the end of the map.
local function registerCount(field)
    local kind = field.type or "float"
    if kind == "int16" or kind == "raw" then return 1 end
    return 2
end

local function decodeField(field, registers, base)
    local kind = field.type or "float"
    local i = field.addr - base + 1
    if kind == "float" then
        return Modbus.toFloat32(registers[i], registers[i + 1])
    elseif kind == "int32" then
        return Modbus.toInt32(registers[i], registers[i + 1])
    elseif kind == "uint32" then
        return Modbus.toUint32(registers[i], registers[i + 1])
    elseif kind == "int16" then
        return Modbus.toInt16(registers[i])
    end
    return registers[i]
end

local function fieldsInBlock(profile, block)
    local out = {}
    for _, field in ipairs(profile.fields) do
        if field.addr >= block.base and field.addr < block.base + block.qty then
            table.insert(out, field)
        end
    end
    return out
end

-- A device may be given as a bare unit address, since one gateway usually
-- carries several identical meters and only the address differs.
local function normalizeDevice(entry)
    if type(entry) == "number" then
        entry = { unit = entry }
    elseif type(entry) ~= "table" then
        return nil
    end

    local unit = gateway:coerceNumber(entry.unit, 0)
    if unit < 1 or unit > 247 then return nil end

    local id = gateway:coerceString(entry.id, "")
    if id == "" then id = "meter" .. tostring(unit) end

    return {
        id = id,
        unit = unit,
        name = gateway:coerceString(entry.name, id),
        profile = gateway:coerceString(entry.profile, "sdm120"),
        registers = entry.registers,
        fc = entry.fc
    }
end

local function sensorId(device, fieldId)
    return device.id .. "_" .. fieldId
end

local function notify(id)
    local s = gateway:get(id)
    if s and s.emit then s:emit("OnChange", s:get()) end
end

--------------------------------------------------------------------------------
-- READING
--------------------------------------------------------------------------------

-- Reads one device and calls done(values, err). Blocks are chained so the RS485 bus
-- carries one transaction at a time.
local function readDevice(device, done)
    local profile = profileFor(device)
    if not profile then
        done(nil, "unknown profile: " .. tostring(device.profile))
        return
    end

    local ds = state.devices[device.id]
    local collected = {}

    -- Per-field reads: the fallback when a device rejects block reads.
    local function readFields(index)
        local field = profile.fields[index]
        if not field then
            done(collected, nil)
            return
        end
        Modbus.request({
            host = settings.host, port = settings.port,
            unit = device.unit, fc = profile.fc,
            addr = field.addr, qty = registerCount(field), timeout = settings.timeout
        }, function(registers, err)
            if err then
                done(nil, err)
                return
            end
            collected[field.id] = decodeField(field, registers, field.addr)
            readFields(index + 1)
        end)
    end

    local function readBlocks(index)
        local block = profile.blocks[index]
        if not block then
            done(collected, nil)
            return
        end
        Modbus.request({
            host = settings.host, port = settings.port,
            unit = device.unit, fc = profile.fc,
            addr = block.base, qty = block.qty, timeout = settings.timeout
        }, function(registers, err)
            if err then
                -- "illegal data address" means the device dislikes wide reads;
                -- drop to per-field mode for good rather than failing every tick.
                if tostring(err):find("illegal data address") and ds.blockMode then
                    ds.blockMode = false
                    gateway:log("warn", string.format(
                        "%s (unit %d): block read rejected, switching to per-register reads",
                        device.id, device.unit))
                    readFields(1)
                    return
                end
                done(nil, err)
                return
            end
            for _, field in ipairs(fieldsInBlock(profile, block)) do
                collected[field.id] = decodeField(field, registers, block.base)
            end
            readBlocks(index + 1)
        end)
    end

    if profile.blocks and ds.blockMode then
        readBlocks(1)
    else
        readFields(1)
    end
end

local function applyResult(device, values)
    local ds = state.devices[device.id]
    local wasOnline = ds.online
    ds.online = true
    ds.lastError = nil
    ds.values = values

    for fieldId, value in pairs(values) do
        notify(sensorId(device, fieldId))
    end
    if not wasOnline then notify(sensorId(device, "online")) end

    gateway:updateObject("devices." .. device.id, {
        name = device.name or device.id,
        unit = device.unit,
        online = true,
        values = values,
        lastUpdate = os.time()
    })
end

local function applyError(device, err)
    local ds = state.devices[device.id]
    local wasOnline = ds.online
    ds.online = false
    ds.lastError = err

    if wasOnline then
        notify(sensorId(device, "online"))
        gateway:emit("modbus:device_offline", { device = device.id, unit = device.unit, error = err })
    end
    gateway:updateObject("devices." .. device.id, { online = false, lastError = err })
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

gateway:onInit(function(config)
    if not Modbus or not Modbus.isAvailable() then
        gateway:log("error", "Modbus backend not available - vCLU >= 1.1.0 required")
        return
    end

    settings.host = gateway:coerceString(config.host, "")
    settings.port = gateway:coerceNumber(config.port, 502)
    settings.timeout = gateway:coerceNumber(config.timeout, 2000)
    local interval = gateway:coerceNumber(config.interval, 30)

    if settings.host == "" then
        gateway:log("error", "host is required (adres bramki, np. 192.168.0.9)")
        return
    end

    -- Drop state from a previous init; a reconfigured plugin may list fewer devices.
    devices = {}
    state.devices = {}
    if type(config.devices) == "table" then
        for _, entry in ipairs(config.devices) do
            local device = normalizeDevice(entry)
            if device then
                table.insert(devices, device)
            else
                gateway:log("warn", "skipping invalid device entry (need a unit address 1-247)")
            end
        end
    end

    if #devices == 0 then
        gateway:log("error", "no devices configured")
        return
    end

    gateway:logSafe("info", "Initializing", {
        host = settings.host, port = settings.port,
        devices = #devices, interval = interval
    })

    gateway:upsertObject("gateway", {
        ready = false, online = false,
        host = settings.host, port = settings.port,
        deviceCount = #devices, lastUpdate = 0
    })

    ---------------------------------------------------------------------------
    -- SENSORS
    ---------------------------------------------------------------------------
    for _, device in ipairs(devices) do
        state.devices[device.id] = { online = false, values = {}, blockMode = true }

        local profile = profileFor(device)
        if profile then
            for _, field in ipairs(profile.fields) do
                local deviceId, fieldId = device.id, field.id
                gateway:sensor(sensorId(device, fieldId), function()
                    return state.devices[deviceId].values[fieldId] or 0
                end)
            end
        end

        local deviceId = device.id
        gateway:sensor(sensorId(device, "online"), function()
            return state.devices[deviceId].online and 1 or 0
        end)

        gateway:upsertObject("devices." .. device.id, {
            name = device.name, unit = device.unit,
            online = false, values = {}, lastUpdate = 0
        })
    end

    gateway:sensor("online", function() return state.online and 1 or 0 end)

    ---------------------------------------------------------------------------
    -- POLLER
    ---------------------------------------------------------------------------
    poller = gateway:poller("read", {
        interval = interval * 1000,
        immediate = true,
        -- Worst case: every device times out twice on the Go side.
        timeout = math.max(15000, #devices * settings.timeout * 3),

        onTick = function(done)
            local index = 1
            local anySuccess = false
            local failures = {}

            local function step()
                local device = devices[index]
                if not device then
                    state.ready = true
                    state.online = anySuccess
                    state.lastUpdate = os.time()
                    state.lastError = (#failures > 0) and table.concat(failures, "; ") or nil

                    gateway:updateObject("gateway", {
                        ready = true, online = anySuccess, lastUpdate = state.lastUpdate
                    })
                    notify("online")

                    if anySuccess then
                        gateway:emit("modbus:updated", { devices = #devices - #failures }, { throttle = 30000 })
                        -- A silent device is normal and often permanent, so it
                        -- must not back the poller off; _online carries the news.
                        if #failures > 0 then
                            gateway:log("warn", "partial read: " .. state.lastError)
                        end
                        done({ read = #devices - #failures, failed = #failures }, nil)
                    else
                        done(nil, state.lastError or "no device responded")
                    end
                    return
                end

                index = index + 1
                readDevice(device, function(values, err)
                    if err then
                        applyError(device, err)
                        table.insert(failures, device.id .. ": " .. tostring(err))
                    else
                        applyResult(device, values)
                        anySuccess = true
                    end
                    step()
                end)
            end

            step()
        end,

        onError = function(err)
            state.online = false
            state.lastError = err
            gateway:log("warn", "Read cycle failed: " .. tostring(err))
            gateway:emit("modbus:error", { error = err })
        end
    })

    poller:start()
end)

gateway:onCleanup(function()
    if poller then poller:stop() end
    gateway:log("info", "Modbus gateway plugin stopped")
end)

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

function gateway:isReady() return state.ready end
function gateway:isOnline() return state.online end
function gateway:getLastError() return state.lastError end
function gateway:getLastUpdate() return state.lastUpdate end

--- All decoded values for one device, e.g. gateway:getDevice("pralka").power
function gateway:getDevice(id)
    local ds = state.devices[id]
    if not ds then return nil end
    return {
        online = ds.online,
        lastError = ds.lastError,
        values = ds.values
    }
end

--- One decoded field, e.g. gateway:getValue("pralka", "power")
function gateway:getValue(deviceId, fieldId)
    local ds = state.devices[deviceId]
    if not ds then return nil end
    return ds.values[fieldId]
end

function gateway:listDevices()
    local out = {}
    for _, device in ipairs(devices) do
        table.insert(out, { id = device.id, unit = device.unit, name = device.name, profile = device.profile })
    end
    return out
end

--- Raw read, for devices without a profile.
-- @param opts table unit, addr, qty, fc (defaults to FC04)
function gateway:read(opts, callback)
    opts = opts or {}
    Modbus.request({
        host = settings.host, port = settings.port,
        unit = opts.unit or 1, fc = opts.fc or Modbus.READ_INPUT,
        addr = opts.addr or 0, qty = opts.qty or 2,
        timeout = opts.timeout or settings.timeout
    }, callback)
end

--- Write a single holding register (FC06).
function gateway:write(opts, callback)
    opts = opts or {}
    Modbus.writeSingle({
        host = settings.host, port = settings.port,
        unit = opts.unit or 1, addr = opts.addr or 0,
        value = opts.value or 0, timeout = opts.timeout or settings.timeout
    }, callback)
end

function gateway:refresh()
    if poller then poller:poll() end
end

function gateway:getStats()
    local stats = Modbus.stats()
    if poller then stats.poller = poller:stats() end
    return stats
end

return gateway
