#!/usr/bin/env bash
# Prometheus + Grafana on the game host, Grafana at https://<domain>/dashboard/
# (owner, 27 Sep 2026: "check are we not exposing https://prod.sungamestudio.com/dashboard/
# for grafana dashboard, if not then install grafana and prometheus on prod").
#
#   sudo bash install-monitoring.sh          install, or re-apply the configuration (idempotent)
#
# What it sets up, every listener on 127.0.0.1 only (the internet reaches Grafana
# through nginx and nothing else):
#   prometheus                 127.0.0.1:9090  scrapes the game server's /metrics on
#                                              127.0.0.1:3000 with METRICS_TOKEN, and the
#                                              four exporters; the alert rules of
#                                              ops/monitoring/prometheus/alerts.yml
#   prometheus-node-exporter   127.0.0.1:9100  the host (dashboard "System" row)
#   prometheus-postgres-exporter 127.0.0.1:9187 as the Postgres role "prometheus"
#                                              (pg_monitor, peer auth over the socket)
#   prometheus-nginx-exporter  127.0.0.1:9113  nginx stub_status on 127.0.0.1:8080
#   prometheus-redis-exporter  127.0.0.1:9121  the live store at REDIS_URL
#   grafana (apt.grafana.com)  127.0.0.1:3001  served from /dashboard/, sign-up and
#                                              anonymous access off; the Prometheus
#                                              datasource and every dashboard of
#                                              ops/monitoring/grafana/dashboards
#                                              provisioned, the Loki logs one included
#   loki                       127.0.0.1:3100  the game server's log lines, on a volume of
#                                              its own (below); the Logs dashboard reads it
#   alloy                      127.0.0.1:12345 ships `journalctl -u gameplay` to Loki as
#                                              {service_name="gameplay"}, DEBUG lines dropped
#   nginx                      location /dashboard/ → Grafana on the site's HTTPS
#                              server, and /metrics answered 404 to the internet
#                              (Prometheus scrapes it on the loopback)
#
# Disk (owner, 27 Sep 2026: "make sure grafana dashboard … store info for previous
# days, so … does not take space more than 5 GB in disk", then "set the limit to
# 1 GB", then "install Grafana Loki also, loki logs disk storage limit 3 GB"):
#   Prometheus and Grafana together stay under 1 GB —
#   /var/lib/prometheus   the metrics every dashboard draws — the newest
#                         RETENTION_SIZE (640 MiB, WAL included) of them, the oldest
#                         days dropped first (RETENTION, 365 days, only if that ever
#                         comes first). At the ~380 samples a second this host takes
#                         (~45–65 MB a day) that is about 10–15 days; fewer under load,
#                         when the game server exposes more series
#   /var/lib/grafana      Grafana's own database, search index and bundled plugins,
#                         ~175 MB, which does not grow with time
#   /var/log/grafana      Grafana's log, to this file only (not the journal): rotated
#                         daily and at 16 MiB, each file deleted after 7 days — a few
#                         MB at the rate it logs
#   Prometheus asks for size retention at 80–85% of the space it may take, which is
#   why 640 MiB of the ~750 MB left once Grafana's share is counted: compaction
#   briefly writes a block beside the ones it replaces.
#   Loki stays under 3 GB —
#   /var/lib/loki         an ext4 volume of its own, the file /var/lib/loki.img
#                         (LOKI_DISK_MB, 2,861 MiB = 3.0 GB) loop-mounted there: chunks,
#                         index, WAL and compactor all live on it, so Loki cannot use
#                         a byte more whatever happens. Loki deletes by AGE only, so
#                         loki-disk-guard (hourly) keeps it off the ceiling: over 80%
#                         full it cuts the time logs are kept (/etc/loki/runtime.yml)
#                         to three quarters and the compactor drops the oldest days;
#                         under 50% it grows back a day at a time to LOKI_RETENTION_DAYS
#                         (180). The game server writes ~0.5 MB of log a day today,
#                         a few hundred KB compressed, so the guard should never act.
#   Nothing logs at DEBUG (owner: "do not enable debug logs"): Alloy drops the game
#   server's DEBUG lines whatever its LOG_LEVEL, Loki logs at warn (at info it writes
#   a journal line per query, crowding the game server's own journal), Alloy and
#   Grafana at info.
#
# The admin password is made when this script installs Grafana, printed once, and
# kept in /root/grafana-admin-password (0600). An existing Grafana's password is
# never touched; a re-run only warns while it is still admin/admin.
#
# Everything the Ubuntu packages leave in /etc/default is rewritten ARGS line by
# ARGS line; the nginx site file is backed up before its one-line edit and
# restored if `nginx -t` refuses the result.
set -euo pipefail

