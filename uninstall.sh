#!/usr/bin/env bash
# Удаление omavpn.
set -euo pipefail

HOME_DIR="${HOME:?}"
PURGE="${1:-}"

# --- 1. Сначала гасим всё, что может ПОДНЯТЬ VPN --------------------------
# Порядок важен. Раньше `omavpn off` и pkill шли первыми, а таймеры гасились
# потом: идущий в этот момент прогон guard спокойно поднимал VPN заново — уже
# после pkill, пока CLI ещё на месте. Дальше CLI удалялся, процессы оставались,
# и гасить их было некому. Поэтому: сперва таймеры и стоп юнитов (с ожиданием
# завершения), только потом `omavpn off` и pkill.
systemctl --user disable --now \
  omavpn-guard.timer omavpn-autostart.service \
  omavpn-route-audit.timer omavpn-route-recheck.timer \
  omavpn-updates.timer >/dev/null 2>&1 || true
# Именно stop: уже запущенный прогон guard (Type=oneshot) может идти до
# 20 минут перебора и всё это время вправе поднять VPN.
systemctl --user stop omavpn-guard.service >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  systemctl --user is-active --quiet omavpn-guard.service 2>/dev/null || break
  sleep 1
done

"$HOME_DIR/.local/bin/omavpn" off >/dev/null 2>&1 || true
pkill -f "$HOME_DIR/.local/share/omavpn/bin/sing-box" 2>/dev/null || true
pkill -f "$HOME_DIR/.local/share/omavpn/bin/xray" 2>/dev/null || true

# --- 2. Файлы юнитов -------------------------------------------------------
# Надзиратель за обходами: таймеры уже погашены выше, иначе после удаления CLI
# они продолжали бы поднимать VPN и слать уведомления каждые 10 минут.
rm -f "$HOME_DIR/.config/systemd/user/omavpn-guard.service" \
      "$HOME_DIR/.config/systemd/user/omavpn-guard.timer" \
      "$HOME_DIR/.config/systemd/user/omavpn-autostart.service"
systemctl --user daemon-reload >/dev/null 2>&1 || true
rm -f "$HOME_DIR/.local/bin/omavpn-guard"

# Проверка обновлений и CLI виджета: без этого «полное удаление» оставляло
# включённый omavpn-updates.timer (он дёргает уже удалённый bypass-status и
# копит ошибки) и живой ~/.local/bin/bypass-status.
rm -f "$HOME_DIR/.config/systemd/user/omavpn-updates.service" \
      "$HOME_DIR/.config/systemd/user/omavpn-updates.timer"
systemctl --user daemon-reload >/dev/null 2>&1 || true
rm -f "$HOME_DIR/.local/bin/bypass-status"
rm -f "$HOME_DIR/.local/bin/omavpn-updater"

# Аудит маршрутов: те же правила — сначала таймеры (погашены выше), потом файлы.
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
  # Копии юнитов, которые install.sh оставляет рядом с перезаписанными файлами.
  rm -f "$HOME_DIR"/.config/systemd/user/omavpn*.bak 2>/dev/null || true
  echo "Удалено полностью (бинари, конфиги, состояние)."
else
  echo "Удалены CLI, надзиратель и виджет. Данные сохранены в:"
  echo "  ~/.local/share/omavpn  ~/.config/omavpn  ~/.local/state/omavpn"
  echo "  ~/.local/state/omavpn-guard  ~/.cache/omavpn"
  # Копии юнитов install.sh пишет рядом (omavpn-*.service.bak) при изменении
  # шаблона — это не мусор, а откат, поэтому оставлены. Убрать: --purge.
  echo "  ~/.config/systemd/user/omavpn*.bak — копии юнитов от прошлых установок (удаляются с --purge)"
  echo "Для полного удаления: $0 --purge"
fi
