#!/usr/bin/env bash
# Установка omavpn: статические бинари Xray + sing-box, CLI, плагин панели Omarchy.
# Единственное, что требует root — setcap на sing-box (для TUN). Запускать обычным пользователем.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME:?}"
SHARE="$HOME_DIR/.local/share/omavpn"
BIN_DIR="$SHARE/bin"
LOCAL_BIN="$HOME_DIR/.local/bin"
PLUGIN_ID="io.github.blazeeers.omavpn"
PLUGIN_DIR="$HOME_DIR/.config/omarchy/plugins/$PLUGIN_ID"

XRAY_VER="${XRAY_VER:-26.3.27}"
SB_VER="${SB_VER:-1.14.1}"
# sha256 закреплённых артефактов. При смене версии задай и соответствующий хеш.
XRAY_SHA256="${XRAY_SHA256:-23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae}"
SB_SHA256="${SB_SHA256:-12cb2816b52febb356f6a885b740cc8758c3f30b8ae0ca8edba80f0d2d35343f}"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64.zip"
SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-amd64.tar.gz"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# Юнит systemd пишем только если содержимое изменилось: раньше `cat >` каждый
# раз затирал файл, и правки пользователя (интервал в таймере, Environment=)
# пропадали молча. Изменённый юнит сохраняем рядом как .bak — так видно, что
# установщик переписал непустой файл, и есть откуда вернуть свои строки.
write_unit() { # $1 — путь юнита, stdin — новое содержимое
  local path="$1" new
  new="$(mktemp)"
  cat >"$new"
  if [ -f "$path" ]; then
    if cmp -s "$new" "$path"; then
      rm -f "$new"
      return 0
    fi
    cp -p "$path" "$path.bak"
    warn "$(basename "$path") отличался от шаблона — прежняя версия в $path.bak"
  fi
  install -m 0644 "$new" "$path"
  rm -f "$new"
}

verify_sha256() { # $1 — файл, $2 — ожидаемый sha256, $3 — имя
  if [ -z "$2" ]; then
    echo "Нет sha256 для $3. Задай XRAY_SHA256/SB_SHA256 для своей версии и повтори."
    exit 1
  fi
  local got
  got="$(sha256sum "$1" | awk '{print $1}')"
  if [ "$got" != "$2" ]; then
    echo "ОШИБКА: sha256 не совпал для $3"
    echo "  ожидалось: $2"
    echo "  получено:  $got"
    exit 1
  fi
  say "sha256 $3 — ок"
}

for tool in curl python3 tar sha256sum jq ip flock; do
  command -v "$tool" >/dev/null || { echo "Нужен '$tool' в PATH"; exit 1; }
done
# getcap — только чтобы показать выданные caps и подсказать, что записать.
# Без него (нет libcap) установка не должна отказывать: caps ставятся setcap,
# а guard умеет жить без getcap и не считает это поломкой.
HAVE_GETCAP=0
if command -v getcap >/dev/null 2>&1; then
  HAVE_GETCAP=1
else
  warn "getcap не найден (libcap) — выданные caps не покажу; на работу TUN это не влияет"
fi

mkdir -p "$BIN_DIR" "$LOCAL_BIN" "$HOME_DIR/.config/omavpn" "$HOME_DIR/.local/state/omavpn" "$HOME_DIR/.cache/omavpn"

# --- Xray -------------------------------------------------------------------
if [ -x "$BIN_DIR/xray" ] && [ -z "${FORCE:-}" ]; then
  say "Xray уже установлен ($("$BIN_DIR/xray" version | head -1))"
else
  say "Скачиваю Xray…"
  TMP="$(mktemp -d)"
  curl -fL --retry 3 -o "$TMP/xray.zip" "$XRAY_URL"
  verify_sha256 "$TMP/xray.zip" "$XRAY_SHA256" "Xray-linux-64.zip"
  python3 - "$TMP/xray.zip" "$BIN_DIR" <<'PY'
import sys, zipfile, os, stat
zf = zipfile.ZipFile(sys.argv[1])
dest = sys.argv[2]
for name in zf.namelist():
    if os.path.basename(name) == "xray":
        out = os.path.join(dest, "xray")
        with zf.open(name) as src, open(out, "wb") as dst:
            dst.write(src.read())
        os.chmod(out, 0o755)
        break
