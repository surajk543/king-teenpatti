# PORT_NOTES — internal/game ↔ the live-state store (Redis beside PostgreSQL)

Owner scope: `internal/game/table.go`, `livestate.go` (new), `snapshot.go`, `durable.go` (new),
`ledger.go`, `roommanager.go`, `roommanager_live.go` (new), `internal/game/livetest/` (new, a
map-backed `live.Store` for tests), and the tests `livestate_test.go`, `roommanager_live_test.go`
(+ small edits to `table_test.go`, `settlement_test.go`, `roommanager_fixture_test.go`). Design:
`../LIVE_STATE_PLAN.md` (authoritative, including "The durable backstop"). `internal/socket` and
`internal/app` are untouched. The 9 Sep 2026 change (hand-boundary durable writes + the two store
leaks) also touched `internal/live` (two new `Store` methods), `internal/db/snapshots.go`
(`HandContributions` returns an ordered slice) and `internal/metrics/names.go` (two op labels).

## 1. What changed, in one paragraph

Every `Table` now serialises its full `Snapshot` (cards included) **once per posted closure** that
changed observable state and saves it to `live.Store.SaveTable` under a per-table strictly rising
`seq`. The same bytes, under the same `seq`, also go to `SnapshotSink.MarkDirty` (the asynchronous
`game_states` writer) — but **only at the two hand boundaries** (§2.1), not on every mutation. The money transaction no longer carries a snapshot: the ledger request
fields `Version`/`State` are left at zero/nil (see §7). `live.ErrStale` on a save **fences** the
table (two-owners guard). Chat is mirrored to the live store only. `RoomManager` mirrors the seat
index, publishes public tables to the matchmaking index, and gains `Restore` (two passes: live
store, then `game_states` reconciled against the ledger), `RestoredSeats`, `ReconcileLive`
(refill an emptied Redis and sweep strays out of it) and `Suspend` (graceful restart that keeps
tables alive).
`RestoreTable(snapshot)` rebuilds a table and re-arms its clocks; Snapshot ⇄ RestoreTable ⇄
Snapshot is an identity under random play (property test).

## 2. Table (`table.go`, `livestate.go`)

### Options
```go
type TableOptions struct {
    …existing…
    Live       live.Store               // nil → no live saves
    LiveTTL    time.Duration            // 0 → DefaultLiveTTL (24 h)
    LiveErrors func(op string, err error) // per failed store call; op = LiveOp* (matches metrics.LiveOps)
    Snapshots  SnapshotSink             // nil → no durable copy; fed at the hand boundaries only (§2.1)
}
```

### Saving
- `emitState()` marks the actor's `liveDirty`; `SetChips` and `sweepUnfunded` (kickPending) mark it
  too. `run()`'s job wrapper calls `flushLive()` after the closure (after the Listener saw every
  event): one `SaveTable(roomID, seq, json, ttl)` per mutation. Reads never save.
- `MarkDirty` is gated on a second flag, `durableDirty`, set only by `markDurable()` (§2.1); when
  both are set the snapshot is marshalled ONCE and both stores get the same bytes under the same
  `seq`. With no live store at all, an ordinary move now takes no snapshot and no `seq` — only a
  hand boundary does.
- `seq` (`Table.LiveSeq()`) is separate from `Version()` (still the count of committed ledger
  writes; now also stored in the snapshot). **Every attempt takes a seq**, landed or not, so the
  durable writer's `version < EXCLUDED.version` guard stays monotonic; gaps are harmless.
- Failure: counted via `LiveErrors`, reported as `OnPersistError{Reason: "live_save"}` (RoomManager
  logs `live store write failed`), the move is **never refused**; the table stays dirty and the next
  post of any kind (a read included) retries under a fresh seq. The durable sink still receives the
  snapshot when the live save fails — that is its purpose.
- `live.ErrStale` → `fence(seq)`: `Fenced()` true, every clock stopped, every post but `Destroy`
  returns `ErrTableDestroyed` (code `table_destroyed`), `OnError` carries a `*FencedError`
  (unwraps to `live.ErrStale`). A fenced `destroy()` **does not settle the hand and does not delete
  the store's copy or the durable row** — both belong to the owner. RoomManager's `tableHooks.OnError`
  destroys the fenced table in a goroutine and skips `RetireTable`/`ClearSeated` for it.
