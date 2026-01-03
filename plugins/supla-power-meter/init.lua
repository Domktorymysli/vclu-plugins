--- Supla Power Meter Plugin for vCLU
-- Integration with Supla 3-phase power meter via Direct Links API
-- @module plugins.supla-power-meter
-- @see https://cloud.supla.org/integrations/tokens
-- @see https://svr59.supla.org/api-docs/docs.html

local supla = Plugin:new("supla-power-meter", {
    name = "Supla Power Meter",
    version = "1.0.0",
    description = "Supla 3-phase power meter integration"
})

-- ============================================
-- INTERNAL STATE
-- ============================================

local data = {
    connected = false,
    -- Total values
    totalPower = 0,           -- Total active power (all phases) [W]
    totalCurrent = 0,         -- Total current (all phases) [A]
    totalEnergy = 0,          -- Total forward active energy [kWh]
    totalReverseEnergy = 0,   -- Total reverse active energy (solar) [kWh]
    totalCost = 0,            -- Total cost
    -- Per-phase data
    phases = {},              -- Array of phase data
    -- Metadata
    currency = "",
    pricePerUnit = 0,
    lastUpdate = 0,
    error = nil
}

local refreshTimerId = nil

-- ============================================
-- HELPERS
-- ============================================

--- Normalize Direct Link URL
local function normalizeUrl(url)
    -- Remove trailing slash
    url = url:gsub("/$", "")
    -- Ensure ?format=json suffix
    if not url:find("format=json") then
        if url:find("?") then
            url = url .. "&format=json"
        else
            url = url .. "?format=json"
        end
    end
    return url
end

--- Parse phase data from API response
local function parsePhase(phaseData)
    return {
        number = phaseData.number or 0,
        frequency = phaseData.frequency or 0,
        voltage = phaseData.voltage or 0,
        current = phaseData.current or 0,
        powerActive = phaseData.powerActive or 0,
        powerReactive = phaseData.powerReactive or 0,
        powerApparent = phaseData.powerApparent or 0,
        powerFactor = phaseData.powerFactor or 0,
        phaseAngle = phaseData.phaseAngle or 0,
        forwardEnergy = phaseData.totalForwardActiveEnergy or 0,
        reverseEnergy = phaseData.totalReverseActiveEnergy or 0,
        forwardReactiveEnergy = phaseData.totalForwardReactiveEnergy or 0,
        reverseReactiveEnergy = phaseData.totalReverseReactiveEnergy or 0
    }
end

--- Parse API response
local function parseResponse(body)
    local jsonData = JSON:decode(body)

    if not jsonData then
        return nil, "Invalid JSON response"
    end

    -- Calculate totals from phases
    local totalPower = 0
    local totalCurrent = 0
    local totalEnergy = 0
    local totalReverseEnergy = 0
    local phases = {}

    if jsonData.phases then
        for i, phase in ipairs(jsonData.phases) do
            local parsed = parsePhase(phase)
            phases[i] = parsed
            totalPower = totalPower + parsed.powerActive
            totalCurrent = totalCurrent + parsed.current
            totalEnergy = totalEnergy + parsed.forwardEnergy
            totalReverseEnergy = totalReverseEnergy + parsed.reverseEnergy
        end
    end

    return {
        connected = jsonData.connected or false,
        totalPower = totalPower,
        totalCurrent = totalCurrent,
        totalEnergy = totalEnergy,
        totalReverseEnergy = totalReverseEnergy,
        totalCost = jsonData.totalCost or 0,
        currency = jsonData.currency or "",
        pricePerUnit = jsonData.pricePerUnit or 0,
        phases = phases,
        phaseCount = #phases
    }
end

-- ============================================
-- DATA FETCHING
-- ============================================

--- Fetch data from Supla API
local function fetchData(callback)
    local config = supla.config
    local url = normalizeUrl(config.directUrl)

    supla:log("debug", "Fetching from: " .. url)

    supla:httpGet(url, function(response, err)
        if err then
            callback(nil, err)
            return
        end

        if not response or response.status ~= 200 then
            callback(nil, "HTTP " .. tostring(response and response.status or "error"))
            return
        end

        local parsed, parseErr = parseResponse(response.body)
        if not parsed then
            callback(nil, parseErr or "Parse error")
            return
        end

        callback(parsed, nil)
    end)
end

