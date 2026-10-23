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

# Тот же лок, что у автотюна ($LOCK). main() автотюна при ZAPRET_AUTOTUNE_SOURCE=1
# выходит раньше и лок не берёт, поэтому blockcheck мог идти параллельно с
# прогоном таймера: тот поднимал zapret и VPN посреди «честного» теста, а после
# завершения blockcheck оставлял систему в состоянии, выставленном не им.
# Лок снимается сам при выходе процесса (fd закрывается), отдельного unlock нет.
exec 9>"$LOCK" || { echo "Не удалось открыть лок $LOCK"; exit 1; }
if ! flock -n 9; then
  echo "==> Автотюн сейчас занят ($LOCK) — жду, пока закончит (до 15 минут)"
  flock -w 900 9 || { echo "Лок так и не освободился — прерываю, ничего не менял"; exit 1; }
fi

mkdir -p "$CACHE"
LOG=/var/log/zapret-blockcheck.log
BCDOMAIN="www.youtube.com"

KEY="$(netkey)"

# --- восстановление ---------------------------------------------------------
# Без трапа Ctrl-C, падение blockcheck или обрыв ssh оставляли машину БЕЗ
# zapret и БЕЗ VPN: скрипт гасит оба ради «честного» теста, а вернуть их мог
# только он же, дойдя до конца. Теперь состояние возвращается на INT/TERM/EXIT:
#   * NFQWS_OPT — прежний (перебор успевает записать проверяемый кандидат);
#   * zapret — включён, если был включён до запуска;
#   * VPN — поднят, если был поднят.
# Функция идемпотентна: RESTORE_DONE ставится сразу, повторный вызов ничего не
# делает (в нормальном финале она вызывается явно, а потом ещё раз трапом).
#
# По INT/TERM восстановления мало: вернув состояние, скрипт продолжал работу,
# blockcheck (и его частичный лог) доигрывались, и уже после восстановления
# могла примениться «найденная» в обрезанном логе стратегия — то есть ровно то,
# от чего трап и защищает. Поэтому прерывание завершает скрипт с кодом 130.
RESTORE_DONE=0
restore_state() {
  [ "$RESTORE_DONE" = 1 ] && return 0
  RESTORE_DONE=1
  trap - INT TERM EXIT

  if [ "${OPT_TOUCHED:-0}" = 1 ] && [ -n "${ORIG_OPT:-}" ]; then
    set_opt "$ORIG_OPT" >/dev/null 2>&1 || true
    # Конфиг вернули — если zapret был включён, его надо перечитать.
    if [ "${ZAPRET_WAS_ON:-0}" = 1 ]; then activate || true; fi
  fi
  if [ "${ZAPRET_WAS_ON:-0}" = 1 ]; then
    ensure_zapret_on || true
  fi
  if [ "${WOW_WAS_ON:-0}" = 1 ]; then
    echo "==> Возвращаю VPN"
    if [ "$(cat "$CACHE/$KEY.strategy" 2>/dev/null)" != custom ]; then
      ensure_direct_min
    fi
    if omavpn_running; then omavpn_restart; else omavpn_start; fi
  fi
}

# Трап по сигналу: восстановить состояние и гарантированно выйти (130 = SIGINT).
# restore_state снимает все трапы и ставит RESTORE_DONE, так что повторного
# восстановления не будет.
abort_restore() {
  restore_state
  exit 130
}

echo "==> Сеть: $KEY, уровень перебора: $LEVEL, домен: $BCDOMAIN"
echo "==> Останавливаю zapret и VPN (для честного теста, бот временно молчит)"
# Состояние фиксируем ДО остановки: по нему восстанавливаемся в трапе.
ZAPRET_WAS_ON=0
systemctl is-active --quiet zapret.service 2>/dev/null && ZAPRET_WAS_ON=1
WOW_WAS_ON=0
omavpn_running && WOW_WAS_ON=1
OPT_TOUCHED=0
ORIG_OPT="$(python3 - "$CFG" <<'PY'
import re, sys
try:
    t = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(0)
m = re.search(r'NFQWS_OPT="(.*?)"', t, re.S)
print(m.group(1).strip() if m else "")
PY
)"
trap abort_restore INT TERM
trap restore_state EXIT

zapret_off
[ "$WOW_WAS_ON" = 1 ] && omavpn_off

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
  OPT_TOUCHED=1   # после этой точки трап обязан вернуть прежний NFQWS_OPT
  apply_opt "$OPT"; APPLY_RC=$?
  if [ "$APPLY_RC" = 2 ]; then
    echo "==> Не удалось записать NFQWS_OPT в $CFG — стратегия не сохранена."
  elif test_targets; then
    printf '%s\n' "$OPT" > "$CACHE/$KEY.opt"
    printf 'custom\n' > "$CACHE/$KEY.strategy"
    OPT_TOUCHED=0   # рабочая стратегия осталась в конфиге — откатывать нечего
    echo "==> УСПЕХ: стратегия применена и сохранена в автотюн (custom) для сети $KEY."
  else
    echo "==> Стратегия применилась, но цели не открылись. Смотри лог."
  fi
fi

# Возврат состояния — restore_state (см. начало файла): он же сработает по
# INT/TERM, если прогон прервут. Вызов явный, чтобы сообщение «Готово» шло
# уже после возврата VPN.
restore_state

echo "==> Готово."
