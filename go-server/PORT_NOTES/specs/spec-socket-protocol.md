# Spec: the realtime protocol (Socket.IO layer) and its wire format

Behavioural specification of `server/src/socket/index.js` and the Socket.IO server it runs on, as the
Node server implements it **today** (working tree of `/home/suraj/Project/king-teenpatti/server`,
socket.io 4.8.3 / engine.io 6.6.10 / socket.io-parser 4.2.4, per `package-lock.json`). A Go engineer
who never reads the JavaScript must be able to reproduce the wire traffic byte-for-byte and the
observable ordering of every message.

Conventions used below:

- **MUST MATCH** — clients, tests or stored data depend on it.
- **INCIDENTAL** — internal naming, logging, metrics label folding; a port may differ without any
  client noticing (but the `/metrics` test suite does assert most metric names, see §12).
- Citations are `file:line-range` in the Node working tree. `socket/index.js` is abbreviated `sock`.
- All JSON shapes list keys **in the order Node emits them** (V8 preserves insertion order; the
  Unity-port scanner in `csharpJsonPort.js` is order-insensitive, but byte-for-byte fidelity
  requires the same order). A key whose value is JavaScript `undefined` is **absent**; `null` is
  emitted as `null`.

---

## 0. Files and imports covered

| File | Role |
|---|---|
| `server/src/index.js:113-135` | Creates the `http.Server`, the Socket.IO `Server` and its options, optional Redis adapter, calls `attachSocketHandlers(io, rooms)`. |
| `server/src/socket/index.js` (762 lines) | The whole realtime protocol. |
| `server/src/auth/tokens.js:14-21` | `verifyToken` used by the handshake middleware. |
| `server/src/db/users.js:21-70` | `findById` → the `user` object sent in `session:ready`. |
| `server/src/game/roomManager.js` | `quickJoin`, `joinByCode`, `createTable`, `switchTable`, `leave`, `lobbyOptions`, events `tableCreated` / `playerMoved` / `tableDestroyed`. |
| `server/src/game/table.js` | Table events consumed by `wireTable`, `serializeFor`, `summary`, `postChat`, `chatHistory`, `setConnected`, `findSeat`. |
| `server/src/game/chat.js` | Chat message shape and sanitising. |
| `server/src/game/constants.js` | `ACTION`, `TABLE_CATEGORY`, `WIN_REASON`, `SEAT_STATE`, `TABLE_STATE` string values. |
| `server/src/metrics/index.js` | Counters/histograms fed by the socket layer; `safeLabel`, `timed`, `timedSync`. |
| `server/src/config/index.js` | Every number the socket layer reads. |
| `server/test/socketProtocol.test.js`, `server/test/helpers/csharpJsonPort.js` | Raw Engine.IO/Socket.IO framing assertions. |
| `server/test/integration.test.js`, `invalidMoves.test.js`, `metrics.test.js` | Behavioural assertions through `socket.io-client`. |
| `flutter-client/lib/net/game_connection.dart`, `server/public/client.js`, `server/tools/bot.js`, `server/test/loadtest.js` | How the clients connect and what they read. |

---

## 1. Socket.IO server construction

`server/src/index.js:115-123`:

```js
const io = new Server(server, {
  cors: { origin: config.corsOrigin, methods: ['GET', 'POST'] },
  transports: ['websocket', 'polling'],
  pingInterval: 20000,
  pingTimeout: 25000,
  maxHttpBufferSize: 1e5,
});
```

| Option | Value | Source | Class |
|---|---|---|---|
| HTTP path | `/socket.io/` (Socket.IO default; `addTrailingSlash` default true, so `/socket.io` and `/socket.io/` both work) | socket.io default | MUST MATCH |
| `cors.origin` | `'*'` unless `CORS_ORIGIN` is set and is not `*`, in which case a comma-split, trimmed **array** of origins (`config/index.js:27`) | config | MUST MATCH (browser client) |
| `cors.methods` | `['GET','POST']` | index.js:116 | MUST MATCH (browser preflight) |
| `transports` | `['websocket','polling']` — both accepted by the server | index.js:119 | MUST MATCH (websocket); polling is accepted but no shipped client actually uses it (see §14.8) |
| `pingInterval` | **20000** ms (server → client ping cadence) | index.js:120 | MUST MATCH (advertised in the OPEN packet; client dead-man timer derives from it) |
| `pingTimeout` | **25000** ms (server waits this long for the pong) | index.js:121 | MUST MATCH (advertised) |
| `maxHttpBufferSize` | **100000** bytes (`1e5`) — max size of one inbound message; advertised as `maxPayload` | index.js:122 | MUST MATCH |
| `connectTimeout` | 45000 ms default — an Engine.IO connection that never sends a Socket.IO CONNECT packet is closed after this (`socket.io/dist/client.js:52-60`) | default | INCIDENTAL |
| `serveClient` | default **true** — the server serves `/socket.io/socket.io.js` (and `.min.js`, `.esm.min.js`, `.msgpack.min.js`, source maps). **The browser client loads `<script src="/socket.io/socket.io.js">`** (`public/index.html:184`). | default | MUST MATCH for the browser client (or ship the bundle from `public/`) |
| `allowEIO3` | false — `EIO=3` clients get HTTP 400 `{"code":5,"message":"Unsupported protocol version"}` | engine.io default | INCIDENTAL |
| `perMessageDeflate` | disabled (engine.io 6 default) | default | INCIDENTAL |
| `httpCompression` | enabled for polling responses (default `{threshold:1024}`) | default | INCIDENTAL |
| `upgradeTimeout` | 10000 ms | default | INCIDENTAL |
| `cookie` | false (no `io` cookie) | default | INCIDENTAL |
| `connectionStateRecovery` | off | default | INCIDENTAL (no `pid` in the CONNECT reply) |
| Adapter | in-memory; if `REDIS_URL` is set, `@socket.io/redis-adapter` on a `redis` pub/sub pair (`index.js:125-133`). RoomManager is process-local, so multi-node is **not** functional (CLAUDE.md §7.4). | | INCIDENTAL |

Socket.IO attaches to the `http.Server` and intercepts every request whose path starts with
`/socket.io/` **before** Express sees it; the Express `httpMetricsMiddleware` therefore never counts
polling requests (INCIDENTAL).

Only the default namespace `/` is used. A CONNECT to any other namespace is answered with
`44/<nsp>,{"message":"Invalid namespace"}` (`socket.io/dist/client.js:74-88`).

---

## 2. Handshake authentication (`sock:378-391`)

```js
io.use(async (socket, next) => {
  try {
    const token = socket.handshake.auth?.token ?? socket.handshake.query?.token;
    const claims = verifyToken(token);
    const user = await findById(claims.sub);
    if (!user) return next(new Error('unknown_user'));
    socket.data.user = user;
    return next();
  } catch (error) {
    return next(new Error(error.code ?? 'unauthorized'));
  }
});
```

Rules, in order:

1. **Token source** (MUST MATCH): the `token` field of the Socket.IO CONNECT packet's auth object
   (`40{"token":"…"}`), falling back (`??`) to a `token` query-string parameter on the Engine.IO
   handshake URL (`/socket.io/?EIO=4&transport=websocket&token=…`). All three shipped clients use the
   auth object.
2. `verifyToken` (`auth/tokens.js:14-21`): falsy token → `AuthError('missing_token', 'A session
   token is required')`; otherwise `jwt.verify(token, config.jwt.secret)` (HS256, `jsonwebtoken`
   defaults; claims `{sub, provider, name, iat, exp}` issued with `expiresIn: '30d'`,
   `tokens.js:6-12`). Any verify failure (bad signature, expired, malformed) →
   `AuthError('invalid_session', 'Session token rejected: <jwt message>')`.
3. `findById(claims.sub)` — `SELECT * FROM users WHERE id = $1` (`db/users.js:67-70`). Row missing →
   `next(new Error('unknown_user'))`.
4. Success: `socket.data.user = user` (the **public user object**, §3.1, frozen at handshake time —
   it is never refreshed; handlers that need fresh chips re-query).
5. Any thrown error → `next(new Error(error.code ?? 'unauthorized'))`.

**What the client sees** (MUST MATCH): a Socket.IO CONNECT_ERROR packet whose `message` is the
code string: `44{"message":"missing_token"}`, `44{"message":"invalid_session"}`,
`44{"message":"unknown_user"}`, or `44{"message":"unauthorized"}`. The human-readable
`AuthError.message` never reaches the socket client. `data` is absent (the error has no `.data`;
`socket.io/dist/namespace.js:229-238` encodes `{message: err.message, data: err.data}` and
`JSON.stringify` drops the undefined `data`).

Trap: a `pg` error thrown by `findById` has a `.code` (SQLSTATE such as `'57P01'`), so a DB outage
during handshake produces `44{"message":"57P01"}`, not `unauthorized`. INCIDENTAL but worth knowing.

Test assertions: `socketProtocol.test.js:189-202` (`/invalid_session|unauthorized|unknown_user/`),
`integration.test.js:225-230` (`/invalid_session|unauthorized/`), browser `client.js:192-200`
matches `/invalid_session|unknown_user|unauthorized/` to drop its stored token.

---

## 3. Connection sequence (`sock:393-446`)

On `connection` (i.e. after the middleware passed and the CONNECT reply `40{"sid":…}` was sent):

1. Metrics: `game_connections_total` +1, `game_connected_sockets` +1, `liveSockets += 1`, and
   `game_connected_sockets_peak` set when a new high-water mark is reached (`sock:396-402`).
2. **One live socket per user** (`sock:406-412`, MUST MATCH):
   `previous = userSockets.get(user.id)`; if it exists and `previous.id !== socket.id`:
   - `game_session_replaced_total` +1;
   - emit to the previous socket `session:replaced` `{"message":"Signed in from another device"}`;
   - `previous.disconnect(true)` — the server sends a Socket.IO DISCONNECT `41` to it and closes
     the Engine.IO connection. **This runs the previous socket's `disconnect` handler
     synchronously with reason `'server namespace disconnect'`** (`socket.io/dist/socket.js
     disconnect()/_onclose()`; `client.js _disconnect()`), i.e. *before* line 412 executes. See
     §10.2 for the consequences (seat marked disconnected, grace timer armed, then immediately
     cancelled at step 3 and counted as a `seat_held` reconnect).
   - `userSockets.set(user.id, socket)`.
3. Grace-timer cancel (`sock:415-420`): if `pendingRemovals` has a timer for this user, clear it,
   delete it, `game_reconnects_total{kind="seat_held"}` +1.
4. Resume resolution (`sock:425-428`):
   `existingTable = rooms.getTableForPlayer(user.id)`;
   `resume = existingTable ? null : takeResumeOffer(user.id)`;
   if `existingTable` → `resumeOffers.delete(user.id)`;
   if `resume` → `game_reconnects_total{kind="offer"}` +1.
5. Emit `session:ready` (§3.2).
6. If `existingTable` (seat still held) (`sock:436-444`), timed into
   `game_join_duration_seconds{route="resume"}`: `wireTable(existingTable)`;
   `trackRoom(existingTable.id, socket)`; `existingTable.setConnected(user.id, true, socket.id)` —
   this emits the table's `state` event, so **every viewer including this socket receives
   `room:state` first**; then this socket gets `room:joined` (same `serializeFor` shape); then
   `chat:history`.
   Resulting order on the resuming socket (MUST MATCH the set; ordering is what the Node server
   does): `session:ready`, `room:state`, `room:joined`, `chat:history`.
