--- Tests for the zakupy plugin.
--
-- Run from the repository root:
--   lua plugins/zakupy/test.lua

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

-- as plugin.json declares it
local ITEM = { type = "string", required = true }
local env = harness.install({ dashboards = { lista = "Zakupy" }, actions = {
    add = { params = { item = ITEM } }, remove = { params = { item = ITEM } }, done = { params = { item = ITEM } },
    list = {}, clear_done = {}, clear_all = { confirm = true },
} })
local plugin = dofile(here .. "/init.lua")
plugin._init({})

local function labels()
    local out = {}
    for _, it in ipairs(plugin:items()) do
        out[#out + 1] = it.label .. (it.qty > 1 and ("x" .. it.qty) or "") .. (it.done and "+" or "")
    end
    return table.concat(out, "|")
end

check("no setmetatable", io.open(here .. "/init.lua"):read("a"):find("setmetatable%s*%(") == nil)
check("starts empty", #plugin:items() == 0 and plugin:pending().text == "Lista zakupów jest pusta.")

--------------------------------------------------------------------------------
-- Adding: labels, several at once, quantities, merging
--------------------------------------------------------------------------------

local r = plugin:add("  mleko,  chleb   razowy i masło oraz jajka; ser ")
check("several items in one text", labels() == "mleko|chleb razowy|masło|jajka|ser")
check("the result says what was added", #r.added == 5 and r.text == "Dodano: mleko, chleb razowy, masło, jajka, ser.")
check("ids are distinct strings", plugin:items()[1].id ~= plugin:items()[2].id and type(plugin:items()[1].id) == "string")

r = plugin:add("Mleko")
check("the same item without a quantity is not added again", #plugin:items() == 5 and r.already[1] == "mleko"
    and r.text == "Już na liście: mleko.")
r = plugin:add("MASLO")
check("case and Polish diacritics do not matter", #plugin:items() == 5 and r.already[1] == "masło")
r = plugin:add("3 jajka")
check("with a quantity it grows", labels():find("jajkax4") ~= nil and r.increased[1] == "jajka ×4")

plugin:clearAll()
plugin:add("2 mleka, chleb x3, 2x kefir, woda ×6, 2 kg ziemniaków, 100 serwetek, mleko 3,2%, cukier 2")
check("quantities", labels() == "mlekax2|chlebx3|kefirx2|wodax6|2 kg ziemniaków|100 serwetek|mleko 3,2%|cukier 2")

plugin:clearAll()
plugin:add(string.rep("ż", 150))
check("a label is cut to 100 characters, not mid-letter", plugin:items()[1].label == string.rep("ż", 100))
check("empty text is an error", plugin:add(" , i ") == nil and select(2, plugin:add("")) == "podaj nazwę produktu")
check("not text is an error", plugin:add(nil) == nil)

plugin:clearAll()
local many = {}
for i = 1, 200 do many[i] = "p" .. i end
plugin:add(table.concat(many, ","))
r = plugin:add("p1, nowy")
check("a full list adds nothing more and says so", #plugin:items() == 200 and r.text == "Już na liście: p1. Lista pełna, nie dodano: nowy.")
local _, fullErr = plugin:add("nowy")
check("only new items on a full list is an error", fullErr == "lista jest pełna (200 pozycji)")

--------------------------------------------------------------------------------
-- Remove, done, matching
--------------------------------------------------------------------------------

plugin:clearAll()
plugin:add("mleko, masło, makaron, chleb")
r = plugin:done("Mleko")
check("done marks bought", labels() == "masło|makaron|chleb|mleko+" and r.text == "Kupione: mleko.")
check("bought items are not to buy", plugin:pending().count == 3
    and plugin:pending().text == "Do kupienia (3): masło, makaron, chleb.")
r = plugin:add("mleko")
check("adding a bought item puts it back", labels() == "mleko|masło|makaron|chleb" and r.restored[1] == "mleko")

local ok, err = plugin:remove("ma")
check("an ambiguous prefix is an error", ok == nil and err:find("pasuje do kilku") and #plugin:items() == 4)
r = plugin:remove("chl")
check("a unique prefix matches", r and r.removed[1] == "chleb" and labels() == "mleko|masło|makaron")
r = plugin:done("maslo i makar")
check("several at once, without diacritics", r and labels() == "mleko|masło+|makaron+")
ok, err = plugin:done("mleko i kawa")
check("a name not on the list changes nothing", ok == nil and err == "nie ma „kawa” na liście" and labels() == "mleko|masło+|makaron+")
r = plugin:done("2x mleko")
check("a quantity is ignored when finding", r and labels() == "mleko+|masło+|makaron+")

--------------------------------------------------------------------------------
-- Clear, onChange, persistence
--------------------------------------------------------------------------------

plugin:clearAll()
plugin:add("mleko, chleb, masło")
plugin:done("chleb")
local seen = {}
local off = plugin:onChange(function(items) seen[#seen + 1] = #items end)
check("clearDone removes only bought", plugin:clearDone() == 1 and labels() == "mleko|masło")
check("onChange gets the list", seen[1] == 2)
check("clearDone with nothing bought is quiet", plugin:clearDone() == 0 and #seen == 1)
plugin:add("mleko")
check("nothing changed, no callback", #seen == 1)
off()
plugin:add("kawa")
check("unsubscribed is quiet", #seen == 1)

local mine = plugin:items()
mine[1].label = "zmienione"
check("items() is a copy", plugin:items()[1].label == "mleko")

plugin:done("kawa")
local before = labels()
plugin._cleanup()
env.actions, env.dashboards = {}, {}   -- the runtime drops them with the plugin
plugin = dofile(here .. "/init.lua")
plugin._init({})
check("the list survives a restart", labels() == before)
plugin:add("cukier")
local ids = {}
for _, it in ipairs(plugin:items()) do
    check("no id used twice (" .. it.label .. ")", not ids[it.id])
    ids[it.id] = true
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

env.actions = {}
env.dashboards = {}
plugin._cleanup()
plugin = dofile(here .. "/init.lua")
plugin._init({})
plugin:clearAll()

local names = {}
for n in pairs(env.actions) do names[#names + 1] = n end
table.sort(names)
check("six actions", table.concat(names, ",") == "add,clear_all,clear_done,done,list,remove")

r = env.callAction("add", { item = "mleko i chleb" })
check("add through the action", r and #r.added == 2)
r, err = env.callAction("add", {})
check("add without item is refused", r == nil and err ~= nil)
r, err = env.actions.add.fn({})
check("and by the plugin itself", r == nil and err == "brak parametru item (nazwa produktu)")
r, err = env.actions.add.fn({ item = 5 })
check("a number is not an item", r == nil and err ~= nil)
r, err = env.actions.add.fn({ item = "   " })
check("blank item", r == nil and err ~= nil)

plugin:clearAll()
env.callAction("add", { item = "mleko, chleb i masło" })
r = env.callAction("done", { item = "chleb" })
check("done", r and r.done[1] == "chleb")
r = env.callAction("list")
check("list gives what is left and a sentence", r.count == 2 and r.items[1].label == "mleko"
    and r.text == "Do kupienia (2): mleko, masło.")
r = env.callAction("remove", { item = "MAS" })
check("remove by prefix", r and r.removed[1] == "masło")
r, err = env.callAction("remove", { item = "kawa" })
check("remove of a missing item", r == nil and err:find("kawa"))
r = env.callAction("clear_done")
check("clear_done", r.removed == 1 and labels() == "mleko")
r, err = env.callAction("clear_all", {})
check("clear_all without confirmation is refused", r == nil and err and labels() == "mleko")
r = env.callAction("clear_all", {}, true)
check("clear_all once confirmed", r and r.removed == 1 and #plugin:items() == 0)

--------------------------------------------------------------------------------
-- Dashboard
--------------------------------------------------------------------------------

local d = env.dashboards.zakupy_lista
check("dashboard zakupy_lista built behind login, the manifest's name", d and d.built and d.name == "Zakupy" and d.auth == "session")
check("no app nor PIN from the plugin: the user grants them", d.remote == nil and d.pin == nil)
local list = d.widgets.items
check("one list, adding is its own field", list and list.type == "list" and d.widgets.add == nil)

check("the list's field adds", env.submit("zakupy_lista", "items", "  mleko, 2 jajka ") == true and labels() == "mleko|jajkax2")
ok, err = env.submit("zakupy_lista", "items", "mleko")
check("already on the list is said", ok == false and err == "Już na liście: mleko")
check("list onAdd adds", list.opts.onAdd("chleb") == true and labels() == "mleko|jajkax2|chleb")

local rows = list.getItems()
check("list rows", #rows == 3 and rows[2].label == "jajka ×2" and rows[2].done == false and type(rows[1].id) == "string")
list.opts.onToggle(rows[1].id, true)
check("toggle marks bought", labels() == "jajkax2|chleb|mleko+" and list.getItems()[3].done == true)
list.opts.onToggle(rows[1].id, false)
check("and back", labels() == "mleko|jajkax2|chleb")
list.opts.onDelete(rows[3].id)
check("delete", labels() == "mleko|jajkax2")

check("no separate counter: the list shows it", d.widgets.left == nil)
local clearDone, clearAll = d.widgets.clear_done, d.widgets.clear_all
check("nothing bought: clear_done disabled", clearDone.opts.disabled() == true)
plugin:done("mleko")
check("something bought: clear_done enabled", clearDone.opts.disabled() == false)
clearDone.onTap()
check("Usuń kupione", labels() == "jajkax2")
check("Wyczyść wszystko is held", clearAll.opts.hold == true)
clearAll.onTap()
check("Wyczyść wszystko", #plugin:items() == 0 and clearAll.opts.disabled() == true)

-- the old wizard settings do nothing now: access is the module's :dashboard(id) chain
env.dashboards = {}
env.actions = {}
plugin._cleanup()
plugin = dofile(here .. "/init.lua")
plugin._init({ dashboard = false, dashboardName = "Inna", dashboardAuth = "public", remote = true, roles = "gosia" })
d = env.dashboards.zakupy_lista
check("old settings are ignored", d and d.name == "Zakupy" and d.auth == "session" and d.remote == nil)

-- the builder refuses what is the user's, as vclu does
for what, f in pairs({
    public = function() plugin:dashboard("lista"):auth("public") end,
    remote = function() plugin:dashboard("lista"):remote() end,
    roles = function() plugin:dashboard("lista"):roles("gosia") end,
    pin = function() plugin:dashboard("lista"):pin("1234") end,
    undeclared = function() plugin:dashboard("inna") end,
}) do
    check("a plugin cannot set " .. what, not pcall(f))
end
-- last: after a caught error gopher-lua can lose this file's reassigned locals
plugin:onChange(function() error("boom") end)
plugin:add("herbata")
check("a failing callback is logged, the list still changes", labels():find("herbata") and env.log[#env.log]:find("onChange"))

os.exit(harness.report())
