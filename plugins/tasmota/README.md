# Tasmota

Przekaźniki i pomiar mocy urządzeń z Tasmotą (Sonoff, Nous, Shelly z Tasmotą i inne) przez HTTP.
Do skonfigurowania kreatorem w panelu albo kodem w module. Wymaga vclu 1.13.

## Kreator

Pluginy → Tasmota → Konfiguruj:

1. **Ustawienia.** Sieć, w której szukać urządzeń (`192.168.1.0/24`), hasło WWW urządzeń, jeśli
   je ustawiłeś (jedno dla wszystkich, użytkownik `admin`), co ile sekund czytać stan i czy
   utworzyć dashboard.
2. **Urządzenia.** „Wykryj” pyta każdy adres sieci o `Status 0` i pokazuje każdy przekaźnik
   w osobnym wierszu. Zaznacz te, które chcesz, i ustaw:
   - **Wystaw jako**: `switch` albo `light` (Home Assistant, Apple Home, dashboardy), `none`: nie wystawiaj;
   - **Powiąż z obiektem**: ścieżka DOUT z Grentona (`CLU221000002.DOU0001`) albo wystawionego
     `VirtualSwitch` (jego `path` z `expose`). Przekaźnik i obiekt są wtedy zawsze w tym samym
     stanie: obiekt przełącza przekaźnik, a przycisk na urządzeniu przełącza obiekt. Przy starcie
     decyduje obiekt;
   - **Pomiar mocy**: moc z licznika urządzenia (jedna na urządzenie) jako sensor w W.

   Urządzenie spoza sieci albo bez odpowiedzi na wyszukiwanie dodasz ręcznie.
3. **Kod.** Kreator pokazuje moduł `modules/plugins/vclu__tasmota.lua` i zapisuje go po
   „Zapisz”. Ponowne uruchomienie kreatora pokaże różnicę, więc nic nie zginie bez Twojej wiedzy.

Hasło urządzeń zostaje w pluginie: nie trafia do konfiguracji, modułu ani logów.

## Kod w module

```lua
local tasmota = Plugin.getPlugin("@vclu/tasmota")

local plug = tasmota:device({ ip = "192.168.1.50" })   -- jedno urządzenie, jeden odczyt na interwał
local lamp = plug:relay(1)                             -- przekaźnik 1..8
expose(lamp, "light", { path = "tasmota.lampa", name = "Lampa", area = "Salon" })

local power = plug:power()                             -- W, tylko odczyt
expose(power, "number", { path = "tasmota.lampa_moc", name = "Lampa moc", readonly = true,
    unit = "W", device_class = "power", state_class = "measurement" })

lamp:onChange(function(v, old) Logger:info("lampa: " .. tostring(v)) end)
```

### API

| | |
|---|---|
| `tasmota:device({ ip, interval })` | urządzenie; ten sam adres to ten sam obiekt. `interval` w sekundach, domyślnie z kreatora |
| `dev:relay(n)` | przekaźnik `n` |
| `dev:power()` | moc w W (suma kanałów na urządzeniu z kilkoma licznikami) |
| `dev:isOnline()`, `dev:refresh()` | czy odpowiada; odczyt teraz |
| `relay:switchOn()`, `switchOff()`, `toggle()` | sterowanie |
| `relay:getValue()`, `isOn()`, `get()` | stan: `1`, `0`, `nil` przed pierwszym odczytem |
| `relay:set(_, v)` | dla `expose` |
| `obj:onChange(fn(v, old))` | zwraca funkcję, która wyrejestrowuje `fn` |

## Uprawnienia

`lan`: HTTP do urządzeń w sieci lokalnej. Jeśli zawęzisz je do listy adresów, kreator dopisze
do niej adresy zapisanych urządzeń, ale wyszukiwanie zapyta tylko adresy z listy.

## Ograniczenia

- Stan z urządzenia przychodzi co interwał odczytu (domyślnie 10 s), nie od razu. Do
  natychmiastowych zmian użyj MQTT i `require("lib/tasmota")` w module.
- Wyszukiwanie obejmuje jedną sieć /24 i trwa do kilkunastu sekund.
- Ściemniacze, kolory, rolety i sensory poza mocą nie są obsługiwane.
