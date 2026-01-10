--- InfluxDB Metrics Plugin for vCLU
-- Send metrics to InfluxDB, Telegraf, VictoriaMetrics or any line-protocol compatible endpoint.
--
-- @module plugins.influx-metrics
--
-- ## Usage
--
-- ```lua
-- local metrics = require("influx-metrics")
--
-- -- Create collector with config
-- local m = metrics:create({
--     url = "http://influxdb:8086/write?db=home",
--     -- or for InfluxDB 2.x:
--     -- url = "http://influxdb:8086/api/v2/write?org=home&bucket=sensors",
--     -- token = "my-token",
--     interval = 60,        -- flush interval (seconds)
--     batchSize = 100,      -- max points before flush
--     tags = {              -- global tags added to all metrics
--         host = "vclu",
--         location = "home"
--     }
-- })
--
-- -- Send metrics
-- m:gauge("temperature", 22.5, { room = "salon" })
-- m:gauge("humidity", 45, { room = "salon" })
-- m:counter("switch_count", 1, { device = "lamp1" })
--
-- -- Manual flush
-- m:flush()
--
-- -- Stop collector
-- m:stop()
-- ```

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local plugin = Plugin:new("influx-metrics", {
    name = "InfluxDB Metrics",
    version = "1.1.0",
    description = "Send metrics to InfluxDB/Telegraf/VictoriaMetrics"
})

--------------------------------------------------------------------------------
-- METRIC COLLECTOR CLASS
--------------------------------------------------------------------------------

local MetricCollector = {}
MetricCollector.__index = MetricCollector

--- Create new metric collector
-- @param config table Configuration
-- @return MetricCollector
function MetricCollector:new(config)
    local c = {
        url = config.url,
        token = config.token,
        interval = (config.interval or 60) * 1000,
        batchSize = config.batchSize or 100,
        maxBuffer = config.maxBuffer or 10000,
        timeout = (config.timeout or 10) * 1000,
        globalTags = config.tags or {},
        precision = config.precision or "s",  -- s, ms, us, ns

        -- Internal state
        _buffer = {},
        _timer = nil,
        _sending = false,
        _stats = {
            sent = 0,
            failed = 0,
            dropped = 0,
            lastFlush = 0,
            lastError = nil
        }
    }
    setmetatable(c, self)

    -- Start flush timer
    if c.interval > 0 then
        c._timer = plugin:setInterval(c.interval, function()
            c:flush()
        end)
    end

    plugin:log("info", string.format("Collector created: url=%s, interval=%ds, batch=%d, maxBuffer=%d",
        c.url, c.interval / 1000, c.batchSize, c.maxBuffer))

    return c
end

