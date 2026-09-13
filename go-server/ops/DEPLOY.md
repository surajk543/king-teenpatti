# Deploying the Go game server to production

Host `148.113.24.201` (`ssh deploy@148.113.24.201`), Ubuntu, 4 cores / 8 GB, checkout at
`/var/www/gameplay/king-teenpatti`. nginx proxies `api.sungamestudio.com` → `127.0.0.1:3000`;
Prometheus on the box scrapes `127.0.0.1:3000/metrics` (job `game-server`, bearer token);
Grafana at `https://api.sungamestudio.com/dashboard/` (dashboard uid `king-teenpatti`).

The Go binary runs **inside the same systemd unit the Node server used, `gameplay.service`**, on the
same port, with the same env keys — now read from `go-server/.env`. Nothing about nginx, Prometheus,
the journal or the database changes. The first-time installer also **removes the Node server tree
from the host** once the Go binary is healthy; the Node code stays in git history (`git log -- server/`,
last commit carrying it `c19963b`) and on the `multi_node` branch.
Everything below is run on the host as `deploy`; lines starting with `sudo` are the only ones that
need root. `/var/www/gameplay/king-teenpatti/steps.txt` is the whole routine in six lines.

Files in this directory:

| File | Run as | Purpose |
|---|---|---|
| `build.sh` | deploy | installs Go 1.27.1 into `~/.local/go` if needed (sha256 verified against go.dev), builds `go-server/bin/gameplay` |
| `gameplay-go.service` | — | the unit that `install-go-server.sh` installs as `gameplay.service` (`WorkingDirectory`, `EnvironmentFile` and `PUBLIC_DIR` all under `go-server/`) |
| `install-go-server.sh` | sudo, once | backs up the Node unit → `gameplay.service.node.bak`, copies `server/.env` → `go-server/.env` once, installs the Go unit under the same name, restarts, verifies `/health` and `/metrics`, then removes `server/` from the host (`KEEP_NODE_TREE=1` skips) |
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
- **The game is not playable from a browser in production.** `go-server/.env` carries
  `ROOT_REDIRECT=/dashboard/` (added 10 Sep 2026): `https://api.sungamestudio.com/` answers 302 to
  the Grafana login, the browser client's files and `/socket.io/socket.io.js` are 404, while
  `/privacy/`, `/account-deletion/` (linked from the Play listing) and `/profiles/*.svg` (the app's
  avatars) keep serving. Remove the line and restart to get the browser client back.
- **Sessions survive.** JWTs issued by Node (HS256) verify in Go and vice versa; nobody logs in again.
- **Restart behaviour is the Node one:** on SIGTERM the server closes the sockets, settles every
  live pot (first still-active seat wins, reason `all_left`), writes the ledger, exits within 8 s.
  Players come back to the lobby. Deploy in a quiet window, exactly as before.
- **WebSocket only.** `transport=polling` is refused with HTTP 400. Every shipped client (Flutter,
  browser, bots, ramptest) connects with websocket only, so nothing notices — but a stray
  `socket.io-client` default (polling first) would.
- **The Node server leaves the host.** `git pull origin master` removes `server/`'s tracked files;
  `install-go-server.sh` step 5 removes what `git` does not know about (`node_modules`, `.env`,
  logs) once `/health` reports the Go runtime. If `server/.env` differed from `go-server/.env` a copy
  is kept at `go-server/.env.node.bak`. `KEEP_NODE_TREE=1 sudo bash …/install-go-server.sh` leaves
  the directory alone. Node itself stays installed — the bots and the load ramp (`tools/`) need it.
- **Rollback goes to the previous Go tag, not to Node** (§5). The Node build cannot run against
  this schema any more, so `rollback-to-node.sh` was removed; `git checkout go-server/vX.Y.Z` +
  `build.sh` + restart is the way back.

---

## 1. Pre-flight — pull the code