else:
    sys.exit("xray не найден в архиве")
PY
  rm -rf "$TMP"
fi

# --- sing-box ---------------------------------------------------------------
if [ -x "$BIN_DIR/sing-box" ] && [ -z "${FORCE:-}" ]; then
  say "sing-box уже установлен ($("$BIN_DIR/sing-box" version | head -1))"
else
  say "Скачиваю sing-box…"
  TMP="$(mktemp -d)"
  curl -fL --retry 3 -o "$TMP/sb.tar.gz" "$SB_URL"
  verify_sha256 "$TMP/sb.tar.gz" "$SB_SHA256" "sing-box-${SB_VER}-linux-amd64.tar.gz"
  tar -xzf "$TMP/sb.tar.gz" -C "$TMP"
  found="$(find "$TMP" -type f -name sing-box | head -1)"
  [ -n "$found" ] || { echo "sing-box не найден в архиве"; exit 1; }
  install -m 0755 "$found" "$BIN_DIR/sing-box"
  rm -rf "$TMP"
fi

# --- capabilities для TUN ----------------------------------------------------
# Недоступный root больше не рвёт установку на середине (CLI, таймеры и виджет
# ещё не поставлены): без caps не работает только TUN, поэтому предупреждаем и
# идём дальше. Порядок — от самого дешёвого к самому навязчивому: sudo без
# пароля, sudo с вводом пароля (только в терминале), pkexec (только с потолком
# по времени — без polkit-агента он висит, ожидая подтверждения).
say "Выдаю CAP_NET_ADMIN бинарю sing-box (нужен root)…"
CAPS_OK=0
CAPS_CMD=(setcap cap_net_admin,cap_net_raw+ep "$BIN_DIR/sing-box")
if sudo -n "${CAPS_CMD[@]}" 2>/dev/null; then
  CAPS_OK=1
elif [ -t 0 ] && [ -t 1 ] && sudo "${CAPS_CMD[@]}"; then
  CAPS_OK=1
elif command -v pkexec >/dev/null 2>&1 &&
     timeout 90 pkexec "${CAPS_CMD[@]}"; then
  CAPS_OK=1
fi
if [ "$CAPS_OK" = 1 ]; then
  if [ "$HAVE_GETCAP" = 1 ]; then getcap "$BIN_DIR/sing-box" || true; fi
else
  warn "Не удалось выдать CAP_NET_ADMIN (sudo/pkexec недоступны)."
  warn "Выдай вручную, иначе TUN не поднимется:"
  warn "  sudo setcap cap_net_admin,cap_net_raw+ep $BIN_DIR/sing-box"
fi

# --- CLI --------------------------------------------------------------------
say "Ставлю CLI в $LOCAL_BIN/omavpn"
install -m 0755 "$HERE/bin/omavpn" "$LOCAL_BIN/omavpn"

# --- Плагин панели -----------------------------------------------------------
if [ -d "$HERE/shell-plugin/bypass-status" ]; then
  say "Устанавливаю плагин панели ($PLUGIN_ID — виджет «Обходы»)…"
  mkdir -p "$PLUGIN_DIR/icons"
  cp -f "$HERE/manifest.json" "$PLUGIN_DIR/"
  cp -f "$HERE/shell-plugin/bypass-status/Panel.qml" "$PLUGIN_DIR/"
  cp -f "$HERE/shell-plugin/bypass-status/icons/"*.png "$PLUGIN_DIR/icons/" 2>/dev/null || true
  # локальная установка кладёт Panel.qml в корень плагина — правим entryPoint
  python3 - "$PLUGIN_DIR/manifest.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["entryPoints"]["barWidget"] = "Panel.qml"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PYEOF
  if command -v omarchy-shell >/dev/null; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    if command -v omarchy >/dev/null; then
      omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
      omarchy bar move "$PLUGIN_ID" --section right >/dev/null 2>&1 || true
    fi
  else
    warn "omarchy-shell не найден в PATH — включите виджет вручную: omarchy plugin enable $PLUGIN_ID"
  fi
else
  warn "Каталог shell-plugin/bypass-status не найден — виджет не установлен"
fi

