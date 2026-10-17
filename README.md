# vCLU Plugins

English | [Polski](README.pl.md)

Plugins for [vCLU](https://github.com/Domktorymysli/vclu), a virtual Grenton CLU.
Each one connects vCLU to a device or a service.

## Plugins

Plugins of the **config** kind are set up in the panel. **Factory** plugins
create their devices in your code, through `create()`, so one plugin can
handle any number of them.

| Plugin | What it does | Kind |
|--------|--------------|------|
| [weather](plugins/weather/) | Weather from OpenWeatherMap | config |
| [time-sync](plugins/time-sync/) | Keeps the clock in sync with internet time servers | config |
| [sun-position](plugins/sun-position/) | Sun position, sunrise and sunset, moon phases, e.g. for blinds | config |
| [telegram](plugins/telegram/) | Notifications through a Telegram bot | config |
| [salda-recuperator](plugins/salda-recuperator/) | Salda heat recovery unit: readings and fan speed | config |
| [supla-power-meter](plugins/supla-power-meter/) | Supla 3-phase energy meter through Direct Links | config |
| [solax](plugins/solax/) | SolaX inverter, read locally through the Solarman LSW-3 WiFi dongle | config |
| [frigate](plugins/frigate/) | Frigate NVR: object detection, camera status, events | config |
| [modbus-gateway](plugins/modbus-gateway/) | Modbus RTU devices behind RS485-Ethernet gateways (Waveshare, USR, Elfin) | factory |
| [influx-metrics](plugins/influx-metrics/) | Sends metrics to InfluxDB, Telegraf or VictoriaMetrics | factory ¹ |
| [musiccast](plugins/musiccast/) | Yamaha MusicCast receivers and speakers through their local API | factory |
| [spotify](plugins/spotify/) | Spotify playback through the Web API (Premium) | factory |
| [tasmota-switch](plugins/tasmota-switch/) | Tasmota switches (Sonoff and others) over HTTP | factory ¹ |

¹ Not in `plugins.json` yet, so the panel does not list it.

Each plugin's directory has a README with configuration and examples.

## Installation

In the vCLU panel open **Plugins** and click **Install**. A config plugin is
then configured in the panel; a factory plugin is used from a module:

```lua
local salon = Plugin.getPlugin("@vclu/musiccast"):create({ id = "salon", ip = "192.168.0.159" })
salon:setVolume(30)
```

## Writing plugins

The runtime API, the sandbox, factory plugins and tests are described in
[DEVELOPMENT.md](DEVELOPMENT.md).

## License

MIT
