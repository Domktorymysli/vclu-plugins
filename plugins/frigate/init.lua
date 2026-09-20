--- Frigate NVR Plugin for vCLU
-- Integration with Frigate NVR for object detection events and camera monitoring.
-- Supports two event modes: polling (HTTP) and mqtt (real-time).
--
-- @module plugins.frigate
--
-- ## Expose API Usage
--
-- ```lua
-- local frigate = Plugin.get("@vclu/frigate")
--
-- -- Detection on/off (global)
-- expose(frigate:get("detection"), "boolean", {
--     name = "Detekcja Frigate",
--     area = "Monitoring"
-- })
--
-- -- Camera count
-- expose(frigate:get("cameraCount"), "number", {
--     name = "Aktywne kamery",
--     area = "Monitoring"
-- })
--
-- -- Total detections counter
-- expose(frigate:get("totalDetections"), "number", {
--     name = "Detekcje",
--     area = "Monitoring"
-- })
-- ```
--
-- ## Available Sensors & Controls
--
-- | ID              | Type    | Description                     |
-- |-----------------|---------|----------------------------------|
-- | detection       | control | Global detection enable/disable  |
-- | cameraCount     | sensor  | Number of active cameras         |
-- | totalDetections | sensor  | Total detections since start     |

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local frigate = Plugin:new("frigate", {
    name = "Frigate NVR",
    version = "2.1.0",
    description = "Frigate NVR integration with object detection events"
})

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local state = {
    ready = false,
    lastUpdate = 0,
    lastError = nil,
    -- Stats
    version = "",
    cameraCount = 0,
    totalDetections = 0,
    detectionEnabled = true,
    -- Cameras
    cameras = {},
    -- Events
    processedEvents = {}
}

local statsPoller = nil
local eventsPoller = nil
local baseUrl = ""
local cameraFilter = nil
local eventMode = "polling"

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function apiRequest(path, callback, method)
    frigate:httpRequest({
        method = method or "GET",
        url = baseUrl .. path,
        timeout = 10000,
        parseJson = "always"
    }, function(resp)
        if resp.err then
            callback(nil, resp.err)
            return
        end
        if resp.status ~= 200 then
            callback(nil, "HTTP " .. tostring(resp.status))
            return
        end
        callback(resp.json or resp.body, nil)
    end)
end

local function shouldTrackCamera(name)
    if not cameraFilter then return true end
    for _, cam in ipairs(cameraFilter) do
        if cam == name then return true end
    end
    return false
end

local function parseCameraStats(name, cam)
    return {
        name = name,
        fps = cam.camera_fps or 0,
        detectionFps = cam.detection_fps or 0,
        detectionEnabled = cam.detection_enabled or false,
        processFps = cam.process_fps or 0,
        skippedFps = cam.skipped_fps or 0,
        audioDbs = cam.audio_dBFS or 0
    }
end

local function parseDetectors(detectors)
    local result = {}
    if not detectors then return result end
    for name, det in pairs(detectors) do
        result[name] = {
            inferenceSpeed = det.inference_speed or 0,
            pid = det.pid or 0
        }
    end
    return result
end

local function notifySensor(id)
    local sensor = frigate:get(id)
    if sensor and sensor._notify then sensor:_notify() end
end

local function cleanupProcessedEvents()
    local count = 0
    for _ in pairs(state.processedEvents) do count = count + 1 end
    if count > 500 then
        state.processedEvents = {}
        frigate:log("debug", "Cleared processed events cache")
    end
end

