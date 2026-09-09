# PORT_NOTES — the platform side of the live-state store

Owner scope: `internal/socket/*`, `internal/app/*`, `internal/db/*`, `internal/config/*`,
`internal/metrics/*`, `cmd/gameplay/*`, `.env.example`, plus the test-only package
`internal/livetest`. Architecture: `../LIVE_STATE_PLAN.md` (authoritative). The store itself is
`internal/live` (`live.md`); the table/RoomManager side is `live-game.md`.

> **Superseded, 9 Sep 2026.** An earlier revision of this file described a durable backstop —
> `db.SnapshotWriter`, `game_states`, `SNAPSHOT_FLUSH_MS`, four `game_snapshot_*` metrics,
> `/health.live.snapshotLagSeconds`, `game_restored_tables_total{source}` and Restore's second pass.
> The owner then decided that **PostgreSQL must hold no game state at all** and that **a bet must
> not be a PostgreSQL transaction**. All of that is **deleted**: `internal/db/snapshots.go` is gone,
> `game_states` is dropped from `schema.sql`, the config key is gone, the metrics are gone, and
> `/health.live` is `{kind, ok, tables}`. What survives is the live store, the refund, and the
> money model below.

## What changed

| Package | Change |
|---|---|
| `db/ledger.go` | The `game_states` upsert (`saveState`, Node's `stale_state` guard) is gone; `stale_state` can no longer be produced by the db layer. `Bet` is **replaced by `FlushBets`** (one transaction banking one player's accumulated bets, `metrics.OpBet`), and `Settle` banks each entry's outstanding `Bets` inline before the settlement row and adds what it banked to the delta. `bankBets` is the shared helper: `INSERT … ON CONFLICT (action_id) DO NOTHING`, skip the debit and the pot update when the row is already there, re-mint the id when it collides with another hand's row. A money transaction touches only `users`, `pots`, `chip_ledger` (+ `hands` on settle). |
| `db/schema.sql` | `game_states` is **removed**: never created, and dropped on an existing database by a guarded `DO` block that fires only when the table exists AND is empty (this file runs on every boot, so an unguarded DROP would be a hazard the day an old backup were restored; a non-empty table is left for a human). The schema is `users`, `chip_ledger`, `pots`, `hands` — money and audit only. |
| `db/refund.go` | `RefundOrphanedPots(ctx, liveHandIDs) (RefundReport, error)` — startup step 3 / last-resort recovery. `LedgerReasonRefund = "refund"`, `RefundActionID(handID, userID) = "<handId>:refund:<userId>"`. |
| `config` | `REDIS_URL` is used (no longer "ignored"); new `LIVE_STATE_TTL_MS` (86400000), `LIVE_INSTANCE_ID` (default `hostname:pid`, applied by `Load()` only — `Defaults()`/`FromEnv()` carry `""` so they stay host-independent, like `PUBLIC_DIR`), `LIVE_RECONCILE_MS` (30000; 0 disables the reconciler). All in `.env.example`; `TestEnvExampleIsTheDefaults` pins the two files together. |
| `metrics` | 8 new families (below); `LiveHooks() live.Hooks` for `live.WithHooks`. Catalogue test covers 43 `game_*` families and requires every exposed family to be catalogued. |
| `socket` | Presence (`SetOnline`/`SetOffline` + one heartbeat), resume offers through the store, `RestoreSeats`, `Close`. `Deps.Live`, `Deps.Instance`. The `resumeOffers` map is gone. |
| `app` | `Options.Live`; opens/wraps the store; runs the startup sequence; `/health.live` = `{kind, ok, tables}`; Suspend-or-Shutdown on stop; reconciler ticker. `Restore()`, `Refund()`, `Live()` accessors for tests/tooling. |
| `cmd/gameplay` | No code change beyond the boot-sequence doc: `app.New` opens the store from the config it is passed and fails the boot when Redis is configured but unreachable. |
| `livetest` (new, test-only) | `livetest.Fake`: a self-contained `live.Store` with ttl from an injectable clock, per-op call counts (`Calls`), fault injection (`Fail`), and peeks (`Online`, `Offer`, `Tables`, `Seed`). Deliberately independent of `live.Memory` so the socket/app suites do not move when the store implementation does. |

## The exact startup order (`app.New` → `Start`)