- `Destroy` (owned table): `DeleteTable` + `DeleteChat` + `MarkDeleted`.
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

### 2.1 The durable copy is written at the two HAND BOUNDARIES only (9 Sep 2026)

Measured on production: writing a `game_states` snapshot of every table once a second competed with
the money for the same saturated disk — committed transactions/s fell from 1,258 to 654 at 7,000
players, I/O wait tripled to 31 %, and the usable ceiling halved from 15,000 players to 7,000. Redis
was blameless. The owner's decision: *"In postgres do not save game live state, only save the state
in the beginning of game, and when game ends. In between, game states should be saved in redis for
all rooms."*

`Table.markDurable()` (unexported, `livestate.go`) sets `liveDirty` **and** `durableDirty`. It is
called from **exactly two places**, both in `table.go`, both with a comment saying why:

| Call site | When | What the snapshot says |
|---|---|---|
| end of `startHand`, after `setTurn(firstSeat, true); emitState()` | boots collected, cards dealt, first turn open | the hand's OPENING state — the state the boot transaction that just committed corresponds to |
| end of `endHand`, after `emitState()`, before `maybeStart()` | settled, `hand == nil`, seats carrying their settled chips | the table AT REST — without it a restore from the hand-start row would resurrect a hand already paid out |

`Destroy` still hands `MarkDeleted`. `Suspend` saves to the live store only — the live copy is what
the next process comes back from. Nothing else touches the sink. A table that is created, filled and
never dealt writes **nothing** durable: nothing is at stake and its players simply re-join, so a
`game_states` row only ever exists for a room that has dealt.

Consequence for restores: a durable snapshot of a live hand is now a whole hand behind the money
instead of ≤ `SNAPSHOT_FLUSH_MS`, which is what `ReconcileWithLedger` (§3) was widened for.

### Snapshot fields added (`snapshot.go`; Node's keys kept)
Top level: `seq`, `version`, `isPrivate`, `createdAt`, `config` (`SnapshotConfig`: category,
bootAmount, maxPlayers, minPlayers, turnTimeoutMs, maxBetRounds, potLimitMultiplier,
maxRaiseSteps, maxPot, maxBlindMoves, maxMissedTurns, sideshowTimeoutMs, sideshowMinPlayers,
nextHandDelayMs, chatMaxHistory, chatMaxLength), `startsAt` (STARTING only, else null).
Seat: `avatarUrl`, `lastBet`, `lastAction`, `missedTurns`, `sideshowAskedThisTurn`, `kickPending`,
`joinedAt`. Hand: `packedUserIds` (sorted), `seatOrder`, `sideshow{fromUserId, fromSeat, toUserId,
toSeat, expiresAt}`, `lastDeparture`, `turnDeadline` (epoch ms, null before the first turn).
Contribution: `displayName`, `seatIndex`, `sawCards`, `cards`. **Deliberately absent**: `connected`,
`socketId`, `disconnectedAt` (a restored process has no sockets), `turnToken` (re-minted), chat.
The old "as it will be" rendering for the ledger (`snapshotWith` overrides, `snapshotAfterBet`) is
gone; the snapshot is always the table as it is.

