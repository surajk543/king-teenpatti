#!/usr/bin/env bash
# Switch the production `gameplay.service` from the Node server to the Go binary.
#
#   sudo bash /var/www/gameplay/king-teenpatti/go-server/ops/install-go-server.sh
#
# Idempotent — re-running it re-installs the unit and restarts the service.
#   1. refuses unless go-server/bin/gameplay exists (run ops/build.sh as deploy first);
#   2. backs up the current unit to /etc/systemd/system/gameplay.service.node.bak
#      (only once: an existing backup is never overwritten, and a unit that is
#      already the Go one is never saved as the "Node" backup);
#   3. installs ops/gameplay-go.service AS gameplay.service — same unit name, so
#      nginx, Prometheus, the journal and `sudo systemctl restart gameplay` are
#      unchanged; daemon-reload; enable; restart;
#   4. waits for http://127.0.0.1:$PORT/health to report process.node = "go…"
#      and checks a HEAD on /metrics with the METRICS_TOKEN from .env → 200.
#
# Undo: sudo bash rollback-to-node.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
UNIT_SRC="$SCRIPT_DIR/gameplay-go.service"

need_root

# ------------------------------------------------------------ 1. preflight
log "Preflight"
[ -x "$GO_BIN" ] || die "$GO_BIN is missing or not executable.
    Build it first, as the deploy user (no sudo):
      cd $GO_DIR && bash ops/build.sh"
[ -f "$UNIT_SRC" ] || die "$UNIT_SRC not found"
# The Node server's .env was untracked, so it survives the removal of server/
# from git. Carry it over once; the Go binary reads the same keys.
if [ ! -e "$ENV_FILE" ] && [ -r "$LEGACY_ENV_FILE" ]; then
  install -m 0640 -o deploy -g deploy "$LEGACY_ENV_FILE" "$ENV_FILE"
  note "copied $LEGACY_ENV_FILE -> $ENV_FILE (the old file is left in place)"
fi
[ -r "$ENV_FILE" ]  || die "$ENV_FILE not readable — the unit's EnvironmentFile must exist (copy the production .env to $GO_DIR/.env)"
note "binary   $GO_BIN"
note "version  $("$GO_BIN" -version)"
note "env file $ENV_FILE (PORT=$(env_value PORT 3000), METRICS_PATH=$(env_value METRICS_PATH /metrics), METRICS_TOKEN=$([ -n "$(env_value METRICS_TOKEN)" ] && echo set || echo empty))"
for key in DATABASE_URL JWT_SECRET; do
  [ -n "$(env_value "$key")" ] || note "WARNING: $key is not set in $ENV_FILE — the Go server uses the same keys as Node"
done
[ -d "$GO_DIR/public" ] || note "WARNING: $GO_DIR/public missing — the browser client at / will 404 (PUBLIC_DIR in the unit)"

# -------------------------------------------------------------- 2. backup
log "Backing up the Node unit"
current="$(systemctl show -p FragmentPath --value "$UNIT_NAME" 2>/dev/null || true)"
if [ -f "$UNIT_BACKUP" ]; then
  note "already backed up: $UNIT_BACKUP (left untouched)"
elif [ -n "$current" ] && [ -f "$current" ]; then
  if grep -q 'go-server/bin/gameplay' "$current"; then
    note "the active unit ($current) is already the Go unit — no Node unit to back up"
  else
    cp -p "$current" "$UNIT_BACKUP"
    note "saved $current → $UNIT_BACKUP"
  fi
else
  note "no existing $UNIT_NAME found — nothing to back up (fresh install)"
fi
if [ -f "$UNIT_BACKUP" ]; then
  log "Unit diff (Node → Go); check that no Environment= line you rely on is lost"
  diff -u "$UNIT_BACKUP" "$UNIT_SRC" | sed 's/^/    /' || true
fi

# ------------------------------------------------------------- 3. install
log "Installing $UNIT_SRC → $UNIT_PATH"
install -m 0644 "$UNIT_SRC" "$UNIT_PATH"
systemctl daemon-reload
systemctl enable --quiet "$UNIT_NAME" 2>/dev/null || true
note "restarting $UNIT_NAME (Node gets SIGTERM and up to 8 s to settle live pots; then the Go binary starts on the same port)"
systemctl restart "$UNIT_NAME"

# -------------------------------------------------------------- 4. verify
log "Verifying"
if ! wait_for_health go; then
  show_service
  die "the Go server did not become healthy within ${HEALTH_WAIT_SECONDS}s.
    Roll back with:  sudo bash $SCRIPT_DIR/rollback-to-node.sh"
fi
note "process.node = $HEALTH_NODE  (must start with \"go\")"
status="$(metrics_head || true)"
case "$status" in
  200) note "/metrics HEAD → 200 (Prometheus can scrape with the token from .env)" ;;
  401) note "WARNING: /metrics HEAD → 401 — METRICS_TOKEN in .env does not match what the server loaded" ;;
  403) note "WARNING: /metrics HEAD → 403 — 127.0.0.1 is not in METRICS_ALLOW_IPS" ;;
  404) note "NOTE: /metrics HEAD → 404 — METRICS_ENABLED=false or METRICS_PATH differs" ;;
  *)   note "WARNING: /metrics HEAD → ${status:-no response}" ;;
esac

show_service
log "Done — gameplay.service now runs the Go binary."
note "Prometheus keeps scraping 127.0.0.1:$(env_value PORT 3000)/metrics; give it one interval, then check http://127.0.0.1:9090/targets."
note "Rollback at any time:  sudo bash $SCRIPT_DIR/rollback-to-node.sh"
