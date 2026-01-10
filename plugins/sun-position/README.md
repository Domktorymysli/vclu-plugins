# Sun Position & Astronomy Plugin

Pozycja słońca, wschody/zachody słońca, fazy księżyca - idealne do automatyzacji rolet i oświetlenia.

## Konfiguracja

| Parametr         | Typ    | Wymagane | Domyślnie | Opis                                    |
|------------------|--------|----------|-----------|---------------------------------------- |
| `latitude`       | number | Tak      | -         | Szerokość geograficzna                  |
| `longitude`      | number | Tak      | -         | Długość geograficzna                    |
| `timezoneOffset` | number | Nie      | `1`       | Offset strefy czasowej (UTC+X)          |
| `sunriseOffset`  | number | Nie      | `0`       | Offset eventu wschodu (minuty)          |
| `sunsetOffset`   | number | Nie      | `0`       | Offset eventu zachodu (minuty)          |

### Przykładowe lokalizacje

| Miasto    | Latitude | Longitude |
|-----------|----------|-----------|
| Warszawa  | 52.2297  | 21.0122   |
| Kraków    | 50.0647  | 19.9450   |
| Gdańsk    | 54.3520  | 18.6466   |
| Wrocław   | 51.1079  | 17.0385   |
| Poznań    | 52.4064  | 16.9252   |

## Eventy

```lua
-- Wschód słońca
plugin:on("sun:rise", function(data)
    print("Wschód słońca: " .. data.time)
    -- Otwórz rolety
    Rolety:execute("open")
end)

-- Zachód słońca
plugin:on("sun:set", function(data)
    print("Zachód słońca: " .. data.time)
    -- Zamknij rolety, włącz światła
    Rolety:execute("close")
    Swiatla:execute("turnOn")
end)

-- Południe słoneczne
plugin:on("sun:noon", function(data)
    print("Południe: " .. data.time .. ", elevation: " .. data.elevation .. "°")
end)

-- Zmiana pozycji słońca (co 10 min)
plugin:on("sun:position", function(data)
    print("Azymut: " .. data.azimuth .. "°, Elevacja: " .. data.elevation .. "°")
end)
```

### Offset eventów

Możesz ustawić offset dla eventów wschodu/zachodu:
- `sunriseOffset: -30` - event 30 minut PRZED wschodem
- `sunsetOffset: 15` - event 15 minut PO zachodzie

## API

```lua
local sun = Plugin.get("@vclu/sun-position")

-- Czasy słońca (format HH:MM)
sun:getSunrise()         -- "06:45"
sun:getSunset()          -- "20:15"
sun:getSolarNoon()       -- "13:30"
sun:getDayLength()       -- 810 (minuty)
sun:getDayLengthFormatted() -- "13:30"

-- Pozycja słońca
sun:getAzimuth()         -- 180.5 (stopnie od N, 0-360)
sun:getElevation()       -- 45.2 (stopnie nad horyzontem)
sun:getPosition()        -- {azimuth=180.5, elevation=45.2, zenith=44.8}

-- Status dnia/nocy
sun:isDaytime()          -- true/false
sun:isNighttime()        -- true/false
sun:isTwilight()         -- true (słońce między -6° a 0°)

-- Czas do wschodu/zachodu
sun:getMinutesToSunrise() -- -120 (minęło 2h temu)
sun:getMinutesToSunset()  -- 180 (za 3h)

-- Sprawdzanie azymutu (dla rolet fasadowych)
sun:isAzimuthBetween(90, 180)   -- Słońce od E do S
sun:isElevationAbove(15)        -- Słońce > 15° nad horyzontem

-- Księżyc
sun:getMoonPhase()        -- 0.5 (0=nów, 0.5=pełnia)
sun:getMoonPhaseName()    -- "Full Moon"
sun:getMoonIllumination() -- 100 (%)
sun:getMoonAge()          -- 14.7 (dni od nowiu)
sun:getMoon()             -- {phase, phaseName, illumination, age}

-- Wszystkie dane
sun:getData()
sun:refresh()             -- Wymuś przeliczenie
```

