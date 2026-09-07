# CLAUDE.md

Project context for Claude Code. Read this before touching the repo. Everything below was derived
from the source on branch `docs/claude-md` (2026-09-07); where the READMEs disagree with it, the
source wins — see [Gotchas](#gotchas).

## What this is

**King Teen Patti** — a turn-based multiplayer Teen Patti (3-card Indian poker) game sized for
500–1000 concurrent players. One **authoritative Node.js game server** plus two clients that speak
the same REST + Socket.IO protocol: a Flutter app and a bundled browser client.

The server owns every rule. Clients send intent and render what comes back; they never decide
legality, bet amounts, or who won. Card faces stay in server memory and are sent only to their
owner, only after that player presses *See*.

The spec of record is [Requirements.txt](Requirements.txt) — 33 numbered requirements (there is no
#11). Source comments cite them by number (`// Requirement 31: ...`); keep that convention when
changing behaviour that traces to one.

## Repository layout

```
king-teenpatti/
├── CLAUDE.md             This file
├── Requirements.txt      The original brief (33 requirements) — the spec of record
├── README.md             Overview + requirement→file map. PARTLY STALE — see Gotchas
├── server/               Node.js + Socket.IO + SQLite — the authoritative game server
│   ├── src/              Engine, auth, db, socket layer (see Server → Module map)
│   ├── public/           Browser client: index.html + client.js + theme.css + style.css
│   │   └── profiles/     15 Noto-emoji SVG avatars (Apache-2.0; NOTICE.txt must travel with them)
│   ├── test/             17 node:test suites (232 cases), helpers, load test
│   ├── tools/bot.js      Practice bots that fill a table
│   ├── kicktest.mjs      Manual harness for the idle/insufficient-chips kicks
│   ├── .env.example      Annotated env reference (copy to .env)
│   └── package.json      ESM, node >= 20
└── flutter-client/       Flutter/Dart client — Android platform dir only
    ├── lib/              main, state, net, models, screens, widgets, theme, l10n
    ├── android/          AGP 9.0.1, Kotlin 2.3.20, JVM 17, landscape-locked, cleartext allowed
    ├── assets/           card_back.svg
    └── test/             widget_test.dart — BROKEN template, see Gotchas
```

**A Unity C# client used to live in `unity-client/`.** It was deleted on this branch (145 files,
staged, not yet committed). It is still in history at `63252bd`
(`git show 63252bd:unity-client/README.md`, or `git checkout 63252bd -- unity-client` to restore).
Some server code and both READMEs still reference it — see Gotchas.

Git: `origin` = `https://github.com/surajk543/king-teenpatti.git`, default branch `master`. Two
commits in history (`101bd63` project scaffold, `63252bd` code drop).

---

## Server (`server/`)

### Runtime and dependencies

Node.js **>= 20** (this machine runs v22.21.1). **ESM** (`"type": "module"`, `.js` extensions on
relative imports). No TypeScript, no bundler, no lint config.

| Package | Version | Role |
|---|---|---|
| `express` | ^4.21.1 | REST + static hosting of `public/`; JSON body limit 32 KB |
| `socket.io` | ^4.8.1 | Live gameplay transport; `websocket` first, `polling` fallback |
| `better-sqlite3` | ^11.5.0 | Synchronous SQLite; WAL, `synchronous=NORMAL`, FK on, 5 s busy timeout |
| `jsonwebtoken` | ^9.0.2 | Session JWTs (`sub`, `provider`, `name`; 30 d default) |
| `google-auth-library` | ^9.14.2 | Google id_token verification against configured client ids |
| `dotenv` | ^16.4.5 | `.env` loading — imported once, at the top of `config/index.js` |
| `redis` + `@socket.io/redis-adapter` | ^4.7 / ^8.3 | Optional; dynamically imported only when `REDIS_URL` is set |
| `socket.io-client` (dev) | ^4.8.1 | Integration tests, bots, load test |
| `ws` | — | **Not declared.** `socketProtocol.test.js` imports it; works only because it is hoisted from `engine.io` |

`node_modules/` is **not present** on this checkout. `cd server && npm install` first.

### Module map

| File | Lines | Responsibility |
|---|---|---|
| [src/index.js](server/src/index.js) | 115 | `createServer()` → `{app, server, io, rooms}`. Express app, error mapping, static `public/`, Socket.IO server (pingInterval 20 s, pingTimeout 25 s, maxHttpBufferSize 100 KB), optional Redis adapter, graceful SIGINT/SIGTERM shutdown (8 s hard exit). Only listens when run as entrypoint — tests import it |
| [src/config/index.js](server/src/config/index.js) | 158 | Parses every env var into `config.{env,port,host,corsOrigin,jwt,google,facebook,allowFakeProviders,db,game,chat,redisUrl,rootDir}`. **Snapshots `process.env` at import time.** Throws in production on the dev JWT secret or fake providers |
| [src/auth/providers.js](server/src/auth/providers.js) | 161 | `verifyLogin({provider, ...})` → normalised profile `{provider, providerUserId, displayName, email, avatarUrl}`. Google (id_token, audience = `GOOGLE_CLIENT_IDS`), Facebook (`debug_token` + `app_id` check, then Graph v20.0 profile), guest (SHA-256 of `teenpatti:<deviceId>`, min 8 chars), fake (dev only). `AuthError(code, message, status=401)` |
| [src/auth/tokens.js](server/src/auth/tokens.js) | 30 | `issueToken(user)`, `verifyToken(token)`, `tokenFromRequest(req)` (Bearer header) |
| [src/auth/routes.js](server/src/auth/routes.js) | 227 | `requireAuth` middleware; `authRoutes()` (`/login`, `/me`, `/me/hands`); `playerRoutes({isSeated})` (rewards, profiles, avatar, name). Avatar list is `readdirSync` of `public/profiles/` filtered to svg/png/jpg/jpeg/webp |
| [src/db/index.js](server/src/db/index.js) | 80 | `openDatabase(file)` (singleton; mkdir; pragmas; runs `schema.sql`; idempotent `migrate()` adds `hands_lost`, `hands_left_mid`, `total_winnings`, `milestone_claimed`, `next_bonus_at`, `avatar_choice` if absent), `getDatabase()`, `closeDatabase()` |
| [src/db/schema.sql](server/src/db/schema.sql) | — | `users`, `hands`, `chip_ledger` + indexes. All `CREATE ... IF NOT EXISTS` |
| [src/db/users.js](server/src/db/users.js) | 404 | Everything that touches the `users` row: `publicUser` shaping (adds `rewards{}` block), `findById`, `findByProvider`, `upsertFromProfile` (welcome grant in same txn), `applyChipDelta` (throws on negative balance), `settleHand` (one txn per hand), `recentHands`, `claimMilestoneReward`, `claimTimedBonus`, `normalizeDisplayName`, `setDisplayName`, `setAvatarChoice`. Reward constants: `MILESTONE_REWARD=25000`, `MILESTONE_EVERY=25`, `TIMED_BONUS_REWARD=10000`, `TIMED_BONUS_INTERVAL_MS=4h` — **hard-coded, not env** |
| [src/game/constants.js](server/src/game/constants.js) | 53 | `TABLE_CATEGORY {BLIND, SEEN}`, `TABLE_STATE {WAITING, STARTING, BETTING, SHOWDOWN}`, `SEAT_STATE {EMPTY, WAITING, ACTIVE, PACKED, LOST, WON}`, `ACTION {SEE, CHAAL, RAISE, PACK, SHOW, SIDESHOW}`, `WIN_REASON {LAST_STANDING, SHOW, FORCED_SHOWDOWN, ALL_LEFT, POT_LIMIT}` |
| [src/game/deck.js](server/src/game/deck.js) | 57 | 52-card deck, Fisher–Yates with `crypto.randomInt`, `deal(count, 3)` one card at a time round-robin. Wire code = rank char + suit letter: `As`, `Td`, `7h` (T for ten; suits `s h d c`) |
| [src/game/handRank.js](server/src/game/handRank.js) | 145 | `evaluate(cards, {aceLowIsLowest})` → `{category, name, score[], cards}`; `compare(a,b)`; `pickWinner(contenders, {tieBreakOrder})`. Categories 0–5: High Card, Pair, Color, Sequence, Pure Sequence, Trail |
| [src/game/table.js](server/src/game/table.js) | 1449 | **The state machine.** `Table extends EventEmitter`. Transport- and DB-agnostic; persistence via injected `settle` / `persistChips` callbacks; time via injected `timers` (so tests use a fake clock). Exports `Table` (default) and `GameError` |
| [src/game/roomManager.js](server/src/game/roomManager.js) | 444 | `RoomManager extends EventEmitter`. Owns `tables: Map<roomId, Table>` and `playerRooms: Map<userId, roomId>`. Creates tables with category/private rule overlays, quick-join, join-by-code, switch, leave, entry cap, consolidation, empty-table sweep (30 s), `stats()`, `shutdown()` |
| [src/game/chat.js](server/src/game/chat.js) | 91 | `RoomChat` ring buffer. `add()` sanitises (strips `\p{C}`, collapses whitespace, trims to `maxLength`), `addSystem()`, `history()`, `clear()` |
| [src/socket/index.js](server/src/socket/index.js) | 536 | `attachSocketHandlers(io, rooms)`. Handshake auth, single-session rule, reconnect restore, per-viewer `room:state` fan-out, table event → wire event wiring, all client handlers wrapped in `guard()`, rate limiters, disconnect grace |
| [src/util/logger.js](server/src/util/logger.js) | 19 | JSON lines to stdout (stderr for `error`). `LOG_LEVEL` env: error/warn/info/debug (default info) |
| [src/util/ids.js](server/src/util/ids.js) | 13 | `uuid()` (`randomUUID`), `roomCode()` — 6 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no 0/O/1/I) |

