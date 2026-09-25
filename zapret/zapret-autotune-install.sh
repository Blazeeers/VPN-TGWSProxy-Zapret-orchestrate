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

systemctl daemon-reload
systemctl enable --now zapret-autotune.timer

cat <<EOF

Готово. Запускаю первый подбор под текущую сеть (может занять несколько минут).

  Куда смотреть:  journalctl -fu zapret-autotune.service
  Лог:            /var/log/zapret-autotune.log
  Кэш сетей:      zapret-autotune show
  Переподобрать:  sudo zapret-autotune rescan

EOF
systemctl start --no-block zapret-autotune.service
echo "==> Сервис запущен в фоне."
