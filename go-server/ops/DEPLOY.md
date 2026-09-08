# Deploying the Go game server to production

Host `148.113.24.201` (`ssh deploy@148.113.24.201`), Ubuntu, 4 cores / 8 GB, checkout at
`/var/www/gameplay/king-teenpatti`. nginx proxies `api.sungamestudio.com` → `127.0.0.1:3000`;
Prometheus on the box scrapes `127.0.0.1:3000/metrics` (job `game-server`, bearer token);
Grafana at `https://api.sungamestudio.com/dashboard/` (dashboard uid `king-teenpatti`).

The Go binary runs **inside the same systemd unit the Node server used, `gameplay.service`**, on the
same port, with the same env keys — now read from `go-server/.env`. Nothing about nginx, Prometheus,
the journal or the database changes. The first-time installer also **removes the Node server tree
from the host** once the Go binary is healthy; the Node code stays on `master` and in git history.
Everything below is run on the host as `deploy`; lines starting with `sudo` are the only ones that
need root. `/var/www/gameplay/king-teenpatti/steps.txt` is the whole routine in six lines.

Files in this directory:

| File | Run as | Purpose |
|---|---|---|
| `build.sh` | deploy | installs Go 1.27.1 into `~/.local/go` if needed (sha256 verified against go.dev), builds `go-server/bin/gameplay` |
| `gameplay-go.service` | — | the unit that `install-go-server.sh` installs as `gameplay.service` (`WorkingDirectory`, `EnvironmentFile` and `PUBLIC_DIR` all under `go-server/`) |
| `install-go-server.sh` | sudo, once | backs up the Node unit → `gameplay.service.node.bak`, copies `server/.env` → `go-server/.env` once, installs the Go unit under the same name, restarts, verifies `/health` and `/metrics`, then removes `server/` from the host (`KEEP_NODE_TREE=1` skips) |
| `rollback-to-node.sh` | sudo | restores the Node unit from the backup, restarts, verifies — **after** the Node tree has been restored from `master` (it refuses otherwise) |
| `lib.sh` | — | helpers shared by the two sudo scripts (paths, health polling, `.env` reading) |
| `monitoring/` | — | Prometheus + Grafana + alerts + nginx bundle and `MONITORING.md` (formerly `server/ops/monitoring`) |

---

## 0. Before the first Go deploy — read once

- **Same keys, new file.** The binary reads `/var/www/gameplay/king-teenpatti/go-server/.env`
  twice (systemd `EnvironmentFile=` and godotenv from the working directory, which is the same
  file). `install-go-server.sh` copies the production `server/.env` there once if `go-server/.env`
  does not exist yet — `DATABASE_URL`, `JWT_SECRET`, `PG_POOL_MAX=50`, `METRICS_TOKEN`, … all apply
  unchanged. **Integer keys are parsed strictly** (`PG_POOL_MAX=50`, not `50 `); a malformed value
  stops the binary at startup with the key named in the journal. `PUBLIC_DIR` is set in the unit
  (`…/go-server/public`) so the browser client at `/` keeps working; `PG_STATEMENT_TIMEOUT_MS`
  (Go-only, default 15000) needs no line unless you want to change it.
- **Sessions survive.** JWTs issued by Node (HS256) verify in Go and vice versa; nobody logs in again.
- **Restart behaviour is the Node one:** on SIGTERM the server closes the sockets, settles every
  live pot (first still-active seat wins, reason `all_left`), writes the ledger, exits within 8 s.
  Players come back to the lobby. Deploy in a quiet window, exactly as before.
- **WebSocket only.** `transport=polling` is refused with HTTP 400. Every shipped client (Flutter,
  browser, bots, ramptest) connects with websocket only, so nothing notices — but a stray
  `socket.io-client` default (polling first) would.
- **The Node server leaves the host.** `git pull` on this branch removes `server/`'s tracked files;
  `install-go-server.sh` step 5 removes what `git` does not know about (`node_modules`, `.env`,
  logs) once `/health` reports the Go runtime. If `server/.env` differed from `go-server/.env` a copy
  is kept at `go-server/.env.node.bak`. `KEEP_NODE_TREE=1 sudo bash …/install-go-server.sh` leaves
  the directory alone. Node itself stays installed — the bots and the load ramp (`tools/`) need it.