**Layering rule:** `Table` knows nothing about sockets or SQLite. `RoomManager` injects
`settleHand`/`applyChipDelta` from `db/users.js`. `socket/index.js` is the only subscriber to
`Table`/`RoomManager` events and the only thing that emits to clients. Keep it that way.

### Boot sequence

```
node src/index.js
 └─ import config            (reads .env, validates production invariants)
 └─ createServer()
     ├─ openDatabase()       mkdir data/, open, pragmas, schema.sql, migrate()
     ├─ new RoomManager()    starts consolidate+sweep interval (CONSOLIDATE_INTERVAL_MS, unref'd)
     ├─ Express: /health, /api/auth/*, /api/*, /api/rooms, static public/, error mapper
     ├─ Socket.IO server     (+ Redis adapter if REDIS_URL)
     └─ attachSocketHandlers(io, rooms)
 └─ server.listen(PORT, HOST)
```

### Configuration (env → `config`)

Copy `server/.env.example` → `server/.env`. No `.env` exists on this checkout; in `development`
the server boots with `JWT_SECRET=dev-only-insecure-secret`. **Production refuses to boot** with
that secret or with `AUTH_ALLOW_FAKE_PROVIDERS=true`.

| Env var | Default | `config.` path | Notes |
|---|---|---|---|
| `NODE_ENV` | `development` | `env` | `production` enables safety checks; tests set `test` |
| `PORT` / `HOST` | `3000` / `0.0.0.0` | `port` / `host` | |
| `CORS_ORIGIN` | `*` | `corsOrigin` | Comma list, or `*` |
| `JWT_SECRET` / `JWT_EXPIRES_IN` | dev secret / `30d` | `jwt.*` | |
| `GOOGLE_CLIENT_IDS` | empty | `google.clientIds[]` | Empty ⇒ Google login returns 503 `provider_unconfigured` |
| `FACEBOOK_APP_ID` / `_SECRET` | empty | `facebook.*` | Both required for FB login |
| `AUTH_ALLOW_FAKE_PROVIDERS` | `false` | `allowFakeProviders` | Lets `google`/`facebook` without a token through as fake |
| `DB_FILE` | `./data/teenpatti.db` | `db.file` | Relative paths resolve from `server/` |
| `WELCOME_CHIPS` | `200000` | `game.welcomeChips` | Requirement 5 |
| `BOOT_AMOUNT` | **`200`** | `game.bootAmount` | server/README wrongly says 100 |
| `TABLE_STAKES` | `200,5000` | `game.tableStakes[]` | **Empty = any stake allowed** (tests rely on this) |
| `MAX_PLAYERS_PER_ROOM` / `MIN_PLAYERS_TO_START` | `5` / `2` | `game.maxPlayers` / `minPlayers` | |
| `TURN_TIMEOUT_MS` | `25000` | `game.turnTimeoutMs` | |
| `MAX_BET_ROUNDS` | `20` | `game.maxBetRounds` | Forced showdown cap |
| `POT_LIMIT_MULTIPLIER` | `1024` | `game.potLimitMultiplier` | Single-bet ceiling = boot × this |
| `MAX_RAISE_STEPS` | `8` | `game.maxRaiseSteps` | Ladder rungs |
| `SEEN_MAX_RAISE_STEPS` / `SEEN_MAX_BET_ROUNDS` | `2` / `7` | `game.seen*` | Requirement 19 |
| `MAX_BLIND_MOVES` | `4` | `game.maxBlindMoves` | Auto-see after N blind bets. **Not in any README** |
| `ENTRY_CAP_BOOT` / `_CATEGORY` / `_MAX_CHIPS` | `200` / `blind` / `500000` | `game.entryCap*` | Requirement 30 |
| `MAX_MISSED_TURNS` | `3` | `game.maxMissedTurns` | Requirement 31 |
| `SIDESHOW_TIMEOUT_MS` / `SIDESHOW_MIN_PLAYERS` | `6000` / `3` | `game.sideshow*` | Requirement 33 |
| `DISPLAY_NAME_MAX` | `24` | `game.displayNameMaxLength` | Requirement 29 |
| `PRIVATE_BOOT` / `PRIVATE_MAX_POT` / `PRIVATE_MAX_RAISE_STEPS` | `200` / `500000` / `2` | `game.private*` | Requirement 22 |
| `NEXT_HAND_DELAY_MS` | `4000` | `game.nextHandDelayMs` | "Starting in N" countdown |
| `CONSOLIDATE_INTERVAL_MS` | `15000` | `game.consolidateIntervalMs` | |
| `RECONNECT_GRACE_MS` | `30000` | `game.reconnectGraceMs` | Seat held after disconnect |
| `CHAT_MAX_HISTORY` / `CHAT_MAX_LENGTH` | `100` / `140` | `chat.*` | |
| `CHAT_RATE_LIMIT` / `CHAT_RATE_WINDOW_MS` | `5` / `5000` | `chat.*` | Per socket |
| `REDIS_URL` | empty | `redisUrl` | Enables Socket.IO Redis adapter |
| `LOG_LEVEL` | `info` | (logger only) | Read directly in `util/logger.js` |

