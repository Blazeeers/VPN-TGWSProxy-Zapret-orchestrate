#!/usr/bin/env bash
# zapret-routefix — направляет пакеты, инжектируемые zapret (nfqws), в main-таблицу,
# чтобы они уходили через физический интерфейс, а не в туннель wowvpn.
#
# Проблема: wowvpn ставит policy-routing (`ip rule 9001: from all lookup 2022`,
# default via wowvpn0). Из-за этого фейковые/десинхронизирующие пакеты nfqws
# (метки 0x40000000 и 0x20000000) тоже уходят в туннель — DPI их не видит, обход
# не срабатывает, и YouTube/Discord не открываются «в связке VPN + zapret».
# Правила с приоритетом 8990 (до правил wowvpn 9000+) возвращают такие пакеты
# на физический канал. Без VPN main-таблица и так указывает на WAN, так что
# правила безопасны в обоих режимах.
#
# Запуск: root (systemd-сервис zapret-routefix).
set -euo pipefail

RULES=(
  "0x40000000/0x40000000"
  "0x20000000/0x20000000"
)
PRIO=8990

apply() {
  for m in "${RULES[@]}"; do
    if ! ip rule show | grep -q "fwmark ${m} lookup main"; then
      ip rule add fwmark "$m" lookup main priority "$PRIO"
      echo "routefix: + fwmark $m -> main (prio $PRIO)"
    fi
  done
}

clear() {
  for m in "${RULES[@]}"; do
    ip rule del fwmark "$m" lookup main priority "$PRIO" 2>/dev/null || true
  done
  echo "routefix: правила удалены"
}

case "${1:-apply}" in
  apply) apply ;;
  clear) clear ;;
  status) ip rule show | grep -E "fwmark 0x(40000000|20000000)/" || echo "routefix: правил нет" ;;
  *) echo "Использование: $0 {apply|clear|status}"; exit 2 ;;
esac