## Registry

Plugin tworzy obiekty:

**plugins.vclu.sun-position.sun:**
```lua
{
    sunrise = "06:45",
    sunset = "20:15",
    solarNoon = "13:30",
    dayLength = 810,
    azimuth = 180.5,
    elevation = 45.2,
    isDaytime = true
}
```

**plugins.vclu.sun-position.moon:**
```lua
{
    phase = 0.5,
    phaseName = "Full Moon",
    illumination = 100,
    age = 14.7
}
```

## Przykłady użycia

### Automatyzacja rolet na podstawie azymutu

```lua
-- Każda fasada reaguje tylko gdy słońce na nią świeci
plugin:on("sun:position", function(data)
    local sun = Plugin.get("@vclu/sun-position")

    -- Fasada wschodnia (45° - 135°)
    if sun:isAzimuthBetween(45, 135) and sun:isElevationAbove(10) then
        RoletyWschod:execute("setPosition", 50)  -- Półprzymknięte
    end

    -- Fasada południowa (135° - 225°)
    if sun:isAzimuthBetween(135, 225) and sun:isElevationAbove(15) then
        RoletyPoludnie:execute("setPosition", 30)
    end

    -- Fasada zachodnia (225° - 315°)
    if sun:isAzimuthBetween(225, 315) and sun:isElevationAbove(10) then
        RoletyZachod:execute("setPosition", 50)
    end
end)
```

### Oświetlenie na podstawie zmierzchu

```lua
plugin:on("sun:position", function(data)
    local sun = Plugin.get("@vclu/sun-position")

    if sun:isTwilight() then
        -- Zmierzch - włącz oświetlenie zewnętrzne
        OswietlenieZewn:execute("turnOn")
    end

    if sun:isNighttime() and data.elevation < -12 then
        -- Noc astronomiczna - pełne oświetlenie
        OswietlenieOgrod:execute("setValue", 100)
    end
end)
```

### Budzenie przed wschodem słońca

```lua
-- W konfiguracji: sunriseOffset: -30 (30 min przed wschodem)
plugin:on("sun:rise", function(data)
    -- Stopniowo otwieraj rolety
    Rolety:execute("setPosition", 20)

    Plugin.get("@vclu/sun-position"):setTimeout(10 * 60 * 1000, function()
        Rolety:execute("setPosition", 50)
    end)

    Plugin.get("@vclu/sun-position"):setTimeout(20 * 60 * 1000, function()
        Rolety:execute("open")
    end)
end)
```

### Wyświetlanie na panelu

```lua
local sun = Plugin.get("@vclu/sun-position")

Panel.sunrise:setValue(sun:getSunrise())
Panel.sunset:setValue(sun:getSunset())
Panel.dayLength:setValue(sun:getDayLengthFormatted())
Panel.moonPhase:setValue(sun:getMoonPhaseName())
```

## Expose do Home Assistant / HomeKit

Plugin udostępnia tylko gettery, więc trzeba je opakować w obiekt exposable i podłączyć eventy:

