# King Teen Patti — Rules Engine (`Table`) behavioural specification

Source of truth: the Node working tree at `/home/suraj/Project/king-teenpatti/server/src/game/`
(`table.js` 1842 lines, `handRank.js`, `deck.js`, `constants.js`, `chat.js`), `src/db/ledger.js`,
`src/util/ids.js`, and the unit suites under `server/test/`. Every rule below cites `file:lines`.
All paths are relative to `server/`.

Legend used throughout:

| Tag | Meaning |
|---|---|
| **MUST** | Wire/DB behaviour that clients, the database, or the other Go components depend on. Reproduce exactly (field names, key order, null vs 0 vs absent, error code strings, event order). |
| *incidental* | Internal naming, logging, unreachable branches, or behaviour no consumer observes. Free to restructure, but the observable result must not change. |

JSON key **order** is given as the Node code inserts it (V8 preserves insertion order and
`JSON.stringify` emits it). Socket.IO clients do not depend on key order, but `game_states.state`
and `hands.summary_json` are stored as JSONB (Postgres normalises key order, so DB order is not
observable). Treat key order as *incidental* but keep it where free.

---

## 1. Constants (`src/game/constants.js`)

All values are lower-case strings and travel on the wire and into the DB verbatim. **MUST**.

| Group | Name | Value | Ref |
|---|---|---|---|
| `TABLE_CATEGORY` | `BLIND` | `"blind"` | constants.js:11-14 |
| | `SEEN` | `"seen"` | |
| `TABLE_STATE` | `WAITING` | `"waiting"` | constants.js:17-22 |
| | `STARTING` | `"starting"` | |
| | `BETTING` | `"betting"` | |
| | `SHOWDOWN` | `"showdown"` | |
| `SEAT_STATE` | `EMPTY` | `"empty"` | constants.js:25-32 |
| | `WAITING` | `"waiting"` | |
| | `ACTIVE` | `"active"` | |
| | `PACKED` | `"packed"` | |
| | `LOST` | `"lost"` | |
| | `WON` | `"won"` | |
| `ACTION` | `SEE` | `"see"` | constants.js:35-42 |
| | `CHAAL` | `"chaal"` | |
| | `RAISE` | `"raise"` | |
| | `PACK` | `"pack"` | |
| | `SHOW` | `"show"` | |
| | `SIDESHOW` | `"sideshow"` | |
| `WIN_REASON` | `LAST_STANDING` | `"last_standing"` | constants.js:45-51 |
| | `SHOW` | `"show"` | |
| | `FORCED_SHOWDOWN` | `"forced_showdown"` | |
| | `ALL_LEFT` | `"all_left"` | |
| | `POT_LIMIT` | `"pot_limit"` | |

Pack *reasons* are plain strings, not an enum: `"pack"`, `"timeout"`, `"sideshow"`, and — for a
removal — whatever reason `removePlayer` was given (`"left"` default, `"disconnected"`, `"moved"`,
`"idle"`, `"insufficient_chips"`, …) (table.js:223, 257-264, 954, 1265).

---

## 2. Configuration the Table reads

The Table receives a plain `config` object and reads it **raw — no defaults are merged** except the
three `??` fallbacks noted. A missing key behaves as `undefined`, and JS comparisons against
`undefined` are `false` (see §27 Traps). Table-relevant keys (table.js references given):

| Key | Used at | Production value (RoomManager `_createTable`, roomManager.js:100-151) | `??` fallback in Table |
|---|---|---|---|
| `maxPlayers` | seats array length, `isFull`, `serializeFor` | 5 | none |
| `minPlayers` | start gate, cancel gate | 2 | none |
| `bootAmount` | boot, funded check, per-bet ceiling | 200 / 5000 (public), forced 200 (private) | none |
| `category` | `"blind"` → BLIND, anything else → SEEN (table.js:69-71) | normalised category | — |
| `maxPot` | `this.maxPot = config.maxPot ?? 0` (table.js:78) | seen public 1,200,000; private 500,000; blind public **absent → 0** | `?? 0` |
| `turnTimeoutMs` | turn clock | 25000 | none |
| `nextHandDelayMs` | start countdown, retry delay, `nextHandAt` | 4000 (tests use 6000) | none |
| `maxBetRounds` | forced showdown (`?? 0`) | seen 7; blind 0; private inherits category | `?? 0` (table.js:721) |
| `potLimitMultiplier` | per-bet ceiling (`?? 1024`) | seen 1024 (global default); blind 0 | `?? 1024` (table.js:767) |
| `maxRaiseSteps` | ladder rungs (`?? 8`) | seen 2; blind 0; private 2 | `?? 8` (table.js:774) |
| `maxBlindMoves` | auto-reveal cap | 4 | none |
| `maxMissedTurns` | idle kick | 3 | none |
| `sideshowTimeoutMs` | sideshow expiry | 6000 | none |
| `sideshowMinPlayers` | sideshow gate | 3 | none |
| `chatMaxHistory`, `chatMaxLength` | `RoomChat` | 100 / 140 | RoomChat's own defaults from global config when `undefined` (chat.js:16) |

Production `config` also carries every other `config.game.*` key (spread in), which the Table ignores.
RoomManager additionally sets `table.isPrivate = isPrivate` after construction (roomManager.js:153) —
never serialised by the Table; *incidental* to this spec.

**MUST**: the numeric meaning of `0` for `maxPot`, `maxBetRounds`, `maxRaiseSteps`,
`potLimitMultiplier` is "unlimited" (table.js:721-722, 767-775, 779, 739).

---

## 3. Construction and state fields

### 3.1 `new Table({ id, code, config, ledger, settle, persistChips, timers })` (table.js:42-99)

| Field | Initial | Notes |
|---|---|---|
| `id` | ctor arg | The roomId (uuid v4 from RoomManager). |
| `code` | ctor arg | 6-char room code. |
| `config` | ctor arg | raw |
| `ledger` | `ledger ?? memoryLedger({settle, persistChips})` | §22 |
| `timers` | ctor arg or `{setTimeout, clearTimeout}` wrapping globals (table.js:1837-1840) | Every timer in the Table goes through this object. |
| `version` | `0` | +1 per **committed** write (boot, bet, show, settle, settle retry). |
| `category` | `"blind"` iff `config.category === "blind"`, else `"seen"` | |
| `maxPot` | `config.maxPot ?? 0` | |
| `seats` | array of `config.maxPlayers` × `null` | Index = seat index. |
| `state` | `"waiting"` | |
| `handNo` | `0` | |
| `hand` | `null` | |
| `dealerSeat` | `-1` | |
| `createdAt` | `Date.now()` | *incidental* (RoomManager sweeps use it) |
| `startsAt` | `undefined` (serialised as `null`) | set in `_maybeStart` |
| `chat` | `new RoomChat({maxHistory: config.chatMaxHistory, maxLength: config.chatMaxLength})` | §25 |
| `_turnTimer`, `_startTimer` | `null` | |
| `_destroyed` | `false` | |
| `_queue` | resolved promise | §5 |

Derived getters (table.js:121-135, 590-592): `occupiedSeats` = non-null seats **in ascending seat
index**; `playerCount`; `isFull` = `playerCount >= maxPlayers`; `isEmpty`; `activeSeats` = occupied
seats with `status === "active"` (ascending index). `findSeat(userId)` → seat or `null`.

### 3.2 Seat (table.js:152-179)

| Field | Initial | Reset at hand start (table.js:447-455)? | Serialised? |
|---|---|---|---|
| `seatIndex` | first null index | — | yes |
| `userId`, `displayName` | args | — | yes |
| `avatarUrl` | `avatarUrl ?? null` | — | yes |
| `chips` | arg | set from DB balance / `-= boot` for participants | yes (redacted on blind tables) |
| `socketId` | arg | — | no |
| `connected` | `true` | — | yes |
| `status` | `"waiting"` | participants → `"active"`, others → `"waiting"` | yes |
| `cards` | `[]` | `[]`, then dealt hand for participants | only `you.cards` (seen) / `cardCount` |
| `isBlind` | `true` | `true` | yes |
| `blindMoves` | `0` | `0` | via `you.blindMovesLeft` |
| `missedTurns` | `0` | **NOT reset** at hand start; only by a successful `act` | `you.missedTurns` only |
| `sideshowAskedThisTurn` | `false` | **NOT reset** at hand start; reset by `_setTurn(freshTurn=true)` | no (drives `canSideshow`) |
| `lastBet` | `0` | `0` | yes |
| `lastAction` | `null` | `null` | yes |
| `contributed` | `0` | `0`, then `bootAmount` for participants | yes |
| `joinedAt` | `Date.now()` | — | no |
| `disconnectedAt` | `null` | — | no |
| `kickPending` | absent (`undefined`) | never cleared | no (table.js:688-689) |

Statuses `"won"`/`"lost"`/`"packed"` and `cards` **persist between hands** until the next
`_startHand` resets them (so a seen player's `you.cards` still returns the finished hand's cards, and
`cardCount` stays 3, during WAITING/STARTING).

### 3.3 Hand (table.js:379-401, plus fields added later)

| Field | Initial | Notes |
|---|---|---|
| `id` | uuid v4 | `handId` everywhere; becomes `pots.hand_id`, `hands.id`, ledger `hand_id`. |
| `handNo` | `table.handNo + 1` | |
| `startedAt` | `Date.now()` | epoch ms |
| `pot` | `bootAmount × participants` | |
| `stake` | `bootAmount` | **always in blind units** |
| `round` | `0` | |
| `packedUserIds` | `Set` | *incidental*, never read |
| `turnSeat` | `-1` | |
| `startSeat` | `-1` → first active seat left of dealer | |
| `seatOrder` | participants' seat indexes | *incidental*, never read |
| `showRequestedBy` | `null` | set by `_show` |
| `sideshow` | `null` | §12.6 object incl. `timer` |
| `lastDeparture` | `null` | userId of the most recent mid-hand leaver |
| `contributions` | `Map<userId, entry>` | §3.4 |
| `turnDeadline` | set by `_setTurn` | epoch ms |
| `turnToken` | set by `_setTurn` | uuid; stale-timeout guard |
| `endedAt` | set by `_endHand` | |

### 3.4 Contribution entry (table.js:403-417, 875-886)

`{ userId, displayName, seatIndex, contributed, status, sawCards, cards, didChaal, leftMidHand, persisted }`

- `contributed` starts at `bootAmount`; `persisted` starts `0` then is set to the ledger's reported
  `persisted` boot (table.js:444).
- `_syncContribution(seat, status = seat.status)` copies `contributed`, `status`, `sawCards = !isBlind`,
  `cards` from the seat (table.js:904-911). Called on see, pack, remove, showdown loss, win.
- `didChaal` → true on any chaal/raise (table.js:1059-1060) **and on a paid show** (table.js:1303-1304).
- `leftMidHand` → true when an active player is removed mid-hand (table.js:254-255).
- Entries are keyed by userId and **outlive the seat**: a leaver is still settled.

---

## 4. Table state machine

```
waiting ──(≥minPlayers funded, no start timer)──► starting ──(nextHandDelayMs)──► betting
   ▲                                                  │                              │
   │◄──(funded < minPlayers on removal: _cancelStart)─┘                              │
   │◄──(boot refused / participants < min at deal time)                              │
   │                                                                                 ▼
   └──────────────────(_endHand)──────────────── showdown ◄──(show / forced / pot cap)┘
                                                     (also directly betting → waiting via
                                                      last_standing / all_left: no showdown state)
```