### RestoreTable
`RestoreTable(snap *Snapshot, opts TableOptions) (*Table, error)` — the snapshot is authoritative
for id, code, config, isPrivate; `opts` supplies Ledger, Clock, Listener, Live, LiveTTL, LiveErrors,
Snapshots. Every seat comes back `connected=false`, no socket. Validation is strict (config present,
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
    Snapshots SnapshotSink   // db.SnapshotWriter (nil → no durable copy)
    Durable   DurableSource  // game_states + chip_ledger reads for Restore (nil → live only)
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
`Restore(ctx) (RestoreReport, error)` — call **before `StartSweeper` and before the listener opens**:
1. live store: `ListTables → LoadTable → parse/validate → restore` (source `live`); garbage →
   `DeleteTable`+`DeleteChat`, `Dropped++`; load error → `Failed++` (left in place).
2. `Durable.LoadSnapshots`, skipping rooms pass 1 registered; for a live hand
   `Durable.HandContributions(handID)` → `ReconcileWithLedger` (below) → `Rejected++` and skip when
   it cannot be reconciled (left to `RefundOrphanedPots`), else restore (source `postgres`); the table's first
   save refills the live store (`SaveTable` seq+1), plus `PublishTable` and `SetSeated` per seat.
Per table: register (`tables`, `order` by `createdAt`, `playerRooms` from seats, code by scan),
`LoadChat` from the live store, resume clocks, `OnTableCreated` (+ `OnTableRestored` when the
listener implements `TableRestoreListener`), publish, log `table restored {roomId, code, source,
…}`. A user seated in two stored tables keeps the older one; the other seat is removed.
`RestoreReport{Tables, FromLive, FromDurable, Seats, HandsInProgress, HandIDs, Reconciled,
Rejected, Dropped, Skipped, Failed}`. `HandIDs` = hands live at restore time (pre-resume) — what
the db refund must skip. `RestoredSeats() []RestoredSeat{UserID, RoomID}` for the socket layer.

### ReconcileWithLedger (exported, pure)
`ReconcileWithLedger(snap *Snapshot, contributions []LedgerContribution) error`: the ledger wins.
Sets each seat's/record's `contributed` and `persisted` to the ledger figure, lowers the seat's
`chips` by the undebited difference (clamped at 0), sets `didChaal` once the figure exceeds the
boot, `hand.pot = Σ`.

**The contract changed with the hand-boundary policy.** `DurableSource.HandContributions` now
returns an ORDERED `[]LedgerContribution{UserID, Amount}` — each player positioned by their most
recent `chip_ledger` row for the hand (`ORDER BY MAX(id)`, and `id` is a BIGSERIAL) — so the last
element is whoever moved last.

**The turn rule after a reconcile that moved anything** (`reopenTurn`): *the turn goes to the first
seat that can still act clockwise after the last contributor in ledger order, on a fresh full turn
clock.* That is exactly where `advanceTurn` would have gone; anything else asks a player to act
twice or skips one. The stored `turnDeadline` is dropped (it belongs to a turn that ended before the
crash — `RestoreTable` fires an expired deadline immediately, which would pack the player and count
a missed turn) and any pending sideshow with it; the new seat starts able to ask for one. Fallbacks,
in order: the last contributor is no longer at the table → keep the snapshot's turn seat if it can
act → otherwise the first seat that can → otherwise leave it to `RestoreTable`. When the ledger
agrees with the snapshot exactly, nothing is touched (idempotent).

**Rejections, now only what cannot be attributed** (→ Restore rejects the room and its pot is
refunded): a contributor the snapshot has neither a seat nor a contribution record for; a ledger
figure BELOW the snapshot's; a snapshot contribution with no ledger row; a live hand with no rows;
the same player twice. **No longer a rejection:** a ledger figure above the snapshot's for a player
the snapshot shows packed, lost or gone from the table — with hand-boundary writes that is the
normal case, not a stale one, and their stake is accounted for by their seat or their record.

Not recoverable from the ledger and left as saved: `hand.stake` (play resumes at the opening stake,
so the ladder can restart one or more rungs low), `hand.round` (the forced-showdown count restarts),
and who had packed (everyone the snapshot had active is asked to act again). All money-safe.

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
    Snapshots: snapshotWriter,   // db.SnapshotWriter (implements game.SnapshotSink)
    Durable:   durableSource,    // db side (implements game.DurableSource)
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
  `live.WithHooks`, which counts the same calls). `RestoreReport.FromLive/FromDurable/Reconciled/
  Rejected/Seats` map onto `game_restored_tables_total{source}`, `game_restore_reconciled_total`,
  `game_restore_rejected_total`, `game_restored_seats_total`.

## 5. Ledger request fields — for the db engineer

