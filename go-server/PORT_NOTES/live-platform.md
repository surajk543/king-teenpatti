# PORT_NOTES — the platform side of the live-state store

Owner scope: `internal/socket/*`, `internal/app/*`, `internal/db/*`, `internal/config/*`,
`internal/metrics/*`, `cmd/gameplay/*`, `.env.example`, plus the test-only package
`internal/livetest`. Architecture: `../LIVE_STATE_PLAN.md` (authoritative, including the owner's
late additions "The durable backstop" and invariant 5, chat never in PostgreSQL). The store itself is
`internal/live` (`live.md`); the table/RoomManager side is the game engineer's (`live-game.md` when
it appears).

## What changed

| Package | Change |
|---|---|
| `db/ledger.go` | The `game_states` upsert (`saveState`, Node's `stale_state` guard) is gone from `Bet`, `CollectBoot`, `Settle` and the settle retry path. A money transaction touches only `users`, `pots`, `chip_ledger` (+ `hands` on settle). `Version`/`State` on the ledger requests are no longer read (the game package has deprecated them). `stale_state` can no longer be produced by the db layer. |
| `db/schema.sql` | `game_states` stays, re-described: the durable backstop written asynchronously by `SnapshotWriter`; `version` is now the live store's per-table `seq`. No migration needed. |
| `db/refund.go` | `RefundOrphanedPots(ctx, liveHandIDs) (RefundReport, error)` — startup step 3 / last-resort recovery. `LedgerReasonRefund = "refund"`, `RefundActionID(handID, userID) = "<handId>:refund:<userId>"`. |
| `db/snapshots.go` | `SnapshotWriter` (the game package's `SnapshotSink`), `(*DB).LoadSnapshots`, `(*DB).HandContributions` (its `DurableSource`), `DurableSnapshot = game.DurableSnapshot`. |
| `config` | `REDIS_URL` is used (no longer "ignored"); new `LIVE_STATE_TTL_MS` (86400000), `LIVE_INSTANCE_ID` (default `hostname:pid`, applied by `Load()` only — `Defaults()`/`FromEnv()` carry `""` so they stay host-independent, like `PUBLIC_DIR`), `SNAPSHOT_FLUSH_MS` (1000; 0 disables the writer), `LIVE_RECONCILE_MS` (30000; 0 disables the reconciler). All in `.env.example`; `TestEnvExampleIsTheDefaults` pins the two files together. |
| `metrics` | 14 new families (below); `LiveHooks() live.Hooks` for `live.WithHooks`; `BindSnapshotLag`. Catalogue test covers 49 `game_*` families and requires every exposed family to be catalogued. |
| `socket` | Presence (`SetOnline`/`SetOffline` + one heartbeat), resume offers through the store, `RestoreSeats`, `Close`. `Deps.Live`, `Deps.Instance`. The `resumeOffers` map is gone. |
| `app` | `Options.Live`; opens/wraps the store; runs the startup sequence; `/health.live`; Suspend-or-Shutdown on stop; reconciler ticker; snapshot writer lifecycle. `Restore()`, `Refund()`, `Live()` accessors for tests/tooling. |
| `cmd/gameplay` | No code change beyond the boot-sequence doc: `app.New` opens the store from the config it is passed and fails the boot when Redis is configured but unreachable. |
| `livetest` (new, test-only) | `livetest.Fake`: a self-contained `live.Store` with ttl from an injectable clock, per-op call counts (`Calls`), fault injection (`Fail`), and peeks (`Online`, `Offer`, `Tables`, `Seed`). Deliberately independent of `live.Memory` so the socket/app suites do not move when the store implementation does. |

## The exact startup order (`app.New` → `Start`)

```
metrics.New
live store        Options.Live, else live.Open(URL: REDIS_URL, Instance: LIVE_INSTANCE_ID, Timeout: 500 ms)
                  — REDIS_URL set and unreachable → New fails → process exits 1
                  wrapped once: live.WithHooks(store, metrics.LiveHooks())
users / ledger / tokens / verifier / sio.Server
db.NewSnapshotWriter(DB, {Interval: SNAPSHOT_FLUSH_MS, Metrics, Clock}); metrics.BindSnapshotLag(writer.Lag)
socket.New(Deps{Live, Instance, …})
game.NewRoomManager({Live, Instance, LiveTTL: LIVE_STATE_TTL_MS, Snapshots: writer, Durable: DB, …})
sockets.SetRooms; sockets.Attach(sio)           ← arms the presence heartbeat
metrics.BindRooms / BindPool
rooms.Restore(ctx)                               pass 1 live store; pass 2 game_states (game side); fatal if the store cannot be listed
db.RefundOrphanedPots(ctx, report.HandIDs)       open pots no restored table holds; failure logged, retried next start
sockets.RestoreSeats(rooms.RestoredSeats())      every restored seat: SetConnected(false) + grace timer
log  "restored tables=N (live=A postgres=B) seats=C reconciled=D rejected=E refunded pots=F"
rooms.StartSweeper
reconciler ticker every LIVE_RECONCILE_MS         → game_live_store_reconciles_total{result}
mux …                                            (Start opens the listener)
```

All of the restore work happens in `New`, before the listener exists, bounded by a 60 s context.

### Shutdown (`app.Shutdown`)

`sio.Close()` (each socket's disconnect marks its seat and clears its presence) → tables:
`rooms.Suspend(ctx)` when the store outlives the process (`Kind() != "memory"`: Redis, or an injected
store — a final snapshot each, clocks stopped, pots left open for the next process), else
`rooms.Shutdown(ctx)` (hands settled, pots paid: the pre-Redis behaviour and the rollback path when
`REDIS_URL` is unset) → `http.Shutdown` → `sio.Shutdown` → `sockets.Close()` (heartbeat) → reconciler
stopped → `snapshots.Flush(ctx)` + `Close()` (the last `game_states` rows land before `cmd` closes the
DB) → `live.Close()` last, **only when `New` opened the store**; an injected store belongs to its owner
(the DB convention).

## Presence and the heartbeat

- On connect (after the single-session replacement has run): `SetOnline(userID, LIVE_INSTANCE_ID, 90 s)`.
  On disconnect: `SetOffline(userID)` **only if that socket was still the account's live socket** — a
  replaced socket's disconnect must not mark the new session offline (tested).
- **One heartbeat per Handler, not one timer per socket.** `Attach` arms `Clock.AfterFunc(30 s)`; each
  tick copies the user ids out of `userSockets` under `mu`, calls `SetOnline` for each off-lock,
  serially, then re-arms. Why: the entry only has to be touched somewhere inside its 90 s window, so N
  timers firing at N scattered instants buy nothing over one pass every 30 s and cost N timer-heap
  entries and N wake-ups; one pass of 1,000 sub-millisecond round trips sits well inside the 60 s of
  slack between beat and expiry, and it is the one place a batched refresh would slot in if the store
  ever offers one. `Handler.Close()` stops it. Runs on the injected `game.Clock`, so `testclock` drives it.
- Every store call from the socket layer is bounded by a 2 s context and **never fails the player**:
  errors are logged (`presence not recorded`, `resume offer not stored`, …) and the sign-in proceeds.

## Resume offers

`graceExpired` writes `live.ResumeOffer{RoomID, Code, Category, BootAmount, At}` with
`PutResumeOffer(userID, offer, RESUME_OFFER_MS)` exactly where the map insert was (before
`rooms.Leave`); `RESUME_OFFER_MS = 0` writes nothing (Node: every offer was already stale at 0).
`onConnection` calls `TakeResumeOffer` where the map lookup was — get-and-delete, so the offer is made
once whether or not it is usable — and keeps the two live checks (table gone or full → no offer); the
store's ttl replaces the age check. A sign-in with a held seat calls `DeleteResumeOffer`. Wire shape
unchanged: `session:ready.resume` is `{roomId, code, category, bootAmount}` from the live table.

## `RestoreSeats`

`Handler.RestoreSeats([]RestoredSeat{UserID, RoomID}) int`: for each seat whose table exists and whose
index entry points there, `table.SetConnected(user, false, "")` then `holdSeat(user)` — the same two
calls `onDisconnect` makes — so the ordinary paths take over: a sign-in inside `RECONNECT_GRACE_MS`
finds the seat held (`room:joined` with the restored hand, `reconnects_total{seat_held}`), nobody
returning lets `graceExpired` leave the seat with a resume offer in the store. Seats whose account
already has a live socket (signed in between `Restore` and this call) are skipped. Adds to
`game_restored_seats_total`. Must run before the listener opens (`New` does).

## Refund semantics (`db.RefundOrphanedPots`)

Orphan = `pots.closed_at IS NULL` and `hand_id ∉ liveHandIDs`. One transaction per pot, statement order:

1. `SELECT room_id, closed_at FROM pots WHERE hand_id = $1 FOR UPDATE` — closed since the listing → nothing.
2. `SELECT user_id, -SUM(delta) FROM chip_ledger WHERE hand_id = $1 AND reason IN ('boot','bet','show') GROUP BY user_id ORDER BY user_id`.
3. Per contributor, ascending id: `SELECT chips … FOR UPDATE` (no row → skipped; the ledger rows went
   with the account), `INSERT INTO chip_ledger (… action_id '<handId>:refund:<userId>', delta +total,
   reason 'refund') ON CONFLICT (action_id) DO NOTHING` — **0 rows = already refunded, no credit**, else
   `UPDATE users SET chips = …`.
4. `UPDATE pots SET closed_at = now, winner_id = NULL`. A `hands` row, if any, is left alone.

Lock order: the pot row first (its own row; a live table's `Settle` takes a *different* pot row, after
its wallets), then wallets ascending like every ledger transaction — no cycles. The refund row and the
credit are one transaction, so `SUM(chip_ledger.delta) == users.chips` holds (tested); rerunning is a
no-op; a pot re-opened after its rows were written (the crash window) is closed again with nothing
credited twice. Report: `{Pots, Contributors, Chips, AlreadyRefunded, Skipped}`; the first per-pot
error is returned with the report, the others logged. It is the **third** recovery path — after the
live store and `game_states`.

## The durable snapshot writer (`db.SnapshotWriter`)

- `MarkDirty(roomID, seq, handID, snapshot)` and `MarkDeleted(roomID)` never block: a mutex-guarded map
  keeps **one entry per room** (newest seq wins; an equal or older seq is ignored; a delete drops a
  pending snapshot; a later mark revives a deleted room). Memory is bounded by the number of live rooms.
- One goroutine flushes every `SNAPSHOT_FLUSH_MS` as **one transaction**: a single multi-row upsert
  over `unnest($1::text[], $2::text[], $3::bigint[], $4::text[], $5::bigint[])` with `state::jsonb`,
  `ON CONFLICT (room_id) DO UPDATE … WHERE game_states.version < EXCLUDED.version` (a late flush never
  overwrites a newer row — tested with a second writer behind), then `DELETE … WHERE room_id = ANY($1)`.
  Deletes run after upserts. `Flush(ctx)` runs the same pass on demand; `Close()` stops the goroutine.
- A failed flush is logged, counted (`game_snapshot_writes_total{result="error"}`) and **merged back**
  into the pending set (a newer snapshot or a delete that arrived meanwhile wins) so the next pass
  retries; nothing is fatal — the money committed already (tested with a `CHECK (false)` outage).
- `SNAPSHOT_FLUSH_MS = 0` → a writer that drops every mark (Redis only).
- `Lag()` = age of the oldest pending snapshot → `game_snapshot_lag_seconds` and `/health.live.snapshotLagSeconds`.
- The writer stores **exactly the bytes it is handed**. `TestGameStatesNeverContainsChat` posts a
  distinctive chat line on a real `game.Table`, snapshots it, flushes, and asserts the text is absent
  from `game_states.state` and that the schema has no chat table or column.

### What is deliberately not durable

Owner's invariant 5: **chat messages are never written to PostgreSQL**. Chat, presence (`kt:online`)
and the matchmaking index live only in the live store; a room rebuilt from `game_states` comes back
with an empty chat history by design, and a dead Redis loses exactly those three things and nothing
else.

## Config keys

| Env | Default | Meaning |
|---|---|---|
| `REDIS_URL` | empty | empty = in-process store (single instance, nothing survives a restart); set → Redis, fail fast when unreachable |
| `LIVE_STATE_TTL_MS` | 86400000 | snapshot expiry in the live store for a table that stops updating |
| `LIVE_INSTANCE_ID` | `hostname:pid` (Load only) | presence/matchmaking owner tag |
| `SNAPSHOT_FLUSH_MS` | 1000 | durable writer interval; 0 disables |
| `LIVE_RECONCILE_MS` | 30000 | reconciler interval; 0 disables |

## Metrics added

`game_live_store_operations_total{op,result}` (result ∈ ok, not_found, stale, error — the two sentinels
are outcomes, not failures), `game_live_store_duration_seconds{op}` (buckets 0.0001 … 1),
`game_live_store_errors_total{op}`, `game_live_store_reconciles_total{result}`,
`game_restored_tables_total{source=live|postgres}`, `game_restored_seats_total`,
`game_restore_reconciled_total`, `game_restore_rejected_total`, `game_refunded_pots_total`,
`game_refunded_chips_total`, `game_snapshot_writes_total{result}`, `game_snapshot_write_duration_seconds`,
`game_snapshot_rows_written_total`, `game_snapshot_lag_seconds`. `op` is bounded to the 20 store method
names in snake_case (`metrics.LiveOps`) through `SafeLabel`; every other label value is a fixed constant.
`/health` gains `live: {kind, ok, tables, snapshotLagSeconds}` after `db`.

## Tests

`go test -race ./internal/socket/... ./internal/app/... ./internal/db/... ./internal/config/... ./internal/metrics/... ./internal/livetest/... ./cmd/...` — green.

- **config (+1):** `TestLiveStateKeys` (REDIS_URL honoured, TTL parsing/empty/malformed, instance id default only through `Load`, explicit wins); rows for the four new keys in `TestEveryKey`; `.env.example` parity.
- **metrics (+3):** catalogue (49), `TestCatalogueCoversEveryGameFamily`, `TestLiveHooksFeedTheLiveStoreMetrics` (op/result classification incl. wrapped sentinels, unknown op → other, buckets, nil receiver, plugs into `live.WithHooks`), `TestSnapshotLagGaugeReadsTheBoundSource`.
- **db (+4 refund, +8 writer):** refund exactly once / rerun no-op / reconcile; live and settled pots untouched; per-contributor idempotency across a re-opened pot; no-op on nothing. Writer: coalescing + newest seq, version guard (older and equal refused, newer accepted), 200 rooms in one flush, delete-vs-dirty in both orders + revive, ticker + shutdown flush + disabled writer, outage → kept batch → recovery with newer/delete winning, `LoadSnapshots`/`HandContributions` round trip, `TestGameStatesNeverContainsChat`. Existing ledger tests lost their `game_states` assertions and the `stale_state` test; they now assert the table is never written by a money transaction.
- **socket (+7):** presence follows the live socket (replacement does not clear it), heartbeat refreshes every live account and stops on `Close` (fake clock), store failures never break sign-in, lapsed-seat offer kept in the store and taken once (+ a seated sign-in deletes a stale offer), `RESUME_OFFER_MS=0` writes nothing, `RestoreSeats` → reconnect inside grace lands at the table with the hand / no reconnect → lapse → offer → `session:ready.resume`, `RestoreSeats` skips what it cannot hold. The 62 pre-existing tests run unchanged on the fake store.
- **app (+5):** `/health` shape with `live`; `TestLiveOpenFailsFastWhenRedisIsUnreachable`; `TestRestartRestoresTablesHoldsSeatsAndRefundsOrphanedPots` (process 1 mid-hand + an orphan pot → Suspend → process 2 on the same store: 1 table/2 seats restored, orphan refunded and the live pot untouched, `SUM(delta)==chips`, `/health.live.tables == 1`, Alice back in `betting`, Bob lapses into an offer); `TestShutdownWithMemoryStoreSettlesTheTables`; `TestRestartWithEmptyLiveStoreRestoresFromGameStates` (empty live store + `game_states` row → table rebuilt from postgres, written back into the store, pot == ledger total).

## Seams to the game engineer's API (`internal/app/durable.go`)

All resolved against the landed game package: `RoomManagerOptions.Snapshots` ← `*db.SnapshotWriter`
and `.Durable` ← `*db.DB` (both left nil without a database — a nil pointer inside a non-nil interface
would not be the no-op the game package promises); `rooms.ReconcileLive(ctx) ReconcileReport` is what
the ticker calls (`!Healthy` or `Errors > 0` → `result="error"`); `RestoreReport.FromLive /
FromDurable / Reconciled / Rejected` feed `game_restored_tables_total{source}`,
`game_restore_reconciled_total`, `game_restore_rejected_total` and the summary line.
`durableRestoreWired` is `true`, so `TestRestartWithEmptyLiveStoreRestoresFromGameStates` runs: process 1
plays a hand and is suspended (the writer's final flush lands the `game_states` row), process 2 boots on an
EMPTY live store, rebuilds the table from `game_states`, writes it back into the store, refunds nothing,
and the restored pot equals the ledger's total for the hand.

## Integrator notes

- `socket.New` defaults `Deps.Live` to `live.NewMemory()`; the app passes the one hooked store to both
  the Handler and the RoomManager (presence/offers and tables share the Redis instance).
- `MetricsHooks.ObserveLiveError` is left nil on purpose: the `WithHooks` wrapper already counts every
  failed store call, and feeding both would double `game_live_store_errors_total`.
- `Table.Suspend`/`RoomManager.Suspend` only make sense with a store that outlives the process; the app
  decides by `store.Kind() != "memory"`. Unset `REDIS_URL` → memory → destroy/settle on stop, exactly
  the pre-Redis behaviour (tested).
- The db test for the writer's outage path uses `ALTER TABLE … ADD CONSTRAINT … CHECK (false) NOT VALID`
  rather than renaming the table: with `search_path = <test schema>, public` a renamed table makes
  the query fall through to `public.game_states` on the shared dev database (it did once; the two rows
  were removed).
- `internal/live/store.go` is flagged by `gofmt -l` (one alignment line, the shared contract, left as is
  per `live.md`).
