# Changelog

Все заметные изменения проекта.
Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версии — [SemVer](https://semver.org/lang/ru/).

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

[1.1.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/releases/tag/v1.0.0
