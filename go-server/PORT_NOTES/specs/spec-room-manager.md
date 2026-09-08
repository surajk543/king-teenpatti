# Spec: RoomManager (lobby, joining, switching, consolidation)

Behavioural specification of `server/src/game/roomManager.js` **as the Node working tree implements it on 2026-09-08**, plus every place the socket layer, REST layer and metrics read from it. Written so a Go engineer who never sees the JavaScript can reproduce it byte-for-byte on the wire.

All file references are relative to `/home/suraj/Project/king-teenpatti/server/`. Line ranges were taken from the working tree (branch `go-server`, identical to `master` for these files).

Legend used throughout:

- **MUST MATCH** — clients, the database, tests or operators depend on it (wire JSON, error codes, ordering, DB effects).
- **INCIDENTAL** — internal naming, log lines, metric plumbing; reproduce if convenient, but nothing external breaks if it differs.

---

## 0. Scope and what RoomManager is

RoomManager (`roomManager.js:19-513`) is a **process-local, in-memory** registry of every live `Table` plus a `userId → roomId` index. It:

1. Creates tables with the per-category rule set (§4).
2. Seats players by quick-join, code, or private-room creation (§5–§7).
3. Moves players between tables (switch §8, consolidation §11).
4. Removes players and disposes of empty tables (§9, §10, §12).
5. Runs a periodic sweeper (§13).
6. Attaches the `error` / `persistError` log listeners to each table (§4.5).

**RoomManager issues no SQL of its own.** Its only database involvement is that, by default, it builds the PostgreSQL ledger (`createLedger()` from `db/ledger.js`) and hands it to every table it creates (§1.2). Everything money-related is inside `Table` and is covered by the Table/ledger specs.

RoomManager `extends EventEmitter` (`roomManager.js:19`) and emits three events consumed by the socket layer (§15):

| Event | Payload | Where emitted |
|---|---|---|
| `tableCreated` | the `Table` instance | `roomManager.js:159` |
| `tableDestroyed` | `roomId` (string) | `roomManager.js:402` |
| `playerMoved` | `{ userId, fromRoomId, toRoomId }` | `roomManager.js:485` |

---

## 1. Constructor

`new RoomManager({ ledger, settle, persistChips, timers } = {})` — `roomManager.js:20-44`. Every option is optional; production calls `new RoomManager()` with no arguments (`src/index.js:30`).

### 1.1 State created

| Field | Type | Initial | Notes |
|---|---|---|---|
| `tables` | `Map<roomId, Table>` | empty | Insertion order = creation order. **Iteration order matters** (§5.3 tie-break, §11 group order, `listTables` order). |
| `playerRooms` | `Map<userId, roomId>` | empty | The seat index. `players` in `/health` is `playerRooms.size`. |
| `ledger` | object or `null` | see §1.2 | |
| `settle`, `persistChips` | functions or `undefined` | as passed | Test hooks, forwarded raw to every Table. |
| `timers` | `{setTimeout, clearTimeout}` or `undefined` | as passed | Forwarded to every Table (which defaults to real timers when `undefined`). **The sweeper (§13) always uses the real `setInterval`, never `timers`.** |
| `_sweeper` | interval handle | started immediately | `unref()`'d so it never keeps the process alive. |

### 1.2 Ledger injection — MUST MATCH (determines whether chips hit Postgres)

`roomManager.js:32`:

```
this.ledger = ledger ?? (settle || persistChips ? null : createLedger());
```

Truth table:

| `ledger` given | `settle` or `persistChips` given | `this.ledger` | What each Table gets (`roomManager.js:147-149`) |
|---|---|---|---|
| yes | any | the given object | `ledger: <given>` |
| no | no | `createLedger()` = `{ bet, collectBoot, settle }` from `db/ledger.js:328-330` (real Postgres) | `ledger: <pg ledger>` |
| no | yes | `null` | `ledger: undefined`, `settle`, `persistChips` → Table wraps them in `memoryLedger()` (`table.js:1803-1833`) |

`createLedger()` is called **once per RoomManager**, in the constructor, not per table. Production therefore has one shared ledger object; it is stateless (module functions) so sharing is harmless.

### 1.3 Sweeper — MUST MATCH (timing), INCIDENTAL (log text)

`roomManager.js:37-43`: every `config.game.consolidateIntervalMs` (env `CONSOLIDATE_INTERVAL_MS`, default **15000**) run, in order:

1. `await this.consolidateTables()` (§11)
2. `await this.sweepEmptyTables()` (§12)

Any rejection is caught and logged as `logger.error('table sweep failed', { error: error.message })`; the interval keeps running. The two steps are chained, so a throw in consolidation skips that tick's sweep.

---

## 2. Static helpers

### 2.1 `normalizeCategory(category)` — `roomManager.js:49-51` — MUST MATCH

```
category === 'blind' ? 'blind' : 'seen'
```

Strict equality on the exact lowercase string `'blind'`. Everything else — `'seen'`, `'BLIND'`, `'Blind'`, `undefined`, `null`, `42`, `'sneaky'` — becomes `'seen'`. (Integration test: "an unknown category is treated as seen rather than hiding chips".)

Constants (`constants.js:11-14`): `TABLE_CATEGORY.BLIND = 'blind'`, `TABLE_CATEGORY.SEEN = 'seen'`.

### 2.2 `assertStakeAllowed(bootAmount)` — `roomManager.js:60-68` — MUST MATCH

Order of checks:

1. `!Number.isInteger(bootAmount) || bootAmount <= 0` → throw `GameError('invalid_stake', 'That stake is not valid')`. Rejects `0`, negatives, `200.5`, `NaN`, strings (even `'200'`), `null`, `undefined`, booleans, arrays.
2. `allowed = config.game.tableStakes`; if `allowed.length > 0 && !allowed.includes(bootAmount)` → throw `GameError('invalid_stake', 'Stake must be one of: ' + allowed.join(', '))`. With the default menu the message is exactly `Stake must be one of: 200, 5000`.

An empty `tableStakes` (env `TABLE_STAKES=''`) disables step 2 only; step 1 still applies.

`config.game.tableStakes` (`config/index.js:71-73`): env `TABLE_STAKES` default `'200,5000'`, split on `,`, trimmed, empty entries dropped, `parseInt(…,10)`, kept only if `Number.isInteger(n) && n > 0`. Order preserved. Default value `[200, 5000]`.

### 2.3 `assertTableOffered(bootAmount, category)` — `roomManager.js:78-89` — MUST MATCH

1. `offered = config.game.lobbyTables`; if empty → return (menu open).
2. If no entry has `entry.bootAmount === bootAmount && entry.category === category` → throw `GameError('table_not_offered', 'The lobby offers: ' + menu)` where `menu = offered.map(e => `${e.category} ${e.bootAmount}`).join(', ')`. Default: `The lobby offers: seen 200, blind 200, blind 5000`.

`config.game.lobbyTables` (`config/index.js:86-91`): env `LOBBY_TABLES` default `'seen:200,blind:200,blind:5000'`; each comma entry split on the first `:` into `category` (trimmed) and `bootAmount = parseInt(boot,10)`; kept only if `category` is non-empty and `bootAmount` is an integer. **The category string is not validated** against seen/blind at config time — `foo:200` would survive into `lobbyOptions().tables` and could never be matched because `normalizeCategory` never produces `'foo'`.

### 2.4 `lobbyOptions()` — `roomManager.js:196-223` — MUST MATCH (wire JSON)

Exact object, key order as listed:

```json
{
  "categories": ["seen", "blind"],
  "stakes": <config.game.tableStakes>,
  "tables": [ { "category": <string>, "bootAmount": <int>, "maxPot": <int>, "maxBlindMoves": <int> }, ... ],
  "entryCapBoot": <int>,
  "entryCapCategory": <string>,
  "entryCapMaxChips": <int>,
  "privateBoot": <int>,
  "privateMaxPot": <int>
}
```

- `categories` is always `['seen','blind']` in that order (`TABLE_CATEGORY.SEEN` then `.BLIND`), regardless of config.
- `stakes` is the parsed `TABLE_STAKES` array (`[]` when the env var is empty).
- `tables` is `config.game.lobbyTables` mapped in menu order to `{ ...entry, maxPot, maxBlindMoves }` where `maxPot = entry.category === 'seen' ? config.game.seenMaxPot : 0` and `maxBlindMoves = config.game.maxBlindMoves`. `0` means uncapped. Note that for a non-seen category the advertised `maxPot` is `0` even though a **private** table of that category is capped — `tables` only describes public rooms.
- Default output (asserted verbatim by `stakes.test.js` "the menu is three rooms, in the order the lobby shows them"):

