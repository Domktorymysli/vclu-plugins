# vCLU Plugins

Official plugins for [Virtual CLU](https://github.com/Domktorymysli/virtual-clu).

**API Version:** 2.0

---

## Quick Reference

```lua
-- Create plugin
local plugin = Plugin:new("my-plugin", { name = "My Plugin", version = "1.0.0" })

-- Lifecycle
plugin:onInit(function(config) end)
plugin:onCleanup(function() end)

-- HTTP
plugin:httpRequest({ url = "...", parseJson = "success" }, function(resp) end)
plugin:url(base, params)
plugin:basicAuth(user, pass)
plugin:bearerAuth(token)

-- Polling
local poller = plugin:poller("name", { interval = 60000, onTick = function(done) done() end })
poller:start() / poller:stop() / poller:poll() / poller:stats()

-- Registry
plugin:upsertObject("path", data)      -- create or replace
plugin:updateObject("path", patch)     -- merge (fails if not exists)
plugin:getObject("path")

-- Events
plugin:emit("event:name", data, { throttle = 60000 })
plugin:on("event:name", function(data) end)

-- Timers
plugin:setTimeout(ms, fn) / plugin:setInterval(ms, fn) / plugin:clearTimer(id)

-- MQTT
plugin:mqttPublish(topic, payload, opts)
plugin:mqttSubscribe(topic, function(topic, payload) end)

-- Helpers
plugin:coerceNumber(val, default)
plugin:coerceString(val, default)
plugin:coerceBool(val, default)
plugin:log(level, message)
plugin:logSafe(level, message, fields, redact)

-- Persistence (KV Store)
plugin:kvGet(key, default)
plugin:kvSet(key, value, { secure = true, ttl = 3600 })
plugin:kvDelete(key)
plugin:kvHas(key)
plugin:kvList(prefix)
plugin:kvGetAll()

-- Access other plugins
local other = Plugin.get("@vclu/weather")
local all = Plugin.list()
```

---

## Available Plugins

| Plugin | Description | Version |
|--------|-------------|---------|
| [weather](plugins/weather/) | Weather data from OpenWeatherMap | 2.0.0 |
| [time-sync](plugins/time-sync/) | Time synchronization (WorldTimeAPI) | 2.0.0 |
| [sun-position](plugins/sun-position/) | Sun position, sunrise/sunset, moon phases | 2.0.0 |
| [telegram](plugins/telegram/) | Telegram Bot notifications | 2.0.0 |
| [salda-recuperator](plugins/salda-recuperator/) | Salda HRV integration | 2.0.0 |
| [supla-power-meter](plugins/supla-power-meter/) | Supla 3-phase energy meter | 2.0.0 |
| [example](plugins/example/) | Template plugin with API examples | 2.0.0 |

---

## Installation

### Via Web UI (recommended)

1. Open vCLU Web UI
2. Go to **Plugins**
3. Click **Install** on desired plugin
4. Configure and enable

### Manual

Add to `.vclu.json`:

```json
{
  "plugins": {
    "installed": [
      {
        "id": "@vclu/weather",
        "enabled": true,
        "config": {
          "apiKey": "your-openweathermap-api-key",
          "city": "Warsaw"
        }
      }
    ]
  }
}
```

---

## Plugin Structure

```
plugins/my-plugin/
├── plugin.json    # Manifest (required)
├── init.lua       # Plugin code (required)
└── README.md      # Documentation (optional)
```

### plugin.json

```json
{
  "id": "my-plugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "description": "What this plugin does",
  "author": "your-name",
  "license": "MIT",

  "requires": {
    "vclu": ">=1.0.0"
  },

  "config": {
    "apiKey": {
      "type": "string",
      "required": true,
      "description": "API key for the service"
    },
    "interval": {
      "type": "number",
      "default": 60,
      "min": 10,
      "max": 3600,
      "description": "Refresh interval in seconds"
    },
    "enabled": {
      "type": "boolean",
      "default": true,
      "description": "Enable/disable feature"
    }
  },

  "exports": {
    "objects": {
      "data": { "description": "Main data object in registry" }
    },
    "events": [
      { "name": "my-plugin:updated", "description": "Fired when data changes" }
    ]
  }
}
```

---

## Plugin Template

```lua
--- My Plugin for vCLU
-- @module plugins.my-plugin

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local plugin = Plugin:new("my-plugin", {
    name = "My Plugin",
    version = "1.0.0",
    description = "What this plugin does"
})

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local state = {
    ready = false,
    lastUpdate = 0,
    lastError = nil,
    -- Plugin-specific data
    value = 0
}

local poller = nil

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function parseResponse(json)
    if not json or not json.data then
        return nil, "Invalid response"
    end
    return {
        value = plugin:coerceNumber(json.data.value, 0)
    }
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

plugin:onInit(function(config)
    -- Validate required config
    if not config.apiKey or config.apiKey == "" then
        plugin:log("error", "apiKey is required")
        return
    end

    -- Parse config with defaults
    local interval = plugin:coerceNumber(config.interval, 60)

    plugin:log("info", "Initializing with interval: " .. interval .. "s")

    -- Create initial registry object
    plugin:upsertObject("data", {
        ready = false,
        value = 0,
        lastUpdate = 0
    })

    -- Create poller
    poller = plugin:poller("fetch", {
        interval = interval * 1000,
        immediate = true,
        timeout = 15000,
        retry = { maxAttempts = 3, backoff = 2000 },

        onTick = function(done)
            local url = plugin:url("https://api.example.com/data", {
                key = config.apiKey
            })

            plugin:httpRequest({
                url = url,
                timeout = 10000,
                parseJson = "success"
            }, function(resp)
                if resp.err then
                    done(resp.err)
                    return
                end

                local data, err = parseResponse(resp.json)
                if not data then
                    done(err)
                    return
                end

                -- Update state
                state.ready = true
                state.lastUpdate = os.time()
                state.lastError = nil
                state.value = data.value

                -- Update registry
                plugin:updateObject("data", {
                    ready = true,
                    value = data.value,
                    lastUpdate = state.lastUpdate
                })

                plugin:log("info", "Updated: value=" .. data.value)

                -- Emit event with throttling
                plugin:emit("my-plugin:updated", {
                    value = data.value
                }, { throttle = 60000 })

                done()
            end)
        end,

        onError = function(err, stats)
            state.lastError = err
            plugin:log("error", "Fetch failed: " .. tostring(err))
        end
    })

    poller:start()
end)

plugin:onCleanup(function()
    if poller then poller:stop() end
    plugin:log("info", "Plugin stopped")
end)

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

function plugin:isReady()
    return state.ready
end

function plugin:getLastError()
    return state.lastError
end

function plugin:getValue()
    return state.value
end

function plugin:getData()
    return {
        ready = state.ready,
        value = state.value,
        lastUpdate = state.lastUpdate,
        lastError = state.lastError
    }
end

function plugin:refresh()
    if poller then poller:poll() end
end

function plugin:getStats()
    if poller then return poller:stats() end
    return {}
end

return plugin
```

---

## API Reference

### Plugin Registration

```lua
local plugin = Plugin:new(id, options)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Unique plugin ID (lowercase, alphanumeric, hyphens) |
| `options.name` | string | Display name |
| `options.version` | string | Semantic version |
| `options.description` | string | Optional description |

### Lifecycle

```lua
-- Called when plugin loads with config from .vclu.json
plugin:onInit(function(config)
    -- config contains user configuration
    local apiKey = config.apiKey
end)

-- Called when plugin unloads (optional - resources auto-cleanup)
plugin:onCleanup(function()
    -- Custom cleanup logic
end)
```

### HTTP Requests

#### `plugin:httpRequest(opts, callback)`

Full-featured HTTP client with JSON parsing, retry, and logging.

```lua
plugin:httpRequest({
    -- Required
    url = "https://api.example.com/data",

    -- Optional
    method = "GET",                    -- GET, POST, PUT, DELETE
    headers = { ["Authorization"] = "Bearer xxx" },
    timeout = 10000,                   -- ms (default: 30000)
    parseJson = "success",             -- "success" | "always" | "never"

    -- Body (mutually exclusive)
    body = "raw string",               -- raw body
    json = { key = "value" },          -- auto JSON.encode + Content-Type
    form = { key = "value" },          -- application/x-www-form-urlencoded

    -- Logging
    log = { redact = true }            -- redact secrets in logs (default: true)
}, function(resp)
    -- resp is ALWAYS a table (never nil)
    -- resp.status   - HTTP status code (number)
    -- resp.body     - Response body (string)
    -- resp.headers  - Response headers (table)
    -- resp.json     - Parsed JSON (table, if parseJson enabled)
    -- resp.err      - Error message (string or nil)
    -- resp.errCode  - Error code: "timeout", "network", "http_4xx", "http_5xx", "parse"
    -- resp.elapsed  - Request duration in ms

    if resp.err then
        plugin:log("error", "Request failed: " .. resp.err)
        return
    end

    if resp.json then
        plugin:log("info", "Got value: " .. tostring(resp.json.value))
    end
end)
```

**parseJson modes:**
- `"success"` - Parse JSON only on 2xx status
- `"always"` - Always try to parse (useful for APIs returning errors as JSON)
- `"never"` - Never parse, return raw body

#### `plugin:url(base, params)`

Build URL with query parameters (sorted, encoded).

```lua
local url = plugin:url("https://api.example.com/data", {
    apiKey = "secret",
    city = "New York",
    units = "metric"
})
-- Result: https://api.example.com/data?apiKey=secret&city=New%20York&units=metric
```

#### `plugin:basicAuth(username, password)`

Generate Basic Auth header value.

```lua
local auth = plugin:basicAuth("user", "pass")
-- Result: "Basic dXNlcjpwYXNz"

plugin:httpRequest({
    url = "https://api.example.com",
    headers = { ["Authorization"] = auth }
}, callback)
```

#### `plugin:bearerAuth(token)`

Generate Bearer Auth header value.

```lua
local auth = plugin:bearerAuth("my-token")
-- Result: "Bearer my-token"
```

### Poller

#### `plugin:poller(name, opts)`

Create a managed polling loop with retry, backoff, and inFlight protection.

```lua
local poller = plugin:poller("fetch", {
    -- Timing
    interval = 60000,           -- ms between ticks
    immediate = true,           -- execute immediately on start
    timeout = 30000,            -- max tick duration (ms)

    -- Retry on error
    retry = {
        maxAttempts = 3,        -- total attempts
        backoff = 2000          -- base backoff (doubles each retry)
    },

    -- Callbacks
    onTick = function(done)
        -- Do async work...
        -- Call done() on success
        -- Call done("error message") on failure
        plugin:httpRequest({ url = "..." }, function(resp)
            if resp.err then
                done(resp.err)  -- triggers retry
                return
            end
            -- process data...
            done()  -- success
        end)
    end,

    onError = function(err, stats)
        -- Called after all retries exhausted
        plugin:log("error", "Polling failed: " .. tostring(err))
    end
})

-- Control
poller:start()              -- start polling
poller:stop()               -- stop polling (doesn't interrupt current tick)
poller:poll()               -- force immediate poll (queued if inFlight)

-- Stats
local stats = poller:stats()
-- stats.running      - boolean
-- stats.inFlight     - boolean
-- stats.tickCount    - number
-- stats.errorCount   - number
-- stats.lastTick     - timestamp
-- stats.lastError    - string or nil
```

### Registry

#### `plugin:upsertObject(path, data)`

Create or replace object in plugin's namespace.

```lua
-- Creates: plugins.<namespace>.<pluginId>.<path>
plugin:upsertObject("sensor", {
    value = 0,
    unit = "°C",
    lastUpdate = 0
})
```

#### `plugin:updateObject(path, patch)`

Shallow merge into existing object. **Fails if object doesn't exist.**

```lua
local ok, err = plugin:updateObject("sensor", {
    value = 22.5,
    lastUpdate = os.time()
})

if not ok then
    plugin:log("error", "Update failed: " .. err)
end
```

**Features:**
- Validates field names against existing object
- Suggests corrections for typos (fuzzy matching)
- Only works within plugin's namespace

```lua
-- Typo protection:
plugin:updateObject("sensor", { valuee = 22 })
-- Error: unknown field 'valuee' (did you mean: 'value'?)
```

#### `plugin:getObject(path)`

Get object from registry.

```lua
-- Own object (short path)
local sensor = plugin:getObject("sensor")

-- Other object (full path)
local clu = plugin:getObject("CLU.DOU5998")
```

### Events

#### `plugin:emit(name, data, opts)`

Emit event with optional throttling.

```lua
-- Basic emit
plugin:emit("weather:changed", { temp = 22.5 })

-- Throttled emit (max 1 per 60s, leading edge)
plugin:emit("weather:changed", { temp = 22.5 }, {
    throttle = 60000
})

-- Throttled with trailing edge
plugin:emit("sensor:value", { value = 100 }, {
    throttle = 1000,
    trailing = true  -- emit last value after window closes
})

-- Coalesce multiple values
plugin:emit("batch:item", { id = 1 }, {
    throttle = 5000,
    coalesce = true,
    key = "id"       -- result: { ids = [1, 2, 3] }
})
```

#### `plugin:on(name, callback)`

Listen for events.

```lua
plugin:on("weather:changed", function(data)
    plugin:log("info", "Temperature: " .. data.temp)
end)
```

### Timers

```lua
-- One-shot timer
local timerId = plugin:setTimeout(5000, function()
    plugin:log("info", "5 seconds passed")
end)

-- Repeating timer
local intervalId = plugin:setInterval(60000, function()
    plugin:log("info", "Tick")
end)

-- Cancel timer
plugin:clearTimer(timerId)
plugin:clearTimer(intervalId)
```

### MQTT

```lua
-- Publish string
plugin:mqttPublish("home/status", "online")

-- Publish JSON (auto-encoded)
plugin:mqttPublish("home/sensor", { temp = 22.5, humidity = 65 })

-- Publish with options
plugin:mqttPublish("home/state", "ON", { retain = true, qos = 1 })

-- Subscribe
plugin:mqttSubscribe("home/+/set", function(topic, payload)
    plugin:log("info", topic .. " = " .. payload)
end)
```

### Type Coercion

Safe type conversion with defaults.

```lua
local num = plugin:coerceNumber(config.interval, 60)
-- nil → 60, "30" → 30, "abc" → 60, 45 → 45

local str = plugin:coerceString(config.city, "Warsaw")
-- nil → "Warsaw", 123 → "123", "Berlin" → "Berlin"

local bool = plugin:coerceBool(config.enabled, true)
-- nil → true, "false" → false, 0 → false, 1 → true
```

### Logging

```lua
-- Standard logging
plugin:log("debug", "Debug message")
plugin:log("info", "Info message")
plugin:log("warn", "Warning message")
plugin:log("error", "Error message")

-- Safe logging with field redaction
plugin:logSafe("info", "API request", {
    url = "https://api.example.com",
    apiKey = "sk-1234567890"    -- logged as "sk-12***"
}, true)  -- redact = true (default)
```

**Auto-redacted fields:** `token`, `password`, `apiKey`, `secret`, `key`, `auth`, `bearer`

### Persistence (KV Store)

Persistent key-value storage for plugin state across restarts.

```
Storage: /var/lib/vclu/plugins/<plugin-id>.json
```

#### `plugin:kvGet(key, default)`

Get value from persistent storage.

```lua
local token = plugin:kvGet("access_token")
local cursor = plugin:kvGet("cursor", 0)  -- with default
```

#### `plugin:kvSet(key, value, opts)`

Store value persistently.

```lua
-- Simple
plugin:kvSet("cursor", 12345)
plugin:kvSet("settings", { theme = "dark" })

-- With options
plugin:kvSet("access_token", token, {
    secure = true,   -- hidden from logs/UI/debug
    ttl = 3600       -- expires in 1 hour (seconds)
})
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `secure` | boolean | false | Hide from logs, UI, registry export |
| `ttl` | number | nil | Time-to-live in seconds |

#### `plugin:kvDelete(key)`

Remove key.

```lua
plugin:kvDelete("cache")
```

#### `plugin:kvHas(key)`

Check if key exists (and not expired).

```lua
if plugin:kvHas("access_token") then
    -- Use existing token
end
```

#### `plugin:kvList(prefix)`

List keys, optionally filtered by prefix.

```lua
local keys = plugin:kvList()           -- all keys
local cache = plugin:kvList("cache:")  -- keys starting with "cache:"
```

#### `plugin:kvGetAll()`

Get entire store as table (useful in onInit).

```lua
plugin:onInit(function(config)
    local store = plugin:kvGetAll()
    if store.cursor then
        state.cursor = store.cursor
    end
end)
```

#### Use Cases

```lua
-- OAuth token persistence
plugin:kvSet("oauth", {
    access_token = token,
    refresh_token = refresh,
    expires_at = os.time() + 3600
}, { secure = true })

-- Polling cursor (Telegram updates)
plugin:kvSet("update_offset", lastUpdateId + 1)

-- Cache with TTL
plugin:kvSet("cache:weather", data, { ttl = 1800 })  -- 30 min

-- Feature toggle
plugin:kvSet("feature_enabled", true)
```

### Plugin Access

```lua
-- Get another plugin
local weather = Plugin.get("@vclu/weather")
if weather then
    local temp = weather:getTemperature()
    plugin:log("info", "Temperature: " .. tostring(temp))
end

-- List all plugins
local plugins = Plugin.list()
for _, p in ipairs(plugins) do
    plugin:log("debug", p.id .. " v" .. p.version)
end
```

---

## Best Practices

### 1. Always validate config in onInit

```lua
plugin:onInit(function(config)
    if not config.apiKey or config.apiKey == "" then
        plugin:log("error", "apiKey is required")
        return  -- Don't proceed without required config
    end
end)
```

### 2. Use state object with ready/lastUpdate/lastError

```lua
local state = {
    ready = false,
    lastUpdate = 0,
    lastError = nil,
    -- ... plugin data
}
```

### 3. Use poller instead of setInterval + httpGet

```lua
-- Bad
plugin:setInterval(60000, function()
    plugin:httpGet(url, function(resp, err)
        -- No retry, no timeout, no inFlight protection
    end)
end)

-- Good
local poller = plugin:poller("fetch", {
    interval = 60000,
    retry = { maxAttempts = 3, backoff = 2000 },
    onTick = function(done) ... end
})
```

### 4. Use coercion helpers for config

```lua
-- Bad
local interval = config.interval or 60

-- Good
local interval = plugin:coerceNumber(config.interval, 60)
```

### 5. Throttle events to prevent spam

```lua
-- Bad - fires every poll
plugin:emit("data:changed", data)

-- Good - max 1 per minute
plugin:emit("data:changed", data, { throttle = 60000 })
```

### 6. Use upsertObject in onInit, updateObject after

```lua
plugin:onInit(function(config)
    -- Create initial object
    plugin:upsertObject("data", { ready = false, value = 0 })

    poller = plugin:poller("fetch", {
        onTick = function(done)
            -- Update existing object
            plugin:updateObject("data", { ready = true, value = newValue })
            done()
        end
    })
end)
```

### 7. Provide standard public API

```lua
function plugin:isReady() return state.ready end
function plugin:getLastError() return state.lastError end
function plugin:getData() return { ... } end
function plugin:refresh() if poller then poller:poll() end end
function plugin:getStats() if poller then return poller:stats() end return {} end
```

---

## Sandbox Environment

Plugins run in an isolated sandbox:

| Available | Blocked |
|-----------|---------|
| `string`, `table`, `math` | `os.execute()`, `io.*` |
| `pairs`, `ipairs`, `type`, `tonumber`, `tostring` | `loadfile`, `dofile` |
| `os.time()`, `os.date()` | `rawset`, `rawget`, `debug` |
| `JSON:decode()`, `JSON:encode()` | Modifying `_G` |
| Plugin API (all methods above) | File system access |

All resources (timers, subscriptions, events) are automatically cleaned up when plugin unloads.

---

## Creating a New Plugin

1. Copy `plugins/example/` as template
2. Edit `plugin.json` (id, name, config schema)
3. Write logic in `init.lua` following the template
4. Test locally
5. Submit Pull Request

---

## Custom Repositories

Create your own plugin repository:

1. Create `plugins.json` in repository root:

```json
{
  "version": 1,
  "name": "My Plugins",
  "namespace": "myrepo",
  "url": "https://github.com/username/my-plugins",
  "plugins": [
    {
      "id": "my-plugin",
      "name": "My Plugin",
      "version": "1.0.0",
      "description": "Description",
      "author": "Author",
      "path": "plugins/my-plugin",
      "tags": ["tag1", "tag2"]
    }
  ]
}
```

2. Add repository in vCLU Web UI: **Settings > Plugin Repositories**

---

## License

MIT
