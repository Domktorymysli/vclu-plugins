# Ceny energii RCE (PSE)

Fabryka obiektów z rynkową ceną energii (RCE) z publicznego API PSE. Ceny są co
15 minut, na dziś i na jutro. PSE publikuje jutrzejsze około 14:00. Nie trzeba
klucza ani konta.

RCE to cena, po której w net-billingu liczy się energia oddana z fotowoltaiki:
mówi, ile jest warta nadwyżka w danym kwadransie. **Nie jest ceną zakupu** z
typowej umowy. Za energię pobraną płacisz według swojej taryfy (G11, G12,
dynamicznej) plus dystrybucję, opłaty i podatki, a ujemna RCE nie oznacza, że
ktoś zapłaci Ci za pobór. RCE pokazuje za to, jak zmienia się cena na rynku w
ciągu doby, więc przydaje się do decyzji, kiedy nadwyżkę lepiej zatrzymać w domu
niż oddać.

Sprawdzenie, czy API odpowiada:

```
curl "https://api.raporty.pse.pl/api/rce-pln?\$filter=business_date%20eq%20'2026-11-02'"
```

## Użycie

```lua
local rce = Plugin.getPlugin("@vclu/pse-rce")

local ceny = rce:create({ id = "rce" })

print(ceny:now())          -- RCE teraz w zł/kWh
print(ceny:rce())          -- to samo w zł/MWh, tak jak podaje PSE

-- godzina "HH:MM" w strefie z datetime.setTimezone
local function godz(ts)
    return datetime.format(datetime.fromTimestamp(ts), "15:04")
end

-- 3 godziny z najniższą RCE od teraz; zaraz po instalacji cen
-- jeszcze nie ma i cheapest() daje nil, stąd "or {}"
for i, h in ipairs(ceny:cheapest(3) or {}) do
    print(godz(h.from), h.price)
end
```

`from` i `to` to znaczniki czasu (sekundy), jak `os.time()`. Do wyświetlenia
użyj `datetime.format`, jak wyżej. Czas polski pokaże tylko wtedy, gdy na początku
`modules/init.lua` jest `datetime.setTimezone("Europe/Warsaw")`; bez tego, tak jak
`os.date`, pokazuje czas serwera (zwykle UTC). Sama wtyczka liczy czas polski
niezależnie od strefy serwera.

## Własny wzór ceny

Bez opcji `now()` i `price()` zwracają RCE w zł/kWh. Gdy Twoja umowa liczy coś
od ceny rynkowej, możesz przeliczyć ją własnym wzorem:

```lua
local ceny = rce:create({
    id = "rce",
    multiplier = 1.0,  -- mnożnik RCE
    extra = 0.0,       -- stała dopłata w zł/kWh
    vat = 0.0,         -- VAT jako ułamek, np. 0.23
})
```

Cena = (RCE / 1000 × `multiplier` + `extra`) × (1 + `vat`). Współczynniki weź z
umowy. To nadal nie jest cena zakupu w G11 ani G12: tam cena nie zależy od RCE.

## Najtańsze i najdroższe godziny

```lua
-- 3 godziny z najniższą RCE od teraz, w kolejności czasu
ceny:cheapest(3)

-- 2 godziny pod rząd z najniższą RCE (np. kiedy pralka ma
-- najlepiej zużyć nadwyżkę zamiast oddać ją do sieci)
ceny:cheapest(2, { block = true })

-- godzina z najwyższą RCE od teraz (po ~14:00 także jutro)
ceny:expensive(1)
```

Każda godzina to `{ from, to, rce, price }`: średnia z czterech kwadransów.
`from` i `to` w `opts` zawężają wybór do okna (znaczniki czasu); bez nich liczą
się wszystkie znane godziny od teraz.
Gdy znanych godzin jest mniej niż `n`, wynik to `nil`. „Od teraz” obejmuje
godzinę, która właśnie trwa, także o :59.

`isCheap()` i `isExpensive()` mówią, czy bieżąca godzina jest wśród `cheapHours`
najtańszych (albo `expensiveHours` najdroższych) godzin swojej doby według RCE.
Domyślnie po 4. „Tania” znaczy tu: nadwyżka oddana w tej godzinie jest warta
najmniej, a nie: prąd z sieci kosztuje najmniej.

## Zdarzenia

```lua
-- przyszły ceny na kolejny dzień (zwykle około 14:00 na jutro)
ceny:on("prices", function(date, hours)
    print("Ceny na " .. date .. ": " .. #hours .. " godzin")
end)

-- zaczęła się jedna z cheapHours godzin z najniższą RCE: nadwyżka
-- oddana teraz jest warta najmniej, lepiej ją zużyć w domu
ceny:on("cheap", function(h) end)

-- zaczęła się jedna z expensiveHours najdroższych godzin doby
ceny:on("expensive", function(h) end)

-- cena się zmieniła; sprawdzane co kwadrans, ta sama cena
-- nie wywołuje zdarzenia
ceny:on("price", function(price) end)
```

