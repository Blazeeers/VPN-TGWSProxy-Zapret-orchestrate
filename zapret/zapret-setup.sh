#!/usr/bin/env bash
# Настройка zapret (nfqws + nftables) для обхода Discord/YouTube поверх omavpn.
# Запуск от root:
#     sudo bash ~/.local/share/omavpn/zapret-setup.sh
#
# Что делает:
#   1. определяет WAN-интерфейс (или берёт WAN_IFACE), задаёт IFACE_WAN,
#      включает nfqws, MODE_FILTER=none;
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

# WAN определяется сам (раньше здесь было жёстко wlp2s0 — на кабеле и на другой
# машине zapret вставал не на тот интерфейс и не ловил трафик). VPN-интерфейсы
# (omavpn0, tailscale0, tun*) пропускаем: WAN — это физический выход в сеть.
wan_iface() {
  ip -o route show default 2>/dev/null | awk '{
    d="";
    for (i=1;i<=NF;i++) if ($i=="dev") d=$(i+1);
    if (d!="" && d!="omavpn0" && d!="tailscale0" && d !~ /^tun/) { print d; exit }
  }'
}
WAN="${WAN_IFACE:-$(wan_iface)}"
[ -n "$WAN" ] || {
  echo "Не удалось определить WAN-интерфейс (нет маршрута по умолчанию?)."
  echo "Запусти с явным указанием: sudo WAN_IFACE=wlp2s0 bash $0"
  exit 1
}

[ -f "$CFG" ] || { echo "Нет $CFG — zapret не установлен?"; exit 1; }

stamp="$(date +%Y%m%d-%H%M%S)"
[ -f "$CFG.orig" ] || cp -a "$CFG" "$CFG.orig"
cp -a "$CFG" "$CFG.bak.$stamp"
# Бэкапы копились без чистки: каждый запуск setup оставлял ещё один файл
# навсегда. Держим последние 3 — этого хватает, чтобы откатить текущий и
# предыдущий прогон (то же правило, что у zapret-strategy.sh).
{ ls -1dt "$CFG".bak.[0-9]* 2>/dev/null || true; } \
  | tail -n +4 | while IFS= read -r old; do rm -f -- "$old"; done
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
# Считаем во временный файл, а не в $EXCL: раньше `> "$EXCL"` уже обнулял
# боевой список, и при пустом результате (нет sub.json, DNS не разрешил имена
# серверов) скрипт печатал «0 адресов исключено», выходил с кодом 0 и
# перезапускал zapret. Дальше zapret десинкал рукопожатие собственного туннеля —
# то есть «успех» ломал VPN. Теперь пустой результат — ошибка: боевой файл не
# трогаем, zapret не перезапускаем.
EXCL_NEW="$(mktemp)"
python3 - "$USER_HOME" > "$EXCL_NEW" <<'PY'
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
EXCL_COUNT=$(grep -c . "$EXCL_NEW" 2>/dev/null || true)
if [ "${EXCL_COUNT:-0}" -eq 0 ]; then
  rm -f "$EXCL_NEW"
  cat >&2 <<EOF
ОШИБКА: не удалось определить ни одного адреса серверов omavpn — исключать из
         zapret нечего. Это не «0 адресов исключено», а поломка: без исключений
         zapret начнёт десинхронизировать рукопожатие собственного туннеля и VPN
         перестанет работать.

  Причины, по которым так бывает:
    * нет ~/.cache/omavpn/sub.json      -> сначала: omavpn update
    * серверы заданы доменами и DNS их не разрешил -> проверь сеть и
      /etc/resolv.conf, затем повтори
    * в подписке нет outbound'ов vless/vmess/trojan/shadowsocks/hysteria2/wireguard

  Что сделано: $CFG обновлён (бэкап $CFG.bak.$stamp), $EXCL НЕ изменён,
  zapret.service НЕ перезапущен.
EOF
  exit 1
fi
install -m 0644 "$EXCL_NEW" "$EXCL"
rm -f "$EXCL_NEW"
echo "    $EXCL_COUNT адресов исключено"

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
