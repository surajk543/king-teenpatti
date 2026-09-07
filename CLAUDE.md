# CLAUDE.md — King Teen Patti

Project context for AI coding sessions. Read this before touching anything. It records what the
code does, why it is shaped the way it is, and the traps that have already bitten people here.

> **The working tree is far ahead of HEAD.** HEAD has two commits and predates most of this project.
> Never use `git show HEAD:…` to learn current behaviour — read the working tree. `unity-client/`
> is deleted and staged; several real files are untracked (see §13).

---

## 1. What this project is

A turn-based multiplayer **Teen Patti** (3-card Indian poker) game:

| Part | Path | Status |
|---|---|---|
| Authoritative game server | `server/` | Live. Node 22 + Express 4 + Socket.IO 4 + **PostgreSQL 18** via `pg`. Database-first money model (§5). No SQLite anywhere any more. |
| Mobile client | `flutter-client/` | **The live client.** Flutter 3.44 / Dart 3.12, Material 3 via FlexColorScheme, Android only so far. |
| Browser client | `server/public/` | Zero-build vanilla-JS reference client served at `/`. **Lags behind** — no sideshow, kick, rename, entry-cap or Indian-numbering UI. |
| Unity client | `unity-client/` | **Removed** (`git rm`, Sept 2026). A JS port of its Socket.IO parser survives as `server/test/helpers/csharpJsonPort.js` and still exercises the raw wire protocol. |
| Brief | `Requirements.txt` | 34 numbered requirements at lines 6–88 (**there is no #11**). Code comments cite these ("Requirement 22"). |
| Docs | `README.md`, `server/README.md` | Updated for Postgres + Flutter (Sept 2026); `CLAUDE.md` is the detailed reference. |

The server is the single authority: it deals, shuffles with `crypto.randomInt`, validates every bet
against a ladder it recomputes itself, decides winners, and redacts state per viewer so a client never
receives a card or a hidden stack it should not see. Clients only render snapshots and forward intent.

---

## 2. Repository layout

```
king-teenpatti/
├── CLAUDE.md                     this file
├── README.md                     project overview
├── Requirements.txt              the numbered brief (1–34, no 11)
├── recordings/                   empty local dir (no root .gitignore; git doesn't show it)
├── server/
│   ├── package.json              ESM, node>=20; scripts: start/dev/test/loadtest/bot
│   ├── .env.example              every env key the code reads, with defaults
│   ├── src/
│   │   ├── index.js              createServer(): awaits openDatabase(); Express + http + Socket.IO
│   │   ├── config/index.js       ALL env → config (snapshotted at import)
│   │   ├── game/
│   │   │   ├── table.js          THE rules engine (async, DB-first; Table, GameError, memoryLedger)
│   │   │   ├── roomManager.js    lobby menu, quick-join, switch, consolidation; injects the ledger
│   │   │   ├── handRank.js       evaluate/compare/pickWinner
│   │   │   ├── deck.js           52 cards, crypto shuffle, 2-char wire codes ("As","Td")
│   │   │   ├── chat.js           in-memory per-room chat buffer
│   │   │   └── constants.js      TABLE_CATEGORY / TABLE_STATE / SEAT_STATE / ACTION / WIN_REASON
│   │   ├── socket/index.js       the whole realtime protocol + per-viewer broadcast
│   │   ├── auth/{routes,providers,tokens}.js   REST (async), login providers, JWT
│   │   ├── db/
│   │   │   ├── index.js          pg Pool, schema bootstrap, withTransaction(), dropSchema() for tests
│   │   │   ├── schema.sql        Postgres DDL: users, hands, pots, chip_ledger (append-only), game_states
│   │   │   ├── ledger.js         THE money transactions: bet(), collectBoot(), settle()
│   │   │   └── users.js          async user store: login upsert, rewards, names, avatars
│   │   └── util/{ids,logger}.js
│   ├── public/                   browser client + profiles/ (15 Noto Emoji animal SVGs, Apache 2.0)
│   ├── test/                     18 node:test suites + helpers/ + loadtest.js
│   ├── tools/bot.js              practice bots
│   ├── kicktest.mjs              scratch script (tracked)
│   └── peek-tmp.mjs              scratch script (untracked) — lists live tables
└── flutter-client/
    ├── pubspec.yaml              package name `teenpatti` (imports are package:teenpatti/...), sdk ^3.12.2
    ├── lib/
    │   ├── main.dart             landscape lock, Provider root, screen switch (no Navigator)
    │   ├── state/game_state.dart the ONE ChangeNotifier + formatChips / NumberSystem globals
    │   │     `resuming` veil on cold start (start() → _beginResume → session:ready.resume ? joinByCode : 900ms wait; room:joined lifts it with t.welcomeBack)
    │   │     `appVersion` from package_info_plus (settings drawer footer); formatChips abbreviates >100000 to TWO decimals (3.24 Lakh, 32.77 Crore)
    │   │     Chat pacing (client-side): `GameState.sendChat()` returns bool, starts `chatCooldown` (4s); `canChat`/`chatCooldownLeft` drive `_ChatCountdown` (ring + seconds) in the rail icon and the send key; `_ChatDrawer._send` unfocuses and pops the drawer after a successful send.
    │   │     `tableScaffold`/`lobbyScaffold` GlobalKeys: main.dart `_BackGuard` closes an open drawer/endDrawer first; only then asks leave (table) / quit (lobby).
    │   │     `_armSeatCheck()`: on a warm `session:ready` while `room != null`, if no snapshot follows within 1.8s the seat is gone (server restarted / room closed) → lobby + t.tableLost. Cold start uses the `resuming` veil instead.
    │   ├── theme/app_theme.dart `AppTheme.paletteFor(scheme, category, bootAmount)` → TablePalette: seen=gold, blind<1000=sapphire(tertiary), blind≥1000=royal purple; used by lobby card, felt, _CategoryTag ("BLIND · 5,000")
    │   ├── screens/table_screen.dart `_MissedTurnsStrip` (zero-height OverflowBox over the Pack button: `_BlindMovesPill` + `_MissedTurns`, always visible), `_BetFlights` (chip from seat to pot on every contributed increase), `_AmbientGlow`
    │   ├── screens/lobby_screen.dart `_DriftingChips` ambient background
    │   └── widgets/seat_pod.dart `BubbleSide {above,left,right}`: chat bubble hung off the column END in a zero-height OverflowBox — rim seats grow it up over their own cards/badge (max 1.7×podW, pointer tail up at the pod), the viewer's grows up from the column top (2.1×podW, tail down). Pods paint AFTER tag/pot/status in the felt Stack so a bubble is never hidden.
    │   │     GameState: bubbles hold `bubbleFor` = 4s; a second line from the same player queues in `_bubbleQueue` and shows when the first expires; `_clearBubbles()` on leave/kick.
    │   │     `_MissedTurnsStrip`: compact (one line, labelMedium, no explanation) when screen width < 760dp; capped at 26% (compact) / 30% (wide) of screen width so it never runs under the viewer's pod. `_CategoryTag` text shrinks via FittedBox (slot w*0.30).
    │   ├── net/game_connection.dart  Socket.IO streams; every move carries a fresh actionId
    │   ├── net/api_client.dart   REST
    │   ├── models/dtos.dart      wire DTOs mirroring server JSON
    │   ├── screens/{login,lobby,table}_screen.dart
    │   ├── widgets/              premium_surface, seat_pod, playing_card, poker_chip, liquid_fill,
    │   │                         fireworks, avatar, buy_chips, rules_sheet
    │   ├── theme/app_theme.dart  FlexColorScheme + shadow/lift helpers
    │   └── l10n/strings.dart     hand-written 5-language table (en/hi/bn/gu/pa)
    ├── assets/card_back.svg
    ├── test/number_format_test.dart
    └── android/                  applicationId com.kinggames.teenpatti, sensorLandscape, cleartext on
```

There is no CI, Dockerfile, ESLint or Prettier anywhere. `cd server && npm test` and
`cd flutter-client && flutter analyze && flutter test` are the whole verification story.

---

## 3. Environment requirements

| Tool | Version in use | Notes |
|---|---|---|
| Node.js | v22.22.1 (`>=20`) | ESM only. Needs global `fetch`, `node:test`, `--watch`. |
| npm | 9.2.0 | |
| **PostgreSQL** | 18.6, local, port 5432 | DB `gameplay`, user/password `postgres`/`postgres`. Default `DATABASE_URL` in config points here. `psql` and `pg_isready` are installed. |
| Flutter | 3.44.7 stable (`/snap/bin/flutter`) | Dart 3.12.2 — this is the **minimum** `pubspec.lock` accepts. Code uses records, switch expressions, `'k': ?v` null-aware map entries, `DropdownButtonFormField(initialValue:)`. |
| Android SDK | `~/Android/Sdk` | **Not on PATH** — `export PATH="$PATH:$HOME/Android/Sdk/platform-tools:$HOME/Android/Sdk/emulator:$HOME/Android/Sdk/cmdline-tools/latest/bin"` |
| Emulator images | `system-images;android-36;google_apis;x86_64` (+ android-34) | AVDs: `TP_API36` (Pixel 6), `TP_Small` (Nexus 5, 640×360dp — tightest), `TP_Tablet`, `TP_Tall` (Pixel 7 Pro), `Pixel_6_API_34`. |
| ffmpeg | 8.0 | stitch/crop `screenrecord` output |
| Python 3 + Pillow | 12.x | ad-hoc screenshot diffing, launcher-icon generation |
| Linux desktop toolchain | absent | `flutter test` prints a GTK/clang warning first — noise |

Shell quirks on this machine: zsh with `grep`→`ugrep` and `find`→`bfs` aliases; an unquoted
`--include=*.js` fails with "no matches found"; `cd` in one Bash call can leak into the next — use
absolute paths.

Server ↔ emulator: the app's default `SERVER_URL` is `http://10.0.2.2:3000` (emulator alias for the
host loopback). Override with `--dart-define=SERVER_URL=http://<lan-ip>:3000` for a real device.
`usesCleartextTraffic="true"` in the manifest makes plain http work.

