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

## Stan

`getState()` zwraca stan z ostatniego odczytu (`getStatus` i `netusb/getPlayInfo`):

| Pole | Typ | Opis |
|---|---|---|
| `id`, `name`, `ip`, `zone` | string | z `create` |
| `power` | boolean | strefa włączona |
| `volume` | number | 0-100, procent zakresu urządzenia |
| `mute` | boolean | wyciszenie |
| `input` | string | wejście strefy |
| `playback` | string | `play`, `pause`, `stop`, ... |
| `track` | table | utwór, to samo co `getTrack()`; `nil` przed pierwszym odczytem |
| `online` | boolean | urządzenie odpowiada |
| `lastError` | string | ostatni błąd albo `nil` |

`track`:

| Pole | Typ | Opis |
|---|---|---|
| `artist`, `title`, `album` | string | pusty napis, gdy usługa ich nie podaje |
| `input` | string | źródło odtwarzania (`net_radio`, `spotify`, `server`, ...) |
| `artwork` | string | adres okładki albo `nil`, gdy jej nie ma |

Amplituner podaje okładkę jako ścieżkę na sobie, zwykle tę samą dla każdego
utworu. Wtyczka składa z niej pełny adres `http://<ip><ścieżka>?t=<skrót>`, gdzie
skrót zależy od wykonawcy, tytułu i albumu: przeglądarka pobiera okładkę na nowo
po zmianie utworu, a nie przy każdym odczycie. Jeśli ścieżka ma już zapytanie,
skrót dochodzi na końcu jako `&t=<skrót>`. Spacje i znaki spoza ASCII w ścieżce są
kodowane (`%20`, `%C5%82`), istniejące `%XX` zostają, a `#fragment` jest pomijany.
Pełny adres (`http://`, `https://`) od usługi zostaje bez zmian.
