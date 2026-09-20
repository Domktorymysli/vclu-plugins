--- Minimal stand-in for the vCLU plugin runtime.
--
-- Plugins are plain Lua that leans on globals the runtime injects (Plugin,
-- Modbus, Logger ...). This module installs believable stubs for those globals
-- and records what the plugin did with them, so a plugin can be exercised with
-- a bare `lua` and no vCLU running.
--
-- Usage:
--   local harness = dofile("test/harness.lua")
--   local env = harness.install()
--   local plugin = dofile("plugins/<name>/init.lua")
--   harness.check("something happened", env.sensors["x"] ~= nil)
--   os.exit(harness.report())

local M = {}

local passed, failed = 0, 0

--- Assert a condition and print a line for it.
function M.check(name, cond)
    if cond then
        passed = passed + 1
        print("  ok   " .. name)
    else
        failed = failed + 1
        print("  FAIL " .. name)
    end
    return cond and true or false
end

--- Print the tally. Returns the exit code to hand to os.exit.
function M.report()
    print("")
    if failed == 0 then
        print(string.format("%d passed", passed))
        return 0
    end
    print(string.format("%d passed, %d FAILED", passed, failed))
    return 1
end

--- Install the fake runtime globals.
-- @param opts table optional { registers = function(reqOpts) -> table }
-- @return table recorder with sensors, pollers, objects, emits, log, clobbered
function M.install(opts)
    opts = opts or {}

    local env = {
        sensors = {},   -- sensor id -> { get, emit }
        pollers = {},   -- poller name -> { started, onTick }
        objects = {},   -- object path -> data
        emits = {},     -- ordered list of { event, data, opts }
        log = {},       -- ordered list of "level: message"
        clobbered = {}  -- sensor ids registered more than once
    }

    -- Registers default to zeros; a test can hand back real values instead.
    local registersFor = opts.registers or function(reqOpts)
        local regs = {}
        for i = 1, (reqOpts.qty or 1) do regs[i] = 0 end
        return regs
    end

    _G.Modbus = {
        READ_COILS = 1, READ_DISCRETE = 2, READ_HOLDING = 3,
        READ_INPUT = 4, WRITE_SINGLE = 6, WRITE_MULTIPLE = 16,
        isAvailable = function() return true end,
        stats = function() return { requests = 0, errors = 0 } end,
        request = function(reqOpts, cb) cb(registersFor(reqOpts), nil) end,
        readInput = function(reqOpts, cb) cb(registersFor(reqOpts), nil) end,
        readHolding = function(reqOpts, cb) cb(registersFor(reqOpts), nil) end,
        writeSingle = function(_, cb) cb({}, nil) end,
        writeMultiple = function(_, cb) cb({}, nil) end,
        toFloat32 = function() return 1.5 end,
        toInt32 = function() return 1 end,
        toUint32 = function() return 1 end,
        toInt16 = function() return 1 end,
        floatAt = function() return 1.5 end
    }

    _G.Logger = {
        info = function(_, m) env.log[#env.log + 1] = "info: " .. tostring(m) end,
        warn = function(_, m) env.log[#env.log + 1] = "warn: " .. tostring(m) end,
        error = function(_, m) env.log[#env.log + 1] = "error: " .. tostring(m) end,
        debug = function() end
    }

    _G.JSON = {
        encode = function() return "{}" end,
        decode = function() return {} end
    }

    local Plugin = {}
    Plugin.__index = Plugin

    function Plugin:new(id, meta)
        return setmetatable({ id = id, shortId = id, meta = meta }, Plugin)
    end

    function Plugin:coerceNumber(v, d) if type(v) == "number" then return v end return d end
    function Plugin:coerceString(v, d) if type(v) == "string" then return v end return d end
    function Plugin:coerceBool(v, d) if type(v) == "boolean" then return v end return d end

    function Plugin:log(level, msg) env.log[#env.log + 1] = level .. ": " .. tostring(msg) end
    function Plugin:logSafe(level, msg) env.log[#env.log + 1] = level .. ": " .. tostring(msg) end

    function Plugin:emit(event, data, emitOpts)
        env.emits[#env.emits + 1] = { event = event, data = data, opts = emitOpts }
        return true
    end

    -- The real runtime keeps one flat sensor namespace and overwrites without
    -- complaint, so a second registration on the same id is recorded here.
    function Plugin:sensor(id, getter)
        if env.sensors[id] then env.clobbered[#env.clobbered + 1] = id end
        env.sensors[id] = {
            _getter = getter,
            get = function() return getter() end,
            emit = function() end,
            on = function() end
        }
        return env.sensors[id]
    end

    function Plugin:get(id) return env.sensors[id] end

    function Plugin:upsertObject(path, data) env.objects[path] = data end

    function Plugin:updateObject(path, patch)
        env.objects[path] = env.objects[path] or {}
        for k, v in pairs(patch) do env.objects[path][k] = v end
        return true
    end

    function Plugin:getObject(path) return env.objects[path] end

    function Plugin:poller(name, pollerOpts)
        env.pollers[name] = { started = false, onTick = pollerOpts.onTick, onError = pollerOpts.onError }
        local p = env.pollers[name]
        return {
            start = function() p.started = true end,
            stop = function() p.started = false end,
            poll = function() if p.onTick then p.onTick(function() end) end end,
            stats = function() return {} end
        }
    end

    function Plugin:onInit(cb) self._init = cb end
    function Plugin:onCleanup(cb) self._cleanup = cb end

    _G.Plugin = Plugin

    --- Run one poller cycle synchronously.
    function env.tick(name)
        local p = env.pollers[name]
        if not p or not p.onTick then return false end
        p.onTick(function() end)
        return true
    end

    --- Every emit recorded for one event name.
    function env.emitsOf(event)
        local out = {}
        for _, e in ipairs(env.emits) do
            if e.event == event then out[#out + 1] = e end
        end
        return out
    end

    function env.clearEmits() env.emits = {} end

    return env
end

return M
