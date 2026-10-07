# Changelog

Все заметные изменения проекта.
Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версии — [SemVer](https://semver.org/lang/ru/).

## [1.6.0] — 2026-10-04

### Added
- **Реальная проверка YouTube**: качается кусок видео с `googlevideo.com`
  (через `yt-dlp` + `curl`) и меряется скорость — ловит случай «страница
  открывается, видео не грузится» (троттлинг). Результат кэшируется
  (`~/.cache/<cli>/yt.json`) и показывается строкой в виджете; иконка трея —
  `YouTube` (жёлтая), если видео не грузится.
- Кнопки в виджете: **Проверить YouTube** (`bypass-status --yt`) и
  **Тест стратегий** (принудительный перебор zapret через
  `--rescan-request` + systemd `zapret-autotune-rescan.path`).
- Автотюн: прямая проверка YouTube теперь требует доступности и страницы, и CDN
  `googlevideo` — иначе YouTube не считается работающим напрямую.

## [1.5.2] — 2026-10-04

### Removed
- Виджет «Обходы»: убрана кнопка «Обновить данные» — статусы и список стран
  обновляются автоматически (опрос раз в 4 с; список — при открытии панели).
  Отметка «обновлено HH:MM:SS» осталась после «Обновить подписку» и «Проверить
  доступность».

## [1.5.1] — 2026-10-04

### Fixed
- Виджет «Обходы»: кнопка **«Обновить данные»** (была «Обновить») теперь
  перезапрашивает и статусы, и список профилей/стран, и показывает внизу
  «обновлено HH:MM:SS». Раньше она лишь повторяла опрос статуса, который и так
  идёт каждые 4 с — поэтому казалось, что кнопка не работает.

## [1.5.0] — 2026-10-04

### Added
- **Автоматическая проверка обновлений компонентов**: zapret (AUR `zapret-git` +
  GitHub bol-van/zapret) и tg-ws-proxy (GitHub-релизы). Раз в сутки
  пользовательским таймером `omavpn-updates.timer` (`bypass-status --updates`),
  результат кэшируется в `~/.cache/<cli>/updates.json`.
- Виджет «Обходы»: строка **«Обновления»**, когда доступна новая версия.
- `tgwsproxy/install.sh` записывает установленную версию
  (`~/.local/share/tgwsproxy/version`) — для сравнения при проверке.

## [1.4.1] — 2026-10-04

### Added
- Виджет «Обходы»: информационная строка **YouTube** — «трафик идёт напрямую,
  без VPN и обхода» (когда YouTube не туннелируется и zapret его не обрабатывает).

## [1.4.0] — 2026-10-04

### Added
- **Прямая проверка по сервисам** в автотюне: youtube и discord проверяются
  отдельно, без обхода. Если youtube работает напрямую — он остаётся напрямую
  (мимо VPN и zapret), а zapret включается и тестируется **только для discord**.
  Если напрямую ничего не работает — прежняя логика (перебор по обоим).
  Виджет показывает, что именно идёт напрямую (например, «обход не сработал:
  youtube напрямую, остальное через VPN»).

## [1.3.1] — 2026-10-04

### Changed
- Виджет «Обходы»: список серверов убран; выбор страны (профиля подписки) сделан
  сворачиваемым — раскрывается кликом по строке **VPN**. Кнопка «Пинг серверов»
  убрана, чтобы не загромождать виджет.

## [1.3.0] — 2026-10-04

### Added
- Виджет «Обходы»: управление VPN из текущей подписки — выбор профиля и сервера,
  обновление подписки и **TCP-пинг до каждого узла** (кнопка «Пинг серверов»).
  Данные берёт `bypass-status --vpn` (параллельный TCP-connect, ~0.4 с на 12 узлов).

## [1.2.4] — 2026-10-04

### Added
- Значок виджета в панели теперь меняется по статусу: разорванная связь (VPN не
  работает), лупа (идёт подбор стратегии zapret), бумажный самолётик
  (tg-ws-proxy не работает), восклицание (zapret не работает), щит (всё в
  порядке). Цвет значка — по важности состояния.

## [1.2.3] — 2026-10-04

### Changed
- Виджет «Обходы»: индикация подбора перенесена в строку `zapret (DPI)`
  («идёт подбор: попытка `i/N` · стратегия · изолированно») — отдельного пункта
  «Подбор стратегии» больше нет.

## [1.2.2] — 2026-10-04

### Added
- Автотюн в режиме `vpn` теперь **периодически перепроверяет обход** (раз в
  `RETRY_SECONDS`, по умолчанию 30 мин) в изолированном режиме: в виджете
  появляется строка «Подбор стратегии», а в строке zapret — «перепроверка через
  N мин». Так обход не «выключается навсегда» после одной неудачи.

## [1.2.1] — 2026-10-04

### Added
- Виджет «Обходы»: строка **«Подбор стратегии»** во время фонового перебора —
  показывает попытку `i/N`, текущую стратегию и пометку «изолированно»
  (автотюн пишет состояние в `/var/lib/zapret-autotune/probe.json`).

### Changed
- Виджет «Обходы»: убрано состояние Telegram-бота и его упоминания.

## [1.2.0] — 2026-10-04

### Added
- **Изолированный фоновый перебор стратегий** (`zapret-autotune`): кандидаты
  проверяются трафиком служебного пользователя `zapret-probe`
  (`ip rule uidrange -> main`), пока Discord/YouTube остаются в VPN — интернет и
  сервисы во время подбора не прерываются. Команда `probe-selftest` проверяет
  изоляцию; установщик создаёт probe-пользователя, без него — откат к прежнему
  перебору.

## [1.1.1] — 2026-10-04

### Security
- `install.sh` и `tgwsproxy/install.sh`: версии артефактов закреплены (pin),
  добавлена проверка **sha256** до запуска и выдачи capabilities
  (Xray 26.3.27, sing-box 1.14.1, tg-ws-proxy 1.10.4).
- `bin/omavpn`: секретные файлы (кэш подписки `sub.json`, сгенерированный
  `xray.json`, логи, pid) создаются с правами `0600`, каталоги
  `~/.config|state|cache` — `0700`; CLI работает с `umask 077`.
- `zapret/zapret-autotune`: запись пользовательского `direct_domains.txt`
  выполняется от имени пользователя (`runuser`) — root не следует по
  пользовательским симлинкам и не меняет владельца цели.

## [1.1.0] — 2026-09-26

### Added
- **Виджет «Обходы»** (`io.github.blazeeers.bypass-status`) — обзор состояния всех
  обходов прямо в панели Omarchy: VPN, zapret (DPI), tg-ws-proxy, Telegram-бот,
  плюс кнопка проверки доступности (Яндекс / Telegram API / YouTube). Цвет щита
  отражает здоровье системы.
- **`bypass-status`** — агрегатор статуса в JSON; сам определяет CLI (`omavpn`
  или `wowvpn`), root не требуется.
- `ALWAYS_DIRECT_DOMAINS` в CLI: российские сервисы (**Яндекс**, MAX) всегда идут
  напрямую, поверх `direct_domains.txt`; zapret-autotune их не перетирает.
- `install.sh` ставит оба виджета; в README — раздел «Виджет „Обходы“».

### Fixed
- **Яндекс не открывался при включённом VPN** — зарубежный выход режется
  провайдером/сервисом; Яндекс и MAX теперь исключены из туннеля всегда.

### Changed
- Проект и репозиторий переименованы в **VPN-TGWSProxy-Zapret-orchestrate**
  (поле `manifest.name`); id плагина прежний — `io.github.blazeeers.omavpn`.

## [1.0.0] — 2026-09-26

### Added
- **omavpn** — VPN-клиент (Xray-core + sing-box TUN) с виджетом панели Omarchy:
  профили/узлы, режимы TUN/SOCKS, автоподключение, проверка внешнего IP.
- Подписки в двух форматах: **Happ / Xray full JSON** и обычные **share-link**
  (`vless`, `vmess`, `trojan`, `ss`, `socks`; транспорты `ws`, `grpc`,
  `httpupgrade`, `xhttp`, `tcp`, `http`; безопасность `none`/`tls`/`reality`).
- **zapret-autotune** — автоматический подбор стратегии DPI-обхода под сеть,
  кэш по сетям, откат на VPN; systemd-сервис, таймер, хук NetworkManager,
  `AUTO_VPN`.
- Скрипты zapret: `zapret-setup.sh`, `zapret-hostlist.sh`, `zapret-strategy.sh`,
  `zapret-blockcheck.sh`.
- **tg-ws-proxy** — установщик локального MTProto-прокси для Telegram Desktop
  (ускорение без VPN).
- Документация: `docs/architecture.md`, `docs/zapret.md`, `docs/telegram.md`,
  `docs/troubleshooting.md`; атрибуция сторонних проектов в `THIRD_PARTY.md`.
- Манифест Omarchy Marketplace (`manifest.json` в корне) и лицензия MIT.

[1.6.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.5.2...v1.6.0
[1.5.2]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.5.1...v1.5.2
[1.5.1]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.2.4...v1.3.0
[1.2.4]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/releases/tag/v1.0.0
