# King Teen Patti — Server

Authoritative game server: Node.js 20+, Socket.IO 4, PostgreSQL (via `pg`).

## Running

```bash
npm install
cp .env.example .env      # set JWT_SECRET; add provider credentials if you want Google/Facebook
npm start                 # http://localhost:3000 — needs PostgreSQL (see Database below)
npm run dev               # with --watch
npm test                  # every suite; the process suites need PostgreSQL too
```

PostgreSQL must be reachable at `DATABASE_URL` (default
`postgres://postgres:postgres@localhost:5432/gameplay`). The schema is created on boot.

The bundled browser client is served from `/` — a zero-build reference implementation of the
protocol, handy for filling a table while testing. The live client is `../flutter-client`.

## Configuration

Everything is environment-driven; see [.env.example](.env.example) for the annotated list.
The settings you are most likely to change:

| Variable | Default | Meaning |
|---|---|---|
| `JWT_SECRET` | — | **Required in production.** Signs session tokens. |
| `GOOGLE_CLIENT_IDS` | — | Comma-separated OAuth client ids (web, android, ios). |
| `FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET` | — | Used to verify access tokens. |
| `AUTH_ALLOW_FAKE_PROVIDERS` | `false` | Dev only. Skips provider verification. Forced off in production. |
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/gameplay` | PostgreSQL connection string. |
| `PG_SCHEMA` | `public` | Schema the tables live in. Tests use a throwaway schema each. |
| `PG_POOL_MAX` | `10` | Connection pool size. |
| `WELCOME_CHIPS` | `200000` | First-login grant (2 lakh). |
| `BOOT_AMOUNT` | `200` | Default ante. |
| `TURN_TIMEOUT_MS` | `25000` | Turn clock. |
| `MAX_BET_ROUNDS` | `20` | Rounds before a forced showdown (default tables; seen and blind override it). |
| `MAX_RAISE_STEPS` | `8` | Rungs on the +/− raise ladder (default tables; seen and blind override it). |
| `TABLE_STAKES` | `200,5000` | Stakes the lobby offers. Empty means any stake is allowed. |
| `LOBBY_TABLES` | `seen:200,blind:200,blind:5000` | The rooms on the menu, as `category:boot` pairs, in display order. |
| `SEEN_MAX_POT` | `1200000` | Seen tables: pot ceiling (0 = uncapped). Blind tables are uncapped. |
| `MAX_BLIND_MOVES` | `4` | Blind bets before the cards turn face up by themselves. |
| `ENTRY_CAP_BOOT` / `ENTRY_CAP_CATEGORY` / `ENTRY_CAP_MAX_CHIPS` | `200` / `blind` / `500000` | Players above the cap cannot join that table from the lobby. |
| `MAX_MISSED_TURNS` | `3` | Consecutive timed-out turns before the seat is given up. |
| `SIDESHOW_TIMEOUT_MS` / `SIDESHOW_MIN_PLAYERS` | `6000` / `3` | Sideshow request window and minimum active players. |
| `DISPLAY_NAME_MAX` | `24` | Longest display name accepted. |
| `NEXT_HAND_DELAY_MS` / `RECONNECT_GRACE_MS` | `4000` / `60000` | Countdown before a deal; how long a dropped connection keeps its seat. |
| `RESUME_OFFER_MS` | `600000` | After the seat lapses, how long the table a player fell off is offered back on their next sign-in (`session:ready.resume`). |
| `SEEN_MAX_RAISE_STEPS` | `2` | Seen tables: one double per turn. |
| `METRICS_ENABLED` / `METRICS_PATH` / `METRICS_PREFIX` | `true` / `/metrics` / `game_server_` | Prometheus exposition; see `ops/monitoring/MONITORING.md`. |
| `METRICS_TOKEN` / `METRICS_ALLOW_IPS` | empty | Bearer token and/or client-IP allow-list for `/metrics`. Set at least one before exposing the port publicly. |
| `SEEN_MAX_BET_ROUNDS` | `7` | Seen tables: showdown after 7 rounds. |
| `BLIND_MAX_RAISE_STEPS` / `BLIND_MAX_BET_ROUNDS` / `BLIND_POT_LIMIT_MULTIPLIER` | `0` / `0` / `0` | Blind tables: 0 = no limit. The ladder runs to the player's stack, no per-bet ceiling, and no forced showdown — the turn rotates until a pack or a show. |
| `PRIVATE_MAX_POT` | `500000` | Private tables: pot ceiling. |
| `PRIVATE_MAX_RAISE_STEPS` | `2` | Private tables: one double per turn. |
| `CONSOLIDATE_INTERVAL_MS` | `15000` | How often half-empty rooms are merged. |
| `PRIVATE_BOOT` | `200` | Private tables: the fixed boot. Not chosen by the player. |
| `CHAT_MAX_HISTORY` | `100` | Messages kept per room, in memory. |
| `REDIS_URL` | — | Enables the Socket.IO Redis adapter (broadcast sharing only — not needed by the worker cluster). |
| `WORKER_ID` | — | Unset or `0` = single process (everything as before). `1..N` = this process is one worker of a cluster; see [Deployment](#deployment-workers). |
| `WORKER_COUNT` | `1` | How many workers the cluster has (informational for the registry; nginx and systemd decide who actually runs). |
| `WORKER_BASE_PORT` | `3100` | Worker `i` listens on `WORKER_BASE_PORT + i` (3101, 3102, …). A worker ignores `PORT` — the production `.env` still says `PORT=3000` and dotenv would otherwise put every worker on it. |
| `WORKER_PORT` | — | Explicit listen port for a worker (overrides `WORKER_BASE_PORT + WORKER_ID`). Never set `WORKER_*` in `.env`: the systemd unit supplies them per worker and the file would override it. |

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
| `POST` | `/api/profile/name` | `{name}` + token | Changes the display name (letters, digits, spaces). Refused while seated |
| `GET` | `/health` | — | `{ok, uptime, tables, players, activeHands, sockets, process, db}` — one process's own numbers (in cluster mode: whichever worker answered) |

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
| `room:joinCode` | `{code}` | `{ok, roomId, code}` | Cluster mode: a code that lives on another worker is answered `{ok:false, code:'other_worker', path}` together with a `session:redirect`; the client reconnects on `path` and repeats the join |
| `room:leave` | `{}` | `{ok, roomId}` | Mid-hand this counts as a pack |
| `game:action` | `{action, amount?, actionId?}` | `{ok}` or `{ok:false, code, message}` | `see` \| `chaal` \| `raise` \| `pack` \| `show` \| `sideshow`. `amount` is the rung picked on the +/− stepper; omit it for the default. `actionId` is the client's own id for the move — it is unique on the ledger, so a repeated request is refused (`duplicate_action`) rather than charged twice |
| `game:sideshowRespond` | `{accept}` | `{ok, accepted, packedUserId}` | Only the player who was asked may answer; the request lapses by itself after `SIDESHOW_TIMEOUT_MS` |
| `room:switch` | `{}` | `{ok, roomId, code, category}` | Moves to another table at the same stake and category (not entry-cap checked) |
| `player:requestCards` | `{}` | `{cards}` | Re-fetch your own hand after a reconnect |
| `chat:message` | `{text}` | `{ok, messageId}` | Room-scoped |
| `chat:history` | `{}` | `{count}` | Re-pull the backlog |
| `lobby:list` | `{category?}` | `{tables, options}` | `options` carries the offered categories and stakes |

### Server → client

| Event | Payload | Sent to |
|---|---|---|
| `session:ready` | `{user, config, worker: {id, path}, resume?}` | you, on connect. `worker.id` is `0` and `worker.path` `/socket.io` in single-process mode; in cluster mode `{id: 2, path: '/w2/socket.io'}` — remember the path and connect with it next time |
| `session:redirect` | `{worker, path, reason: 'seat' \| 'room', joinCode?}` | you, **instead of** `session:ready`, when your seat (or the private table you asked for) lives on another worker. The socket is closed right after; reconnect on `path`, then send `room:joinCode {code: joinCode}` if it was given |
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
| `game:sideshowRequested` / `game:sideshowResolved` | who asked whom, the outcome — never cards | room |
| `game:sideshowReveal` | `{reveal: {hands, packedUserId}}` | **only the two players comparing** |
| `room:kicked` | `{roomId, reason, message}` | you, when the table shows you out (`idle`, `insufficient_chips`) |
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
Every rule is enforced here, never trusted from a client. `test/invalidMoves.test.js` plays a
tampered client against the live server: moves out of turn, bets off the ladder (negative, between
rungs, more than the stack, strings or arrays coerced to numbers), shows with three players,
sideshows with two, replays of the same `actionId`, joins while seated (including `room:create`),
full tables, empty and over-long chat, garbage payloads on every event, and request bursts. Each
is refused with a code, acknowledged (a rate-limited request is answered `rate_limited` rather
than dropped), and leaves every wallet equal to its ledger.

A reconnecting player is put straight back at their table: `session:ready` is followed by
`room:joined` with their own view of the hand (cards included if already seen). Once the seat
has lapsed, `session:ready` carries `resume: { roomId, code, category, bootAmount }` for
`RESUME_OFFER_MS` after the drop, provided the table still exists and has room; the client
takes it up with an ordinary `room:joinCode`. Leaving on purpose, or being kicked, leaves no
offer. The offer is made once.

A disconnected player keeps their seat for `RECONNECT_GRACE_MS`, but their turn still times out
normally — dropping your connection is not a way to stall a table.

## Database

PostgreSQL. Eight tables (see [schema.sql](src/db/schema.sql)); the schema is applied on every boot
and is fully idempotent.

- `users` — one row per `(provider, provider_user_id)`. `chips` is the wallet (`CHECK (chips >= 0)`).
- `hands` — one row per completed hand, with a JSON summary of every seat, for auditing.
- `pots` — one row per hand: opened when the boots are collected, grown by every bet, closed to the
  winner at settlement.
- `chip_ledger` — **append-only** (a trigger refuses UPDATE and DELETE). Every chip movement, with
  the resulting balance and the client's `action_id`, which is UNIQUE — a retried bet can never
  deduct twice. `SUM(delta)` per user must always equal `users.chips`.
- `game_states` — the authoritative snapshot of each live table with a monotonically rising
  `version`; a write carrying an older version is refused.
- `cluster_workers`, `cluster_players`, `cluster_rooms` — the worker registry (cluster mode only;
  empty and unread in single-process mode): which worker is alive (heartbeat every 5 s), which
  worker holds each seated player, which worker owns each table code. Routing data, not money —
  see [Deployment](#deployment-workers).

**Money is database-first.** A bet is validated in memory (turn, amount, balance), then written as
one transaction — lock the wallet row `FOR UPDATE`, deduct, add to the pot, append the ledger row,
save the table state/version — and only once that has committed does the table change what it
holds in memory and broadcast to players. A write that fails leaves the game exactly as it was and
the player's move is refused (`persist_failed`, `insufficient_chips`, `duplicate_action`). The
boots for a hand are collected the same way before a card is dealt, and settlement pays the winner
in the same shape. See [ledger.js](src/db/ledger.js).

Because those writes are asynchronous, every mutation of a table runs through a per-table queue,
so a turn timeout can never interleave with a bet that is halfway to the database.

## Deployment (workers)

One Node process handles ~1,000 players at ~15 % of a core, but the event loop is single-threaded:
the 2026-09-08 ramp tests pinned one of the four production cores at ~90 % from about 4,000
players while the other three idled. Production therefore runs **N worker processes** — the same
code, `WORKER_ID=1..N` — behind nginx. Everything lives in `ops/cluster/`.

### What a worker is

Each worker is a complete game server: its own `RoomManager`, tables, sockets, chat buffers and
`/metrics`. **A table never moves between workers and is never shared.** Workers coordinate only
through PostgreSQL (no Redis):

| Table | Written when | Read when |
|---|---|---|
| `cluster_workers` | start + heartbeat every 5 s, on a **dedicated connection** (not the pool, so a pool queued behind ledger transactions cannot make a busy worker look dead) | to decide whether another worker is alive (heartbeat < 15 s old) |
| `cluster_players` | a player is seated (quick-join, create, code, switch, resume) — a **compare-and-set** that only takes the row if it is free, already this worker's, or its owner has stopped heartbeating; deleted on leave/kick — **not** on a disconnect-grace lapse, so the row keeps routing the player back for the resume offer, and deleted `RESUME_OFFER_MS` after the lapse (a live worker's rows are never refreshed in bulk) | every connect, before `session:ready`; every heartbeat, to find seats held here whose row another live worker now owns |
| `cluster_rooms` | a table is created (code → worker); deleted when it is destroyed | `room:joinCode` for a code this worker does not have |

Routing, in `src/socket/index.js`:

1. **Connect.** Before `session:ready` the worker asks the registry where the player is. If the
   player's seat is on another *live* worker it emits `session:redirect {worker, path, reason:
   'seat'}` and closes the socket; the client reconnects on `path` (`/w<id>/socket.io`) and lands
   on the right worker, where the normal held-seat / resume-offer logic runs. If that worker is
   dead the row is ignored and the player is served locally (takeover). The row outranks a seat
   on this worker: one that contradicts a live foreign row was taken over while this worker was
   out of touch, and is released.
2. **`session:ready`** always carries `worker: {id, path}`. Clients persist the path and use it on
   the next cold start, so a returning player usually connects to the right worker first time.
3. **Seating.** Every seat is claimed in the registry *before* `room:joined` is sent. If the claim
   is refused — the same account is seated on another live worker (a second device that landed
   elsewhere while the first was in the lobby) — the seat is given straight back and the request
   is answered `{ok:false, code:'already_seated', path}` plus `session:redirect {reason:'seat'}`.
   One wallet is never at two tables.
4. **Private codes.** `room:joinCode` for a code owned by another live worker answers
   `{ok:false, code:'other_worker', path}` plus `session:redirect {reason:'room', joinCode}`; the
   client reconnects and repeats the join.
5. **Takeover clean-up.** A worker declared dead (heartbeat > 15 s old) may have been merely slow.
   Every heartbeat it checks the seats it still holds against the registry; a seat whose row now
   belongs to another live worker is released (`room:kicked {reason:'takeover'}` + a redirect to
   the owner), so it stops charging boots against a wallet that is playing elsewhere.
6. **Quick-join is worker-local by design** — the fullest local table with a free seat, else a
   new one. nginx's `least_conn` keeps the workers roughly even, and the sweeper merges lone
   players *within* a worker as before. A player on worker 1 and a friend on worker 2 who both
   quick-join the same stake will not meet; a private code always works.
7. **Shutdown** withdraws the worker from the registry *first* — its worker, player and room rows —
   then closes the sockets and settles the tables. Reconnecting players are served wherever they
   land instead of being redirected back to a port that no longer answers.

In single-process mode (`WORKER_ID` unset) the registry is a no-op object: nothing is written,
nothing redirects, `session:ready.worker` is `{id: 0, path: '/socket.io'}`. All existing tests
run in that mode unchanged; `test/cluster.test.js` starts two workers in one process against a
throwaway schema and exercises the redirects.

### Ports and nginx

| | Single process | Cluster (`WORKER_COUNT=3`) |
|---|---|---|
| systemd | `gameplay.service` | `gameplay@1`, `gameplay@2`, `gameplay@3` (template `gameplay@.service`; `gameplay.target` groups them) |
| Listen | `PORT` (3000) | `WORKER_BASE_PORT + WORKER_ID` = 3101, 3102, 3103 (`WORKER_PORT` overrides). A worker ignores `PORT`: the `.env` still says `PORT=3000`, and since the server loads `.env` itself an `UnsetEnvironment=PORT` in the unit could not hide it |
| nginx `location /` and `/socket.io/` | `127.0.0.1:3000` | `upstream game_workers { least_conn; 127.0.0.1:3101; :3102; :3103 }` |
| nginx `/w1/socket.io/` … `/w3/socket.io/` | — | `proxy_pass http://127.0.0.1:310N/socket.io/` — pins a client to one worker; the worker itself keeps Socket.IO's default path |
| `/metrics` | `404` at nginx; Prometheus scrapes `:3000` directly | `404` at nginx; one Prometheus job per worker on `127.0.0.1:310N` |
| `/health` | the process | whichever worker `least_conn` picks — its own numbers |
| Grafana | `/dashboard/` → `127.0.0.1:3001` | unchanged |

