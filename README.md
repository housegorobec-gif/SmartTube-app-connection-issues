# SmartTube app connection issues — z2k-tool

> **Это надстройка (add-on) для z2k.** Сама по себе она ничего не обходит: она работает только с роутером, на котором уже установлен и запущен z2k с веб-панелью.
>
> **This is an add-on for z2k.** It does not bypass anything by itself: it only works with a router that already has z2k installed and running, with its web panel enabled.

[Русский](#русский) · [English](#english)

---

## Русский

### Зачем это нужно

SmartTube (и обычный YouTube на ТВ, приставках, телефонах) часто «не подключается», крутит бесконечную загрузку или обрывает видео на середине. Обычно причина в том, что провайдер блокирует или замедляет домены YouTube/Google (`googlevideo.com`, `youtubei.googleapis.com`, `ytimg.com`, `ggpht.com` и т. д.), а стратегия обхода, которую z2k подобрал автоматически, перестала работать или работает нестабильно.

**z2k-tool** — надстройка для z2k, которая через панель z2k на роутере:

1. выгружает все строки автоподбора (как на вкладке «Автоподбор»);
2. проверяет каждый домен **мимо обхода** — роутер сам стучится к сайту, и видно, что делает провайдер: блокирует, замедляет или пропускает;
3. раскладывает домены на списки «блокируются» и «не блокируются»;
4. предлагает:
   - не блокируемые домены — добавить в «Исключения» z2k;
   - для блокируемых — подобрать рабочую стратегию и **заморозить** её:
     - **короткий подбор** — первая стратегия, прошедшая проверку и контрольную серию;
     - **длинный подбор** — проверяются все стратегии пула, три лучшие проходят финал, замораживается лучшая.

Если для строки стабильная стратегия не нашлась, строка возвращается как была и запоминается в `z2k-recheck.tsv` — её можно перепроверить позже (пункт **[5]** меню).

Роутер меняется **только** на шаге 4 и **только** после вашего подтверждения. Прерывание по Ctrl+C возвращает текущую строку в исходное состояние.

### Файлы

| Файл | Что это |
|---|---|
| `z2k-tool.exe` | Основная программа (консольная, Windows x64). Сама ищет роутер с z2k в локальной сети, умеет выбирать домены для проверки и добавлять свои домены, которых нет в автоподборе. Настройки хранит в `z2k-tool.json`. |
| `z2k-tool.bat` | Та же логика в виде скрипта PowerShell внутри `.bat` — без компиляции, код можно прочитать и поправить. Настройки хранит в `z2k-tool.ini`. |
| `curl3.exe` | curl 8.23.0 с поддержкой HTTP/3 (ngtcp2 + nghttp3). Нужен, чтобы проверять **QUIC**-строки автоподбора: штатный `curl.exe` в Windows HTTP/3 не умеет. Без него QUIC-строки просто пропускаются. |

`z2k-tool.exe` и `z2k-tool.bat` взаимозаменяемы — используйте любой. `curl3.exe` должен лежать **в той же папке**.

### Требования

- Роутер с установленным **z2k** и включённой веб-панелью (по умолчанию `http://192.168.7.1:8088`; адрес и порт можно ввести при запуске — они запоминаются).
- На роутере должен быть модуль проверки **z2k-detect** (если его нет, программа об этом скажет — переустановите z2k или включите модуль в меню **[Y]**).
- Вход в панель по паролю на время работы нужно **выключить** (меню z2k **[P] → [6]**).
- Windows 10/11 (в системе уже есть `curl.exe` и PowerShell).
- Компьютер подключён к той же сети, что и роутер.

### Как пользоваться

1. Скачайте все три файла в одну папку (или клонируйте репозиторий).
2. Запустите `z2k-tool.exe` (или `z2k-tool.bat`).
3. Программа подключится к панели z2k, выгрузит автоподбор и проверит домены — на роутере в этот момент ничего не меняется (≈3–20 с на домен).
4. В меню выберите действие:

```
[1] Не блокируемые — добавить в «Исключения»
[2] Блокируемые — КОРОТКИЙ подбор (первая подошедшая стратегия)
[3] Блокируемые — ДЛИННЫЙ подбор (все стратегии, лучшая)
[4] Повторить выгрузку и проверку
[5] Перепроверить не найденные
[0] Выход
```

Для SmartTube обычно достаточно пункта **[2]**; если видео всё равно рвётся — **[3]**.

> ⚠️ Домены, от которых зависят YouTube, Google и мессенджеры, в списке исключений помечены **(!)**. Добавляйте их в исключения только осознанно: если провайдер начнёт их блокировать, SmartTube перестанет работать, пока вы не уберёте домен из «Исключений».

Только перепроверка сохранённого списка, без полной проверки:

```bat
z2k-tool.bat recheck
```

### Результаты

Всё складывается в папку `z2k-ГГГГММДД-ЧЧММ` рядом с программой:

| Файл | Содержимое |
|---|---|
| `1-autopodbor-full.tsv` | Полная выгрузка автоподбора |
| `2-check-report.tsv` | Подробный отчёт проверки без обхода |
| `3-blocked.txt` / `3-not-blocked.txt` | Блокируемые / не блокируемые домены |
| `4-exclusions.txt` | Что добавлено в исключения |
| `5-strategies.tsv` | Журнал подбора стратегий |
| `5-matrix.tsv` | Длинный подбор: результат каждой стратегии |
| `6-not-found.tsv` | Строки без стабильной стратегии |

Файлы `.tsv` в UTF-8 с BOM — открываются в Excel и Блокноте с нормальной кириллицей.

### Тонкая настройка (`z2k-tool.ini`, для `.bat`)

```ini
Router=192.168.7.1
Port=8088
Timeout=7        ; таймаут одного запроса, с
Settle=3         ; пауза после смены стратегии, с
ShortTries=5     ; короткий подбор: попыток на стратегию
ShortConfirm=10  ; короткий подбор: контрольная серия
LongTries=6      ; длинный подбор: попыток на стратегию
Finalists=3      ; сколько стратегий выходит в финал
FinalTries=15    ; попыток в финале
MinRate=0.9      ; минимальная доля успешных попыток для заморозки
```

### Что значат итоги проверки

| Итог | Что делать |
|---|---|
| БЛОКИРУЕТСЯ / ЗАМЕДЛЯЕТСЯ | Подобрать стратегию (пункты 2/3) |
| открывается без обхода | Можно добавить в «Исключения» |
| блок по IP | Стратегия z2k не поможет — нужен VPN/прокси |
| имя не резолвится | Проблема DNS, а не DPI |
| сервер отказывает сам | Это не блокировка провайдера |

### Важно

- Это неофициальная надстройка для z2k, не связанная с авторами z2k, SmartTube или YouTube.
- Используйте на своём оборудовании и на свой риск, соблюдая законы вашей страны.
- `curl3.exe` — сторонняя сборка curl, распространяется по [лицензии curl](https://curl.se/docs/copyright.html) (© Daniel Stenberg и участники проекта).

---

## English

### Why

SmartTube (and regular YouTube on TVs, set-top boxes and phones) often fails to connect, loads forever, or cuts videos off midway. Usually the ISP is blocking or throttling YouTube/Google domains (`googlevideo.com`, `youtubei.googleapis.com`, `ytimg.com`, `ggpht.com`, etc.), and the bypass strategy z2k picked automatically has stopped working or is unstable.

**z2k-tool** is an add-on for z2k. Through the z2k panel on the router it:

1. exports every auto-selection (“Автоподбор”) row;
2. checks every domain **without the bypass** — the router itself connects to the site, which shows what the ISP is doing: blocking, throttling, or letting it through;
3. splits the domains into “blocked” and “not blocked” lists;
4. offers to:
   - add not-blocked domains to the z2k **Exclusions** list;
   - find a working strategy for blocked ones and **freeze** it:
     - **short search** — the first strategy that passes a test run and a confirmation run;
     - **long search** — every strategy in the pool is tested, the top three go to a final round, and the best one is frozen.

If no stable strategy is found, the row is restored to its original state and saved to `z2k-recheck.tsv` so you can re-check it later (menu item **[5]**).

The router is changed **only** in step 4 and **only** after you confirm. Pressing Ctrl+C restores the row currently being tested.

### Files

| File | What it is |
|---|---|
| `z2k-tool.exe` | Main program (console, Windows x64). Finds the z2k router on the local network automatically, lets you choose which domains to check and add your own domains that are not in auto-selection. Settings are stored in `z2k-tool.json`. |
| `z2k-tool.bat` | The same logic as a PowerShell script embedded in a `.bat` file — nothing compiled, you can read and edit the code. Settings are stored in `z2k-tool.ini`. |
| `curl3.exe` | curl 8.23.0 with HTTP/3 support (ngtcp2 + nghttp3). Needed to test **QUIC** auto-selection rows: the `curl.exe` bundled with Windows has no HTTP/3. Without it, QUIC rows are skipped. |

`z2k-tool.exe` and `z2k-tool.bat` are interchangeable — use either one. `curl3.exe` must be in **the same folder**.

### Requirements

- A router with **z2k** installed and its web panel enabled (default `http://192.168.7.1:8088`; you can enter another address and port at startup — they are remembered).
- The **z2k-detect** check module on the router (if it is missing, the tool tells you — reinstall z2k or enable it in menu **[Y]**).
- Panel password login must be **turned off** while the tool runs (z2k menu **[P] → [6]**).
- Windows 10/11 (ships with `curl.exe` and PowerShell).
- The PC must be on the same network as the router.

### Usage

1. Download all three files into one folder (or clone the repository).
2. Run `z2k-tool.exe` (or `z2k-tool.bat`).
3. The tool connects to the z2k panel, exports auto-selection and checks the domains — nothing on the router changes at this point (about 3–20 s per domain).
4. Pick an action from the menu:

```
[1] Not blocked — add to Exclusions
[2] Blocked — SHORT search (first working strategy)
[3] Blocked — LONG search (all strategies, best one)
[4] Export and check again
[5] Re-check rows with no strategy found
[0] Exit
```

For SmartTube, item **[2]** is usually enough; if videos still break off, use **[3]**.

> ⚠️ Domains that YouTube, Google and messengers depend on are marked **(!)** in the exclusions list. Exclude them only deliberately: if the ISP starts blocking them, SmartTube will stop working until you remove the domain from Exclusions.

Re-check the saved list only, without a full check:

```bat
z2k-tool.bat recheck
```

### Output

Everything goes into a `z2k-YYYYMMDD-HHMM` folder next to the program:

| File | Contents |
|---|---|
| `1-autopodbor-full.tsv` | Full auto-selection export |
| `2-check-report.tsv` | Detailed no-bypass check report |
| `3-blocked.txt` / `3-not-blocked.txt` | Blocked / not blocked domains |
| `4-exclusions.txt` | What was added to Exclusions |
| `5-strategies.tsv` | Strategy search log |
| `5-matrix.tsv` | Long search: result of every strategy |
| `6-not-found.tsv` | Rows with no stable strategy |

`.tsv` files are UTF-8 with BOM, so Excel and Notepad show Cyrillic correctly.

### Tuning (`z2k-tool.ini`, for the `.bat`)

```ini
Router=192.168.7.1
Port=8088
Timeout=7        ; per-request timeout, s
Settle=3         ; pause after switching strategy, s
ShortTries=5     ; short search: tries per strategy
ShortConfirm=10  ; short search: confirmation run
LongTries=6      ; long search: tries per strategy
Finalists=3      ; strategies that reach the final
FinalTries=15    ; tries in the final
MinRate=0.9      ; minimum success rate required to freeze
```

### Check results explained

| Result | What to do |
|---|---|
| BLOCKED / THROTTLED | Find a strategy (items 2/3) |
| opens without bypass | Can be added to Exclusions |
| IP block | A z2k strategy won't help — use a VPN/proxy |
| name does not resolve | DNS problem, not DPI |
| server refuses by itself | Not an ISP block |

### Notes

- This is an unofficial add-on for z2k and is not affiliated with the authors of z2k, SmartTube or YouTube.
- Use it on your own equipment at your own risk and in accordance with the laws of your country.
- `curl3.exe` is a third-party curl build distributed under the [curl license](https://curl.se/docs/copyright.html) (© Daniel Stenberg and contributors).