- **Rollback is two steps now** (§5): restore the Node tree from `master`, then
  `rollback-to-node.sh` (~10 s once the tree is back).

---

## 1. Pre-flight — pull the code

```bash
ssh deploy@148.113.24.201
cd /var/www/gameplay/king-teenpatti
git fetch origin
git checkout go-server            # until go-server is merged into master; afterwards: git checkout master
git pull
git log --oneline -1              # note the hash — build.sh stamps it into the binary
```

No `npm ci` in the deploy path any more: the binary is self-contained. The bots and the ramp
(`tools/`) are optional and have their own `npm install` (§4).

## 2. Build (deploy user, no sudo)

```bash
cd /var/www/gameplay/king-teenpatti/go-server
bash ops/build.sh
```

First run: downloads `go1.27.1.linux-amd64.tar.gz` (~75 MB), verifies its sha256 against
`https://go.dev/dl/?mode=json`, unpacks into `~/.local/go` (nothing outside `$HOME`, no root).
Later runs find that toolchain and skip straight to the build (~20 s cold, ~3 s warm). Output:

```
==> Built
    size  16M  /var/www/gameplay/king-teenpatti/go-server/bin/gameplay
    …: ELF 64-bit LSB executable, x86-64, … statically linked, … stripped
    gameplay <git describe> go1.27.1 linux/amd64
```

`bin/` is git-ignored; the binary is static (CGO off) — no shared libraries, no Go on the host at
run time. Optional smoke test on a spare port with a throwaway schema (does not touch production
data — it creates and uses schema `test_smoke`, drop it afterwards). Before the first install
`go-server/.env` may not exist yet; point the smoke test at the old file in that case:

```bash
cd /var/www/gameplay/king-teenpatti/go-server
ENV=./.env; [ -f "$ENV" ] || ENV=../server/.env                      # first time only: the Node file is still the live one
set -a; . "$ENV"; set +a
PORT=3999 HOST=127.0.0.1 PG_SCHEMA=test_smoke ./bin/gameplay &        # PUBLIC_DIR defaults to ./public here
sleep 2; curl -s 127.0.0.1:3999/health; kill %1
psql "$DATABASE_URL" -c 'drop schema test_smoke cascade'
```

## 3. Install / switch the unit (sudo, first time only)

```bash
sudo bash /var/www/gameplay/king-teenpatti/go-server/ops/install-go-server.sh
```

It refuses to run if `bin/gameplay` is missing, copies `server/.env` → `go-server/.env` if the
latter is absent (the old file is left in place for now), backs up
`/etc/systemd/system/gameplay.service` to `gameplay.service.node.bak` (once — never overwritten),
prints the unit diff so you can check no `Environment=` line you relied on is lost, installs
`gameplay-go.service` **as `gameplay.service`**, `daemon-reload`, `restart`, then waits for
`http://127.0.0.1:3000/health` to answer with `process.node = "go1.27.1"` and checks `HEAD /metrics`
with the `METRICS_TOKEN` from `.env` → `200`. It prints `systemctl status` and the last 20 journal
lines, and **then removes `/var/www/gameplay/king-teenpatti/server`** (step 5; keeping a
`go-server/.env.node.bak` if the two `.env` files differed). Expected journal head:

```
{"level":"INFO","msg":"gameplay build","version":"<hash>","go":"go1.27.1"}
{"level":"INFO","msg":"database ready","url":"postgres://…:***@…","schema":"public"}
{"level":"INFO","msg":"king-teenpatti server listening","url":"http://0.0.0.0:3000","env":"production",…}
```

Re-running the script is harmless (re-installs, restarts, re-verifies; step 5 is a no-op once the
directory is gone).

### Every later deploy

Once the unit points at the Go binary, the routine is the old one with the build step swapped in
(this is `steps.txt`):

```bash
cd /var/www/gameplay/king-teenpatti && git pull
bash go-server/ops/build.sh
sudo systemctl restart gameplay
sudo systemctl status gameplay --no-pager
sudo journalctl -u gameplay -n 20 --no-pager
curl -s 127.0.0.1:3000/health | python3 -m json.tool | grep -E '"ok"|"node"|"players"'
```

The build writes `bin/gameplay` while the old binary is running — Linux keeps the old inode alive
until the restart, so building never disturbs the live process.

## 4. Verify

