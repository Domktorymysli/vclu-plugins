# Yamaha MusicCast Plugin

Fabryka obiektów dla amplitunerów i głośników Yamaha MusicCast. Działa lokalnie przez
Yamaha Extended Control (HTTP), bez chmury i bez logowania.

Sprawdzenie, czy urządzenie odpowiada:

```
curl http://<ip>/YamahaExtendedControl/v1/system/getDeviceInfo
```

## Użycie

```lua
local musiccast = Plugin.getPlugin("@vclu/musiccast")

local salon = musiccast:create({ id = "salon", ip = "192.168.0.159", name = "Amplituner" })
local taras = musiccast:create({ id = "taras", ip = "192.168.0.159", zone = "zone2" })

salon:on()
salon:setInput("net_radio")   -- spotify, airplay, bluetooth, tv, hdmi1, ...
salon:recallPreset(1)          -- ulubione z aplikacji MusicCast
salon:setVolume(35)            -- procent zakresu urządzenia
salon:setMute(true)
salon:play() ; salon:pause() ; salon:next()
salon:off()                    -- standby

print(salon:getTrack().artist, salon:getVolume())   -- stan z ostatniego odczytu
```

Wtyczka nie wystawia urządzenia przez `expose`: Home Assistant ma własną
integrację MusicCast z pełnym odtwarzaczem. Jej miejsce to automatyka w Lua,
np. przycisk Grentona włącza radio w salonie.

Głośność w API wtyczki to zawsze procent; wtyczka przelicza go na skalę urządzenia
(`max_volume` z `getStatus`, np. 161 w RX-A2A).

## API

| Metoda | Opis |
|---|---|
| `on()`, `off()`, `toggle()` | zasilanie strefy |
| `setVolume(0-100)`, `volumeUp()`, `volumeDown()`, `setMute(bool)` | głośność |
| `setInput(name)` | wejście |
| `play()`, `pause()`, `stop()`, `next()`, `previous()`, `recallPreset(n)` | odtwarzanie sieciowe |
| `refresh()`, `isOn()`, `getVolume()`, `isMuted()`, `getInput()`, `getTrack()`, `getState()` | stan |

Opcje `create`: `id` (domyślnie ip), `ip`, `name`, `zone` (`main`, `zone2`, ...),
`polling` (domyślnie `true`), `pollInterval` (s, domyślnie 10).
