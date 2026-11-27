--[[
    Lista zakupów for vclu: a shopping list on a dashboard, for voice and agents, kept in the
    plugin's KV store. Needs no permissions.

    Dashboard /d/zakupy_lista, declared in plugin.json, behind login. Who else opens it (no login,
    a PIN, the vclu app, roles) and its name are the user's: the wizard's Dashboards step writes
    Plugin.getPlugin("@vclu/zakupy"):dashboard("lista"):auth(...) to modules/plugins/vclu__zakupy.lua.
    Actions for agents and voice: add, remove, done, list, clear_done, clear_all.
    From a module:

        local zakupy = Plugin.getPlugin("@vclu/zakupy")
        zakupy:add("mleko, 2 chleby i masło")
        local off = zakupy:onChange(function(items) Logger:info(#items .. " na liście") end)
        for _, it in ipairs(zakupy:items()) do Logger:info(it.label) end
]]

local plugin = Plugin:new("zakupy", {
    name = "Lista zakupów",
    version = "1.0.0",
    description = "A shopping list: dashboard, voice and agent actions"
})
-- vclu 1.12 does not read "requires" in plugin.json: say what is missing instead of failing later
if type(plugin.has) ~= "function" then
    error("@vclu/zakupy needs vclu 1.13 or newer", 0)
end

local MAX_LABEL = 100   -- characters
local MAX_ITEMS = 200
local MAX_QTY = 99

-- Changed in place, never reassigned: gopher-lua can lose a reassigned upvalue after a pcall
local items = {}        -- { id, label, done, qty, addedAt }, in the order they were added
local ids = { next = 1 }
local listeners = {}

local function clear(t)
    for i = #t, 1, -1 do t[i] = nil end
end

--------------------------------------------------------------------------------
-- Text: labels, keys for matching, quantities, several items in one string
--------------------------------------------------------------------------------

-- Cut to n characters without splitting a UTF-8 sequence
local function cut(s, n)
    local chars = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 128 or b >= 192 then
            chars = chars + 1
            if chars > n then return s:sub(1, i - 1) end
        end
    end
    return s
end

local function normalize(s)
    s = tostring(s or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return (cut(s, MAX_LABEL):gsub(" $", ""))
end

local FOLD = {
    ["ą"] = "a", ["ć"] = "c", ["ę"] = "e", ["ł"] = "l", ["ń"] = "n", ["ó"] = "o", ["ś"] = "s", ["ź"] = "z", ["ż"] = "z",
    ["Ą"] = "a", ["Ć"] = "c", ["Ę"] = "e", ["Ł"] = "l", ["Ń"] = "n", ["Ó"] = "o", ["Ś"] = "s", ["Ź"] = "z", ["Ż"] = "z",
}

-- Case and Polish diacritics do not matter when matching: "Masło" is "maslo"
local function key(s)
    return (normalize(s):gsub("[\195\196\197][\128-\191]", FOLD):lower())
end

-- After a number these make it part of the name: "2 kg ziemniaków" is one item
local UNITS = { g = true, dag = true, dkg = true, kg = true, kilo = true, l = true, ml = true,
    litr = true, litry = true, litra = true, litrow = true, procent = true }

-- "2 mleka", "2x mleko", "mleko x2", "mleko ×2" -> label, qty; anything else is qty 1
local function parseQty(text)
    local n, rest = text:match("^(%d+)%s*[xX]%s+(.+)$")
    if not n then n, rest = text:match("^(%d+)%s*\195\151%s*(.+)$") end
    if not n then
        n, rest = text:match("^(%d+)%s+(.+)$")
        if n and UNITS[key(rest:match("^([^%s%.]+)") or "")] then n = nil end
    end
    if not n then
        rest, n = text:match("^(.-)%s+[xX]%s*(%d+)$")
        if not n then rest, n = text:match("^(.-)%s*\195\151%s*(%d+)$") end
    end
    n = tonumber(n)
    if not n or n < 1 or n > MAX_QTY or normalize(rest) == "" then return text, 1, false end
    return normalize(rest), n, true
end

-- "mleko, chleb i masło" -> { "mleko", "chleb", "masło" }; "mleko 3,2%" stays one
local function split(text)
    local s = tostring(text or ""):gsub("(%d),(%d)", "%1\1%2")
    s = (" " .. s .. " "):gsub("%s+[iI]%s+", ","):gsub("%s+[oO]raz%s+", ","):gsub("[;\n]", ",")
    local parts = {}
    for raw in s:gmatch("[^,]+") do
        local part = normalize(raw:gsub("\1", ","))
        if part ~= "" then parts[#parts + 1] = part end
    end
    return parts
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

local function restore()
    clear(items)
    local saved = plugin:kvGet("items", {})
    if type(saved) ~= "table" then saved = {} end
    for _, it in ipairs(saved) do
        if type(it) == "table" and it.id ~= nil and type(it.label) == "string" then
            items[#items + 1] = {
                id = tostring(it.id), label = it.label, done = it.done == true,
                qty = math.floor(tonumber(it.qty) or 1), addedAt = tonumber(it.addedAt) or 0,
            }
        end
    end
    ids.next = math.floor(tonumber(plugin:kvGet("nextId", 1)) or 1)
end

local function copy(it)
    return { id = it.id, label = it.label, done = it.done, qty = it.qty, addedAt = it.addedAt }
end

local function snapshot()
    local out = {}
    for i, it in ipairs(items) do out[i] = copy(it) end
    return out
end

local function changed()
    plugin:kvSet("items", snapshot())
    plugin:kvSet("nextId", ids.next)
    local list = snapshot()
    for _, cb in ipairs(listeners) do
        local ok, err = pcall(cb, list)
        if not ok then plugin:log("warn", "onChange: " .. tostring(err)) end
    end
end

local function byKey(k)
    for _, it in ipairs(items) do
        if key(it.label) == k then return it end
    end
end

local function pendingItems()
    local out = {}
    for _, it in ipairs(items) do
        if not it.done then out[#out + 1] = it end
    end
    return out
end

local function show(it)
    if it.qty > 1 then return it.label .. " ×" .. it.qty end
    return it.label
end

local function names(list)
    local out = {}
    for i, it in ipairs(list) do out[i] = type(it) == "table" and show(it) or it end
    return table.concat(out, ", ")
end

-- An item by name: the same name (case and diacritics aside), else the only one starting with it
local function find(text)
    local k = key(text)
    if k == "" then return nil, "podaj nazwę produktu" end
    local it = byKey(k)
    if it then return it end
    local label, _, hasQty = parseQty(text)
    if hasQty then
        it = byKey(key(label))
        if it then return it end
        k = key(label)
    end
    local hits = {}
    for _, cand in ipairs(items) do
        if key(cand.label):sub(1, #k) == k then hits[#hits + 1] = cand end
    end
    if #hits == 1 then return hits[1] end
    if #hits > 1 then return nil, "„" .. text .. "” pasuje do kilku: " .. names(hits) end
    return nil, "nie ma „" .. text .. "” na liście"
end

-- The parts that are not nil, joined: sentence(a, nil, b)
local function sentence(...)
    local out = {}
    for i = 1, select("#", ...) do
        local p = select(i, ...)
        if p then out[#out + 1] = p end
    end
    return table.concat(out, " ")
end

--- Add one or more items: "mleko, 2 chleby i masło".
-- An item already on the list is not added again: with a quantity ("2 mleka") its quantity
-- grows, without one it stays as it is; a bought item goes back on the list.
-- @return table { added, increased, already, restored (labels), text } or nil, error
function plugin:add(text)
    if type(text) ~= "string" then return nil, "podaj produkty jako tekst" end
    local parts = split(text)
    if #parts == 0 then return nil, "podaj nazwę produktu" end
    local r = { added = {}, increased = {}, already = {}, restored = {} }
    local full = {}
    for _, part in ipairs(parts) do
        local label, qty, hasQty = parseQty(part)
        local it = byKey(key(label))
        if it and it.done then
            it.done, it.qty = false, qty
            r.restored[#r.restored + 1] = show(it)
        elseif it and hasQty then
            it.qty = math.min(MAX_QTY, it.qty + qty)
            r.increased[#r.increased + 1] = show(it)
        elseif it then
            r.already[#r.already + 1] = show(it)
        elseif #items >= MAX_ITEMS then
            full[#full + 1] = label
        else
            it = { id = tostring(ids.next), label = label, done = false, qty = qty, addedAt = os.time() }
            ids.next = ids.next + 1
            items[#items + 1] = it
            r.added[#r.added + 1] = show(it)
        end
    end
    local touched = #r.added + #r.increased + #r.restored
    if touched > 0 then changed() end
    if #full > 0 then
        plugin:log("warn", "list full (" .. MAX_ITEMS .. "), not added: " .. #full)
        if touched == 0 and #r.already == 0 then return nil, "lista jest pełna (" .. MAX_ITEMS .. " pozycji)" end
    end
    r.text = sentence(
        #r.added > 0 and ("Dodano: " .. names(r.added) .. ".") or nil,
        #r.restored > 0 and ("Z powrotem na liście: " .. names(r.restored) .. ".") or nil,
        #r.increased > 0 and ("Więcej: " .. names(r.increased) .. ".") or nil,
        #r.already > 0 and ("Już na liście: " .. names(r.already) .. ".") or nil,
        #full > 0 and ("Lista pełna, nie dodano: " .. names(full) .. ".") or nil
    )
    return r
end

-- Apply fn to each item named in text; stops at the first name that does not match
local function each(text, fn)
    if type(text) ~= "string" then return nil, "podaj nazwę produktu" end
    local parts = split(text)
    if #parts == 0 then return nil, "podaj nazwę produktu" end
    local found = {}
    for _, part in ipairs(parts) do
        local it, err = find(part)
        if not it then return nil, err end
        found[#found + 1] = it
    end
    local labels = {}
    for i, it in ipairs(found) do
        fn(it)
        labels[i] = it.label
    end
    changed()
    return labels
end

--- Take items off the list: "mleko" or "mleko i chleb".
-- @return table { removed, text } or nil, error (nothing is removed then)
function plugin:remove(text)
    local labels, err = each(text, function(it)
        for i, cand in ipairs(items) do
            if cand == it then table.remove(items, i) return end
        end
    end)
    if not labels then return nil, err end
    return { removed = labels, text = "Usunięto: " .. table.concat(labels, ", ") .. "." }
end

--- Mark items as bought.
-- @return table { done, text } or nil, error
function plugin:done(text)
    local labels, err = each(text, function(it) it.done = true end)
    if not labels then return nil, err end
    return { done = labels, text = "Kupione: " .. table.concat(labels, ", ") .. "." }
end

--- Mark one item bought or not, by id (the dashboard)
function plugin:setDone(id, done)
    for _, it in ipairs(items) do
        if it.id == tostring(id) then
            it.done = done and true or false
            changed()
            return true
        end
    end
    return nil, "nie ma pozycji " .. tostring(id)
end

function plugin:removeId(id)
    for i, it in ipairs(items) do
        if it.id == tostring(id) then
            table.remove(items, i)
            changed()
            return true
        end
    end
    return nil, "nie ma pozycji " .. tostring(id)
end

--- Remove the bought items. @return number removed
function plugin:clearDone()
    local kept, n = {}, 0
    for _, it in ipairs(items) do
        if it.done then n = n + 1 else kept[#kept + 1] = it end
    end
    if n > 0 then
        clear(items)
        for i, it in ipairs(kept) do items[i] = it end
        changed()
    end
    return n
end

--- Empty the list. @return number removed
function plugin:clearAll()
    local n = #items
    if n > 0 then
        clear(items)
        changed()
    end
    return n
end

--- Every item, a copy: { id, label, done, qty, addedAt }, not bought first
function plugin:items()
    local out = {}
    for _, it in ipairs(items) do
        if not it.done then out[#out + 1] = copy(it) end
    end
    for _, it in ipairs(items) do
        if it.done then out[#out + 1] = copy(it) end
    end
    return out
end

--- What is left to buy: { items = { {label, qty} }, count, text }
function plugin:pending()
    local list = {}
    for i, it in ipairs(pendingItems()) do list[i] = { label = it.label, qty = it.qty } end
    local text = #list == 0 and "Lista zakupów jest pusta."
        or ("Do kupienia (" .. #list .. "): " .. names(pendingItems()) .. ".")
    return { items = list, count = #list, text = text }
end

--- cb(items) after every change, items as from plugin:items(). Returns a function that unsubscribes.
function plugin:onChange(cb)
    if type(cb) ~= "function" then error("onChange(fn): fn is a function", 2) end
    listeners[#listeners + 1] = cb
    return function()
        for i, c in ipairs(listeners) do
            if c == cb then table.remove(listeners, i) return end
        end
    end
end

--------------------------------------------------------------------------------
-- Actions for agents and voice assistants
--------------------------------------------------------------------------------

-- plugin.json "actions" declares them (descriptions, params, confirm for clear_all);
-- vclu before 1.13 has no actions: the list still works from the dashboard and modules
local function action(name, fn)
    if type(plugin.action) == "function" then plugin:action(name, fn) end
end

local function itemParam(p)
    if type(p) ~= "table" or type(p.item) ~= "string" or normalize(p.item) == "" then
        return nil, "brak parametru item (nazwa produktu)"
    end
    return p.item
end

action("add", function(p)
    local item, err = itemParam(p)
    if not item then return nil, err end
    return plugin:add(item)
end)

action("remove", function(p)
    local item, err = itemParam(p)
    if not item then return nil, err end
    return plugin:remove(item)
end)

action("done", function(p)
    local item, err = itemParam(p)
    if not item then return nil, err end
    return plugin:done(item)
end)

action("list", function()
    return plugin:pending()
end)

action("clear_done", function()
    local n = plugin:clearDone()
    return { removed = n, text = n == 0 and "Nie było kupionych produktów." or ("Usunięto kupione: " .. n .. ".") }
end)

-- "confirm": true in plugin.json: vclu runs it only once the user confirmed
action("clear_all", function()
    local n = plugin:clearAll()
    return { removed = n, text = "Lista zakupów wyczyszczona (" .. n .. ")." }
end)

--------------------------------------------------------------------------------
-- Dashboard
--------------------------------------------------------------------------------

local function addFromDashboard(text)
    local r, err = plugin:add(text)
    if not r then return false, err end
    if #r.added + #r.increased + #r.restored == 0 and #r.already > 0 then
        return false, "Już na liście: " .. names(r.already)
    end
    return true
end

-- The name comes from plugin.json; access beyond login is the user's (Plugin.getPlugin(id):dashboard(id) in a module)
local function buildDashboard()
    if type(plugin.dashboard) ~= "function" then
        plugin:log("warn", "this vclu has no plugin dashboards (1.13 needed)")
        return
    end
    plugin:dashboard("lista"):icon("cart"):auth("session"):poll(5)
        :section("Lista", "cart")
        :list("items", "Do kupienia", function()
            local out = {}
            for i, it in ipairs(plugin:items()) do
                out[i] = { id = it.id, label = show(it), done = it.done }
            end
            return out
        end, {
            icon = "cart",
            placeholder = "mleko, 2 chleby i masło",
            empty = "Lista jest pusta",
            onToggle = function(id, done) plugin:setDone(id, done) end,
            onDelete = function(id) plugin:removeId(id) end,
            onAdd = addFromDashboard,
        })
        :button("clear_done", "Usuń kupione", "check2-all", function() plugin:clearDone() end, {
            disabled = function()
                for _, it in ipairs(items) do
                    if it.done then return false end
                end
                return true
            end,
        })
        :button("clear_all", "Wyczyść wszystko", "trash", function() plugin:clearAll() end, {
            hold = true,
            disabled = function() return #items == 0 end,
        })
        :build()
end

plugin:onInit(function()
    restore()
    buildDashboard()
    plugin:log("info", "list: " .. #pendingItems() .. " to buy, " .. #items .. " in all")
end)

plugin:onCleanup(function()
    clear(listeners)
end)

return plugin