7. Per-socket rate limiter created: `createRateLimiter({limit: 30, windowMs: 5000})` (`sock:446`).
8. Handlers registered (§5–§7); `ping:rtt` (§7.4); `disconnect` (§10).

### 3.1 The public `user` object (`db/users.js:21-60`)

Produced by `publicUser(row)` from a `users` row. Key order and types (MUST MATCH — Flutter
`User.fromJson`, browser `session:ready` handler and tests read it):

```jsonc
{
  "id": "<uuid string>",
  "provider": "google" | "facebook" | "guest",
  "displayName": "<string>",
  "email": "<string>" | null,
  "avatarUrl": "<avatar_choice || avatar_url>",   // string, or null when both null ("||" so "" falls through to avatar_url)
  "providerAvatarUrl": "<avatar_url>" | null,
  "avatarChoice": "<avatar_choice>" | null,
  "chips": <integer>,                              // BIGINT parsed to a JS number
  "handsPlayed": <integer>,
  "handsWon": <integer>,
  "handsLost": <integer>,                          // row.hands_lost ?? 0
  "handsLeftMid": <integer>,                       // row.hands_left_mid ?? 0
  "totalWinnings": <integer>,                      // row.total_winnings ?? 0
  "biggestPot": <integer>,
  "rewards": {
    "milestoneAvailable": <bool>,                  // floor(handsPlayed/25)*25 > (milestone_claimed ?? 0)
    "milestoneAt": <integer>,                      // floor(handsPlayed/25)*25
    "milestoneReward": 25000,
    "milestoneEvery": 25,
    "handsToNextMilestone": <integer>,             // 25 - (handsPlayed % 25)  (says 25, not 0, at an exact multiple)
    "bonusReadyAt": <epoch ms integer>,            // row.next_bonus_at ?? 0
    "bonusAvailable": <bool>,                      // Date.now() >= bonusReadyAt
    "bonusReward": 10000,
    "bonusIntervalMs": 14400000
  },
  "createdAt": <epoch ms>,
  "lastLoginAt": <epoch ms>
}
```

### 3.2 `session:ready` payload (`sock:430-434`, `sock:733-745`)

```jsonc
{
  "user": <public user, §3.1>,
  "config": <publicGameConfig(), below>,
  "resume": { "roomId": "<uuid>", "code": "<6 chars>", "category": "seen"|"blind", "bootAmount": <int> }   // ONLY when an offer stands; otherwise the key is ABSENT
}
```

`publicGameConfig()` (`sock:733-745`) — key order:

```jsonc
{
  "maxPlayers": config.game.maxPlayers,            // 5
  "minPlayers": config.game.minPlayers,            // 2
  "bootAmount": config.game.bootAmount,            // 200
  "turnTimeoutMs": config.game.turnTimeoutMs,      // 25000
  "welcomeChips": config.game.welcomeChips,        // 200000
  "maxBetRounds": config.game.maxBetRounds,        // 20 (the GLOBAL default, not the per-category value)
  "sideshowTimeoutMs": config.game.sideshowTimeoutMs,   // 6000
  "sideshowMinPlayers": config.game.sideshowMinPlayers, // 3
  // ...RoomManager.lobbyOptions()  (roomManager.js:196-223):
  "categories": ["seen", "blind"],                 // fixed order: SEEN then BLIND
  "stakes": [200, 5000],                           // config.game.tableStakes (may be [] in tests)
  "tables": [                                      // config.game.lobbyTables in env order
    { "category": "seen",  "bootAmount": 200,  "maxPot": 1200000, "maxBlindMoves": 4 },
    { "category": "blind", "bootAmount": 200,  "maxPot": 0,       "maxBlindMoves": 4 },
    { "category": "blind", "bootAmount": 5000, "maxPot": 0,       "maxBlindMoves": 4 }
  ],                                               // maxPot = seenMaxPot for seen, 0 for blind
  "entryCapBoot": 200,
  "entryCapCategory": "blind",
  "entryCapMaxChips": 500000,
  "privateBoot": 200,
  "privateMaxPot": 500000
}
```

Flutter reads `maxPlayers, minPlayers, bootAmount, turnTimeoutMs, sideshowTimeoutMs, categories,
stakes, tables, privateBoot, privateMaxPot, entryCapBoot, entryCapCategory, entryCapMaxChips`
(`dtos.dart:271-290`); the browser reads `stakes, tables, categories, privateBoot, privateMaxPot`
(`client.js:203-227`); tests assert `config.categories` deep-equals `['seen','blind']` and
`config.stakes` is an array (`integration.test.js:516-518`). All MUST MATCH.

### 3.3 `takeResumeOffer(userId)` (`sock:138-151`)

```
offer = resumeOffers.get(userId); if none → null
resumeOffers.delete(userId)                       // offered ONCE, valid or not
if Date.now() - offer.at > config.game.resumeOfferMs (600000) → null
table = rooms.getTable(offer.roomId); if !table || table.isFull → null
return { roomId: table.id, code: table.code, category: table.category, bootAmount: table.config.bootAmount }
```

The stored offer is only `{roomId, at}` (`sock:710`); `code/category/bootAmount` are read from the
live table when the offer is taken. The Flutter client answers an offer by sending
`room:joinCode {code}` itself (`game_state.dart:225-232`); the server does not auto-seat.

---

## 4. The `guard` wrapper (`sock:453-478`)

Every inbound event except `ping:rtt` is registered through `handle(event, handler)`, which wraps
`handler` in `guard`:

```
socketMessagesTotal.inc({event})
if (!rateLimiter()):
    socketErrorsTotal.inc({code:'rate_limited'})
    emit game:error {code:'rate_limited', message:'Slow down'}      ← emitted FIRST
    if ack is a function: ack({ok:false, code:'rate_limited', message:'Slow down'})
    return
try:
    result = await handler(payload ?? {})          // null/undefined payload → {}
    if ack: ack({ok:true, ...result})              // result spread AFTER ok
catch error:
    code = safeLabel(error.code ?? 'internal_error', KNOWN_ERROR_CODES)   // metrics only
    socketErrorsTotal.inc({code}); if event === 'game:action': invalidMovesTotal.inc({code})
    if ack: ack({ok:false, code: error.code ?? 'internal_error', message: error.message})
    fail(socket, error)                             // → game:error, see below
```

MUST MATCH:

- **Rate limit**: fixed window, per socket, **30 requests per 5000 ms**, counting every guarded
  event (chat included; `ping:rtt` excluded). `createRateLimiter` (`sock:748-760`): on each call,
  if `now - windowStart >= windowMs` then `windowStart = now; count = 0`; then `count += 1`; allowed
  iff `count <= limit`. So the 31st request inside a window is refused; the window is anchored to
  the first request after it lapsed (not sliding).
- Rate-limited requests **are acked** (`{ok:false, code:'rate_limited', message:'Slow down'}`) and
  also get `game:error` — CLAUDE.md §7.1's "no ack" note is stale; `sock:460` acks.
- **Success ack**: `{ ok: true, ...result }`. If the handler returns `{}` the ack is `{"ok":true}`.
  If a result key were named `ok` it would override — none does.
- **Failure ack**: `{ ok: false, code, message }` where `code = error.code ?? 'internal_error'` and
  `message = error.message` **raw** — for a non-`GameError` (e.g. a `TypeError` or a `pg` error) the
  ack carries the raw JS/PG message and, for pg, the SQLSTATE as `code`. Meanwhile `fail()` emits
  `game:error {code:'internal_error', message:'Something went wrong'}` for anything that is not a
  `GameError` and logs it (`sock:201-208`). For a `GameError`, `game:error {code, message}` mirrors
  the ack. So **a refusal reaches the client twice**: ack (first) then `game:error` (both are
  written in that order: `ack(...)` on line 471 precedes `fail()` on 473).
- The handler receives **`payload ?? {}`** and destructures it. Non-object payloads (`42`,
  `'string'`, `[]`, `[1,2]`, `true`) are destructured as JS primitives/arrays: every named field is
  `undefined`, so they behave like `{}` (this is what makes `room:quickJoin` with payload `null` a
  legitimate default-stake join, `invalidMoves.test.js:328-331`).
- Unknown event names are ignored by Socket.IO — **no ack is ever sent**, so a client awaiting one
  hangs (Flutter `request()` times out after 8 s with `{ok:false, message:'The server did not
  answer'}`, `game_connection.dart:258-261`).
- If the client sends an event with an ack id, Socket.IO passes the ack function as the **last**
  argument. Handlers are `(payload, ack)`: a client that sends two data args (`["ev", a, b]` with an
  ack id) gets `ack = b` (not a function) and never receives the ack. INCIDENTAL.

`KNOWN_ERROR_CODES` (`sock:55-101`) exists only to fold metric labels; the ack always carries the
real code. INCIDENTAL, but `metrics.test.js:613-615` asserts every `code` label is `^[a-z][a-z0-9_]*$`.

---

## 5. Inbound events — lobby / rooms

All acks below are the `result` spread after `ok:true`. Every handler first re-reads the user from
the DB (`fresh = await findById(user.id)`) for the join family so chip balances are current.

### 5.1 `lobby:list` (`sock:482-485`)

- Payload `{category?}`; `category ?? null`. `rooms.listTables({category})` returns public tables
  only (`includePrivate` false), filtered by `!category || table.category === category` — so any
  category string other than an existing one yields `[]`; a non-string truthy value also yields `[]`
  (`roomManager.js:188-193`).
- Ack: `{ ok:true, tables: [summary…], options: lobbyOptions() }`. `summary()`
  (`table.js:1742-1753`): `{roomId, code, category, state, players, maxPlayers, bootAmount, pot}`
  (`pot = hand?.pot ?? 0`).
- No client sends this in production (tests + scratch only).

### 5.2 `room:quickJoin` (`sock:487-505`)

Payload `{bootAmount?, category?}`. Inside `timed(gameJoinDuration,{route:'quick_join'})`:

1. `fresh = await findById(user.id)`.
2. `rooms.quickJoin(fresh, { bootAmount: bootAmount ?? config.game.bootAmount, category })`
   (`roomManager.js:232-258`), checks **in this order**:
   1. `_assertNotSeated` → `already_in_room` "You are already seated at a table".
   2. `assertStakeAllowed(bootAmount)`: not an integer or `<= 0` → `invalid_stake` "That stake is
      not valid"; not in `config.game.tableStakes` (when non-empty) → `invalid_stake` "Stake must
      be one of: 200, 5000". Note `??` only replaces `null`/`undefined`: `0`, `-5`, `'lots'` all
      reach this check and are refused.
   3. `normalizeCategory(category)`: `'blind'` → blind, **anything else → `'seen'`**.
   4. `assertTableOffered(boot, category)`: when `config.game.lobbyTables` non-empty and no entry
      has both same `bootAmount` and `category` → `table_not_offered` "The lobby offers: seen 200,
      blind 200, blind 5000".
   5. `user.chips < bootAmount` → `insufficient_chips` "Not enough chips to join this table".
   6. `_assertUnderEntryCap` (`roomManager.js:372-383`): only when `entryCapMaxChips` truthy,
      `bootAmount === entryCapBoot` and `category === entryCapCategory`; `user.chips > cap` →
      `over_entry_cap` "Players with more than 500,000 chips cannot join this table"
      (`toLocaleString('en-US')` grouping).
   7. Candidate = public, not full, same `bootAmount` and `category`, sorted by `playerCount`
      descending (stable sort → ties keep `Map` insertion = creation order); else `createTable`.
   8. `join(table, user)` → `_assertNotSeated` again, `table.addPlayer({userId, displayName,
      avatarUrl, chips, socketId: null})` (may throw `already_seated` / `table_full`,
      `table.js:148-149`), `playerRooms.set`.