```bash
ssh deploy@148.113.24.201
cd /var/www/gameplay/king-teenpatti
git checkout master               # the go-server branch was merged into master (PR #2); master is what runs
git pull origin master
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
`go-server/.env` may not exist yet — copy the live Node file over, which is exactly what the
installer would do:

```bash
cd /var/www/gameplay/king-teenpatti/go-server
[ -f .env ] || cp ../server/.env .env                                 # first time only
PORT=3999 HOST=127.0.0.1 PG_SCHEMA=test_smoke ./bin/gameplay &        # reads ./.env; PUBLIC_DIR defaults to ./public
sleep 2; curl -s 127.0.0.1:3999/health; kill %1
psql "$(sed -n 's/^DATABASE_URL=//p' .env)" -c 'drop schema test_smoke cascade'
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
cd /var/www/gameplay/king-teenpatti && git pull origin master
bash go-server/ops/build.sh
sudo systemctl restart gameplay
sudo systemctl status gameplay --no-pager
sudo journalctl -u gameplay -n 20 --no-pager
curl -s 127.0.0.1:3000/health | python3 -m json.tool | grep -E '"ok"|"node"|"players"'
```

The build writes `bin/gameplay` while the old binary is running — Linux keeps the old inode alive
until the restart, so building never disturbs the live process. Files under `go-server/public/`
are different: the running binary reads them from disk, so a pull that deletes one takes it away
before the restart. Keep the pull, the build and the restart back to back; §5 has the one such
release so far (Butterfly Flapping's move to Drive).

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

**Roll back to the previous Go release, not to Node.** Rolling back to Node stopped being possible
on 12 Sep 2026: `users.avatar_choice` — which the Node build reads and writes in three places — no
longer exists, the catalogue tables (`profile_pictures`, `user_profile_pictures`) are not in its
schema at all, and `server/` is long gone from the host. `rollback-to-node.sh` was removed rather
than left as a safety net with a hole in it; a recovery script that fails at the moment it is needed
is worse than none, because it implies a way back that is not there.

Releases are tagged (`go-server/vX.Y.Z`, see `../README.md` §Releasing), so going back one is a
checkout and a rebuild. One thing has to be settled **before** the checkout — who owns `users` — and
one is worth knowing first: going back to `go-server/v1.3.0` brings back a second Butterfly Flapping.
Both are explained below the commands. As `deploy`, no sudo needed until the restart:

```bash
cd /var/www/gameplay/king-teenpatti
git tag --list 'go-server/v*' --sort=-v:refname | head       # what there is to go back to
psql "$(sed -n 's/^DATABASE_URL=//p' go-server/.env)" -Atc "SET statement_timeout = '10s'" \
  -c "SELECT tableowner FROM pg_tables WHERE schemaname = 'public' AND tablename = 'users'"   # gameplay_app; postgres = §7 is applied, do its undo first
