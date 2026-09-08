# PORT_PLAN.md — King Teen Patti server, Node → Go

This directory is the Go port of `server/` (Node 22 + Express + Socket.IO + `pg`). The Node
code in the **working tree** of `/server` is the single source of truth — read it, never
`git show HEAD:…`. `CLAUDE.md` at the repo root is the detailed behavioural reference; every
doc comment in this module cites the Node file (and requirement number) it was ported from.

The skeleton compiles (`go build ./... && go vet ./...`) with every exported identifier,
struct, json tag, constant and doc comment in place. Function bodies are
`panic("not ported: <pkg>.<Func>")` unless trivially correct. **Porters fill in one package
each without changing any exported signature.** If a signature must change, change it in
the skeleton first, `go build ./...`, and tell the other porters — that is the whole point
of having the skeleton.

---

## 1. Fixed architecture decisions

1. **Module** `github.com/surajk543/king-teenpatti/go-server`, `go 1.27`. **Single process**;
   Go's scheduler uses every core. No Redis adapter, no cluster/worker registry, no worker
   ids (`REDIS_URL` is read and logged as ignored).
2. **Layout**

   | Package | Node source | Purpose |
   |---|---|---|
   | `cmd/gameplay` | `src/index.js` (entrypoint block) | `.env` via godotenv, config, open DB, build app, listen, SIGINT/SIGTERM graceful shutdown (8 s budget) |
   | `internal/config` | `src/config/index.js`, `.env.example` | every env key → one immutable `*Config`; `Defaults()` is the shared vocabulary |
   | `internal/game` | `src/game/*.js` | constants, deck, handrank, chat, errors, `Ledger` + `Clock` interfaces, `Table` (actor), `RoomManager` |
   | `internal/game/testclock` | `test/helpers/fakeTimers.js` | deterministic clock (`Advance`) — **implemented** |
   | `internal/sio` | socket.io / engine.io | our own Engine.IO v4 + Socket.IO v5 server, **WebSocket only**, on gorilla/websocket |
   | `internal/socket` | `src/socket/index.js` | the game's realtime protocol on top of sio; implements `game.Listener` and `game.RoomListener` |
   | `internal/auth` | `src/auth/{tokens,providers,routes}.js` | JWT HS256, login providers, REST handlers, `AuthError` |
   | `internal/db` | `src/db/{index,ledger,users}.js`, `schema.sql` | pgx v5 pool, embedded schema bootstrap, `WithTx`, `Ledger` (implements `game.Ledger`), `Users` |
   | `internal/db/dbtest` | test env setup in the process suites | `dbtest.Open(t, pkg)`: throwaway schema, skip when Postgres is unreachable — **implemented** |
   | `internal/metrics` | `src/metrics/index.js` | prometheus/client_golang; identical `game_*` names; process/Go metrics under `game_server_` |
   | `internal/app` | `src/index.js` (`createServer`) | mux, static dir, `/health`, `/metrics`, REST, socket endpoint, `Start`/`Shutdown` |
   | `internal/util` | `src/util/{ids,logger}.js` | `UUID()`, `RoomCode()` (**implemented**), slog JSON logger |

3. **Dependencies** (all in `go.mod`, pinned; do not add more without a line in §9):
   `github.com/gorilla/websocket`, `github.com/jackc/pgx/v5` (+`pgxpool`),
   `github.com/golang-jwt/jwt/v5`, `github.com/prometheus/client_golang`,
   `github.com/google/uuid`, `github.com/joho/godotenv`.
4. **Table concurrency = actor.** See §3.
5. **RoomManager locking.** See §3.
6. **`game.Ledger`** mirrors `db/ledger.js` exactly: `Bet`, `CollectBoot`, `Settle`; request/
   result structs carry everything `table.js` reads (`persisted`, `balances`, hand/pot ids,
   action ids, reasons); errors are `*game.GameError` with the same snake_case codes.
   **`game.Clock`** (`Now`, `AfterFunc → Timer.Stop`) is the only time source; production
   `game.RealClock{}`, tests `testclock.Fake`.
