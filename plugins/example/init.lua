--[[
    Example Plugin dla vCLU

    Ten plik pokazuje minimum potrzebne do stworzenia pluginu
    oraz przykłady użycia HTTP, MQTT i Registry.

    Struktura pluginu:
        plugins/example/
        ├── plugin.json     -- manifest (wymagany)
        └── init.lua        -- kod pluginu (wymagany)
]]

-- ============================================
-- MINIMUM - Rejestracja pluginu
-- ============================================

local plugin = Plugin:new("example", {
    name = "Example Plugin",
    version = "1.0.0"
})

-- Callback wywoływany przy starcie pluginu
plugin:onInit(function(config)
    plugin:log("info", "Plugin załadowany!")
    plugin:log("info", "Config greeting: " .. tostring(config.greeting))

    -- Tutaj inicjalizuj swój plugin...
end)

-- Callback wywoływany przy wyłączeniu pluginu (opcjonalny)
plugin:onCleanup(function()
    plugin:log("info", "Plugin wyłączany...")
    -- Tutaj posprzątaj zasoby jeśli potrzeba
    -- (timery i eventy są czyszczone automatycznie przez sandbox)
end)


-- ============================================
-- PRZYKŁAD: Timery
-- ============================================
--[[

-- Jednorazowy timer (po 5 sekundach)
plugin:setTimeout(5000, function()
    plugin:log("info", "Minęło 5 sekund!")
end)

-- Powtarzający się timer (co 60 sekund)
local timerId = plugin:setInterval(60000, function()
    plugin:log("info", "Tick!")
end)

-- Anulowanie timera
plugin:clearTimer(timerId)

]]


-- ============================================
-- PRZYKŁAD: HTTP GET
-- ============================================
--[[

plugin:httpGet("https://api.example.com/data", function(response, err)
    if err then
        plugin:log("error", "HTTP error: " .. tostring(err))
        return
    end

    -- response to string z odpowiedzią
    plugin:log("info", "Response: " .. response)

    -- Parsowanie JSON
    local data = JSON:decode(response)
    if data then
        plugin:log("info", "Parsed value: " .. tostring(data.value))
    end
end)

]]


-- ============================================
-- PRZYKŁAD: HTTP POST
-- ============================================
--[[

local payload = {
    name = "test",
    value = 123
}

plugin:httpPost("https://api.example.com/data", payload, function(response, err)
    if err then
        plugin:log("error", "HTTP POST error: " .. tostring(err))
        return
    end

    plugin:log("info", "POST response: " .. response)
end)

]]


-- ============================================
-- PRZYKŁAD: MQTT Publish
-- ============================================
--[[

-- Prosty publish
plugin:mqttPublish("home/example/status", "online")

-- Publish z JSON
plugin:mqttPublish("home/example/data", {
    temperature = 22.5,
    humidity = 65
})

-- Publish z opcjami (retain, qos)
plugin:mqttPublish("home/example/state", "ON", {
    retain = true,
    qos = 1
})

]]


-- ============================================
-- PRZYKŁAD: MQTT Subscribe
-- ============================================
--[[

-- Subskrypcja na konkretny topic
plugin:mqttSubscribe("home/example/set", function(topic, payload)
    plugin:log("info", "Received on " .. topic .. ": " .. payload)

    -- Parsuj jeśli JSON
    local data = JSON:decode(payload)
    if data then
        plugin:log("info", "Command: " .. tostring(data.command))
    end
end)

-- Subskrypcja z wildcard
plugin:mqttSubscribe("home/+/temperature", function(topic, payload)
    -- topic = "home/salon/temperature"
    -- payload = "22.5"
    plugin:log("info", topic .. " = " .. payload)
end)

]]


-- ============================================
-- PRZYKŁAD: Registry - Tworzenie obiektów
-- ============================================
--[[

-- Utwórz obiekt w registry (automatycznie w namespace pluginu)
-- Ścieżka: plugins.vclu.example.sensor
local sensor = plugin:createObject("sensor", {
    value = 0,
    unit = "°C",
    lastUpdate = os.time()
})

-- Aktualizacja obiektu
sensor.value = 22.5
sensor.lastUpdate = os.time()

-- Obiekt jest dostępny w registry jako:
-- plugins.vclu.example.sensor

]]


-- ============================================
-- PRZYKŁAD: Registry - Odczyt obiektów
-- ============================================
--[[

-- Odczyt własnego obiektu
local mySensor = plugin:getObject("sensor")
if mySensor then
    plugin:log("info", "Sensor value: " .. tostring(mySensor.value))
end

-- Odczyt obiektu z innego miejsca w registry (pełna ścieżka)
local cluObject = plugin:getObject("CLU.onInit")
if cluObject then
    plugin:log("info", "Found CLU object")
end

]]


-- ============================================
-- PRZYKŁAD: Eventy
-- ============================================
--[[

-- Nasłuchiwanie na event
plugin:on("registry:changed", function(path, value)
    plugin:log("info", "Registry changed: " .. path)
end)

-- Emitowanie własnego eventu
plugin:emit("example:myEvent", {
    message = "Something happened",
    timestamp = os.time()
})

-- Nasłuchiwanie na własny event (z innego pluginu)
plugin:on("weather:updated", function(data)
    plugin:log("info", "Weather updated: " .. tostring(data.temp))
end)

]]


-- ============================================
-- PRZYKŁAD: Pełny plugin z HTTP polling
-- ============================================
--[[

local plugin = Plugin:new("example", {
    name = "Example Plugin",
    version = "1.0.0"
})

plugin:onInit(function(config)
    -- Utwórz obiekt w registry
    local data = plugin:createObject("data", {
        value = 0,
        status = "unknown",
        lastUpdate = 0
    })

    -- Funkcja pobierająca dane
    local function fetchData()
        plugin:httpGet(config.apiUrl, function(response, err)
            if err then
                data.status = "error"
                return
            end

            local parsed = JSON:decode(response)
            if parsed then
                data.value = parsed.value
                data.status = "ok"
                data.lastUpdate = os.time()

                -- Emituj event
                plugin:emit("example:updated", data)

                -- Publikuj na MQTT
                plugin:mqttPublish("home/example/value", tostring(data.value))
            end
        end)
    end

    -- Pierwsze pobranie
    fetchData()

    -- Cykliczne pobieranie
    plugin:setInterval(config.interval * 1000, fetchData)
end)

]]
