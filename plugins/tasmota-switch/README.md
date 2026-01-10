# Tasmota Switch Plugin

Fabryka obiektów do sterowania urządzeniami Tasmota (Sonoff, Shelly, etc.) przez HTTP.

## Użycie

```lua
local tasmota = Plugin.get("@vclu/tasmota-switch")

-- Tworzenie urządzeń
local lamp1 = tasmota:create({ ip = "192.168.1.100", name = "Lampka Biurko" })
local lamp2 = tasmota:create({ ip = "192.168.1.101", name = "Lampka Salon" })

-- Lub prościej (tylko IP)
local lamp3 = tasmota:create("192.168.1.102")

-- Sterowanie
lamp1:on()
lamp1:off()
lamp1:toggle()
lamp1:refresh()  -- wymuś odczyt stanu

-- Stan
if lamp1:isOn() then print("włączona") end
if lamp1:isOnline() then print("dostępna") end

-- Eventy
lamp1:onChange(function(newVal, oldVal)
    print("Zmiana: " .. oldVal .. " -> " .. newVal)
end)
```

## Expose do Home Assistant / HomeKit

```lua
local tasmota = Plugin.get("@vclu/tasmota-switch")

local lamp = tasmota:create({ ip = "192.168.1.100", name = "Lampka Biurko" })

-- Eksponuj do HA/HomeKit
expose(lamp, "switch", { name = "Lampka Biurko" })
```

## Konfiguracja urządzenia

```lua
local lamp = tasmota:create({
    id = "lampka_biurko",    -- stały identyfikator (dla expose)
    ip = "192.168.1.100",
    name = "Lampka Biurko",
    password = "admin",      -- opcjonalne, jeśli Tasmota ma hasło
    polling = true,          -- automatyczne odpytywanie stanu (default: true)
    pollInterval = 30        -- interwał w sekundach (default: 30)
})

-- Lub fluent API
local lamp = tasmota:create("192.168.1.100")
    :setId("lampka_biurko")
    :setName("Lampka Biurko")
    :setPassword("admin")
    :setPolling(true, 60)
```

> **Uwaga:** `id` definiuje tożsamość w HA/HomeKit (`unique_id`). Po pierwszym `expose()` jest zablokowane. Użyj `rename()` do zmiany nazwy wyświetlanej.

## API

### Sterowanie
- `lamp:on()` - włącz
- `lamp:off()` - wyłącz
- `lamp:toggle()` - przełącz
- `lamp:refresh()` - odśwież stan

### Stan
- `lamp:getId()` - identyfikator
- `lamp:isOn()` - czy włączona (true/false)
- `lamp:isOnline()` - czy dostępna
- `lamp:getValue()` - wartość (0 lub 1)
- `lamp:getState()` - pełny stan { id, name, ip, value, online, lastUpdate, lastError }

### Konfiguracja (fluent)
- `lamp:setId(id)` - ustaw identyfikator (przed pierwszym expose!)
- `lamp:setIp(ip)` - zmień IP
- `lamp:setName(name)` - zmień nazwę
- `lamp:setPassword(pass)` - ustaw hasło
- `lamp:setPolling(enabled, interval)` - włącz/wyłącz polling

### Eventy
- `lamp:onChange(callback)` - callback przy zmianie stanu

## Tasmota HTTP API

Plugin używa standardowego HTTP API:
- `GET /cm?cmnd=Power` - odczyt
- `GET /cm?cmnd=Power%20ON` - włącz
- `GET /cm?cmnd=Power%20OFF` - wyłącz
- `GET /cm?cmnd=Power%20TOGGLE` - przełącz

Z hasłem: `&user=admin&password=xxx`
