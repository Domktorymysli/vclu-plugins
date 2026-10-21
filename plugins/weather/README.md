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

Instancja wtyczki nie jest globalną zmienną. Pobierz ją przez `Plugin.getPlugin()`
(nie `Plugin.get()`, bo to metoda instancji zwracająca sensor):

```lua
-- Pobierz instancję pluginu
local weather = Plugin.getPlugin("@vclu/weather")

-- Teraz możesz używać metod
local temp = weather:getTemperature()
print("Temperatura: " .. temp .. "°C")
```

### Przykład funkcji w user.lua

```lua
function getWeather()
    local weather = Plugin.getPlugin("@vclu/weather")
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
    local weather = Plugin.getPlugin("@vclu/weather")
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
| `getData()`        | table       | Wszystkie dane, z `icon` (nazwa z Bootstrap Icons) |
| `getForecast()`    | table / nil | Prognoza na 5 dni, `nil` przed pierwszym pobraniem |
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
    icon = "cloud-sun",   -- ikona z Bootstrap Icons
    city = "Warsaw",      -- miasto
    updated = 1704067200  -- timestamp
}
```

## Prognoza

`getForecast()` zwraca prognozę z `/data/2.5/forecast` (5 dni co 3 godziny,
darmowy plan). Prognoza nie jest pobierana, dopóki nikt o nią nie zapyta:
pierwsze wywołanie zwraca `nil` i uruchamia pobieranie, potem wtyczka odświeża ją
co 30 minut (48 zapytań na dobę, poza bieżącą pogodą). `refresh()` jej nie
dotyczy. Po błędzie zostaje ostatnia pobrana prognoza; jej wiek widać w `updated`.

```lua
local weather = Plugin.getPlugin("@vclu/weather")
local f = weather:getForecast()
if f then
    for _, d in ipairs(f.days) do
        print(d.date, d.icon, d.min, d.max, d.rain, d.pop)
    end
end
```

```lua
{
    days = {
        -- dzień w strefie domu; pierwszy i ostatni zwykle niepełny
        { date = "2026-10-26", icon = "cloud-rain", min = 7.6, max = 11.8, rain = 1.9, pop = 0.8 },
        ...
    },
    hours = {
        -- wszystkie kroki 3 h z odpowiedzi (zwykle 40)
        { at = 1793026800, temp = 10.4, rain = 1.2, icon = "cloud-rain" },
        ...
    },
    updated = 1792800000  -- kiedy pobrano (unix, s)
}
```

| Pole | Opis |
|---|---|
| `days[].date` | data `YYYY-MM-DD` w strefie domu |
| `days[].min`, `max` | najniższa i najwyższa temperatura z kroków dnia (°C, °F dla `imperial`) |
| `days[].rain` | suma opadów z dnia w mm: deszcz i śnieg razem, mimo nazwy pola |
| `days[].pop` | największe prawdopodobieństwo opadu z dnia, 0-1 |
| `days[].icon` | ikona dnia: krok w dzień (6-20) ze znaczącymi opadami (prawdopodobieństwo ≥ 0,4 i ≥ 0,3 mm; burza zawsze), najgorszy z nich; bez takich kroków krok najbliższy południa |
| `hours[].at` | początek kroku, unix (s) |
| `hours[].temp`, `rain`, `icon` | temperatura, opady (deszcz i śnieg) w mm za 3 h, ikona (nocą `moon`, `cloud-moon`) |

Ikony to nazwy z [Bootstrap Icons](https://icons.getbootstrap.com/): `sun`, `moon`,
`cloud-sun`, `cloud-moon`, `cloud`, `clouds`, `cloud-drizzle`, `cloud-rain`,
`cloud-rain-heavy`, `cloud-lightning`, `cloud-lightning-rain`, `cloud-snow`,
`cloud-sleet`, `cloud-fog2`, `cloud-haze2`, `wind`, `tornado`.

Dni liczone są w strefie z `datetime.setTimezone`, jeśli środowisko wtyczek daje
dostęp do `datetime`. W przeciwnym razie wtyczka bierze przesunięcie miasta z
odpowiedzi OWM (`city.timezone`). To przesunięcie jest stałe, więc po zmianie
czasu w ciągu tych 5 dni przesuwa się o godzinę. W Polsce (+1 i +2) daty dni się przez to nie
zmieniają (kroki OWM wypadają o pełnych godzinach UTC podzielnych przez 3), ale
ikona dnia może pochodzić z sąsiedniego kroku.

## Uzyskanie API Key

1. Zarejestruj się na [openweathermap.org](https://openweathermap.org/)
2. Przejdź do [API keys](https://home.openweathermap.org/api_keys)
3. Skopiuj klucz (darmowy plan = 1000 zapytań/dzień)
