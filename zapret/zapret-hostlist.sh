#!/usr/bin/env bash
# Переводит zapret в режим hostlist: десинкаются только домены из
# zapret-hosts-user.txt (Discord/YouTube), остальной трафик не трогается.
# Запуск: sudo bash ~/.local/share/omavpn/zapret-hostlist.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти через sudo: sudo bash $0"
  exit 1
fi

CFG=/opt/zapret/config
LIST=/opt/zapret/ipset/zapret-hosts-user.txt

[ -f "$CFG" ] || { echo "Нет $CFG — zapret не установлен?"; exit 1; }

cp -a "$CFG" "$CFG.bak.hostlist.$(date +%Y%m%d-%H%M%S)"
sed -i -E 's/^#?\s*MODE_FILTER=.*/MODE_FILTER=hostlist/' "$CFG"
grep -q '^MODE_FILTER=' "$CFG" || echo 'MODE_FILTER=hostlist' >> "$CFG"

cat > "$LIST" <<'EOF'
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
chmod 644 "$LIST"

echo "==> $(grep -E '^MODE_FILTER=' "$CFG")"
echo "==> hostlist: $(grep -c . "$LIST") доменов"
systemctl restart zapret.service
sleep 3
echo "==> status: $(systemctl is-active zapret.service)"
pgrep -a nfqws | cut -c1-400
echo
