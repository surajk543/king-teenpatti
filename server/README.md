# King Teen Patti — Server

Authoritative game server: Node.js 20+, Socket.IO 4, SQLite (better-sqlite3).

## Running

```bash
npm install
cp .env.example .env      # set JWT_SECRET; add provider credentials if you want Google/Facebook
npm start                 # http://localhost:3000
npm run dev               # with --watch
npm test                  # 194 tests
```

The bundled browser client is served from `/` — useful for playing, for filling a table while
testing the Unity build, and as a reference implementation of the protocol.

## Configuration

Everything is environment-driven; see [.env.example](.env.example) for the annotated list.
The settings you are most likely to change:

| Variable | Default | Meaning |
|---|---|---|
| `JWT_SECRET` | — | **Required in production.** Signs session tokens. |
| `GOOGLE_CLIENT_IDS` | — | Comma-separated OAuth client ids (web, android, ios). |
| `FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET` | — | Used to verify access tokens. |
| `AUTH_ALLOW_FAKE_PROVIDERS` | `false` | Dev only. Skips provider verification. Forced off in production. |
| `WELCOME_CHIPS` | `200000` | First-login grant (2 lakh). |
| `BOOT_AMOUNT` | `100` | Default ante. |
| `TURN_TIMEOUT_MS` | `25000` | Turn clock. |
| `MAX_BET_ROUNDS` | `20` | Rounds before a forced showdown. |
| `MAX_RAISE_STEPS` | `8` | Rungs on the +/− raise ladder. |
| `TABLE_STAKES` | `200,5000` | Stakes the lobby offers. Empty means any stake is allowed. |
| `SEEN_MAX_RAISE_STEPS` | `2` | Seen tables: one double per turn. |
| `SEEN_MAX_BET_ROUNDS` | `7` | Seen tables: showdown after 7 rounds. |
| `PRIVATE_MAX_POT` | `500000` | Private tables: pot ceiling. |
| `PRIVATE_MAX_RAISE_STEPS` | `2` | Private tables: one double per turn. |
| `CONSOLIDATE_INTERVAL_MS` | `15000` | How often half-empty rooms are merged. |
| `PRIVATE_BOOT` | `200` | Private tables: the fixed boot. Not chosen by the player. |
| `CHAT_MAX_HISTORY` | `100` | Messages kept per room, in memory. |
| `REDIS_URL` | — | Enables the Socket.IO Redis adapter. |

Production refuses to boot with a default `JWT_SECRET` or with fake providers enabled.

## REST API

| Method | Path | Body / Auth | Returns |
|---|---|---|---|
| `POST` | `/api/auth/login` | `{provider, ...}` | `{token, user, isNew, welcomeChips}` |
| `GET` | `/api/auth/me` | Bearer token | `{user}` |
| `GET` | `/api/auth/me/hands` | Bearer token | `{hands}` — recent hand history |
| `GET` | `/api/rooms` | `?category=blind\|seen` | `{tables, options}` — open tables, optionally filtered |
| `POST` | `/api/rewards/milestone` | Bearer token | Collects 25,000 chips for reaching a multiple of 25 hands played |
| `POST` | `/api/rewards/bonus` | Bearer token | Collects the 10,000 chip bonus and restarts its 4-hour countdown |
| `GET` | `/api/profiles` | — | `{profiles}` — the bundled pictures a player may choose |
| `POST` | `/api/profile/avatar` | `{avatar}` + token | Chooses a picture; `null` restores the provider one. Refused while seated |
| `GET` | `/health` | — | `{ok, uptime, tables, players, activeHands}` |

Login bodies by provider:

```jsonc
{ "provider": "google",   "idToken": "<Google Sign-In id_token>" }
{ "provider": "facebook", "accessToken": "<Facebook user access token>" }
{ "provider": "guest",    "deviceId": "<stable device id>", "displayName": "Optional" }
```