# --- CLI виджета «Обходы» --------------------------------------------------
if [ -f "$HERE/bin/bypass-status" ]; then
  install -m 0755 "$HERE/bin/bypass-status" "$LOCAL_BIN/bypass-status"
fi

# --- Проверка и установка обновлений --------------------------------------
# Виджет умеет скачать его сам, но установка должна ставить всё сразу: иначе
# раздел «Обновления» до первого запуска панели остаётся пустым.
if [ -f "$HERE/bin/omavpn-updater" ]; then
  install -m 0755 "$HERE/bin/omavpn-updater" "$LOCAL_BIN/omavpn-updater"
fi

# --- Надзиратель за обходами (omavpn-guard) --------------------------------
# Проверяет YouTube/Discord/Telegram и лечит: поднимает VPN, чинит профиль,
# перезапускает tg-ws-proxy, перебирает ноды, просит zapret-autotune
# перепроверить стратегии. VPN никогда не выключает.
if [ -f "$HERE/bin/omavpn-guard" ]; then
  say "Ставлю надзиратель omavpn-guard и его таймеры…"
  install -m 0755 "$HERE/bin/omavpn-guard" "$LOCAL_BIN/omavpn-guard"
  mkdir -p "$HOME_DIR/.config/systemd/user"

  write_unit "$HOME_DIR/.config/systemd/user/omavpn-guard.service" <<EOF
[Unit]
Description=Проверка и самовосстановление VPN/YouTube/Discord/Telegram (omavpn-guard)

[Service]
Type=oneshot
ExecStart=%h/.local/bin/omavpn-guard
# 4200 с: худший законный прогон — autotune-перебор (1200 с), перебор нод
# (до 750 с), heal (420 с) и несколько подъёмов VPN. При 3600 с systemd убивал
# guard посреди лечения, и в лог не попадало состояние (бэкофф/итог). Внутри
# скрипта свой дедлайн 3900 с: он заканчивает работу сам, с записью в лог.
TimeoutStartSec=4200
# 150 с на остановку: по SIGTERM guard восстанавливает исходную ноду (до 90 с на
# `omavpn node` + ожидание туннеля), и systemd не должен добивать его раньше.
TimeoutStopSec=150
SuccessExitStatus=1
Nice=10
# KillMode=process обязателен: аудит/guard перезапускают VPN, а xray и sing-box
# живут в cgroup юнита (omavpn запускает их через setsid, но из cgroup не выводит).
# Без этого systemd по завершении oneshot-юнита убивает их вместе с собой, и VPN
# ложится после каждого исправленного маршрута, а guard — после каждой проверки.
KillMode=process
EOF

  write_unit "$HOME_DIR/.config/systemd/user/omavpn-guard.timer" <<'EOF'
[Unit]
Description=Периодическая проверка обходов

[Timer]
OnBootSec=120s
OnUnitInactiveSec=10min
AccuracySec=30s
# Разброс, чтобы guard и аудит маршрутов не стартовали в одну секунду и не
# перезапускали туннель одновременно (аудит — RandomizedDelaySec=180).
RandomizedDelaySec=60
Unit=omavpn-guard.service

[Install]
WantedBy=timers.target
EOF

  write_unit "$HOME_DIR/.config/systemd/user/omavpn-autostart.service" <<'EOF'
[Unit]
Description=Поднять VPN при входе, если он был включён (omavpn)
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/omavpn-guard --autostart
RemainAfterExit=yes
# Таймаут больше ожидания лока в --autostart (AUTOSTART_LOCK_WAIT=1260 с):
# иначе systemd убивал юнит раньше, чем guard дожидался идущего прогона, и VPN
# после входа не поднимался. 1500 с — ожидание лока плюс запас на подъём VPN.
TimeoutStartSec=1500
# KillMode=process, как у guard/аудита: omavpn поднимает xray и sing-box из
# cgroup этого юнита, и без process они умерли бы вместе с oneshot-запуском,
# то есть VPN ложился бы сразу после автозапуска.
KillMode=process

[Install]
WantedBy=graphical-session.target
EOF

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now omavpn-guard.timer >/dev/null 2>&1 || \
    warn "Не удалось включить omavpn-guard.timer — включи вручную: systemctl --user enable --now omavpn-guard.timer"
  systemctl --user enable omavpn-autostart.service >/dev/null 2>&1 || true
