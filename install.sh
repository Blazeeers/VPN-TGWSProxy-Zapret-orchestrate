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

XRAY_VER="${XRAY_VER:-latest}"
SB_VER="${SB_VER:-1.14.1}"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
if [ "$XRAY_VER" != "latest" ]; then
  XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64.zip"
fi
SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-amd64.tar.gz"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

for tool in curl python3 tar; do
  command -v "$tool" >/dev/null || { echo "Нужен '$tool' в PATH"; exit 1; }
done

mkdir -p "$BIN_DIR" "$LOCAL_BIN" "$HOME_DIR/.config/omavpn" "$HOME_DIR/.local/state/omavpn" "$HOME_DIR/.cache/omavpn"

# --- Xray -------------------------------------------------------------------
if [ -x "$BIN_DIR/xray" ] && [ -z "${FORCE:-}" ]; then
  say "Xray уже установлен ($("$BIN_DIR/xray" version | head -1))"
else
  say "Скачиваю Xray…"
  TMP="$(mktemp -d)"
  curl -fL --retry 3 -o "$TMP/xray.zip" "$XRAY_URL"
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
  tar -xzf "$TMP/sb.tar.gz" -C "$TMP"
  found="$(find "$TMP" -type f -name sing-box | head -1)"
  [ -n "$found" ] || { echo "sing-box не найден в архиве"; exit 1; }
  install -m 0755 "$found" "$BIN_DIR/sing-box"
  rm -rf "$TMP"
fi

# --- capabilities для TUN ----------------------------------------------------
say "Выдаю CAP_NET_ADMIN бинарю sing-box (нужен sudo)…"
sudo setcap cap_net_admin,cap_net_raw+ep "$BIN_DIR/sing-box"
getcap "$BIN_DIR/sing-box" || true

# --- CLI --------------------------------------------------------------------
say "Ставлю CLI в $LOCAL_BIN/omavpn"
install -m 0755 "$HERE/bin/omavpn" "$LOCAL_BIN/omavpn"

# --- Плагин панели -----------------------------------------------------------
if [ -d "$HERE/shell-plugin/omavpn" ]; then
  say "Устанавливаю плагин панели ($PLUGIN_ID)…"
  mkdir -p "$PLUGIN_DIR"
  cp -f "$HERE/manifest.json" "$PLUGIN_DIR/"
  cp -f "$HERE/shell-plugin/omavpn/Panel.qml" "$PLUGIN_DIR/"
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
  warn "Каталог shell-plugin/omavpn не найден — виджет не установлен"
fi

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

cat <<EOF

Готово.

  Подключить:      omavpn on
  Отключить:       omavpn off
  Статус:          omavpn status
  Список:          omavpn profiles
  Проверить IP:    omavpn check

Виджет $PLUGIN_ID должен появиться в правой части панели Omarchy.
Если его нет: omarchy plugin enable $PLUGIN_ID && omarchy bar move $PLUGIN_ID --section right
EOF