**Health** — `process.node` must start with `go`; `goroutines`/`numCpu`/`gomaxprocs` are Go-only extras:

```bash
curl -s 127.0.0.1:3000/health | python3 -m json.tool
curl -s https://api.sungamestudio.com/health | python3 -c 'import json,sys; h=json.load(sys.stdin); print(h["ok"], h["process"]["node"], h["players"], "players")'
```

**Metrics — scrape by hand, then confirm Prometheus sees the target as `up`:**

```bash
TOKEN=$(sed -n 's/^METRICS_TOKEN=//p' /var/www/gameplay/king-teenpatti/go-server/.env)
curl -s -H "Authorization: Bearer $TOKEN" 127.0.0.1:3000/metrics | grep -c '^game_'            # > 0
curl -s -H "Authorization: Bearer $TOKEN" 127.0.0.1:3000/metrics | grep '^game_server_go_info'  # version="go1.27.1"
curl -s -H "Authorization: Bearer $TOKEN" 127.0.0.1:3000/metrics | grep -c '^game_server_nodejs_' # 0 — expected
curl -s 127.0.0.1:9090/api/v1/targets | python3 -c '
import json,sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print(f"{t[\"labels\"][\"job\"]:14} {t[\"scrapeUrl\"]:45} {t[\"health\"]:5} {t.get(\"lastError\",\"\")}")'
```

`game-server … up` with an empty last error is what you want. If it says `401`, the token in
`.env` and the one Prometheus sends (`authorization.credentials_file`) differ — same fix as with Node.

**Grafana** — open the dashboard; the "Runtime" row (the former "Node.js" row) fills within one
scrape interval. The game rows (WebSockets, Multiplayer Game, Latency) show the same series as
before because the `game_*` names are identical. If the row is still the old "Node.js" one, the
dashboard JSON has not been re-imported yet — §6.

**Real traffic — three bots for a minute** (they log in as guests, sit at a blind 200 table, play,
chat, sideshow; Ctrl-C to stop; they leave cleanly). The bots are a small Node package under
`tools/`; `npm install` there once (Node ≥ 20 is still on the host):

```bash
cd /var/www/gameplay/king-teenpatti/tools && npm install
npm run bot -- --url https://api.sungamestudio.com --count 3 --boot 200 --category blind
```

Watch `journalctl -u gameplay -f` in a second terminal: a `table created` line when they sit, no
`ERROR` lines, and `/health` shows `players: 3`, `activeHands: 1`. Then the Flutter app on a
phone: login, lobby, a hand, chat, leave.

**Money — the ledger must reconcile to the wallets (CLAUDE.md §4). Must print `0`:**

```bash
psql "$(sed -n 's/^DATABASE_URL=//p' /var/www/gameplay/king-teenpatti/go-server/.env)" -Atc \
  "select count(*) from users u join (select user_id, sum(delta) s from chip_ledger group by user_id) l on l.user_id=u.id where l.s <> u.chips"
```

Also worth a glance after the first hands: the newest ledger rows carry the app's uuid
`action_id` for bets and `<handId>:boot:<userId>` / `<handId>:settle:<userId>` for boots and settlements:

```bash
psql "$(sed -n 's/^DATABASE_URL=//p' /var/www/gameplay/king-teenpatti/go-server/.env)" -c \
  "select reason, delta, action_id, to_timestamp(created_at/1000) from chip_ledger order by id desc limit 10"
```

## 5. Rollback

The Node server is no longer in the checkout (this branch removed it, and `install-go-server.sh`
removed the untracked residue from the host), so a rollback first puts the tree back — as `deploy`,
never as root — and only then swaps the unit:

```bash
cd /var/www/gameplay/king-teenpatti
git checkout master -- server && (cd server && npm ci --omit=dev)     # the Node tree, from master
cp go-server/.env server/.env                                          # the Node unit reads server/.env (or use go-server/.env.node.bak)
sudo bash /var/www/gameplay/king-teenpatti/go-server/ops/rollback-to-node.sh
```

`rollback-to-node.sh` refuses to run until `server/src/index.js`, `server/.env` and
`server/node_modules` exist, and says exactly that. It then restores `gameplay.service` from
`gameplay.service.node.bak`, `daemon-reload`, `restart`, waits for `/health` to report
`process.node` starting with `v` (Node; an older Node build without the `process` key also passes),
prints `HEAD /metrics`, status and journal. The backup is kept, so `install-go-server.sh` can switch
back to Go later (and will remove `server/` again unless `KEEP_NODE_TREE=1`). Afterwards
`git status` shows `server/` as staged additions on this branch — `git restore --staged server && rm -rf server`
undoes that once Go is back.

