#!/usr/bin/env bash
# Put the Node server back as `gameplay.service`.
#
#   sudo bash /var/www/gameplay/king-teenpatti/go-server/ops/rollback-to-node.sh
#
# Restores /etc/systemd/system/gameplay.service from the .node.bak that
# install-go-server.sh made, daemon-reloads, restarts, and waits for /health to
# report a Node runtime (process.node = "v22…"; an older build without the
# `process` key also counts). The backup file is kept so install-go-server.sh
# can be run again later. Idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

need_root

log "Preflight"
[ -f "$UNIT_BACKUP" ] || die "$UNIT_BACKUP not found — nothing to roll back to.
    (install-go-server.sh writes it; if the Node unit was never replaced there is nothing to do.
     A reference Node unit is in $REPO_DIR/server/ops/monitoring/nginx/systemd/king-teenpatti.service.example.)"
grep -q 'go-server/bin/gameplay' "$UNIT_BACKUP" && die "$UNIT_BACKUP is a Go unit, not the Node one — refusing to install it as a rollback"
note "backup  $UNIT_BACKUP"
note "ExecStart in backup: $(sed -n 's/^ExecStart=//p' "$UNIT_BACKUP" | head -n1)"
node_bin="$(sed -n 's/^ExecStart=//p' "$UNIT_BACKUP" | head -n1 | awk '{print $1}')"
if [ -n "$node_bin" ] && [ "${node_bin#/}" != "$node_bin" ] && [ ! -x "$node_bin" ]; then
  note "WARNING: $node_bin is not executable on this host"
fi
[ -d "$NODE_DIR/node_modules" ] || note "WARNING: $NODE_DIR/node_modules missing — run 'npm ci' in $NODE_DIR before/after the restart"

log "Restoring the Node unit → $UNIT_PATH"
install -m 0644 "$UNIT_BACKUP" "$UNIT_PATH"
systemctl daemon-reload
systemctl enable --quiet "$UNIT_NAME" 2>/dev/null || true
note "restarting $UNIT_NAME (the Go binary gets SIGTERM and settles live pots within 8 s)"
systemctl restart "$UNIT_NAME"

log "Verifying"
if ! wait_for_health v; then
  show_service
  die "the Node server did not become healthy within ${HEALTH_WAIT_SECONDS}s — check the journal above (npm ci? .env?)."
fi
note "process.node = ${HEALTH_NODE:-<absent: old Node build>}  (must start with \"v\" = Node)"
status="$(metrics_head || true)"
note "/metrics HEAD → ${status:-no response}"

show_service
log "Done — gameplay.service runs the Node server again. $UNIT_BACKUP was kept."
