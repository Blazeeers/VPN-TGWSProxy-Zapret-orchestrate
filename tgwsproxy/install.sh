#!/usr/bin/env bash
# Установка tg-ws-proxy (локальный MTProto-прокси для Telegram Desktop) без root.
# Скачивает бинарь из последнего релиза, ставит иконку, .desktop и автозапуск.
set -euo pipefail

REPO="Flowseal/tg-ws-proxy"
VERSION="${TGWSPROXY_VERSION:-1.10.4}"
ASSET="TgWsProxy_linux_amd64"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${ASSET}"
SHA256="${TGWSPROXY_SHA256:-818ce6c3c49b0e07f1ab689586adf3a23ec5106fd4f947848f7d8145f8ba2676}"
ICON_URL="https://raw.githubusercontent.com/${REPO}/v${VERSION}/icon.ico"
ICON_SHA256="${TGWSPROXY_ICON_SHA256:-4b3108858a414b35d0a6fde2e304fb7ae18e5b2831e69e9e492cfdb1b048009d}"

HOME_DIR="${HOME:?}"
BIN="$HOME_DIR/.local/bin/tg-ws-proxy"
ICON_DIR="$HOME_DIR/.local/share/icons/hicolor/64x64/apps"
APP_DIR="$HOME_DIR/.local/share/applications"
AUTOSTART="$HOME_DIR/.config/autostart"
CONF="$HOME_DIR/.config/TgWsProxy/config.json"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

verify_sha256() { # $1 — файл, $2 — ожидаемый sha256, $3 — имя
  if [ -z "$2" ]; then
    echo "Нет sha256 для $3. Задай TGWSPROXY_SHA256/TGWSPROXY_ICON_SHA256 и повтори."
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

for tool in curl sha256sum; do
  command -v "$tool" >/dev/null || { echo "Нужен '$tool' в PATH"; exit 1; }
done

mkdir -p "$HOME_DIR/.local/bin" "$ICON_DIR" "$APP_DIR" "$AUTOSTART"

if [ -x "$BIN" ] && [ -z "${FORCE:-}" ]; then
  say "tg-ws-proxy уже установлен: $("$BIN" --version 2>/dev/null || echo "$BIN")"
else
  say "Скачиваю tg-ws-proxy ($URL)"
  TMP="$(mktemp)"
  curl -fL --retry 3 -o "$TMP" "$URL"
  verify_sha256 "$TMP" "$SHA256" "TgWsProxy_linux_amd64"
  install -Dm755 "$TMP" "$BIN"
  rm -f "$TMP"
fi
mkdir -p "$HOME_DIR/.local/share/tgwsproxy"
printf '%s\n' "$VERSION" > "$HOME_DIR/.local/share/tgwsproxy/version"

say "Иконка"
if command -v magick >/dev/null || command -v convert >/dev/null; then
  mkdir -p "$ICON_DIR"
  TMPICO="$(mktemp --suffix=.ico)"
  if curl -fsSL -o "$TMPICO" "$ICON_URL"; then
    verify_sha256 "$TMPICO" "$ICON_SHA256" "icon.ico"
    (magick "$TMPICO[5]" -background none -alpha on "$ICON_DIR/tg-ws-proxy.png" 2>/dev/null \
      || convert "$TMPICO[5]" -background none -alpha on "$ICON_DIR/tg-ws-proxy.png") || warn "не удалось сконвертировать иконку"
  fi
  rm -f "$TMPICO"
else
  warn "нет imagemagick (magick/convert) — иконка пропущена"
fi

say "Ярлык и автозапуск"
write_desktop() {
  cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Name=tg-ws-proxy
Comment=Local MTProto proxy server for partial bypassing of Telegram loading
Exec=$BIN
Icon=tg-ws-proxy
Terminal=false
Categories=Network;Utility;
$( [ "$2" = autostart ] && echo 'X-GNOME-Autostart-enabled=true' )
EOF
}
write_desktop "$APP_DIR/tg-ws-proxy.desktop" app
write_desktop "$AUTOSTART/tg-ws-proxy.desktop" autostart

command -v update-desktop-database >/dev/null && update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true

say "Запуск"
if pgrep -x tg-ws-proxy >/dev/null 2>&1; then
  say "уже запущен"
else
  setsid -f "$BIN" >/dev/null 2>&1 || true
  sleep 4
fi

if command -v python3 >/dev/null && [ -f "$CONF" ]; then
  SECRET="$(python3 -c "import json;print(json.load(open('$CONF')).get('secret',''))" 2>/dev/null || true)"
  PORT="$(python3 -c "import json;print(json.load(open('$CONF')).get('port',1443))" 2>/dev/null || true)"
  if [ -n "$SECRET" ]; then
    say "Ссылка для Telegram (открой в Telegram):"
    echo "    tg://proxy?server=127.0.0.1&port=${PORT:-1443}&secret=dd${SECRET}"
  fi
fi

cat <<EOF

Готово. tg-ws-proxy слушает 127.0.0.1:1443.
Подключи Telegram Desktop: иконка в трее -> «Открыть в Telegram», либо вручную
(MTProto, 127.0.0.1:1443, secret из $CONF).
EOF
