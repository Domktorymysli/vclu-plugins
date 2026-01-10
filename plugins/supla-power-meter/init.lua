--- Supla Power Meter Plugin for vCLU
-- Integration with Supla 3-phase power meter via Direct Links API.
--
-- @module plugins.supla-power-meter
--
-- ## Expose API Usage
--
-- ```lua
-- local supla = Plugin.get("@vclu/supla-power-meter")
--
-- -- Moc całkowita (W)
-- expose(supla:get("power"), "number", {
--     name = "Moc",
--     area = "Techniczny",
--     unit = "W",
--     min = 0,
--     max = 20000
-- })
--
-- -- Energia (kWh)
-- expose(supla:get("energy"), "number", {
--     name = "Energia",
--     area = "Techniczny",
--     unit = "kWh"
-- })
--
-- -- Napięcie fazy 1
-- expose(supla:get("voltage1"), "number", {
--     name = "Napięcie L1",
--     area = "Techniczny",
--     unit = "V"
-- })
-- ```
--
-- ## Available Sensors
--
-- | ID            | Unit | Description              |
-- |---------------|------|--------------------------|
-- | power         | W    | Moc całkowita            |
-- | current       | A    | Prąd całkowity           |
-- | energy        | kWh  | Energia pobrana          |
-- | reverseEnergy | kWh  | Energia oddana           |
-- | frequency     | Hz   | Częstotliwość sieci      |
-- | connected     | 0/1  | Status połączenia        |
-- | voltage1/2/3  | V    | Napięcie fazy 1/2/3      |
-- | power1/2/3    | W    | Moc fazy 1/2/3           |
-- | current1/2/3  | A    | Prąd fazy 1/2/3          |

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local supla = Plugin:new("supla-power-meter", {
    name = "Supla Power Meter",
    version = "2.1.0",
    description = "Supla 3-phase power meter integration with expose API support"
})

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local state = {
    ready = false,
    lastUpdate = 0,
    lastError = nil,
    connected = false,
    -- Total values
    totalPower = 0,
    totalCurrent = 0,
    totalEnergy = 0,
    totalReverseEnergy = 0,
    totalCost = 0,
    -- Per-phase data
    phases = {},
    -- Metadata
    currency = "",
    pricePerUnit = 0
}

local poller = nil

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function normalizeUrl(url)
    url = url:gsub("/$", "")
    if not url:find("format=json") then
        if url:find("?") then
            url = url .. "&format=json"
        else
            url = url .. "?format=json"
        end
    end
    return url
end

local function parsePhase(phaseData)
    return {
        number = supla:coerceNumber(phaseData.number, 0),
        frequency = supla:coerceNumber(phaseData.frequency, 0),
        voltage = supla:coerceNumber(phaseData.voltage, 0),
        current = supla:coerceNumber(phaseData.current, 0),
        powerActive = supla:coerceNumber(phaseData.powerActive, 0),
        powerReactive = supla:coerceNumber(phaseData.powerReactive, 0),
        powerApparent = supla:coerceNumber(phaseData.powerApparent, 0),
        powerFactor = supla:coerceNumber(phaseData.powerFactor, 0),
        phaseAngle = supla:coerceNumber(phaseData.phaseAngle, 0),
        forwardEnergy = supla:coerceNumber(phaseData.totalForwardActiveEnergy, 0),
        reverseEnergy = supla:coerceNumber(phaseData.totalReverseActiveEnergy, 0),
        forwardReactiveEnergy = supla:coerceNumber(phaseData.totalForwardReactiveEnergy, 0),
        reverseReactiveEnergy = supla:coerceNumber(phaseData.totalReverseReactiveEnergy, 0)
    }
end

local function parseResponse(json)
    if not json then
        return nil, "Invalid JSON"
    end

    local totalPower = 0
    local totalCurrent = 0
    local totalEnergy = 0
    local totalReverseEnergy = 0
    local phases = {}

    if json.phases then
        for i, phase in ipairs(json.phases) do
            local parsed = parsePhase(phase)
            phases[i] = parsed
            totalPower = totalPower + parsed.powerActive
            totalCurrent = totalCurrent + parsed.current
            totalEnergy = totalEnergy + parsed.forwardEnergy
            totalReverseEnergy = totalReverseEnergy + parsed.reverseEnergy
        end
    end

    return {
        connected = supla:coerceBool(json.connected, false),
        totalPower = totalPower,
        totalCurrent = totalCurrent,
        totalEnergy = totalEnergy,
        totalReverseEnergy = totalReverseEnergy,
        totalCost = supla:coerceNumber(json.totalCost, 0),
        currency = supla:coerceString(json.currency, ""),
        pricePerUnit = supla:coerceNumber(json.pricePerUnit, 0),
        phases = phases,
        phaseCount = #phases
    }
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

