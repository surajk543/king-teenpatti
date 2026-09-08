# King Teen Patti — Test suites, fixtures and tools: behavioural specification and parity plan

Source of truth: the **working tree** of `/home/suraj/Project/king-teenpatti/server` on branch `go-server`
(identical to `master` @ `db2ae22`; the "N workers / Postgres worker registry" commit `002bc30` exists only on
`multi_node` and is **not** part of what this document describes). All file:line citations below are into
that working tree. Baseline verified on 2026‑09‑08: `cd server && npm test` → **284 tests, 284 pass, 0 fail,
~12.4 s wall clock** against local PostgreSQL 18 (`postgres://postgres:postgres@localhost:5432/gameplay`).

Legend used throughout:

- **MUST MATCH** — wire or database behaviour that a client, a tool, or stored data depends on. A Go server that
  differs here fails an existing test or breaks the Flutter/browser/bot clients.
- **INCIDENTAL** — internal naming, log lines, in-process API shape. Free to differ; noted so a porter does not
  mistake it for contract.

---

## 0. Table of contents

1. How the suite is run (`package.json`, runner semantics, prerequisites)
2. Suite inventory (boot mode, env, black-box vs white-box)
3. The five boot patterns
4. Helpers (`fakeTimers`, `csharpJsonPort`, in-suite login/connect/wait/DB helpers)
5. The wire and REST contract exactly as the tests observe it (with captured frames)
6. Black-box suites — every test, scenario and assertion
   - 6.1 `integration.test.js` (36) · 6.2 `socketProtocol.test.js` (14) · 6.3 `invalidMoves.test.js` (16) · 6.4 `metrics.test.js` (9)
7. Semi-black-box suites (`stakes`, `statsAndRewards`) and how to drive them from outside
8. White-box suites — test cases to mirror (`table`, `tableRules`, `blindRules`, `categories`, `chat`,
   `chipPersistence`, `consolidation`, `handRank`, `lobbyRules`, `privateTables`, `raiseLadder`, `seatKeeping`,
   `settlement`, `sideshow`)
9. Tools as clients: `tools/bot.js`, `tools/ramptest.mjs`, `test/loadtest.js`, `kicktest.mjs`, `peek-tmp.mjs`
10. Every SQL statement the tests and tools run
11. Recommended parity harness
12. Traps for the port

---

## 1. How the suite is run

`server/package.json` (`"type": "module"`, `engines.node >= 20`) — scripts, verbatim:

| Script | Command | Notes |
|---|---|---|
| `start` | `node src/index.js` | production entry; `isEntrypoint` check at `src/index.js:140-142` |
| `dev` | `node --watch src/index.js` | |
| `test` | `node --test --test-timeout=30000 "test/*.test.js"` | `node:test` runner; **each file is a separate child process** run concurrently (default `--test-concurrency` = CPUs−1). Per-test timeout 30 s. |
| `loadtest` | `node test/loadtest.js` | needs a running server; **defaults to `--boot 100`**, which the default lobby menu refuses (`invalid_stake`) — pass `--boot 200` |
| `bot` | `node tools/bot.js` | practice bots against a running server |

Dependencies that matter to tests/tools: `socket.io-client ^4.8.1` (devDependency, used by every process suite and
every tool), `ws` (**transitive** only — `socketProtocol.test.js` imports it directly; `test/loadtest.js`,
`ramptest.mjs` do not), `pg`, `prom-client`, `jsonwebtoken`.

Prerequisites for a green run:

- PostgreSQL reachable at `config.db.url` (default `postgres://postgres:postgres@localhost:5432/gameplay`,
  `src/config/index.js:222`). Each DB-touching suite creates and later drops its own schema
  `test_<suite>_<6 base36 chars>` — see §3. A crashed run can leave `test_*` schemas behind; the suites never
  clean up other suites' leftovers.
- No server needs to be running: process suites start their own `createServer()` on port 0.
- Node ≥ 20 with global `fetch`, `node:test`, `node:assert/strict`. Node 22.22.1 is what runs here.

There is no CI, lint or formatter. `npm test` is the whole verification story for the server.

---

## 2. Suite inventory

Test counts are `grep -c '^test('` and match the runner's `# tests 284`.

| File | Tests | Boot mode (§3) | Env set before import | DB | Class | Could run against a foreign server given a base URL? |
|---|---|---|---|---|---|---|
| `test/integration.test.js` | 36 | **P** — `createServer()` in-process, `server.listen(0,'127.0.0.1')` | `NODE_ENV=test`, `PG_SCHEMA=test_integration_*`, `JWT_SECRET=integration-test-secret`, `AUTH_ALLOW_FAKE_PROVIDERS=true`, `WELCOME_CHIPS=200000`, `BOOT_AMOUNT=100`, `TURN_TIMEOUT_MS=1200`, `NEXT_HAND_DELAY_MS=150`, `RECONNECT_GRACE_MS=400`, `PORT=0`, `TABLE_STAKES=''`, `LOBBY_TABLES=''` (lines 7-21) | yes (own schema; reads `users`, `chip_ledger` via `query`) | **Black-box** over socket.io-client + `fetch`, with **8 white-box peeks** into `rooms.*`/`table.postChat` (listed in §6.1) | Yes for 28/36 unmodified; the 8 peeks need the substitutes given in §6.1 |
| `test/socketProtocol.test.js` | 14 (6 pure parser + 8 live) | **P** | `NODE_ENV=test`, `PG_SCHEMA=test_proto_*`, `JWT_SECRET=protocol-test-secret`, `AUTH_ALLOW_FAKE_PROVIDERS=true`, `BOOT_AMOUNT=100`, `TURN_TIMEOUT_MS=3000`, `NEXT_HAND_DELAY_MS=150`, `TABLE_STAKES=''`, `LOBBY_TABLES=''` (16-27). No `PORT`, no `RECONNECT_GRACE_MS`. | yes (own schema, no direct reads) | **Black-box, raw WebSocket** (Engine.IO framing by hand via `ws`) | Yes, all 8 live tests unmodified (6 parser tests need no server) |
| `test/invalidMoves.test.js` | 16 | **P** | `NODE_ENV=test`, `PG_SCHEMA=test_invalid_*`, `JWT_SECRET=invalid-moves-test-secret`, `AUTH_ALLOW_FAKE_PROVIDERS=true`, `WELCOME_CHIPS=200000`, `BOOT_AMOUNT=100`, `TURN_TIMEOUT_MS=60000`, `NEXT_HAND_DELAY_MS=150`, `RECONNECT_GRACE_MS=400`, `SIDESHOW_TIMEOUT_MS=60000`, `TABLE_STAKES=''`, `LOBBY_TABLES=''` (10-21). No `PORT`. | yes (reads `users.chips`, `chip_ledger`; writes via `applyChipDelta`) | Black-box over socket + **white-box peeks** (`rooms.getTable`, `table.hand.turnSeat/stake/pot`, `table.findSeat`, `rooms.createTable`) | Mostly; peeks replaceable by reading `room:state` (§6.3) |
| `test/metrics.test.js` | 9 | **P** | as integration plus `TURN_TIMEOUT_MS=4000`, `METRICS_TOKEN=metrics-test-token`, `PG_SCHEMA=test_metrics_*`, `JWT_SECRET=metrics-test-secret`, `PORT=0` (19-38) | yes (own schema) | Black-box over HTTP `/metrics` + socket; peeks: `io.engine.clientsCount`, `rooms.getTable(...).hand.turnSeat` | Yes with the two peeks replaced (§6.4). **Node-specific metric names** (`game_server_nodejs_*`) will not exist on a Go server — see §6.4 |
| `test/stakes.test.js` | 9 | **R** — `RoomManager` + `openDatabase()` (real ledger, real DB) | `NODE_ENV=test`, `PG_SCHEMA=test_stakes_*`, `JWT_SECRET=stakes-test-secret`, `NEXT_HAND_DELAY_MS=150`; **`delete process.env.TABLE_STAKES` and `LOBBY_TABLES`** so the real default menu applies (16-22) | yes (schema created; nothing read) | White-box (in-process `RoomManager` API) but every assertion is reproducible over the socket with the default menu (§7.1) | Indirectly |
| `test/statsAndRewards.test.js` | 13 | **U** — `db/users.js` + `openDatabase()` | `NODE_ENV=test`, `PG_SCHEMA=test_stats_*`, `JWT_SECRET=stats-test-secret` (170-172) | yes (reads/writes `users`, `chip_ledger`) | White-box over the users module; partially reproducible over REST + SQL (§7.2) | Partially |
| `test/table.test.js` | 32 | **T** — `new Table({...})` + fake timers, `settle` hook | none | no | White-box | No |
| `test/tableRules.test.js` | 12 | **T** + **R'** (`new RoomManager({timers, settle})`, no DB) | none | no | White-box | No |
| `test/blindRules.test.js` | 9 | **T** | none | no | White-box | No |
| `test/categories.test.js` | 11 | **T** | none | no | White-box (asserts on `serializeFor` output = the `room:state` payload) | Assertions reproducible via `room:state` |
| `test/chat.test.js` | 14 | **T** + pure `RoomChat` | none | no | White-box | Partially via `chat:*` events |
| `test/chipPersistence.test.js` | 6 | **T** with `persistChips` + `settle` hooks | none | no | White-box | No |
| `test/consolidation.test.js` | 15 | **R'** | none | no | White-box | Partially (`room:moved`) |
| `test/handRank.test.js` | 13 | pure functions (`handRank.js`, `deck.js`) | none | no | White-box | No (pure unit) |
| `test/lobbyRules.test.js` | 17 | **R'** + `normalizeDisplayName` + `config` | none (reads real default config) | no | White-box | Partially (`POST /api/profile/name`, quickJoin codes) |
| `test/privateTables.test.js` | 10 | **T** + **R'** | none | no | White-box | Partially |
| `test/raiseLadder.test.js` | 18 | **T** | none | no | White-box | Partially (`options.raiseSteps`) |
| `test/seatKeeping.test.js` | 7 | **T** with a `kick` listener that calls `removePlayer` | none | no | White-box | Partially (`room:kicked`) |
| `test/settlement.test.js` | 7 | **T** with bank-like `settle` | none | no | White-box | No |
| `test/sideshow.test.js` | 16 | **T** (calls `table._rightActiveSeat`, sets `seat.isBlind`, `seat.cards`) | none | no | White-box | Partially (`game:sideshow*`) |

**Not tests, but in scope:** `test/loadtest.js` (tool), `test/helpers/fakeTimers.js`, `test/helpers/csharpJsonPort.js`,
`tools/bot.js`, `tools/ramptest.mjs`, `kicktest.mjs` (tracked scratch), `peek-tmp.mjs` (untracked scratch).

---

## 3. The five boot patterns

### P — full process in-process (`integration`, `socketProtocol`, `invalidMoves`, `metrics`)

```js
process.env.X = '...';                                    // BEFORE any import of src/ — config is snapshotted at import (config/index.js:193-381)
const { createServer } = await import('../src/index.js');
const { io: connect } = await import('socket.io-client');
const { query, dropSchema, closeDatabase } = await import('../src/db/index.js');
test.before(async () => {
  const created = await createServer();                    // awaits openDatabase() → CREATE SCHEMA + schema.sql (db/index.js:377-409)
  server = created.server; io = created.io; rooms = created.rooms;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});
test.after(async () => {
  await rooms.shutdown();                                  // destroys every table → live hands settled with reason all_left
  await new Promise((resolve) => io.close(resolve));
  server.closeAllConnections?.();
  await new Promise((resolve) => server.close(resolve));
  await dropSchema();                                      // DROP SCHEMA IF EXISTS "<schema>" CASCADE (refuses 'public')
  await closeDatabase();
});
```

`createServer()` (`src/index.js:16-138`) returns `{ app, server, io, rooms }`; it does **not** listen. Everything the
process suites need from the server is reachable through `baseUrl` except the peeks listed per suite.

