#!/usr/bin/env bash
# Moves the production King Teen Patti server from ONE Node process
# (gameplay.service on :3000) to WORKER_COUNT worker processes
# (gameplay@1..N on 3101..310N) behind nginx, and points Prometheus at them.
# Idempotent: every step checks before it changes, so re-running after a
# failure or a config edit is safe and prints only what it had to do.
#
#   sudo bash install-cluster.sh                # 3 workers (the shipped config)
#   sudo WORKER_COUNT=4 bash install-cluster.sh # regenerates unit/nginx/prom for 4
#
# Order is chosen so a failure leaves the old path serving: workers come up on
# their own ports first and must answer /health; only then is nginx switched
# (graceful reload) and the old single-process unit stopped. Players on the
# old process are dropped once and reconnect through nginx onto a worker.
#
# Assumes the layout of the 2026-09 production box: repo at $APP_DIR with its
# .env, systemd, nginx with sites-enabled, Prometheus at $PROM_CFG (systemd
# unit "prometheus", or a docker one reachable on :9090), Grafana on :3001.
set -euo pipefail

WORKER_COUNT=${WORKER_COUNT:-3}
WORKER_BASE_PORT=${WORKER_BASE_PORT:-3100}
APP_DIR=${APP_DIR:-/var/www/gameplay/king-teenpatti/server}
ENV_FILE=${ENV_FILE:-$APP_DIR/.env}
OLD_SERVICE=${OLD_SERVICE:-gameplay}          # the single-process unit to retire
NGINX_SITE=${NGINX_SITE:-gameplay}            # /etc/nginx/sites-available/<name>
PROM_CFG=${PROM_CFG:-/etc/prometheus/prometheus.yml}
PUBLIC_URL=${PUBLIC_URL:-https://api.sungamestudio.com}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

log()  { printf '\e[1m==> %s\e[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\e[33m    WARNING: %s\e[0m\n' "$*"; }
die()  { printf '\e[31mERROR: %s\e[0m\n' "$*" >&2; exit 1; }
CHANGED=()
did()  { CHANGED+=("$*"); note "$*"; }

[ "$(id -u)" = 0 ] || die "run as root: sudo bash $0"
[[ "$WORKER_COUNT" =~ ^[1-9][0-9]?$ ]] || die "WORKER_COUNT must be 1..99, got '$WORKER_COUNT'"
[[ "$WORKER_BASE_PORT" =~ ^[0-9]+$ ]] || die "WORKER_BASE_PORT must be a number"
[ -f "$APP_DIR/src/index.js" ] || die "no server at $APP_DIR (set APP_DIR)"
[ -f "$ENV_FILE" ] || die "no .env at $ENV_FILE"
[ -f "$HERE/gameplay@.service" ] || die "gameplay@.service missing next to this script"
[ -f "$HERE/gameplay.target" ] || die "gameplay.target missing next to this script"
[ -f "$HERE/nginx-gameplay.conf" ] || die "nginx-gameplay.conf missing next to this script"
command -v node >/dev/null || die "node not on PATH"
command -v nginx >/dev/null || die "nginx not installed"
command -v curl >/dev/null || die "curl not installed"

port_of() { echo $((WORKER_BASE_PORT + $1)); }

# wait_health <id> — true once the worker answers /health on its own port AND
# reports itself as worker <id> (30 s budget). Answering on the port is not
# enough: a process that came up in single-process mode, or as another worker,
# is exactly the misconfiguration this guards against.
wait_health() {
  local id=$1 port body reported; port=$(port_of "$1")
  for _ in $(seq 1 60); do
    if body=$(curl -sf -m 2 "http://127.0.0.1:$port/health" 2>/dev/null); then
      reported=$(printf '%s' "$body" | node -e '
        let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
          try { console.log(JSON.parse(s).worker?.id ?? "none"); } catch { console.log("unparseable"); } });')
      if [ "$reported" = "$id" ]; then return 0; fi
      printf '\e[31m    :%s answers /health but reports worker.id=%s, expected %s — check %s and the unit\e[0m\n' "$port" "$reported" "$id" "$ENV_FILE" >&2
      journalctl -u "gameplay@$id" -n 20 --no-pager || true
      return 1
    fi
    sleep 0.5
  done
  journalctl -u "gameplay@$id" -n 20 --no-pager || true
  return 1
}

# ---------------------------------------------------------------- sanity
log "Checking the environment"
# The unit provides WORKER_ID/COUNT/BASE_PORT; EnvironmentFile= would override
# them, and an empty WORKER_ID= means "single process on :3000" for every worker.
if grep -qE '^\s*WORKER_(ID|COUNT|BASE_PORT|PORT)=' "$ENV_FILE"; then
  grep -nE '^\s*WORKER_(ID|COUNT|BASE_PORT|PORT)=' "$ENV_FILE" >&2
  die "$ENV_FILE must not set WORKER_*; the systemd unit provides them (comment the lines out and re-run)"