--- Validate and slugify measurement/tag/field key
-- Only allows: a-z, A-Z, 0-9, underscore
-- @param key string Key to validate
-- @return string|nil Slugified key or nil if invalid
local function slugifyKey(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    -- Replace invalid chars with underscore, collapse multiple
    local slug = key:gsub("[^%w_]", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
    if slug == "" then
        return nil
    end
    return slug
end

--- Escape tag/field key for line protocol
-- @param key string Key
-- @return string Escaped key
local function escapeKey(key)
    return key:gsub(",", "\\,"):gsub("=", "\\="):gsub(" ", "\\ ")
end

--- Escape tag value for line protocol
-- @param value string Value
-- @return string Escaped value
local function escapeTagValue(value)
    return tostring(value):gsub(",", "\\,"):gsub("=", "\\="):gsub(" ", "\\ ")
end

--- Format tags for line protocol (sorted by key)
-- @param tags table Tag key-value pairs
-- @return string Formatted tags (,key=value,key2=value2)
local function formatTags(tags)
    if not tags or next(tags) == nil then
        return ""
    end

    local parts = {}
    local keys = {}
    for k in pairs(tags) do
        local slug = slugifyKey(k)
        if slug then table.insert(keys, { orig = k, slug = slug }) end
    end
    table.sort(keys, function(a, b) return a.slug < b.slug end)

    for _, kv in ipairs(keys) do
        local v = tags[kv.orig]
        if v ~= nil then
            table.insert(parts, escapeKey(kv.slug) .. "=" .. escapeTagValue(v))
        end
    end

    if #parts == 0 then return "" end
    return "," .. table.concat(parts, ",")
end

--- Format field value for line protocol
-- @param value any Field value
-- @return string Formatted value
local function formatValue(value)
    local t = type(value)
    if t == "number" then
        -- Check if integer
        if value == math.floor(value) and math.abs(value) < 2^53 then
            return tostring(value) .. "i"
        end
        return tostring(value)
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "string" then
        -- Escape quotes and backslashes
        local escaped = value:gsub('\\', '\\\\'):gsub('"', '\\"')
        return '"' .. escaped .. '"'
    end
    return tostring(value)
end

--- Add metric to buffer
-- @param measurement string Metric name
-- @param fields table Field values (or single number for "value" field)
-- @param tags table Optional tags
-- @param timestamp number Optional timestamp (unix seconds)
function MetricCollector:write(measurement, fields, tags, timestamp)
    -- Validate and slugify measurement name
    local measSlug = slugifyKey(measurement)
    if not measSlug then
        plugin:log("warn", "Invalid measurement name: " .. tostring(measurement))
        return
    end

    -- Handle simple case: write("temp", 22.5)
    if type(fields) == "number" or type(fields) == "boolean" then
        fields = { value = fields }
    end

    -- Merge global tags with metric tags
    local allTags = {}
    for k, v in pairs(self.globalTags) do allTags[k] = v end
    if tags then
        for k, v in pairs(tags) do allTags[k] = v end
    end

    -- Build line protocol
    local line = measSlug .. formatTags(allTags)

    -- Add fields (sorted by key)
    local fieldParts = {}
    local fieldKeys = {}
    for k in pairs(fields) do
        local slug = slugifyKey(k)
        if slug then table.insert(fieldKeys, { orig = k, slug = slug }) end
    end
    table.sort(fieldKeys, function(a, b) return a.slug < b.slug end)

    for _, kv in ipairs(fieldKeys) do
        local v = fields[kv.orig]
        if v ~= nil then
            table.insert(fieldParts, escapeKey(kv.slug) .. "=" .. formatValue(v))
        end
    end

    if #fieldParts == 0 then
        plugin:log("warn", "No valid fields for measurement: " .. measSlug)
        return
    end

    line = line .. " " .. table.concat(fieldParts, ",")

    -- Add timestamp
    if timestamp then
        if self.precision == "ms" then
            line = line .. " " .. tostring(math.floor(timestamp * 1000))
        elseif self.precision == "us" then
            line = line .. " " .. tostring(math.floor(timestamp * 1000000))
        elseif self.precision == "ns" then
            line = line .. " " .. tostring(math.floor(timestamp * 1000000000))
        else
            line = line .. " " .. tostring(math.floor(timestamp))
        end
    end

    -- Check buffer limit
    if #self._buffer >= self.maxBuffer then
        self._stats.dropped = self._stats.dropped + 1
        plugin:log("warn", "Buffer full, dropping metric: " .. measSlug)
        return
    end

    table.insert(self._buffer, line)

    -- Auto-flush if batch full
    if #self._buffer >= self.batchSize then
        self:flush()
    end
end

--- Write gauge metric (current value)
-- @param name string Metric name
-- @param value number Value
-- @param tags table Optional tags
function MetricCollector:gauge(name, value, tags)
    self:write(name, value, tags)
end

--- Write counter metric (incrementing value)
-- @param name string Metric name
-- @param value number Increment value (default 1)
-- @param tags table Optional tags
function MetricCollector:counter(name, value, tags)
    self:write(name, value or 1, tags)
end

--- Write multiple fields as single metric
-- @param name string Metric name
-- @param fields table Field key-value pairs
-- @param tags table Optional tags
function MetricCollector:fields(name, fields, tags)
    self:write(name, fields, tags)
end

--- Flush buffer to endpoint
function MetricCollector:flush()
    if #self._buffer == 0 then
        return
    end

    -- Prevent concurrent flushes
    if self._sending then
        return
    end

    self._sending = true
    local lines = self._buffer
    self._buffer = {}

    local body = table.concat(lines, "\n")
    local headers = {
        ["Content-Type"] = "text/plain"
    }

    -- Add auth token if configured
    if self.token then
        headers["Authorization"] = "Token " .. self.token
    end

    plugin:httpRequest({
        method = "POST",
        url = self.url,
        body = body,
        headers = headers,
        timeout = self.timeout
    }, function(resp)
        self._sending = false

        if resp.err then
            self._stats.failed = self._stats.failed + #lines
            self._stats.lastError = resp.err
            plugin:log("error", "Flush failed: " .. tostring(resp.err))
            return
        end

        if resp.status >= 200 and resp.status < 300 then
            self._stats.sent = self._stats.sent + #lines
            self._stats.lastFlush = os.time()
            plugin:log("debug", "Flushed " .. #lines .. " metrics")
        else
            self._stats.failed = self._stats.failed + #lines
            self._stats.lastError = "HTTP " .. tostring(resp.status)
            plugin:log("error", "Flush failed: HTTP " .. tostring(resp.status))
        end
    end)
end

--- Get collector stats
-- @return table Stats
function MetricCollector:stats()
    return {
        buffered = #self._buffer,
        sent = self._stats.sent,
        failed = self._stats.failed,
        dropped = self._stats.dropped,
        lastFlush = self._stats.lastFlush,
        lastError = self._stats.lastError
    }
end

--- Stop collector
function MetricCollector:stop()
    if self._timer then
        plugin:clearTimer(self._timer)
        self._timer = nil
    end
    -- Final flush
    self:flush()
    plugin:log("info", "Collector stopped")
end

--------------------------------------------------------------------------------
-- PLUGIN STATE
--------------------------------------------------------------------------------

local collectors = {}

--------------------------------------------------------------------------------
-- PLUGIN LIFECYCLE
--------------------------------------------------------------------------------

plugin:onInit(function(config)
    plugin:log("info", "InfluxDB Metrics plugin loaded")
end)

plugin:onCleanup(function()
    -- Stop all collectors
    for id, collector in pairs(collectors) do
        collector:stop()
    end
    collectors = {}
    plugin:log("info", "All collectors stopped")
end)

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--- Create new metric collector
-- @param config table Configuration
-- @param id string Optional collector ID (for management)
-- @return MetricCollector
function plugin:create(config, id)
    if not config.url then
        plugin:log("error", "url is required")
        return nil
    end

    local collector = MetricCollector:new(config)

    if id then
        collectors[id] = collector
    end

    return collector
end

--- Get collector by ID
-- @param id string Collector ID
-- @return MetricCollector|nil
function plugin:get(id)
    return collectors[id]
end

--- List all collector IDs
-- @return table Array of IDs
function plugin:list()
    local ids = {}
    for id in pairs(collectors) do
        table.insert(ids, id)
    end
    return ids
end

--- Stop and remove collector
-- @param id string Collector ID
function plugin:remove(id)
    local collector = collectors[id]
    if collector then
        collector:stop()
        collectors[id] = nil
    end
end

return plugin
