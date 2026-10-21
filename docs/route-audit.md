# Аудит маршрутов

Блокировки меняются: сегодня недоступен один служебный домен, через месяц —
другой CDN или API. Аудит маршрутов находит домен, который **не отвечает по
своему текущему пути**, и сам переводит его на рабочий — без человека.

Пример из жизни (22.10.2026): YouTube «тормозил». `www.youtube.com` отдавал
200, видео с `googlevideo.com` качалось 10–24 МБ/с, а страница висела.
Виноват был служебный API `youtubei.googleapis.com`: напрямую все его адреса
дают таймаут 10 с, а zapret его не пробивает — домена нет в
`/opt/zapret/ipset/zapret-hosts-user.txt`. Через VPN тот же домен отвечает за
1–2 с. Такую поломку не видно ни по «пингу», ни по открытию сайта.

## Приоритет маршрутов

Правила собирает `bin/omavpn`, функция `build_singbox()`. Порядок правил —
это и есть приоритет:

```
1. override из ~/.config/omavpn/route_overrides.json  → proxy
2. ALWAYS_PROXY_DOMAINS                               → proxy
3. ALWAYS_DIRECT_DOMAINS + direct_domains.txt + оверрайды direct → direct
4. всё остальное                                      → final = proxy
```

Правило proxy стоит **перед** правилом direct, поэтому домен из пункта 1–2
физически не может попасть в direct.

### Почему overrides важнее direct_domains.txt

`~/.config/omavpn/direct_domains.txt` перезаписывает `zapret-autotune`
(root-таймер, раз в 30 минут). Это его рабочий инструмент: не справляется
обход в этой сети — он выкидывает домен из файла, и тот идёт через VPN.
Доверять этому файлу как источнику истины нельзя: любое решение автотюна
основано на стратегии zapret, а не на реальной доступности конкретного API.
Оверрайд — ручное (или автоматическое, от аудита) решение, которое автотюн
переписать не может: файл его не касается.

Если `route_overrides.json` нет — всё работает как раньше (кроме доменов из
`ALWAYS_PROXY_DOMAINS`, они идут в туннель всегда).

## Что проверяется

`ROUTE_PROBES` в `bin/bypass-status`:

| Домен | Проверка | Успех |
|---|---|---|
| `www.youtube.com` | `GET https://www.youtube.com/` | 200 и в теле есть `youtube` |
| `youtubei.googleapis.com` | `GET /youtubei/v1/player` | **любой** HTTP-код (405/400 — норма: TLS и ответ состоялись), `000`/таймаут — провал |
| `i.ytimg.com` | `GET /vi/<id>/hqdefault.jpg` | 200, `content-type: image/*`, больше 2000 байт |
| `redirector.googlevideo.com` | `GET /generate_204` | 204 или 200 |
| `discord.com` | `GET /api/v9/gateway` | 200 |
| `api.telegram.org` | `GET /` | 200 или 302 |
| `api.deepseek.com` | `GET /` | любой ответ ниже 500 (на 22.10.2026 — 401, это норма) |

Домены с «мягким» успехом (любой HTTP-код) выбраны намеренно: у служебных API
ответ 4xx — признак живой связи, а не поломки.

## Как проходит аудит

`bypass-status --route-audit` для каждого домена:

1. определяет текущий путь — по тем же правилам, что и sing-box: сначала
   спрашивает `omavpn --json route list` (единая логика приоритета, без
   дублирования), при старом CLI — читает правила из `singbox.json`;
2. проверяет домен «как есть» — `curl` идёт по текущему маршруту через TUN;
   провал подтверждается второй попыткой (одиночный обрыв на живой сети — не
   повод менять маршрут);
3. если путь `direct` и проверка провалилась — проверяет через VPN:
   `curl --socks5-hostname 127.0.0.1:<порт>`, порт берётся из `inbounds`
   `~/.local/state/<cli>/xray.json` (не хардкодится);
4. если через VPN хорошо — `omavpn route set <домен> proxy --reason "аудит:
   direct не отвечает"`, перезапуск sing-box и повторная проверка;
5. если плохо обоими путями — **не переключает**: домен недоступен и через
   VPN, значит дело не в маршруте (или VPN лежит).

Чего аудит **не** делает: не вызывает `omavpn heal`, не перебирает ноды, не
трогает настройки VPN и `direct_domains.txt`.

Выход — JSON:

