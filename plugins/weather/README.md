# Weather Plugin

Pobiera dane pogodowe z OpenWeatherMap i udostępnia w Lua.

## Instalacja

```bash
# Skopiuj do katalogu pluginów vCLU
cp -r weather ~/.vclu/plugins/
```

## Konfiguracja

Ustaw zmienną środowiskową:

```bash
export OPENWEATHERMAP_API_KEY="twój_klucz_api"
```

Lub w pliku konfiguracyjnym vCLU:

```yaml
plugins:
  weather:
    apiKey: "twój_klucz_api"
    city: "Warsaw"
    interval: 3600
    units: "metric"
```

## Użycie w Lua

```lua
-- Pobierz temperaturę
local temp = weather:getTemperature()
print("Temperatura: " .. temp .. "°C")

-- Sprawdź warunki
local condition = weather:getCondition()
if condition == "Rain" then
    -- zamknij okna
    _:byTag("windows"):close()
end

-- Wszystkie dane
local data = weather:getData()
print("Miasto: " .. data.city)
print("Wilgotność: " .. data.humidity .. "%")
print("Wiatr: " .. data.wind.speed .. " m/s")
```

## Eventy

```lua
-- Gdy zmieni się pogoda
events:on("weather.OnWeatherChange", function(data)
    print("Nowa temperatura: " .. data.temp)
end)

-- Gdy zacznie padać
events:on("weather.OnRainAlert", function(data)
    notify:push("Pogoda", "Pada deszcz!")
    _:byTag("markizy"):close()
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

## Uzyskanie API Key

1. Zarejestruj się na [openweathermap.org](https://openweathermap.org/)
2. Przejdź do [API keys](https://home.openweathermap.org/api_keys)
3. Skopiuj klucz (darmowy plan = 1000 zapytań/dzień)
