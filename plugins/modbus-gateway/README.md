# Modbus Gateway

Odczyt urządzeń Modbus RTU wpiętych w magistralę RS485 za bramką RS485↔Ethernet,
po Modbus TCP. Testowane na **Waveshare RS485 TO ETH (B)** z trzema licznikami
energii **VCX SDM120M**.

- 🔌 **W pełni lokalnie** — bez chmury, bez mostków, bez osobnych procesów
- 🏭 **Fabryka, nie singleton** — bramki deklarujesz w kodzie przez `create()`,
  więc jedno vCLU obsługuje ich dowolnie wiele
- ⚡ **Blokowy odczyt** — profil `sdm120` czyta licznik trzema transakcjami
  (`0x0000/32`, `0x0046/10`, `0x0156/4`) zamiast dziesięcioma; sześć podstawowych
  parametrów z pierwszego zwartego zakresu schodzi jednym zapytaniem
- 🔁 **Współdzielone gniazdo** — połączenie do bramki jest utrzymywane i kolejkowane
- 🧯 **Odporny na ciszę** — niezasilone urządzenie nie wywraca całego cyklu

## Wymagania

- vCLU **>= 1.1.0** (moduł `Modbus` w rdzeniu)
- Bramka w trybie **TCP Server** z włączonym **Modbus TCP to RTU**
- Parametry portu szeregowego zgodne z magistralą (SDM120M fabrycznie **9600 8N1**)

## Deklaracja bramki

Plugin nie ma sekcji konfiguracji w panelu. Bramkę tworzysz w module albo
w `user.lua`, tam gdzie i tak piszesz resztę logiki:

```lua
local modbus = Plugin.get("@vclu/modbus-gateway")

local garaz = modbus:create({
    id       = "garaz",
    host     = "192.168.0.9",
    port     = 4196,
    interval = 30,
    devices  = {
        { id = "ladowarka", unit = 1, name = "Ładowarka auta" },
        { id = "klima",     unit = 2, name = "Klimatyzacja" },
        { id = "pralnia",   unit = 3, name = "Pralka i suszarka" }
    }
})
```

Druga bramka to po prostu drugie wywołanie:

```lua
local kotlownia = modbus:create({
    id = "kotlownia", host = "192.168.0.14",
    devices = { { id = "kociol", unit = 1 } }
})
```

Gdy domyślne wartości pasują, urządzenie można podać samym adresem Modbus.
`devices = { 1, 2, 3 }` daje `meter1`, `meter2` i `meter3` na profilu `sdm120`.
Obie formy wolno mieszać w jednej liście.

### Opcje `create()`

| Opcja | Domyślnie | Opis |
|---|---|---|
| `host` | wymagane | Adres IP bramki |
| `id` | `gw1`, `gw2`… | Identyfikator bramki, daje sensor `gateway_<id>_online` |
| `port` | `502` | Port TCP. Waveshare fabrycznie `4196` |
| `interval` | `30` | Interwał odczytu w sekundach |
| `timeout` | `2000` | Timeout pojedynczej transakcji w ms |
| `devices` | wymagane | Lista urządzeń na magistrali |
| `autostart` | `true` | Czy od razu wystartować poller |

Wpis urządzenia przyjmuje `unit` (adres Modbus 1–247, jedyne pole wymagane),
`id` (domyślnie `meter<unit>`), `name` (domyślnie `id`), `profile` (domyślnie
`sdm120`) oraz `registers` i `fc` dla własnej mapy.
Dostępne profile: `sdm120`, `sdm220`, `sdm230`.

Identyfikatory urządzeń są płaskie na całe vCLU, bo z nich powstają nazwy
sensorów. Jeśli druga bramka poda `id` już zajęte, plugin pominie to urządzenie
i zapisze błąd w logu, zamiast po cichu przesłonić pierwsze.

## Wystawianie sensorów

```lua
expose(garaz:get("pralnia_power"),  "number", { name = "Pralnia moc",     area = "Energia", unit = "W" })
expose(garaz:get("pralnia_energy"), "number", { name = "Pralnia zużycie", area = "Energia", unit = "kWh" })
expose(garaz:get("pralnia_online"), "binary_sensor", { name = "Licznik pralni", area = "Energia" })

expose(garaz:get("klima_power"),     "number", { name = "Klimatyzacja moc", area = "Energia", unit = "W" })
expose(garaz:get("ladowarka_power"), "number", { name = "Ładowarka moc",    area = "Energia", unit = "W" })

expose(garaz:get("gateway_garaz_online"), "binary_sensor", { name = "Bramka garaż", area = "Energia" })
```

Sensor nazywa się `<id urządzenia>_<pole>`. Dostępne pola: `voltage`, `current`,
`power`, `apparent`, `reactive`, `pf`, `frequency`, `energy`, `exported`,
`total`, `online`. Każda bramka dokłada własny `gateway_<id bramki>_online`,
w osobnej przestrzeni nazw, żeby bramka nazwana jak urządzenie nie przesłoniła
jego sensora.

## API

```lua
garaz:isOnline()                      -- czy cokolwiek na tej bramce odpowiada
garaz:getValue("pralnia", "power")    -- pojedyncza wartość
garaz:getDevice("pralnia")            -- { online, lastError, values }
garaz:listDevices()                   -- lista urządzeń tej bramki
garaz:refresh()                       -- wymuś odczyt teraz
garaz:stop() / garaz:start()          -- zatrzymaj i wznów poller
garaz:getStats()                      -- liczniki transakcji i błędów

-- Surowy odczyt urządzenia bez profilu
garaz:read({ unit = 5, addr = 0x0100, qty = 4 }, function(registers, err)
    if err then Logger:warn(err) return end
    Logger:info("temperatura: " .. Modbus.toFloat32(registers[1], registers[2]))
end)

-- Zapis pojedynczego rejestru (FC06)
garaz:write({ unit = 5, addr = 0x0020, value = 3 }, function(echo, err) end)
```

Na poziomie pluginu:

```lua
modbus:gateway("garaz")   -- bramka po id
modbus:getGateways()      -- wszystkie utworzone bramki
modbus:listProfiles()     -- dostępne profile urządzeń
```

## Własna mapa rejestrów

Zamiast `profile` można podać `registers`:

```lua
{
    id = "kociol", unit = 5,
    registers = {
        { id = "temp_zasilania", addr = 0x0010, type = "float" },
        { id = "tryb",           addr = 0x0020, type = "int16" }
    }
}
```

Typy: `float` (IEEE-754, 2 rejestry big-endian), `int32`, `uint32`, `int16`, `raw`.
Typy 32-bitowe zajmują dwa rejestry, `int16` i `raw` jeden — plugin pyta dokładnie
o tyle, ile dany typ zajmuje, więc pole na ostatnim dostępnym rejestrze nie kończy
się błędem `illegal data address`. Urządzenia z własną mapą są czytane pole po polu.

## Zdarzenia

```lua
EventBus:on("modbus:updated", function(data) end)
EventBus:on("modbus:error", function(data) Logger:warn(data.gateway .. ": " .. data.error) end)
EventBus:on("modbus:device_offline", function(data)
    Logger:warn("Licznik " .. data.device .. " (unit " .. data.unit .. ") milczy")
end)
```

Każde zdarzenie niesie `gateway` z identyfikatorem bramki, więc przy kilku
bramkach wiesz, której dotyczy.

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