3. `wireTable(seated)` (no-op if wired), `trackRoom(seated.id, socket)`,
   `seated.setConnected(user.id, true, socket.id)` (emits `state` → **`room:state` to every viewer
   including the joiner**), `emitTo(socket, 'room:joined', serializeFor(user.id))`.
4. After the timed block: `sendChatHistory(table, socket)` → `chat:history`; `broadcastState(table)`
   → `room:state` to all viewers again.
5. Ack `{ ok:true, roomId: table.id, code: table.code, category: table.category }`.

Observable order on the joining socket (MUST MATCH set; order is what Node does):
`room:state`, `room:joined`, `chat:history`, `room:state`, then the ack `43…`. Existing viewers get
(from `addPlayer`, `table.js:181-189`): `chat:message` (system "X joined the table"), possibly a
`room:state` for the STARTING transition, then `room:state` ×2.

### 5.3 `room:create` (`sock:507-523`)

Payload `{bootAmount?, isPrivate = true, category?}` — **`isPrivate` defaults to `true` only when
undefined**; `null`/`false` create a **public** table. Inside `timed(...,{route:'create'})`:

1. `fresh = await findById(user.id)`.
2. `rooms.createTable({ bootAmount: bootAmount ?? config.game.bootAmount, isPrivate, category })`
   → `_createTable` (`roomManager.js:100-169`): `id = uuid()`, category normalised, **`boot =
   isPrivate ? config.game.privateBoot : bootAmount`** — no stake validation at all on this route
   (a public `room:create {isPrivate:false, bootAmount: 7}` opens a public table at boot 7; a
   non-integer `bootAmount` is stored verbatim). Seen rules `{maxRaiseSteps: 2, maxBetRounds: 7,
   maxPot: 1200000}` or blind rules `{maxRaiseSteps: 0, maxBetRounds: 0, potLimitMultiplier: 0}`;
   private adds `{maxPot: 500000, maxRaiseSteps: 2}`. `code = roomCode()` (6 chars from
   `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, `util/ids.js:150-157`, no collision check). Emits
   `tableCreated` → `wireTable`. Timed into `game_creation_duration_seconds`.
3. `wireTable(created)`; **`rooms.join(created, fresh, socket.id)`** — `_assertNotSeated` →
   `already_in_room` for a seated player (`invalidMoves.test.js:312-314`). **No chips-vs-boot check
   on this route**; an unfunded creator is swept out by `_sweepUnfunded` when a second player
   arrives (`table.js:681-696`).
4. `trackRoom`, `room:joined`. **No `setConnected`, no `broadcastState`** — the creator receives
   exactly `room:joined`, `chat:history`, then the ack. (`addPlayer`'s `state`/`chat` emits happen
   before `trackRoom`, so nobody receives them; `game_socket_emits_total{event="room:state"}` is
   still incremented once — INCIDENTAL.)
5. Ack `{ ok:true, roomId, code, category }`.

Flutter sends `{isPrivate: true, category: 'seen'}`; the browser sends `{category:'blind',
isPrivate:true}`; neither sends `bootAmount` (requirement 22).

### 5.4 `room:joinCode` (`sock:525-538`)

Payload `{code}`. Inside `timed(...,{route:'code'})`: `fresh = findById`; `rooms.joinByCode(fresh,
code)` (`roomManager.js:260-276`) checks in order: `already_in_room`; `getTableByCode` with
`String(code ?? '').toUpperCase()` compared to `table.code` (private tables included) →
`room_not_found` "No table with that code"; `table.isFull` → `table_full` "That table is full";
`chips < table.config.bootAmount` → `insufficient_chips`; entry cap **only for public tables**;
`join`. Then identical tail to quick-join: `wireTable`, `trackRoom`, `setConnected(true, socket.id)`,
`room:joined`, `chat:history`, `broadcastState`, ack `{roomId, code, category}`. Codes are
case-insensitive on input; an object code becomes `'[OBJECT OBJECT]'` → `room_not_found`.

### 5.5 `room:switch` (`sock:540-579`)

Payload ignored. Inside `timed(...,{route:'switch'})`:

1. `fresh = findById`. `leaving = rooms.getTableForPlayer(user.id)`; if set →
   **`untrackRoom(leaving.id, socket)` first** (so a `room:closed` from destroying the vacated table
   never reaches this socket).
2. `({from, table: target} = await rooms.switchTable(fresh))` (`roomManager.js:294-327`):
   `not_in_room` "You are not at a table"; `private_table` "A private table cannot be swapped for
   another"; target = public, not full, `id !== current.id`, same boot and category, fullest first;
   none → `no_other_table` "No other <category> table at this stake has a free seat right now".
   **No entry-cap check.** Then `await leave(user.id, 'moved')` (removePlayer with reason `'moved'`
   — if mid-hand this emits a `game:action` pack with `reason:'moved'` to the old room; `'moved'`
   skips consolidation) then `join(target, user)`.
3. On any error: if `leaving` still exists → `trackRoom(leaving.id, socket)` again; rethrow (ack
   `{ok:false, code, message}`).
4. Success: `wireTable(target)`, `trackRoom`, `target.setConnected(user.id, true, socket.id)`
   (→ `room:state`), `room:joined`.
5. After the timed block: `chat:history`; `broadcastState(target)`; `vacated =
   rooms.getTable(from.id)`; if alive `broadcastState(vacated)`.
6. Ack `{ ok:true, roomId, code, category }`.

**No `room:left` / `room:moved` is sent on a switch.** Flutter sets `switching = true` around the
request so an incidental `room:closed` cannot bounce it to the lobby (`game_state.dart:610-625`).

### 5.6 `room:leave` (`sock:581-591`)

Payload ignored. `table = getTableForPlayer`; if none → ack `{ok:true}` (result `{}`). Else
`roomId = table.id`; `await rooms.leave(user.id, 'left')` — **the leaving socket is still tracked
while this runs**, so it receives whatever the table emits during removal: `chat:message` (system
"X left the table"), `game:action` `{…, action:'pack', amount:0, reason:'left'}` if it was active
in a hand, possibly `game:handEnded` (last-standing), `room:state` with `you: null`, and, if the
table emptied, **`room:closed {roomId}`** from `tableDestroyed` (`sock:368-376`). Then
`untrackRoom` (no-op if already closed), `emitTo(socket,'room:left',{roomId})`,
`broadcastState(stillAlive)` if the table survives, ack `{ ok:true, roomId }`.

`rooms.leave` (`roomManager.js:345-363`): deletes `playerRooms` **before** awaiting
`table.removePlayer`; if `table.isEmpty` → `destroyTable`, else if reason !== `'moved'` →
`consolidateTables()` (which may emit `playerMoved`, §9.2).

---

## 6. Inbound events — gameplay

### 6.1 `game:action` (`sock:595-628`)

Payload `{action, amount?, actionId?}`. Checks in this exact order (each throws a `GameError` →
`{ok:false, code, message}` + `game:error`):

1. `VALID_ACTIONS.has(action)` where `VALID_ACTIONS = {'see','chaal','raise','pack','show',
   'sideshow'}` (`constants.js:126-133`); else `unknown_action` with message
   `` `Unknown action "${action}"` `` (string interpolation: `undefined` → `Unknown action
   "undefined"`, an object → `Unknown action "[object Object]"`). `'__proto__'` is refused (a `Set`
   lookup, not a property lookup).
2. `rooms.getTableForPlayer(user.id)` null → `not_in_room` "You are not at a table".
3. Amount typing: `parsed = (amount === undefined || amount === null) ? undefined : amount`; if
   `parsed !== undefined && (typeof parsed !== 'number' || !Number.isSafeInteger(parsed))` →
   `invalid_bet` "Bet amount must be a whole number". Refuses strings (`"100"`, `"1e3"`), booleans,
   arrays, objects, `1.5`, and anything beyond ±2^53−1. Negative integers and `0` pass this check
   and are refused later by the ladder. **This check runs for every action, including `pack`,
   `see`, `sideshow`** — `{action:'pack', amount:'x'}` is `invalid_bet`.
4. `id = (typeof actionId === 'string' && actionId.length > 0 && actionId.length <= 64) ? actionId
   : undefined` — anything else is silently dropped and the table generates a `uuid()` for the
   ledger row (`table.js:849`), which removes idempotency protection for that move. Length is
   JS string length (UTF-16 code units).
5. `result = await timed(moveDuration, {action}, () => table.act(user.id, action, {amount: parsed,
   actionId: id}))`; on success `movesTotal.inc({action})`.

`table.act` → `_act` (`table.js:924-970`) order: `no_hand` "No hand is in progress" → `not_seated`
"You are not at this table" → `not_in_hand` "You are not in this hand" (status !== `'active'`) →
`not_your_turn` "It is not your turn" for every action **except `see`** → dispatch. After a
successful move `seat.missedTurns = 0`.

Per-action results (the ack is `{ok:true, ...result}`), MUST MATCH:

| action | Table refusals (code → message) | `result` |
|---|---|---|
| `see` | `already_seen` "You have already seen your cards" | `{action:'see', auto:false}` |
| `chaal` / `raise` | `insufficient_chips` "Not enough chips to bet" (empty ladder); `invalid_bet` "Bet amount must be a whole number" (non-integer — unreachable after step 3); `invalid_bet` "That bet amount is not available" (not a rung); `invalid_bet` "A raise must be at least double the chaal" (`raise` with `requested < 2*steps[0]`); `invalid_bet` "That bet is not available" (`!amount`); `insufficient_chips` "Not enough chips for that bet"; then ledger refusals mapped by `_refusal` (`table.js:892-901`): `insufficient_chips` "Not enough chips for that bet", `duplicate_action` "That move was already applied", anything else `persist_failed` "The move could not be recorded, so nothing was changed" | `{action:'chaal'|'raise', amount:<int>, autoSeen:<bool>}` |
| `pack` | — | `{action:'pack', reason:'pack'}` |
| `show` | `show_unavailable` "A show needs exactly two players left"; `insufficient_chips` "Not enough chips to pay for the show" (cost null or unaffordable); ledger refusals as above | `{action:'show', amount:<cost>}` |
| `sideshow` | `sideshowBlockedReason` (`table.js:558-578`) in order `no_hand`, `not_in_hand`, `not_your_turn`, `sideshow_pending`, `already_asked`, `too_few_players`, `you_are_blind`, `no_neighbour`, `neighbour_is_blind`; messages (`table.js:1153-1161`): `sideshow_pending` "A sideshow is already in progress", `already_asked` "You have already asked for a sideshow this turn", `too_few_players` "A sideshow needs at least 3 players in the hand", `you_are_blind` "See your cards before asking for a sideshow", `neighbour_is_blind` "The player on your right has not seen their cards", `no_neighbour` "There is nobody on your right to ask", others "You cannot ask for a sideshow now" | `{action:'sideshow', toUserId:<id>}` |

When `amount` is omitted for `chaal`/`raise`, the table uses `options.chaal` / `options.raise`
(`table.js:1030-1031`); Flutter omits `amount` for `see`/`pack` and sends it for bets/show; the
browser sends `{action}` or `{action, amount}`; bots send `{action}` only.

DB coupling (MUST MATCH): the `actionId` string becomes `chip_ledger.action_id` for a `bet`/`show`
row (`ledger.js:97-103`), where it is UNIQUE; a Postgres `23505` whose detail/constraint mentions
`action_id` is classified `duplicate_action` (`ledger.js:48-56`). `invalidMoves.test.js:257-275`
asserts exactly one ledger row carries a replayed id.

### 6.2 `game:sideshowRespond` (`sock:636-640`)

Payload `{accept}`; `not_in_room` if unseated; `table.respondToSideshow(user.id, accept === true)`
(`table.js:1201-1210`): `no_sideshow` "There is no sideshow to answer" → `not_your_sideshow` "That
sideshow was not asked of you" → `_resolveSideshow(accept, accept ? 'accepted' : 'declined')`.
**Only the literal boolean `true` accepts**; `1`, `"true"`, `{}` decline. Ack
`{ok:true, accepted:<bool>, packedUserId:<id>|null}`.

### 6.3 `player:requestCards` (`sock:643-651`)

Payload ignored. `not_in_room` if unseated. `seat = table.findSeat(user.id)`; if no seat, or
`seat.isBlind`, or `seat.cards.length === 0` → ack `{ok:true, cards: []}` with **no** emit.
Otherwise `cards = table.serializeFor(user.id).you.cards`, emit `player:cards {roomId, cards}` to
this socket, ack `{ok:true, cards}`. Flutter wires but never calls it.

---

## 7. Inbound events — chat and ping

### 7.1 `chat:message` (`sock:655-670`)

A second limiter per socket: `createRateLimiter({limit: config.chat.rateLimit (5), windowMs:
config.chat.rateWindowMs (5000)})`. Handler order:

1. `not_in_room` "You are not at a table" if unseated (checked **before** the chat limiter, so
   unseated spam does not consume the chat allowance — but it does consume the general 30/5s one).
2. `chatLimiter()` false → `chat_rate_limited` "You are sending messages too quickly". **Every
   seated send counts, whether or not anything is posted** (blank text still consumes one).
3. `message = table.postChat(user.id, text)` (`table.js:199-212`): `not_in_room` "You are not at
   this table" if the seat vanished; `RoomChat.add` (`chat.js:26-44`) sanitises (§7.1.1); if the
   result is empty → returns `null` → ack `{ok:true}` (**no `messageId`**, nothing posted,
   `integration.test.js:701-714`); else appends (capped at `maxHistory` 100, oldest dropped) and
   the table emits `chat` → `chat:message` to the room (§8).
4. Ack `{ok:true, messageId: message.id}`.

#### 7.1.1 Sanitising (`chat.js:82-88`) — MUST MATCH

```js
String(text ?? '').replace(/[\p{C}]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, maxLength /*140*/)
```

- `String(x)`: numbers → digits (`12345` → `"12345"`, asserted `invalidMoves.test.js:392`),
  `true` → `"true"`, arrays → comma-joined, plain objects → `"[object Object]"` (posted as a real
  message).
- `\p{C}` with the `u` flag = Unicode General Category "Other" **including Cn (unassigned)**, i.e.
  Cc, Cf, Cs, Co, Cn → each replaced by a single space. Cf includes U+200C/U+200D (ZWNJ/ZWJ used in
  Indic conjuncts and emoji ZWJ sequences) — they are destroyed today.
- `\s` is JavaScript's Unicode whitespace class (`\t \n \v \f \r space U+00A0 U+1680 U+2000–200A
  U+2028 U+2029 U+202F U+205F U+3000 U+FEFF`) → runs collapse to one ASCII space.
- `.trim()` strips the same class from both ends.
- `.slice(0, 140)` counts **UTF-16 code units**, may split a surrogate pair (the lone surrogate is
  then JSON-encoded as `\udXXX`). Asserted length 140 for `'x'.repeat(5000)`
  (`invalidMoves.test.js:391`).

### 7.2 `chat:history` (inbound, `sock:673-678`)

`not_in_room` if unseated; re-sends `chat:history` (§8) and acks `{ok:true, count: <messages
length>}`. Only tests send it.

### 7.3 Chat message object (`chat.js:26-63`) — MUST MATCH

Player message: `{ "id": "<uuid>", "userId": "<id>", "displayName": "<seat displayName at join>",
"text": "<clean>", "at": <epoch ms> }` — **no `system` key**. System line: `{ "id", "userId": null,
"displayName": "Table", "text": "<text.slice(0,140)>", "at", "system": true }`. System texts:
`` `${displayName} joined the table` `` (`table.js:186`) and `` `${displayName} left the table` ``
(`table.js:245`). `socketProtocol.test.js:316` relies on `getBool(...,'system')` returning its
`false` fallback for a player message (key absent).

### 7.4 `ping:rtt` (`sock:680-683`) — unguarded

```js
socket.on('ping:rtt', (sentAt, ack) => { socketMessagesTotal.inc({event:'ping:rtt'}); if (typeof ack === 'function') ack({ sentAt, serverTime: Date.now() }); });
```

Not rate limited, no `ok` field, echoes `sentAt` verbatim (any JSON value, or absent if the client
sent none — `{"serverTime":…}` only). No shipped client sends it.

---

## 8. Outbound events — catalogue

Three emit helpers (`sock:172-185`): `emitTo(socket, event, payload)`, `emitToRoom(roomId, …)` =
`io.to(roomId).emit`, `emitToUser(userId, …)` via `userSockets`. Each increments
`game_socket_emits_total{event}` **once per call** (a room broadcast counts once). Two places emit
raw `socket.emit` and count manually: `broadcastState` (`sock:192-199`) and the per-socket
`player:hand` / `game:sideshowReveal` loops; `room:closed` is counted once only if there are viewers
(`sock:370`). INCIDENTAL except the counter names (metrics tests).

| Event | Audience | Payload (exact keys, in order) | Source |
|---|---|---|---|
| `session:ready` | socket | `{user, config, resume?}` §3.2 | `sock:430-434` |
| `session:replaced` | the *previous* socket of the same user | `{"message":"Signed in from another device"}` | `sock:409` |
| `room:joined` | socket | `serializeFor(viewer)` §8.1 | quick-join/create/joinCode/switch/resume/moved |
| `room:state` | **each viewer separately**, own redaction | `serializeFor(viewer)` | `broadcastState`, on every table `state` event |
| `room:moved` | moved player's socket | `{fromRoomId, toRoomId, code, message:"Moved to a table with other players waiting."}` — **no `state`** | `sock:357-362` |
| `room:left` | socket | `{roomId}` | `sock:587` |
| `room:closed` | every socket still tracked on the destroyed room | `{roomId}` | `sock:368-376` |
| `room:kicked` | kicked user's current socket | `{roomId, reason, message}`; `reason` ∈ `'idle'` (message `` `Left the table after ${missedTurns} missed turns` ``) or `'insufficient_chips'` (message `You don't have enough coins to remain in this table`) | `sock:239`, `table.js:654,693,504` |
| `game:handStarted` | room | `{handId, handNo, dealerSeat, bootAmount, pot, stake, participants:[userId…], roomId}` | `table.js:471-479`, `sock:250` |
| `player:hand` | each socket in the room | `{roomId, dealt:true, cardsHidden:true}` | `sock:253-256` |
| `player:cards` | owner only (`emitToUser`) | `{roomId, cards:["As","Td","7h"]}` — 2-char codes rank `2-9 T J Q K A` + suit `s h d c` | `sock:259-261`, `deck.js:14` |
| `game:turn` | room | `{roomId, userId, seatIndex, deadline, timeoutMs}` (no options) | `sock:263-270` |
| `game:yourTurn` | player on turn (`emitToUser`) | `{roomId, deadline, timeoutMs, options}` §8.2 | `sock:272-277` |
| `game:action` | room | `{userId, action, amount, pot, stake, [reason], [auto], roomId}` — `see`: `amount:0, auto:<bool>`; `pack`: `amount:0, reason:<'pack'|'timeout'|'sideshow'|leave reason 'left'|'disconnected'|'moved'|'idle'|'insufficient_chips'>`; `chaal`/`raise`/`show`: `amount:<int>`, neither extra key | `table.js:982-989, 1065-1071, 1104-1111, 1306-1312, 257-264`; `sock:280-284` |
| `game:sideshowRequested` | room | `{fromUserId, fromName, fromSeat, toUserId, toName, toSeat, expiresAt, timeoutMs, roomId}` | `table.js:1185-1194` |
| `game:sideshowReveal` | **the two participants only** (asker, asked) | `{roomId, reveal:{reason, packedUserId, hands:[{userId, displayName, cards, handName}, {…}]}}` asker first | `table.js:1244-1262`, `sock:295-300` |
| `game:sideshowResolved` | room | `{fromUserId, toUserId, accepted, reason, packedUserId, roomId}`; `reason` ∈ `'accepted'|'declined'|'timeout'|'left'`; `packedUserId` null unless accepted | `table.js:1268-1274` |
| `game:showdown` | room | `{reveals:[{userId, seatIndex, cards:[3 codes], handName, category:<0-5>, won}], reason, roomId}` | `table.js:1360-1369` |
| `game:handEnded` | room | `{handId, handNo, winnerId, winnerName, pot, reason, reveals, summary:[{userId, displayName, seatIndex, contributed, status, sawCards, cards:[…]|null}], nextHandAt, roomId}`; `reason` ∈ `last_standing|show|forced_showdown|all_left|pot_limit`; `winnerId` may be `null` (ALL_LEFT with no departure), `winnerName` may be `null` | `table.js:1509-1519` |
| `chat:message` | room | `{…message (§7.3), roomId}` | `sock:326-330` |
| `chat:history` | socket | `{roomId, messages:[message…]}` oldest first, ≤100, per-message objects **without** `roomId` | `sock:334-339` |
| `game:error` | socket | `{code, message}` | `sock:201-208, 457` |

Hand names (`handRank.js:16-23`) are English: `High Card`, `Pair`, `Color`, `Sequence`, `Pure
Sequence`, `Trail`; `category` is the integer 0–5. MUST MATCH (Flutter shows them untranslated).

### 8.1 `serializeFor(viewerId)` (`table.js:1642-1739`) — MUST MATCH, including redaction

```jsonc
{
  "roomId": "<uuid>", "code": "<6>", "category": "seen"|"blind",
  "chipsHidden": <category === 'blind'>,
  "state": "waiting"|"starting"|"betting"|"showdown",
  "handNo": <int>, "dealerSeat": <int, -1 before first hand>,
  "maxPlayers": 5, "minPlayers": 2, "bootAmount": <int>, "turnTimeoutMs": 25000,
  "startsAt": <epoch ms> | null,           // this.startsAt ?? null (undefined before the first countdown → null)
  "pot": <hand?.pot ?? 0>,
  "maxPot": <int, 0 = uncapped>,
  "stake": <hand?.stake ?? bootAmount>,
  "round": <hand?.round ?? 0>,
  "sideshow": { "fromUserId", "fromSeat", "toUserId", "toSeat", "expiresAt" } | null,   // never cards
  "turn": { "seatIndex": <int>, "userId": <id|null>, "deadline": <ms|null> } | null,    // null when no hand
  "you": {                                  // null when the viewer is not seated
    "seatIndex", "chips": <int>, "status", "isBlind": <bool>,
    "blindMovesLeft": <isBlind ? max(0, maxBlindMoves - blindMoves) : 0>,
    "contributed": <int>, "missedTurns": <int>, "maxMissedTurns": 3,
    "cards": <isBlind ? [] : ["As","Kd","7c"]>,
    "options": <turnOptions(viewer) when hand && turnSeat === viewer.seatIndex && status === 'active', else null>
  } | null,
  "seats": [                               // exactly maxPlayers entries, index = seatIndex
    { "seatIndex": i, "status": "empty" },   // empty seat: ONLY these two keys
    { "seatIndex", "userId", "displayName", "avatarUrl": <string|null>,
      "chips": <int | null>,                 // null (NOT 0) for other players on a blind table
      "status", "isBlind", "lastBet": <int>, "lastAction": <"chaal"|"raise"|"pack"|null>,
      "contributed", "connected": <bool>, "cardCount": <0|3> }
  ]
}
```

Redaction rules that clients/tests depend on: other seats never carry `cards` (only `cardCount`);
`you.cards` is `[]` while blind; blind-table others' `chips` is `null` and `chipsHidden` is true
(`integration.test.js:479-510`, `categories.test.js`); `missedTurns/maxMissedTurns/options` appear
only under `you`; `sideshow` never carries cards.

### 8.2 `turnOptions(seat)` (`table.js:806-831`) — carried by `you.options` and `game:yourTurn`

```jsonc
{ "canSee": <isBlind>, "canSideshow": <bool>, "sideshowWith": <displayName|null>,
  "chaal": <int|null>, "raise": <int|null>, "raiseSteps": [<int>…], "maxBet": <int|null>,
  "show": <int|null>,   // only with exactly 2 active seats and affordable; else null
  "canPack": true, "isBlind": <bool>, "currentStake": <int>, "chips": <int>, "pot": <int> }
```

Flutter derives its whole action bar from `you.options` in `room:state` and never listens to
`game:yourTurn`/`game:turn`; bots and the browser act on `game:yourTurn.options`
(`bot.js:151-154`, `client.js:290`). Changing either breaks a client.

---

## 9. `wireTable` and the RoomManager events (`sock:210-376`)

`wireTable(table)` is idempotent via a `table._wired` flag; it is called on `tableCreated` and
defensively in every join path. Listener mapping (Table event → socket emits → metrics):

| Table event | Emits | Metrics |
|---|---|---|
| `state` | `broadcastState(table)`: `socket.emit('room:state', table.serializeFor(socket.data.user.id))` for every socket in `roomSockets[table.id]`, timed as one `game_state_update_duration_seconds` observation | `game_socket_emits_total{event="room:state"}` +1 per broadcast |
| `kick {userId, displayName, reason, message}` | async: `if (!rooms.getTableForPlayer(userId)) return;` `await rooms.leave(userId, reason)` (log + return on error); `emitToUser(userId,'room:kicked',{roomId: table.id, reason, message})`; `untrackRoom(table.id, socket)` if the user has a socket; `broadcastState(rooms.getTable(table.id))` if still alive | `game_kicks_total{reason}` (folded to `idle|insufficient_chips|unfunded|disconnected|other`) |
| `handStarted` | `emitToRoom('game:handStarted', {...payload, roomId})`; then `player:hand {roomId, dealt:true, cardsHidden:true}` to each socket in the room | `game_games_started_total{category}`; `game_socket_emits_total{event="player:hand"}` +1 |
| `cards {userId, cards}` | `emitToUser(userId,'player:cards',{roomId, cards})` | emits counter |
| `turn {userId, seatIndex, deadline, timeoutMs, options}` | `game:turn` to room (without `options`); `game:yourTurn {roomId, deadline, timeoutMs, options}` to the user | emits counter ×2 |
| `action` | `game:action {...payload, roomId}` to room | `game_turn_timeouts_total` +1 when `payload.reason === 'timeout'` |
| `sideshowRequested` / `sideshowResolved` | `{...payload, roomId}` to room | emits counter |
| `sideshowReveal {userIds, reveal}` | `game:sideshowReveal {roomId, reveal}` to each `userSockets.get(userId)` that exists | `game_socket_emits_total{event="game:sideshowReveal"}` +1 |
| `showdown` | `game:showdown {...payload, roomId}` to room | emits counter |
| `handEnded` | `game:handEnded {...payload, roomId}` to room | `reason === 'all_left'` → `game_games_abandoned_total{category}`; else `game_games_completed_total{category, reason}`; `winnerId && isFinite(pot) && pot > 0` → `game_pot_settled_chips_total += pot` |
| `chat message` | if message falsy return; `chat:message {...message, roomId}` to room | `game_chat_messages_total` +1 (system lines included) |

Listeners not consumed here: `seatUpdated` (nobody listens), `persistError`/`error` (RoomManager
logs, `roomManager.js:154-156`).

### 9.1 `tableCreated` → `wireTable` (`sock:341`).

### 9.2 `playerMoved {userId, fromRoomId, toRoomId}` (`sock:347-366`, requirement 24)

Emitted by `RoomManager._movePlayer` (`roomManager.js:456-488`) during consolidation. Handler:
`socket = userSockets.get(userId)`, `target = rooms.getTable(toRoomId)`; return if either missing.
Then `untrackRoom(fromRoomId, socket)`, `wireTable(target)`, `trackRoom(toRoomId, socket)`,
`target.setConnected(userId, true, socket.id)` (→ `room:state` to target viewers incl. the mover),
`room:moved`, `room:joined`, `chat:history`, `broadcastState(target)`.

Because `_movePlayer` removes the player from the source, joins the target, and **destroys the
empty source (emitting `tableDestroyed`) before emitting `playerMoved`**, and the mover's socket is
still tracked on the source until the handler above runs, the mover observes, in order:
`chat:message` (system "X left the table", old room), `room:state` (old room, `you: null`),
`room:closed {roomId: old}`, then `room:state` (new), `room:moved`, `room:joined`, `chat:history`,
`room:state` (new). Flutter treats `room:closed` as `onLeft` (lobby unless `switching`), then the
following snapshot puts it back on the table — an existing flicker, not a port target. Flag rather
than fix.

### 9.3 `tableDestroyed roomId` (`sock:368-376`)

`viewers = roomSockets.get(roomId) ?? ∅`; if non-empty count one `room:closed` emit; for each
viewer `socket.emit('room:closed', {roomId})` and `socket.leave(roomId)`;
`roomSockets.delete(roomId)`.

### 9.4 Room tracking (`sock:153-167`)

`roomSockets: Map<roomId, Set<socket>>` mirrors Socket.IO rooms: `trackRoom` adds to the set and
`socket.join(roomId)`; `untrackRoom` removes, deletes an empty set, `socket.leave(roomId)`.
`broadcastState` iterates the **set** (per-viewer payloads); `emitToRoom` uses the **Socket.IO
room** (one payload). Both must stay in step. A socket is tracked on at most one room at a time by
construction, but nothing enforces it.

---

## 10. Disconnect handling (`sock:687-725`)

On Socket.IO `disconnect(reason)`:

1. `game_connected_sockets` −1; `liveSockets = max(0, liveSockets-1)`;
   `game_disconnections_total{reason}` with reason folded into `KNOWN_DISCONNECT_REASONS =
   {'transport close','transport error','ping timeout','client namespace disconnect','server
   namespace disconnect','forced close','server shutting down'}` else `other` (e.g. `'parse
   error'`). `metrics.test.js:415-417` asserts `^[a-z][a-z _]*$`.
2. `if (userSockets.get(user.id) === socket) userSockets.delete(user.id)` — guards against a
   stale socket clearing a newer one. In the `session:replaced` path the condition is *true* at
   the instant it runs (the map still points at the old socket; the new one is stored a line
   later) — see §10.2 for the exact interleaving.
3. `table = rooms.getTableForPlayer(user.id)`; if none, return (no grace timer, no offer).
4. `untrackRoom(table.id, socket)`; `table.setConnected(user.id, false)` → seat `connected:false`,
   `disconnectedAt = now`, emits `state` → remaining viewers get `room:state`.
5. Arm the **grace timer** for `config.game.reconnectGraceMs` (default **60000**; `unref`'d):
   ```
   pendingRemovals.delete(user.id)
   if (userSockets.has(user.id)) return            // reconnected on another socket
   current = rooms.getTableForPlayer(user.id); if none return
   roomId = current.id
   resumeOffers.set(user.id, { roomId, at: Date.now() })    // BEFORE leaving
   try { await rooms.leave(user.id, 'disconnected') } catch { log; return }
   if (rooms.getTable(roomId)) broadcastState(it)
   ```
   `pendingRemovals.set(user.id, timer)`.

MUST MATCH: the seat is held for the grace period with `connected:false` visible to others and the
turn clock still running; the removal reason `'disconnected'` appears as `game:action
{action:'pack', reason:'disconnected'}` if the player was active in a hand; the resume offer is
created only on this path (voluntary `room:leave` and kicks never create one because the timer
finds no seat — `integration.test.js:792-814`).

### 10.1 Reconnect inside the grace window

A new connection for the same user: step 3 of §3 cancels the timer (`seat_held`); `existingTable`
is found → `room:joined` etc.; `setConnected(user.id, true, socket.id)` flips `connected` back.

### 10.2 `session:replaced` interleaving (exact)

`previous.disconnect(true)` (line 410) synchronously fires the old socket's `disconnect`
(`'server namespace disconnect'`). At that instant `userSockets.get(user.id) === previous` (line 412
has not run) → deleted. If seated: `untrackRoom(previous)`, `setConnected(false)` (a `room:state`
with `connected:false` goes to the other viewers), grace timer armed and stored in
`pendingRemovals`. Control returns to line 412: `userSockets.set(user.id, newSocket)`; line 415
finds the just-armed timer → cleared, `game_reconnects_total{kind="seat_held"}` +1; then
`existingTable` → normal resume (`room:state`/`room:joined`/`chat:history`) and
`setConnected(true)`. Net effect: a replacement is a seamless seat hand-over; the old socket
receives `session:replaced` then `41` then the TCP close.

---

## 11. Server → client message ordering summary (MUST MATCH as sets; ordering as implemented)

| Trigger | Socket(s) | Sequence |
|---|---|---|
| connect, not seated, no offer | self | `40{"sid"}` → `session:ready` |
| connect, seat held | self | `session:ready`, `room:state`, `room:joined`, `chat:history` (others: `room:state` with `connected:true`) |
| connect, offer stands | self | `session:ready` with `resume`; nothing else until the client joins |
| `room:quickJoin` / `room:joinCode` ok | self | `room:state`, `room:joined`, `chat:history`, `room:state`, ack |
| `room:create` ok | self | `room:joined`, `chat:history`, ack |
| `room:switch` ok | self | `room:state`(new), `room:joined`, `chat:history`, `room:state`(new), ack; old room viewers get removal traffic + `room:state` |
| `room:leave` (others remain) | self | [`chat:message` system, `game:action` pack if active, maybe `game:handEnded`, `room:state` with `you:null`], `room:left`, ack |
| `room:leave` (last player) | self | [`chat:message`, `room:state`], `room:closed`, `room:left`, ack |
| hand deals | room | `game:handStarted`, `player:hand` (each), `game:turn`, `game:yourTurn` (one), `room:state` (each) |
| `see` on turn | room / self | `player:cards` (self), `game:action{see}`, `game:turn`+`game:yourTurn` (re-issued with remaining `timeoutMs`), `room:state`; ack |
| bet | room | `game:action`, [`player:cards`+`game:action{see,auto:true}` if 4th blind move], `game:turn`/`game:yourTurn` or showdown, `room:state` ×2 (from `_advanceTurn` and `_bet`); ack |
| kick | self | [removal traffic while still tracked], `room:kicked`; others `room:state` |

Acks are always written **after** every emit the handler performed (Socket.IO preserves order on one
connection).

---

## 12. Metrics fed from this layer (names MUST MATCH `metrics.test.js`; label folding INCIDENTAL)

`game_connected_sockets`, `game_connected_sockets_peak`, `game_connections_total`,
`game_disconnections_total{reason}`, `game_reconnects_total{kind=seat_held|offer}`,
`game_socket_errors_total{code}`, `game_socket_messages_total{event}`,
`game_socket_emits_total{event}`, `game_session_replaced_total`, `game_games_started_total{category}`,
`game_games_completed_total{category,reason}`, `game_games_abandoned_total{category}`,
`game_moves_total{action}`, `game_invalid_moves_total{code}`, `game_turn_timeouts_total`,
`game_kicks_total{reason}`, `game_chat_messages_total`, `game_pot_settled_chips_total`,
histograms `game_move_processing_duration_seconds{action}`,
`game_join_duration_seconds{route=quick_join|code|create|switch|resume}`,
`game_state_update_duration_seconds` (buckets `0.001,0.005,0.01,0.025,0.05,0.1,0.25,0.5,1`). All
series carry default label `service="king-teenpatti"`. Label values must never contain ids, codes,
URLs or IPs (`metrics.test.js:580-625`); `event` labels must match `^[a-z]+:[a-zA-Z]+$`.

---

## 13. Config keys read by this layer (`config/index.js`)

| Key | Env | Default | Used at |
|---|---|---|---|
| `game.reconnectGraceMs` | `RECONNECT_GRACE_MS` | 60000 | `sock:719` |
| `game.resumeOfferMs` | `RESUME_OFFER_MS` | 600000 | `sock:142` |
| `game.bootAmount` | `BOOT_AMOUNT` | 200 | default boot for quickJoin/create |
| `chat.rateLimit` / `chat.rateWindowMs` | `CHAT_RATE_LIMIT` / `CHAT_RATE_WINDOW_MS` | 5 / 5000 | `sock:655-658` |
| `chat.maxLength` / `chat.maxHistory` | `CHAT_MAX_LENGTH` / `CHAT_MAX_HISTORY` | 140 / 100 | via table config |
| `corsOrigin` | `CORS_ORIGIN` | `'*'` | `index.js:116` |
| `jwt.secret` | `JWT_SECRET` | `dev-only-insecure-secret` (production throws) | `tokens.js` |
| everything in `publicGameConfig` | see §3.2 | | |

The general socket limiter (30/5000) is **hardcoded** (`sock:446`).

---

## 14. Raw wire framing (Engine.IO v4 + Socket.IO v5 over WebSocket)

Derived from `csharpJsonPort.js`, `socketProtocol.test.js`, and the socket.io/engine.io 4.8.3 /
6.6.10 sources in `server/node_modules`. Every frame below is a **text** WebSocket frame (UTF-8).
No binary attachments are ever used (packet types 45/46 never occur).

### 14.1 HTTP upgrade

```
GET /socket.io/?EIO=4&transport=websocket HTTP/1.1
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Version: 13
Sec-WebSocket-Key: …
```

Query parameters: `EIO=4` (required; `3` → HTTP 400 `{"code":5,"message":"Unsupported protocol
version"}`), `transport=websocket` (or `polling`), optional `t=<yeast id>` cache-buster (the JS
client adds it for polling only), optional `sid=<engine sid>` (only when upgrading an existing
polling session), optional `token=` (accepted by the handshake middleware, §2). Engine.IO HTTP
error bodies are JSON `{"code":<0-5>,"message":"Transport unknown"|"Session ID unknown"|"Bad
handshake method"|"Bad request"|"Forbidden"|"Unsupported protocol version"}` with status 400
(403 for code 4) (`engine.io/build/server.js:425-440,726-736`). Unknown transport → code 0.
`Origin` header is echoed per the `cors` option.

Asserted: `socketProtocol.test.js:71` builds exactly
`ws://127.0.0.1:<port>/socket.io/?EIO=4&transport=websocket`.

### 14.2 Engine.IO packet types (first character of every frame)

| Char | Type | Direction | Notes |
|---|---|---|---|
| `0` | OPEN | S→C | JSON handshake body follows (§14.3) |
| `1` | CLOSE | either | rarely sent; the server just closes the transport on `io.close()` |
| `2` | PING | **S→C** in v4 | sent every `pingInterval` (20000 ms) after OPEN; payload empty (`2`) |
| `3` | PONG | **C→S** | client must answer `3` within `pingTimeout` (25000 ms) or the server closes with reason `ping timeout` |
| `4` | MESSAGE | either | payload is a Socket.IO packet (§14.4) |
| `5` | UPGRADE | C→S | only in the polling→websocket upgrade (`2probe`/`3probe`/`5`) |
| `6` | NOOP | S→C | only on polling |

Asserted: `socketProtocol.test.js:181` — the first frame starts with `0{`; `:209-211` — receiving
`2` must produce `3`, receiving `3` produces nothing (the Unity port replies `'3'` to `'2'`).

Timing (MUST MATCH the advertised numbers; the schedule is engine.io's): the server arms
`pingInterval` after OPEN, sends `2`, then waits `pingTimeout` for `3`
(`engine.io/build/socket.js:142-163`). Clients (socket.io-client, socket_io_client) close on their
side if no `2` arrives within `pingInterval + pingTimeout` = 45000 ms
(`engine.io-client/build/cjs/socket.js:308-310`); the Unity port stored the same sum.

### 14.3 OPEN packet

```
0{"sid":"<20-char base64id>","upgrades":[],"pingInterval":20000,"pingTimeout":25000,"maxPayload":100000}
```

Exact key order `sid, upgrades, pingInterval, pingTimeout, maxPayload`
(`engine.io/build/socket.js:62-68`). `upgrades` is `[]` for a direct websocket connection and
`["websocket"]` for a polling handshake. `maxPayload` = `maxHttpBufferSize` = 100000: an inbound
message larger than this closes the connection. Asserted: `sid` non-empty and `pingInterval > 0`
(`socketProtocol.test.js:176-177`; the port parses `pingInterval`/`pingTimeout` with `getInt`).

The engine `sid` is a base64id (`engine.io/build/server.js:244-245`); its exact alphabet is
INCIDENTAL (clients treat it as opaque) but it must not contain `"`.

### 14.4 Socket.IO packets (inside an Engine.IO `4` frame → frames start with `4x`)

Encoding (`socket.io-parser` 4.2.4): `<type>[<attachments>-][<nsp>,][<ackId>][<json>]`. For the
default namespace `/` the nsp part is omitted. Types:

| Frame | Type | Direction | Shape |
|---|---|---|---|
| `40` | CONNECT | C→S | `40` alone, or `40<json auth>` — here **`40{"token":"<jwt>"}`**. Non-default nsp: `40/admin,{"token":…}`. |
| `40` | CONNECT (ack) | S→C | `40{"sid":"<socket id>"}` — a **new** base64id distinct from the engine sid; `pid` is omitted because connection-state recovery is off (`socket.io/dist/socket.js _onconnect`). Only sent after the async middleware has resolved. |
| `41` | DISCONNECT | either | `41` (server sends it on `socket.disconnect()`; a client sends it on `socket.disconnect()` → server reason `client namespace disconnect`) |
| `42` | EVENT | either | `42["event",payload]` without ack; **`42<ackId>["event",payload]`** with ack, e.g. `421["room:quickJoin",{"bootAmount":100}]` |
| `43` | ACK | either | `43<ackId>[<args…>]` — the server acks with exactly one arg: `431[{"ok":true,"roomId":"…","code":"ABC234","category":"seen"}]` |
| `44` | CONNECT_ERROR | S→C | `44{"message":"invalid_session"}` (§2) |
| `45`/`46` | BINARY_EVENT/ACK | — | never used |

Rules:

- Event and ack payloads are `JSON.stringify([eventName, ...args])`; a server event always has
  exactly one arg, so the array has two elements (`["room:left",{"roomId":"…"}]`). An event with
  no payload would be `42["room:left"]` — the port handles it (`socketProtocol.test.js:153-157`)
  but the server never sends one.
- Ack ids are integers assigned by the emitting side (socket.io-client starts at 0, the Unity port
  at 1); the server echoes the id it received. Ids are per-socket, never reused within a socket.
- The Unity-port scanner (`csharpJsonPort.js:261-280`) locates the payload by the first `[` after
  the type/ack-id and reads the **second** array element; the ack handler parses the integer before
  `[`. Strings containing `[`, `]`, `{`, `}`, escaped quotes and `\uXXXX` must remain valid JSON
  (asserted `:130-151, 333-362`).
- Server → client JSON is whatever `JSON.stringify` produces: no spaces, `\uXXXX` only for control
  characters and lone surrogates, non-ASCII emitted raw (UTF-8 on the wire). `csharpJsonPort.js`
  `Json.escape` (`:114-127`) is the client-side counterpart.
- Socket.IO reserved event names (`connect`, `connect_error`, `disconnect`, `disconnecting`,
  `newListener`, `removeListener`) cannot be emitted by a client; a packet that fails to decode
  closes the connection with reason `parse error`.
- The server never sends CONNECT until `io.use` finished (DB round-trip); a client that sends
  events before receiving `40{"sid"}` has them dropped by the client library, not by the server.

### 14.5 Example full session (bytes on the wire, `#` are comments)

```
S→C  0{"sid":"lv_VI97HAXpY6yYWAAAC","upgrades":[],"pingInterval":20000,"pingTimeout":25000,"maxPayload":100000}
C→S  40{"token":"eyJhbGciOiJIUzI1NiIs…"}
S→C  40{"sid":"Ww1JzH9pS0m1Z1ZfAAAD"}
S→C  42["session:ready",{"user":{…},"config":{…}}]
C→S  420["room:quickJoin",{"bootAmount":200,"category":"blind"}]
S→C  42["room:state",{…}]
S→C  42["room:joined",{…}]
S→C  42["chat:history",{"roomId":"…","messages":[…]}]
S→C  42["room:state",{…}]
S→C  430[{"ok":true,"roomId":"…","code":"K7MPQ2","category":"blind"}]
S→C  2                                    # every 20 s
C→S  3
C→S  421["game:action",{"action":"chaal","amount":"100","actionId":"…"}]
S→C  431[{"ok":false,"code":"invalid_bet","message":"Bet amount must be a whole number"}]
S→C  42["game:error",{"code":"invalid_bet","message":"Bet amount must be a whole number"}]
C→S  41                                   # client disconnect → reason 'client namespace disconnect'
```

### 14.6 Reasons reported to the `disconnect` handler (server side)

`transport close` (TCP/WebSocket closed by peer), `transport error`, `ping timeout`, `client
namespace disconnect` (`41` received), `server namespace disconnect` (`socket.disconnect()` — the
`session:replaced` path), `forced close`, `server shutting down` (`io.close()`), `parse error`.
Only the label folding depends on them (§10); nothing on the wire does.

### 14.7 How the three shipped clients connect

| Client | Library | Options | Wire behaviour |
|---|---|---|---|
| Flutter | `socket_io_client` **3.1.6** (`pubspec.lock:392-399`) | `setTransports(['websocket'])`, `setAuth({'token': token})`, `enableReconnection()`, `setReconnectionDelay(800)` (`game_connection.dart:89-97`) | Direct WS upgrade to `/socket.io/?EIO=4&transport=websocket`; CONNECT `40{"token":…}`; every emit via `emitWithAck` (`42<id>[…]`), so every request carries an ack id; on drop it reconnects every ~800 ms (with backoff jitter) using the same token → a brand-new handshake and `session:ready` each time; `request()` gives up waiting for an ack after 8 s. |
| Browser | `socket.io-client` 4.8.3 bundle served at `/socket.io/socket.io.js` | `io({ auth: {token}, transports: ['websocket','polling'] })` (`client.js:189`) | Tries **websocket first**; because `tryAllTransports` is false by default in 4.8 it does *not* fall back to polling on a websocket failure — it simply retries websocket (`engine.io-client/build/cjs/socket.js:509-516`). Lobby emits carry ack ids (`client.js:428-437`); `game:action` emits have no ack (`client.js:628, 689`); chat emits have an ack (`client.js:413`). |
| Node bots / load test | `socket.io-client` 4.8.3 | `io(BASE_URL, { auth: {token}, transports: ['websocket'], forceNew: true })` (`bot.js:104`; loadtest adds `reconnection: false`) | Websocket only. `room:quickJoin` with ack; `game:action`/`game:sideshowRespond`/`chat:message` without ack (bot) or with ack (loadtest `:111`). Bots act on `game:yourTurn`, answer `game:sideshowRequested` when `toUserId` is theirs, chat on `game:handEnded`. |
| Unity port (tests only) | hand-rolled (`csharpJsonPort.js`) | raw `ws` | `40{"token":…}`, `42[…]`/`42<id>[…]`, answers `2` with `3`. |

### 14.8 Long-polling (accepted by the Node server; no shipped client actually uses it)

`GET /socket.io/?EIO=4&transport=polling&t=<yeast>` → `200 text/plain; charset=UTF-8` body
`0{"sid":…,"upgrades":["websocket"],…}`; subsequent `POST …&sid=<sid>` bodies and `GET` responses
carry one or more Engine.IO packets separated by U+001E (RECORD SEPARATOR); binary as `b<base64>`.
Upgrade probe: WS `2probe` → `3probe` → `5`. CORS headers per §1. Reproducing polling is optional
for the shipped clients (Flutter and bots are websocket-only; the browser never falls back), but the
Node server does accept it.

### 14.9 What the existing tests assert about the wire (MUST MATCH)

| Test (`socketProtocol.test.js`) | Asserts |
|---|---|
| `the Unity handshake is accepted by the real server` (`:169-187`) | first frame starts with `0{`; `sid` and `pingInterval` parse; `40{"token":…}` is accepted (a `40…` reply is received); `session:ready` follows and `user.id` matches the login |
| `a bad token is reported as a connect error the client can read` (`:189-202`) | a `44{"message":…}` arrives whose message matches `/invalid_session|unauthorized|unknown_user/`; no CONNECT |
| `the client answers Engine.IO pings…` (`:204-214`) | port logic only (`2`→`3`), no server assertion |
| `a full hand is readable end to end…` (`:218-281`) | ack `43<id>[{…}]` for `room:quickJoin` with `ok:true` and `code` matching `^[A-Z2-9]{6}$`; `room:joined.maxPlayers == 5`; `game:handStarted.pot == 200`, `handNo == 1`; only the on-turn player gets `game:yourTurn` with `options.chaal == 100`, `raise == 200`, `canSee == true`; `player:cards.cards` has 3 codes matching `^[2-9TJQKA][shdc]$` and the opponent gets none; `game:showdown.reveals` has 2 entries each with 3 cards and a non-empty `handName`; `game:handEnded.pot == 400`, `winnerId` and `reason` non-empty |
| `a game error frame reaches the Unity client` (`:283-296`) | `game:action {"action":"chaal"}` from an unseated player → ack `ok:false`, `code:"not_in_room"`, non-empty message |
| `room chat frames…` (`:298-331`) | `chat:history.messages` is an array; posted `chat:message` has `text`, `displayName`, `system` absent/false, `at > 0`; a later joiner's backlog contains it plus a `system:true` line |
| `chat text with quotes and braces…` (`:333-348`), `a display name with quotes and braces…` (`:350-362`) | the frames stay valid JSON and the hand-rolled scanner reads them |

---

## 15. Test cases to mirror

### 15.1 `test/socketProtocol.test.js` — see §14.9. Environment: `NODE_ENV=test`, throwaway
`PG_SCHEMA`, `JWT_SECRET`, `AUTH_ALLOW_FAKE_PROVIDERS=true`, `BOOT_AMOUNT=100`,
`TURN_TIMEOUT_MS=3000`, `NEXT_HAND_DELAY_MS=150`, `TABLE_STAKES=''`, `LOBBY_TABLES=''`. Players are
guests (`POST /api/auth/login {provider:'guest', deviceId, displayName}`).

### 15.2 `test/integration.test.js` (env: as above but `TURN_TIMEOUT_MS=1200`,
`RECONNECT_GRACE_MS=400`, `WELCOME_CHIPS=200000`, `PORT=0`)

| Test | Setup → assertion |
|---|---|
| `a socket without a valid token cannot connect` (`:225`) | `auth:{token:'garbage'}` → `connect_error.message` matches `/invalid_session|unauthorized/` |
| `two players quick-join the same table and a hand is dealt` (`:232`) | same unique boot → same `roomId`; `game:handStarted.participants.length == 2`, `pot == 2*boot`; `room:state` with `state:'betting'` has `maxPlayers 5`, `minPlayers 2`, `you.cards == []` |
| `a full hand plays out…` (`:259`) | on-turn `see` ack ok → `player:cards.cards.length == 3`, opponent receives none; `show` ok → `game:handEnded.winnerId` set, `pot == 4*boot`, `reveals.length == 2`; `/api/auth/me` shows winner `chips > 200000`, `handsWon 1`; show-payer `handsPlayed 1` |
| `acting out of turn returns an error to the client` (`:317`) | waiting player `chaal` → `{ok:false, code:'not_your_turn'}` |
| `a player who stalls past the turn timer…` (`:337`) | nobody acts → `game:handEnded.reason == 'last_standing'`, winner ≠ on-turn user; a `game:action` with `reason:'timeout'` was broadcast |
| `a table holds at most five players…` (`:360`) | 6 quick-joins at one boot → 2 rooms with counts `[1,5]` |
| `a private room can be created and joined by its code` (`:382`) | `room:create {isPrivate:true}` → `code` matches `^[A-Z2-9]{6}$`; `room:joinCode` returns the same `roomId`; `ZZZZZZ` → `ok:false`; table boot == 200 (private boot) |
| `leaving a room frees the seat` (`:408`) | after `room:leave`, `getTableForPlayer` null |
| `a second sign-in replaces the first session` (`:421`) | first socket receives `session:replaced` with a `message` |
| `blind and seen tables at the same stake are separate rooms` (`:434`) | acks carry `category` `'blind'` / `'seen'`, different `roomId` |
| `on a seen table a player can see everyone's chips` (`:454`) | `room:state.category 'seen'`, `chipsHidden false`, every occupied seat's `chips` is a positive number |
| `on a blind table you see only your own chips` (`:479`) | `chipsHidden true`; own `chips` number; every other occupied seat `chips === null` |
| `the lobby offers the configured categories and stakes` (`:512`) | `session:ready.config.categories` deep-equals `['seen','blind']`, `stakes` is an array; `lobby:list {}` ack ok with `tables` array and `options.categories` array |
| `the lobby can be filtered to one category` (`:528`) | `lobby:list {category:'blind'}` returns only blind tables incl. the one just joined; `'seen'` only seen |
| `an unknown category is treated as seen…` (`:545`) | `room:quickJoin {category:'sneaky'}` → ok, `category:'seen'` |
| `a chat message reaches everyone in the room and nobody outside it` (`:562`) | `chat:message` at the same table has `displayName`, `userId`, `at > 0`; a player at another table never receives it (150 ms wait) |
| `a player joining later is sent the room backlog` (`:594`) | `chat:history.messages` texts include both earlier messages and `'HistA joined the table'`; `history.roomId == roomId` |
| `room chat history is capped at 100 messages` (`:620`) | 130 direct `postChat` → inbound `chat:history` → exactly 100 messages, last is `'spam 130'`, `'spam 1'` gone |
| `chat history dies with the room when the last player leaves` (`:643`) | table gone after `room:leave`; a new room's history lacks the old text |
| `a player who is not at a table cannot chat` (`:670`) | `{ok:false, code:'not_in_room'}` |
| `chat flooding is rate limited` (`:681`) | 12 sequential sends → some `ok:false` with `code:'chat_rate_limited'`, ≥3 ok |
| `empty chat messages are ignored` (`:701`) | `{text:'   '}` → `ok:true`, `messageId` undefined, history unchanged |
| `a player whose app dies mid-hand is put straight back…` (`:720`) | disconnect (no leave), reconnect within 400 ms grace → `session:ready.resume` undefined; unsolicited `room:joined` with same `roomId`, `state 'betting'`, `you.status 'active'`, `seats[you.seatIndex].userId == self` |
| `once the held seat has lapsed, the next sign-in is offered the same table back — once` (`:750`) | wait 800 ms → seat gone; reconnect → `resume` deep-equals `{roomId, code, category, bootAmount}`; no `room:joined` within 50 ms; `room:joinCode {code}` ok → same room; another drop+reconnect → no `resume`, `room:joined` arrives |
| `leaving a table on purpose leaves nothing to resume` (`:792`) | `room:leave` then disconnect, 800 ms → `resume` undefined, no `room:joined` |
| `a table that closed while the player was away is not offered back` (`:816`) | seat lapses, last player leaves (table destroyed) → `resume` undefined |
| `health reports live table and player counts` (`:840`) | `/health` `ok true`, numeric `tables`, `players` |

### 15.3 `test/invalidMoves.test.js` (env: `TURN_TIMEOUT_MS=60000`, `SIDESHOW_TIMEOUT_MS=60000`,
`RECONNECT_GRACE_MS=400`; stakes start at 1050)

| Test | Setup → assertion |
|---|---|
| `acting out of turn is refused and the turn does not move` (`:138`) | waiting player sends `chaal/pack/show/sideshow` with `amount: stake` → all `not_your_turn`; `turnSeat` unchanged |
| `a bet that is not on the ladder is refused…` (`:151`) | `stake+1, stake*3, -stake, 0, 1, 1e15, wallet+1` → `ok:false`, code ∈ `invalid_bet|insufficient_chips`; pot and wallet unchanged |
| `a bet amount that is not a number at all…` (`:175`) | `"<stake>"`, `'abc'`, `1.5`, `{amount:100}`, `[stake]`, `true` → `invalid_bet`; pot unchanged |
| `an unknown action, or one from a player at no table…` (`:192`) | `'allin'` → `unknown_action`; `'__proto__'` → `ok:false`; unseated `pack` → `not_in_room` |
| `a show with more than two players in the hand is refused` (`:209`) | 3 players, on-turn `show` → `show_unavailable`; hand live |
| `a sideshow with only two players is refused, and so is answering one that was never asked` (`:230`) | `sideshow` → `too_few_players`; `game:sideshowRespond {accept:true}` → `no_sideshow` |
| `seeing twice is refused, and seeing never hands over the turn` (`:243`) | off-turn `see` ok; second `see` → `already_seen`; `turnSeat` unchanged; seat `isBlind false` |
| `replaying a move with the same actionId charges nobody twice` (`:257`) | `chaal` with `actionId:'dup-same-id'` ok; replay `ok:false`; `SELECT COUNT(*) FROM chip_ledger WHERE action_id = $1` == 1; wallet == before − amount |
| `a player who is not seated cannot ask for cards…` (`:277`) | unseated `player:requestCards` → `not_in_room`; the opponent's seat has no `cards` key; no `"cards":["` substring anywhere in the on-turn client's received frames before it looks |
| `joining while already seated, or a room that does not exist, is refused` (`:300`) | seated `room:quickJoin` → `already_in_room`; seated `room:joinCode 'NOPE00'` → `already_in_room|room_not_found`; seated `room:create {isPrivate:true}` → `already_in_room`; unseated `joinCode 'NOPE00'` → `room_not_found`; `code:{$gt:''}` → `ok:false`; `quickJoin {bootAmount:-5}` and `{bootAmount:'lots'}` → `ok:false`; `quickJoin null` → `ok:true` |
| `a player who cannot cover the boot is not seated` (`:335`) | wallet reduced to 50 via ledger → `quickJoin` → `insufficient_chips`, not seated |
| `the sixth player is not squeezed onto a full table` (`:348`) | 5 join by code ok, 6th → `table_full` |
| `chat that is empty, too long, or from outside the room never reaches the table` (`:369`) | sends `{text:'   '}`, `{text:'x'×5000}`, `{text:12345}`, `null`, `{text:'hello table'}` → the other player hears exactly 3: a 140-char text, `'12345'`, `'hello table'` |
| `garbage on every gameplay event is refused rather than crashing the server` (`:399`) | for payloads `undefined, null, 42, 'string', [], [1,2], {action:null}, {action:{}}, {amount:{}}, {action:'chaal',amount:'1e3'}, {action:'chaal',amount:[100]}, {action:'raise',amount:true}, {__proto__:{action:'pack'}}` × events `game:action, game:sideshowRespond, room:quickJoin, room:joinCode, room:create, chat:message`: **every request is acked within 1.5 s**; `chat:message` acks have no `messageId`; all others `ok:false`; hand and socket survive; after 5.2 s a `pack` succeeds (limiter window passed) |
| `too many requests in a burst are rate limited but the session survives` (`:437`) | 60 parallel `lobby:list` → at least one `game:error {code:'rate_limited'}` (or an undefined ack); socket still connected |
| `after all of the above every wallet still equals its ledger` (`:449`) | `users.chips == SUM(chip_ledger.delta)` for every user |

### 15.4 `test/metrics.test.js` (socket-relevant parts; env adds `METRICS_TOKEN`,
`TURN_TIMEOUT_MS=4000`)

