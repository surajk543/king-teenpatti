# go-server — the King Teen Patti game server

The game server: one static Go binary, one process. It began as a port of the original Node 22 +
Express + Socket.IO + `pg` server and is **wire-identical** to it — same Socket.IO events and acks,
same REST bodies and statuses, same JWTs, same PostgreSQL schema and ledger rows, same `/health`
keys, same `game_*` Prometheus metrics — so the Flutter app, the browser client, the bots and the
load tools connect to it unchanged. The Node implementation was removed from the repository on
8 Sep 2026 once the port matched it (141/141 black-box parity suites, identical event streams); it
lives in git history only (`git log -- server/`; the last commit carrying it is `c19963b`, and the
`multi_node` branch still has it). The tooling that used to live beside it — bots, load ramp,
parity harness — is now the `../tools` package.

Go's scheduler uses every core; there is no cluster, no Redis.

## Architecture in one paragraph

Each table is an **actor**: one goroutine owns its state and every mutation or read is a closure
posted to it (`Table.run`), so a database round-trip inside a move can never interleave with a
turn timer — Node's `_run` promise queue made synchronous. The `RoomManager` holds only the two
index maps under a mutex that is never held while calling into a table. `internal/sio` is our own
Engine.IO v4 / Socket.IO v5 server (WebSocket only, on `gorilla/websocket`); `internal/socket`
speaks the game protocol on top of it. Money is database-first through `pgx`: validate in memory →
one transaction (lock wallet, debit, pot, append-only `chip_ledger` row with a UNIQUE `action_id`,
the live store's per-table `seq`) → only then mutate the table and broadcast. `PORT_PLAN.md` §3 is the full
set of concurrency rules; read it before touching `game`, `socket` or `sio`.

## Layout

```
go-server/
├── cmd/gameplay/            main: .env (godotenv) → config → db → app → listen; SIGTERM = graceful 8 s;  -version flag
├── internal/
│   ├── config/              every env key → one immutable Config (the keys in .env.example, + PUBLIC_DIR)
│   ├── game/                rules engine: constants, deck, handrank, chat, Table (actor), RoomManager, Ledger/Clock interfaces
│   │   └── testclock/       deterministic clock for unit tests (Advance)
│   ├── sio/                 Engine.IO v4 + Socket.IO v5 server, websocket only (our own; no library)
│   ├── socket/              the realtime protocol: handlers, per-viewer broadcast, grace, resume offers
│   │   └── testclient/      raw Socket.IO client used by the tests
│   ├── auth/                JWT HS256, Google/Facebook/guest providers, REST handlers, AuthError
│   ├── db/                  pgxpool, embedded schema.sql, Ledger, Users
│   │   └── dbtest/          throwaway test schemas (skips when Postgres is unreachable)
│   ├── metrics/             prometheus/client_golang; identical game_* names; process/Go runtime under game_server_
│   ├── app/                 mux, static browser client, /health, /metrics, REST, socket endpoint, Start/Shutdown
│   │   └── assets/          socket.io.min.js (MIT) served at /socket.io/socket.io.js for the browser client
│   └── util/                UUID, RoomCode, slog JSON logger
├── public/                  the browser reference client (index.html, client.js, style.css, theme.css, profiles/)
├── .env.example             every env key with its default — copy to .env
├── ops/                     production packaging — see ops/DEPLOY.md; ops/monitoring/ is the Prometheus/Grafana/nginx bundle
├── PORT_PLAN.md             architecture, Node→Go file map, concurrency rules, wire rules, deviations table (§9)
├── DECISIONS.md             every ambiguity settled; overrides PORT_PLAN §9 where they differ
└── PORT_NOTES/              per-package porting notes (what was ported, how it was tested, deviations) — they cite the removed Node source
```

## Build, run, test

Go 1.27 (`ops/build.sh` installs it into `~/.local/go` when missing). Postgres for the
DB-backed tests: `postgres://postgres:postgres@localhost:5432/gameplay` by default
(`TEST_DATABASE_URL`/`DATABASE_URL` override); without a reachable database those tests skip.

```bash
export PATH=$HOME/.local/go/bin:$PATH
cd go-server

go build ./... && go vet ./... && test -z "$(gofmt -l .)"      # compiles, vets, formatted
go test ./...                                                  # unit + Postgres-backed (skips without a DB)
go test -race ./...                                            # the actor/lock rules are what the race detector checks
go test -run TestVersionString ./cmd/gameplay                  # one test

go run ./cmd/gameplay                                          # dev run: reads ./.env if present; http://0.0.0.0:3000; browser client from ./public
bash ops/build.sh                                              # static, stripped, version-stamped → bin/gameplay (git-ignored)
./bin/gameplay -version                                        # gameplay <git describe> go1.27.1 linux/amd64
./bin/gameplay                                                 # same as go run, from the built binary
PORT=3001 PG_SCHEMA=test_me ./bin/gameplay                     # spare port, throwaway schema (drop it afterwards)
```

Every env key and default is in `internal/config/config.go` (`Defaults()`), documented in
`.env.example` and `../CLAUDE.md` §7.4. Three keys are Go-only:

- `PUBLIC_DIR` — the browser client's directory. Default `./public` relative to the working
  directory (i.e. `go-server/public` when started from `go-server/`); when that does not exist the
  binary falls back to `go-server/public` (started from the repository root). The systemd unit sets
  it explicitly.
- `ROOT_REDIRECT` (default empty) — set, it takes the browser client off the internet: `GET /`
  answers 302 to this URL (production: `/dashboard/`, the Grafana login), every top-level file of
  `PUBLIC_DIR` and the Socket.IO browser bundle are 404, and only the subdirectories keep serving
  (`privacy/`, `account-deletion/` for Google Play, `profiles/` for the Flutter avatars). Empty keeps
  the browser client at `/` for development and the parity harness.
- `PG_STATEMENT_TIMEOUT_MS` (default 15000) — Postgres `statement_timeout` on every pooled
  connection, so a hung query fails one ledger write (`persist_failed`, the move is refused) instead
  of freezing that table's actor; `0` disables it (Node's behaviour). See DECISIONS.md §5.

