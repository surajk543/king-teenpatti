# PORT_NOTES — internal/game ↔ the live-state store (Redis beside PostgreSQL)

Owner scope: `internal/game/table.go`, `livestate.go` (new), `snapshot.go`, `ledger.go`,
`roommanager.go`, `roommanager_live.go` (new), `internal/game/livetest/` (new, a map-backed
`live.Store` for tests), and the tests `livestate_test.go`, `roommanager_live_test.go` (+ edits to
`table_test.go`, `settlement_test.go`, `review_money*_test.go`, `roommanager_fixture_test.go`).
Design: `../LIVE_STATE_PLAN.md` (authoritative).

> **Superseded, 9 Sep 2026.** An earlier revision of this file described a "durable backstop":
> `game_states` in PostgreSQL, written asynchronously at the two hand boundaries by
> `db.SnapshotWriter`, read back at startup and reconciled against the ledger. The owner then
> decided that **PostgreSQL must hold no game state at all** and that **a bet must not be a
> PostgreSQL transaction**. `SnapshotSink`, `DurableSource`, `DurableSnapshot`,
> `ReconcileWithLedger`, `Table.Snapshots`/`markDurable`/`MarkDeleted`, `RoomManager.Snapshots`/
> `Durable` and Restore's second pass are all **deleted**; `game_states` is dropped from the schema.

## 1. What changed, in one paragraph

Every `Table` serialises its full `Snapshot` (cards included) **once per posted closure** that
changed observable state and saves it to `live.Store.SaveTable` under a per-table strictly rising
`seq`. That is the ONLY place game state goes: PostgreSQL sees money and audit only. `live.ErrStale`
on a save **fences** the table (two-owners guard). Chat is mirrored to the live store only.
`RoomManager` mirrors the seat index, publishes public tables to the matchmaking index, and gains
`Restore` (one pass, the live store), `RestoredSeats`, `ReconcileLive` (refill an emptied Redis and
sweep strays out of it) and `Suspend` (graceful restart that keeps tables alive).
`RestoreTable(snapshot)` rebuilds a table and re-arms its clocks; Snapshot ⇄ RestoreTable ⇄
Snapshot is an identity under random play (property test).

A **bet writes nothing to PostgreSQL** (§2.1): it moves chips at the seat, in the pot and in the
snapshot, and is banked when the player leaves the hand (`Table.flushBets` → `Ledger.FlushBets`) or
when the hand ends (`endHand` → `Ledger.Settle`, which carries the outstanding bets).

## 2. Table (`table.go`, `livestate.go`)

### Options
```go
type TableOptions struct {
    …existing…
    Live       live.Store               // nil → no live saves
    LiveTTL    time.Duration            // 0 → DefaultLiveTTL (24 h)
    LiveErrors func(op string, err error) // per failed store call; op = LiveOp* (matches metrics.LiveOps)
}
```

### Saving
- `emitState()` marks the actor's `liveDirty`; `SetChips` and `sweepUnfunded` (kickPending) mark it
  too. `run()`'s job wrapper calls `flushLive()` after the closure (after the Listener saw every
  event): one `SaveTable(roomID, seq, json, ttl)` per mutation. Reads never save. With no live store
  no snapshot is taken at all.
- `seq` (`Table.LiveSeq()`) is separate from `Version()` (the count of committed ledger writes; also
  stored in the snapshot). **Every attempt takes a seq**, landed or not; gaps are harmless.
- Failure: counted via `LiveErrors`, reported as `OnPersistError{Reason: "live_save"}` (RoomManager
  logs `live store write failed`), the move is **never refused**; the table stays dirty and the next
  post of any kind (a read included) retries under a fresh seq.
- `live.ErrStale` → `fence(seq)`: `Fenced()` true, every clock stopped, every post but `Destroy`
  returns `ErrTableDestroyed` (code `table_destroyed`), `OnError` carries a `*FencedError`
  (unwraps to `live.ErrStale`). A fenced `destroy()` **does not settle the hand and does not delete
  the store's copy** — it belongs to the owner. RoomManager's `tableHooks.OnError`
  destroys the fenced table in a goroutine and skips `RetireTable`/`ClearSeated` for it.
