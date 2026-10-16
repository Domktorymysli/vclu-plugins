# Supla Power Meter Plugin

Integracja z 3-fazowym licznikiem energii Supla przez Direct Links API z expose API.

## Wymagania

- Konto Supla Cloud (https://cloud.supla.org)
- Licznik energii podłączony do Supla (np. Zamel MEW-01)
- Wygenerowany Direct Link dla urządzenia

## Konfiguracja

### 1. Wygeneruj Direct Link

1. Zaloguj się do https://cloud.supla.org
2. Przejdź do **Integrations** → **Direct Links**
3. Kliknij **Add new direct link**
4. Wybierz swój licznik energii
5. Zaznacz **Read** jako dozwoloną operację
6. Skopiuj wygenerowany URL

Format URL: `https://svrXX.supla.org/direct/{id}/{token}/read`

### 2. Skonfiguruj plugin

```json
{
  "directUrl": "https://svr59.supla.org/direct/717/XXXXXXXX/read",
  "interval": 60
}
```

| Parametr    | Opis                         | Domyślnie |
|-------------|------------------------------|-----------|
| `directUrl` | Direct Link URL (wymagany)   | -         |
| `interval`  | Interwał odczytu w sekundach | 60        |

## Użycie w Lua

### Odczyt danych

```lua
local supla = Plugin.getPlugin("supla-power-meter")

-- Podstawowe odczyty
local power = supla:getTotalPower()      -- Moc całkowita [W]
local current = supla:getTotalCurrent()  -- Prąd całkowity [A]
local energy = supla:getTotalEnergy()    -- Energia pobrana [kWh]
local reverse = supla:getReverseEnergy() -- Energia oddana [kWh]

-- Dane pojedynczej fazy
local phase1 = supla:getPhase(1)
local voltage = supla:getVoltage(1)  -- Napięcie fazy 1 [V]
local current = supla:getCurrent(1)  -- Prąd fazy 1 [A]
local power = supla:getPower(1)      -- Moc fazy 1 [W]

-- Częstotliwość sieci
local freq = supla:getFrequency()  -- [Hz]

-- Wszystkie dane
local data = supla:getData()
```

### Nasłuchiwanie zdarzeń

```lua
-- Aktualizacja danych
EventBus:subscribe("supla:updated", function(data)
    print("Moc: " .. data.totalPower .. "W")
    print("Prąd: " .. data.totalCurrent .. "A")
end)

-- Błąd komunikacji
EventBus:subscribe("supla:error", function(data)
    print("Błąd Supla: " .. data.error)
end)

-- Licznik rozłączony
EventBus:subscribe("supla:disconnected", function()
    print("Licznik Supla rozłączony!")
end)
```

### Obiekt w Registry

Plugin tworzy obiekt `@supla-power-meter/power` z danymi:

```lua
local obj = _.get("@supla-power-meter/power")

-- Dostępne właściwości:
obj.connected        -- true/false
obj.totalPower       -- Moc całkowita [W]
obj.totalCurrent     -- Prąd całkowity [A]
obj.totalEnergy      -- Energia pobrana [kWh]
obj.totalReverseEnergy -- Energia oddana [kWh]
obj.totalCost        -- Koszt całkowity
obj.currency         -- Waluta (np. "PLN")
obj.pricePerUnit     -- Cena za kWh
obj.phaseCount       -- Liczba faz (1-3)
obj.phase1           -- Dane fazy 1
obj.phase2           -- Dane fazy 2
obj.phase3           -- Dane fazy 3
obj.lastUpdate       -- Timestamp ostatniej aktualizacji
```

### Dane fazy

Każda faza zawiera:

| Pole            | Opis              | Jednostka |
|-----------------|-------------------|-----------|
| `number`        | Numer fazy        | 1-3       |
| `frequency`     | Częstotliwość     | Hz        |
| `voltage`       | Napięcie          | V         |
| `current`       | Prąd              | A         |
| `powerActive`   | Moc czynna        | W         |
| `powerReactive` | Moc bierna        | var       |
| `powerApparent` | Moc pozorna       | VA        |
| `powerFactor`   | Współczynnik mocy | -         |
| `phaseAngle`    | Kąt fazowy        | °         |
| `forwardEnergy` | Energia pobrana   | kWh       |
| `reverseEnergy` | Energia oddana    | kWh       |

## Expose do Home Assistant

Plugin udostępnia sensory przez `plugin:get()`:

| ID            | Unit | Opis                     |
|---------------|------|--------------------------|
| `power`       | W    | Moc całkowita            |
| `current`     | A    | Prąd całkowity           |
| `energy`      | kWh  | Energia pobrana          |
| `reverseEnergy`| kWh | Energia oddana           |
| `frequency`   | Hz   | Częstotliwość sieci      |
| `connected`   | 0/1  | Status połączenia        |
| `voltage1/2/3`| V    | Napięcie fazy 1/2/3      |
| `power1/2/3`  | W    | Moc fazy 1/2/3           |
| `current1/2/3`| A    | Prąd fazy 1/2/3          |

Odczyty z licznika wystawiaj jako `number` z `readonly = true`. Bez `readonly` Home Assistant
dostaje encję `number` (suwak, który da się przestawić), a nie sensor. `device_class` i
`state_class` mówią HA, czym jest wartość; panel **Energia** przyjmuje tylko licznik z
`device_class = "energy"` i `state_class = "total_increasing"`.

Sensory `energy` i `reverseEnergy` oddają `nil`, dopóki licznik nie poda pierwszego odczytu,
a gdy licznik się rozłączy, trzymają ostatnią wartość. Dzięki temu HA nie dostaje zera po
restarcie i nie liczy powrotu do prawdziwej wartości jako ogromnego zużycia. Metody
`getTotalEnergy()` i `getReverseEnergy()` dalej zwracają liczbę (0 przed pierwszym odczytem).

Jeśli wystawiałeś już odczyty bez `readonly`, po jego dodaniu encja w HA zmieni się z
`number.*` na `sensor.*` (vCLU usunie starą). Popraw odwołania w automatyzacjach i kartach;
historia starej encji nie przechodzi na nową.

### Przykład - expose do HA

```lua
local supla = Plugin.getPlugin("@vclu/supla-power-meter")

local function sensor(id, name, unit, deviceClass, stateClass)
    expose(supla:get(id), "number", {
        name = name, area = "Techniczny", unit = unit, readonly = true,
        device_class = deviceClass, state_class = stateClass or "measurement",
    })
end

-- Liczniki energii do panelu Energia
sensor("energy", "Energia Pobrana", "kWh", "energy", "total_increasing")
sensor("reverseEnergy", "Energia Oddana", "kWh", "energy", "total_increasing")

-- Moc całkowita (ujemna = eksport do sieci)
sensor("power", "Moc Całkowita", "W", "power")

-- Per-faza
for n = 1, 3 do
    sensor("voltage" .. n, "Napięcie L" .. n, "V", "voltage")
    sensor("power" .. n, "Moc L" .. n, "W", "power")
    sensor("current" .. n, "Prąd L" .. n, "A", "current")
end

sensor("frequency", "Częstotliwość", "Hz", "frequency")
```

### Expose - tylko podstawowe

```lua
local supla = Plugin.getPlugin("@vclu/supla-power-meter")

expose(supla:get("power"), "number", {
    name = "Moc", area = "Techniczny", unit = "W", readonly = true,
    device_class = "power", state_class = "measurement",
})
expose(supla:get("energy"), "number", {
    name = "Energia", area = "Techniczny", unit = "kWh", readonly = true,
    device_class = "energy", state_class = "total_increasing",
})
```

### Rezultat w Home Assistant

Po expose w HA pojawią się sensory:
- **sensor.energia_pobrana**, **sensor.energia_oddana** - liczniki energii [kWh]; wybierz je w
  *Ustawienia → Panele → Energia* jako pobór z sieci i oddawanie do sieci
- **sensor.moc_calkowita** - aktualna moc [W]
- **sensor.napiecie_l1/l2/l3**, **sensor.moc_l1/l2/l3**, **sensor.prad_l1/l2/l3** - pomiary faz

Statystyki do panelu Energia HA zaczyna liczyć od chwili pojawienia się sensora; pierwsze
słupki zobaczysz po około godzinie.

## Przykłady automatyzacji

### Monitoring zużycia

```lua
-- events.lua
EventBus:subscribe("supla:updated", function(data)
    -- Alarm przy wysokim zużyciu
    if data.totalPower > 10000 then
        -- Wyślij powiadomienie
        local telegram = Plugin.getPlugin("telegram")
        if telegram then
            telegram:send("Wysokie zużycie energii: " .. data.totalPower .. "W")
        end
    end
end)
```

### Eksport do fotowoltaiki

```lua
-- Sprawdź czy oddajemy energię do sieci
local supla = Plugin.getPlugin("supla-power-meter")
local power = supla:getTotalPower()

if power < 0 then
    print("Eksport do sieci: " .. math.abs(power) .. "W")
else
    print("Pobór z sieci: " .. power .. "W")
end
```

### Bilans energii

```lua
local supla = Plugin.getPlugin("supla-power-meter")
local consumed = supla:getTotalEnergy()
local exported = supla:getReverseEnergy()
local balance = consumed - exported

print(string.format(
    "Pobrano: %.2f kWh, Oddano: %.2f kWh, Bilans: %.2f kWh",
    consumed, exported, balance
))
```

## API Reference

### Metody

| Metoda               | Opis                   | Zwraca       |
|----------------------|------------------------|--------------|
| `isConnected()`      | Czy licznik połączony  | boolean      |
| `getTotalPower()`    | Moc całkowita          | number (W)   |
| `getTotalCurrent()`  | Prąd całkowity         | number (A)   |
| `getTotalEnergy()`   | Energia pobrana        | number (kWh) |
| `getReverseEnergy()` | Energia oddana         | number (kWh) |
| `getTotalCost()`     | Koszt całkowity        | number       |
| `getCurrency()`      | Kod waluty             | string       |
| `getPricePerUnit()`  | Cena za kWh            | number       |
| `getPhaseCount()`    | Liczba faz             | number (1-3) |
| `getPhase(n)`        | Dane fazy n            | table        |
| `getVoltage(n)`      | Napięcie fazy n        | number (V)   |
| `getCurrent(n)`      | Prąd fazy n            | number (A)   |
| `getPower(n)`        | Moc fazy n             | number (W)   |
| `getFrequency()`     | Częstotliwość          | number (Hz)  |
| `getPhases()`        | Wszystkie fazy         | table[]      |
| `getLastUpdate()`    | Timestamp aktualizacji | number       |
| `getError()`         | Ostatni błąd           | string/nil   |
| `getData()`          | Wszystkie dane         | table        |
| `refresh()`          | Wymuś odświeżenie      | -            |

### Zdarzenia

| Zdarzenie            | Opis                | Dane                                             |
|----------------------|---------------------|--------------------------------------------------|
| `supla:updated`      | Dane zaktualizowane | connected, totalPower, totalCurrent, totalEnergy |
| `supla:error`        | Błąd komunikacji    | error                                            |
| `supla:disconnected` | Licznik rozłączony  | -                                                |

## Rozwiązywanie problemów

### Brak danych

1. Sprawdź czy Direct Link jest aktywny w Supla Cloud
2. Sprawdź czy URL jest poprawny (format JSON)
3. Sprawdź logi: `Plugin.getPlugin("supla-power-meter"):getError()`

### Błąd HTTP 401

Direct Link wygasł lub został usunięty. Wygeneruj nowy w Supla Cloud.

### Błąd HTTP 503

Serwer Supla tymczasowo niedostępny. Plugin automatycznie ponowi próbę.

## Obsługiwane urządzenia

- Zamel MEW-01 (3-fazowy licznik energii)
- Inne liczniki Supla z funkcją pomiaru energii

## Linki

- [Supla Cloud](https://cloud.supla.org)
- [Supla API Docs](https://svr59.supla.org/api-docs/docs.html)