7. **Wire compatibility is absolute.** See §4.
8. **Money is `int64`** everywhere. **Time is `time.Time`** internally, **epoch milliseconds**
   (`game.Millis`) on the wire and in the DB (`BIGINT`), exactly as Node's `Date.now()`.
9. **Errors:** `game.GameError{Code, Message, UserID, Cause}`, `auth.AuthError{Code, Message,
   Status}`; constructors `game.NewGameError`, `game.Errorf`, `auth.NewAuthError`; both
   implement `Is` on `Code` so `errors.Is`/`errors.As` work; `game.CodeOf(err, fallback)`.
10. **Tests:** standard `go test ./...`. Postgres-backed tests call `dbtest.Open(t, "<pkg>")`
    → schema `test_<pkg>_<rand>`, dropped in `t.Cleanup`; `t.Skip` when
    `TEST_DATABASE_URL`/`DATABASE_URL`/the default `postgres://postgres:postgres@localhost:5432/gameplay`
    is unreachable. See §6.

---

## 2. Node → Go file map (what to read before porting each file)

| Go file | Port of | Notes |
|---|---|---|
| `internal/config/config.go` | `config/index.js` | `FromEnv(lookup)` for tests; `ParseDuration` = jsonwebtoken's `expiresIn` grammar |
| `internal/game/constants.go` | `game/constants.js` + string literals scattered in `table.js`/`socket/index.js` | **filled in** — categories, states, actions, win/pack/leave/kick/sideshow reasons, ledger reasons, verbatim messages |
| `internal/game/errors.go` | `GameError` (table.js), `LedgerError` (ledger.js), `KNOWN_ERROR_CODES` (socket) | **filled in** — every code and every refusal message |
| `internal/game/deck.go` | `game/deck.js` | card codes **filled in**; `Shuffle`/`Deal` stubs |
| `internal/game/handrank.go` | `game/handRank.js` | run strength on the doubled scale (A-K-Q 28 > A-2-3 27 > K-Q-J 26 … 4-3-2 8) |
| `internal/game/chat.go` | `game/chat.js` | `RoomChat` owned by the Table, actor-only |
| `internal/game/clock.go` | `defaultTimers` in table.js + `Date.now()` | `Millis`/`FromMillis` |
| `internal/game/ledger.go` | `memoryLedger` (table.js) + the ledger.js call shapes | `MemoryLedger` with `Settle`/`PersistChips` hooks for unit tests |
| `internal/game/snapshot.go` | `_snapshot` / `_endHand` `record` | DB-side JSON — never sent to clients |
| `internal/game/view.go` | `serializeFor`, `betOptions`, `turnOptions`, `summary` | wire structs with the null/omit rules encoded |
| `internal/game/events.go` | the `emit(...)` calls in table.js | `Listener` (one method per event) + payload structs |
| `internal/game/table.go` | `class Table` | actor; every private method's doc is its spec |
| `internal/game/roommanager.go` | `game/roomManager.js` | `RoomListener`, `tableHooks` (kick → Leave in a goroutine) |
| `internal/sio/*.go` | socket.io-parser v4 / engine.io v6 (server side) | frame grammar in the package doc |
| `internal/socket/wire.go` | event names + payloads in `socket/index.js` | **filled in** — every event, ack, message |
| `internal/socket/handler.go` | `attachSocketHandlers` | `Attach`, `guard`, one method per client event, disconnect grace, resume offers |
| `internal/auth/tokens.go` | `auth/tokens.js` | claims `{sub, provider, name, iat, exp}` HS256 — Node-issued tokens must verify |
| `internal/auth/providers.go` | `auth/providers.js` | Google (JWKS by hand), Facebook Graph, guest sha256, fake providers |
| `internal/auth/http.go` | `auth/routes.js` + the error middleware in index.js | 8 routes, `RequireAuth`, `WriteError`, response structs |
| `internal/db/db.go` | `db/index.js` | `search_path` as a **connection parameter**, schema bootstrap from `//go:embed schema.sql` |
| `internal/db/schema.sql` | `db/schema.sql` | **verbatim copy** — `diff` it against the Node file whenever either changes |
| `internal/db/ledger.go` | `db/ledger.js` | SQL quoted verbatim in the doc comments |
| `internal/db/users.go` | `db/users.js` | `User` wire struct, rewards, `NormalizeDisplayName` (`\p{M}` matters) |
| `internal/metrics/names.go` | metric names/labels in `metrics/index.js` | **filled in** |
| `internal/metrics/metrics.go` | the rest of `metrics/index.js` | `New`, `Bind*`, `Handler`, `HTTPMiddleware`, `SafeLabel`, `Timed` |
| `internal/app/app.go` | `createServer` + `/health` | `HealthResponse`/`ProcessHealth` field mapping in the doc |
| `cmd/gameplay/main.go` | entrypoint block | mostly written; the Start/Shutdown block is described inline |

