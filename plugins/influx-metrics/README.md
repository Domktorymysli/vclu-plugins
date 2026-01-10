# InfluxDB Metrics Plugin

Wysyłanie metryk do InfluxDB, Telegraf, VictoriaMetrics lub dowolnego endpointu obsługującego line protocol.

## Cechy

- **Line Protocol** - kompatybilny z InfluxDB 1.x, 2.x, Telegraf, VictoriaMetrics, QuestDB
- **Wiele instancji** - możesz tworzyć wiele collectorów do różnych baz
- **Batching** - automatyczne buforowanie i wysyłanie w paczkach
- **Konfiguracja w kodzie** - bez JSON, pełna kontrola w Lua

## Użycie

### Podstawowe

```lua
local metrics = Plugin.get("@vclu/influx-metrics")

-- Utwórz collector
local m = metrics:create({
    url = "http://influxdb:8086/write?db=home"
})

-- Wysyłaj metryki
m:gauge("temperature", 22.5, { room = "salon" })
m:gauge("humidity", 45, { room = "salon" })
```

### InfluxDB 2.x z tokenem

```lua
local m = metrics:create({
    url = "http://influxdb:8086/api/v2/write?org=home&bucket=sensors",
    token = "my-influxdb-token",
    interval = 30,
    batchSize = 50
})
```

### Telegraf

```lua
local m = metrics:create({
    url = "http://telegraf:8186/write"
})
```

### VictoriaMetrics

```lua
local m = metrics:create({
    url = "http://victoriametrics:8428/write"
})
```

## API

### metrics:create(config, id?)

Tworzy nowy collector metryk.

**Config:**

| Parametr    | Typ    | Domyślnie   | Opis                                        |
|-------------|--------|-------------|---------------------------------------------|
| `url`       | string | (wymagany)  | URL endpointu (z query params)              |
| `token`     | string | nil         | Token autoryzacji (InfluxDB 2.x)            |
| `interval`  | number | 60          | Interwał flush w sekundach (0 = wyłączony)  |
| `batchSize` | number | 100         | Max punktów przed auto-flush                |
| `maxBuffer` | number | 10000       | Max punktów w buforze (potem dropped)       |
| `timeout`   | number | 10          | Timeout HTTP w sekundach                    |
| `tags`      | table  | {}          | Globalne tagi dodawane do wszystkich metryk |
| `precision` | string | "s"         | Precyzja timestampów: s, ms, us, ns         |

**Walidacja kluczy:**
- Measurement, tagi i pola są automatycznie "slugifikowane" do `[a-zA-Z0-9_]`
- Nieprawidłowe znaki zamieniane na `_`
- Puste/nieprawidłowe klucze są ignorowane z ostrzeżeniem w logach

**Przykład:**

```lua
local m = metrics:create({
    url = "http://influxdb:8086/write?db=home",
    interval = 30,
    batchSize = 50,
    tags = {
        host = "vclu",
        location = "dom"
    }
}, "main")  -- opcjonalne ID do późniejszego dostępu
```

### collector:gauge(name, value, tags?)

Wysyła metrykę typu gauge (aktualna wartość).

```lua
m:gauge("temperature", 22.5, { room = "salon", sensor = "dht22" })
m:gauge("power", 1500)  -- bez tagów
```

### collector:counter(name, value?, tags?)

Wysyła metrykę typu counter (inkrementalna).

```lua
m:counter("requests", 1, { endpoint = "/api" })
m:counter("errors")  -- domyślnie 1
```

### collector:fields(name, fields, tags?)

Wysyła wiele pól jako jedną metrykę.

```lua
m:fields("weather", {
    temperature = 22.5,
    humidity = 45,
    pressure = 1013.25
}, { city = "Warsaw" })
```

### collector:write(measurement, fields, tags?, timestamp?)

Niskopoziomowe API - pełna kontrola.

```lua
m:write("sensor", { value = 22.5, battery = 95 }, { id = "s01" }, os.time())
```

**Timestamp:**
- Opcjonalny - jeśli pominięty, InfluxDB użyje czasu odbioru
- Podawany jako Unix timestamp w sekundach (np. `os.time()`)
- Konwertowany do precyzji ustawionej w `precision` (domyślnie sekundy)
- Dla `precision = "ms"` wartość jest mnożona przez 1000
- Dla `precision = "ns"` wartość jest mnożona przez 10^9

### collector:flush()

Wymusza natychmiastowe wysłanie bufora.

```lua
m:flush()
```

### collector:stats()

Zwraca statystyki collectora.