REPO_DIR="${REPO_DIR:-/var/www/gameplay/king-teenpatti}"
GO_DIR="$REPO_DIR/go-server"
MON_DIR="${MON_DIR:-$GO_DIR/ops/monitoring}"
ENV_FILE="${ENV_FILE:-$GO_DIR/.env}"
DOMAIN="${DOMAIN:-prod.sungamestudio.com}"
SITE="${SITE:-/etc/nginx/sites-available/$DOMAIN}"
GRAFANA_PORT="${GRAFANA_PORT:-3001}"
NODENAME="${NODENAME:-$(hostname -s)}"
PG_DB="${PG_DB:-gameplay}"
RETENTION="${RETENTION:-365d}"
RETENTION_SIZE="${RETENTION_SIZE:-640MB}"
GAME_UNIT="${GAME_UNIT:-gameplay.service}"
LOKI_DISK_MB="${LOKI_DISK_MB:-2861}"          # 2,861 MiB = 3.0 GB
LOKI_RETENTION_DAYS="${LOKI_RETENTION_DAYS:-180}"
# The Grafana release installed from dl.grafana.com when apt.grafana.com cannot
# be reached (the apt route always takes the newest).
GRAFANA_VERSION="${GRAFANA_VERSION:-12.2.0}"
# Loki and Alloy from GitHub when apt.grafana.com cannot be reached: the same
# files as the repository's pool (checked 27 Sep 2026), pinned by checksum.
LOKI_DEB_URL=https://github.com/grafana/loki/releases/download/v3.7.8/loki_3.7.8_amd64.deb
LOKI_DEB_SHA256=f6b0dcf22e08342dafc11c559e988c62279c570e2246ef887ee18329d2b53afb
ALLOY_DEB_URL=https://github.com/grafana/alloy/releases/download/v1.20.0/alloy-1.20.0-1.amd64.deb
ALLOY_DEB_SHA256=c0994473ef41498ac37392baef22081d6b7f6c4d45632600e93d202a3c34d661

SNIPPET=/etc/nginx/snippets/king-teenpatti-dashboard.conf
STUB_CONF=/etc/nginx/conf.d/king-teenpatti-stub-status.conf
PROM_CFG=/etc/prometheus/prometheus.yml
PROM_RULES=/etc/prometheus/king-teenpatti-alerts.yml
PROM_TOKEN=/etc/prometheus/metrics_token
GRAFANA_DASHBOARDS=/var/lib/grafana/dashboards/king-teenpatti
GRAFANA_DROPIN=/etc/systemd/system/grafana-server.service.d/king-teenpatti.conf
ADMIN_PW_FILE=/root/grafana-admin-password
LOKI_DIR=/var/lib/loki
LOKI_IMG=/var/lib/loki.img
LOKI_MOUNT_UNIT=/etc/systemd/system/var-lib-loki.mount
LOKI_CFG=/etc/loki/king-teenpatti.yml
LOKI_RUNTIME=/etc/loki/runtime.yml
LOKI_DROPIN=/etc/systemd/system/loki.service.d/king-teenpatti.conf
LOKI_GUARD=/usr/local/sbin/loki-disk-guard
ALLOY_CFG=/etc/alloy/king-teenpatti.alloy
ALLOY_ENV=/etc/alloy/king-teenpatti.env
ALLOY_DROPIN=/etc/systemd/system/alloy.service.d/king-teenpatti.conf

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# env_value KEY [default] — the last KEY=value line of the game server's .env,
# quotes and a trailing comment stripped.
env_value() {
  local key="$1" default="${2:-}" value=""
  if [ -r "$ENV_FILE" ]; then
    value="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\+\)\?$key=//p" "$ENV_FILE" | tail -n1)"
    value="${value%%[[:space:]]#*}"
    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' -e "s/^'\(.*\)'$/\1/" -e 's/^"\(.*\)"$/\1/')"
  fi
  printf '%s' "${value:-$default}"
}

# set_default FILE KEY VALUE — KEY="VALUE" in an /etc/default file: the line
# replaced where the key is set, appended where it is not.
set_default() {
  local file="$1" key="$2" value="$3"
  touch "$file"
  if grep -q "^[[:space:]]*$key=" "$file"; then
    local escaped
    escaped="$(printf '%s' "$value" | sed -e 's/[\/&|]/\\&/g')"
    sed -i "s|^[[:space:]]*$key=.*|$key=\"$escaped\"|" "$file"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$file"
  fi
}

# fetch URL FILE — a download that rides out a passing 5xx or a dropped
# connection (apt.grafana.com answered 503 on the first production run).
fetch() {
  curl -fsSL --retry 6 --retry-delay 5 --retry-all-errors -m 300 -o "$2" "$1"
}

# apt_try CMD… — an apt command, tried three times ten seconds apart.
apt_try() {
  local i
  for i in 1 2 3; do
    "$@" && return 0
    note "attempt $i failed: $*"
    [ "$i" -lt 3 ] && sleep 10
  done
  return 1
}

# install_grafana_apt — Grafana from its apt repository (the newest release,
# upgraded with the rest of the system from then on).
install_grafana_apt() {
  local key
  key="$(mktemp)"
  fetch https://apt.grafana.com/gpg.key "$key" || { rm -f "$key"; return 1; }
  install -d -m 0755 /etc/apt/keyrings
  gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg < "$key" || { rm -f "$key"; return 1; }
  rm -f "$key"
  chmod 0644 /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt_try apt-get update -qq && apt_try apt-get install -y -qq grafana >/dev/null
}

