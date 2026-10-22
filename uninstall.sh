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

# Оверрайды маршрутов — это решение человека, а не мусор установки: в обычном
# режиме сохраняем их и убираем только записи аудита (reason начинается с
# «аудит»). Иначе переустановка молча стирает ручные `omavpn route set`, а
# автоматические оверрайды остаются и тихо уводят домены под другую сеть.
OVERRIDES="$HOME_DIR/.config/omavpn/route_overrides.json"
if [ "$PURGE" = "--purge" ]; then
  rm -f "$OVERRIDES"
else
  if [ -f "$OVERRIDES" ]; then
    cp -f "$OVERRIDES" "$OVERRIDES.bak" 2>/dev/null || true
    if command -v jq >/dev/null 2>&1; then
      TMP_OVR="$(mktemp)"
      if jq 'with_entries(select(((.value.reason // "") | startswith("аудит")) | not))' \
           "$OVERRIDES" >"$TMP_OVR" 2>/dev/null; then
        mv -f "$TMP_OVR" "$OVERRIDES"
      else
        rm -f "$TMP_OVR"
        echo "предупреждение: не удалось разобрать $OVERRIDES — оставил как есть" >&2
      fi
      echo "  ручные оверрайды маршрутов сохранены (копия: $OVERRIDES.bak)"
    else
      echo "  jq не найден — оверрайды оставлены целиком: $OVERRIDES (копия: $OVERRIDES.bak)"
      echo "  записи аудита можно убрать вручную: reason начинается с «аудит»"
    fi
  fi
fi
# Кэш аудита (в т.ч. route-audit-state.json с кулдаунами) — состояние машины,
# чистим в любом режиме: после переустановки кулдауны от другой сети вредны.
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
