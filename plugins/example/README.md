# Example Plugin

Przykładowy plugin pokazujący jak pisać własne pluginy dla vCLU.

## Szybki start

### 1. Utwórz katalog pluginu

```
clu/plugins/moj-plugin/
├── plugin.json
└── init.lua
```

### 2. Minimalny plugin.json

```json
{
  "id": "moj-plugin",
  "name": "Mój Plugin",
  "version": "1.0.0"
}
```

### 3. Minimalny init.lua

```lua
local plugin = Plugin:new("moj-plugin", {
    name = "Mój Plugin",
    version = "1.0.0"
})

plugin:onInit(function(config)
    plugin:log("info", "Plugin załadowany!")
end)
```

### 4. Dodaj do .vclu.json

```json
{
  "plugins": {
    "installed": [{
      "id": "moj-plugin",
      "version": "1.0.0",
      "enabled": true
    }]
  }
}
```

### 5. Uruchom vCLU

Plugin zostanie automatycznie załadowany.

## API Reference

### Lifecycle

```lua
-- Rejestracja pluginu
local plugin = Plugin:new("id", { name = "...", version = "..." })

-- Inicjalizacja (wywoływana przy starcie)
plugin:onInit(function(config) ... end)

-- Cleanup (wywoływana przy wyłączeniu)
plugin:onCleanup(function() ... end)
```

### Konfiguracja

```lua
-- Odczyt wartości z config
local value = plugin:getConfig("key", "default")
```

### Timery

```lua
-- Jednorazowy (ms)
plugin:setTimeout(5000, function() ... end)

-- Powtarzający się (ms)
local id = plugin:setInterval(60000, function() ... end)

-- Anulowanie
plugin:clearTimer(id)
```

### HTTP

```lua
-- GET
plugin:httpGet(url, function(response, err) ... end)

-- POST (data jako table -> JSON)
plugin:httpPost(url, data, function(response, err) ... end)
```

### MQTT

```lua
-- Publish
plugin:mqttPublish(topic, payload)
plugin:mqttPublish(topic, payload, { retain = true, qos = 1 })

-- Subscribe
plugin:mqttSubscribe(topic, function(topic, payload) ... end)
```

### Registry

```lua
-- Tworzenie obiektu (w namespace pluginu)
local obj = plugin:createObject("path", { key = "value" })

-- Odczyt obiektu
local obj = plugin:getObject("path")
```

### Eventy

```lua
-- Nasłuchiwanie
plugin:on("eventName", function(...) ... end)

-- Emitowanie
plugin:emit("eventName", data)
```

### Logowanie

```lua
plugin:log("info", "message")
plugin:log("warn", "message")
plugin:log("error", "message")
plugin:log("debug", "message")
```

## Struktura plików

```
plugins/moj-plugin/
├── plugin.json      # Manifest (wymagany)
├── init.lua         # Główny kod (wymagany)
├── utils.lua        # Dodatkowe moduły (opcjonalne)
└── README.md        # Dokumentacja (opcjonalna)
```

Jeśli masz dodatkowe pliki, dodaj je do `files` w plugin.json:

```json
{
  "files": ["init.lua", "utils.lua", "lib/helpers.lua"]
}
```

## Sandbox

Plugin działa w sandboxie - ma dostęp tylko do bezpiecznych funkcji:

| Dostępne | Zablokowane |
|----------|-------------|
| `string`, `table`, `math` | `os.execute` |
| `pairs`, `ipairs`, `type` | `io.*` |
| `tostring`, `tonumber` | `loadfile`, `dofile` |
| `os.time`, `os.date` | `rawset`, `debug` |
| `JSON`, `Logger` | modyfikacja `_G` |

## Tips

1. **Używaj plugin:log()** zamiast print() - logi będą miały prefix pluginu
2. **Nie musisz czyścić timerów** - sandbox robi to automatycznie przy unload
3. **Błędy nie crashują systemu** - każdy callback jest w pcall
4. **Testuj lokalnie** - edytuj pliki w `clu/plugins/` i restartuj vCLU