# install_grafana_deb — Grafana $GRAFANA_VERSION from dl.grafana.com, checked
# against the checksum published beside it: the way in when the apt
# repository is down.
install_grafana_deb() {
  local dir deb url
  dir="$(mktemp -d)"
  deb="grafana_${GRAFANA_VERSION}_amd64.deb"
  url="https://dl.grafana.com/oss/release/$deb"
  fetch "$url" "$dir/$deb" && fetch "$url.sha256" "$dir/$deb.sha256" || { rm -rf "$dir"; return 1; }
  (cd "$dir" && printf '%s  %s\n' "$(awk '{print $1; exit}' "$deb.sha256")" "$deb" | sha256sum -c --quiet -) \
    || { rm -rf "$dir"; die "the checksum of $deb does not match; not installing it"; }
  apt_try apt-get install -y -qq "$dir/$deb" >/dev/null || { rm -rf "$dir"; return 1; }
  rm -rf "$dir"
}

# install_grafana_pkg NAME URL SHA256 — NAME from apt.grafana.com, or the pinned
# .deb at URL, checked against SHA256, when the repository cannot be reached.
install_grafana_pkg() {
  local name="$1" url="$2" sum="$3" dir deb
  if dpkg-query -W -f='${Status}' "$name" 2>/dev/null | grep -q 'install ok installed'; then
    note "$name already installed"
    return 0
  fi
  if [ -f /etc/apt/sources.list.d/grafana.list ] && apt_try apt-get install -y -qq "$name" >/dev/null; then
    note "$name from apt.grafana.com"
    return 0
  fi
  dir="$(mktemp -d)"
  deb="$dir/$(basename "$url")"
  fetch "$url" "$deb" || { rm -rf "$dir"; return 1; }
  printf '%s  %s\n' "$sum" "$deb" | sha256sum -c --quiet - \
    || { rm -rf "$dir"; die "the checksum of $(basename "$url") does not match; not installing it"; }
  apt_try apt-get install -y -qq "$deb" >/dev/null || { rm -rf "$dir"; return 1; }
  rm -rf "$dir"
  note "$name from $url"
}

# wait_http URL [seconds] — true once URL answers 2xx.
wait_http() {
  local url="$1" wait="${2:-30}" i
  for ((i = 0; i < wait; i++)); do
    curl -sf -m 2 -o /dev/null "$url" && return 0
    sleep 1
  done
  return 1
}