--- Update internal state and emit events
local function updateData(newData)
    local wasConnected = data.connected
    local changed = data.totalPower ~= newData.totalPower or
                    data.connected ~= newData.connected

    -- Update state
    data.connected = newData.connected
    data.totalPower = newData.totalPower
    data.totalCurrent = newData.totalCurrent
    data.totalEnergy = newData.totalEnergy
    data.totalReverseEnergy = newData.totalReverseEnergy
    data.totalCost = newData.totalCost
    data.currency = newData.currency
    data.pricePerUnit = newData.pricePerUnit
    data.phases = newData.phases
    data.lastUpdate = os.time()
    data.error = nil

    -- Log update
    supla:log("info", string.format(
        "Power: %.0fW, Current: %.1fA, Energy: %.2fkWh, Connected: %s",
        data.totalPower,
        data.totalCurrent,
        data.totalEnergy,
        tostring(data.connected)
    ))

    -- Update registry object
    supla:createObject("power", {
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
        lastUpdate = data.lastUpdate
    })

    -- Emit events
    if changed then
        supla:emit("supla:updated", {
            connected = data.connected,
            totalPower = data.totalPower,
            totalCurrent = data.totalCurrent,
            totalEnergy = data.totalEnergy
        })
    end

    -- Connection state change
    if wasConnected and not data.connected then
        supla:log("warn", "Power meter disconnected")
        supla:emit("supla:disconnected", {})
    end
end

--- Refresh data from API
local function refresh()
    fetchData(function(newData, err)
        if err then
            data.error = err
            supla:log("error", "Fetch failed: " .. tostring(err))
            supla:emit("supla:error", { error = err })
            return
        end
        updateData(newData)
    end)
end

-- ============================================
-- INITIALIZATION
-- ============================================

supla:onInit(function(config)
    if not config.directUrl or config.directUrl == "" then
        supla:log("error", "Direct Link URL is required")
        return
    end

    config.interval = tonumber(config.interval) or 60

    supla:log("info", string.format(
        "Initializing: url=%s, interval=%ds",
        config.directUrl:sub(1, 50) .. "...",
        config.interval
    ))

    -- Setup refresh timer
    if config.interval > 0 then
        local intervalMs = config.interval * 1000
        refreshTimerId = supla:setInterval(intervalMs, refresh)
    end

    -- Initial fetch after short delay
    supla:setTimeout(2000, refresh)
end)

supla:onCleanup(function()
    if refreshTimerId then
        supla:clearTimer(refreshTimerId)
    end
    supla:log("info", "Supla plugin stopped")
end)

-- ============================================
-- PUBLIC API
-- ============================================

--- Check if power meter is connected
function supla:isConnected()
    return data.connected
end

--- Get total active power (all phases) in Watts
function supla:getTotalPower()
    return data.totalPower
end

--- Get total current (all phases) in Amps
function supla:getTotalCurrent()
    return data.totalCurrent
end

--- Get total forward active energy in kWh
function supla:getTotalEnergy()
    return data.totalEnergy
end

--- Get total reverse active energy (solar export) in kWh
function supla:getReverseEnergy()
    return data.totalReverseEnergy
end

--- Get total cost
function supla:getTotalCost()
    return data.totalCost
end

--- Get currency code
function supla:getCurrency()
    return data.currency
end

--- Get price per unit (kWh)
function supla:getPricePerUnit()
    return data.pricePerUnit
end

--- Get number of phases
function supla:getPhaseCount()
    return #data.phases
end

--- Get phase data by number (1-3)
-- @param phaseNum number Phase number (1, 2, or 3)
-- @return table Phase data or nil
function supla:getPhase(phaseNum)
    return data.phases[phaseNum]
end

--- Get voltage for specific phase
-- @param phaseNum number Phase number (1, 2, or 3)
-- @return number Voltage in Volts
function supla:getVoltage(phaseNum)
    local phase = data.phases[phaseNum]
    return phase and phase.voltage or 0
end

--- Get current for specific phase
-- @param phaseNum number Phase number (1, 2, or 3)
-- @return number Current in Amps
function supla:getCurrent(phaseNum)
    local phase = data.phases[phaseNum]
    return phase and phase.current or 0
end

--- Get power for specific phase
-- @param phaseNum number Phase number (1, 2, or 3)
-- @return number Active power in Watts
function supla:getPower(phaseNum)
    local phase = data.phases[phaseNum]
    return phase and phase.powerActive or 0
end

--- Get frequency (from phase 1)
function supla:getFrequency()
    local phase = data.phases[1]
    return phase and phase.frequency or 0
end

--- Get all phases data
function supla:getPhases()
    return data.phases
end

--- Get last update timestamp
function supla:getLastUpdate()
    return data.lastUpdate
end

--- Get last error
function supla:getError()
    return data.error
end

--- Get all data
function supla:getData()
    return {
        connected = data.connected,
        totalPower = data.totalPower,
        totalCurrent = data.totalCurrent,
        totalEnergy = data.totalEnergy,
        totalReverseEnergy = data.totalReverseEnergy,
        totalCost = data.totalCost,
        currency = data.currency,
        pricePerUnit = data.pricePerUnit,
        phases = data.phases,
        phaseCount = #data.phases,
        lastUpdate = data.lastUpdate,
        error = data.error
    }
end

--- Force refresh data
function supla:refresh()
    refresh()
end

return supla