| Transition | Trigger | Ref |
|---|---|---|
| `waiting → starting` | `_maybeStart()`: not destroyed, state waiting, no `_startTimer`, after `_sweepUnfunded()`, funded seats ≥ `minPlayers`. Sets `startsAt = now + nextHandDelayMs`, emits `state`, arms `_startTimer`. | table.js:308-328 |
| `starting → waiting` | `_cancelStart()` when an active-less removal leaves funded < minPlayers during STARTING (table.js:270-271); clears timer, `startsAt = null`, emits `state`. | table.js:330-338 |
| `starting → waiting` | `_startHand` finds participants < minPlayers (`startsAt = null`, emit `state`, return `null`). | table.js:363-369 |
| `starting → waiting` | `_startRefused` (ledger refused the boot). | table.js:494-519 |
| `starting/waiting → betting` | `_startHand` after `collectBoot` commits. | table.js:467-468 |
| `betting → showdown` | `_resolveShowdown` (from `_show`, `_forcedShowdown`, pot cap). | table.js:1333 |
| `betting/showdown → waiting` | `_endHand` (`hand = null`, `state = "waiting"`), then `_maybeStart()` immediately. | table.js:1505-1522 |

`_maybeStart` is called from: `addPlayer` (synchronously, **outside** the queue), `_removePlayer`
(waiting branch), `_endHand`, and the `_startRefused` retry timer.

Note `_startHand` does **not** check `state`; it checks `_destroyed` and `this.hand` (table.js:354-355).
A direct `startHand()` while WAITING with enough funded players deals immediately (tests use this).

---

## 5. The serial mutation queue `_run` (table.js:108-117)

```js
_run(fn) {
  const run = this._queue.then(fn, fn);           // fn runs whether the previous one resolved or rejected
  this._queue = run.then(() => undefined, () => undefined);   // the chain never rejects
  return run;                                     // caller sees fn's resolution/rejection
}
settled() { return this._queue; }
```

**Queued (return Promises):** `act`, `removePlayer`, `startHand`, `respondToSideshow`, `destroy`,
the start-timer callback, the turn-timeout callback, the sideshow-timeout callback, the
`_startRefused` retry callback (table.js:224, 326, 342, 511, 626, 924-926, 1179, 1202, 1764).

**Synchronous (not queued):** `addPlayer`, `postChat`, `chatHistory`, `setConnected`, `setChips`,
`serializeFor`, `summary`, `betOptions`, `turnOptions`, `showCost`, `sideshowBlockedReason`, and the
`_maybeStart()` invoked from `addPlayer` (which can emit `state` and `kick`, and arm a timer).

**Not queued but async:** `_retrySettle`'s timer callback runs `ledger.settle` outside the queue
(table.js:1540-1558). It only touches `version` and non-active seats' chips.

Internals (`_act`, `_pack`, `_endHand`, …) must never re-enter `_run` — it would deadlock.
A `kick` emitted mid-mutation leads the RoomManager to call `removePlayer`, which queues behind the
current mutation (tests use `await table.settled()` to observe it — seatKeeping.test.js:53-60).

---

## 6. Seating API

### 6.1 `addPlayer({ userId, displayName, avatarUrl, chips, socketId })` → seat (sync) (table.js:147-191)

Order of checks and effects — **MUST**:
1. `findSeat(userId)` → throw `GameError("already_seated", "You are already at this table")`.
2. `isFull` → throw `GameError("table_full", "This table is full")`.
3. Seat placed at the **lowest** null index (`findIndex(seat === null)`).
4. `emit("seatUpdated", { seatIndex })` (*incidental*: no listener).
5. `emit("chat", chat.addSystem(`${displayName} joined the table`))` — system message, §25.
6. `_maybeStart()` — may emit `kick`(s) via sweep and `state` (STARTING).
7. `emit("state", table)`.
8. Return the seat object.

A player joining during a live hand sits with `status: "waiting"`, `cards: []`, is not dealt in
(table.test.js:107-117). A player who joins with `chips < bootAmount` is seated (not refused here);
the sweep kicks them at the next `_maybeStart`/`_startHand`.

### 6.2 `removePlayer(userId, reason = "left")` → Promise<seat|null> (table.js:223-280)

Queued. `_removePlayer`:
1. No seat → resolve `null`, no events.
2. Record `wasOnTurn = hand?.turnSeat === seat.seatIndex`, `wasActive = status === "active"`.
3. If `hand.sideshow` exists and its `fromUserId` or `toUserId` is this user →
   `await _resolveSideshow(false, "left")` **before** the seat is vacated (§12.8). Side effect: if the
   leaver is the *asker*, `_resolveSideshow` re-arms their turn clock and emits a `turn` event for the
   leaver (turnSeat === fromSeat and they are still active at that instant); the pack that follows
   then clears it. Observed order: `sideshowResolved > turn > state > seatUpdated > chat > action(pack) > turn > state > state`.
4. `seats[i] = null`; `emit("seatUpdated", {seatIndex})`; `emit("chat", addSystem(`${displayName} left the table`))`.
5. If `wasActive && hand`:
   - `hand.packedUserIds.add(userId)`; `seat.status = "packed"`; `_syncContribution(seat, "packed")`
     (the detached seat object is mutated; the entry is what matters). **Note:** unlike `_pack`,
     `seat.lastAction` is *not* set (*incidental*, seat is gone).
   - `entry.leftMidHand = true`; `hand.lastDeparture = userId`.
   - `emit("action", { userId, action: "pack", amount: 0, pot, stake, reason })` — `reason` is the
     removal reason string.
   - `if (await _resolveIfOnlyOneLeft()) return seat` (hand ends; note **no** final `state` emit from
     this function in that path — `_endHand` emitted its own).
   - Else if `wasOnTurn`: `_clearTurnTimer(); await _advanceTurn(seat.seatIndex)`.
   - (If not on turn, the turn does not move.)
6. Else if `state === "starting"` and `_fundedSeats().length < minPlayers` → `_cancelStart()`.
7. Else if `state === "waiting"` → `_maybeStart()`.
8. `emit("state", table)`; return the (detached) seat.

Removal of a `waiting` seat during a live hand only does steps 4 and 8.

### 6.3 `setConnected(userId, connected, socketId = null)` (sync) (table.js:282-291)

Seat missing → `null`. Else `seat.connected = connected`; `seat.disconnectedAt = connected ? null : Date.now()`;
`if (socketId) seat.socketId = socketId`; emit `seatUpdated`, `state`. Return seat. No game effect;
a disconnected player still times out normally.

### 6.4 `setChips(userId, chips)` (sync) (table.js:294-299)

Sets `seat.chips`, emits `seatUpdated` only (no `state`). **No caller in `src/`** — *incidental*.

### 6.5 `postChat(userId, text)` / `chatHistory()` (table.js:199-217)

Not seated → `GameError("not_in_room", "You are not at this table")`. `chat.add(...)` returns `null`
when the sanitised text is empty → return `null`, no event. Else `emit("chat", message)`, return it.
`chatHistory()` → copy of the buffer, oldest first.

---

## 7. Hand start

### 7.1 `_maybeStart()` (table.js:308-328) — see §4. `_sweepUnfunded()` runs **before** the funded count.

### 7.2 `_startHand()` (table.js:353-487), inside the queue

1. `if (_destroyed) return null; if (hand) return null`.
2. `_sweepUnfunded()` (emits `kick` for each unfunded seat not already `kickPending`; the seats remain
   until the queued removal lands, so they are excluded as non-participants but still serialised).
3. `participants = _fundedSeats()` = occupied seats with `chips >= bootAmount`, ascending seat index.
   If `< minPlayers`: `state = "waiting"`, `startsAt = null`, emit `state`, return `null`.
4. `handId = uuid()`; `handNo = this.handNo + 1`;
   `dealerSeat = _nextOccupiedSeat(this.dealerSeat, participants)` = the first participant seat index
   strictly clockwise (ascending, wrapping) after the previous dealer (table.js:527-534). With
   `dealerSeat = -1` initially → the lowest participant index.
5. `deal(participants.length)` (§24): `hands[i]` belongs to `participants[i]`.
6. Build the `hand` object (§3.3) and contribution entries (§3.4) **off the table**.
7. `await ledger.collectBoot({ roomId: id, handId, bootAmount, entries: participants.map(s => ({ userId, amount: bootAmount, balanceBefore: s.chips })), version: this.version + 1, state: _snapshot({ hand, handNo, dealerSeat, deals: hands, participants, bootAmount }) })`.
   Result destructured as `{ balances, persisted: persistedBoot = bootAmount }` — an absent/undefined
   `persisted` means the full boot; a returned `0` (memory ledger without `persistChips`) is honoured.
   Any throw → `return _startRefused(error)`.
8. Commit path: `version += 1`; every entry `persisted = persistedBoot`; `this.handNo = handNo`;
   `this.dealerSeat = dealerSeat`.
   For **every occupied seat**: `cards = []`, `isBlind = true`, `blindMoves = 0`, `lastBet = 0`,
   `lastAction = null`, `contributed = 0`, `status = participant ? "active" : "waiting"`.
   For participants: `cards = hands[i]`, `contributed = bootAmount`,
   `chips = hasOwnProperty(balances, userId) ? balances[userId] : chips - bootAmount`
   (key-presence test, so a DB balance of `0` is honoured).
9. `this.hand = hand`; `state = "betting"`; `startsAt = null`.
10. `emit("handStarted", { handId, handNo, dealerSeat, bootAmount, pot, stake, participants: [userId…] })`.
11. `firstSeat = _nextActiveSeat(dealerSeat)`; `hand.startSeat = firstSeat`; `_setTurn(firstSeat)`
    (emits `turn`); `emit("state")`. Return `hand`.

The dealer's own seat is a participant and plays **last** in the first rotation (play opens to the
dealer's left = next higher index).

### 7.3 `_startRefused(error)` (table.js:494-519)

1. `emit("persistError", { reason: "boot", error })`.
2. `state = "waiting"`, `startsAt = null`.
3. If `error.code === "insufficient_chips" && error.userId`: find that seat; if present
   `seat.chips = Math.min(seat.chips, bootAmount - 1)` and `_kick(seat, "insufficient_chips", "You don't have enough coins to remain in this table")`.
   **No retry timer is armed** in this branch — the restart relies on the kick → `removePlayer` →
   waiting-branch `_maybeStart()`. If the seat is not found nothing restarts the table until the next
   add/remove (trap).
4. Else if not destroyed: arm `_startTimer` for `nextHandDelayMs` → `_run(() => _maybeStart())`.
5. `emit("state")`; return `null`.

---

## 8. Turn order helpers (table.js:523-592, 743-745)

- `_nextActiveSeat(from)`: for step 1..N: `idx = (from + step + N) % N`; first seat with
  `status === "active"`; else `-1`. Clockwise = **ascending index, wrapping**.
- `_rightActiveSeat(from)`: for step 1..N: `idx = (from - step + 2N) % N`; first active seat with
  `idx !== from`; else `-1`. "Right" = descending index = the player who acted immediately before.
- `_nextOccupiedSeat(from, pool)`: as `_nextActiveSeat` but membership in `pool`'s seat indexes;
  fallback `pool[0]?.seatIndex ?? -1` (unreachable when pool non-empty).
- `_distance(from, to) = (to - from + N) % N`.
- `_seatsInOrder()` — unused, *incidental*.

---

## 9. Turn clock, missed turns, kick

### 9.1 `_setTurn(seatIndex, { freshTurn = true })` (table.js:601-628)

- `seatIndex < 0` → return **without** changing anything (hand.turnSeat keeps its old value; no timer).
- `hand.turnSeat = seatIndex`; if `freshTurn` → `seat.sideshowAskedThisTurn = false`.
- `deadline = Date.now() + turnTimeoutMs`; `hand.turnDeadline = deadline`; `hand.turnToken = uuid()`.
- `emit("turn", { userId, seatIndex, deadline, timeoutMs: config.turnTimeoutMs, options: turnOptions(seat) })`.
- `_clearTurnTimer()`; arm `_turnTimer` = `timers.setTimeout(() => { _turnTimer = null; return _run(() => _onTurnTimeout(seatIndex, token)) }, turnTimeoutMs)`.