# ------------------------------------------------------------------ checks
[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash $0"
[ -r "$MON_DIR/prometheus/alerts.yml" ] || die "no $MON_DIR/prometheus/alerts.yml (REPO_DIR=$REPO_DIR)"
[ -d "$MON_DIR/grafana/dashboards" ] || die "no $MON_DIR/grafana/dashboards"
[ -f "$SITE" ] || die "no nginx site $SITE (set SITE=…)"
METRICS_TOKEN="$(env_value METRICS_TOKEN)"
METRICS_PATH="$(env_value METRICS_PATH /metrics)"
GAME_PORT="$(env_value PORT 3000)"
REDIS_URL="$(env_value REDIS_URL redis://127.0.0.1:6379)"
[ -n "$METRICS_TOKEN" ] || die "METRICS_TOKEN is empty in $ENV_FILE: set one (openssl rand -hex 32) and restart the game server first"
ALLOW_IPS="$(env_value METRICS_ALLOW_IPS)"
if [ -n "$ALLOW_IPS" ] && ! printf ',%s,' "$ALLOW_IPS" | grep -q ',127\.0\.0\.1,'; then
  die "METRICS_ALLOW_IPS=$ALLOW_IPS does not include 127.0.0.1, where Prometheus scrapes from"
fi
[ "$GRAFANA_PORT" != "$GAME_PORT" ] || die "GRAFANA_PORT $GRAFANA_PORT is the game server's port"
[ "$LOKI_RETENTION_DAYS" -ge 1 ] 2>/dev/null || die "LOKI_RETENTION_DAYS must be a whole number of days, 1 or more"
[ "$LOKI_DISK_MB" -ge 256 ] 2>/dev/null || die "LOKI_DISK_MB must be 256 or more"

# ---------------------------------------------------------------- packages
log "Installing Prometheus and the exporters (Ubuntu packages)"
export DEBIAN_FRONTEND=noninteractive
# A Grafana repository left by an earlier run that could not reach it would
# fail this update too: it is written again below.
rm -f /etc/apt/sources.list.d/grafana.list
apt_try apt-get update -qq || die "apt-get update failed"
apt_try apt-get install -y -qq prometheus prometheus-node-exporter prometheus-postgres-exporter \
  prometheus-nginx-exporter prometheus-redis-exporter curl gpg openssl >/dev/null \
  || die "could not install Prometheus and the exporters"

log "Installing Grafana"
GRAFANA_NEW=1
if dpkg-query -W -f='${Status}' grafana 2>/dev/null | grep -q 'install ok installed'; then
  note "already installed"
  GRAFANA_NEW=0
elif install_grafana_apt; then
  note "from apt.grafana.com"
else
  note "apt.grafana.com unavailable; installing grafana $GRAFANA_VERSION from dl.grafana.com"
  rm -f /etc/apt/sources.list.d/grafana.list
  apt_try apt-get update -qq >/dev/null 2>&1 || true
  install_grafana_deb || die "could not install Grafana from apt.grafana.com or dl.grafana.com; try again later"
fi
note "grafana $(dpkg-query -W -f='${Version}' grafana), prometheus $(dpkg-query -W -f='${Version}' prometheus)"

# -------------------------------------------------------------------- loki
# Everything Loki writes lives on a volume of its own, so the 3 GB is a hard
# limit; the volume, the config and the unit's override are in place BEFORE the
# package is installed, because its postinst starts Loki at once — with the
# stock config it would listen on every interface and write to /tmp.
log "Loki: its own $LOKI_DISK_MB MiB volume at $LOKI_DIR"
if ! id loki >/dev/null 2>&1; then
  adduser --system --group --no-create-home --home "$LOKI_DIR" --shell /bin/false loki >/dev/null
fi
if [ ! -f "$LOKI_IMG" ]; then
  if [ -d "$LOKI_DIR" ] && ! mountpoint -q "$LOKI_DIR" && [ -n "$(ls -A "$LOKI_DIR" 2>/dev/null)" ]; then
    die "$LOKI_DIR already holds files; move them away first (the volume would hide them)"
  fi
  fallocate -l "${LOKI_DISK_MB}M" "$LOKI_IMG"
  chmod 0600 "$LOKI_IMG"
  mkfs.ext4 -q -F -m 0 -L loki "$LOKI_IMG"
  note "created $LOKI_IMG"
else
  have_mb=$(( $(stat -c %s "$LOKI_IMG") / 1048576 ))
  [ "$have_mb" = "$LOKI_DISK_MB" ] || note "$LOKI_IMG is $have_mb MiB, not $LOKI_DISK_MB: left as it is (resize by hand)"
fi
install -d -m 0750 "$LOKI_DIR"
cat > "$LOKI_MOUNT_UNIT" <<EOF
# Written by go-server/ops/install-monitoring.sh: Loki's volume, so its logs can
# never take more than the image's size.
[Unit]
Description=Loki's volume ($LOKI_IMG)
Before=loki.service

[Mount]
What=$LOKI_IMG
Where=$LOKI_DIR
Type=ext4
Options=loop,noatime,nodev,nosuid,noexec

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now var-lib-loki.mount >/dev/null 2>&1 || true
mountpoint -q "$LOKI_DIR" || die "could not mount $LOKI_IMG at $LOKI_DIR (journalctl -u var-lib-loki.mount)"
chown loki:loki "$LOKI_DIR"
chmod 0750 "$LOKI_DIR"
note "$(df -h --output=size,used,avail "$LOKI_DIR" | tail -n1 | awk '{print "size " $1 ", used " $2 ", free " $3}')"

install -d -m 0755 /etc/loki
MAX_HOURS=$(( LOKI_RETENTION_DAYS * 24 ))
cat > "$LOKI_CFG" <<EOF
# Written by go-server/ops/install-monitoring.sh — re-run it rather than editing here.
# One process, the loopback only, everything under $LOKI_DIR (its own volume).
auth_enabled: false

server:
  http_listen_address: 127.0.0.1
  http_listen_port: 3100
  grpc_listen_address: 127.0.0.1
  grpc_listen_port: 9096
  log_level: warn

common:
  instance_addr: 127.0.0.1
  path_prefix: $LOKI_DIR
  replication_factor: 1
  storage:
    filesystem:
      chunks_directory: $LOKI_DIR/chunks
      rules_directory: $LOKI_DIR/rules
  ring:
    kvstore:
      store: inmemory

memberlist:
  bind_addr: [127.0.0.1]

schema_config:
  configs:
    - from: "2026-09-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  # The longest logs are kept; loki-disk-guard lowers it in $LOKI_RUNTIME
  # when the volume fills.
  retention_period: ${MAX_HOURS}h
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  ingestion_rate_mb: 4
  ingestion_burst_size_mb: 8
  volume_enabled: true

compactor:
  working_directory: $LOKI_DIR/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 30m
  delete_request_store: filesystem

runtime_config:
  file: $LOKI_RUNTIME
  period: 10s

analytics:
  reporting_enabled: false
EOF
chmod 0644 "$LOKI_CFG"
# The retention the guard adjusts ("fake" is the one tenant of a Loki without
# auth). A re-run keeps what the guard set, unless it is over the new maximum.
# (Read only when it exists: under pipefail a sed on a missing file ends the
# whole script, silently — the first production run stopped here.)
cur_hours=""
if [ -r "$LOKI_RUNTIME" ]; then
  cur_hours="$(sed -n 's/^[[:space:]]*retention_period:[[:space:]]*\([0-9]\+\)h.*/\1/p' "$LOKI_RUNTIME" | head -n1)"
fi
if [ -z "$cur_hours" ] || [ "$cur_hours" -gt "$MAX_HOURS" ]; then cur_hours="$MAX_HOURS"; fi
cat > "$LOKI_RUNTIME" <<EOF
# Written by install-monitoring.sh and rewritten by $LOKI_GUARD. Loki reads it every 10 s.
overrides:
  fake:
    retention_period: ${cur_hours}h
EOF
chmod 0644 "$LOKI_RUNTIME"
install -d -m 0755 "$(dirname "$LOKI_DROPIN")"
cat > "$LOKI_DROPIN" <<EOF
# Written by go-server/ops/install-monitoring.sh: this config, not the package's
# /etc/loki/config.yml, and never without its volume.
[Unit]
RequiresMountsFor=$LOKI_DIR

[Service]
ExecStart=
ExecStart=/usr/bin/loki -config.file=$LOKI_CFG
EOF

cat > /etc/default/loki-disk-guard <<EOF
# Read by $LOKI_GUARD (install-monitoring.sh).
DIR=$LOKI_DIR
RUNTIME=$LOKI_RUNTIME
MAX_HOURS=$MAX_HOURS
MIN_HOURS=24
HIGH=80
LOW=50
EOF
cat > "$LOKI_GUARD" <<'EOF'
#!/usr/bin/env bash
# Written by go-server/ops/install-monitoring.sh; run hourly by loki-disk-guard.timer.
# Keeps Loki's logs off the ceiling of their volume. Loki deletes by age only, so
# when the volume is HIGH% full or more the time logs are kept is cut to three
# quarters (never under MIN_HOURS) and the compactor drops the oldest days within
# the hour; under LOW% it grows back a day a run, up to MAX_HOURS. The volume is
# the hard limit either way.
set -euo pipefail
. /etc/default/loki-disk-guard
used="$(df --output=pcent "$DIR" | tail -n1 | tr -dc '0-9')"
cur="$(sed -n 's/^[[:space:]]*retention_period:[[:space:]]*\([0-9]\+\)h.*/\1/p' "$RUNTIME" 2>/dev/null | head -n1 || true)"
cur="${cur:-$MAX_HOURS}"
new="$cur"
if [ "$used" -ge "$HIGH" ]; then
  new=$(( cur * 3 / 4 ))
  [ "$new" -ge "$MIN_HOURS" ] || new="$MIN_HOURS"
  [ "$new" -lt "$cur" ] || { logger -t loki-disk-guard "volume ${used}% full and logs already kept only ${cur}h"; exit 0; }
elif [ "$used" -lt "$LOW" ] && [ "$cur" -lt "$MAX_HOURS" ]; then
  new=$(( cur + 24 ))
  [ "$new" -le "$MAX_HOURS" ] || new="$MAX_HOURS"
fi
[ "$new" != "$cur" ] || exit 0
tmp="$(mktemp "$RUNTIME.XXXXXX")"
printf '# Written by install-monitoring.sh and rewritten by loki-disk-guard. Loki reads it every 10 s.\noverrides:\n  fake:\n    retention_period: %sh\n' "$new" > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$RUNTIME"
logger -t loki-disk-guard "volume ${used}% full: logs now kept ${new}h (were ${cur}h)"
EOF
chmod 0755 "$LOKI_GUARD"
cat > /etc/systemd/system/loki-disk-guard.service <<EOF
# Written by go-server/ops/install-monitoring.sh.
[Unit]
Description=Keep Loki's logs inside their volume
RequiresMountsFor=$LOKI_DIR

[Service]
Type=oneshot
ExecStart=$LOKI_GUARD
EOF
cat > /etc/systemd/system/loki-disk-guard.timer <<'EOF'
# Written by go-server/ops/install-monitoring.sh.
[Unit]
Description=Keep Loki's logs inside their volume, hourly

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload

log "Installing Loki and Alloy"
install_grafana_pkg loki "$LOKI_DEB_URL" "$LOKI_DEB_SHA256" || die "could not install Loki; try again later"
install_grafana_pkg alloy "$ALLOY_DEB_URL" "$ALLOY_DEB_SHA256" || die "could not install Alloy; try again later"
note "loki $(dpkg-query -W -f='${Version}' loki), alloy $(dpkg-query -W -f='${Version}' alloy)"

# ------------------------------------------------------------------- alloy
# Its own config file and settings beside the package's, which stay untouched
# (both are conffiles): the override adds a second EnvironmentFile, and a later
# EnvironmentFile wins.
log "Alloy: $GAME_UNIT's journal → Loki"
cat > "$ALLOY_CFG" <<EOF
// Written by go-server/ops/install-monitoring.sh — re-run it rather than editing here.
// The game server's journal → Loki, as the stream {service_name="gameplay"} the Logs
// dashboard reads (go-server/ops/monitoring/MONITORING.md, "The Logs dashboard").
logging {
  level  = "info"
  format = "logfmt"
}

loki.relabel "journal" {
  forward_to = []

  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "service"
  }

  rule {
    source_labels = ["__journal__hostname"]
    target_label  = "host"
  }
}

