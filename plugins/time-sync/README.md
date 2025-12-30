# Time Sync Plugin

Synchronizacja czasu z internetowych serwerów czasu (WorldTimeAPI).

## Konfiguracja

| Parametr     | Typ         | Domyślnie       | Opis                              |
|--------------|-------------|-----------------|-----------------------------------|
| `timezone`   | string      | `Europe/Warsaw` | Strefa czasowa IANA               |
| `interval`   | number      | `3600`          | Interwał synchronizacji (sekundy) |
| `autoSync`   | boolean     | `true`          | Auto-sync przy starcie            |

### Przykładowe strefy czasowe

- `Europe/Warsaw` - Polska
- `Europe/London` - Wielka Brytania
- `Europe/Berlin` - Niemcy
- `America/New_York` - USA (wschód)
- `America/Los_Angeles` - USA (zachód)
- `Asia/Tokyo` - Japonia
- `UTC` - czas uniwersalny

Pełna lista: [IANA Time Zones](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones)

## API

```lua
local time = Plugin.get("@vclu/time-sync")

-- Aktualny czas (tyka jak zegar)
time:getTimestamp()      -- Unix timestamp
time:getHour()           -- 0-23
time:getMinute()         -- 0-59
time:getSecond()         -- 0-59
time:getFormatted()      -- "15:30:45"
time:getFormattedDate()  -- "2025-12-30"

-- Informacje o strefie
time:getTimezone()       -- "Europe/Warsaw"
time:getUtcOffset()      -- "+01:00"
time:isDst()             -- true/false (czas letni)

-- Dla automatyzacji
time:isBetween(8, 0, 22, 0)  -- czy między 8:00 a 22:00
time:isWeekday()             -- czy poniedziałek-piątek
time:isWeekend()             -- czy sobota/niedziela
time:getDayOfWeek()          -- 0=niedziela, 6=sobota

-- Kontrola
time:sync()                      -- wymuś synchronizację
time:setTimezone("Europe/London") -- zmień strefę
time:getDrift()                  -- różnica serwer vs lokalny (s)
time:getLastSync()               -- timestamp ostatniej sync
```

## Eventy

```lua
-- Czas zsynchronizowany
plugin:on("time:synced", function(data)
    print("Czas: " .. data.datetime)
    print("Drift: " .. data.drift .. "s")
end)

-- Zmiana godziny (do automatyzacji)
plugin:on("time:hourChanged", function(data)
    print("Nowa godzina: " .. data.hour)
end)

-- Błąd synchronizacji
plugin:on("time:error", function(data)
    print("Błąd: " .. data.error)
end)
```

## Registry

Plugin tworzy obiekt `plugins.vclu.time-sync.current`:

```lua
{
    timestamp = 1735570200,
    datetime = "2025-12-30T15:30:00+01:00",
    timezone = "Europe/Warsaw",
    utcOffset = "+01:00",
    dayOfWeek = 1,
    weekNumber = 1,
    dst = false,
    drift = 0,
    lastSync = 1735570200
}
```

## Przykłady użycia

### Automatyzacja oparta na czasie

```lua
plugin:on("time:hourChanged", function(data)
    local time = Plugin.get("@vclu/time-sync")

    -- Włącz światła o 18:00 w dni robocze
    if data.hour == 18 and time:isWeekday() then
        CLU.lights:execute("turnOn")
    end

    -- Wyłącz wszystko o 23:00
    if data.hour == 23 then
        CLU.lights:execute("turnOff")
    end
end)
```

### Sprawdzanie zakresu czasu

```lua
local time = Plugin.get("@vclu/time-sync")

-- Czy jest noc (22:00 - 06:00)?
if time:isBetween(22, 0, 6, 0) then
    -- Tryb nocny
end

-- Czy godziny pracy (8:00 - 17:00 w dni robocze)?
if time:isWeekday() and time:isBetween(8, 0, 17, 0) then
    -- Tryb biurowy
end
```