```json
"tables": [
  { "category": "seen",  "bootAmount": 200,  "maxPot": 1200000, "maxBlindMoves": 4 },
  { "category": "blind", "bootAmount": 200,  "maxPot": 0,       "maxBlindMoves": 4 },
  { "category": "blind", "bootAmount": 5000, "maxPot": 0,       "maxBlindMoves": 4 }
]
```

- Defaults for the scalars: `entryCapBoot 200`, `entryCapCategory 'blind'`, `entryCapMaxChips 500000`, `privateBoot 200`, `privateMaxPot 500000`.

Consumers: `session:ready.config` spreads `lobbyOptions()` into `publicGameConfig()` (`socket/index.js:727-738`), the `lobby:list` ack (`socket/index.js:482-485`), and `GET /api/rooms` (`index.js:90-101`). The Flutter `GameConfig.fromJson` reads every one of these keys (`flutter-client/lib/models/dtos.dart:200-267`) and renders `tables` verbatim.

---

## 3. Lookups and listing

### 3.1 `getTable(roomId)` — `roomManager.js:171-173`
`tables.get(roomId) ?? null`.

### 3.2 `getTableByCode(code)` — `roomManager.js:175-181` — MUST MATCH
`wanted = String(code ?? '').toUpperCase()`; linear scan of `tables.values()` for `table.code === wanted`; first match or `null`. Consequences: codes are matched case-insensitively (`'abc234'` finds `ABC234`); a non-string code is stringified (`{ $gt: '' }` → `'[OBJECT OBJECT]'` → no match → `room_not_found`, exercised by `invalidMoves.test.js:322`); `null`/`undefined` → `''` → no match. No trimming.

### 3.3 `getTableForPlayer(userId)` — `roomManager.js:183-186`
`roomId = playerRooms.get(userId)`; `roomId ? getTable(roomId) : null`. If the index points at a table that no longer exists, returns `null` (the stale entry is left in place — this cannot normally happen because `destroyTable` clears the index for every occupied seat).

### 3.4 `listTables({ includePrivate = false, category = null } = {})` — `roomManager.js:188-193` — MUST MATCH

`[...tables.values()]` in creation order → filter `includePrivate || !table.isPrivate` → filter `!category || table.category === category` → map `table.summary()`.

- `category` is compared with strict equality **without normalisation**: `'BLIND'` or `'sneaky'` yields an empty list, not "all".
- `table.isPrivate` is the raw value stored by `_createTable` (§4.4) and tested for truthiness.

`Table.summary()` (`table.js:1742-1753`) — exact JSON, key order:

```json
{
  "roomId": <string uuid>,
  "code": <string 6 chars>,
  "category": "seen" | "blind",
  "state": "waiting" | "starting" | "betting" | "showdown",
  "players": <int occupied seats incl. disconnected>,
  "maxPlayers": <int config.maxPlayers>,
  "bootAmount": <int>,
  "pot": <int hand.pot, or 0 when no hand>
}
```

Callers: `lobby:list` socket event (`socket/index.js:482-485`, passes `{ category: category ?? null }`), `GET /api/rooms` (`index.js:90-101`, passes `{ category }` where category is `'blind'|'seen'` or `null`). Neither passes `includePrivate`, so private tables never appear in a listing.

### 3.5 `stats()` — `roomManager.js:500-507` — MUST MATCH (`/health` JSON)

```json
{ "tables": <tables.size>, "players": <playerRooms.size>, "activeHands": <count of tables with hand !== null> }
```

Spread into the `/health` body (`index.js:59`): `{ ok, uptime, tables, players, activeHands, sockets, process, db }`. Integration test "health reports live table and player counts" asserts `typeof tables === 'number'` and `typeof players === 'number'`.

### 3.6 Fields read directly by the metrics module — INCIDENTAL (names) / MUST MATCH (semantics)

`metrics/index.js:139-181` reads `rooms.tables` at scrape time via `bindRooms(rooms)`:

| Gauge | Value |
|---|---|
| `game_players_online` | sum of `table.playerCount` over all tables (differs from `stats().players` only if the index and seats disagree, which they should not) |
| `game_active_games` | tables with `hand !== null` |
| `game_waiting_games` | tables with `hand === null` |
| `game_tables{category,stake}` | count per `(table.category, String(table.config.bootAmount))`, reset each scrape |

Private tables are included in all four.

---

## 4. `createTable(options)` and the per-category rule set

### 4.1 Entry point — `roomManager.js:96-98`
`createTable(options = {})` wraps `_createTable(options)` in `timedSync(gameCreationDuration, {}, …)` — observes the wall time into the `game_creation_duration_seconds` histogram (INCIDENTAL). Synchronous; returns the `Table`.

### 4.2 Arguments — `roomManager.js:100`
`{ bootAmount = config.game.bootAmount, isPrivate = false, category }`.

- `bootAmount` defaults only when `undefined`; `null` passes through as `null`. **No stake validation happens here.** `createTable({ bootAmount: 100, isPrivate: false })` yields a public table at boot 100 even with the default menu (`privateTables.test.js` "a public table still uses the stake it was created with"). Validation is the caller's job (`quickJoin` validates; the `room:create` socket handler does **not** — see §16 open question 1).
- `isPrivate` is used by truthiness (`isPrivate ? … : …`) and also **stored raw** on the table (§4.4).
- `category` goes through `normalizeCategory` (§2.1).

### 4.3 The `config` object passed to `new Table` — MUST MATCH (drives ladder, caps, serializeFor.maxPot)

`roomManager.js:100-151`:

```
id       = randomUUID()                       // util/ids.js:3
resolved = normalizeCategory(category)
boot     = isPrivate ? config.game.privateBoot : bootAmount
categoryRules = resolved === 'seen'
  ? { maxRaiseSteps: seenMaxRaiseSteps, maxBetRounds: seenMaxBetRounds, maxPot: seenMaxPot }
  : { maxRaiseSteps: blindMaxRaiseSteps, maxBetRounds: blindMaxBetRounds, potLimitMultiplier: blindPotLimitMultiplier }
privateRules  = isPrivate ? { maxPot: privateMaxPot, maxRaiseSteps: privateMaxRaiseSteps } : {}

tableConfig = { ...config.game, ...categoryRules, ...privateRules,
                bootAmount: boot, category: resolved,
                chatMaxHistory: config.chat.maxHistory, chatMaxLength: config.chat.maxLength }
```

Later spreads win. `config.game` itself has **no `maxPot` key**, so a public blind table ends with `maxPot` absent → `Table` sets `this.maxPot = config.maxPot ?? 0` = `0` (`table.js:78`).

Resulting values with default env (the only keys `Table` actually reads are listed; the rest of `config.game` rides along unused):

| Key | Public seen | Public blind | Private seen (default category) | Private blind | Read by Table at |
|---|---|---|---|---|---|
| `bootAmount` | as requested | as requested | **200** (`privateBoot`, request ignored) | **200** | many |
| `category` | `'seen'` | `'blind'` | `'seen'` | `'blind'` | `table.js:71` |
| `maxRaiseSteps` | 2 (`seenMaxRaiseSteps`) | 0 (`blindMaxRaiseSteps`, = unlimited) | 2 (`privateMaxRaiseSteps`) | 2 | ladder |
| `maxBetRounds` | 7 (`seenMaxBetRounds`) | 0 (`blindMaxBetRounds`, = no forced showdown) | 7 | 0 | round cap |
| `potLimitMultiplier` | 1024 (from `config.game`, untouched) | 0 (`blindPotLimitMultiplier`, = no per-bet ceiling) | 1024 | 0 | ladder |
| `maxPot` → `table.maxPot` | 1 200 000 (`seenMaxPot`) | **absent → 0** | 500 000 (`privateMaxPot`) | 500 000 | `table.js:78`, `serializeFor.maxPot`, pot-limit showdown |
| `maxPlayers` | 5 | 5 | 5 | 5 | seats array length, `isFull` |
| `minPlayers` | 2 | 2 | 2 | 2 | start gate |
| `turnTimeoutMs` | 25000 | 25000 | 25000 | 25000 | |
| `nextHandDelayMs` | 4000 | 4000 | 4000 | 4000 | |
| `maxBlindMoves` | 4 | 4 | 4 | 4 | |
| `maxMissedTurns` | 3 | 3 | 3 | 3 | |
| `sideshowTimeoutMs` / `sideshowMinPlayers` | 6000 / 3 | same | same | same | |
| `chatMaxHistory` / `chatMaxLength` | 100 / 140 | same | same | same | `RoomChat` |

