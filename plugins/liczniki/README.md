# Liczniki

Liczniki odczytywane ręcznie: gaz, woda, podlicznik w garażu, ciepło, prąd z licznika bez
Modbusa. Wpisujesz stan z telefonu (albo mówisz asystentowi „gaz 1234,5”), a plugin pokazuje
odczyty, średnie zużycie dziennie i wykres zużycia miesięcznie z porównaniem do roku wcześniej.
Wszystko jest zapisane w pluginie i przetrwa restart vclu. Plugin nie potrzebuje uprawnień.

Wymaga vclu 1.13. Wykres miesięczny pojawia się od vclu 1.14, wcześniej są odczyty bez wykresu.

## Dashboard

Dashboard jest pod `/d/liczniki_odczyty`, domyślnie tylko dla zalogowanych do panelu. Kto jeszcze
go otwiera (bez logowania w sieci domowej, z PIN-em, w aplikacji vclu, role), ustawiasz Ty w
kreatorze, krok **Dashboardy**, albo kodem w module:

```lua
Plugin.getPlugin("@vclu/liczniki"):dashboard("odczyty"):auth("public")
```

Każdy licznik ma swoją sekcję:

- **Ostatni odczyt** i jego data;
- **Średnio dziennie**: z odczytów z ostatnich 30 dni (albo z dwóch ostatnich);
- **Zużycie miesięcznie**: 12 miesięcy, obok każdego słupka ten sam miesiąc rok wcześniej;
- **Odczyty**: od najnowszego, ze zużyciem od poprzedniego. Pole na dole dopisuje odczyt:
  `1234,5` (dzisiaj), `1234,5 20.11`, `1234,5 wczoraj`. Krzyżyk usuwa błędny odczyt.

Na dole sekcja **Liczniki**: pole dodaje licznik (`Gaz`, `Woda ogród m³`, `Podlicznik garaż kWh`),
krzyżyk usuwa licznik bez odczytów. Po dodaniu albo usunięciu licznika odśwież stronę, żeby
zobaczyć jego sekcję.

### Liczniki i jednostki

Nazwa podpowiada jednostkę i ikonę: gaz i woda to m³, prąd, energia i podlicznik to kWh, ciepło
to GJ, olej to l, pellet to kg. Jednostka na końcu nazwy ma pierwszeństwo: `Woda ogród m3`,
`Kocioł h`. Licznik wybierasz po nazwie albo jej słowie: `garaż` to `Podlicznik garaż`.

## Jak plugin liczy zużycie

Między dwoma odczytami zużycie rozkłada się równo na dni, które dzielą. Odczyt z 1.09 (1000) i
z 1.10 (1100) to 3,33 m³ dziennie, z czego wrzesień dostaje prawie całe 100 m³. Miesiąc bez
odczytu po obu stronach nie ma słupka, a po ostatnim odczycie nie ma szacunków: wykres pokazuje
tylko to, co wynika z odczytów.

- Odczyt bez daty jest z chwili wpisania, a z datą z południa tego dnia.
- Drugi odczyt z tego samego dnia zastępuje pierwszy.
- Licznik tylko rośnie: odczyt mniejszy od wcześniejszego albo większy od późniejszego jest
  odrzucany i plugin mówi, z którym się nie zgadza.
- Data w przyszłości jest odrzucana. `20.12` wpisane w listopadzie to grudzień zeszłego roku.

## Głos i agenci

| Akcja | Parametry | Co robi |
|---|---|---|
| `add_reading` | `meter`, `value`, `date`? | zapisuje odczyt; zwraca zużycie od poprzedniego |
| `status` | | stan wszystkich liczników z gotowym zdaniem (`text`) |
| `add_meter` | `name`, `unit`? | dodaje licznik |
| `remove_reading` | `meter`, `date`?, `confirm` | usuwa odczyt z dnia albo ostatni; tylko po potwierdzeniu |

„Zapisz gaz 1234 i pół” to `add_reading` z `meter = "gaz"`, `value = 1234.5`.

## Kod w module

```lua
local liczniki = Plugin.getPlugin("@vclu/liczniki")

liczniki:addMeter("Gaz")
liczniki:addReading("gaz", 1234.5)                 -- dzisiaj
liczniki:addReading("gaz", "1201,3", "2026-10-20")

for _, m in ipairs(liczniki:meters()) do
    Logger:info(m.name .. ": " .. (m.last and m.last.v or "brak odczytów"))
end

local off = liczniki:onReading(function(meter, r)
    Logger:info(meter.name .. " " .. r.v .. " z " .. r.date)
end)
```

Tak samo można zapisywać odczyty z licznika, który vclu czyta sam, np. raz w miesiącu z Modbusa,
żeby mieć jego historię dłużej niż metryki.

### API

| | |
|---|---|
| `liczniki:addMeter(name, unit?)` | dodaje licznik; zwraca `{ id, name, unit, icon }` albo `nil, błąd` |
| `liczniki:removeMeter(meter)` | usuwa licznik razem z odczytami |
| `liczniki:addReading(meter, value, date?)` | zapisuje odczyt; `{ date, value, used, days, replaced, text }` albo `nil, błąd` |
| `liczniki:removeReading(meter, date?)` | usuwa odczyt z dnia albo ostatni |
| `liczniki:meters()` | `{ id, name, unit, icon, readings, last = { date, v } }` |
| `liczniki:readings(meter)` | odczyty od najstarszego: `{ date, t, v }` |
| `liczniki:status()` | `{ meters, text }`, jak akcja `status` |
| `liczniki:onReading(fn(meter, reading))` | po każdym nowym odczycie; zwraca funkcję, która wyrejestrowuje `fn` |

`meter` to id (`gaz`), nazwa albo jej słowo.

## Ograniczenia

- Do 20 liczników, do 3000 odczytów na licznik, nazwa do 40 znaków.
- Wymiana licznika (stan od zera) nie jest jeszcze obsługiwana: najprościej dodać nowy licznik.
- Bez cen i kosztów: na razie tylko zużycie.
- Wykres sięga dwóch lat wstecz (rok i porównanie z poprzednim), odczyty zostają wszystkie.
