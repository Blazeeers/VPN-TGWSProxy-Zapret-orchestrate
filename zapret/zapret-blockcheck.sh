#!/usr/bin/env bash
# Глубокий подбор стратегии zapret через штатный blockcheck (перебор всех
# основных вариантов nfqws). Найденная рабочая стратегия применяется и
# сохраняется в автотюн как 'custom' для текущей сети.
#
# Запуск: sudo bash ~/.local/share/omavpn/zapret-blockcheck.sh [quick|standard|force]
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти через sudo: sudo bash $0 [quick|standard|force]"
  exit 1
fi

LEVEL="${1:-standard}"
[ -x /usr/local/bin/zapret-autotune ] || { echo "Сначала установи автотюн (zapret-autotune-install.sh)"; exit 1; }

# переиспользуем функции автотюна
export ZAPRET_AUTOTUNE_SOURCE=1
. /usr/local/bin/zapret-autotune

mkdir -p "$CACHE"
LOG=/var/log/zapret-blockcheck.log
BCDOMAIN="www.youtube.com"

KEY="$(netkey)"
echo "==> Сеть: $KEY, уровень перебора: $LEVEL, домен: $BCDOMAIN"
echo "==> Останавливаю zapret и VPN (для честного теста, бот временно молчит)"
zapret_off
if omavpn_running; then WOW_WAS_ON=1; omavpn_off; else WOW_WAS_ON=0; fi

echo "==> Запускаю blockcheck (может занять 10-30 минут, не прерывай)"
BATCH=1 DOMAINS="$BCDOMAIN" IPVS=4 SCANLEVEL="$LEVEL" \
  ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=1 ENABLE_HTTPS_TLS13=0 REPEATS=1 SKIP_TPWS=1 \
  /opt/zapret/blockcheck.sh > "$LOG" 2>&1
echo "==> blockcheck завершён, лог: $LOG"

STRAT="$(grep -oE 'working strategy found for ipv4 [^:]+: nfqws .*' "$LOG" | head -1 | sed -E 's/.*: nfqws //; s/ *!!!!! *$//')"

if [ -z "$STRAT" ]; then
  echo "==> blockcheck НЕ нашёл рабочую стратегию для $BCDOMAIN."
  echo "    Смотри $LOG. Оставляю автотюн как был."
else
  echo "==> Найдена стратегия: $STRAT"
  OPT="--filter-tcp=443 --hostlist=$GOOGLE $STRAT --new
--filter-tcp=443 --hostlist=$ULIST --dpi-desync=multisplit --dpi-desync-split-pos=1 --new
--filter-tcp=80 --dpi-desync=fake,multisplit --dpi-desync-split-pos=method+2 --dpi-desync-fooling=md5sig --hostlist=$GOOGLE --hostlist=$ULIST --new
--filter-udp=443 --hostlist=$GOOGLE --hostlist=$ULIST --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic=$F/quic_initial_www_google_com.bin"

  ensure_direct_all
  if set_opt "$OPT"; then activate; else ensure_zapret_on; fi
  if test_targets; then
    printf '%s\n' "$OPT" > "$CACHE/$KEY.opt"
    printf 'custom\n' > "$CACHE/$KEY.strategy"
    echo "==> УСПЕХ: стратегия применена и сохранена в автотюн (custom) для сети $KEY."
  else
    echo "==> Стратегия применилась, но цели не открылись. Смотри лог."
  fi
fi

echo "==> Возвращаю VPN"
if [ "${WOW_WAS_ON:-0}" = 1 ]; then
  if [ "$(cat "$CACHE/$KEY.strategy" 2>/dev/null)" != custom ]; then
    ensure_direct_min
  fi
  if omavpn_running; then omavpn_restart; else omavpn_start; fi
fi

echo "==> Готово."