Asserted by tests: `tableRules.test.js` "a blind table has no round cap, no rung cap and no per-bet ceiling" (`maxBetRounds 0`, `maxRaiseSteps 0`, `potLimitMultiplier 0`, `maxPot 0`), "a seen table forces a showdown after 7 rounds" (`maxBetRounds 7`); `privateTables.test.js` "every table but a public blind one carries a pot ceiling" (private 500000 both categories, public seen 1200000, public blind 0), "a private table always uses the fixed boot of 200 chips" (asked 50/199/200/1000/99999/undefined → 200); `stakes.test.js` "the ceiling a card advertises is the one the table is built with" (`table.maxPot === entry.maxPot`, `table.config.maxBlindMoves === entry.maxBlindMoves` for every menu row).

Other constructor arguments (`roomManager.js:135-151`): `id`, `code: roomCode()` (§4.6), `ledger: this.ledger ?? undefined`, `settle: this.settle`, `persistChips: this.persistChips`, `timers: this.timers`.

### 4.4 Post-construction — `roomManager.js:153-168`

In this order:

1. `table.isPrivate = isPrivate` — **raw value**, not coerced to boolean. Through the socket, `room:create` passes the client's `isPrivate` (default `true`) unchanged, so `"yes"` or `1` is stored as-is; every reader tests truthiness (`!table.isPrivate` in `listTables`, `quickJoin`, `switchTable`, `consolidateTables`; `if (current.isPrivate)`, `if (!table.isPrivate)`).
2. `table.on('error', …)` and `table.on('persistError', …)` listeners attached (§4.5).
3. `tables.set(id, table)`.
4. `emit('tableCreated', table)` — the socket layer's `wireTable` runs here (§15.1).
5. `logger.info('table created', { roomId, code, bootAmount: boot, category: resolved, isPrivate, maxPot: table.maxPot || null })` — INCIDENTAL; note `maxPot` logs `null` for 0.
6. return `table`.

`Table.createdAt = Date.now()` (`table.js:85`) is set inside the Table constructor, i.e. before step 3; it is the sort key for §11 and the age check for §12.

### 4.5 Table `error` / `persistError` handling — MUST MATCH (presence of the listener), INCIDENTAL (text)

- `table.on('error', (error) => logger.error('table error', { roomId: id, error: error.message }))` — `roomManager.js:154`.
- `table.on('persistError', ({ reason, error }) => logger.warn('table write refused', { roomId: id, reason, error: error?.message }))` — `roomManager.js:155-156`.

Why the presence matters: `Table._retrySettle` (`table.js:1532-1536`) emits `'error'` **only if `listenerCount('error') > 0`**, otherwise `persistError {reason:'settle_abandoned'}`. With RoomManager's listener attached the abandoned-settlement path emits `error` (logged at error level). A bare `Table` in unit tests has no listener and gets `persistError` instead. An EventEmitter `'error'` with no listener would throw — RoomManager's listener is what makes that path safe in production.

`persistError` payloads seen from Table: `{reason:'boot', error}` (`table.js:495`), `{userId, delta, reason:'bet'|'show', error}` (`table.js:856`), `{reason:'settle', handId, error}` (`table.js:1479`), `{reason:'settle_retry', handId, attempt, error}` (`table.js:1555`), `{reason:'settle_abandoned', handId, error}` (`table.js:1535`). RoomManager only logs `reason` and `error.message`; nothing is forwarded to clients.

### 4.6 Room code and room id generation — MUST MATCH (format), INCIDENTAL (RNG)

`util/ids.js`:

- `uuid()` = `crypto.randomUUID()` — RFC 4122 v4 lowercase string; used for `roomId` (and by Table for hand ids).
- `roomCode(length = 6)`: `bytes = randomBytes(6)`; each char = `ALPHABET[bytes[i] % 32]` where `ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'` (32 symbols: A–Z minus **I** and **O**, digits **2–9**; no 0/1/I/O). Uniform because 256 is a multiple of 32. Always uppercase, always 6 characters. The integration test asserts `/^[A-Z2-9]{6}$/` (looser than the real alphabet).
- **No collision check** — two live tables can in principle share a code; `getTableByCode` returns whichever was created first.

---

## 5. `quickJoin(user, { bootAmount, category })` — `roomManager.js:232-258`

Synchronous; returns the `Table` the player was seated at; throws `GameError`.

### 5.1 `user` shape
Whatever the caller passes; the socket layer passes the **fresh DB row** from `findById(user.id)` (`db/users.js:67-70` → `publicUser`, `users.js:21-…`): fields used are `id` (string), `displayName` (string), `avatarUrl` (`avatar_choice || avatar_url`, may be `null`/`undefined`), `chips` (JS number — `pg` int8 is parsed to number by `db/index.js`). Tests pass plain `{id, displayName, avatarUrl, chips}` objects.

### 5.2 Step order and error codes — MUST MATCH

Defaults: `bootAmount = config.game.bootAmount` **only when `undefined`**; `category` undefined → normalised to `'seen'`.

| # | Check | Error code | Message |
|---|---|---|---|
| 1 | `_assertNotSeated(user.id)` (§14.2) | `already_in_room` | `You are already seated at a table` |
| 2 | `assertStakeAllowed(bootAmount)` (§2.2) | `invalid_stake` | `That stake is not valid` / `Stake must be one of: 200, 5000` |
| 3 | `resolved = normalizeCategory(category)` | — | — |
| 4 | `assertTableOffered(bootAmount, resolved)` (§2.3) | `table_not_offered` | `The lobby offers: seen 200, blind 200, blind 5000` |
| 5 | `user.chips < bootAmount` | `insufficient_chips` | `Not enough chips to join this table` |
| 6 | `_assertUnderEntryCap(user, { bootAmount, category: resolved })` (§14.1) | `over_entry_cap` | `Players with more than 500,000 chips cannot join this table` |
| 7 | pick table (§5.3) or create | — | — |
| 8 | `join(table, user)` (§7) | `already_in_room` / `already_seated` / `table_full` | see §7 |

Step 5 uses `<`: a player holding exactly the boot may join. `user.chips` is compared as a number; a non-number `chips` (never the case from the DB) would compare via JS coercion.

### 5.3 Candidate selection — MUST MATCH (clustering behaviour)

```
candidates = [...tables.values()]
  .filter(t => !t.isPrivate && !t.isFull && t.config.bootAmount === bootAmount && t.category === resolved)
  .sort((a, b) => b.playerCount - a.playerCount)
table = candidates[0] ?? createTable({ bootAmount, category: resolved })
```

- `isFull` = `playerCount >= config.maxPlayers` (`table.js:132`); `playerCount` counts every occupied seat, **including disconnected players inside their reconnect grace** and players sitting out.
- **Table state is not considered**: a table mid-hand (`betting`/`showdown`) is a valid candidate; the new player sits with `status: 'waiting'` until the next deal (`table.js:151-193`).
- Sort is descending by `playerCount`; JS `Array.prototype.sort` is stable, so ties resolve to **creation order** (earliest-created table first).
- Boot match is strict `===` on numbers.
- If nothing matches, a **public** table is created with exactly the requested (validated) boot and category.

Tests: `stakes.test.js` "players cluster onto the fullest matching table" (second joiner lands on the first table; a different category at the same stake opens its own table); integration "a table holds at most five players and a sixth opens a new one" (player counts end `[1, 5]`).

### 5.4 Return value
The `Table`. The socket layer turns that into the ack `{ ok: true, roomId: table.id, code: table.code, category: table.category }` (§15.2).

---

## 6. `joinByCode(user, code)` — `roomManager.js:260-276`

Synchronous. Step order — MUST MATCH:

| # | Check | Error code | Message |
|---|---|---|---|
| 1 | `_assertNotSeated(user.id)` | `already_in_room` | `You are already seated at a table` |
| 2 | `table = getTableByCode(code)` (§3.2); `!table` | `room_not_found` | `No table with that code` |
| 3 | `table.isFull` | `table_full` | **`That table is full`** (RoomManager's wording; differs from Table's `This table is full`) |
| 4 | `user.chips < table.config.bootAmount` | `insufficient_chips` | `Not enough chips to join this table` |
| 5 | if `!table.isPrivate`: `_assertUnderEntryCap(user, { bootAmount: table.config.bootAmount, category: table.category })` | `over_entry_cap` | as §14.1 |
| 6 | `join(table, user)` | see §7 | |

Notes:
- **No `assertStakeAllowed` / `assertTableOffered`** on this route — any live table (public or private, any boot) can be joined by code.
- Private tables skip the entry cap; public ones are checked (test `lobbyRules.test.js` "joining the capped table by code is refused too").
- Because step 1 runs before the lookup, a seated player asking for a nonexistent code gets `already_in_room`, not `room_not_found` (`invalidMoves.test.js:306-308` accepts either, but the actual order yields `already_in_room`).

---

## 7. `join(table, user, socketId = null)` — `roomManager.js:329-343`

The single chokepoint through which every seating passes (quickJoin, joinByCode, switchTable, `_movePlayer`, and directly from the `room:create` socket handler). Synchronous.

1. `_assertNotSeated(user.id)` → `already_in_room` (`You are already seated at a table`).
2. `table.addPlayer({ userId: user.id, displayName: user.displayName, avatarUrl: user.avatarUrl, chips: user.chips, socketId })` — `table.js:151-193`. May throw:
   - `GameError('already_seated', 'You are already at this table')` if a seat already holds this userId (only reachable if `playerRooms` and the seats disagree);
   - `GameError('table_full', 'This table is full')`.
   Side effects inside `addPlayer` (all synchronous, before the index is updated): seat placed at the **lowest-index `null` seat**; seat fields initialised (`avatarUrl: avatarUrl ?? null`, `chips` as passed, `socketId` as passed, `connected: true`, `status: 'waiting'`, `isBlind: true`, counters 0, `joinedAt: Date.now()`); emits `seatUpdated {seatIndex}`, then `chat` with a system message `"<displayName> joined the table"` (`RoomChat.addSystem`, `chat.js:47-…`: `{ id: uuid, userId: null, displayName: 'Table', text, at, system: true }`, text truncated to `chatMaxLength`), then `_maybeStart()` (may move the table to `starting` and emit `state`), then `state`.
3. `playerRooms.set(user.id, table.id)`.
4. return `table`.

Ordering consequence: the `state` broadcast triggered by `addPlayer` happens **before** `playerRooms` knows about the player. The socket layer's `broadcastState` iterates `roomSockets`, not `playerRooms`, so the joiner (not yet tracked) simply does not receive that particular `room:state`; they get `room:joined` from the handler afterwards.