The account is created on first sight with the welcome grant, and looked up by
`(provider, provider_user_id)` on every later login. Guest device ids are SHA-256 hashed before
they are stored.

## Socket.IO protocol

Connect with the session token in the handshake:

```js
io("http://localhost:3000", { auth: { token }, transports: ["websocket", "polling"] });
```

### Client → server

| Event | Payload | Ack | Notes |
|---|---|---|---|
| `room:quickJoin` | `{bootAmount, category}` | `{ok, roomId, code, category}` | Seats you at a matching table, else creates one. `category` is `seen` or `blind` |
| `room:create` | `{bootAmount, isPrivate, category}` | `{ok, roomId, code, category}` | |
| `room:joinCode` | `{code}` | `{ok, roomId, code}` | |
| `room:leave` | `{}` | `{ok, roomId}` | Mid-hand this counts as a pack |
| `game:action` | `{action, amount?}` | `{ok}` or `{ok:false, code, message}` | `see` \| `chaal` \| `raise` \| `pack` \| `show`. `amount` is the rung picked on the +/− stepper; omit it for the default |
| `player:requestCards` | `{}` | `{cards}` | Re-fetch your own hand after a reconnect |
| `chat:message` | `{text}` | `{ok, messageId}` | Room-scoped |
| `chat:history` | `{}` | `{count}` | Re-pull the backlog |
| `lobby:list` | `{category?}` | `{tables, options}` | `options` carries the offered categories and stakes |

### Server → client

| Event | Payload | Sent to |
|---|---|---|
| `session:ready` | `{user, config}` | you, on connect |
| `session:replaced` | `{message}` | you, when a second sign-in kicks this one |
| `room:joined` | full table snapshot | you |
| `room:state` | full table snapshot | each viewer, redacted per viewer |
| `room:left` / `room:closed` | `{roomId}` | you |
| `room:moved` | `{fromRoomId, toRoomId, code, message}` | you, when two half-empty rooms are merged |
| `game:handStarted` | `{handId, handNo, dealerSeat, pot, stake, participants}` | room |
| `game:turn` | `{userId, seatIndex, deadline, timeoutMs}` | room |
| `game:yourTurn` | `{deadline, timeoutMs, options}` | **only the player on turn** |
| `game:action` | `{userId, action, amount, pot, stake, reason}` | room |
| `game:showdown` | `{reveals, reason}` | room |
| `game:handEnded` | `{winnerId, winnerName, pot, reason, reveals, summary, nextHandAt}` | room |
| `player:cards` | `{cards}` | **only that player**, only after `see` |
| `chat:history` | `{roomId, messages}` | you, on join |
| `chat:message` | `{id, userId, displayName, text, at, system}` | room |
| `game:error` | `{code, message}` | you |

`options` on `game:yourTurn` is the authoritative list of legal moves and their costs:

```jsonc
{
  "canSee": true,                        // you have not looked yet
  "chaal": 100,                          // bet the same amount; null if unaffordable
  "raise": 200,                          // bet double
  "raiseSteps": [100, 200, 400, 800],    // the +/- ladder: every legal bet, ascending
  "maxBet": 800,                         // the largest bet available right now
  "show": null,                          // cost of a show, only with two players left
  "canPack": true,
  "isBlind": true,
  "currentStake": 100,
  "chips": 950,                          // what the player has left
  "pot": 200
}
```

The client renders exactly these options and decides nothing itself.

### The bet ladder

`raiseSteps` is the ladder the **+** and **−** buttons walk. Each rung is double the last, and index
0 is the plain chaal.

Clients render this as a single control — **[ − ][ Chaal *n* ][ + ]** — where the steppers pick the
amount and the Chaal button places the bet. Send `chaal` when the chosen amount is the base rung and
`raise` for anything above it, so the action log stays meaningful.

The ladder stops at whichever limit bites first:

- `BOOT_AMOUNT x POT_LIMIT_MULTIPLIER` — the table's pot limit;
- the player's **own chip stack** — so no rung is ever unaffordable;
- `MAX_RAISE_STEPS` rungs.

A client sends the rung it landed on as `{"action":"raise","amount":800}`. The server rebuilds the
ladder and refuses anything that is not on it (`invalid_bet`), so an amount larger than the player's
stack cannot be staked however the client behaves. A stack that affords only one rung gets a chaal
and no raise — the **+** button has nowhere to go.

## Game rules as implemented

**Hand ranking** (high to low): Trail, Pure Sequence, Sequence, Color, Pair, High Card.

Sequences order as **A-K-Q > A-2-3 > K-Q-J > … > 4-3-2**, the standard Teen Patti ordering where
the ace plays high in A-K-Q and low in A-2-3. If you want the variant where A-2-3 is the *weakest*
run, pass `{ aceLowIsLowest: true }` to `evaluate` — it is tested both ways.

**Betting.** Stake is always tracked in blind units. A blind player bets `stake` or `2 × stake`;
a seen player bets `2 × stake` or `4 × stake`. A seen player's bet halves back into the stake, so
the two kinds of player stay comparable. Bets are capped at `BOOT_AMOUNT × POT_LIMIT_MULTIPLIER`.

**Show.** Legal only with exactly two players left. The caller pays their normal chaal amount, both
hands are revealed, and the better hand takes the pot. An exact tie goes to the player who did
**not** call the show. A forced showdown at the round cap breaks ties by seat order from the
dealer's left. There is never more than one winner and the pot is never split.

### Table categories

The lobby offers two categories at every stake. They differ in one thing — whether you can see other
players' chip stacks:

| | Your chips | Other players' chips |
|---|---|---|
| **Seen** | visible | visible |
| **Blind** | visible | hidden |

Quick-join matches on **both** stake and category, so a blind table and a seen table at the same
boot are different rooms. On a blind table `serializeFor` sends `null` for every seat but the
viewer's own and sets `chipsHidden: true` — the figure never reaches the client, so this is a real
privacy boundary. A seat's `contributed` and the pot stay public in both categories, since bets are
announced as they are made. An unrecognised category falls back to `seen`, so chips are never hidden
by accident.

### Rewards

| Reward | Trigger | Amount | Stored as |
|---|---|---|---|
| Milestone | every 25 hands **played** | 25,000 | `milestone_claimed` |
| Timed bonus | every 4 hours | 10,000 | `next_bonus_at` |

Both are decided by the server. A milestone pays once per milestone however often the endpoint is
called, and the bonus refuses until its stored unlock time has passed — so neither can be farmed by
replaying a request or reinstalling the client. A brand new account can collect the bonus straight
away; every collection after that starts a fresh 4-hour countdown.

"Played" counts only hands where the player committed chips beyond the boot (a chaal, a raise, or
paying for a show). Posting the ante and folding immediately is not a hand played, which is what the
milestone is measured against.

### Filling tables

Two rooms each down to a single player are merged (requirement 24). `consolidateTables()` runs on a
timer and immediately after any departure, since that is exactly when a table drops to one.

A table is only eligible when it is **public, idle and holding exactly one player** — the `!table.hand`
check is the important one, because it is what guarantees a player is never moved out from under a
live game. Tables are grouped by `category:bootAmount`, so a player never lands on a different stake
or category than the one they picked, and the longest-standing room is the destination.

The moved player gets a `room:moved` notice followed by a normal `room:joined` for the new table, so
the client follows along without a reconnect. Once two players are seated the table enters
`starting` with a `startsAt` deadline, which clients render as "Starting game in N seconds".

### Private tables

A private table is created with `room:create` and reached by its code. It carries its own rules
(requirement 22):

| | Private | Public |
|---|---|---|
| Boot | fixed at `PRIVATE_BOOT` (200) | one of `TABLE_STAKES` |
| Maximum win | `PRIVATE_MAX_POT` (500,000) | uncapped |
| Doubles per turn | one | seen: one, blind: unlimited |