- `Destroy` (owned table): `DeleteTable` + `DeleteChat`.
- `Suspend()` (new): stops every clock, saves a final snapshot, marks destroyed **without** ending
  the hand or touching the stores — the graceful-restart path; detached settle retries continue as
  after Destroy. Without a live store (or when fenced) it is a Destroy.
- `SaveLive()` (new): posts an unconditional re-save (used by `ReconcileLive`).
- Chat: `PostChat` and the join/leave system lines call `Live.AppendChat(roomID, msgJSON,
  ChatMaxHistory)`; failure → `OnPersistError{live_chat}`. **Chat is never in the snapshot**
  (invariant 5; `TestSnapshotNeverCarriesChat`).
- `Snapshot()` (new posting read) returns the full server-side snapshot — never send it to a client.
- All store calls use a 2 s context (`liveCallTimeout`) on top of the store's own timeout, and a
  panic inside the store is recovered on the actor and reported, never fatal.

### 2.1 A BET IS NOT A DATABASE TRANSACTION (9 Sep 2026)

Owner: *"Do not update pg database in bet chaal or show, just update in redis. Only update in pg when
game starts and game ends. And in case of switch table or leave table, only update in pg for that
player who left the table or switched the table."*

`chargeToPot` no longer calls the ledger. It:

1. sanitises the client `actionId` (reserved-namespace ids are replaced by a uuid, as before);
2. refuses `duplicate_action` when this hand has already accepted that id (`handHasActionID` — the
   in-memory half of what the `chip_ledger.action_id` UNIQUE index used to do on its own);
3. refuses `insufficient_chips` when `seat.chips < amount` — which IS the wallet check, because
   `wallet == seat.chips + Σ unbanked bets` holds throughout a hand (boot debited up front, seat only
   decreases, one seat per player);
4. moves `seat.chips`, `seat.contributed` and `hand.pot`, and appends a `stakedBet{amount, reason,
   actionID, flushed}` to the player's `contribution.bets`.

`contribution.bets` is in `SnapshotContribution.Bets`, so the record of what is staked lives in the
live store and survives a restart. It is banked in exactly two places:

| Call site | When | What is written |
|---|---|---|
| `flushBets(userID)` from `removePlayer` (leave, switch, kick, lapsed grace) | that player is out of the hand | `Ledger.FlushBets`: their bets in order, wallet debit, `pots.amount +=`. Every bet is marked `flushed` and `contribution.persisted += result.Persisted`. A failure is reported (`PersistReasonFlush`), never refuses the departure, and leaves the bets pending for the settlement. |
| `endHand` → `Ledger.Settle` | the hand is over | `SettleEntry.Bets` carries each player's still-unflushed bets; the ledger banks them inside the settlement transaction. |