Per-table config is `{...config.game, ...categoryRules, ...privateRules, bootAmount, category,
chatMaxHistory, chatMaxLength}` built in `RoomManager.createTable`. Seen tables overlay
`maxRaiseSteps=seenMaxRaiseSteps, maxBetRounds=seenMaxBetRounds`; private tables overlay
`maxPot=privateMaxPot, maxRaiseSteps=privateMaxRaiseSteps` and force `bootAmount=privateBoot`.

### Data model (SQLite)

```sql
users        id PK, provider CHECK IN ('google','facebook','guest'), provider_user_id,
             display_name, email, avatar_url, avatar_choice, chips,
             hands_played, hands_won, hands_lost, hands_left_mid, total_winnings, biggest_pot,
             milestone_claimed, next_bonus_at, created_at, updated_at, last_login_at
             UNIQUE (provider, provider_user_id)
hands        id PK, room_id, hand_no, pot, winner_id FK→users (SET NULL), win_reason,
             boot_amount, started_at, ended_at, summary_json (array of every contributor)
chip_ledger  id AUTOINCREMENT, user_id FK→users (CASCADE), hand_id, delta, balance, reason, created_at
```

`chip_ledger.reason` values: `welcome_bonus`, `bet` (banked live during a hand), `hand_win`,
`hand_loss`, `milestone_reward`, `timed_bonus`. `users.chips` is always reconcilable against the
ledger. All timestamps are epoch ms.

**Write pattern:** chips are banked **as each bet is made** (`Table._bank` → `applyChipDelta`,
reason `bet`), then `settleHand` runs once per hand in one transaction, writing the `hands` row,
updating counters, and applying only the *unbanked* remainder (`delta = net + persisted`). A
`Table` built without `persistChips` (the unit tests) settles in a single write at the end.
`applyChipDelta` throws if a balance would go negative — the last line of defence.

### Auth flow

```
POST /api/auth/login {provider, ...}
  → verifyLogin()       provider-specific verification → normalised profile
  → upsertFromProfile() find by (provider, provider_user_id) or INSERT + welcome ledger row
  → issueToken()        JWT {sub, provider, name}
  ← {token, user, isNew, welcomeChips}

REST:   Authorization: Bearer <token>   → requireAuth → req.user (fresh DB read every request)
Socket: io(url, {auth: {token}})        → io.use verifies → socket.data.user
```

Login bodies: `{provider:'google', idToken}`, `{provider:'facebook', accessToken}`,
`{provider:'guest', deviceId, displayName?}`. With `AUTH_ALLOW_FAKE_PROVIDERS=true`, a `google`
or `facebook` body **without** its token is accepted as a fake account keyed on
`providerUserId ?? displayName ?? 'fake'` — this is what the browser client's social buttons send.

### REST API

| Method | Path | Auth | Returns / notes |
|---|---|---|---|
| POST | `/api/auth/login` | — | `{token, user, isNew, welcomeChips}` |
| GET | `/api/auth/me` | Bearer | `{user}` |
| GET | `/api/auth/me/hands?limit=20` | Bearer | `{hands[]}` — max 100, joined via ledger |
| GET | `/api/rooms?category=blind\|seen` | — | `{tables: Table.summary()[], options: lobbyOptions()}` |
| POST | `/api/rewards/milestone` | Bearer | `{claimed, amount, milestone, user}` or **409** `reward_not_available` |
| POST | `/api/rewards/bonus` | Bearer | `{claimed, amount, readyAt, user}` or **409** `reward_not_ready` |
| GET | `/api/profiles` | — | `{profiles: [{id, url}]}` from `public/profiles/` |
| POST | `/api/profile/avatar` `{avatar: "cat.svg" \| null}` | Bearer | `{user}`; **409** `seated` while at a table; 400 `unknown_avatar` |
| POST | `/api/profile/name` `{name}` | Bearer | `{user}`; 409 `seated`; 400 `empty_name`/`name_too_long`/`invalid_name` |
| GET | `/health` | — | `{ok, uptime, tables, players, activeHands}` |

Error shape: `{error: <code>, message}`. `AuthError` → its own status; `GameError` → 400;
anything else → 500 `internal_error`.

`user` object shape (from `publicUser`): `id, provider, displayName, email, avatarUrl` (choice
wins over provider), `providerAvatarUrl, avatarChoice, chips, handsPlayed, handsWon, handsLost,
handsLeftMid, totalWinnings, biggestPot, rewards{milestoneAvailable, milestoneAt, milestoneReward,
milestoneEvery, handsToNextMilestone, bonusReadyAt, bonusAvailable, bonusReward, bonusIntervalMs},
createdAt, lastLoginAt`.

