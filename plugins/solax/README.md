# SolaX Inverter

Lokalny monitoring falownika **SolaX** przez dongle WiFi **Solarman LSW-3** ("Pocket WiFi").
Czyta stronę `status.html` serwowaną przez stick i wystawia dane jako czujniki vCLU.

- 🔌 **W pełni lokalnie** — bez chmury SolaX/Solarman, bez Modbusa, bez kodu Go.
- 🪶 Czysty plugin Lua (HTTP + Basic Auth).
- ♻️ Nie ruszamy konfiguracji "Server A/B" w sticku — chmura działa dalej równolegle.

## Jak to działa

Dongle LSW-3 serwuje pod `/status.html` zmienne JS:

```js
var webdata_sn      = "SF4ES006L94585";
var webdata_now_p   = "2150";   // moc AC [W]
var webdata_today_e = "29.94";  // produkcja dziś [kWh]
var webdata_total_e = "36643.0";// produkcja łącznie [kWh]
var webdata_msvn    = "V240";   // firmware
```

Plugin pobiera tę stronę co `interval` sekund (Basic Auth `admin`/`admin`),
parsuje wartości i aktualizuje czujniki. Pola `"---"` (np. nocą, gdy falownik
śpi) są ignorowane — utrzymywany jest ostatni znany odczyt.

## Konfiguracja

| Klucz      | Domyślnie               | Opis                                         |
|------------|-------------------------|----------------------------------------------|
| `host`     | `http://192.168.0.132`  | Adres dongla WiFi (LSW-3)                     |
| `user`     | `admin`                 | Login panelu dongla                          |
| `pass`     | `admin`                 | Hasło panelu dongla                          |
| `interval` | `30`                    | Interwał odczytu [s] (10–3600)               |

> Jak znaleźć IP: w kontrolerze sieci (np. UniFi) dongle widnieje jako
> **SolaX Power** / hostname numeryczny. Otwórz `http://<ip>/status.html`
> i zaloguj się `admin`/`admin`, by potwierdzić.

## Czujniki

| ID       | Typ             | Jedn. | Opis                    |
|----------|-----------------|-------|-------------------------|
| `power`  | `number`        | W     | Moc AC chwilowa         |
| `today`  | `number`        | kWh   | Produkcja dziś          |
| `total`  | `number`        | kWh   | Produkcja łącznie       |
| `online` | `binary_sensor` | 0/1   | Czy ostatni odczyt OK   |

## Wystawienie obiektów (`user.lua`)

```lua
local solax = Plugin.getPlugin("@vclu/solax")

expose(solax:get("power"), "number", {
    name = "Falownik — moc AC", area = "Fotowoltaika", unit = "W", min = 0, max = 20000
})
expose(solax:get("today"), "number", {
    name = "Produkcja dziś", area = "Fotowoltaika", unit = "kWh"
})
expose(solax:get("total"), "number", {
    name = "Produkcja łącznie", area = "Fotowoltaika", unit = "kWh"
})
expose(solax:get("online"), "binary_sensor", {
    name = "Falownik online", area = "Fotowoltaika"
})
```

Wystawione obiekty trafiają automatycznie na dashboard vCLU oraz do
Home Assistant (MQTT discovery) z odpowiednią jednostką.

## API skryptowe

```lua
local solax = Plugin.getPlugin("@vclu/solax")

solax:getPower()    -- moc AC [W]
solax:getToday()    -- produkcja dziś [kWh]
solax:getTotal()    -- produkcja łącznie [kWh]
solax:isOnline()    -- true/false
solax:getSerial()   -- numer seryjny falownika
solax:getData()     -- pełny snapshot (tabela)
solax:refresh()     -- wymuś natychmiastowy odczyt
```

## Zdarzenia

| Nazwa            | Opis                          |
|------------------|-------------------------------|
| `solax:updated`  | Dane zaktualizowane (throttle 30 s) |
| `solax:error`    | Błąd komunikacji z donglem    |

```lua
solax:on("solax:updated", function(d)
    print(string.format("PV: %.0f W, dziś %.2f kWh", d.power, d.today))
end)
```

## Ograniczenia / roadmapa

`status.html` udostępnia tylko zbiorcze pola (moc, produkcja dziś/łącznie).
Dla pełnych danych (PV1/PV2 U/I/P, fazy AC, oddanie do sieci, SOC baterii dla
hybryd) potrzebny jest protokół **Solarman V5** na porcie `8899` — to osobny,
większy plugin/most (wymaga surowego TCP). Ten plugin celowo zostaje przy
lekkim, czysto-HTTP odczycie.

## Wymagania

- Falownik SolaX z donglem WiFi Solarman **LSW-3** (firmware `LSW3_*`).
- Dongle i vCLU w tej samej sieci LAN.
- vCLU `>= 1.0.0`, moduły: `http`, `timer`.