| Test | Assertion touching this layer |
|---|---|
| `sockets: the live gauge follows connects and disconnects…` (`:391`) | `game_connected_sockets` +2 after two connects and equals `io.engine.clientsCount`; `game_connections_total` +2; `game_connected_sockets_peak` ≥ before+2; after both close, gauge back to before and `game_disconnections_total` +2 with `reason` labels matching `^[a-z][a-z _]*$` |
| `game: a dealt hand and its moves are counted and timed` (`:423`) | after `see` + `chaal`: `game_moves_total{action=see|chaal} ≥ 1`, `game_socket_messages_total{event=game:action} ≥ 2`, `{event=room:quickJoin} ≥ 2`, `game_move_processing_duration_seconds_bucket{action=chaal,le=+Inf} ≥ 1` and a `le="1"` bucket, `_count{action=see} ≥ 1`, `game_state_update_duration_seconds_count ≥ 1`, `game_join_duration_seconds_count{route=quick_join} ≥ 2`; sums > 0 |
| `invalid moves are counted by refusal code` (`:462`) | `game_invalid_moves_total{code=not_your_turn|unknown_action} ≥ 1`, `game_socket_errors_total` same, `game_socket_emits_total{event=game:error} ≥ 2`; `game_moves_total` unchanged; `'teleport'` never appears as an `action` label |
| `a completed hand is counted with its reason, and the pot it paid out` (`:491`) | `pack` → `game:handEnded.reason 'last_standing'`, `pot == 2*boot`; `game_games_completed_total{category=seen,reason=last_standing} ≥ 1`; `game_pot_settled_chips_total` ≥ before + pot; `game_socket_emits_total{event=game:handEnded} ≥ 1`; `game_moves_total{action=pack} ≥ 1` |
| `chat: a posted message is counted…` (`:550`) | ack `ok:true` with `messageId`; `game_chat_messages_total ≥ 1`, `game_socket_emits_total{event=chat:message} ≥ 1`, `game_socket_messages_total{event=chat:message} ≥ 1` |
| `cardinality…` (`:580`) | no label named `*_id`, `code_*`, `socket_id`, `user_id`, `room_id`, `ip`, `url`, `path`, `device_id`; no label value is a UUID, IPv4/6 or 64-hex; `code` values `^[a-z][a-z0-9_]*$`; `event` values `^[a-z]+:[a-zA-Z]+$`; `category` ∈ `seen|blind|other` |

