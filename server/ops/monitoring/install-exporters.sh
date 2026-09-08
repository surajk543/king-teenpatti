#!/usr/bin/env bash
# Installs the two missing exporters on the production host and wires them,
# plus node_exporter, into the host's Prometheus — the pieces that fill the
# System, PostgreSQL and Nginx rows of the Grafana dashboard (requirements
# 35e, 35g, 36). Idempotent: safe to run again.
#
#   sudo bash install-exporters.sh
#
# Assumes: Prometheus at /etc/prometheus/prometheus.yml (systemd unit
# "prometheus"), node_exporter already running on :9100, nginx with
# sites-enabled, the game server's .env at the path below holding DATABASE_URL.
set -euo pipefail

ENV_FILE=${ENV_FILE:-/var/www/gameplay/king-teenpatti/server/.env}
PROM_CFG=${PROM_CFG:-/etc/prometheus/prometheus.yml}
PG_EXPORTER_VERSION=0.17.1
NGINX_EXPORTER_VERSION=1.4.2

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

# ---------------------------------------------------------------- postgres
if ! id postgres_exporter >/dev/null 2>&1; then useradd --system --no-create-home --shell /usr/sbin/nologin postgres_exporter; fi
if [ ! -x /usr/local/bin/postgres_exporter ]; then
  tmp=$(mktemp -d)
  curl -sSL "https://github.com/prometheus-community/postgres_exporter/releases/download/v${PG_EXPORTER_VERSION}/postgres_exporter-${PG_EXPORTER_VERSION}.linux-amd64.tar.gz" | tar xz -C "$tmp"
  install -m 0755 "$tmp"/postgres_exporter-*/postgres_exporter /usr/local/bin/postgres_exporter
  rm -rf "$tmp"
fi
# The exporter reads the same database the game writes; the URL comes from the
# server's own .env so there is one place to change a password.
DATABASE_URL=$(grep -E '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")
[ -n "$DATABASE_URL" ] || { echo "no DATABASE_URL in $ENV_FILE"; exit 1; }
case "$DATABASE_URL" in *\?*) DSN="$DATABASE_URL&sslmode=disable";; *) DSN="$DATABASE_URL?sslmode=disable";; esac
install -d -m 0750 -o postgres_exporter -g postgres_exporter /etc/postgres_exporter
printf 'DATA_SOURCE_NAME=%s\n' "$DSN" > /etc/postgres_exporter/env
chmod 0640 /etc/postgres_exporter/env; chown postgres_exporter:postgres_exporter /etc/postgres_exporter/env
cat > /etc/systemd/system/postgres_exporter.service <<'EOF'
[Unit]
Description=Prometheus PostgreSQL exporter (King Teen Patti)
After=network.target postgresql.service

[Service]
User=postgres_exporter
EnvironmentFile=/etc/postgres_exporter/env
ExecStart=/usr/local/bin/postgres_exporter --web.listen-address=127.0.0.1:9187 --collector.database --collector.stat_database --collector.locks --collector.stat_user_tables
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------------------------------- nginx
# stub_status on the loopback only; the exporter reads it from the same host.
cat > /etc/nginx/conf.d/stub_status.conf <<'EOF'
server {
    listen 127.0.0.1:8080;
    server_name _;
    location /stub_status {
        stub_status;
        access_log off;
        allow 127.0.0.1;
        deny all;
    }
}
EOF
nginx -t
systemctl reload nginx

if ! id nginx_exporter >/dev/null 2>&1; then useradd --system --no-create-home --shell /usr/sbin/nologin nginx_exporter; fi
if [ ! -x /usr/local/bin/nginx-prometheus-exporter ]; then
  tmp=$(mktemp -d)
  curl -sSL "https://github.com/nginx/nginx-prometheus-exporter/releases/download/v${NGINX_EXPORTER_VERSION}/nginx-prometheus-exporter_${NGINX_EXPORTER_VERSION}_linux_amd64.tar.gz" | tar xz -C "$tmp"
  install -m 0755 "$tmp"/nginx-prometheus-exporter /usr/local/bin/nginx-prometheus-exporter
  rm -rf "$tmp"
fi
cat > /etc/systemd/system/nginx_exporter.service <<'EOF'
[Unit]
Description=Prometheus nginx exporter (King Teen Patti)
After=network.target nginx.service

[Service]
User=nginx_exporter
ExecStart=/usr/local/bin/nginx-prometheus-exporter --nginx.scrape-uri=http://127.0.0.1:8080/stub_status --web.listen-address=127.0.0.1:9113
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now postgres_exporter nginx_exporter

# -------------------------------------------------------------- prometheus
# Append the three jobs once. The dashboard filters on these job names.
add_job() {
  local name=$1 target=$2
  if grep -q "job_name: \"$name\"" "$PROM_CFG" || grep -q "job_name: $name\b" "$PROM_CFG" || grep -q "job_name: '$name'" "$PROM_CFG"; then
    echo "prometheus: job $name already present"
  else
    printf '\n  - job_name: "%s"\n    static_configs:\n      - targets: ["%s"]\n' "$name" "$target" >> "$PROM_CFG"
    echo "prometheus: added job $name -> $target"
  fi
}
grep -q '^scrape_configs:' "$PROM_CFG" || { echo "no scrape_configs in $PROM_CFG"; exit 1; }
add_job node 127.0.0.1:9100
add_job postgres 127.0.0.1:9187
add_job nginx 127.0.0.1:9113
promtool check config "$PROM_CFG" >/dev/null 2>&1 || /usr/bin/promtool check config "$PROM_CFG"
systemctl reload prometheus || systemctl restart prometheus

sleep 3
echo
echo "exporters:"
curl -s -m 5 http://127.0.0.1:9187/metrics | grep -E '^pg_up' || echo "  postgres_exporter not answering yet"
curl -s -m 5 http://127.0.0.1:9113/metrics | grep -E '^nginx_up' || echo "  nginx_exporter not answering yet"
echo "prometheus targets:"
curl -s -m 5 http://127.0.0.1:9090/api/v1/targets | python3 -c 'import json,sys; [print(" ", t["labels"].get("job"), t["scrapeUrl"], t["health"]) for t in json.load(sys.stdin)["data"]["activeTargets"]]'
echo
echo "done — the System, PostgreSQL and Nginx rows fill within a minute."