supla:onInit(function(config)
    if not config.directUrl or config.directUrl == "" then
        supla:log("error", "directUrl is required")
        return
    end

    local interval = supla:coerceNumber(config.interval, 60)
    local url = normalizeUrl(config.directUrl)

    supla:logSafe("info", "Initializing", { interval = interval })

    -- Create initial registry object
    supla:upsertObject("power", {
        ready = false,
        connected = false,
        totalPower = 0,
        totalCurrent = 0,
        totalEnergy = 0,
        totalReverseEnergy = 0,
        totalCost = 0,
        currency = "",
        pricePerUnit = 0,
        phaseCount = 0,
        phase1 = {},
        phase2 = {},
        phase3 = {},
        lastUpdate = 0
    })

    ---------------------------------------------------------------------------
    -- SENSORS (for expose API)
    ---------------------------------------------------------------------------

    -- Total values
    supla:sensor("power", function() return state.totalPower end)
    supla:sensor("current", function() return state.totalCurrent end)
    supla:sensor("energy", function() return state.totalEnergy end)
    supla:sensor("reverseEnergy", function() return state.totalReverseEnergy end)
    supla:sensor("frequency", function()
        local phase = state.phases[1]
        return phase and phase.frequency or 0
    end)
    supla:sensor("connected", function() return state.connected and 1 or 0 end)

    -- Per-phase voltage
    supla:sensor("voltage1", function()
        local phase = state.phases[1]
        return phase and phase.voltage or 0
    end)
    supla:sensor("voltage2", function()
        local phase = state.phases[2]
        return phase and phase.voltage or 0
    end)
    supla:sensor("voltage3", function()
        local phase = state.phases[3]
        return phase and phase.voltage or 0
    end)

    -- Per-phase power
    supla:sensor("power1", function()
        local phase = state.phases[1]
        return phase and phase.powerActive or 0
    end)
    supla:sensor("power2", function()
        local phase = state.phases[2]
        return phase and phase.powerActive or 0
    end)
    supla:sensor("power3", function()
        local phase = state.phases[3]
        return phase and phase.powerActive or 0
    end)

    -- Per-phase current
    supla:sensor("current1", function()
        local phase = state.phases[1]
        return phase and phase.current or 0
    end)
    supla:sensor("current2", function()
        local phase = state.phases[2]
        return phase and phase.current or 0
    end)
    supla:sensor("current3", function()
        local phase = state.phases[3]
        return phase and phase.current or 0
    end)

    -- Create poller
    poller = supla:poller("fetch", {
        interval = interval * 1000,
        immediate = true,
        timeout = 15000,
        retry = { maxAttempts = 2, backoff = 2000 },

        onTick = function(done)
            supla:httpRequest({
                url = url,
                timeout = 10000,
                parseJson = "success",
                log = { redact = true }
            }, function(resp)
                if resp.err then
                    done(resp.err)
                    return
                end

                local data, parseErr = parseResponse(resp.json)
                if not data then
                    done(parseErr or "Parse error")
                    return
                end

                local wasConnected = state.connected
                local changed = state.totalPower ~= data.totalPower or
                                state.connected ~= data.connected

                -- Update state
                state.ready = true
                state.lastUpdate = os.time()
                state.lastError = nil
                state.connected = data.connected
                state.totalPower = data.totalPower
                state.totalCurrent = data.totalCurrent
                state.totalEnergy = data.totalEnergy
                state.totalReverseEnergy = data.totalReverseEnergy
                state.totalCost = data.totalCost
                state.currency = data.currency
                state.pricePerUnit = data.pricePerUnit
                state.phases = data.phases

                -- Update registry
                supla:updateObject("power", {
                    ready = true,
                    connected = data.connected,
                    totalPower = data.totalPower,
                    totalCurrent = data.totalCurrent,
                    totalEnergy = data.totalEnergy,
                    totalReverseEnergy = data.totalReverseEnergy,
                    totalCost = data.totalCost,
                    currency = data.currency,
                    pricePerUnit = data.pricePerUnit,
                    phaseCount = #data.phases,
                    phase1 = data.phases[1] or {},
                    phase2 = data.phases[2] or {},
                    phase3 = data.phases[3] or {},
                    lastUpdate = state.lastUpdate
                })

                supla:log("info", string.format(
                    "Power: %.0fW, Current: %.1fA, Energy: %.2fkWh, Connected: %s",
                    data.totalPower, data.totalCurrent, data.totalEnergy, tostring(data.connected)
                ))

                -- Notify sensors for expose API
                local function notifySensor(id)
                    local sensor = supla:get(id)
                    if sensor and sensor._notify then sensor:_notify() end
                end

                notifySensor("power")
                notifySensor("current")
                notifySensor("energy")
                notifySensor("reverseEnergy")
                notifySensor("frequency")
                notifySensor("connected")
                notifySensor("voltage1")
                notifySensor("voltage2")
                notifySensor("voltage3")
                notifySensor("power1")
                notifySensor("power2")
                notifySensor("power3")
                notifySensor("current1")
                notifySensor("current2")
                notifySensor("current3")

                -- Emit events
                if changed then
                    supla:emit("supla:updated", {
                        connected = data.connected,
                        totalPower = data.totalPower,
                        totalCurrent = data.totalCurrent,
                        totalEnergy = data.totalEnergy
                    }, { throttle = 30000 })
                end

                if wasConnected and not data.connected then
                    supla:log("warn", "Power meter disconnected")
                    supla:emit("supla:disconnected", {})
                end

                done()
            end)
        end,

        onError = function(err, stats)
            state.lastError = err
            supla:log("error", "Fetch failed: " .. tostring(err))
            supla:emit("supla:error", { error = err })
        end
    })

    poller:start()
end)