git diff --name-status HEAD go-server/v1.1.0 -- go-server/public/profiles    # a "D" line is a served picture the rollback deletes (none today)
git checkout go-server/v1.1.0                                # detached HEAD, on purpose
bash go-server/ops/build.sh                                  # stamps v1.1.0 into the binary
sudo systemctl restart gameplay                              # or: kill "$(systemctl show gameplay -p MainPID --value)"
bash go-server/ops/prod-version.sh                           # must now report v1.1.0
```

**Files the catalogue still points at can vanish.** A picture this server serves itself lives in
`go-server/public/profiles/`, which belongs to the checkout, while its catalogue row lives in the
database, which a rollback does not touch. The static handler reads that directory from disk, so a
file the older tag lacks is gone the moment that tag is checked out — before the restart — and its
row stays on sale: a player who buys it pays and gets the default avatar. No served picture is in that
position today — every file in `go-server/public/profiles/` exists in every tag, so the `git diff`
above prints nothing. If a later release adds one, put each "D" file back straight after the checkout
(`git show <the ref you left>:<path> > <path>`), before the build, and delete it again before
returning to the branch: git refuses to check out over an untracked file, even an identical one.

**Butterfly Flapping, and rolling back to `go-server/v1.3.0`.** v1.3.0 served Butterfly Flapping
itself, from `go-server/public/profiles/butterfly-flapping.json`. The release after it serves the
byte-identical file from Drive, deletes it from the checkout, and its V1.0.2 moves the catalogue row
to the Drive URL at boot — in place, so production's row keeps id 65, and every purchase and every
player wearing it stay on that id.

- **Back to `go-server/v1.2.0` or older: nothing to do.** Those builds have no V1.0.2, and the row
  they find already points at Drive, which needs no file on this host.
- **Back to `go-server/v1.3.0`** (or any untagged build between it and the move): the checkout
  brings the file back — v1.3.0 tracks it — so nothing 404s. But v1.3.0's V1.0.2 still seeds the old
  path, and with the row moved its `ON CONFLICT (asset_url)` no longer matches, so its first boot
  **inserts a second Butterfly Flapping** at `/profiles/butterfly-flapping.json` under a new id. What
  you see: the first query below answers two rows, and players see the picture twice on the Premium
  (Animated) shelf — the original (65, Drive) still owned and worn by whoever had it, and the
  duplicate locked for everyone and on sale at 4 diamonds.
- **What to run: nothing is required.** The next forward boot of any later build folds the duplicate
  into id 65: ownership rows and wearers move across (a player who bought both keeps the later rental
  plus whatever was left of the earlier one), the duplicate is deleted, and one row remains, on the
  Drive URL (`TestARollbackDuplicateOfButterflyFlappingFoldsIntoTheOriginalWithoutLosingOwnership`,
  `internal/db`). If the rollback will last long enough that you would rather nobody bought the
  duplicate meanwhile, retire it with the second query. It matches only an old-path row NEWER than
  the row at the Drive URL, so it can never retire the owned original, and it answers `UPDATE 0` when
  there is nothing to retire. v1.3.0's later boots leave a retired row
  alone (`ON CONFLICT DO NOTHING`), and the forward fold treats it exactly like an active one.

```bash
cd /var/www/gameplay/king-teenpatti
psql "$(sed -n 's/^DATABASE_URL=//p' go-server/.env)" -Atc "SET statement_timeout = '10s'" \
  -c "SELECT id, asset_url, is_active FROM profile_pictures WHERE name = 'Butterfly Flapping' ORDER BY id"   # two rows under v1.3.0; one (65, Drive URL) after the next forward boot
psql "$(sed -n 's/^DATABASE_URL=//p' go-server/.env)" -Atc "SET statement_timeout = '10s'" \
  -c "UPDATE profile_pictures SET is_active = FALSE WHERE asset_url = '/profiles/butterfly-flapping.json' AND id > (SELECT id FROM profile_pictures WHERE asset_url = 'https://drive.google.com/uc?export=download&id=19mQ9PjStBJUoFyThaSe97fEcfzARw_Ar')"   # optional, while v1.3.0 runs: UPDATE 1 retires the duplicate; UPDATE 0 = nothing to retire
