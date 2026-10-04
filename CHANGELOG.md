# Changelog

Все заметные изменения проекта.
Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версии — [SemVer](https://semver.org/lang/ru/).

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

[1.2.3]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/releases/tag/v1.0.0