--- Process a single detection event (shared by both modes)
local function processDetection(eventId, camera, label, score, zones, startTime, endTime)
    if state.processedEvents[eventId] then return false end
    if not shouldTrackCamera(camera) then return false end
    if score < 0.5 then return false end

    state.processedEvents[eventId] = true
    state.totalDetections = state.totalDetections + 1

    frigate:log("info", string.format(
        "Detection: %s on %s (score=%.0f%%, zones=%s)",
        label, camera, score * 100,
        table.concat(zones, ",")
    ))

    frigate:emit("frigate:detection", {
        id = eventId,
        camera = camera,
        label = label,
        score = score,
        zones = zones,
        startTime = startTime,
        endTime = endTime,
        thumbnail = baseUrl .. "/api/events/" .. eventId .. "/thumbnail.jpg",
        snapshot = baseUrl .. "/api/events/" .. eventId .. "/snapshot.jpg"
    })

    notifySensor("totalDetections")
    cleanupProcessedEvents()
    return true
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

frigate:onInit(function(config)
    if not config.host or config.host == "" then
        frigate:log("error", "host is required")
        return
    end

    local host = config.host:gsub("^https?://", ""):gsub("/$", "")
    local port = frigate:coerceNumber(config.port, 5000)
    local interval = frigate:coerceNumber(config.interval, 30)
    local eventInterval = frigate:coerceNumber(config.eventInterval, 10)
    eventMode = frigate:coerceString(config.mode, "polling")

    baseUrl = "http://" .. host .. ":" .. port

    -- Parse camera filter
    local camerasStr = frigate:coerceString(config.cameras, "")
    if camerasStr ~= "" then
        cameraFilter = {}
        for cam in string.gmatch(camerasStr, "([^,]+)") do
            local trimmed = cam:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                table.insert(cameraFilter, trimmed)
            end
        end
    end

    frigate:log("info", string.format("Initializing: url=%s, mode=%s, interval=%ds",
        baseUrl, eventMode, interval))

    -- Create initial registry object
    frigate:upsertObject("stats", {
        ready = false,
        version = "",
        cameras = {},
        detectors = {},
        cameraCount = 0,
        totalDetections = 0,
        lastUpdate = 0
    })

    ---------------------------------------------------------------------------
    -- SENSORS & CONTROLS (for expose API)
    ---------------------------------------------------------------------------

    frigate:sensor("cameraCount", function() return state.cameraCount end)
    frigate:sensor("totalDetections", function() return state.totalDetections end)

    frigate:control("detection",
        function() return state.detectionEnabled end,
        function(enabled)
            frigate:setDetection(enabled)
        end
    )

    ---------------------------------------------------------------------------
    -- STATS POLLER (used in both modes)
    ---------------------------------------------------------------------------

    statsPoller = frigate:poller("stats", {
        interval = interval * 1000,
        immediate = true,
        timeout = 15000,
        retry = { maxAttempts = 2, backoff = 3000 },

        onTick = function(done)
            apiRequest("/api/stats", function(data, err)
                if err then
                    done(err)
                    return
                end

                if type(data) ~= "table" then
                    done("Invalid stats response")
                    return
                end

                -- Parse version on first successful fetch
                if not state.ready then
                    apiRequest("/api/version", function(ver)
                        if ver then
                            state.version = tostring(ver)
                            frigate:log("info", "Frigate version: " .. state.version)
                        end
                    end)
                end

                -- Parse camera stats
                local cameras = {}
                local activeCameras = 0
                local rawCameras = data.cameras or data
                for name, cam in pairs(rawCameras) do
                    if type(cam) == "table" and cam.camera_fps ~= nil and shouldTrackCamera(name) then
                        cameras[name] = parseCameraStats(name, cam)
                        activeCameras = activeCameras + 1
                    end
                end

                local detectors = parseDetectors(data.detectors)

                -- Update state
                state.ready = true
                state.lastUpdate = os.time()
                state.lastError = nil
                state.cameras = cameras
                state.cameraCount = activeCameras

                -- Update registry
                frigate:updateObject("stats", {
                    ready = true,
                    version = state.version,
                    cameras = cameras,
                    detectors = detectors,
                    cameraCount = activeCameras,
                    totalDetections = state.totalDetections,
                    lastUpdate = state.lastUpdate
                })

                local camsWithFps = 0
                for _, cam in pairs(cameras) do
                    if cam.fps > 0 then camsWithFps = camsWithFps + 1 end
                end

                frigate:log("info", string.format(
                    "Stats: %d cameras (%d active), detections=%d",
                    activeCameras, camsWithFps, state.totalDetections
                ))

                notifySensor("cameraCount")
                notifySensor("totalDetections")
                notifySensor("detection")

                frigate:emit("frigate:updated", {
                    cameraCount = activeCameras,
                    totalDetections = state.totalDetections
                }, { throttle = 30000 })

                done()
            end)
        end,

        onError = function(err, stats)
            state.lastError = err
            frigate:log("error", "Stats fetch failed: " .. tostring(err))
            frigate:emit("frigate:error", { error = err })
        end
    })

    ---------------------------------------------------------------------------
    -- EVENT MODE: POLLING (HTTP)
    ---------------------------------------------------------------------------

    if eventMode == "polling" then
        frigate:log("info", string.format("Events mode: polling (interval=%ds)", eventInterval))

        eventsPoller = frigate:poller("events", {
            interval = eventInterval * 1000,
            immediate = false,
            timeout = 10000,
            retry = { maxAttempts = 1, backoff = 5000 },

            onTick = function(done)
                local after = os.time() - 60
                local url = "/api/events?after=" .. after .. "&limit=20"

                apiRequest(url, function(data, err)
                    if err then
                        done(err)
                        return
                    end

                    if type(data) ~= "table" then
                        done()
                        return
                    end

                    local newEvents = 0
                    for _, event in ipairs(data) do
                        local eventId = event.id
                        if eventId then
                            local camera = event.camera or "unknown"
                            local label = event.label or "unknown"
                            local score = event.top_score or 0
                            local zones = event.zones or {}
                            if processDetection(eventId, camera, label, score, zones,
                                event.start_time, event.end_time) then
                                newEvents = newEvents + 1
                            end
                        end
                    end

                    if newEvents > 0 then
                        frigate:log("info", string.format("Processed %d new events", newEvents))
                    end

                    done()
                end)
            end,

            onError = function(err)
                frigate:log("warn", "Events fetch failed: " .. tostring(err))
            end
        })

        eventsPoller:start()
    end

    ---------------------------------------------------------------------------
    -- EVENT MODE: MQTT (real-time)
    ---------------------------------------------------------------------------

    if eventMode == "mqtt" then
        local topicPrefix = frigate:coerceString(config.mqttPrefix, "frigate")

        frigate:log("info", "Events mode: mqtt (prefix=" .. topicPrefix .. ")")

        -- Subscribe to Frigate event updates
        frigate:mqttSubscribe(topicPrefix .. "/events", function(topic, payload)
            if not payload or payload == "" then return end

            local ok, event = pcall(function()
                return frigate:jsonDecode(payload)
            end)
            if not ok or type(event) ~= "table" then return end

            local data = event.after or event
            local eventId = data.id
            if not eventId then return end

            -- Only process new detections, skip end events
            local eventType = event.type or "new"
            if eventType == "end" then return end

            local camera = data.camera or "unknown"
            local label = data.label or "unknown"
            local score = data.top_score or data.score or 0
            local zones = data.current_zones or data.zones or {}

            processDetection(eventId, camera, label, score, zones,
                data.start_time, data.end_time)
        end)

        -- Subscribe to per-camera person count
        frigate:mqttSubscribe(topicPrefix .. "/+/person", function(topic, payload)
            local camera = topic:match(topicPrefix .. "/([^/]+)/person")
            if camera and shouldTrackCamera(camera) then
                local count = tonumber(payload) or 0
                if count > 0 then
                    frigate:log("debug", string.format(
                        "%s: %d person(s) in frame", camera, count))
                end
            end
        end)
    end

    statsPoller:start()
end)