### Socket.IO protocol

Connect: `io(url, { auth: { token }, transports: ['websocket', 'polling'] })`. On connect the
server emits `session:ready` and, if the user is already seated (reconnect), `room:joined` +
`chat:history`.

Every client→server handler is wrapped in `guard()`: it acks `{ok: true, ...result}` or
`{ok: false, code, message}` **and** emits `game:error` on failure. Payloads default to `{}`.

**Client → server**

| Event | Payload | Ack result |
|---|---|---|
| `lobby:list` | `{category?}` | `{tables, options}` |
| `room:quickJoin` | `{bootAmount?, category?}` | `{roomId, code, category}` — fullest matching public table with room, else create |
| `room:create` | `{bootAmount?, isPrivate=true, category?}` | `{roomId, code, category}` — private boot is forced to `PRIVATE_BOOT` |
| `room:joinCode` | `{code}` | `{roomId, code, category}` — case-insensitive; entry cap skipped for private |
| `room:switch` | `{}` | `{roomId, code, category}` — same stake+category, public only, no cap re-check |
| `room:leave` | `{}` | `{roomId}` — mid-hand = pack; stake stays in pot |
| `game:action` | `{action, amount?}` | varies — `see\|chaal\|raise\|pack\|show\|sideshow`; `amount` must be an integer rung |
| `game:sideshowRespond` | `{accept: bool}` | `{accepted, packedUserId}` — only the asked player |
| `player:requestCards` | `{}` | `{cards}` — empty unless seen |
| `chat:message` | `{text}` | `{messageId}` — separate tighter limiter |
| `chat:history` | `{}` | `{count}` — re-sends backlog |
| `ping:rtt` | `sentAt` | `{sentAt, serverTime}` — not guarded |

**Server → client**

| Event | To | Payload |
|---|---|---|
| `session:ready` | you | `{user, config}` — config = `publicGameConfig()` (maxPlayers, minPlayers, bootAmount, turnTimeoutMs, welcomeChips, maxBetRounds, categories, stakes, entryCap*, privateBoot, privateMaxPot) |
| `session:replaced` | old socket | `{message}` then disconnect |
| `room:joined` / `room:state` | you / each viewer | Full `serializeFor(viewer)` snapshot (below) |
| `room:left` / `room:closed` | you | `{roomId}` |
| `room:moved` | you | `{fromRoomId, toRoomId, code, message}` — followed by `room:joined` |
| `room:kicked` | you | `{roomId, reason: 'idle'\|'insufficient_chips', message}` |
| `game:handStarted` | room | `{handId, handNo, dealerSeat, bootAmount, pot, stake, participants[]}` |
| `player:hand` | each viewer | `{dealt: true, cardsHidden: true}` — no faces |
| `game:turn` | room | `{userId, seatIndex, deadline, timeoutMs}` |
| `game:yourTurn` | player on turn | `{deadline, timeoutMs, options}` — also re-sent after `see` |
| `game:action` | room | `{userId, action, amount, pot, stake, reason?, auto?}` |
| `game:sideshowRequested` | room | `{fromUserId, fromName, fromSeat, toUserId, toName, toSeat, expiresAt, timeoutMs}` |
| `game:sideshowReveal` | the two players | `{reveal: {reason, packedUserId, hands: [{userId, displayName, cards, handName}×2]}}` |
| `game:sideshowResolved` | room | `{fromUserId, toUserId, accepted, reason, packedUserId}` |
| `game:showdown` | room | `{reveals[], reason}` |
| `game:handEnded` | room | `{handId, handNo, winnerId, winnerName, pot, reason, reveals, summary, nextHandAt}` |
| `player:cards` | owner only | `{cards: ['As','Kd','7h']}` — only after `see` |
| `chat:history` | you | `{roomId, messages[]}` |
| `chat:message` | room | `{id, userId, displayName, text, at, system?}` |
| `game:error` | you | `{code, message}` |

**`room:state` snapshot (`Table.serializeFor(userId)`)**

```jsonc
{
  roomId, code, category, chipsHidden, state, handNo, dealerSeat,
  maxPlayers, minPlayers, bootAmount, turnTimeoutMs, startsAt, pot, maxPot, stake, round,
  sideshow: { fromUserId, fromSeat, toUserId, toSeat, expiresAt } | null,
  turn: { seatIndex, userId, deadline } | null,
  you: { seatIndex, chips, status, isBlind, blindMovesLeft, contributed,
         cards: [],                 // [] until seen
         options: TurnOptions|null  // non-null ONLY when it is your turn and you are active
       } | null,
  seats: [ { seatIndex, status:'empty' } |
           { seatIndex, userId, displayName, avatarUrl,
             chips,                 // null for others on a BLIND table (never 0 — "hidden" ≠ "broke")
             status, isBlind, lastBet, lastAction, contributed, connected, cardCount } ]
}
```

**`TurnOptions`** (`Table.turnOptions`): `{canSee, canSideshow, sideshowWith, chaal, raise,
raiseSteps[], maxBet, show, canPack, isBlind, currentStake, chips, pot}`. `raiseSteps` is the
authoritative +/− ladder; `show` is non-null only with exactly two active players and enough chips.

### The table state machine (`table.js`)

**Table states:** `waiting` → (≥ minPlayers funded) `starting` (countdown `nextHandDelayMs`) →
`betting` → `showdown` → back to `waiting` → `_maybeStart()`.

**Seat states:** `waiting` (seated, sitting out this hand) → `active` → `packed` | `lost` | `won`.
A player joining mid-hand is `waiting` until the next deal.

**Hand lifecycle** (`startHand`):
1. `_sweepUnfunded()` — kick anyone with `chips < bootAmount` (requirement 32). Runs both in
   `_maybeStart` and `startHand` because a player can sit down during the countdown.
2. Dealer rotates clockwise among funded seats. Every seat reset (`cards=[]`, `isBlind=true`,
   `blindMoves=0`, `lastBet=0`, `contributed=0`).
3. `deal()` — three cards each, round-robin.
4. Boot moved to pot from every participant (`_moveToPot` → banks live via `persistChips`).
5. `hand = {id, handNo, pot, stake: boot, round: 0, seatOrder, startSeat, turnSeat, sideshow,
   packedUserIds, lastDeparture, contributions: Map<userId, entry>, showRequestedBy}`.
6. First turn goes to the seat left of dealer (`_nextActiveSeat(dealerSeat)`).