The boot is **not** a choice: whatever `bootAmount` a client sends for a private table is replaced
with the configured one, so there is nothing to validate and no way to open a room at another
amount. Clients read `privateBoot` from the session config purely to label the button.

The ceiling is enforced in two places. `betOptions` withholds any rung that would push the pot past
it, so an over-the-top bet is never offered; and once the pot is close enough that not even the
smallest legal bet fits underneath, the hand resolves as a showdown with reason `pot_limit`. Checking
the headroom rather than only equality matters — otherwise a player could be left on turn with
nothing legal to do but fold.

**Timeouts.** A player who does not act inside `TURN_TIMEOUT_MS` is packed and play continues.
A disconnected player keeps their seat for `RECONNECT_GRACE_MS`, but their turn still times out
normally — dropping your connection is not a way to stall a table.

## Database

Three tables (see [schema.sql](src/db/schema.sql)):

- `users` — one row per `(provider, provider_user_id)`, holding chips and lifetime stats.
- `hands` — one row per completed hand, with a JSON summary of every seat, for auditing.
- `chip_ledger` — every chip movement, with the resulting balance. `users.chips` can be
  reconciled against this at any time. Reward grants appear here as `milestone_reward` and
  `timed_bonus`, so free chips are as auditable as anything won at a table.

`users` also carries the play record and reward state: `hands_played`, `hands_won`, `hands_lost`,
`hands_left_mid`, `total_winnings`, `milestone_claimed` (the highest milestone already collected)
and `next_bonus_at` (when the timed bonus unlocks). Columns added after a database was first created
are applied by an idempotent migration on boot, so an existing `teenpatti.db` upgrades in place.

SQLite runs in WAL mode with `synchronous = NORMAL`. All gameplay is in memory; the database is
touched at login, once per completed hand, and on chip grants. A crash mid-hand loses that hand's
bets rather than half-applying them — bets never reach the database until the hand settles.

## Scaling

Measured on one machine, single process, 1000 bot players: **~15% of one CPU core, 162 MB RSS,
p99 action latency 2 ms, 0 errors.** The 500–1000 target has ample headroom in one process.

To go further, be aware of the real constraint: **game state is per process.** Setting `REDIS_URL`
enables the Socket.IO Redis adapter, which shares *broadcasts* across processes — but it does not
share the `Table` objects. Two players on different processes cannot sit at the same table.

So horizontal scaling means **sharding rooms**, not just adding processes:

1. Run N game processes, each owning its own tables.
2. Put a router in front that assigns a player to a process and keeps them there (consistent
   hashing on room code, or a lobby service that hands out a process address on join).
3. Keep SQLite per process, or move to Postgres/MySQL if you want one shared account store —
   `src/db/users.js` is the only module that would change.

Sticky sessions alone are **not** sufficient; they keep a socket on one process but do not stop two
players being routed to different processes for the same room.

## Layout

```
src/
├── index.js            Express + Socket.IO bootstrap, graceful shutdown
├── config/             Environment parsing, production safety checks
├── auth/
│   ├── providers.js    Google / Facebook / guest verification
│   ├── tokens.js       Session JWTs
│   └── routes.js       REST endpoints
├── db/
│   ├── schema.sql      Tables and indexes
│   ├── index.js        Connection, WAL pragmas, migration on boot
│   └── users.js        Accounts, chip ledger, hand settlement
├── game/
│   ├── deck.js         Crypto-secure shuffle and dealing
│   ├── handRank.js     Hand evaluation and comparison
│   ├── table.js        The game state machine (turn order, betting, showdown)
│   ├── chat.js         Per-room in-memory chat buffer
│   ├── roomManager.js  Table lifecycle, matchmaking, sweeping
│   └── constants.js    Shared enums
├── socket/index.js     Socket.IO handlers, per-viewer state redaction
└── util/               Logger, id generation
```
