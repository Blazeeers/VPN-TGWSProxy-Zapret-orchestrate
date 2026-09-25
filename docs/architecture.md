# Архитектура

Как устроена маршрутизация и как взаимодействуют сервисы.

## Слои

```
┌───────────────────────────────────────────────────────────────────┐
│ Приложения: браузер, Telegram Desktop, MAX, Telegram-бот, игры    │
└───────────────────────────────────────────────────────────────────┘
        │ TCP/UDP
┌───────▼───────────────────────────────────────────────────────────┐
│ sing-box: TUN omavpn0 (auto_route), маршрутизация и DNS           │
│   final = proxy (всё в туннель), кроме правил direct/block        │
└───────┬───────────────────────────────────────┬───────────────────┘
        │ SOCKS 127.0.0.1:10808                  │ direct
┌───────▼──────────────────┐          ┌──────────▼───────────────────┐
│ Xray (VLESS/Reality/…)   │          │ физический WLAN (wlp2s0)     │
│  → VPN-сервер подписки   │          │  + zapret nfqws (DPI-обход)  │
└──────────────────────────┘          └──────────────────────────────┘
```

- **sing-box TUN** перехватывает трафик через `auto_route` и решает, куда его
  направить: `proxy` (в Xray), `direct` (в сеть) или `block`.
- **Xray** держит соединение с VPN-сервером и ходит SOCKS5 на `127.0.0.1:10808`.
- **zapret/nfqws** работает на уровне пакетов на физическом интерфейсе и правит
  ClientHello для обхода DPI — поэтому он видит только `direct`-трафик.

## Правила маршрутизации sing-box (в порядке приоритета)

Формируются в `bin/omavpn`, функция `build_singbox()`:

1. `sniff` — определять протокол/домен из пакета.
2. `protocol: dns → hijack-dns` — DNS заворачивается в sing-box.
3. `ip_is_private` → `direct` — LAN, loopback.
4. `domain_suffix: direct_domains()` → `direct` — MAX, Discord, YouTube
   (список из `DEFAULT_DIRECT_DOMAINS` либо `~/.config/omavpn/direct_domains.txt`).
5. `process_name: tg-ws-proxy, TgWsProxy, Telegram, telegram-desktop` → `direct` —
   локальный MTProto-прокси и Telegram Desktop.
6. `bypass` — адреса серверов подписки (`ip_cidr`/`domain`) → `direct`,
   чтобы туннель не зациклился.
7. `port: 25,465,587` → `direct` — SMTP.
8. `process_name: xray` → `direct` — соединения самого Xray.
9. `ip_version: 6` → `block` — IPv6 выключен.

DNS: сервер `1.1.1.1` через прокси (`remote`), финальный резолвер — тоже remote.
Это важно: провайдерский DNS для заблокированных доменов может отдавать
недоступные IP, а через туннель приходит «чистый» адрес.

## Почему что исключено

- **Telegram Desktop / tg-ws-proxy** — MTProto-прокси должен сам дойти до DC
  Telegram по WebSocket; если его трафик уйдёт в VPN, обход теряет смысл. Процесс
  определяется по имени (`process_name`).
- **Bot API бота (api.telegram.org)** — наоборот, остаётся в туннеле: прямой
  доступ режется провайдером, а tg-ws-proxy Bot API не обслуживает.
- **MAX (`max.ru`)** — работает напрямую, вне туннеля (российский сервис).
- **Discord / YouTube** — выводятся напрямую, чтобы их обрабатывал zapret;
  если zapret в сети не справляется, автотюн убирает их из direct-списка и они
  идут через VPN.

## Динамическое управление direct-списком

`bin/omavpn` читает `~/.config/omavpn/direct_domains.txt`, если файл существует:

- есть домены → используется этот список;
- файла нет или пуст → используется встроенный `DEFAULT_DIRECT_DOMAINS`.

Это позволяет `zapret-autotune` управлять тем, что выводится из туннеля:
режим `vpn` пишет туда только `max.ru`, режим `off`/`custom`/пресет — полный список.

## Временные файлы и процессы

| Артефакт | Кто создаёт | Комментарий |
|---|---|---|
| `~/.local/state/omavpn/singbox.json` | omavpn | генерируется при `on/restart` |
| `~/.local/state/omavpn/xray.json` | omavpn | конфиг из подписки + правки |
| `/opt/zapret/config` | zapret/автотюн | `NFQWS_OPT`, `IFACE_WAN`, `MODE_FILTER` |
| `/etc/network/…` (nft rules) | zapret | таблица `inet zapret` |
| `/var/lib/zapret-autotune/*.strategy` | автотюн | решение по каждой сети |
| `/var/lib/zapret-autotune/*.opt` | автотюн/blockcheck | строка `NFQWS_OPT` для `custom` |

## Сосуществование zapret и TUN

- zapret навешивает правила на **физический** интерфейс (`IFACE_WAN=wlp2s0`),
  поэтому трафик внутри `omavpn0` он не трогает.
- Серверы VPN попадают в nft-сет `nozapret` (`/opt/zapret/ipset/zapret-ip-exclude.txt`),
  чтобы zapret не портил рукопожатие туннеля.
- `MODE_FILTER=hostlist` — десинхронизируются только домены из hostlist’ов
  (Discord/YouTube), остальной прямой трафик не задевается.
