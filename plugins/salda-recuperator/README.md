# Salda Recuperator Plugin

Integracja z rekuperatorem Salda - odczyt danych i sterowanie.

## Konfiguracja

| Parametr   | Typ    | Wymagane | Domyślnie | Opis                          |
|------------|--------|----------|-----------|-------------------------------|
| `ip`       | string | Tak      | -         | Adres IP rekuperatora         |
| `login`    | string | Tak      | -         | Login do rekuperatora         |
| `password` | string | Tak      | -         | Hasło do rekuperatora         |
| `interval` | number | Nie      | `60`      | Interwał odczytu danych (s)   |

## API

```lua
local salda = Plugin.get("@vclu/salda-recuperator")

-- Temperatury (°C)
salda:getSupplyAir()      -- Temperatura nawiewu
salda:getExhaustAir()     -- Temperatura wywiewu
salda:getExtractAir()     -- Temperatura wyciągu
salda:getOutsideAir()     -- Temperatura zewnętrzna

-- Wilgotność
salda:getHumidity()        -- 0.0 - 1.0
salda:getHumidityPercent() -- 0 - 100

-- Wentylator
salda:getFanSpeed()        -- Poziom 0-4 (0=off, 1=low, 2=med, 3=high, 4=max)

-- Temperatura zadana
salda:getTemperature()     -- °C

-- Wszystkie dane
salda:getData()            -- Tabela ze wszystkimi wartościami

-- Sterowanie
salda:setTemperature(22)   -- Ustaw temperaturę (15-30°C)
salda:setFanSpeed(2)       -- Ustaw prędkość wentylatora (0-4)

-- Odświeżanie
salda:refresh()            -- Wymuś odczyt danych
salda:getLastUpdate()      -- Timestamp ostatniego odczytu
salda:getError()           -- Ostatni błąd (lub nil)
```

## Eventy

```lua
-- Dane zaktualizowane
plugin:on("salda:updated", function(data)
    print("Supply: " .. data.supplyAir .. "°C")
    print("Outside: " .. data.outsideAir .. "°C")
    print("Fan: " .. data.fanSpeed)
end)

-- Błąd komunikacji
plugin:on("salda:error", function(data)
    print("Error: " .. data.error)
end)
```

## Registry

Plugin tworzy obiekt `plugins.vclu.salda-recuperator.data`:

```lua
{
    supplyAir = 22.5,      -- Temperatura nawiewu
    exhaustAir = 20.1,     -- Temperatura wywiewu
    extractAir = 20.1,     -- Temperatura wyciągu
    outsideAir = 5.2,      -- Temperatura zewnętrzna
    humidity = 0.45,       -- Wilgotność (0.0-1.0)
    fanSpeed = 2,          -- Poziom wentylatora (0-4)
    temperature = 22,      -- Temperatura zadana
    lastUpdate = 1735571234
}
```

## Przykłady użycia

### Automatyczne dostosowanie wentylatora

```lua
plugin:on("salda:updated", function(data)
    local salda = Plugin.get("@vclu/salda-recuperator")

    -- Zwiększ wentylator gdy wilgotność > 60%
    if data.humidity > 0.6 and data.fanSpeed < 3 then
        salda:setFanSpeed(3)
    end

    -- Zmniejsz gdy wilgotność < 40%
    if data.humidity < 0.4 and data.fanSpeed > 1 then
        salda:setFanSpeed(1)
    end
end)
```

### Integracja z pogodą

```lua
plugin:on("weather:changed", function(weather)
    local salda = Plugin.get("@vclu/salda-recuperator")

    -- Gdy na zewnątrz zimno, zwiększ temperaturę nawiewu
    if weather.temp < 0 then
        salda:setTemperature(24)
    elseif weather.temp > 20 then
        salda:setTemperature(20)
    else
        salda:setTemperature(22)
    end
end)
```

### Wyświetlanie na panelu

```lua
-- W skrypcie Grenton
local salda = Plugin.get("@vclu/salda-recuperator")

-- Ustaw wartości na panelu
Panel.tempNawiew:setValue(salda:getSupplyAir())
Panel.tempZewn:setValue(salda:getOutsideAir())
Panel.humidity:setValue(salda:getHumidityPercent())
Panel.fanLevel:setValue(salda:getFanSpeed())
```

## Mapowanie prędkości wentylatora

| Poziom | Wartość raw | Opis    |
|--------|-------------|---------|
| 0      | 0           | Wyłączony |
| 1      | 30          | Niski   |
| 2      | 60          | Średni  |
| 3      | 80          | Wysoki  |
| 4      | 100         | Maksymalny |