**Delta arithmetic (unchanged rows).** The Table still computes `Delta = net + persisted` where
`persisted` counts only what has actually been banked (the boot, plus a departure's flush). The
LEDGER adds what it banks in the settlement to that delta, so the settlement row is exactly what the
per-bet model produced: `+pot` for the winner, `0` for a fully-banked loser. This is the `persisted`
contract of CLAUDE.md §12.2 taken one step further — the ledger reports what it banked, the Table
never assumes it — and it is what keeps the bookless `MemoryLedger` conserving (it banks 0, so the
delta stays the whole net).

**No double-write.** The `flushed` flag stops the re-send; `db.bankBets` inserts with
`ON CONFLICT (action_id) DO NOTHING` and skips the debit and the pot update when the row is already
there (a settle retry, or a flush whose marker was lost with Redis). A collision with a row from
another hand is banked under a fresh uuid rather than dropped — the pot must never hold chips no row
accounts for.

### Snapshot fields added (`snapshot.go`; Node's keys kept)
Top level: `seq`, `version`, `isPrivate`, `createdAt`, `config` (`SnapshotConfig`: category,
bootAmount, maxPlayers, minPlayers, turnTimeoutMs, maxBetRounds, potLimitMultiplier,
maxRaiseSteps, maxPot, maxBlindMoves, maxMissedTurns, sideshowTimeoutMs, sideshowMinPlayers,
nextHandDelayMs, chatMaxHistory, chatMaxLength), `startsAt` (STARTING only, else null).
Seat: `avatarUrl`, `lastBet`, `lastAction`, `missedTurns`, `sideshowAskedThisTurn`, `kickPending`,
`joinedAt`. Hand: `packedUserIds` (sorted), `seatOrder`, `sideshow{fromUserId, fromSeat, toUserId,
toSeat, expiresAt}`, `lastDeparture`, `turnDeadline` (epoch ms, null before the first turn).
Contribution: `displayName`, `seatIndex`, `sawCards`, `cards`, **`bets`** (`[]SnapshotBet{amount,
reason, actionId, flushed}`, never nil — §2.1). **Deliberately absent**: `connected`,
`socketId`, `disconnectedAt` (a restored process has no sockets), `turnToken` (re-minted), chat.
The old "as it will be" rendering for the ledger (`snapshotWith` overrides, `snapshotAfterBet`) is
gone; the snapshot is always the table as it is.

### RestoreTable
`RestoreTable(snap *Snapshot, opts TableOptions) (*Table, error)` — the snapshot is authoritative
for id, code, config, isPrivate; `opts` supplies Ledger, Clock, Listener, Live, LiveTTL and LiveErrors. Every seat comes back `connected=false`, no socket. Validation is strict (config present,
seat indices, user ids unique, card codes parse, hand references occupied seats, sideshow seats
match) and refuses with a descriptive error. Re-arm rules, on the actor, against `Clock.Now()`:

| Stored state | Restore does |
|---|---|
| hand + pending sideshow | expired → `resolveSideshow(false, "timeout")` (asker's clock restarts full, `already_asked` kept); else the sideshow timer for what is left |
| hand on turn | deadline past → `onTurnTimeout` now (missedTurns++, pack, idle kick at MaxMissedTurns — ordinary semantics); else the turn timer for what is left under a fresh `turnToken`; `turn.deadline` on the wire is unchanged |
| starting | `startsAt` past → `startHand()` now (boots through the Ledger; refusal → ordinary `startRefused` path); else the countdown for what is left |
| waiting | `maybeStart()` — a no-op unless enough funded seats are present, which at rest only happens when a boot refusal's retry timer died with the process (deviation from "nothing", documented) |
| seats with `kickPending` | `OnKick` announced again so the RoomManager hook finishes the removal |

With a live store the restored table saves once immediately (seq + 1) — the claim that fences a
stale writer. Two-phase internals (`restoreTable` then `resume`) let the RoomManager register the
table between construction and the first clock; the exported `RestoreTable` does both.

## 3. RoomManager (`roommanager.go`, `roommanager_live.go`)

### Options
```go
type RoomManagerOptions struct {
    …existing…
    Live      live.Store     // nil → pre-Redis behaviour exactly
    Instance  string         // TableSummary.Instance (LIVE_INSTANCE_ID)
    LiveTTL   time.Duration  // 0 → DefaultLiveTTL
}
type MetricsHooks struct { …; ObserveLiveError func(op string, err error) } // optional; the wrapped store counts too
```

### Mirroring (never under `mu`)
- `SetSeated(user, room)` after every successful `AddPlayer` (`seatHeld`); `ClearSeated(user)` in
  `vacateFrom` (leave / kick / grace), at the index deletion of a consolidation move (the target
  `SetSeated` follows), and for every seat of a destroyed table.
- `PublishTable` on creation and restore, and from `tableHooks.OnState` whenever `PlayerCount` or
  `State` differ from the last publish (deduped, lock-free getters, one round trip on the actor).
  **Private tables are never published**. `RetireTable` when a table is destroyed (not when fenced).

### Restore
`Restore(ctx) (RestoreReport, error)` — call **before `StartSweeper` and before the listener opens**.
ONE pass, the live store, because there is nowhere else a table can come from:
`ListTables → LoadTable → parse/validate → restore`; garbage → `DeleteTable`+`DeleteChat`,
`Dropped++`; load error → `Failed++` (left in place).
Per table: register (`tables`, `order` by `createdAt`, `playerRooms` from seats, code by scan),
`LoadChat` from the live store, resume clocks, `OnTableCreated` (+ `OnTableRestored` when the
listener implements `TableRestoreListener`), publish, log `table restored {roomId, code, …}`.
A user seated in two stored tables keeps the older one; the other seat is removed.
`RestoreReport{Tables, Seats, HandsInProgress, HandIDs, Dropped, Skipped, Failed}` — `FromLive`,
`FromDurable`, `Reconciled` and `Rejected` are gone with the second pass. `HandIDs` = hands live at
restore time (pre-resume) — what the db refund must skip. `RestoredSeats() []RestoredSeat{UserID,
RoomID}` for the socket layer.

**An empty live store restores nothing** (`TestRoomsRestoreFindsNothingWhenTheLiveStoreIsEmpty`).
The players re-join and `db.RefundOrphanedPots` returns every open pot: that is the whole recovery
story now.

### ReconcileLive (refill + stray sweep)
`ReconcileLive(ctx) ReconcileReport{Healthy, Tables, Published, Seats, StaleSeats, StaleSummaries,
Errors}`: `Ping`; if healthy, **refill** — `SaveLive()` every table, `PublishTable` every public
one, `SetSeated` every index entry (for a Redis that came back empty / a FLUSHALL) — then **sweep**
(`sweepStrays`): `live.ListSeats` → `ClearSeated` every user not in `playerRooms`, and
`live.ListSummaries` → `RetireTable` every room not registered here. Safe every 30 s; no mutex held
across store calls.

Two new `live.Store` methods back the sweep, implemented for Redis (SCAN + pipelined MGET/HGETALL,
never KEYS), Memory and both test fakes, covered by the shared conformance suite:
`ListSeats(ctx) (map[string]string, error)` and `ListSummaries(ctx) ([]TableSummary, error)`. New op
labels `list_seats` / `list_summaries` in `metrics.LiveOps`.

### The two store leaks found on production (9 Sep 2026)
Zero players, zero tables, and Redis still held **4,715 `kt:seat:<userId>`** keys and **141
`kt:summary:<roomId>`** hashes. Root causes and fixes:

1. **Seat keys have no ttl** (everything else does), so any table that disappeared without going
   through `destroyTable` — its snapshot expired, it was dropped at restore, the process was
   replaced without a successful restore — left its players' seat entries in Redis forever, and
   nothing ever looked for them. Summaries carry `auxTTL` (24 h) so they self-healed slowly.
   → `sweepStrays` on the reconcile tick.
2. **`dropStored` deleted only the snapshot and the chat.** A stored table that cannot be rebuilt
   now also retires its summary and clears the seat entry of every player its snapshot named (when
   the snapshot parsed at all; when it did not, the sweep gets them on the next tick).
3. **A `ClearSeated` / `RetireTable` that failed against a store that was briefly down was logged
   and forgotten.** → the sweep retries the effect forever.
4. **A departure through a stale index entry cleared nothing.** `seatedTableLocked` drops an entry
   naming an unregistered table on sight and now reports it (`(t *Table, dropped bool)`); every
   caller that leaves the player unseated — `GetTableForPlayer`, `SwitchTable`, `vacateFrom` —
   clears the live mirror.

Unchanged on purpose: `Suspend` keeps seats and summaries (the next process restores the tables and
re-sets them), and a FENCED table touches neither (both belong to the owning process).

### Suspend
`Suspend(ctx)`: stop the sweeper, take every table out of the maps and `Table.Suspend()` it, wait
for detached settlements within ctx. Without a live store it is `Shutdown`.

## 4. Exact hooks the socket/app layers must call

```
store, _ := live.Open(ctx, live.Options{URL: cfg.RedisURL, Instance: id, …})   // app
rooms := game.NewRoomManager(game.RoomManagerOptions{
    Game, Chat, Ledger, Clock, TableListener: h, Listener: h, Logger, Metrics,
    Live: store, Instance: id, LiveTTL: cfg.LiveStateTTL,
})
h.SetRooms(rooms)
report, err := rooms.Restore(ctx)                 // BEFORE StartSweeper / listener
db.RefundOrphanedPots(ctx, report.HandIDs)        // db engineer's step 3
h.RestoreSeats(rooms.RestoredSeats())             // socket: seats are already connected=false; arm the grace timer per seat
rooms.StartSweeper()
go ticker(cfg.LiveReconcile) { rooms.ReconcileLive(ctx) }   // and once on unhealthy→healthy
// shutdown: rooms.Suspend(ctx) when a real live store is configured (tables come back), else rooms.Shutdown(ctx)
```
- `RoomListener` is unchanged; restored tables arrive via `OnTableCreated` (+ optional
  `OnTableRestored` if the listener implements `game.TableRestoreListener`).
- `Listener` is unchanged. New `PersistErrorEvent.Reason` values: `live_save`, `live_chat`,
  `live_delete` (nothing refused; fold into your metrics as you see fit). `OnError` may now carry
  `*game.FencedError`.
- `table_destroyed` can now also mean "fenced" — ack it like any refusal (already the case).
- `Table.LiveSeq()`, `Fenced()`, `Snapshot()`, `SaveLive()`, `Suspend()` are new; nothing else on
  the Table's exported surface changed.
- Metric feeds: `MetricsHooks.ObserveLiveError(op, err)` is optional (the app wraps the store with
  `live.WithHooks`, which counts the same calls). `RestoreReport.Tables/Seats` map onto
  `game_restored_tables_total` (unlabelled) and `game_restored_seats_total`.

## 5. Ledger contract — for the db engineer

`Ledger.Bet` / `BetRequest` / `BetResult` are **deleted** — a bet is not a transaction. In their
place:

```go
type StakedBet struct { Amount int64; Reason string; ActionID string }   // reason: bet | show

FlushBets(ctx, FlushBetsRequest{UserID, RoomID, HandID, Bets []StakedBet}) (FlushBetsResult{Balance, Persisted}, error)
```

and `SettleEntry` gains `Bets []StakedBet`. `Persisted` is what the ledger ACTUALLY banked (bets
already present are not charged again), and `Settle` must add what it banks to the entry's `Delta`
before writing the settlement row — see §2.1. No request carries a snapshot: nothing about a table
reaches PostgreSQL, and `game_states` is dropped from `schema.sql` by a guarded DO block that fires
only when the table exists and is empty.

## 6. Tests (`go test -race ./internal/game/...` green; gofmt/vet clean)

- `livestate_test.go` (package game, fake clock, `livetest.Store`): one save per mutation with seq
  1..n, parses, cards present, reads save nothing; live failure never refuses + retries next post;
  ErrStale → fenced + `FencedError` + `table_destroyed` + Destroy leaves the store alone; chat mirror
  (player + system lines, cap, sanitised, failure reported); Destroy deletes; Suspend saves/ends
  nothing; **TestSnapshotNeverCarriesChat**; RestoreTable (a) deadline ahead →
  same turn, fires at the original instant, (b) deadline past → immediate timeout pack, turn
  advances, 3rd miss → idle kick, (c) sideshow pending: answerable / lapses on restore / expires at
  the original instant, (d) countdown: armed for what is left / deals now / refusal path, (e) all
  seats disconnected → last standing, Σdelta = 0, bank conserved, waiting → nothing (+ the
  boot-refusal deviation), kicks re-announced, claim save seq+1, 14 garbage cases refused;
  **TestSnapshotRoundTripIsLossless** (8 seeds × 60 checkpoints of random play incl. sideshows,
  timeouts, kicks, leaves, disconnects — the bets on each contribution ride round with it).
- The money model (§2.1), in `settlement_test.go` / `table_test.go` / `review_money_test.go`:
  **TestAChaalIsBankedWhenTheHandEndsNotWhenItIsMade**,
  **TestLeavingMidHandBanksTheBetsOnceAndTheSettlementDoesNotResendThem**,
  **TestASeatNeverHoldsMoreThanItsAccount**, **TestAReplayedBetIsRefusedAndChangesNothing**,
  **TestAFlushTheLedgerRefusesStillLetsThePlayerLeave**, and
  **TestChipConservationUnderRandomPlay** (Σaccounts + the BANKED part of the pot is invariant, and
  every seat is its account less its unbanked bets).
- `roommanager_live_test.go` (package game_test, testclock): seats mirrored / published / deduped /
  retired / private never indexed / kick clears; Suspend → Restore rebuilds 5 tables (order, codes,
  index, RestoredSeats, Stats, chat, same turn + deadline, listener, publish, second Restore no-op);
  restored tables consolidated and swept; garbage dropped, load failure kept, list failure fatal;
  **two owners**: the stale writer fences itself, is destroyed, touches nothing of the owner's;
  Suspend without a store = Shutdown;
  **TestRoomsRestoreFindsNothingWhenTheLiveStoreIsEmpty** (an empty store rebuilds no table and no
  seat, while the store that DID have them still does); `ReconcileLive` refills a flushed store (tables/published/seats counts, fresh seqs, unhealthy → nothing);
  **TestAFullLifecycleLeavesNoSeatOrSummaryBehind** (join → play → leave → kick → consolidate →
  sweep → shutdown ends with zero `kt:seat:*` and zero `kt:summary:*`);
  **TestReconcileLiveSweepsStraySeatsAndSummaries** (three ghost seats and one ghost summary
  removed, real ones — private tables included — kept, idempotent);
  **TestRestoreDroppingATableAlsoDropsItsSeatsAndSummary**.
- Harness fix worth knowing: `harness.turnUser` used to `t.Fatal` inside the posted closure, which
  Goexits the **actor goroutine** and hangs the next post forever; it now fails outside the closure.

## 7. Open questions / deviations

- WAITING restore runs `maybeStart()` (spec said "nothing") — only differs when a boot refusal's
  retry died with the process; otherwise identical. Say if you want the literal rule.
- `Suspend` vs `Shutdown` at SIGTERM is the app's call: Suspend keeps hands alive across a deploy
  (players reconnect within `RECONNECT_GRACE_MS`), Shutdown settles them `all_left` as before.
- **A bet is not durable until the hand ends.** Losing Redis un-makes every unbanked bet: the players
  keep those chips, the boots are refunded from the open pot, and nothing is created or destroyed.
  That is the one guarantee this design gives up, deliberately (LIVE_STATE_PLAN.md invariant 7).
- The in-memory balance check replaces the wallet `FOR UPDATE` lock for a bet. It is exact because
  `wallet == seat.chips + Σ unbanked bets` throughout a hand; `bankBets` still refuses rather than
  letting the `chips >= 0` CHECK abort a transaction, so a divergence would surface as a logged
  `insufficient_chips`, not as lost money.
- A client that reuses one `actionId` across two hands is no longer refused; its second use is
  banked under a fresh server-minted id so the pot and the ledger still agree.
- A fenced table settles nothing; if the owner also dies, the pot is refunded at the next startup.
- `RoomListener.OnTableRestored` is an optional interface (`TableRestoreListener`), not a new
  method on `RoomListener`, so `socket.Handler` keeps compiling unchanged.