```

Never `DELETE` the duplicate by hand: `user_profile_pictures` cascades on it and
`users.active_picture_id` is set to null, so whoever bought or wore it during the rollback would lose
it — which is exactly what the fold exists to avoid.

**The forward deploy that moves it has a short gap.** `git pull` deletes
`go-server/public/profiles/butterfly-flapping.json` from disk at once, while the running binary's
catalogue keeps handing out that path until the restart runs the new V1.0.2. For the length of the
build and the restart the path answers 404, so keep the three steps back to back. A phone that has
already downloaded the picture keeps drawing it from its own copy; only a phone meeting it for the
first time inside the gap draws the default avatar, until it next reads the catalogue. After the
restart every phone is handed the Drive URL — a new URL to its cache — and downloads the file once
more. One slower tail: a table restored from Redis keeps each seat's picture URL from its snapshot, so
a seated player wearing Butterfly Flapping keeps the old path on their seat — drawn by the phones that
have the file and as the default by the rest — until they sit down again or put the picture back on.

**Under §7, older tags cannot start.** Once `postgres` owns `users` (§7), every tag up to and
including `go-server/v1.3.0` fails at boot with `must be owner of table users`, because its baseline
creates `idx_users_last_login` without the ownership-proof lookup. That is what the owner query at the
top is for: if it answers `postgres`, hand `users` and its function back to `gameplay_app` first (the
undo in §7), then check out, build and restart, and run §7 again once a guarded build is back.

Then get back onto the branch when the fix is ready. From v1.3.0 the checkout removes
`butterfly-flapping.json` by itself — the tag tracks it and `master` does not — which opens the same
short 404 gap as the forward deploy above, until the restart. So build and restart straight after it:

```bash
git checkout master && git pull origin master
bash go-server/ops/build.sh
sudo systemctl restart gameplay                              # or: kill "$(systemctl show gameplay -p MainPID --value)"
bash go-server/ops/prod-version.sh                           # the release you came back to; its first boot folds any duplicate
```

**What a rollback does not undo.** The database is not versioned with the binary. Migrations run at
every boot and only ever add; an older binary against a newer schema is fine (it ignores columns it
does not know), but an older binary cannot remove a column a newer one added, and **nothing here
reverses a data change**. If a release altered data rather than code, say so in the release notes and
plan the reversal separately — through the ledger for anything touching money (`chip_ledger` is
append-only; a correction is a compensating row, never a DELETE). Butterfly Flapping's move is one
such change: no rollback puts the row back on the served path, and none needs to.

`go-server/.env` is also not versioned. A release that changed a key's meaning needs that key put
back by hand, or the old binary reads a value it does not expect.

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
| Checkout contents | `server/` + `go-server/` | `go-server/` + `tools/` (bots, ramp, parity); `server/` removed from `master` and from the host |
| Deploy routine | `git pull origin master && npm ci && systemctl restart` | `git pull origin master && bash go-server/ops/build.sh && systemctl restart` (`steps.txt`) |
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

## 7. Locking `users` rows to the superuser — one-time, sudo

Since 10 Sep 2026 the baseline migration installs a trigger, `users_no_delete`, that refuses every
`DELETE FROM users` (the server never issues one; the deletion route was removed the same day). It
lands on the next restart with no action needed. But the app role `gameplay_app` **owns** the table
and the trigger function, because it is the role that runs the migrations at every boot, and an owner
can disable a trigger. To make deleting a user something only a person with sudo on the host can do, hand both
to the `postgres` superuser once, and grant the app role back exactly what it uses.

**Check the build first.** Every release up to and including `go-server/v1.3.0` creates
`idx_users_last_login` with a bare `CREATE INDEX IF NOT EXISTS … ON users`. PostgreSQL checks that
the caller owns the table *before* it looks for the index, so those builds cannot start once
`postgres` owns `users` — `run V1.0.0__baseline.sql: ERROR: must be owner of table users` on every
restart, and systemd restarts it straight back into the same error. Apply this section only on a
checkout whose baseline carries the guarded statement — and, because the migrations are compiled into
`bin/gameplay` (`//go:embed`), only once the running server was built from that checkout. A grep of
the checkout says nothing about a binary built before the last `git pull`:

```bash
cd /var/www/gameplay/king-teenpatti
grep -c "indrelid = 'users'::regclass" go-server/internal/db/migration/V1.0.0__baseline.sql   # 1 = this checkout is guarded; 0 = stop
git describe --tags --match 'go-server/v*'                                                      # the checkout …
curl -s 127.0.0.1:3000/health | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'   # … and the running build: must be the same, else build.sh + restart first
```

```bash
sudo -u postgres psql gameplay <<'SQL'
ALTER FUNCTION users_immutable_rows() OWNER TO postgres;
ALTER TABLE users OWNER TO postgres;
GRANT SELECT, INSERT, UPDATE ON users TO gameplay_app;
GRANT REFERENCES ON users TO gameplay_app;
SQL
sudo systemctl restart gameplay
sudo journalctl -u gameplay -n 20 --no-pager     # "database ready" then "king-teenpatti server listening", once — not a restart loop
```

**Why REFERENCES.** The app role creates tables at boot, and creating a table with a foreign key to
`users` — `diamond_purchases` (V1.0.3) has one, and a later table may — needs the REFERENCES
privilege on `users`. An owner holds it implicitly; once `postgres` owns the table, `gameplay_app`
holds it only if granted. Its absence does not show on the day this section is run:
`CREATE TABLE IF NOT EXISTS` skips a table that already exists before it checks anything. It shows on
the first boot that has to *create* such a table — `permission denied for table users` — which is to
say in some later release. If `users` is already owned by `postgres` from a run of this section that
predates the REFERENCES line, run that one `GRANT` on its own now.