fi

# --- Аудит маршрутов --------------------------------------------------------
# Каждые 10 минут проверяет домены из ROUTE_PROBES: если домен по текущему
# маршруту не отвечает, а через VPN отвечает — ставит оверрайд
# (omavpn route set ... proxy) и перезапускает sing-box. Раз в сутки —
# перепроверка старых оверрайдов: снять и посмотреть, не работает ли direct.
if [ -x "$LOCAL_BIN/bypass-status" ] && [ -x "$LOCAL_BIN/omavpn" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    say "Ставлю таймеры аудита маршрутов (route-audit)…"
    mkdir -p "$HOME_DIR/.config/systemd/user"

    write_unit "$HOME_DIR/.config/systemd/user/omavpn-route-audit.service" <<EOF
[Unit]
Description=Router audit: a domain that fails on its current route moves to a working one
After=network-online.target

[Service]
Type=oneshot
# %h, а не подставленный абсолютный путь: если в домашнем каталоге есть
# пробел, ExecStart без кавычек systemd разбирает по словам и юнит не
# запускается вовсе.
ExecStart=%h/.local/bin/bypass-status --route-audit
Nice=10
# 1200 с, а не 600: прогон двусторонний (7 проб × 2 попытки × 10 с) и может
# сделать до четырёх перезапусков VPN. С 600 с systemd убивал юнит между
# переключением и откатом — домен оставался на непроверенном пути.
TimeoutStartSec=1200
# KillMode=process обязателен: аудит/guard перезапускают VPN, а xray и sing-box
# живут в cgroup юнита (omavpn запускает их через setsid, но из cgroup не выводит).
# Без этого systemd по завершении oneshot-юнита убивает их вместе с собой, и VPN
# ложится после каждого исправленного маршрута, а guard — после каждой проверки.
KillMode=process
EOF

    write_unit "$HOME_DIR/.config/systemd/user/omavpn-route-audit.timer" <<'EOF'
[Unit]
Description=Periodic route audit (direct/proxy per domain)

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
# 180 с, а не 30: с 30 с аудит регулярно попадал в тот же момент, что и guard
# (у него RandomizedDelaySec=60), и оба перезапускали VPN почти одновременно.
RandomizedDelaySec=180
Persistent=true
Unit=omavpn-route-audit.service

[Install]
WantedBy=timers.target
EOF

    write_unit "$HOME_DIR/.config/systemd/user/omavpn-route-recheck.service" <<EOF
[Unit]
Description=Route overrides recheck: try direct again for old proxy overrides
After=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/bypass-status --route-audit-recheck
Nice=10
# 1200 с: снятие пачки оверрайдов, перезапуск, проба каждого домена (2 попытки
# по 10 с) и ещё один перезапуск на возврат. 900 с не хватало на 10+ доменов.
TimeoutStartSec=1200
# KillMode=process обязателен: аудит/guard перезапускают VPN, а xray и sing-box
# живут в cgroup юнита (omavpn запускает их через setsid, но из cgroup не выводит).
# Без этого systemd по завершении oneshot-юнита убивает их вместе с собой, и VPN
# ложится после каждого исправленного маршрута, а guard — после каждой проверки.
KillMode=process
EOF

    write_unit "$HOME_DIR/.config/systemd/user/omavpn-route-recheck.timer" <<'EOF'
[Unit]
Description=Daily route override recheck

[Timer]
OnBootSec=12min
OnUnitActiveSec=24h
RandomizedDelaySec=5min
Persistent=true
Unit=omavpn-route-recheck.service

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable --now omavpn-route-audit.timer >/dev/null 2>&1 || \
      warn "Не удалось включить omavpn-route-audit.timer — включи вручную: systemctl --user enable --now omavpn-route-audit.timer"
    systemctl --user enable --now omavpn-route-recheck.timer >/dev/null 2>&1 || \
      warn "Не удалось включить omavpn-route-recheck.timer — включи вручную: systemctl --user enable --now omavpn-route-recheck.timer"
  else
    warn "systemctl не найден — таймеры аудита маршрутов не поставлены (bypass-status --route-audit можно запускать вручную)"
  fi
fi

# --- Ежедневная проверка обновлений ----------------------------------------
if [ -x "$LOCAL_BIN/bypass-status" ]; then
  say "Ставлю таймер проверки обновлений (zapret, tg-ws-proxy)…"
  mkdir -p "$HOME_DIR/.config/systemd/user"
  write_unit "$HOME_DIR/.config/systemd/user/omavpn-updates.service" <<EOF
[Unit]
Description=Check component updates (zapret, tg-ws-proxy)

[Service]
Type=oneshot
ExecStart=%h/.local/bin/bypass-status --updates
EOF
  write_unit "$HOME_DIR/.config/systemd/user/omavpn-updates.timer" <<'EOF'
[Unit]
Description=Daily component update check

[Timer]
OnBootSec=5min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now omavpn-updates.timer >/dev/null 2>&1 || true
fi

# --- Re:filter: списки заблокированного в РФ -------------------------------
# Готовые бинарные rule-set'ы (домены + IP) обновляются раз в сутки. Отдельный
# юнит, а не общий updates: наборы весят ~0,6 МБ, и их обновление при изменении
# перезапускает туннель — это должно быть видно в журнале отдельной строкой.
mkdir -p "$HOME_DIR/.config/systemd/user"
write_unit "$HOME_DIR/.config/systemd/user/omavpn-refilter.service" <<EOF
[Unit]
Description=Re:filter: обновление списков заблокированных в РФ доменов и IP
After=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/omavpn refilter update
Nice=10
# 400 с: два файла по 120 с на скачивание + до 60 с на разбор sing-box каждый,
# плюс перезапуск туннеля при изменении списка. Меньший таймаут убивал законное
# обновление на плохой сети.
TimeoutStartSec=400
# KillMode=process: при изменении списка omavpn перезапускает VPN, а xray и
# sing-box живут в cgroup юнита — иначе systemd убил бы их вместе с собой.
KillMode=process
EOF

write_unit "$HOME_DIR/.config/systemd/user/omavpn-refilter.timer" <<'EOF'
[Unit]
Description=Daily Re:filter list update

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
RandomizedDelaySec=2min
Persistent=true
Unit=omavpn-refilter.service

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user enable --now omavpn-refilter.timer >/dev/null 2>&1 || \
  warn "Не удалось включить omavpn-refilter.timer — включи вручную: systemctl --user enable --now omavpn-refilter.timer"

# --- Подписка ---------------------------------------------------------------
SUB_FILE="$HOME_DIR/.config/omavpn/subscription"
if [ ! -s "$SUB_FILE" ]; then
  if [ -n "${OMAVPN_SUB_URL:-}" ]; then
    printf '%s\n' "$OMAVPN_SUB_URL" > "$SUB_FILE"
    chmod 600 "$SUB_FILE"
    say "URL подписки сохранён в $SUB_FILE"
  else
    warn "URL подписки не задан. Положи его в $SUB_FILE (chmod 600) или задай OMAVPN_SUB_URL и перезапусти установку."
  fi
fi

say "Загружаю подписку…"
"$LOCAL_BIN/omavpn" --json update || warn "Не удалось загрузить подписку (проверьте сеть)"

# Списки Re:filter — сразу, без ручных действий: иначе «Заблокированные в РФ —
# через VPN» первые сутки работало бы без самих списков. Сбой сети установку не
# рвёт: таймер подтянет наборы позже.
say "Загружаю списки Re:filter (заблокированные в РФ домены и IP)…"
"$LOCAL_BIN/omavpn" --json refilter update \
  || warn "Списки Re:filter не загрузились — обновятся по таймеру omavpn-refilter.timer (systemctl --user start omavpn-refilter.service)"

cat <<EOF

Готово.

  Подключить:      omavpn on
  Отключить:       omavpn off
  Статус:          omavpn status
  Список:          omavpn profiles
  Проверить IP:    omavpn check
  Re:filter:       omavpn refilter status | on | off | update
  Подписка:        omavpn subscription get | set <url>
  Полный сброс:    omavpn reset

Виджет $PLUGIN_ID должен появиться в правой части панели Omarchy.
Если его нет: omarchy plugin enable $PLUGIN_ID && omarchy bar move $PLUGIN_ID --section right
EOF