```
metrics.New
live store        Options.Live, else live.Open(URL: REDIS_URL, Instance: LIVE_INSTANCE_ID, Timeout: 500 ms)
                  — REDIS_URL set and unreachable → New fails → process exits 1
                  wrapped once: live.WithHooks(store, metrics.LiveHooks())
users / ledger / tokens / verifier / sio.Server
socket.New(Deps{Live, Instance, …})
game.NewRoomManager({Live, Instance, LiveTTL: LIVE_STATE_TTL_MS, …})
sockets.SetRooms; sockets.Attach(sio)           ← arms the presence heartbeat
metrics.BindRooms / BindPool
rooms.Restore(ctx)                               the live store, the only source; fatal if it cannot be listed
db.RefundOrphanedPots(ctx, report.HandIDs)       open pots no restored table holds; failure logged, retried next start
sockets.RestoreSeats(rooms.RestoredSeats())      every restored seat: SetConnected(false) + grace timer
log  "restored tables=N seats=C refunded pots=F"
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
stopped → `live.Close()` last, **only when `New` opened the store**; an injected store belongs to its
owner (the DB convention).

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
live store.

## The money model (`db/ledger.go`)

PostgreSQL is written at exactly three moments per hand and never per bet (owner, 9 Sep 2026):

| Moment | Call | Scope |
|---|---|---|
| hand start | `CollectBoot` — wallets debited, `pots` row opened, one `boot` row each | everyone in the hand |
| a player leaves / switches mid-hand | `FlushBets` — that player's bets in order, wallet debit, `pots.amount +=` | that one player |
| hand end | `Settle` — everyone else's bets, then the settlement rows, the `hands` row, the pot closed, ONE transaction | everyone still in |

`bankBets(ctx, tx, userID, handID, chips, bets, at)` is shared by the last two. Per bet, against a
wallet row the transaction already holds locked:

1. `balance = chips - amount`; **`balance < 0` → `insufficient_chips`**, refused rather than left to
   abort the transaction on the `users.chips >= 0` CHECK. It cannot happen in practice: the seat can
   only have staked chips the wallet held (boot debited up front, seat only decreases, one seat per
   player), so this is a tripwire, not a clamp.
2. `INSERT INTO chip_ledger … ON CONFLICT (action_id) DO NOTHING`. **0 rows** → look up the existing
   row's `hand_id`: the same hand means it is already banked (a settle retry, or a flush whose
   `flushed` marker was lost with Redis) — skip the debit and the pot update; a **different** hand
   means a client reused its own id, so the row is written under a fresh `util.UUID()` and the chips
   are banked after all. The pot must never hold chips no ledger row accounts for.
3. `chips = balance`, `banked += amount`.

Afterwards one `UPDATE users SET chips` and one `UPDATE pots SET amount = amount + banked`.
`FlushBets` returns `{Balance, Persisted: banked}`; `Settle` adds `banked` to that entry's `Delta`
before writing the settlement row, so the row is exactly what the per-bet model produced (+pot for
the winner, 0 for a fully-banked loser) and `SUM(chip_ledger.delta) == users.chips` holds.

`Settle` keeps its wallet-lock-order deviation from ledger.js (every wallet locked ascending before
the `hands` insert, whose `winner_id` FK would otherwise take an out-of-order KEY SHARE lock).

### What is deliberately not durable

**Nothing about a table is.** Chat, presence, the matchmaking index, the hand in progress and every
bet made inside it live only in the live store. Losing it loses the tables; the boots are still in
PostgreSQL and `RefundOrphanedPots` returns them, so no chip is created or destroyed.

## Config keys

| Env | Default | Meaning |
|---|---|---|
| `REDIS_URL` | empty | empty = in-process store (single instance, nothing survives a restart); set → Redis, fail fast when unreachable |
| `LIVE_STATE_TTL_MS` | 86400000 | snapshot expiry in the live store for a table that stops updating |
| `LIVE_INSTANCE_ID` | `hostname:pid` (Load only) | presence/matchmaking owner tag |
| `LIVE_RECONCILE_MS` | 30000 | reconciler interval; 0 disables |

## Metrics added

`game_live_store_operations_total{op,result}` (result ∈ ok, not_found, stale, error — the two sentinels
are outcomes, not failures), `game_live_store_duration_seconds{op}` (buckets 0.0001 … 1),
`game_live_store_errors_total{op}`, `game_live_store_reconciles_total{result}`,
`game_restored_tables_total` (**no labels**: the live store is the only source),
`game_restored_seats_total`, `game_refunded_pots_total`, `game_refunded_chips_total`. `op` is bounded
to the 20 store method names in snake_case (`metrics.LiveOps`) through `SafeLabel`; every other label
value is a fixed constant. `/health` gains `live: {kind, ok, tables}` after `db`.
`game_db_transaction_duration_seconds{op="bet"}` now times the transaction that BANKS a departing
player's bets, not one per bet.

## Tests

`go test -race ./internal/socket/... ./internal/app/... ./internal/db/... ./internal/config/... ./internal/metrics/... ./internal/livetest/... ./cmd/...` — green.

- **config (+1):** `TestLiveStateKeys` (REDIS_URL honoured, TTL parsing/empty/malformed, instance id default only through `Load`, explicit wins); rows for the four new keys in `TestEveryKey`; `.env.example` parity.
- **metrics (+3):** catalogue (49), `TestCatalogueCoversEveryGameFamily`, `TestLiveHooksFeedTheLiveStoreMetrics` (op/result classification incl. wrapped sentinels, unknown op → other, buckets, nil receiver, plugs into `live.WithHooks`), `TestSnapshotLagGaugeReadsTheBoundSource`.
- **db (+4 refund, +3 money model):** refund exactly once / rerun no-op / reconcile; live and settled pots untouched; per-contributor idempotency across a re-opened pot; no-op on nothing. Money model: **TestBankingTheSameBetTwiceChargesNobodyTwice** (the repeat banks 0, no second row, wallet and pot unmoved), **TestAnActionIDReusedInAnotherHandIsStillBanked** (a fresh id, the chips banked, the pot exact), **TestAPlayerWhoLeavesMidHandIsBankedOnceNotTwice** (flush then settle re-sending the same bets → exactly one row per bet, one charge, pot == banked). `internal/db/snapshots.go` and its 8 writer tests are deleted; the ledger tests lost their `game_states` assertions and the `stale_state` test.
- **socket (+7):** presence follows the live socket (replacement does not clear it), heartbeat refreshes every live account and stops on `Close` (fake clock), store failures never break sign-in, lapsed-seat offer kept in the store and taken once (+ a seated sign-in deletes a stale offer), `RESUME_OFFER_MS=0` writes nothing, `RestoreSeats` → reconnect inside grace lands at the table with the hand / no reconnect → lapse → offer → `session:ready.resume`, `RestoreSeats` skips what it cannot hold. The 62 pre-existing tests run unchanged on the fake store.
- **app (+5):** `/health` shape with `live` = `{kind, ok, tables}`; `TestLiveOpenFailsFastWhenRedisIsUnreachable`; `TestRestartRestoresTablesHoldsSeatsAndRefundsOrphanedPots` (process 1 mid-hand + an orphan pot → Suspend → process 2 on the same store: 1 table/2 seats restored, orphan refunded and the live pot untouched, `SUM(delta)==chips`, `/health.live.tables == 1`, Alice back in `betting`, Bob lapses into an offer); `TestShutdownWithMemoryStoreSettlesTheTables`; **TestRestartWithEmptyLiveStoreLosesTheTablesAndRefundsThePots** (empty live store → 0 tables, 0 seats, the pot refunded, every wallet back to boot-in-hand and equal to its ledger, and the players deal a fresh hand); **TestPostgresHoldsNoGameState** (the schema has no `game_states` table after a hand is played).

## Seams to the game engineer's API (`internal/app/live.go`)

`internal/app/durable.go` is gone (renamed `live.go`, carrying only `reconcileLive`).
`RoomManagerOptions.Snapshots` / `.Durable`, `wireDurable`, `durableRestoreWired` and
`restoreBreakdown` are deleted with the second restore pass. `rooms.ReconcileLive(ctx)
ReconcileReport` is what the ticker calls (`!Healthy` or `Errors > 0` → `result="error"`);
`RestoreReport.Tables/Seats` feed `game_restored_tables_total` (unlabelled) and
`game_restored_seats_total` and the summary line.

## Integrator notes

- `socket.New` defaults `Deps.Live` to `live.NewMemory()`; the app passes the one hooked store to both
  the Handler and the RoomManager (presence/offers and tables share the Redis instance).
- `MetricsHooks.ObserveLiveError` is left nil on purpose: the `WithHooks` wrapper already counts every
  failed store call, and feeding both would double `game_live_store_errors_total`.
- `Table.Suspend`/`RoomManager.Suspend` only make sense with a store that outlives the process; the app
  decides by `store.Kind() != "memory"`. Unset `REDIS_URL` → memory → destroy/settle on stop, exactly
  the pre-Redis behaviour (tested).
- A `search_path = <test schema>, public` trap worth remembering: a query naming a table the test
  schema does not have falls through to `public`, so a db test that expects a table to be MISSING
  must ask `pg_tables WHERE schemaname = current_schema()`, never `SELECT … FROM game_states`.
- `internal/live/store.go` is flagged by `gofmt -l` (one alignment line, the shared contract, left as is
  per `live.md`).
