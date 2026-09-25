# Сторонние компоненты и благодарности

Проект стоит на чужих разработках. Спасибо их авторам и мейнтейнерам.

## zapret — DPI-обход

- Автор: **bol-van**
- Репозиторий: <https://github.com/bol-van/zapret>
- Лицензия: **MIT**
- Что используется: `nfqws` и конфигурация обхода DPI. Каталог `zapret/` этого
  репозитория — наши обёртки (установка, hostlist-режим, автотюн, обёртка над
  `blockcheck.sh`), сам zapret скачивается отдельно (`yay -S zapret-git`) и
  распространяется под своей лицензией.

## tg-ws-proxy — MTProto-прокси для Telegram Desktop

- Автор: **Flowseal**
- Репозиторий: <https://github.com/Flowseal/tg-ws-proxy>
- Лицензия: **MIT**
- Что используется: бинарь `tg-ws-proxy` (скачивается из релизов). Каталог
  `tgwsproxy/` — наш установщик/обёртка, оригинальный код не изменялся.

## Happ — формат подписок

- Автор: **Happ-proxy**
- Репозиторий: <https://github.com/Happ-proxy/happ-desktop>
- Что используется: **формат подписки** («Happ-формат» — Xray full JSON) и идея
  клиента. Код Happ не копировался; `omavpn` лишь читает совместимые подписки.
- Лицензия: см. репозиторий Happ.

## Прочие зависимости

- **Xray-core** — <https://github.com/XTLS/Xray-core> (MPL-2.0): прокси-ядро.
- **sing-box** — <https://github.com/SagerNet/sing-box> (GPL-3.0): TUN и
  маршрутизация.
- **Omarchy** — <https://omarchy.org> / <https://github.com/basecamp/omarchy>:
  платформа, панель (Quickshell) и контракт плагинов.

Полные тексты лицензий каждой зависимости — в её репозитории. Наш собственный
код распространяется под MIT (см. [LICENSE](LICENSE)).