### 9.2 `_onTurnTimeout(seatIndex, token)` (table.js:641-656)

Guards, in order, each returning silently: `!hand`; `!seat`; `hand.turnSeat !== seatIndex`;
`token && hand.turnToken !== token`; `seat.status !== "active"`.
Then `seat.missedTurns += 1`; `await _pack(seat, "timeout")`; then if
`seat.missedTurns >= config.maxMissedTurns` →
`_kick(seat, "idle", `Left the table after ${seat.missedTurns} missed turns`)` (the kick is emitted
*after* the pack, which may already have ended the hand and started the next countdown).

### 9.3 `_kick(seat, reason, message)` (table.js:665-672)

`emit("kick", { userId, displayName, reason, message })`. The Table never removes the seat itself.
Kick reasons emitted by the Table: `"idle"`, `"insufficient_chips"`. Messages (**MUST**, shown to users):
`"Left the table after N missed turns"`, `"You don't have enough coins to remain in this table"`.

### 9.4 `missedTurns` reset

Only at the end of a **successful** `_act` of any kind — including an off-turn `see` and a sideshow
request (table.js:968). Never reset at hand start or on join.

---

## 10. `_sweepUnfunded()` and `kickPending` (table.js:681-696)

`if (hand) return;` — never mid-hand. For each occupied seat with `chips < bootAmount`: skip if
`seat.kickPending`; else `seat.kickPending = true` and
`_kick(seat, "insufficient_chips", "You don't have enough coins to remain in this table")`.
`kickPending` is never cleared (the seat is removed by the handler). A seat at exactly `bootAmount`
is funded; after paying the boot it may sit at 0 chips mid-hand and is not kicked until the hand ends
(seatKeeping.test.js:188-199).

---

## 11. Bet ladder

### 11.1 `betOptions(seat)` (table.js:761-798) — **MUST** reproduce exactly

```
unit          = hand.stake                              // blind units
base          = seat.isBlind ? unit : unit * 2
multiplier    = config.potLimitMultiplier ?? 1024
perBetCeiling = multiplier > 0 ? config.bootAmount * multiplier : +Infinity
ceiling       = min(perBetCeiling, seat.chips)
configured    = config.maxRaiseSteps ?? 8
maxSteps      = configured > 0 ? configured : +Infinity
headroom      = this.maxPot ? this.maxPot - hand.pot : +Infinity     // maxPot 0 → unlimited
steps = []
amount = min(base, perBetCeiling)        // NOTE: not `base`
while (amount <= ceiling && amount <= headroom && steps.length < maxSteps) { steps.push(amount); amount *= 2 }
return { steps, chaal: steps[0] ?? null, raise: steps[1] ?? null, max: steps.at(-1) ?? null }
```

Consequences:
- Rungs double: `[base, 2base, 4base, …]`. Verified `[100,200,…,12800]` for boot 100, 8 steps
  (raiseLadder.test.js:59-73).
- `steps` is `[]` when `base > chips` (or `> headroom`); then `chaal/raise/max` are `null`.
- **Quirk (MUST keep):** if `base > perBetCeiling`, the first rung is `perBetCeiling` itself, not a
  multiple of `base`. Verified: boot 100, `potLimitMultiplier: 4`, blind stake 800 →
  `{steps:[400], chaal:400, raise:null, max:400}`.
- `headroom` is checked against each rung's own amount (a rung that would push the pot past `maxPot`
  is withheld: pot 4000, cap 5000, boot 200 → `[200,400,800]`, privateTables.test.js:325-348).
- `betOptions` dereferences `this.hand` — only call with a live hand.

### 11.2 `showCost(seat)` = `betOptions(seat).chaal` (table.js:801-804) — may be `null`.

### 11.3 `turnOptions(seat)` (table.js:806-831) — the `you.options` / `game:yourTurn.options` object, **MUST**

```json
{ "canSee": <isBlind>, "canSideshow": <sideshowBlockedReason(seat) === null>,
  "sideshowWith": <displayName of _rightActiveSeat | null when blocked or none>,
  "chaal": <int|null>, "raise": <int|null>, "raiseSteps": [<int>...], "maxBet": <int|null>,
  "show": <int|null>, "canPack": true, "isBlind": <bool>, "currentStake": <hand.stake>,
  "chips": <seat.chips>, "pot": <hand.pot> }
```

- `show` = `showCost(seat)` only when `activeSeats.length === 2` **and** cost non-null **and**
  `seat.chips >= cost`; else `null`.
- `sideshowWith` is computed only when not blocked (`rightIndex = blocked ? -1 : _rightActiveSeat`).

---

## 12. Actions

### 12.1 `act(userId, action, payload = {})` → Promise (table.js:924-970)

`_act` check order — **MUST** (the first failing check wins):

| # | Condition | Error code | Message |
|---|---|---|---|
| 1 | `!hand` | `no_hand` | `No hand is in progress` |
| 2 | no seat | `not_seated` | `You are not at this table` |
| 3 | `seat.status !== "active"` | `not_in_hand` | `You are not in this hand` |
| 4 | `action !== "see" && hand.turnSeat !== seat.seatIndex` | `not_your_turn` | `It is not your turn` |
| 5 | dispatch: `see`→`_see`; `chaal`→`_bet(seat,"chaal",amount,actionId)`; `raise`→`_bet(seat,"raise",…)`; `pack`→`_pack(seat,"pack")`; `show`→`_show(seat,actionId)`; `sideshow`→`_requestSideshow(seat)`; default → | `unknown_action` | `Unknown action "<action>"` |

Note: an unknown action sent off-turn yields `not_your_turn` (check 4 precedes the switch). In
production the socket layer rejects unknown actions before the Table (socket/index.js:596-598).
After a successful dispatch: `seat.missedTurns = 0`; return the handler's result (this is what the
socket layer spreads into the ack: `{ ok: true, ...result }`, socket/index.js:465).

Return values (**MUST**, they reach the client in the ack):

| Action | Result |
|---|---|
| see | `{ action: "see", auto: false }` |
| chaal / raise | `{ action: "chaal"\|"raise", amount, autoSeen: <bool> }` |
| pack | `{ action: "pack", reason: "pack" }` |
| show | `{ action: "show", amount: <cost> }` |
| sideshow | `{ action: "sideshow", toUserId }` |

### 12.2 `_see(seat, { auto = false })` (table.js:976-1008)

1. `!seat.isBlind` → `GameError("already_seen", "You have already seen your cards")`.
2. `isBlind = false`; `_syncContribution(seat)` (sets `sawCards = true`).
3. `emit("cards", { userId, cards: seat.cards.map(cardCode) })`.
4. `emit("action", { userId, action: "see", amount: 0, auto, pot, stake })` — note `auto` key is
   always present (`false`/`true`); no `reason` key.
5. If `!auto && hand.turnSeat === seat.seatIndex`:
   `emit("turn", { userId, seatIndex, deadline: hand.turnDeadline, timeoutMs: max(0, turnDeadline - now), options: turnOptions(seat) })`
   — re-issued with the **remaining** time; the timer and `turnToken` are **not** touched.
6. `emit("state")`; return `{ action: "see", auto }`.

SEE is free, allowed off-turn, never moves the turn or the clock (blindRules.test.js:177-217).

### 12.3 `_bet(seat, kind, requested, actionId)` (table.js:1022-1089) — `kind ∈ {"chaal","raise"}`

Validation order — **MUST**:

| # | Condition | Code | Message |
|---|---|---|---|
| 1 | `options.steps.length === 0` | `insufficient_chips` | `Not enough chips to bet` |
| 2a | `requested` is `undefined`/`null` → `amount = options[kind]` (`chaal`→`steps[0]`, `raise`→`steps[1]`, may be `null`) | | |
| 2b | else `!Number.isInteger(requested)` | `invalid_bet` | `Bet amount must be a whole number` |
| 2c | else `!steps.includes(requested)` | `invalid_bet` | `That bet amount is not available` |
| 2d | else `kind === "raise" && requested < steps[0] * 2` | `invalid_bet` | `A raise must be at least double the chaal` |
| 3 | `!amount || amount <= 0` (covers `null` default for an unavailable raise) | `invalid_bet` | `That bet is not available` |
| 4 | `seat.chips < amount` (normally unreachable — ladder ≤ chips) | `insufficient_chips` | `Not enough chips for that bet` |
| 5 | `await _chargeToPot(seat, amount, { actionId, reason: "bet" })` — may throw `insufficient_chips` / `duplicate_action` / `persist_failed` (§12.4) | | |

Note 2c: a "raise" of exactly `steps[0]` with a 2-rung ladder passes 2c and fails 2d; a bare
`raise` (no amount) when `steps.length === 1` → `amount = null` → rule 3 `invalid_bet`.
`NaN`, `Infinity`, `100.5`, `-100` → 2b (raiseLadder.test.js:253-267).

After the charge commits:
6. `seat.lastBet = amount`; `seat.lastAction = kind === "raise" ? "raise" : "chaal"`.
7. `entry.didChaal = true`.
8. `hand.stake = seat.isBlind ? amount : Math.floor(amount / 2)` (**blind units**; evaluated with the
   *pre-reveal* `isBlind`).
9. `emit("action", { userId, action: "chaal"|"raise", amount, pot, stake })` (no `reason`, no `auto`).
10. If `seat.isBlind`: `blindMoves += 1`; if `blindMoves >= config.maxBlindMoves` →
    `_see(seat, { auto: true })` (emits `cards`, `action(see, auto:true)`, `state`; no `turn`) and
    `autoSeen = true`. The bet just made was charged at the blind rate (blindRules.test.js:242-266).
11. `_clearTurnTimer(); await _advanceTurn(seat.seatIndex)`; `emit("state")`;
    return `{ action: kind, amount, autoSeen }`.

Observed event order for a blind chaal that trips the cap:
`action:chaal > cards > action:see(auto) > state > turn > state > state`.

### 12.4 `_chargeToPot(seat, amount, { actionId, reason })` (table.js:840-889)

```
version = this.version + 1
result = await ledger.bet({ userId, amount, roomId: id, handId: hand.id,
                            actionId: actionId ?? uuid(), reason,           // reason: "bet" | "show"
                            balanceBefore: seat.chips, version,
                            state: _snapshotAfterBet(seat, amount) })
```
On throw: `emit("persistError", { userId, delta: -amount, reason, error })` then throw
`_refusal(error)` (table.js:892-901):

| `error.code` | GameError |
|---|---|
| `insufficient_chips` | `("insufficient_chips", "Not enough chips for that bet")` |
| `duplicate_action` | `("duplicate_action", "That move was already applied")` |
| anything else | `("persist_failed", "The move could not be recorded, so nothing was changed")` |

Nothing in memory changes on failure. On success: `this.version = version`;
`balance = Number.isFinite(result?.balance) ? result.balance : seat.chips - amount`;
`persisted = Number.isFinite(result?.persisted) ? result.persisted : amount`;
`seat.chips = balance`; `seat.contributed += amount`; `hand.pot += amount`; the contribution entry
gets `contributed = seat.contributed`, `persisted += persisted` (or is created — table.js:875-886,
practically unreachable). Returns `balance`.

### 12.5 `_pack(seat, reason, { advanceTurn = true })` (table.js:1098-1120)

1. `status = "packed"`; `lastAction = "pack"`; `packedUserIds.add`; `_syncContribution(seat, "packed")`.
2. `emit("action", { userId, action: "pack", amount: 0, pot, stake, reason })`.
3. `_clearTurnTimer()` (even when `advanceTurn` is false).
4. `if (await _resolveIfOnlyOneLeft()) return { action: "pack", reason }`.
5. `if (advanceTurn) await _advanceTurn(seat.seatIndex)`.
6. `emit("state")`; return `{ action: "pack", reason }`.