Two numbers scale with N: **`PG_POOL_MAX` is per worker** (3 × 50 = 150 connections, more than
Postgres' default `max_connections = 100` — lower the pool or raise the limit), and nginx's
`worker_connections` must cover two connections per player (`ops/monitoring/nginx/nginx.conf.example`).

### Installing

```bash
sudo bash ops/cluster/install-cluster.sh            # 3 workers; WORKER_COUNT=4 for four
```

Idempotent. Order: refuse a `.env` that sets any `WORKER_*` (the unit supplies them; the file
would override it) → install the template unit → start the workers on their own ports → wait for
each `/health` **and check it reports `worker.id == N`** → install the nginx site (backing up the
old one) → `nginx -t` → reload → stop and disable `gameplay.service` → append the
`king-teenpatti-w1..3` Prometheus jobs → `promtool check` → reload → print each worker's health.
A failure before the nginx switch leaves the single process serving. Players connected to the
old process are dropped once and reconnect onto a worker; their held seats do not survive (the
old process is gone).

Deploying new code: `systemctl restart gameplay@1`, wait for `/health`, then `@2`, then `@3` —
players on the restarting worker lose their table, everyone else plays on (the stopping worker
withdraws its registry rows before it closes a socket, so they are not redirected back to it).
`systemctl restart gameplay.target` restarts all three at once.

### Rollback

`ops/cluster/ROLLBACK.md`, in short: `systemctl enable --now gameplay.service` → `systemctl
disable --now 'gameplay@*'` → install `ops/cluster/nginx-gameplay-single.conf` (or the `.bak`
the installer wrote) → `nginx -t && systemctl reload nginx`. The single-mode site keeps the
`/w1..3/socket.io/` paths pointing at `:3000`, so a client that remembered a worker path still
connects; the single process then tells it `worker.path: '/socket.io'`. The `cluster_*` tables
are harmless when unused.

### Beyond one box

The registry is the piece that would let workers live on several machines — `cluster_workers`
would carry a host, nginx's upstream would list remote addresses, and the `/w<id>/` paths would
point at them. Nothing in the game code assumes localhost; only the ops files do.

## Layout

```
src/
├── index.js            Express + Socket.IO bootstrap, graceful shutdown
├── config/             Environment parsing, production safety checks
├── auth/
│   ├── providers.js    Google / Facebook / guest verification
│   ├── tokens.js       Session JWTs
│   └── routes.js       REST endpoints
├── cluster/registry.js Worker registry over Postgres (heartbeat, player → worker, code → worker); null object in single-process mode
├── db/
│   ├── schema.sql      Tables, indexes, the append-only ledger trigger
│   ├── index.js        pg connection pool, schema bootstrap, transactions
│   ├── ledger.js       The money transactions: boot, bet, settle
│   └── users.js        Accounts, rewards, names and pictures
├── game/
│   ├── deck.js         Crypto-secure shuffle and dealing
│   ├── handRank.js     Hand evaluation and comparison
│   ├── table.js        The game state machine — async, database-first (turn order, betting, sideshow, showdown)
│   ├── chat.js         Per-room in-memory chat buffer
│   ├── roomManager.js  Table lifecycle, matchmaking, sweeping
│   └── constants.js    Shared enums
├── metrics/index.js    Prometheus registry, HTTP middleware, game counters/histograms
├── socket/index.js     Socket.IO handlers, per-viewer state redaction, session:redirect
└── util/               Logger, id generation

ops/
├── cluster/            gameplay@.service, gameplay.target, nginx-gameplay.conf, install-cluster.sh, ROLLBACK.md
└── monitoring/         Prometheus + Grafana stack, exporters, nginx capacity settings, MONITORING.md
```