loki.source.journal "gameplay" {
  matches       = "_SYSTEMD_UNIT=$GAME_UNIT"
  max_age       = "12h"
  relabel_rules = loki.relabel.journal.rules
  labels        = { service_name = "gameplay" }
  forward_to    = [loki.process.gameplay.receiver]
}

// No DEBUG line reaches Loki (owner, 27 Sep 2026: "do not enable debug logs"),
// whatever LOG_LEVEL the game server is started with.
loki.process "gameplay" {
  stage.drop {
    expression          = "\"level\":\"DEBUG\""
    drop_counter_reason = "debug"
  }

  forward_to = [loki.write.local.receiver]
}

loki.write "local" {
  endpoint {
    url = "http://127.0.0.1:3100/loki/api/v1/push"
  }
}
EOF
cat > "$ALLOY_ENV" <<EOF
# Written by go-server/ops/install-monitoring.sh; read after /etc/default/alloy.
CONFIG_FILE="$ALLOY_CFG"
CUSTOM_ARGS="--server.http.listen-addr=127.0.0.1:12345 --disable-reporting"
EOF
chown root:alloy "$ALLOY_CFG" "$ALLOY_ENV"
chmod 0640 "$ALLOY_CFG" "$ALLOY_ENV"
install -d -m 0755 "$(dirname "$ALLOY_DROPIN")"
cat > "$ALLOY_DROPIN" <<EOF
# Written by go-server/ops/install-monitoring.sh.
[Service]
EnvironmentFile=$ALLOY_ENV
EOF
usermod -a -G systemd-journal alloy

