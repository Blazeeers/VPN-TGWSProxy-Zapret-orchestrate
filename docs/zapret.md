# DPI-обход (zapret) и автотюн

Как устроен обход блокировок Discord/YouTube без VPN и как подбирается рабочая
стратегия под конкретную сеть.

## Что это

[zapret](https://github.com/bol-van/zapret) — набор утилит для обхода DPI.
На Linux используется ядро `nfqws` (Netfilter queue) + правила nftables/iptables.
`nfqws` перехватывает пакеты и модифицирует TLS ClientHello (дробит, подсовывает
фейковые пакеты, меняет TTL и т.п.), чтобы DPI провайдера не увидел запрещённый
домен. Пакетный уровень обязателен: userspace-прокси за TUN теряет эффект.

Установка (Arch):

```bash
yay -S zapret-git          # ipset, libnetfilter_queue, bind, nmap
```

Файлы: `/opt/zapret` (`nfq/nfqws`, `ipset/`, `config`), сервис `zapret.service`.

## Наша конфигурация

`zapret/zapret-setup.sh` (запуск под root) приводит `/opt/zapret/config` к виду:

| Параметр | Значение | Смысл |
|---|---|---|
| `IFACE_WAN` | `wlp2s0` | физический интерфейс (определяется автоматически) |
| `NFQWS_ENABLE` | `1` | включить nfqws |
| `MODE_FILTER` | `hostlist` | десинхронить только домены из списков |
| `INIT_APPLY_FW` | `1` | применять правила nftables |

Плюс исключение серверов omavpn: адреса из кэша подписки
(`~/.cache/omavpn/sub.json`) пишутся в `/opt/zapret/ipset/zapret-ip-exclude.txt`,
который создаёт nft-сет `nozapret` — иначе zapret мог бы сломать туннель.

`zapret/zapret-hostlist.sh` кладёт списки доменов:

- `/opt/zapret/ipset/list-google.txt` — YouTube;
- `/opt/zapret/ipset/zapret-hosts-user.txt` — Discord.

Поддомены в hostlist подхватываются автоматически (`youtube.com` покрывает
`www.youtube.com`).

## Стратегия = `NFQWS_OPT`

Автовыбора стратегии у zapret нет: всегда применяется ровно то, что записано в
`NFQWS_OPT` в `/opt/zapret/config`. Сменить — отредактировать и
`systemctl restart zapret.service`.

Встроенный дефолт bol-van (tcp80 `fake,multisplit`, tcp443 `fake,multidisorder`,
udp443 `fake`) во многих сетях не проходит — отсюда нужда в переборе.

### Ручной перебор/переключение

`zapret/zapret-strategy.sh` — аналог ручного перебора `.bat`-стратегий из
Windows-сборки Flowseal:

```bash
sudo bash zapret/zapret-strategy.sh list          # список пресетов
sudo bash zapret/zapret-strategy.sh scan          # перебрать и оставить рабочую
sudo bash zapret/zapret-strategy.sh set flowseal  # применить пресет
```

Пресеты: `flowseal`, `flowseal-alt` (переводы из репозитория Flowseal),
`disorder`, `simple-multisplit`, `default` (bol-van).

## Автотюн (`zapret-autotune`)

Устанавливается в `/usr/local/bin` скриптом
`zapret/zapret-autotune-install.sh`. Это systemd-сервис от root, который
подбирает и применяет стратегию под текущую сеть.

### Как определяется сеть

`netkey()`:

- Wi-Fi → `wifi-<SSID>` (`iwgetid`);
- иначе → `net-<iface>-<MAC шлюза>`.

Если физический WAN определить не удалось (например, кратковременный обрыв
Wi-Fi), запуск **пропускается** — иначе был бы полный скан на «фантомной» сети.

### Кэш и решения

`/var/lib/zapret-autotune/<ключ>.strategy` содержит одно из:

- `off` — сеть ничего не блокирует, zapret выключен;
- число — индекс встроенной стратегии из массива `STRATEGIES`;
- `custom` — стратегия найдена `blockcheck`, строка лежит в `<ключ>.opt`;
- `vpn` — ничего не помогло, Discord/YouTube уходят в туннель.

### Алгоритм

1. `run` определяет сеть; если есть кэш — применяет и проверяет, при провале
   пересканирует.
2. `run_scan` (изолированный режим, если доступен probe-пользователь):
   - Discord/YouTube временно **держит в VPN** (`direct_domains.txt` = `max.ru`),
     чтобы сервисы работали во время подбора;
   - добавляет `ip rule uidrange <probe> -> main`: трафик служебного
     пользователя `zapret-probe` идёт напрямую, и только он попадает под
     проверяемую стратегию;
   - останавливает zapret и проверяет «чистую сеть» трафиком probe;
   - перебирает `STRATEGIES`: пишет `NFQWS_OPT`, рестарт zapret, проверка
     YouTube+Discord **от probe**; боевой трафик не затрагивается;
   - нашлась рабочая → `direct_domains.txt` = полный список (сервисы напрямую
     через zapret), `ip rule` удаляется;
   - не нашлась → `vpn`: сервисы остаются в VPN, при `AUTO_VPN=1` поднимается
     omavpn. В режиме `vpn` обход **периодически перепроверяется** (раз в
     `RETRY_SECONDS`, по умолчанию 1800 с): если стратегия появилась — виджет
     покажет «Подбор стратегии», а сервисы переключатся на прямой обход; если нет —
     всё остаётся в VPN.
   Если probe недоступен (нет пользователя `zapret-probe`/прав), используется
   прежний «боевой» перебор с кратким выводом сервисов из VPN.

Изменения применяются только если реально изменились (сравнение `NFQWS_OPT` и
содержимого `direct_domains.txt`) — сервис не перезапускает VPN/zapret зря.

### Изолированный перебор (без разрыва связи)

Подбор новых стратегий не трогает боевой трафик:

- трафик служебного пользователя `zapret-probe` направляется напрямую правилом
  `ip rule add uidrange <uid>-<uid> lookup main pref 100`;
- пока идёт подбор, Discord/YouTube остаются в VPN — ими можно пользоваться;
- выбранная стратегия применяется к продакшену только после успешной проверки; а
  если ни одна не подошла, всё остаётся в режиме `vpn`.

Проверить изоляцию (host должен показать VPN-IP, probe — прямой):

```bash
sudo zapret-autotune probe-selftest
```

### Управление и параметры

```bash
sudo zapret-autotune run|rescan|tune-wan
zapret-autotune show
sudo zapret-autotune probe-selftest   # проверить изоляцию пробника
```

`/etc/zapret-autotune.conf`:

```
USER_NAME=...
USER_HOME=...
AUTO_VPN=1               # автотюн сам поднимает omavpn на сетях, где обход не работает
PROBE_USER=zapret-probe  # служебный пользователь для изолированного перебора
RETRY_SECONDS=1800       # как часто в режиме vpn перепроверять обход, сек
```

### Триггеры

- NetworkManager dispatcher `/etc/NetworkManager/dispatcher.d/90-zapret-autotune`
  на `up`/`connectivity-change` (интерфейсы VPN/tun игнорируются);
- таймер `zapret-autotune.timer`: `OnBootSec=3min`, `OnUnitActiveSec=15min`;
- ручной `rescan`.

## Глубокий подбор (`blockcheck`)

`zapret/zapret-blockcheck.sh` запускает штатный `/opt/zapret/blockcheck.sh`
(он перебирает десятки вариантов: позиции split по SNI `sniext/host/midsld`,
режимы `fake/fakedsplit/hostfakesplit/fakeddisorder`, fooling
`md5sig/badseq/datanoack/ts/badsum`, TTL 1–12, seqovl и др.), выключает на время
VPN и zapret, парсит найденную стратегию, применяет её и сохраняет в автотюн как
`custom`.

```bash
sudo bash zapret/zapret-blockcheck.sh standard   # или quick
```

Лог: `/var/log/zapret-blockcheck.log`. Если стратегия не найдена — значит в этой
сети obход zapret невозможен и правильный режим — `vpn`.

## Связка VPN + zapret (маршрутизация пакетов nfqws)

wowvpn в режиме TUN ставит policy-routing: `ip rule 9001: from all lookup 2022`,
где таблица 2022 — `default dev wowvpn0`. Из-за этого пакеты, которые nfqws
дополнительно инжектирует при десинхронизации (метки `0x40000000` и
`0x20000000`), тоже уходят в туннель — провайдерский DPI их не видит, и обход
**не срабатывает**, хотя стратегия рабочая (YouTube/Discord не открываются).

Лечится скриптом `zapret-routefix.sh` (сервис `zapret-routefix.service`,
включается установщиком автотюна): он добавляет правила с приоритетом **8990**
(до правил wowvpn 9000+):

```
ip rule add fwmark 0x40000000/0x40000000 lookup main priority 8990
ip rule add fwmark 0x20000000/0x20000000 lookup main priority 8990
```

Так инжектируемые пакеты уходят через физический интерфейс. Без VPN правила
безвредны (main и так смотрит на WAN). Проверка: `systemctl status
zapret-routefix.service`, `ip rule show | grep 8990`.

## Логи и диагностика

```bash
systemctl status zapret.service
journalctl -u zapret.service -n 50
tail -f /var/log/zapret-autotune.log
zapret-autotune show
```

Если YouTube перестал открываться «при включённом VPN» — проверь, не идёт ли
сейчас скан автотюна (`/var/log/zapret-autotune.log`): на время скана
Discord/YouTube выводятся напрямую. Также см.
[docs/troubleshooting.md](troubleshooting.md).

---

Автор оригинального **zapret** — [bol-van](https://github.com/bol-van/zapret)
(MIT). См. [THIRD_PARTY.md](../THIRD_PARTY.md).
