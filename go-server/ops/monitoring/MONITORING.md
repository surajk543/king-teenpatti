# Monitoring runbook — King Teen Patti server

Prometheus + Grafana observability for the game server (Requirements 35 and 36).
The server side of this — the `/metrics` endpoint and every `game_*` metric — lives in
`go-server/internal/metrics/` (`names.go` is the catalogue, `metrics.go` the registry, handler and
HTTP middleware) and the socket/room/ledger code that feeds it. This directory is everything
*around* the process: the scrapers, the exporters, the dashboard, the alerts, and the nginx
settings that decide how many players the box can carry.

```
ops/monitoring/
├── docker-compose.yml            Prometheus, Grafana, postgres_exporter, nginx exporter, node_exporter
├── .env.example                  → copy to .env (Grafana password, ports, DSNs)
├── prometheus/
│   ├── prometheus.yml            scrape jobs: game-server, postgres, nginx, node, prometheus
│   ├── alerts.yml                25 rules (see "Alerts")
│   └── metrics_token             (optional, git-ignored) bearer token for /metrics
├── grafana/
│   ├── provisioning/datasources/prometheus.yml
│   ├── provisioning/dashboards/dashboards.yml
│   ├── dashboards/king-teenpatti.json   the metrics dashboard, uid king-teenpatti
│   └── dashboards/king-teenpatti-logs.json   the Loki logs dashboard, uid king-teenpatti-logs (see "The Logs dashboard")
└── nginx/
    ├── king-teenpatti.conf.example      api.sungamestudio.com site + stub_status server
    ├── nginx.conf.example               main-context: worker_rlimit_nofile / events {}
    └── systemd/                         LimitNOFILE drop-ins for nginx and the (former) Node service; the Go unit carries its own LimitNOFILE
```

