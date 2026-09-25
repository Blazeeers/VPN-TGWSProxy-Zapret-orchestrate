#!/usr/bin/env bash
# Управление стратегией обхода zapret (аналог ручного перебора general*.bat на Windows).
#
#   sudo bash ~/.local/share/omavpn/zapret-strategy.sh list          # список пресетов
#   sudo bash ~/.local/share/omavpn/zapret-strategy.sh scan          # перебрать и выбрать рабочий
#   sudo bash ~/.local/share/omavpn/zapret-strategy.sh set flowseal  # применить пресет вручную
#
# Стратегия = переменная NFQWS_OPT в /opt/zapret/config. Ничего не выбирается
# автоматически: применяется ровно то, что записано там. scan перебирает
# пресеты и оставляет первый, который открывает и YouTube, и Discord.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти через sudo: sudo bash $0 $*"
  exit 1
fi

CFG=/opt/zapret/config
F=/opt/zapret/files/fake
G=/opt/zapret/ipset/list-google.txt
U=/opt/zapret/ipset/zapret-hosts-user.txt

write_lists() {
  cat > "$G" <<'EOF'
youtube.com
youtu.be
ytimg.com
googlevideo.com
youtube-nocookie.com
youtubekids.com
youtubegaming.com
youtubeeducation.com
youtubemusic.com
ytstatic.com
youtube.googleapis.com
youtubei.googleapis.com
EOF
  cat > "$U" <<'EOF'
discord.com
discord.gg
discordapp.com
discordapp.net
discord.co
discord.dev
discord.new
discord.media
discordmerch.com
discordstatus.com
discord-activities.com
discordactivities.com
discordpartygames.com
discordapp.io
discordcdn.com
EOF
  chmod 644 "$G" "$U"
}

preset_text() {
  case "$1" in
    flowseal) cat <<EOF
--filter-udp=443 --hostlist=$G --hostlist=$U --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic=$F/quic_initial_www_google_com.bin --new
--filter-tcp=443 --hostlist=$G --ip-id=zero --dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=$F/tls_clienthello_www_google_com.bin --new
--filter-tcp=80,443 --hostlist=$U --dpi-desync=multisplit --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=$F/tls_clienthello_www_google_com.bin
EOF
      ;;
    flowseal-alt) cat <<EOF
--filter-udp=443 --hostlist=$G --hostlist=$U --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic=$F/quic_initial_www_google_com.bin --new
--filter-tcp=443 --hostlist=$G --ip-id=zero --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls=$F/tls_clienthello_www_google_com.bin --new
--filter-tcp=80,443 --hostlist=$U --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls=$F/tls_clienthello_www_google_com.bin
EOF
      ;;
    disorder) cat <<EOF
--filter-udp=443 --hostlist=$G --hostlist=$U --dpi-desync=fake --dpi-desync-repeats=6 --new
--filter-tcp=443 --hostlist=$G --hostlist=$U --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq,md5sig
EOF
      ;;
    simple-multisplit) cat <<EOF
--filter-udp=443 --hostlist=$G --hostlist=$U --dpi-desync=fake --dpi-desync-repeats=6 --new
--filter-tcp=443 --hostlist=$G --hostlist=$U --ip-id=zero --dpi-desync=multisplit --dpi-desync-split-pos=1 --dpi-desync-fooling=md5sig
EOF
      ;;
    default) cat <<EOF
--filter-tcp=80 --dpi-desync=fake,multisplit --dpi-desync-split-pos=method+2 --dpi-desync-fooling=md5sig --hostlist=$G --hostlist=$U --new
--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq,md5sig --hostlist=$G --hostlist=$U --new
--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --hostlist=$G --hostlist=$U
EOF
      ;;
    *) echo "Нет пресета '$1'" >&2; return 1 ;;
  esac
}

apply_preset() {
  local name="$1" opt
  opt="$(preset_text "$name")"
  cp -a "$CFG" "$CFG.bak.strategy.$(date +%Y%m%d-%H%M%S)"
  printf '%s\n' "$opt" > /tmp/zapret-nfqws-opt.txt
  python3 - "$CFG" /tmp/zapret-nfqws-opt.txt <<'PY'
import re, sys
cfg, optf = sys.argv[1], sys.argv[2]
opt = open(optf).read().strip()
text = open(cfg).read()
if re.search(r'NFQWS_OPT=".*?"', text, re.S):
    text = re.sub(r'NFQWS_OPT=".*?"', 'NFQWS_OPT="' + opt + '"', text, flags=re.S)
else:
    text = text.rstrip() + '\nNFQWS_OPT="' + opt + '"\n'
open(cfg, 'w').write(text)
PY
  systemctl restart zapret.service
  sleep 3
}

ok_url() {
  local code
  for _ in 1 2 3; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || true)
    case "$code" in 2??|3??) return 0 ;; esac
  done
  return 1
}

ORDER=(flowseal flowseal-alt disorder simple-multisplit default)

case "${1:-}" in
  list)
    for p in "${ORDER[@]}"; do echo "$p"; done
    ;;
  set)
    name="${2:?Укажи пресет: $(IFS=' '; echo "${ORDER[*]}")}"
    write_lists
    apply_preset "$name"
    echo "Применён пресет: $name ($(systemctl is-active zapret.service))"
    ;;
  scan)
    write_lists
    best=""
    for name in "${ORDER[@]}"; do
      apply_preset "$name"
      yt="—"; dc="—"; gv="—"
      ok_url https://www.youtube.com/ && yt="OK" || yt="fail"
      ok_url https://discord.com/ && dc="OK" || dc="fail"
      ok_url https://redirector.googlevideo.com/ && gv="OK" || gv="fail"
      printf '%-18s youtube=%-4s discord=%-4s googlevideo=%s\n' "$name" "$yt" "$dc" "$gv"
      if [ "$yt" = "OK" ] && [ "$dc" = "OK" ] && [ "$gv" = "OK" ]; then best="$name"; break; fi
      if [ "$yt" = "OK" ] && [ "$dc" = "OK" ] && [ -z "$best" ]; then best="$name"; fi
    done
    if [ -n "$best" ]; then
      apply_preset "$best"
      echo "==> Выбрана стратегия: $best"
    else
      apply_preset default
      echo "==> Полностью рабочей нет; оставлена default (см. вывод выше)"
    fi
    ;;
  *)
    echo "Использование: sudo bash $0 {list|scan|set <пресет>}"
    ;;
esac