---

## 3. Concurrency rules (read twice)

### 3.1 The Table is an actor
* `NewTable` starts one goroutine (`loop`) that owns all "actor-owned" fields.
* Every mutation and every read of actor state is a closure posted with `run(fn)`, which
  **blocks until fn has finished** — Node's `_run` promise queue, made synchronous. A Ledger
  round-trip inside a move therefore blocks the table for its duration, and a turn timeout
  queued behind it runs afterwards and finds `hand.turnToken` changed → no-op. This is the
  Node semantics and is required for correctness.
* **Entry points wrap themselves in `run`; internals never do.** Calling `run` from a
  closure that is already on the actor deadlocks (Node's `_run` would await itself). There is
  no runtime guard — keep the discipline: exported methods post, unexported ones don't.
* **Timers** (`clock.AfterFunc`) fire on some other goroutine; the callback must be
  `func() { _ = t.run(func() { t.onTurnTimeout(seat, token) }) }`. `ErrTableDestroyed` from a
  late timer is ignored.
* **Events are delivered synchronously on the actor goroutine** to the single `Listener`, in
  the exact order Node emitted them, each with a `*View` valid only during the call.
  Listeners **must not** call any posting method of that table (deadlock), must not block
  (no DB, no network, no lock a Table caller may hold), and must not retain the `View`.
  Anything that needs to call back into a Table or the RoomManager goes in a **new goroutine**.
* **Lock-free reads** for everyone else: `ID/Code/Category/IsPrivate/Config/BootAmount/MaxPot/
  CreatedAt` (immutable), `PlayerCount/IsFull/IsEmpty/HasHand/State/Version/Destroyed`
  (atomics the actor updates after every mutation). `SerializeFor/Summary/Seats/FindSeat/
  ChatHistory` post a read closure.
* **Destroy**: ends a live hand (`all_left`), stops timers, clears chat, marks destroyed, stops
  the loop, cancels `ctx`. Every later post returns `ErrTableDestroyed` (a `GameError`, code
  `table_destroyed`). The retry-settle timer body runs **on the actor** (Node ran it outside
  the queue and mutated seats concurrently — the port does not copy that bug).

### 3.2 RoomManager
* `mu` protects **only** `tables` and `playerRooms`. It is **never held while calling into a
  Table** (any Table method may block on the actor, which may be inside a Ledger write).
  Pattern: lock → look up / decide → unlock → call the table → lock → record.
* `Join` (and therefore `QuickJoin`/`JoinByCode`/`SwitchTable`) **reserves**
  `playerRooms[userId] = roomId` under the lock **before** `AddPlayer`, so a concurrent second
  join is refused with `already_in_room`, and deletes the reservation if `AddPlayer` fails.
* `Leave` deletes `playerRooms` **first**, then `RemovePlayer` (Node: "off the index first").
* `DestroyTable` removes the table and its players from the maps **before** `table.Destroy()`
  (the possibly slow settlement) so nobody can be seated at a table on its way out.
* Table events that need the RoomManager are handled by `tableHooks` **in a new goroutine**:
  `OnKick → Leave(userId, reason) → RoomListener.OnPlayerKicked`. `OnPersistError`/`OnError`
  just log. Everything else is forwarded unchanged to the socket layer's Listener.
* All methods Node marked `async` are ordinary blocking methods.

### 3.3 Socket layer
* `Handler.mu` guards the four maps (`roomSockets`, `userSockets`, `pendingRemovals`,
  `resumeOffers`). It is **never held** while calling a Table or the RoomManager, and never
  while emitting to a socket. Lock → copy → unlock → act.
* `game.Listener` methods run on a table's actor: they may use the `*View` and take `mu`
  briefly; they must not call Table/RoomManager methods. Kick handling therefore moved from
  the table listener (Node) to `RoomListener.OnPlayerKicked` (Go), which runs off-actor.
* sio handlers run one at a time per socket, concurrently across sockets; they may block.

### 3.4 Deadlock checklist
| Never do this | Because |
|---|---|
| Call `table.Act/AddPlayer/…/SerializeFor/Seats` inside a `Listener` method | posts to the actor that is delivering the event |
| Call `run` from an unexported Table method | same |
| Hold `RoomManager.mu` while calling any Table method | the actor may be blocked on the DB; the RoomManager freezes |
| Hold `socket.Handler.mu` while calling a Table, the RoomManager, or `Socket.Emit` | a slow client or a DB write stalls every socket |
| Call `testclock.Fake.Advance` from a Listener | the fired timer posts to the delivering actor |
| Block in a Listener on a channel/lock another goroutine fills only after posting to the same table | circular wait |

---

## 4. Wire-compatibility rules

Everything a client can observe is identical to Node: JSON field names, null-vs-absent,
error codes, ack shapes, event names, JWT claims, REST bodies and statuses, `/health`,
metric names/labels/buckets. The wire types live in the package that produces them and
are the only thing that may be serialised (never `map[string]any`).

### 4.1 null vs absent vs empty — encoded in the struct tags
| Field | Rule |
|---|---|
| `TableView.startsAt/sideshow/turn/you`, `TurnView.userId/deadline` | `null` when absent → pointer, no omitempty |
| `SeatView.chips` | `null` (never 0) for other players on a BLIND table, always set for the viewer / seen tables → `*int64` |
| `SeatView.avatarUrl/lastAction`, `User.email/avatarUrl/…`, `HandEnded.winnerId/winnerName`, `SideshowResolved.packedUserId` | `null` when none → pointer |
| empty seat | exactly `{"seatIndex":n,"status":"empty"}` → `SeatView.Empty` + `MarshalJSON` |
| `you.cards`, `options.raiseSteps`, `handEnded.reveals`, `chat:history.messages`, `Snapshot.seats[i].cards`, `profiles`, `lobbyOptions.stakes/tables` | `[]` **never null** → always allocate a non-nil empty slice (Go marshals a nil slice as `null`) |
| `summary[i].cards` | `null` unless revealed at showdown → nil slice is correct here |
| `session:ready.resume` | **absent** unless offered → `omitempty` pointer |
| `game:action.reason` | present only on a pack → `omitempty` string |
| `game:action.auto` | present (`true`/`false`) only on a SEE → `*bool` + `omitempty` |
| `chat message.system` | present only when true; `userId` is `null` for system lines |
| `ActResult` fields | vary by action — see the struct doc |
| acks | `{ok:true, ...result}` / `{ok:false, code, message}`; `ping:rtt` ack has **no `ok`** |
| `Snapshot.seats` | `null` entries for empty seats → `[]*SnapshotSeat` |
| numbers | never `omitempty` on a numeric wire field unless Node omitted it — a legitimate 0 would vanish |

### 4.2 Protocol constants that must not drift
* Engine.IO OPEN: `pingInterval 20000`, `pingTimeout 25000`, `maxPayload 100000`, `upgrades []`.
* Handshake refusals: HTTP 400 `{"code":0,"message":"Transport unknown"}` for anything but
  `transport=websocket`; `{"code":5,…}` for `EIO != 4`. `CONNECT_ERROR` is
  `44{"message":"<code>"}` with the code from the auth middleware
  (`missing_token | invalid_session | unknown_user | unauthorized`).
* Rate limit: 30 requests / 5 s per socket; a trip **acks** `{ok:false, code:"rate_limited"}`
  **and** emits `game:error` (Node also acks — see `guard`). Chat: `CHAT_RATE_LIMIT`/window.
* `game:action.amount` must be a JSON number that is a safe integer; strings/arrays/booleans →
  `invalid_bet`. `actionId` used only when 1–64 chars.
* JWT: HS256, claims `sub, provider, name, iat, exp` only. Tokens the Node server issued
  must verify (rolling deploy).
* REST errors `{error, message}`; `AuthError.Status`; `GameError` → 400; else 500
  `internal_error`. Reward 409s carry `user` (+ `readyAt` for the bonus). `seated` 409 on
  avatar/name while at a table.
* `/health` keys: `ok, uptime, tables, players, activeHands, sockets, process{pid, node,
  rssMb, heapUsedMb, heapTotalMb, externalMb, cpuPercent, loopLagP50Ms, loopLagP99Ms,
  loopLagMaxMs}, db{total, idle, waiting}`.
* Metrics: every `game_*` name, help string, label set and bucket list in
  `metrics/names.go`; **no label ever carries an id, code, name, URL or IP** — pass values
  through `SafeLabel(value, knownSet, "other")`.

### 4.3 Time
Config durations are `time.Duration`; convert with `.Milliseconds()` where the wire wants
`*Ms` (`turnTimeoutMs`, `sideshowTimeoutMs`, `timeoutMs`, `bonusIntervalMs`). Timestamps are
`game.Millis(clock.Now())` — never `time.Now()` directly inside game/socket code (tests
drive the clock).

---

## 5. Behavioural invariants every porter must keep (CLAUDE.md §5–§7 condensed)

* **Database-first money.** Validate in memory → one transaction (lock wallet, debit, pot,
  append-only ledger row with UNIQUE `action_id`, versioned `game_states`) → **only then**
  mutate the Table and emit. A refused write changes nothing and acks `{ok:false, code}`.
  `SUM(chip_ledger.delta) per user == users.chips` must stay true (psql check in CLAUDE.md §4).
* **Idempotency ids:** client `actionId` for bets/shows; `<handId>:boot:<userId>` and
  `<handId>:settle:<userId>` (`game.BootActionID/SettleActionID`).
* **`persisted` is reported by the Ledger, not assumed**: Postgres banks all of it, a bookless
  `MemoryLedger` banks 0; settlement `delta = net + persisted`.
* **Settlement** is the one place memory changes before the write commits; failure → pay the
  winner in memory, retry the idempotent write (10 attempts, `min(30s, NextHandDelay×n)`).
* **Winner by userId, not seat**; `all_left` pays `lastDeparture`; the pot is never split;
  exact ties: show-payer loses, else nearest the dealer's left; sideshow tie goes against
  the asker.
* **`hand.stake` stays in blind units** (`floor(amount/2)` after a seen bet); a client bet
  must be exactly a ladder rung; `raise ≥ 2×steps[0]`; a show costs `chaal` and is never free.
* **SEE** is free, allowed off-turn, doesn't move the turn or reset the clock; auto-reveal at
  `MaxBlindMoves` — that last bet is still charged at the blind rate.
* **Rounds** count when the turn steps *over* `startSeat` by distance.
* **Turn clock 25 s** → `missedTurns++`, pack `timeout`; `MaxMissedTurns` → `kick idle`;
  `missedTurns` resets only after a successful own move.
* **`sweepUnfunded` only between hands**, `kickPending` prevents double kicks.
* **Redaction (`serializeFor`) — do not break**: see `TableView` doc.
* **Quick-join order**: not seated → stake allowed → normalise category → pair offered →
  chips ≥ boot → entry cap → fullest matching public table else create. **Switch**: no entry
  cap, leave reason `moved` (no consolidation).
* **Consolidation**: lone players on idle public tables of the same `category:boot` merge
  onto the **oldest**; empty tables older than a **hardcoded 30 s** are swept.
* **Disconnect**: seat held `ReconnectGrace` (60 s) → `Leave(disconnected)` + resume offer
  (`ResumeOffer`, 10 min, offered once, table alive and not full) → `session:ready.resume`.
* **One live socket per user** → `session:replaced` to the old one.
* Every login **overwrites `display_name`** (known issue vs requirement 29) — keep it.

---

## 6. Testing plan

* **Unit (no DB):** `internal/game` — port `test/*.test.js` (table, tableRules, blindRules,
  raiseLadder, sideshow, seatKeeping, settlement, chipPersistence, consolidation,
  categories, lobbyRules, privateTables, handRank, chat, invalidMoves) using
  `game.NewMemoryLedger(hooks)` + `testclock.Fake`. `await advance(ms)` becomes
  `clock.Advance(d)` (synchronous, waits for each callback); `await table.settled()` becomes
  `table.Settled()`. Force deterministic showdowns by a test-only seam that sets seat cards
  (add an unexported `setCardsForTest` in a `_test.go` file of package `game` — never an
  exported method).
* **Postgres-backed:** `internal/db` (ledger transactions, uniqueness → `duplicate_action`,
  `stale_state`, users/rewards, `NormalizeDisplayName`), `internal/app` (integration,
  socketProtocol, stakes, statsAndRewards, metrics). Each test calls `dbtest.Open(t, "<pkg>")`;
  it skips when Postgres is unreachable, so `go test ./...` always passes on a laptop without
  a database and exercises everything on the dev box (`gameplay`, `postgres`/`postgres`).
  Leftover schemas: `select nspname from pg_namespace where nspname like 'test_%'`.
* **Wire tests:** port `test/helpers/csharpJsonPort.js` + `test/socketProtocol.test.js` to
  `internal/sio/protocol_test.go` / `internal/app/socket_test.go` (raw WebSocket, frame by
  frame). Port `test/metrics.test.js`'s last test — parse every label in the exposition and
  assert none is an id/code/URL/IP.
* **Acceptance against the real clients (no code changes allowed on their side):**
  1. `cd server && node tools/bot.js --count 8 --boot 200 --category blind --churn 40 --url http://localhost:3000`
     against the Go binary — bots play, switch, sideshow, chat.
  2. `node tools/ramptest.mjs --url http://localhost:3000 --stages 10,50,200,1000 --hold 40 --boot 200`.
  3. Flutter debug build with `--dart-define=SERVER_URL=http://10.0.2.2:3000` on `TP_Tall`
     and `TP_Small`; the browser client at `/`.
  4. `PGPASSWORD=postgres psql … "select count(*) from users u join (select user_id, sum(delta) s from chip_ledger group by user_id) l on l.user_id=u.id where l.s <> u.chips"` → 0.
* `go vet ./...` and `gofmt -l .` (empty) are part of "done". Run `go test -race ./...` for
  `internal/game` and `internal/socket` — the actor/lock rules above are exactly what the race
  detector checks.

---

## 7. Coding conventions

* `gofmt`; `go vet` clean; no `//nolint`.
* Doc comments on every exported identifier, written as **the specification the porter
  implements**: cite the Node file/function and `Requirement N` where the Node comment did.
* **No global mutable state** except the Prometheus registry inside `*metrics.Metrics`
  (and even that is a value the app owns; nothing else is package-level). Config is passed,
  not imported from a singleton.
* `context.Context` is the first parameter of every DB call and of anything that may block
  on I/O (`Ledger`, `Users`, `Verifier`, `Shutdown`). Table/RoomManager methods do not take a
  ctx — they are in-memory operations bounded by the Table's own ctx.
* Structured logging via `*slog.Logger` with attribute names identical to Node's `meta` keys
  (`roomId`, `userId`, `code`, `bootAmount`, `category`, `isPrivate`, `maxPot`, `reason`,
  `error`). **The Table never logs — it emits**; RoomManager logs table events.
* Errors: return `*game.GameError`/`*auth.AuthError` for anything a client is told about;
  wrap driver errors in `Cause`; compare by `Code`, never by message. Messages are the verbatim
  Node strings in `game/errors.go`, `auth/http.go`, `socket/wire.go`.
* Money `int64`; counts `int`; durations `time.Duration`; wire timestamps `int64` ms.
* Wire types: explicit structs with json tags, defined in the producing package; the socket
  layer embeds game payloads to add `roomId` (Node's `{...payload, roomId}`).
* Enums are typed string constants (`game.Category`, `TableState`, `SeatState`, `Action`,
  `WinReason`); plain-string reasons (pack/leave/kick/sideshow) are `const` strings.
* Unexported Table internals keep Node's names minus the underscore (`maybeStart`,
  `startHand`, `setTurn`, `advanceTurn`, `pack`, `endHand`, `retrySettle`, `snapshot`,
  `serializeFor`, `betOptions`, `turnOptions`, `sideshowBlockedReason`, …) so a reviewer can
  read the two side by side.
* No package may import `internal/socket` or `internal/app` except `app`/`cmd`. `metrics`
  imports `game` (for `*game.Table` in `RoomsSource`); `game` must **not** import `metrics`
  (it uses `MetricsHooks` func fields instead) — that is the one cycle to watch.

---

## 8. Package contracts at a glance

* `game.Table` — posting mutations: `AddPlayer, RemovePlayer, SetConnected, SetChips, PostChat,
  StartHand, Act, RespondToSideshow, Destroy, Settled`; posting reads: `SerializeFor, Summary,
  Seats, FindSeat, ChatHistory`; lock-free: `ID, Code, Category, IsPrivate, Config, BootAmount,
  MaxPot, CreatedAt, PlayerCount, IsFull, IsEmpty, HasHand, State, Version, Destroyed`.
* `game.View` (inside callbacks only) — `ID, Code, Category, IsPrivate, Config, State, HasHand,
  Pot, SerializeFor, Seats, FindSeat, ChatHistory, Summary`.
* `game.Listener` — `OnState, OnSeatUpdated, OnChat, OnHandStarted, OnCards, OnTurn, OnAction,
  OnSideshowRequested, OnSideshowReveal, OnSideshowResolved, OnShowdown, OnHandEnded, OnKick,
  OnPersistError, OnError`.
* `game.RoomManager` — `StartSweeper, AssertStakeAllowed, AssertTableOffered, CreateTable,
  GetTable, GetTableByCode, GetTableForPlayer, ListTables, LobbyOptions, LiveTables, QuickJoin,
  JoinByCode, SwitchTable, Join, Leave, DestroyTable, ConsolidateTables, SweepEmptyTables,
  Stats, Shutdown`; `RoomListener` — `OnTableCreated, OnTableDestroyed, OnPlayerMoved,
  OnPlayerKicked`.
* `game.Ledger` — `Bet, CollectBoot, Settle` (+ `MemoryLedger`, `BootActionID`, `SettleActionID`).
* `sio.Server` — `ServeHTTP, Use, OnConnection, To(room).Emit, ClientsCount, Close, Shutdown`;
  `sio.Socket` — `ID, Handshake, SetData/Data, On, OnDisconnect, Emit, Join, Leave, Rooms,
  Disconnect, Connected`; `EncodePacket/DecodePacket`.
* `socket.New(Deps) *Handler` (implements `game.Listener` + `game.RoomListener`), `(*Handler).SetRooms`,
  `(*Handler).Attach(srv)`, `Stats`. Build order: `New` → `game.NewRoomManager{TableListener: h, Listener: h}` → `SetRooms` → `Attach`.
* `auth.Tokens{Issue, Verify}`, `auth.TokenFromRequest`, `auth.Verifier{VerifyLogin, VerifyGoogle,
  VerifyFacebook}`, `auth.VerifyGuest`, `auth.SanitizeName`, `auth.Handler{Register, RequireAuth}`,
  `auth.WriteError/WriteJSON/UserFrom`.
* `db.Open, (*DB).WithTx/Query/Exec/DropSchema/Close/Stats, db.Redact, db.SchemaSQL`;
  `db.NewLedger` (→ `game.Ledger`), `db.Classify`; `db.NewUsers{FindByID, FindByProvider,
  UpsertFromProfile, ApplyChipDelta, RecentHands, ClaimMilestoneReward, ClaimTimedBonus,
  SetDisplayName, SetAvatarChoice}`, `db.NormalizeDisplayName`, `db.MilestoneFor`.
* `metrics.New, (*Metrics).BindRooms/BindPool/Handler/HTTPMiddleware`, `metrics.RouteLabelFor,
  SafeLabel, Timed, Observe`.
* `app.New, (*App).Handler/Rooms/Start/Addr/Shutdown/Health`.
* `config.Load, FromEnv, Defaults, ParseDuration, (*Config).Validate`.
* `util.UUID, RoomCode, NewLogger, ParseLogLevel`.

---

## 9. Recorded deviations from Node (deliberate; keep this list current)

| Area | Node | Go | Why |
|---|---|---|---|
| Transport | websocket + polling | websocket only; polling → 400 `Transport unknown` | decision 2; every client uses websocket |
| Scaling | optional Redis adapter (non-functional multi-node) | none; `REDIS_URL` logged as ignored | decision 1 |
| Retry-settle | ran outside the mutation queue | runs on the actor | fixes a latent data race |
| Kick handling | socket listener awaited `rooms.leave` inside the table event | `RoomManager.tableHooks` does it in a goroutine and reports `OnPlayerKicked` | actor rule |
| Log lines | `{t, level, msg, meta}`; errors to stderr | slog JSON `{time, level, msg, …attrs}`; one writer | not wire; attribute names kept |
| Malformed JSON body | 500 `internal_error` (Express parser error fell through) | 400 `invalid_json` | nothing depends on it; the honest status |
| Unknown `/api` path | Express HTML 404 | JSON `{error:"not_found"}` 404 | nothing depends on it |
| Process metrics | `game_server_nodejs_*` (heap spaces, ELU, GC, handles) | `game_server_process_*` + `game_server_go_*`; `process_uptime_seconds` kept | no Node runtime; Grafana "Node.js" row will be empty until re-pointed at `go_*` |
| `/health.process.node` | Node version | Go runtime version string | key kept for the tooling |
| `/health.process.loopLag*` | event-loop delay | scheduler-tick latency proxy (see `ProcessHealth`) | Go has no event loop |
| `/health.db.waiting`, `game_db_pool_waiting_requests` | `pool.waitingCount` | always 0 | pgxpool exposes no live waiter count |
| Google login | google-auth-library | JWKS fetch + RS256 verification by hand (or an added dep, noted here) | no Go equivalent in the dependency list |
| Chat/name length | UTF-16 code units | UTF-16 code units, never splitting a surrogate pair | DECISIONS.md §4 |
| New env key | — | `PUBLIC_DIR` (default `../server/public`, falling back to `./public`) for the browser client | the Go binary has no `rootDir` |
| New error code | — | `table_destroyed` (post to a destroyed table) | folds to `other` in metrics |
| Room code collisions | none checked | regenerated until unique among live tables | DECISIONS.md §3 |
| Settle retry after the table is destroyed | dropped (`if (this._destroyed) return`) — pot never banked | continues off the actor (`settleDetached`); `Shutdown` waits for it; `WaitSettlements` reports | DECISIONS.md §2 |
| `settle` statement order | `INSERT hands` first (FK KEY SHARE on the winner before the ordered wallet locks — deadlock-prone) | wallet locks first, hands row after | DECISIONS.md §2 |
| Client `actionId` with `:` | accepted verbatim (could squat `<userId>:milestone:<n>`) | replaced by a server uuid | DECISIONS.md §2 |

`DECISIONS.md` (same directory) settles every open question the specs raised and OVERRIDES this table where they differ. Anything else that differs is a bug in the port.
