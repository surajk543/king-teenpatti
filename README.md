# King Teen Patti

A turn-based multiplayer Teen Patti game: authoritative **Node.js + Socket.IO** server with
**SQLite** persistence, a **Unity** client for Android / iOS / WebGL, and a bundled browser client
for playing and testing without a Unity build.

```
king-teenpatti/
├── server/          Node.js + Socket.IO + SQLite game server (authoritative)
│   ├── src/         Game engine, auth, database, socket layer
│   ├── public/      Browser client — playable immediately, no Unity needed
│   └── test/        146 tests + a load-test harness
├── unity-client/    Unity client (C#): Socket.IO protocol, models, runtime UI
└── Requirements.txt The original brief
```

## Quick start

```bash
cd server
npm install
cp .env.example .env          # then set JWT_SECRET
npm start
```

Open <http://localhost:3000> in two browser tabs, press **Play as Guest** in each, then
**Quick Join**. Two players are enough to start a hand.

```bash
npm test                      # 146 tests
npm run loadtest -- --players 1000 --seconds 60
```

## What is implemented

| # | Requirement | Where |
|---|---|---|
| 1 | Google, Facebook and guest (deviceId) login | [providers.js](server/src/auth/providers.js), [AuthService.cs](unity-client/Assets/Scripts/Game/AuthService.cs) |
| 2 | SQLite storage per provider identity | [schema.sql](server/src/db/schema.sql), [users.js](server/src/db/users.js) |
| 3 | Rooms of at most 5 players | [table.js](server/src/game/table.js), [roomManager.js](server/src/game/roomManager.js) |
| 4 | 2 players minimum to start; many rooms | [table.js](server/src/game/table.js) |
| 5 | 2 lakh welcome chips on first login | [users.js](server/src/db/users.js) |
| 6a | 3 hidden cards each | [deck.js](server/src/game/deck.js), [table.js](server/src/game/table.js) |
| 6b | Clockwise turn rotation | [table.js](server/src/game/table.js) |
| 6c | Bet the same amount or double | [table.js](server/src/game/table.js) |
| 6d | 25-second turn clock, auto-pack on timeout | [table.js](server/src/game/table.js) |
| 6e | Exactly one winner takes the whole pot | [table.js](server/src/game/table.js) |
| 6f | Pack to fold, turn moves on | [table.js](server/src/game/table.js) |
| 6g | Trail > pure sequence > sequence > color > pair > high card | [handRank.js](server/src/game/handRank.js) |
| 7 | Account and chips restored on next login | [users.js](server/src/db/users.js) |
| 8 | Room chat: in-memory, 100 messages, dies with the room | [chat.js](server/src/game/chat.js) |
| 9 | +/− stepper doubles the bet, capped at the player's chips | [table.js](server/src/game/table.js), [GameUI.cs](unity-client/Assets/Scripts/UI/GameUI.cs) |
| 10 | Auto-pack when a turn is not acted on | [table.js](server/src/game/table.js) |
| 12 | Chat panel collapses to a badge and reopens | [client.js](server/public/client.js), [ChatPanel.cs](unity-client/Assets/Scripts/UI/ChatPanel.cs) |
| 13 | Blind/Seen categories at 200 and 5000; chip visibility per category | [table.js](server/src/game/table.js), [roomManager.js](server/src/game/roomManager.js) |

## How the game works

**Dealing.** Every funded player antes the boot. Three cards are dealt one at a time from a
`crypto.randomInt` shuffle. **Card faces stay on the server** — a client is only sent its own hand
after the player presses *See*, so a modified client has nothing to read.

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

**Settlement.** Bets move in memory during a hand, then the whole hand settles in **one SQLite
transaction** — chip deltas, the hand record, and the ledger row per player. That keeps database
writes flat as table count grows, and every chip movement is auditable in `chip_ledger`.

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

Full protocol reference: [server/README.md](server/README.md).
Unity setup, including Google/Facebook SDK wiring: [unity-client/README.md](unity-client/README.md).

## Measured performance

Load test on one machine, single Node process, 1000 bot players playing real hands:

```
sockets connected   1000        (0 login failures, 0 connect failures)
server sees         1000 players / 200 tables
hands completed     776 in 60s  (12.9 hands/sec)
actions sent        21672       (0 action errors)
latency p50/p95/p99 1 / 1 / 2 ms
server process      ~15% of one CPU core, 162 MB RSS
```

Reproduce with `npm start` then `npm run loadtest -- --players 1000 --seconds 60`.

The 500–1000 concurrent target fits comfortably in a single process. Scaling notes and the
sharding caveat are in [server/README.md](server/README.md#scaling).

## Testing

146 tests, all passing:

| File | Covers |
|---|---|
| `handRank.test.js` | Hand ranking, every category, tie-breaks, shuffle integrity |
| `table.test.js` | Seating, dealing, turn order, betting maths, timeouts, showdowns |
| `settlement.test.js` | Chip conservation on every route a hand can take |
| `chat.test.js` | Buffer cap, sanitising, room scoping, history lifetime |
| `raiseLadder.test.js` | The +/− ladder, its caps, amount validation, and the turn timeout |
| `categories.test.js` | Blind/Seen chip visibility, per viewer, on and off the wire |
| `stakes.test.js` | The lobby's fixed stakes and their validation |
| `integration.test.js` | Real sockets + real SQLite: auth, gameplay, room capacity, chat |
| `socketProtocol.test.js` | The Unity client's Socket.IO framing, driven with real server frames |

### Unity client — 25 tests

Compiled and run with **Unity 6000.6.0f1**:

```
Compile         KingTeenPatti.dll — 0 errors, 0 warnings (WebGL transport included)
PlayMode tests  25 passed, 0 failed
Build           StandaloneLinux64 — Succeeded, 0 errors, 0 warnings
```

The PlayMode suite runs the real client code against a **live server**: guest login and the welcome
grant, returning-account lookup, the Engine.IO handshake and auth packet, rejection of a bad token,
two clients seated at one table playing a hand through to settlement (including the check that an
opponent never receives your card faces), and room chat with backlog. Run it with:

```bash
cd server && npm start          # in one terminal
# then, in Unity: Window > General > Test Runner > PlayMode > Run All
```

The tests skip themselves rather than fail when no server is running.

`socketProtocol.test.js` on the server side ports the same C# parser to JavaScript so protocol
regressions are caught by `npm test` alone, without needing a Unity install. **If you change the
`Json` helper or packet dispatch in `SocketIOClient.cs`, update the port too** — both files say so.

## Security notes

- Provider tokens are verified server-side. Google id_tokens are checked against the configured
  OAuth client ids; Facebook tokens are checked with `debug_token` including the `app_id`, without
  which any Facebook token from any app would be accepted.
- Guest device ids are SHA-256 hashed before storage — the database never holds a raw device id.
- Card faces are never sent to anyone but their owner, and only after they look.
- The deck is shuffled with `crypto.randomInt`, not `Math.random`, whose state is recoverable from
  a short run of outputs.
- Chip balances are server-authoritative; a negative balance is rejected at the database layer as a
  last line of defence.
- Bet amounts are validated against a ladder the server recomputes, so a client cannot bet an
  arbitrary figure or more than its stack.
- On a blind table another player's chip balance is never serialized to your client at all.
- One live session per account; a second sign-in disconnects the first.
- Per-socket rate limiting, with a tighter separate allowance for chat.

## Not included

- **Google/Facebook native SDKs in Unity.** They are per-project native plugins that need your own
  app ids, so `AuthService` exposes `GoogleSignIn` / `FacebookSignIn` hooks instead — wiring is
  documented in the Unity README. Guest login works out of the box on every platform.
- **Side show.** Not in the brief; the ruleset is *see, chaal, raise, pack, show*.
- **Designed art.** The UI is built at runtime from code, so the client runs from a generated
  scene with no prefab wiring; swapping in designed prefabs is a drop-in replacement in `GameUI`.
- **Android / iOS / WebGL builds verified.** Only the Linux Standalone module is installed on this
  machine, so those targets were not built. All three code paths compile (the WebGL transport was
  type-checked explicitly), and `BuildScript` has ready entry points for each — but install the
  platform modules and run a build before shipping.