Prometheus and Grafana need nothing for a rollback: the game rows work for both servers and the
Runtime row simply goes empty while Node runs (Node's `nodejs_*` panels are gone from the JSON; the
old dashboard is in git history if you ever want it back).

## 6. Monitoring changes — one-time, after the first Go deploy

### What changes for ops

| | Node | Go |
|---|---|---|
| Port / unit | `127.0.0.1:3000`, `gameplay.service` | **same** |
| Env file | `server/.env` | `go-server/.env` (copied once by the installer; same keys) |
| Working directory / browser client | `server/`, `server/public` | `go-server/`, `go-server/public` (`PUBLIC_DIR` in the unit) |
| Checkout contents | `server/` + `go-server/` | `go-server/` + `tools/` (bots, ramp, parity); `server/` removed from the host |
| Deploy routine | `git pull && npm ci && systemctl restart` | `git pull && bash go-server/ops/build.sh && systemctl restart` (`steps.txt`) |
| Monitoring bundle | `server/ops/monitoring/` | `go-server/ops/monitoring/` |
| `game_*` metrics (sockets, game, latency, HTTP, pool) | | **identical names, labels, buckets** |
| Process metrics | `game_server_process_*` + `game_server_nodejs_*` | `game_server_process_*` + `game_server_go_*`; **no `nodejs_*` series** |
| Event-loop lag | `game_server_nodejs_eventloop_lag_p99_seconds` | scheduler latency `histogram_quantile(0.99, sum by (le) (rate(game_server_go_sched_latencies_seconds_bucket[5m])))` |
| Heap | `nodejs_heap_size_used/total/limit` | `go_memstats_heap_alloc/inuse/sys_bytes`, `go_gc_heap_live/goal_bytes`; no hard limit unless `GOMEMLIMIT` is set |
| GC | `nodejs_gc_duration_seconds{kind}` | `go_gc_duration_seconds` (summary), `go_sched_pauses_total_gc_seconds` (histogram) |
| Runtime version | `nodejs_version_info{version}` | `go_info{version}`; `/health process.node` = `go1.27.1` |
| Concurrency | one event loop, ~1 core | `GOMAXPROCS` = all 4 cores by default (dashboard CPU panel shows the ceiling as a dashed line) |
| Transport | websocket + polling | websocket only (polling → 400) |
| DB pool | `PG_POOL_MAX=50` | **stays 50** (pgxpool; `game_db_pool_waiting_requests` is an acquire-wait delta, usually 0); `PG_STATEMENT_TIMEOUT_MS=15000` default |
| Alerts | `GameServerEventLoopLagHigh`, `GameServerEventLoopSaturated`, `GameServerHeapNearLimit` | `GameServerSchedulerLatencyHigh` (p99 > 100 ms 5 m), `GameServerGoroutinesHigh` (> 50,000 5 m), `GameServerMemoryHigh` (RSS > 80 % of `king_teenpatti:host_memory_bytes` 10 m) |

### Re-import the dashboard (Grafana HTTP API)

The dashboard was imported through the API, not file provisioning, so the edited JSON has to be
posted again. `overwrite: true` replaces the dashboard with uid `king-teenpatti` in place (same
URL, same folder). `-u admin` makes curl **prompt** for the password — nothing is stored anywhere.
Run on the host if Grafana listens only on localhost (`GRAFANA=http://127.0.0.1:3001`), or through
nginx from anywhere (`GRAFANA=https://api.sungamestudio.com/dashboard`):

```bash
cd /var/www/gameplay/king-teenpatti/go-server/ops/monitoring
GRAFANA=https://api.sungamestudio.com/dashboard          # or http://127.0.0.1:3001
python3 -c 'import json,sys; json.dump({"dashboard": json.load(open(sys.argv[1])), "overwrite": True, "message": "Go runtime row"}, open(sys.argv[2], "w"))' \
  grafana/dashboards/king-teenpatti.json /tmp/king-teenpatti-import.json
curl -u admin --fail -sS -X POST -H 'Content-Type: application/json' \
  --data-binary @/tmp/king-teenpatti-import.json "$GRAFANA/api/dashboards/db"
rm /tmp/king-teenpatti-import.json
```

