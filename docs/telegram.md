# Telegram: Desktop, tg-ws-proxy и бот

## Telegram Desktop через tg-ws-proxy

[tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) — локальный MTProto-прокси,
который принимает подключения Telegram Desktop и пересылает их в дата-центры
Telegram по **WebSocket (TLS)**, что ускоряет и стабилизирует Telegram без VPN.

```
Telegram Desktop → MTProto 127.0.0.1:1443 → WebSocket(TLS) → Telegram DC
```

### Установка

```bash
bash tgwsproxy/install.sh
```

Скрипт (без root):

- скачивает `TgWsProxy_linux_amd64` из последнего релиза в `~/.local/bin/tg-ws-proxy`;
- кладёт иконку и `.desktop`, включает автозапуск в `~/.config/autostart/`;
- запускает и печатает ссылку `tg://proxy?...`.

Альтернатива для Arch — AUR-пакет `tg-ws-proxy-bin` (системный, требует sudo).

### Настройка Telegram Desktop

1. Правый клик по иконке в трее → **«Открыть в Telegram»** (автонастройка), либо
2. вручную: Настройки → Продвинутые → Тип подключения → Прокси → MTProto:
   - сервер `127.0.0.1`, порт `1443`;
   - secret из `~/.config/TgWsProxy/config.json`.

Если фото/видео не грузятся (аккаунты без Premium): в настройках прокси в
Telegram оставить в DC→IP только `4:149.154.167.220` или очистить поле.

### Конфиг

`~/.config/TgWsProxy/config.json` — порт, host, secret, список DC IP, флаги
`cfproxy`. `secret` генерируется автоматически, в репозиторий не попадает.

## Почему Telegram Desktop идёт мимо VPN

В `bin/omavpn` есть правило:

```python
{"process_name": ["tg-ws-proxy", "TgWsProxy", "Telegram", "telegram-desktop"],
 "outbound": "direct"}
```

Оно выводит процесс tg-ws-proxy и Telegram Desktop из туннеля: WS-прокси сам
устанавливает соединение с Telegram по WebSocket, и это соединение должно идти
напрямую. Если бы оно уходило в VPN, смысл ускорения/обхода терялся бы.

Процессная фильтрация выбрана **намеренно** вместо широкого исключения по
доменам/подсетям Telegram. Причина — бот (ниже).

## Бот-инбокс и Bot API

`telegram-inbox-bot` (`~/.local/bin/telegram-inbox-bot`, systemd user service)
принимает файлы/текст через **Bot API** (`https://api.telegram.org`) и складывает
их в `~/Inbox/telegram/<дата>/`.

Важно: **Bot API остаётся внутри VPN** и его нельзя исключать по домену/IP.
На проверке прямой доступ к `api.telegram.org` у провайдера режется (DNS отдаёт
недоступный IP), а `tg-ws-proxy` работает только с MTProto и Bot API не
обслуживает. Поэтому в правилах omavpn нет `domain_suffix: telegram.org` — там
только процессное исключение для Desktop.

Вывод: если бот молчит (ошибки `name resolution` / `Network is unreachable` в
`journalctl --user -u telegram-inbox-bot`), вероятнее всего выключен или нерабочий
VPN — см. [troubleshooting.md](troubleshooting.md).

## Связка с автотюном

`tg-ws-proxy` не зависит от zapret: он работает всегда, независимо от выбранного
режима сети (Discord/YouTube). `direct_domains.txt` управляет только
Discord/YouTube/MAX, Telegram не трогает.

---

Автор **tg-ws-proxy** — [Flowseal](https://github.com/Flowseal/tg-ws-proxy) (MIT);
формат подписки — [Happ-proxy](https://github.com/Happ-proxy/happ-desktop).
См. [THIRD_PARTY.md](../THIRD_PARTY.md).
