--- influx-metrics writes numbers as floats, so a field keeps one type.
--
-- Run from the repository root:
--   lua test/influx_fields_test.lua
--
-- InfluxDB fixes a field's type at its first write. A thermometer reading 21.0
-- written as 21i and then 21.5 as a float is a type conflict, and the server
-- rejects the later points. Only counter() writes integers.

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local root = here .. "/.."
local harness = dofile(root .. "/test/harness.lua")
local check = harness.check

local env = harness.install({ http = function() return { ok = true, status = 204, code = 204 } end })
local metrics = dofile(root .. "/plugins/influx-metrics/init.lua")
local m = metrics:create({ url = "http://influx/api/v2/write?org=o&bucket=b", interval = 0 })

m:gauge("temperatura", 21.0, { pomieszczenie = "salon" })
m:gauge("temperatura", 21.5, { pomieszczenie = "salon" })
m:gauge("temperatura", 0/0, { pomieszczenie = "ogrod" })
m:fields("pogoda", { temperatura = 5, wilgotnosc = 80.5 })
m:counter("przelaczenia", 3)
m:flush()

local body = env.http[1] and env.http[1].body or ""
print(body)
check("a whole gauge value is a float", body:find("temperatura,pomieszczenie=salon value=21[%.0]* ") ~= nil
    or body:find("temperatura,pomieszczenie=salon value=21[%.0]*\n") ~= nil
    or body:find("temperatura,pomieszczenie=salon value=21[%.0]*$") ~= nil)
check("no gauge or fields value is an integer", not body:find("temperatura=%d+i") and
    not body:find("value=21i"))
check("a fractional value is a float", body:find("value=21%.5") ~= nil)
check("NaN is not written", not body:find("ogrod"))
check("a counter is an integer", body:find("przelaczenia value=3i") ~= nil)

os.exit(harness.report())