Expected: `{"id":…,"slug":"king-teen-patti-…","status":"success","uid":"king-teenpatti","url":"/d/king-teenpatti/…","version":N}`.
Reload the dashboard page; the second row is now "Runtime". (`412 … version-mismatch` cannot
happen with `overwrite:true`; `401` = wrong password; `404` = wrong `GRAFANA` sub-path — the
API lives under the same root as the UI, so `…/dashboard/api/dashboards/db` behind nginx.)

### Reload the alert rules

```bash
grep -A3 '^rule_files' /etc/prometheus/prometheus.yml           # where does the host's Prometheus read its rules from?
# if it points at a copy rather than at the checkout:
sudo cp /var/www/gameplay/king-teenpatti/go-server/ops/monitoring/prometheus/alerts.yml /etc/prometheus/alerts.yml
promtool check rules /etc/prometheus/alerts.yml                  # "SUCCESS: 26 rules found"
sudo systemctl reload prometheus
curl -s 127.0.0.1:9090/api/v1/rules | python3 -c 'import json,sys; print(sorted(r["name"] for g in json.load(sys.stdin)["data"]["groups"] for r in g["rules"] if r["type"]=="alerting"))'
```

If Prometheus reads its rules from the checkout by path, the path has moved: point `rule_files` at
`/var/www/gameplay/king-teenpatti/go-server/ops/monitoring/prometheus/alerts.yml` (it used to be
under `server/ops/monitoring/`). The list must contain `GameServerSchedulerLatencyHigh`,
`GameServerGoroutinesHigh`, `GameServerMemoryHigh` and no `EventLoop`/`HeapNearLimit` names. The
recording rule `king_teenpatti:host_memory_bytes` takes RAM from node_exporter (job `node`) and falls
back to 8 GiB when that job is absent — edit the constant in `alerts.yml` if the box changes.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `install-go-server.sh`: "bin/gameplay is missing" | run `bash ops/build.sh` as `deploy` first |
| `install-go-server.sh`: "`go-server/.env` not readable" | neither `go-server/.env` nor the old `server/.env` exists — copy the production `.env` to `go-server/.env` |
| journal: `config: PG_POOL_MAX: …` (or any key) at startup | strict integer/enum parsing of `.env`; fix the value, `sudo systemctl restart gameplay` |
| journal: `JWT_SECRET must be set in production` | `.env` lacks `JWT_SECRET` (Node used the same key) — the unit sets `NODE_ENV=production` |
| `/health` never answers, unit flaps every 2 s | port 3000 still held by the old process for a few seconds — normal; if it lasts, `ss -lptn 'sport = :3000'` |
| `/metrics` → `401` from the install script | `METRICS_TOKEN` in `.env` has quotes/spaces Node tolerated; the script strips quotes — check the raw line |
| Browser client at `/` is a `Cannot GET /` 404 | `PUBLIC_DIR` in the unit does not exist; `ls /var/www/gameplay/king-teenpatti/go-server/public` |
| Prometheus: `rule_files` path not found after the pull | the bundle moved to `go-server/ops/monitoring/`; fix the path or copy `alerts.yml` (§6) |
| Grafana Runtime row empty, game rows fine | dashboard not re-imported (§6), or Prometheus target down (`/api/v1/targets`) |
| `game_server_nodejs_*` panels wanted back | they only exist while Node runs; the pre-Go dashboard is in git history (`git log -- server/ops/monitoring/grafana/dashboards/king-teenpatti.json`) |
| `rollback-to-node.sh`: "`server/src/index.js` is missing" | expected on this branch — restore the tree first (§5): `git checkout master -- server && (cd server && npm ci --omit=dev)` |
| Need Node back now | §5 — restore the tree, then `sudo bash go-server/ops/rollback-to-node.sh` |

Reference: `go-server/README.md` (build/test/parity), `go-server/PORT_PLAN.md` §9 and
`go-server/DECISIONS.md` (every deliberate difference from Node),
`go-server/ops/monitoring/MONITORING.md` (metrics, dashboard, alert runbook), `CLAUDE.md` (repo-wide reference),
`steps.txt` (the six-line deploy routine).
