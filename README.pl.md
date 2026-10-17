# Pluginy vCLU

[English](README.md) | Polski

Pluginy do [vCLU](https://github.com/Domktorymysli/vclu), wirtualnego CLU Grentona.
Każdy łączy vCLU z jakimś urządzeniem albo usługą.

## Pluginy

Plugin **konfigurowany** ustawiasz w panelu. **Fabryka** tworzy urządzenia
w Twoim kodzie przez `create()`, więc jeden plugin obsłuży ich dowolnie wiele.

| Plugin | Do czego służy | Rodzaj |
|--------|----------------|--------|
| [weather](plugins/weather/) | Pogoda z OpenWeatherMap | konfigurowany |
| [time-sync](plugins/time-sync/) | Synchronizuje zegar z internetowymi serwerami czasu | konfigurowany |
| [sun-position](plugins/sun-position/) | Pozycja słońca, wschody i zachody, fazy księżyca, np. do rolet | konfigurowany |
| [telegram](plugins/telegram/) | Powiadomienia przez bota Telegrama | konfigurowany |
| [salda-recuperator](plugins/salda-recuperator/) | Rekuperator Salda: odczyty i bieg wentylatora | konfigurowany |
| [supla-power-meter](plugins/supla-power-meter/) | Trójfazowy licznik energii Supla przez Direct Links | konfigurowany |
| [solax](plugins/solax/) | Falownik SolaX, odczyt lokalny przez dongiel WiFi Solarman LSW-3 | konfigurowany |
| [frigate](plugins/frigate/) | Frigate NVR: detekcja obiektów, stan kamer, zdarzenia | konfigurowany |
| [modbus-gateway](plugins/modbus-gateway/) | Urządzenia Modbus RTU za bramkami RS485-Ethernet (Waveshare, USR, Elfin) | fabryka |
| [influx-metrics](plugins/influx-metrics/) | Wysyła metryki do InfluxDB, Telegrafa albo VictoriaMetrics | fabryka ¹ |
| [musiccast](plugins/musiccast/) | Amplitunery i głośniki Yamaha MusicCast przez ich lokalne API | fabryka |
| [spotify](plugins/spotify/) | Sterowanie Spotify przez Web API (Premium) | fabryka |
| [tasmota-switch](plugins/tasmota-switch/) | Przełączniki Tasmota (Sonoff i inne) przez HTTP | fabryka ¹ |

¹ Jeszcze nie ma go w `plugins.json`, więc panel go nie pokazuje.

W katalogu każdego pluginu jest README z konfiguracją i przykładami.

## Instalacja

W panelu vCLU otwórz **Plugins** i kliknij **Install**. Plugin konfigurowany
ustawiasz potem w panelu, a fabryki używasz w module:

```lua
local salon = Plugin.getPlugin("@vclu/musiccast"):create({ id = "salon", ip = "192.168.0.159" })
salon:setVolume(30)
```

## Pisanie pluginów

API runtime'u, sandbox, fabryki i testy opisuje [DEVELOPMENT.md](DEVELOPMENT.md)
(po angielsku).

## Licencja

MIT