**Turn flow** (`_setTurn` / `_advanceTurn`):
- Each turn: `turnDeadline = now + turnTimeoutMs`, a `turnToken`, emits `turn` (→ `game:turn` +
  `game:yourTurn`), arms the timer.
- Timeout → `missedTurns++`, `_pack(seat, 'timeout')`; at `maxMissedTurns` → `_kick(seat, 'idle')`.
  Any voluntary action resets `missedTurns = 0`.
- Round counter increments when the turn steps *over* `startSeat` (measured by seat distance so
  it stays right after the opener packs). At `maxBetRounds` → `_forcedShowdown()`.
- Before handing on a turn, `_potCapReached()` (`pot + stake > maxPot`) → showdown with reason
  `pot_limit`. Headroom, not equality, so nobody is left on turn with nothing legal.

**Betting maths** (`betOptions`):
```
unit   = hand.stake                        (always in "blind units")
base   = isBlind ? unit : unit * 2         (seen pays double)
potCap = bootAmount * potLimitMultiplier
ceiling = min(potCap, seat.chips)
headroom = maxPot ? maxPot - pot : ∞
steps = [base, base*2, base*4, ...] while step <= ceiling && step <= headroom && len < maxRaiseSteps
chaal = steps[0]; raise = steps[1]; max = steps[last]
```
After a bet: `hand.stake = isBlind ? amount : floor(amount / 2)` — a seen bet halves back into
blind units so both kinds of player stay comparable. `_bet` rejects: non-integer, not on ladder,
`raise` below `2 × steps[0]`, unaffordable. `entry.didChaal = true` on any chaal/raise/show — that
is what "hands played" counts.

**Blind moves:** `see` is free, allowed any time (not only on turn), does not end the turn, and
re-emits `turn` so the client gets the doubled ladder. After `maxBlindMoves` (4) blind bets the
cards auto-reveal (`_see(seat, {auto: true})`) without re-issuing the turn.

**Pack / leave:** `_pack` sets `packed`, emits `action`, then `_resolveIfOnlyOneLeft()`. Leaving
mid-hand (`removePlayer`) is a pack with `entry.leftMidHand = true` and `hand.lastDeparture =
userId`; if everyone leaves, the pot goes to `lastDeparture` (reason `all_left`) — settled by
user id because they no longer hold a seat.

**Show** (two left only): caller pays `showCost` (= their chaal), both reveal, better hand wins;
**exact tie goes to the player who did *not* call**. Forced showdown ties go to the seat nearest
the dealer's left. Never a split pot.

**Sideshow** (requirement 33, server-only — see Gotchas): `sideshowBlockedReason(seat)` returns
`null` or one of `no_hand | not_in_hand | not_your_turn | sideshow_pending | already_asked |
too_few_players | you_are_blind | neighbour_is_blind | no_neighbour`. Target is the active seat on
the asker's **right** (the one who acted just before). Turn timer pauses while pending; 6 s
expiry auto-declines. On accept, hands compared, **asker loses a tie**, loser is packed (turn
only advances if the asker lost), and the asker gets a fresh clock with `freshTurn=false` so they
cannot ask twice in one turn. Cards go only to the two players (`sideshowReveal`); everyone else
gets `sideshowResolved`. A pending sideshow is cancelled if either party leaves.

**Settlement** (`_endHand`): builds `entries[{userId, delta, isWinner, didChaal, leftMidHand}]`
from `hand.contributions` (includes players who already left), calls `settle()`, applies returned
balances to seats. If settlement fails or omits the winner, the winner's seat is credited in
memory so play continues (key presence check — a balance of 0 is valid). Emits `handEnded` with
`nextHandAt`, sets `waiting`, calls `_maybeStart()`.

`destroy()` clears timers and marks `_destroyed`; `_maybeStart`/`startHand` bail when destroyed.

### RoomManager (`roomManager.js`)

- `quickJoin(user, {bootAmount, category})`: asserts not seated, stake allowed (`TABLE_STAKES`),
  `chips >= boot`, entry cap; picks the **fullest** public non-full table matching stake **and**
  category; else `createTable`.
- `joinByCode(user, code)`: uppercase match; entry cap skipped for private tables.
- `switchTable(user)`: refuses on private; finds fullest *other* public table, same stake+category;
  leaves with reason `'moved'` (so no consolidation fires mid-switch) then joins. Entry cap
  deliberately not re-applied.
- `leave(userId, reason)`: `removePlayer`, destroy if empty, else `consolidateTables()` unless
  reason is `'moved'`.
- `_assertUnderEntryCap`: only bites when `bootAmount === entryCapBoot && category ===
  entryCapCategory && chips > entryCapMaxChips` → `over_entry_cap`.
- `consolidateTables()`: candidates = public, `!table.hand`, `state === waiting`, exactly one
  player. Grouped by `category:bootAmount`, oldest table is the destination. `_movePlayer` tries
  the join and restores the seat on failure. Emits `playerMoved`.
- `sweepEmptyTables()`: destroys empty idle tables older than 30 s.
- Interval: both run every `consolidateIntervalMs`; `unref()`'d so tests exit.
- Static `lobbyOptions()`: `{categories, stakes, entryCapBoot, entryCapCategory, entryCapMaxChips,
  privateBoot, privateMaxPot}` — sent in `session:ready.config` and `/api/rooms.options`.

### Socket layer specifics (`socket/index.js`)

- **Per-viewer broadcast.** `table.on('state')` → `broadcastState` emits `room:state` to every
  socket in the room with `serializeFor(thatViewer)`. Never `io.to(room).emit('room:state', ...)`.
- **Single session.** `userSockets: Map<userId, socket>`; a second connection emits
  `session:replaced` to the first and disconnects it.
