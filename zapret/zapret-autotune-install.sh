#!/usr/bin/env bash
# Установка zapret-autotune: сервис автоматического подбора стратегии zapret
# под текущую сеть. Запуск один раз:
#     sudo bash ~/.local/share/omavpn/zapret-autotune-install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти через sudo: sudo bash $0"
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${SUDO_USER:-}"
[ -n "$USER_NAME" ] && [ "$USER_NAME" != "root" ] || {
  echo "Не удалось определить пользователя (SUDO_USER). Запусти именно через sudo из сессии пользователя."
  exit 1
}
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

PROBE_USER="${PROBE_USER:-zapret-probe}"
echo "==> Служебный пользователь для изолированного пробника: $PROBE_USER"
if ! id "$PROBE_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$PROBE_USER" 2>/dev/null || true
fi
if ! id "$PROBE_USER" >/dev/null 2>&1; then
  echo "u $PROBE_USER - \"zapret isolated probe user\"" > /usr/lib/sysusers.d/zapret-probe.conf
  systemd-sysusers >/dev/null 2>&1 || true
fi
if id "$PROBE_USER" >/dev/null 2>&1; then
  echo "    probe uid: $(id -u "$PROBE_USER")"
else
  echo "    [!] не удалось создать $PROBE_USER — перебор будет без изоляции"
fi

echo "==> Пользователь: $USER_NAME ($USER_HOME)"
echo "==> Ставлю скрипт в /usr/local/bin/zapret-autotune"
install -Dm755 "$HERE/zapret-autotune" /usr/local/bin/zapret-autotune

mkdir -p /var/lib/zapret-autotune
# подчистить мусорные записи от моментов без сети
find /var/lib/zapret-autotune -maxdepth 1 -name '*unknown*.strategy' -delete 2>/dev/null || true
find /var/lib/zapret-autotune -maxdepth 1 -name '*unknown*.opt' -delete 2>/dev/null || true
cat > /etc/zapret-autotune.conf <<EOF
# Пользователь, чьи omavpn/direct_domains обслуживаются автотюнером.
USER_NAME=$USER_NAME
USER_HOME=$USER_HOME
# 1 = автотюнер сам поднимает omavpn на сетях, где обход не работает.
AUTO_VPN=1
# Пользователь для изолированного пробника стратегий.
PROBE_USER=$PROBE_USER
# Как часто (сек) в режиме vpn перепроверять, не появился ли рабочий обход.
RETRY_SECONDS=1800
EOF
chmod 644 /etc/zapret-autotune.conf

echo "==> Гарантирую базовые настройки zapret"
python3 - /opt/zapret/config <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
def setopt(t, k, v):
    if re.search(rf'^#?\s*{k}=', t, re.M):
        return re.sub(rf'^#?\s*{k}=.*$', f'{k}={v}', t, count=1, flags=re.M)
    return t.rstrip() + f"\n{k}={v}\n"
t = setopt(t, 'NFQWS_ENABLE', '1')
t = setopt(t, 'MODE_FILTER', 'hostlist')
t = setopt(t, 'INIT_APPLY_FW', '1')
open(p, 'w').write(t)
PY

echo "==> systemd units"
cat > /etc/systemd/system/zapret-autotune.service <<'EOF'
[Unit]
Description=Auto-tune zapret strategy for the current network
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zapret-autotune run
Nice=5
TimeoutStartSec=2400
EOF

cat > /etc/systemd/system/zapret-autotune.timer <<'EOF'
[Unit]
Description=Periodic zapret strategy auto-tune

[Timer]
OnBootSec=3min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "==> NetworkManager dispatcher"
cat > /etc/NetworkManager/dispatcher.d/90-zapret-autotune <<'EOF'
#!/bin/sh
# Перезапуск автотюнера zapret при смене физической сети.
case "$1" in
  omavpn0|tailscale0|tun*|lo|docker*|veth*) exit 0 ;;
esac
case "$2" in
  up|connectivity-change) systemctl start --no-block zapret-autotune.service ;;
esac
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/90-zapret-autotune

echo "==> routefix: маршрутизация пакетов zapret мимо policy-routing VPN"
install -Dm755 "$HERE/zapret-routefix.sh" /usr/local/bin/zapret-routefix
cat > /etc/systemd/system/zapret-routefix.service <<'EOF'
[Unit]
Description=Route zapret desync packets past VPN policy routing
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/zapret-routefix apply
ExecStop=/usr/local/bin/zapret-routefix clear

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now zapret-autotune.timer
systemctl enable --now zapret-routefix.service

echo "==> Проверка изоляции пробника (host IP должен быть VPN, probe IP — прямой)"
systemctl stop zapret-autotune.service 2>/dev/null || true
/usr/local/bin/zapret-autotune probe-selftest || echo "[!] probe-selftest не прошёл — перебор будет без изоляции"

cat <<EOF

Готово. Запускаю первый подбор под текущую сеть (может занять несколько минут).

  Куда смотреть:  journalctl -fu zapret-autotune.service
  Лог:            /var/log/zapret-autotune.log
  Кэш сетей:      zapret-autotune show
  Переподобрать:  sudo zapret-autotune rescan

EOF
systemctl start --no-block zapret-autotune.service
echo "==> Сервис запущен в фоне."