Schema names: `` `test_integration_${Math.random().toString(36).slice(2, 8)}` `` etc. — `openDatabase` validates
`/^[A-Za-z_][A-Za-z0-9_]*$/` (`db/index.js:380`) and sets `search_path` via the pool's `options:
'-c search_path=<schema>,public'` (`db/index.js:392`).

### R — `RoomManager` with the real Postgres ledger (`stakes`)

`new RoomManager()` with no args → `this.ledger = createLedger()` (`roomManager.js:32`); needs `await openDatabase()`
first. Tables created here really write `pots`/`chip_ledger`/`game_states` when hands start — but `stakes.test.js`
never starts a hand (a single `player()` per table), so nothing is written. `rooms.shutdown()` after each test clears
the sweeper interval.

### R' — `RoomManager` with in-memory books (`tableRules`, `consolidation`, `lobbyRules`, `privateTables`)

`new RoomManager({ timers: createFakeTimers().timers, settle: () => ({}) })` — passing `settle` (or `persistChips`)
makes `this.ledger = null` so each `Table` builds a `memoryLedger` (`roomManager.js:32`, `table.js:54,1803-1835`).
**INCIDENTAL** (in-process API), but the *rules* these suites pin are MUST MATCH.

### T — bare `Table` (`table`, `tableRules`, `blindRules`, `categories`, `chat`, `chipPersistence`, `raiseLadder`,
`seatKeeping`, `settlement`, `sideshow`, `privateTables`)

```js
const { timers, advance } = createFakeTimers();
const table = new Table({ id: 'room-1', code: 'TEST01', config: { ...baseConfig, ...overrides }, timers, settle, persistChips });
```

Table reads `config` **raw — no defaults are merged** (`table.js:46`). Every suite therefore declares a full
`baseConfig`; the keys used are `maxPlayers, minPlayers, bootAmount, turnTimeoutMs, maxBetRounds,
potLimitMultiplier, maxRaiseSteps, maxBlindMoves, maxMissedTurns, nextHandDelayMs, chatMaxHistory, chatMaxLength,
sideshowTimeoutMs, sideshowMinPlayers, maxPot, category, welcomeChips` (the last is unused by Table). Missing keys behave
as `undefined`: e.g. `table.test.js` omits `maxRaiseSteps` → `betOptions` falls back to `?? 8` (`table.js:774`), omits
`maxBlindMoves` → `seat.blindMoves >= undefined` is always false → cards never auto-reveal in that suite;
omits `maxMissedTurns` → never kicks for idling; `sideshowMinPlayers` undefined → `activeSeats.length < undefined`
false → sideshow never blocked for `too_few_players` (irrelevant there).

`seat(id, chips)` helpers call `table.addPlayer({ userId, displayName, avatarUrl: null, chips, socketId })` — sync.
Deterministic showdowns are forced by writing `table.findSeat(id).cards = codes.map(parseCard)` after the deal.

### U — users module (`statsAndRewards`)

`await openDatabase()` then direct calls to `upsertFromProfile`, `settleHand` (= `ledger.settle`), `findById`,
`claimMilestoneReward`, `claimTimedBonus`, `setAvatarChoice`, plus raw `query()` updates.

---

## 4. Helpers

### 4.1 `test/helpers/fakeTimers.js` (45 lines) — INCIDENTAL (test-only), but its semantics define what the white-box tests mean

`createFakeTimers()` → `{ timers: { setTimeout(fn, ms) → id, clearTimeout(id) }, advance(ms), now(), pending() }`.

- Virtual clock starts at 0; ids are 1, 2, 3… (line 10-11).
- `await advance(ms)`: repeatedly picks the **earliest** due timer (`at <= target`, sorted ascending by `at`; ties
  broken by Map insertion order via stable sort), deletes it, sets `now = timer.at`, **awaits `timer.fn()`**, loops;
  finally `now = target` (27-40). Timers scheduled *during* a callback that fall inside the window fire in the same
  `advance` call. Because Table's callbacks return `this._run(...)` promises, `advance` waits for the queued mutation.
- The Table never reads `timers.now()`; deadlines (`turnDeadline`, `startsAt`, `expiresAt`, `nextHandAt`) are computed
  with the **real** `Date.now()` (`table.js:321,606,1171,1508`). Tests therefore assert `deadline > Date.now() + 20000`
  (table.test.js:362), not against the fake clock.

### 4.2 `test/helpers/csharpJsonPort.js` (291 lines) — a JS port of the deleted Unity client's hand-rolled Socket.IO parser

Kept alive because it exercises the raw Engine.IO/Socket.IO wire format. Behaviour a Go server must be compatible with
(the *parser* is the client; the server must produce frames it can read):

- `PortedSocketIOClient(token).receive(rawFrame)` — Engine.IO packet type is the first char: `'0'` OPEN → reads
  `sid`, `pingInterval`, `pingTimeout` (defaults 25000/20000 when absent) and replies once with **`40{"token":"<escaped>"}`**
  (Socket.IO CONNECT with the auth object as payload; lines 229, 271-277). `'2'` PING → returns `'3'` PONG. `'3'` → null.
  `'4'` → Socket.IO packet: sub-type `'0'` CONNECT ack (reads `sid`, sets `connected`), `'1'` DISCONNECT, `'2'` EVENT,
  `'3'` ACK, `'4'` CONNECT_ERROR (reads `"message"` field or the raw body into `connectError`) (279-303).
- EVENT body: finds the first `[`, `firstArrayString` = event name, `secondArrayElement` = payload text or `'{}'` when
  absent (306-314). ACK body: digits before `[` are the ack id; `firstArrayElement` of the array is the payload (316-325).
- `emit(event, payloadText, wantsAck)` → `42["<event>",<payload>]` or `42<ackId>["<event>",<payload>]` with ack ids
  starting at 1 (239-251).
- `Json.escape` escapes `"` `\` `\n` `\r` `\t` and other `< 0x20` as `\u00XX`; `Json.getString/getInt/getBool` are
  naive first-occurrence scanners (`getInt` reads `[0-9-]+`, so it cannot read a float or exponent); `unescape` handles
  `\n \r \t \uXXXX` and passes any other escaped char through.

The 6 parser-only tests (§6.2) run without a server.

### 4.3 In-suite client helpers (duplicated in `integration`, `invalidMoves`, `metrics`; behaviour identical)

- `login(body)` → `POST ${baseUrl}/api/auth/login` with `content-type: application/json`, returns `{status, body}`.
  `guestLogin(deviceId, displayName)` → body of `login({provider:'guest', deviceId, displayName})` (metrics asserts
  `status === 200`).
- `openClient(token)` → `socket.io-client` `connect(baseUrl, { auth: { token }, transports: ['websocket'], forceNew: true })`.
  Records every payload for a fixed event list into `seen[]` (`integration`: `session:ready, room:joined, room:state,
  game:handStarted, game:turn, game:yourTurn, game:action, game:showdown, game:handEnded, player:cards, game:error,
  session:replaced, chat:message, chat:history`; `invalidMoves`: `session:ready, room:joined, room:state,
  game:handStarted, game:error, game:handEnded, game:showdown, player:cards, room:kicked, room:left,
  game:sideshowAsked` (the last is not a real server event)). Rejects if no `connect` within 4000 ms or on
  `connect_error`. Returns `{ socket, seen, last(event), all(event), wait(event, predicate, timeoutMs=4000),
  emit(event, payload) → Promise<ack>, close() }`.
  - `wait` resolves immediately if a matching payload was **already** recorded, else subscribes; rejects after the
    timeout (`timed out waiting for ${event}`).
  - `emit` (integration/metrics) sends `payload ?? {}`; **invalidMoves' `emit` sends the payload verbatim** (so `null`,
    `undefined`, `42`, `'string'`, arrays reach the server as-is — line 97-98).
  - `close()` emits `room:leave` with `{}` and awaits its ack, then `socket.disconnect()` — so the seat is freed
    immediately instead of being held for `RECONNECT_GRACE_MS`.
- `uniqueStake()` — integration/metrics start at 100 and add 50 per call (150, 200, 250 …); invalidMoves starts at
  1000 (1050, 1100 …). Because `TABLE_STAKES=''`/`LOBBY_TABLES=''`, any positive integer boot is accepted, and
  quick-join matches on `(bootAmount, category)`, so each test gets a private universe of tables.
- `dealtTable(tag)` (invalidMoves 109-124) / `dealTwoPlayerHand(tag)` (metrics 156-182): two guests
  `device-${tag}-a/b`, both `room:quickJoin {bootAmount}` (metrics adds `category:'seen'`), `await ca.wait('game:handStarted')`,
  then **peeks** `rooms.getTable(joined.roomId)` and `table.seats[table.hand.turnSeat].userId` to decide `onTurn`/`waiting`.
  Black-box substitute: `room:state.turn.userId` (or `game:turn.userId`), see §6.3.
- `pause(ms)` = `setTimeout` promise.
- DB helpers (invalidMoves 126-134): `ledgerSum(userId)` = `SELECT COALESCE(SUM(delta), 0) AS total FROM chip_ledger WHERE user_id = $1`
  → `rows[0].total` (a JS **number** only because `db/index.js:359-362` parses int8/numeric); `wallet(userId)` =
  `SELECT chips FROM users WHERE id = $1`.

### 4.4 `socketProtocol` raw-WS helper `openUnityLikeClient(token)` (70-118)

`new WebSocket(ws://127.0.0.1:<port>/socket.io/?EIO=4&transport=websocket)` from the `ws` package; every inbound text
frame is pushed to `frames[]` and fed to `PortedSocketIOClient.receive`; a non-null reply is sent back verbatim.
`waitFor(name, timeoutMs=4000)` polls `client.last(name)` every 20 ms (event names, or `ack:<event>` for acks);
`waitConnected()` polls `client.connected`. `emit(event, payloadText, wantsAck=false)` sends the frame the port builds.
`close()` = `socket.close()` — **no `room:leave`**, so seats in this suite are held for the (default 60 s) grace and
are settled by `rooms.shutdown()` in `test.after`.

### 4.5 `metrics` exposition helpers (186-298)

`fetchMetrics(headers)` → `GET /metrics`. `parseExposition(text)` parses every non-comment line with
`/^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{(.*)\})?\s+(\S+)(?:\s+\S+)?$/` (asserting each line parses), collects `# TYPE`
lines, and offers `value(name, labelSubset)` (**sum** over matching samples, `undefined` if none), `has`, `labelNames()`,
`labelValues(label)`. `scrape()` sends `authorization: Bearer metrics-test-token` and asserts 200.
`eventually(check, {timeoutMs=5000, intervalMs=60})` re-scrapes until `check` stops throwing; the last failure surfaces.
`atLeast(snapshot, name, labels, min)`, `present(snapshot, name, labels)`.

---

## 5. The wire and REST contract exactly as the tests observe it — MUST MATCH

Everything in this section was both read from the source and confirmed by capturing real frames from
`createServer()` on 2026‑09‑08 (raw WebSocket, `EIO=4`). Field order is as JSON.stringify emits it (object insertion
order in the source); a Go server should preserve it where cheap — the hand-rolled parser in §4.2 uses
first-occurrence scans, so **a key that appears twice at different nesting levels is read at its first occurrence**
(e.g. `Json.getString(ready,'displayName')` on `session:ready` finds `user.displayName` because `user` precedes `config`).

### 5.1 Transport parameters (`src/index.js:115-123`)

Socket.IO 4 server: `transports: ['websocket','polling']`, `pingInterval: 20000`, `pingTimeout: 25000`,
`maxHttpBufferSize: 1e5`, CORS origin `config.corsOrigin` (default `'*'`), methods GET/POST. Captured OPEN frame:

```
0{"sid":"4zQFRjf_KSheswFaAAAA","upgrades":[],"pingInterval":20000,"pingTimeout":25000,"maxPayload":100000}
```

Handshake auth: `socket.handshake.auth?.token ?? socket.handshake.query?.token` (`socket/index.js:382`) — so both
`40{"token":"…"}` (CONNECT payload) and `?token=…` on the Engine.IO URL work. Middleware: `verifyToken` (JWT HS256,
secret `config.jwt.secret`, claims `{sub, provider, name, iat, exp}` — `auth/tokens.js:398-404`), then
`findById(claims.sub)`; failures → `next(new Error(code))` where code ∈ `missing_token | invalid_session |
unknown_user`, else `unauthorized` (`socket/index.js:380-391`). Captured refusal for a garbage token:

```
44{"message":"invalid_session"}
```

Success: `40{"sid":"…"}` then immediately `42["session:ready",{…}]`.

### 5.2 REST

`POST /api/auth/login` body `{provider, deviceId?, displayName?, idToken?, accessToken?, providerUserId?}`
(`auth/routes.js:61-80`, `auth/providers.js:375-390`):

- `guest`: `deviceId` trimmed, **length ≥ 8** else `400 {"error":"invalid_device_id","message":"A deviceId of at least 8 characters is required"}`;
  `providerUserId = sha256("teenpatti:" + trimmed)` hex (64 lowercase hex chars); `displayName = sanitizeName(displayName) || "Guest" + hashed.slice(0,5).toUpperCase()`
  where `sanitizeName` = strip `\p{C}`, trim, `.slice(0,24)`, and requires **≥ 2 chars** else `''` (348-354).
  **Login names are NOT run through `NAME_PATTERN`** — `Raj "Ace" {x}` is accepted verbatim (socketProtocol 350-362).
- `google`/`facebook` with `AUTH_ALLOW_FAKE_PROVIDERS=true` and **no** `idToken`/`accessToken`: `verifyFake` →
  `providerUserId = String(providerUserId ?? displayName ?? 'fake')`, `displayName = sanitizeName(displayName) || 'Player'`.
  Without the flag → `503 provider_unconfigured`.
- unknown provider → `400 {"error":"unknown_provider","message":"Unsupported login provider \"myspace\""}`.
- Success `200`: `{"token": <jwt>, "user": <publicUser>, "isNew": bool, "welcomeChips": isNew ? config.game.welcomeChips : 0}`.
- `publicUser` shape (`db/users.js:21-60`), captured:

```json
{"id":"b4f3fc0c-…","provider":"guest","displayName":"FrameA","email":null,"avatarUrl":null,"providerAvatarUrl":null,
 "avatarChoice":null,"chips":200000,"handsPlayed":0,"handsWon":0,"handsLost":0,"handsLeftMid":0,"totalWinnings":0,
 "biggestPot":0,"rewards":{"milestoneAvailable":false,"milestoneAt":0,"milestoneReward":25000,"milestoneEvery":25,
 "handsToNextMilestone":25,"bonusReadyAt":0,"bonusAvailable":true,"bonusReward":10000,"bonusIntervalMs":14400000},
 "createdAt":1788847016878,"lastLoginAt":1788847016878}
```

  `avatarUrl = avatar_choice || avatar_url` (choice wins); `handsToNextMilestone = 25 - (hands_played % 25)` (so 25 at an
  exact multiple); `milestoneAvailable = floor(hp/25)*25 > milestone_claimed`; `bonusAvailable = Date.now() >= next_bonus_at`.
  Numbers are JSON numbers (BIGINT parsed at `db/index.js:359`).
- `GET /api/auth/me` with `authorization: Bearer <jwt>` → `200 {"user": <publicUser>}`; bad token →
  `401 {"error":"invalid_session","message":"Session token rejected: jwt malformed"}` (message text is jsonwebtoken's;
  INCIDENTAL beyond the code). Missing header → `401 missing_token`. Unknown sub → `401 unknown_user`.
- `GET /api/auth/me/hands?limit=N` → `{"hands":[…]}` (limit `min(parseInt||20, 100)`); used only by metrics test for a 200.
- `GET /health` (`src/index.js:44-80`), captured:

```json
{"ok":true,"uptime":3.847,"tables":1,"players":1,"activeHands":0,"sockets":3,
 "process":{"pid":12292,"node":"v22.22.1","rssMb":108.6,"heapUsedMb":21.3,"heapTotalMb":36.2,"externalMb":4.6,
            "cpuPercent":5.1,"loopLagP50Ms":20.2,"loopLagP99Ms":21.2,"loopLagMaxMs":26.3},
 "db":{"total":1,"idle":1,"waiting":0}}
```

  Tests assert only `ok === true`, `typeof tables === 'number'`, `typeof players === 'number'`. `ramptest.mjs` reads
  `players, tables, activeHands, uptime`, and — when present — `process.rssMb, heapUsedMb, cpuPercent, loopLagP99Ms,
  loopLagMaxMs`, `sockets`, `db.waiting`, `db.total` (§9.2). `players` = `playerRooms.size` (seated users), `tables` =
  `tables.size`, `activeHands` = tables with `hand !== null` (`roomManager.js:500-507`).
- Error envelope for thrown `AuthError`/`GameError`: `{"error": code, "message": text}` with the error's status / 400;
  anything else `500 {"error":"internal_error","message":"Something went wrong"}` (`src/index.js:102-111`).
- Unmatched path → Express 404 (HTML body; metrics test only checks status 404 and route label `unmatched`).

### 5.3 Socket events, server → client (payloads as emitted; `roomId` is spread in by `socket/index.js`)

| Event | Audience | Exact shape | Source |
|---|---|---|---|
| `session:ready` | socket | `{user: <publicUser>, config: {maxPlayers, minPlayers, bootAmount, turnTimeoutMs, welcomeChips, maxBetRounds, sideshowTimeoutMs, sideshowMinPlayers, categories:["seen","blind"], stakes:[…], tables:[{category, bootAmount, maxPot, maxBlindMoves}…], entryCapBoot, entryCapCategory, entryCapMaxChips, privateBoot, privateMaxPot}, resume?: {roomId, code, category, bootAmount}}` — `resume` key **absent** (not null) when no offer | `socket/index.js:430-434, 733-745`; `roomManager.js:196-223` |
| `session:replaced` | the older socket of the same user | `{message: "Signed in from another device"}` then that socket is `disconnect(true)`d | 406-411 |
| `room:joined` | the joiner | `serializeFor(userId)` (§5.4) | 441, 499, 518, 532, 566, 363 |
| `room:state` | **each** tracked viewer, own redaction | `serializeFor(viewerId)` | 192-199 |
| `chat:history` | joiner | `{roomId, messages: [<message>…]}` oldest first | 334-339 |
| `chat:message` | room | `{id, userId, displayName, text, at, system?: true, roomId}` — user messages have **no `system` key**; system lines have `userId: null`, `displayName: "Table"`, `system: true` | 326-330; `chat.js:281-318` |
| `game:handStarted` | room | `{handId, handNo, dealerSeat, bootAmount, pot, stake, participants:[userId…], roomId}` | `table.js:471-479`, 248-251 |
| `player:hand` | every viewer | `{roomId, dealt: true, cardsHidden: true}` | 253-256 |
| `player:cards` | owner only | `{roomId, cards: ["9s","Ks","5d"]}` | 259-261 |
| `game:turn` | room | `{roomId, userId, seatIndex, deadline, timeoutMs}` — **no options** | 263-270 |
| `game:yourTurn` | player on turn | `{roomId, deadline, timeoutMs, options: <turnOptions>}` | 272-277 |
| `game:action` | room | `{userId, action, amount, pot, stake, roomId}` plus `auto` (bool) for `see`, `reason` (string) for `pack` | `table.js:982-989, 1065-1071, 1104-1111, 1306-1312, 257-264` |
| `game:sideshowRequested` | room | `{fromUserId, fromName, fromSeat, toUserId, toName, toSeat, expiresAt, timeoutMs, roomId}` | `table.js:1185-1194` |
| `game:sideshowReveal` | the two players | `{roomId, reveal: {reason, packedUserId, hands: [{userId, displayName, cards, handName} ×2 (asker first)]}}` | 1244-1262; 295-300 |
| `game:sideshowResolved` | room | `{fromUserId, toUserId, accepted, reason, packedUserId (string|null), roomId}` — `reason ∈ accepted|declined|timeout|left` | 1268-1274 |
| `game:showdown` | room | `{reveals: [{userId, seatIndex, cards:[3 codes], handName, category:int, won:bool}], reason, roomId}` | 1360-1369 |
| `game:handEnded` | room | `{handId, handNo, winnerId (string|null), winnerName (string|null), pot, reason, reveals, summary: [{userId, displayName, seatIndex, contributed, status, sawCards, cards: [codes]|null}], nextHandAt, roomId}` | 1509-1519 |
| `room:left` | socket | `{roomId}` | 587 |
| `room:closed` | every viewer still tracked | `{roomId}` | 368-376 |
| `room:kicked` | the user | `{roomId, reason, message}` — `reason ∈ idle | insufficient_chips`; messages `"Left the table after N missed turns"` / `"You don't have enough coins to remain in this table"` | 239; `table.js:654, 693, 504` |
| `room:moved` | the moved user | `{fromRoomId, toRoomId, code, message: "Moved to a table with other players waiting."}` followed by `room:joined`, `chat:history`, then `room:state` broadcast | 357-365 |
| `game:error` | socket | `{code, message}` — sent **in addition to** the `{ok:false,…}` ack for every refused guarded request; `{code:"rate_limited", message:"Slow down"}` on limiter trip | 201-208, 455-461, 473 |

Ack envelope for every `handle()`d event: success `{ok: true, ...result}`; failure `{ok: false, code, message}`
(`code = error.code ?? 'internal_error'`); rate-limit trip **is acked** `{ok:false, code:'rate_limited', message:'Slow down'}`
(453-475). (CLAUDE.md §7.1 still says "no ack" — the code acks; the code wins.)

Captured ack frames: `431[{"ok":true,"roomId":"f43b…","code":"HF792G","category":"seen"}]`,
`432[{"ok":true,"action":"see","auto":false}]`, `433[{"ok":false,"code":"invalid_bet","message":"Bet amount must be a whole number"}]`,
`434[{"ok":true,"messageId":"63310af1-…"}]`, `435[{"ok":true,"roomId":"f43b…"}]`.

`game:action` ack `result` per action (`table.js`): `see` → `{action:"see", auto:false}`; `chaal`/`raise` →
`{action:"chaal"|"raise", amount, autoSeen:bool}` (1088); `pack` → `{action:"pack", reason:"pack"}` (1115/1119);
`show` → `{action:"show", amount}` (1316); `sideshow` → `{action:"sideshow", toUserId}` (1197).
`game:sideshowRespond` ack → `{accepted, packedUserId}` (1284) or `null` result if nothing pending (can't happen — throws first).
`room:leave` → `{roomId}` or `{}` when not seated. `player:requestCards` → `{cards: []|[codes]}`. `chat:message` →
`{messageId}` or `{}` when nothing was posted. `chat:history` → `{count}`. `lobby:list` → `{tables:[summary…], options: lobbyOptions()}`
where `summary = {roomId, code, category, state, players, maxPlayers, bootAmount, pot}` (`table.js:1742-1753`).

**Observed ordering on `room:quickJoin` for the joiner** (captured): `room:state` (emitted by `setConnected`'s
`'state'` event, 498), `room:joined`, `chat:history`, `room:state` (explicit `broadcastState`, 503), then the ack.
Other viewers get `chat:message` (system "X joined the table") **before** their `room:state`. On the deal:
`game:handStarted`, `player:hand`, `game:turn`, [`game:yourTurn` to the player on turn], `room:state`.
On `see` by the player on turn: `player:cards`, `game:action`, `game:turn` **re-issued to the room with the same deadline
and remaining `timeoutMs`** (`table.js:996-1004`) + `game:yourTurn` with the seen ladder, `room:state`, ack. On `see`
off-turn: `player:cards`, `game:action`, `room:state`, ack (no `game:turn`).

### 5.4 `serializeFor(viewerId)` — the `room:joined` / `room:state` payload (`table.js:1642-1739`)

```json
{"roomId":"f8ee…","code":"EGWYF5","category":"seen","chipsHidden":false,"state":"waiting","handNo":0,"dealerSeat":-1,
 "maxPlayers":5,"minPlayers":2,"bootAmount":100,"turnTimeoutMs":25000,"startsAt":null,"pot":0,"maxPot":1200000,
 "stake":100,"round":0,"sideshow":null,"turn":null,
 "you":{"seatIndex":0,"chips":200000,"status":"waiting","isBlind":true,"blindMovesLeft":4,"contributed":0,
        "missedTurns":0,"maxMissedTurns":3,"cards":[],"options":null},
 "seats":[{"seatIndex":0,"userId":"60d9…","displayName":"FrameA","avatarUrl":null,"chips":200000,"status":"waiting",
           "isBlind":true,"lastBet":0,"lastAction":null,"contributed":0,"connected":true,"cardCount":0},
          {"seatIndex":1,"status":"empty"},{"seatIndex":2,"status":"empty"},{"seatIndex":3,"status":"empty"},{"seatIndex":4,"status":"empty"}]}
```

Rules the tests pin: `you` is `null` for a non-seated viewer; `you.cards` is `[]` while blind, 3 codes once seen;
`you.options` is `turnOptions(viewer)` only when it is the viewer's turn and they are active, else `null`; `seats[i].chips`
is **`null`** (never 0) for others on a `blind` table, always a number for the viewer (1725); `chipsHidden` is the
category flag; occupied seats never carry a `cards` key (only `cardCount`); `missedTurns`/`maxMissedTurns` appear only
under `you`; `stake` falls back to `bootAmount` between hands; `pot` 0 between hands; `turn` `{seatIndex, userId, deadline}`
or `null`; `sideshow` `{fromUserId, fromSeat, toUserId, toSeat, expiresAt}` or `null`; `startsAt` epoch-ms or `null`.

`turnOptions` (`table.js:806-831`), captured for a blind player on a seen table (2 rungs):

```json
{"canSee":true,"canSideshow":false,"sideshowWith":null,"chaal":100,"raise":200,"raiseSteps":[100,200],"maxBet":200,
 "show":100,"canPack":true,"isBlind":true,"currentStake":100,"chips":199900,"pot":200}
```

`chaal`/`raise`/`maxBet`/`show` are `null` when unavailable (`show` also `null` unless exactly two active seats and the
player can afford it).

### 5.5 Client → server events and validation order (`socket/index.js:482-683`)

| Event | Payload read | Order of checks → error code |
|---|---|---|
| `lobby:list` | `{category?}` | none; `category` filter only when it equals a table's category string (any other value → no filter, because `!category` is false but nothing matches → **empty list**; `null`/undefined → all) |
| `room:quickJoin` | `{bootAmount?, category?}`; `bootAmount ?? config.game.bootAmount` | `already_in_room` → `invalid_stake` (not integer / ≤0 / not in `tableStakes` when non-empty) → `table_not_offered` (pair not in `lobbyTables` when non-empty) → `insufficient_chips` (`user.chips < bootAmount`, chips re-read from DB via `findById`) → `over_entry_cap` → seat (fullest non-full public table with same boot+category, else create) (`roomManager.js:232-258`) |
| `room:create` | `{bootAmount?, isPrivate=true, category?}` | table is **created first**, then `join` → `already_in_room` (so a refused create leaves an **empty public/private table** behind until the 30 s sweep — INCIDENTAL leak, but visible in `/health.tables`) (507-523, `roomManager.js:329-343`) |
| `room:joinCode` | `{code}`; `String(code ?? '').toUpperCase()` | `already_in_room` → `room_not_found` → `table_full` → `insufficient_chips` → `over_entry_cap` (public tables only) (`roomManager.js:260-276`) |
| `room:switch` | `{}` | `not_in_room` → `private_table` → `no_other_table`; on success leaves with reason `'moved'` (no consolidation) then joins (`roomManager.js:294-327`) |
| `room:leave` | `{}` | never fails; `{}` if not seated |
| `game:action` | `{action, amount?, actionId?}` | `unknown_action` (action ∉ `see|chaal|raise|pack|show|sideshow`) → `not_in_room` → `invalid_bet` if `amount` present and not (`typeof number && Number.isSafeInteger`) → `actionId` kept only if string with 1..64 chars else replaced by a fresh uuid → `table.act` (see below) |
| `game:sideshowRespond` | `{accept}`; accepts only `accept === true` | `not_in_room` → `no_sideshow` → `not_your_sideshow` |
| `player:requestCards` | `{}` | `not_in_room` → `{cards:[]}` if blind/no cards, else re-emits `player:cards` and returns them |
| `chat:message` | `{text}` | `not_in_room` → `chat_rate_limited` (5 per 5000 ms fixed window per socket; **every send counts, even blank**) → `postChat` (sanitise; nothing posted → `{}`) |
| `chat:history` | `{}` | `not_in_room` → re-sends `chat:history`, acks `{count}` |
| `ping:rtt` | `sentAt` (raw arg) | unguarded, not rate-limited, acks `{sentAt, serverTime}` without `ok` |

General guard (`453-475`): message counter → limiter **30 per 5000 ms fixed window per socket** (`createRateLimiter`,
748-760: window resets when `now - windowStart >= windowMs`; count includes the request that trips) → `handler(payload ?? {})`.
Handlers destructure the payload, so a non-object (`42`, `'string'`, `[]`) yields undefined fields rather than a crash.

`table.act` order (`table.js:928-970`): `no_hand` → `not_seated` → `not_in_hand` (status ≠ active) → `not_your_turn`
(**except `see`, allowed off-turn**) → per action. Bets (`_bet`, 1022-1089): `insufficient_chips` if the ladder is empty
→ if `amount` given: `invalid_bet` unless integer AND a rung AND (`raise` ⇒ `≥ 2*steps[0]`) → `insufficient_chips` if
`chips < amount` → ledger write (`insufficient_chips | duplicate_action | persist_failed` from `_refusal`, 892-900) →
mutate → `missedTurns = 0` only after success (968). `show` (1287-1317): `show_unavailable` unless exactly 2 active →
`insufficient_chips` if `showCost` null or unaffordable. `sideshow`: `sideshowBlockedReason` order `no_hand | not_in_hand |
not_your_turn | sideshow_pending | already_asked | too_few_players | you_are_blind | no_neighbour | neighbour_is_blind`
(558-578) — note `not_your_turn` is thrown by `_act` before `_requestSideshow` ever runs.

### 5.6 Disconnect / resume as the tests exercise it (`socket/index.js:687-725, 414-444`)

On `disconnect`: seat marked `connected:false` (state broadcast), a grace timer `RECONNECT_GRACE_MS` is armed; when it
fires and the user has not reconnected: `resumeOffers.set(userId, {roomId, at})` **then** `rooms.leave(userId,'disconnected')`
(the leave is a pack if mid-hand, emits `game:action {action:"pack", reason:"disconnected"}`), state broadcast.
On connect: pending removal cancelled; if still seated → `session:ready` (no `resume`) then `room:joined` + `chat:history`
(no `room:state` to others until something changes); else `takeResumeOffer` (deleted on read; valid if
`Date.now()-at ≤ RESUME_OFFER_MS` and table exists and not full) → `session:ready.resume = {roomId, code, category, bootAmount}`;
a voluntary `room:leave` never creates an offer (the grace timer finds no seat).

---

## 6. Black-box suites — every test, scenario and assertion

Conventions: "guest(X, Name)" = `guestLogin('device-X', 'Name')`; "open(A)" = `openClient(a.token)`; "QJ(c, boot[, cat])" =
`c.emit('room:quickJoin', {bootAmount: boot[, category: cat]})`; `⇒` = assertion. Timeouts: `wait` 4 s unless noted.
"PEEK" marks an in-process read that a foreign-server run must replace; the substitute follows in brackets.

### 6.1 `test/integration.test.js` — 36 tests, env §2 (boot 100, turn 1200 ms, next hand 150 ms, grace 400 ms)

**Auth (REST only)**

| # | Test name | Scenario | Assertions |
|---|---|---|---|
| 1 | `guest login creates an account with the welcome chip grant` (133) | `guest('guest-0001','Suraj')` | `token` truthy; `isNew === true`; `welcomeChips === 200000`; `user.chips === 200000`; `user.provider === 'guest'`; `user.displayName === 'Suraj'` |
| 2 | `logging in again from the same device returns the same saved account` (144) | same deviceId twice | 2nd: `isNew === false`, `welcomeChips === 0`, `user.id` equal, `user.chips` equal |
| 3 | `a different device is a different account` (154) | two deviceIds | `user.id` differ |
| 4 | `the raw device id is never stored` (160) | **PEEK/DB**: `SELECT provider_user_id FROM users WHERE provider = $1` `['guest']` | ≥1 row; none equals `'device-guest-0001'`; each matches `/^[0-9a-f]{64}$/` [substitute: same SQL against the harness schema] |
| 5 | `a short or missing device id is rejected` (174) | `{provider:'guest', deviceId:'abc'}`; `{provider:'guest'}` | status 400 + `body.error === 'invalid_device_id'`; status 400 |
| 6 | `an unknown provider is rejected` (183) | `{provider:'myspace', deviceId:'device-xxxx-9999'}` | 400, `error === 'unknown_provider'` |
| 7 | `google and facebook logins create provider-scoped accounts` (189) | `{provider:'google', providerUserId:'google-sub-123', displayName:'G Player'}`, `{provider:'facebook', providerUserId:'fb-123', displayName:'F Player'}`, google again | both 200; `user.provider` echoes; google `chips === 200000`; ids differ; second google login returns the same `user.id` |
| 8 | `/api/auth/me returns the persisted profile` (207) | `GET /api/auth/me` Bearer token | 200; `body.user.id === user.id`; `body.user.chips === 200000` |
| 9 | `a bad session token is refused` (218) | `authorization: Bearer nonsense` | status 401 |

**Sockets & gameplay**

| # | Test name | Scenario | Assertions |
|---|---|---|---|
| 10 | `a socket without a valid token cannot connect` (225) | connect with `auth:{token:'garbage'}` | `connect_error.message` matches `/invalid_session|unauthorized/` |
| 11 | `two players quick-join the same table and a hand is dealt` (232) | Alice/Bob open, both QJ same unique boot | both acks `ok`; `roomId` equal; `game:handStarted.participants.length === 2`, `.pot === boot*2`; first `room:state` with `state==='betting'` has `maxPlayers===5`, `minPlayers===2`, `you.cards` deepEqual `[]` |
| 12 | `a full hand plays out: see, bet, show, and the pot is paid` (259) | QJ ×2; wait `game:turn`; the player named by `turn.userId` emits `{action:'see'}` then `{action:'show'}` | see ack `ok`; that player receives `player:cards` with 3 cards; the other has **zero** `player:cards`; show ack `ok`; `game:handEnded.winnerId` truthy, `.pot === boot*4` (two boots + seen show = 2×stake), `.reveals.length === 2`; winner's `GET /me` → `chips > 200000`, `handsWon === 1`; show-payer's `/me` → `handsPlayed === 1` |
| 13 | `acting out of turn returns an error to the client` (317) | the player **not** in `game:turn.userId` emits `{action:'chaal'}` | ack `ok === false`, `code === 'not_your_turn'` |
| 14 | `a player who stalls past the turn timer is packed and the other wins` (337) | nobody acts; wait `game:handEnded` (5 s) | `winnerId !== turn.userId`; `reason === 'last_standing'`; some `game:action` has `reason === 'timeout'` |
| 15 | `a table holds at most five players and a sixth opens a new one` (360) | 6 guests `device-cap-{i}-0050`, each QJ same boot | all `ok`; distinct `roomId`s === 2; **PEEK** `rooms.getTable(id).playerCount` sorted deepEqual `[1,5]` [substitute: `lobby:list` → `tables[].players` for those two roomIds, or count occupied `seats` in each client's last `room:state`] |
| 16 | `a private room can be created and joined by its code` (382) | host `room:create {isPrivate:true}`; guest `room:joinCode {code}`; `room:joinCode {code:'ZZZZZZ'}` | create `ok`, `code` matches `/^[A-Z2-9]{6}$/`; join `ok` and `roomId === created.roomId`; ZZZZZZ → `ok === false`; **PEEK** `rooms.getTable(created.roomId).config.bootAmount === 200` (private boot fixed despite suite `BOOT_AMOUNT=100`) [substitute: `room:joined.bootAmount === 200` on the host's socket] |
| 17 | `leaving a room frees the seat` (408) | QJ; **PEEK** `playerCount === 1`; `room:leave {}`; **PEEK** `rooms.getTableForPlayer(id) === null` | [substitute: `room:left {roomId}` received and a subsequent `room:quickJoin` succeeds instead of `already_in_room`] |
| 18 | `a second sign-in replaces the first session` (421) | open two sockets with the same token | first receives `session:replaced` with truthy `message` |

**Blind / seen categories**

| # | Test name | Scenario | Assertions |
|---|---|---|---|
| 19 | `blind and seen tables at the same stake are separate rooms` (434) | QJ(boot,'blind') and QJ(boot,'seen') | both `ok`; acks `category` echo `'blind'`/`'seen'`; `roomId`s differ |
| 20 | `on a seen table a player can see everyone's chips` (454) | two QJ(boot,'seen'); wait `room:state` with 2 occupied seats | `category === 'seen'`; `chipsHidden === false`; every occupied seat `typeof chips === 'number'` and `> 0` |
| 21 | `on a blind table you see only your own chips` (479) | two QJ(boot,'blind') | `category === 'blind'`; `chipsHidden === true`; own seat `typeof chips === 'number'`; other seat `chips === null`; every non-viewer occupied seat `chips === null` |
| 22 | `the lobby offers the configured categories and stakes` (512) | wait `session:ready`; `lobby:list {}` | `config.categories` deepEqual `['seen','blind']`; `Array.isArray(config.stakes)` (it is `[]` here); ack `ok`, `Array.isArray(tables)`, `Array.isArray(options.categories)` |
| 23 | `the lobby can be filtered to one category` (528) | QJ(boot,'blind'); `lobby:list {category:'blind'}` and `{category:'seen'}` | every table in the blind list has `category==='blind'`, seen list all `'seen'`; blind list contains a table with `bootAmount === boot` |
| 24 | `an unknown category is treated as seen rather than hiding chips` (545) | QJ(boot, `'sneaky'`) | `ok`; ack `category === 'seen'` |

**Room chat**

| # | Test name | Scenario | Assertions |
|---|---|---|---|
| 25 | `a chat message reaches everyone in the room and nobody outside it` (562) | A,B same table; C another stake; A `chat:message {text:'good luck all'}` | B receives it: `displayName === 'ChatA'`, `userId === a.user.id`, `at > 0`; after 150 ms C has **no** `chat:message` with that text |
| 26 | `a player joining later is sent the room backlog` (594) | A QJ, posts 'first message','second message'; B `room:joinCode {code}` | B's `chat:history.messages[].text` includes both texts **and** `'HistA joined the table'`; `history.roomId === joined.roomId` |
| 27 | `room chat history is capped at 100 messages` (620) | **PEEK** `table.postChat(userId, 'spam i')` ×130 (bypasses the 5/5 s limiter); then `chat:history {}`; wait for a history with ≥100 messages | `messages.length === 100`; last text `'spam 130'`; no `'spam 1'` [substitute: no black-box path can post 130 messages fast — either accept a slow run (130 msgs at 5/5 s ≈ 2.2 min) or keep this white-box] |
| 28 | `chat history dies with the room when the last player leaves` (643) | QJ; chat; **PEEK** `chatHistory().length > 0`; `room:leave`; **PEEK** `rooms.getTable(roomId) === null`; new player QJ new stake → `chat:history` | `rejoined.roomId !== joined.roomId`; history lacks `'anyone around?'` [substitute: `/health.tables` decreases, or `lobby:list` no longer lists the roomId] |
| 29 | `a player who is not at a table cannot chat` (670) | `chat:message {text:'hello?'}` unseated | `ok === false`, `code === 'not_in_room'` |
| 30 | `chat flooding is rate limited` (681) | QJ then 12 sequential `chat:message {text:'flood i'}` | some ack `ok === false`; some `code === 'chat_rate_limited'`; ≥3 acks `ok` |
| 31 | `empty chat messages are ignored` (701) | QJ; **PEEK** history length before; `chat:message {text:'   '}` | `ok === true`; `messageId === undefined`; **PEEK** history length unchanged [substitute: no `chat:message` event arrives within ~150 ms] |

**Resume / reconnect**

| # | Test name | Scenario | Assertions |
|---|---|---|---|
| 32 | `a player whose app dies mid-hand is put straight back at the table on reconnect` (720) | A,B QJ; wait `game:handStarted`; `ca.socket.disconnect()` (no leave); pause 100 ms (< 400 grace); reopen A | `session:ready.resume === undefined`; `room:joined` arrives unrequested with `roomId === joined.roomId`, `state === 'betting'`, `you` truthy, `you.status === 'active'`, `seats[you.seatIndex].userId === alice.id` |
| 33 | `once the held seat has lapsed, the next sign-in is offered the same table back — once` (750) | as above but pause 800 ms; **PEEK** `rooms.getTableForPlayer(alice) === null`; reopen | `ready.resume` deepEqual `{roomId, code, category, bootAmount}` (all from the join ack + the boot); after 50 ms zero `room:joined`; `room:joinCode {code: resume.code}` `ok` with same `roomId`; `room:joined.roomId` equal; disconnect again, pause 50, reopen → `resume === undefined` and `room:joined.roomId` equal [PEEK substitute: B's `room:state` shows A's seat `status:'empty'`, or `/health.players`] |
| 34 | `leaving a table on purpose leaves nothing to resume` (792) | A `room:leave` (payload undefined → `{}`), disconnect, pause 800, reopen | `resume === undefined`; after 50 ms zero `room:joined` |
| 35 | `a table that closed while the player was away is not offered back` (816) | A disconnects, pause 800, B `close()` (leave+disconnect); **PEEK** `rooms.getTable(roomId) === null`; reopen A | `resume === undefined` |
| 36 | `health reports live table and player counts` (840) | `GET /health` | `ok === true`; `typeof tables === 'number'`; `typeof players === 'number'` |

Notes for re-running against a foreign server: the suite relies on `TABLE_STAKES=''`/`LOBBY_TABLES=''` (any boot
accepted), `BOOT_AMOUNT=100` (private/`room:create` boot is `PRIVATE_BOOT=200` regardless), `TURN_TIMEOUT_MS=1200`
(test 14 waits ≤5 s: the stalling player is packed at 1.2 s and the other is last standing),
`NEXT_HAND_DELAY_MS=150`, `RECONNECT_GRACE_MS=400`, `AUTH_ALLOW_FAKE_PROVIDERS=true` (test 7), `WELCOME_CHIPS=200000`.
Device ids are fixed strings, so a re-run against a **persistent** schema makes test 1 fail (`isNew === false`) — always
use a throwaway schema.

### 6.2 `test/socketProtocol.test.js` — 14 tests, env §2 (boot 100, turn 3000 ms, next hand 150 ms)

Parser-only (no server; they pin the *client's* parser, INCIDENTAL for the server except that server frames must stay
readable by it):

| # | Test (line) | Input → expectation |
|---|---|---|
| 1 | `the ported parser splits a Socket.IO event envelope` (122) | `["game:turn",{"userId":"abc","seatIndex":2,"deadline":1730000000000}]` → name `game:turn`, `userId` `abc`, `seatIndex` 2 |
| 2 | `braces and brackets inside strings do not confuse the splitter` (130) | text `gg [nice] {hand} \"wp\"` round-trips |
| 3 | `nested objects and arrays are extracted whole` (138) | payload of a `room:state` sample is valid JSON with `you.cards.length===3`, `seats.length===2` |
| 4 | `escaped quotes and unicode survive a round trip` (147) | `Raj "The Ace" éü` via `Json.escape` → `getString` equal |
| 5 | `an event with no payload does not break the splitter` (153) | `["room:left"]` → name ok, second element `null` |
| 6 | `booleans and negative numbers parse` (159) | `getBool` true/false, `getInt` −1500 and 0 |

Live, over a raw WebSocket (MUST MATCH):

| # | Test (line) | Scenario | Assertions |
|---|---|---|---|
| 7 | `the Unity handshake is accepted by the real server` (169) | guest `device-proto-0001`; open; wait connected | `client.sid` truthy (read from OPEN); `pingIntervalMs > 0`; `connected === true`; `frames[0].startsWith('0{')`; `session:ready` payload → `Json.getString(ready,'id')` (first `"id"` in the frame = `user.id`) `=== account.user.id` |
| 8 | `a bad token is reported as a connect error the client can read` (189) | token `not-a-real-token` | within 4 s `connectError` set (from `44{"message":…}`) and matches `/invalid_session|unauthorized|unknown_user/`; `connected === false` |
| 9 | `the client answers Engine.IO pings so the server keeps the socket` (204) | after connect, `receive('2') === '3'`, `receive('3') === null` (pure parser, but run connected) | |
| 10 | `a full hand is readable end to end by the Unity parser` (218) | A,B: `421["room:quickJoin",{"bootAmount":100}]` (ack id 1) | `ack:room:quickJoin` → `ok` true, `code` matches `/^[A-Z2-9]{6}$/`; `room:joined.maxPlayers === 5`; `game:handStarted.pot === 200`, `.handNo === 1`; `game:turn.userId` picks the on-turn client; its `game:yourTurn.options` has `chaal === 100`, `raise === 200`, `canSee === true`; emit `42["game:action",{"action":"see"}]` (no ack) → `player:cards.cards` length 3, each `/^[2-9TJQKA][shdc]$/`; the idle client has 0 `player:cards`; emit `{"action":"show"}` → `game:showdown.reveals` length 2, each `cards.length===3` and non-empty string `handName`; `game:handEnded.pot === 400`, `winnerId` and `reason` non-empty strings |
| 11 | `a game error frame reaches the Unity client` (283) | unseated client `421["game:action",{"action":"chaal"}]` | ack `ok === false`, `code === 'not_in_room'`, `message.length > 0` |
| 12 | `room chat frames are readable by the Unity parser` (298) | A QJ boot **700** with ack; read `code`; wait `chat:history` (messages is an array); emit `chat:message {"text":"hello table"}` | A's `chat:message` echo: `text`, `displayName === 'ChatProtoA'`, `getBool(posted,'system') === false` (key absent → fallback), `at > 0`; B `421["room:joinCode",{"code":"<code>"}]` → its `chat:history.messages` includes `hello table` and some message with `system === true` |
| 13 | `chat text with quotes and braces round-trips through the parser` (333) | QJ boot **800**; text `nice {trail} "wp" [gg]` escaped | echoed text equal via scanner and via `JSON.parse` |
| 14 | `a display name with quotes and braces survives the round trip` (350) | guest with displayName `Raj "Ace" {x}` | `JSON.parse(session:ready).user.displayName` equal; `Json.getString(ready,'displayName')` equal (first `"displayName"` occurrence is inside `user`) |

Test 10 and 12/13 share the same server; boots 100/700/800 keep their tables apart. Sockets are never `room:leave`d
here, so the players stay seated until `rooms.shutdown()`.

### 6.3 `test/invalidMoves.test.js` — 16 tests, env §2 (boot 100, turn 60 s, sideshow 60 s, grace 400 ms)

`dealtTable(tag)` returns `{bootAmount, ca, cb, onTurn, waiting, onTurnUser, waitingUser, table, joined, started}`; the
`table` object is the PEEK. Black-box substitute for "who is on turn": `ca.wait('room:state', s => s.turn?.userId)` →
`turn.userId`, and for `table.hand.stake` / `table.hand.pot` read `room:state.stake` / `.pot`.

| # | Test (line) | Scenario | Assertions |
|---|---|---|---|
| 1 | `acting out of turn is refused and the turn does not move` (138) | for each action in `['chaal','pack','show','sideshow']` the waiting player emits `{action, amount: stake, actionId:'oot-'+action}` | each ack `ok false`, `code 'not_your_turn'`; PEEK `hand.turnSeat` unchanged [sub: `room:state.turn.seatIndex`] |
| 2 | `a bet that is not on the ladder is refused, whatever the figure` (151) | on-turn chaals with amounts `stake+1, stake*3, -stake, 0, 1, 1e15, wallet+1` (`actionId: 'ladder-'+amount`) | each `ok false` with code ∈ `{invalid_bet, insufficient_chips}`; pot unchanged (PEEK) [sub: `room:state.pot`]; **DB** `SELECT chips FROM users WHERE id=$1` unchanged |
| 3 | `a bet amount that is not a number at all is refused before it reaches the table` (175) | amounts `String(stake), 'abc', 1.5, {amount:100}, [stake], true` | every ack `ok false`, `code === 'invalid_bet'`; pot unchanged. (NaN/Infinity omitted: JSON turns them into `null` = "chaal at stake") |
| 4 | `an unknown action, or one from a player at no table, is refused` (192) | `{action:'allin'}` → `unknown_action`; `{action:'__proto__'}` → `ok false` (also `unknown_action`); unseated Cara `{action:'pack'}` → `not_in_room` | |
| 5 | `a show with more than two players in the hand is refused` (209) | 3 players `device-show3-{1,2,3}` QJ same boot; on-turn `{action:'show'}` | `ok false`, `code 'show_unavailable'`; PEEK `table.hand` still truthy [sub: `room:state.state === 'betting'`] |
| 6 | `a sideshow with only two players is refused, and so is answering one that was never asked` (230) | on-turn `{action:'sideshow'}` → `too_few_players`; waiting `game:sideshowRespond {accept:true}` → `no_sideshow` | hand still live |
| 7 | `seeing twice is refused, and seeing never hands over the turn` (243) | **waiting** player `see` → `ok true`; `see` again → `ok false`, `already_seen` | turnSeat unchanged; PEEK `findSeat(waiting).isBlind === false` [sub: waiting's `room:state.you.isBlind === false`] |
| 8 | `replaying a move with the same actionId charges nobody twice` (257) | on-turn `{action:'chaal', amount: stake, actionId:'dup-same-id'}` → `ok true`; same payload again → `ok false` (fails `not_your_turn` first, turn moved) | **DB** `SELECT COUNT(*) AS n FROM chip_ledger WHERE action_id = $1` → `n === 1` (number); wallet `=== before - stake` |
| 9 | `a player who is not seated cannot ask for cards, and a seated one cannot see another's` (277) | unseated `player:requestCards {}` → `not_in_room`; PEEK other seat's real cards exist; inspect `JSON.stringify(onTurn.seen)` | other seat in last `room:state`/`room:joined` has `cards === undefined`; the entire recorded event log contains no substring `"cards":["` (nobody has seen yet) |
| 10 | `joining while already seated, or a room that does not exist, is refused` (300) | seated: QJ → `already_in_room`; `room:joinCode {code:'NOPE00'}` → code ∈ `{already_in_room, room_not_found}` (actual: `already_in_room`, checked first); `room:create {isPrivate:true}` → `already_in_room`; unseated Cara: `joinCode NOPE00` → `room_not_found`; `joinCode {code:{$gt:''}}` → `ok false` (`String({...})` = `[OBJECT OBJECT]` → not found); `QJ {bootAmount:-5}` → false (`invalid_stake`); `QJ {bootAmount:'lots'}` → false; **`QJ null` → `ok true`** (payload `?? {}` → default boot 100) |
| 11 | `a player who cannot cover the boot is not seated` (335) | `applyChipDelta({userId, delta: -(chips-50), reason:'test_fixture', actionId:'poor-fixture'})` (leaves 50) [sub: any ledger-consistent way to set the wallet to 50 — see §10]; QJ | `ok false`, `insufficient_chips`; not seated (PEEK) |
| 12 | `the sixth player is not squeezed onto a full table` (348) | PEEK `rooms.createTable({bootAmount, isPrivate:true})` [sub: first client `room:create {isPrivate:true}` and use its `code`; that host counts as seat 1]; 5 joins by code `ok`; 6th | `ok false`, `code 'table_full'` |
| 13 | `chat that is empty, too long, or from outside the room never reaches the table` (369) | on-turn sends, in order, `{text:'   '}`, `{text:'x'.repeat(5000)}`, `{text:12345}`, `null`, `{text:'hello table'}` (5 sends = the whole 5/5 s allowance) | waiting hears exactly 3 messages: `[0].text.length === 140`, `[1].text === '12345'`, `[2].text === 'hello table'` |
| 14 | `garbage on every gameplay event is refused rather than crashing the server` (399) | payloads `undefined, null, 42, 'string', [], [1,2], {action:null}, {action:{}}, {amount:{}}, {action:'chaal',amount:'1e3'}, {action:'chaal',amount:[100]}, {action:'raise',amount:true}, {__proto__:{action:'pack'}}` × events `game:action, game:sideshowRespond, room:quickJoin, room:joinCode, room:create, chat:message` (78 requests, mostly rate-limited after 30) | every request is **acked within 1.5 s** (never silent); `chat:message` acks have no `messageId`; all others `ok === false`; hand still live; socket still connected; after 5200 ms `{action:'pack', actionId:'garbage-pack'}` → `ok true` |
| 15 | `too many requests in a burst are rate limited but the session survives` (437) | 60 concurrent `lobby:list {i}` | some `game:error` with `code 'rate_limited'` (or undefined acks); socket connected |
| 16 | `after all of the above every wallet still equals its ledger` (449) | **DB** `SELECT id, chips FROM users`; per row `SELECT COALESCE(SUM(delta),0) AS total FROM chip_ledger WHERE user_id=$1` | `chips === total` for every user in the schema |

### 6.4 `test/metrics.test.js` — 9 tests, env §2 + `METRICS_TOKEN=metrics-test-token`, `TURN_TIMEOUT_MS=4000`

| # | Test (line) | Scenario | Assertions |
|---|---|---|---|
| 1 | `/metrics requires the bearer token and serves the text exposition` (302) | no header → **401**; `Bearer not-the-token` → 401; right token → 200 | `content-type` startsWith `text/plain`; body matches `/^# HELP /m` and `/^# TYPE game_connected_sockets gauge$/m` |
| 2 | `default process metrics are exported under the game_server_ prefix` (357) | scrape | each of `game_server_process_resident_memory_bytes, game_server_nodejs_heap_size_used_bytes, …heap_size_total_bytes, …heap_size_limit_bytes, …external_memory_bytes, …array_buffers_bytes, …eventloop_lag_seconds, …eventloop_utilization, …active_handles_total, …active_requests_total, game_server_process_uptime_seconds, game_server_nodejs_version_info, game_server_process_start_time_seconds, game_server_process_cpu_user_seconds_total, game_server_process_cpu_system_seconds_total, game_server_process_open_fds` present; `# TYPE game_server_nodejs_gc_duration_seconds histogram`; **every** sample name startsWith `game_`; every sample has label `service="king-teenpatti"`; RSS/heap/uptime/open_fds > 0; heap limit > heap used; ELU ∈ [0,1]; after churning garbage, eventually `game_server_nodejs_gc_duration_seconds_count ≥ 1`. **Node-specific — a Go server cannot satisfy this test literally**; the parity harness should replace the list with the Go runtime's equivalents while keeping the `game_server_` prefix, the `game_` namespace rule, the `service` label, and `game_server_process_uptime_seconds`/`process_open_fds`/`process_resident_memory_bytes`/`process_cpu_*_seconds_total`/`process_start_time_seconds` |
| 3 | `sockets: the live gauge follows connects and disconnects, and the totals count them` (391) | two guests open | eventually `game_connected_sockets === before+2`, `game_connections_total ≥ before+2`, `game_connected_sockets_peak ≥ before+2`, gauge `=== io.engine.clientsCount` (PEEK; sub: drop); after `closeAll` eventually gauge `=== before`, `game_disconnections_total ≥ before+2`, every `reason` label value matches `/^[a-z][a-z _]*$/` (Socket.IO reason strings, e.g. `client namespace disconnect`, folded to `other` when unknown) |
| 4 | `game: a dealt hand and its moves are counted and timed` (423) | `dealTwoPlayerHand` (seen); on-turn `see` then `chaal` | eventually: `game_players_online ≥ 2`; `game_active_games ≥ 1`; `game_tables{category="seen",stake="<boot>"} ≥ 1`; `game_games_started_total{category="seen"} ≥ 1`; `game_moves_total{action="see"} ≥ 1`, `{action="chaal"} ≥ 1`; `game_socket_messages_total{event="game:action"} ≥ 2`, `{event="room:quickJoin"} ≥ 2`; `game_move_processing_duration_seconds_bucket{action="chaal",le="+Inf"} ≥ 1` and `le="1"` present; `…_count{action="see"} ≥ 1`; `game_state_update_duration_seconds_count ≥ 1`; `game_join_duration_seconds_count{route="quick_join"} ≥ 2`; `game_creation_duration_seconds_count ≥ 1`; `game_hand_start_duration_seconds_count ≥ 1`; `game_db_transaction_duration_seconds_count{op="boot"} ≥ 1`, `{op="bet"} ≥ 1`; `game_move_processing_duration_seconds_sum{action="chaal"} > 0`; `game_db_transaction_duration_seconds_sum{op="bet"} > 0` |
| 5 | `invalid moves are counted by refusal code` (462) | waiting emits `chaal` (→ `not_your_turn`) and `{action:'teleport'}` (→ `unknown_action`) | eventually `game_invalid_moves_total{code="not_your_turn"} ≥ 1`, `game_socket_errors_total{code="not_your_turn"} ≥ 1`, `{code="unknown_action"} ≥ 1` (both metrics); `game_socket_emits_total{event="game:error"} ≥ 2`; `game_moves_total` total unchanged; no `action="teleport"` label value |
| 6 | `a completed hand is counted with its reason, and the pot it paid out` (491) | on-turn `pack` | `game:handEnded.reason === 'last_standing'`, `.pot === boot*2`, `winnerId` truthy; eventually `game_games_completed_total{category="seen",reason="last_standing"} ≥ 1`; `game_pot_settled_chips_total ≥ before + pot`; `game_socket_emits_total{event="game:handEnded"} ≥ 1`; `game_moves_total{action="pack"} ≥ 1`; `game_settlement_duration_seconds_count ≥ 1` |
| 7 | `http: requests are counted by route pattern, never by raw path` (518) | `/api/auth/me` 200, `/health` 200, `/api/auth/me/hands?limit=3` 200, `/nothing-here-123` 404 | eventually `game_http_requests_total{method="POST",route="/api/auth/login",status_code="200"} ≥ 1`; `{GET,"/api/auth/me",200}`; `{GET,"/health",200}`; `{GET,"/api/auth/me/hands",200}`; `{GET,route="unmatched",404}`; `game_http_request_duration_seconds_bucket{route="/health",le="+Inf"} ≥ 1` and `_count ≥ 1`; no route label contains `?`, `limit=`, or `/\/\d+(\/|$)/`; no route `/nothing-here-123`; **no** `game_http_requests_total{route="/metrics"}` (scrapes excluded) |
| 8 | `chat: a posted message is counted and its broadcast recorded` (550) | two players; A `chat:message {text:'good luck all'}` | ack `ok`, `messageId` truthy; B receives it; eventually `game_chat_messages_total ≥ max(1, before+1)`; `game_socket_emits_total{event="chat:message"} ≥ 1`; `game_socket_messages_total{event="chat:message"} ≥ 1` |
| 9 | `cardinality: no label carries an identifier, address or raw path` (580) | final scrape | some `game_*` sample has >1 label; no label **name** in `[socket_id,user_id,room_id,code_,ip,url,path,device_id]`, none ending `_id`, none starting `code_`; no label **value** contains a UUID, IPv4, IPv6-looking (≥2 colons of `[0-9a-f.:]`), or 64-hex string; every `code` value matches `/^[a-z][a-z0-9_]*$/`; every `event` value matches `/^[a-z]+:[a-zA-Z]+$/`; every `category` ∈ `{seen, blind, other}`; every `method` matches `/^[A-Z]+$/` |

Metric catalogue the tests depend on is in `src/metrics/index.js:80-325`; label folding `safeLabel` (368-371) with the
known sets at `socket/index.js:44-105` and `db/ledger.js:59-67`. Histogram buckets `[0.001,0.005,0.01,0.025,0.05,0.1,0.25,0.5,1]`.
Route label rule (`metrics/index.js:333-341`): Express `baseUrl + route.path` (so `/api/auth/me/hands`), `static` for `/`
or paths with a 2–5 char extension, else `unmatched`. `/metrics` itself bypasses the middleware (346).

---

## 7. Semi-black-box suites

### 7.1 `test/stakes.test.js` — 9 tests, **default menu** (`TABLE_STAKES` and `LOBBY_TABLES` deleted from env)

`player(chips=200000)` = `{id:'p-<8 base36>', displayName:'Player', avatarUrl:null, chips}`; `rooms.quickJoin(player, {bootAmount, category})`
returns the `Table`. Every rule here is reachable over `room:quickJoin` on a server started **without** `TABLE_STAKES`/`LOBBY_TABLES`
overrides (chips come from the DB, so use `applyChipDelta`/fixture rows to set stacks).

| # | Test (line) | Assertion (in-process) | Black-box equivalent |
|---|---|---|---|
| 1 | `the lobby offers exactly the 200 and 5000 stakes` (42) | `config.game.tableStakes` deepEqual `[200,5000]`; `lobbyOptions().stakes` same; `.categories` deepEqual `['seen','blind']` | `session:ready.config.stakes`/`.categories` |
| 2 | `the menu is three rooms, in the order the lobby shows them` (48) | `lobbyOptions().tables` deepEqual `[{category:'seen',bootAmount:200,maxPot:1200000,maxBlindMoves:4},{category:'blind',bootAmount:200,maxPot:0,maxBlindMoves:4},{category:'blind',bootAmount:5000,maxPot:0,maxBlindMoves:4}]` (key order `category, bootAmount, maxPot, maxBlindMoves`) | `session:ready.config.tables` deepEqual |
| 3 | `the ceiling a card advertises is the one the table is built with` (58) | for each menu entry, `quickJoin(...)` → `table.maxPot === entry.maxPot`, `table.config.maxBlindMoves === entry.maxBlindMoves` | `room:joined.maxPot` per entry (1200000 / 0 / 0) |
| 4 | `every room on the menu can be joined` (73) | each entry joinable; `table.config.bootAmount`, `table.category` echo; `rooms.listTables().length === 3` | acks `ok` + `category`; `lobby:list.tables.length === 3` |
| 5 | `a stake and category that is not a room on the menu is refused` (86) | `{bootAmount:5000, category:'seen'}` → `table_not_offered`; `listTables().length === 0` | same ack code; `lobby:list` empty |
| 6 | `a stake the lobby does not offer is refused` (100) | boots `1, 100, 199, 4999, 10000` → `invalid_stake` | same |
| 7 | `a malformed stake is refused` (114) | `0, -200, 200.5, NaN, 'lots', null` → `invalid_stake` — **note `null` throws here because the in-process default only applies when the key is `undefined`**; over the wire `{bootAmount:null}` also reaches `quickJoin` as `null ?? config.game.bootAmount` = **200**, so the socket path accepts it | wire: `null`→ok(200), others `invalid_stake` (`NaN` is not representable in JSON) |
| 8 | `a player short of the stake cannot sit down` (128) | chips 4999: `{5000,'blind'}` → `insufficient_chips`; `{200}` (seen default) ok with `config.bootAmount === 200` | same |
| 9 | `players cluster onto the fullest matching table` (144) | two seen-200 joins share `id`; a blind-200 join gets another | acks `roomId` |

### 7.2 `test/statsAndRewards.test.js` — 13 tests over `db/users.js` + `db/ledger.js.settle`

`makeUser(name)` = `upsertFromProfile({provider:'guest', providerUserId:'stats-<seq>-<rand>', displayName})`.
`settle(entries, pot)` = `users.settleHand({hand:{id:'hand-…', roomId:'room-stats', handNo:1, pot, winnerId: first isWinner or null,
winReason:'show', bootAmount:200, startedAt: now-1000, endedAt: now, summary:[]}, entries})` — i.e. **`ledger.settle`**
(`db/ledger.js:234-322`) with hand-written `entries [{userId, delta, isWinner, didChaal, leftMidHand}]`.
`setHandsPlayed(userId, n)` = `UPDATE users SET hands_played = $1 WHERE id = $2`.

| # | Test (line) | Setup → assertions (MUST MATCH the DB semantics) |
|---|---|---|
| 1 | `a hand only counts as played once the player bets beyond the boot` (222) | entries better `{delta:400,isWinner:true,didChaal:true}`, folder `{delta:-200,isWinner:false,didChaal:false}`, pot 600 → better `handsPlayed 1`, folder `handsPlayed 0` |
| 2 | `wins, losses and abandoned hands are counted separately` (239) | winner `+800 W`, loser `-400 didChaal`, quitter `-400 didChaal leftMidHand` → W: won 1 lost 0 leftMid 0; L: won 0 lost 1 leftMid 0; Q: leftMid 1, lost **0**, played 1 |
| 3 | `total winnings accumulate the pots taken` (270) | two winning settles pots 1000 and 2500 → `totalWinnings 3500`, `biggestPot 2500`, `handsWon 2` (winner gets `+pot` into total_winnings and `GREATEST(biggest_pot, pot)`) |
| 4 | `the milestone reward unlocks every 25 played hands` (284) | fresh: `milestoneAvailable false`, `handsToNextMilestone 25`; hp=24: false, 1; hp=25: true, `milestoneAt 25`, `milestoneReward 25000` |
| 5 | `collecting the milestone reward grants 25,000 chips exactly once` (303) | hp=50; `claimMilestoneReward` → `{claimed:true, amount:25000, milestone:50, user}` with `user.chips === before+25000`, `user.rewards.milestoneAvailable false`; second → `{claimed:false, reason:'not_available', user}`, chips unchanged |
| 6 | `reaching the next milestone unlocks the reward again` (322) | hp 25 claim ok; hp 49 → not available; hp 50 → available, claim ok |
| 7 | `the milestone reward is written to the chip ledger` (340) | `SELECT * FROM chip_ledger WHERE user_id = $1 AND reason = 'milestone_reward'` → one row, `delta === 25000` (its `action_id` is `` `${userId}:milestone:${milestone}` ``, `db/users.js:236`) |
| 8 | `a new account can collect the timed bonus straight away` (357) | `rewards.bonusAvailable true`, `bonusReward 10000`, `bonusIntervalMs 14400000` |
| 9 | `collecting the bonus grants 10,000 chips and starts a 4-hour countdown` (366) | `claimTimedBonus` → `{claimed:true, amount:10000, readyAt, user}`; `readyAt` within ±1 s of `now+4h`; `user.chips === before+10000`; `user.rewards.bonusAvailable false` |
| 10 | `the bonus cannot be collected twice inside the countdown` (383) | second → `{claimed:false, reason:'not_ready', readyAt > now, user}`; chips unchanged |
| 11 | `the countdown lives in the database, so it survives a restart` (396) | `SELECT next_bonus_at FROM users WHERE id=$1` `=== result.readyAt`; `UPDATE users SET next_bonus_at = $1 WHERE id = $2` to `now-1` → `bonusAvailable true`, claim ok |
| 12 | `a provider picture is kept and used by default` (411) | google profile with `avatarUrl` → `user.avatarUrl` and `providerAvatarUrl` both the URL; `avatarChoice null` |
| 13 | `a chosen picture overrides the provider one, and clearing restores it` (424) | `setAvatarChoice(id,'/profiles/ace.svg')` → `avatarUrl '/profiles/ace.svg'`, `providerAvatarUrl` original; `setAvatarChoice(id,null)` → `avatarUrl` back to provider URL |

Black-box equivalents: 4–11 via `POST /api/rewards/milestone` / `POST /api/rewards/bonus` (`auth/routes.js:114-151`: success
returns the same `{claimed, amount, milestone|readyAt, user}` object; refusal `409 {"error":"reward_not_available","message":"No milestone reward is waiting yet.","user"}`
or `409 {"error":"reward_not_ready","message":"The bonus is still recharging.","readyAt","user"}`) plus the two SQL
updates; 12–13 via fake-provider login with… no — the fake provider sets `avatarUrl: null` (`providers.js:370`), so
provider pictures are only testable with `upsertFromProfile` or a DB write; `POST /api/profile/avatar {avatar:'ace.svg'|null}`
covers the choice/clear half (only ids listed by `GET /api/profiles` — files in `public/profiles/` — are accepted).
Tests 1–3 need `ledger.settle` with synthetic entries; black-box, play real hands and assert `/me` counters (integration #12
covers `handsWon`/`handsPlayed`).

---

## 8. White-box suites — test cases to mirror

These construct `Table`/`RoomManager` directly. The **rules** they pin are MUST MATCH (they are what clients see through
`room:state`, `game:*` events and the ledger); the construction API is INCIDENTAL. For each: setup → assertions, with the
rule's source line.

Shared conventions: `turnUser(table) = table.seats[table.hand.turnSeat].userId`; `await advance(nextHandDelayMs)` deals the
first hand; `setHands/giveCards` overwrite `seat.cards` with `parseCard` objects; `settle` hooks return `{userId: balance}`.
Suite-specific `baseConfig` values are given at the head of each block because ladders/caps depend on them.

### 8.1 `test/table.test.js` — 32 tests. Config: boot 100, start 200000, turn 25000, `maxBetRounds 20`, `potLimitMultiplier 1024`, next hand 6000; **no `maxRaiseSteps`/`maxBlindMoves`/`maxMissedTurns`** (see §3 T)

`settle` mirrors production: returns `seat.chips + (isWinner ? pot : 0)` per entry (chips already net of contributions).

| Test (line) | Setup → assertions | Rule source |
|---|---|---|
| `a table waits until the minimum number of players is seated` (78) | seat alice → `state 'waiting'`, `hand null`; seat bob → `state 'starting'`; advance 6000 → `'betting'`, hand truthy | `table.js:308-328` |
| `a table seats at most five players` (93) | 5 seats → `playerCount 5`, `isFull`; 6th throws `table_full` | 147-149 |
| `the same player cannot take two seats` (101) | re-seat → `already_seated` | 148 |
| `a player who joins mid-hand sits out until the next deal` (107) | seat carol after deal → `status 'waiting'`, `cards.length 0`, `activeSeats.length 2` | 160 |
| `a player who cannot cover the boot is dealt out` (119) | `seat('broke', 99)` → after deal `status 'waiting'`, 2 active (no kick listener here; `_sweepUnfunded` only emits) | 304-306, 681-696 |
| `every player is dealt three hidden cards and the boot is collected` (132) | 3 players → each active: 3 cards, `isBlind`, `chips 199900`, `contributed 100`; `hand.pot 300`; `handStarted.pot 300`; `serializeFor('alice').you.cards` deepEqual `[]` | 353-487 |
| `a snapshot never contains another player's cards` (153) | on-turn `see`; `view.you.cards.length 3`; every `view.seats[i].cards === undefined` | 1708, 1715-1737 |
| `turns open left of the dealer and rotate clockwise` (170) | 3 players; expected order = walk `(dealerSeat+1)%5` upward over occupied seats; 3 chaals → order deepEqual; ≥3 `turn` events | 482-484, 581-588 |
| `acting out of turn is refused` (193) | `not_your_turn` | 938 |
| `a player not in the hand cannot act` (205) | late seat → `not_in_hand`; unknown user → `not_seated` | 931-933 |
| `a blind player bets the stake or double it; a seen player pays double that` (218) | blind `betOptions`: `chaal 100`, `raise 200`; after `see`: `chaal 200`, `raise 400` | 761-798 |
| `a blind bet raises the stake; a seen bet raises it by half as much` (235) | blind `raise` → `stake 200`, `pot 400`; next `see`+`chaal` (pays 400) → `pot 800`, `stake` stays 200 (`floor(400/2)`) | 1063 |
| `seeing cards is free, reveals only your hand, and does not pass the turn` (253) | chips unchanged; turn unchanged; `cards` event `{userId, cards.length 3}`; second `see` → `already_seen` | 976-1008 |
| `bets are capped by the pot limit` (271) | `potLimitMultiplier 4`, seen player: `chaal 200`, `raise 400`, `max 400` | 767-771 |
| `a player who cannot afford a bet is offered no bet` (286) | bob 110 → 10 left: `turnOptions` `chaal null`, `raise null`, `canPack true` | 792-796, 825 |
| `packing forfeits the hand and passes the turn` (301) | 3 players; pack → `status 'packed'`, pot unchanged, turn moved, last `action.action 'pack'` | 1098-1120 |
| `the last player standing takes the pot without a show` (316) | two packs → `handEnded.reason 'last_standing'`, `.pot`, `.reveals` deepEqual `[]`, winner seat `status 'won'` | 1123-1140, 1406 |
| `a player who does not act within 25 seconds is packed automatically` (338) | advance 25000 → stalling `status 'packed'`; an `action` with `userId===stalling && reason==='timeout'`; turn moved | 641-656 |
| `the turn clock is announced with a deadline the client can count down` (354) | last `turn`: `timeoutMs 25000`; `deadline > Date.now()+20000`; `options.chaal > 0` | 601-628 |
| `acting resets the clock for the next player` (366) | advance 24000, chaal, advance 24000 → next still `'active'` | 623-627 |
| `a show needs exactly two players left` (382) | 3 active → `show_unavailable` | 1289 |
| `a show reveals both hands and the better hand takes the pot` (393) | alice `As Ah Ad` vs bob `2s 7h 9d`; show → `showdown.reveals.length 2`, `.reason 'show'`; `handEnded.winnerId 'alice'`, `.reason 'show'`, alice's reveal `handName 'Trail'` | 1332-1379 |
| `paying for a show costs the caller a chaal` (417) | blind caller `showCost === 100`; after show `serializeFor().pot === 0` | 801-804, 1663 |
| `an exact tie goes to the player who did not call the show` (435) | `As 9s 4s` vs `Ah 9h 4h` → `winnerId !== caller` | 1338-1358 |
| `the round cap forces a showdown so a pot cannot run forever` (454) | `maxBetRounds 3`; alice pure sequence; chaal until hand ends → `hand null`, `reason 'forced_showdown'`, `winnerId 'alice'` | 712-726, 1320-1323 |
| `the winner takes the whole pot and everyone else pays what they staked` (478) | chaal then show; `settled[-1].entries` deltas sum to 0; winner alice; `hand.summary` contributions sum === `ended.pot`; exactly one `isWinner` | 1416-1465 |
| `a hand record carries the full audit trail` (504) | record `roomId 'room-1'`, `handNo 1`, `bootAmount 100`, `startedAt <= endedAt`, `summary.length 2`, each row `cards.length 3` (showdown) and `contributed > 0` | 1444-1465 |
| `a player who leaves mid-hand still forfeits their stake` (524) | 3 players; on-turn chaal then `removePlayer(quitter,'left')`; remaining packs; quitter entry exists with `delta -200` (boot+chaal, no persistence in this suite); deltas sum 0; winner among remaining | 227-280, 1420-1441 |
| `the next hand starts automatically and the dealer button moves` (548) | pack ends hand 1 (`handNo 1`); advance 6000 → `handNo 2`, `dealerSeat` changed | 1522, 374 |
| `play stops when only one funded player remains` (564) | pack; `removePlayer('bob')`; advance 18000 → `state 'waiting'`, `hand null` | 363-369 |
| `a destroyed table stops all of its timers` (578) | destroy before deal; advance 30000 → `hand null` | 1767-1784 |
| `unknown actions are rejected` (587) | `act(user,'steal_the_pot')` → `GameError` `unknown_action` | 962-963 |

### 8.2 `test/tableRules.test.js` — 12 tests. Config: boot 200, start 200000, turn 25000, rounds 20, mult 1024, `maxRaiseSteps 8`, next 6000, chat 100/140

| Test (line) | Setup → assertions | Rule source |
|---|---|---|
| `when a player leaves mid-hand the one still sitting takes the pot` (69) | 2 players; on-turn chaal; `removePlayer(first,'left')` → `handEnded.reason 'last_standing'`, `winnerId === other`, `pot === potBefore`; deltas sum 0 | 247-269, 1123-1140 |
| `destroying a table mid-hand pays the pot out rather than voiding it` (94) | 3 players, one chaal, `destroy()` → `reason 'all_left'`, winner ∈ still-active, `pot` whole, deltas sum 0 | 1767-1772 |
| `successive departures hand the pot to whoever is still in the hand` (120) | remove active[0] → hand continues; remove active[1] → `hand null`, winner active[2], pot unchanged | |
| `a player who leaves mid-hand is flagged for the abandoned counter` (141) | quitter entry `leftMidHand true`, `didChaal true`, `isWinner false` | 254-256, 1438-1439 |
| `a player who only posts the boot is not marked as having played` (161) | immediate pack → `didChaal false`, `leftMidHand false` | 1059-1060 |
| `betting marks the hand as played` (178) | chaal → `didChaal true` | |
| `a seen table allows a single double per turn` (194) | `RoomManager.createTable({bootAmount:200, category:'seen'})` + `startHand()`: `steps` deepEqual `[200,400]`; `RAISE {amount:800}` → `invalid_bet` | `roomManager.js:113-119`, config `seenMaxRaiseSteps 2` |
| `a blind table keeps the full doubling ladder` (217) | blind: `steps.length > 2`, `steps[2] === 800` | 120-124 |
| `a blind table has no round cap, no rung cap and no per-bet ceiling` (232) | `config.maxBetRounds 0`, `maxRaiseSteps 0`, `potLimitMultiplier 0`, `table.maxPot 0` | |
| `a blind table never forces a showdown, however long the betting goes on` (244) | 120 chaals (players auto-seen after 4 blind moves) → hand live, `round >= 50`, no `handEnded` | 721-722 |
| `a seen table forces a showdown after 7 rounds` (269) | `config.maxBetRounds 7`; chaal loop → `hand null`, `reason 'forced_showdown'`, `showdown.reveals.length 2`, winner set | |
| `the showdown reveals every remaining player to everyone` (298) | show → each reveal `cards.length 3`, truthy `handName`, boolean `won`; exactly one `won` | 1360-1367 |

### 8.3 `test/blindRules.test.js` — 9 tests. Config: boot 200, start 5,000,000, rounds 40, mult 1,048,576, steps 8, `maxBlindMoves 4`

| Test (line) | Assertions | Rule source |
|---|---|---|
| `a player may see their cards when it is not their turn` (385) | waiting `isBlind true` → `see` does not reject → `isBlind false` | 938 |
| `seeing out of turn does not hand the player the turn` (399) | turn unchanged | 996 |
| `a player still cannot bet out of turn after looking` (412) | chaal → `not_your_turn` | |
| `the cards turn face up after the capped number of blind bets` (429) | for move 1..4: still blind before, `blindMoves === move` after; after 4th `isBlind false` | 1076-1083 |
| `the capped bet is itself still charged at the blind rate` (450) | 4th blind chaal costs exactly `hand.stake` (one unit), then `isBlind false` | 1063, 1077-1082 |
| `a player who looked early is never auto-seen` (476) | after `see`, 6 chaals keep `blindMoves 0` | 1077 |
| `the counter starts again on the next hand` (494) | next deal → `blindMoves 0`, `isBlind true` | 447-455 |
| `a seat reports its last bet as well as its running total` (515) | `serializeFor('watcher')` (non-seated viewer) seat: `lastBet 0` before; after chaal `lastBet > 0`, `contributed === before + lastBet`, `lastAction 'chaal'` | 1054-1055, 1731-1733 |
| `the last bet is cleared when the next hand is dealt` (535) | next deal → `lastBet 0`, `lastAction null` | 451-452 |

### 8.4 `test/categories.test.js` — 11 tests. Config: boot 200, rounds 20, mult 1024, steps 8; `category` passed inside config

| Test (line) | Assertions | Rule source |
|---|---|---|
| `a table defaults to the seen category` (50) | `category undefined` → `'seen'` | 69-71 |
| `an unknown category falls back to seen rather than hiding chips` (55) | `'nonsense'` → `'seen'` | |
| `the category is reported in the snapshot and the lobby row` (60) | `serializeFor().category` and `summary().category === 'blind'` | 1652, 1746 |
| `on a seen table everyone can see every stack` (70) | `chipsHidden false`; own 150000, bob 75000, carol 42000 | 1647, 1725 |
| `on a blind table you see your own stack but nobody else's` (86) | `chipsHidden true`; own 150000; others `null` | |
| `a hidden stack is null, never zero` (100) | `=== null`, `!== 0` | 1725 |
| `each viewer sees only their own stack on a blind table` (111) | symmetric | |
| `another player's stack is not in the serialized payload at all` (126) | `JSON.stringify(serializeFor('alice'))` lacks `'987654'`, contains `'1000'` | |
| `your own turn options still carry your stack on a blind table` (138) | `you.chips === 199800`; `you.options.chips === 199800` | 1692, 828 |
| `bets stay public on a blind table` (151) | bob's `contributed 200` visible, `chips null`; `pot 400` | 1733 |
| `hiding chips does not affect gameplay` (165) | blind vs seen table: identical `betOptions().steps` and pot (same config; category alone changes nothing) | |

### 8.5 `test/chat.test.js` — 14 tests (6 on `RoomChat`, 8 on `Table`). Config: boot 100, chat 100/140

| Test (line) | Assertions | Rule source |
|---|---|---|
| `messages are stored in order with author and timestamp` (224) | `history()[0]` `{text 'hello', displayName 'Alice', userId 'u1', at > 0, id truthy}`; `[1].text 'gg'` | `chat.js:281-299` |
| `history is capped at 100 messages, keeping the newest` (239) | 150 adds → length 100, `[0].text 'msg 51'`, `[99].text 'msg 150'` | 294-296 |
| `the cap is configurable` (252) | `maxHistory 3` → `['c','d','e']` | |
| `empty and whitespace-only messages are dropped` (259) | `''`, `'    '`, `null` → `add` returns `null`; `size 0` | 282-283, 337-343 |
| `control characters are stripped and long messages are trimmed` (267) | `maxLength 20`: input `'hi ' + U+001B + '[31m there'` → `'hi [31m there'` (the ESC becomes a space, the double space collapses); `'one\ntwo\r\nthree'` → `'one two three'`; 200 x's → length 20 | 337-343 (`\p{C}` → `' '`, `\s+` → `' '`, trim, slice) |
| `clearing drops the whole history` (283) | `clear()` → size 0, `[]` | 329-331 |
| `a seated player can post to their room` (293) | `postChat('alice','good luck everyone')` → `text`, `displayName 'Alice'`; a `chat` event fired | `table.js:199-212` |
| `a player who is not at the table cannot post to it` (304) | `not_in_room` | 201 |
| `joining and leaving are announced in the room log` (311) | texts include `'Alice joined the table'`, `'Bob joined the table'`, `'Bob left the table'`; every `system` line has `userId null` | 186, 245; `chat.js:302-318` |
| `a player who joins later sees the existing history` (327) | backlog + `'Carol joined the table'` | |
| `destroying the room deletes its chat history` (341) | after `destroy()` `chatHistory().length 0` | 1782 |
| `two tables never see each other's messages` (352) | isolation | |
| `chat keeps working while a hand is in progress` (366) | post succeeds mid-hand | |
| `chat history is never part of the table snapshot` (377) | `JSON.stringify(serializeFor())` lacks the text | |

### 8.6 `test/chipPersistence.test.js` — 6 tests. Config: boot 200, start 100000, rounds 40, mult 1024, steps 8, blind 4. `persistChips` hook debits a Map of accounts per boot/bet (asserting never negative); `settle` applies each entry's `delta` to the account

Key semantic: with `persistChips` present, `memoryLedger.bet` returns `persisted: amount` and `collectBoot` returns
`persisted: bootAmount` (`table.js:1805-1829`), so at `_endHand` `delta = net + persisted` → losers get **0**, the winner gets **+pot**
(`1425-1431`) — exactly the production shape.

| Test (line) | Assertions |
|---|---|
| `the boot leaves the account the moment it is posted` (88) | after deal both accounts `START-200`; `pot 400` |
| `every chaal is banked as it is made` (100) | account falls by `hand.stake`; `seat.chips === account` |
| `the winner is paid the pot and nobody is charged twice` (116) | after opponent packs: winner `+pot`, loser unchanged, total `2*START` |
| `a player who walks out mid-hand does not get their stake back` (138) | 3 players; quitter chaals then leaves: account `START - contributed` immediately and after the hand ends; total `3*START` |
| `chips are conserved across a long hand of raises` (165) | 9 raises/chaals (raise to `steps[1]` when available) then packs → total `3*START` |
| `a seat and its account never disagree` (187) | after each of 4 chaals every active seat `chips === account` |

### 8.7 `test/consolidation.test.js` — 15 tests. `RoomManager({timers, settle: () => ({})})`, `singleTable(rooms,{bootAmount=200, category='blind'})` = createTable + `rooms.join(table, player('Solo'))`

| Test (line) | Assertions | Rule source |
|---|---|---|
| `two tables with one player each are merged into one` (240) | `consolidateTables()` returns 1 move; `tables.size 1`; survivor `playerCount 2` with both ids | `roomManager.js:416-450` |
| `the merged players can now actually start a hand` (259) | survivor `state 'starting'`; advance 10000 → hand dealt | |
| `the player is moved onto the longest-standing table` (273) | `moves[0].fromRoomId === second.id`, `.toRoomId === first.id` (sorted by `createdAt` asc); second destroyed | 439-440 |
| `three lone players end up at the same table` (286) | size 1, `playerCount 3` | |
| `a move is announced so the client can follow it` (299) | `playerMoved` event `{userId, fromRoomId, toRoomId}` once | 484-485 |
| `the room index follows the player to their new table` (316) | `getTableForPlayer(moved).id === first.id` | 470-473 |
| `a table with a hand in progress is never disturbed` (330) | busy 2-player table mid-hand + a lone table → 0 moves; both tables remain | 417-423 (`!table.hand && state === 'waiting' && playerCount === 1`) |
| `a lone player is not moved while their own table has a live hand` (350) | `rooms.leave(one,'left')` mid-hand → `playerCount 1`, `hand null` (hand resolved as last_standing during the leave) | 345-363 |
| `tables of different stakes are never merged` (370) | 200 vs 5000 → 0 moves | 429 |
| `blind and seen tables are never merged` (380) | 0 moves | |
| `private tables are left alone` (390) | two private singles → 0 moves | 419 |
| `a full destination stops taking players` (402) | oldest table full (5) + lone → 0 moves | 443, 458 |
| `a single lone table has nothing to merge with` (416) | 0 moves, size 1 | |
| `the table announces when the next hand starts` (426) | survivor `serializeFor().state 'starting'`, `startsAt` in `(now, now+5000]` (default `nextHandDelayMs` 4000) | `table.js:320-322, 1662` |
| `leaving a table triggers a merge without waiting for the sweep` (441) | A(2 players) + B(1); one leaves A with `'left'` → `tables.size 1`, `playerCount 2` (leave calls `consolidateTables` unless reason `'moved'`) | 354-360 |

### 8.8 `test/handRank.test.js` — 13 tests (pure). Codes: rank `2-9,T,J,Q,K,A`, suit `s h d c`; `evaluate(cards)` → `{category, name, score, cards}`; `compare(a,b)` sign

| Test (line) | Assertions | Rule source |
|---|---|---|
| `classifies every Teen Patti category` (10) | `As Ah Ad` TRAIL(5); `As Ks Qs` PURE_SEQUENCE(4); `As Kh Qd` SEQUENCE(3); `As 9s 4s` COLOR(2); `As Ah 4d` PAIR(1); `As 9h 4d` HIGH_CARD(0) | `handRank.js:163-202` |
| `category ordering: trail > pure sequence > sequence > color > pair > high card` (19) | `2s2h2d > AsKsQs > AsKhQd > AsKsJs > AsAhKd > AsKhJd` | |
| `trails rank by card, ace high` (34) | AAA > KKK; 333 > 222 | |
| `sequence order is A-K-Q, then A-2-3, then K-Q-J down to 4-3-2` (39) | run strengths 28 > 27 > 26 … > 8 | 145-149 |
| `A-2-3 is recognised as a run in both flavours` (45) | `As 2s 3s` pure seq; `As 2h 3d` seq; `As 2h 4d` high card; `Ks Ah 2d` high card (no wrap) | 151-155 |
| `the ace-low variant demotes A-2-3 to the weakest run` (54) | `evaluate(..., {aceLowIsLowest:true})`: 4-3-2 beats A-2-3 (strength 5) | 147 |
| `colors compare card by card` (60) | `As9s4s > KhQh9h`; `As9s5s > Ah9h4h`; `As9s4s` ties `Ah9h4h` (suits never break ties) | 182-184 |
| `pairs compare pair rank first, then the kicker` (67) | `KsKh2d > QsQhAd`; `KsKhAd > KsKdQh`; `score` of `As Kh Kd` deepEqual `[1,13,14]`; `Ks Kh 2d` → `[1,13,2]` | 185-190 |
| `high cards compare in descending order` (75) | `As9h4d > KsQh9d`; `AsTh4d > Ah9d8s`; `AsTh5d > AhTd4s` | |
| `rejects hands that are not exactly three cards` (82) | throws `/exactly 3 cards/` for 2 or 4 cards | 164-166 |
| `a shuffled deck stays a legal 52-card deck` (87) | 52 unique codes | `deck.js:74-94` |
| `dealing five hands produces fifteen distinct cards` (93) | `deal(5,3)` → 5 hands, 15 distinct | 97-108 (round-robin one card at a time) |
| `the shuffle actually moves cards around` (101) | 10 shuffles never equal the ordered deck | |

`CATEGORY_NAMES` on the wire: `High Card`, `Pair`, `Color`, `Sequence`, `Pure Sequence`, `Trail` (126-133) — MUST MATCH (Flutter shows them verbatim).

### 8.9 `test/lobbyRules.test.js` — 17 tests. Uses the **real default config** (`entryCapMaxChips 500000`, `entryCapBoot 200`, `entryCapCategory 'blind'`, `tableStakes [200,5000]`)

| Test (line) | Assertions | Rule source |
|---|---|---|
| `a display name keeps letters, numbers and single spaces` (124) | `'  Suraj  Kumar '` → `'Suraj Kumar'`; `'Player7'` | `db/users.js:305-320` |
| `a name may be written in any script` (129) | `'सूरज'`, `'সুরজ'` pass | `\p{L}\p{N}\p{M}` |
| `an empty or blank name is refused` (134) | `''`, `'   '`, `'\t'`, `null`, `undefined` → throws `/empty_name/` | |
| `special characters are refused` (140) | `'Su<b>raj'`, `'a@b'`, `'hi!'`, `'--'`, `'x_y'`, `'drop;table'` → `/invalid_name/` | |
| `a name cannot start with a space or a digit-only decoration` (146) | `'   '` → empty_name; `'!Suraj'` → invalid_name | |
| `an over-long name is refused` (151) | 30 chars with `maxLength 24` → `/name_too_long/` (checked **before** the pattern) | 313-315 |
| `a big stack cannot join the capped table` (179) | chips `500001` at blind/200 → `over_entry_cap` | `roomManager.js:372-383` |
| `a stack exactly at the cap may still join` (187) | `500000` ok (`<=`) | 377 |
| `the cap applies only to that stake and category` (194) | rich at seen/200 ok; after `leave`, blind/5000 ok | 375-376 |
| `joining the capped table by code is refused too` (214) | `joinByCode(rich, code)` → `over_entry_cap` (public table) | 269-274 |
| `the lobby is told the rule so it can grey the table out` (228) | `lobbyOptions().entryCapBoot 200`, `entryCapCategory 'blind'`, `entryCapMaxChips 500000` | 216-218 |
| `names in Indic scripts survive their vowel marks` (235) | `'सूरज' 'সুরজ' 'સૂરજ' 'ਸੂਰਜ' 'प्रिया'` unchanged | |
| `a switch is not blocked by the entry cap` (245) | rich seated at a blind/200 table (via `join`), another blind/200 table exists → `switchTable(rich)` moves them there | 294-327 |
| `but the lobby route still refuses them` (263) | `quickJoin` → `over_entry_cap` | |
| `a switch never changes the stake or the category` (271) | only a seen/200 and a blind/5000 alternative exist → `no_other_table` | 304-321 |
| `switching keeps the seat when there is nowhere to go` (291) | after `no_other_table`, still seated at home | |
| `a player who is not seated cannot switch` (301) | `not_in_room` | 296 |

Name-error → HTTP mapping (`auth/routes.js:205-220`, MUST MATCH): `400 {"error":"empty_name","message":"Your name cannot be empty."}`,
`{"error":"name_too_long","message":"Keep it to 24 characters or fewer."}`, `{"error":"invalid_name","message":"Letters, numbers and spaces only."}`;
while seated `409 {"error":"seated","message":"You can only change your name in the lobby."}`.

### 8.10 `test/privateTables.test.js` — 10 tests

| Test (line) | Assertions | Rule source |
|---|---|---|
| `a private table always uses the fixed boot of 200 chips` (335) | `createTable({bootAmount: 50|199|200|1000|99999|undefined, isPrivate:true}).config.bootAmount === 200` | `roomManager.js:107` |
| `a public table still uses the stake it was created with` (347) | 100 → 100, 5000 → 5000 | |
| `the lobby advertises the fixed boot and the maximum win` (356) | `privateBoot 200`, `privateMaxPot 500000` | 220-221 |
| `a private table allows a single double per turn` (365) | private blind: `steps` deepEqual `[200,400]`; `RAISE 800` → `invalid_bet` | 128-133 (`privateMaxRaiseSteps 2` overrides blind's 0) |
| `a public blind table still keeps the full ladder` (384) | `steps.length > 2` | |
| `every table but a public blind one carries a pot ceiling` (397) | private (any category) `maxPot 500000`; public seen `1200000`; public blind `0` | 113-133 |
| `the ceiling is reported to clients in the table snapshot` (422) | `serializeFor('a').maxPot === 500000` | `table.js:1665` |
| `a bet that would push the pot past the ceiling is not offered` (432) | bare Table `maxPot 5000`, `hand.pot` forced to 4000 → `steps` deepEqual `[200,400,800]` (1600 > headroom 1000) | 779-786 |
| `reaching the ceiling ends the hand in a showdown` (457) | `maxPot 5000`, both bet `max` each turn → `hand null`, `reason 'pot_limit'`, `showdown.reveals.length 2`, winner set, `pot <= 5000`, deltas sum 0 | 704-710, 738-741 |
| `an uncapped table is unaffected by the ceiling logic` (503) | public blind, 2,000,000 chips: `steps.length > 8`, `max <= seat.chips`, `max*2 > seat.chips` | 767-786 |

### 8.11 `test/raiseLadder.test.js` — 18 tests. Config: boot 100, start 200000, rounds 20, mult 1024, `maxRaiseSteps 8`

| Test (line) | Assertions | Rule source |
|---|---|---|
| `each step doubles the previous amount` (59) | blind `steps` deepEqual `[100,200,400,800,1600,3200,6400,12800]` | 781-786 |
| `a seen player's ladder starts at double a blind player's` (75) | after `see`: `steps[0] 200`, `steps[1] 400` | 763 |
| `the ladder is capped by the number of steps configured` (89) | `maxRaiseSteps 3` → `[100,200,400]` | 774-775 |
| `the ladder is capped by the pot limit` (98) | `potLimitMultiplier 4` → `[100,200,400]`, `max 400` | 767-771 |
| `zero rungs and a zero multiplier mean the ladder runs to the whole stack` (109) | steps 0, mult 0, chips 1,000,100 → after boot 1,000,000: `steps.length 14`, `max 819200` | |
| `the ladder never offers more chips than the player holds` (127) | 650 left → `[100,200,400]`, `max 400` | 771 |
| `a player who cannot afford the base bet is offered no bet at all` (145) | 50 left → `raiseSteps []`, `chaal null`, `raise null`, `maxBet null`, `canPack true` | |
| `the turn payload carries the ladder and the player's stack` (161) | `raiseSteps[0] === chaal`, `[1] === raise`, `chips === 199900`, `maxBet === raiseSteps.at(-1)` | 806-831 |
| `a raise can be placed at any rung of the ladder` (178) | `RAISE {amount:800}` → action `amount 800`, pot +800, chips `START-100-800`, `stake 800` | 1029-1044, 1063 |
| `omitting the amount keeps the old default behaviour` (196) | bare `RAISE` → amount 200; bare `CHAAL` → action chaal | 1030-1031 |
| `an amount that is not on the ladder is refused` (209) | 150, 999, 101, 1 → `invalid_bet` | 1036-1037 |
| `a bet larger than the player's stack is refused` (226) | short stack (650) `RAISE 800` and `200000` → `invalid_bet` (not on *their* ladder); chips unchanged | |
| `non-integer and negative amounts are refused` (253) | 100.5, −100, NaN, +∞ → `invalid_bet` | 1033-1035 |
| `a raise must be at least double the chaal` (269) | `RAISE {amount: 100}` → `invalid_bet` | 1040-1042 |
| `stepping up repeatedly stays inside the stack across a whole hand` (282) | always betting `max` (raise if >1 rung else chaal) never drives chips negative | |
| `a stack that affords only one rung can chaal but not raise` (310) | 150 left → `raiseSteps [100]`, `chaal 100`, `raise null`; `RAISE 100` → `invalid_bet`; `CHAAL 100` → chips 50 | |
| `a player who does not act on their turn is packed automatically` (337) | timeout pack event `{action:'pack', reason:'timeout'}`; play moved | 641-656 |
| `the timeout still fires while a raise stepper is open` (353) | `see` does not stop the clock; after 25000 the seer is packed and the hand ended (`hand null`) | |

### 8.12 `test/seatKeeping.test.js` — 7 tests. Config: boot 200, start 50000, turn 25000, rounds 40, mult 1024, steps 8, blind 4, `maxMissedTurns 3`. A `kick` listener calls `table.removePlayer(userId, reason)`; tests `await table.settled()` after timeouts

| Test (line) | Assertions | Rule source |
|---|---|---|
| `three missed turns in a row loses the seat` (444) | 3 players; the idler never acts across hands; exactly one `kick` `{userId: idler, reason:'idle', message: /missed turns/i}`; seat freed | 647-655 |
| `a player is told their own missed-turn count, and nobody else is` (483) | `you.missedTurns 0`, `you.maxMissedTurns 3`; after a timeout `1`; `JSON.stringify(serializeFor(other).seats)` lacks `missedTurns` | 1706-1707 |
| `playing a turn clears the missed-turn count` (509) | one miss → 1; a successful chaal later → 0; no kicks | 968 |
| `a player who cannot cover the boot is shown out between hands` (536) | carol with 199 → one kick `{userId:'carol', reason:'insufficient_chips', message: /enough coins/i}`; seat freed | 681-696 |
| `a player is never shown out mid-hand for being all in` (554) | bob with exactly 200 → after boot `chips 0`, no kicks, hand live | 682 |
| `the sweep runs again once the hand is over` (567) | bob (200) packs each turn and loses; after the hand + next-hand delay a kick `insufficient_chips` for bob | 1522 → 308-318 |
| `a table that empties out does not throw` (587) | both players at 199 → both kicked, `playerCount 0`, no rejection | |

### 8.13 `test/settlement.test.js` — 7 tests. Config: boot 100, start 200000, rounds 20, mult 1024 (no `maxRaiseSteps` → 8). `settle` applies deltas to a `bank` Map seeded with each seat's starting chips

`assertConserved(record)`: Σ`entries.delta === 0`; Σ`hand.summary.contributed === hand.pot`; exactly one `isWinner`;
`winner.delta === hand.pot - winner.contributed` (no persistence in this suite, so deltas are net).

| Test (line) | Route to the end of the hand |
|---|---|
| `chips are conserved when everyone else packs` (91) | 3 players: chaal, pack, pack |
| `chips are conserved through a show` (103) | see, raise, show (trail vs nothing) |
| `chips are conserved through a forced showdown` (117) | `maxBetRounds 4`, 3 players chaal until `hand null` |
| `chips are conserved when a player leaves mid-hand` (128) | chaal, `removePlayer(quitter,'left')`, pack; quitter entry has `delta < 0` |
| `chips are conserved when every player times out but one` (146) | two 25 s timeouts → `hand null` |
| `the total in play is unchanged across many hands` (158) | 4 players, 25 hands of mixed show/pack/chaal (show whenever `options.show`, pack every 4th move); bank total unchanged; `handNo > 5` |
| `a settled balance of zero is not treated as a failed settlement` (187) | `settle` returns `0` for everyone → every seat `chips === 0` (presence check, not truthiness — `table.js:1490`) |

### 8.14 `test/sideshow.test.js` — 16 tests. Config: boot 100, start 100000, turn 25000, rounds 20, mult 1024, steps 8, blind 4, next 6000, `sideshowTimeoutMs 6000`, `sideshowMinPlayers 3`; `makeTable({count})` seats `p0..p{n-1}`, `startHand()`, everybody `see`s. `rightOf(userId)` uses `table._rightActiveSeat(seatIndex)` (walks **downward**)

| Test (line) | Assertions | Rule source |
|---|---|---|
| `the sideshow button is offered to the player on turn and nobody else` (299) | actor `turnOptions.canSideshow true`, `sideshowWith === rightOf(actor).displayName`; others `canSideshow false`, `sideshowBlockedReason 'not_your_turn'` | 806-831, 558-578 |
| `a sideshow needs three players in the hand` (314) | 2 players: reason `'too_few_players'`, `canSideshow false`, `act` rejects `{code:'too_few_players'}` | 567 |
| `both hands must have been seen` (323) | right seat `isBlind=true` → `'neighbour_is_blind'`; actor blind → `'you_are_blind'` (checked first) | 571-575 |
| `the request goes to the player on the right, who acted immediately before` (337) | 4 players, one chaal first; `sideshowRequested {fromUserId: actor, toUserId: previous}` with **no `cards` key**; `serializeFor(actor).sideshow.toUserId === previous` | 1185-1194, 1673-1681 |
| `only the player who was asked can answer` (358) | bystander and asker → `not_your_sideshow`; asked declines ok; declining again → `no_sideshow` | 1201-1210 |
| `a declined sideshow packs nobody and hands the turn straight back` (374) | `sideshowResolved {accepted:false, reason:'declined', packedUserId:null}`; no `sideshowReveal`; asked still active; `turnSeat === actor.seatIndex`; actor `chaal > 0` | 1268-1281 |
| `an unanswered request is rejected after six seconds` (394) | after 5999 ms still pending; at 6000 `hand.sideshow null`, resolved `reason 'timeout'`, turn back with actor | 1178-1181 |
| `the turn clock stops while a request stands and restarts full afterwards` (410) | 20 s into the turn, ask; 5999 ms later actor still active/on turn; decline → a **fresh 25 s** clock (still on turn at +24999, packed at +25000) | 1169, 1280 |
| `the weaker hand packs and only the two of them see the cards` (435) | trail vs nothing: `sideshowReveal {userIds:[actor,asked], reveal:{hands:[[As,Ah,Ad],[2s,7h,9d]] in asker-first order, packedUserId: asked}}`; `sideshowResolved {accepted:true, packedUserId: asked}` whose JSON lacks `'As'`; asked `packed`, actor `active` | 1236-1266 |
| `losing your own sideshow packs you and passes the turn on` (464) | 4 players; actor weaker → actor packed, asked active, turn moved to an active seat | 1265 (`advanceTurn: loser === asker`) |
| `a tie goes against the player who asked` (481) | `Ks Kh 4d` vs `Kd Kc 4s` → actor packed | 1240 (`compare(a,b) > 0 ? asked : asker`) |
| `when the sideshow leaves two players the hand carries on rather than ending` (497) | 3 → 2 active; hand live; on-turn `turnOptions.show > 0` | |
| `one sideshow per turn, and the next turn brings a fresh one` (516) | after a decline: `turnSeat` unchanged, reason `'already_asked'`, `act` rejects `already_asked`; after chaal and a full rotation back: reason `null`, `canSideshow true` | 565, 605, 1280 (`freshTurn:false`) |
| `a second request cannot be opened while one is standing` (539) | `sideshow_pending` | 562 |
| `a player leaving cancels the sideshow they were part of` (549) | `removePlayer(asked,'left')` → `hand.sideshow null`, resolved `reason 'left'`, no reveal, turn with actor, actor `chaal > 0` | 237-241 |
| `a pending request does not outlive its hand` (566) | everyone else leaves → `hand null`; advancing 12 s does not throw, no reveal | 1399-1401 |

---

## 9. Tools as clients (must work unchanged against the Go server)

All tools use `socket.io-client` 4.x with `{ auth: { token }, transports: ['websocket'], forceNew: true }` (websocket-only;
no polling fallback, no `?token=` query) and log in as **guests** over `POST /api/auth/login`. All read `GET /health` first
and exit 1 unless `body.ok` is truthy. Argument parsing (all three): every `--key value` pair from `process.argv.slice(2)`
into an object; missing values fall to defaults; numbers via `Number.parseInt(…,10)` / `Number(…)`.

### 9.1 `tools/bot.js` — practice bots (211 lines)

| Flag | Default | Meaning |
|---|---|---|
| `--count` | 2 | bots to start (sequentially, 400 ms apart) |
| `--boot` | 200 | `bootAmount` sent on `room:quickJoin` |
| `--category` | `seen` (anything but `blind` → `seen`) | category sent |
| `--url` | `http://localhost:3000` | base URL |
| `--offset` | 0 | identity slot shift: `slot = (index + offset) % 16` |
| `--churn` | 0 (off) | seconds between table hops |

Identities (fixed order): `Ravi, Meera, Arjun, Kavya, Vikram, Anita, Rohit, Neha, Priya, Aman, Sneha, Karan, Pooja, Rahul, Isha, Dev`.
Login body: `{provider:'guest', deviceId: 'practice-bot-<slot>-<Name>', displayName: <Name>}` (**stable device ids**, so
bots keep their chips across runs and accounts persist in the DB); `response.ok` required.

Behaviour per bot:

- `connect` → `joinTable()`: `room:quickJoin {bootAmount, category}` with ack. `ack.ok` → log `"<name> joined table <code> (chips N)"`
  (uses `user.chips` from login). Retries every 5000 ms up to 12 times when `ack.code ∈ {already_in_room, table_full}`
  (covers restarting inside the reconnect grace, when the server still holds the old seat). Any other refusal → log and stop.
- `--churn N`: every `N*1000*(0.6+rand*0.8)` ms → `room:leave {}` (with ack) then after `1200+rand*2500` ms `joinTable()` again.
- `game:yourTurn {options}` → after `700+rand*1600` ms emit `game:action {action: decide(options)}` (**no `actionId`, no ack**).
  `decide`: `canSee` → `see`; `show && rand<0.5` → `show`; `canSideshow && rand<0.45` → `sideshow`; roll `<0.12` → `pack`;
  `<0.25 && raise` → `raise`; `chaal` → `chaal`; `raise` → `raise`; else `pack`. Bare `raise` (no amount) = server default double.
- `game:sideshowRequested {toUserId}` — only when `toUserId === user.id`: roll `>0.9` → never answer (lets the 6 s timeout
  fire); else after `600+rand*1500` ms `game:sideshowRespond {accept: roll < 0.75}`.
- `game:handEnded {winnerName, pot}` → 25 % chance of `chat:message {text}` from `['good luck all','nice hand','wow','all yours','lets go','that was close']`
  after `800+rand*1200` ms; bot 0 logs `"  hand won by <winnerName ?? '—'> for <pot.toLocaleString()>"` — **relies on `winnerName` and numeric `pot`**.
- `disconnect` → log. SIGINT/SIGTERM → `socket.close()` all, exit 0.

Server expectations exercised: guest login idempotence, `room:quickJoin` ack fields `ok/code/message`, `game:yourTurn.options`
field names `canSee, show, canSideshow, raise, chaal`, `game:sideshowRequested.toUserId`, `game:handEnded.winnerName/pot`,
reconnect seat-hold (restarted bots land back on their old table via `room:joined` on connect — then their `quickJoin` gets
`already_in_room` and the retry loop rides it out).

### 9.2 `tools/ramptest.mjs` — staged capacity test (246 lines)

| Flag | Default |
|---|---|
| `--url` | `http://localhost:3000` |
| `--stages` | `10,25,50,100,200,300,400,500` (cumulative player targets) |
| `--hold` | 40 s per stage |
| `--boot` / `--category` | 200 / `blind` |
| `--batch` / `--rampDelay` | 25 players per batch / 150 ms between batches |
| `--out` | `ramp-report.json` |
| `--maxP95` / `--maxErrors` | 3000 ms / 0.10 |
| `--idOffset` | 0 (second generator uses a disjoint id range) |

Identities: `deviceId 'ramp-bot-<i+idOffset>-device-id'`, `displayName 'LoadBot<i+idOffset>'` (fixed → re-runs reuse accounts).
Socket options add `reconnection: false`. Per bot: on `connect` → `room:quickJoin {bootAmount, category}` (records `ack.ok`, `ack.code`);
`connect_error` → records `e.message`; `disconnect` counted; `game:handStarted {handId}` / `game:handEnded {handId}` de-duplicated
by `handId` (every seat receives the same event); `room:kicked` → count and immediately `room:quickJoin` again;
`game:yourTurn {options}` → after `120+rand*400` ms `game:action {action, actionId: '<i>-<Date.now()>'}` **with ack**, latency =
ack round-trip, `ack.ok === false` counted as an action error; every 5000 ms 15 % chance of `chat:message {text:'nice hand'}`.
`chooseAction`: `canSee && rand<0.6` → see; `show && rand<0.45` → show; roll `<0.15` pack; `<0.30 && raise` raise; chaal; raise; pack.

Flow: `/health` before (`h0`, must be `ok`); per stage `addPlayers(target)` in batches (login + createBot), aborting when ≥50
newly added and >5 % failed to connect, or `/health` missed twice; sleep 2500; measurement window `HOLD_S` polling `/health` every
5 s (two consecutive `!ok` → stop); then a result row with login/connect/action percentiles (p50/p95/p99/max/mean), moves/s,
hands started/completed (per s, per min), chat sent, `/health` RTT percentiles, `server: {players, tables, activeHands, uptime}`
from the last health, `host` block when `h.process` exists (`rssMbMax, heapUsedMbMax, cpuPercentMean/Max, loopLagP99MsMax,
loopLagMaxMs, socketsMax, dbWaitingMax, dbTotalMax`), and the generator's own event-loop lag. Stop rules: `p95 > maxP95`,
error rate `> maxErrors`, `connected < 0.9*target`, health not ok. `finish()` writes the JSON report, `room:leave`s every bot,
closes sockets, exits 0. **Depends on**: `/health` fields above (a Go server lacking `process.*` simply gets `host: null`);
`actionId` acceptance (≤64 chars — `'<i>-<13 digits>'` fits); `room:kicked` event.

### 9.3 `test/loadtest.js` — flat load test (221 lines)

Flags `--players` (600), `--seconds` (45), `--url`, `--boot` (**100** — refused by the default menu), `--batch` (25), `--rampDelay` (120).
Identity `deviceId 'loadtest-device-<i>-<pid>'`, `displayName 'Bot<i>'` (**new accounts every run** — each run inserts N users and N
`welcome_bonus` ledger rows). Same `chooseAction` as ramptest; `game:action {action}` **without actionId**, with ack for latency;
`room:quickJoin {bootAmount}` (no category → seen); dedupes hands by `handId`; chat trickle 15 %/5 s; prints a summary and exits.

### 9.4 `kicktest.mjs` (tracked scratch, 55 lines) — requires `localhost:3000` **and** direct DB access to the server's schema

Imports `openDatabase/query/closeDatabase` from `./src/db/index.js` (so it honours `DATABASE_URL`/`PG_SCHEMA` env). Two guests:
`kick-idler-device`/`Idler` set to 50,000 chips; `kick-shorty-device`/`Shorty` set to 260. Wallet fixture SQL:
`SELECT chips FROM users WHERE id = $1`; `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3`;
`INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at) VALUES ($1, NULL, NULL, $2, $3, 'test_fixture', $4)`
with `delta = target - current`, `balance = target` — keeps `SUM(delta) == chips`. Logs in a second time, then both
`room:quickJoin {bootAmount:200, category:'blind'}`; Idler never acts (expects `room:kicked {reason:'idle'}` after 3 timeouts);
Shorty packs 400 ms after each `game:yourTurn` (expects `room:kicked {reason:'insufficient_chips'}` once below 200). Exits after 150 s.

### 9.5 `peek-tmp.mjs` (untracked scratch, 14 lines)

Guest `peek-observer`/`Peek`, `lobby:list {}` → prints `code category boot players state` per `ack.tables[]`
(fields `code, category, bootAmount, players, state` of `table.summary()`); exits.

---

## 10. Every SQL statement the tests and tools run directly (schema = the suite's `PG_SCHEMA`; `$n` are pg positional params)

| Where | Statement | Purpose / expectation |
|---|---|---|
| integration #4 | `SELECT provider_user_id FROM users WHERE provider = $1` (`'guest'`) | all 64-hex |
| invalidMoves | `SELECT COALESCE(SUM(delta), 0) AS total FROM chip_ledger WHERE user_id = $1` | number equal to `users.chips` |
| invalidMoves | `SELECT chips FROM users WHERE id = $1` | wallet reads |
| invalidMoves #8 | `SELECT COUNT(*) AS n FROM chip_ledger WHERE action_id = $1` (`'dup-same-id'`) | `n === 1` |
| invalidMoves #16 | `SELECT id, chips FROM users` | reconciliation loop |
| invalidMoves #11 (via `applyChipDelta`, `db/users.js:155-173`) | `SELECT chips FROM users WHERE id = $1 FOR UPDATE`; `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3`; `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7)` with reason `'test_fixture'`, action_id `'poor-fixture'` | fixture that keeps the invariant |
| statsAndRewards | `UPDATE users SET hands_played = $1 WHERE id = $2` | fast-forward the counter |
| statsAndRewards #7 | `SELECT * FROM chip_ledger WHERE user_id = $1 AND reason = 'milestone_reward'` | one row, `delta 25000` |
| statsAndRewards #11 | `SELECT next_bonus_at FROM users WHERE id = $1`; `UPDATE users SET next_bonus_at = $1 WHERE id = $2` | persisted countdown |
| kicktest.mjs | see §9.4 | wallet fixture |
| all DB suites (teardown) | `DROP SCHEMA IF EXISTS "<schema>" CASCADE` (`db/index.js:453`) | |
| all DB suites (setup, via `openDatabase`) | `CREATE SCHEMA IF NOT EXISTS "<schema>"`; `SET search_path TO "<schema>", public`; the whole of `src/db/schema.sql` | idempotent DDL |

Rows the tests **expect the server to have written** (via `db/ledger.js` and `db/users.js`; MUST MATCH for the invariant and the
uniqueness checks): `chip_ledger` rows with `reason ∈ welcome_bonus (action_id NULL) | boot (action_id "<handId>:boot:<userId>") |
bet | show (action_id = client actionId or a fresh uuid) | hand_win | hand_loss (action_id "<handId>:settle:<userId>") |
milestone_reward ("<userId>:milestone:<n>") | timed_bonus (NULL)`; `delta` negative for boot/bet/show, `balance` = wallet after;
`pots` row per hand (`hand_id, room_id, boot_amount, amount, opened_at`, later `closed_at, winner_id`); `hands` row on settle;
`game_states` upsert with strictly rising `version`. The invariant `SUM(chip_ledger.delta) GROUP BY user_id == users.chips`
must hold after any sequence of the above (invalidMoves #16; CLAUDE.md §4 psql check).

Type parsing that the assertions silently rely on: `chips`, `total`, `n`, `next_bonus_at`, `delta` come back as **JS numbers**
(`pg.types.setTypeParser(20|1700)`, `db/index.js:359-362`). A harness written in another language must compare numerically.

---

## 11. Recommended parity harness (behavioural plan; no Go design implied)

Goal: run the black-box scenarios of §6 (and the socket-observable halves of §7–§8) against **either** server — Node started
from `node src/index.js` or the Go binary — from a base URL, with a throwaway Postgres schema, and diff what each emits.

### 11.1 Starting a server under test

1. Pick a free port `P` and a schema `test_parity_<rand>` (regex `^[A-Za-z_][A-Za-z0-9_]*$`).
2. Environment (the union the process suites use; §2): `NODE_ENV=test`, `PORT=P`, `HOST=127.0.0.1`, `PG_SCHEMA=<schema>`,
   `DATABASE_URL=postgres://postgres:postgres@localhost:5432/gameplay`, `JWT_SECRET=parity-secret`,
   `AUTH_ALLOW_FAKE_PROVIDERS=true`, `WELCOME_CHIPS=200000`, `BOOT_AMOUNT=100`, `TURN_TIMEOUT_MS=1200`,
   `NEXT_HAND_DELAY_MS=150`, `RECONNECT_GRACE_MS=400`, `TABLE_STAKES=`, `LOBBY_TABLES=`, `METRICS_TOKEN=metrics-test-token`.
   For invalidMoves scenarios use its own values (`TURN_TIMEOUT_MS=60000`, `SIDESHOW_TIMEOUT_MS=60000`); for socketProtocol
   `TURN_TIMEOUT_MS=3000`; for metrics `TURN_TIMEOUT_MS=4000`. Because config is read once at start, **one server process per
   env profile** (4 profiles) — or accept the strictest common set where a test does not depend on the difference.
   The stakes/lobbyRules scenarios need the **default** menu (unset `TABLE_STAKES`/`LOBBY_TABLES`) → a fifth profile.
3. Readiness: poll `GET /health` until `{"ok":true}`. Node prints `king-teenpatti server listening` (INCIDENTAL).
4. Teardown: SIGTERM (Node settles live hands via `rooms.shutdown()` then exits 0 within 8 s — `src/index.js:154-166`), then
   `DROP SCHEMA "<schema>" CASCADE` from the harness's own pg connection.

### 11.2 Making the existing Node suites run against a URL

The four process suites already do everything through `baseUrl`, `fetch`, `socket.io-client`/`ws`, and `query()`. To point them at an
external server: replace `test.before` with `baseUrl = process.env.PARITY_BASE_URL` and skip `createServer()`; keep `openDatabase()`
(from `src/db/index.js`) for `query()` with `PG_SCHEMA` set to the server's schema; drop `rooms.shutdown()`/`io.close()` from
`test.after`; replace each PEEK per the bracketed substitutes in §6.1/§6.3/§6.4. The 6 parser tests and the 8 live protocol tests
need no change beyond `baseUrl`. `stakes.test.js` and `lobbyRules.test.js` become socket scenarios (§7.1 table's last column;
§8.9 via `room:quickJoin`/`room:joinCode`/`room:switch`/`POST /api/profile/name`). `statsAndRewards` becomes REST + SQL (§7.2).

Scenario list to keep as the parity gate (all MUST MATCH):

- **Auth/REST**: §6.1 #1–#9, #36; name endpoint mappings (§8.9 footer); rewards endpoints (§7.2).
- **Protocol**: §6.2 #7–#14 (raw frames incl. `0{…}` OPEN, `40{"token"}` CONNECT, `44{"message":…}` error, `42[...]`, `43<id>[...]`, ping/pong).
- **Lobby & seating**: §6.1 #11, #15–#17, #19–#24; §6.3 #10–#12; §7.1 all; entry-cap and switch rules from §8.9.
- **Gameplay**: §6.1 #12–#14; §6.3 #1–#9, #14–#16; blind-move cap, ladder, sideshow and pot-cap behaviours from §8.3, §8.10,
  §8.11, §8.14 replayed over the socket (they are visible via `game:yourTurn.options`, `game:action`, `game:sideshow*`, `room:state`).
- **Chat**: §6.1 #25–#31 (with #27 either slow or dropped); §6.3 #13.
- **Resume**: §6.1 #32–#35.
- **Metrics**: §6.4 #1, #3–#9 verbatim; #2 with a Go-appropriate default list but the same namespace/label rules.
- **Books**: §6.3 #16 after every run; plus `pots.amount == SUM(chip_ledger.delta WHERE hand_id AND reason IN ('boot','bet','show')) * -1`
  and `game_states.version` monotonic — the CLAUDE.md §12.1 check.

### 11.3 Comparing emitted payloads between Node and Go

Record, per client socket, the ordered list of `(event, payload)` plus each `(request, ack)`; record HTTP `(status, body)`.
Drive both servers with the **same deterministic script** (same device ids, names, boots, action sequence). Then normalise and
diff:

- **Replace** opaque values with stable placeholders before diffing: uuids (`user.id`, `roomId`, `handId`, chat `id`, `messageId`,
  `token`), room `code` (6 chars of `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`), epoch-ms fields (`at, createdAt, lastLoginAt, deadline,
  startsAt, expiresAt, nextHandAt, opened_at…`), `sid`. Map each first-seen uuid to `<uuid-N>` so *identity relationships* still
  diff (same id in `winnerId` and `participants[0]`).
- **Cards are random** (`crypto.randomInt` shuffle): mask `cards` arrays and `handName`/`category`/`won`/`winnerId` in
  `game:showdown`/`game:handEnded`/`player:cards`/`sideshowReveal` unless the harness forces a deterministic deck; compare
  *shape* (3 codes matching `/^[2-9TJQKA][shdc]$/`) and *invariants* (exactly one `won`, `pot` = Σ contributed). Who is on turn
  first is deterministic given seat order (`dealer = _nextOccupiedSeat(-1)` = seat 0; first turn = next active clockwise = seat 1
  in a 2-player table; `table.js:374, 482`), so action scripts can be written against seat indices.
- **Order-sensitive**: keep event order within one socket (the sequences in §5.3 "Observed ordering"); across sockets only
  compare per-socket streams. `room:state` may legitimately be emitted several times in a row with identical content
  (e.g. captured: three identical `starting` snapshots after the second player sat down); compare the **set of distinct
  snapshots in order** (collapse consecutive duplicates) to avoid false diffs, but do flag a missing snapshot at a state boundary
  (`waiting → starting → betting → waiting`).
- **JSON key order**: the Unity-style parser (§4.2) reads the *first* occurrence of a key; keep top-level key order for
  `session:ready` (`user` before `config`), `room:state` (`you` before `seats`), and `chat:message` (`id, userId, displayName, text, at[, system], roomId`).
  A strict diff on serialised text after placeholder substitution catches key-order and null-vs-absent regressions
  (`resume` absent vs `null`, `system` absent vs `false`, `chips` `null` vs `0`).
- **Numbers**: compare `chips`, `pot`, `stake`, `amount`, `delta` as integers; `uptime` and `process.*` as floats within tolerance
  or masked.
- **Timing fields**: assert relationships instead of values — `deadline − now ∈ [timeoutMs − 100, timeoutMs]`, `startsAt − now ≤ NEXT_HAND_DELAY_MS`,
  `expiresAt − now ≤ SIDESHOW_TIMEOUT_MS`, `nextHandAt − now ≈ NEXT_HAND_DELAY_MS`.
- **DB**: after each scenario dump `users (chips, hands_*, total_winnings, biggest_pot, milestone_claimed, next_bonus_at)`,
  `chip_ledger (reason, delta, balance, action_id pattern)`, `pots`, `hands (pot, winner_id, win_reason, summary_json)`,
  `game_states.version` for both servers, normalise ids/timestamps, and diff.
- **Tools**: run `tools/bot.js --count 3 --boot 200 --category blind --churn 20 --url <go>` and `tools/ramptest.mjs --stages 10,25 --hold 20 --url <go>`
  as smoke: zero `could not join`, hands completing (`hands.completed > 0`), report `errors 0`.

---

## 12. Traps for the port

1. **Config snapshot semantics.** Tests set env *before* import; nothing is re-read. A Go server must read all env at start
   (including `TABLE_STAKES=''` → *any* stake, `LOBBY_TABLES=''` → *any* pair — empty string means "unrestricted", not "none";
   `config/index.js:187-191, 240-260`). `num()` uses `parseInt` with fallback on non-numeric; `bool()` accepts `1/true/yes/on`.
2. **`null` vs absent vs 0.** `seats[].chips` is `null` (not 0, not absent) for hidden stacks; `resume` is *absent* when there is no
   offer; user chat messages have *no* `system` key while system lines have `system:true` and `userId:null`; `you` is `null` for
   spectators; `turn`/`sideshow`/`startsAt` are `null`; `options.chaal/raise/maxBet/show` are `null`; `handEnded.summary[].cards`
   is `null` for unrevealed players; `winnerId` may be `null` (all-left with no `lastDeparture`).
3. **`amount` must be a JSON number and a safe integer** — `"100"`, `[100]`, `true`, `1.5`, `"1e3"` are `invalid_bet`; `null`/absent
   means "default for the kind". `bootAmount: null` on `room:quickJoin` means default boot (accepted), `"lots"`/`-5`/`200.5` →
   `invalid_stake`. `code: {$gt:''}` → `String(...)` → `room_not_found`. Non-object payloads (`42`, `'string'`, `[]`, `null`,
   `undefined`) must be handled as `{}`-like and **always acked** — a hung ack fails invalidMoves #14 (1.5 s).
4. **Two refusal channels.** Every guarded failure produces *both* an ack `{ok:false, code, message}` and a `game:error {code, message}`;
   a rate-limit trip acks `{ok:false, code:'rate_limited', message:'Slow down'}` **and** emits `game:error`. The general limiter is
   30 requests / 5 s fixed window per socket; chat has its own 5 / 5 s, counted on **every** `chat:message` request including
   blank ones (invalidMoves #13 sends exactly 5), and both windows reset only when `now − windowStart ≥ window`.
5. **`see` is exempt from the turn check and never moves the turn**, but when the seer *is* on turn the server re-emits `game:turn`
   (same deadline, `timeoutMs` = remaining) and a fresh `game:yourTurn` with the seen ladder. Off-turn see: no `game:turn`.
   Second `see` → `already_seen`. The 4th blind bet is charged at the blind rate and *then* auto-reveals (`action` `see` with `auto:true`,
   ack `autoSeen:true`); `blindMovesLeft` in `you` counts down from `maxBlindMoves`.
6. **Stake is stored in blind units**: after a seen bet `stake = floor(amount/2)`. `showCost = betOptions(seat).chaal` (blind: stake;
   seen: 2×stake). A show with `chaal === null` → `insufficient_chips`, never free.
7. **Ladder maths** (`betOptions`): `base = isBlind ? stake : 2*stake`; first rung `min(base, perBetCeiling)`; rungs double while
   `≤ min(perBetCeiling, chips)`, `≤ maxPot − pot` (∞ when `maxPot` 0), count `< maxRaiseSteps` (∞ when 0). `raise` with an amount
   must be a rung **and** `≥ 2*steps[0]`; a 1-rung ladder allows `chaal 100` but refuses `raise 100`.
8. **Idempotency keys**: `actionId` from the client (string, 1–64 chars; anything else → server uuid → no protection) becomes
   `chip_ledger.action_id` (UNIQUE) → second insert fails → `duplicate_action`; boots use `<handId>:boot:<userId>`, settlement
   `<handId>:settle:<userId>`, milestone `<userId>:milestone:<n>`. The **same** id must yield exactly one ledger row even when the
   move is refused earlier for `not_your_turn`.
9. **Money is DB-first except settlement**: a bet mutates memory only after COMMIT; a failed write → `persist_failed` and *nothing*
   changes (no events). `_endHand` mutates memory first and retries the idempotent settle in the background (10 attempts, delay
   `min(30000, nextHandDelayMs*attempt)`). Wallet rows are locked in **ascending `userId` order** in `collectBoot`/`settle`.
   `settle` clamps balances at `Math.max(0, chips + delta)` and writes a `hand_win`/`hand_loss` row **even for delta 0**.
   `_endHand` uses `hasOwnProperty(balances, winnerId)` — a returned balance of exactly `0` is valid and must not trigger the
   in-memory `+pot` fallback (settlement #7).
10. **Turn/round bookkeeping**: rounds increment when the turn *steps over* `startSeat` by distance, not equality; forced showdown at
    `round >= maxBetRounds` (0 = never); pot-cap showdown when `pot + stake > maxPot` checked in `_advanceTurn` **before** the round
    logic; ties in a showdown go to the non-show-payer, then nearest the dealer's left (`preference` list); the sideshow tie goes
    against the asker (`compare(a,b) > 0 ? asked : asker`). When the *asked* player loses a sideshow the turn does **not** advance;
    when the asker loses it does. The sideshow re-arms the asker's clock with `freshTurn:false` so `already_asked` persists for that turn.
11. **Timers and the serial queue**: every mutation is queued; a stale turn timeout is detected by `turnToken` and ignored; the turn
    clock is *stopped* while a sideshow is pending and restarted **full** afterwards; `see` never touches the clock; kicks are
    emitted synchronously mid-operation but the removal is queued behind the current mutation (tests `await table.settled()`).
    `_sweepUnfunded` runs only when `!this.hand` and marks `kickPending` to avoid double kicks; a player with exactly `bootAmount`
    is dealt in and sits at 0 chips mid-hand without being kicked.
12. **Leaving mid-hand = pack with `reason: <leave reason>`** (`left`, `disconnected`, `moved`, `idle`, `insufficient_chips`) broadcast
    as `game:action`; `lastDeparture` receives the pot if everyone leaves (`all_left`); `destroy()` mid-hand pays the first still-active
    seat or `lastDeparture`. `leave` with reason `'moved'` skips consolidation; any other reason triggers an immediate
    `consolidateTables()` (lone players on idle public tables of the same `category:boot` merge onto the **oldest** table; the moved
    player gets `room:moved` + `room:joined` + `chat:history`).
13. **Order of join-side effects** (observed): `room:state` (setConnected), `room:joined`, `chat:history`, `room:state`, ack. Others:
    system `chat:message` then `room:state`. Deal: `game:handStarted`, `player:hand` (to every viewer), `game:turn` (room),
    `game:yourTurn` (player), `room:state`. Room-wide `room:state` is **per viewer** (`serializeFor(viewer)`), never one payload.
14. **Names**: login names bypass `NAME_PATTERN` (control chars stripped, trimmed, sliced to 24, need ≥2 chars, else
    `Guest<5 HEX>`); quotes/braces/`<b>` are legal at login. `POST /api/profile/name` applies `NAME_PATTERN =
    /^[\p{L}\p{N}][\p{L}\p{N}\p{M} ]*$/u` after `trim().replace(/\s+/g,' ')`, length checked **before** pattern; Indic vowel signs
    (`\p{M}`) must pass. Every login **overwrites `display_name`** with the provider's name (`db/users.js:98-113`).
15. **Guest identity** = `sha256("teenpatti:" + trim(deviceId))` lowercase hex; device id min 8 chars after trim. Fake providers
    key on `String(providerUserId ?? displayName ?? 'fake')`.
16. **Chat sanitising**: `\p{C}` → space, `\s+` → single space, trim, slice to 140 (server) — a 5000-char message is *kept and cut*,
    a bare number `12345` is posted as `'12345'`, blank → nothing posted with ack `{ok:true}` (no `messageId`). History cap 100 keeps
    the newest; system lines count toward the cap. `chat:history` on join is oldest-first and includes the joiner's own
    "X joined the table" line.
17. **Socket lifecycle**: one live socket per user — the older gets `session:replaced {message}` then a server-side disconnect;
    disconnect holds the seat `RECONNECT_GRACE_MS`, then `resumeOffers` + `leave('disconnected')`; on connect while still seated →
    `room:joined` + `chat:history` unrequested; else a one-shot `session:ready.resume {roomId, code, category, bootAmount}` valid
    for `RESUME_OFFER_MS` and only if the table exists and is not full. `room:switch` must untrack the old room *before* leaving so
    the socket never sees `room:closed` for the room it is leaving.
18. **Metrics label discipline**: unknown values fold to `other`; `event` labels are wire names; `code` labels snake_case; HTTP `route`
    is the pattern (`/api/auth/me/hands`), `static`, or `unmatched`; `/metrics` scrapes are not counted; default label
    `service="king-teenpatti"`; everything under `game_`/`game_server_`. Token guard returns **401** (`unauthorized`), IP guard 403.
19. **Postgres types**: BIGINT/NUMERIC come back as strings from the driver unless parsed; every test compares numerically.
    Timestamps are epoch-ms BIGINT; `summary_json`/`state` are JSONB written via `$n::jsonb` of `JSON.stringify`.
20. **Room codes**: 6 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no 0/O/1/I), matched case-insensitively on join
    (`toUpperCase`), no collision check. Table ids and hand ids are UUID v4; the first dealer is seat 0 (`_nextOccupiedSeat(-1)`),
    first turn seat 1; dealer rotates to the next *participating* seat each hand.
21. **Private tables**: `room:create` ignores `bootAmount` (fixed `PRIVATE_BOOT` 200), caps `maxPot` 500000 and rungs 2 whichever
    category; a private table is exempt from the entry cap on `joinByCode`, invisible to `lobby:list`/quick-join/consolidation, and
    cannot be switched from (`private_table`). `room:create` builds the table **before** checking `already_in_room`, leaving an empty
    table until the 30 s sweep — visible in `/health.tables`.
22. **Test-fixture wallet edits must leave a ledger row** (`reason 'test_fixture'`) or the reconciliation check fails; never a bare
    `UPDATE users SET chips`.