**What the restart proves, and what it does not.** A clean restart proves that the scripts in *this*
checkout boot under the new ownership. It proves nothing about the next release, which brings scripts
of its own: without the REFERENCES grant this restart is clean, and a release that adds a table
referencing `users` still crash-loops. What covers a checkout's scripts is
`TestTheAppRoleBootsTwiceBeforeAndAfterUsersIsHandedToTheSuperuser` (`internal/db`; needs a local
PostgreSQL superuser). It reads the SQL block above out of this file, applies it to a throwaway
schema, and boots every migration twice as a role that is not a superuser, before and after — then
twice more while re-creating `diamond_purchases` under the new ownership. Run it before deploying a
release that touches `users` or adds a table referencing it:

```bash
cd go-server && go test -count=1 -v -run UsersIsHandedToTheSuperuser ./internal/db | grep -E -- '--- (PASS|SKIP|FAIL)'   # must print PASS
```

It must print `--- PASS`. Without `-v`, a skipped test prints `ok` exactly like a passing one, and it
skips when PostgreSQL is unreachable, when the test connection is not a superuser, or when a new role
cannot log in with a password — a SKIP proves nothing.

If the restart fails anyway, give both objects back and restart; that is exactly the arrangement the
server ran under before this section:

```bash
sudo -u postgres psql gameplay -c 'ALTER TABLE users OWNER TO gameplay_app' -c 'ALTER FUNCTION users_immutable_rows() OWNER TO gameplay_app'
sudo systemctl restart gameplay
```

Verify, as the app role (the `DATABASE_URL` in `go-server/.env`):

```bash
psql "$(sed -n 's/^DATABASE_URL=//p' /var/www/gameplay/king-teenpatti/go-server/.env)" <<'SQL'
BEGIN; DELETE FROM users WHERE id = (SELECT id FROM users LIMIT 1); ROLLBACK;   -- ERROR: permission denied for table users
ALTER TABLE users DISABLE TRIGGER users_no_delete;                              -- ERROR: must be owner of table users
SQL
```

The `DELETE` never reaches the trigger: `gameplay_app` holds no DELETE privilege at all. The trigger
is the wall behind that one, for a role that does.

From then on, removing a row is deliberately three statements as `postgres`:

```sql
ALTER TABLE users DISABLE TRIGGER users_no_delete;
DELETE FROM users WHERE id = '…';        -- cascades into chip_ledger, whose own trigger will refuse it:
ALTER TABLE users ENABLE TRIGGER users_no_delete;   -- a player with ledger rows cannot be removed at all, by design
```

**Scripts that touch `users` from now on.** Every boot runs every migration as `gameplay_app`, and
PostgreSQL checks privileges before `IF NOT EXISTS`, so a statement that needs to own `users` fails
even when there is nothing left for it to do: `CREATE INDEX [IF NOT EXISTS] … ON users` (the baseline
did exactly this until `idx_users_last_login` was put behind a lookup), `ALTER TABLE users …`
(`ADD COLUMN IF NOT EXISTS` included), `COMMENT ON TABLE users`, and
`CREATE OR REPLACE FUNCTION users_immutable_rows()`; `CREATE TRIGGER … ON users` needs the TRIGGER
privilege, which is not granted either. Such a statement goes into its script behind a catalogue
lookup in a `DO` block — the pattern the baseline uses for `users_no_delete` and
`idx_users_last_login` — so a fresh database runs it and a handed-over one skips it. On production,
run the statement once as `postgres` before deploying the release, so the lookup finds the work
done. This is also why the trigger function is created only when missing rather than with
`CREATE OR REPLACE`. The test above fails on a script that forgets the lookup; it cannot fail on a
guarded statement whose work production has not done yet (it builds its schema as the owner first),
which is exactly why that one-off run as `postgres` comes before the deploy.

**Releases that need that one-off run, oldest first.** Only on a database this section has already
been applied to; where `gameplay_app` still owns `users` the boot does the work itself. Each statement
is idempotent, so running it twice, or on a database that already has the change, does nothing.

