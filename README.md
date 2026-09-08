# King Teen Patti

A turn-based multiplayer Teen Patti game: an authoritative **Socket.IO** game server written in
**Go** with **PostgreSQL** persistence (every chip movement is one transaction), a **Flutter**
client for Android (Material 3), and a bundled browser client for playing and testing without a
build. The server was first written in Node.js; the Go port replaced it on 8 Sep 2026 once it
matched the original wire-for-wire (141/141 black-box parity suites, identical event streams).
The Node implementation now lives only in git history — `git log -- server/`, and on `master` as
of the merge of PR #2 — and nothing here depends on it.

```
king-teenpatti/
├── go-server/       THE game server — one static Go binary (see go-server/README.md)
│   ├── cmd/gameplay/     entrypoint;  internal/{config,game,sio,socket,auth,db,metrics,app,util}
│   ├── public/           browser client — a zero-build protocol reference, served by the binary at /
│   ├── ops/              build.sh, systemd unit, install/rollback scripts, DEPLOY.md, monitoring/ (Prometheus + Grafana + alerts + nginx)
│   ├── .env.example      every env key the server reads, with defaults
│   └── PORT_PLAN.md, DECISIONS.md, PORT_NOTES/   how the port was done and every settled ambiguity
├── tools/           Node package: practice bots, load ramp, black-box parity suite (npm install here first)
│   └── parity/           the suites + lib/ (harness, launcher, raw Socket.IO client)
├── docs/load-reports/    ramp-test reports (HTML + JSON)
├── flutter-client/  Flutter client (Dart): the live app — lobby, table, chat, sideshow
├── CLAUDE.md        Detailed project context for coding sessions
└── Requirements.txt The original brief (items 1–34; there is no 11)
```

## The server

`go-server/` is a single process. Each table is an **actor** — one goroutine owns its state and
every mutation or read is a closure posted to it, so a database round-trip inside a move can never
interleave with a turn timer. Go's scheduler uses every core; there is no cluster and no Redis. It
carries its own WebSocket-only Engine.IO/Socket.IO server (`internal/sio`), talks to Postgres through
`pgx`, and serves the browser client and the `socket.io.js` bundle itself. Everything a client or the
database can observe — Socket.IO events, acks and error codes, REST bodies, JWTs, the schema and
ledger rows, `/health`, the `game_*` Prometheus metrics — is the contract the Node original defined
and the parity suites in `tools/parity/` still enforce.

```bash
export PATH=$HOME/.local/go/bin:$PATH          # Go 1.27.1; ops/build.sh installs it there when missing
cd go-server
go run ./cmd/gameplay                          # dev: reads ./.env if present → http://0.0.0.0:3000, browser client from ./public
bash ops/build.sh && ./bin/gameplay            # static, stripped, version-stamped binary (bin/ is git-ignored)
go test -race ./...                            # unit + Postgres-backed tests (they skip without a database)
```

Production deploys follow `go-server/ops/DEPLOY.md` (systemd unit `gameplay.service`, working
directory and `.env` in `go-server/`). Everything the Go server does differently from the Node
original on purpose — websocket only, no Redis, Go runtime metrics under `game_server_go_*`, a few
latent money-path bugs fixed — is listed in `go-server/PORT_PLAN.md` §9 and `go-server/DECISIONS.md`.

## Quick start

```bash
# PostgreSQL must be running with a database the server can use — by default
# postgres://postgres:postgres@localhost:5432/gameplay (see go-server/.env.example).
cd go-server
cp .env.example .env          # optional for local dev; set JWT_SECRET for anything public
go run ./cmd/gameplay         # creates the schema on first boot
```

Open <http://localhost:3000> in two browser tabs, press **Play as Guest** in each, then tap a
table. Two players are enough to start a hand. For the real client:

```bash
cd flutter-client
flutter build apk --debug     # default server: https://api.sungamestudio.com (production)
flutter build apk --debug --dart-define=SERVER_URL=http://10.0.2.2:3000   # local server from the emulator
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

## Tools (`tools/`, Node ≥ 20)

The bots, the load ramp and the parity harness are Node scripts in their own small package;
they are clients of the server and need `npm install` once:

```bash
cd tools && npm install
npm run bot -- --url http://localhost:3000 --count 3 --boot 200 --category blind      # practice bots (Ctrl-C to stop)
npm run bot -- --url http://localhost:3000 --count 8 --boot 200 --category blind --churn 40   # bots hop tables
npm run parity                                                                          # black-box suites against ../go-server/bin/gameplay
npm run parity -- --url http://127.0.0.1:3000 --schema public --filter rest             # attach to a running server
npm run parity:diff -- --a go --b http://127.0.0.1:3000 --schema-b public               # frame-by-frame traffic diff
npm run ramp -- --url http://localhost:3000 --stages 10,50,200,1000 --hold 40 --boot 200 --category blind --out ramp.json
```

`npm run parity` builds nothing: run `bash ops/build.sh` in `go-server/` first, or pass `--bin`.

## What is implemented

| # | Requirement | Where |
|---|---|---|
| 1 | Google, Facebook and guest (deviceId) login | [providers.go](go-server/internal/auth/providers.go), [handlers.go](go-server/internal/auth/handlers.go), [game_state.dart](flutter-client/lib/state/game_state.dart) |
| 2 | Persistent storage per provider identity — **PostgreSQL** (the brief said SQLite; changed by the owner) | [schema.sql](go-server/internal/db/schema.sql), [ledger.go](go-server/internal/db/ledger.go), [users.go](go-server/internal/db/users.go) |
| 3 | Rooms of at most 5 players | [table.go](go-server/internal/game/table.go), [roommanager.go](go-server/internal/game/roommanager.go) |
| 4 | 2 players minimum to start; many rooms | [table.go](go-server/internal/game/table.go) |
| 5 | 2 lakh welcome chips on first login | [users.go](go-server/internal/db/users.go) |
| 6a | 3 hidden cards each | [deck.go](go-server/internal/game/deck.go), [table.go](go-server/internal/game/table.go) |
| 6b | Clockwise turn rotation | [table.go](go-server/internal/game/table.go) |
| 6c | Bet the same amount or double | [table.go](go-server/internal/game/table.go) |
| 6d | 25-second turn clock, auto-pack on timeout | [table.go](go-server/internal/game/table.go) |
| 6e | Exactly one winner takes the whole pot | [table.go](go-server/internal/game/table.go) |
| 6f | Pack to fold, turn moves on | [table.go](go-server/internal/game/table.go) |
| 6g | Trail > pure sequence > sequence > color > pair > high card | [handrank.go](go-server/internal/game/handrank.go) |
| 7 | Account and chips restored on next login | [users.go](go-server/internal/db/users.go) |
| 8 | Room chat: in-memory, 100 messages, dies with the room | [chat.go](go-server/internal/game/chat.go) |
| 9 | +/− stepper doubles the bet, capped at the player's chips | [table.go](go-server/internal/game/table.go), [table_screen.dart](flutter-client/lib/screens/table_screen.dart) |
| 10 | Auto-pack when a turn is not acted on | [table.go](go-server/internal/game/table.go) |
| 12 | Chat panel collapses to a badge and reopens | [client.js](go-server/public/client.js), [table_screen.dart](flutter-client/lib/screens/table_screen.dart) |
| 13 | Blind/Seen categories at 200 and 5000; chip visibility per category | [table.go](go-server/internal/game/table.go), [view.go](go-server/internal/game/view.go), [roommanager.go](go-server/internal/game/roommanager.go) |
| 14 | Show reveals every hand to the room, with the winner and amount | [table.go](go-server/internal/game/table.go), [client.js](go-server/public/client.js) |
| 15 | The pot always pays out, even when the table empties | [table.go](go-server/internal/game/table.go) |
| 16 | Played / won / lost / abandoned counters and total winnings | [users.go](go-server/internal/db/users.go), [schema.sql](go-server/internal/db/schema.sql) |
| 17 | 25,000 chip reward at every 25 hands played | [users.go](go-server/internal/db/users.go), [handlers.go](go-server/internal/auth/handlers.go) |
| 18 | 10,000 chip bonus on a 4-hour countdown, stored in the database | [users.go](go-server/internal/db/users.go) |
| 19 | Seen tables: one double per turn, showdown after 7 rounds | [roommanager.go](go-server/internal/game/roommanager.go) |
| 20 | Profile picture taken from the Google/Facebook account | [providers.go](go-server/internal/auth/providers.go) |
| 21 | Pick a bundled picture; locked once seated; visible to everyone | [handlers.go](go-server/internal/auth/handlers.go), [profiles/](go-server/public/profiles/) |
| 22 | Private tables: fixed 200 boot, maximum win 500,000, one double per turn | [roommanager.go](go-server/internal/game/roommanager.go), [table.go](go-server/internal/game/table.go) |
| 23 | Landscape on phones, icons, light/dark toggle, Material 3 | [theme.css](go-server/public/theme.css), [app_theme.dart](flutter-client/lib/theme/app_theme.dart) |
| 24 | Two half-empty rooms merge; never mid-hand; "starting in N" countdown | [roommanager.go](go-server/internal/game/roommanager.go) |
| 25 | Leaving a table asks for confirmation first | [client.js](go-server/public/client.js), [main.dart](flutter-client/lib/main.dart) |
| 26 | 4-hour bonus in the top-left corner, counting down in seconds | [client.js](go-server/public/client.js) |
| 27 | Milestone reward in the bottom-right corner | [client.js](go-server/public/client.js) |
| 28 | Square table cards with a looping diagonal sheen | [style.css](go-server/public/style.css) |

## How the game works

**Dealing.** Every funded player antes the boot. Three cards are dealt one at a time from a
`crypto/rand` Fisher–Yates shuffle. **Card faces stay on the server** — a client is only sent its own
hand after the player presses *See*, so a modified client has nothing to read.

**Betting.** A blind player stakes the current unit; a seen player pays twice that — the standard
handicap for having looked. From that base the server builds a **bet ladder** that doubles on each
rung (base, 2x, 4x, 8x …).

The client shows one control: **[ − ][ Chaal *n* ][ + ]**. The steppers choose the amount — **+**
doubles it, **−** halves it — and the **Chaal** button is the only thing that places the bet. An
amount above the base rung is sent as a `raise`, so the hand history stays accurate while the player
only ever presses one button.

The ladder is truncated by whichever bites first, the table's pot limit or **the player's own chip
stack**, so a bet larger than a player holds is never offered — and never accepted: the server
recomputes the ladder and rejects any amount that is not on it, so a tampered client gains nothing.

**Turn clock.** 25 seconds, announced as an absolute deadline so the client counts down without
clock drift. Miss it and you are packed; play continues without you.

**Ending a hand.** Everyone else packs (last player standing), or a player pays for a *show* with
two left. A round cap forces a showdown so a pot can never run forever. Exactly one player wins;
an exact tie goes to the player who did *not* pay for the show.

**Money.** Database-first. A bet is validated in memory, then written as **one PostgreSQL
transaction** — the wallet row locked and debited, the pot credited, an append-only ledger row
carrying the client's `actionId` (unique, so a retried request can never charge twice), and the
table's versioned state — and only once that has committed does the table change what players see.
A write that fails leaves the game untouched and refuses the move. Settlement pays the winner in the
same shape. Every chip that ever moved is in `chip_ledger`, and `SUM(delta)` per player always
equals their balance.

**Showdown.** A show reveals every remaining hand to everyone at the table, with the winner and the
amount written across the middle of the felt until the next deal. Seen tables also force a showdown
once everyone has had 7 turns.

**Rewards.** Two, both server-authoritative: 25,000 chips at every 25 hands played, and 10,000 chips
on a 4-hour countdown. The milestone already collected and the next unlock time live in the
database, so neither can be farmed by replaying a request or reinstalling the app.

**Statistics.** Hands played, won, lost and abandoned, plus total winnings. A hand only counts as
*played* once the player commits chips beyond the boot — posting the ante and folding immediately
does not count, which is the rule the milestone reward is paid against.

**Profile pictures.** Google and Facebook pictures are captured at login. A player can instead pick
one of the pictures bundled in `go-server/public/profiles/`, and that choice is what everyone at the
table sees. Changing it is refused while seated, so a picture cannot swap mid-hand.

**Private tables.** Opened with a code rather than through the lobby. The boot is **fixed at 200
chips** — not a choice, so there is nothing to pick in the UI and a requested amount is simply
replaced. The most that can be won in a hand is **500,000**, and a player may double their chaal only
once per turn. A bet that would push the pot past the ceiling is never offered, and once no further
bet fits underneath it the hand goes straight to a showdown, so the cap is a real limit rather than
a number the pot drifts past.

**Filling tables.** Two rooms that have each dwindled to a single player are two rooms where nobody
can play, so the stragglers are merged onto one table — the longest-standing room wins, and the
emptied one is disposed of. Only idle tables are touched: **a table with a hand in progress is never
disturbed**, which is what stops a player being moved out from under a live game. Stake, category and
privacy all have to match, so nobody is moved to a table they did not choose. Once two players are
seated the room counts down and every client shows *"Starting game in N seconds"* against the same
server deadline.

**Rewards on screen.** The 4-hour bonus sits in the top-left corner and counts down in hours,
minutes **and seconds**, so the timer visibly moves; the milestone sits in the bottom-right. Both
light up and pulse when they are ready to collect, and both are lobby furniture — they would clash
with the chat button and the bet controls at a table.

**Leaving a table** asks first. The wording changes when a hand is live, because that is the case
where walking away actually costs something: the stake stays in the pot.

**Look and feel.** The interface follows **Material 3**: one tonal palette drives both schemes, with
filled and tonal buttons, state layers, elevation and the M3 shape scale. A ☀️/🌙 icon switches
light and dark, and the choice is remembered. Phones run the game in **landscape** — the Flutter app
locks the orientation, and the browser client lays the table out for a wide screen and asks a
portrait phone to turn.

**Chat.** Per room, in server memory, capped at 100 messages. A player joining mid-session is sent
the backlog; when the last player leaves, the room and its chat are destroyed together. Nothing is
written to the database. The panel is collapsed by default and reopens from a button that carries an
unread badge.

**Table categories.** The lobby offers two categories at each stake (200 and 5000):

| | Your chips | Other players' chips |
|---|---|---|
| **Seen** | visible | visible |
| **Blind** | visible | hidden |

Blind and seen tables at the same stake are separate rooms. The hiding is done when state is
serialized **for each viewer** — on a blind table another player's balance is never put on the wire,
so it is a real privacy boundary rather than something the client politely declines to draw. Bets
and the pot stay public in both categories, because those are announced as they happen.

Server tour, build and parity: [go-server/README.md](go-server/README.md). Architecture, the
Node→Go file map and the concurrency rules: [go-server/PORT_PLAN.md](go-server/PORT_PLAN.md).
The Socket.IO contract, event by event:
[go-server/PORT_NOTES/specs/spec-socket-protocol.md](go-server/PORT_NOTES/specs/spec-socket-protocol.md).
Everything a coding session needs to know, including the gotchas: [CLAUDE.md](CLAUDE.md).

## Measured performance

Same `tools/ramptest.mjs` ramp, both servers local on a 12-core dev box, real hands from 4,000
bot players: the **single Go process answered actions at p95 5 ms**; the Node process it replaced
answered the same load at p95 255 ms. The staged production runs against the Node build (4-core
host behind nginx, 8 Sep 2026) are in `docs/load-reports/` and are the baseline the Go server was
measured against:

| Report | What it shows |
|---|---|
| [production-2026-09-08.html](docs/load-reports/production-2026-09-08.html) | 10 → 1,000 players, 40 s holds: p95 ≈ 40 ms, 0 errors, no ceiling |
| [production-2026-09-08-run2.html](docs/load-reports/production-2026-09-08-run2.html) | soak at 1,000 / 1,500; nginx answered handshakes with 500 near 1,500 sockets (`worker_connections 768`) |
| [production-2026-09-08-run3.html](docs/load-reports/production-2026-09-08-run3.html) | the ceiling run that pinned the nginx limit |
| [production-2026-09-08-run5-4000.html](docs/load-reports/production-2026-09-08-run5-4000.html) | 1,500 → 4,000 after the nginx fix: 4,000 connected, 0 errors, p95 rising to ~1 s on one Node core |

Each `.html` has a `.json` twin written by the ramp tool. Reproduce with
`cd tools && npm run ramp -- --url <server> --stages 10,50,200,1000,2000,4000 --hold 60 --boot 200 --category blind --out ramp.json`.

## Testing

`cd go-server && go test -race ./...` runs every Go suite. The `internal/game` suites drive the
engine with a fake clock (`testclock`) and an in-memory ledger; the Postgres-backed suites
(`internal/db`, `internal/app`, `internal/socket`) each open a throwaway schema through
`dbtest.Open` and drop it afterwards, and skip when no database is reachable.

| Package | Covers |
|---|---|
| `internal/game` | Hand ranking, dealing, turn order, betting maths and the ladder, timeouts, showdowns, sideshow, seat keeping, settlement and chip conservation, blind rules, private tables, consolidation, chat buffer, redaction (`wire_test.go`) |
| `internal/sio` | The raw Engine.IO/Socket.IO framing, frame by frame, plus an interop test against `socket.io-client` from `tools/node_modules` |
| `internal/socket` | The realtime protocol: invalid moves, hostile payloads, leaks, money under concurrency |
| `internal/db` | Ledger transactions (`duplicate_action`, `stale_state`), users, rewards, display-name normalisation, `statement_timeout` |
| `internal/auth` | JWT (including tokens minted by Node's `jsonwebtoken`, via `tools/node_modules`), providers, REST handlers |
| `internal/app` | Real sockets + real PostgreSQL: auth, gameplay, room capacity, chat, `/health`, `/metrics`, static files |
| `internal/config`, `internal/metrics`, `cmd/gameplay` | Env parsing, the label-cardinality rule, the version stamp |

The differential tests that compared the Go engine with the Node one (`internal/game/interop_test.go`)
skip unless `NODE_REFERENCE_DIR` points at a checkout of the removed `server/` tree with its
`node_modules` installed. The black-box parity suites (`cd tools && npm run parity`) exercise the
built binary over real sockets. The Flutter client has `flutter analyze` and `flutter test` (money
formatting).

## Security notes

- Provider tokens are verified server-side. Google id_tokens are checked against the configured
  OAuth client ids; Facebook tokens are checked with `debug_token` including the `app_id`, without
  which any Facebook token from any app would be accepted.
- Guest device ids are SHA-256 hashed before storage — the database never holds a raw device id.
- Card faces are never sent to anyone but their owner, and only after they look.
- The deck is shuffled with `crypto/rand`, not `math/rand`, whose state is recoverable from a short
  run of outputs.
- Chip balances are server-authoritative; a negative balance is rejected at the database layer as a
  last line of defence.
- Bet amounts are validated against a ladder the server recomputes, so a client cannot bet an
  arbitrary figure or more than its stack.
- On a blind table another player's chip balance is never serialized to your client at all.
- One live session per account; a second sign-in disconnects the first.
- Per-socket rate limiting, with a tighter separate allowance for chat.
- A hung database statement fails one ledger write (`PG_STATEMENT_TIMEOUT_MS`, default 15 s) instead
  of freezing a table for good.

## Not included

- **Google/Facebook native sign-in SDKs.** The server verifies both providers, but the Flutter app
  does not bundle the native SDKs yet, so those buttons are disabled and guest login is the way in.
- **An iOS build.** Only `flutter-client/android/` exists so far; the Dart code has nothing
  platform-specific in it.
- **Multi-process scaling.** Accounts are shared through PostgreSQL, but a table lives in one
  process (`REDIS_URL` is read and logged as ignored). One Go process carried 4,000 players at
  p95 5 ms on the dev box, so sharding tables across processes has not been needed.
