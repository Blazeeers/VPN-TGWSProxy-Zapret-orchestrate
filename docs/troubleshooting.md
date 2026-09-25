# Диагностика

## Быстрая проверка «всё ли живо»

```bash
systemctl is-active zapret.service zapret-autotune.timer
omavpn status --json | python3 -m json.tool | head
zapret-autotune show
curl -s -o /dev/null -w 'youtube %{http_code}\n' https://www.youtube.com/
curl -s -o /dev/null -w 'discord %{http_code}\n' https://discord.com/
curl -s -o /dev/null -w 'max %{http_code}\n' https://max.ru/
journalctl --user -u telegram-inbox-bot -n 5
```

---

## YouTube не открывается, хотя VPN включён

Сначала — **идёт ли сейчас скан автотюна**: на время скана он выводит
Discord/YouTube напрямую (чтобы их видел nfqws), и они недоступны, пока не
завершится.

```bash
systemctl is-active zapret-autotune.service   # activating = идёт скан
tail -20 /var/log/zapret-autotune.log
```

Другие причины и что смотреть:

1. **Режим сети.** `zapret-autotune show`. Если `vpn` — Discord/YouTube должны
   идти через туннель. Проверь `~/.config/omavpn/direct_domains.txt` (в режиме
   `vpn` там только `max.ru`).
2. **VPN реально работает.** `omavpn status --json`, `omavpn check`. Если узел
   мёртв — `omavpn nodes`, выбери живой `omavpn profile N` / `omavpn node M`.
3. **Зависший/битый кэш.** `sudo zapret-autotune rescan`.
4. **Фантомная сеть.** Если в логе `net-unknown-` — это лечится с версии с
   guard’ом по WAN (запуск пропускается). Убедись, что установлена актуальная
   версия: `sudo bash zapret/zapret-autotune-install.sh`.

---

## Бот не получает сообщения / файлы

Проверь VPN и API:

```bash
journalctl --user -u telegram-inbox-bot -n 20
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://api.telegram.org/
```

Ошибки `Temporary failure in name resolution` или `Network is unreachable`
означают, что нет рабочего туннеля (Bot API ходит только через VPN). Включи/почини
VPN (`omavpn on`, смени профиль).

---

## zapret не обходит

```bash
systemctl status zapret.service
journalctl -u zapret.service -n 50
pgrep -a nfqws                 # nfqws должен быть запущен
grep -m1 NFQWS_OPT /opt/zapret/config
```

- Убедись, что `MODE_FILTER=hostlist` и `IFACE_WAN` — твой реальный интерфейс.
- Списки доменов: `/opt/zapret/ipset/list-google.txt` и
  `zapret-hosts-user.txt` (скрипт `zapret-hostlist.sh`).
- Серверы VPN должны быть в `/opt/zapret/ipset/zapret-ip-exclude.txt` (иначе
  zapret сломает туннель) — пересоздаётся `zapret-setup.sh`.
- Перебор стратегий вручную: `sudo bash zapret/zapret-strategy.sh scan`.
- Глубокий перебор: `sudo bash zapret/zapret-blockcheck.sh standard`
  (10–30 мин, VPN выключится; лог `/var/log/zapret-blockcheck.log`).
- Если `blockcheck` не находит ничего — в этой сети обход zapret невозможен,
  правильный режим `vpn`.

---

## VPN не поднимается / медленный

```bash
omavpn status --json | python3 -m json.tool
omavpn check        # сравнить IP напрямую и через прокси
tail -40 ~/.local/state/omavpn/xray.log
tail -40 ~/.local/state/omavpn/singbox.log
```

- Мёртвый узел: посмотри `omavpn nodes`, проверь доступность адресов и смени
  профиль/ноду (`omavpn profile N`, `omavpn node M`).
- Перезапуск: `omavpn restart`.

---

## Telegram Desktop (tg-ws-proxy)

```bash
pgrep -af tg-ws-proxy
ss -lntp | grep 1443
tail -30 ~/.config/TgWsProxy/proxy.log
```

- Нет трея — нужен `libayatana-appindicator` (на Omarchy обычно есть).
- Не подключается — перепроверь прокси в Telegram (`127.0.0.1:1443`, secret из
  `~/.config/TgWsProxy/config.json`).
- Фото/видео не грузятся — поправь DC→IP в настройках прокси Telegram (см.
  [telegram.md](telegram.md)).

---

## Полный сброс автотюна

```bash
sudo systemctl stop zapret-autotune.service
sudo rm -f /var/lib/zapret-autotune/*.strategy /var/lib/zapret-autotune/*.opt
sudo bash zapret/zapret-autotune-install.sh
```

## Где логи

| Лог | Что |
|---|---|
| `/var/log/zapret-autotune.log` | автотюн (выбор стратегии по сетям) |
| `/var/log/zapret-blockcheck.log` | глубокий перебор blockcheck |
| `journalctl -u zapret.service` | сам zapret/nfqws |
| `~/.local/state/omavpn/{xray,singbox}.log` | VPN-движки |
| `~/.config/TgWsProxy/proxy.log` | tg-ws-proxy |
| `journalctl --user -u telegram-inbox-bot` | бот |