`_resolveIfOnlyOneLeft()` (table.js:1123-1140): `active = activeSeats`; if `> 1` → `false`.
If exactly 1 → `_endHand({ winnerId: active[0].userId, reason: "last_standing", reveals: [] })`.
If 0 → `_endHand({ winnerId: hand.lastDeparture, reason: "all_left", reveals: [] })`. Return `true`.

### 12.6 `_requestSideshow(seat)` (table.js:1150-1198)

`blocked = sideshowBlockedReason(seat)` (§12.7). If blocked → `GameError(blocked, message)` with:

| code | message |
|---|---|
| `sideshow_pending` | `A sideshow is already in progress` |
| `already_asked` | `You have already asked for a sideshow this turn` |
| `too_few_players` | `` `A sideshow needs at least ${config.sideshowMinPlayers} players in the hand` `` |
| `you_are_blind` | `See your cards before asking for a sideshow` |
| `neighbour_is_blind` | `The player on your right has not seen their cards` |
| `no_neighbour` | `There is nobody on your right to ask` |
| any other (`no_hand`, `not_in_hand`, `not_your_turn` — unreachable via `_act`) | `You cannot ask for a sideshow now` |

Then: `target = seats[_rightActiveSeat(seat.seatIndex)]`; `seat.sideshowAskedThisTurn = true`;
`_clearTurnTimer()` (the turn clock **stops**); `expiresAt = now + sideshowTimeoutMs`;
```
hand.sideshow = { fromUserId, fromSeat, toUserId, toSeat, expiresAt,
                  timer: timers.setTimeout(() => _run(() => _resolveSideshow(false, "timeout")), sideshowTimeoutMs) }
```
`emit("sideshowRequested", { fromUserId, fromName, fromSeat, toUserId, toName, toSeat, expiresAt, timeoutMs: config.sideshowTimeoutMs })`
(no cards); `emit("state")`; return `{ action: "sideshow", toUserId }`.

### 12.7 `sideshowBlockedReason(seat)` (table.js:558-578) — order **MUST**

1. `!hand` → `"no_hand"`
2. `seat.status !== "active"` → `"not_in_hand"`
3. `hand.turnSeat !== seat.seatIndex` → `"not_your_turn"`
4. `hand.sideshow` → `"sideshow_pending"`
5. `seat.sideshowAskedThisTurn` → `"already_asked"`
6. `activeSeats.length < config.sideshowMinPlayers` → `"too_few_players"`
7. `seat.isBlind` → `"you_are_blind"`
8. `_rightActiveSeat(seat.seatIndex) === -1` → `"no_neighbour"`
9. `seats[right].isBlind` → `"neighbour_is_blind"`
10. else `null` (allowed).

### 12.8 `respondToSideshow(userId, accept)` → Promise (table.js:1201-1210) and `_resolveSideshow(accepted, reason)` (table.js:1222-1285)

