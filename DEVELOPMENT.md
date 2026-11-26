# Writing vclu Plugins

How plugins are built: the runtime API, the sandbox, factory plugins and tests.
For the list of plugins and how to install them, see [README.md](README.md).

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

-- Another plugin: read-only, its sensors and controls
local other = Plugin.getPlugin("@jan/other-plugin")
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

  "api": 2,
  "permissions": { "internet": ["api.example.com"], "lan": true },

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
--- My Plugin for vclu
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
                    done(nil, resp.err)
                    return
                end

                local data, err = parseResponse(resp.json)
                if not data then
                    done(nil, err)
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
    -- resp.ok       - true for 2xx
    -- resp.err      - nil on 2xx, otherwise the network error or "HTTP 404"
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
- `"always"` - Always try to parse (useful for APIs returning errors as JSON:
  with `"success"` the API's own message is lost and only `"HTTP 403"` remains)

`if resp.err then` is the whole failure check: a status outside 2xx already
sets it. Look at `resp.status` only to tell failures apart (e.g. retry on 401).
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
        -- done(data, err): call done() or done(data) on success,
        -- done(nil, "error message") on failure. A single argument is data:
        -- done("error") counts as a success, so onError, retry and backoff never run.
        plugin:httpRequest({ url = "..." }, function(resp)
            if resp.err then
                done(nil, resp.err)  -- failure: onError, retry, backoff
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

### Plugin id

The namespace and the id are lower case: `a-z`, digits, `.`, `_` and `-`, with no `--` and no
`-` at either end (`@jan/my-plugin`). vclu refuses any other id.

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

Needs `"mqtt": true` in the permissions of `plugin.json`.

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

### UDP to devices

`"udp": true` (vclu 1.13+, plugin API 2) is for devices with a local UDP protocol, such as an air
conditioner. It needs no `grenton_raw`: installing allows it like `lan`, and the user can limit
it to some hosts. The socket reaches local addresses only, not the vclu it runs in, not the ports
vclu listens on and not the CLU ports 1234 and 69 (those need `grenton_raw` or `tftp`). It
broadcasts only to the ports `plugin.json` lists, at most 8, and not at all when the user limited
it to some hosts:

```json
"permissions": { "udp": true },
"udp": { "broadcastPorts": [7000] },
```

```lua
local socket, err = plugin:udpSocket({ port = 0 })   -- port 0: any free one
socket:onReceive(function(bytes, ip, port) end)
socket:broadcast(7000, '{"t":"scan"}')                -- true, or nil and an error
socket:send("192.168.1.40", 7000, packet)
socket:close()
```

A broadcast to another port returns nil and an error. A list with something other than whole
ports, with 1234 or 69, or `"udp"` without `"udp": true` in permissions refuses the manifest;
`validate.yml` checks it (`.github/scripts/check-udp.py`).

### TCP and telnet

`"tcp": true` (vclu 1.13+, plugin API 2) is for devices with a TCP protocol of their own: a
local Tuya socket, a telnet console. Installing allows it like `lan`, and the user can limit it
to some hosts. `plugin.json` lists the ports it connects to, at least one and at most 8; a port
that belongs to another permission (1234 `grenton_raw`, 69 `tftp`, 502 `modbus`, 1883 and 8883
`mqtt`) is refused:

```json
"permissions": { "tcp": true },
"tcp": { "ports": [23] },
```

```lua
local conn, err = plugin:tcpConnect({ host = "192.168.1.20", port = 23, timeout = 5 })
conn:onConnect(function() conn:send("status\r\n") end)   -- send works once connected
conn:onReceive(function(bytes) end)                      -- in order, possibly in pieces
conn:onClose(function(reason) end)                       -- the device or the network ended it
conn:isOpen()
conn:close()                                             -- no onClose for your own close
```

It connects only to an IPv4 address on the local network, not the vclu it runs in, in the
background (`timeout` in seconds, 5 by default, at most 30). `send` queues the bytes and returns
nil and an error before `onConnect`, after the end or with 1 MiB not sent yet. A plugin is a
client only, it does not listen.

For a telnet console wrap the connection; `Telnet` needs no permission of its own:

```lua
local t = Telnet.wrap(conn)                       -- { newline = "\r\n" } by default
t:onPrompt("login: $", function() t:send("admin") end)
t:onPrompt("> $", function() t:send("show status") end)
t:onLine(function(line) Logger:info(line) end)
```

`Telnet.wrap` takes the connection's `onReceive`. It answers every DO with WONT and every WILL
with DONT, so the device stays in plain line mode, drops subnegotiation and other commands, and
gives the text as lines (without the line end) and prompts (text without a line end that matches
a pattern; end it with `$`). `t:send(line)` adds the newline, `t:sendRaw(bytes)` sends as is.

`"tcp"` without `"tcp": true`, the permission without ports, or a port that is not a whole number,
repeated or of another permission refuses the manifest; `validate.yml` checks it
(`.github/scripts/check-tcp.py`).

### Grenton frames, TFTP and serial ports

Three permissions for plugins that work below HTTP: `"grenton_raw"`, `"tftp"` and `"serial"`.
They reach a CLU's commands, files on devices and whatever is on a port, so installing a plugin
does not allow them: the user does, on the plugins page, after a warning. Until then the methods
below raise an error. The user can also limit `grenton_raw` and `tftp` to some hosts, and assigns
the serial ports. Neither the socket nor the TFTP client reaches the vclu the plugin runs in or
anything outside the local network.

```lua
-- grenton_raw: a UDP socket of the plugin's own (port 0: any free one)
local socket, err = plugin:grentonSocket({ port = 0 })
socket:onReceive(function(bytes, ip, port) end)
socket:send("192.168.1.10", 1234, frame)   -- true, or nil and an error
socket:broadcast(1234, frame)               -- only to the CLU port, for discovery
socket:close()

-- grenton_raw: the CLU cipher; key and IV raw or in base64, as in the CLU's configuration.
-- The plugin brings the key (its config); vclu does not hand out its own.
local cipher = plugin:grentonCipher(config.key, config.iv)
local plain, err = cipher:decrypt(bytes)
local frame = cipher:encrypt("req:...")

-- tftp: reading and writing files on a device
local device = plugin:tftp("192.168.1.10", { port = 69 })
device:get("a.lua", function(bytes, err) end)
device:put("a.lua", bytes, function(ok, err) end)

-- serial: only a port the user assigned to the plugin
local port, err = plugin:serialOpen("/dev/ttyUSB0", { baud = 9600, data = 8, parity = "none", stop = 1 })
port:onData(function(bytes, err) end)  -- (nil, err) once, when the port fails
port:write(bytes)
port:close()
```

Bytes are Lua strings. Sockets and ports close when the plugin is disabled or removed.

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

### Secrets

A token or a password the user types in the plugin's wizard (a `"type": "secret"` field of its
form, vclu 1.13+) is kept apart from the plugin's config and reaches only the plugin:

```lua
plugin:onInit(function(cfg)
    local token = plugin:secret("token")   -- nil when the user did not set it
    plugin:httpRequest({ url = cfg.url, headers = { Authorization = plugin:bearerAuth(token) } },
        function(resp)
            if resp.err then plugin:log("error", "status: " .. resp.err) end
        end)
end)
```

Keep it in a local variable. **Never put a secret in a sensor, an exposed object,
`createObject`/`upsertObject`, an event or a log line:** other plugins, agents and MQTT/Home
Assistant read those. vclu masks the plugin's secret values as `***` in what it logs
(`plugin:log`, `plugin:logSafe`, `Logger`, `print`), as a safety net, not as a way to log them.

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
-- Another plugin is read-only: its sensors and controls, not its config or methods
local other = Plugin.getPlugin("@jan/other-plugin")
local sensor = other and other:get("value")
if sensor then
    plugin:log("info", "value: " .. tostring(sensor:get()))
end
```

A module (not a plugin) calls another plugin's methods as before, e.g. `Plugin.getPlugin("@vclu/telegram"):send(...)`.

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
| | `setmetatable`, `require` |
| `JSON:decode()`, `JSON:encode()` | Modifying `_G` |
| Plugin API (all methods above) | File system access |

All resources (timers, subscriptions, events) are automatically cleaned up when plugin unloads.

`string`, `table` and `math` are the plugin's own copies; `Logger`, `JSON` and `Plugin`
cannot be modified, and on plugin API 2 there is no `HTTP` or `MQTT` global: use
`plugin:httpRequest` and `plugin:mqttSubscribe`. Objects the plugin did not create, other plugins included, are
read-only: only `get`, `getX`, `isX` and `hasX` methods can be called on them, and another
plugin shows only its sensors and controls.

### Plugin API version

`"api"` in `plugin.json` names the contract the plugin is written for. New plugins use `2`.

| `api` | Contract |
|-------|----------|
| none or `1` | The contract from before permissions: `lan`, `mqtt` and `modbus` without declaring them, events and expose paths with any name, the `HTTP` and `MQTT` globals. Kept so existing plugins run without changing their manifest; the isolation above still applies (no methods on objects the plugin did not create, no `Plugin.list`). vclu logs a notice. |
| `2` | Only the declared permissions, events and expose paths under the plugin's prefix, HTTP and MQTT through the plugin API. |

The isolation above holds on every version. A plugin for a newer API than the vclu it is
installed on does not load and says to update vclu; `Plugin.apiVersion` is the highest
version the runtime runs. A vclu in strict mode (`"strict": true` in the `plugins` section of
`.vclu.json`) loads only API 2 or later. A vclu from before plugin API versions ignores the field
and runs every plugin on the old contract.

### Permissions

On plugin API 2 a plugin reaches only what `plugin.json` declares, the internet included:

| Permission | Gives |
|------------|-------|
| `"internet": ["api.example.com"]` | HTTP to the internet hosts on the list (below) |
| `"lan": true` | HTTP to local addresses: the house's devices, `localhost`, private networks (checked after DNS resolution) |
| `"mqtt": true` | `plugin:mqttSubscribe` and `plugin:mqttPublish` |
| `"udp": true` | a UDP socket for devices on the local network, not the CLU (see below) |
| `"tcp": true` | TCP connections to devices on the local network, to the ports in `"tcp"` (see below) |
| `"modbus": true` | the `Modbus` table (requests, reads and writes) |
| `"grenton_raw": true` | a UDP socket and the CLU cipher (see below); the user allows it in the panel |
| `"tftp": true` | a TFTP client (see below); the user allows it in the panel |
| `"serial": true` | a serial port the user assigns to the plugin (see below) |

Without the field an API 2 plugin gets none of them; declare `"permissions": {}` when it needs
none. A plugin that talks to a device whose address the user gives in `create(opts)`
needs `lan`.

#### Internet hosts

`internet` (vclu 1.13+, plugin API 2) names the servers the plugin connects to:

| In `permissions` | Means | The plugins page |
|---|---|---|
| `"internet": ["openapi.tuyaeu.com", "*.tuyaeu.com"]` | only these hosts | "Internet: connects to: …" |
| `"internet": "*"` (or `["*"]`) | any host on the internet | a warning: it can connect to any server |
| no `internet` | no internet | "Internet" in grey |

- An entry is a host name, `*.domain` for the domain's subdomains (`*.tuyaeu.com` matches
  `openapi.tuyaeu.com`, not `tuyaeu.com`; add both when the plugin calls both), or an exact IP
  address. No scheme, path, port or user: `"https://api.example.com/v1"` refuses the whole
  manifest, at download and at load. A non-ASCII name goes in its `xn--` form.
- vclu checks the host name in the URL, before the request and after every redirect, not the
  address it resolves to (cloud addresses change). An IP address in the URL matches only the same
  address on the list.
- The LAN is separate: a device in the house needs `lan`, also when its name is on the list, and
  a plugin with `lan` reaches local addresses without listing them.
- A request to a host that is not on the list fails with
  `api.example.com is not on the host list of @vclu/foo (permissions.internet)`.
- The user allows the hosts when installing. An update that adds a host or switches to `"*"`
  runs with the hosts allowed before until the user allows the new ones in the panel; keep the
  list exact so the user is not asked again without need.
- Plugin API 1 (no `"api"`) reaches any host, as before.

In this repository (`validate.yml`, `.github/scripts/check-internet.py`): every `http(s)://`
host written in the plugin's Lua must be on the list, and `"*"` needs `"internetWhy"` next to
`permissions` saying which servers and why the user gives them, e.g. a proxy or an InfluxDB
address from the configuration:

```json
"permissions": {"internet": "*", "lan": true},
"internetWhy": "InfluxDB at the address the user gives (InfluxDB Cloud or a server outside the house)",
```

`Crypto` (hashes, HMAC, AES, random bytes, hex and base64) and `bit` (LuaJIT BitOp) need no
permission on either API; the plugin gets its own copies. See the Lua reference on docs.vclu.pl.

### Events

On plugin API 2, events a plugin emits start with its prefix, so it cannot pass for another integration:
an official plugin's short id or the id's first word (`sun-position` emits `sun:rise`), any
other plugin's full id (`@jan/foo` emits `@jan/foo:changed`). `init`, `cleanup` and `timers`
of the instance belong to vclu; a poller and an expose handle are used through their methods.

---

## Factory Plugins

A plugin that talks to a device is a factory: no `config` in `plugin.json`, and
`plugin:create(opts)` returns an independent instance per call. The sandbox is
keyed by plugin id, so a configured singleton blocks a second gateway, receiver
or account. Reference: `plugins/musiccast`.

```lua
local salon = Plugin.getPlugin("@vclu/musiccast"):create({ id = "salon", ip = "192.168.0.159" })
```

`Plugin.getPlugin(id)` is the accessor; `Plugin.get` is an instance method that
returns a sensor.

Pitfalls found the hard way:

- **No `setmetatable`.** A metatable class passes every local test and fails on
  the runtime with `attempt to call a non-function object`. Copy the methods
  onto the instance: `for k, fn in pairs(Class) do obj[k] = fn end`.
- **Methods and state share one table.** A field named like a method replaces
  it at the first assignment (`self._playback = "play"` kills
  `self:_playback()`). Keep state under different names than methods.
- **Duplicate ids.** Sensor and poller names are flat across vclu. Derive them
  from the instance `id`, and on a duplicate log an error and return the
  existing instance instead of replacing it.
- **KV is per plugin, not per instance.** Prefix keys with the instance id:
  `plugin:kvSet("token:" .. self._id, ...)`.
- **Cleanup.** Keep the instances in a list and stop their pollers in
  `onCleanup`, or a reload leaves them polling.

### Exposing is the user's call

A plugin makes talking to a service easy: methods, state, polling. Whether the
device goes to HA, Apple Home or the dashboard is decided in the user's module,
not in the plugin, so a plugin does not need `get`/`set`/`onChange` or its own
event system. Whoever wants to `expose` wraps the instance in a small object
of their own.

A plugin that wants to make this easier registers values with
`plugin:sensor()` / `plugin:control()` (as `supla-power-meter` and
`modbus-gateway` do); the runtime gives those objects a correct `onChange`, and
the user exposes them with `expose(plugin:get("power"), "number", {...})`. In a
factory, derive the sensor id from the instance id.

That object follows the expose contract:

- `get(feature)` returns the state, `set(feature, value)` changes it.
- `onChange(cb)` **must return a function that removes `cb`**. `expose()`
  calls it on `unexpose()`; anything else leaves the callback registered and
  logs a warning.
- One object is one type. A receiver with power and volume is two objects
  (`switch` and `number`); HA has no MQTT media player.

### Dashboards: the plugin builds, the user grants access

Declare each dashboard in `plugin.json` (up to 8; id `[a-z0-9_]`, up to 64):

```json
"dashboards": [{ "id": "lista", "name": { "pl": "Zakupy", "en": "Shopping" }, "description": "..." }]
```

On API 2 `plugin:dashboard(id)` builds only a declared id, at `/d/<shortId>_<id>`, named as
declared. The plugin may keep it behind login (`:auth("session")`, the default) or a PIN
(`:auth("pin")`); `:auth("public")`, `:pin()`, `:remote()` and `:roles()` are refused: who else
opens it is the user's. The plugin wizard shows a Dashboards step for it and writes the user's
choice as code, which people and agents can also write by hand in a module:

```lua
Plugin.getPlugin("@vclu/zakupy"):dashboardAccess("lista", { auth = "public", remote = { roles = { "domownicy" } } })
```

`test/harness.lua` checks the same: `harness.install({ dashboards = { lista = "Zakupy" } })`
refuses an undeclared id, and the builder refuses public, a PIN code, remote and roles.

## Testing

`test/harness.lua` stands in for the runtime, so a plugin runs under a bare
`lua` with no vclu. Responses follow the runtime: an HTTP responder returns
`{ status, json }` or `{ err }`, and a status outside 2xx arrives with
`resp.err = "HTTP <status>"`.

```bash
lua plugins/musiccast/test.lua
```

The harness is plain Lua with `setmetatable`, so check in the test that the
plugin does not use it and that methods sit on the instance
(`rawget(obj, "on")`). See `plugins/musiccast/test.lua`.

## Creating a New Plugin

1. Copy `plugins/musiccast/` for a device (factory), or `plugins/example/`
   for a single service configured from the panel; `plugins/tasmota/` for a device
   factory with a wizard (discovery, expose, binding, a dashboard)
2. Edit `plugin.json` (id, name; `config` only for the singleton kind). The id
   is the short one, the same as in `plugins.json` (`musiccast`, not
   `@vclu/musiccast`); the runtime adds the namespace for `Plugin.getPlugin`
3. Write logic in `init.lua`
4. Add `test.lua` on `test/harness.lua` and run it
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

2. Add repository in vclu Web UI: **Settings > Plugin Repositories**