---

## 16. Traps for the port

1. **Async ordering inside a handler determines what the client sees before the ack.** Joins
   send `room:state` (from `setConnected`) *before* `room:joined`; `room:leave` lets the leaver
   receive the table's removal traffic (including `room:closed`) *before* `room:left`; the ack is
   always last. Flutter/browser tolerate any order of the snapshot events, but tests wait for
   specific ones (`room:joined` after a resume; `chat:history` after joins).
2. **`session:replaced` is synchronous re-entry.** `previous.disconnect(true)` fires the old
   socket's `disconnect` handler before `userSockets.set(newSocket)`, so the seat is briefly marked
   disconnected, a grace timer is armed and then immediately cancelled and counted as
   `reconnects_total{kind=seat_held}`. Reproduce the observable outcome (seamless hand-over, one
   `room:state` with `connected:false` to other viewers, then `connected:true`).
3. **`null` vs `0` vs absent.** Blind-table others' `chips` is `null`; `resume` is *absent*, never
   `null`; `you` and `turn` and `sideshow` are `null` when not applicable; player chat messages have
   *no* `system` key; `startsAt` is `null` (via `?? null`) when unset; `winnerId`/`winnerName` may be
   `null`; `options.show/chaal/raise/maxBet/sideshowWith` are `null`, not omitted.
