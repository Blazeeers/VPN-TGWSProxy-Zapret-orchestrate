#!/usr/bin/env bash
# Удаление omavpn.
set -euo pipefail

HOME_DIR="${HOME:?}"
PURGE="${1:-}"

"$HOME_DIR/.local/bin/omavpn" off >/dev/null 2>&1 || true
pkill -f "$HOME_DIR/.local/share/omavpn/bin/sing-box" 2>/dev/null || true
pkill -f "$HOME_DIR/.local/share/omavpn/bin/xray" 2>/dev/null || true

# Надзиратель за обходами: сначала гасим таймеры, иначе после удаления CLI
# они продолжат поднимать VPN и слать уведомления каждые 10 минут.
systemctl --user disable --now omavpn-guard.timer omavpn-autostart.service >/dev/null 2>&1 || true
rm -f "$HOME_DIR/.config/systemd/user/omavpn-guard.service" \
      "$HOME_DIR/.config/systemd/user/omavpn-guard.timer" \
      "$HOME_DIR/.config/systemd/user/omavpn-autostart.service"
systemctl --user daemon-reload >/dev/null 2>&1 || true
rm -f "$HOME_DIR/.local/bin/omavpn-guard"

# Аудит маршрутов: те же правила — сначала таймеры, потом файлы юнитов.
systemctl --user disable --now omavpn-route-audit.timer omavpn-route-recheck.timer >/dev/null 2>&1 || true
rm -f "$HOME_DIR/.config/systemd/user/omavpn-route-audit.service" \
      "$HOME_DIR/.config/systemd/user/omavpn-route-audit.timer" \
      "$HOME_DIR/.config/systemd/user/omavpn-route-recheck.service" \
      "$HOME_DIR/.config/systemd/user/omavpn-route-recheck.timer"
systemctl --user daemon-reload >/dev/null 2>&1 || true

# Оверрайды маршрутов и кэш аудита — состояние машины, а не данные пользователя.
# Оставленные после удаления, они тихо ломают маршруты после переустановки:
# домен «навсегда» уходит в туннель по правилу, которое ставил аудит под другую
# сеть. Поэтому чистим в любом режиме, не только в --purge.
rm -f "$HOME_DIR/.config/omavpn/route_overrides.json"
rm -f "$HOME_DIR"/.cache/omavpn/route-audit*.json 2>/dev/null || true

rm -rf "$HOME_DIR/.config/omarchy/plugins/io.github.blazeeers.omavpn"
command -v omarchy-shell >/dev/null && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

rm -f "$HOME_DIR/.local/bin/omavpn"

if [ "$PURGE" = "--purge" ]; then
  rm -rf "$HOME_DIR/.local/share/omavpn" \
         "$HOME_DIR/.config/omavpn" \
         "$HOME_DIR/.local/state/omavpn" \
         "$HOME_DIR/.local/state/omavpn-guard" \
         "$HOME_DIR/.cache/omavpn"
  echo "Удалено полностью (бинари, конфиги, состояние)."
else
  echo "Удалены CLI, надзиратель и виджет. Данные сохранены в:"
  echo "  ~/.local/share/omavpn  ~/.config/omavpn  ~/.local/state/omavpn"
  echo "  ~/.local/state/omavpn-guard  ~/.cache/omavpn"
  echo "Для полного удаления: $0 --purge"
fi