frigate:onCleanup(function()
    if statsPoller then statsPoller:stop() end
    if eventsPoller then eventsPoller:stop() end
    frigate:log("info", "Frigate plugin stopped")
end)

--------------------------------------------------------------------------------
-- PUBLIC API - GETTERS
--------------------------------------------------------------------------------

function frigate:isReady()
    return state.ready
end

function frigate:getLastError()
    return state.lastError
end

function frigate:getVersion()
    return state.version
end

function frigate:getCameraCount()
    return state.cameraCount
end

function frigate:getTotalDetections()
    return state.totalDetections
end

function frigate:getCameras()
    return state.cameras
end

function frigate:getCamera(name)
    return state.cameras[name]
end

function frigate:getData()
    return {
        ready = state.ready,
        version = state.version,
        cameraCount = state.cameraCount,
        totalDetections = state.totalDetections,
        detectionEnabled = state.detectionEnabled,
        cameras = state.cameras,
        lastUpdate = state.lastUpdate,
        lastError = state.lastError
    }
end

--------------------------------------------------------------------------------
-- PUBLIC API - ACTIONS
--------------------------------------------------------------------------------

--- Enable or disable detection on a specific camera
function frigate:setCameraDetection(camera, enabled)
    local endpoint = enabled and "enable" or "disable"
    local path = "/api/" .. camera .. "/detect/" .. endpoint

    frigate:log("info", string.format("Setting detection %s for %s", endpoint, camera))

    apiRequest(path, function(data, err)
        if err then
            frigate:log("error", "Set detection failed for " .. camera .. ": " .. tostring(err))
            return
        end
        frigate:log("info", string.format("Detection %sd for %s", endpoint, camera))
        if statsPoller then
            frigate:setTimeout(1000, function() statsPoller:poll() end)
        end
    end, "POST")