4. **`??` vs falsy.** `bootAmount ?? default` keeps `0`, `-5`, `'lots'`, `false` and refuses them
   downstream (`invalid_stake`); `isPrivate = true` default applies only to `undefined` — `null`
   or `false` makes a **public** table with no stake validation and no chips check.
5. **`amount` typing is done at the socket layer for every action**, before the table's turn
   check: a non-integer `amount` yields `invalid_bet` even for `pack`/`see`/`sideshow` and even when
   it is not the player's turn. `Number.isSafeInteger` semantics (|n| ≤ 2^53−1, integral, finite).
   JSON `1e3` is the number 1000 (valid); the string `"1e3"` is not.
6. **`actionId` idempotency key**: only a string of 1–64 UTF-16 units is honoured; otherwise a
   fresh UUID is used and the replay protection silently disappears. The id lands in
   `chip_ledger.action_id` (UNIQUE); a `23505` mentioning `action_id` → `duplicate_action`. Boots
   and settlements use `${handId}:boot:${userId}` / `${handId}:settle:${userId}` (other spec).
7. **`accept === true` only** for `game:sideshowRespond`.
8. **Rate limiting**: fixed window anchored to the first request after expiry, 30/5 s general
   (counts every guarded event, including chat and refused requests) and 5/5 s chat (counts every
   seated chat attempt, posted or not; unseated attempts are refused by `not_in_room` first and do
   not count). Rate-limited requests **are acked** and also get `game:error`. `ping:rtt` bypasses
   both.
