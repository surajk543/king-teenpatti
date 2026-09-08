# Live state plan — Redis beside PostgreSQL

Target architecture (owner's diagram, 9 Sep 2026):

```
                 Internet
                    │
            ┌───────▼───────┐
            │   Go server   │  game engine · websocket
            └───┬───────┬───┘
                │       │
        ┌───────▼──┐  ┌─▼────────────┐
        │  Redis   │  │  PostgreSQL  │
        │ live state│  │ users        │
        │ presence  │  │ wallets      │
        │ deadlines │  │ chip_ledger  │
        │ matchmaking│ │ hands, audit │
        └──────────┘  └──────────────┘
      FAST / TEMPORARY   DURABLE / AUTHORITATIVE
      reconstructable    never lose
```

## What moves where

| Today (single process, Postgres only) | After |
|---|---|
| `game_states` JSONB upsert inside every bet/boot/settle transaction | Snapshot saved to the live store by the table actor after every mutation; the money transaction only touches users, pots, chip_ledger, hands |
| `stale_state` guard = `game_states.version` | CAS on the live store's per-table `seq` (`live.ErrStale`) |
| RoomManager `playerRooms` in memory only | Mirrored to the live store (`SetSeated`/`ClearSeated`) |
| `resumeOffers` map in the socket handler | Live store with TTL (`PutResumeOffer`/`TakeResumeOffer`), survives restarts |
| Timers only in process | Deadlines are in the snapshot (turn, sideshow, next hand); a restarted process re-arms them |
| Lobby selection in memory | Still in memory for one instance; every change is published to the index so a restart (or later a second instance) can read it |
| Chat buffer in memory | Mirrored to the live store (capped list) so it survives a restart with the table. **Never written to PostgreSQL** — if the live store is lost the chat is lost with it, by design |
| Restart = every table and pot lost | Restart = tables rebuilt from the live store, seats held for `RECONNECT_GRACE_MS`, timers re-armed; orphaned open pots (no live table) refunded from the ledger |
| `game_states` written synchronously inside the money transaction | `game_states` written **asynchronously, outside it, and only at the two hand boundaries** by a batching writer — the durable backstop Redis is reconstructed from (§ below) |

## Invariants that must hold

1. **Money never depends on Redis.** A move is accepted only after its Postgres transaction commits; the live-store save comes after and a failure there is logged (metric `game_live_store_errors_total`), never turned into a refused move.
2. **`SUM(chip_ledger.delta) == users.chips`** as before. The new refund path writes ordinary ledger rows (reason `refund`, action id `<handId>:refund:<userId>`, idempotent) and closes the pot.
3. **No wire change.** Clients see the same events, acks and REST bodies. The one visible difference: after a server restart within the grace period, players are back at their table instead of the lobby.
4. **Snapshot ⇄ table round trip is lossless** for everything gameplay needs: `RestoreTable(snapshot)` followed by `Snapshot()` yields an equal snapshot (property test), and `SerializeFor` on the restored table equals the original for every viewer.
5. **Chat never reaches PostgreSQL.** Chat is the one thing that is allowed to disappear. It
   lives only in the table's memory and, mirrored, in the live store's capped list; it is not in
   `Snapshot` (which carries the chat *limits* from the config, never a message) and there is no
   chat table in the schema. A room rebuilt from `game_states` therefore comes back with an empty
   chat history, and that is the intended behaviour, not a bug. Pinned by a test that posts
   messages and then asserts the durable snapshot bytes contain none of them.
6. **A stale process cannot write.** If `SaveTable` returns `ErrStale` the table marks itself `fenced`: it stops accepting moves (`table_destroyed` to callers), emits an error event, and RoomManager destroys it. This is the two-owners guard that `game_states.version` used to be.

## Sequence on startup (`app.New` → `Start`)

1. `live.Open` (Redis when `REDIS_URL` set, memory otherwise; fail fast if Redis is unreachable).
2. `rooms.Restore(ctx)`: `ListTables` → for each `LoadTable` → `game.RestoreTable(snapshot, opts)` → register in maps (`playerRooms` from seats) → `PublishTable`. Tables whose snapshot fails to parse are deleted from the store and reported.
3. `db.RefundOrphanedPots(ctx, liveHandIDs)`: every `pots` row with `closed_at IS NULL` whose `hand_id` is not held by a restored table gets each contributor's boot/bet/show total returned (one ledger row per contributor) and the pot closed with `winner_id NULL`. Logged and counted (`game_refunded_pots_total`).
4. `handler.RestoreSeats(rooms)`: for every restored seat, mark disconnected and arm the reconnect grace timer exactly as a drop would; when the player reconnects, `session:ready` → `room:joined` as today.
5. Restored tables re-arm their own timers inside `RestoreTable`: turn deadline in the past → the pack fires on the first actor turn; sideshow past its expiry → lapses; `starting` → `startsAt` (or now).
6. Then the sweeper starts and the listener opens.

## Key schema (prefix `kt:`; tests use a random prefix)

| Key | Type | Content |
|---|---|---|
| `kt:table:<roomId>` | hash | `seq`, `snapshot` (JSON), `handId`, `updatedAt` — TTL 24 h refreshed on save |
| `kt:tables` | set | room ids with a stored snapshot |
| `kt:chat:<roomId>` | list | serialised chat messages, capped at `CHAT_MAX_HISTORY` |
| `kt:seat:<userId>` | string | roomId |
| `kt:online` | hash | userId → `instance\|epochMs`, entries refreshed every 30 s, considered dead after 90 s |
| `kt:resume:<userId>` | string | ResumeOffer JSON, TTL `RESUME_OFFER_MS` |
| `kt:lobby:<category>:<boot>` | zset | roomId scored by players (fullest first), private tables never indexed |
| `kt:summary:<roomId>` | hash | TableSummary fields |

`SaveTable` and `TakeResumeOffer` are Lua scripts (compare-and-set; get-and-delete) so they are atomic under concurrency.

## Configuration

| Env | Default | Meaning |
|---|---|---|
| `REDIS_URL` | empty | empty = in-process live store (single instance, nothing survives a restart); `redis://127.0.0.1:6379/0` in production |
| `LIVE_STATE_TTL_MS` | 86400000 | snapshot expiry for a table that stops updating |
| `LIVE_INSTANCE_ID` | hostname:pid | presence/matchmaking owner tag |

## Metrics

`game_live_store_operations_total{op,result}`, `game_live_store_duration_seconds{op}` (buckets 0.1 ms … 1 s), `game_restored_tables_total`, `game_restored_seats_total`, `game_refunded_pots_total`, `game_live_store_errors_total{op}`. `/health.live` = `{kind, ok, tables}`.

## Ops

- `ops/install-redis.sh` (sudo): `apt install redis-server`, bind 127.0.0.1, `maxmemory 512mb`, `maxmemory-policy noeviction` (we never want the store to drop a table silently; it is small), RDB `save 60 100` (reconstructable — a minute of loss is acceptable), `appendonly no`, enable + start; adds `REDIS_URL` to `go-server/.env`; installs `redis_exporter` and a Prometheus job; Grafana gets a Redis row.
- `gameplay.service`: `After=redis-server.service postgresql.service`.
- Rollback: unset `REDIS_URL` → memory store, exactly the pre-Redis behaviour.

## The durable backstop: reconstructing Redis from PostgreSQL

Redis is fast and disposable, but "disposable" only holds if the live state can be rebuilt.
PostgreSQL is where it is rebuilt from, so `game_states` stays — moved **out of the money
transaction** (where it cost every move an extra JSONB write) and, since 9 Sep 2026, written only
at the two **hand boundaries** rather than on a flush interval.

```
   move → PostgreSQL money transaction (users, pots, chip_ledger, hands)   ← durable, synchronous
        → Redis  SaveTable                                                 ← fast, after the commit
        (nothing durable)

   deal      → mark the table dirty ─┐
   settlement → mark the table dirty ─┴→ every SNAPSHOT_FLUSH_MS, one batched transaction
          PostgreSQL game_states (room_id, hand_id, version, state)         ← durable, asynchronous
```

### Why hand boundaries and not a flush interval (9 Sep 2026)

Measured on production: a durable snapshot of every table once a second competed with the money for
the same saturated disk. **Committed transactions/s fell from 1,258 to 654 at 7,000 players, I/O
wait tripled to 31%, and the usable ceiling halved from 15,000 players to 7,000.** Redis was
blameless — sub-millisecond, 6 MB, no errors. The owner's decision:

> "In postgres do not save game live state, only save the state in the beginning of game, and when
> game ends. In between, game states should be saved in redis for all rooms. If redis died, then it
> will pick the state from postgres db and restart the game."

So the write policy is now:

| Moment | Redis (`SaveTable`) | PostgreSQL (`MarkDirty`) |
|---|---|---|
| any mutation (join, bet, see, pack, chat…) | yes, every one | **no** |
| **hand start** — boots collected, cards dealt, first turn open | yes | **yes** |
| **hand end** — settled, `hand == nil`, seats carrying their settled chips | yes | **yes** |
| destroy | `DeleteTable` + `DeleteChat` | `MarkDeleted` |
| suspend (graceful restart) | final `SaveTable` | no — the live copy is what comes back |

`Table.markDurable()` is called from exactly two places, both in `table.go` and both commented
there: the end of `startHand` and the end of `endHand`. `saveLive`/`flushLive` still writes to Redis
after every mutation; it hands the sink the **same bytes under the same `seq`** when, and only when,
the closure asked for it, so the durable copy always corresponds to a Redis copy and both version
guards compare the same number.

The hand-end write is the one that matters most: without it a restore from the hand-start row would
resurrect a hand that has already been paid out.

**A table that never deals writes nothing durable at all.** That is intended — nothing is at stake,
and its players simply re-join. It also means a `game_states` row only ever exists for a room that
has dealt at least one hand.

### The writer (`internal/db/snapshots.go`)

`SnapshotWriter` with `MarkDirty(roomID, seq, handID, snapshot []byte)` — non-blocking, keeps only
the newest snapshot per room. One goroutine flushes the dirty set every `SNAPSHOT_FLUSH_MS`
(default 1000) as **one** multi-row upsert guarded by `version < EXCLUDED.version`, so a late
flush can never overwrite a newer state. `MarkDeleted(roomID)` batches the delete on destroy.
`Flush(ctx)` runs on graceful shutdown. The interval is now only a batching window for the two
boundary writes, not a sampling rate: at steady state it costs roughly two rows per table per hand
instead of one per table per second.

### Three recovery paths, in precedence order

| Situation | What happens |
|---|---|
| **Redis dies, server keeps running** | Saves fail, are counted (`game_live_store_errors_total`) and logged; play continues from memory, because memory is the live truth while the process is up. A reconciler ticker (`LIVE_RECONCILE_MS`, default 30000) pings the store; on the transition back to healthy it **re-saves every live table, re-publishes the lobby index and every seat**, so a Redis that came back empty is refilled without waiting for each table's next move. The same ticker heals a `FLUSHALL` or an eviction, and sweeps stray seats and summaries (§ below). |
| **Redis and the server both die (Redis empty on restart)** | Startup restores in order: (1) `live.ListTables` — the freshest copy; (2) for every room in `game_states` that Redis did not have, load the snapshot — for a hand in progress that is the hand's **opening** state — **reconcile it against the ledger**, rebuild the table, and write it straight back into Redis; (3) any open pot with no table after both passes is refunded. |
| **Both stores lost the room** | The pot is returned to whoever paid into it (`RefundOrphanedPots`), one idempotent ledger row each. Nobody loses chips; only the hand is lost. |

### Reconciling a hand-start snapshot against the ledger

The durable snapshot of a live hand is now the hand as it was **dealt**, while the ledger has every
round of betting since. The ledger is never behind, so the ledger wins. Before rebuilding a table
from `game_states`:

```sql
SELECT user_id, -SUM(delta) AS contributed
FROM chip_ledger
WHERE hand_id = $1 AND reason IN ('boot','bet','show')
GROUP BY user_id
ORDER BY MAX(id);          -- ledger order: whoever moved last comes last
```

- Each seat's and contribution record's `contributed` and `persisted` are set from that result, the
  seat's stack is lowered by whatever the snapshot had not yet debited, `didChaal` is set once the
  figure passes the boot, and the hand's `pot` becomes the ledger total.
- **Where play resumes:** the last row in the ledger is the last chips anybody put in, so the turn
  goes to **the first seat that can still act clockwise after the last contributor, on a fresh full
  turn clock** — exactly where `advanceTurn` would have gone. The stored `turnDeadline` is dropped
  (it belongs to a turn that ended before the crash; honouring it would time the new player out the
  instant the table came back) and any pending sideshow with it. When the ledger agrees with the
  snapshot — nothing was played after it — the snapshot's own turn and deadline stand.
- **Rejected only when the money cannot be attributed**: a contributor the snapshot has neither a
  seat nor a contribution record for; a ledger figure *below* the snapshot's (a snapshot is only
  written after its transaction commits, so the ledger cannot be behind it); a snapshot contribution
  with no ledger row; a live hand with no ledger rows at all; the same player twice. A contribution
  from a seat the snapshot shows as packed, lost or gone is **no longer a rejection** — with
  hand-boundary writes that is simply what a hand that has been played looks like from its opening
  snapshot. A rejected room is skipped and its pot refunded.
