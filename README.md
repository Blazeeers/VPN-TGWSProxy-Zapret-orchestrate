# VPN-TGWSProxy-Zapret-orchestrate

**VPN (Xray + sing-box TUN) + автоматический обход DPI (zapret) + прокси Telegram
(tg-ws-proxy) для Omarchy.**

Персональный набор для Omarchy (Arch/Hyprland), который держит ноутбук
подключённым и «раскрытым» в разных сетях:

- **omavpn** — VPN-клиент (Xray-core + sing-box TUN) по подписке Happ-формата,
  с виджетом в панели Omarchy.
- **zapret-autotune** — автоматический подбор стратегии DPI-обхода (zapret/nfqws)
  под текущую сеть, с кэшем по сетям и откатом на VPN.
- **tg-ws-proxy** — локальный MTProto-прокси через WebSocket для ускорения
  Telegram Desktop.
- **Telegram-бот для инбокса** (внешний, `telegram-inbox-bot`) — его Bot API
  остаётся внутри VPN, см. [docs/telegram.md](docs/telegram.md).

> Это личная конфигурация под конкретную машину. В репозитории нет секретов:
> URL подписки и ключи хранятся вне кода (см. «Безопасность»).

---

## Содержание

- [Как всё связано](#как-всё-связано)
- [Компоненты](#компоненты)
- [Установка](#установка)
  - [1. omavpn](#1-omavpn)
  - [2. zapret + автотюн](#2-zapret--автотюн)
  - [3. tg-ws-proxy](#3-tg-ws-proxy)
- [Подписки: форматы и совместимость](#подписки-форматы-и-совместимость)
- [Поведение по сетям](#поведение-по-сетям)
  - [Надзиратель (omavpn-guard)](#надзиратель-omavpn-guard)
- [Использование](#использование)
- [Файлы и пути](#файлы-и-пути)
- [Документация](#документация)
- [Зависимости и привилегии](#зависимости-и-привилегии)
  - [Пароль при включении VPN](#пароль-при-включении-vpn)
- [Публикация в Omarchy Marketplace](#публикация-в-omarchy-marketplace)
- [Благодарности](#благодарности)
- [Безопасность](#безопасность)
- [Лицензия](#лицензия)

---

## Как всё связано

```
  Telegram Desktop ──MTProto──► tg-ws-proxy (127.0.0.1:1443) ──WebSocket──► Telegram DC
                                              (напрямую, мимо VPN)

  Telegram bot ──HTTPS──► api.telegram.org  ──► VPN (напрямую режется)

  MAX (браузер) ──HTTPS──► max.ru (напрямую, вне туннеля)

  Discord / YouTube ──► zapret (nfqws на WLAN) ──► напрямую, если стратегия работает
                         └─ если нет ──► в туннель через omavpn

  остальной трафик ─────────► sing-box TUN (omavpn0) ──► Xray ──► сервер
```

`omavpn` строит TUN и маршрутизирует почти всё через прокси. Часть трафика
принудительно выводится **напрямую** правилами sing-box:

| Правило | Что исключается | Зачем |
|---|---|---|
| `ip_is_private` | LAN, localhost | локальная сеть, петли |
| `domain_suffix: direct_domains()` | MAX, Яндекс, Discord, YouTube | см. [docs/zapret.md](docs/zapret.md), [docs/telegram.md](docs/telegram.md); российские сервисы (MAX, Яндекс) — всегда мимо VPN |
| `process_name: tg-ws-proxy/Telegram` | Telegram Desktop и локальный MTProto-прокси | трафик WS-прокси должен идти напрямую |
| `ip_cidr`/`domain` серверов подписки | адреса VPN-серверов | чтобы туннель не зациклился |
| `port: 25,465,587` | SMTP | не прогонять почту через прокси |
| `process_name: xray` | сам Xray | его соединения к серверу — напрямую |
| `ip_version: 6 → block` | весь IPv6 | у Xray-профилей только IPv4 |

**Bot API Telegram намеренно остаётся в VPN**: прямой доступ к `api.telegram.org`
у провайдера режется, а `tg-ws-proxy` умеет только MTProto, не Bot API.

Сверху за всем этим следит `omavpn-guard`: раз в 10 минут проверяет, что
YouTube, Discord и Telegram действительно открываются, и лечит, если нет —
поднимает VPN, чинит профиль, перезапускает прокси, перебирает ноды или просит
автотюн перепроверить стратегии. VPN при этом не выключается никогда.

---

## Компоненты

| Компонент | Роль | Расположение |
|---|---|---|
| `omavpn` (CLI) | управление VPN | `~/.local/bin/omavpn` |
| `bin/bypass-status` | агрегатор статуса всех обходов (JSON) | `~/.local/bin/bypass-status` |
| `bin/omavpn-guard` | надзиратель: следит, что YouTube/Discord/Telegram работают, и лечит | `~/.local/bin/omavpn-guard` |
| `shell-plugin/bypass-status` | виджет «Обходы» — статусы всего | `~/.config/omarchy/plugins/io.github.blazeeers.omavpn` |
| `zapret/*` | DPI-обход и автотюн | `/usr/local/bin`, `/opt/zapret`, `/etc`, `/var/lib` |
| `tgwsproxy/install.sh` | установка tg-ws-proxy | `~/.local/bin/tg-ws-proxy` |

---

## Установка

### 1. omavpn

```bash
cd omavpn
./install.sh
```

Скрипт скачает Xray и sing-box в `~/.local/share/omavpn/bin`, выдаст
`cap_net_admin,cap_net_raw` на `sing-box` (нужен `sudo` один раз), поставит CLI,
виджет панели и **надзиратель `omavpn-guard`** с его таймерами.

**Чтобы VPN включался без запроса пароля**, поставь правило polkit (один раз):

```bash
sudo install -m 0644 docs/polkit/49-omavpn-resolved.rules /etc/polkit-1/rules.d/
sudo systemctl restart polkit
```

Перед установкой замени `USER_NAME` в файле на своё имя пользователя. Подробнее —
[Пароль при включении VPN](#пароль-при-включении-vpn).

**Задай URL подписки** (в коде его нет):

```bash
printf '%s\n' 'https://<твой-подписочный-URL>' > ~/.config/omavpn/subscription
chmod 600 ~/.config/omavpn/subscription
omavpn update
```

Либо через переменную `OMAVPN_SUB_URL`.

Удаление: `./uninstall.sh` (данные оставить) или `./uninstall.sh --purge`.

### 2. zapret + автотюн

```bash
# пакет
yay -S zapret-git        # тянет ipset, libnetfilter_queue, bind, nmap

# сценарий под нашу связку: WAN, hostlist-режим, исключение серверов omavpn
sudo bash zapret/zapret-setup.sh
sudo bash zapret/zapret-hostlist.sh

# автотюнер: сервис, таймер, хук NetworkManager
sudo bash zapret/zapret-autotune-install.sh
```

`zapret-autotune` сам подбирает стратегию под каждую сеть и при необходимости
поднимает VPN. Подробности и внутренности — [docs/zapret.md](docs/zapret.md).

### 3. tg-ws-proxy

```bash
bash tgwsproxy/install.sh
```

Ставит `tg-ws-proxy` в `~/.local/bin`, иконку, `.desktop` и автозапуск, запускает.
Затем подключи Telegram Desktop по ссылке `tg://proxy?...` (скрипт покажет) или
вручную: `127.0.0.1:1443`, secret из `~/.config/TgWsProxy/config.json`.
Детали — [docs/telegram.md](docs/telegram.md).

---

## Подписки: форматы и совместимость

`omavpn` не привязан к конкретному провайдеру — важен только формат подписки.
Формат определяется автоматически.

Поддерживаются:

1. **Happ / Xray full JSON** — массив профилей, каждый с `remarks`, `inbounds`,
   `outbounds`, `routing` (то, что отдаёт приложение Happ по кнопке «Happ»).
   Также принимается `{"configs":[...]}` / `{"data":[...]}` и тот же JSON в base64.
2. **Обычные share-ссылки**, по одной на строку (при необходимости — вся подписка
   в base64):
   `vless://`, `vmess://`, `trojan://`, `ss://` (shadowsocks), `socks://`.
   Поддерживаются транспорты `tcp`, `ws`, `grpc`, `httpupgrade`, `xhttp`, `http`
   и безопасность `none`/`tls`/`reality` (включая `flow=xtls-rprx-vision`,
   `sni`, `fp`, `pbk`, `sid`, `spx`, `alpn`).

Ограничения:

- Транспортом прокси выступает **Xray-core**, поэтому outbound'ы ограничены его
  возможностями: `vless`, `vmess`, `trojan`, `shadowsocks` (+ `socks`).
  Схемы `hysteria2`/`tuic`/`wireguard` в share-link подписке пропускаются — Xray
  их не умеет. Если в подписке только они, будет ошибка.
- Запрос подписки идёт с `User-Agent: Happ/1.0`, поэтому провайдеры, отдающие
  Happ-формат по этому UA, подходят автоматически.

Сменить провайдера/подписку:

```bash
printf '%s\n' 'https://<новый-URL>' > ~/.config/omavpn/subscription
omavpn update
omavpn profiles     # список профилей
omavpn nodes        # узлы выбранного профиля
```

---

## Поведение по сетям

Автотюн определяет сеть по SSID Wi-Fi (или MAC шлюза для проводной) и хранит
решение в `/var/lib/zapret-autotune/<ключ>.strategy`:

| Решение | Когда | Что делает |
|---|---|---|
| `off` | сеть ничего не блокирует | zapret выключен, всё напрямую |
| `<индекс>` | одна из встроенных стратегий работает | zapret включён, Discord/YouTube напрямую |
| `custom` | стратегию нашёл `blockcheck` | zapret включён с сохранённой строкой |
| `vpn` | обход не помог | рабочие напрямую сервисы остаются напрямую (например, YouTube), остальные — в туннеле; при `AUTO_VPN=1` поднимается omavpn; обход перепроверяется каждые 30 мин (`RETRY_SECONDS`) |

«YouTube работает» проверяется по-настоящему: открывается страница **и** качается
кусок видео с `googlevideo` (через `yt-dlp`, порог ≥100 КиБ/с). Если страница
открывается, а видео тормозит, обход ищется сразу для **YouTube и Discord**
вместе; если ни одна стратегия не помогает — оба сервиса уходят в VPN.

Триггеры запуска: смена сети (NetworkManager dispatcher), загрузка
(`OnBootSec=3min`), периодически (`OnUnitActiveSec=15min`). Применяется только
изменившееся — VPN и zapret не «мигают».

### Надзиратель (omavpn-guard)

Автотюн выбирает путь, но не следит за результатом. Это делает `omavpn-guard`:
каждые 10 минут проверяет, что YouTube (страница + превью + медиа-CDN), Discord
(шлюз + сайт) и Telegram (юнит `tg-ws-proxy` + API) действительно открываются.

Если что-то не работает, лечение идёт от мягкого к жёсткому: перезапуск
`tg-ws-proxy` → `omavpn heal` → перепрос стратегий zapret → перебор нод → и лишь
в крайнем случае сломанный сервис уходит в VPN.

Что важно понимать:

- **VPN не выключается** — он нужен для остальных заблокированных сайтов.
  Меняется только путь YouTube/Discord/Telegram: пока обход справляется, они
  идут мимо VPN.
- Ручная смена пути — не чаще раза в 15 минут и не больше трёх раз в час: если
  автотюн и сторож начнут тянуть файл в разные стороны, сторож отступает.
- После трёх неудач подряд — пауза по нарастающей (до часа) и уведомление.

Подробности — [docs/guard.md](docs/guard.md).

### Аудит маршрутов (route-audit)

Отдельная страховка от «домен заблокировали, а маршрут остался прежним».
Каждые 10 минут `bypass-status --route-audit` прогоняет список доменов
(YouTube, `youtubei.googleapis.com`, `i.ytimg.com`, `redirector.googlevideo.com`,
Discord, Telegram Bot API, DeepSeek) и смотрит не «открывается ли сайт», а
**отвечает ли конкретный домен по своему текущему пути**. Аудит двусторонний:

1. проверка «как есть» (curl по текущему маршруту через TUN);
2. путь `direct` и провал — проверка через локальный SOCKS (порт берётся из
   `xray.json`); хорошо — `route set <домен> proxy`;
3. путь `proxy` и провал — домен переводится в `direct`, VPN перезапускается и
   проверяется снова; не помогло и там — оверрайд снимается, домен попадает в
   «не отвечают». Так ловится обратная поломка: `zapret-autotune` перевёл сеть
   в режим `vpn`, и видеотрафик `googlevideo.com` ушёл в туннель, где не
   работает (22.10.2026, 02:19);
4. плохо обоими путями — маршрут не меняется (это не про маршрут).

Оверрайды ставятся пачкой без перезапуска, затем один `omavpn restart` на весь
прогон. Домены из `ALWAYS_DIRECT_DOMAINS` в туннель не уводятся, из
`ALWAYS_PROXY_DOMAINS` — не выпускаются напрямую; ручные оверрайды аудит не
трогает. Оверрайды лежат в `~/.config/omavpn/route_overrides.json` и
**сильнее** `direct_domains.txt` (его перезаписывает `zapret-autotune`).

Два предохранителя, без которых обратное направление вреднее поломки:

- **прямого пути может не быть вовсе.** Пока `zapret.service` не `active` или
  стратегия сети = `vpn` (autotune сам считает обход нерабочим), YouTube и
  Discord в direct не переводятся: в `detail` пишется причина, маршрут остаётся
  прежним. Домены, которым обход не нужен (`api.deepseek.com`,
  `api.telegram.org`), проверка не касается;
- **память между прогонами** (`~/.cache/omavpn/route-audit-state.json`):
  переключение в одну сторону — не чаще `6 ч × 2^min(fails,3)` (12 → 24 → 48 ч
  после неудач), успех сбрасывает счётчик. Иначе выключенный обход давал по два
  обрыва трафика каждые 10 минут.

Видео YouTube (`youtube.com`, `googlevideo.com`, `ytimg.com`, `youtu.be`,
`youtubekids.com`, …) идёт напрямую **по умолчанию** — встроенный список
`BUILTIN_DIRECT_DOMAINS` в конфиге стоит перед `direct_domains.txt`, поэтому
решение autotune «всё в vpn» видео в туннель не уводит. В `route list` у таких
доменов источник `default-direct`; переопределяется обычным
`omavpn route set <домен> proxy`.

Раз в сутки (`--route-audit-recheck`) **свои** оверрайды старше 24 часов
снимаются и перепроверяются: если direct снова работает — домен остаётся
напрямую, если нет — оверрайд возвращается. Если перезапуск VPN не удался,
direct не проверяется вовсе (`action: "keep"`): правило ещё не применилось, и
проба дала бы ложное «direct снова работает». Ручные оверрайды перепроверка не
снимает никогда — как и записи аудита, если они перекрыты ручным ключом
родительского домена.

Поводом послужила реальная поломка 22.10.2026: `youtubei.googleapis.com`
(служебный API плеера) блокируется напрямую наглухо, zapret его не пробивает, и
YouTube «тормозил» при живом видео. Теперь домен всегда идёт через VPN
(`ALWAYS_PROXY_DOMAINS`), а аудит ловит такие случаи сам.

```bash
omavpn route list                          # домен, путь, источник, возраст, причина
omavpn route set example.com proxy --reason "API не отвечает напрямую"
omavpn route unset example.com             # вернуть обычный приоритет
bypass-status --route-audit                # прогнать аудит вручную
bypass-status --route-audit-recheck        # перепроверить старые оверрайды
```

Подробности — [docs/route-audit.md](docs/route-audit.md).

---

## Использование

### omavpn

```bash
omavpn on | off | toggle | restart
omavpn --json status
omavpn profiles | nodes
omavpn profile 5 | node 0
omavpn mode tun|proxy
omavpn strict on|off
omavpn route list | route set <домен> proxy|direct | route unset <домен>
omavpn check | logs | update
```

Клик по иконке в панели Omarchy — popup с профилем, сервером, тумблером и т.д.

### Типичные задачи

```bash
# подключиться к лучшему узлу профиля «Авто»
omavpn update && omavpn profile 0 && omavpn on

# выбрать конкретный сервер и переподключиться
omavpn nodes            # посмотреть индексы узлов
omavpn node 3           # при активном VPN переподключит автоматически

# только SOCKS/HTTP-прокси без системного TUN
omavpn mode proxy

# понять, что реально работает
omavpn check            # сравнит внешний IP напрямую и через прокси
omavpn --json status | python3 -m json.tool | head -30
```

Автоподключение при входе — тумблер «Подключаться при входе» в настройках
виджета панели (`autoconnect`).

### Виджет «Обходы» (Bypass Status)

Отдельный виджет в панели показывает и проверяет **все** обходы сразу. Верхняя
карточка — VPN, ниже строки сервисов, снизу — кнопки действий.

- **VPN** — состояние, профиль (регион), сервер, режим (TUN/SOCKS), uptime и
  кнопка «Включить/Выключить». По строке **«Регионы и серверы»** раскрывается
  список регионов подписки (у лучшего стоит ★, у текущего — ●) и серверов
  выбранного региона с результатами проб (med, p90, потери). Клик по региону или
  серверу переключает на него; если VPN включён, он сразу переподключается.
  **Пароль при включении/выключении не запрашивается**: TUN поднимается бинарём
  `sing-box` с `cap_net_admin` (ставится один раз установщиком), весь путь идёт от
  обычного пользователя. Если capability потерялась, виджет честно пишет это и
  показывает одну команду для восстановления.
- **zapret (DPI)** — служба и стратегия для текущей сети; во время фонового
  перебора — «идёт подбор»;
- **YouTube** — страница **и** реальная скорость видео с `googlevideo`
  (`yt-dlp`), поэтому виден троттлинг, а не только «страница открылась»;
- **Discord** — страница, шлюз (`/api/v9/gateway`) и CDN;
- **DeepSeek API** — доступность `api.deepseek.com`. Этот домен **всегда идёт
  мимо туннеля** (в `ALWAYS_DIRECT_DOMAINS`): через зарубежный выход VPN ассистент
  периодически терял связь с DeepSeek, напрямую из РФ API отвечает стабильно;
- **tg-ws-proxy** — слушает ли локальный порт;
- **Обновления** — строка появляется, если для zapret или tg-ws-proxy есть новая
  версия (нажатие обновляет компоненты);
- **Маршруты** — строка «маршруты: проверено N, исправлено M» или «маршруты в
  порядке» (то же в подсказке иконки) и кнопка **«Проверить маршруты»**. Домен,
  который не отвечает своим путём, уходит на рабочий — см.
  [docs/route-audit.md](docs/route-audit.md).

#### Монитор работоспособности (каждые 5 минут)

Виджет сам раз в 5 минут запускает `bypass-status --health` — комплексный тест
**текущей конфигурации** (то же делает кнопка **«Проверить всё»**):

1. VPN: идут ли данные через туннель (SOCKS + внешний IP), жив ли TUN;
2. zapret: активна ли служба и какая стратегия применена;
3. YouTube: страница + видео (ловит троттлинг);
4. Discord: страница, шлюз, CDN;
5. DeepSeek API и Telegram API (через прокси VPN, если он включён);
6. tg-ws-proxy: порт.

Результат — вердикт «всё работает / есть замечания / не работает», время и
длительность проверки; он кэшируется в `~/.cache/<cli>/health.json` и показывается
в строках виджета. Если VPN подключён, но трафик не идёт, монитор **сам лечит**
(`omavpn heal`): перезапускает туннель, а если не помогло — перебирает серверы
профиля и переключается на живой. Лечение ограничено одним разом в 10 минут,
чтобы не дёргать сеть.

Значок в панели — сгенерированные пиктограммы из `icons/` (щит с замком,
молния, play, геймпад, самолётик, галочка, восклицание, обновление, кубики
региона). Он меняется по состоянию:

| Иконка | Состояние | Цвет |
|---|---|---|
| `warning` | что-то не работает | тревожный |
| `warning` | есть замечания (жёлтые строки) | янтарный |
| `refresh` | идёт подбор стратегии или серверов | янтарный |
| `check` | всё в порядке | акцентный |
| `vpn` | данных ещё нет / VPN выключен | обычный |

Данные берёт из `bypass-status --json` (обновление раз в 4 с). Скрипт понимает и
`omavpn`, и `wowvpn` — CLI определяется автоматически.

Проверка обновлений компонентов идёт **автоматически раз в сутки** пользовательским
таймером `omavpn-updates.timer` (`bypass-status --updates`): сверяет zapret с AUR
(`zapret-git`) и GitHub, а tg-ws-proxy — с GitHub-релизами; результат кэшируется в
`~/.cache/<cli>/updates.json`. Вручную: `bypass-status --updates`.

Если строка **«Обновления»** есть в списке — по ней можно **нажать**, и компоненты
обновятся автоматически (`bypass-status --update-components`):

- **tg-ws-proxy** — скачивается последний релиз с GitHub, sha256 сверяется с
  дайджестом из API релиза, бинарь подменяется (старый — в `tg-ws-proxy.bak`),
  запущенный процесс перезапускается;
- **zapret** — системный пакет: обновляется через `pkexec` + `pacman`, а если
  графического агента polkit нет — открывается терминал с `yay -S zapret-git`.

Кнопки: **Проверить всё** (комплексный тест текущей конфигурации),
**Подобрать лучший** (тест всех регионов и серверов, см. ниже), **Тест стратегий**
(принудительный перебор zapret через path-юнит `zapret-autotune-rescan.path`),
**Обновить подписку** и **Включить/Выключить** VPN в карточке.

### Подбор лучшего региона и сервера (кнопка «Подобрать лучший»)

Кнопка **«Подобрать лучший»** прогоняет **все регионы** подписки, а не только
текущий: на каждую ноду поднимается отдельный временный Xray на свободном локальном
SOCKS-порту (живой туннель не трогается) и через него гоняются реальные пробы до
`discord.com/api/v9/gateway`.

- быстрый проход — по 2 пробы с таймаутом 3,5 с на каждый сервер всех регионов
  (42 сервера в подписке — около 2,5 минут), затем подтверждающая серия из 6 проб
  на победителе, чтобы не выбрать случайно «быструю» ноду;
- по каждой ноде считаются медиана, p90, потери и оценка
  `med×0.4 + p90×0.6 + потери×1.5` (чем меньше, тем лучше);
- прогресс пишется в `~/.cache/omavpn/probe.json` (`phase`, `nodes_done/nodes_total`,
  текущий регион и сервер), в карточке VPN видно полосу прогресса;
- итог — лучшая пара «регион + сервер»: она применяется в настройках, а если VPN
  включён, туннель переподключается на неё; в строке появляется «★ регион · сервер»;
- старые серверы помечаются «нет ответа» и больше не перебираются в этом тесте.

Вручную:

```
omavpn best                 # только измерить и показать лучшую пару
omavpn best --apply         # измерить и применить (переподключиться, если VPN включён)
omavpn best --probes-quick 3 --timeout-quick 5
omavpn probe                # тест серверов только текущего профиля
omavpn probe --node 12      # один сервер
omavpn heal                 # перезапуск/переключение ноды, если туннель не работает
bypass-status --optimize    # запустить подбор фоном (то же делает кнопка)
bypass-status --health      # комплексная проверка текущей конфигурации
bypass-status --route-audit # аудит маршрутов: нерабочий домен → рабочий путь
```

Установка отдельно:

```bash
install -m 0755 bin/bypass-status ~/.local/bin/bypass-status
ID=io.github.blazeeers.omavpn
mkdir -p ~/.config/omarchy/plugins/$ID/icons
cp shell-plugin/bypass-status/manifest.json shell-plugin/bypass-status/Panel.qml ~/.config/omarchy/plugins/$ID/
cp shell-plugin/bypass-status/icons/*.png ~/.config/omarchy/plugins/$ID/icons/
omarchy-shell shell rescanPlugins
omarchy plugin enable $ID
omarchy bar move $ID --section right
omarchy restart shell
```

### Один плагин — один виджет

Плагин один: `io.github.blazeeers.omavpn` (этот репозиторий). Его виджет в панели —
**«Обходы»** (`shell-plugin/bypass-status/Panel.qml`, прописан в
`entryPoints.barWidget` корневого манифеста). Отдельного виджета подключения VPN
больше нет (`shell-plugin/omavpn/` удалён в 2.3.0): его функции — включение и
выключение VPN (правый клик по иконке), выбор страны и сервера, «Подключаться при
входе» — перенесены в «Обходы», поэтому вторая кнопка в панели не нужна.

Маркетплейс ставит плагин из этого репозитория и обновляет его из него же:
`omarchy plugin add <url>` ставит, `omarchy plugin update io.github.blazeeers.omavpn`
подтягивает новую версию, каталог (plugins.omarchy.org) пересобирается ежедневно в
04:17 UTC и читает версию из `manifest.json`. Отдельная заявка на обновление не
нужна — достаточно запушить новую версию. После обновления плагин помечается
`update-unverified`: галочку «verified» возвращает мейнтейнер после ревью, на
установку это не влияет.

Windows-версия (`bypass-tray`) — отдельное приложение в своём репозитории, к этому
плагину отношения не имеет.

### zapret-autotune

```bash
sudo zapret-autotune run      # применить/подобрать для текущей сети
sudo zapret-autotune rescan   # принудительно переподобрать
zapret-autotune show          # кэш сетей
sudo zapret-autotune tune-wan # только выставить IFACE_WAN
sudo zapret-autotune probe-selftest  # проверить изоляцию фонового пробника
```

Перебор новых стратегий идёт **изолированно** — трафиком служебного пользователя
`zapret-probe`, пока Discord/YouTube остаются в VPN, поэтому интернет и сервисы во
время проверки не прерываются.

Ручное переключение пресетов (аналог `.bat`-стратегий на Windows):

```bash
sudo bash zapret/zapret-strategy.sh list
sudo bash zapret/zapret-strategy.sh scan
sudo bash zapret/zapret-strategy.sh set flowseal
```

Полный перебор штатным `blockcheck` (10–30 мин, VPN выключится):

```bash
sudo bash zapret/zapret-blockcheck.sh standard
```

---

## Файлы и пути

| Путь | Назначение |
|---|---|
| `~/.local/bin/omavpn` | CLI |
| `~/.local/share/omavpn/bin/` | бинари `xray`, `sing-box` |
| `~/.config/omavpn/settings.json` | профиль/нода/режим |
| `~/.config/omavpn/subscription` | URL подписки (секрет, 600) |
| `~/.config/omavpn/direct_domains.txt` | переопределение direct-списка |
| `~/.config/omavpn/route_overrides.json` | оверрайды маршрутов доменов (сильнее `direct_domains.txt`) |
| `~/.cache/omavpn/route-audit.json` | результат последнего аудита маршрутов |
| `~/.cache/omavpn/route-audit-state.json` | кулдауны переключений между прогонами (`fails`/`ts`) |
| `~/.local/state/omavpn/` | конфиги, pid, логи |
| `~/.cache/omavpn/sub.json` | кэш подписки |
| `/opt/zapret/` | zapret, бинарь `nfqws`, списки, конфиг |
| `/etc/zapret-autotune.conf` | USER_NAME, USER_HOME, AUTO_VPN |
| `/var/lib/zapret-autotune/` | кэш стратегий по сетям |
| `/var/log/zapret-autotune.log` | лог автотюна |
| `/var/log/zapret-blockcheck.log` | лог глубокого теста |
| `~/.config/TgWsProxy/config.json` | конфиг tg-ws-proxy (secret, port) |
| `~/.config/autostart/tg-ws-proxy.desktop` | автозапуск tg-ws-proxy |
| `manifest.json` (корень репозитория) | манифест плагина (id `io.github.blazeeers.omavpn`) |
| `~/.config/omarchy/plugins/io.github.blazeeers.omavpn/` | установленный плагин VPN |
| `~/.local/bin/bypass-status` | агрегатор статусов обходов (JSON) |
| `~/.local/bin/omavpn-guard` | надзиратель за обходами |
| `~/.local/state/omavpn-guard/` | его журнал, намерение, история переключений (0700) |
| `~/.config/systemd/user/omavpn-guard.*` | юнит и таймер надзирателя |
| `~/.config/systemd/user/omavpn-route-audit.*` | таймер аудита маршрутов (каждые 10 мин) |
| `~/.config/systemd/user/omavpn-route-recheck.*` | таймер перепроверки оверрайдов (раз в сутки) |
| `~/.config/systemd/user/omavpn-autostart.service` | поднятие VPN при входе |
| `~/.local/state/omavpn-guard/intent` | включён ли VPN по решению пользователя |
| `shell-plugin/bypass-status/` | QML виджета «Обходы» |
| `~/.config/omarchy/plugins/io.github.blazeeers.omavpn/` | установленный виджет «Обходы» |

---

## Документация

- [docs/architecture.md](docs/architecture.md) — как устроена маршрутизация и связка сервисов.
- [docs/guard.md](docs/guard.md) — надзиратель за обходами: что проверяет и как лечит.
- [docs/route-audit.md](docs/route-audit.md) — аудит маршрутов: оверрайды, пробы, перепроверка.
- [docs/zapret.md](docs/zapret.md) — DPI-обход: конфиг, стратегии, автотюн, blockcheck.
- [docs/telegram.md](docs/telegram.md) — Telegram Desktop, tg-ws-proxy и бот.
- [docs/troubleshooting.md](docs/troubleshooting.md) — что делать, если что-то отвалилось.
- [CHANGELOG.md](CHANGELOG.md) — история изменений по версиям.

---

## Зависимости и привилегии

Внешние компоненты (полный список и лицензии — в [THIRD_PARTY.md](THIRD_PARTY.md)):

| Компонент | Как ставится | Откуда |
|---|---|---|
| Xray-core | `install.sh` → `~/.local/share/omavpn/bin` | релиз XTLS/Xray-core |
| sing-box | `install.sh` | релиз SagerNet/sing-box |
| zapret (nfqws) | `yay -S zapret-git` | AUR / bol-van/zapret |
| tg-ws-proxy | `tgwsproxy/install.sh` → `~/.local/bin` | релиз Flowseal/tg-ws-proxy |

Привилегии и сервисы (что именно требует root и зачем):

| Действие | Права | Назначение |
|---|---|---|
| `setcap cap_net_admin,cap_net_raw` на `sing-box` | **root, разово** | TUN без полного root |
| `zapret-setup.sh`, `zapret-hostlist.sh` | **root** | конфиг + правила nftables, исключение серверов |
| `zapret-autotune-install.sh` | **root** | системный сервис `zapret-autotune.service` + таймер |
| `zapret.service` | root (systemd) | nfqws от пользователя `zapret` (`--user`) |
| `zapret-autotune.timer` + NM dispatcher | root (systemd) | автоподбор стратегии по сети |
| CLI `omavpn`, виджет, tg-ws-proxy | обычный пользователь | — |
| `omavpn-guard` и его таймеры | обычный пользователь (`systemd --user`) | надзор за обходами |
| правило polkit для `resolve1` | **root, разово** | VPN без запроса пароля |

### Пароль при включении VPN

`sing-box` при поднятии TUN (`auto_route`) перенастраивает DNS через
systemd-resolved — это действие D-Bus `org.freedesktop.resolve1`, и polkit по
умолчанию спрашивает на него пароль: по запросу на каждое `omavpn on/off`,
включая перезапуски из таймера.

Правило `docs/polkit/49-omavpn-resolved.rules` разрешает шесть нужных действий
своему пользователю в локальной активной сессии. Отключение DNSSEC и публикация
mDNS-записей по-прежнему требуют пароля.

```bash
# замени USER_NAME в файле на свой логин
sudo install -m 0644 docs/polkit/49-omavpn-resolved.rules /etc/polkit-1/rules.d/
sudo systemctl restart polkit
```

Без правила всё работает, но при каждом включении и выключении VPN будет
появляться запрос пароля.

Сетевые обращения: загрузка подписки по HTTPS, Xray/sing-box к серверам
провайдера, tg-ws-proxy к Telegram. Секретов в репозитории нет. Внешних сборок
кроме скачивания готовых бинарей нет; симлинков в каталоге плагина нет.

Утилиты, которые нужны в системе (проверяются `install.sh`): `curl`, `python3`,
`tar`, `sha256sum`, `jq`, `ip`, `flock`, `getcap`; опционально `notify-send`
(уведомления надзирателя) и `nmcli` (определение сети).

---

## Публикация в Omarchy Marketplace

Репозиторий подготовлен по [гайду публикации](https://plugins.omarchy.org/publish.html):

- публичный GitHub-репозиторий;
- `manifest.json` **в корне** репозитория с namespaced id
  `io.github.blazeeers.omavpn` (замени `blazeeers` на свой GitHub-логин);
- README и LICENSE;
- безопасные установка (`install.sh`) и удаление (`uninstall.sh`).

```bash
# установка как плагина Omarchy (или ./install.sh)
omarchy plugin add https://github.com/<ты>/omavpn.git --enable
# удаление (или ./uninstall.sh)
omarchy plugin remove io.github.blazeeers.omavpn
```

Проверка перед подачей:

```bash
PLUGIN_ID="io.github.blazeeers.omavpn"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
omarchy plugin validate "$PLUGIN_DIR"
qmllint -I "$OMARCHY_PATH/shell" "$PLUGIN_DIR/Panel.qml"
```

Затем заявка через форму
[Submit a plugin](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml)
(ссылка на репозиторий, категория, теги). Опционально — `preview.png` рядом с
манифестом. Плагины выполняются без песочницы: см. таблицу привилегий выше.

---

## Благодарности

Проект использует и переосмысляет чужие работы (полный список — в
[THIRD_PARTY.md](THIRD_PARTY.md)):

- **zapret** — [bol-van](https://github.com/bol-van/zapret), MIT. Обход DPI.
- **tg-ws-proxy** — [Flowseal](https://github.com/Flowseal/tg-ws-proxy), MIT.
  Ускорение Telegram Desktop.
- **Happ** — [Happ-proxy](https://github.com/Happ-proxy/happ-desktop). Формат
  подписки (Xray full JSON) и идея клиента.
- **Xray-core**, **sing-box**, **Omarchy** — см. [THIRD_PARTY.md](THIRD_PARTY.md).

Этот репозиторий собран с использованием агента **OpenCode**
(<https://opencode.ai>) и модели **DeepSeek V4.1 Flash**.

---

## Безопасность

- В репозитории **нет** URL подписки и ключей. URL берётся из
  `~/.config/omavpn/subscription` (режим 600) или `OMAVPN_SUB_URL`.
- `secret` tg-ws-proxy генерируется локально в `~/.config/TgWsProxy/config.json`.
- **Артефакты пиннингуются и проверяются по sha256** до запуска/выдачи
  capabilities: Xray, sing-box (`install.sh`) и tg-ws-proxy
  (`tgwsproxy/install.sh`). Версии и хеши задаются переменными в начале скриптов
  (`XRAY_VER`/`XRAY_SHA256`, `SB_VER`/`SB_SHA256`,
  `TGWSPROXY_VERSION`/`TGWSPROXY_SHA256`).
- Секретные данные (`~/.cache/omavpn/sub.json`, `~/.local/state/omavpn/*.json`,
  логи, pid) создаются с правами **0600**, каталоги конфига/состояния/кэша —
  **0700**; CLI работает с `umask 077`.
- Автотюн пишет пользовательский `direct_domains.txt` **от имени пользователя**
  (`runuser`), не следуя root'ом по симлинкам и не меняя владельца цели.
- zapret/автотюн работают от root, но не хранят секретов; `nfqws` запускается
  с понижением привилегий (`--user=zapret`).
- Скрипты автотюна, устанавливаемые в `/usr/local/bin`, принадлежат root —
  пользовательские процессы не могут их подменить.

## Лицензия

MIT (см. [LICENSE](LICENSE)). Сторонние компоненты, их авторы и лицензии —
[THIRD_PARTY.md](THIRD_PARTY.md).