---

## 4. Commands

### Server (`cd server`)
```bash
npm install
cp .env.example .env            # optional; defaults work for local dev. Set JWT_SECRET for prod.
npm start                       # node src/index.js  → http://0.0.0.0:3000 (needs Postgres up)
npm run dev                     # node --watch src/index.js
npm test                        # node --test --test-timeout=30000 "test/*.test.js"
node --test test/sideshow.test.js          # one suite
npm run loadtest -- --players 1000 --seconds 60 --boot 200
node tools/bot.js --count 3 --boot 200  --category blind --offset 0
node tools/bot.js --count 3 --boot 5000 --category blind --offset 3   # 2nd group needs its own --offset
node tools/bot.js --count 8 --boot 200 --category blind --churn 40    # bots hop tables → room:switch testable
```

Find/stop the server safely (read §12.1 before reaching for `pkill`):
```bash
ss -lptn 'sport = :3000'                      # shows the PID
kill <pid>
nohup node src/index.js > /tmp/server.log 2>&1 &     # start in a SEPARATE command from the kill
```

Useful Postgres checks:
```bash
PGPASSWORD=postgres psql -h localhost -U postgres -d gameplay -c "select display_name, chips from users order by chips desc limit 10"
# ledger must reconcile to wallets:
PGPASSWORD=postgres psql -h localhost -U postgres -d gameplay -Atc "select count(*) from users u join (select user_id, sum(delta) s from chip_ledger group by user_id) l on l.user_id=u.id where l.s <> u.chips"   # expect 0
PGPASSWORD=postgres psql -h localhost -U postgres -d gameplay -c "select nspname from pg_namespace where nspname like 'test_%'"   # leftover test schemas (should be none)
```

### Flutter client (`cd flutter-client`)
```bash
flutter pub get
flutter analyze                 # must be clean (it is)
flutter test                    # 6 tests (number formatting)
flutter build apk --debug       # ~7s incremental; build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --debug --dart-define=SERVER_URL=http://192.168.1.10:3000
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell monkey -p com.kinggames.teenpatti -c android.intent.category.LAUNCHER 1   # launch
adb shell am force-stop com.kinggames.teenpatti
```