`BetRequest.Version/State`, `CollectBootRequest.Version/State` and `SettleRequest.Version/State` are
**deleted**: the snapshot no longer rides in the money transaction (`db.saveState` and its three
call sites were already gone from `internal/db` when this landed, so the module builds). The
`Ledger` interface docs no longer mention the `game_states` upsert. `MemoryLedger` never read them.
`tools/parity/money.test.js` "game_states holds one versioned snapshot per room" now depends on the
async `SnapshotWriter` having flushed (`SNAPSHOT_FLUSH_MS`) and on `version` meaning the live `seq`.

## 6. Tests (`go test -race ./internal/game/...` green; gofmt/vet clean)

- `livestate_test.go` (package game, fake clock, `livetest.Store`): one save per mutation with seq
  1..n, parses, cards present, reads save nothing; live failure never refuses + retries next post;
  ErrStale → fenced + `FencedError` + `table_destroyed` + Destroy leaves the store alone; chat mirror
  (player + system lines, cap, sanitised, failure reported); Destroy deletes; Suspend saves/ends
  nothing; durable sink gets the same bytes, is fed while Redis is down, `MarkDeleted` on destroy,
  nothing for a fenced table; **TestSnapshotNeverCarriesChat**; RestoreTable (a) deadline ahead →
  same turn, fires at the original instant, (b) deadline past → immediate timeout pack, turn
  advances, 3rd miss → idle kick, (c) sideshow pending: answerable / lapses on restore / expires at
  the original instant, (d) countdown: armed for what is left / deals now / refusal path, (e) all
  seats disconnected → last standing, Σdelta = 0, bank conserved, waiting → nothing (+ the
  boot-refusal deviation), kicks re-announced, claim save seq+1, 14 garbage cases refused;
  `ReconcileWithLedger` applies the missing bet (pot/contributed/persisted/chips/didChaal), moves
  the turn past the last contributor on a fresh clock, is idempotent, and rejects only what cannot
  be attributed; **TestTheDurableSinkIsFedAtTheHandBoundariesOnly** (nothing on a join or a move,
  one mark at the deal carrying the hand id, one at the settlement carrying none and no hand in the
  bytes, fed while Redis is down, MarkDeleted on destroy);
  **TestReconcileRebuildsAHandStartSnapshotAfterThreeRoundsOfBetting** (nine chaals of ledger, the
  opening snapshot, correct pot and per-seat contributions, the right player on a full fresh turn
  clock, play continues); **TestSnapshotRoundTripIsLossless** (8 seeds × 60
  checkpoints of random play incl. sideshows, timeouts, kicks, leaves, disconnects).
- `roommanager_live_test.go` (package game_test, testclock): seats mirrored / published / deduped /
  retired / private never indexed / kick clears; Suspend → Restore rebuilds 5 tables (order, codes,
  index, RestoredSeats, Stats, chat, same turn + deadline, listener, publish, second Restore no-op);
  restored tables consolidated and swept; garbage dropped, load failure kept, list failure fatal;
  **two owners**: the stale writer fences itself, is destroyed, touches nothing of the owner's;
  Suspend without a store = Shutdown; durable fallback reconciles a stale row and refills Redis;
  a row it cannot account for rejected and not restored; live wins over durable; `ReconcileLive`
  refills a flushed store (tables/published/seats counts, fresh seqs, unhealthy → nothing);
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
- Reconciled restores cannot recover `hand.stake`, `hand.round` or who had packed: the ladder may
  start low, the forced-showdown count restarts, and a player who had packed is asked to act again.
  The turn IS recovered (the seat after the ledger's last contributor, fresh clock). Money is exact.
- `game_states` no longer has a row for a table that has never dealt. Anything that counted rows
  against live tables has to count them against rooms with a pot instead (`tools/parity/money.test.js`
  already does).
- A fenced table settles nothing; if the owner also dies, the pot is refunded at the next startup.
- `RoomListener.OnTableRestored` is an optional interface (`TableRestoreListener`), not a new
  method on `RoomListener`, so `socket.Handler` keeps compiling unchanged.
