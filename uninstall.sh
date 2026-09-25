#!/usr/bin/env bash
# Удаление omavpn.
set -euo pipefail

HOME_DIR="${HOME:?}"
PURGE="${1:-}"

"$HOME_DIR/.local/bin/omavpn" off >/dev/null 2>&1 || true
pkill -f "$HOME_DIR/.local/share/omavpn/bin/sing-box" 2>/dev/null || true
pkill -f "$HOME_DIR/.local/share/omavpn/bin/xray" 2>/dev/null || true

rm -rf "$HOME_DIR/.config/omarchy/plugins/io.github.blazeeers.omavpn"
command -v omarchy-shell >/dev/null && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

rm -f "$HOME_DIR/.local/bin/omavpn"

if [ "$PURGE" = "--purge" ]; then
  rm -rf "$HOME_DIR/.local/share/omavpn" \
         "$HOME_DIR/.config/omavpn" \
         "$HOME_DIR/.local/state/omavpn" \
         "$HOME_DIR/.cache/omavpn"
  echo "Удалено полностью (бинари, конфиги, состояние)."
else
  echo "Удалены CLI и виджет. Данные сохранены в:"
  echo "  ~/.local/share/omavpn  ~/.config/omavpn  ~/.local/state/omavpn  ~/.cache/omavpn"
  echo "Для полного удаления: $0 --purge"
fi