Contents: [What the server exposes](#what-the-server-exposes) · [Running the stack](#running-the-stack-locally) ·
[Production](#pointing-prometheus-at-production) · [Securing /metrics](#securing-metrics) ·
[Percentiles](#percentiles-p50--p90--p95--p99) · [Exporters](#exporters) · [Label rule](#the-label-cardinality-rule) ·
[Dashboard](#the-grafana-dashboard) · [Alerts](#alerts) · [Requirements checklist](#requirements-checklist) ·
[Troubleshooting](#troubleshooting)

---

## What the server exposes

`GET /metrics` (path from `METRICS_PATH`, on the same port as the API — 3000) returns the
Prometheus text format. Controlled by five env keys in `go-server/.env` (`go-server/.env.example` lists them):

| Key | Default | Meaning |
|---|---|---|
| `METRICS_ENABLED` | `true` | `false` removes the endpoint and the HTTP middleware entirely |
| `METRICS_PATH` | `/metrics` | must match `metrics_path` in `prometheus/prometheus.yml` |
| `METRICS_PREFIX` | `game_server_` | prefix of the process/runtime metrics (not of the `game_*` ones) |
| `METRICS_TOKEN` | empty | when set, requests must carry `Authorization: Bearer <token>` |
| `METRICS_ALLOW_IPS` | empty | comma-separated client IPs that may scrape (see [Securing](#securing-metrics)) |

Every series carries the default label `service="king-teenpatti"`. Quick look:

```bash
curl -s localhost:3000/metrics | grep -v '^#' | cut -d'{' -f1 | cut -d' ' -f1 | sort -u | wc -l   # distinct metric names
curl -s localhost:3000/metrics | grep '^game_connected_sockets '
curl -s -H 'Authorization: Bearer <token>' https://api.sungamestudio.com/metrics | head
```

### Node.js process (`game_server_*`, prom-client default collectors + four extras)

> **Go server (production since the `go-server/` deploy — see `go-server/ops/DEPLOY.md`).** The Go
> binary keeps every `game_*` metric below byte-for-byte, and the `game_server_process_*` family
> (`cpu_*`, `resident_memory_bytes`, `open_fds`/`max_fds`, `start_time_seconds`, `uptime_seconds`,
> plus `network_receive/transmit_bytes_total`). **No `game_server_nodejs_*` series exist**; the
> runtime is described by `game_server_go_*` instead: `go_goroutines`, `go_threads`,
> `go_sched_gomaxprocs_threads`, `go_sched_latencies_seconds` (histogram — the event-loop-lag
> analogue), `go_sched_pauses_total_gc_seconds` (histogram), `go_gc_duration_seconds` (summary),
> `go_memstats_{heap_alloc,heap_inuse,heap_sys,stack_inuse,sys}_bytes`, `go_memstats_heap_objects`,
> `go_memstats_mallocs_total`, `go_gc_heap_{live,goal}_bytes`, `go_info{version}`. The dashboard's
> "Runtime" row and the `GameServerSchedulerLatencyHigh` / `GameServerGoroutinesHigh` /
> `GameServerMemoryHigh` alerts use exactly these. The table below documents the Node build.

| Metric | Type | What |
|---|---|---|
| `game_server_process_cpu_seconds_total`, `_cpu_user_seconds_total`, `_cpu_system_seconds_total` | counter | CPU time; `rate()` gives cores used (1.0 = one core) |
| `game_server_process_resident_memory_bytes` | gauge | RSS |
| `game_server_process_virtual_memory_bytes`, `game_server_process_heap_bytes` | gauge | VSZ, process heap |
| `game_server_nodejs_heap_size_total_bytes`, `_heap_size_used_bytes` | gauge | V8 heap reserved / in use |
| `game_server_nodejs_heap_size_limit_bytes` | gauge | V8 `heap_size_limit` — OOM at 100 % (extra) |
| `game_server_nodejs_heap_space_size_{total,used,available}_bytes{space}` | gauge | per V8 space |
| `game_server_nodejs_external_memory_bytes` | gauge | C++ objects bound to JS (socket buffers) |
| `game_server_nodejs_array_buffers_bytes` | gauge | ArrayBuffer/SharedArrayBuffer memory (extra) |
| `game_server_nodejs_eventloop_lag_seconds` and `_min/_max/_mean/_stddev/_p50/_p90/_p99_seconds` | gauge | event-loop delay, sampled every 10 ms |
| `game_server_nodejs_eventloop_utilization` | gauge | share of the last scrape interval the loop was busy, 0–1 (extra) |
| `game_server_nodejs_gc_duration_seconds{kind}` | histogram | GC pauses; `kind` = minor / major / incremental / weakcb |
| `game_server_nodejs_active_handles{type}`, `_active_handles_total` | gauge | libuv handles (sockets, timers) |
| `game_server_nodejs_active_requests{type}`, `_active_requests_total` | gauge | in-flight libuv requests |
| `game_server_nodejs_active_resources{type}`, `_active_resources_total` | gauge | handles + requests |
| `game_server_process_uptime_seconds` | gauge | seconds since start (extra) |
| `game_server_process_start_time_seconds` | gauge | epoch of process start |
| `game_server_nodejs_version_info{version,major,minor,patch}` | gauge (1) | runtime version |
| `game_server_process_open_fds`, `game_server_process_max_fds` | gauge | open / allowed file descriptors |

### Sockets (`game_*`, Requirement 35b)

| Metric | Type | Labels | What |
|---|---|---|---|
| `game_connected_sockets` | gauge | — | Socket.IO connections open now |
| `game_connected_sockets_peak` | gauge | — | highest simultaneous count since start |
| `game_connections_total` | counter | — | connections accepted |
| `game_disconnections_total` | counter | `reason` | Socket.IO disconnect reason (`transport close`, `ping timeout`, `client namespace disconnect`, `server namespace disconnect`, `transport error`, …, else `other`) |
| `game_reconnects_total` | counter | `kind` | player came back to a held seat, or accepted a resume offer |
| `game_socket_errors_total` | counter | `code` | requests refused on the socket, by snake_case error code |
| `game_socket_messages_total` | counter | `event` | inbound messages by event name (`game:action`, `room:quickJoin`, `chat:message`, …) |
| `game_socket_emits_total` | counter | `event` | outbound messages by event name (a room broadcast counts once) |
| `game_session_replaced_total` | counter | — | a second sign-in displaced an existing socket |

### Game (Requirement 35c)

| Metric | Type | Labels | What |
|---|---|---|---|
| `game_players_online` | gauge | — | players seated at a table (computed at scrape time from RoomManager) |
| `game_active_games` | gauge | — | tables with a hand in progress |
| `game_waiting_games` | gauge | — | tables with no hand (waiting / between hands) |
| `game_tables` | gauge | `category`, `stake` | open tables per lobby entry (`seen`/`blind` × boot amount) |
| `game_games_started_total` | counter | `category` | hands dealt |
| `game_games_completed_total` | counter | `category`, `reason` | hands with a winner; `reason` = `last_standing` `show` `forced_showdown` `pot_limit` |
| `game_games_abandoned_total` | counter | `category` | hands ended by `all_left` or a table destroyed mid-hand |
| `game_moves_total` | counter | `action` | accepted actions: `see` `chaal` `raise` `pack` `show` `sideshow` |
| `game_invalid_moves_total` | counter | `code` | refused actions by `GameError` code (`not_your_turn`, `invalid_bet`, `insufficient_chips`, `duplicate_action`, …) |
| `game_turn_timeouts_total` | counter | — | turns auto-packed by the 25 s clock |
| `game_kicks_total` | counter | `reason` | players removed by the server (`idle`, `unfunded`, …) |
| `game_chat_messages_total` | counter | — | chat messages posted |
| `game_pot_settled_chips_total` | counter | — | chips paid to winners |

### Latency histograms (Requirement 35d) — buckets `0.001 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1` s

| Metric | Labels | Measures |
|---|---|---|
| `game_move_processing_duration_seconds` | `action` | validate → ledger transaction → table update |
| `game_creation_duration_seconds` | — | opening a new table (quick-join with no room, or `room:create`) |
| `game_join_duration_seconds` | `route` | join request → seated and sent the snapshot (`quickJoin`, `joinCode`, `switch`, `create`) |
| `game_state_update_duration_seconds` | — | serialise per viewer + emit one table state change |
| `game_hand_start_duration_seconds` | — | collect boot + deal (one transaction) |
| `game_settlement_duration_seconds` | — | pay the winner |
| `game_db_transaction_duration_seconds` | `op` | the ledger transactions: `bet`, `boot`, `settle` |

Plus `game_db_transaction_errors_total{op,code}` (rolled back), and the pg pool gauges
`game_db_pool_connections`, `game_db_pool_idle_connections`, `game_db_pool_waiting_requests`.

### HTTP (Requirement 35f)

`game_http_requests_total{method,route,status_code}` and
`game_http_request_duration_seconds{method,route,status_code}` (same buckets). `route` is the
Express route *pattern* (`/api/auth/me/hands`), `static` for files, `unmatched` for 404s —
never a URL with an id in it. `/metrics` itself is not counted.

---

## Running the stack locally

Prerequisites on the host: Docker with the compose plugin; the game server running on
`0.0.0.0:3000`; PostgreSQL on 5432; optionally nginx with the stub_status server.

```bash
cd go-server/ops/monitoring
cp .env.example .env            # set GRAFANA_ADMIN_PASSWORD at least
docker compose up -d
docker compose ps               # five containers, all "running"
```

| URL | What |
|---|---|
| http://localhost:3001 | Grafana (admin / the password from `.env`); opens on the king-teenpatti dashboard |
| http://localhost:9090/targets | Prometheus target health — every job should be UP within 15 s |
| http://localhost:9090/alerts | rule state |

The containers reach the host through `host.docker.internal`, which compose maps to the gateway
of the fixed `172.30.0.0/24` network (`172.30.0.1`). Three host services have to accept
connections from that address, not only from loopback:

1. **The game server** — already does (`HOST=0.0.0.0`).
2. **PostgreSQL** — stock installs listen on `localhost` only. See
   [postgres_exporter](#postgres_exporter-requirement-35e) for `listen_addresses` and `pg_hba.conf`.
3. **nginx stub_status** — the example site binds `127.0.0.1:8080`; switch to `listen 8080;`
   with the allow-list for the docker case. See [nginx](#nginx-prometheus-exporter-requirement-35g).

If a target is DOWN, the reason is on `/targets`. `connection refused` is one of the three
items above; `401`/`403` is the token / IP allow-list on `/metrics`.

Useful operations:

```bash
docker compose logs -f prometheus grafana
curl -X POST localhost:9090/-/reload            # after editing prometheus.yml or alerts.yml
docker compose pull && docker compose up -d      # after bumping an image tag
docker compose down                              # keeps the data volumes
docker compose down -v                           # ...and deletes them
```

Prometheus retention is `PROMETHEUS_RETENTION` (default 15 d). The server produces on the order
of a thousand series (each histogram is 12 series per label combination; the HTTP ones grow with
the route × status combinations seen); at 15 s that is well under 1 GB per 15 days.

---

## Pointing Prometheus at production

Three ways, in order of preference:

1. **Run the stack on the production box** (the default config). Prometheus scrapes
   `host.docker.internal:3000` over the private bridge; `/metrics` never has to be reachable
   from the internet. Publish Grafana only on `127.0.0.1:3001` (the default) and reach it over
   an SSH tunnel (`ssh -L 3001:127.0.0.1:3001 host`) or put it behind nginx with auth.

2. **Scrape production from elsewhere over HTTPS.** Uncomment the `game-server-prod` job in
   `prometheus/prometheus.yml`, set `METRICS_TOKEN` on the server, write the same token to
   `prometheus/metrics_token` (git-ignored; mounted at `/etc/prometheus/metrics_token`), and
   open the `/metrics` location in `nginx/king-teenpatti.conf.example` to the scraper's IP.
   Both layers are needed — see the next section for why.

3. **Remote-write** from a Prometheus on the box to a hosted backend (Grafana Cloud, Mimir,
   Thanos): add a `remote_write:` block to `prometheus.yml`. The dashboard and alert rules
   work unchanged against any Prometheus-compatible datasource; import
   `grafana/dashboards/king-teenpatti.json` and pick the datasource in the `Prometheus` variable.

For the `postgres`/`nginx`/`node` jobs in production, either run the whole compose stack there
(option 1) or install the exporters as system packages (`prometheus-node-exporter`,
`prometheus-postgres-exporter`, `prometheus-nginx-exporter` on Debian/Ubuntu) and change the
targets to their addresses. The `nodename` label on the `node` job is free text — set it to the
machine's name so alert annotations read well.

---

## Securing /metrics

`/metrics` reveals player counts, error codes and stack sizes. It is open by default because
the intended scraper is on the same box. Before exposing port 3000 or the nginx `/metrics`
location to anything else:

- **`METRICS_TOKEN=<long random string>`** — the handler compares the `Authorization` header
  with `Bearer <token>` exactly; a wrong or missing header is a `401`. Generate one with
  `openssl rand -hex 32`. Prometheus sends it via `authorization.credentials_file`, never
  inline in the yml.
- **`METRICS_ALLOW_IPS=127.0.0.1,172.30.0.1`** — comma-separated exact addresses (no CIDR).
  IPv4-mapped IPv6 (`::ffff:127.0.0.1`) is normalised. A miss is a `403`, checked *before*
  the token.

  **Caveat behind nginx:** Express does not have `trust proxy` enabled, so `req.ip` for a
  proxied request is nginx's own address (`127.0.0.1`), whatever the real client is. Through
  the proxy the allow-list therefore cannot tell clients apart — restrict the nginx
  `location = /metrics` (`allow <scraper>; deny all;`) and rely on the token for the
  application layer. Direct scrapes of `:3000` on the private network are matched correctly.
- Keep the **`/metrics` nginx location** denied to the world (it is in the example config)
  even with a token set: this removes the endpoint from scanners entirely.
- Set `METRICS_ENABLED=false` on any instance that has no scraper (a staging copy on a laptop).

Restart the server after changing any of these — config is read once at start.

---

## Percentiles (P50 / P90 / P95 / P99)

Every histogram uses the same buckets, so the same query shape works for all of them.
Replace `Q` with `0.5`, `0.9`, `0.95` or `0.99`:

```promql
histogram_quantile(Q, sum by (le) (rate(<histogram>_bucket[5m])))
```

| Histogram | Dashboard panel | Per-label variant |
|---|---|---|
| `game_move_processing_duration_seconds` | Latency → Move processing latency (P50/P90/P95/P99) and the four stats | `sum by (le, action) (…)` → "Move P95 by action" |
| `game_creation_duration_seconds` | Latency → Game creation latency | — |
| `game_join_duration_seconds` | Latency → Game join latency | `sum by (le, route) (…)` → "Game join P95 by route" |
| `game_state_update_duration_seconds` | Latency → State update latency (P50/P95/P99) | — |
| `game_hand_start_duration_seconds` | Latency → Hand start & settlement P95 | — |
| `game_settlement_duration_seconds` | Latency → Hand start & settlement P95 | — |
| `game_db_transaction_duration_seconds` | Latency → DB transaction P95 by op | `sum by (le, op) (…)` |
| `game_http_request_duration_seconds` | Nginx → Node HTTP P95 by route | `sum by (le, route) (…)` |
| `game_server_nodejs_gc_duration_seconds` | Node.js → GC activity shows time share; quantiles with `sum by (le, kind)` | `sum by (le, kind) (…)` |

Spelled out for moves:

```promql
histogram_quantile(0.50, sum by (le) (rate(game_move_processing_duration_seconds_bucket[5m])))
histogram_quantile(0.90, sum by (le) (rate(game_move_processing_duration_seconds_bucket[5m])))
histogram_quantile(0.95, sum by (le) (rate(game_move_processing_duration_seconds_bucket[5m])))
histogram_quantile(0.99, sum by (le) (rate(game_move_processing_duration_seconds_bucket[5m])))
```

Things to know when reading them:

- `histogram_quantile` interpolates linearly inside a bucket, so a p99 of "0.18 s" means
  "between 0.1 and 0.25 s". Above the last bucket (1 s) it returns 1 s — the value is a floor.
- It returns `NaN` while the rate is zero (no moves in the window). Panels show a gap; that is
  correct, not broken.
- Averages: `rate(<h>_sum[5m]) / rate(<h>_count[5m])`. Throughput: `rate(<h>_count[5m])`.
- The dashboard uses fixed windows (`[1m]` for rates, `[5m]` for quantiles) rather than
  Grafana's `$__rate_interval`, so every expression on it can be pasted unchanged into
  the Prometheus UI or an alert rule. With a 15 s scrape a `[1m]` rate has four samples.
- Event-loop lag percentiles are **not** histograms: prom-client publishes them as ready-made
  gauges (`game_server_nodejs_eventloop_lag_p50/p90/p99_seconds`), plotted directly.

---

## Exporters

### node_exporter (System row)

Runs in host PID + network mode with `/proc`, `/sys` and `/` mounted read-only, so the
container reports the machine. Listens on host `:9100` — firewall it from the outside (`ufw
deny 9100` then allow from the compose subnet, or bind `NODE_EXPORTER_BIND=172.30.0.1`
once the network exists). Docker bridges and `veth` interfaces are excluded from the network
collectors so RX/TX show the real NIC.

Metrics used: `node_cpu_seconds_total`, `node_memory_*`, `node_filesystem_*`,
`node_network_{receive,transmit}_bytes_total`, `node_load{1,5,15}`, `node_filefd_*`,
`node_netstat_Tcp_CurrEstab`, `node_sockstat_TCP_*`, and its own `process_open_fds`.

### postgres_exporter (Requirement 35e)

Image `prometheuscommunity/postgres-exporter`, configured entirely by `DATA_SOURCE_NAME`.
Default collectors give everything the dashboard needs:

| Requirement 35e item | Metric (collector) |
|---|---|
| Active / idle connections | `pg_stat_activity_count{datname,state,…}` (`stat_activity`) — always `sum by (state)`, it also carries `usename`, `application_name`, `backend_type`, `wait_event*` |
| Connections | `pg_stat_database_numbackends{datname}` (`stat_database`) vs `pg_settings_max_connections` (`settings`) |
| Transactions | `pg_stat_database_xact_commit` / `xact_rollback` |
| Queries | no per-database statement counter exists in PostgreSQL; the dashboard plots `tup_returned` + `tup_fetched` per second as a proxy and says so in the panel. For real queries/sec enable `pg_stat_statements` (below) |
| Database size | `pg_database_size_bytes{datname}` (`database`) |
| Cache hit ratio | `blks_hit / (blks_hit + blks_read)` from `pg_stat_database_*` |
| Locks | `pg_locks_count{datname,mode}` (`locks`) |
| Deadlocks | `pg_stat_database_deadlocks` |
| Rows fetched / inserted / updated / deleted | `pg_stat_database_tup_fetched` / `tup_inserted` / `tup_updated` / `tup_deleted` |

**Database role.** Do not hand the exporter the superuser. Create a monitoring role once:

```sql
CREATE ROLE postgres_exporter LOGIN PASSWORD 'choose-a-password';
GRANT pg_monitor TO postgres_exporter;          -- pg_stat_*, pg_locks, pg_database_size()
GRANT CONNECT ON DATABASE gameplay TO postgres_exporter;
```

then `POSTGRES_EXPORTER_DSN=postgresql://postgres_exporter:choose-a-password@host.docker.internal:5432/gameplay?sslmode=disable`
in `.env`. `pg_monitor` (PostgreSQL ≥ 10) is enough for every default collector.

**Reachability from the container.** In `postgresql.conf` set `listen_addresses = '*'` (or
`'localhost,172.30.0.1'` — Postgres only warns if the docker address is absent at start) and
add to `pg_hba.conf`:

```
host  gameplay  postgres_exporter  172.30.0.0/24  scram-sha-256
```

then `systemctl reload postgresql`. Keep 5432 closed on the public interface (`ufw`). The
alternative that needs no Postgres change is running the exporter with `network_mode: host`
and `@127.0.0.1:5432` in the DSN; Prometheus then scrapes it at `host.docker.internal:9187`.

**pg_stat_statements (optional, true queries/sec).** In `postgresql.conf`
`shared_preload_libraries = 'pg_stat_statements'` (restart), then
`CREATE EXTENSION pg_stat_statements;` in `gameplay`, add `--collector.stat_statements` to the
exporter's `command:` in the compose file, and plot
`sum(rate(pg_stat_statements_calls_total{datname="gameplay"}[1m]))`. The collector emits one
series per `queryid`; it is bounded by `pg_stat_statements.max` (default 5000) — acceptable,
but watch the series count.

### nginx-prometheus-exporter (Requirement 35g)

Reads nginx's `stub_status` page and exposes:

| Requirement 35g item | Metric | Panel |
|---|---|---|
| Active connections | `nginx_connections_active` | Nginx → Active connections / Connection states |
| Reading | `nginx_connections_reading` | Nginx → Reading |
| Writing | `nginx_connections_writing` | Nginx → Writing (every open websocket sits here) |
| Waiting | `nginx_connections_waiting` | Nginx → Waiting |
| Requests | `nginx_http_requests_total` → `rate()` | Nginx → Requests/sec |
| Connections | `nginx_connections_accepted`, `nginx_connections_handled` | Nginx → Accepted vs handled/sec (`accepted − handled` = dropped) |
| up | `nginx_up` | Nginx → nginx stat |

**nginx side.** `nginx/king-teenpatti.conf.example` ends with a `server` on `127.0.0.1:8080`
serving `location = /stub_status { stub_status; }` behind an allow-list. Requires the
`http_stub_status_module` (`nginx -V 2>&1 | grep -o with-http_stub_status_module` — present in
every distro build). Test with `curl 127.0.0.1:8080/stub_status`:

```
Active connections: 1503
server accepts handled requests
 40212 40212 91877
Reading: 0 Writing: 1502 Waiting: 1
```

If the exporter runs in the compose stack it connects from `172.30.0.1`; change the bind to
`listen 8080;` and keep the `allow 172.30.0.0/24; deny all;` lines (they are already there).

**5xx errors.** `stub_status` has no per-status counters. The dashboard's "5xx errors/sec"
panel uses the application's `game_http_requests_total{status_code=~"5.."}`, which does *not*
see errors nginx generates itself — `502` when Node is down, `500 worker_connections are not
enough`, `504` upstream timeouts. Two ways to get those:

- **VTS module** (`nginx-module-vts`). Not in the distro packages; build nginx with
  `--add-dynamic-module=/path/to/nginx-module-vts` (or use a build that ships it, e.g. the
  OpenResty / Docker images that include it), then in `http {}`:
  `vhost_traffic_status_zone;` and a status server
  `location /status { vhost_traffic_status_display; vhost_traffic_status_display_format prometheus; }`.
  Scrape that location directly (no exporter needed) and use
  `sum(rate(nginx_vts_server_requests_total{code="5xx"}[1m]))`. Swap the expression in the
  `Nginx5xxRate` alert to the one in its comment.
- **Access-log exporter**: [`prometheus-nginxlog-exporter`](https://github.com/martin-helmich/prometheus-nginxlog-exporter)
  tails `/var/log/nginx/king-teenpatti.access.log` and exposes
  `nginx_http_response_count_total{status}`; plot `sum(rate(nginx_http_response_count_total{status=~"5.."}[1m]))`.
  No nginx rebuild; needs the log format it is told about.

**Capacity settings — read this before the next load test.** The 2026-09-08 ramp tests
(`loadtest-report/production-2026-09-08-run2/run3`) stalled at ~1,500 players twice: nginx
answered every new connection and Socket.IO handshake with HTTP 500 while Node sat at 3 % CPU.
`error.log` had `worker_connections are not enough`. Ubuntu ships `worker_connections 768`; with
4 workers that is 3,072 connections, and a proxied websocket costs **two** (client leg +
upstream leg to Node), so the ceiling was 768 × 4 ÷ 2 ≈ 1,500. The fix is in three files:

| File | Sets | Install |
|---|---|---|
| `nginx/nginx.conf.example` | `worker_rlimit_nofile 65536;` `events { worker_connections 16384; use epoll; multi_accept on; }` | merge into `/etc/nginx/nginx.conf`, `nginx -t`, `systemctl reload nginx` |
| `nginx/systemd/nginx-limits.conf` | `LimitNOFILE=65536` for nginx | `/etc/systemd/system/nginx.service.d/limits.conf`, `daemon-reload`, restart |
| `nginx/systemd/king-teenpatti-limits.conf` | `LimitNOFILE=65536` for Node | `/etc/systemd/system/king-teenpatti.service.d/limits.conf`, `daemon-reload`, restart |

Verify: `cat /proc/$(cat /run/nginx.pid)/limits | grep 'open files'` and
`curl -s localhost:3000/metrics | grep game_server_process_max_fds` both read 65536. Then set
`king_teenpatti:socket_limit` in `prometheus/alerts.yml` to the new real capacity (min of
nginx `workers × worker_connections ÷ 2`, Node's fd limit, and what a ramp test proved).
The dashboard's "Accepted vs handled/sec" panel and the `NginxDroppingConnections` alert show
this failure directly: `accepted − handled > 0`.

---

## The label-cardinality rule

Prometheus keeps one time series per unique label set, in memory, forever (until retention).
A label whose values grow with the player base — socket id, user id, room id, table code,
display name, raw URL, IP address — turns every player into a new series and eventually
kills Prometheus and Grafana together. The rule for this codebase, enforced in
`src/metrics/index.js`:

- **Every label has a small, fixed set of values** known when the code is written: an event
  name from the protocol table, an action from `constants.js`, a Socket.IO disconnect
  reason, a `GameError` code, an Express route *pattern*, an HTTP method, a status code, a
  table category, a boot amount from the lobby menu.
- **Anything else goes through `safeLabel(value, knownSet, 'other')`**, which folds unknown
  values into `"other"`. A new code path that produces an unplanned value costs one series,
  not one per value.
- **Never** a socket id, user id, room id, table code, display name, raw URL or IP. Not even
  hashed — a hash is still one series per player.
- **Routes** are `req.route.path` patterns (`/api/auth/me/hands`), `static` or `unmatched` —
  never `req.url`.
- Per-player or per-table detail belongs in logs (`logger.info('...', {meta})`) or the
  database, not in metrics.

Adding a metric: declare it in `src/metrics/index.js` with `registers: [registry]`, give it a
`help` string that says what one unit means, and if it has labels, add the known-value `Set`
next to it. Check the result:

```promql
count({__name__=~"game_.*"})                                   # total game series — on the order of 1,000, and it should plateau
topk(10, count by (__name__) ({__name__=~"game_.*"}))          # which metrics carry the most series
count(count by (event) (game_socket_messages_total))           # distinct label values of one label
```

A metric whose series count keeps rising over a day has a leaking label.

---

## The Grafana dashboard

`grafana/dashboards/king-teenpatti.json` — uid `king-teenpatti`, refresh 10 s, 7 rows /
91 panels, schemaVersion 39 (Grafana 11 migrates it forward on load). Provisioned from
`grafana/provisioning/dashboards/dashboards.yml` into the folder "King Teen Patti"; the file
is re-read every 30 s, so editing the JSON updates the live dashboard. UI edits are allowed but
live in Grafana's database until the file changes — export the JSON to keep them.

Variables: **Prometheus** (`$DS_PROMETHEUS`, datasource picker — every panel uses it) and
**PostgreSQL database** (`$datname`, default `gameplay`). There are deliberately no `job` /
`instance` variables: the server is one process, and adding the selectors would make the
expressions unusable outside Grafana. If a second instance ever appears, add an `instance`
variable and `{instance=~"$instance"}` to the `game_*` and `game_server_*` selectors.

Rows and what to look at first:

| Row | First glance | Then |
|---|---|---|
| System | CPU / RAM / Swap / Disk gauges | Open file descriptors vs the dashed limit; TCP established ≈ 2 × sockets |
| Runtime | Scheduler latency p99 (red line at 100 ms), heap live vs next-GC goal, goroutines (red line 50k) | CPU vs the dashed GOMAXPROCS line = the box is the bottleneck; GC pause time share; RSS vs runtime sys; open fds vs limit |
| WebSockets | Connected sockets vs peak, connections/sec | disconnections by reason (`ping timeout` spikes = network), errors by code |
| Multiplayer Game | Players online, active/waiting games | moves/sec by action, invalid moves by code, abandoned games |
| Latency | Move P50/P90/P95/P99 stats | DB transaction P95 by op — when moves slow down this says whether it is the database |
| PostgreSQL | pg_up, connections, cache hit ratio | transactions/sec against moves/sec; locks; the app-side pool's *waiting* line |
| Nginx | nginx_up, active connections vs the red worker line | accepted vs handled (dropped > 0 is the worker_connections failure); 5xx |

Orange "Game server restarted" annotations mark process restarts
(`changes(game_server_process_start_time_seconds[2m]) > 0`).

Regenerating: the JSON is plain, 2-space indented and hand-editable; validate with
`node -e "JSON.parse(require('fs').readFileSync('grafana/dashboards/king-teenpatti.json','utf8'))"`.

---

## The Logs dashboard (Loki)

`grafana/dashboards/king-teenpatti-logs.json` — uid `king-teenpatti-logs`, refresh 30 s, default
range 6 h, 5 rows / 24 panels, same folder as the metrics dashboard; the two link to each other
through the "King Teen Patti dashboards" drop-down (a `dashboards`-type link on the tag
`king-teenpatti`). Added 10 Sep 2026.

**Where the lines come from.** Production runs `loki.service` (Loki 3.7, `127.0.0.1:3100`, not
reachable from outside) and `alloy.service` (`/etc/alloy/config.alloy`), which reads
`journalctl -u gameplay` and ships every line as the stream `{service_name="gameplay"}` with labels
`host`, `job=loki.source.journal.gameplay`, `service`, `service_name` and Loki's `detected_level`.
Each line is the server's slog JSON exactly as `journalctl -u gameplay` shows it, so every query
starts `{service_name="gameplay"} | json` and then filters on the fields: `level`, `msg`, and the
attributes (`userId`, `roomId`, `code`, `provider`, `err`, `errors`, …). `msg` values are the
literal strings in the Go source (`grep -rhoE '\.(Info|Warn|Error)\("[^"]+"' internal cmd`).

| Row | Panels | What to read |
|---|---|---|
| Volume | Log lines · Warnings · Errors · Restarts · Logins refused · Reconcile passes with errors; Lines/min by level | The six stats are counts over the selected range. Errors > 0 or an unexplained restart is the thing to open. The per-minute floor is `live store reconciled` (every 30 s) plus bot-play's guest sign-ins. |
| Warnings & errors | WARN / ERROR per minute by message; the WARN/ERROR lines | Every warning as its own series, so a burst is named without scrolling. |
| Sessions & money | Logins/min by provider · Refused logins/min by code · Money events/min; Refused logins · Money events | `login refused` carries provider, code, status and the reason with the credential cut out — the first stop for a "Google sign-in does not work" report (`Wrong recipient` = app built with a different `GOOGLE_SERVER_CLIENT_ID`; `missing_token` = no idToken was sent). Money = purchases, rewards, deletions, ledger purges, and the two settlement edge cases (`table destroyed with a settlement still owed`, `late settlement landed after table destroyed`). |
| Server lifecycle | Starts & shutdowns · Tables/min by event · Live store: reconcile errors & failures; Lifecycle & live store lines | `gameplay build` opens every start, `shutting down` closes a SIGTERM stop; a start without a shutdown before it is a crash. The **Game server starts** annotation draws each start as a vertical line on every panel. |
| All logs | All logs | Driven by the variables **Level** (INFO/WARN/ERROR, multi), **Search** (regex over the whole line — a userId, a room code, an error text) and **Message** (regex over `msg`). |

**Importing.** Both dashboards were imported through the HTTP API rather than file provisioning
(`overwrite: true` replaces the dashboard with that uid in place). A one-off service-account token
(Administration → Users and access → Service accounts, role Editor) does it from anywhere through
nginx; revoke the token afterwards:

```bash
cd go-server/ops/monitoring
G=https://api.sungamestudio.com/dashboard
python3 -c 'import json,sys; json.dump({"dashboard": json.load(open(sys.argv[1])), "folderUid": "king-teenpatti-dashboards", "overwrite": True, "message": sys.argv[2]}, open("/tmp/import.json","w"))' \
  grafana/dashboards/king-teenpatti-logs.json "why"
curl --fail -sS -X POST -H "Authorization: Bearer $GRAFANA_TOKEN" -H 'Content-Type: application/json' \
  --data-binary @/tmp/import.json "$G/api/dashboards/db"; rm /tmp/import.json
```

Before committing a change, every LogQL expression in the file can be run against Loki on the
host (`curl -G 127.0.0.1:3100/loki/api/v1/query_range --data-urlencode 'query=…'`) with `$__auto`
→ `1m`, `$__range` → `6h`, `${level:regex}` → `(INFO|WARN|ERROR)`, `$search` → `` and `$msg` → `.*`.

---

## Alerts

`prometheus/alerts.yml`, evaluated every 15 s. `severity="critical"` means players are affected
now; `warning` means they will be if nothing changes. Alertmanager is not part of the compose
stack — uncomment the `alerting:` block in `prometheus.yml` to route these somewhere. Until
then they are visible at http://localhost:9090/alerts and the dashboard's threshold lines mirror
the same limits.

| Alert | Fires when | What it means / first move |
|---|---|---|
| **GameServerDown** | `up{job="game-server"} == 0` 1 m | Node is down or `/metrics` refuses us (token / IP). `systemctl status king-teenpatti`, `curl -i localhost:3000/metrics` |
| **GameServerSchedulerLatencyHigh** | Go scheduler latency p99 > 100 ms 5 m | Runnable goroutines are waiting for a CPU — every ack, broadcast and turn timer queues behind it. Check process CPU vs GOMAXPROCS, GC pause share, state-update latency |
| **GameServerGoroutinesHigh** | `game_server_go_goroutines` > 50,000 5 m | With flat sockets/tables this is a leak (a listener that never returns, an unstopped timer). `curl :3000/health` shows `process.goroutines`; profile before restarting |
| **GameServerSocketsNearLimit** / **AtLimit** | sockets > 85 % / 97 % of `king_teenpatti:socket_limit` | Capacity. Beyond it nginx returns 500 on handshakes or Node hits EMFILE. Raise limits (nginx section) or add a box |
| **GameServerHttp5xxRate** | 5xx > 5 % of REST responses with > 1 req/s, 5 m | Break down: `sum by (route) (rate(game_http_requests_total{status_code=~"5.."}[5m]))`; check DB |
| **GameServerMoveLatencyHigh** | move p99 > 0.5 s 5 m | A move is one ledger transaction: look at DB transaction P95 by op and the pool's waiting requests |
| **GameServerDbTransactionErrors** | any rollback rate for 5 m | `duplicate_action` = client retries (benign). Anything else: chips are not moving — server log, Postgres log |
| **GameServerDbPoolSaturated** | `game_db_pool_waiting_requests > 0` 2 m | All `PG_POOL_MAX` connections busy. Find the slow transaction (`pg_stat_activity_max_tx_duration`) or raise the pool |
| **GameServerMemoryHigh** | process RSS > 80 % of `king_teenpatti:host_memory_bytes` 10 m | Go has no heap limit unless `GOMEMLIMIT` is set; the OOM killer is next. Compare heap live bytes with players; `Environment=GOMEMLIMIT=6GiB` in the unit buys time |
| **GameServerFileDescriptorsHigh** | open / max fds > 0.8 5 m | Raise `LimitNOFILE` (systemd drop-in) before `accept()` fails |
| **PostgresDown** | `pg_up == 0` 1 m | DB down, or DSN / `pg_hba.conf` wrong for the exporter. Every move fails while true |
| **PostgresDeadlocks** | any deadlock in 5 m | The ledger locks wallets in ascending id order; a deadlock means new code takes locks out of order |
| **PostgresCacheHitRatioLow** | hit ratio < 0.9 for 15 m while reading > 1 blk/s | Working set > `shared_buffers`, or a scan without an index on `chip_ledger`/`hands` |
| **PostgresConnectionsNearMax** | > 80 % of `max_connections` 5 m | The game uses ≤ `PG_POOL_MAX`; find who else is connected (`pg_stat_activity`) |
| **PostgresLongTransaction** | a `gameplay` transaction open > 60 s for 2 m | Something is holding a wallet row lock; `pg_stat_activity` → `pg_terminate_backend` if it is not ours |
| **NginxDown** | `nginx_up == 0` 1 m | nginx down or stub_status server / allow-list wrong |
| **NginxDroppingConnections** | `accepted − handled > 0` 2 m | `worker_connections are not enough` — the 2026-09-08 failure. Apply `nginx.conf.example`, reload |
| **NginxConnectionsNearWorkerLimit** | active > 80 % of 4 × 16384 5 m | Change the constant with the config; raise before the previous alert fires |
| **Nginx5xxRate** | 5xx > 5 % behind nginx (application counter) | See the [nginx 5xx note](#nginx-prometheus-exporter-requirement-35g); switch the expression to VTS / log-exporter metrics when available |
| **HostHighCpu** | > 90 % 10 m | If `game_server_process_cpu_seconds_total` ≈ 1 core, Node is the bottleneck; else Postgres/other |
| **HostLowMemory** | < 10 % available 5 m | OOM killer will take the biggest process (Postgres or Node) |
| **HostDiskAlmostFull** | `/` > 85 % 10 m | Postgres stops writing when full; check `pg_database_size_bytes`, Prometheus retention, logs |
| **HostFileDescriptorsHigh** | `node_filefd_allocated / maximum > 0.8` 5 m | Raise `fs.file-max`; each websocket is an fd in nginx and another in Node |

Tunables: `king_teenpatti:socket_limit` (recording rule, default 12,000) and the nginx
worker constant `4 * 16384` — both commented in `alerts.yml`. After editing:
`promtool check rules prometheus/alerts.yml` (or `docker compose exec prometheus promtool check rules /etc/prometheus/alerts.yml`)
then `curl -X POST localhost:9090/-/reload`.

---

## Requirements checklist

### Requirement 35 — monitoring

**35a — Node.js default metrics** (prefix `game_server_`)

| Item | Metric |
|---|---|
| Process CPU usage | `game_server_process_cpu_seconds_total` (Node.js → CPU) |
| Process CPU user/system time | `game_server_process_cpu_user_seconds_total`, `game_server_process_cpu_system_seconds_total` (Node.js → CPU) |
| RSS memory | `game_server_process_resident_memory_bytes` (Node.js → RSS memory) |
| Heap total | `game_server_nodejs_heap_size_total_bytes` (Node.js → Heap total) |
| Heap used | `game_server_nodejs_heap_size_used_bytes` (Node.js → Heap used) |
| Heap limit | `game_server_nodejs_heap_size_limit_bytes` (Node.js → Heap limit stat, dashed line on Heap total) |
| External memory | `game_server_nodejs_external_memory_bytes` (Node.js → RSS memory) |
| ArrayBuffer memory | `game_server_nodejs_array_buffers_bytes` (Node.js → RSS memory) |
| Event-loop lag | `game_server_nodejs_eventloop_lag_seconds` + `_p50/_p90/_p99/_max` (Node.js → Event-loop lag) |
| Event-loop utilization | `game_server_nodejs_eventloop_utilization` (Node.js → Event-loop utilization) |
| Garbage collection | `game_server_nodejs_gc_duration_seconds{kind}` (Node.js → GC activity) |
| Active handles | `game_server_nodejs_active_handles_total` / `{type}` (Node.js → Active handles) |
| Active requests | `game_server_nodejs_active_requests_total` / `{type}` (Node.js → Active requests) |
| Process uptime | `game_server_process_uptime_seconds` (Node.js → Uptime) |
| Node.js version | `game_server_nodejs_version_info` (Node.js → Node.js version) |
| Process start time | `game_server_process_start_time_seconds` (Node.js → Started at; restart annotations) |
| Open file descriptors | `game_server_process_open_fds`, `game_server_process_max_fds` (System → Open file descriptors) |
| Prefix `game_server_` | `METRICS_PREFIX`, default `game_server_` |

**35b — Socket.IO metrics**

| Item | Metric / panel |
|---|---|
| Current connected sockets | `game_connected_sockets` (WebSockets → Connected sockets) |
| Total connections | `game_connections_total` |
| Total disconnections | `game_disconnections_total{reason}` |
| Connections per second | `rate(game_connections_total[1m])` (WebSockets → Connections/sec) |
| Disconnections per second | `sum by (reason) (rate(game_disconnections_total[1m]))` (WebSockets → Disconnections/sec) |
| Reconnects | `game_reconnects_total{kind}` (WebSockets → Reconnects/sec) |
| Socket errors | `game_socket_errors_total{code}` (WebSockets → Errors/sec) |
| Socket messages | `game_socket_messages_total{event}` (+ `game_socket_emits_total{event}`) (WebSockets → Messages/sec, Emits/sec) |
| Careful labels, no socket_id / user_id / game_id / IP | `event`, `reason`, `code`, `kind` only — see [the label rule](#the-label-cardinality-rule) |

**35c — Game metrics**

| Item | Metric / panel |
|---|---|
| Players currently online | `game_players_online` (gauge) — Multiplayer Game → Players online |
| Active games | `game_active_games` (gauge) — Active games |
| Waiting games | `game_waiting_games` (gauge) — Waiting games |
| Games started | `game_games_started_total{category}` (counter) — Games started/sec |
| Games completed | `game_games_completed_total{category,reason}` (counter) — Games completed/sec |
| Games abandoned | `game_games_abandoned_total{category}` (counter) — Games abandoned/sec |
| Moves processed | `game_moves_total{action}` (counter) — Moves/sec |
| Invalid moves | `game_invalid_moves_total{code}` (counter) — Invalid moves/sec |
| Reconnects | `game_reconnects_total{kind}` — WebSockets → Reconnects/sec |
| Gauges for state, counters for events | as above; the gauges are computed at scrape time from `RoomManager` |

**35d — Latency histograms** (buckets 0.001 … 1 s)

| Item | Histogram / panel |
|---|---|
| Move processing latency | `game_move_processing_duration_seconds{action}` — Latency → Move P50/P90/P95/P99 |
| Game creation latency | `game_creation_duration_seconds` — Latency → Game creation latency |
| Game join latency | `game_join_duration_seconds{route}` — Latency → Game join latency |
| Game state update latency | `game_state_update_duration_seconds` — Latency → State update latency |
| (extra) hand start, settlement, DB transactions | `game_hand_start_duration_seconds`, `game_settlement_duration_seconds`, `game_db_transaction_duration_seconds{op}` |
| P50 / P90 / P95 / P99 in Grafana | `histogram_quantile(Q, sum by (le) (rate(<h>_bucket[5m])))` — see [Percentiles](#percentiles-p50--p90--p95--p99) |

**35e — PostgreSQL** (postgres_exporter, not Node)

| Item | Metric / panel |
|---|---|
| Active connections | `pg_stat_activity_count{state="active"}` — PostgreSQL → Active connections |
| Idle connections | `pg_stat_activity_count{state=~"idle.*"}` — Idle connections |
| Transactions | `pg_stat_database_xact_commit` / `xact_rollback` — Transactions/sec |
| Queries | `tup_returned` + `tup_fetched` proxy — Queries/sec (proxy); `pg_stat_statements_calls_total` if enabled |
| Database size | `pg_database_size_bytes` — Database size |
| Cache hit ratio | `blks_hit / (blks_hit + blks_read)` — Cache hit ratio gauge + series |
| Locks | `pg_locks_count{mode}` — Locks (by mode) |
| Deadlocks | `pg_stat_database_deadlocks` — Deadlocks; `PostgresDeadlocks` alert |
| Rows fetched / inserted / updated / deleted | `pg_stat_database_tup_fetched/inserted/updated/deleted` — Rows/sec |
| Prefer postgres_exporter | `postgres-exporter` service in `docker-compose.yml`; Node only publishes its own pool gauges (`game_db_pool_*`) |

**35f — HTTP metrics**

| Item | Metric / panel |
|---|---|
| Request count | `game_http_requests_total{method,route,status_code}` |
| Request duration | `game_http_request_duration_seconds{method,route,status_code}` — Nginx → Node HTTP P95 by route |
| Response status | `status_code` label — Nginx → Node HTTP responses/sec by status class |
| Requests/sec | `sum(rate(game_http_requests_total[1m]))` — Nginx → Requests/sec |
| Errors/sec | `sum by (status_code) (rate(game_http_requests_total{status_code=~"5.."}[1m]))` — Nginx → 5xx errors/sec; `GameServerHttp5xxRate` alert |
| Controlled labels, route patterns not URLs | `routeLabel()` in `src/metrics/index.js` uses `req.route.path`; files → `static`, 404 → `unmatched` |

**35g — Nginx**

| Item | Metric / panel |
|---|---|
| Active connections | `nginx_connections_active` — Nginx → Active connections |
| Reading | `nginx_connections_reading` — Reading |
| Writing | `nginx_connections_writing` — Writing |
| Waiting | `nginx_connections_waiting` — Waiting |
| Requests | `nginx_http_requests_total` — Requests/sec |
| Connections | `nginx_connections_accepted` / `handled` — Accepted vs handled/sec |
| Exporter | `nginx-exporter` service + `stub_status` server in `nginx/king-teenpatti.conf.example`; 5xx options documented above |

### Requirement 36 — Grafana dashboard sections

| Section | Required display | Panel(s) |
|---|---|---|
| **System** | CPU % | gauge + "CPU %" series (`1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))`) |
| | RAM usage | gauge + "RAM usage" (used / cache+buffers / swap / total) |
| | Swap usage | "Swap usage" gauge (+ swap line in RAM usage) |
| | Disk usage | "Disk usage (root fs)" gauge |
| | Network RX / TX | "Network RX", "Network TX" (bits/s, physical NICs) |
| | Load average | "Load average" (1/5/15 + core count) |
| | Open file descriptors | "Open file descriptors" (game server, system, node_exporter, Node limit) |
| | TCP connections | "TCP connections" (`node_netstat_Tcp_CurrEstab`, time-wait, allocated) |
| **Node.js** | RSS memory | "RSS memory" stat + series |
| | Heap used / Heap total | "Heap used" stat + series; "Heap total" (+ limit) |
| | Heap utilization | "Heap utilization" (used/total, used/limit) |
| | CPU | "CPU" (`rate(game_server_process_cpu_seconds_total[1m])`, user, system) |
| | Event-loop lag | "Event-loop lag" (p50/p90/p99/max) |
| | Event-loop utilization | "Event-loop utilization" |
| | GC activity | "GC activity" (time share and runs/s by kind) |
| | Active handles / Active requests | "Active handles", "Active requests" |
| | Uptime | "Uptime" stat, unit s (+ version, started at) |
| **WebSockets** | Connected sockets | stat + "Connected sockets" series |
| | Peak connected sockets | "Peak connected sockets" stat (+ dashed line) |
| | Connections/sec | stat + "Connections/sec" |
| | Disconnections/sec | "Disconnections/sec (by reason)" |
| | Reconnects/sec | "Reconnects/sec" |
| | Messages/sec | stat + "Messages/sec (by event, top 10)" (+ Emits/sec) |
| | Errors/sec | "Errors/sec (by code)" |
| **Multiplayer Game** | Players online / Active games / Waiting games | three stats + "Players & games" |
| | Games started/sec | "Games started/sec" |
| | Games completed/sec | "Games completed/sec (by reason)" |
| | Games abandoned/sec | "Games abandoned/sec" |
| | Moves/sec | "Moves/sec (by action)" |
| | Invalid moves/sec | "Invalid moves/sec (by code)" |
| | (extra) | "Tables by category / stake", "Turn timeouts & kicks/sec", "Chat messages/sec & chips paid out/sec" |
| **Latency** | Move P50 / P95 / P99 | four stats (P50, P90, P95, P99) + "Move processing latency" |
| | Game creation P50/P95/P99 | "Game creation latency" (P50/P90/P95/P99) |
| | Game join P50/P95/P99 | "Game join latency" (P50/P90/P95/P99) |
| | (extra) | "Move P95 by action", "Game join P95 by route", "State update latency", "DB transaction P95 by op", "Hand start & settlement P95", "DB transaction errors/sec" |
| **PostgreSQL** | Connections | "Connections" stat + "Connections by state" |
| | Active connections / Idle connections | "Active connections", "Idle connections" stats |
| | Queries/sec | "Queries/sec (proxy)" — description explains the proxy and pg_stat_statements |
| | Transactions/sec | "Transactions/sec" (commit, rollback) |
| | Cache hit ratio | gauge + "Cache hit ratio" series |
| | Deadlocks | "Deadlocks" |
| | Locks | "Locks (by mode)" |
| | Database size | stat + "Database size" series |
| | (extra) | "PostgreSQL" up stat, "Rows/sec", "App-side pg pool" |
| **Nginx** | Active connections | stat + "Connection states" |
| | Requests/sec | stat + "Requests/sec" (nginx vs Node) |
| | Reading / Writing / Waiting | three stats + "Connection states" |
| | 5xx errors | "5xx errors/sec" (application counter; description explains VTS / log exporter for nginx-generated errors) |
| | (extra) | "nginx" up stat, "Accepted vs handled/sec", "Node HTTP responses/sec by status class", "Node HTTP P95 by route" |

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Target `game-server` DOWN, `connection refused` | server not running, or `HOST=127.0.0.1` — it must listen on `0.0.0.0` for the container to reach it |
| Target `game-server` DOWN, `server returned HTTP status 401/403` | `METRICS_TOKEN` set but no `authorization:` in the job (create `prometheus/metrics_token`, uncomment the block), or `METRICS_ALLOW_IPS` lacks `172.30.0.1` |
| Target `postgres` UP but `pg_up == 0` | exporter cannot log in: `listen_addresses`, `pg_hba.conf` line for `172.30.0.0/24`, or DSN password. `docker compose logs postgres-exporter` |
| Target `nginx` UP but `nginx_up == 0` | stub_status bound to `127.0.0.1` only (see [nginx](#nginx-prometheus-exporter-requirement-35g)), or the `deny all` hit: `docker compose logs nginx-exporter` |
| Target `node` DOWN | node_exporter not in host network mode, or `:9100` firewalled from the bridge |
| Latency panels empty / "No data" | no traffic in the window — `histogram_quantile` is NaN until the first move. Run `cd tools && npm install && npm run bot -- --count 3 --boot 200 --category blind` |
| `game_players_online` is 0 while people play | `BindRooms()` not called — only happens if `app.New()` was bypassed |
| Dashboard shows "Datasource not found" | the provisioned datasource uid is `prometheus`; pick another in the **Prometheus** variable if you imported the JSON elsewhere |
| `docker compose up` fails on `GRAFANA_ADMIN_PASSWORD` | copy `.env.example` to `.env` and set it — the compose file refuses to start with an empty password |
| Series count climbing steadily | a label leaking values: `topk(10, count by (__name__) ({__name__=~"game_.*"}))`, then check the `Set` passed to `safeLabel` for that metric |
| Server restarted and the config change did nothing | config is read once at startup — restart the server process (`sudo systemctl restart gameplay`, or find it with `ss -lptn 'sport = :3000'`) |