# --------------------------------------------------------------- exporters
log "Exporters: loopback only"
set_default /etc/default/prometheus-node-exporter ARGS "--web.listen-address=127.0.0.1:9100"

# The postgres exporter runs as the OS user "prometheus"; peer authentication
# over the socket maps it to the database role of the same name, which gets
# pg_monitor and nothing else.
PGOPTIONS='-c statement_timeout=15000' runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d "$PG_DB" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'prometheus') THEN
    CREATE ROLE prometheus LOGIN;
  END IF;
END
$$;
GRANT pg_monitor TO prometheus;
SQL
set_default /etc/default/prometheus-postgres-exporter DATA_SOURCE_NAME \
  "user=prometheus host=/var/run/postgresql dbname=$PG_DB sslmode=disable"
set_default /etc/default/prometheus-postgres-exporter ARGS "--web.listen-address=127.0.0.1:9187"
chmod 0600 /etc/default/prometheus-postgres-exporter

set_default /etc/default/prometheus-nginx-exporter ARGS \
  "--web.listen-address=127.0.0.1:9113 --nginx.scrape-uri=http://127.0.0.1:8080/stub_status"
set_default /etc/default/prometheus-redis-exporter ARGS \
  "--web.listen-address=127.0.0.1:9121 --redis.addr=$REDIS_URL"
chmod 0600 /etc/default/prometheus-redis-exporter

cat > "$STUB_CONF" <<'EOF'
# nginx stub_status for prometheus-nginx-exporter (install-monitoring.sh). Loopback only.
server {
    listen 127.0.0.1:8080;
    server_name localhost;
    access_log off;
    location = /stub_status {
        stub_status;
        allow 127.0.0.1;
        deny all;
    }
}
EOF

# -------------------------------------------------------------- prometheus
log "Prometheus: $PROM_CFG"
install -m 0644 "$MON_DIR/prometheus/alerts.yml" "$PROM_RULES"
printf '%s' "$METRICS_TOKEN" > "$PROM_TOKEN"
chown root:prometheus "$PROM_TOKEN"
chmod 0640 "$PROM_TOKEN"
[ -f "$PROM_CFG" ] && [ ! -f "$PROM_CFG.dist" ] && cp -p "$PROM_CFG" "$PROM_CFG.dist"
PROM_NEW="$(mktemp)"
cat > "$PROM_NEW" <<EOF
# Written by go-server/ops/install-monitoring.sh — re-run it rather than editing here.
# Every target is on this host's loopback; job names match the dashboards in
# go-server/ops/monitoring/grafana/dashboards.
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s
  external_labels:
    monitor: king-teenpatti
    environment: production

rule_files:
  - $PROM_RULES

scrape_configs:
  - job_name: game-server
    metrics_path: $METRICS_PATH
    scheme: http
    authorization:
      type: Bearer
      credentials_file: $PROM_TOKEN
    static_configs:
      - targets: ['127.0.0.1:$GAME_PORT']
        labels:
          app: king-teenpatti

  - job_name: postgres
    static_configs:
      - targets: ['127.0.0.1:9187']

  - job_name: nginx
    static_configs:
      - targets: ['127.0.0.1:9113']

  - job_name: redis
    static_configs:
      - targets: ['127.0.0.1:9121']

  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:9100']
        labels:
          nodename: $NODENAME

  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']
EOF
promtool check config "$PROM_NEW" >/dev/null || { promtool check config "$PROM_NEW"; rm -f "$PROM_NEW"; die "promtool refused the new configuration; nothing changed"; }
install -m 0644 "$PROM_NEW" "$PROM_CFG"
rm -f "$PROM_NEW"
set_default /etc/default/prometheus ARGS \
  "--web.listen-address=127.0.0.1:9090 --storage.tsdb.retention.time=$RETENTION --storage.tsdb.retention.size=$RETENTION_SIZE"