`on()` zwraca funkcję, która wyrejestrowuje callback. Pierwsza godzina po starcie
i po reloadzie nie wywołuje `cheap` ani `expensive`, bo nie wiadomo, czy już nie
zadziałała.

## RCE w Home Assistant i na wykresie

Wtyczka niczego nie wystawia sama. RCE teraz jest w sensorze `ceny:sensor()`.
Do Home Assistant i na wykres przez `metric()` wystawiasz ją w swoim module:

```lua
local cena = VirtualNumber:new("rce_teraz", { unit = "zł/kWh" })
ceny:on("price", function(p) cena:setValue(p) end)
-- pierwsza cena mogła przyjść już w create(), przed on();
-- bez ceny nie wysyłamy nic, żeby HA nie dostał zera
if ceny:now() then cena:setValue(ceny:now()) end
expose(cena, "number", {
    name = "RCE", area = "Energia", unit = "zł/kWh",
    readonly = true, path = "energia:rce",
})

metric("energia:rce", function() return ceny:now() end, {
    unit = "zł/kWh",
})
```

Tabela cen na jutro na dashboardzie:

```lua
local dash = Dashboard.new("rce"):name("RCE"):icon("lightning-charge")

local function jutro()
    local rows = {}
    for i, h in ipairs(ceny:hours("tomorrow")) do
        rows[i] = { godzina = godz(h.from), cena = h.price }
    end
    return rows
end

dash:section("RCE", "lightning-charge")
    :table("jutro", "Jutro", jutro, { columns = {
        { key = "godzina", label = "Godzina" },
        { key = "cena", label = "Cena", unit = "zł/kWh", decimals = 2 },
    } })

dash:build()
```

## API

| Metoda | Opis |
|---|---|
| `now()`, `price(at)` | RCE w zł/kWh teraz albo w chwili `at` (przeliczona wzorem, jeśli go podasz); `nil`, gdy nieznana |
| `rce(at)` | RCE w zł/MWh, jak podaje PSE |
| `slots(day)`, `hours(day)` | kwadranse albo godziny doby: `"today"`, `"tomorrow"` albo `"YYYY-MM-DD"` |
| `cheapest(n, opts)`, `expensive(n, opts)` | n najtańszych/najdroższych godzin; `opts`: `from`, `to`, `block` |
| `isCheap(at)`, `isExpensive(at)` | czy godzina jest wśród najtańszych/najdroższych swojej doby |
| `hasTomorrow()` | czy są już ceny na jutro |
| `on(event, fn)` | `prices`, `price`, `cheap`, `expensive`; zwraca funkcję wyrejestrowania |
| `sensor()` | sensor z ceną teraz |
| `toPrice(rce)` | przelicza RCE w zł/MWh na zł/kWh wzorem z `create` |
| `refresh()` | pobiera od razu doby, których brakuje (dziś, od 13:00 też jutro); te, które już są, zostają |
| `getId()`, `getState()` | identyfikator i stan |

Opcje `create`:

| Opcja | Domyślnie | Opis |
|---|---|---|
| `id` | `"rce"` | identyfikator; sensor ma id `<id>_price` |
| `extra` | `0` | dopłata netto w zł/kWh |
| `vat` | `0` | VAT jako ułamek, np. `0.23` |
| `multiplier` | `1` | mnożnik RCE |
| `cheapHours`, `expensiveHours` | `4` | ile godzin doby liczy się jako tanie/drogie |
| `polling` | `true` | `false`: bez pobierania (testy) |

## Jak to działa

- Co minutę wtyczka sprawdza, czy ma ceny na dziś, a od 13:00 także na jutro.
  Brakującą dobę pobiera jeszcze raz najwcześniej po 10 minutach, aż przyjdzie.
- Ceny są w KV wtyczki, więc po reloadzie i restarcie są od razu, bez czekania na PSE.
  Trzyma dziś, jutro i dwie poprzednie doby.
- Doby ze zmianą czasu mają 23 albo 25 godzin (92 albo 100 kwadransów); godziny
  są liczone według polskiego czasu, niezależnie od strefy serwera.
- Ceny bywają ujemne (dużo słońca i wiatru). `cheapest` je uwzględnia.

`getState()`:

| Pole | Typ | Opis |
|---|---|---|
| `id` | string | z `create` |
| `price`, `rce` | number | cena teraz (zł/kWh) i RCE (zł/MWh); `nil`, gdy nieznane |
| `days` | table | doby z cenami, `"YYYY-MM-DD"` |
| `tomorrow` | boolean | są ceny na jutro |
| `cheap`, `expensive` | boolean | jak `isCheap()`, `isExpensive()` |
| `lastError` | string | ostatni błąd albo `nil` |

Testy: `lua plugins/pse-rce/test.lua`.
