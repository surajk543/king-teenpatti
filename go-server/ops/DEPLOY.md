# Deploying the Go game server to production

> **The current routine (29 Sep 2026).** Production is **`prod.sungamestudio.com` → `129.121.135.218`**
> (`game-server-01`), PostgreSQL 16.15, and it runs a **tag**. The operator is **`write`**, the checkout's owner,
> who deploys with **one command inside `tmux`**: `bash go-server/ops/deploy.sh [go-server/vX.Y.Z]` (§3 "One-command
> deploy"; `steps.txt` is the short form). A rollback is `deploy.sh go-server/v<previous> --allow-downgrade`. The
> sections below keep the history of how the host was set up — against the preprod box `148.113.24.201` and the old
> `api.sungamestudio.com`, as `deploy`, by `git pull origin master` — read them for the facts they record, not as
> the commands to run today.

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
| `deploy.sh` | the checkout's owner (`write`), no `sudo` in front, inside `tmux` | **every deploy since 29 Sep 2026** (§3 "One-command deploy"): log and lock, fetch, the release tag checked out and built, `gameplay -migrate` with the new binary, restart, `/health` checked and watched — rolled back when it fails; refuses a tag older than what runs without `--allow-downgrade`, and one older than `go-server/v1.7.0` always |
| `lib.sh` | — | helpers shared by the sudo scripts and `deploy.sh` (paths, health polling, `.env` reading) |
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
  live pot (first still-active seat wins, reason `all_left`), writes the ledger, exits within its
  budget — 8 s in Node; since 24 Sep 2026 `max(8 s, PG_STATEMENT_TIMEOUT_MS + 5 s)`, 20 s on the
  default 15 s statement timeout, so an actor stuck in a stalled write still settles its pot (a budget
  that runs out logs `shutdown budget ran out; rooms abandoned` with the room ids). The unit's
  `TimeoutStopSec` went from 15 to **30** to stay above it: the installed unit is a copy, so on a host
  installed before that run `sudo cp go-server/ops/gameplay-go.service /etc/systemd/system/gameplay.service
  && sudo systemctl daemon-reload` once. Players come back to the lobby. Deploy in a quiet window,
  exactly as before.
- **`JWT_SECRET` must be at least 32 bytes in production** (24 Sep 2026): `NODE_ENV=production`
  refuses to boot on an empty or shorter secret, not only on the default. Check the `.env` BEFORE the
  restart (`grep -c '^JWT_SECRET=.\{32,\}' go-server/.env` must print 1); a new one is
  `openssl rand -hex 32` — changing it signs every player out once.
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

### One-command deploy (deploy.sh)

Since 29 Sep 2026 (owner: "a script whenever i run it applies all ddl/dml from migration folder and then it takes latest
pull and deploy backend tag") one command on the host does the whole routine — the pull, the tag, the build, the
migrations, the restart — and checks every step:

```bash
tmux new -A -s deploy                                                              # FIRST: a session a dropped ssh cannot end
bash /var/www/gameplay/king-teenpatti/go-server/ops/deploy.sh --dry-run            # what it would do; changes nothing
bash /var/www/gameplay/king-teenpatti/go-server/ops/deploy.sh                      # the newest go-server/v* tag
bash /var/www/gameplay/king-teenpatti/go-server/ops/deploy.sh go-server/v1.11.0    # that tag (v1.11.0 or 1.11.0 read the same)
bash /var/www/gameplay/king-teenpatti/go-server/ops/deploy.sh --force              # restart even if /health already reports the tag
bash /var/www/gameplay/king-teenpatti/go-server/ops/deploy.sh go-server/v1.10.2 --allow-downgrade   # a rollback, after reading §5
```

Run it as the operator who owns the checkout (`write` on game-server-01), from any directory, **never with `sudo` in
front** (it refuses root: a root build leaves root-owned files in `bin/` and uses root's Go), and **inside `tmux` or
`screen`** (below). It asks sudo itself — up front, before the build — for the three steps that need it: the migration
as the service's user, the restart, and the journal when a restart goes wrong; and it refreshes that right before the
migration and again before the restart, so **sudo may ask for the password once more** when the build ran past sudo's
timeout (15 minutes by default — the first run as `write` downloads Go 1.27.1 and every module into `write`'s home, since
`build.sh` as `deploy` filled `deploy`'s, and takes longer than any later one). Everything it prints also goes to
`.git/deploy-logs/deploy-<UTC time>-<pid>.log` (the last 20 runs are kept), named at the top of the run and again at its
end. In order:

1. **Log and lock** — the log above, then `flock` on `.git/deploy.lock`; a second deploy is refused while one runs, and
   the file says who holds it. If the pid it names no longer exists, a process that run started still holds the lock (a
   `git gc` a fetch left running in the background, say — every child that could outlive the script is started without
   the lock's descriptor, so this should not happen): `fuser -v .git/deploy.lock` names it. Wait for it; never delete the
   file.
2. **Tracked local changes are refused** (`git status --porcelain --untracked-files=no`, listed): a deploy checks another
   commit out over them. Untracked and ignored files — `go-server/.env`, `bin/`, `play-key.json` — are fine.
3. **The installed unit is read** (`systemctl show gameplay`): user, group, working directory, environment file,
   `Environment=`, `ExecStart`. The installed unit may differ from `gameplay-go.service`, so nothing is assumed. It refuses a
   unit that does not run this checkout's `go-server/bin/gameplay` from `go-server/`, or whose `EnvironmentFile=` is not
   `go-server/.env` — the file `-migrate` reads (below). A unit with no `Environment=` at all is fine; it WARNS when
   `NODE_ENV=production` is in neither the unit nor (as far as `write` can read it) the `.env`, since the server's and
   `-migrate`'s production guards hang on it.
4. **The latest pull** — `git fetch origin --prune --tags --force`, then the local `master` fast-forwarded to
   `origin/master` **as a ref**: the working tree is not touched until step 6, since the running binary serves
   `go-server/public/` from disk. A `master` with commits `origin/master` lacks stops it — the host holds no history of its own.
5. **The tag, and what may be deployed** — the argument, or the newest `go-server/v*` by version. It prints what `/health`
   reports now (version and table catalogue), the tag's migrations and which changed since what runs (the running
   version's own tag; the checkout's HEAD where no tag matches it). Then:
   - a tag **older than `go-server/v1.7.0`** is refused outright, whatever the flags — this database cannot run it (§5:
     v1.6.0 writes `player_stats` with `ON CONFLICT (user_id)`, which fails every pack, leave and hand end while `/health`
     says ok; v1.5.0 and older do not even boot). Such a tag goes onto a fresh database only, by hand (§8);
   - a tag **older than what runs** (`/health`'s version, else `bin/gameplay -version`) is refused without
     `--allow-downgrade`: a rollback is a decision, taken after reading §5, never a typo;
   - **the installed unit is compared with the tag's `gameplay-go.service`** — `TimeoutStopSec` (a stop timeout under the
     template's would SIGKILL the server inside its own shutdown budget, mid-settle), `LimitNOFILE`, `Restart`,
     `RestartSec` and the template's `Environment=` keys — and every difference is a WARNING, said here and again in the
     report, with the commands that install the tag's template (`git show <tag>:go-server/ops/gameplay-go.service | sudo tee
     /etc/systemd/system/gameplay.service && sudo systemctl daemon-reload` — after a dry run, so the deploy's own restart
     already runs under it). A warning, not a refusal: what serves today already runs on that unit;
   - **every directory a checkout writes in must be writable by `write`** (the checkout's, `.git`, `go-server/bin`):
     `git checkout` that cannot replace a file says so, moves HEAD anyway and exits 0, leaving the old file under the
     new commit — so it is refused here, naming each directory with its owner and mode;
   - **the rollback copy is chosen** (step 6).
6. **Keep, check out, build** — it remembers HEAD and keeps **the running build** as `bin/gameplay.prev` (only one): a copy
   of `bin/gameplay` when `/health` reports that binary's version; the `.prev` already there when that is the one running
   (an earlier deploy stopped before its restart, or a `build.sh` with no restart, left a build in `bin/gameplay` that
   never ran — copying it over `.prev` would lose the only copy of the running one); and when neither is, it refuses
   without `--force` and says which build runs and which are on disk (`deploy.sh go-server/<running> --force` puts the
   running build back on disk). When nothing answers `/health` it keeps `bin/gameplay`, unverified, and says so. Then it
   checks the tag out **detached**, checks git wrote every tracked file (and names any it could not, with owners and
   modes), runs the tag's own `build.sh`, and checks that `bin/gameplay -version` names the tag.
7. **Migrate** — the NEW binary's `gameplay -migrate`, as the unit's user, in its working directory, with its
   `Environment=` (`NODE_ENV=production` at least): `cd go-server && sudo -n -u <user> env NODE_ENV=production … ./bin/gameplay
   -migrate`. It prints one line per script applied and `migrated schema public: 3 of 3 scripts applied in … ms`.
8. **Restart** — `sudo systemctl restart gameplay`, unless `/health` already answers ok with the tag's version AND the build
   just made is byte for byte the running one (`cmp` with `.prev`: a `-trimpath` build of one commit is the same bytes) —
   then "already running vX; migrations applied; not restarted". A tag moved on origin names new code under the same
   version string, so it is restarted onto, with a warning; `--force` always restarts. Then up to 60 s
   (`HEALTH_WAIT_SECONDS`) for `/health` to answer `ok` with that version — the graceful stop alone can take 20 s — and
   **30 s more of watching** (`HEALTH_WATCH_SECONDS`): `/health`'s `ok` is true the moment the listener is up, and a build
   that falls over seconds later (a background job's panic at 10 s) would flap under `Restart=always` while every probe
   between two crashes said ok. The unit's `MainPID` and `NRestarts` must not change, and at the end `/health` must still
   answer with the tag and a later uptime. **From the restart on, Ctrl-C and a dropped session do not stop it**: the
   previous build is already stopped, so the run goes on until the new one is judged — and rolled back if it must be.
9. **Report** — the version before and after, the table catalogue `/health` reports (a loud WARNING when
   `tableConfig.fallback` is true: the build could not use the database's catalogue and plays the env menu, so the lobby
   changed), the tag, the migrations, every warning again, the time and the log. Then `prod-version.sh` from anywhere.

`--dry-run` does 1–5 (the fetch only moves `origin/*` and the tags; the floor, the downgrade rule, the unit comparison, the
writability check and the rollback-copy choice all run) and prints the commands 6–8 would run. `/health` is read at
`127.0.0.1:<PORT>`, `PORT` from the `.env` when `write` can read it, else the unit's `Environment=`, else 3000;
`HEALTH_URL=…` overrides it.

Exit codes — every exit is one of these five; a command failing unexpectedly (a fetch's own 128, say) or a signal is
reported with its own code and exits 1, or 4 during the restart:
`0` deployed, or nothing to do; `1` refused, or failed before any restart (a failed build or checkout puts the previous
binary and HEAD back); `2` **a migration failed — the previous binary and HEAD are back and nothing was restarted**; `3`
the new build never answered `/health`, or fell over while watched — the journal is printed, the previous binary put back,
the service restarted onto it and seen healthy, the HEAD put back; `4` the rollback did not come back either, or the run
was stopped during the restart and cannot say what serves: **production may be down**, act on the journal now.

**Run it inside `tmux` or `screen`.** A dropped ssh session sends the script SIGHUP. Before the restart that stops the run
and puts the previous build back (the old build never stopped serving); from the restart on the script ignores it and
runs to its end, writing to the log — but sudo's cached password belongs to the terminal that typed it, so a rollback
that needs `sudo systemctl restart` after the session has gone cannot get it. The binary on disk is the previous one
again by then, so a new build that keeps crashing comes back on it at systemd's next automatic restart; one that hangs
does not. Inside `tmux` none of this arises, and the script says so at the top of every run started outside it. After a
drop: `tmux attach -t deploy`, or `tail -f` the log it named.

**Why the migrations run with the new binary, before the restart.** A boot applies every embedded migration anyway
(`db.Open`) and refuses to start when one fails — so until now a bad script was found by the restart, with the previous
build already stopped and systemd restarting the new one into the same error every 2 s. `gameplay -migrate` is exactly the
first half of a boot: the same `db.Open`, the same scripts embedded in the same binary, in the same order, under the same
schema lock, `lock_timeout` and `PG_STATEMENT_TIMEOUT_MS`, with the same `.env` and `DATABASE_URL`/`PG_SCHEMA` — and nothing
else (no Redis, no listener, no table catalogue, no background job). Run first, it moves the failure to a moment when the
previous build is still serving and only the checkout has to be put back. Every script is idempotent and additive
(CLAUDE.md §7.3): the previous build runs on the newer schema, as a rollback already requires (§5), and the boot that follows
re-applies them all as a no-op. A script is one transaction, so a failing one leaves nothing of itself behind while the
scripts before it stay applied (and harmless, being additive). The configuration is checked too: `-migrate` reads the
`.env` through the same parser and production guards as the server, so a `.env` the new build would refuse to boot on
stops the deploy here.

**What running beside the live server costs.** Since 29 Sep 2026 a migration that changes nothing takes no lock a writer
waits for: every index in the baseline is built behind a catalogue lookup, as `idx_users_last_login` always was, because a
bare `CREATE INDEX IF NOT EXISTS` takes SHARE on its table BEFORE it looks — on twelve tables, `chip_ledger` among them —
and SHARE waits for every open writer and makes every later one queue behind it (`TestABootThatChangesNothingWaitsForNoWriter`
replays every script on an up-to-date schema and fails on any SHARE-or-stronger lock). Measured before that change on a
throwaway schema: a settle write waited 2.3 s behind a waiting `-migrate`, and a purchase-shaped transaction (ledger row,
then ownership row) deadlocked with it — the baseline reached `user_profile_pictures` before `chip_ledger`. What remains is
a release whose scripts DO change the structure: a new index takes SHARE on its table for as long as it builds (on
`chip_ledger`, seconds of frozen ledger writes), a new column or trigger a stronger lock for a moment. Each waits at most
3 s (`lock_timeout`) for the locks it needs — and while it waits, every writer of that table waits behind it, so pack,
leave and hand-end writes can stall up to 3 s, and one purchase can be aborted by a deadlock (its money is rolled back,
the player sees an error and buys again). A migration that cannot get its lock in 3 s fails: exit 2, nothing restarted,
run it again. **Deploy a release that changes the structure at a quiet hour** — the dry run's "changed since
what runs" line says whether any script changed. Such a release ran all of this at its boot before, with the server down;
the difference is only that the players are still playing.

**Why never `psql -f` the migration files as `postgres`.** A table belongs to whoever creates it. Scripts run as
`postgres` leave every new table, sequence and function owned by `postgres`: the server — which connects as its own role,
from `DATABASE_URL` — cannot write to a table it holds no grant on, and its next boot cannot even run the scripts again
(every boot does), since `CREATE OR REPLACE FUNCTION` on a function `postgres` owns is `must be owner` — a crash loop (§7 is
the ownership story). `-migrate` connects with the server's own `DATABASE_URL`, as the
service's own user, from the service's own directory, so everything is created exactly as a boot would create it. (That is
also why `write` never needs to read the `.env`: the service's user does, through `sudo -u`.) A key the unit sets in
`Environment=` and the `.env` sets too is left to the `.env`, as systemd does.

**The detached HEAD it leaves.** The checkout ends on the tag, detached, on purpose: what runs is the tag, not a branch.
`master` is kept at `origin/master` as a ref. So on the host `git pull origin master` is replaced by the script — a pull on a
detached HEAD fails — and step 2 is what keeps the checkout rebuildable. The `deploy.sh` that runs is the checkout's,
i.e. the previously deployed tag's; to run a newer one than that, check the newer commit out first:
`git fetch origin && git checkout --detach origin/master && bash go-server/ops/deploy.sh`.

**Rollback.** Automatic when the new build never answers `/health`, or falls over while it is watched (exit 3). By hand a
rollback is a deploy of the older tag with **`--allow-downgrade`** — `bash go-server/ops/deploy.sh go-server/v<previous>
--allow-downgrade` — after reading §5 for what that tag needs; without the flag the script refuses any tag older than what
runs, and no flag deploys one older than `go-server/v1.7.0` (the oldest this database can run; §5, §8). The newer tag's
migrations stay (they are additive, and the older build ignores what it does not know). A tag from before `-migrate`
existed is built and restarted without the migrate step: its migrations run at its own boot, as they always did.
`bin/gameplay.prev` is the build that was running when the last deploy started — after a run that restarted nothing,
that is the running build itself; to go back further, deploy the older tag with `--allow-downgrade`. **After rolling back to
a tag older than the first one that carries `deploy.sh`** (e.g. `go-server/v1.10.2`), the checkout holds no `deploy.sh`:
the next deploy is the first-time line below again (`git fetch origin && git checkout --detach origin/master && bash
go-server/ops/deploy.sh`), or the by-hand lines.

**First time.** The script arrives with the first checkout that contains it. The host has sat on a detached HEAD at
the tag it runs since the by-hand v1.10.2 deploy (29 Sep 2026), so the first run fetches and checks master out detached,
then runs the script:

```bash
tmux new -A -s deploy
cd /var/www/gameplay/king-teenpatti && git fetch origin && git checkout --detach origin/master && bash go-server/ops/deploy.sh --dry-run
bash go-server/ops/deploy.sh
```

Every later run is the last line alone, inside `tmux` — the fetch is the script's. The unit must already be the Go one
(`install-go-server.sh`, above), with `EnvironmentFile=` pointing at `go-server/.env`.

### Every later deploy

`deploy.sh` (above) does this, with its checks, the migration before the restart and the automatic rollback.
By hand — a fallback, or on a host where the script cannot run — every deploy is still of a TAG,
`go-server/vX.Y.Z`, cut on master after the release is merged (`ops/release.sh`), never of "whatever master
is now" (`steps.txt`; 29 Sep 2026, owner: deploy a specific tag):

```bash
cd /var/www/gameplay/king-teenpatti
TAG=go-server/vX.Y.Z                              # the tag to run (an older one rolls back)
git fetch origin --tags --force
git status --short --untracked-files=no           # must print nothing
git checkout --detach "$TAG"
bash go-server/ops/build.sh
./go-server/bin/gameplay -version                 # names the tag
(cd go-server && sudo -u deploy env NODE_ENV=production ./bin/gameplay -migrate) && sudo systemctl restart gameplay
#   ^ the tag's migrations first (the unit's User= and NODE_ENV: the production guards), and the restart ONLY if they
#     succeeded — one line, so a failed migration leaves the old build serving even when the block is pasted
sudo systemctl status gameplay --no-pager
sudo journalctl -u gameplay -n 20 --no-pager
for i in $(seq 60); do curl -sf -o /dev/null 127.0.0.1:3000/health && break; sleep 1; done
curl -s 127.0.0.1:3000/health | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["ok"], d["version"])'
```

Wait for `/health` before reading it: the restart first settles every live pot and closes the sockets
(up to max(8 s, `PG_STATEMENT_TIMEOUT_MS` + 5 s) — 20 s by default), and a `curl` in that window gets
no answer, which `json.load` reports as a traceback although nothing is wrong (29 Sep 2026, the
v1.10.2 deploy).

The host stays on a detached HEAD at the tag it runs, and the next deploy's fetch and checkout move
it on. A `git pull origin master` there is no longer part of a deploy: master can be ahead of the last
tag, and a pull changes the source the next build would compile without changing what is running.

The build writes `bin/gameplay` while the old binary is running — Linux keeps the old inode alive
until the restart, so building never disturbs the live process. Files under `go-server/public/`
are different: the running binary reads them from disk, so a pull that deletes one takes it away
before the restart. Keep the pull, the build and the restart back to back.

### The table-catalogue release (23 Sep 2026) — deploy first, then move the tables into the database

This is the first release whose tables can come from PostgreSQL (owner: "all table related config store in
database"; CLAUDE.md §7.3/§7.4): four configuration tables — `table_engines`, `table_categories`, `table_settings`,
`table_configs` — `TABLE_CONFIG_SOURCE`, `GET /api/tables` and two flags on the binary. It goes out in two steps, and
the first changes nothing a player sees.

**Before the restart: who owns `users`.** Production's database was built by `go-server/v1.1.0` and last booted by
`go-server/v1.1.2`, so it has `chip_ledger.game`/`variant` (v1.1.2's `V1.0.2`) and lacks `users.is_bot`. This build's baseline adds the column at its first boot, through
a catalogue-guarded `ALTER TABLE users ADD COLUMN is_bot BOOLEAN NOT NULL DEFAULT FALSE` — a statement only the owner
of `users` may run. While `gameplay_app` owns it (§7 not applied) there is nothing to do. If `postgres` owns it, every
boot would fail `must be owner of table users`, so add the column as `postgres` once, first; the boot's lookup then
finds it and skips the ALTER. The running server is unaffected (it never names the column; new rows take the default):

```bash
cd /var/www/gameplay/king-teenpatti
psql "$(sed -n 's/^DATABASE_URL=//p' go-server/.env)" -Atc "SET statement_timeout = '10s'" \
  -c "SELECT tableowner FROM pg_tables WHERE schemaname = 'public' AND tablename = 'users'" \
  -c "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'is_bot'"
# gameplay_app → nothing to do.  postgres and 0 → once, as postgres (catalogue-only: instant, but it must get the lock):
sudo -u postgres psql gameplay -c "SET lock_timeout = '5s'" -c 'ALTER TABLE users ADD COLUMN is_bot BOOLEAN NOT NULL DEFAULT FALSE'
```

**Step 1 — deploy as usual** (§1, §2, the restart). Production's `.env` names `LOBBY_TABLES`, and with
`TABLE_CONFIG_SOURCE` unset a server whose environment sets ANY table key resolves to `env`: it plays exactly the menu
it played before. The same boot creates the four configuration tables and seeds them with the CODE's default
catalogue, which it does not read. The journal says so, and so does `/health`:

```bash
sudo journalctl -u gameplay -n 30 --no-pager | grep -E 'table config'
#   WARN "table config comes from the env keys, not the database"  keys=[LOBBY_TABLES, …]  hint="to move it into the database, …"
#   INFO "table config ready"  source=env  fallback=false
curl -s 127.0.0.1:3000/health | python3 -c 'import json,sys; print(json.load(sys.stdin)["tableConfig"])'   # {'source': 'env', 'version': '…', 'fallback': False}
```

**Step 2 — put production's own menu in the database, check it, switch.** The seed holds the code's default menu, not
production's, so the database is first made to hold what production plays today. `-export-table-config` composes the
table keys exactly as the running env-mode server does (from `./.env`, the file the service reads — so run it from
`go-server/`) and prints them as one psql transaction; nothing else goes to stdout. `-check-table-config` then reads
the database WITHOUT migrating anything and judges it as a db boot would. As `deploy`, no sudo until the restart:

```bash
cd /var/www/gameplay/king-teenpatti/go-server
DB="$(sed -n 's/^DATABASE_URL=//p' .env)"
TS=$(date -u +%Y%m%dT%H%M%SZ)
./bin/gameplay -export-table-config > ~/tables-$TS.sql        # stderr: "table env keys set: LOBBY_TABLES, …", "exported N public tables and M private templates, under 2 engines and 7 categories"
less ~/tables-$TS.sql                                         # engines, categories, table_settings, every table and private template — read it
psql "$DB" -f ~/tables-$TS.sql                                # BEGIN … INSERT/UPDATE … COMMIT; any refusal stops it with nothing changed
./bin/gameplay -check-table-config; echo "exit $?"            # lists the engines and every table key; must be "exit 0"
grep -n '^TABLE_CONFIG_SOURCE=' .env || printf '\nTABLE_CONFIG_SOURCE=db\n' >> .env   # a line already there: edit it to db. LEAVE every table key in the file (rollback, §5)
sudo systemctl restart gameplay
curl -s 127.0.0.1:3000/health | python3 -c 'import json,sys; print(json.load(sys.stdin)["tableConfig"])'   # source 'db', fallback False
curl -s 127.0.0.1:3000/api/tables | python3 -c 'import json,sys; b=json.load(sys.stdin); print(b["source"], len(b["tables"]), "tables", [(e["code"], [c["code"] for c in e["categories"]]) for e in b["engines"]])'
sudo journalctl -u gameplay -n 30 --no-pager | grep -E 'table (config|env keys)|draining'
#   WARN "table env keys are ignored in db mode" (expected: the keys stay for a rollback) — and no ERROR
```

The export retires every row it does not name (`UPDATE … SET is_active = FALSE`), so after it the database holds
production's menu and nothing else active; running it twice is running it once. `exit 1` from the check means a db boot
would leave rows out (each is printed as `problem:`); `exit 2`, that it could not use the catalogue at all — fix either
before the switch. The catalogue's `version` changes once at the switch (the payload names its source), so every app
fetches it once. If `/health` ever says `fallback: true`, the journal's ERROR names the reason and
`./bin/gameplay -check-table-config` lists every problem; to go back to env meanwhile, delete the
`TABLE_CONFIG_SOURCE` line (the table keys make it `env` again) and restart. Rehearsed on 23 Sep 2026 against a scratch
schema with production's shape of `.env` (a five-table `LOBBY_TABLES`): export, apply (`UPDATE 8` retiring the seeded
rows it did not name), check `exit 0`, a `TABLE_CONFIG_SOURCE=db` boot at `source: db`, and `GET /api/tables` 304 on
its own ETag.

**From then on the database is the menu.** Edit it with SQL, one statement at a time in autocommit (`psql -c`) — never
leave a transaction open in psql across a restart, since the boot's seed writes to the same tables:

```bash
cd /var/www/gameplay/king-teenpatti/go-server && DB="$(sed -n 's/^DATABASE_URL=//p' .env)"
psql "$DB" -c "UPDATE table_configs SET max_blind_moves = 3, updated_at = (EXTRACT(EPOCH FROM now()) * 1000)::bigint WHERE table_key = 'blind:200'"
psql "$DB" -c "UPDATE table_configs SET is_active = FALSE WHERE table_key = 'seen:50000'"           # retire one table
psql "$DB" -c "UPDATE table_categories SET is_active = FALSE WHERE code = 'variation'"             # hide every variation table
psql "$DB" -c "UPDATE table_engines SET is_active = FALSE WHERE code = 'poker'"                    # hide all of Poker
./bin/gameplay -check-table-config; echo "exit $?"                                                  # what the next boot will play
sudo systemctl restart gameplay                                                                     # nothing applies before this
```

- **A restart applies it, to tables opened after it.** The server reads the catalogue once, at boot. A table restored
  from Redis keeps the rules it was opened with; one whose rules the rows no longer give (or whose table left the menu)
  is **drained** — its players play on and its code still works, but the lobby sends nobody to it and it goes once
  empty (`table draining` INFO in the journal). A player left alone at one is still merged (requirement 24): onto the
  table of the same stake with the new rules once there is one and their stack fits its entry band, or else onto an
  older drained table playing by the same old rules. `GET /api/tables` and `/health.tableConfig.version` show what the
  process runs; a `SELECT` shows only what the next boot will.
- **Retire, never DELETE.** `is_active = FALSE` works at every level: a table, a category (every table of it) or an
  engine (every category and table of it). A DELETE of a category or engine something names is refused by the foreign
  keys, and a seeded row deleted comes back at the next boot — a table inactive, an engine or category active.
- **`seen` cannot be switched off** — nor, therefore, the `teen_patti` engine: the private table `room:create` opens
  is the seen template, and without it the boot cannot use the catalogue and falls back to the env composition
  (`fallback: true`). To take seen tables out of the lobby, retire their public rows.
- **A new table** is an INSERT stating every figure (the rule and clock columns have no DEFAULT on purpose); the easy
  way is to copy a row — `INSERT INTO table_configs (category, boot_amount, is_private, min_chips, …, sort_order,
  is_active) SELECT category, 1000, FALSE, min_chips, …, 25, FALSE FROM table_configs WHERE table_key = 'blind:200'` —
  and switch it on with `is_active = TRUE` when it should appear. That one row is all it takes: **a table's own boot is
  always an allowed stake**, so `table_settings.stakes` need not be edited — a boot it does not list (1000 here) is
  appended to it at boot, after the stakes it lists (`/api/tables` and the lobby's `stakes` show it there), and
  quick-join and a public `room:create` reach the new card. An empty `stakes` array still means any stake. A category
  installed apps do not know (as variation and poker once were) goes live only after `MIN_CLIENT_BUILD` is raised to a
  build that can draw it.
- **The database has the last word on shape**: a turn clock under 5 s, a sideshow window under 1 s, a variation row
  without both windows, a poker buy-in under its boot, a band min over max, a category nobody declared — each refused by
  a CHECK or a foreign key at the `UPDATE`. What PostgreSQL accepts but the engine must not open is left out at boot
  with an ERROR `table config row left out` naming the row, and the rest plays.
- **A release that changes a default table does NOT change production's.** The seed never touches a row the database
  already has, and a table appended to it arrives INACTIVE on an existing catalogue; read the release notes and apply
  what they ask for by hand.

### The first deploy that carries Variation Teen Patti — check `LOBBY_TABLES` first

*(Written for env mode, before the catalogue. In db mode the same rule is the row's: a variation or poker row added to
an existing catalogue arrives inactive, and `is_active = TRUE` goes after `MIN_CLIENT_BUILD`, never before.)*

The same check covers the second seen table (19 Sep 2026): the default menu now also ends with
`seen:50000:pot=50000000` — boot 50,000, open to all, a 5 Crore pot limit of its own. A `.env` that
names `LOBBY_TABLES` needs that entry added by hand to offer it, and a Go tag older than this
build cannot parse `pot=` and will refuse to boot on it.

The build's **default** menu ends with two variation tables —
`variation:50000:max=1000000000,variation:1000000:min=500000000` — so what the restart does
depends on production's `.env`:

```bash
grep -n '^LOBBY_TABLES' /var/www/gameplay/king-teenpatti/go-server/.env
```

- **A line comes back** — production keeps exactly the menu it names. Nothing changes until
  the two `variation:` entries are added to it (and the server restarted).
- **Nothing comes back** — the restart puts the variation tables in every lobby at once,
  including phones whose installed app has never heard of the category.

An app older than the first build with the picker draws those cards as extra "SEEN" tables (at
50,000 and 10 Lakh), shows no "Choose Variation" panel, and so every hand one of its players opens is timed
out into a server-chosen **Muflis** — the weakest hand wins, with nothing on screen to say why.
So, in order: ship the new app, wait until it is the version the store actually serves, raise
`MIN_CLIENT_BUILD` to that build number (§7.4 of `CLAUDE.md`; it holds older apps on the update
screen), and only then list the `variation:` entries. That same build is the one with the
lobby's category chooser, the hidden stacks and the wild-card turn, all of which an older app
lacks. To deploy this server *before* that, pin the old
menu explicitly so the default cannot reach anyone:

```bash
LOBBY_TABLES=seen:200,blind:200,blind:5000:max=50000000,blind:50000:max=1000000000,blind:1000000:min=500000000
```

Rolling back past this release with `variation:` still in `.env` stops the older binary at boot
(it rejects an unknown `LOBBY_TABLES` category at load) — take the entry out first.

### Variation bets as blind (28 Sep 2026) — a catalogue seeded before keeps the old ladder

*(Owner, 28 Sep 2026: "no limit on chaal if a player has money" — "the bug is that i am only able to raise one time in
variation 50000".)* From this release a PUBLIC variation table bets as a blind one: no raise limit (the ladder doubles
until the stack stops it), no round cap, no per-bet ceiling; a PRIVATE one keeps `PRIVATE_MAX_RAISE_STEPS`' two rungs,
with no round cap and no per-bet ceiling. In env mode that is code (`config.TableRules`, read from neither `SEEN_*` nor
`BLIND_*`) and the restart applies it. In db mode the figures are the `table_configs` rows, and **the seed never rewrites
a row a database already has**: a deployment whose catalogue was seeded before 28 Sep 2026 — preprod, a dev box — keeps
the seen ladder on its variation rows (2 rungs, 7 rounds, 1024 boots a bet) until they are changed by hand. Production's
were changed on 28 Sep 2026 with exactly these two statements and a restart:

```bash
cd /var/www/gameplay/king-teenpatti/go-server && DB="$(sed -n 's/^DATABASE_URL=//p' .env)"
psql "$DB" -c "UPDATE table_configs SET max_bet_rounds = 0, pot_limit_multiplier = 0 WHERE category = 'variation'"
psql "$DB" -c "UPDATE table_configs SET max_raise_steps = 0 WHERE category = 'variation' AND NOT is_private"
./bin/gameplay -check-table-config; echo "exit $?"                  # must be exit 0
sudo systemctl restart gameplay                                     # nothing applies before this
curl -s 127.0.0.1:3000/api/tables | python3 -c 'import json,sys; b=json.load(sys.stdin); [print(e["key"], e["maxRaiseSteps"], e["maxBetRounds"], e["potLimitMultiplier"], e["maxPot"]) for e in b["tables"] + b["privateTables"] if e["category"] == "variation"]'
#   variation:50000 0 0 0 0
#   variation:2000000 0 0 0 0
#   private:variation 2 0 0 500000
```

(On a dev box the same two statements go through the local `psql` — `PGPASSWORD=postgres psql -h localhost -U postgres
-d gameplay -c "…"` — followed by a restart of the dev server.) **Verify with `GET /api/tables`, never with a `SELECT`**: the
rows say what the NEXT boot will play, the endpoint what the running process plays, and until the restart they differ. A
variation table restored from Redis across that restart keeps the ladder it was opened with and is drained (above, "A
restart applies it"): its players play on at the old rules while quick-join opens a fresh table at the new ones.

### The app version gate (28 Sep 2026) — minimum, latest and maintenance, per platform, with no restart

*(`CLAUDE.md` §7.2 "The app version gate" is the reference; `internal/appversion`.)* The server decides, per app platform,
whether a build may play, from ONE table, `app_versions` — a row for `android` and one for `ios`:

| column | meaning |
|---|---|
| `status` | `NORMAL`, or `MAINTENANCE`: nobody on that platform may play, whatever their version |
| `minimum_version` | the oldest version allowed (MAJOR.MINOR.PATCH); below it the app shows **Update required** and the server refuses it at every signed-in door (426 `update_required`, `connect_error update_required`). `0.0.0` = no floor |
| `latest_version` | the newest version announced; between the minimum and this the app offers **New version available** with Later. `0.0.0` = none |
| `store_url` | where **Update now** goes (Play on android; the App Store listing on ios, once there is one) |
| `message` | shown with a force update or a maintenance; `NULL` = the app's own words, in the player's language |

**The deploy itself changes nothing**: the first boot creates the table and seeds both rows with NO floor (`0.0.0`), nothing
announced, `NORMAL`, and `APP_VERSION_REQUIRED` defaults to false. The rows are read through a cache of `APP_VERSION_CACHE_MS`
(15 s): **an UPDATE is enforced within 15 seconds, with no restart and no app release**. Every statement below is run as the
app's database user (`psql "$DATABASE_URL"`, or `sudo -u postgres psql gameplay`); a malformed version or status is refused by a
CHECK at the UPDATE, never locks anyone out.

**Check what the server enforces** (public, no token; the headers or the query name the build):

```bash
curl -s 'https://prod.sungamestudio.com/api/app-config?platform=android&version=1.5.0' | python3 -m json.tool
psql "$DATABASE_URL" -c "SELECT platform, status, minimum_version, latest_version, store_url, message, updated_at FROM app_versions ORDER BY platform"
```

**Raise the minimum** — the operational change of the brief: Android 1.5.0 → 1.6.0. **Only ever to a version the store is
already serving** (the §14.4 rule of `CLAUDE.md` for `MIN_CLIENT_BUILD`, which this replaces: a floor above what Play serves takes
the game down for everyone with no way past):

```sql
UPDATE app_versions SET minimum_version = '1.6.0' WHERE platform = 'android';
-- announce a newer one as optional at the same time (a Soft Update, Later allowed):
UPDATE app_versions SET latest_version = '1.6.2' WHERE platform = 'android';
-- iOS is its own row:
UPDATE app_versions SET minimum_version = '1.4.0', latest_version = '1.5.0' WHERE platform = 'ios';
```

Within 15 s: Android 1.5.0 → FORCE_UPDATE (the Update required screen, and 426 / connect_error from the server), 1.6.0 → SOFT_UPDATE
while 1.6.2 is announced, 1.6.2 → NORMAL. **The installs that predate the gate** (1.5.0+13 and older) send no version; they are
held too, because every connection's `session:ready.config.minClientBuild` is now the build number the minimum translates to
(1.6.0 → 14: every legacy release), which their own update screen already obeys. `MIN_CLIENT_BUILD` in `.env` can stay 0.

**Enter maintenance** — every platform, or one:

```sql
UPDATE app_versions SET status = 'MAINTENANCE', message = 'Back at 14:00 IST';     -- both rows
UPDATE app_versions SET status = 'MAINTENANCE' WHERE platform = 'ios';            -- iOS only
```

Within 15 s the app shows **Under maintenance** (with the message) and its Try again; every signed-in request answers 503
`maintenance` and every handshake `connect_error maintenance`. **A socket already connected is NOT dropped** — the gate is at
the door — so players mid-hand finish in peace; the login and `/health` stay open, and the bot fleet and the tools (which
declare `bot` / `tool`) keep playing. For maintenance that must empty the tables, set the rows first and then restart: the
graceful shutdown settles every live pot (§14.3), and the reconnecting apps meet the maintenance screen. **Leave maintenance**:

```sql
UPDATE app_versions SET status = 'NORMAL', message = NULL;
```

— a player on the maintenance screen taps Try again (or reopens the app) and is back where they were.

**When to turn `APP_VERSION_REQUIRED` on** — the switch that refuses every client that declares NO app platform (every
install that predates the gate, and any script): only once (1) the oldest build Play still serves is one that sends
`X-App-Platform` (the first build with the gate), and (2) the android `minimum_version` is at or above it. Until then it would
lock out apps nobody has updated yet. Then, in `go-server/.env`:

```bash
APP_VERSION_REQUIRED=true
sudo systemctl restart gameplay
```

`bot-play/` (the resident fleet), `tools/` and the browser client declare `bot`, `tool` and `web` and are never refused — deploy
bot-play from a commit that carries the declaration (it does since this release) BEFORE turning the switch on.

**Watch it**: `game_app_version_rejections_total{platform,status,via}` (Grafana → Explore) counts the old builds still
knocking; the journal has one line a minute per kind:

```bash
journalctl -u gameplay --since '10 min ago' | grep -E 'FORCE_UPDATE_REJECTED|WEBSOCKET_VERSION_REJECTED|MAINTENANCE_REJECTED|SOFT_UPDATE_DETECTED'
```

**Rollback**: an older Go tag never reads `app_versions` (the table stays, harmless) and serves nothing at `/api/app-config` —
the app then carries on as it does offline, and the legacy `MIN_CLIENT_BUILD` floor is the only one in force again. Set it in
`.env` to the build number the minimum meant before rolling back, if one was raised.

## 4. Verify

**Health** — `process.node` must start with `go`; `goroutines`/`numCpu`/`gomaxprocs` are Go-only extras:

```bash
curl -s 127.0.0.1:3000/health | python3 -m json.tool
curl -s https://api.sungamestudio.com/health | python3 -c 'import json,sys; h=json.load(sys.stdin); print(h["ok"], h["process"]["node"], h["players"], "players")'
curl -s 127.0.0.1:3000/health | python3 -c 'import json,sys; print(json.load(sys.stdin)["tableConfig"])'   # source env|db as intended; fallback must be False
```

`tableConfig.fallback: true` means a `TABLE_CONFIG_SOURCE=db` server found a catalogue it could not use and is playing
the env composition — look for the ERROR in the journal and run `./bin/gameplay -check-table-config` (§3).

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

**Since 29 Sep 2026 a rollback is `bash go-server/ops/deploy.sh go-server/v<previous> --allow-downgrade`** (§3) — the
script refuses a tag this database cannot run (anything before `go-server/v1.7.0`), migrates nothing backwards, restarts,
watches `/health`, and puts the newer build back by itself if the older one does not come up. To come forward again,
`deploy.sh` with no argument. The command blocks below are the by-hand history of this section; what they say about
which tags need what still holds.

**Roll back to the previous Go release, not to Node.** Rolling back to Node stopped being possible
on 12 Sep 2026: `users.avatar_choice` — which the Node build reads and writes in three places — no
longer exists, the catalogue tables (`profile_pictures`, `user_profile_pictures`) are not in its
schema at all, and `server/` is long gone from the host. `rollback-to-node.sh` was removed rather
than left as a safety net with a hole in it; a recovery script that fails at the moment it is needed
is worse than none, because it implies a way back that is not there.

**A tag before Friends V1 needs a fresh database.** Friends V1 (26 Sep 2026) moved the six gameplay
counters off `users` into `player_stats`, and a database built by this build's scripts has no
`users.hands_played` … `biggest_pot` at all (owner: "only store in player_stats table"; the build is
deployed onto a fresh database, so nothing migrates them). go-server/v1.5.0 and older read and write
those columns on every login and checkpoint, so rolling back to one of them means deploying it onto a
fresh database, not onto this one.

**Player stats v2 and go-server/v1.6.0 need a fresh database in both directions** (27 Sep 2026). v2
keeps `player_stats` per game — one row per player per bucket (TEEN_PATTI, VARIATION, POKER), keyed
`(user_id, category)`, beside `player_variation_stats` and the flusher's receipts in `stats_flushes` —
where v1.6.0 kept one row per player. `CREATE TABLE IF NOT EXISTS` changes neither shape into the other,
so:
- **Deploying v2 onto a database v1.6.0 built**: the baseline REFUSES the boot, naming this section
  (`player_stats has the go-server/v1.6.0 shape … needs a fresh database`) — without that guard the boot
  looked clean and then every login failed. Deploy it with §8's fresh-database procedure.
- **Rolling back from v2 to v1.6.0**: v1.6.0 writes its counters in the money transaction with
  `ON CONFLICT (user_id)`, which v2's table cannot satisfy, so every hand-end settle and every leave of
  a player who had bet would fail and money would stop being written. Roll back onto a fresh database
  too — or recreate v1.6.0's `player_stats` by hand (`user_id` primary key, the six counters) and drop
  `player_variation_stats` and `stats_flushes` first.
- A hand's counters wait in Redis (`kt:stats:<userId>`) for up to `STATS_FLUSH_MS` before the flusher
  moves them; a restart keeps them there for the next process, and the fresh-database procedure's
  `kt:*` wipe discards them with everything else, which is intended.

Releases are tagged (`go-server/vX.Y.Z`, see `../README.md` §Releasing), so going back one is a
checkout and a rebuild. One thing has to be settled **before** the checkout — who owns `users` — and
one is worth knowing first: what an older tag's own migrations do to a database built from the
consolidated scripts (§8). Both are explained below the commands. As `deploy`, no sudo needed until the restart:

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

**Older tags on a database built from the consolidated scripts.** Since 14 Sep 2026 the database is
built by two scripts (§8), and a rollback runs the older tag's own scripts against it at every boot.
Checked with `go-server/v1.3.0`'s four scripts, booted twice on a schema the consolidated scripts had
built: they boot cleanly and change no structure — every `CREATE TABLE IF NOT EXISTS` finds its table,
and the columns and tables that build does not know (`users.hammer`, `hammer_purchases`,
`hammer_spends`) are simply never read — but they add one row. v1.3.0's `V1.0.2` still seeds Butterfly
Flapping at `/profiles/butterfly-flapping.json`, the file its checkout serves, and that URL conflicts
with nothing, so the shelf gains **a second Butterfly Flapping**, locked for everyone and on sale at 4
diamonds. While v1.3.0 runs nobody can force a sideshow or buy a hammer pack: neither exists in that
build. Only v1.3.0 was checked. Any build from before the missiles (`go-server/v1.0.0` and older)
likewise never reads `users.missile`, `missile_purchases` or `missile_spends`; while it runs nobody can fire a missile or
trade for one, and new accounts still get 9 diamonds and 1 missile from the column defaults.

**Tags from before the Poker family (19 Sep 2026)** meet two more things. `LOBBY_TABLES` in the
`.env`: a tag that does not know `three_card_poker`, `five_card_draw`, `texas_holdem` or `omaha`
refuses to boot on a line that lists one (`parseLobbyTables` names the entry), so take the poker
entries out of the line before the restart and put them back when coming forward. Redis: a poker
room's snapshot begins `{"game":"poker",…}` and keeps its config under `pokerConfig`; the older tag
reads it as a Teen Patti snapshot, finds no `config`, refuses it ("snapshot has no config") and
deletes the key, so every poker room is dropped at that boot and its players re-join (rehearsed on
19 Sep 2026 against a scratch Redis: the new binary saved a seen table and a Hold'em room mid-hand and
was SIGKILLed; `master`'s binary logged `table restore: dropping stored table … has no config
(maxPlayers 0)` for the poker room, `restored tables=1 seats=2` for the seen one, and the poker key was
gone; the new binary booted forward on the same Redis and restored the seen table again) —
their wallets are what PostgreSQL last knew (CLAUDE.md §5.1), and a hand in flight is un-made exactly
as a lost-Redis hand is. The two nullable `chip_ledger` columns (`V1.0.2` from go-server/v1.1.1; in the baseline
since 23 Sep 2026) are never read by the older tag and its rows leave them NULL, which is what a Teen Patti row holds anyway.

**Tags from before the table catalogue (23 Sep 2026 — every tag up to and including `go-server/v1.1.2`)** never read
`table_engines`, `table_categories`, `table_settings` or `table_configs`, nor `TABLE_CONFIG_SOURCE`: they play the table
keys in `go-server/.env` and their own compiled-in defaults. So **an edit made in the database does not survive a
rollback** — the older binary plays whatever the `.env` says — and that is why the table keys (`LOBBY_TABLES` and the
rest) stay in the `.env` after the switch to `db`, where the new build ignores them with one WARN. If the catalogue has
been edited since the switch, carry the edit into those keys before the rollback's restart, or accept the older menu
while it runs; coming forward again, the rows are exactly where they were and the new build reads them. The older tag's
scripts are harmless on this database: checked on 23 Sep 2026, `go-server/v1.1.2`'s three (its baseline, its
`V1.0.1__seed_profile_pictures.sql`, the guarded `V1.0.2__chip_ledger_game.sql`) ran twice on a schema this build's two
had built — fourteen tables before and after, 45 pictures before and after, the configuration rows untouched — and
this build's two then ran over the result cleanly. `users.is_bot` is left alone too; the older build's logins simply do
not mark the bot fleet's new accounts while it runs.

Coming forward again does **not** remove the second row — the consolidated seed carries no clean-up —
so retire it with the second query below, either during the rollback or after it (`UPDATE 1` retires
it; `UPDATE 0` means there is nothing to retire). Never `DELETE` it: `user_profile_pictures` cascades
on it and `users.active_picture_id` is set to null, so whoever bought or wore it during the rollback
would lose it. A player who did buy it keeps a retired row whose file the branch no longer ships, and
draws the default avatar while wearing it.

```bash
cd /var/www/gameplay/king-teenpatti
psql "$(sed -n 's/^DATABASE_URL=//p' go-server/.env)" -Atc "SET statement_timeout = '10s'" \
  -c "SELECT id, asset_url, is_active FROM profile_pictures WHERE name = 'Butterfly Flapping' ORDER BY id"   # one row at the Drive URL; two after a v1.3.0 boot
psql "$(sed -n 's/^DATABASE_URL=//p' go-server/.env)" -Atc "SET statement_timeout = '10s'" \
  -c "UPDATE profile_pictures SET is_active = FALSE WHERE asset_url = '/profiles/butterfly-flapping.json'"   # UPDATE 1 retires the rollback's copy; UPDATE 0 = nothing to retire
```

**Hammer-priced pictures under an older build.** Every release before the pictures' `HAMMER`
currency (14 Sep 2026) knows only `COIN` and `DIAMOND`, and its purchase code treats any row that is
not `DIAMOND` as chips. Booted on a database this build seeded, it sells the 15 hammer-priced animated pictures
in the lobby **for chips at their hammer figures** — 10 to 100 chips — through ordinary `picture_purchase`
ledger rows, and refuses them at a table as chip-priced. No chips are created and the books still
reconcile, but the animated shelf is all but free while the rollback lasts. Take those rows off sale
before the rollback's restart and put them back once this build runs again (`UPDATE 20` each time,
unless some were retired on purpose — then re-activate by id). Retiring leaves every bought rental and
every worn picture where it is:

```bash
psql "$(sed -n 's/^DATABASE_URL=//p' go-server/.env)" -Atc "SET statement_timeout = '10s'" \
  -c "UPDATE profile_pictures SET is_active = FALSE WHERE currency = 'HAMMER'"   # before rolling back
psql "$(sed -n 's/^DATABASE_URL=//p' go-server/.env)" -Atc "SET statement_timeout = '10s'" \
  -c "UPDATE profile_pictures SET is_active = TRUE WHERE currency = 'HAMMER'"    # after coming forward again
```

**Under §7, older tags cannot start.** Once `postgres` owns `users` (§7), every tag up to and
including `go-server/v1.3.0` fails at boot with `must be owner of table users`, because its baseline
creates `idx_users_last_login` without the ownership-proof lookup. That is what the owner query at the
top is for: if it answers `postgres`, hand `users` and its function back to `gameplay_app` first (the
undo in §7), then check out, build and restart, and run §7 again once a guarded build is back.

Then get back onto the branch when the fix is ready. From v1.3.0 the checkout removes
`butterfly-flapping.json` by itself — the tag tracks it and `master` does not — so build and restart
straight after it, then retire the rollback's Butterfly Flapping with the query above:

```bash
git checkout master && git pull origin master
bash go-server/ops/build.sh
sudo systemctl restart gameplay                              # or: kill "$(systemctl show gameplay -p MainPID --value)"
bash go-server/ops/prod-version.sh                           # the release you came back to
```

**What a rollback does not undo.** The database is not versioned with the binary. Migrations run at
every boot and only ever add; an older binary against a newer schema is fine (it ignores columns it
does not know), but an older binary cannot remove a column a newer one added, and **nothing here
reverses a data change**. If a release altered data rather than code, say so in the release notes and
plan the reversal separately — through the ledger for anything touching money (`chip_ledger` is
append-only; a correction is a compensating row, never a DELETE).

`go-server/.env` is also not versioned. A release that changed a key's meaning needs that key put
back by hand, or the old binary reads a value it does not expect. And the table catalogue is data: a rollback neither
undoes an edit to it nor makes an older binary read it (above).

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
| Deploy routine | `git pull origin master && npm ci && systemctl restart` | `bash go-server/ops/deploy.sh` (`steps.txt`; a tag, since 29 Sep 2026) — by hand: fetch the tags, check the tag out detached, `build.sh`, `-migrate`, restart |
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
`users` — `diamond_purchases`, `hammer_purchases`, `hammer_spends`, `missile_purchases` and
`missile_spends` each have one, and a later table may — needs the REFERENCES privilege on `users`. An owner holds it implicitly; once `postgres` owns
the table, `gameplay_app` holds it only if granted. Its absence does not show on the day this section
is run: `CREATE TABLE IF NOT EXISTS` skips a table that already exists before it checks anything. It
shows on the first boot that has to *create* such a table — `permission denied for table users` —
which is to say in some later release. If `users` is already owned by `postgres` from a run of this
section that predates the REFERENCES line, run that one `GRANT` on its own now.

**What the restart proves, and what it does not.** A clean restart proves that the scripts in *this*
checkout boot under the new ownership. It proves nothing about the next release, which brings scripts
of its own: without the REFERENCES grant this restart is clean, and a release that adds a table
referencing `users` still crash-loops. What covers a checkout's scripts is
`TestTheAppRoleBootsTwiceBeforeAndAfterUsersIsHandedToTheSuperuser` (`internal/db`; needs a local
PostgreSQL superuser). It reads the SQL block above out of this file, applies it to a throwaway
schema, and boots every migration twice as a role that is not a superuser, before and after — then
twice more while re-creating the twelve tables that reference `users` under the new ownership, and
spends a hammer and a missile, trades diamonds for missiles and loads the table catalogue on the new grants. Run it before deploying a
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

**Releases that need that one-off run: the table-catalogue release (23 Sep 2026), on a database that lacks
`users.is_bot`.** The migrations are one DDL script and one DML script (§8), and everything they do to `users` —
`users.hammer`, `users.missile`, the new-account `diamond` default of 9 and `users.is_bot` — is declared in the
baseline's `CREATE TABLE users`, which a database started over under §8 builds as its owner on the first boot. But
`is_bot` is also in a catalogue-guarded block right after it (it was `V1.0.3__users_is_bot.sql` until it was folded in,
never tagged), and on a database built before it — production's, last booted by `go-server/v1.1.2` — that block runs
`ALTER TABLE users ADD COLUMN is_bot BOOLEAN NOT NULL DEFAULT FALSE` at the first boot. Under §7 the app role cannot, so
run that one statement as `postgres` before deploying (§3 has the check and the command); the lookup then skips it for
good. (For a day a `V1.0.2__new_account_diamonds.sql` moved the default with a guarded ALTER that needed this run too;
it was folded into the baseline long since.) The next statement that ALTERs or indexes `users` goes into the baseline
behind a catalogue lookup — never into a new script, CLAUDE.md §7.3 — and is run once as `postgres` here before its
release is deployed. The four configuration tables need nothing: none of them references `users`, and the app role
creates and owns them.

## 8. Starting production on an empty database

`go-server/internal/db/migration/` holds two scripts (since 14 Sep 2026, and again since 23 Sep 2026, when
`V1.0.2__chip_ledger_game.sql` and `V1.0.3__users_is_bot.sql` were folded back in): `V1.0.0__baseline.sql`
(every table, column, check, index, function and trigger — the missile column and tables, the new-account `diamond`
default of 9, the pictures' `COIN`/`DIAMOND`/`HAMMER` currency check, `users.is_bot`, `chip_ledger.game`/`variant` and
the four table-configuration tables included) and `V1.0.1__seed.sql` (formerly `V1.0.1__seed_profile_pictures.sql`:
the 45 pictures — the 15 animals, 6 animated pictures priced in chips, 19 in hammers and 5 in diamonds — then the table
catalogue: 2 engines, 7 categories, the `table_settings` row, 12 public tables and 7 private templates, the code's
default menu). They build a database from nothing on the first boot. The only thing they bring forward on an older
database is a MISSING column of the three the baseline guards (`users.is_bot`, `chip_ledger.game`, `.variant`), and
no database built before the pictures' HAMMER currency boots this build: one built
by `go-server/v1.0.0` or older lacks `users.missile` (and one from `go-server/v1.3.0` or older,
`users.hammer`), and every database built before the hammer pictures
keeps `profile_pictures_currency_check` at `COIN`/`DIAMOND`, so the seed's first `HAMMER` row fails the
boot with `violates check constraint "profile_pictures_currency_check"` (PostgreSQL checks a row
before `ON CONFLICT DO NOTHING` can skip it, so rows already present do not save it). That is why
production started over on 14 Sep 2026 (`go-server/v1.1.0`). **Its database since then does not need to**: the
table-catalogue release (23 Sep 2026) boots on it — the guarded block adds `users.is_bot` (mind §7) and the four
configuration tables are created and seeded (§3). A start on an **empty** `public` schema is for when one is wanted,
and it deletes every account, wallet, ledger row, purchase record and owned picture — players come back as new
accounts with the welcome chips (3 lakh — production's `.env` sets `WELCOME_CHIPS=300000`), 9 diamonds, 20 hammers and
1 missile. Take the backup.

This is the order that worked on 13 Sep 2026 (`go-server/v1.2.0`), as `deploy`, no sudo. The facts
that shape it: `gameplay_app` owns every table and function but not the `public` schema, so "empty
the schema" means dropping every object inside it; `gameplay.service` is `Restart=always`,
`RestartSec=2s`, `StartLimitBurst=5` in 10 s, so the new binary must never boot against the old
schema (a crash loop can trip the start limit and leave the service down until someone runs sudo);
and a graceful SIGTERM writes table snapshots back to Redis (`kt:*`), so Redis is cleared *after* the
old process exits and *before* systemd starts the new one.

```bash
set -euo pipefail
cd /var/www/gameplay/king-teenpatti
DB="$(sed -n 's/^DATABASE_URL=//p' go-server/.env)"
psql "$DB" -Atc "SET statement_timeout = '10s'" \
  -c "SELECT tableowner FROM pg_tables WHERE schemaname = 'public' AND tablename = 'users'"   # gameplay_app = go on; postgres = §7 is applied: run its undo first
mkdir -p ~/backups && pg_dump -Fc "$DB" -f ~/backups/gameplay-pre-fresh-$(date -u +%Y%m%dT%H%M%SZ).dump
git fetch --tags && git checkout go-server/vX.Y.Z && bash go-server/ops/build.sh   # the running server is unaffected
psql "$DB" -1 -v ON_ERROR_STOP=1 <<'SQL'
SET lock_timeout = '5s';
SET statement_timeout = '30s';
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', r.tablename);
  END LOOP;
  FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname = 'public' LOOP
    EXECUTE format('DROP SEQUENCE IF EXISTS public.%I CASCADE', r.sequencename);
  END LOOP;
  FOR r IN SELECT p.oid::regprocedure AS fn FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', r.fn);
  END LOOP;
END $$;
SQL
PID=$(systemctl show gameplay -p MainPID --value); kill "$PID"
while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
redis-cli --scan --pattern 'kt:*' | xargs -r redis-cli DEL
```

If the drop fails, the script stops there and the old server keeps serving the old schema — nothing
is lost. Once systemd has started the new binary:

```bash
until curl -sf 127.0.0.1:3000/health >/dev/null; do sleep 1; done
curl -s 127.0.0.1:3000/health | python3 -c 'import json,sys; h=json.load(sys.stdin); print(h["ok"], h["version"])'
psql "$DB" -Atc "SET statement_timeout = '10s'" \
  -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'" \
  -c "SELECT count(*) FROM profile_pictures" \
  -c "SELECT count(*) FILTER (WHERE is_active), count(*) FROM table_configs"   # 14, then 45, then 19|19
journalctl -u gameplay -n 50 --no-pager | grep -iE 'restored|"level":"(WARN|ERROR)"'   # restored tables=0; no ERROR (a WARN naming the table keys, below, is expected)
curl -s 127.0.0.1:3000/health | python3 -c 'import json,sys; print(json.load(sys.stdin)["tableConfig"])'
bash go-server/ops/prod-version.sh                                                     # IN SYNC
```

**The fresh database holds the CODE's default table catalogue**, every row active. With production's `.env` naming
`LOBBY_TABLES` the server resolves to `env` and plays that line anyway (one WARN says so), exactly as before. If the
menu should be the database's, and production's is not the code default, run §3's step 2 now — export with the
`.env`, apply, check, `TABLE_CONFIG_SOURCE=db`, restart — rather than switching onto the seed and finding the lobby
changed. If production already had `TABLE_CONFIG_SOURCE=db` before the fresh start, its edits went with the old
database: run the export from the `.env` keys (which you kept for exactly this) or re-apply the edits, then restart.

Then restart `bot-play` the same way (kill its MainPID; `RestartSec=15s`) — the bots log in again as
fresh guests. §7 belongs to the database, not the release: a database started over has lost it, so
run §7 again if `users` should belong to `postgres`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `install-go-server.sh`: "bin/gameplay is missing" | run `bash ops/build.sh` as `deploy` first |
| `install-go-server.sh`: "`go-server/.env` not readable" | neither `go-server/.env` nor the old `server/.env` exists — copy the production `.env` to `go-server/.env` |
| journal: `config: PG_POOL_MAX: …` (or any key) at startup | strict integer/enum parsing of `.env`; fix the value, `sudo systemctl restart gameplay` |
| journal: `run V1.0.0__baseline.sql: ERROR: must be owner of table users` on the table-catalogue release | `postgres` owns `users` (§7) and the database lacks `users.is_bot`: add the column as `postgres` (§3, "Before the restart"), then restart |
| journal WARN `table config comes from the env keys, not the database` | `TABLE_CONFIG_SOURCE` is unset and the `.env` sets table keys, so the server plays those keys (env mode) — expected until §3's step 2 |
| journal WARN `table env keys are ignored in db mode` | expected after the switch: the table keys stay in `.env` for a rollback (§5), and the database is what plays |
| journal ERROR `table config row left out` | a row PostgreSQL accepted but this build must not open (unknown category, wrong engine, poker buy-in under the boot, …) — the rest plays; `./bin/gameplay -check-table-config` prints each, fix the row, restart |
| journal ERROR `table config in the database is unusable; running the env composition instead`, `/health` `tableConfig.fallback: true` | no settings row, no active public table, no private seen template (seen or `teen_patti` switched off), or the read failed — the server plays the `.env` keys; `-check-table-config` (exit 2) says which, fix, restart |
| psql refuses the export: `violates check constraint "table_configs_turn_timeout_ms_check"` (or a sideshow one) | the `.env` configures a clock the database does not allow (a turn under 5 s, a sideshow window under 1 s) — fine for tests, never for production; fix the key, export again. The transaction changed nothing |
| a `table_configs` edit "does nothing" | the catalogue is read once, at boot — restart; and a table restored from Redis keeps its old rules (it is drained, not changed) |
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