```lua
local sun = Plugin.get("@vclu/sun-position")

-- Helper do opakowania gettera z eventami
-- epsilon: opcjonalna tolerancja dla floatów (debounce)
local function wrapGetter(getter, id, epsilon)
    local obj = {
        _id = id,
        _callbacks = {},
        _last = nil,
        _epsilon = epsilon,
        get = function(self, f) return getter() end,
        onChange = function(self, callback)
            table.insert(self._callbacks, callback)
            return function()
                for i, cb in ipairs(self._callbacks) do
                    if cb == callback then table.remove(self._callbacks, i); break end
                end
            end
        end,
        _notify = function(self)
            local value = getter()
            local changed = (self._last == nil)
                or (self._epsilon and type(value) == "number" and math.abs(value - self._last) >= self._epsilon)
                or (not self._epsilon and value ~= self._last)
            if changed then
                self._last = value
                for _, cb in ipairs(self._callbacks) do cb(value) end
            end
        end
    }
    return obj
end

-- Tworzenie obiektów (z epsilon dla debounce)
local azimuth = wrapGetter(function() return sun:getAzimuth() end, "sun:azimuth", 1.0)      -- notify gdy zmiana >= 1°
local elevation = wrapGetter(function() return sun:getElevation() end, "sun:elevation", 0.5) -- notify gdy zmiana >= 0.5°
local moonPhase = wrapGetter(function() return sun:getMoonIllumination() end, "sun:moon", 1) -- notify gdy zmiana >= 1%
local daytime = wrapGetter(function() return sun:isDaytime() and 1 or 0 end, "sun:daytime")  -- binary, bez epsilon

-- Expose
expose(azimuth, "number", { name = "Słońce Azymut", min = 0, max = 360, unit = "°" })
expose(elevation, "number", { name = "Słońce Wysokość", min = -90, max = 90, unit = "°" })
expose(moonPhase, "number", { name = "Faza Księżyca", min = 0, max = 100, unit = "%" })
expose(daytime, "sensor", { name = "Dzień" })

-- Podłączenie eventów pluginu - TO JEST KLUCZOWE!
-- Plugin emituje "sun:position" co 10 minut
sun:on("sun:position", function(data)
    azimuth:_notify()
    elevation:_notify()
    daytime:_notify()
end)

-- Księżyc zmienia się raz dziennie, można odświeżać o północy
-- lub przy każdym sun:position (wartość i tak się nie zmieni często)
```

### Krótsza wersja (jeden obiekt, wiele wartości)

```lua
local sun = Plugin.get("@vclu/sun-position")

-- Osobne obiekty dla każdej wartości
local sensors = {
    azimuth = { get = function() return sun:getAzimuth() end },
    elevation = { get = function() return sun:getElevation() end },
}

-- Expose z id w options
expose(sensors.azimuth, "number", { id = "sun_azimuth", name = "Azymut", min = 0, max = 360 })
expose(sensors.elevation, "number", { id = "sun_elevation", name = "Wysokość", min = -90, max = 90 })

-- Odświeżanie przez StateBus (gdy znasz path)
sun:on("sun:position", function()
    StateBus:getShared():emit("state_changed", { path = "sun_azimuth", value = sun:getAzimuth(), type = "number" })
    StateBus:getShared():emit("state_changed", { path = "sun_elevation", value = sun:getElevation(), type = "number" })
end)
```

### Dostępne wartości do expose

| Getter                    | Typ          | Zakres      | Jednostka |
|---------------------------|--------------|-------------|-----------|
| `sun:getAzimuth()`        | number       | 0-360       | °         |
| `sun:getElevation()`      | number       | -90 - 90    | °         |
| `sun:getMoonIllumination()`| number      | 0-100       | %         |
| `sun:getMoonPhase()`      | number       | 0-1         | -         |
| `sun:getMoonAge()`        | number       | 0-29.5      | dni       |
| `sun:getDayLength()`      | number       | 0-1440      | min       |
| `sun:isDaytime()`         | sensor       | true/false  | -         |
| `sun:isTwilight()`        | sensor       | true/false  | -         |

## Fazy księżyca

| Faza             | Phase  | Iluminacja |
|------------------|--------|------------|
| New Moon         | 0.00   | 0%         |
| Waxing Crescent  | 0.125  | 25%        |
| First Quarter    | 0.25   | 50%        |
| Waxing Gibbous   | 0.375  | 75%        |
| Full Moon        | 0.50   | 100%       |
| Waning Gibbous   | 0.625  | 75%        |
| Last Quarter     | 0.75   | 50%        |
| Waning Crescent  | 0.875  | 25%        |

## Uwagi

- Obliczenia bazują na algorytmach NOAA Solar Calculator
- Pozycja słońca aktualizowana co 10 minut
- Wschód/zachód obliczany dla oficjalnego zenitu (90.833°) uwzględniającego refrakcję atmosferyczną
- Strefa czasowa musi być ustawiona ręcznie (nie wykrywa DST automatycznie)
