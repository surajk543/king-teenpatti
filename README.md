# King Teen Patti

A turn-based multiplayer Teen Patti game: authoritative **Node.js + Socket.IO** server with
**PostgreSQL** persistence (every chip movement is one transaction), a **Flutter** client for
Android (Material 3), and a bundled browser client for playing and testing without a build.

```
king-teenpatti/
├── server/          Node.js + Socket.IO + PostgreSQL game server (authoritative)
│   ├── src/         Game engine, auth, database + ledger, socket layer
│   ├── public/      Browser client — a zero-build protocol reference
│   └── test/        node:test suites + a load-test harness
├── flutter-client/  Flutter client (Dart): the live app — lobby, table, chat, sideshow
├── CLAUDE.md        Detailed project context for coding sessions
└── Requirements.txt The original brief (items 1–34; there is no 11)
```

## Quick start

```bash
# PostgreSQL must be running with a database the server can use — by default
# postgres://postgres:postgres@localhost:5432/gameplay (see server/.env.example).
cd server
npm install
cp .env.example .env          # then set JWT_SECRET
npm start                     # creates the schema on first boot
```

Open <http://localhost:3000> in two browser tabs, press **Play as Guest** in each, then tap a
table. Two players are enough to start a hand. For the real client:

```bash
cd flutter-client
flutter build apk --debug     # default server: http://10.0.2.2:3000 (the emulator's host alias)
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

```bash
cd server && npm test
npm run loadtest -- --players 1000 --seconds 60 --boot 200
```

## What is implemented

| # | Requirement | Where |
|---|---|---|
| 1 | Google, Facebook and guest (deviceId) login | [providers.js](server/src/auth/providers.js), [game_state.dart](flutter-client/lib/state/game_state.dart) |
| 2 | Persistent storage per provider identity — **PostgreSQL** (the brief said SQLite; changed by the owner) | [schema.sql](server/src/db/schema.sql), [ledger.js](server/src/db/ledger.js), [users.js](server/src/db/users.js) |
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
| 9 | +/− stepper doubles the bet, capped at the player's chips | [table.js](server/src/game/table.js), [table_screen.dart](flutter-client/lib/screens/table_screen.dart) |
| 10 | Auto-pack when a turn is not acted on | [table.js](server/src/game/table.js) |
| 12 | Chat panel collapses to a badge and reopens | [client.js](server/public/client.js), [table_screen.dart](flutter-client/lib/screens/table_screen.dart) |
| 13 | Blind/Seen categories at 200 and 5000; chip visibility per category | [table.js](server/src/game/table.js), [roomManager.js](server/src/game/roomManager.js) |
| 14 | Show reveals every hand to the room, with the winner and amount | [table.js](server/src/game/table.js), [client.js](server/public/client.js) |
| 15 | The pot always pays out, even when the table empties | [table.js](server/src/game/table.js) |
| 16 | Played / won / lost / abandoned counters and total winnings | [users.js](server/src/db/users.js), [schema.sql](server/src/db/schema.sql) |
| 17 | 25,000 chip reward at every 25 hands played | [users.js](server/src/db/users.js), [routes.js](server/src/auth/routes.js) |
| 18 | 10,000 chip bonus on a 4-hour countdown, stored in the database | [users.js](server/src/db/users.js) |
| 19 | Seen tables: one double per turn, showdown after 7 rounds | [roomManager.js](server/src/game/roomManager.js) |
| 20 | Profile picture taken from the Google/Facebook account | [providers.js](server/src/auth/providers.js) |
| 21 | Pick a bundled picture; locked once seated; visible to everyone | [routes.js](server/src/auth/routes.js), [profiles/](server/public/profiles/) |
| 22 | Private tables: fixed 200 boot, maximum win 500,000, one double per turn | [roomManager.js](server/src/game/roomManager.js), [table.js](server/src/game/table.js) |
| 23 | Landscape on phones, icons, light/dark toggle, Material 3 | [theme.css](server/public/theme.css), [app_theme.dart](flutter-client/lib/theme/app_theme.dart) |
| 24 | Two half-empty rooms merge; never mid-hand; "starting in N" countdown | [roomManager.js](server/src/game/roomManager.js) |
| 25 | Leaving a table asks for confirmation first | [client.js](server/public/client.js), [main.dart](flutter-client/lib/main.dart) |
| 26 | 4-hour bonus in the top-left corner, counting down in seconds | [client.js](server/public/client.js) |
| 27 | Milestone reward in the bottom-right corner | [client.js](server/public/client.js) |
| 28 | Square table cards with a looping diagonal sheen | [style.css](server/public/style.css) |

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
one of the pictures bundled in `server/public/profiles/`, and that choice is what everyone at the
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

Full protocol reference: [server/README.md](server/README.md).
Everything a coding session needs to know, including the gotchas: [CLAUDE.md](CLAUDE.md).

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

`cd server && npm test` runs every suite with `node:test`. The unit suites drive the engine with a
fake clock and an in-memory ledger; the process suites (`integration`, `socketProtocol`, `stakes`,
`statsAndRewards`) start a real server against PostgreSQL, each in a throwaway schema it drops
afterwards.

| File | Covers |
|---|---|
| `handRank.test.js` | Hand ranking, every category, tie-breaks, shuffle integrity |
| `table.test.js` | Seating, dealing, turn order, betting maths, timeouts, showdowns |
| `settlement.test.js` | Chip conservation on every route a hand can take |
| `chipPersistence.test.js` | Every boot and bet is banked as it happens; the winner is paid exactly the pot |
| `blindRules.test.js` | Seeing out of turn, the blind-move cap and the auto-reveal |
| `sideshow.test.js` | Who may ask, who may answer, ties, expiry, turn ownership |
| `seatKeeping.test.js` | Three missed turns and an unfunded seat both lose the seat |
| `lobbyRules.test.js` | Display names in every script; the entry cap and table switching |
| `chat.test.js` | Buffer cap, sanitising, room scoping, history lifetime |
| `raiseLadder.test.js` | The +/− ladder, its caps, amount validation, and the turn timeout |
| `categories.test.js` | Blind/Seen chip visibility, per viewer, on and off the wire |
| `stakes.test.js` | The lobby menu (seen 200, blind 200, blind 5000) and its validation |
| `statsAndRewards.test.js` | Play counters, both rewards, and avatar precedence |
| `tableRules.test.js` | Pot payout when a table empties; seen-table betting limits |
| `privateTables.test.js` | The fixed private boot, the win ceiling and the single double |
| `consolidation.test.js` | Merging half-empty rooms, and never doing it mid-hand |
| `integration.test.js` | Real sockets + real PostgreSQL: auth, gameplay, room capacity, chat |
| `socketProtocol.test.js` | The raw Socket.IO/Engine.IO framing, driven with real server frames |

The Flutter client has `flutter analyze` and `flutter test` (money formatting).

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

- **Google/Facebook native sign-in SDKs.** The server verifies both providers, but the Flutter app
  does not bundle the native SDKs yet, so those buttons are disabled and guest login is the way in.
- **An iOS build.** Only `flutter-client/android/` exists so far; the Dart code has nothing
  platform-specific in it.
- **Multi-process scaling.** Accounts are shared through PostgreSQL, but a table lives in one
  process; see the sharding notes in [server/README.md](server/README.md#scaling).
