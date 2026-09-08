# PORT_NOTES — internal/game Table actor (table.go, view.go, snapshot.go, ledger.go, events.go, clock.go)

Owner scope: the rules engine (`table.go`, 2760 lines — the port of `server/src/game/table.js`),
its wire/DB shapes (`view.go`, `snapshot.go`), the `Ledger`/`Clock` contracts and `MemoryLedger`
(`ledger.go`, `clock.go`), the `Listener` and event payloads (`events.go`), and the new suites
`table_test.go`, `sideshow_test.go`, `tablerules_test.go`, `settlement_test.go`. `deck.go`,
`handrank.go`, `chat.go` (game-pure.md) and `roommanager*.go` (roommanager.md) are other engineers'.

The behavioural spec this was audited against is `PORT_NOTES/specs/spec-game-rules.md` (recovered
verbatim from the session log after `/tmp` was wiped by a reboot; byte-identical to the copy the
integrator restored).

## 1. What was audited

`table.go` was read line by line against `table.js` (working tree, all 1842 lines) and every section
of the spec. Checked and found exact — no change needed:

| Area | Spec § | Result |
|---|---|---|
| `_act` validation order `no_hand > not_seated > not_in_hand > not_your_turn (skipped for see) > unknown_action`; every code and verbatim message | 12.1, 20 | exact (an unknown action off turn is `not_your_turn`) |
| `betOptions`: `amount = min(base, perBetCeiling)`; `ceiling = min(perBetCeiling, chips)`; `headroom = MaxPot - pot`; 0 = unlimited for `MaxRaiseSteps`/`PotLimitMultiplier`/`MaxPot`; `raise ≥ 2×steps[0]`; bare raise with one rung → `invalid_bet` "That bet is not available"; empty ladder → `insufficient_chips` "Not enough chips to bet" | 11, 12.3 | exact (Go adds an `amount > 0` / int64-overflow guard Node did not need) |
| `hand.stake = amount` (blind) / `floor(amount/2)` (seen), evaluated with the pre-reveal `isBlind` | 12.3 | exact |
| SEE free, off turn, no clock reset; on-turn re-emit of `turn` with the remaining time and the seen ladder; no re-emit when auto | 12.2 | exact |
| Auto-reveal at `MaxBlindMoves`: the tripping bet charged blind, `action see {auto:true}`, ack `autoSeen`, order `action:chaal > cards > action:see > state > turn > state > state` | 12.3, 19.1 | exact |
| `missedTurns++` on timeout, kick at `MaxMissedTurns` with `"Left the table after N missed turns"`, reset only after ANY successful act (incl. off-turn SEE), never by a new hand; token/turnSeat/status guards on the timeout | 9 | exact |
| Rounds by distance (`toStart > 0 && toStart <= toNext`), `startSeat` frozen; forced showdown at `MaxBetRounds`; `POT_LIMIT` when `pot + stake > MaxPot` (blind-unit stake) | 13 | exact (verified against Node: rounds `0,0,1,1,2,2,end` with the opener packed; 14 chaals on a 7-round seen table) |
| Show: exactly 2 active, cost = chaal, `nil`/unaffordable → `insufficient_chips` "Not enough chips to pay for the show"; `didChaal`; no `lastBet/lastAction/stake` change | 12.9 | exact |
| Tie preference: dealer's own seat (distance 0) first, dealer's left next, show payer appended last | 14 | exact (verified against Node: a three-way tie at a forced showdown goes to the dealer) |
| Sideshow: blocked-reason ORDER, right neighbour found walking indices downward, clock stopped while pending, only `toUserId` answers, tie against the asker, asked-loser packs with `advanceTurn=false`, re-arm `setTurn(fromSeat, freshTurn=false)` so `already_asked` persists, participant leaving → `left`, `endHand` clears the timer, late timer no-op | 12.6–12.8 | exact, including the three observed event orders and the "asker leaves with a request pending" sequence |
| Leave mid-hand = pack with the leave reason; `leftMidHand`; `lastDeparture`; `ALL_LEFT` pays `lastDeparture` (settled by userId, named from the contribution record) | 6.2, 12.5 | exact |
| `endHand`: memory-first; `delta = net + persisted`; balances adopted by KEY PRESENCE (0 valid); winner `+= pot` only when the key is absent; `retrySettle(…, 1)` on failure; `winnerName` fallback; `nextHandAt`; `maybeStart()` last | 15 | exact |
| `retrySettle`: ≤10 attempts, `min(30s, NextHandDelay×n)`, live `version+1`, original snapshot resent, balances adopted onto non-active seats only, `settle_retry` persist errors carry `attempt`, abandon → `OnError` | 15.1 | exact; runs on the actor and `duplicate_action` = success (DECISIONS §2) |
| `startHand`: sweep, `< MinPlayers` → waiting, hand built beside the table, `CollectBoot` with `version+1` and the boot snapshot (participants pre-debited, `turnSeat/startSeat -1`, state `betting`), commit → every occupied seat reset, participants dealt, balances by key presence, `handStarted > turn > state` | 7.2, 17 | exact |
| `startRefused`: `insufficient_chips`+`UserID` → `chips = min(chips, boot-1)` + kick, NO retry timer; anything else → retry after `NextHandDelay`; `persistError > kick > state` | 7.3 | exact |
| `sweepUnfunded` only between hands; `kickPending` set once, never cleared | 10 | exact |
| `serializeFor` redaction: `you.cards` only when seen (else `[]`), others `cardCount` only, `chips: null` + `chipsHidden` on BLIND, `missedTurns/maxMissedTurns/options` only in `you`, `you: null` for a non-seated viewer, `sideshow` ids/seats/expiresAt only, empty seat exactly `{seatIndex,status}`, `turn`/`startsAt`/`options` null rules, seats keep last hand's status/cards until the next deal | 18 | exact (JSON asserted) |
| `Snapshot` content and key set; `snapshotAfterBet` advancing pot/chips/contributed/persisted; the settle snapshot at rest with the ended hand's `handNo` | 17 | exact (asserted on captured `CollectBootRequest`/`BetRequest`/`SettleRequest`) |
| `Destroy`: live hand ended `all_left` to the lowest active seat else `lastDeparture`, every timer stopped (turn, start, sideshow, settle retries), chat cleared, `ErrTableDestroyed` from every later post, seats kept | 16 | exact + Go additions below |
| The four "0 = disabled" knobs (`MaxBlindMoves`, `MaxMissedTurns`, `SideshowMinPlayers`, `SideshowTimeout`) | DECISIONS §2 | correct; each has a dedicated test |
| Event emit sites: 16 `state`, and every other event count matches Node site for site (the fifth Node `persistError` site, `settle_abandoned`, is `OnError` in Go — a RoomManager listener always exists) | 19 | exact |