### Emulator / verification helpers
```bash
emulator -avd TP_Tall -gpu host -no-snapshot-save &
adb wait-for-device; until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 3; done
adb shell settings put secure stylus_handwriting_enabled 0   # Pixel 7 Pro AVD: stop the stylus tutorial stealing focus
adb exec-out screencap -p > shot.png
adb shell uiautomator dump /sdcard/ui.xml && adb shell cat /sdcard/ui.xml | tr '>' '\n' | grep -o 'content-desc="[^"]\+"[^/]*bounds="[^"]*"'
adb logcat -c; ...; adb logcat -d | grep -ic "overflowed"     # Flutter RenderFlex overflow detector (0 = clean)
adb shell screenrecord --time-limit 170 --bit-rate 8000000 /sdcard/seg.mp4   # falls back to 1280x720 on 3120x1440 devices
```

---

## 5. Architecture

```
 Flutter / browser client                 server/src
 ┌──────────────────────┐   REST (JWT)    ┌─────────────┐      ┌────────────────────┐
 │ GameState (Provider) │◄──────────────►│ auth/routes  │◄────►│ db/users.js        │
 │  ├ ApiClient         │                └─────────────┘      │ (pg Pool)          │
 │  └ GameConnection    │   Socket.IO     ┌─────────────┐      │                    │
 │     (websocket only) │◄──────────────►│ socket/index │──┐   │ db/ledger.js       │
 └──────────────────────┘  per-viewer     └─────────────┘  │   │  bet / collectBoot │
                           room:state           ▲          ▼   │  / settle          │
                                                │   ┌──────────┴──┐  one transaction │
                                                └───┤ RoomManager │◄──── each ───────┘
                                                    │  └ Table    │
                                                    └─────────────┘
```

### 5.1 The money model (database-first)
Every chip movement follows this exact shape — the client sends `BET amount + actionId`:

```
validate in memory (turn, amount ∈ ladder, balance)
  → BEGIN
  → SELECT chips FROM users WHERE id=$1 FOR UPDATE        lock the wallet row
  → UPDATE users SET chips = chips - amount               deduct
  → UPDATE pots SET amount = amount + $1                  pot accounting
  → INSERT INTO chip_ledger (…, action_id) — UNIQUE       immutable ledger entry
  → UPSERT game_states … WHERE stored.version < new       save state/version
  → COMMIT
  → SUCCESS: mutate Table memory, emit 'action'/'state'  (broadcast)
  → FAILURE: change nothing, emit nothing, ack {ok:false, code}
```

- `chip_ledger.action_id` is UNIQUE → a retried request (`duplicate_action`) is refused, never
  double-charged. Boots use `${handId}:boot:${userId}`, settlement `${handId}:settle:${userId}`, so
  those transactions are idempotent too.
- `chip_ledger` is **append-only**: a trigger raises on UPDATE/DELETE.
- `game_states.version` only rises; a write with an older version is rejected (`stale_state`) — the
  guard against two processes owning one table.
- `Table` never touches the DB directly. It is given a `ledger` object `{bet, collectBoot, settle}`
  (production: `db/ledger.js`; tests: `memoryLedger` built from the older `settle`/`persistChips`
  hooks). `table.version` increments per committed write.
- **Every mutation runs through the table's serial queue** (`_run`). A DB round-trip can therefore
  never interleave with a turn timeout; `hand.turnToken` additionally makes a late-firing timeout a
  no-op. Consequence: `act`, `removePlayer`, `startHand`, `destroy`, `respondToSideshow` return
  **Promises**; `addPlayer`, `postChat`, `setConnected`, `serializeFor` stay synchronous.
- Settlement (`_endHand`) is the one place memory is updated before the write completes — the hand
  *is* over. If the settle transaction fails the table pays the winner in memory and retries the
  idempotent write in the background (10 attempts, backoff) so the DB catches up.

### 5.2 Flow of a hand
`WAITING → STARTING (nextHandDelayMs) → BETTING → SHOWDOWN → WAITING`. Boots are collected in one
transaction (`collectBoot`, wallets locked in id order) before a card is dealt; if it is refused the
table drops back to WAITING (an unfunded player is kicked; any other error retries after the delay).
After every mutation the table emits `state`; the socket layer sends each viewer
`table.serializeFor(viewerId)` — never a room-wide snapshot.

---

## 6. Server — game engine (`server/src/game/`)

### 6.1 `table.js`
**Seat:** `{ userId, displayName, avatarUrl, chips, status, isBlind, blindMoves, cards, lastBet,
lastAction, contributed, connected, socketId, missedTurns, sideshowAskedThisTurn, seatIndex }`.
**Hand:** `{ id, handNo, pot, stake, round, packedUserIds, turnSeat, startSeat, seatOrder,
showRequestedBy, sideshow, lastDeparture, turnDeadline, turnToken, contributions: Map<userId,
{contributed, persisted, status, sawCards, cards, didChaal, leftMidHand}> }`.

- **Turn order**: clockwise = ascending seat index (`_nextActiveSeat`). `_rightActiveSeat` walks
  *downward* — "the player on your right" acted just before you (who a sideshow is asked of).
- **Ladder** (`betOptions`): `base = isBlind ? stake : 2*stake`; rungs double while
  `≤ min(bootAmount*potLimitMultiplier, chips)`, `≤ maxPot - pot`, `< maxRaiseSteps`. A client amount
  must be exactly a rung (`invalid_bet`); `raise ≥ 2*steps[0]`. `hand.stake` stays in **blind units**
  (`floor(amount/2)` after a seen bet). The `potLimitMultiplier` product is a *per-bet* ceiling; the
  pot cap is `maxPot` (0 = uncapped).
- **SEE** is free, allowed off-turn, doesn't move the turn or reset the clock. After `maxBlindMoves`
  (4) blind bets the cards auto-reveal; that last bet is still charged at the blind rate.
- **Turn clock** 25s → `missedTurns++`, `_pack('timeout')`; at `maxMissedTurns` (3) emits
  `kick {reason:'idle'}`. `missedTurns` resets to 0 only **after a successful move**. The table only
  *emits* `kick`; RoomManager/socket layer removes the player.
- **Rounds** count when the turn steps *over* `startSeat` (by `_distance`, not equality).
  `round >= maxBetRounds` → forced showdown. `pot + stake > maxPot` → `POT_LIMIT` showdown.
