# Frigate NVR Plugin

Integracja z [Frigate NVR](https://frigate.video/) - monitorowanie kamer, detekcja obiektow i eventy.

## Funkcje

- Odpytywanie statusu kamer (FPS, detekcja, audio)
- Polling eventow detekcji (person, car, dog, cat, ...)
- Globalne wlaczanie/wylaczanie detekcji
- Expose API - sensory i kontrolki dla HomeKit/Home Assistant
- Linki do snapshotow, miniatur i klipow

## Konfiguracja

```json
{
  "host": "192.168.0.50",
  "port": 5000,
  "interval": 30,
  "eventInterval": 10,
  "cameras": ""
}
```

| Parametr        | Typ    | Domyslnie | Opis                                          |
|-----------------|--------|-----------|-----------------------------------------------|
| `host`          | string | -         | Adres IP Frigate (wymagany)                   |
| `port`          | number | 5000      | Port API Frigate                              |
| `interval`      | number | 30        | Interwal statusu kamer (sekundy)              |
| `eventInterval` | number | 10        | Interwal sprawdzania eventow (sekundy)        |
| `cameras`       | string | ""        | Filtr kamer (np. "camera_201,camera_202")     |

## Expose API

```lua
local frigate = Plugin.getPlugin("@vclu/frigate")

-- Detekcja wl/wyl (global)
expose(frigate:get("detection"), "boolean", {
    name = "Detekcja Frigate",
    area = "Monitoring"
})

-- Liczba aktywnych kamer
expose(frigate:get("cameraCount"), "number", {
    name = "Aktywne kamery",
    area = "Monitoring"
})

-- Licznik detekcji
expose(frigate:get("totalDetections"), "number", {
    name = "Detekcje",
    area = "Monitoring"
})
```

## Eventy

### `frigate:detection`
Emitowany przy kazdej nowej detekcji obiektu.

```lua
plugin:on("frigate:detection", function(data)
    -- data.camera    = "camera_201"
    -- data.label     = "person"
    -- data.score     = 0.87
    -- data.zones     = {"front_yard"}
    -- data.thumbnail = "http://192.168.0.50:5000/api/events/.../thumbnail.jpg"
    -- data.snapshot   = "http://192.168.0.50:5000/api/events/.../snapshot.jpg"
    -- data.clip      = "http://192.168.0.50:5000/api/events/.../clip.mp4"
end)
```

### `frigate:updated`
Emitowany po odswiezeniu statusu kamer.

### `frigate:error`
Emitowany przy bledzie komunikacji.

## Public API

```lua
local frigate = Plugin.getPlugin("@vclu/frigate")

frigate:isReady()              -- bool
frigate:getVersion()           -- "0.14.1"
frigate:getCameraCount()       -- 7
frigate:getTotalDetections()   -- 42
frigate:getCameras()           -- { camera_201 = {...}, ... }
frigate:getCamera("camera_201") -- { name, fps, detectionFps, detectionEnabled, ... }
frigate:getData()              -- pelne dane

-- Sterowanie
frigate:setCameraDetection("camera_201", false)  -- wylacz detekcje na kamerze
frigate:setDetection(false)                      -- wylacz detekcje globalnie

-- Snapshoty
frigate:getSnapshotUrl("camera_201")  -- URL do najnowszego zdjecia
frigate:getThumbnailUrl(eventId)      -- URL do miniatury eventu

frigate:refresh()   -- wymus odswiezenie
frigate:getStats()  -- statystyki pollerow
```

## Przyklad: powiadomienie Telegram przy detekcji osoby

```lua
local frigate = Plugin.getPlugin("@vclu/frigate")
local telegram = Plugin.getPlugin("@vclu/telegram")

frigate:on("frigate:detection", function(data)
    if data.label == "person" and data.score > 0.7 then
        telegram:sendMessage(
            "Wykryto osobe na " .. data.camera ..
            " (pewnosc: " .. math.floor(data.score * 100) .. "%)"
        )
    end
end)
```