## 2. Bugs found and fixed in table.go

1. **Category not normalised in `NewTable`.** Node's constructor does
   `config.category === 'blind' ? BLIND : SEEN` (table.js:69-71); Go used `cfg.Category` raw, so a
   table built with `Category: ""` or `"nonsense"` serialised `"category":""` and `chipsHidden:false`
   with an empty category on the wire and in `game_states`. Fixed: `NewTable` forces anything but
   `blind` to `seen` (categories.test.js "defaults to seen" / "unknown category falls back to seen"
   now pass; `Config().Category` reports the normalised value). RoomManager already normalises, so
   production was not affected; defence in depth as Node had it.

That was the only discrepancy. Everything else in the audit table above matched without change.
Exported signatures and json tags are untouched.

## 3. Tests added (149 test functions + 10 random-play subtests; whole package: 282 passing)

All in package `game` (white-box: forced cards, `t.run` reads, a Listener that must not post back),
on a fake clock, with `MemoryLedger` hooks mirroring the Node stubs (mirror-real, `() => ({})`,
bank-backed, `persistChips` accounts).

| File | Mirrors | Count |
|---|---|---|
| `table_test.go` | every case of `table.test.js` (32), the direct-Table cases of `categories.test.js`, `blindRules.test.js`, `raiseLadder.test.js` (incl. NaN/-100/non-rung/`raise < 2×`), `chat.test.js` (postChat, join/leave lines, destroy clears, mid-hand, never in snapshot, two tables isolated), `privateTables.test.js` (headroom `[200,400,800]`, `pot_limit` showdown); plus redaction JSON, seats-between-hands, ledger snapshot content, event orders (`addPlayer`, deal, chaal, show, cancelStart, manual see on/off turn), `SetConnected`/`SetChips`, View accessors inside callbacks, lock-free getters, the first-rung ceiling quirk, and the **Node differential test** (§4) | 73 |
| `sideshow_test.go` | every case of `sideshow.test.js` (16) + blocked-reason order, `SideshowTimeout 0` never expires, `SideshowMinPlayers 0`, the asker-leaves event sequence | 20 |
| `tablerules_test.go` | every case of `tableRules.test.js` (the RoomManager-built tables are built directly with `_createTable`'s exact per-category config — see §6) and every case of `seatKeeping.test.js`, plus rounds-by-distance with a packed opener, dealer-first tie, `all_left` with `winnerName` from the contribution record, a paid show counts as played, `kickPending`, `MaxMissedTurns 0` | 26 |
| `settlement_test.go` | every case of `settlement.test.js` and `chipPersistence.test.js`; boot refused (both paths), bet/show refused (all four `refusal` mappings, nothing changes, `persistError` payload), settle refused → paid in memory → retried, `duplicate_action` retry = success, abandoned after 10 retries (11 persist errors + 1 error), zero balances by key presence at boot and settle; **properties**: chip conservation under seeded random play (10 seeds, seen/blind, every knob, sideshows, timeouts, kicks, leaves/rejoins: `Σaccounts + pot` constant, seat == account, one winner, `Σdelta == pot`), no deadlock behind a slow listener with 8 concurrent callers, no timer fires after Destroy, `ErrTableDestroyed` from every posting method (all 15, including a second `Destroy`), a stale timeout is a no-op, a panic in a move is `internal_error` and the actor survives, version rises once per committed write | 30 |

`go test -race -count=5` on these suites is stable; `-cpu 1,4` clean.

## 4. Node differential test (`TestParityWithNodeTableOnScriptedScenarios`)

Two scripted scenarios run through the real `server/src/game/table.js` (under `fakeTimers`) and the
Go Table, emitting the same normalised record stream: every event in order (names and payloads),
every ack (result, or error code + verbatim message), settle records, and `serializeFor` for every
viewer at 20 checkpoints. Only wall-clock fields (`deadline`, `expiresAt`, `startsAt`, `nextHandAt`,
`timeoutMs` on turns, timestamps) and random ids are stripped. **346 records identical** (204 + 142),
covering: sideshow request/reveal/pack/turn-stays, two shows including the exact tie against the show
payer, `pot_limit`, four blind moves → auto-reveal, idle kick after three timeouts, unfunded kick,
leave-as-pack (`left`, `moved`), chat (sanitised-empty → null, `not_in_room`), `setConnected`, hidden
chips on a blind table, and every refusal code with its message. Skips when `node` or `../server` is
absent (same rule as `interop_test.go`).

The one post deliberately left out of the script is an `act` after `destroy()`: Node's dead object
still answers `no_hand`; Go answers `table_destroyed` (PORT_PLAN §9) — pinned by a Go-only test.

## 5. Deviations (all traced to DECISIONS.md / PORT_PLAN.md)

| Behaviour | Node | Go | Source |
|---|---|---|---|
| Posts after `Destroy` (mutations AND reads: `SerializeFor`, `ChatHistory`, `Seats`, `Summary`, `FindSeat`, `Settled`) | object keeps working (`chatHistory()` → `[]`, `act` → `no_hand`) | `ErrTableDestroyed` (code `table_destroyed`) | PORT_PLAN §3.1, §9 |
| Settle retry | ran outside the queue, mutated seats concurrently | runs on the actor; `Destroy` stops armed retry timers | PORT_PLAN §3.1, §9 |
| Settle retry refused `duplicate_action` | kept retrying to 10 | success (version rises, chain stops) | DECISIONS §2 |
| Settlement abandoned | `error` if a listener exists else `persistError settle_abandoned` | always `OnError` | events.go (RoomManager always listens) |
| `MaxBlindMoves`/`MaxMissedTurns`/`SideshowMinPlayers`/`SideshowTimeout` = 0 | key `undefined` → comparison false | disabled / never | DECISIONS §2 |
| `you.blindMovesLeft` with `MaxBlindMoves` 0 | `NaN` → `null` | `0` | consequence of the above; production uses 4 |
| `AddPlayer`, `PostChat`, `SetConnected`, `SetChips`, reads | synchronous, unqueued (could interleave with an in-flight DB write) | posted to the actor (serialised) | PORT_PLAN §3.1 |
| Stale start-timer callback (timer fired, then cancelled/re-armed before its closure ran) | `_startHand` ran anyway | skipped (generation guard) — only reachable with real timers in a race window | Go addition, same spirit as `turnToken` |
| Panic inside a move | promise rejection (plain Error) | recovered → `internal_error` GameError; actor survives | Go addition |
| Kick handling in tests | `table.on('kick', …removePlayer)` synchronously queued | the Listener must spawn a goroutine (RoomManager does); tests wait on a WaitGroup instead of `settled()` | PORT_PLAN §3 |

## 6. Requests for other packages

- **RoomManager** (`roommanager_test.go`): `tablerules_test.go` rebuilds `_createTable`'s per-category
  config by hand (`productionConfig`: seen `MaxRaiseSteps 2 / MaxBetRounds 7 / MaxPot 1_200_000`;
  blind `0 / 0 / PotLimitMultiplier 0 / MaxPot 0`; both `MaxBlindMoves 4, MaxMissedTurns 3,
  SideshowTimeout 6s, SideshowMinPlayers 3`). Please keep a RoomManager test asserting `CreateTable`
  produces exactly those `TableConfig` values so the two never drift. (Your settle-retry count
  expectation — 1 `settle` + 10 `settle_retry` persist errors + 1 error — matches Node and Go.)
- **socket layer**: `table_destroyed` can now come back from any Table call that races a
  `DestroyTable`; ack it like any refusal (metrics fold it to `other`). A `Table` with `MaxPlayers 0`
  is not defended (Node was not either) — never build one.
- **db.Ledger**: the Table adopts `BetResult.Balance` and `Persisted` verbatim (Node had a
  `Number.isFinite` fallback; Go's int64 cannot express "absent"). Always return `Balance` = wallet
  after the debit and `Persisted = amount`; `CollectBootResult.Balances` for **every** entry and
  `Persisted = bootAmount`; `SettleResult` for every entry whose wallet row exists (a returned 0 is
  adopted as 0). Return `*GameError` with the ledger codes so `refusal()` maps them
  (`insufficient_chips` on `CollectBoot` must carry `UserID`).
- **testclock**: `internal/game/testclock` imports `game`, so in-package (white-box) game tests
  cannot import it — `table_test.go` carries an identical `fakeClock`. Either move `Fake` into
  package `game` (e.g. `game.FakeClock`) and make `testclock` an alias, or accept the duplicate.
- **PORT_PLAN §6** says "add an unexported `setCardsForTest`": it is the harness method
  `(*harness).setCards` (same idea, `t.run` + `seat.cards = ParseCards(codes)`).

## 7. Notes for the integrator

- **Actor rules are load-bearing and now tested**: a `Listener` callback must never call a posting
  method of the same table (deadlock); anything that needs the RoomManager goes in a goroutine
  (`TestNoDeadlockWithASlowListenerAndConcurrentCallers` runs 8 concurrent callers behind a slow
  listener; `TestChipConservationUnderRandomPlay` uses the goroutine kick pattern under `-race`).
- `Settled()` only waits for posts already queued; a kick's removal is posted by a *goroutine*, so a
  caller that must observe it has to wait on that goroutine (RoomManager's `OnPlayerKicked`).
- `Destroy()` on a live hand emits `handEnded`/`state` (and may emit a `state` for STARTING before the
  start timer is torn down) — same as Node; after it returns no event is ever delivered again and
  `clock.Pending()` is 0.
- Event orders a client can observe are exactly Node's (spec §19.1) — every row of that table is
  asserted, most of them twice (unit test + Node differential).
- `Version()` rises once per committed ledger write: boot, bet/show, settle, settle retry.
- Final run: `go test -race ./internal/game/...` →
  `ok github.com/surajk543/king-teenpatti/go-server/internal/game 5.5s`,
  `ok …/internal/game/testclock 1.0s` (282 test functions pass; `go vet` and `gofmt -l` clean).
