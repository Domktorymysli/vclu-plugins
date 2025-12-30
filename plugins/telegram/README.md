# Telegram Notifications Plugin

Powiadomienia przez Telegram Bot API.

## Konfiguracja bota

### 1. Utwórz bota

1. Otwórz Telegram i znajdź **@BotFather**
2. Wyślij `/newbot`
3. Podaj nazwę bota (np. "Mój Dom Bot")
4. Podaj username bota (np. "mojdom_bot")
5. Skopiuj **token** (np. `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

### 2. Uzyskaj Chat ID

1. Napisz wiadomość do swojego bota
2. Otwórz w przeglądarce:
   ```
   https://api.telegram.org/bot<TOKEN>/getUpdates
   ```
3. Znajdź `"chat":{"id":123456789}` - to Twój **chat_id**

### 3. Konfiguracja pluginu

```json
{
  "id": "@vclu/telegram",
  "config": {
    "botToken": "123456789:ABCdefGHIjklMNOpqrsTUVwxyz",
    "chatId": "123456789",
    "defaultParseMode": "HTML"
  }
}
```

## API

```lua
local tg = Plugin.get("@vclu/telegram")

-- Podstawowe wysyłanie
tg:send("Hello World!")
tg:send("Wiadomość z <b>HTML</b>")

-- Bez dźwięku powiadomienia
tg:sendSilent("Cicha wiadomość")

-- Szybkie alerty
tg:alert("Tytuł", "Treść wiadomości")
tg:warning("Wykryto ruch w ogrodzie!")
tg:error("Błąd połączenia z rekuperatorem")
tg:success("System uzbrojony")

-- Ze zdjęciem
tg:sendPhoto("https://example.com/camera.jpg", {
    caption = "Kamera ogrodowa"
})

-- Lokalizacja
tg:sendLocation(52.2297, 21.0122)

-- Z callbackiem
tg:send("Test", {}, function(result, err)
    if err then
        print("Błąd: " .. err)
    else
        print("Wysłano, ID: " .. result.message_id)
    end
end)
```

## Formatowanie wiadomości

### HTML (domyślne)
```lua
tg:send("<b>Pogrubienie</b>")
tg:send("<i>Kursywa</i>")
tg:send("<code>Kod</code>")
tg:send("<a href='https://example.com'>Link</a>")
tg:send("<pre>Blok kodu</pre>")
```

### Markdown
```lua
tg:send("*Pogrubienie*", { parseMode = "Markdown" })
tg:send("_Kursywa_", { parseMode = "Markdown" })
tg:send("`Kod`", { parseMode = "Markdown" })
```

## Przykłady użycia

### Alarm włamaniowy

```lua
plugin:on("alarm:triggered", function(data)
    local tg = Plugin.get("@vclu/telegram")
    tg:alert("ALARM!", string.format(
        "Wykryto ruch w strefie: %s\nCzas: %s",
        data.zone,
        os.date("%H:%M:%S")
    ))
end)
```

### Status rekuperatora

```lua
plugin:on("salda:error", function(data)
    local tg = Plugin.get("@vclu/telegram")
    tg:error("Rekuperator: " .. data.error)
end)
```

### Powiadomienie o wschodzie słońca

```lua
plugin:on("sun:rise", function(data)
    local tg = Plugin.get("@vclu/telegram")
    local weather = Plugin.get("@vclu/weather")

    local temp = weather and weather:getTemperature() or "?"

    tg:sendSilent(string.format(
        "Wschód słońca: %s\nTemperatura: %s°C",
        data.time, temp
    ))
end)
```

### Dzienna statystyka

```lua
-- Codziennie o 22:00
plugin:on("time:hourChanged", function(data)
    if data.hour == 22 then
        local tg = Plugin.get("@vclu/telegram")
        local sun = Plugin.get("@vclu/sun-position")

        tg:send(string.format([[
<b>Podsumowanie dnia</b>

Wschód: %s
Zachód: %s
Długość dnia: %s

Księżyc: %s (%d%%)
        ]],
            sun:getSunrise(),
            sun:getSunset(),
            sun:getDayLengthFormatted(),
            sun:getMoonPhaseName(),
            sun:getMoonIllumination()
        ))
    end
end)
```

### Powiadomienie o otwarciu drzwi

```lua
-- Gdy nikt nie ma być w domu
plugin:on("door:opened", function(data)
    local time = Plugin.get("@vclu/time-sync")

    -- Tylko w godzinach pracy
    if time:isWeekday() and time:isBetween(8, 0, 16, 0) then
        local tg = Plugin.get("@vclu/telegram")
        tg:alert("Drzwi otwarte!", string.format(
            "Drzwi %s otwarte o %s",
            data.name,
            time:getFormatted()
        ))
    end
end)
```

## Wysyłanie do wielu odbiorców

```lua
local tg = Plugin.get("@vclu/telegram")

-- Wysyłka do konkretnego chatu
tg:send("Wiadomość", { chatId = "987654321" })

-- Lub zmiana domyślnego odbiorcy
tg:setChatId("987654321")
tg:send("Teraz idzie tu")
```

## Grupy i kanały

Aby wysyłać do grupy:
1. Dodaj bota do grupy
2. Użyj chat_id grupy (często ujemny, np. `-123456789`)

Dla kanału:
1. Dodaj bota jako administratora kanału
2. Użyj `@nazwakanalu` jako chatId

## Limity Telegram

- Max 30 wiadomości/sekundę do różnych chatów
- Max 1 wiadomość/sekundę do tego samego chatu
- Max 4096 znaków na wiadomość
- Plugin automatycznie obsługuje błędy rate-limit

## Statystyki

```lua
local tg = Plugin.get("@vclu/telegram")
local stats = tg:getStats()

print("Wysłano: " .. stats.messagesSent)
print("Ostatnia: " .. os.date("%H:%M", stats.lastMessageTime))
print("Błąd: " .. (stats.lastError or "brak"))
```