# ----------------------------------------------------------------- grafana
log "Grafana: 127.0.0.1:$GRAFANA_PORT, served at https://$DOMAIN/dashboard/"
install -d -m 0755 "$(dirname "$GRAFANA_DROPIN")"
cat > "$GRAFANA_DROPIN" <<EOF
# Written by go-server/ops/install-monitoring.sh.
[Service]
Environment=GF_SERVER_HTTP_ADDR=127.0.0.1
Environment=GF_SERVER_HTTP_PORT=$GRAFANA_PORT
Environment=GF_SERVER_DOMAIN=$DOMAIN
Environment=GF_SERVER_ROOT_URL=https://$DOMAIN/dashboard/
Environment=GF_SERVER_SERVE_FROM_SUB_PATH=true
Environment=GF_SECURITY_ADMIN_USER=admin
Environment=GF_SECURITY_COOKIE_SECURE=true
Environment=GF_SECURITY_DISABLE_GRAVATAR=true
Environment=GF_USERS_ALLOW_SIGN_UP=false
Environment=GF_USERS_ALLOW_ORG_CREATE=false
Environment=GF_AUTH_ANONYMOUS_ENABLED=false
Environment=GF_ANALYTICS_REPORTING_ENABLED=false
Environment=GF_ANALYTICS_CHECK_FOR_UPDATES=false
Environment=GF_NEWS_NEWS_FEED_ENABLED=false
Environment=GF_LOG_MODE=file
Environment=GF_LOG_LEVEL=info
Environment=GF_LOG_FILE_LOG_ROTATE=true
Environment=GF_LOG_FILE_DAILY_ROTATE=true
Environment=GF_LOG_FILE_MAX_DAYS=7
Environment=GF_LOG_FILE_MAX_SIZE_SHIFT=24
Environment=GF_DASHBOARDS_VERSIONS_TO_KEEP=20
EOF

cat > /etc/grafana/provisioning/datasources/king-teenpatti.yml <<'EOF'
# Written by go-server/ops/install-monitoring.sh. The dashboards' datasource
# variables list every Prometheus / Loki datasource and default to these.
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
    jsonData:
      httpMethod: POST
      timeInterval: 15s
      prometheusType: Prometheus
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://127.0.0.1:3100
    editable: false
    jsonData:
      maxLines: 1000
EOF
cat > /etc/grafana/provisioning/dashboards/king-teenpatti.yml <<EOF
# Written by go-server/ops/install-monitoring.sh: the dashboards of
# go-server/ops/monitoring/grafana/dashboards, copied to $GRAFANA_DASHBOARDS.
apiVersion: 1
providers:
  - name: king-teenpatti
    orgId: 1
    folder: King Teen Patti
    folderUid: king-teenpatti-dashboards
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: $GRAFANA_DASHBOARDS
      foldersFromFilesStructure: false