- **Show**: exactly 2 active seats; costs `showCost = chaal`; **null/unaffordable cost →
  `insufficient_chips`** (a show is never free). Exact ties: show-payer loses, else nearest the dealer's
  left. The pot is never split.
- **Sideshow** (req. 33): `sideshowBlockedReason` order `no_hand | not_in_hand | not_your_turn |
  sideshow_pending | already_asked | too_few_players | you_are_blind | no_neighbour |
  neighbour_is_blind`. Clock stopped while pending (6s). Only `toUserId` may answer. Tie goes
  **against the asker**. When the *asked* player loses, `_pack(..., {advanceTurn:false})` — the turn
  never left the asker. Clock re-armed with `_setTurn(fromSeat, {freshTurn:false})` so
  `sideshowAskedThisTurn` survives (one ask per turn). Participant leaving → resolved `'left'`;
  `_endHand` clears the timer. The sideshow is **free** (the brief specified no bet — flagged as an
  exploit vs. standard rules).
- **Leaving mid-hand** = pack; stake stays; `leftMidHand=true`; `lastDeparture` gets the pot if all
  leave (`ALL_LEFT`). Winner identified by **userId**, not seat.
- `_sweepUnfunded` only between hands (`if (this.hand) return`); it sets `seat.kickPending` so a
  seat is kicked once even if two sweeps run before the queued removal lands.
- **`serializeFor` redaction (do not break)**: `you.cards` only when `!viewer.isBlind`; other seats
  carry only `cardCount`; on BLIND tables others' `chips` is **`null`** (not 0) + `chipsHidden:true`;
  `missedTurns/maxMissedTurns/options` only in `you`; `sideshow` carries ids/seats/`expiresAt`, never
  cards. Public everywhere: `lastBet, lastAction, contributed, isBlind, connected, status`.
- `_snapshot()` is the *server-side* full state (cards included) saved to `game_states` — never sent
  to a client.
- **Events**: `state, seatUpdated, chat, handStarted, cards, turn, action, showdown, handEnded, kick,
  sideshowRequested, sideshowReveal, sideshowResolved, persistError, error`. `seatUpdated` has no
  listener; `persistError` is logged by RoomManager only.

### 6.2 `roomManager.js`
- `quickJoin`: `_assertNotSeated` → `assertStakeAllowed` (`tableStakes`) → `normalizeCategory`
  (unknown → **seen**) → `assertTableOffered` (`lobbyTables` pair) → chips ≥ boot →
  `_assertUnderEntryCap` → fullest public non-full table with same boot+category, else `createTable`.
  Sync.
- `switchTable` (**async**): same boot+category, **no entry cap**, leaves with reason `'moved'`
  (skips consolidation). `leave`, `destroyTable`, `consolidateTables`, `sweepEmptyTables`,
  `_movePlayer`, `shutdown` are **async** and must be awaited. `leave` deletes `playerRooms` *before*
  awaiting the removal.
- `createTable`: public seen → `{maxRaiseSteps: 2, maxBetRounds: 7, maxPot: 1_200_000}`; private →
  boot forced to `privateBoot`, `{maxPot: 500_000, maxRaiseSteps: 2}`; public blind → full ladder,
  uncapped. Constructs `Table` with `ledger: this.ledger` (defaults to `createLedger()` unless tests
  pass `settle`/`persistChips`).
- `lobbyOptions()` → `{categories, stakes, tables:[{category, bootAmount, maxPot, maxBlindMoves}],
  entryCap*, privateBoot, privateMaxPot}`. Clients render `tables` verbatim.
