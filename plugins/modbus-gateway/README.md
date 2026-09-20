# Modbus Gateway

Odczyt urządzeń Modbus RTU wpiętych w magistralę RS485 za bramką RS485↔Ethernet,
po Modbus TCP. Testowane na **Waveshare RS485 TO ETH (B)** z trzema licznikami
energii **VCX SDM120M**.

- 🔌 **W pełni lokalnie** — bez chmury, bez mostków, bez osobnych procesów
- ⚡ **Blokowy odczyt** — profil `sdm120` czyta licznik trzema transakcjami
  (`0x0000/32`, `0x0046/10`, `0x0156/4`) zamiast dziesięcioma; sześć podstawowych
  parametrów z pierwszego zwartego zakresu schodzi jednym zapytaniem
- 🔁 **Współdzielone gniazdo** — połączenie do bramki jest utrzymywane i kolejkowane
- 🧯 **Odporny na ciszę** — niezasilone urządzenie nie wywraca całego cyklu

## Wymagania

- vCLU **>= 1.1.0** (moduł `Modbus` w rdzeniu)
- Bramka w trybie **TCP Server** z włączonym **Modbus TCP to RTU**
- Parametry portu szeregowego zgodne z magistralą (SDM120M fabrycznie **9600 8N1**)

## Konfiguracja

Najkrótsza wersja — adres bramki i adresy liczników na magistrali. Profil `sdm120`
jest domyślny, `id` robi się z adresu:

```json
{
  "host": "192.168.0.9",
  "port": 4196,
  "devices": [1, 2, 3]
}
```

Daje to sensory `meter1_power`, `meter2_energy` i tak dalej.

Pełna wersja, gdy chcesz własne nazwy albo inny profil:

```json
{
  "host": "192.168.0.9",
  "port": 4196,
  "interval": 30,
  "timeout": 2000,
  "devices": [
    { "id": "ladowarka", "unit": 1, "name": "Ładowarka samochodu",       "profile": "sdm120" },
    { "id": "klima",     "unit": 2, "name": "Klimatyzator i rekuperator", "profile": "sdm120" },
    { "id": "pralnia",   "unit": 3, "name": "Pralka i suszarka",          "profile": "sdm120" }
  ]
}
```

| Pole | Domyślnie | Opis |
|---|---|---|
| `host` | — | Adres IP bramki (wymagane) |
| `port` | 502 | Port TCP. Waveshare fabrycznie **4196** |
| `interval` | 30 | Co ile sekund odczyt |
| `timeout` | 2000 | Timeout pojedynczej transakcji w ms |
| `devices` | — | Lista urządzeń (wymagane) |

Wpis urządzenia to albo **sam adres** (`2`), albo obiekt. Wymagany jest tylko
`unit` (adres Modbus 1–247); `id` domyślnie `meter<unit>`, `name` domyślnie `id`,
`profile` domyślnie `sdm120`. Obie formy można mieszać w jednej liście.
Dostępne profile: `sdm120`, `sdm220`, `sdm230`.

## Użycie w `user.lua`

```lua
local mb = Plugin.get("@vclu/modbus-gateway")

expose(mb:get("pralnia_power"),  "number", { name = "Pralnia moc",     area = "Energia", unit = "W" })
expose(mb:get("pralnia_energy"), "number", { name = "Pralnia zużycie", area = "Energia", unit = "kWh" })
expose(mb:get("pralnia_online"), "binary_sensor", { name = "Licznik pralni", area = "Energia" })

expose(mb:get("klima_power"),    "number", { name = "Klimatyzacja moc", area = "Energia", unit = "W" })
expose(mb:get("ladowarka_power"),"number", { name = "Ładowarka moc",    area = "Energia", unit = "W" })
```

Sensor nazywa się `<id urządzenia>_<pole>`. Dostępne pola: `voltage`, `current`,
`power`, `apparent`, `reactive`, `pf`, `frequency`, `energy`, `exported`,
`total`, `online`.

## API

```lua
local mb = Plugin.get("@vclu/modbus-gateway")

mb:isOnline()                      -- czy cokolwiek odpowiada
mb:getValue("pralnia", "power")    -- pojedyncza wartość
mb:getDevice("pralnia")            -- { online, lastError, values }
mb:listDevices()                   -- lista skonfigurowanych urządzeń
mb:refresh()                       -- wymuś odczyt teraz
mb:getStats()                      -- liczniki transakcji i błędów

-- Surowy odczyt urządzenia bez profilu
mb:read({ unit = 5, addr = 0x0100, qty = 4 }, function(registers, err)
    if err then Logger:warn(err) return end
    Logger:info("temperatura: " .. Modbus.toFloat32(registers[1], registers[2]))
end)

-- Zapis pojedynczego rejestru (FC06)
mb:write({ unit = 5, addr = 0x0020, value = 3 }, function(echo, err) end)
```

## Własna mapa rejestrów

Zamiast `profile` można podać `registers`:

```json
{
  "id": "kociol", "unit": 5,
  "registers": [
    { "id": "temp_zasilania", "addr": 16, "type": "float" },
    { "id": "tryb",           "addr": 32, "type": "int16" }
  ]
}
```

Typy: `float` (IEEE-754, 2 rejestry big-endian), `int32`, `uint32`, `int16`, `raw`.
Typy 32-bitowe zajmują dwa rejestry, `int16` i `raw` jeden — plugin pyta dokładnie
o tyle, ile dany typ zajmuje, więc pole na ostatnim dostępnym rejestrze nie kończy
się błędem `illegal data address`. Urządzenia z własną mapą są czytane pole po polu.

## Zdarzenia

```lua
EventBus:on("modbus:updated", function(data) end)
EventBus:on("modbus:error", function(data) Logger:warn(data.error) end)
EventBus:on("modbus:device_offline", function(data)
    Logger:warn("Licznik " .. data.device .. " (unit " .. data.unit .. ") milczy")
end)
```

## Rozwiązywanie problemów

**Wszystkie urządzenia milczą, a konfiguracja się zgadza.** Zanim zaczniesz
zmieniać parametry, sprawdź zaciski — luźne połączenie na listwie RS485 daje
dokładnie ten objaw. Dopiero potem: prędkość portu (SDM120M fabrycznie 9600,
bramka Waveshare fabrycznie 115200), adresy urządzeń i zamianę A/B.

**`illegal data address`.** Urządzenie nie akceptuje szerokiego odczytu. Plugin
przełącza je wtedy na stałe na odczyt pole po polu i zapisuje ostrzeżenie w logu —
nic nie trzeba robić, będzie tylko więcej transakcji na cykl.

**Jedno urządzenie milczy, reszta działa.** To normalne przy niezasilonym
urządzeniu. Cykl kończy się powodzeniem dla pozostałych, a milczące dostaje
`_online = 0` i zdarzenie `modbus:device_offline`.

**Waveshare: `Instruction Time out`.** Przy `Protocol = Modbus TCP to RTU`
multi-host bywa wymuszany, a wtedy wartość 0 potrafi ucinać odpowiedzi.
Jeśli bramka zachowuje się niestabilnie, ustaw 1024 ms (musi być wielokrotnością 32).

**`No-Data-Restart`.** Zostaw wyłączone. Włączone restartuje bramkę po okresie
ciszy, co przy rzadkim odpytywaniu zrywa połączenie w środku pracy.