end

--- Enable or disable detection on all tracked cameras
function frigate:setDetection(enabled)
    state.detectionEnabled = enabled
    for name, _ in pairs(state.cameras) do
        frigate:setCameraDetection(name, enabled)
    end
end

--- Get snapshot URL for a camera (JPEG, refreshable)
--- @param camera string Camera name (e.g. "cam1")
--- @param opts table|nil Options: bbox=true (draw bounding boxes), h=number (height)
function frigate:getSnapshotUrl(camera, opts)
    local url = baseUrl .. "/api/" .. camera .. "/latest.jpg"
    local params = {}
    if opts then
        if opts.bbox then table.insert(params, "bbox=1") end
        if opts.h then table.insert(params, "h=" .. opts.h) end
    end
    if #params > 0 then url = url .. "?" .. table.concat(params, "&") end
    return url
end

--- Get RTSP restream URL (for RTSP players/widgets)
--- @param camera string Camera name
function frigate:getStreamUrl(camera)
    local host = baseUrl:match("http://([^:]+)")
    return "rtsp://" .. host .. ":8554/" .. camera
end

--- Get MSE/WebRTC stream URL (low latency, browser-friendly)
--- @param camera string Camera name
function frigate:getWebStreamUrl(camera)
    local host = baseUrl:match("http://([^:]+)")
    return "http://" .. host .. ":8555/" .. camera
end

--- Get all stream URLs for a camera
--- @param camera string Camera name
--- @param opts table|nil Snapshot options: bbox=true, h=number
function frigate:getCameraUrls(camera, opts)
    local host = baseUrl:match("http://([^:]+)")
    return {
        snapshot = frigate:getSnapshotUrl(camera, opts),
        rtsp = "rtsp://" .. host .. ":8554/" .. camera,
        web = "http://" .. host .. ":8555/" .. camera,
        mjpeg = baseUrl .. "/api/" .. camera .. "/latest.jpg?h=360"
    }
end

--- Get thumbnail URL for an event
function frigate:getThumbnailUrl(eventId)
    return baseUrl .. "/api/events/" .. eventId .. "/thumbnail.jpg"
end

function frigate:refresh()
    if statsPoller then statsPoller:poll() end
end

function frigate:getStats()
    local result = {}
    if statsPoller then result.stats = statsPoller:stats() end
    if eventsPoller then result.events = eventsPoller:stats() end
    return result
end

return frigate