```json
{"ok": true, "checked": 1792645769, "verdict": "fixed",
 "summary": "проверено 7, исправлено 1", "count": 7, "fixed": 1,
 "probes": [{"domain": "youtubei.googleapis.com", "path": "proxy",
             "before": true, "after": true, "action": "", "detail": "HTTP 405 · 2.4 с"}],
 "actions": [{"domain": "example.com", "from": "direct", "to": "proxy",
              "reason": "аудит: direct не отвечает"}],
 "secs": 8.4}
```

Кэш — `~/.cache/<cli>/route-audit.json` (его читает виджет: строка «маршруты:
проверено N, исправлено M» / «маршруты в порядке»). Журнал — systemd:
`journalctl --user -u omavpn-route-audit.service -n 50`.

## Перепроверка (раз в сутки)

`bypass-status --route-audit-recheck` берёт оверрайды `proxy` старше 24 часов и
для каждого:

1. снимает оверрайд (`omavpn route unset`), перезапускает sing-box;
2. проверяет домен напрямую;
3. работает — оверрайд остаётся снятым (блокировку убрали или zapret научился);
4. не работает — оверрайд возвращается с причиной «direct всё ещё не отвечает».

Сам прогон тоже имеет ограничение: не чаще раза в 20 часов (страховка от
ручных запусков). Кэш — `~/.cache/<cli>/route-audit-recheck.json`.

## Вручную

```bash
omavpn route list                     # таблица: домен, путь, источник, возраст, причина
omavpn route list --json              # то же в JSON (его читает bypass-status)
omavpn --json route list              # равноценная запись, как у остальных команд
omavpn route set example.com proxy --reason "API не отвечает напрямую"
omavpn route set example.com direct   # принудительно напрямую
omavpn route unset example.com        # вернуть обычный приоритет
omavpn route set example.com proxy --no-restart   # без перезапуска VPN

bypass-status --route-audit           # прогнать аудит вручную
bypass-status --route-audit-recheck   # перепроверить старые оверрайды
```

Источник в `route list`: `override` (файл оверрайдов), `always` (константы
`ALWAYS_PROXY_DOMAINS` / `ALWAYS_DIRECT_DOMAINS`), `file` (`direct_domains.txt`),
`default` (встроенный список).

## Если файл оверрайдов повреждён

`route_overrides.json` пишется атомарно (временный файл + `os.replace`), поэтому
«полузаписанного» состояния практически не бывает. Но если файл всё же побит
руками или диском:

- `omavpn` печатает предупреждение в stderr и считает список **пустым** —
  маршруты работают по умолчанию, VPN не ломается;
- первая же запись (`route set`/`route unset`, аудит) перезапишет файл целиком.

Файл не секретный — там только домены, пути и причины.

## Откат

```bash
omavpn route unset youtubei.googleapis.com   # один домен
rm ~/.config/omavpn/route_overrides.json     # все оверрайды сразу
```

После отката домен снова подчиняется `direct_domains.txt`/умолчаниям. Если
это `ALWAYS_PROXY_DOMAINS`, он всё равно останется в туннеле — эти домены
заданы в коде намеренно (напрямую недоступны).

Полный откат вместе с автоматикой:

```bash
systemctl --user disable --now omavpn-route-audit.timer omavpn-route-recheck.timer
```

## Юниты

| Юнит | Когда |
|---|---|
| `omavpn-route-audit.service` | один прогон `bypass-status --route-audit` (`Type=oneshot`) |
| `omavpn-route-audit.timer` | через 3 минуты после загрузки, дальше каждые 10 минут после завершения предыдущего |
| `omavpn-route-recheck.service` | один прогон `bypass-status --route-audit-recheck` |
| `omavpn-route-recheck.timer` | раз в сутки (через 12 минут после загрузки) |

Проверить:

```bash
systemctl --user list-timers 'omavpn-route-*'
systemctl --user status omavpn-route-audit.service
```

## Ограничения

- Только IPv4 (`curl -4`) — как и весь проект: IPv6 в туннеле заблокирован.
- Проба идёт «как есть», поэтому при выключенном VPN путь `direct` — это
  настоящий прямой путь, а `proxy`-пробы упираются в мёртвый SOCKS. Аудит в
  таком состоянии ничего не переключает (проверка через VPN недоступна).
- Если домен не отвечает ни напрямую, ни через VPN (VPN упал, сеть лежит),
  аудит молчит: лечением VPN занимается `omavpn-guard` (`docs/guard.md`).
- Таймаут одной пробы — 10 с; прогон по семи доменам занимает 10–20 с.
