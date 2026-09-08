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
| `game_states` written synchronously inside the money transaction | `game_states` written **asynchronously, outside it**, by a batching writer — the durable backstop Redis is reconstructed from (§ below) |

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
transaction** (where it cost every move an extra JSONB write) into a background writer.

```
   move → PostgreSQL money transaction (users, pots, chip_ledger, hands)   ← durable, synchronous
        → Redis  SaveTable                                                 ← fast, after the commit
        → mark the table dirty
                     ↓  every SNAPSHOT_FLUSH_MS, one batched transaction
          PostgreSQL game_states (room_id, hand_id, version, state)         ← durable, asynchronous
```

### The writer (`internal/db/snapshots.go`)

`SnapshotWriter` with `MarkDirty(roomID, seq, handID, snapshot []byte)` — non-blocking, keeps only
the newest snapshot per room. One goroutine flushes the dirty set every `SNAPSHOT_FLUSH_MS`
(default 1000) as **one** multi-row upsert guarded by `version < EXCLUDED.version`, so a late
flush can never overwrite a newer state. `MarkDeleted(roomID)` batches the delete on destroy.
`Flush(ctx)` runs on graceful shutdown. One transaction per second for all tables costs a single
fsync, against one per move before.

### Three recovery paths, in precedence order

| Situation | What happens |
|---|---|
| **Redis dies, server keeps running** | Saves fail, are counted (`game_live_store_errors_total`) and logged; play continues from memory, because memory is the live truth while the process is up. A reconciler ticker (`LIVE_RECONCILE_MS`, default 30000) pings the store; on the transition back to healthy it **re-saves every live table, re-publishes the lobby index and every seat**, so a Redis that came back empty is refilled without waiting for each table's next move. The same ticker heals a `FLUSHALL` or an eviction. |
| **Redis and the server both die (Redis empty on restart)** | Startup restores in order: (1) `live.ListTables` — the freshest copy; (2) for every room in `game_states` that Redis did not have, load the snapshot, **reconcile it against the ledger**, rebuild the table, and write it straight back into Redis; (3) any open pot with no table after both passes is refunded. |
| **Both stores lost the room** | The pot is returned to whoever paid into it (`RefundOrphanedPots`), one idempotent ledger row each. Nobody loses chips; only the hand is lost. |

### Reconciling a stale snapshot against the ledger

The asynchronous snapshot can be up to `SNAPSHOT_FLUSH_MS` behind the money. The ledger is never
behind, so the ledger wins. Before rebuilding a table from `game_states`:

```sql
SELECT user_id, -SUM(delta) AS contributed
FROM chip_ledger
WHERE hand_id = $1 AND reason IN ('boot','bet','show')
GROUP BY user_id;
```

- Each seat's `contributed` and `persisted` are set from that result, and the hand's `pot` to its
  total. Cards, seat order, blind/seen status and who has packed come from the snapshot: none of
  them can change without a chip moving, so a snapshot that is only missing the last bet still has
  them right.
- If the ledger shows a contribution from a seat the snapshot has as `packed` or absent, the
  snapshot is too old to trust: that room is skipped and its pot refunded.
- **Invariant (tested):** after any restore, `table.hand.pot` equals the ledger's total for that
  hand, and every seat's `contributed` equals its ledger total.

### Configuration

| Env | Default | Meaning |
|---|---|---|
| `SNAPSHOT_FLUSH_MS` | 1000 | How often the durable snapshot writer flushes its dirty set. 0 disables it (Redis-only; a Redis loss then loses tables). |
| `LIVE_RECONCILE_MS` | 30000 | How often the live store is pinged and, after an outage, refilled from memory. |

### Metrics

`game_snapshot_writes_total{result}`, `game_snapshot_write_duration_seconds`, `game_snapshot_rows_written_total`, `game_snapshot_lag_seconds` (oldest dirty table), `game_live_store_reconciles_total{result}`, `game_restored_tables_total{source=live|postgres}`, `game_restore_reconciled_total` (snapshots the ledger corrected), `game_restore_rejected_total` (too stale, refunded instead).