- Sweeper interval (unref'd): merges lone players on idle public tables of the same
  `category:boot` into the oldest; sweeps empty tables older than a **hardcoded** 30s.

### 6.3 `handRank.js` / `deck.js`
`HIGH_CARD 0 < PAIR < COLOR < SEQUENCE < PURE_SEQUENCE < TRAIL 5`. Runs: **A-K-Q > A-2-3 > K-Q-J >
… > 4-3-2**. Suits never break ties. `pickWinner` is exported but `table.js` re-implements the tie
loop — keep consistent. Wire hand names are the **English** `CATEGORY_NAMES` and Flutter shows them
untranslated.

---

## 7. Server — platform

### 7.1 Socket.IO contract (`socket/index.js`)
Handshake: JWT in `handshake.auth.token`; `io.use` is async (`await findById`). Failures →
`connect_error` `missing_token | invalid_session | unknown_user | unauthorized`. One live socket per
user (`session:replaced` to the old one). On connect: `session:ready {user, config}`; if still seated
→ `room:joined` + `chat:history` (**why restarted bots land on their previous table**).

`guard`: rate limit **30/5s per socket** (trip → `game:error rate_limited`, **no ack**), then ack
`{ok:true,…}` or `{ok:false, code, message}` **and** `game:error` (reported twice — clients dedupe).

| Client → server | Payload | Ack |
|---|---|---|
| `lobby:list` | `{category?}` | `{tables, options}` (used only by scratch/tests) |
| `room:quickJoin` | `{bootAmount?, category?}` | `{roomId, code, category}` |
| `room:create` | `{isPrivate=true, category?}` | `{roomId, code, category}` — boot ignored |
| `room:joinCode` | `{code}` | `{roomId, code, category}` |
| `room:switch` | `{}` | `{roomId, code, category}` |
| `room:leave` | `{}` | `{roomId}` or `{}` |
| `game:action` | `{action, amount?, actionId?}` | table.act result; `actionId` (≤64 chars) becomes the ledger row's unique id |
| `game:sideshowRespond` | `{accept}` (only `=== true` accepts) | `{accepted, packedUserId}` |
| `player:requestCards` | `{}` | `{cards}` (empty unless seen) |
| `chat:message` | `{text}` | `{messageId}` — own 5/5s limiter (`chat_rate_limited`) |
| `chat:history` | `{}` | `{count}` (no client sends it) |
| `ping:rtt` | `sentAt` | `{sentAt, serverTime}` — **unguarded**, no `ok` |

| Server → client | Audience |
|---|---|
| `session:ready {user, config}` / `session:replaced` | socket |
| `room:joined` / `room:state` — `serializeFor(viewer)` | **per viewer** |
| `room:moved {fromRoomId, toRoomId, code, message}` — **no `state`**; the snapshot is the `room:joined` that follows | socket |
| `room:left` / `room:closed` / `room:kicked {roomId, reason, message}` | socket |
| `game:handStarted {…participants}` then per-socket `player:hand` | room |
| `player:cards {cards}` | owner only |
| `game:turn {userId, seatIndex, deadline, timeoutMs}` (no options) | room |
| `game:yourTurn {deadline, timeoutMs, options}` | player on turn |
| `game:action {userId, action, amount, pot, stake, reason?\|auto?}` | room |
| `game:sideshowRequested` / `game:sideshowResolved` | room (no cards) |
| `game:sideshowReveal {reveal}` | **the two players only** |
| `game:showdown {reveals, reason}` / `game:handEnded {…nextHandAt}` | room |
| `chat:message` / `chat:history` / `game:error` | room / socket / socket |

Client coverage: **Flutter** never sends `lobby:list`, `chat:history`, `ping:rtt`, and never listens
to `game:handStarted`, `player:hand`, `game:turn`, `game:yourTurn` — it derives turn and options
from `room:state.turn` / `you.options`. Changing `you.options` affects Flutter; changing
`game:yourTurn` does not. **Browser** ignores `room:kicked` and all `game:sideshow*`.
Input guards (`socket/index.js`): `game:action.amount` must be a JS number and safe integer (strings/arrays/booleans → `invalid_bet`);
rate-limited requests are acked `{ok:false, code:'rate_limited'}`; `RoomManager.join()` asserts one seat per player (also closes
`room:create` to a seated player); `player:requestCards` outside a table → `not_in_room`. Covered by `test/invalidMoves.test.js`.
Disconnect: seat held `reconnectGraceMs` (60s) then `await rooms.leave(userId,'disconnected')`; just before
leaving, `resumeOffers.set(userId, {roomId, at})`. On connect: if still seated → `room:joined` + `chat:history`
re-sent (resume); else `takeResumeOffer(userId)` (fresh within `resumeOfferMs`, table alive and not full, offered
once) rides on `session:ready.resume {roomId, code, category, bootAmount}` and the Flutter client auto-joins it
with `room:joinCode`. Voluntary leave / kick never create an offer (the grace timer finds no seat).
`room:switch` must `untrackRoom` *before* `switchTable` and re-track on failure.

### 7.2 REST (`auth/routes.js`, all handlers async)
`POST /api/auth/login {provider: google|facebook|guest, idToken|accessToken|deviceId, displayName?}`
→ `{token, user, isNew, welcomeChips}`; `GET /api/auth/me`; `GET /api/auth/me/hands?limit` (no
client calls it); `POST /api/rewards/milestone|bonus`; `GET /api/profiles` (unauthenticated);
`POST /api/profile/avatar {avatar|null}` and `POST /api/profile/name {name}` (409 `seated` while at
a table; live in `playerRoutes({isSeated})`, **not** `authRoutes`); `GET /api/rooms` (no client);
`GET /health`. Errors `{error: code, message}`. Guest id = `sha256('teenpatti:'+deviceId)`, deviceId
≥ 8 chars. `AUTH_ALLOW_FAKE_PROVIDERS=true` lets google/facebook skip verification (tests, browser
stubs).

### 7.3 Database (`db/`)
`pg` Pool (`DATABASE_URL`, `PG_POOL_MAX`), `search_path` set as a connection **option**
(`-c search_path=<schema>,public`). `openDatabase({url, schema})` creates the schema if missing and
runs `schema.sql` (fully idempotent: IF NOT EXISTS / CREATE OR REPLACE / DO-block trigger).
`withTransaction(fn)` = BEGIN/COMMIT/ROLLBACK. `dropSchema()` refuses `public`. **int8 and numeric
are parsed to JS numbers** (`pg.types.setTypeParser(20|1700)`) — without that, `chips` and `SUM()`
come back as strings.

Tables: `users` (wallet = `chips BIGINT CHECK ≥ 0`, counters, `milestone_claimed`, `next_bonus_at`,
`avatar_choice`), `hands` (`summary_json JSONB`), **`pots`** (`hand_id PK, amount, winner_id,
opened_at, closed_at`), **`chip_ledger`** (`action_id UNIQUE`, `hand_id`, `delta`, `balance`,
`reason`; append-only trigger), **`game_states`** (`room_id PK, version, state JSONB`). Timestamps
are epoch-ms BIGINT. Rewards: milestone 25,000 / 25 hands (`didChaal` only), timed 10,000 / 4h —
constants in `users.js`. Display names: `NAME_PATTERN = /^[\p{L}\p{N}][\p{L}\p{N}\p{M} ]*$/u` —
**`\p{M}` is essential** for Indic vowel signs.

Ledger `reason` values: `welcome_bonus, boot, bet, show, hand_win, hand_loss, milestone_reward,
timed_bonus, legacy_reconciliation, test_fixture, sqlite import rows keep their old reasons`.
**Invariant to keep true:** `SUM(chip_ledger.delta) per user == users.chips` (the psql check in §4
must return 0). The import wrote 12 `legacy_reconciliation` rows to make the old data satisfy it.

### 7.4 Config (`config/index.js`) — env → default. Built **once at import**.
| Env | Default | Purpose |
|---|---|---|
| `NODE_ENV` | development | `production` throws on default JWT secret / fake providers |
| `PORT` / `HOST` / `CORS_ORIGIN` | 3000 / 0.0.0.0 / `*` | |
| `JWT_SECRET` / `JWT_EXPIRES_IN` | dev-only-insecure-secret / 30d | |
| `GOOGLE_CLIENT_IDS`, `FACEBOOK_APP_ID/SECRET` | empty → 503 | |
| `AUTH_ALLOW_FAKE_PROVIDERS` | false | |
| **`DATABASE_URL`** | `postgres://postgres:postgres@localhost:5432/gameplay` | |
| **`PG_SCHEMA`** | `public` | tests use `test_<suite>_<rand>` and drop it after |
| **`PG_POOL_MAX`** | 10 | |
| `WELCOME_CHIPS` / `BOOT_AMOUNT` | 200000 / 200 | |
| `TABLE_STAKES` | `200,5000` | empty = any (tests) |
| `LOBBY_TABLES` | `seen:200,blind:200,blind:5000` | the menu; empty = any pair (tests) |
| `MAX_PLAYERS_PER_ROOM` / `MIN_PLAYERS_TO_START` | 5 / 2 | 5 is also hardcoded in Flutter `_places` and browser CSS |
| `TURN_TIMEOUT_MS` | 25000 | |
| `MAX_BET_ROUNDS` / `POT_LIMIT_MULTIPLIER` / `MAX_RAISE_STEPS` | 20 / 1024 / 8 | defaults only; `createTable` overrides all three per category (seen: 7 / 1024 / 2, blind: 0 / 0 / 0) |
| `SEEN_MAX_RAISE_STEPS` / `SEEN_MAX_BET_ROUNDS` / `SEEN_MAX_POT` | 2 / 7 / 1200000 | brief says "10 moves"; code is 7 rounds |
| `MAX_BLIND_MOVES` | 4 | |
| `ENTRY_CAP_BOOT` / `ENTRY_CAP_CATEGORY` / `ENTRY_CAP_MAX_CHIPS` | 200 / blind / 500000 | |
| `MAX_MISSED_TURNS` | 3 | |
| `SIDESHOW_TIMEOUT_MS` / `SIDESHOW_MIN_PLAYERS` | 6000 / 3 | |
| `DISPLAY_NAME_MAX` | 24 | also hardcoded: providers.js `.slice(0,24)`, Flutter login/lobby `maxLength: 24` |
| `PRIVATE_BOOT` / `PRIVATE_MAX_POT` / `PRIVATE_MAX_RAISE_STEPS` | 200 / 500000 / 2 | |
| `NEXT_HAND_DELAY_MS` / `CONSOLIDATE_INTERVAL_MS` / `RECONNECT_GRACE_MS` | 4000 / 15000 / 60000 | |
| `RESUME_OFFER_MS` | 600000 | how long a lapsed seat's table is offered back via `session:ready.resume` |
| `BLIND_MAX_RAISE_STEPS` / `BLIND_MAX_BET_ROUNDS` / `BLIND_POT_LIMIT_MULTIPLIER` | 0 / 0 / 0 | blind tables: 0 = unlimited (ladder to the stack, no per-bet ceiling, no forced showdown) |
| `CHAT_MAX_HISTORY` / `CHAT_MAX_LENGTH` / `CHAT_RATE_LIMIT` / `CHAT_RATE_WINDOW_MS` | 100 / 140 / 5 / 5000 | Flutter's chat field allows **200** — chars 141–200 are dropped server-side |
| `REDIS_URL` | empty | adapter only; RoomManager is process-local, so multi-node is **not** functional |
| `LOG_LEVEL` | info | read directly by `util/logger.js` |

There is no `server/.env`; the server runs on these defaults.

### 7.5 Tests & tools
- Runner: `node:test` + `node:assert/strict`; flat `test('sentence', async () => …)`.
- **Unit suites** build `new Table({config, timers, settle, persistChips})` with
  `test/helpers/fakeTimers.js`. **`advance(ms)` is async** — always `await advance(ms)`; it awaits each
  fired timer's callback. **`await table.act/removePlayer/startHand/destroy/respondToSideshow`**;
  `await assert.rejects(table.act(...), {code})`. After an indirect removal (a `kick` handler calling
  `removePlayer`) use `await table.settled()` — the removal is queued behind the current mutation.
  Every suite declares a full `baseConfig` (Table uses config raw, no defaults merged). Force
  deterministic showdowns with `seat.cards = codes.map(parseCard)`. `persistChips` receives
  `{userId, delta, reason:'boot'|'bet'|'show', roomId, handId, actionId}`; a throw **refuses** the
  move (`persist_failed`).
- **Process suites** (`integration`, `socketProtocol`, `stakes`, `statsAndRewards`): set env before
  `await import(...)`: `NODE_ENV=test`, **`PG_SCHEMA='test_<suite>_'+random`**, `TABLE_STAKES=''`,
  `LOBBY_TABLES=''`, `PORT=0`, `AUTH_ALLOW_FAKE_PROVIDERS=true`, short `*_MS`. Teardown:
  `await rooms.shutdown()` … `await dropSchema(); await closeDatabase()`. **`stakes.test.js` must run
  with the real default menu** (it `delete`s those two env vars). Direct row checks use
  `query(text, params)` from `db/index.js`.
- `socketProtocol.test.js` imports `ws` — only a **transitive** dependency.
- `tools/bot.js` flags: `--count --boot --category --url --offset --churn`. 8 fixed identities
  (Ravi Meera Arjun Kavya Vikram Anita Rohit Neha; device id `practice-bot-<slot>-<name>`); a second
  group **must** use `--offset`. Bots always `see`, ask sideshow 45%, answer 75/15/10
  accept/decline/lapse; retry `already_in_room` for 60s.
- `test/loadtest.js` defaults to `--boot 100` which the default menu refuses — pass `--boot 200`.
- `kicktest.mjs` (tracked) and `peek-tmp.mjs` (untracked) are manual scratch scripts on
  localhost:3000, not in npm scripts.

---

## 8. Flutter client (`flutter-client/lib`)

### 8.1 Shape
- **No Navigator.** `_Root` switches Login/Lobby/Table on `GameState.screen`; the server drives it
  (`room:state` → table; `room:left/closed/kicked` → lobby). `PopScope(canPop:false)` everywhere.
- Landscape only, immersive sticky.
- **One `ChangeNotifier`** — `GameState` — with a `Timer.periodic(1s, notifyListeners)` for the
  reward countdown. **Any `context.watch<GameState>()` rebuilds every second.**
- `GameConnection`: websocket-only Socket.IO; broadcast `Stream`s; every emit via `emitWithAck`; a
  refusal is `{ok:false, message}` → `notice`. `request()` awaits an ack with an 8s timeout.
  **Every `act()` sends a fresh `actionId` (uuid v4)** for server-side idempotency. The `room:moved`
  `j['state']` branch is dead code (server sends no `state` there).
- DTOs (`dtos.dart`): `const` classes + tolerant `fromJson`; server enums as `static const String`
  classes; `Seat.chips` **nullable** (null = withheld, never 0).
- SharedPreferences: `deviceId`, `token`, `darkMode`, `lang`, `numbers`.

### 8.2 GameState essentials
New hand = `handNo` changed → clears celebration/sideshow reveal, resets `raiseIndex`. **The
celebration has its own timer** (`nextHandAt`, 6s fallback) — it used to clear only on the next deal,
which stranded a lone winner behind the banner forever. `switching` suppresses `onLeft` during
`room:switch`. `bet()` sends `chaal` when amount == `raiseSteps.first`, else `raise`.
`createPrivate()` sends category **seen** (the browser sends **blind**) — a private table's chip
visibility depends on which client created it.

### 8.3 Money formatting (req. 34)
`formatChips(int)` reads two **module-level globals** `chipNumberSystem` / `chipUnits`, written only
by `GameState._publishNumberFormat()`. Abbreviate only `> 100000`; Indian `3.24 Lakh`/`2.5 Crore`/`32.77 Crore`
(2dp, rounded, trailing zeros trimmed); international keeps digits below 1,000,000 then `1.2 Million`. Tests reset the globals
in `tearDown`. `_sampleIn()` mutates the global to preview — don't interleave.

### 8.4 UI
- **Lobby**: rail of square `_TableCard`s from `config.tables` (server order), capped at 400dp tall;
  `_CategoryBadge` (sheen + `SpinningChip`, blind delayed 900ms), `LivelyChipStack`, `_CardFact`
  rows, entry-cap overlay; `_TopBar` `fromLTRB(240,…)` clears the bonus chip, `tight` < 760;
  `_MilestoneChip` above `BuyChipsButton` ("Coming soon"); one `endDrawer` for stats/settings.
- **Table**: `_TableScreenState.build` **watches nothing** (a per-second Scaffold rebuild destroyed
  the open drawer); `_LeftPanel {menu, chat}` shares one `drawer`. `_ActionBar` always present, only
  disables: `Pack | − [chip amount] + | Chaal | Sideshow⇄Show`; natural width 760, `FittedBox`.
  `_Felt`: seats at fractional `_places` (5 only), viewer at view seat 0, `podW = min(h*0.30,
  w*0.155).clamp(56,128)`, pods clamped inside. Overlays: `_CategoryTag`, `_Pot`, `_Status`,
  `_MissedTurns` (only when `you.missedTurns > 0`), `_SideshowLink/Prompt/RevealPanel`, `_Showdown`
  (scrim, `Fireworks(focus: winner)`, `_PotToWinner` under the banner). `handLive` gates bet pills.
- **Per-frame clocks** (`LiquidFill`, `_SideshowCountdown`) compute from `deadlineMs -
  DateTime.now()` inside an `AnimationController` — never from the 1s tick. No clock-skew correction.
- **Theme**: FlexColorScheme with explicit palettes (the "one seed" comment is stale);
  `_raisedButtons` = state-driven elevation (`liftElevation`: disabled 0, pressed rest/3, hover 2×),
  tinted `shadowFor`, transparent surfaceTint; text buttons flat. `PremiumSurface` = the one raised
  treatment (3 shadows + bevel + optional `Glint`).
- **i18n**: `AppLang` × 5; `Strings(lang)` with English → key fallback. **New keys go in all five
  maps + a getter.** Teen Patti vocabulary transliterated. Still-English strings: `'YOU'`, `'Table
  ${code}'`, `'hand N'`, private-card body, picture-picker labels, `'Switch theme'`, chat `'You'`,
  the `'$winner won N'` banner (bypasses lakh formatting), and **wire hand names**.
- **Android**: `com.kinggames.teenpatti`, `sensorLandscape`, cleartext, INTERNET (needed in
  release), chip launcher PNGs (no adaptive XML), `values-v31/styles.xml` splash bg `#FAF7F0`
  (night `#0B0B0B`). Release **signed with debug keys** (TODO in `build.gradle.kts`).

---

## 9. Browser client (`server/public/`)
Vanilla JS IIFE; `localStorage tp_token/tp_device/tp_theme`; lobby from `config.tables`. No
`room:kicked`, no sideshow, no rename/entry-cap/numbering. Google/Facebook buttons are stubs needing
`AUTH_ALLOW_FAKE_PROVIDERS`. Chat `maxlength=140`. Treat as a protocol smoke-test surface.

---

## 10. Requirements index (`Requirements.txt`)
1 login providers · 2 DB per identity (brief says SQLite; **now Postgres by owner's decision**) ·
3 ≤5/room · 4 ≥2 to start · 5 2 lakh welcome · 6a–g core play · 7 persistence · 8 room chat ·
9 +/− stepper · 10 auto-pack · **(no 11)** · 12 collapsible chat · 13 Blind/Seen × 200/5000 ·
14 Show reveal · 15 pot to last leaver · 16 stats (played = made a chaal) · 17 25k/25 hands ·
18 4h 10k bonus · 19 Seen: one double, forced showdown (brief 10 moves / code 7 rounds) ·
20 provider avatar · 21 avatar picker, locked when seated · 22 private table · 23 landscape/M3 ·
24 merge lone rooms · 25 leave confirm · 26 4h reward top-left · 27 milestone bottom-right ·
28 square cards + sweep · 29 display name · 30 entry cap (not on switch) · 31 3 auto-packs → kick,
below boot → kick · 32 boot deducted at start · 33 sideshow · 34 Indian numbering + toggle.
Verbal additions: menu = exactly seen 200 / blind 200 / blind 5000; seen pot cap 1.2M; buy-chips
button; category tag; winner chip flight; action-bar icons; chat as left drawer; missed-turn warning.

---

## 11. Coding conventions
**Server**: ESM; `node:*` imports; default + named exports; `GameError(code, message)` /
`AuthError(code, message, status)` with **snake_case** codes; `_private` methods; section banners
`// ------ name`; JSDoc that explains *why* and cites `Requirement N`; option objects with
destructured defaults; enums via constants (pack *reasons* are plain strings); structured
`logger.info('msg', {meta})`; `Table` never logs — it emits; config read once. **Anything that
moves chips or ends a hand is `async` and returns from `_run`; entry points wrap, internals don't
(re-entering `_run` from inside the queue deadlocks).**
**Client**: `flutter_lints`, single quotes, British spelling; `final state = context.watch<GameState>();
final t = state.t;` at the top of `build`; M3 roles via `theme.colorScheme`; `.withValues(alpha:)`;
`late final AnimationController … ..repeat()` + `AnimatedBuilder` + `RepaintBoundary`;
`CustomPainter.shouldRepaint` compares all inputs; `LayoutBuilder` thresholds + `FittedBox`.

---

## 12. Gotchas

### 12.1 Operational
- **Verified end-to-end on 2026‑09‑07**: a Chaal tapped in the Flutter app on the Pixel 6 emulator
  produced a `chip_ledger` row (`bet −400`, the app's uuid `action_id`, `hand_id` set), `pots.amount`
  matched `game_states.state.hand.pot`, and `SUM(delta) == chips` for the account. Repeat this check
  after any change to `ledger.js` or `_chargeToPot`.
- **`pgrep -f`/`pkill -f` match your own shell command line** and kill the session (exit 137/144) —
  ~6 times so far. Use `pgrep -f "[b]ot\.js"`, find the server by port (`ss -lptn`), and **never
  put a kill and a start in one command**.
- **Restart the server after any `src/` or `config/` change** — a long-lived process silently runs
  old code (a client fell back to a default once because `publicGameConfig` lacked a new key).
- **Bots reconnect to their previous table** (server restores seated users on connect). Use
  `--churn`, or wait out the 30s grace.
- `adb exec-out screencap` back-to-back returns **stale duplicate frames**; sleep ≥1s between grabs.
  Detect Flutter overflows with `adb logcat -d | grep -ic overflowed`.
- `screenrecord` silently falls back to 1280×720 letterboxed; crop with ffmpeg `crop=1280:588:0:66`.
- Pixel 7 Pro AVD: `settings put secure stylus_handwriting_enabled 0`.
- Use `uiautomator dump` bounds for taps; screenshot coordinates are display-scaled.
- Test schemas are dropped in `test.after`; a crashed run can leave `test_*` schemas — see §4 psql
  check and `DROP SCHEMA test_x CASCADE`.

### 12.2 Server
- `pg` returns BIGINT/NUMERIC as **strings** unless parsed — `db/index.js` sets both parsers; don't
  bypass it with a second Pool.
- `search_path` is a connection *option*; a per-connection `SET` on `pool.on('connect')` races the
  pool and trips a pg deprecation warning.
- A `Table` with no `'error'` listener emits `persistError` instead when a settle retry is abandoned;
  RoomManager attaches both listeners. Bare unit-test tables don't.
- `_endHand` credits the winner in memory only when `balances` **lacks the key** — a returned
  balance of exactly 0 is valid; never `|| fallback`.
- Every login **overwrites `display_name`** with the provider's name — a rename is clobbered on next
  login (known, unresolved vs. req. 29).
- Rate-limit trips **do not ack**. `room:create` does not `broadcastState`. `roomCode()` has no
  collision check. `sweepEmptyTables` uses a hardcoded 30s. `handsToNextMilestone` says 25 (not 0)
  at an exact multiple — use `milestoneAvailable`.
- Dead surface with no caller: `GET /api/rooms`, `GET /api/auth/me/hands`, inbound `lobby:list`,
  `chat:history`, `ping:rtt`.
- **SQLite is gone entirely** (file, driver, import tool). The 41 old accounts (4,494 hands, 16,471
  ledger rows) were imported once on 2026‑09‑07; 12 of them didn't reconcile (the old `kicktest.mjs`
  wrote `users.chips` with no ledger row; old settlement clamped at 0) and got a
  `legacy_reconciliation` row each. `kicktest.mjs` now writes a `test_fixture` ledger row.
- **`persisted` is reported by the ledger, not assumed.** `ledger.bet()`/`collectBoot()` return how
  much they actually banked (all of it for Postgres; `0` for a `memoryLedger` with no `persistChips`
  hook). `_endHand`'s `delta = net + persisted` therefore gives the `settle` callback *net* deltas
  summing to 0 in bookless unit tests, and *payout-only* deltas (winner `+pot`, losers `0`) in
  production. Assuming `persisted = amount` broke conservation in four unit tests.

### 12.3 Flutter
- The 1s ticker: `watch` GameState only where per-second rebuilds are wanted.
- `FractionallySizedBox` with only `widthFactor` and a childless child **collapses to zero height**
  (needed `heightFactor: 1`, `alignment: centerLeft`).
- Both `game:showdown` and `game:handEnded` hit `onShowdown`; only the latter has `nextHandAt`.
- Refused moves surface **twice** (ack + `game:error`).
- `GameConfig.fromJson` ints fall to 0 → `config.maxPlayers == 0 ? 5 : …` guards.
- `Avatar` SVG branch has no `errorBuilder`. `_PotChips` animates only on increase. `PlayingCard`
  flips only face-down↔up. Only 5 `_places`.
- Google/Facebook buttons `onPressed: null` — SDKs not bundled; "use provider picture" disabled.
- `main()` awaits `/api/auth/me` with no timeout before the first frame.
- Chat field `maxLength: 200` vs server 140 (see §7.4).

---

## 13. Known stale / leftover items
- `README.md` / `server/README.md` were rewritten for Postgres/Flutter; the "measured performance"
  numbers in both still date from the SQLite build and have not been re-measured on Postgres.
- `flutter-client/README.md` and `pubspec.yaml description` are `flutter create` boilerplate.
- `flutter-client/test/widget_test.dart` was **deleted on purpose** (template counter test).
- **Untracked real work needing `git add`**: `flutter-client/android/…/values-v31/`,
  `values-night-v31/`, `lib/widgets/buy_chips.dart`, `test/number_format_test.dart`,
  `server/test/sideshow.test.js`, `server/src/db/ledger.js`.
  `unity-client/` deletion (145 files, incl. 55 committed CMake `.utmp` outputs) is **staged**.
- `server/kicktest.mjs` (tracked) and `server/peek-tmp.mjs` (untracked) are scratch.
- `csharpJsonPort.js`/`socketProtocol.test.js` guard a wire format whose C# original is gone.
- `GameConnection.onCards`/`requestCards()` wired but unused; `room:moved` `state` branch dead.
- Local demo video: `~/Downloads/king-teenpatti-walkthrough.mp4`.
