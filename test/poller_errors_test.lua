--- Every polling plugin reports a failed request as a failure.
--
-- Run from the repository root:
--   lua test/poller_errors_test.lua
--
-- The poller's callback is done(data, err): a single argument is data, so
-- done(err) counts the tick as a success, skips onError, retries and backoff.
-- Each plugin is started with its HTTP answering "connection refused" and every
-- poller tick must end in done(nil, <error text>).

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local root = here .. "/.."
local harness = dofile(root .. "/test/harness.lua")
local check = harness.check

local REFUSED = { ok = false, status = 0, code = 0, err = "connection refused", errCode = "network" }

-- Minimal configuration that makes each plugin start its pollers, and what its
-- HTTP answers: refused, except where a plugin needs one call to succeed first.
local refused = function() return REFUSED end
local plugins = {
    ["salda-recuperator"] = { config = { ip = "127.0.0.1", login = "test", password = "test" } },
    ["solax"] = { config = { host = "127.0.0.1" } },
    ["frigate"] = { config = { host = "127.0.0.1", mode = "polling" } },
    ["supla-power-meter"] = { config = { directUrl = "http://127.0.0.1/direct/1/x/read" } },
    ["time-sync"] = { config = {} },
    ["weather"] = { config = { apiKey = "test" } },
    ["example"] = { config = { apiUrl = "http://127.0.0.1" } },
    -- Telegram starts polling only after getMe succeeds.
    ["telegram"] = {
        config = { botToken = "test" },
        http = function(reqOpts)
            if tostring(reqOpts.url):find("getMe") then
                return { ok = true, status = 200, code = 200, json = { ok = true, result = { username = "bot" } } }
            end
            return REFUSED
        end
    },
}

local names = {}
for name in pairs(plugins) do names[#names + 1] = name end
table.sort(names)

for _, name in ipairs(names) do
    print("== " .. name)
    local env = harness.install({ http = plugins[name].http or refused })
    local ok, plugin = pcall(dofile, root .. "/plugins/" .. name .. "/init.lua")
    check(name .. ": loads", ok and type(plugin) == "table")
    if ok and type(plugin) == "table" and plugin._init then
        plugin.config = plugins[name].config -- the runtime sets it before onInit
        local started, initErr = pcall(plugin._init, plugins[name].config)
        check(name .. ": starts" .. (started and "" or " (" .. tostring(initErr) .. ")"), started)

        local ticked = 0
        for pollerName in pairs(env.pollers) do
            local ran, got = env.tick(pollerName)
            if ran then
                ticked = ticked + 1
                check(name .. "/" .. pollerName .. ": done(nil, err) on a refused request",
                    got ~= nil and got.data == nil and type(got.err) == "string" and got.err ~= "")
            end
        end
        check(name .. ": has a poller to tick", ticked > 0)
    end
end

-- The tasmota switch is a factory; its poller is created per switch.
print("== tasmota-switch")
do
    local env = harness.install({ http = function() return REFUSED end })
    local plugin = dofile(root .. "/plugins/tasmota-switch/init.lua")
    plugin:create({ id = "lamp", name = "Lamp", ip = "127.0.0.1" })
    local ticked = 0
    for pollerName in pairs(env.pollers) do
        local ran, got = env.tick(pollerName)
        if ran then
            ticked = ticked + 1
            check("tasmota-switch/" .. pollerName .. ": done(nil, err) on a refused request",
                got ~= nil and got.data == nil and type(got.err) == "string" and got.err ~= "")
        end
    end
    check("tasmota-switch: has a poller to tick", ticked > 0)
end

os.exit(harness.report())
