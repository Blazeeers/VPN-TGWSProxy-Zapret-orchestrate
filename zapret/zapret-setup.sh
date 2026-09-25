#!/usr/bin/env bash
# Настройка zapret (nfqws + nftables) для обхода Discord/YouTube поверх omavpn.
# Запуск от root:
#     sudo bash ~/.local/share/omavpn/zapret-setup.sh
#
# Что делает:
#   1. задаёт IFACE_WAN (физический интерфейс), включает nfqws, MODE_FILTER=none;
#   2. пишет IP серверов omavpn в nozapret-исключение (чтобы не ломать туннель);
#   3. включает и перезапускает zapret.service.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти через sudo: sudo bash $0"
  exit 1
fi

USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
CFG=/opt/zapret/config
EXCL=/opt/zapret/ipset/zapret-ip-exclude.txt
WAN="${WAN_IFACE:-wlp2s0}"

[ -f "$CFG" ] || { echo "Нет $CFG — zapret не установлен?"; exit 1; }

stamp="$(date +%Y%m%d-%H%M%S)"
[ -f "$CFG.orig" ] || cp -a "$CFG" "$CFG.orig"
cp -a "$CFG" "$CFG.bak.$stamp"
echo "==> Конфиг сохранён: $CFG.bak.$stamp"

echo "==> WAN=$WAN, пользователь=$USER_NAME"
python3 - "$CFG" "$WAN" <<'PY'
import re, sys
path, wan = sys.argv[1], sys.argv[2]
text = open(path).read()

def setopt(text, key, value):
    if re.search(rf'^#?\s*{key}=', text, re.M):
        return re.sub(rf'^#?\s*{key}=.*$', f'{key}={value}', text, count=1, flags=re.M)
    return text.rstrip() + f"\n{key}={value}\n"

text = setopt(text, 'IFACE_WAN', f'"{wan}"')
text = setopt(text, 'NFQWS_ENABLE', '1')
text = setopt(text, 'MODE_FILTER', 'none')
text = setopt(text, 'INIT_APPLY_FW', '1')
open(path, 'w').write(text)
PY

echo "==> Формирую исключение серверов omavpn"
python3 - "$USER_HOME" > "$EXCL" <<'PY'
import ipaddress, json, socket, sys
home = sys.argv[1]
try:
    data = json.load(open(f"{home}/.cache/omavpn/sub.json"))
except (OSError, ValueError):
    sys.exit(0)
configs = data.get("configs") if isinstance(data, dict) else data
PROXY = {"vless", "vmess", "trojan", "shadowsocks", "hysteria2", "wireguard"}
ips = set()
for cfg in configs or []:
    for out in cfg.get("outbounds", []) or []:
        if out.get("protocol") not in PROXY:
            continue
        settings = out.get("settings", {}) or {}
        for key in ("vnext", "servers"):
            for item in settings.get(key, []) or []:
                addr = item.get("address") or item.get("server")
                if not addr:
                    continue
                try:
                    ip = ipaddress.ip_address(addr)
                    ips.add(f"{ip}/{32 if ip.version == 4 else 128}")
                except ValueError:
                    try:
                        for res in socket.getaddrinfo(addr, None, socket.AF_INET):
                            ips.add(res[4][0] + "/32")
                    except OSError:
                        pass
print("\n".join(sorted(ips)))
PY
echo "    $(grep -c . "$EXCL" 2>/dev/null || echo 0) адресов исключено"

echo "==> Перезапуск zapret.service"
systemctl daemon-reload
systemctl enable zapret.service >/dev/null 2>&1 || true
systemctl restart zapret.service
sleep 3

echo "==> Статус: $(systemctl is-active zapret.service)"
pgrep -a nfqws || echo "nfqws НЕ запущен"
echo "==> nozapret (исключения):"
nft list set inet zapret nozapret 2>/dev/null | sed -n '1,12p' || ipset list nozapret 2>/dev/null | head -12 || true
echo "==> Готово"