- **`V1.0.5__hammers.sql` (hammers and Force Sideshow, 13 Sep 2026)** adds `users.hammer`. Before
  deploying the first release that carries that script:

  ```bash
  sudo -u postgres psql gameplay <<'SQL'
  ALTER TABLE users ADD COLUMN IF NOT EXISTS hammer INTEGER NOT NULL DEFAULT 20 CHECK (hammer >= 0);
  SQL
  ```

  The `DEFAULT` gives every existing account its 20 hammers (the owner's decision); on PostgreSQL 11+
  a constant default is a catalogue change, not a table rewrite, so it holds the lock for a moment.
  `hammer_purchases` and `hammer_spends` need nothing by hand: the app role creates them at boot, and
  their foreign keys to `users` are what the `REFERENCES` grant above is for. Skip this and every
  restart fails with `run V1.0.5__hammers.sql: ERROR: must be owner of table users`.
  `TestTheAppRoleBootsTwiceBeforeAndAfterUsersIsHandedToTheSuperuser` reads this block out of this
  file and proves the release boots after it.

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
| Need the previous build now | §5 — `git checkout go-server/vX.Y.Z`, `build.sh`, restart. Node is not a rollback target any more: it cannot run against this schema. |

Reference: `go-server/README.md` (build/test/parity), `go-server/PORT_PLAN.md` §9 and
`go-server/DECISIONS.md` (every deliberate difference from Node),
`go-server/ops/monitoring/MONITORING.md` (metrics, dashboard, alert runbook), `CLAUDE.md` (repo-wide reference),
`steps.txt` (the six-line deploy routine).

## Database tuning (the production ceiling after the Go switch)

Measured on 8 Sep 2026 right after the switch (run 8, 4,000 players): the Go process used about
one core while the bet transaction p95 reached 0.8 s, the 50-connection pool was saturated and
the host showed 17% I/O wait at 930 commits/s. `pg_test_fsync` on the virtual disk gives ~650
fsyncs/s, and Postgres runs stock settings. Every move is a durable commit, so the disk's fsync
rate is the limit, for Node and Go alike.

`ops/tune-postgres.sh` applies the remedy in steps, each reversible:

```bash
sudo bash go-server/ops/tune-postgres.sh durable   # group commit; full durability kept; reload only
sudo bash go-server/ops/tune-postgres.sh fast      # + synchronous_commit=off (owner's call; read the warning in the script)
sudo bash go-server/ops/tune-postgres.sh memory    # shared_buffers 2GB etc.; restarts postgresql
sudo bash go-server/ops/tune-postgres.sh revert
```

Re-run the ramp after each step (`cd tools && npm run ramp -- --url https://api.sungamestudio.com --stages 1000,2000,3000,4000 --hold 75 --idOffset <new range> --out ramp.json`)
and compare `game_db_transaction_duration_seconds` p95 in Grafana. Beyond that, the fix is a
database on its own host or a faster disk.

## Live state (Redis)

The server keeps its live table state — snapshots, presence, turn deadlines and the matchmaking
index — in Redis, and its durable copy in PostgreSQL. See `../LIVE_STATE_PLAN.md` for the whole
design. Redis is **optional**: with `REDIS_URL` empty the server uses an in-process store and
behaves exactly as it did before, so a missing Redis never stops the game.

```bash
sudo bash go-server/ops/install-redis.sh      # install, configure, wire REDIS_URL, add the exporter
sudo systemctl restart gameplay               # pick up REDIS_URL
curl -s http://127.0.0.1:3000/health | python3 -m json.tool | grep -A4 '"live"'
redis-cli --scan --pattern 'kt:*' | head
```

What it buys, in one line each:

| Failure | Before | With Redis |
|---|---|---|
| Server restarted or crashed | every table and hand lost, seats gone | tables rebuilt, seats held for the reconnect grace, hands continue |
| Redis dies while the server runs | — | play is unaffected; the reconciler refills Redis when it returns |
| Redis and the server both die | — | nothing is rebuilt (PostgreSQL holds no game state): players re-join, and every open pot is refunded to its contributors (`game_refunded_pots_total`) |
| Neither store has the room | pot stranded | pot returned to its contributors, one idempotent ledger row each |

Chat is deliberately not durable: it lives only in Redis, so a room rebuilt from PostgreSQL comes
back with an empty chat history. Nothing else is lost, and no chip is ever at risk — every chip
movement is committed to PostgreSQL before the player is told the move succeeded.

Verify a deploy end to end with the acceptance test, which kills the server and wipes Redis for
real (run it against a scratch database, never production):

```bash
cd tools && npm install && npm run crashtest
```

Rollback: `sudo bash go-server/ops/install-redis.sh uninstall && sudo systemctl restart gameplay`.
