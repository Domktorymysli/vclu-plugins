# Spotify Plugin

Fabryka kont Spotify sterowanych przez Web API. Sterowanie odtwarzaniem wymaga **Spotify Premium**.

## Przygotowanie (jednorazowo)

1. Na https://developer.spotify.com/dashboard utwórz aplikację, zaznacz *Web API*.
2. Dodaj Redirect URI: `http://127.0.0.1:8888/callback` (nic nie musi tam nasłuchiwać).
3. Skopiuj *Client ID* i *Client secret*.

```lua
local spotify = Plugin.getPlugin("@vclu/spotify")
local sp = spotify:create({ id = "spotify", clientId = "...", clientSecret = "..." })
print(sp:authUrl())
```

4. Otwórz wypisany URL, zaloguj się i zaakceptuj. Przeglądarka przejdzie na
   `http://127.0.0.1:8888/callback?code=AQB...` i pokaże błąd połączenia, to normalne.
5. Skopiuj wartość `code` i wywołaj raz:

```lua
sp:authorize("AQB...")
```

Refresh token trafia do KV wtyczki (pod `refresh_token:<id>`), więc przeżywa restart.

## Użycie

```lua
local spotify = Plugin.getPlugin("@vclu/spotify")
local sp = spotify:create({ id = "spotify", clientId = "...", clientSecret = "..." })

sp:play()                                              -- wznów
sp:play("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")     -- playlista / album / utwór
sp:play({ uri = "spotify:album:...", device = "Salon" }) -- na konkretnym głośniku
sp:pause()
sp:toggle()
sp:next()
sp:previous()
sp:setVolume(30)
sp:transfer("Kuchnia")                                 -- przenieś odtwarzanie

sp:devices(function(list) for _, d in ipairs(list) do print(d.name, d.id) end end)
```

Wtyczka nie wystawia konta przez `expose`: Home Assistant ma własną integrację
Spotify.

Urządzenie (`device`) to nazwa lub id z `devices()`. Spotify widzi tylko głośniki,
które są aktywne w Spotify Connect, uśpiony głośnik może nie być na liście.

## API

| Metoda | Opis |
|---|---|
| `authUrl()` / `authorize(code)` / `isAuthorized()` | autoryzacja |
| `play([uri \| {uri, device}])`, `pause()`, `toggle()`, `next()`, `previous()` | odtwarzanie |
| `setVolume(0-100)`, `transfer(device, [play])`, `devices(cb)` | głośność i urządzenia |
| `refresh()`, `isPlaying()`, `getTrack()`, `getVolume()`, `getDevice()`, `getState()` | stan |

Opcje `create`: `id`, `name`, `clientId`, `clientSecret`, `redirectUri`,
`refreshToken` (pomija KV), `polling` (domyślnie `true`), `pollInterval` (s, domyślnie 15).
