# go-server — the King Teen Patti game server in Go

The production game server: a Go port of `../server` (Node 22 + Express + Socket.IO + `pg`) that
is **wire-identical** to it — same Socket.IO events and acks, same REST bodies and statuses, same
JWTs, same PostgreSQL schema and ledger rows, same `/health` keys, same `game_*` Prometheus
metrics — so the Flutter app, the browser client, the bots and the load tools work against either
without a change. `../server` stays as the reference implementation, the parity oracle and the
home of the tooling (`tools/bot.js`, `tools/ramptest.mjs`, the parity harness).

One static binary, one process. Go's scheduler uses every core; there is no cluster, no Redis.

## Architecture in one paragraph

Each table is an **actor**: one goroutine owns its state and every mutation or read is a closure
posted to it (`Table.run`), so a database round-trip inside a move can never interleave with a
turn timer — Node's `_run` promise queue made synchronous. The `RoomManager` holds only the two
index maps under a mutex that is never held while calling into a table. `internal/sio` is our own
Engine.IO v4 / Socket.IO v5 server (WebSocket only, on `gorilla/websocket`); `internal/socket`
speaks the game protocol on top of it. Money is database-first through `pgx`: validate in memory →
one transaction (lock wallet, debit, pot, append-only `chip_ledger` row with a UNIQUE `action_id`,
versioned `game_states`) → only then mutate the table and broadcast. `PORT_PLAN.md` §3 is the full
set of concurrency rules; read it before touching `game`, `socket` or `sio`.

## Layout

```
go-server/
├── cmd/gameplay/            main: .env (godotenv) → config → db → app → listen; SIGTERM = graceful 8 s;  -version flag
├── internal/
│   ├── config/              every env key → one immutable Config (same keys as server/.env.example, + PUBLIC_DIR)
│   ├── game/                rules engine: constants, deck, handrank, chat, Table (actor), RoomManager, Ledger/Clock interfaces
│   │   └── testclock/       deterministic clock for unit tests (Advance)
│   ├── sio/                 Engine.IO v4 + Socket.IO v5 server, websocket only (our own; no library)
│   ├── socket/              the realtime protocol (socket/index.js): handlers, per-viewer broadcast, grace, resume offers
│   │   └── testclient/      raw Socket.IO client used by the tests
│   ├── auth/                JWT HS256, Google/Facebook/guest providers, REST handlers, AuthError
│   ├── db/                  pgxpool, embedded schema.sql (verbatim copy of server/src/db/schema.sql), Ledger, Users
│   │   └── dbtest/          throwaway test schemas (skips when Postgres is unreachable)
│   ├── metrics/             prometheus/client_golang; identical game_* names; process/Go runtime under game_server_
│   ├── app/                 mux, static browser client, /health, /metrics, REST, socket endpoint, Start/Shutdown
│   └── util/                UUID, RoomCode, slog JSON logger
├── ops/                     production packaging — see ops/DEPLOY.md
├── PORT_PLAN.md             architecture, Node→Go file map, concurrency rules, wire rules, deviations table (§9)
├── DECISIONS.md             every ambiguity settled; overrides PORT_PLAN §9 where they differ
└── PORT_NOTES/              per-package porting notes (what was ported, how it was tested, deviations)
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

bash ops/build.sh                                              # static, stripped, version-stamped → bin/gameplay
./bin/gameplay -version                                        # gameplay <git describe> go1.27.1 linux/amd64

# run locally against the dev database, serving the browser client from ../server/public
cd ../server && ../go-server/bin/gameplay                      # reads ./.env if present; http://0.0.0.0:3000
PORT=3001 PG_SCHEMA=test_me PUBLIC_DIR=$PWD/public ../go-server/bin/gameplay   # spare port, throwaway schema
```

Every env key and default is in `internal/config/config.go` (`Defaults()`), documented in
`../server/.env.example` and `../CLAUDE.md` §7.4. The one Go-only key is `PUBLIC_DIR` (default
`../server/public` relative to the working directory, falling back to `./public`). `REDIS_URL` is
read and logged as ignored. Integers are parsed strictly; `TABLE_STAKES=`/`LOBBY_TABLES=` empty
mean unrestricted, as in Node.

## Parity against the Node server

`../server/test/parity/` is a black-box suite that runs the same scenarios against whichever
server is on the other end, and `parity-diff` records both servers' traffic and diffs it after
normalisation. Both need a built binary. From `server/`:

```bash
cd ../server && npm ci
npm run parity -- --target node                                        # the oracle must pass first
npm run parity -- --target go --bin ../go-server/bin/gameplay           # same suites against Go
npm run parity:diff -- --a node --b go --bin ../go-server/bin/gameplay  # frame-by-frame diff of both
npm run parity -- --target go --bin ../go-server/bin/gameplay --filter game,money --keep   # one suite, keep logs/schemas
```

Then the real clients, unchanged: `node tools/bot.js --count 8 --boot 200 --category blind --churn 40 --url http://localhost:3000`,
`node tools/ramptest.mjs --url http://localhost:3000 --stages 10,50,200,1000 --hold 40 --boot 200`,
the Flutter debug build with `--dart-define=SERVER_URL=http://10.0.2.2:3000`, and the ledger check
(`SUM(chip_ledger.delta) per user == users.chips`, `../CLAUDE.md` §4) must return 0.

## Deploying

`ops/DEPLOY.md` — build as `deploy` (`ops/build.sh`), install once with
`sudo bash ops/install-go-server.sh` (replaces the Node service *inside* `gameplay.service`, same
port/env/metrics), verify, and `ops/rollback-to-node.sh` to go back. Every later deploy is
`git pull` → `bash ops/build.sh` → `sudo systemctl restart gameplay`.

## What differs from Node on purpose

`PORT_PLAN.md` §9 (table) and `DECISIONS.md` (the reasoning) list every deliberate deviation:
websocket only; no Redis; `game_server_go_*` runtime metrics instead of `nodejs_*`;
`/health process.node` is the Go version; JSON 404 for unknown `/api` paths and 400
`invalid_json` for bad bodies; a handful of latent Node bugs fixed on the money path (settle
statement order, retry after table destroy, `actionId` containing `:`, room-code collisions).
Anything else that differs is a bug in the port — the parity suites are how it is found.

Go-only key: `PG_STATEMENT_TIMEOUT_MS` (default 15000) sets Postgres `statement_timeout` on every pooled connection; `0` disables it (Node's behaviour). See DECISIONS.md §5.