supla:onCleanup(function()
    if poller then
        poller:stop()
    end
    supla:log("info", "Supla plugin stopped")
end)

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

function supla:isConnected()
    return state.connected
end

function supla:isReady()
    return state.ready
end

function supla:getLastError()
    return state.lastError
end

function supla:getTotalPower()
    return state.totalPower
end

function supla:getTotalCurrent()
    return state.totalCurrent
end

function supla:getTotalEnergy()
    return state.totalEnergy
end

function supla:getReverseEnergy()
    return state.totalReverseEnergy
end

function supla:getTotalCost()
    return state.totalCost
end

function supla:getCurrency()
    return state.currency
end

function supla:getPricePerUnit()
    return state.pricePerUnit
end

function supla:getPhaseCount()
    return #state.phases
end

function supla:getPhase(phaseNum)
    return state.phases[phaseNum]
end

function supla:getVoltage(phaseNum)
    local phase = state.phases[phaseNum]
    return phase and phase.voltage or 0
end

function supla:getCurrent(phaseNum)
    local phase = state.phases[phaseNum]
    return phase and phase.current or 0
end

function supla:getPower(phaseNum)
    local phase = state.phases[phaseNum]
    return phase and phase.powerActive or 0
end

function supla:getFrequency()
    local phase = state.phases[1]
    return phase and phase.frequency or 0
end

function supla:getPhases()
    return state.phases
end

function supla:getLastUpdate()
    return state.lastUpdate
end

function supla:getData()
    return {
        ready = state.ready,
        connected = state.connected,
        totalPower = state.totalPower,
        totalCurrent = state.totalCurrent,
        totalEnergy = state.totalEnergy,
        totalReverseEnergy = state.totalReverseEnergy,
        totalCost = state.totalCost,
        currency = state.currency,
        pricePerUnit = state.pricePerUnit,
        phases = state.phases,
        phaseCount = #state.phases,
        lastUpdate = state.lastUpdate,
        lastError = state.lastError
    }
end

function supla:refresh()
    if poller then
        poller:poll()
    end
end

function supla:getStats()
    if poller then
        return poller:stats()
    end
    return {}
end

return supla