```lua
local s = m:stats()
--[[
{
    buffered = 5,           -- aktualnie w buforze
    sent = 1000,            -- wysłanych (sukces)
    failed = 2,             -- nieudanych (HTTP error)
    dropped = 0,            -- odrzuconych (buffer pełny)
    lastFlush = 1234567890, -- timestamp ostatniego flush
    lastError = nil         -- ostatni błąd (string lub nil)
}
]]
```

**Delivery guarantees:**
- `sent` - metryki dostarczone (HTTP 2xx)
- `failed` - metryki utracone przez błąd sieci/serwera
- `dropped` - metryki odrzucone gdy bufor osiągnął `maxBuffer`

### collector:stop()

Zatrzymuje collector (flush + stop timer).

```lua
m:stop()
```

### metrics:get(id)

Pobiera collector po ID.

```lua
local m = metrics:get("main")
```

### metrics:list()

Lista ID wszystkich collectorów.

```lua
local ids = metrics:list()  -- {"main", "backup"}
```

### metrics:remove(id)

Zatrzymuje i usuwa collector.

```lua
metrics:remove("main")
```

## Przykłady

### Metryki z sensorów Grenton

```lua
local metrics = Plugin.get("@vclu/influx-metrics")
local m = metrics:create({
    url = "http://influxdb:8086/write?db=grenton",
    interval = 60,
    tags = { source = "grenton" }
})

-- Subskrybuj zmiany stanów
StateBus:getShared():on("state_changed", function(data)
    if data.type == "ONE_WIRE" or data.type == "PANELSENSTEMP" then
        m:gauge("temperature", data.value, {
            path = data.path,
            type = data.type
        })
    elseif data.type == "DOUT" or data.type == "DIMMER" then
        m:gauge("device_state", data.value, {
            path = data.path,
            type = data.type
        })
    end
end)
```

### Metryki z pluginu Supla

```lua
local metrics = Plugin.get("@vclu/influx-metrics")
local supla = Plugin.get("@vclu/supla-power-meter")

local m = metrics:create({
    url = "http://influxdb:8086/write?db=energy",
    interval = 30
})

-- Przy każdej aktualizacji Supla
EventBus:subscribe("supla:updated", function(data)
    m:fields("power_meter", {
        power = supla:getTotalPower(),
        current = supla:getTotalCurrent(),
        energy = supla:getTotalEnergy(),
        voltage_l1 = supla:getVoltage(1),
        voltage_l2 = supla:getVoltage(2),
        voltage_l3 = supla:getVoltage(3)
    })
end)
```

### Metryki z rekuperatora

```lua
local metrics = Plugin.get("@vclu/influx-metrics")
local salda = Plugin.get("@vclu/salda-recuperator")

local m = metrics:create({
    url = "http://influxdb:8086/write?db=hvac",
    interval = 60,
    tags = { device = "salda" }
})

salda:on("salda:updated", function(data)
    m:fields("recuperator", {
        supply_air = data.supplyAir,
        outside_air = data.outsideAir,
        humidity = data.humidity * 100,
        fan_speed = data.fanSpeed,
        setpoint = data.temperature
    })
end)
```

### Wiele baz danych

```lua
local metrics = Plugin.get("@vclu/influx-metrics")

-- Główna baza - wszystkie metryki
local main = metrics:create({
    url = "http://influxdb:8086/write?db=home",
    interval = 60
}, "main")

-- Energia - częstsze próbkowanie
local energy = metrics:create({
    url = "http://influxdb:8086/write?db=energy",
    interval = 10,
    batchSize = 20
}, "energy")

-- Backup do VictoriaMetrics
local backup = metrics:create({
    url = "http://victoria:8428/write",
    interval = 300
}, "backup")
```

## Line Protocol

Plugin generuje standardowy InfluxDB line protocol:

```
measurement,tag1=value1,tag2=value2 field1=1i,field2=2.5,field3="text" timestamp
```

Przykłady:

```
temperature,room=salon,sensor=dht22 value=22.5 1704067200
power_meter power=1500i,voltage=230.5,current=6.52 1704067200
weather,city=Warsaw temperature=22.5,humidity=45i,pressure=1013.25
```

## Rozwiązywanie problemów

### Metryki nie docierają

1. Sprawdź URL i dostępność endpointu
2. Sprawdź logi: `metrics:get("main"):stats()`
3. Sprawdź czy baza istnieje (InfluxDB 1.x wymaga wcześniejszego utworzenia)

### Błąd 401 Unauthorized

Dodaj token dla InfluxDB 2.x:

```lua
metrics:create({
    url = "http://influxdb:8086/api/v2/write?org=myorg&bucket=mybucket",
    token = "your-token-here"
})
```

### Wysoka latencja

Zwiększ `batchSize` i `interval`:

```lua
metrics:create({
    url = "...",
    interval = 120,  -- flush co 2 minuty
    batchSize = 200  -- lub po 200 punktach
})
```