EOF
install -d -o grafana -g grafana -m 0755 "$GRAFANA_DASHBOARDS"
find "$GRAFANA_DASHBOARDS" -maxdepth 1 -name '*.json' -delete
for dashboard in "$MON_DIR"/grafana/dashboards/*.json; do
  install -o grafana -g grafana -m 0644 "$dashboard" "$GRAFANA_DASHBOARDS/"
done
note "$(find "$GRAFANA_DASHBOARDS" -name '*.json' | wc -l) dashboards provisioned"

# ------------------------------------------------------------------- nginx
log "nginx: /dashboard/ → Grafana, /metrics closed to the internet"
cat > "$SNIPPET" <<EOF
# Written by go-server/ops/install-monitoring.sh; included by $SITE.
# Grafana, served from its /dashboard/ sub-path (GF_SERVER_SERVE_FROM_SUB_PATH).
location /dashboard/ {
    proxy_pass http://127.0.0.1:$GRAFANA_PORT;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
}
location = /dashboard {
    return 301 /dashboard/;
}
# Prometheus scrapes the game server on the loopback; the internet never needs /metrics.
location = $METRICS_PATH {
    return 404;
}
EOF
BACKUP="$SITE.bak-monitoring-$(date +%Y%m%d%H%M%S)"
if ! grep -q "include $SNIPPET;" "$SITE"; then
  cp -p "$SITE" "$BACKUP"
  # The first server block is the HTTPS one (certbot writes the port-80
  # redirect after it); the include goes right after its server_name line.
  sed -i "0,/^[[:space:]]*server_name[[:space:]]\+$DOMAIN;/s//&\n    include ${SNIPPET//\//\\/};/" "$SITE"
  grep -q "include $SNIPPET;" "$SITE" || { cp -p "$BACKUP" "$SITE"; die "could not add the include to $SITE; restored it"; }
  note "backup: $BACKUP"
fi
if ! nginx -t 2>/tmp/nginx-test.$$; then
  cat /tmp/nginx-test.$$ >&2
  [ -f "$BACKUP" ] && cp -p "$BACKUP" "$SITE"
  rm -f "$SNIPPET" "$STUB_CONF"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx
  die "nginx -t refused the configuration; the site is restored"
fi
rm -f /tmp/nginx-test.$$

# ---------------------------------------------------------------- services
log "Starting the services"
systemctl daemon-reload
systemctl reload nginx
for unit in prometheus-node-exporter prometheus-postgres-exporter prometheus-nginx-exporter \
  prometheus-redis-exporter prometheus grafana-server loki alloy loki-disk-guard.timer; do
  systemctl enable "$unit" >/dev/null 2>&1
  systemctl restart "$unit"
done

# The admin password: replaced only on a Grafana this run installed, while it still
# takes the default admin/admin. An existing Grafana's password is never touched —
# the owner set admin/admin on production to change it at the first sign-in
# (27 Sep 2026) — and is only warned about. Through Grafana's own API on the
# loopback: `grafana cli` run from a directory the grafana user cannot read (sudo
# from a home directory) panics before it starts (the first production run).
wait_http "http://127.0.0.1:$GRAFANA_PORT/api/health" 60 || die "Grafana did not come up (journalctl -u grafana-server)"
FIRST_RUN=0
DEFAULT_PW=0
if [ "$(curl -s -o /dev/null -w '%{http_code}' -u admin:admin "http://127.0.0.1:$GRAFANA_PORT/api/user")" = "200" ]; then
  DEFAULT_PW=1
fi
if [ "$GRAFANA_NEW" = 1 ] && [ "$DEFAULT_PW" = 1 ]; then
  FIRST_RUN=1
  DEFAULT_PW=0
  ADMIN_PW="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  changed="$(curl -s -o /dev/null -w '%{http_code}' -u admin:admin -H 'Content-Type: application/json' \
    -X PUT "http://127.0.0.1:$GRAFANA_PORT/api/user/password" \
    -d "{\"oldPassword\":\"admin\",\"newPassword\":\"$ADMIN_PW\",\"confirmNew\":\"$ADMIN_PW\"}")"
  [ "$changed" = "200" ] || die "could not replace Grafana's default admin password (HTTP $changed) — do it now: it is still admin/admin"
  (umask 077; printf '%s\n' "$ADMIN_PW" > "$ADMIN_PW_FILE")
fi

# ------------------------------------------------------------------ verify
log "Checking"
fail=0
check() {
  local name="$1" url="$2" wait="${3:-30}"
  if wait_http "$url" "$wait"; then note "ok    $name  $url"; else note "FAIL  $name  $url"; fail=1; fi
}
check node-exporter     http://127.0.0.1:9100/metrics
check postgres-exporter http://127.0.0.1:9187/metrics
check nginx-exporter    http://127.0.0.1:9113/metrics
check redis-exporter    http://127.0.0.1:9121/metrics
check prometheus        http://127.0.0.1:9090/-/ready
check grafana           http://127.0.0.1:$GRAFANA_PORT/api/health
check loki              http://127.0.0.1:3100/ready 90
check alloy             http://127.0.0.1:12345/-/ready
sleep 20   # one scrape of every target
curl -s http://127.0.0.1:9090/api/v1/targets | python3 -c '
import json, sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print("    target %-12s %-5s %s" % (t["labels"].get("job"), t["health"], t.get("lastError") or ""))
' || note "could not read the targets"
public="$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/dashboard/login" || true)"
note "https://$DOMAIN/dashboard/login → $public"
[ "$public" = "200" ] || fail=1
metrics_public="$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN$METRICS_PATH" || true)"
note "https://$DOMAIN$METRICS_PATH → $metrics_public (404 wanted)"
curl -s http://127.0.0.1:9090/api/v1/status/flags | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
print("    prometheus keeps %s or %s, whichever comes first" % (d["storage.tsdb.retention.time"], d["storage.tsdb.retention.size"]))
' || note "could not read the retention flags"
note "on disk: $(du -sh /var/lib/prometheus /var/lib/grafana /var/log/grafana 2>/dev/null | awk '{printf "%s %s  ", $2, $1}')"
note "loki volume: $(df -h --output=size,used,pcent "$LOKI_DIR" | tail -n1 | awk '{print $2 " of " $1 " (" $3 ")"}'), logs kept $(sed -n 's/^[[:space:]]*retention_period:[[:space:]]*//p' "$LOKI_RUNTIME")"
sleep 15   # Alloy's first push
lines="$(curl -sG http://127.0.0.1:3100/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({service_name="gameplay"}[12h]))' \
  | python3 -c 'import json, sys; r = json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null || echo "?")"
note "loki holds $lines game-server lines from the last 12 h"
[ "$lines" != "0" ] && [ "$lines" != "?" ] || { note "FAIL  no game-server lines in Loki (journalctl -u alloy)"; fail=1; }

log "Done"
note "Grafana:  https://$DOMAIN/dashboard/   user admin"
if [ "$FIRST_RUN" = 1 ]; then
  note "password: $(cat "$ADMIN_PW_FILE")   (kept in $ADMIN_PW_FILE)"
elif [ "$DEFAULT_PW" = 1 ]; then
  note "password: admin — STILL THE DEFAULT, and Grafana is on the internet: change it now"
elif [ -s "$ADMIN_PW_FILE" ]; then
  note "password: unchanged (sudo cat $ADMIN_PW_FILE)"
else
  note "password: already set, unchanged"
fi
note "Dashboards: folder \"King Teen Patti\" — king-teenpatti (all rows) and one per concern"
[ "$fail" = 0 ] || die "a check failed; see above (journalctl -u <service>)"
