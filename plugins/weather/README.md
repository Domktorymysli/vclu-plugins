# Weather Plugin

Pobiera dane pogodowe z OpenWeatherMap i udostępnia w Lua.

## Instalacja

1. Otwórz panel vCLU: `http://<adres-vclu>:8080/plugins`
2. W sekcji "Available Plugins" znajdź "Weather Plugin"
3. Kliknij "Install"
4. Kliknij "Configure" i ustaw:
   - `apiKey` - klucz API z OpenWeatherMap (wymagany)
   - `city` - miasto (domyślnie: Warsaw)
   - `interval` - interwał odświeżania w sekundach (domyślnie: 3600)
   - `units` - jednostki: metric/imperial (domyślnie: metric)
5. Kliknij "Enable"

## Użycie w Lua

### Dostęp do pluginu

Plugin NIE jest dostępny jako globalna zmienna. Użyj `Plugin.get()`:

```lua
-- Pobierz instancję pluginu
local weather = Plugin.get("@vclu/weather")

-- Teraz możesz używać metod
local temp = weather:getTemperature()
print("Temperatura: " .. temp .. "°C")
```

### Przykład funkcji w user.lua

```lua
function getWeather()
    local weather = Plugin.get("@vclu/weather")
    if not weather then
        return "Plugin weather nie jest załadowany"
    end

    local temp = weather:getTemperature()
    local condition = weather:getCondition()
    local humidity = weather:getHumidity()

    return string.format("%.1f°C, %s, wilgotność %d%%",
        temp or 0, condition or "?", humidity or 0)
end
```

### Alternatywnie: przez Registry

Plugin zapisuje dane do registry pod ścieżką `plugins.vclu.weather.current`:

```lua
function getWeatherFromRegistry()
    local current = _:get("plugins.vclu.weather.current")
    if not current then
        return "Brak danych pogodowych"
    end

    return string.format("%.1f°C, %s", current.temp, current.condition)
end
```

### Automatyzacja - sprawdzanie deszczu

```lua
function checkRain()
    local weather = Plugin.get("@vclu/weather")
    if not weather then return end

    local condition = weather:getCondition()
    if condition == "Rain" then
        -- zamknij okna/markizy
        _:byTag("windows"):execute("close()")
    end
end
```

## Eventy

Plugin emituje eventy które można nasłuchiwać:

```lua
-- W onInit lub innym pluginie:

-- Gdy zmieni się pogoda
EventBus:on("weather:changed", function(data)
    print("Nowa temperatura: " .. data.temp)
    print("Warunki: " .. data.condition)
end)

-- Gdy zacznie padać
EventBus:on("weather:rain", function(data)
    print("Pada! " .. data.rain .. " mm/h")
    -- automatycznie zamknij markizy
end)
```

## API

| Metoda             | Zwraca      | Opis                                |
|--------------------|-------------|-------------------------------------|
| `getTemperature()` | number      | Temperatura (°C lub °F)             |
| `getCondition()`   | string      | Warunki (Clear, Clouds, Rain, Snow) |
| `getHumidity()`    | number      | Wilgotność (0-100%)                 |
| `getWind()`        | number      | Prędkość wiatru                     |
| `getFeelsLike()`   | number      | Temperatura odczuwalna              |
| `getPressure()`    | number      | Ciśnienie (hPa)                     |
| `getClouds()`      | number      | Zachmurzenie (0-100%)               |
| `getRain()`        | number      | Opady (mm/h)                        |
| `getData()`        | table       | Wszystkie dane                      |
| `refresh()`        | void        | Wymuś odświeżenie                   |

## Struktura danych w Registry

`plugins.vclu.weather.current`:

```lua
{
    temp = 22.5,          -- temperatura
    humidity = 65,        -- wilgotność %
    condition = "Clouds", -- warunki
    pressure = 1013,      -- ciśnienie hPa
    wind = 5.2,           -- wiatr m/s
    rain = 0,             -- opady mm/h
    clouds = 40,          -- zachmurzenie %
    city = "Warsaw",      -- miasto
    updated = 1704067200  -- timestamp
}
```

## Uzyskanie API Key

1. Zarejestruj się na [openweathermap.org](https://openweathermap.org/)
2. Przejdź do [API keys](https://home.openweathermap.org/api_keys)
3. Skopiuj klucz (darmowy plan = 1000 zapytań/dzień)
