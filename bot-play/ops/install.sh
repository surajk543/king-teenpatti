#!/usr/bin/env bash
# Installs the bot fleet as a systemd unit, running bin/bot-play.
#
#   bash ops/build.sh                    # as the checkout's owner: build bin/bot-play
#   sudo bash ops/install.sh             # install, enable, start
#   sudo BOT_USER=gameplay bash ops/install.sh   # run the fleet as that user
#   sudo bash ops/install.sh uninstall   # stop and remove
#
# The unit runs as BOT_USER. Unset, it keeps the user the installed fleet
# already runs as (drop-ins included), else the unit's own (deploy). A user
# this host does not have, or who cannot run the binary, is refused here:
# installed, the unit would restart-loop on systemd's 217/USER (production,
# 30 Sep 2026, where the checkout's owner is `write` and the game server runs
# as `gameplay`).
#
# The fleet talks to the game server over loopback, so this belongs on the
# game host itself — see README.md.
set -euo pipefail

REPO_DIR="${REPO_DIR:-/var/www/gameplay/king-teenpatti}"
DIR="$REPO_DIR/bot-play"
UNIT=/etc/systemd/system/bot-play.service

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0 $*"; exit 1; }
log() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

if [ "${1:-}" = uninstall ]; then
  log "Removing the bot fleet"
  systemctl disable --now bot-play 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload
  note "gone. Seats were released on SIGTERM."
  exit 0
fi

[ -x "$DIR/bin/bot-play" ] || { echo "not built: run 'bash ops/build.sh' as the checkout's owner first"; exit 1; }
log "$("$DIR/bin/bot-play" -version)"

# Who the fleet runs as.
if [ -z "${BOT_USER:-}" ]; then
  BOT_USER="$(systemctl show bot-play -p User --value 2>/dev/null || true)"
  [ -n "$BOT_USER" ] || BOT_USER="$(sed -n 's/^User=//p' "$DIR/ops/bot-play.service" | head -1)"
fi
if ! id "$BOT_USER" >/dev/null 2>&1; then
  echo "no user '$BOT_USER' on this host: the unit could not start (systemd 217/USER)."
  echo "run it as the game server's user instead:  sudo BOT_USER=gameplay bash $0"
  exit 1
fi
BOT_GROUP="$(id -gn "$BOT_USER")"
if ! runuser -u "$BOT_USER" -- test -x "$DIR/bin/bot-play" -a -r "$DIR/configs/bot.yaml"; then
  echo "user '$BOT_USER' cannot run $DIR/bin/bot-play or read configs/bot.yaml: fix the permissions or pick another BOT_USER"
  exit 1
fi
note "runs as $BOT_USER:$BOT_GROUP"

log "Installing $UNIT"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed -e "s/^User=.*/User=$BOT_USER/" -e "s/^Group=.*/Group=$BOT_GROUP/" "$DIR/ops/bot-play.service" >"$tmp"
install -m 0644 "$tmp" "$UNIT"
systemctl daemon-reload
systemctl enable bot-play
systemctl restart bot-play

log "Started"
sleep 5
systemctl status bot-play --no-pager | head -12 || true
note ""
note "Watch it:   journalctl -u bot-play -f"
note "Fleet size: edit BOT_COUNT in $UNIT (or configs/bot.yaml), then systemctl restart bot-play"
note "Debug:      curl -s 127.0.0.1:9102/debug/bots | head     (metrics: curl -s 127.0.0.1:9101/metrics)"
note "Stop it:    sudo systemctl stop bot-play    (every bot finishes its hand and leaves)"
