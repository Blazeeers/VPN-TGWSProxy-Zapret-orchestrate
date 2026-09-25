# tg-ws-proxy

Локальный MTProto-прокси для Telegram Desktop: принимает подключения на
`127.0.0.1:1443` и пересылает их в дата-центры Telegram по WebSocket (TLS).
Ускоряет и стабилизирует Telegram без VPN.

Внешний проект: [Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy).

## Установка (без root)

```bash
bash tgwsproxy/install.sh
```

Ставит `tg-ws-proxy` в `~/.local/bin`, иконку, `.desktop`, автозапуск и запускает.
Печатает ссылку `tg://proxy?...`.

Альтернатива для Arch — AUR `tg-ws-proxy-bin` (системная установка, нужен sudo):

```bash
yay -S tg-ws-proxy-bin
```

## Подключение Telegram Desktop

1. Иконка в трее → **«Открыть в Telegram»** (автонастройка), либо
2. вручную: Настройки → Продвинутые настройки → Тип подключения → Прокси →
   добавить MTProto: сервер `127.0.0.1`, порт `1443`, secret из
   `~/.config/TgWsProxy/config.json`.

## Важно в связке с omavpn

В `bin/omavpn` процесс `tg-ws-proxy` (и `Telegram`) выведен из туннеля
(`process_name → direct`), чтобы WebSocket-соединения шли напрямую. Не заменяй
это широким исключением по доменам/подсетям Telegram — это сломает Bot API бота
(см. [../docs/telegram.md](../docs/telegram.md)).

## Обновление

```bash
FORCE=1 bash tgwsproxy/install.sh
```

Затем перезапусти приложение (или `pkill -x tg-ws-proxy` и запусти заново).
