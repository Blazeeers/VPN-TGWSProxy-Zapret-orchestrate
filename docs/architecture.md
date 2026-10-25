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
3. `ip_cidr: 77.88.8.8/32` → `direct` — запросы к российскому резолверу `ru`
   идут мимо туннеля (иначе ответ вернулся бы «из-за границы», см. раздел DNS).
4. `ip_is_private` → `direct` — LAN, loopback.
5. **`domain_suffix: proxy_domains()` → `proxy`** — домены, которым положено в
   туннель: `ALWAYS_PROXY_DOMAINS` (`youtubei.googleapis.com`,
   `youtube.googleapis.com` — напрямую блокируются наглухо) плюс оверрайды
   `proxy` из `~/.config/omavpn/route_overrides.json`. Стоит **перед**
   direct-правилом, поэтому автотюн не может вытолкнуть их из туннеля.
6. **`domain_suffix: ALWAYS_DIRECT_DOMAINS → action: resolve, server: ru`** —
   внутренний резолв sing-box для «прямых» доменов идёт в `ru`. Действие
   `resolve` не финальное: маршрут домена решает следующее правило.
7. `domain_suffix: direct_domains()` → `direct` — MAX, Яндекс, Discord, YouTube
   (`ALWAYS_DIRECT_DOMAINS` — MAX/Яндекс/DeepSeek/Tailscale — применяется всегда;
   Discord/YouTube берутся из `DEFAULT_DIRECT_DOMAINS` либо
   `~/.config/omavpn/direct_domains.txt`; оверрайды `direct` тоже попадают сюда).
8. `process_name: tg-ws-proxy, TgWsProxy, Telegram, telegram-desktop` → `direct` —
   локальный MTProto-прокси и Telegram Desktop.
9. `bypass` — адреса серверов подписки (`ip_cidr`/`domain`) → `direct`,
   чтобы туннель не зациклился.
10. `process_name: xray` → `direct` — соединения самого Xray (в том числе
    временного, из `probe`).
11. `port: 25,465,587` → `direct` — SMTP.
12. **`rule_set: refilter-domain, refilter-ip` → `proxy`** — Re:filter: домены и
    адреса, заблокированные в РФ, идут в туннель. Правило стоит **после** всех
    direct-исключений (пункты 5–11), поэтому уже настроенные прямые маршруты и
    почту не перебивает, и **после** `process_name: xray`, поэтому не
    зацикливает соединение с сервером подписки. Наборы — локальные бинарные
    `.srs` из `~/.local/state/omavpn/refilter/`; если функция выключена
    (`omavpn refilter off`) или файлов нет, ни `rule_set`, ни правила в конфиге
    не появляется.
13. `ip_version: 6` → `block` — IPv6 выключен.

Полный приоритет источников: **overrides → `ALWAYS_PROXY_DOMAINS` →
`direct_domains.txt` → `final = proxy`**. Оверрайды правятся командой
`omavpn route set|unset` и автоматически — аудитом маршрутов
([docs/route-audit.md](route-audit.md)).

## DNS

Резолверов два, и это не резервная копия, а разные задачи:

| Тег | Сервер | Куда ходит | Для чего |
|---|---|---|---|
| `remote` (`final`) | `1.1.1.1` | через туннель (`detour: proxy`) | всё остальное: провайдерский DNS для заблокированных доменов отдаёт недоступные IP, а через туннель приходит «чистый» адрес |
| `ru` | `77.88.8.8` | напрямую | домены из `ALWAYS_DIRECT_DOMAINS` (`max.ru`, Яндекс, DeepSeek, Tailscale): им нужен **российский** адрес, зарубежный ломает прямой путь |

- `dns.rules`: `domain_suffix: ALWAYS_DIRECT_DOMAINS` → `action: route`,
  `server: ru`. Всё, что не попало в правило, идёт на `final: remote`.
  Стратегия — `ipv4_only`.
- У сервера `ru` **нет** `detour`: `detour: direct` sing-box отвергает при старте
  («detour to an empty direct outbound makes no sense»). Поэтому запросы к самому
  `77.88.8.8` уводятся в обход туннеля маршрутным правилом
  `ip_cidr: 77.88.8.8/32 → direct` (правило 3 в списке выше). `sing-box check`
  такую ошибку не ловит — проверять надо запуском.
- `resolve(ru)` — правило 6: без него внутренний резолв sing-box
  (`default_domain_resolver = remote`, например socks5h-запрос с доменом в
  запросе) обошёл бы `dns.rules` и вернул зарубежный адрес.
- Зачем вообще: `max.ru` отдаётся `77.88.8.8` за ~55 мс, а через туннель — ~3 с,
  при этом адрес из туннеля может быть недоступен напрямую (проверено 23.10.2026).

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
- файла нет → используется встроенный `DEFAULT_DIRECT_DOMAINS`.

Это позволяет `zapret-autotune` управлять тем, что выводится из туннеля:
режим `vpn` пишет туда только `max.ru`, режим `off`/`custom`/пресет — полный список.

Поверх этого работают оверрайды `~/.config/omavpn/route_overrides.json`
(`omavpn route set|unset`): они сильнее `direct_domains.txt`, потому что этот
файл автотюн перезаписывает сам, а оверрайд — решение о конкретном домене,
принятое по реальной доступности. См. [route-audit.md](route-audit.md).

## Временные файлы и процессы

| Артефакт | Кто создаёт | Комментарий |
|---|---|---|
| `~/.local/state/omavpn/singbox.json` | omavpn | генерируется при `on/restart` |
| `~/.local/state/omavpn/xray.json` | omavpn | конфиг из подписки + правки |
| `~/.config/omavpn/route_overrides.json` | omavpn / аудит | ручные оверрайды маршрутов (сильнее `direct_domains.txt`) |
| `~/.local/state/omavpn/ctrl.lock` | omavpn | `flock` на управление VPN: `on`, `off`, `restart`, `route set/unset` |
| `~/.local/state/omavpn/refilter/*.srs` | omavpn | наборы Re:filter (домены, IP) и `meta.json`; качает `omavpn refilter update` |
| `~/.cache/bypass-status/route-audit.lock` | bypass-status | `flock` аудита и перепроверки маршрутов |
| `~/.cache/<cli>/route-audit.json` | bypass-status | результат последнего аудита маршрутов |
| `~/.cache/<cli>/route-audit-state.json` | bypass-status | гистерезис: когда и сколько раз переключали домен (`ts`, `fails`) |
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
