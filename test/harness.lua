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
-- @param opts table optional { registers = function(reqOpts) -> table,
--                                http = function(reqOpts) -> response,
--                                dashboards = { id = name } as plugin.json "dashboards" declares,
--                                actions = { name = { params, confirm } } as plugin.json "actions" declares }
-- @return table recorder with sensors, pollers, objects, emits, log, clobbered,
--         kv, dashboards, actions
function M.install(opts)
    opts = opts or {}

    local env = {
        sensors = {},   -- sensor id -> { get, emit }
        pollers = {},   -- poller name -> { started, onTick }
        objects = {},   -- object path -> data
        emits = {},     -- ordered list of { event, data, opts }
        log = {},       -- ordered list of "level: message"
        clobbered = {}, -- sensor ids registered more than once
        http = {},      -- ordered list of request option tables
        exposed = {}    -- ordered list of { object, kind, opts } from expose()
    }

    -- HTTP answers with an empty success unless a test says otherwise. A
    -- responder returns { status, json } or { err }; httpRequest fills in the
    -- rest the way the runtime does.
    local httpResponder = opts.http or function() return { status = 200, json = {} } end

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

    -- A control is a sensor with a setter; tests read it through env.sensors.
    function Plugin:control(id, getter, setter)
        local c = self:sensor(id, getter)
        c.set = function(_, v) return setter(v) end
        return c
    end

    -- Plugin key-value store, kept per test run. Values are copied in and out, as the
    -- runtime stores them outside Lua: a table changed after kvSet is not changed in the store.
    env.kv = {}
    local function deepCopy(v)
        if type(v) ~= "table" then return v end
        local t = {}
        for k, x in pairs(v) do t[k] = deepCopy(x) end
        return t
    end
    function Plugin:kvGet(key, default)
        if env.kv[key] == nil then return default end
        return deepCopy(env.kv[key])
    end
    function Plugin:kvSet(key, value) env.kv[key] = deepCopy(value); return true end
    function Plugin:kvDelete(key) env.kv[key] = nil; return true end

    function Plugin:url(base, params)
        local q = {}
        for k, v in pairs(params or {}) do q[#q + 1] = tostring(k) .. "=" .. tostring(v) end
        table.sort(q)
        return tostring(base) .. (#q > 0 and ("?" .. table.concat(q, "&")) or "")
    end

    function Plugin:basicAuth(user, pass) return "Basic " .. tostring(user) .. ":" .. tostring(pass) end
    function Plugin:bearerAuth(token) return "Bearer " .. tostring(token) end

    -- Same contract as PluginHelpers.httpRequest: a status outside 2xx sets
    -- resp.err to "HTTP <status>", and resp.json is parsed only on success.
    function Plugin:httpRequest(reqOpts, cb)
        env.http[#env.http + 1] = reqOpts
        local resp = httpResponder(reqOpts) or {}
        resp.status = resp.status or resp.code or (resp.err and 0 or 200)
        resp.ok = resp.status >= 200 and resp.status < 300
        if not resp.ok then
            resp.err = resp.err or ("HTTP " .. resp.status)
            if (reqOpts.parseJson or "success") == "success" then resp.json = nil end
        end
        if cb then cb(resp) end
        return true
    end

    -- Wizard: secrets from the test, discover and moduleCode kept for the test to call
    env.secrets = {}
    function Plugin:secret(name) return env.secrets[name] end
    function Plugin:discover(fn) self._discover = fn end
    function Plugin:moduleCode(fn) self._moduleCode = fn end

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

    -- Timers wait for env.runTimers(); nothing runs on its own.
    env.timers = {}
    local nextTimer = 0
    function Plugin:setTimeout(ms, fn)
        nextTimer = nextTimer + 1
        env.timers[nextTimer] = { ms = ms, fn = fn }
        return nextTimer
    end
    function Plugin:clearTimer(id) env.timers[id] = nil end

    -- Plugin dashboards: plugin:dashboard(id) is a builder like Dashboard.new, its real id
    -- "<shortId>_<id>". The stub keeps each widget with its callbacks for the test to call.
    -- env.dashboards[realId] = { id, name, icon, auth, poll, built, sections, widgets = { id -> w } }
    -- As in vclu, a plugin keeps a dashboard behind login or a PIN; public, a PIN code, the app
    -- and roles are the user's (dashboardAccess in a module), so the builder refuses them.
    env.dashboards = {}
    local AUTHS = { session = true, pin = true }
    local declared = opts.dashboards
    local function userOnly(what)
        error(":" .. what .. "() is the user's to grant (dashboardAccess in a module), not the plugin's", 3)
    end
    local function newBuilder(realId, name)
        local d = { id = realId, name = name, auth = "session", sections = {}, widgets = {}, order = {}, built = false }
        env.dashboards[realId] = d
        local b = {}
        local function widget(kind, id, fields)
            if not d.section then error(kind .. '("' .. tostring(id) .. '"): call :section() first', 3) end
            if type(id) ~= "string" or id == "" then error(kind .. ": id is a string", 3) end
            if d.widgets[id] then error(kind .. '("' .. id .. '"): duplicate widget id', 3) end
            fields.type, fields.id, fields.section = kind, id, d.section
            fields.opts = fields.opts or {}
            if type(fields.opts) ~= "table" then error(kind .. '("' .. id .. '"): opts must be a table', 3) end
            local h = fields.opts.hold
            if h ~= nil and h ~= false and h ~= true and (type(h) ~= "number" or h < 300 or h > 5000) then
                error(kind .. '("' .. id .. '"): opts.hold must be true, false or 300-5000 ms', 3)
            end
            d.widgets[id] = fields
            d.order[#d.order + 1] = id
            return b
        end
        local function fn(kind, what, f)
            if type(f) ~= "function" then error(kind .. ": " .. what .. " must be a function", 3) end
        end
        function b:name(s) d.name = s return b end
        function b:icon(s) d.icon = s return b end
        function b:auth(s)
            if not AUTHS[s] then error(':auth(): a plugin sets "session" or "pin", got ' .. tostring(s), 2) end
            d.auth = s
            return b
        end
        function b:poll(n) d.poll = n return b end
        function b:pin() userOnly("pin") end
        function b:remote() userOnly("remote") end
        function b:roles() userOnly("roles") end
        function b:columns(n) d.columns = n return b end
        function b:section(name, icon)
            d.sections[#d.sections + 1] = { name = name, icon = icon }
            d.section = name
            return b
        end
        function b:button(id, label, icon, onTap, o)
            fn("button", "onTap", onTap)
            return widget("button", id, { label = label, icon = icon, onTap = onTap, opts = o })
        end
        function b:toggle(id, label, icon, get, onToggle, o)
            return widget("toggle", id, { label = label, icon = icon, getValue = get, onToggle = onToggle, opts = o })
        end
        function b:status(id, label, icon, get, unit, o)
            fn("status", "getValue", get)
            return widget("status", id, { label = label, icon = icon, getValue = get, unit = unit or "", opts = o })
        end
        function b:select(id, label, icon, options, get, onSelect, o)
            return widget("select", id, { label = label, icon = icon, options = options, getValue = get, onSelect = onSelect, opts = o })
        end
        -- onSubmit(text) gets trimmed non-empty text; false/nil, "msg" shows an error
        function b:input(id, label, icon, onSubmit, o)
            fn("input", "onSubmit", onSubmit)
            return widget("input", id, { label = label, icon = icon, onSubmit = onSubmit, opts = o })
        end
        -- getItems() -> { { id, label, done, note? } }; opts onToggle(id, done), onDelete(id), onAdd(text)
        function b:list(id, label, getItems, o)
            fn("list", "getItems", getItems)
            for _, k in ipairs({ "onToggle", "onDelete", "onAdd" }) do
                if o and o[k] ~= nil then fn("list", "opts." .. k, o[k]) end
            end
            return widget("list", id, { label = label, getItems = getItems, opts = o })
        end
        function b:build() d.built = true return d end
        return b
    end
    function Plugin:dashboard(id)
        if type(id) ~= "string" or not id:match("^[a-z0-9_]+$") then error("dashboard(id): id is [a-z0-9_]", 2) end
        if declared and not declared[id] then
            error("dashboard(" .. id .. ') is not declared: declare it in plugin.json "dashboards"', 2)
        end
        local realId = self.shortId:gsub("-", "_") .. "_" .. id
        return newBuilder(realId, declared and declared[id] or realId)
    end

    --- What an input widget does with typed text: trimmed, empty is not sent.
    function env.submit(dashId, widgetId, text)
        local w = env.dashboards[dashId].widgets[widgetId]
        text = tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then return nil end
        -- an input's onSubmit, or the add field of a list
        return (w.onSubmit or w.opts.onAdd)(text)
    end

    -- Actions for agents and voice. plugin.json declares them (opts.actions = { name =
    -- { params = {...}, confirm = true } }) and the plugin gives each its function:
    -- plugin:action(name, fn). env.callAction checks params and confirm as vclu does.
    env.actions = {}
    local PARAM_TYPES = { string = "string", number = "number", boolean = "boolean" }
    function Plugin:action(name, f, extra)
        if type(name) ~= "string" or not name:match("^[a-z][a-z0-9_]*$") then error("action(name): name is [a-z0-9_]", 2) end
        if env.actions[name] then error('action("' .. name .. '"): defined twice', 2) end
        if type(f) ~= "function" or extra ~= nil then
            error('action("' .. name .. '", fn): the description and params are in plugin.json "actions"', 2)
        end
        local spec = (opts.actions or {})[name]
        if not spec then error('action("' .. name .. '") is not declared: declare it in plugin.json "actions"', 2) end
        for pname, p in pairs(spec.params or {}) do
            if type(p) ~= "table" or not PARAM_TYPES[p.type] then
                error('action("' .. name .. '"): param ' .. tostring(pname) .. " = { type }", 2)
            end
        end
        env.actions[name] = { spec = spec, fn = f }
    end

    --- Call an action as an agent would: nil, error for a missing or mistyped param, or
    -- for one plugin.json marks confirm without confirmed.
    function env.callAction(name, params, confirmed)
        local a = env.actions[name]
        if not a then return nil, "no action " .. tostring(name) end
        if a.spec.confirm and confirmed ~= true then return nil, "asks for confirmation" end
        params = params or {}
        for pname, p in pairs(a.spec.params or {}) do
            local v = params[pname]
            if v == nil then
                if p.required then return nil, "missing " .. pname end
            elseif type(v) ~= PARAM_TYPES[p.type] then
                return nil, pname .. " is a " .. p.type
            end
        end
        return a.fn(params)
    end

    function Plugin:onInit(cb) self._init = cb end
    function Plugin:onCleanup(cb) self._cleanup = cb end

    _G.Plugin = Plugin

    _G.expose = function(object, kind, exposeOpts)
        env.exposed[#env.exposed + 1] = { object = object, kind = kind, opts = exposeOpts }
        return object
    end

    _G.HTTP = {
        new = function() return { get = function() end, post = function() end } end
    }

    --- Run one poller cycle synchronously.
    -- Returns true and what the plugin passed to done(data, err), as { n, data, err }.
    function env.tick(name)
        local p = env.pollers[name]
        if not p or not p.onTick then return false end
        local got = nil
        p.onTick(function(...) got = { n = select("#", ...), data = (...), err = select(2, ...) } end)
        return true, got
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

    --- Run every pending timer once, in the order they were set.
    function env.runTimers()
        local ids = {}
        for id in pairs(env.timers) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local t = env.timers[id]
            env.timers[id] = nil
            if t then t.fn() end
        end
        return #ids
    end

    function env.pendingTimers()
        local n = 0
        for _ in pairs(env.timers) do n = n + 1 end
        return n
    end

    return env
end

return M
