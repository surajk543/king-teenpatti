# PORT_NOTES — internal/game ↔ the live-state store (Redis beside PostgreSQL)

Owner scope: `internal/game/table.go`, `livestate.go` (new), `snapshot.go`, `durable.go` (new),
`ledger.go`, `roommanager.go`, `roommanager_live.go` (new), `internal/game/livetest/` (new, a
map-backed `live.Store` for tests), and the tests `livestate_test.go`, `roommanager_live_test.go`
(+ small edits to `table_test.go`, `settlement_test.go`, `roommanager_fixture_test.go`). Design:
`../LIVE_STATE_PLAN.md` (authoritative, including "The durable backstop"). Nothing under
`internal/live`, `internal/socket`, `internal/app`, `internal/db` was touched.

## 1. What changed, in one paragraph

Every `Table` now serialises its full `Snapshot` (cards included) **once per posted closure** that
changed observable state and hands the same bytes to two places: `live.Store.SaveTable` under a
per-table strictly rising `seq`, and `SnapshotSink.MarkDirty` (the db engineer's asynchronous
`game_states` writer). The money transaction no longer carries a snapshot: the ledger request
fields `Version`/`State` are left at zero/nil (see §7). `live.ErrStale` on a save **fences** the
table (two-owners guard). Chat is mirrored to the live store only. `RoomManager` mirrors the seat
index, publishes public tables to the matchmaking index, and gains `Restore` (two passes: live
store, then `game_states` reconciled against the ledger), `RestoredSeats`, `ReconcileLive`
(refill an emptied Redis) and `Suspend` (graceful restart that keeps tables alive).
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
    Snapshots  SnapshotSink             // nil → no durable copy
}
```

### Saving
- `emitState()` marks the actor's `liveDirty`; `SetChips` and `sweepUnfunded` (kickPending) mark it
  too. `run()`'s job wrapper calls `flushLive()` after the closure (after the Listener saw every
  event): one `SaveTable(roomID, seq, json, ttl)` + one `MarkDirty(roomID, seq, handID, json)` per
  mutation, **the same bytes, marshalled once**. Reads never save.
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
   too stale (left to `RefundOrphanedPots`), else restore (source `postgres`); the table's first
   save refills the live store (`SaveTable` seq+1), plus `PublishTable` and `SetSeated` per seat.
Per table: register (`tables`, `order` by `createdAt`, `playerRooms` from seats, code by scan),
`LoadChat` from the live store, resume clocks, `OnTableCreated` (+ `OnTableRestored` when the
listener implements `TableRestoreListener`), publish, log `table restored {roomId, code, source,
…}`. A user seated in two stored tables keeps the older one; the other seat is removed.
`RestoreReport{Tables, FromLive, FromDurable, Seats, HandsInProgress, HandIDs, Reconciled,
Rejected, Dropped, Skipped, Failed}`. `HandIDs` = hands live at restore time (pre-resume) — what
the db refund must skip. `RestoredSeats() []RestoredSeat{UserID, RoomID}` for the socket layer.

### ReconcileWithLedger (exported, pure)
`ReconcileWithLedger(snap *Snapshot, contributions map[string]int64) error`: the ledger wins. Sets
each seat's/record's `contributed` and `persisted` to the ledger figure, lowers the seat's `chips`
by the undebited difference, sets `didChaal` once the figure exceeds the boot, `hand.pot = Σ`.
Errors (→ Restore rejects the room): a ledger figure above the snapshot's for a player shown
packed/lost/absent (they bet after the snapshot), a ledger figure below the snapshot's, a snapshot
contribution with no ledger row, a live hand with no rows. `hand.stake` (the last bet's size) cannot
be read back and is left as saved — the next ladder may be one rung low after a reconciled restore
(money-safe; noted).

### ReconcileLive
`ReconcileLive(ctx) ReconcileReport{Healthy, Tables, Published, Seats, Errors}`: `Ping`; if healthy,
`SaveLive()` every table, `PublishTable` every public one, `SetSeated` every index entry. For a
Redis that came back empty / a FLUSHALL. Safe every 30 s; no mutex held across store calls.

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
  `ReconcileWithLedger` applies the missing bet (pot/contributed/persisted/chips/didChaal), is
  idempotent, rejects 5 kinds of too-stale; **TestSnapshotRoundTripIsLossless** (8 seeds × 60
  checkpoints of random play incl. sideshows, timeouts, kicks, leaves, disconnects).
- `roommanager_live_test.go` (package game_test, testclock): seats mirrored / published / deduped /
  retired / private never indexed / kick clears; Suspend → Restore rebuilds 5 tables (order, codes,
  index, RestoredSeats, Stats, chat, same turn + deadline, listener, publish, second Restore no-op);
  restored tables consolidated and swept; garbage dropped, load failure kept, list failure fatal;
  **two owners**: the stale writer fences itself, is destroyed, touches nothing of the owner's;
  Suspend without a store = Shutdown; durable fallback reconciles a stale row and refills Redis;
  too-stale row rejected and not restored; live wins over durable; `ReconcileLive` refills a
  flushed store (tables/published/seats counts, fresh seqs, unhealthy → nothing).
- Harness fix worth knowing: `harness.turnUser` used to `t.Fatal` inside the posted closure, which
  Goexits the **actor goroutine** and hangs the next post forever; it now fails outside the closure.

## 7. Open questions / deviations

- WAITING restore runs `maybeStart()` (spec said "nothing") — only differs when a boot refusal's
  retry died with the process; otherwise identical. Say if you want the literal rule.
- `Suspend` vs `Shutdown` at SIGTERM is the app's call: Suspend keeps hands alive across a deploy
  (players reconnect within `RECONNECT_GRACE_MS`), Shutdown settles them `all_left` as before.
- Reconciled restores cannot recover `hand.stake` or the turn advance of the missing bet: the same
  player may be asked to act again and the ladder may start one rung low. Money is exact.
- A fenced table settles nothing; if the owner also dies, the pot is refunded at the next startup.
- `RoomListener.OnTableRestored` is an optional interface (`TableRestoreListener`), not a new
  method on `RoomListener`, so `socket.Handler` keeps compiling unchanged.
