#!/usr/bin/env bash
# Installs Redis as the game server's live-state store (LIVE_STATE_PLAN.md):
# the fast, reconstructable half of storage — table snapshots, presence, turn
# deadlines and the matchmaking index. PostgreSQL stays the authoritative
# record of every chip; nothing here is allowed to lose money.
#
#   sudo bash install-redis.sh            # install, configure, enable, wire REDIS_URL, add the exporter
#   sudo bash install-redis.sh --no-exporter
#   sudo bash install-redis.sh uninstall  # unset REDIS_URL (server falls back to its in-process store) and stop Redis
#
# After it runs, restart the game server so it picks up REDIS_URL:
#   sudo systemctl restart gameplay
#
# Configuration chosen here and why:
#   bind 127.0.0.1               only this host talks to it; no password needed on a private loopback
#   maxmemory 512mb              the store is small: ~2 KB per table plus presence
#   maxmemory-policy noeviction  never silently drop a live table; if it ever fills, writes fail loudly
#                                and the game server logs it and keeps playing from memory
#   save 60 1000                 an RDB snapshot is enough — the data is reconstructable
#   appendonly no                the durability that matters is in PostgreSQL
set -euo pipefail

REPO_DIR="${REPO_DIR:-/var/www/gameplay/king-teenpatti}"
GO_DIR="$REPO_DIR/go-server"
ENV_FILE="${ENV_FILE:-$GO_DIR/.env}"
PROM_CFG="${PROM_CFG:-/etc/prometheus/prometheus.yml}"
REDIS_EXPORTER_VERSION="${REDIS_EXPORTER_VERSION:-1.69.0}"
REDIS_URL_VALUE="${REDIS_URL_VALUE:-redis://127.0.0.1:6379/0}"
WANT_EXPORTER=1
MODE=install

for arg in "$@"; do
  case "$arg" in
    --no-exporter) WANT_EXPORTER=0 ;;
    uninstall) MODE=uninstall ;;
    *) echo "unknown argument: $arg"; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0 $*"; exit 1; }

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# set_env KEY VALUE — idempotent upsert into the game server's .env
set_env() {
  local key=$1 value=$2
  [ -f "$ENV_FILE" ] || die "$ENV_FILE not found — run install-go-server.sh first"
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?$key=" "$ENV_FILE"; then
    sed -i -E "s|^[[:space:]]*(export[[:space:]]+)?$key=.*|$key=$value|" "$ENV_FILE"
    note "$ENV_FILE: $key set to $value"
  else
    printf '\n# Live state store (LIVE_STATE_PLAN.md). Empty = in-process fallback.\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    note "$ENV_FILE: added $key=$value"
  fi
}

if [ "$MODE" = uninstall ]; then
  log "Reverting to the in-process live store"
  set_env REDIS_URL ""
  systemctl disable --now redis-server 2>/dev/null || true
  systemctl disable --now redis_exporter 2>/dev/null || true
  note "Redis stopped. Restart the game server:  sudo systemctl restart gameplay"
  note "(the tables it holds now are rebuilt from memory only — a restart loses them, as before Redis)"
  exit 0
fi

# ----------------------------------------------------------------- install
log "Installing redis-server"
if ! command -v redis-server >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq redis-server
else
  note "already installed: $(redis-server --version | cut -c1-40)"
fi

log "Configuring"
install -d -m 0755 /etc/redis/redis.conf.d 2>/dev/null || true
cat > /etc/redis/redis.conf.d/king-teenpatti.conf <<'EOF'
# King Teen Patti live-state store — see go-server/LIVE_STATE_PLAN.md.
# Loopback only; the game server is the sole client.
bind 127.0.0.1 -::1
protected-mode yes
port 6379
maxmemory 512mb
# Never evict: a dropped table would look like a vanished game. If this ever
# fills, writes fail, the server logs game_live_store_errors_total and keeps
# playing from its own memory.
maxmemory-policy noeviction
# The data is reconstructable, so a periodic RDB is enough.
save 60 1000
appendonly no
# Snapshot failures must not stop writes: PostgreSQL holds the money.
stop-writes-on-bgsave-error no
EOF
# Debian's unit reads /etc/redis/redis.conf; make sure it includes our drop-in.
if ! grep -q 'redis.conf.d/king-teenpatti.conf' /etc/redis/redis.conf; then
  printf '\n# King Teen Patti overrides\ninclude /etc/redis/redis.conf.d/king-teenpatti.conf\n' >> /etc/redis/redis.conf
  note "/etc/redis/redis.conf: include added"