- Carried over from the snapshot and not recoverable from the ledger: `hand.stake` (play resumes at
  the opening stake, so the ladder can restart low), `hand.round` (the forced-showdown count
  restarts) and who had packed (everyone the snapshot had active is asked to act again). Cards, seat
  order and blind/seen status cannot change without a chip moving, so those are right.
- **Invariant (tested):** after any restore, `table.hand.pot` equals the ledger's total for that
  hand, and every seat's `contributed` equals its ledger total.

### The reconciler also sweeps strays

`kt:seat:<userId>` carries **no ttl** — it is cleared by whoever wrote it — so any departure that
missed a `ClearSeated` leaked one for good. Production, 9 Sep 2026, with zero players and zero
tables: 4,715 seat keys and 141 summary hashes still in Redis. `RoomManager.ReconcileLive` therefore
does a second pass after the refill (`sweepStrays`), on the same `LIVE_RECONCILE_MS` tick:

- `live.ListSeats` (SCAN `kt:seat:*` + MGET) → `ClearSeated` every user this manager does not have
  in `playerRooms`;
- `live.ListSummaries` (SCAN `kt:summary:*` + HGETALL) → `RetireTable` every room it does not have
  registered, which takes the lobby-bucket entry with it.

Counted in `ReconcileReport.StaleSeats` / `StaleSummaries` and logged as `live store strays removed`.
This process owns every table in the store (there is no instance filter yet), so an entry naming
something it does not have is by definition finished with. A missed deletion now costs one tick,
not one permanent key.

### Configuration

| Env | Default | Meaning |
|---|---|---|
| `SNAPSHOT_FLUSH_MS` | 1000 | How often the durable snapshot writer flushes its dirty set — a batching window for the two hand-boundary writes, not a sampling rate. 0 disables it (Redis-only; a Redis loss then loses tables). |
| `LIVE_RECONCILE_MS` | 30000 | How often the live store is pinged, refilled from memory after an outage, and swept for strays. |

### Metrics

`game_snapshot_writes_total{result}`, `game_snapshot_write_duration_seconds`, `game_snapshot_rows_written_total`, `game_snapshot_lag_seconds` (oldest dirty table), `game_live_store_reconciles_total{result}`, `game_restored_tables_total{source=live|postgres}`, `game_restore_reconciled_total` (snapshots the ledger corrected), `game_restore_rejected_total` (unattributable, refunded instead). The live-store op labels gain `list_seats` and `list_summaries`.
