#!/usr/bin/env bash
# Installs the resident bot fleet as a systemd unit.
#
#   sudo bash ops/install.sh              # install, enable, start
#   sudo bash ops/install.sh uninstall    # stop and remove
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

[ -d "$DIR" ] || { echo "not found: $DIR — pull the repo first"; exit 1; }
command -v node >/dev/null || { echo "node is not installed"; exit 1; }

log "Node $(node --version)"

log "Installing dependencies"
sudo -u deploy bash -lc "cd '$DIR' && npm install --omit=dev"

log "Installing $UNIT"
install -m 0644 "$DIR/ops/bot-play.service" "$UNIT"
systemctl daemon-reload
systemctl enable bot-play
systemctl restart bot-play

log "Started"
sleep 5
systemctl status bot-play --no-pager | head -12 || true
note ""
note "Watch it:      journalctl -u bot-play -f"
note "Fleet size:    edit PER_CATEGORY in $UNIT, then systemctl restart bot-play"
note "Stop it:       sudo systemctl stop bot-play    (seats released cleanly)"
note "Chips minted:  journalctl -u bot-play | grep rotated"