`respondToSideshow` (queued): `!hand?.sideshow` → `GameError("no_sideshow", "There is no sideshow to answer")`;
`pending.toUserId !== userId` → `GameError("not_your_sideshow", "That sideshow was not asked of you")`
(the asker cannot accept on the other's behalf); else `_resolveSideshow(Boolean(accept), accept ? "accepted" : "declined")`.
Socket layer passes `accept === true` (socket/index.js:639).

`_resolveSideshow(accepted, reason)` — `reason ∈ {"accepted","declined","timeout","left"}`:
1. `pending = hand?.sideshow`; none → return `null` (a late timer is a no-op).
2. Clear `pending.timer`; `hand.sideshow = null`.
3. `asker = findSeat(fromUserId)`, `asked = findSeat(toUserId)`; `packedUserId = null`;
   `bothInHand = asker?.status === "active" && asked?.status === "active"`.
4. If `accepted && bothInHand`:
   - `a = evaluate(asker.cards)`, `b = evaluate(asked.cards)`;
     `loser = compare(a, b) > 0 ? asked : asker` — **a tie packs the asker**.
   - `reveal = { reason, packedUserId, hands: [ { userId, displayName, cards: codes, handName: a.name } (asker), { … } (asked) ] }`
     — asker first, asked second.
   - `emit("sideshowReveal", { userIds: [asker.userId, asked.userId], reveal })` — the socket layer
     sends this to exactly those two users.
   - `await _pack(loser, "sideshow", { advanceTurn: loser === asker })` — if the *asked* player loses,
     the turn does not move (they never held it); if the asker loses, the turn advances from the asker.
     This pack can end the hand (`last_standing`).
5. `emit("sideshowResolved", { fromUserId, toUserId, accepted, reason, packedUserId })` (no cards).
   `accepted` may be `true` with `packedUserId: null` only if `bothInHand` was false (practically unreachable).
6. If `hand && hand.turnSeat === pending.fromSeat && asker && asker.status === "active"` →
   `_setTurn(pending.fromSeat, { freshTurn: false })`: a **full** new clock, new `turnToken`, `turn`
   event, but `sideshowAskedThisTurn` stays `true` (one ask per turn).
7. `emit("state")`; return `{ accepted, packedUserId }` (this is the `game:sideshowRespond` ack body).

Observed order on acceptance where the asker loses:
`sideshowReveal > action:pack/sideshow > turn > state > state > sideshowResolved > state`.
On a decline: `sideshowResolved > turn > state`.

The sideshow is **free** — no chips move (brief's decision; flagged in CLAUDE.md as an exploit vs. standard rules).

### 12.9 `_show(seat, actionId)` (table.js:1287-1317)

1. `active = activeSeats`; `active.length !== 2` → `GameError("show_unavailable", "A show needs exactly two players left")`.
2. `cost = showCost(seat)`; `cost === null || seat.chips < cost` → `GameError("insufficient_chips", "Not enough chips to pay for the show")`. **A show is never free.** A blind caller pays the blind chaal (stake), a seen caller pays `2 × stake`.
3. `await _chargeToPot(seat, cost, { actionId, reason: "show" })` (ledger `reason: "show"`).
4. `hand.showRequestedBy = seat.userId`; `entry.didChaal = true`.
5. `emit("action", { userId, action: "show", amount: cost, pot, stake })`.
6. `_clearTurnTimer(); await _resolveShowdown(active, "show", seat.userId)`; return `{ action: "show", amount: cost }`.

Show does **not** touch `lastBet`/`lastAction`/`stake`/`blindMoves` and is allowed while blind.

---

## 13. Advancing the turn, rounds, forced showdowns (table.js:698-745)

`_advanceTurn(fromSeat)`:
1. `!hand` → return.
2. `next = _nextActiveSeat(fromSeat)`; `-1` → return (no turn set).
3. `_potCapReached()` = `maxPot && hand && hand.pot + hand.stake > maxPot` (uses the **blind-unit
   stake**, not the next real bet) → `_clearTurnTimer(); await _resolveShowdown(activeSeats, "pot_limit", null)`; return.
4. `toNext = _distance(fromSeat, next)`, `toStart = _distance(fromSeat, hand.startSeat)`.
   If `toStart > 0 && toStart <= toNext` → `hand.round += 1` — i.e. the round increments whenever
   the turn lands **on or steps over** `startSeat` (the seat that opened the hand, even if since packed).
   Then `roundCap = config.maxBetRounds ?? 0`; if `roundCap > 0 && hand.round >= roundCap` →
   `await _forcedShowdown()` (`_clearTurnTimer(); _resolveShowdown(activeSeats, "forced_showdown", null)`); return.
5. `_setTurn(next)`; `emit("state")`.

Round semantics: `round = N` after N complete rotations. Seen tables (`maxBetRounds: 7`) end when
the turn would return to the opener for the 7th time → each player has bet 7 times.
Blind tables (`maxBetRounds: 0`) never force a showdown (tableRules.test.js:610-633).
`_advanceTurn` is also reached from `_removePlayer` (leaver on turn), so a leave can trigger a
pot-limit or forced showdown.

---

## 14. Showdown and tie-breaks — `_resolveShowdown(contenders, reason, showRequestedBy)` (table.js:1332-1379)

1. `state = "showdown"`.
2. `scored = contenders.map(seat => ({ seat, hand: evaluate(seat.cards) }))` — contenders arrive in
   ascending seat order (`activeSeats`).
3. Tie preference list: contenders sorted by `_distance(dealerSeat, seatIndex)` ascending (**the
   dealer's own seat, distance 0, ranks first**, then the dealer's left, …), mapped to userIds, with
   `showRequestedBy` removed and appended **last** (if non-null). Ties therefore go against the show
   payer; in a forced/pot-limit showdown to the seat nearest the dealer (dealer first).
4. Best: `best = scored[0]; tied = [best]`; for each later candidate `diff = compare(candidate, best)`:
   `> 0` → `best = candidate; tied = [candidate]`; `=== 0` → `tied.push(candidate)`.
   If `tied.length > 1` → sort `tied` by preference index ascending; `best = tied[0]`.
5. `reveals = scored.map(({seat, hand}) => ({ userId, seatIndex, cards: hand.cards, handName: hand.name, category: hand.category, won: seat.userId === best.seat.userId }))`
   — `cards` are wire codes in the seat's card order; `category` is the **integer** 0–5.
6. `emit("showdown", { reveals, reason })`.
7. Every non-winning contender: `status = "lost"`, `_syncContribution(seat, "lost")`.
8. `await _endHand({ winnerId: best.seat.userId, reason, reveals })`.

The pot is never split (exactly one `won: true`).

---

## 15. Hand end and settlement — `_endHand({ winnerId, reason, reveals })` (table.js:1395-1523)

1. `!hand` → return.
2. `_clearTurnTimer()`; clear `hand.sideshow?.timer`; `hand.sideshow = null`; `hand.endedAt = now`.
3. `winnerSeat = winnerId ? findSeat(winnerId) : null`. If seated → `status = "won"`,
   `_syncContribution(winnerSeat, "won")`; else if `winnerId` (winner already left) → the contribution
   entry's `status = "won"`.
4. `contributors = [...contributions.values()].filter(e => e.contributed > 0)` (map insertion order =
   participant seat order).
5. Settlement entries — **MUST**:
   ```
   isWinner = e.userId === winnerId
   net      = winnerId ? (isWinner ? hand.pot - e.contributed : -e.contributed) : 0
   delta    = net + e.persisted
   entry    = { userId, delta, isWinner, didChaal: Boolean(e.didChaal), leftMidHand: Boolean(e.leftMidHand) }
   ```
   Production (`persisted == contributed`): winner `delta = pot`, losers `delta = 0`, no-winner
   `delta = contributed` (refund). Bookless memory ledger (`persisted == 0`): net deltas summing to 0.
6. `revealed = Set(reveals.map(r => r.userId))`;
   `summary = contributors.map(e => ({ userId, displayName, seatIndex, contributed, status, sawCards, cards: revealed.has(userId) ? e.cards.map(cardCode) : null }))`.
7. `record = { id: hand.id, roomId: this.id, handNo, pot, winnerId: winnerId ?? null, winReason: reason, bootAmount: config.bootAmount, startedAt, endedAt, summary }`.
8. `version = this.version + 1`; `state = _snapshot({ hand: null, stateOverride: "waiting" })`
   (seats already carry `won`/`lost`/`packed`, cards and contributions; `hand: null`; `handNo` = the
   hand just ended).
9. `try { balances = (await ledger.settle({ hand: record, entries, version, state })) ?? {}; this.version = version; settledInDb = true }`
   `catch (error) { emit("persistError", { reason: "settle", handId, error }) }` — **memory is updated
   regardless**; the hand is over.
10. For every `[userId, balance]` in `balances`: if seated → `seat.chips = balance` (verbatim; `0` is valid).
11. If `winnerSeat && !hasOwnProperty(balances, winnerSeat.userId)` → `winnerSeat.chips += hand.pot`
    (key presence, never truthiness — settlement.test.js:187-208).
12. If `!settledInDb` → `_retrySettle({ hand: record, entries, version, state }, 1)` (§15.1).
13. `winnerName = winnerSeat?.displayName ?? (winnerId ? contributions.get(winnerId)?.displayName : null) ?? null`.
14. `this.hand = null`; `state = "waiting"`; `nextHandAt = now + nextHandDelayMs`.
15. `emit("handEnded", { handId, handNo, winnerId: record.winnerId, winnerName, pot, reason, reveals, summary, nextHandAt })`.
16. `emit("state")`; `_maybeStart()` (may emit `kick`s and a second `state` for STARTING).

### 15.1 `_retrySettle(args, attempt)` (table.js:1529-1559)

- `_destroyed` → return. `attempt > 10` → `error = new Error(`settlement of hand ${id} failed after 10 attempts`)`;
  if `listenerCount("error") > 0` → `emit("error", error)` else `emit("persistError", { reason: "settle_abandoned", handId, error })`; return.
- `delay = min(30000, nextHandDelayMs * attempt)`; `timers.setTimeout(async () => { if destroyed return; version = this.version + 1; balances = (await ledger.settle({ ...args, version })) ?? {}; this.version = version; for seats in balances with status !== "active": chips = balance; emit("state") } catch → emit("persistError", { reason: "settle_retry", handId, attempt, error }); _retrySettle(args, attempt + 1) }, delay)`.
- Runs **outside** the `_run` queue. Re-sends the **original** (stale) `state` snapshot with a newer version.

---

## 16. `destroy()` → Promise (table.js:1763-1784)

Queued. If a hand is live: `winnerId = activeSeats[0]?.userId ?? hand.lastDeparture` (lowest active
seat index wins) and `await _endHand({ winnerId, reason: "all_left", reveals: [] })` — which emits
`handEnded`/`state` and calls `_maybeStart()` (possibly arming a start timer and emitting `state`
STARTING). Then `_destroyed = true`; `_clearTurnTimer()`; clear `_startTimer` (undoing that arm);
`chat.clear()`; `removeAllListeners()`. Seats are **not** cleared. A destroyed table never deals
(`_maybeStart`/`_startHand` check `_destroyed`).

---

## 17. Snapshots saved to `game_states.state` — `_snapshot(...)` (table.js:1568-1616), **MUST** (auditable DB content)

```json
{ "roomId": "<id>", "code": "<code>", "category": "seen|blind",
  "state": <stateOverride ?? (hand ? "betting" : this.state)>,
  "handNo": <int>, "dealerSeat": <int>,
  "hand": null | { "id", "handNo", "pot", "stake", "round", "turnSeat", "startSeat", "startedAt",
                   "showRequestedBy": <userId|null>,
                   "contributions": [ { "userId", "contributed", "persisted", "status", "didChaal", "leftMidHand" } ] },
  "seats": [ null | { "seatIndex", "userId", "displayName", "chips", "status", "isBlind", "blindMoves", "contributed", "cards": ["As","Td","7h"] } ] }
```
- `seats` has exactly `maxPlayers` entries, `null` for empty.
- With `deals`+`participants` (boot snapshot): participants are rendered *as they will be after the
  boot* — `chips - bootAmount`, `"active"`, `isBlind true`, `blindMoves 0`, `contributed bootAmount`,
  `cards` = dealt codes — while the `hand` object still has `turnSeat: -1`, `startSeat: -1`; state `"betting"`.
  Non-participant seats are rendered with their **current** values (which may be last hand's status and cards).
- Cards are included in full (server-side only; never sent to clients). `turnDeadline`, `turnToken`,
  `sideshow`, `lastDeparture`, `packedUserIds`, `seatOrder` are **not** in the snapshot.

`_snapshotAfterBet(seat, amount)` (table.js:1619-1633): `_snapshot()` then `hand.pot += amount`;
own seat `chips -= amount`, `contributed += amount`; own contribution `contributed += amount`,
`persisted += amount` (the snapshot always assumes the bet is fully banked).

---

## 18. `serializeFor(userId)` — the `room:joined` / `room:state` payload (table.js:1642-1739), **MUST**

Key order and types:

```json
{ "roomId": str, "code": str, "category": "seen|blind", "chipsHidden": bool,
  "state": "waiting|starting|betting|showdown", "handNo": int, "dealerSeat": int,
  "maxPlayers": int, "minPlayers": int, "bootAmount": int, "turnTimeoutMs": int,
  "startsAt": int|null, "pot": int, "maxPot": int, "stake": int, "round": int,
  "sideshow": null | { "fromUserId", "fromSeat", "toUserId", "toSeat", "expiresAt" },
  "turn": null | { "seatIndex": int, "userId": str|null, "deadline": int|null },
  "you": null | { "seatIndex", "chips", "status", "isBlind", "blindMovesLeft", "contributed",
                  "missedTurns", "maxMissedTurns", "cards": [codes], "options": null | <turnOptions> },
  "seats": [ { "seatIndex": i, "status": "empty" } | { "seatIndex", "userId", "displayName", "avatarUrl",
              "chips": int|null, "status", "isBlind", "lastBet", "lastAction": str|null, "contributed",
              "connected", "cardCount" } ] }
```

Rules:
- `chipsHidden = category === "blind"`.
- `startsAt = this.startsAt ?? null`; `pot = hand?.pot ?? 0`; `maxPot = this.maxPot` (0 = uncapped);
  `stake = hand?.stake ?? config.bootAmount`; `round = hand?.round ?? 0`.
- `sideshow`: the five public fields only — never cards, never `timer`.
- `turn`: present whenever `hand` exists; `userId = seats[turnSeat]?.userId ?? null`;
  `deadline = hand.turnDeadline ?? null`.
- `you`: `null` when the viewer is not seated. `blindMovesLeft = isBlind ? max(0, maxBlindMoves - blindMoves) : 0`.
  `cards = isBlind ? [] : cards.map(cardCode)` (own cards only once seen; still returned between hands).
  `options = hand && hand.turnSeat === viewer.seatIndex && viewer.status === "active" ? turnOptions(viewer) : null`.
  `missedTurns`/`maxMissedTurns` appear **only** here (seatKeeping.test.js:117-141).
- `seats[i]`: empty → `{ seatIndex, status: "empty" }` only. Occupied → `chips` is **`null`** (not 0)
  for every seat other than the viewer's when `chipsHidden`; the viewer's own `chips` is always the
  number. No seat entry ever has a `cards` key; `cardCount = seat.cards.length` (3 for participants,
  including after the hand until the next deal). `lastBet`, `lastAction`, `contributed`, `isBlind`,
  `connected`, `status` are public on both categories.

`summary()` (table.js:1742-1753): `{ roomId, code, category, state, players: playerCount, maxPlayers, bootAmount, pot: hand?.pot ?? 0 }`.

---

## 19. Event catalogue (Table → listeners) with payloads, **MUST**

The socket layer (socket/index.js:212-333) forwards them as shown in the last column.

| Event | Payload | Wire mapping |
|---|---|---|
| `state` | the Table itself | per-viewer `room:state` = `serializeFor(viewerId)` to every socket in the room |
| `seatUpdated` | `{ seatIndex }` | no listener (*incidental*) |
| `chat` | message object (§25) | `chat:message` `{ ...message, roomId }` to room; `null` messages skipped |
| `handStarted` | `{ handId, handNo, dealerSeat, bootAmount, pot, stake, participants: [userId] }` | `game:handStarted` `{ ...payload, roomId }` to room, then per-socket `player:hand` `{ roomId, dealt: true, cardsHidden: true }` |
| `cards` | `{ userId, cards: [codes] }` | `player:cards` `{ roomId, cards }` to that user only |
| `turn` | `{ userId, seatIndex, deadline, timeoutMs, options }` | `game:turn` `{ roomId, userId, seatIndex, deadline, timeoutMs }` to room (**no options**); `game:yourTurn` `{ roomId, deadline, timeoutMs, options }` to the player |
| `action` | `{ userId, action, amount, pot, stake }` + `reason` (pack) or `auto` (see) | `game:action` `{ ...payload, roomId }` to room |
| `sideshowRequested` | `{ fromUserId, fromName, fromSeat, toUserId, toName, toSeat, expiresAt, timeoutMs }` | `game:sideshowRequested` `{ ...payload, roomId }` to room |
| `sideshowReveal` | `{ userIds: [asker, asked], reveal: { reason, packedUserId, hands: [{ userId, displayName, cards, handName }×2] } }` | `game:sideshowReveal` `{ roomId, reveal }` to each of `userIds` only |
| `sideshowResolved` | `{ fromUserId, toUserId, accepted, reason, packedUserId }` | `game:sideshowResolved` `{ ...payload, roomId }` to room |
| `showdown` | `{ reveals: [{ userId, seatIndex, cards, handName, category, won }], reason }` | `game:showdown` `{ ...payload, roomId }` to room |
| `handEnded` | `{ handId, handNo, winnerId, winnerName, pot, reason, reveals, summary, nextHandAt }` | `game:handEnded` `{ ...payload, roomId }` to room |
| `kick` | `{ userId, displayName, reason, message }` | RoomManager `leave(userId, reason)` → `room:kicked` `{ roomId, reason, message }` to the user |
| `persistError` | `{ reason: "boot", error }` / `{ userId, delta, reason: "bet"\|"show", error }` / `{ reason: "settle"\|"settle_retry"\|"settle_abandoned", handId, [attempt], error }` | logged only (*incidental*) |
| `error` | `Error` (settlement abandoned, only if a listener exists) | logged (*incidental*) |

### 19.1 Observed event order per operation (verified by running the Node engine)

| Operation | Order |
|---|---|
| `addPlayer` (2nd player, triggers countdown) | `seatUpdated > chat > state(starting) > state` |
| `addPlayer` (no start) | `seatUpdated > chat > state` |
| `_startHand` | `handStarted > turn > state` |
| manual `see` on turn | `cards > action:see > turn > state` |
| manual `see` off turn | `cards > action:see > state` |
| chaal/raise, hand continues | `action > turn > state > state` |
| blind chaal hitting the cap | `action:chaal > cards > action:see(auto) > state > turn > state > state` |
| pack, hand continues | `action:pack > turn > state > state` |
| pack → last_standing | `action:pack > handEnded > state > [state(starting)]` |
| timeout | `action:pack/timeout > turn > state > state` (+ `kick` after, when the cap is hit) |
| show | `action:show > showdown > handEnded > state > state(starting)` |
| sideshow request | `sideshowRequested > state` |
| sideshow declined / timeout | `sideshowResolved > turn > state` |
| sideshow accepted, asker loses | `sideshowReveal > action:pack/sideshow > turn > state > state > sideshowResolved > state` |
| sideshow accepted, asked loses | `sideshowReveal > action:pack/sideshow > state > sideshowResolved > turn > state` |
| asker leaves with a request pending | `sideshowResolved > turn > state > seatUpdated > chat > action:pack/left > turn > state > state` |

---

## 20. GameError catalogue (`class GameError extends Error { name = "GameError"; code }`, table.js:1787-1793)

| code | Where | Message |
|---|---|---|
| `already_seated` | addPlayer | You are already at this table |
| `table_full` | addPlayer | This table is full |
| `not_in_room` | postChat | You are not at this table |
| `no_hand` | _act | No hand is in progress |
| `not_seated` | _act | You are not at this table |
| `not_in_hand` | _act | You are not in this hand |
| `not_your_turn` | _act | It is not your turn |
| `unknown_action` | _act | Unknown action "<action>" |
| `already_seen` | _see | You have already seen your cards |
| `insufficient_chips` | _bet (empty ladder) | Not enough chips to bet |
| `insufficient_chips` | _bet (chips < amount) / ledger refusal | Not enough chips for that bet |
| `insufficient_chips` | _show | Not enough chips to pay for the show |
| `invalid_bet` | _bet | Bet amount must be a whole number / That bet amount is not available / A raise must be at least double the chaal / That bet is not available |
| `duplicate_action` | ledger refusal | That move was already applied |
| `persist_failed` | ledger refusal (any other code) | The move could not be recorded, so nothing was changed |
| `show_unavailable` | _show | A show needs exactly two players left |
| `sideshow_pending`, `already_asked`, `too_few_players`, `you_are_blind`, `neighbour_is_blind`, `no_neighbour` | _requestSideshow | see §12.6 |
| `no_sideshow` | respondToSideshow | There is no sideshow to answer |
| `not_your_sideshow` | respondToSideshow | That sideshow was not asked of you |

Codes are **MUST** (clients switch on them; metrics label `invalid_moves_total{code}`). Messages
are shown to users by the browser client and in the Flutter `notice`; keep them verbatim.
`handRank.evaluate` throws a plain `Error("a Teen Patti hand must be exactly 3 cards")`, not a GameError.

---

## 21. Ledger contract (what the Table requires of `ledger`)

### 21.1 Interface (table.js:423-434, 844-854, 1475, 1546; 1803-1835)

```
collectBoot({ roomId, handId, bootAmount, entries: [{ userId, amount, balanceBefore }], version, state })
  → { balances: { [userId]: number }, persisted?: number }        // throws on refusal; error.code, error.userId (insufficient_chips)
bet({ userId, amount, roomId, handId, actionId, reason: "bet"|"show", balanceBefore, version, state })
  → { balance?: number, persisted?: number }                         // throws LedgerError-like { code }
settle({ hand: record, entries: [{ userId, delta, isWinner, didChaal, leftMidHand }], version, state })
  → { [userId]: balance } | undefined                                 // throws on failure
```

Table-side interpretation: `collectBoot.persisted` defaults to `bootAmount` when `undefined`;
`bet.balance` defaults to `balanceBefore - amount` and `bet.persisted` to `amount` when not finite;
`settle` result `?? {}`; seats adopt returned balances by **key presence**.

### 21.2 `memoryLedger({ settle, persistChips })` (table.js:1803-1835) — the test stand-in, **MUST for test parity**

- `bet`: if `persistChips` → `await persistChips({ userId, delta: -amount, reason, roomId, handId, actionId })`
  (a throw refuses the move → `persist_failed` unless the thrown error has a `code`); return
  `{ balance: balanceBefore - amount, persisted: persistChips ? amount : 0 }`.
- `collectBoot`: per entry, if `persistChips` → `persistChips({ userId, delta: -amount, reason: "boot", roomId, handId, actionId: `${handId}:boot:${userId}` })`;
  `balances[userId] = balanceBefore - amount`; return `{ balances, persisted: persistChips ? (entries[0]?.amount ?? 0) : 0 }`.
- `settle`: `settle ? (await settle({ hand, entries })) ?? {} : {}`.

### 21.3 Postgres implementation (`src/db/ledger.js`) — **MUST** (DB contents are audited)

`LedgerError(code, message)` with `name = "LedgerError"`. `classify(error)` (ledger.js:48-56):
already a LedgerError → as is; Postgres `23505` whose `detail`/`constraint` mentions `action_id` →
`("duplicate_action", "That move has already been applied")`; else
`("persist_failed", error.message ?? "database write failed")` with `.cause`. Known codes:
`duplicate_action, insufficient_chips, stale_state, no_pot, unknown_user, invalid_amount, persist_failed`.
Each op runs in `withTransaction` (`BEGIN` / `COMMIT` / `ROLLBACK` on throw, db/index.js:82-99);
timestamps `at = Date.now()` once per transaction.

Shared statements:
```sql
-- lockWallet (ledger.js:88-95); no row → LedgerError('unknown_user', `unknown user ${userId}`)
SELECT chips FROM users WHERE id = $1 FOR UPDATE
-- appendLedger (ledger.js:97-103)
INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7)              -- [userId, handId ?? null, actionId ?? null, delta, balance, reason, at]
-- saveState (ledger.js:112-128); skipped when version is undefined/null; rowCount 0 → 'stale_state'
INSERT INTO game_states (room_id, hand_id, version, state, updated_at)
     VALUES ($1, $2, $3, $4::jsonb, $5)
     ON CONFLICT (room_id) DO UPDATE
        SET hand_id = EXCLUDED.hand_id, version = EXCLUDED.version,
            state = EXCLUDED.state, updated_at = EXCLUDED.updated_at
      WHERE game_states.version < EXCLUDED.version      -- [roomId, handId ?? null, version, JSON.stringify(state ?? {}), at]
```

`bet(...)` (ledger.js:135-169): `!Number.isInteger(amount) || amount <= 0` → `invalid_amount`
(outside the transaction). Then: lock wallet; `chips < amount` → `insufficient_chips`;
`balance = chips - amount`;
`UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3`;
`UPDATE pots SET amount = amount + $1 WHERE hand_id = $2` — rowCount 0 → `no_pot`;
appendLedger `{ delta: -amount, balance, reason, actionId }`; saveState; return `{ balance, persisted: amount }`.

`collectBoot(...)` (ledger.js:179-222): entries sorted by `userId` ascending (JS `<` on strings =
UTF-16 code-unit order); for each: lock, `chips < amount` → `insufficient_chips` with
`error.userId = userId`; `balances[userId] = chips - amount`; `UPDATE users SET chips…`.
Then `INSERT INTO pots (hand_id, room_id, boot_amount, amount, opened_at) VALUES ($1, $2, $3, $4, $5)`
with `amount = Σ entry.amount`; then per entry appendLedger with `actionId = `${handId}:boot:${userId}``,
`delta: -amount`, `reason: 'boot'`; saveState; return `{ balances, persisted: bootAmount }`.

`settle({ hand, entries, version, state })` (ledger.js:234-322):
```sql
INSERT INTO hands (id, room_id, hand_no, pot, winner_id, win_reason, boot_amount, started_at, ended_at, summary_json)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb) ON CONFLICT (id) DO NOTHING
-- [hand.id, hand.roomId, hand.handNo, hand.pot, hand.winnerId ?? null, hand.winReason ?? null, hand.bootAmount, hand.startedAt, hand.endedAt, JSON.stringify(hand.summary ?? [])]
```
Then entries sorted by userId; per entry: `SELECT chips FROM users WHERE id = $1 FOR UPDATE` (no row →
skip silently); `balance = Math.max(0, chips + delta)`; `played = didChaal ? 1 : 0`;
`left = leftMidHand ? 1 : 0`; `lost = !isWinner && !leftMidHand ? 1 : 0`;
```sql
UPDATE users SET chips = $1, hands_played = hands_played + $2, hands_won = hands_won + $3,
                 hands_lost = hands_lost + $4, hands_left_mid = hands_left_mid + $5,
                 total_winnings = total_winnings + $6, biggest_pot = GREATEST(biggest_pot, $7),
                 updated_at = $8 WHERE id = $9
-- [balance, played, isWinner?1:0, lost, left, isWinner?pot:0, isWinner?pot:0, at, userId]
```
appendLedger `{ actionId: `${hand.id}:settle:${userId}`, delta: entry.delta, balance, reason: isWinner ? 'hand_win' : 'hand_loss' }`
(a zero delta row is still written); `balances[userId] = balance`. Then
`UPDATE pots SET closed_at = $1, winner_id = $2 WHERE hand_id = $3` `[at, hand.winnerId ?? null, hand.id]`;
saveState with `handId: null`; return `balances`.

Idempotency keys: `chip_ledger.action_id` UNIQUE — client `actionId` (≤64 chars, else server-generated
uuid) for bets/shows; `<handId>:boot:<userId>`; `<handId>:settle:<userId>`. Invariant:
`SUM(chip_ledger.delta) per user == users.chips`.

Schema (`src/db/schema.sql`): `users.chips BIGINT NOT NULL DEFAULT 0 CHECK (chips >= 0)`;
`pots (hand_id TEXT PK, room_id, boot_amount BIGINT, amount BIGINT DEFAULT 0 CHECK (amount >= 0), winner_id REFERENCES users ON DELETE SET NULL, opened_at, closed_at)`;
`chip_ledger (id BIGSERIAL PK, user_id REFERENCES users ON DELETE CASCADE, hand_id, action_id TEXT UNIQUE, delta, balance, reason, created_at)` with a BEFORE UPDATE OR DELETE trigger raising
`'chip_ledger is append-only (attempted %)'`; `game_states (room_id TEXT PK, hand_id, version BIGINT, state JSONB, updated_at)`;
`hands (id TEXT PK, room_id, hand_no INTEGER, pot, winner_id, win_reason, boot_amount, started_at, ended_at, summary_json JSONB)`.
All timestamps epoch-ms BIGINT. `pg` int8/numeric are parsed to JS numbers.

---

## 22. Hand ranking (`src/game/handRank.js`), **MUST**

`CATEGORY`: `HIGH_CARD 0 < PAIR 1 < COLOR 2 < SEQUENCE 3 < PURE_SEQUENCE 4 < TRAIL 5`.
`CATEGORY_NAMES` (English, sent on the wire untranslated): `"High Card"`, `"Pair"`, `"Color"`,
`"Sequence"`, `"Pure Sequence"`, `"Trail"`.

`evaluate(cards, { aceLowIsLowest = false })` (handRank.js:53-92): requires exactly 3 cards
(else `Error("a Teen Patti hand must be exactly 3 cards")`). `ranks` sorted **descending**
`[high, mid, low]`; `sameSuit`.
1. `high === mid === low` → TRAIL, tiebreak `[high]`.
2. `isRun`: `[14,3,2]` (A-2-3) or `high-mid === 1 && mid-low === 1` → `sameSuit ? PURE_SEQUENCE : SEQUENCE`,
   tiebreak `[runStrength]` where A-2-3 → `27` (or `5` under the unused ace-low variant), else `2*high`
   (A-K-Q 28 > A-2-3 27 > K-Q-J 26 > … > 4-3-2 8). K-A-2 does not wrap.
3. `sameSuit` → COLOR, `[high, mid, low]`.
4. `high === mid || mid === low` → PAIR, `[mid, high === mid ? low : high]` (pair rank, kicker).
5. else HIGH_CARD `[high, mid, low]`.
Returns `{ category, name, score: [category, ...tiebreak], cards: cards.map(cardCode) }` (codes in
the **input** order).

`compare(a, b)` (handRank.js:98-105): element-wise over `max(len)` with missing → 0; returns
first non-zero difference (`> 0` a wins), `0` exact tie. **Suits never break ties.**

`pickWinner` (handRank.js:115-143) is exported but the Table re-implements the loop (§14); keep
both consistent (*incidental* unless exposed).

---

## 23. Deck (`src/game/deck.js`), **MUST**

`SUITS = ['s','h','d','c']`; `RANKS = 2..14` (11 J, 12 Q, 13 K, 14 A). Card `{ rank: int, suit: char }`.
`cardCode = RANK_CODES[rank] + suit` with `10 → 'T'`, `11 'J'`, `12 'Q'`, `13 'K'`, `14 'A'`
(e.g. `"As"`, `"Td"`, `"7h"`). `parseCard(code)` inverse (`code[0]`, `code[1]`).
`newDeck()` suit-major: all 13 spades, then hearts, diamonds, clubs.
`shuffle(deck)`: Fisher–Yates, `for i = 51 down to 1: j = crypto.randomInt(i + 1); swap(i, j)` —
CSPRNG required (`Math.random` forbidden).
`deal(count, cardsPer = 3)`: shuffled deck; `hands[seat].push(deck[round*count + seat])` round-robin
one card at a time; returns `{ hands, remaining }`.

---

## 24. Chat buffer (`src/game/chat.js`), **MUST** (messages reach clients)

`new RoomChat({ maxHistory = config.chat.maxHistory (100), maxLength = config.chat.maxLength (140) })`.
- `sanitize(text, maxLength)`: `String(text ?? '')` → replace every `/[\p{C}]/gu` match (Unicode
  category **C**: Cc control, Cf format — incl. ZWJ/ZWNJ/BOM — Cs surrogates, Co private use, Cn
  unassigned) with a space → collapse `/\s+/g` to one space → `trim()` → `.slice(0, maxLength)`
  (**UTF-16 code units**, may split a surrogate pair).
- `add({ userId, displayName, text })` → `null` if clean is empty; else push
  `{ id: uuid(), userId, displayName, text: clean, at: Date.now() }`; trim oldest past `maxHistory`.
- `addSystem(text)` → `{ id: uuid(), userId: null, displayName: "Table", text: String(text).slice(0, maxLength), at, system: true }`
  (not sanitised beyond the slice). Texts used: `` `${displayName} joined the table` ``, `` `${displayName} left the table` ``.
- `history()` copy oldest-first; `size`; `clear()`.
Chat is never persisted and never in `serializeFor`.

---

## 25. Test cases to mirror

All unit suites use `test/helpers/fakeTimers.js`: `createFakeTimers()` → `{ timers, advance, now, pending }`;
`setTimeout(fn, ms)` records `{fn, at: now+ms}` with incrementing integer ids; `clearTimeout(id)`
deletes; **`await advance(ms)`** fires due timers one at a time in `at` order, setting `now = at`
and awaiting each callback (so callbacks that schedule new timers within the window fire too), then
`now = target`. Tests construct `new Table({ id, code, config, timers, settle | persistChips })` with a
**complete** `baseConfig` (no defaults are merged). Deterministic showdowns set
`table.findSeat(id).cards = codes.map(parseCard)` directly. `turnUser(table) = table.seats[table.hand.turnSeat].userId`.

Common `settle` stubs: (a) `() => ({})` → winner credited in memory via the fallback;
(b) "mirror real": returns `seat.chips + (isWinner ? pot : 0)` per entry; (c) bank-backed applying
`delta` to a pre-hand balance; (d) `chipPersistence`: `persistChips` decrements an accounts map and
asserts non-negative, `settle` applies deltas.

### `test/table.test.js` (config: boot 100, start 200000, turn 25000, rounds 20, multiplier 1024, delay 6000; **no `maxRaiseSteps`/`maxBlindMoves`/`maxMissedTurns`** → defaults 8 / never / never)
| Test | Setup → assertion |
|---|---|
| a table waits until the minimum number of players is seated | 1 player → waiting, no hand; 2nd → starting; advance 6000 → betting, hand set |
| a table seats at most five players | 5 seats; 6th throws `table_full`; `isFull` |
| the same player cannot take two seats | `already_seated` |
| a player who joins mid-hand sits out until the next deal | late seat `status waiting`, `cards []`, `activeSeats.length 2` |
| a player who cannot cover the boot is dealt out | seat with boot−1 → `waiting`, 2 active (no kick listener; seat remains) |
| every player is dealt three hidden cards and the boot is collected | 3 players: each 3 cards, `isBlind`, chips −100, contributed 100; pot 300; `handStarted.pot` 300; `serializeFor(alice).you.cards` = `[]` |
| a snapshot never contains another player's cards | after SEE: `you.cards.length 3`; every `seats[i].cards === undefined` |
| turns open left of the dealer and rotate clockwise | order of 3 chaals = occupied seats clockwise from `dealerSeat`; ≥3 `turn` events |
| acting out of turn is refused | `not_your_turn` |
| a player not in the hand cannot act | late joiner → `not_in_hand`; unknown user → `not_seated` |
| a blind player bets the stake or double it; a seen player pays double that | blind chaal 100 raise 200; after SEE chaal 200 raise 400 |
| a blind bet raises the stake; a seen bet raises it by half as much | blind RAISE → stake 200, pot 400; next SEE+CHAAL pays 400 → pot 800, stake stays 200 |
| seeing cards is free, reveals only your hand, and does not pass the turn | chips unchanged, turn unchanged, `cards` event 3 codes, 2nd SEE → `already_seen` |
| bets are capped by the pot limit | multiplier 4, seen: chaal 200, raise 400, max 400 |
| a player who cannot afford a bet is offered no bet | 10 chips left: `chaal null`, `raise null`, `canPack true` |
| packing forfeits the hand and passes the turn | status packed, pot unchanged, turn moved, last action `pack` |
| the last player standing takes the pot without a show | two packs → `handEnded.reason last_standing`, pot, `reveals []`, winner status `won` |
| a player who does not act within 25 seconds is packed automatically | advance 25000 → packed, action with `reason 'timeout'`, turn moved |
| the turn clock is announced with a deadline the client can count down | `turn.timeoutMs 25000`, `deadline > now+20000`, `options.chaal > 0` |
| acting resets the clock for the next player | advance 24000, chaal, advance 24000 → next still active |
| a show needs exactly two players left | 3 players → `show_unavailable` |
| a show reveals both hands and the better hand takes the pot | AAA vs junk; `showdown.reveals.length 2`, reason `show`, winner alice, `handName 'Trail'` |
| paying for a show costs the caller a chaal | blind caller cost 100; after hand `serializeFor.pot 0` |
| an exact tie goes to the player who did not call the show | As9s4s vs Ah9h4h; winner ≠ caller |
| the round cap forces a showdown so a pot cannot run forever | `maxBetRounds 3`, chaal loop → `forced_showdown`, winner alice (pure seq) |
| the winner takes the whole pot and everyone else pays what they staked | chaal then show; Σdelta 0; one winner; Σsummary.contributed == pot |
| a hand record carries the full audit trail | `roomId 'room-1'`, `handNo 1`, `bootAmount 100`, `startedAt ≤ endedAt`, 2 summary rows each 3 cards |
| a player who leaves mid-hand still forfeits their stake | quitter chaal then remove → entry `delta -200`, Σ 0, winner among remaining |
| the next hand starts automatically and the dealer button moves | pack ends hand 1; advance 6000 → `handNo 2`, dealer changed |
| play stops when only one funded player remains | pack; remove bob; advance 18000 → waiting, no hand |
| a destroyed table stops all of its timers | destroy before deal; advance 30000 → no hand |
| unknown actions are rejected | `'steal_the_pot'` → GameError `unknown_action` |

### `test/sideshow.test.js` (boot 100, start 100000, `sideshowTimeoutMs 6000`, `sideshowMinPlayers 3`, `maxBlindMoves 4`; `count` players, `startHand()` directly, everyone SEEs)
| Test | Assertion |
|---|---|
| the sideshow button is offered to the player on turn and nobody else | `canSideshow true`, `sideshowWith` = right neighbour's name; others `not_your_turn` |
| a sideshow needs three players in the hand | 2 players → `too_few_players` (reason, `canSideshow false`, act rejects) |
| both hands must have been seen | neighbour blind → `neighbour_is_blind`; self blind → `you_are_blind` |
| the request goes to the player on the right, who acted immediately before | 4 players, one chaal; `sideshowRequested.fromUserId/toUserId`; no `cards` key; `serializeFor(...).sideshow.toUserId` |
| only the player who was asked can answer | bystander & asker → `not_your_sideshow`; after decline → `no_sideshow` |
| a declined sideshow packs nobody and hands the turn straight back | `accepted false`, `reason 'declined'`, `packedUserId null`, no reveal, turn = asker, `chaal > 0` |
| an unanswered request is rejected after six seconds | pending at 5999; at 6000 `sideshow null`, `reason 'timeout'`, turn = asker |
| the turn clock stops while a request stands and restarts full afterwards | advance 20000, request, advance 5999 still active; decline; advance 24999 still their turn; +1 → packed |
| the weaker hand packs and only the two of them see the cards | `reveal.userIds` = both; `hands[].cards` asker first; `packedUserId` = asked; `sideshowResolved` JSON has no `'As'`; statuses |
| losing your own sideshow packs you and passes the turn on | 4 players; asker packed, turn moved to an active seat |
| a tie goes against the player who asked | KsKh4d vs KdKc4s → asker packed |
| when the sideshow leaves two players the hand carries on rather than ending | 2 active, hand live, `turnOptions.show > 0` |
| one sideshow per turn, and the next turn brings a fresh one | after decline `already_asked`; act rejects; after a full rotation `null`/`canSideshow true` |
| a second request cannot be opened while one is standing | `sideshow_pending` |
| a player leaving cancels the sideshow they were part of | remove asked → `sideshow null`, resolved reason `'left'`, no reveal, turn = asker, `chaal > 0` |
| a pending request does not outlive its hand | others leave → hand null; advance 12000 does not reject; no reveal |

### `test/handRank.test.js`
Categories of `AsAhAd` TRAIL, `AsKsQs` PURE_SEQUENCE, `AsKhQd` SEQUENCE, `As9s4s` COLOR, `AsAh4d` PAIR,
`As9h4d` HIGH_CARD; ladder `2s2h2d > AsKsQs > AsKhQd > AsKsJs > AsAhKd > AsKhJd`; trails by rank;
runs `A-K-Q > A-2-3 > K-Q-J > 4-3-2`; `As2s3s` PURE_SEQUENCE, `As2h3d` SEQUENCE, `As2h4d` and `KsAh2d`
HIGH_CARD; ace-low variant `4-3-2 > A-2-3`; colors card by card and `As9s4s` ties `Ah9h4h`; pairs
`KK2 > QQA`, `KKA > KKQ`, scores `[1,13,14]` for `AsKhKd` and `[1,13,2]` for `KsKh2d`; high cards
`A94 > KQ9`, `AT4 > A98`, `AT5 > AT4`; 2- or 4-card hands throw `/exactly 3 cards/`; shuffled deck 52
distinct; `deal(5,3)` 15 distinct; 10 shuffles never equal the ordered deck.

### `test/blindRules.test.js` (boot 200, start 5,000,000, rounds 40, multiplier 1,048,576, steps 8, blind moves 4)
SEE off-turn allowed and does not move the turn; bet off-turn after SEE → `not_your_turn`;
cards face up after exactly 4 blind bets (`blindMoves` counts 1..4); the 4th bet costs `stake` (blind
rate) and only then reveals; a player who SEEs early never accrues `blindMoves`; `blindMoves` and
`isBlind` reset on the next deal; `serializeFor('watcher')` (non-seated viewer) shows `lastBet 0`
before betting, then `lastBet > 0`, `contributed += lastBet`, `lastAction 'chaal'`; `lastBet 0` /
`lastAction null` after the next deal.

### `test/raiseLadder.test.js` (boot 100, start 200000, steps 8)
Steps `[100,200,400,800,1600,3200,6400,12800]`; seen `[200,400,…]`; `maxRaiseSteps 3` → 3 rungs;
`potLimitMultiplier 4` → `[100,200,400]`, max 400; `maxRaiseSteps 0 && potLimitMultiplier 0` with
1,000,100 chips → 14 rungs, max 819,200; 650 chips → `[100,200,400]`; 50 chips → `raiseSteps []`,
all null, `canPack true`; `raiseSteps[0] === chaal`, `[1] === raise`, `chips === START-BOOT`,
`maxBet === last`; RAISE 800 → action amount 800, pot +800, chips −800, stake 800; bare RAISE = 200,
bare CHAAL action `chaal`; amounts 150/999/101/1 → `invalid_bet`; 800 and 200000 with 650 chips →
`invalid_bet`, chips unchanged; 100.5/−100/NaN/Infinity → `invalid_bet`; RAISE 100 → `invalid_bet`;
max-bet loop never drives a stack negative; 150-chip stack: `raiseSteps [100]`, `raise null`, RAISE 100
→ `invalid_bet`, CHAAL 100 → 50 left; timeout packs with `reason 'timeout'`; SEE does not stop the
clock and a 2-player timeout ends the hand.

### `test/tableRules.test.js` (boot 200; also uses `RoomManager({timers, settle})`)
Leaver on a 2-player hand → `last_standing` to the other, pot preserved, Σdelta 0; `destroy()` mid-hand
→ `all_left`, winner among active, full pot, Σdelta 0; successive departures → last remaining wins;
leaver entry `leftMidHand true`, `didChaal true`, `isWinner false`; immediate pack → `didChaal false`,
`leftMidHand false`; a chaal → `didChaal true`. Via RoomManager: seen table steps `[200,400]` and RAISE
800 → `invalid_bet`; blind table `steps[2] === 800`; blind config `maxBetRounds 0`, `maxRaiseSteps 0`,
`potLimitMultiplier 0`, `maxPot 0`; 120 blind chaals never end the hand (`round ≥ 50`); seen table
`maxBetRounds 7` ends in `forced_showdown` with 2 reveals; a show's `showdown.reveals` has 2 rows with
3 cards, `handName`, boolean `won`, exactly one `won`.

### `test/seatKeeping.test.js` (boot 200, start 50000, `maxMissedTurns 3`; a `kick` listener calls `removePlayer(userId, reason)`)
Three timeouts → one kick `{ reason 'idle', message /missed turns/i }`, seat freed after `settled()`;
`you.missedTurns` 0 then 1, `you.maxMissedTurns 3`, and `'missedTurns'` absent from another viewer's
`seats` JSON; a chaal resets `missedTurns` to 0; a boot−1 seat is kicked `insufficient_chips` with
message `/enough coins/i` after the deal; a seat at exactly the boot is dealt in, sits at 0 chips and
is **not** kicked mid-hand; after busting they are kicked once the hand ends; two unfunded seats →
both kicked, `playerCount 0`, nothing throws.

### `test/chipPersistence.test.js` (`persistChips` + `settle` accounts map)
Boots leave both accounts at the deal (`START-BOOT`), pot 400; each chaal debits `stake` and
`seat.chips === account`; winner paid exactly the pot, loser not charged again, total conserved;
mid-hand leaver keeps `START - staked` through settlement; 9 raises then packs conserve the total;
seat and account never disagree for active seats.

### `test/settlement.test.js` (bank-backed settle)
`assertConserved`: Σdelta 0, Σsummary.contributed == pot, one winner, winner delta == pot − own
contributed. Paths: everyone packs; SEE+RAISE+SHOW; `maxBetRounds 4` forced showdown; leaver;
two timeouts; 25 mixed hands keep the bank total (`handNo > 5`); `settle` returning `0` for everyone
→ every seat's chips exactly 0 (no fallback credit).

### `test/categories.test.js`
Undefined and `'nonsense'` categories → `seen`; blind category in `serializeFor` and `summary`; seen
table shows all stacks, `chipsHidden false`; blind table `chipsHidden true`, own chips visible,
others `null` (never 0); each viewer sees only their own; the other stack's digits are absent from
the JSON; `you.chips` and `you.options.chips` = START−BOOT on a blind table; `contributed` and `pot`
public on blind; ladder and pot identical across categories.

### `test/chat.test.js`
Order/author/`at`/`id`; cap 100 keeps `msg 51..150`; `maxHistory 3`; empty/whitespace/`null` →
`null` and `size 0`; `'hi [31m there'` → `'hi [31m there'`; `'one\ntwo\r\nthree'` →
`'one two three'`; 200 x's with `maxLength 20` → length 20; `clear()`; `postChat` returns message with
`displayName 'Alice'` and emits `chat`; stranger → `not_in_room`; system lines `'Alice joined the table'`,
`'Bob joined the table'`, `'Bob left the table'` with `userId null`; late joiner sees backlog;
`destroy()` empties history; two tables isolated; chat works mid-hand; chat text absent from `serializeFor`.

### `test/privateTables.test.js`
Direct-Table cases: `maxPot 5000`, pot forced to 4000 → steps `[200,400,800]`; max-bet loop with
`maxPot 5000` ends in `pot_limit` with 2 reveals, pot ≤ 5000, Σdelta 0. RoomManager cases: private
boot always 200; public keeps its boot; `lobbyOptions().privateBoot 200 / privateMaxPot 500000`;
private blind steps `[200,400]`, RAISE 800 refused; public blind > 2 rungs; `maxPot` 500000 /
500000 / 1200000 / 0; `serializeFor('a').maxPot 500000`; uncapped blind ladder > 8 rungs, `max ≤ chips`, `max*2 > chips`.

### `test/invalidMoves.test.js` (process-level, Postgres) — relevant Table facts
Replaying `actionId 'dup-same-id'` → second ack `ok:false`, exactly one `chip_ledger` row with that id,
wallet debited once (the replay fails the turn check first). `player:requestCards` returns `[]`
unless seen.

---

## 26. Ordering/idempotency summary (quick reference)

| Concern | Rule |
|---|---|
| Memory vs DB | Boot/bet/show: DB commit **first**, memory after. Settlement: memory **first**, DB after (retry ×10). |
| `version` | +1 only on a committed write; the value sent is `version + 1`; `game_states` refuses `<=`. |
| Idempotency keys | `actionId` (client, ≤64 chars) or `uuid()`; `<handId>:boot:<userId>`; `<handId>:settle:<userId>` |
| Turn timeout | Guarded by `turnToken` and `turnSeat`; queued behind in-flight mutations. |
| Sideshow timer | Cleared on resolve, on hand end; a late fire finds `hand.sideshow` null → no-op. |
| Start timer | Single `_startTimer`; `_maybeStart` refuses while one is armed. |

---

## 27. Traps for the port

1. **Async ordering through one queue.** Every hand mutation (including timer callbacks) is serialised.
   A `kick` handler's `removePlayer` lands *after* the current mutation. Tests rely on this
   (`await table.settled()`). The settle retry runs *outside* the queue.
2. **`_maybeStart` from `addPlayer` is synchronous and unqueued.** It can emit `kick` and `state`
   while a queued mutation is mid-flight (between awaits). Reproduce the same observable sequence.
3. **Key presence, not truthiness.** `balances[userId] === 0` must be adopted (`hasOwnProperty`),
   both at hand start and at settlement. Never `|| fallback`.
4. **`null` vs `0` vs absent.** Hidden chips → `null`. `chaal/raise/max/show` → `null` when
   unavailable. `you` → `null` for a non-seated viewer. Empty seat object has only `seatIndex` and
   `status`. `avatarUrl` → `null` when not given. `winnerId` → `null` when none. `turn.deadline`
   → `null` before the first `_setTurn`. `startsAt` → `null` unless STARTING. Seat entries never have a
   `cards` key; `you.cards` is `[]` (not null) while blind.
5. **`hand.stake` is in blind units**: a seen bet of `amount` sets `stake = floor(amount / 2)`;
   the pot-cap check uses `pot + stake` (blind unit), not the real next bet.
6. **Ladder first rung is `min(base, perBetCeiling)`**, not `base` — when the stake outgrows the
   per-bet ceiling, the only rung is the ceiling itself (verified: `[400]` for stake 800, ceiling 400).
7. **Validation order and codes** in `_act`/`_bet`/`_show`/`_requestSideshow` (tables above); an
   unknown action off-turn is `not_your_turn`; a bare `raise` with one rung is `invalid_bet`
   ("That bet is not available"), not `insufficient_chips`.
8. **`missedTurns` resets on *any* successful act, including an off-turn SEE**, and is not reset by a
   new hand. `sideshowAskedThisTurn` resets only via `_setTurn(freshTurn=true)`.
9. **The auto-reveal's bet is charged at the blind rate** and the auto `see` emits `cards`,
   `action{auto:true}`, `state` but **no** `turn`. `blindMoves >= maxBlindMoves` — with
   `maxBlindMoves` absent (table.test.js config) the comparison is false and no auto-reveal ever
   happens; likewise absent `maxMissedTurns` → never kicks, absent `sideshowMinPlayers` → gate passes.
   A Go port with typed zero values would behave differently here (0 would trigger immediately) —
   tests that omit these keys must be given explicit "disabled" semantics or the same keys.
10. **Rounds count by distance**, incrementing when the turn lands on **or passes** `startSeat`
    (`toStart > 0 && toStart <= toNext`); `startSeat` never changes even if that player packs/leaves.
11. **Tie preference puts the dealer's own seat first** (distance 0), then the dealer's left; the
    show payer is moved to the very end. Sideshow tie → asker loses.
12. **Sideshow turn handling**: clock stopped on request; on resolve the asker gets a *full* new
    clock with a new `turnToken` but `freshTurn:false`; if the asked player loses, `_pack(..., {advanceTurn:false})`.
    When the *asker* leaves during a pending request, a spurious `turn` event for the leaver is
    emitted before the pack (§6.2 step 3) — reproduce or consciously deviate (clients tolerate it,
    but the event stream differs).
13. **Show is never free**: `null`/unaffordable cost → `insufficient_chips`. Show sets `didChaal`
    but not `lastBet/lastAction/stake`.
14. **Contributions outlive seats**: leavers are settled by `userId`; `ALL_LEFT` pays
    `hand.lastDeparture` who is no longer seated (`winnerName` from the contribution entry).
15. **`persisted` is reported by the ledger**: full amount in Postgres, `0` for a bookless memory
    ledger. `delta = net + persisted` yields payout-only deltas (winner `+pot`, losers `0`) in
    production and zero-sum net deltas in unit tests. A zero-delta `hand_loss` ledger row **is** written.
16. **Settlement retries resend the stale snapshot** with a fresh `version + 1` and can overwrite a
    newer `game_states` row; a retry after a lost-but-committed settle hits the UNIQUE
    `<handId>:settle:<userId>` and surfaces as `duplicate_action` → keeps retrying to 10.
17. **Number handling**: bet amounts must be JS-safe integers (socket layer) and `Number.isInteger`
    (Table). `pg` BIGINT/NUMERIC are parsed to numbers. Chips are `int64`-scale (50 crore fixtures exist).
18. **Sorting user ids** in the ledger uses JS string `<` (UTF-16 code units); ids are ASCII
    (uuid/sha256 hex) in practice, so bytewise order matches — but do not rely on it for arbitrary ids.
19. **Unicode in chat**: `\p{C}` removal strips ZWJ (U+200D) — breaking emoji sequences — and
    `slice(0, maxLength)` counts UTF-16 units and may cut a surrogate pair. Display names are unsanitised
    in system lines. Go's `unicode.C` table covers Cc/Cf/Co/Cs (Cn unassigned differs by Unicode version).
20. **Timers**: the start timer is cleared/re-armed by `_maybeStart`/`_cancelStart`/`_startRefused`;
    `_startRefused` on `insufficient_chips` arms **no** retry (relies on the kick path). `destroy()`
    ends a live hand via `_endHand`, which calls `_maybeStart` (arming a timer) before `_destroyed`
    is set and the timer cleared.
21. **`turn` re-emit on manual SEE** carries the *remaining* `timeoutMs` and the existing `deadline`;
    the socket layer turns every `turn` into both `game:turn` (no options) and `game:yourTurn`.
22. **`evaluate` returns cards in input order**; `showdown.reveals[].cards` and `sideshowReveal`
    cards therefore follow the deal order, not sorted.
23. **Seats keep last hand's status/cards until the next deal**: `serializeFor` between hands shows
    `status won/lost/packed`, `cardCount 3`, and a seen viewer's `you.cards` from the finished hand.
24. **The boot snapshot** (sent to `collectBoot`) has `turnSeat -1`, `startSeat -1`, participants
    already debited, and state `"betting"`; non-participants carry stale values.
25. **Two `state` emits** are normal after most operations (inner `_advanceTurn` + outer); clients
    receive duplicate `room:state` snapshots. Not harmful, but the count is observable in tests that
    record events.