fi
if grep -qE '^\s*PORT=' "$ENV_FILE"; then
  note "$ENV_FILE sets PORT — that is the single process's port; workers ignore it and listen on $WORKER_BASE_PORT + WORKER_ID"
fi
pool=$(grep -E '^\s*PG_POOL_MAX=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '[:space:]"'"'" || true)
[[ "${pool:-}" =~ ^[0-9]+$ ]] || pool=10
max_conn=$(sudo -u postgres psql -Atqc 'show max_connections' 2>/dev/null || true)
[[ "${max_conn:-}" =~ ^[0-9]+$ ]] || max_conn=100
# Each worker also holds one connection outside the pool for the registry heartbeat.
note "PG_POOL_MAX=$pool per worker (+1 heartbeat connection) × $WORKER_COUNT workers = $(( (pool + 1) * WORKER_COUNT )) Postgres connections; max_connections=$max_conn"
needed=$(( (pool + 1) * WORKER_COUNT + 20 ))   # + exporter, psql, headroom
if [ "$needed" -gt "$max_conn" ]; then
  # Postgres would refuse the workers' connections under load, so raise the
  # limit here rather than leave the cluster starved. max_connections needs a
  # restart to take effect; the game is being restarted by this deploy anyway.
  target=$(( (needed + 49) / 50 * 50 ))
  [ "$target" -lt 200 ] && target=200
  note "Postgres max_connections=$max_conn is below the $needed the cluster needs — raising it to $target (ALTER SYSTEM + restart)"
  sudo -u postgres psql -Atqc "ALTER SYSTEM SET max_connections = $target" >/dev/null || die "could not ALTER SYSTEM SET max_connections"
  systemctl restart postgresql || die "postgresql did not restart — check journalctl -u postgresql"
  for _ in $(seq 1 30); do sudo -u postgres psql -Atqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  max_conn=$(sudo -u postgres psql -Atqc 'show max_connections' 2>/dev/null || echo '?')
  did "postgres max_connections is now $max_conn"
fi
wc_val=$(grep -hoE '^\s*worker_connections\s+[0-9]+' /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | head -1 || true)
if [[ "${wc_val:-}" =~ ^[0-9]+$ ]] && [ "$wc_val" -lt 4096 ]; then
  warn "nginx worker_connections is $wc_val — a proxied websocket costs two; ~$((wc_val / 2)) players per nginx worker. See ops/monitoring/nginx/nginx.conf.example."
fi

# ---------------------------------------------------------------- systemd
log "Installing gameplay@.service and gameplay.target for $WORKER_COUNT workers"
tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
sed -e "s/^Environment=WORKER_COUNT=.*/Environment=WORKER_COUNT=$WORKER_COUNT/" \
    -e "s/^Environment=WORKER_BASE_PORT=.*/Environment=WORKER_BASE_PORT=$WORKER_BASE_PORT/" \
    "$HERE/gameplay@.service" > "$tmpdir/gameplay@.service"
wants=""
for ((i = 1; i <= WORKER_COUNT; i++)); do wants="$wants gameplay@$i.service"; done
sed -e "s/^Wants=.*/Wants=${wants# }/" "$HERE/gameplay.target" > "$tmpdir/gameplay.target"
units_changed=0
for name in gameplay@.service gameplay.target; do
  dst=/etc/systemd/system/$name
  if [ -f "$dst" ] && cmp -s "$tmpdir/$name" "$dst"; then
    note "$dst unchanged"
  else
    install -m 0644 "$tmpdir/$name" "$dst"; did "wrote $dst"; units_changed=1
  fi
done
systemctl daemon-reload
for ((i = 1; i <= WORKER_COUNT; i++)); do
  if systemctl is-active --quiet "gameplay@$i"; then
    if [ "$units_changed" = 1 ]; then
      # One at a time, and only after the previous one is healthy again.
      systemctl restart "gameplay@$i"; did "restarted gameplay@$i (unit changed)"
      wait_health "$i" || die "gameplay@$i did not come back after the restart — fix it before continuing"
    else
      note "gameplay@$i already running"
    fi
    systemctl is-enabled --quiet "gameplay@$i" 2>/dev/null || { systemctl enable "gameplay@$i" 2>/dev/null; did "enabled gameplay@$i"; }
  else
    systemctl enable --now "gameplay@$i" 2>&1 | grep -v '^Created symlink' || true
    did "enabled + started gameplay@$i"
  fi
done
systemctl is-enabled --quiet gameplay.target 2>/dev/null || systemctl enable gameplay.target 2>/dev/null || true
# Workers beyond WORKER_COUNT from an earlier run with a larger count.
for u in $(systemctl list-units --all --plain --no-legend 'gameplay@*.service' | awk '{print $1}'); do
  id=${u#gameplay@}; id=${id%.service}
  if [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -gt "$WORKER_COUNT" ]; then
    systemctl disable --now "$u" >/dev/null 2>&1 || true; did "stopped surplus $u"
  fi
done

log "Waiting for the workers to answer /health"
for ((i = 1; i <= WORKER_COUNT; i++)); do
  if wait_health "$i"; then
    note "worker $i healthy on :$(port_of "$i")"
  else
    die "worker $i did not answer on :$(port_of "$i") within 30 s — nginx and $OLD_SERVICE were NOT touched"
  fi
done

# ------------------------------------------------------------------ nginx
log "Installing the nginx site '$NGINX_SITE'"
site_src=$tmpdir/site.conf
if [ "$WORKER_COUNT" = 3 ] && [ "$WORKER_BASE_PORT" = 3100 ]; then
  cp "$HERE/nginx-gameplay.conf" "$site_src"
else
  # Regenerate the two marked blocks for this count/base port.
  awk -v n="$WORKER_COUNT" -v base="$WORKER_BASE_PORT" '
    /# --- workers BEGIN/ { print; for (i = 1; i <= n; i++) printf "    server 127.0.0.1:%d max_fails=3 fail_timeout=10s;\n", base + i; skip = 1; next }
    /# --- per-worker paths BEGIN/ { print
      for (i = 1; i <= n; i++) {
        printf "    location /w%d/socket.io/ {\n", i
        printf "        proxy_pass http://127.0.0.1:%d/socket.io/;\n", base + i
        print  "        proxy_set_header Host              $host;"
        print  "        proxy_set_header X-Real-IP         $remote_addr;"
        print  "        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;"
        print  "        proxy_set_header X-Forwarded-Proto $scheme;"
        print  "        proxy_set_header Upgrade           $http_upgrade;"
        print  "        proxy_set_header Connection        $gameplay_connection_upgrade;"
        print  "        proxy_read_timeout    3600s;"
        print  "        proxy_send_timeout    3600s;"
        print  "        proxy_connect_timeout 10s;"
        print  "        proxy_buffering off;"
        print  "    }"
      }
      skip = 1; next }
    /# --- (workers|per-worker paths) END/ { skip = 0 }
    !skip { print }
  ' "$HERE/nginx-gameplay.conf" > "$site_src"
fi
site_dst=/etc/nginx/sites-available/$NGINX_SITE
backup=""
if [ -f "$site_dst" ] && cmp -s "$site_src" "$site_dst"; then
  note "$site_dst unchanged"
else
  if [ -f "$site_dst" ]; then
    backup="$site_dst.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$site_dst" "$backup"; did "backed up previous site to $backup (ROLLBACK.md uses it)"
  fi
  install -m 0644 "$site_src" "$site_dst"; did "wrote $site_dst"
fi
if [ ! -e "/etc/nginx/sites-enabled/$NGINX_SITE" ]; then
  ln -s "$site_dst" "/etc/nginx/sites-enabled/$NGINX_SITE"; did "enabled site $NGINX_SITE"
fi
if out=$(nginx -t 2>&1); then
  systemctl reload nginx; did "nginx -t ok, reloaded"
else
  printf '%s\n' "$out"
  if [ -n "$backup" ]; then cp -p "$backup" "$site_dst"; warn "restored $backup"; fi
  die "nginx -t failed — previous site restored, $OLD_SERVICE left running"
fi

# ------------------------------------------------------ retire the old unit
log "Retiring the single-process unit $OLD_SERVICE.service"
if systemctl list-unit-files --no-legend "$OLD_SERVICE.service" 2>/dev/null | grep -q .; then
  if systemctl is-active --quiet "$OLD_SERVICE" || systemctl is-enabled --quiet "$OLD_SERVICE" 2>/dev/null; then
    systemctl disable --now "$OLD_SERVICE" >/dev/null 2>&1 || true
    did "stopped + disabled $OLD_SERVICE.service (unit file kept for rollback)"
  else
    note "$OLD_SERVICE.service already stopped and disabled"
  fi
else
  note "no $OLD_SERVICE.service on this box"
fi

# ------------------------------------------------------------- prometheus
log "Prometheus jobs king-teenpatti-w1..w$WORKER_COUNT"
if [ -f "$PROM_CFG" ]; then
  grep -q '^scrape_configs:' "$PROM_CFG" || die "no scrape_configs in $PROM_CFG"
  # Jobs are appended at the end of the file, which is only valid YAML when
  # scrape_configs is the LAST top-level key.
  last_key=$(grep -oE '^[a-z_]+:' "$PROM_CFG" | tail -1)
  prom_changed=0
  for ((i = 1; i <= WORKER_COUNT; i++)); do
    name="king-teenpatti-w$i"; target="127.0.0.1:$(port_of "$i")"
    if grep -qE "job_name: [\"']?${name}[\"']?\s*$" "$PROM_CFG"; then
      note "job $name already present"
    elif [ "$last_key" != "scrape_configs:" ]; then
      warn "scrape_configs is not the last top-level key in $PROM_CFG ($last_key is) — add this job by hand:"
      printf '  - job_name: "%s"\n    metrics_path: /metrics\n    static_configs:\n      - targets: ["%s"]\n        labels:\n          app: king-teenpatti\n          worker: "%s"\n' "$name" "$target" "$i"
    else
      printf '\n  - job_name: "%s"\n    metrics_path: /metrics\n    static_configs:\n      - targets: ["%s"]\n        labels:\n          app: king-teenpatti\n          worker: "%s"\n' "$name" "$target" "$i" >> "$PROM_CFG"
      did "added job $name -> $target"; prom_changed=1
    fi
  done
  if grep -qE 'job_name: [\"'"'"']?game-server[\"'"'"']?\s*$' "$PROM_CFG" && grep -qE '127\.0\.0\.1:3000|localhost:3000|host\.docker\.internal:3000' "$PROM_CFG"; then
    warn "the old 'game-server' job (…:3000) will report DOWN now that $OLD_SERVICE is stopped. Delete it from $PROM_CFG. (The repo's alerts.yml GameServerDown already matches up{job=~\"game-server|king-teenpatti-w.*\"}; copy it over the host's rules file if that is a separate copy.)"
  fi
  if command -v promtool >/dev/null; then promtool check config "$PROM_CFG" >/dev/null || die "promtool rejects $PROM_CFG — fix it before Prometheus is reloaded"; fi
  if [ "$prom_changed" = 1 ]; then
    if systemctl list-unit-files --no-legend prometheus.service 2>/dev/null | grep -q .; then
      systemctl reload prometheus 2>/dev/null || systemctl restart prometheus; did "reloaded prometheus"
    elif curl -sf -m 5 -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
      did "reloaded prometheus via /-/reload"
    else
      warn "could not reload Prometheus — reload it yourself (systemctl reload prometheus, or docker compose exec prometheus kill -HUP 1)"
    fi
  fi
else
  warn "no Prometheus config at $PROM_CFG — skipped (set PROM_CFG to add the per-worker jobs)"
fi

# ----------------------------------------------------------------- report
log "Worker health"
for ((i = 1; i <= WORKER_COUNT; i++)); do
  port=$(port_of "$i")
  body=$(curl -s -m 5 "http://127.0.0.1:$port/health" || echo '{"ok":false}')
  printf '    worker %d  :%d  %s\n' "$i" "$port" "$(printf '%s' "$body" | node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      try { const h = JSON.parse(s); const p = h.process || {};
        console.log(`ok=${h.ok} up=${Math.round(h.uptime || 0)}s tables=${h.tables} players=${h.players} sockets=${h.sockets ?? "-"} rss=${p.rssMb ?? "-"}MB db=${h.db ? h.db.total + "/" + h.db.idle : "-"}`); }
      catch { console.log(s.slice(0, 80) || "no answer"); } });')"
done
printf '    via nginx  %s\n' "$(curl -s -m 5 -o /dev/null -w "$PUBLIC_URL/health -> HTTP %{http_code}" "$PUBLIC_URL/health" 2>/dev/null || echo "$PUBLIC_URL/health unreachable from here")"
for ((i = 1; i <= WORKER_COUNT; i++)); do
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$PUBLIC_URL/w$i/socket.io/?EIO=4&transport=polling" 2>/dev/null || echo '---')
  printf '    /w%d/socket.io/ handshake via nginx -> HTTP %s (200 = routed to worker %d)\n' "$i" "$code" "$i"
done

echo
if [ "${#CHANGED[@]}" = 0 ]; then
  log "Nothing to do — the cluster was already installed as configured"
else
  log "Done. Changes made:"
  for c in "${CHANGED[@]}"; do note "- $c"; done
fi
note "logs: journalctl -u 'gameplay@*' -f     status: systemctl status 'gameplay@*'"
note "one-at-a-time restart (no-downtime deploy): for i in $(seq -s ' ' 1 "$WORKER_COUNT"); do systemctl restart gameplay@\$i; sleep 5; done"
note "rollback: $HERE/ROLLBACK.md"