`socketId`: passed through only by `room:create` (`rooms.join(created, fresh, socket.id)`, `socket/index.js:516`) and by `_movePlayer` (preserving the seat's existing socket id). `quickJoin`/`joinByCode`/`switchTable` pass `null` and the socket handler then calls `table.setConnected(user.id, true, socket.id)` to set it.

---

## 8. `switchTable(user)` — `roomManager.js:294-327` — async

Returns `{ from: <Table left>, table: <Table joined> }`; rejects with `GameError`.

| # | Step | Error |
|---|---|---|
| 1 | `current = getTableForPlayer(user.id)`; none | `not_in_room` — `You are not at a table` |
| 2 | `current.isPrivate` truthy | `private_table` — `A private table cannot be swapped for another` |
| 3 | `bootAmount = current.config.bootAmount; category = current.category` | |
| 4 | `target = [...tables.values()].filter(t => !t.isPrivate && !t.isFull && t.id !== current.id && t.config.bootAmount === bootAmount && t.category === category).sort((a,b) => b.playerCount - a.playerCount)[0]` (fullest, ties by creation order, exactly as §5.3 but excluding the current table) | |
| 5 | no target | `no_other_table` — `` `No other ${category} table at this stake has a free seat right now` `` e.g. `No other blind table at this stake has a free seat right now` |
| 6 | `await this.leave(user.id, 'moved')` (§9) | |
| 7 | `return { from: current, table: this.join(target, user) }` | `join` may throw (§7) |

Rules that MUST MATCH:
- **The entry cap is not applied** (tests "a switch is not blocked by the entry cap"). Neither are `assertStakeAllowed`/`assertTableOffered`/chips ≥ boot.
- Same boot **and** same category only; a switch never changes either ("a switch never changes the stake or the category").
- Steps 1–5 happen before any state changes, so on `no_other_table` the seat is untouched ("switching keeps the seat when there is nowhere to go").
- Reason `'moved'` (§9) means: if the player was the last one at `current`, the table is destroyed; otherwise **no consolidation** is triggered by this departure.
- The new seat's `chips` come from the `user` object passed in — the socket layer passes the fresh DB row read **before** the leave (`socket/index.js:544`). Because bets are DB-first, that figure already reflects every bet placed; leaving mid-hand forfeits the stake (it stays in the pot) without any further debit, so the figure is still current after the leave.
- **Gap between step 6 and 7**: step 6 awaits the table's mutation queue. If, during that await, another player fills `target`, step 7 throws `table_full` from `Table.addPlayer` and the switching player is left **unseated** (their `playerRooms` entry was deleted in step 6; nothing restores it). The socket handler then re-tracks nothing (its `catch` only re-tracks `leaving` if it still exists — the player is not on it any more) and the client receives `{ok:false, code:'table_full'}` while actually being in the lobby. Rare; documented as-is (§17).

---

## 9. `leave(userId, reason = 'left')` — `roomManager.js:345-363` — async

Returns the `Table` the player left, or `null` if they were not seated.

1. `table = getTableForPlayer(userId)`; if `null` → return `null` (no error).
2. **`playerRooms.delete(userId)` first** — before any await, so nothing that runs while the removal settles (a hand ending, a settle transaction) still finds the player seated. MUST MATCH: `isSeated`/`getTableForPlayer` answer "not seated" from this instant.
3. `await table.removePlayer(userId, reason)` — queued through the table's `_run` (`table.js:224-280`). The `reason` string is forwarded verbatim; Table uses it only in the `action` event it emits when the leaver was active in a live hand: `{ userId, action: 'pack', amount: 0, pot, stake, reason }` (`table.js:255-264`) → wire `game:action { …, reason }`. The system chat line is always `"<displayName> left the table"` regardless of reason.
4. If `table.isEmpty` → `await destroyTable(table.id)` (§10).
5. Else if `reason !== 'moved'` → `await consolidateTables()` (§11) — a departure is the moment a table can drop to one player, so the merge runs immediately rather than waiting for the sweeper (test "leaving a table triggers a merge without waiting for the sweep").
6. return `table`.

Reason strings in use (MUST MATCH, they reach the wire in `game:action.reason` and `room:kicked.reason`):

| Reason | Origin |
|---|---|
| `'left'` | default; `room:leave` handler (`socket/index.js:580`) |
| `'disconnected'` | reconnect-grace expiry (`socket/index.js:702`) |
| `'moved'` | `switchTable` (§8) and `_movePlayer` (§11.2; there the table's `removePlayer` is called directly, not `leave`) |
| `'idle'` | forwarded from a Table `kick` (§15.3) |
| `'insufficient_chips'` | forwarded from a Table `kick` (§15.3) |

---

## 10. `destroyTable(roomId)` — `roomManager.js:394-404` — async

1. `table = tables.get(roomId)`; if missing → return (silently).
2. `for (seat of table.occupiedSeats) playerRooms.delete(seat.userId)`.
3. `tables.delete(roomId)` — **before** the possibly slow destroy, so no one can be seated at a table on its way out.
4. `await table.destroy()` (`table.js:1763-1785`): if a hand is live, ends it with `WIN_REASON.ALL_LEFT = 'all_left'`, winner = first seat in `activeSeats` (occupied seats with `status === 'active'`) else `hand.lastDeparture` (which may be `null` → pot refunded, no winner) — this **writes the settlement transaction**; then marks destroyed, clears turn/start timers, clears chat, `removeAllListeners()`.
5. `emit('tableDestroyed', roomId)` — socket layer sends `room:closed {roomId}` to every socket still tracked in that room and forgets the room (§15.4).
6. `logger.info('table destroyed', { roomId })` — INCIDENTAL.

Note step 2 does not remove the seats from the table object itself; they remain on the (now orphaned) Table.

---

## 11. `consolidateTables()` — `roomManager.js:416-450` — async — requirement 24

Returns `moves: Array<{ userId, fromRoomId, toRoomId }>` (used by tests and logging).

### 11.1 Algorithm — MUST MATCH

1. `singles = [...tables.values()].filter(t => !t.isPrivate && !t.hand && t.state === 'waiting' && t.playerCount === 1)`.
   - Private tables are never touched.
   - `!t.hand` and `state === 'waiting'` both required: a one-player table in `starting` (impossible in practice) or `showdown` is skipped.
   - `playerCount === 1` counts a disconnected-but-in-grace player as present.
2. Group by key `` `${t.category}:${t.config.bootAmount}` `` (e.g. `blind:200`), preserving creation order within each group and group insertion order across.
3. For each group: `group.sort((a,b) => a.createdAt - b.createdAt)` (oldest first; stable); `target = group[0]`; for each `source` of `group.slice(1)`: `if (target.isFull) break;` `move = await _movePlayer(source, target)`; push if non-null.
4. Return `moves`.

Consequences: the **oldest** table in each stake/category group survives and collects everyone; the newer ones are emptied and destroyed. With three singles, the result is one table with three players (test "three lone players end up at the same table"). A full destination (5 seats) stops the loop for that group. Different stakes or categories are never merged.

### 11.2 `_movePlayer(source, target)` — `roomManager.js:456-488` — async

1. `seat = source.occupiedSeats[0]`; if `!seat || source.hand || target.hand || target.isFull` → return `null` (re-checked here because the caller's filter may be stale after awaits).
2. Build `player = { id: seat.userId, displayName: seat.displayName, avatarUrl: seat.avatarUrl, chips: seat.chips }` — **chips are the seat's in-memory figure**, not a fresh DB read (fine because between hands the seat equals the wallet); `socketId = seat.socketId`; `fromRoomId = source.id`.
3. `await source.removePlayer(player.id, 'moved')` — directly on the table (not `leave`), emitting on `source`: `seatUpdated`, `chat` (`"<name> left the table"`), then (no hand, state waiting) `_maybeStart()` and `state`.
4. `playerRooms.delete(player.id)`.
5. `try { this.join(target, player, socketId) }` — emits on `target`: `seatUpdated`, `chat` (`"<name> joined the table"`), `_maybeStart()` (two funded players → `starting`, `startsAt = now + nextHandDelayMs`, `state`), `state`. `catch` → `logger.warn('table consolidation failed, restoring seat', { error })`; `this.join(source, player, socketId)` (puts them back at `source`, which still exists because it has not been destroyed yet); return `null`.
6. `if (source.isEmpty) await destroyTable(fromRoomId)` → emits `tableDestroyed` (§10).
7. `move = { userId, fromRoomId, toRoomId: target.id }`; `emit('playerMoved', move)`; `logger.info('player moved to a busier table', move)`; return `move`.

**Event order MUST MATCH** because the socket layer reacts to each: `source` state events → `target` state events → `tableDestroyed(fromRoomId)` → `playerMoved`. The resulting wire sequence for the moved player is spelled out in §15.5.

Tests: `consolidation.test.js` (all 15 cases, §16).

---

## 12. `sweepEmptyTables()` — `roomManager.js:491-498` — async

```
cutoff = Date.now() - 30_000            // hardcoded 30 s, not configurable
for table of [...tables.values()]:      // snapshot copy, safe against deletion
  if table.isEmpty && table.state === 'waiting' && table.createdAt < cutoff:
    await destroyTable(table.id)
```

Uses the **real clock** (`Date.now()`), not `timers`. Only tables that were created but never (or no longer) occupied and are older than 30 s. Ordinary play never leaves an empty table alive (`leave` destroys on `isEmpty`), so this catches: tables created via `createTable` whose `join` then threw, `_movePlayer` restore edge cases, and tests. MUST MATCH the 30 s and the three conditions.

---

## 13. `shutdown()` — `roomManager.js:509-512` — async

1. `clearInterval(this._sweeper)`.
2. `for (roomId of [...tables.keys()]) await destroyTable(roomId)` — sequentially, in creation order; live hands are settled (pots paid) through `Table.destroy()` before the caller closes the DB pool (`index.js:150-158`: `io.close()` → `await rooms.shutdown()` → `server.close` → `closeDatabase()`; a hard `process.exit(1)` after 8 s).

Every test suite that builds a `RoomManager` calls `await rooms.shutdown()` in teardown.

---

## 14. Guards

### 14.1 `_assertUnderEntryCap(user, { bootAmount, category })` — `roomManager.js:372-383` — requirement 30 — MUST MATCH

```
cap = config.game.entryCapMaxChips       // default 500000; 0 disables the rule
if (!cap) return
if (bootAmount !== config.game.entryCapBoot) return        // default 200, strict ===
if (category !== config.game.entryCapCategory) return      // default 'blind', strict ===
if (user.chips <= cap) return                              // exactly the cap is allowed
throw GameError('over_entry_cap', `Players with more than ${cap.toLocaleString('en-US')} chips cannot join this table`)
```

Default message: `Players with more than 500,000 chips cannot join this table` — `toLocaleString('en-US')` gives comma thousands grouping, no decimals.

Where applied: `quickJoin` (always, with the normalised category) and `joinByCode` (public tables only). **Not** applied in `switchTable`, `join`, `createTable`, `_movePlayer`, or when a seated player's stack grows past the cap during play.

Tests: `lobbyRules.test.js` "a big stack cannot join the capped table" (`cap+1` → `over_entry_cap`), "a stack exactly at the cap may still join", "the cap applies only to that stake and category" (same boot other category OK; higher stake same category OK), "joining the capped table by code is refused too", "the lobby is told the rule so it can grey the table out" (`lobbyOptions` fields), "a switch is not blocked by the entry cap", "but the lobby route still refuses them". Flutter mirrors the rule client-side (`dtos.dart:235-238`: `entryCapMaxChips > 0 && boot == entryCapBoot && category == entryCapCategory && chips > entryCapMaxChips`).

### 14.2 `_assertNotSeated(userId)` — `roomManager.js:385-390`
`if (getTableForPlayer(userId)) throw GameError('already_in_room', 'You are already seated at a table')`. Called at the top of `quickJoin`, `joinByCode` and `join`.

### 14.3 `isSeated` for REST — `index.js:80`
`playerRoutes({ isSeated: (userId) => Boolean(rooms.getTableForPlayer(userId)) })` — `POST /api/profile/avatar` and `POST /api/profile/name` answer `409 { error: 'seated', … }` while this is true (`auth/routes.js:166-170, 198-202`). Because `leave` deletes the index before awaiting the removal (§9 step 2), a player is "not seated" for REST the moment their leave begins.

---

## 15. What the socket layer does with RoomManager (`socket/index.js`)

This section lists only the RoomManager-facing behaviour needed to reproduce the wire; the full socket contract lives in its own spec.

### 15.1 Wiring
- `rooms.on('tableCreated', wireTable)` (`socket/index.js:341`). `wireTable(table)` is idempotent via a `table._wired` flag and attaches the `state/kick/handStarted/cards/turn/action/sideshow*/showdown/handEnded/chat` listeners. Handlers also call `wireTable(table)` defensively before tracking a socket.
- `rooms.on('playerMoved', …)` (`socket/index.js:347-368`) — see §15.5.
- `rooms.on('tableDestroyed', …)` (`socket/index.js:370-378`) — see §15.4.

### 15.2 Request handlers — argument mapping and ack shapes (MUST MATCH)

All go through `guard` (`socket/index.js:427-453`): ack `{ ok: true, ...result }` on success; on a thrown error ack `{ ok: false, code: error.code ?? 'internal_error', message: error.message }` **and** emit `game:error { code, message }`. `payload ?? {}` — a `null` payload means defaults (`invalidMoves.test.js:328-330`: `room:quickJoin` with `null` succeeds at the default stake).

| Event | RoomManager calls, in order | Ack result |
|---|---|---|
| `lobby:list {category?}` | `rooms.listTables({ category: category ?? null })`, `RoomManager.lobbyOptions()` | `{ tables, options }` |
| `room:quickJoin {bootAmount?, category?}` | `fresh = await findById(user.id)`; `seated = rooms.quickJoin(fresh, { bootAmount: bootAmount ?? config.game.bootAmount, category })`; `wireTable`; `trackRoom`; `seated.setConnected(user.id, true, socket.id)`; emit `room:joined` = `seated.serializeFor(user.id)`; then `sendChatHistory`; `broadcastState(seated)` | `{ roomId, code, category }` |
| `room:create {bootAmount?, isPrivate=true, category?}` | `fresh = await findById`; `created = rooms.createTable({ bootAmount: bootAmount ?? config.game.bootAmount, isPrivate, category })`; `wireTable`; `rooms.join(created, fresh, socket.id)`; `trackRoom`; emit `room:joined`; `sendChatHistory`. **No `broadcastState`** (the creator is the only viewer). | `{ roomId, code, category }` |
| `room:joinCode {code}` | `fresh = await findById`; `rooms.joinByCode(fresh, code)`; then as quickJoin | `{ roomId, code, category }` |
| `room:switch {}` | `fresh = await findById`; `leaving = rooms.getTableForPlayer(user.id)`; if `leaving` → `untrackRoom(leaving.id, socket)` **before** the switch; `{from, table} = await rooms.switchTable(fresh)` (on throw: if `leaving && rooms.getTable(leaving.id)` re-`trackRoom`, rethrow); `wireTable(target)`; `trackRoom`; `setConnected`; emit `room:joined`; `sendChatHistory`; `broadcastState(target)`; `vacated = rooms.getTable(from.id)`; if alive `broadcastState(vacated)` | `{ roomId, code, category }` |
| `room:leave {}` | `table = rooms.getTableForPlayer(user.id)`; if none → ack `{}` (ok:true, no error); `await rooms.leave(user.id, 'left')`; `untrackRoom`; emit `room:left { roomId }`; if `rooms.getTable(roomId)` still alive → `broadcastState` | `{ roomId }` or `{}` |
| `game:action`, `game:sideshowRespond`, `player:requestCards`, `chat:message`, `chat:history` | `rooms.getTableForPlayer(user.id)`; none → `GameError('not_in_room', 'You are not at a table')` | — |

Important: `room:create` runs `rooms.createTable` **before** `rooms.join`. If the creator is already seated, `join` throws `already_in_room` (`invalidMoves.test.js:312-314`) — but the table has already been created and registered, and is left behind empty until `sweepEmptyTables` reaps it after 30 s. The ack is `{ok:false, code:'already_in_room'}`.

`room:create` with `isPrivate: false` (or any falsy value) creates a **public** table at `bootAmount ?? default` with **no stake/menu validation** and no chips check on the creator beyond `Table.addPlayer` (which has none). See §17 open question 1.

### 15.3 Kick handling — `socket/index.js:222-241` — MUST MATCH

`table.on('kick', async ({ userId, reason, message }) => …)`:

1. `if (!rooms.getTableForPlayer(userId)) return;` — already gone (e.g. a second kick for the same seat).
2. `try { await rooms.leave(userId, reason) } catch → logger.error('kick failed', …); return`.
3. `kicksTotal.inc({ reason })` (INCIDENTAL).
4. `emitToUser(userId, 'room:kicked', { roomId: table.id, reason, message })` — to the kicked player's current socket only, if connected.
5. `untrackRoom(table.id, socket)` for that user's socket.
6. `stillAlive = rooms.getTable(table.id)`; if alive → `broadcastState(stillAlive)`.

Kick payloads emitted by Table (`table.js:665-672`) — the strings reach the wire unchanged:

| `reason` | `message` | Source |
|---|---|---|
| `'idle'` | `` `Left the table after ${seat.missedTurns} missed turns` `` (e.g. `Left the table after 3 missed turns`) | `table.js:654`, after the 3rd consecutive timeout |
| `'insufficient_chips'` | `You don't have enough coins to remain in this table` | `table.js:504` (boot transaction refused for this user) and `table.js:690-694` (`_sweepUnfunded` between hands) |

The `kick` event is emitted **synchronously inside a queued table mutation**; `rooms.leave` → `table.removePlayer` re-enters `_run` and is therefore queued behind the mutation in progress (`table.js:107-111`). This is why `_sweepUnfunded` sets `seat.kickPending` (`table.js:688-689`) — the removal has not landed yet when a second sweep could run.

Because the kick `reason` is passed straight to `leave`, it becomes `game:action.reason` if the player was still active in a hand (for `'idle'` the player was already packed by the timeout, so no second `pack` action is emitted; for `'insufficient_chips'` there is no hand).

### 15.4 `tableDestroyed` — `socket/index.js:370-378`
For every socket in `roomSockets[roomId]`: emit `room:closed { roomId }`, `socket.leave(roomId)`; then `roomSockets.delete(roomId)`. Sockets that were untracked beforehand (the `room:switch` path, a kicked player) receive nothing.

### 15.5 `playerMoved` — `socket/index.js:347-368` — and the full wire order seen by a consolidated player

Handler: `socket = userSockets.get(userId)`, `target = rooms.getTable(toRoomId)`; if either missing → return. Then `untrackRoom(fromRoomId, socket)`; `wireTable(target)`; `trackRoom(toRoomId, socket)`; `target.setConnected(userId, true, socket.id)` (emits `seatUpdated` + `state` → `broadcastState(target)`); emit `room:moved { fromRoomId, toRoomId, code: target.code, message: 'Moved to a table with other players waiting.' }` (**no `state` field**); emit `room:joined` = `target.serializeFor(userId)`; `sendChatHistory(target, socket)` = `chat:history { roomId, messages }`; `broadcastState(target)`.

Combining §11.2 with the listeners, the moved player's socket receives, in order (MUST MATCH if you want identical client behaviour; the Flutter client tolerates it — `room:closed` drops it to the lobby and `room:state`/`room:joined` put it back on the table):

1. `chat:message` (system, `"<name> left the table"`, `roomId: fromRoomId`) — still tracked in the old room.
2. `room:state` for the **old** table (viewer's seat gone, `you: null`) — from `_removePlayer`'s `state` event.
3. *(target's `chat:message` "joined" and `room:state` go only to players already at the target — the mover is not yet tracked there.)*
4. `room:closed { roomId: fromRoomId }` — the old table was destroyed **before** `playerMoved` fired.
5. `room:state` for the **new** table — from `setConnected` inside the `playerMoved` handler.
6. `room:moved { fromRoomId, toRoomId, code, message }`.
7. `room:joined` (new table snapshot).
8. `chat:history { roomId: toRoomId, messages }` (includes the "joined the table" system line).
9. `room:state` for the new table again.

Players already at the target see: `chat:message` "joined", `room:state` (from `addPlayer`), `room:state` (from `setConnected`), `room:state` (final broadcast) — and the table typically shows `state: 'starting'` with `startsAt` because two funded players are now present (test "the table announces when the next hand starts").

### 15.6 Reconnect / resume reads
- On connect: `rooms.getTableForPlayer(user.id)` — if a table, the socket is re-tracked and sent `room:joined` + `chat:history` ("restarted bots land on their previous table"). Otherwise `takeResumeOffer` uses `rooms.getTable(offer.roomId)` and refuses if missing or `isFull`, returning `{ roomId, code, category, bootAmount: table.config.bootAmount }` (`socket/index.js:137-151`).
- Disconnect grace (`socket/index.js:687-712`): after `reconnectGraceMs`, if the player has no live socket and `rooms.getTableForPlayer` still returns a table → `resumeOffers.set(…)` then `await rooms.leave(user.id, 'disconnected')`; then `broadcastState` if the table survived.

---

## 16. Test cases to mirror

Unit suites construct `new RoomManager({ timers: createFakeTimers().timers, settle: () => ({}) })` — fake timers for the tables, in-memory ledger (no Postgres). `createFakeTimers()` (`test/helpers/fakeTimers.js`) gives `{ timers, advance, now, pending }`; `await advance(ms)` fires due timers in order, awaiting each. Player fixtures are `{ id, displayName, avatarUrl: null, chips }` with unique ids.

### 16.1 `test/consolidation.test.js` (BOOT=200, START=200000, blind by default)

| Test | Setup | Asserts |
|---|---|---|
| two tables with one player each are merged into one | two `createTable({200, blind})` each with one `join` | `consolidateTables()` returns 1 move; `tables.size === 1`; survivor `playerCount === 2`; the two seated userIds are the original two |
| the merged players can now actually start a hand | same, then `advance(10000)` | survivor `state === 'starting'` right after the merge; a hand exists after the advance |
| the player is moved onto the longest-standing table | first, second created in order | `moves[0].fromRoomId === second.id`, `toRoomId === first.id`; `getTable(second.id) === null` |
| three lone players end up at the same table | three singles | `tables.size === 1`, `playerCount === 3` |
| a move is announced so the client can follow it | listen `playerMoved` | exactly one event with `userId` = second table's occupant and `fromRoomId === second.id` |
| the room index follows the player to their new table | | `getTableForPlayer(moved).id === first.id` |
| a table with a hand in progress is never disturbed | busy table (2 players, `advance(10000)` → hand), plus a single | 0 moves; both tables still exist |
| a lone player is not moved while their own table has a live hand | 2-player table mid-hand; `leave(firstSeat.userId, 'left')` | `playerCount === 1` and `hand === null` afterwards (hand resolved by the leave before any merge) |
| tables of different stakes are never merged | singles at 200 and 5000 | 0 moves, 2 tables |
| blind and seen tables are never merged | singles blind and seen | 0 moves, 2 tables |
| private tables are left alone | two `createTable({ isPrivate: true, blind })` each with one player | 0 moves, 2 tables |
| a full destination stops taking players | 5-seat full table + a single | 0 moves; single keeps its 1 player |
| a single lone table has nothing to merge with | one single | 0 moves, 1 table |
| the table announces when the next hand starts | merge two singles; `serializeFor(occupant)` | `state === 'starting'`; `Date.now() < startsAt <= Date.now() + 5000` (nextHandDelayMs default 4000) |
| leaving a table triggers a merge without waiting for the sweep | table A (2 players), table B (1 player); `leave(A1, 'left')` | `tables.size === 1`, `playerCount === 2` (A was created first, so B1 moves onto A) |

### 16.2 `test/lobbyRules.test.js` (entry cap and switch parts; uses live `config` values)

| Test | Setup | Asserts |
|---|---|---|
| a big stack cannot join the capped table | `quickJoin(player(cap+1), {capBoot, capCategory})` | throws code `over_entry_cap` |
| a stack exactly at the cap may still join | `player(cap)` | does not throw |
| the cap applies only to that stake and category | rich player quick-joins same boot other category; `await leave`; then higher stake same category | neither throws |
| joining the capped table by code is refused too | eligible player opens capped table via `quickJoin`; `joinByCode(player(cap+1), table.code)` | `over_entry_cap` |
| the lobby is told the rule so it can grey the table out | `lobbyOptions()` | `entryCapBoot`, `entryCapCategory`, `entryCapMaxChips` equal config |
| a switch is not blocked by the entry cap | `first` via quickJoin (1000 chips), `second` via `createTable` + `join(player(2000))`; `join(first, rich)`; `switchTable(rich)` | `table.id === second.id`; `getTableForPlayer(rich.id).id === second.id` |
| but the lobby route still refuses them | | `over_entry_cap` |
| a switch never changes the stake or the category | home table; other-category table and higher-stake table exist; `switchTable(mover)` | rejects `no_other_table` |
| switching keeps the seat when there is nowhere to go | one table, two players | rejects `no_other_table`; `getTableForPlayer(mover.id).id === home.id` |
| a player who is not seated cannot switch | | rejects `not_in_room` |

### 16.3 `test/privateTables.test.js` (RoomManager-facing cases)

| Test | Asserts |
|---|---|
| a private table always uses the fixed boot of 200 chips | `createTable({ bootAmount: asked, isPrivate: true }).config.bootAmount === 200` for asked ∈ {50,199,200,1000,99999,undefined} |
| a public table still uses the stake it was created with | `createTable({ bootAmount: 100, isPrivate: false })` → 100; 5000 → 5000 (no validation in createTable) |
| the lobby advertises the fixed boot and the maximum win | `lobbyOptions().privateBoot === 200`, `.privateMaxPot === 500000` |
| a private table allows a single double per turn | private blind table, two players, `startHand()`; `betOptions(onTurn).steps` deep-equals `[200, 400]`; raise 800 → `invalid_bet` |
| a public blind table still keeps the full ladder | `steps.length > 2` |
| every table but a public blind one carries a pot ceiling | private (default cat) 500000; private blind 500000; public seen 1200000; public blind 0 |
| the ceiling is reported to clients in the table snapshot | private table `serializeFor('a').maxPot === 500000` |
| an uncapped table is unaffected by the ceiling logic | public blind: `steps.length > 8`, `max <= seat.chips`, `max*2 > seat.chips` |

### 16.4 `test/stakes.test.js` (real Postgres, real default menu; env `TABLE_STAKES`/`LOBBY_TABLES` deleted, `NEXT_HAND_DELAY_MS=150`, `PG_SCHEMA=test_stakes_<rand>`; `new RoomManager()` with the pg ledger)

| Test | Asserts |
|---|---|
| the lobby offers exactly the 200 and 5000 stakes | `config.game.tableStakes` and `lobbyOptions().stakes` deep-equal `[200, 5000]`; `categories` deep-equals `['seen','blind']` |
| the menu is three rooms, in the order the lobby shows them | `lobbyOptions().tables` deep-equals the three-row JSON in §2.4 |
| the ceiling a card advertises is the one the table is built with | for each menu row `quickJoin(player(), row)` → `table.maxPot === row.maxPot`, `table.config.maxBlindMoves === row.maxBlindMoves` |
| every room on the menu can be joined | each row joins; `table.config.bootAmount` and `table.category` match; `listTables().length === 3` |
| a stake and category that is not a room on the menu is refused | `{5000, 'seen'}` → `table_not_offered`; `listTables().length === 0` afterwards (nothing created) |
| a stake the lobby does not offer is refused | 1, 100, 199, 4999, 10000 → `invalid_stake` |
| a malformed stake is refused | 0, -200, 200.5, NaN, `'lots'`, `null` → `invalid_stake` |
| a player short of the stake cannot sit down | `player(4999)` at `{5000,'blind'}` → `insufficient_chips`; same player at `{200}` succeeds with boot 200 |
| players cluster onto the fullest matching table | two seen/200 quick-joins share a table; blind/200 gets a different one |

### 16.5 `test/tableRules.test.js` (tables built through `rooms.createTable`)

| Test | Asserts |
|---|---|
| a seen table allows a single double per turn | `steps` deep-equals `[200, 400]`; raise 800 → `invalid_bet` |
| a blind table keeps the full doubling ladder | `steps.length > 2`, `steps[2] === 800` |
| a blind table has no round cap, no rung cap and no per-bet ceiling | `config.maxBetRounds === 0`, `config.maxRaiseSteps === 0`, `config.potLimitMultiplier === 0`, `table.maxPot === 0` |
| a blind table never forces a showdown, however long the betting goes on | 120 chaals: hand still live, `round >= 50`, no `handEnded` |
| a seen table forces a showdown after 7 rounds | `config.maxBetRounds === 7`; hand ends with reason `forced_showdown`, 2 reveals, a winner |

### 16.6 `test/integration.test.js` (full server, Postgres, `TABLE_STAKES=''`, `LOBBY_TABLES=''`, `BOOT_AMOUNT=100`, unique stake per test)

| Test | Asserts about RoomManager |
|---|---|
| two players quick-join the same table and a hand is dealt | both acks `ok`, same `roomId`; a `room:state` with `state === 'betting'` arrives |
| a table holds at most five players and a sixth opens a new one | 6 quick-joins at one stake → 2 distinct roomIds; `playerCount`s sorted `[1, 5]` |
| a private room can be created and joined by its code | `room:create {isPrivate:true}` → `code` matches `/^[A-Z2-9]{6}$/`; `room:joinCode {code}` → same `roomId`; `room:joinCode {code:'ZZZZZZ'}` → `ok:false`; `rooms.getTable(roomId).config.bootAmount === 200` |
| leaving a room frees the seat | after `room:leave`, `rooms.getTableForPlayer(id) === null` |
| blind and seen tables at the same stake are separate rooms | acks carry `category` `'blind'`/`'seen'`; different roomIds |
| the lobby offers the configured categories and stakes | `session:ready.config.categories` deep-equals `['seen','blind']`; `lobby:list` ack has `tables` array and `options.categories` array |
| the lobby can be filtered to one category | `lobby:list {category:'blind'}` rows all blind (and include the joined boot); `{category:'seen'}` rows all seen |
| an unknown category is treated as seen rather than hiding chips | `room:quickJoin {category:'sneaky'}` → `ok:true`, `category:'seen'` |
| health reports live table and player counts | `/health` `tables`, `players` are numbers |

### 16.7 `test/invalidMoves.test.js` (seating cases)

| Test | Asserts |
|---|---|
| joining while already seated, or a room that does not exist, is refused | seated player: `room:quickJoin` → `already_in_room`; `room:joinCode {code:'NOPE00'}` → `already_in_room` or `room_not_found`; `room:create {isPrivate:true}` → `already_in_room` and the player is still seated. Unseated player: `NOPE00` → `room_not_found`; `code: {$gt:''}` → `ok:false`; `bootAmount: -5` → `ok:false`; `bootAmount: 'lots'` → `ok:false`; payload `null` → `ok:true` |
| a player who cannot cover the boot is not seated | wallet reduced to 50 via the ledger; `room:quickJoin` → `insufficient_chips`; `getTableForPlayer === null` |
| the sixth player is not squeezed onto a full table | `rooms.createTable({bootAmount, isPrivate:true})`; five `room:joinCode` succeed; sixth → `table_full` |

### 16.8 `test/metrics.test.js` (gauges fed from `rooms.tables`)
After two quick-joins on a seen table with a dealt hand: `game_players_online >= 2`, `game_active_games >= 1`, `game_tables{category="seen",stake="<boot>"} >= 1`, `game_join_duration_seconds_count{route="quick_join"} >= 2`, `game_creation_duration_seconds_count >= 1`.

---

## 17. Traps for the port

1. **Ledger default is decided in the constructor, once.** `ledger ?? (settle || persistChips ? null : createLedger())`. Passing *either* legacy hook must suppress the Postgres ledger and hand the hooks to every table (tests depend on this: without it unit suites would hit the database).
2. **Validation lives in the caller, not `createTable`.** `createTable` never checks the stake or the menu; `quickJoin` does (order in §5.2). `room:create` with `isPrivate:false` therefore opens an unvalidated public table (open question 1). `joinByCode` checks neither stake nor menu either — only existence, fullness, chips, and (public only) the entry cap.
3. **Check order determines the error code.** `_assertNotSeated` is first in `quickJoin`, `joinByCode` and `join`; a seated player sending a garbage code gets `already_in_room`, not `room_not_found`. In `quickJoin`, `invalid_stake` precedes `table_not_offered` precedes `insufficient_chips` precedes `over_entry_cap`.
4. **`undefined` vs `null` defaults.** `bootAmount = config.game.bootAmount` in `quickJoin`/`_createTable` applies only to `undefined`; `null` falls through (`quickJoin` → `invalid_stake`; `_createTable` → a table with `bootAmount: null`). The socket layer normalises with `bootAmount ?? config.game.bootAmount`, so `null` from a client becomes the default *there*.
5. **Category normalisation is strict lowercase `'blind'`**; everything else is `'seen'`. `listTables`' category filter, by contrast, is a raw `===` with no normalisation (an unknown filter yields an empty list, not everything).
6. **`isPrivate` is stored raw** and tested by truthiness everywhere. A Go port storing a `bool` must coerce with JS truthiness semantics on the way in (`0`, `''`, `false`, `null`, `undefined`, `NaN` → false; everything else including `'false'` → true).
7. **Map insertion order is load-bearing.** Quick-join and switch pick the fullest table with **stable** ordering, so ties go to the earliest-created table; `listTables` returns creation order; consolidation groups and sorts by `createdAt` (ms) with a stable sort — two tables created in the same millisecond keep creation order.
8. **`isFull`/`playerCount` count disconnected players** still inside `reconnectGraceMs`, and players sitting out a hand. A "full" table may show fewer than 5 connected players.
9. **Quick-join ignores table state.** A player may be seated at a table mid-hand; they sit out (`status:'waiting'`) until the next deal.
10. **`leave` deletes `playerRooms` before awaiting the removal.** REST `isSeated`, `getTableForPlayer`, `_assertNotSeated` all flip to "not seated" before the table has processed the departure. Conversely, `join` sets the index **after** `addPlayer` has already emitted `state`.
11. **Reason `'moved'` suppresses consolidation but not destruction.** `leave(…, 'moved')` still destroys an emptied table; any other reason triggers `consolidateTables()` immediately after a non-emptying departure.
12. **Consolidation's event order is `source` events → `target` events → `tableDestroyed` → `playerMoved`.** The moved player receives `room:closed` for the old room *before* `room:moved`/`room:joined` (§15.5). Reordering these would change what clients see.
13. **`_movePlayer` copies `chips` from the seat, not the DB**, and preserves the seat's `socketId`. Failure to seat at the target restores the player to the source (which has not been destroyed yet at that point).
14. **Kick handling re-enters the table's queue.** Table emits `kick` synchronously mid-mutation; the socket layer's handler `await rooms.leave(userId, reason)` queues `removePlayer` behind the current mutation. The `reason` string (`'idle'`/`'insufficient_chips'`) is the `leave` reason and appears verbatim in `room:kicked.reason`. The handler bails out early if `getTableForPlayer` is already null.
15. **RoomManager must attach an `'error'` listener to every table.** Its presence changes Table's abandoned-settlement path from `persistError` to `error`; without any listener a Node EventEmitter would throw on `emit('error')`. The Go equivalent must never let that path crash.
16. **Timers.** Tables use the injected `timers` (fake in tests); the sweeper uses the real `setInterval(config.game.consolidateIntervalMs)` and `sweepEmptyTables` uses the real `Date.now()` with a **hardcoded 30 000 ms**. `createdAt` is epoch milliseconds.
17. **Room code alphabet** excludes `0 1 I O`; always 6 uppercase chars; lookup upper-cases the input; **no uniqueness check**.
18. **Money formatting in an error message.** `over_entry_cap` embeds `cap.toLocaleString('en-US')` → `500,000` (comma grouping). Byte-match the message if clients ever display it (Flutter shows `message` from `game:error` as a notice).
19. **`insufficient_chips` is a shared code.** RoomManager throws it on join (`Not enough chips to join this table`); Table/ledger throw it for boots/bets and use it as a kick reason. Keep the message texts distinct as in Node.
20. **`table_full` has two messages.** `That table is full` (RoomManager `joinByCode`) vs `This table is full` (`Table.addPlayer`, reachable via `quickJoin`/`join` races and `room:create`).
21. **`switchTable` can strand a player** if the target fills between `leave` and `join` (§8). Node does not restore the seat; the ack is `table_full` and the player is in the lobby. Reproduce or fix — but record which (open question 2).
22. **`room:create` by a seated player leaks an empty table** (§15.2) until the 30 s sweep. `tables` in `/health` and `game_waiting_games` count it meanwhile.
23. **Numbers from Postgres are JS numbers** (`db/index.js` sets int8/numeric type parsers). `user.chips < bootAmount` is a numeric comparison; a port reading `BIGINT` as string would break every chips check.
24. **`lobbyOptions()` reads config at call time** but config is snapshotted at process start; the shape is fixed per process. `categories` is a constant `['seen','blind']` irrespective of `LOBBY_TABLES`.
25. **Private tables: boot forced, cap applied, entry cap skipped, never listed, never consolidated, never switchable, never a quick-join candidate, joinable only by code.**

---

## 18. Open questions surfaced while reading (decisions for the port owner)

1. `room:create { isPrivate: false, bootAmount: 7 }` creates a public table at an arbitrary boot with no `assertStakeAllowed`/`assertTableOffered`/chips check (`socket/index.js:506-522`, `roomManager.js:100-107`). Bug-compatible, or validate?
2. `switchTable` leaves the player unseated if `join(target)` throws after `leave` (§8, §17.21). Bug-compatible, or restore the seat as `_movePlayer` does?
3. `room:create` by an already-seated player registers an empty table before `join` throws (§15.2). Bug-compatible (swept after 30 s), or check seating first?
4. `roomCode()` has no collision check; `getTableByCode` returns the first match. Keep, or guarantee uniqueness?
5. The consolidated player receives `room:closed` before `room:moved` (§15.5). Preserve the exact order (Flutter copes), or reorder?
6. `lobbyTables` entries with an unknown category (e.g. `LOBBY_TABLES=foo:200`) are advertised but unjoinable. Keep or validate at config time?
