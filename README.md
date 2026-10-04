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
- [Использование](#использование)
- [Файлы и пути](#файлы-и-пути)
- [Документация](#документация)
- [Зависимости и привилегии](#зависимости-и-привилегии)
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

---

## Компоненты

| Компонент | Роль | Расположение |
|---|---|---|
| `omavpn` (CLI) | управление VPN | `~/.local/bin/omavpn` |
| `shell-plugin/omavpn` | виджет управления VPN в панели Omarchy | `~/.config/omarchy/plugins/io.github.blazeeers.omavpn` |
| `bin/bypass-status` | агрегатор статуса всех обходов (JSON) | `~/.local/bin/bypass-status` |
| `shell-plugin/bypass-status` | виджет «Обходы» — статусы всего | `~/.config/omarchy/plugins/io.github.blazeeers.bypass-status` |
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
`cap_net_admin,cap_net_raw` на `sing-box` (нужен `sudo` один раз), поставит CLI и
виджет панели.

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
| `vpn` | ничего не помогло | Discord/YouTube уходят в туннель, при `AUTO_VPN=1` поднимается omavpn |

Триггеры запуска: смена сети (NetworkManager dispatcher), загрузка
(`OnBootSec=3min`), периодически (`OnUnitActiveSec=15min`). Применяется только
изменившееся — VPN и zapret не «мигают».

---

## Использование

### omavpn

```bash
omavpn on | off | toggle | restart
omavpn status --json
omavpn profiles | nodes
omavpn profile 5 | node 0
omavpn mode tun|proxy
omavpn strict on|off
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
omavpn status --json | python3 -m json.tool | head -30
```

Автоподключение при входе — тумблер «Подключаться при входе» в настройках
виджета панели (`autoconnect`).

### Виджет «Обходы» (Bypass Status)

Отдельный виджет в панели показывает статус **всех** обходов сразу:

- **VPN** — включён/выключен, профиль, режим (TUN/SOCKS), uptime;
- **zapret (DPI)** — активна ли служба и что выбрано для текущей сети
  (сеть чистая / стратегия #N / кастомная / «через VPN»);
- **Подбор стратегии** — появляется, когда идёт фоновый перебор (когда обход
  перестал работать): показывает попытку `i/N`, текущую стратегию и пометку
  «изолированно»;
- **tg-ws-proxy** — слушает ли порт 1443;
- по кнопке **«Проверить доступность»** — HTTP-коды Яндекс / Telegram API / YouTube
  / Discord.

Цвет щита в панели: зелёный — всё хорошо, янтарный — предупреждение (например,
обход ушёл в VPN), красный — что-то не работает. Данные берёт из
`bypass-status --json` (обновление раз в 4 с). Скрипт понимает и `omavpn`, и
`wowvpn` — CLI определяется автоматически.

Установка отдельно:

```bash
install -m 0755 bin/bypass-status ~/.local/bin/bypass-status
ID=io.github.blazeeers.bypass-status
mkdir -p ~/.config/omarchy/plugins/$ID
cp shell-plugin/bypass-status/manifest.json shell-plugin/bypass-status/Panel.qml ~/.config/omarchy/plugins/$ID/
omarchy-shell shell rescanPlugins
omarchy plugin enable $ID
omarchy bar move $ID --section right
omarchy restart shell
```

> Для маркетплейса в одном репозитории публикуется один плагин (манифест в корне —
> это `omavpn`). Виджет статусов — второй, локальный; для публикации ему нужен
> отдельный репозиторий.

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
| `shell-plugin/omavpn/Panel.qml` | QML-виджет панели |
| `~/.config/omarchy/plugins/io.github.blazeeers.omavpn/` | установленный плагин VPN |
| `~/.local/bin/bypass-status` | агрегатор статусов обходов (JSON) |
| `shell-plugin/bypass-status/` | QML виджета «Обходы» |
| `~/.config/omarchy/plugins/io.github.blazeeers.bypass-status/` | установленный виджет «Обходы» |

---

## Документация

- [docs/architecture.md](docs/architecture.md) — как устроена маршрутизация и связка сервисов.
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

Сетевые обращения: загрузка подписки по HTTPS, Xray/sing-box к серверам
провайдера, tg-ws-proxy к Telegram. Секретов в репозитории нет. Внешних сборок
кроме скачивания готовых бинарей нет; симлинков в каталоге плагина нет.

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