9. **Refusals are delivered twice** (ack then `game:error`), and for non-`GameError` failures the
   two differ: ack has the raw error message/code, `game:error` has `internal_error` / "Something
   went wrong".
10. **Unicode in chat**: JS `\p{C}` (incl. unassigned Cn and Cf such as ZWJ/ZWNJ), JS `\s`
    (Unicode), `.trim()`, and `.slice(0,140)` on UTF-16 code units. Go's `\pC`, `\s` (ASCII in
    RE2), `strings.TrimSpace`, and rune/byte slicing all differ. To be byte-compatible the port
    must implement JS semantics explicitly (and JSON-encode a lone surrogate as `\udXXX`).
11. **`String(text)` coercion**: numbers/booleans/arrays/objects become text (`'[object Object]'`
    is a postable message).
12. **Display names in system chat lines** use the seat's `displayName` captured at join; the
    `user` in `session:ready` is the DB row at handshake and is never refreshed on that socket.
13. **Timers**: grace 60 s (unref'd), offer 10 min, both from `Date.now()`; `takeResumeOffer`
    deletes the offer whether or not it is still valid (offered once); an offer is refused if the
    table is gone or full at connect time.
14. **`resumeOffers` is written before `rooms.leave`** in the grace timer; if `leave` throws, the
    offer still stands.
15. **`kick` handler guard** checks `getTableForPlayer(userId)` is non-null (any table), then
    `rooms.leave` with the kick reason, so the departure reason on the ledger/summary is `'idle'`
    or `'insufficient_chips'`, and `rooms.leave` triggers consolidation (possible `playerMoved`).
16. **Consolidation move ordering** (§9.2): the mover gets `room:closed` for the old room before
    `room:moved`/`room:joined` for the new one. Flutter copes; do not "fix" it in the wire order
    without changing the client.
17. **Metric label folding** (`safeLabel`) never changes what goes on the wire; the ack carries the
    real `code`. But `metrics.test.js` asserts the *names* of every metric and the shape of labels.
18. **Unknown inbound events are never acked** (no `{ok:false}`), and a malformed Socket.IO packet
    closes the connection with reason `parse error`.
19. **`/socket.io/socket.io.js` must exist** for `server/public/index.html`, or the browser
    reference client breaks.
20. **Handshake `next(new Error(code))`** puts the code in `message`; the `AuthError.message` text
    is not sent. A `pg` failure during `findById` leaks its SQLSTATE as the message.
21. **`publicGameConfig().maxBetRounds` is the global default (20)**, not the seen-table 7; clients
    do not use it, but it is on the wire.
22. **Key order** in every object above is Node's insertion order; the shipped clients are
    order-insensitive, so this is only needed for literal byte-for-byte parity in recorded frames.
23. **`room:create` and `room:switch` send no `room:state` to the actor from `addPlayer`** (the
    socket is not yet tracked); `room:create` sends none at all — only `room:joined` +
    `chat:history`. `game_socket_emits_total{event="room:state"}` still increments (INCIDENTAL).
24. **Chat `at`, `deadline`, `expiresAt`, `startsAt`, `nextHandAt`** are epoch **milliseconds**;
    no clock-skew correction anywhere; Flutter computes remaining time as `deadline -
    DateTime.now()`.
25. **`serializeFor` for a socket whose user has left** (still tracked during `room:leave`) yields
    `you: null` and its old seat as `{seatIndex, status:'empty'}` — clients must accept `you: null`
    in `room:state`.