`REDIS_URL` is read and logged as ignored. Integers are parsed strictly; `TABLE_STAKES=`/`LOBBY_TABLES=`
empty mean unrestricted, as in Node.

### Tests that need Node

Three groups of Go tests reach for Node and skip cleanly when it is not there:

- `internal/auth/nodeinterop_test.go` (tokens minted by `jsonwebtoken` must verify in Go and vice
  versa) and `internal/sio/interop_test.go` (a real `socket.io-client` against our server) use
  `../tools/node_modules` — run `npm install` in `../tools` once.
- `internal/game/interop_test.go` compares every hand ranking and every sanitising result with the
  original Node engine. It skips unless `NODE_REFERENCE_DIR` points at a checkout of the removed
  `server/` tree with its `node_modules` installed, e.g.
  `git worktree add /tmp/node-ref c19963b` (the last commit that carries the tree; `git log -- server/`
  lists the others), `(cd /tmp/node-ref/server && npm ci)`, then
  `NODE_REFERENCE_DIR=/tmp/node-ref/server go test ./internal/game -run Interop`.

## Parity — the black-box suites

`../tools/parity/` runs the same scenarios over real sockets against whichever server is on the
other end; it is what proved the port and it is still the acceptance test for any change here. It
spawns the built binary on a throwaway schema (or attaches to a running server with `--url`).

```bash
cd ../tools && npm install
npm run parity                                                    # spawns ../go-server/bin/gameplay (build it first)
npm run parity -- --bin /path/to/gameplay --filter game,money --keep   # one suite, keep logs/schemas
npm run parity -- --url http://127.0.0.1:3000 --schema public --filter rest   # attach to a running server
npm run parity:diff -- --a go --b http://127.0.0.1:3000 --schema-b public     # frame-by-frame diff: spawned binary vs a live server
```

Then the real clients, unchanged: `npm run bot -- --url http://localhost:3000 --count 8 --boot 200 --category blind --churn 40`,
`npm run ramp -- --url http://localhost:3000 --stages 10,50,200,1000 --hold 40 --boot 200`,
the Flutter debug build with `--dart-define=SERVER_URL=http://10.0.2.2:3000`, and the ledger check
(`SUM(chip_ledger.delta) per user == users.chips`, `../CLAUDE.md` §4) must return 0.

## Deploying

`ops/DEPLOY.md` — build as `deploy` (`ops/build.sh`), install once with
`sudo bash ops/install-go-server.sh` (installs the Go unit *as* `gameplay.service`, same port and
metrics, copies the old `server/.env` to `go-server/.env` once, and removes the Node tree from the
host once the Go binary is healthy — `KEEP_NODE_TREE=1` skips that), verify, and
`ops/rollback-to-node.sh` to go back (it needs the Node tree restored from history first —
`git checkout c19963b -- server` — and says so). Every later deploy is `git pull origin master` →
`bash ops/build.sh` → `sudo systemctl restart gameplay`; `../steps.txt` is that routine in six lines.

## What differs from Node on purpose

`PORT_PLAN.md` §9 (table) and `DECISIONS.md` (the reasoning) list every deliberate deviation:
websocket only; no Redis; `game_server_go_*` runtime metrics instead of `nodejs_*`;
`/health process.node` is the Go version; JSON 404 for unknown `/api` paths and 400
`invalid_json` for bad bodies; a handful of latent Node bugs fixed on the money path (settle
statement order, retry after table destroy, `actionId` containing `:`, room-code collisions);
`PG_STATEMENT_TIMEOUT_MS`. Anything else that differs from the documented behaviour
(`../CLAUDE.md` §5–§7, `PORT_NOTES/specs/`) is a bug — the parity suites are how it is found.
