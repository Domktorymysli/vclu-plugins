# Salda Recuperator Plugin

Integracja z rekuperatorem Salda - odczyt danych i sterowanie z pełnym wsparciem expose API.

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

## Expose do Home Assistant / HomeKit

Plugin udostępnia sensory i kontrolki przez `plugin:get()`:

| ID           | Typ      | Zakres  | Expose type   | Opis                     |
|--------------|----------|---------|---------------|--------------------------|
| `fanSpeed`   | control  | 0-4     | `fan`         | Prędkość wentylatora     |
| `temperature`| control  | 15-30   | `number`      | Temperatura zadana °C    |
| `supplyAir`  | sensor   | °C      | `temperature` | Temperatura nawiewu      |
| `exhaustAir` | sensor   | °C      | `temperature` | Temperatura wywiewu      |
| `extractAir` | sensor   | °C      | `temperature` | Temperatura wyciągu      |
| `outsideAir` | sensor   | °C      | `temperature` | Temperatura zewnętrzna   |
| `humidity`   | sensor   | 0-100%  | `humidity`    | Wilgotność powietrza     |

### Przykład - pełne expose

```lua
local salda = Plugin.get("@vclu/salda-recuperator")

-- Wentylator jako fan (typ fan w HA)
expose(salda:get("fanSpeed"), "fan", {
    name = "Rekuperator",
    area = "Techniczny",
    min = 0,
    max = 4,
    step = 1
})

-- Temperatura zadana
expose(salda:get("temperature"), "number", {
    name = "Temp Zadana Rekuperator",
    area = "Techniczny",
    min = 15,
    max = 30,
    step = 1,
    unit = "°C"
})

-- Sensory temperatur
expose(salda:get("supplyAir"), "temperature", { name = "Nawiew", area = "Techniczny" })
expose(salda:get("exhaustAir"), "temperature", { name = "Wywiew", area = "Techniczny" })
expose(salda:get("outsideAir"), "temperature", { name = "Zewnętrzna", area = "Techniczny" })

-- Wilgotność
expose(salda:get("humidity"), "humidity", { name = "Wilgotność", area = "Techniczny" })
```

### Expose - tylko najważniejsze

```lua
local salda = Plugin.get("@vclu/salda-recuperator")

-- Tylko wentylator i temperatura zewnętrzna
expose(salda:get("fanSpeed"), "fan", {
    name = "Rekuperator",
    area = "Techniczny",
    min = 0, max = 4, step = 1
})
expose(salda:get("outsideAir"), "temperature", {
    name = "Temp Zewnętrzna",
    area = "Techniczny"
})

-- Reszta dostępna tylko w Lua przez API
```

### Rezultat w Home Assistant

Po expose w HA pojawią się:
- **fan.rekuperator** - wentylator z 4 biegami (OFF, 1, 2, 3, 4)
- **sensor.nawiew** - temperatura nawiewu
- **sensor.zewnetrzna** - temperatura zewnętrzna
- **sensor.wilgotnosc** - wilgotność %
- **number.temp_zadana_rekuperator** - slider 15-30°C

Wszystkie encje automatycznie w pokoju "Techniczny" (dzięki `area`).

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

| Poziom   | Wartość raw   | Opis       | W HA         |
|----------|---------------|------------|--------------|
| 0        | 0             | Wyłączony  | OFF          |
| 1        | 30            | Niski      | 25%          |
| 2        | 60            | Średni     | 50%          |
| 3        | 80            | Wysoki     | 75%          |
| 4        | 100           | Maksymalny | 100%         |

W Home Assistant typ `fan` wyświetla się jako procentowy slider. Wartości 0-4 są mapowane na 0-100%:
- Poziom 1 (30 raw) → 25% w HA
- Poziom 2 (60 raw) → 50% w HA
- Poziom 3 (80 raw) → 75% w HA
- Poziom 4 (100 raw) → 100% w HA

Dzięki `step = 1` i `max = 4` HA wie że to 4 dyskretne poziomy, nie ciągły zakres.