fi
systemctl enable --now redis-server
systemctl restart redis-server
sleep 1
redis-cli ping | grep -q PONG || die "redis-server is not answering on 127.0.0.1:6379"
note "redis-server up: $(redis-cli info server | grep -m1 redis_version | tr -d '\r')"
note "maxmemory $(redis-cli config get maxmemory | tail -1) policy $(redis-cli config get maxmemory-policy | tail -1)"

log "Pointing the game server at it"
set_env REDIS_URL "$REDIS_URL_VALUE"

log "Ordering the service after Redis"
UNIT=/etc/systemd/system/gameplay.service
if [ -f "$UNIT" ] && ! grep -q 'redis-server.service' "$UNIT"; then
  sed -i -E 's|^After=(.*)$|After=\1 redis-server.service|' "$UNIT"
  sed -i -E '/^After=/a Wants=redis-server.service' "$UNIT"
  systemctl daemon-reload
  note "$UNIT: After/Wants redis-server.service"
else
  note "$UNIT already ordered after redis-server (or not installed yet)"
fi

# ---------------------------------------------------------------- exporter
if [ "$WANT_EXPORTER" = 1 ]; then
  log "Installing redis_exporter (Prometheus)"
  if ! id redis_exporter >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin redis_exporter
  fi
  if [ ! -x /usr/local/bin/redis_exporter ]; then
    tmp=$(mktemp -d)
    curl -sSL "https://github.com/oliver006/redis_exporter/releases/download/v${REDIS_EXPORTER_VERSION}/redis_exporter-v${REDIS_EXPORTER_VERSION}.linux-amd64.tar.gz" | tar xz -C "$tmp"
    install -m 0755 "$tmp"/redis_exporter-*/redis_exporter /usr/local/bin/redis_exporter
    rm -rf "$tmp"
  fi
  cat > /etc/systemd/system/redis_exporter.service <<'EOF'
[Unit]
Description=Prometheus Redis exporter (King Teen Patti)
After=network.target redis-server.service

[Service]
User=redis_exporter
ExecStart=/usr/local/bin/redis_exporter --redis.addr=redis://127.0.0.1:6379 --web.listen-address=127.0.0.1:9121
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now redis_exporter
  sleep 2
  curl -sf -m 5 http://127.0.0.1:9121/metrics | grep -m1 '^redis_up' || note "WARNING: redis_exporter not answering yet"

  if [ -f "$PROM_CFG" ] && ! grep -q 'job_name: "redis"' "$PROM_CFG"; then
    printf '\n  - job_name: "redis"\n    static_configs:\n      - targets: ["127.0.0.1:9121"]\n' >> "$PROM_CFG"
    note "$PROM_CFG: job redis → 127.0.0.1:9121"
    (command -v promtool >/dev/null && promtool check config "$PROM_CFG" >/dev/null) || true
    systemctl reload prometheus 2>/dev/null || systemctl restart prometheus 2>/dev/null || note "reload Prometheus by hand"
  else
    note "Prometheus already has a redis job (or $PROM_CFG is elsewhere)"
  fi
fi

log "Done"
note "Restart the game server to pick up REDIS_URL:   sudo systemctl restart gameplay"
note "Then check it took:   curl -s http://127.0.0.1:3000/health | python3 -m json.tool | grep -A4 '\"live\"'"
note "Live keys:            redis-cli --scan --pattern 'kt:*' | head"
note "Rollback:             sudo bash $0 uninstall && sudo systemctl restart gameplay"