- **Reconnect.** On connect, a pending removal is cancelled and the seat restored (`room:joined`
  + `chat:history`). On disconnect the seat is held for `reconnectGraceMs` (30 s, unref'd timer);
  the turn clock keeps running.
- **Kick flow.** `Table` emits `kick` → socket layer calls `rooms.leave`, emits `room:kicked`,
  untracks the socket, rebroadcasts. The table never removes players itself.
- **`room:switch` ordering.** Untracks the old room *before* `switchTable` so a `room:closed`
  from destroying the vacated table cannot land on the switching socket; re-tracks on failure.
- **Rate limits.** 30 events / 5 s per socket (all guarded handlers) → `rate_limited`; chat has
  its own `CHAT_RATE_LIMIT` / window → `chat_rate_limited`.
- `wireTable` is idempotent via `table._wired`.

### Rewards and stats

| Reward | Endpoint | Amount | Gate | Stored |
|---|---|---|---|---|
| Milestone | `POST /api/rewards/milestone` | 25,000 | `floor(hands_played/25)*25 > milestone_claimed` | `milestone_claimed` |
| Timed bonus | `POST /api/rewards/bonus` | 10,000 | `now >= next_bonus_at` (0 = ready; new accounts collect immediately) | `next_bonus_at = now + 4h` |

Counters updated in `settleHand`: `hands_played += didChaal`, `hands_won += isWinner`,
`hands_lost += (!isWinner && !leftMidHand)`, `hands_left_mid += leftMidHand`,
`total_winnings += pot (winner)`, `biggest_pot = max`. **"Played" requires a voluntary bet** —
ante-and-fold does not count.

### Chat

Per-table `RoomChat`; never persisted; capped at `CHAT_MAX_HISTORY`; system lines
(`displayName: 'Table'`, `system: true`) for joins/leaves; new joiners get the backlog; destroyed
with the table. Text sanitised server-side (control chars → space, whitespace collapsed, trimmed
to 140).

### Security invariants (do not regress)

1. Card faces are never serialised for anyone but the owner, and only once `isBlind === false`.
   `serializeFor` sends `cardCount` for other seats. `integration.test.js` asserts this.
2. Bet amounts are validated against a server-recomputed ladder; client numbers are never trusted.
3. On a blind table other players' `chips` are `null` on the wire — not hidden client-side.
4. Deck shuffle uses `crypto.randomInt`, never `Math.random`.
5. Guest device ids are SHA-256 hashed before storage.
6. Google audience and Facebook `app_id` are checked; fake providers are impossible in production.
7. `applyChipDelta` refuses negative balances at the DB layer.
8. One live socket per account; per-socket rate limits.

### Scaling

Measured (README): 1000 bots, single process — ~15 % of one core, 162 MB RSS, p99 2 ms. Game
state is **per process**. `REDIS_URL` only shares Socket.IO broadcasts; `Table` objects do not
cross processes, so two players on different processes cannot share a table. Going multi-process
means **routing by room** (consistent hashing on room code, or a lobby that assigns a process),
not sticky sessions alone. `db/users.js` is the only module to change for Postgres/MySQL.

### Commands

```bash
cd server
npm install                     # required — node_modules absent
cp .env.example .env            # optional in dev; set JWT_SECRET for anything else
npm start                       # node src/index.js → http://localhost:3000
npm run dev                     # node --watch src/index.js
npm test                        # node --test --test-timeout=30000 "test/*.test.js"
node --test test/table.test.js  # one suite
node --test --test-name-pattern="sideshow" test/table.test.js
npm run bot -- --count 2 --boot 200 [--category blind] [--url http://host:3000] [--churn 45] [--offset 4]
npm run loadtest -- --players 1000 --seconds 60 [--url ...] [--boot 100] [--batch 25] [--rampDelay 120]
node kicktest.mjs               # manual; needs a running server; writes to the live DB
LOG_LEVEL=debug npm start
```

`loadtest` and `bot` log in as guests, so they need no provider config. `loadtest` defaults to
`--boot 100`, which is **not** in the default `TABLE_STAKES` — pass `--boot 200` or run the
server with `TABLE_STAKES=` empty.

### Tests (`server/test/`)

Plain `node:test` + `node:assert/strict`, ESM, no mocking library. 17 suites, **232 `test()`
cases** (root README says 194).

| Suite | Cases | Covers |
|---|---|---|
| `handRank.test.js` | 13 | Ranking, A-K-Q > A-2-3 > K-Q-J, `aceLowIsLowest`, tie-breaks, shuffle integrity |
| `table.test.js` | 32 | Seating, dealing, turn order, betting, timeouts, show, forced showdown |
| `settlement.test.js` | 7 | Chip conservation on every route a hand can end |
| `chipPersistence.test.js` | 6 | Live banking via `persistChips`; leaver's stake not returned |
| `raiseLadder.test.js` | 17 | Ladder rungs, caps, `invalid_bet`, timeout auto-pack |
| `blindRules.test.js` | 9 | See any time; auto-see after `maxBlindMoves` |
| `categories.test.js` | 11 | Blind/Seen chip visibility per viewer, on the wire |
| `stakes.test.js` | 6 | `TABLE_STAKES` validation |
| `lobbyRules.test.js` | 17 | Display-name normalisation (Unicode scripts), entry cap |
| `tableRules.test.js` | 10 | `all_left` payout; seen-table limits |
| `privateTables.test.js` | 10 | Fixed private boot, `maxPot`, single double, `pot_limit` |
| `seatKeeping.test.js` | 6 | Missed-turn kick, insufficient-chips kick |
| `consolidation.test.js` | 15 | Merging singles; never mid-hand; same stake+category only |
| `statsAndRewards.test.js` | 13 | Counters, both rewards, avatar precedence (real temp SQLite) |
| `chat.test.js` | 14 | Cap, sanitising, room scoping, backlog, destruction |
| `integration.test.js` | 32 | Real sockets + real SQLite: auth, gameplay, capacity, chat, card privacy |
| `socketProtocol.test.js` | 14 | JS port of the **deleted** Unity C# Socket.IO parser against real frames |

**Patterns to follow:**
- Pure engine tests build `new Table({id, code, config, timers, settle})` with
  `createFakeTimers()` from [test/helpers/fakeTimers.js](server/test/helpers/fakeTimers.js)
  (default *and* named export) and `advance(ms)` to drive the clock. `config` is a plain object —
  see `baseConfig` in any suite; `chatMaxHistory`/`chatMaxLength` must be present.
- DB/server tests set `process.env.*` **first**, then `await import('../src/index.js')` — because
  `config` snapshots env at import. Each uses `fs.mkdtempSync(os.tmpdir())` for `DB_FILE`,
  `PORT=0`, `TABLE_STAKES=''`, shortened timeouts, and a `test.after` that closes io/server/db and
  removes the temp dir.
- Integration tests use `socket.io-client`; `socketProtocol.test.js` uses raw `ws`.

### Browser client (`server/public/`)

Vanilla JS IIFE in [client.js](server/public/client.js) (1009 lines), no build step, served at
`/`. Sections: theme, device (stable id in `localStorage`), auth, socket, chat, lobby, render,
showdown, rewards, profile picture, stats, start countdown, timer. Material 3 tokens in
[theme.css](server/public/theme.css) (`:root` = dark, `[data-theme="light"]` overrides);
[style.css](server/public/style.css) has the landscape table layout, square cards with a diagonal
sheen loop, and the "rotate your phone" hint. Token in `localStorage.tp_token`, theme in
`tp_theme`. Handles every server event **except** the `game:sideshow*` family. Social buttons
post fake-provider bodies (dev only).

---

## Flutter client (`flutter-client/`)

### Toolchain and dependencies

Dart SDK `^3.12.2`, Flutter `>= 3.44.0` (from `pubspec.lock`). Uses Dart 3.8+ null-aware element
syntax (`'amount': ?amount`) — older SDKs will not parse it. Neither `flutter` nor `dart` is on
PATH on this machine.

| Package | Locked | Role |
|---|---|---|
| `socket_io_client` | 3.1.6 | Socket.IO v4 client, websocket transport only, auto-reconnect 800 ms |
| `http` | 1.6.0 | REST |
| `provider` | 6.1.5+1 | `ChangeNotifierProvider<GameState>` at the root |
| `shared_preferences` | 2.5.5 | `deviceId`, `token`, `darkMode`, `lang` |
| `flex_color_scheme` | 8.4.0 | M3 light/dark from one seed |
| `flutter_svg` | 2.3.0 | Server-hosted SVG avatars, `card_back.svg` |
| `uuid` | 4.6.0 | Guest device id |
| `cupertino_icons` | 1.0.8 | |
| `flutter_lints` (dev) | 6.0.0 | `analysis_options.yaml` includes `package:flutter_lints/flutter.yaml`, no overrides |

Android: `applicationId com.kinggames.teenpatti`, AGP 9.0.1, Kotlin 2.3.20, JVM 17,
`android.newDsl=false`, `android.builtInKotlin=false`, Gradle JVM `-Xmx8G`. Manifest:
`INTERNET`, `usesCleartextTraffic="true"` (plain-HTTP dev server), `screenOrientation=
sensorLandscape`, label "King Teen Patti". Release build signs with the **debug** key (TODO in
`build.gradle.kts`). Requires `android/local.properties` with `flutter.sdk` (generated by the
Flutter tool, gitignored).

### Layout

```
lib/
├── main.dart                 Orientation lock (landscape both ways), immersiveSticky, GameState.start(),
│                             MaterialApp (theme animation 420 ms), _Root screen switch, _BackGuard
│                             (PopScope: leave-table / quit dialogs), _NoticeHost (snackbars)
├── state/game_state.dart     ChangeNotifier. THE integration point: owns ApiClient + GameConnection,
│                             all UI-readable state, 1 s ticker for countdowns, bet stepper index
├── net/api_client.dart       REST: loginGuest, me, profilePictures, setAvatar, setDisplayName, claimReward
├── net/game_connection.dart  Socket.IO → typed broadcast Streams; _emit() acks → error stream;
│                             request() for ack-returning calls (8 s timeout)
├── models/dtos.dart          Wire readers: SeatState, TableState, TableCategory, GameAction, Rewards, User,
│                             GameConfig (+ .fallback, .cappedFor), Seat, TurnOptions, Turn, You, RoomState,
│                             Reveal, ChatMessage, ProfilePicture. Null-safe: chips:null ≠ 0
├── screens/login_screen.dart Guest name + Play as Guest; Google/Facebook buttons present but inert
├── screens/lobby_screen.dart Horizontal rail of _TableCard (category × stake) + _PrivateCard; _TopBar;
│                             endDrawer = _StatsDrawer | _SettingsDrawer (rename, avatar, language, theme,
│                             sign out); _BonusChip top-left, _MilestoneChip bottom-right; entry-cap overlay
├── screens/table_screen.dart _SideRail (menu, chat badge) | _Felt (SeatPods around oval, _Pot, _Status,
│                             _OwnHand, _Dealt, _Showdown + Fireworks, _Banner) / _ActionBar
│                             ([−][Chaal n][+], See, Pack, Show); _TableDrawer; _ChatSheet
├── widgets/seat_pod.dart     One seat: avatar, name, chips/hidden, LiquidFill turn clock, bet bubble, chat bubble
├── widgets/playing_card.dart Face up/down card with flip animation
├── widgets/poker_chip.dart   Drawn chip + ChipStack
├── widgets/avatar.dart       Network/SVG avatar with fallback initial
├── widgets/fireworks.dart    Win celebration CustomPainter
├── widgets/liquid_fill.dart  Turn-clock liquid CustomPainter
├── widgets/premium_surface.dart  Gradient/lit-edge surface + Glint sheen
├── widgets/rules_sheet.dart  Translucent hand-ranking reference dialog
├── theme/app_theme.dart      FlexThemeData light/dark from seed #0F5236; gold #C9A227; fixed card colours
└── l10n/strings.dart         Hand-rolled Strings(lang) map — English, Hindi, Bengali, Gujarati, Punjabi
                              (~105 keys × 5); falls back to English then to the key. Not gen_l10n/ARB
```

### Architecture notes

- **No Navigator.** `GameState.screen` (`login | lobby | table`) drives `_Root`'s `switch`; the
  server decides where the player is. Back gesture is intercepted by `_BackGuard`.
- **State comes from `room:state`.** `GameState` reads `room.you.options` for the turn; it does
  **not** subscribe to `game:turn` / `game:yourTurn` / `game:action` / `player:hand`. It handles
  `session:ready`, `room:joined|state|moved|left|kicked|closed`, `player:cards`, `game:showdown`,
  `game:handEnded`, `chat:message|history`, `game:error`, `session:replaced`.
- **Sideshow is absent.** `GameAction` has no `sideshow`; `TurnOptions` ignores `canSideshow`;
  no `game:sideshow*` listeners. See Gotchas.
- **Ack semantics.** `_emit` fires-and-forgets but pushes `{ok:false}.message` onto `onError`;
  `request()` awaits the ack (used by `switchTable` so the lobby never flashes mid-switch via
  `switching`).
- **Persistence.** `deviceId` (UUID v4, generated once), `token`, `darkMode`, `lang` in
  `SharedPreferences`. A saved token goes straight to the lobby after `GET /api/auth/me`.
- **Server URL.** `--dart-define=SERVER_URL=http://host:3000`; default `http://10.0.2.2:3000`
  (Android-emulator loopback). `absoluteUrl()` prefixes server-relative avatar paths.
- **Seat ordering.** `seatsInViewOrder()` rotates so the viewer is always at the bottom.
- **Chat bubbles** over seats for 3 s; local chat list mirrors the server's 100 cap.
- **Theme.** Light by default; toggle persisted. Table felt and cards are fixed colours by design.

### Commands

```bash
cd flutter-client
flutter pub get
flutter run --dart-define=SERVER_URL=http://192.168.1.5:3000     # device on LAN
flutter run                                                     # emulator → 10.0.2.2:3000
flutter analyze
flutter test                                                    # FAILS — see Gotchas #6
flutter build apk --release                                     # debug-signed
```

---

## Coding conventions

**JavaScript (server).** ESM, `.js` on relative imports, 2-space indent, single quotes,
semicolons, trailing commas, `const`/arrows, `Number.parseInt`, `??`/`?.`. No ESLint/Prettier —
match neighbouring code by eye. Private-by-convention methods are `_prefixed`. Section dividers
`// ---------------------- name` inside long files. Errors: `GameError(code, message)` from game
code, `AuthError(code, message, status)` from auth, both mapped centrally in `index.js` and
`socket/index.js` — never hand-format an error payload at a call site. Error codes are
`snake_case` strings and are part of the protocol (clients show `message`, may branch on `code`).

**Comments explain *why*, not *what*.** Density is high and deliberate: JSDoc on every export and
on non-obvious internals; inline comments carry design rationale and requirement numbers ("Null
rather than 0, so the client shows 'hidden' instead of 'broke'"; "the `!table.hand` check is the
important one"). A change that strips a rationale comment is a regression. Match this in Dart too
— the widget files explain intent the same way.

**Dart.** `flutter_lints` defaults. Records for multi-value returns (`({String token, User user})`),
`context.select` for narrow rebuilds, `context.watch` in screens, private widgets `_Prefixed`, DTO
`fromJson` factories with `_int`/`_str` coercion helpers. Strings go through `state.t.<key>`,
never literals in widgets.

**Tests.** One suite per requirement cluster, header docblock naming the requirement(s), `test()`
names as plain English sentences.

---

## Gotchas

1. **`node_modules` is not installed**; `flutter`/`dart` are not on PATH. `cd server && npm install`
   before anything. Flutter work cannot be run or analysed locally without installing the SDK.
2. **Root `README.md` and `server/README.md` are stale.** Root says "194 tests" (232), lists
   "Side show — not in the brief" under *Not included* (it **is** requirement 33 and **is**
   implemented server-side), never mentions `flutter-client/`, and its requirement table stops at
   #28 (29–33 are implemented). `server/README.md` says `BOOT_AMOUNT` default is 100 (it is 200)
   and omits `room:switch`, `room:kicked`, `player:hand`, `ping:rtt`, all `game:sideshow*`,
   `POST /api/profile/name`, and `MAX_BLIND_MOVES`. Both still describe the Unity client.
3. **Sideshow is server-only.** `table.js`, `socket/index.js`, `config` implement it fully;
   **neither client** sends `sideshow`/`game:sideshowRespond` or listens for
   `game:sideshowRequested|Reveal|Resolved`. Largest functional gap in the repo. Note the turn
   clock *pauses* while a request is pending — a client that ignores the event will see a frozen
   countdown for up to 6 s.
4. **`config` snapshots `process.env` at import time.** Set env, *then* `await import()`. Any
   module that transitively imports `config` (nearly all of `src/`) locks it in.
5. **`TABLE_STAKES` empty means "any stake".** Tests depend on this for isolation; do not make an
   empty list mean "no tables".
6. **`flutter-client/test/widget_test.dart` is the untouched counter template.** It imports
   `MyApp`, which does not exist (`KingTeenPattiApp`), so `flutter test` fails to compile. Fix or
   delete before relying on Flutter tests.
7. **Unity client deleted; leftovers remain.** `server/test/socketProtocol.test.js` +
   `test/helpers/csharpJsonPort.js` are a JS port of the deleted `SocketIOClient.cs`. They pass
   and do exercise real Engine.IO/Socket.IO frames, but their stated purpose (guarding a C# file)
   is gone. Keep or delete deliberately; don't "sync" them to a file that no longer exists.
   `public/client.js` header and both READMEs still say "same protocol as the Unity client".
   `Requirements.txt` still asks for Unity.
8. **`ws` is used but not declared** in `server/package.json`. `socketProtocol.test.js` works only
   because `engine.io` hoists it. Add it to `devDependencies` if the lockfile ever changes shape.
9. **Redis does not shard game state.** See Scaling. Sticky sessions alone are insufficient.
10. **Only guest login actually works end-to-end.** Server verification for Google/Facebook is
    real, but: the browser client's social buttons post fake-provider bodies (accepted only with
    `AUTH_ALLOW_FAKE_PROVIDERS=true`, which production forbids); the Flutter client has
    `loginGuest` only, and its Google/Facebook buttons are inert. Real social login needs
    `google_sign_in` / `flutter_facebook_auth` posting `idToken` / `accessToken`.
11. **`flutter-client/` has `android/` only** — no `ios/`, `web/`, `macos/` despite the brief.
    `flutter create --platforms=ios,web .` to add them; iOS will additionally need an ATS exception
    for plain HTTP in dev.
12. **Reward amounts are hard-coded** in `db/users.js` (`MILESTONE_REWARD`, `TIMED_BONUS_REWARD`,
    intervals), not env — unlike everything else.
13. **Card privacy is load-bearing.** `serializeFor` must keep sending `cardCount` (not `cards`)
    for other seats, and `you.cards` only when `!isBlind`. `integration.test.js` asserts an
    opponent never receives faces.
14. **Chat is never persisted.** Do not add a chat table. The room's `RoomChat` dies with the
    table.
15. **`loadtest.js` defaults to `--boot 100`**, which the default lobby (`200,5000`) rejects with
    `invalid_stake`. Pass `--boot 200` or start the server with `TABLE_STAKES=`.
16. **`kicktest.mjs` writes directly to the live database** (`UPDATE users SET chips`). Run it
    only against a throwaway `DB_FILE`.
17. **Private tables ignore the entry cap and the requested boot.** `room:create` with
    `isPrivate` always uses `PRIVATE_BOOT`; `joinByCode` skips `_assertUnderEntryCap` for them.
    `room:switch` is refused on private tables.
18. **Room codes are case-insensitive on lookup** (`toUpperCase`), 6 chars, no `0/O/1/I`.
19. **Branch state.** `docs/claude-md` has 145 staged deletions (`unity-client/`) and this
    untracked file; nothing committed yet. `master` still contains the Unity client.
