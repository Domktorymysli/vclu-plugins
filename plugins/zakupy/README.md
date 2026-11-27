# Lista zakupów

Wspólna lista zakupów domu: na dashboardzie, z asystenta głosowego albo agenta i z kodu
w module (np. bot Telegram). Lista jest zapisana w pluginie i przetrwa restart vclu.
Plugin nie potrzebuje żadnych uprawnień: nie łączy się z siecią ani z urządzeniami.
Wymaga vclu 1.13.

## Kto otwiera listę

Lista jest pod `/d/zakupy_lista`, domyślnie tylko dla zalogowanych do panelu. Kto jeszcze ją
otwiera, ustawiasz Ty, nie plugin: Pluginy → Lista zakupów → Konfiguruj, krok **Dashboardy**:

- **Nazwa**: domyślnie „Zakupy”;
- **Kto może otworzyć**: zalogowani do panelu, z kodem PIN (4 cyfry), każdy w sieci domowej
  (wygodne na tablecie w kuchni) albo wyłączony (lista znika z panelu);
- **W aplikacji vclu (przez chmurę)**: lista w telefonie także w sklepie, opcjonalnie z PIN-em
  w aplikacji i **rolami** z chmury (np. `domownicy, gosia`; znane role są do kliknięcia).
  Bez ról listę widzą wszyscy domownicy.

Krok **Kod** pokazuje różnicę i zapisuje to jako kod w `modules/plugins/vclu__zakupy.lua`. To ten
kod decyduje o dostępie, więc ludzie i agenci mogą go też napisać sami, w dowolnym module:

```lua
local zakupy = Plugin.getPlugin("@vclu/zakupy")
if zakupy then
    zakupy:dashboard("lista")
        :name("Zakupy")
        :auth("public")
        :remote({ pin = false })
        :roles("domownicy", "gosia")
end
```

`:auth()` to `"session"`, `"pin"` (wtedy też `:pin("1234")`), `"public"` albo `"off"`, tak jak przy
każdym dashboardzie. Kod z kreatora
nadpisuje ręczne zmiany w tym pliku dopiero po pokazaniu różnicy.

## Dashboard

- lista: dotknięcie odhacza produkt jako kupiony, krzyżyk go usuwa, a pole na dole dopisuje
  jeden produkt albo kilka naraz, np. `mleko, 2 chleby i masło`;
- „Usuń kupione”: zdejmuje z listy odhaczone;
- „Wyczyść wszystko”: trzeba przytrzymać, usuwa całą listę.

## Głos i agenci

Plugin daje akcje, które asystent głosowy albo agent wywołuje sam, gdy użytkownik o to prosi.
„Dodaj mleko i chleb do listy zakupów” to `add` z `item = "mleko i chleb"`.

| Akcja | Parametry | Co robi |
|---|---|---|
| `add` | `item` | dodaje jeden albo kilka produktów (`mleko, chleb i masło`, `2 mleka`, `mleko x2`) |
| `remove` | `item` | usuwa produkty z listy |
| `done` | `item` | odhacza jako kupione („kupiłem mleko”) |
| `list` | | co jest do kupienia, z gotowym zdaniem do przeczytania (`text`) |
| `clear_done` | | usuwa kupione |
| `clear_all` | `confirm` | czyści całą listę; tylko z `confirm = true`, po potwierdzeniu użytkownika |

Każda akcja zwraca też `text`: krótkie zdanie po polsku, co się stało.

### Jak plugin rozumie produkty

- Kilka produktów rozdzielają przecinki, średniki, „ i ” oraz „ oraz ”. Liczba z przecinkiem
  zostaje: `mleko 3,2%` to jeden produkt.
- Ilość: `2 mleka`, `2x mleko`, `mleko x2`. Liczba przed jednostką jest częścią nazwy:
  `2 kg ziemniaków` to jeden produkt o takiej nazwie.
- Wielkość liter i polskie znaki nie mają znaczenia: `Maslo` to `masło`.
- Produkt, który już jest na liście, nie pojawia się drugi raz: bez ilości zostaje, jak był,
  z ilością (`2 mleka`) ilość rośnie. Kupiony produkt wraca na listę.
- `remove` i `done` przyjmują pełną nazwę albo jej początek, jeśli pasuje do jednego produktu
  (`chl` → `chleb`). Gdy pasuje do kilku albo do żadnego, nic się nie zmienia i akcja mówi dlaczego.

## Kod w module

```lua
local zakupy = Plugin.getPlugin("@vclu/zakupy")

zakupy:add("mleko, 2 chleby i masło")
zakupy:done("mleko")

for _, it in ipairs(zakupy:items()) do
    Logger:info(it.label .. " x" .. it.qty .. (it.done and " (kupione)" or ""))
end

local off = zakupy:onChange(function(items)
    Logger:info("lista zakupów: " .. #items)
end)
-- off() wyrejestrowuje
```

### API

| | |
|---|---|
| `zakupy:add(text)` | dodaje; zwraca `{ added, increased, already, restored, text }` albo `nil, błąd` |
| `zakupy:remove(text)`, `zakupy:done(text)` | usuwa, odhacza; `nil, błąd`, gdy któregoś produktu nie ma |
| `zakupy:items()` | kopia listy: `{ id, label, done, qty, addedAt }`, najpierw niekupione |
| `zakupy:pending()` | `{ items, count, text }`: co zostało do kupienia |
| `zakupy:clearDone()`, `zakupy:clearAll()` | usuwa kupione, wszystko; zwracają liczbę usuniętych |
| `zakupy:onChange(fn(items))` | po każdej zmianie; zwraca funkcję, która wyrejestrowuje `fn` |

## Ograniczenia

- Do 200 pozycji, nazwa do 100 znaków.
- Jedna lista na dom, bez kategorii i sklepów.
- Odmiana nie jest rozpoznawana: `2 mleka` i `mleko` to dwa różne produkty.
- Dashboard, pole „Dodaj”, lista i akcje wymagają vclu 1.13 (dashboardy pluginów i
  dostęp do nich z modułu, widgety `input` i `list`, akcje pluginów).
