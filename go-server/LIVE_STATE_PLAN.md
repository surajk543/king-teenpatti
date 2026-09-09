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
        │ ALL game  │  │ users        │
        │   state   │  │ wallets      │
        │ presence  │  │ chip_ledger  │
        │ deadlines │  │ pots         │
        │matchmaking│  │ hands, audit │
        └──────────┘  └──────────────┘
      THE ONLY COPY      MONEY AND AUDIT ONLY
      lose it → rejoin   never lose
```

**Owner's decision, 9 Sep 2026 — this is the whole design:**

> "1. In postgres do not maintain any game state. All game state should be maintained in redis only.
> Suppose redis died, all players will need to rejoin the table again, no need to construct the game
> state."
>
> "2. bet in between do not update in pg db, only update in redis."
>
> "3. Do not update pg database in bet chaal or show, just update in redis. Only update in pg when
> game starts and game ends. And in case of switch table or leave table, only update in pg for that
> player who left the table or switched the table."
>
> "4. do not store any game state info in pg database … so check pg schema again."

So: **Redis holds all game state; PostgreSQL holds money and audit only** (`users`, `chip_ledger`,
`pots`, `hands` — the `game_states` table is gone from the schema). A Redis loss loses the tables:
players re-join, and the one thing that must still happen is the money safety net — every `pots` row
left open with no live table is refunded to its contributors (`RefundOrphanedPots`).

## What moves where

| Today (single process, Postgres only) | After |
|---|---|
| `game_states` JSONB upsert inside every bet/boot/settle transaction | Snapshot saved to the live store by the table actor after every mutation; `game_states` is dropped from the schema and PostgreSQL sees no game state at all |
| `stale_state` guard = `game_states.version` | CAS on the live store's per-table `seq` (`live.ErrStale`) |
| RoomManager `playerRooms` in memory only | Mirrored to the live store (`SetSeated`/`ClearSeated`) |
| `resumeOffers` map in the socket handler | Live store with TTL (`PutResumeOffer`/`TakeResumeOffer`), survives restarts |
| Timers only in process | Deadlines are in the snapshot (turn, sideshow, next hand); a restarted process re-arms them |
| Lobby selection in memory | Still in memory for one instance; every change is published to the index so a restart (or later a second instance) can read it |
| Chat buffer in memory | Mirrored to the live store (capped list) so it survives a restart with the table. **Never written to PostgreSQL** — if the live store is lost the chat is lost with it, by design |
| Restart = every table and pot lost | Restart = tables rebuilt from the live store, seats held for `RECONNECT_GRACE_MS`, timers re-armed; orphaned open pots (no live table) refunded from the ledger |
| One money transaction per bet | **No** money transaction per bet: PostgreSQL is written at the deal (boots), when a player leaves the hand (their bets), and at the settlement (everyone else's bets plus the payout) — §The money model below |
| Restart with an empty Redis = rooms rebuilt from `game_states` | Restart with an empty Redis = **nothing is rebuilt**; players re-join and every open pot is refunded |

## Invariants that must hold

1. **Money never depends on Redis.** A move is accepted only after its Postgres transaction commits; the live-store save comes after and a failure there is logged (metric `game_live_store_errors_total`), never turned into a refused move.
2. **`SUM(chip_ledger.delta) == users.chips`** as before. The new refund path writes ordinary ledger rows (reason `refund`, action id `<handId>:refund:<userId>`, idempotent) and closes the pot.
3. **No wire change.** Clients see the same events, acks and REST bodies. The one visible difference: after a server restart within the grace period, players are back at their table instead of the lobby.
4. **Snapshot ⇄ table round trip is lossless** for everything gameplay needs: `RestoreTable(snapshot)` followed by `Snapshot()` yields an equal snapshot (property test), and `SerializeFor` on the restored table equals the original for every viewer.
5. **Chat never reaches PostgreSQL.** Chat is the one thing that is allowed to disappear. It
   lives only in the table's memory and, mirrored, in the live store's capped list; it is not in
   `Snapshot` (which carries the chat *limits* from the config, never a message) and there is no
   chat table in the schema. Chat goes with the live store when the live store is lost, and that is
   the intended behaviour, not a bug. It is the general case of the rule now: **nothing about a
   table is ever written to PostgreSQL**, chat least of all.
6. **A stale process cannot write.** If `SaveTable` returns `ErrStale` the table marks itself `fenced`: it stops accepting moves (`table_destroyed` to callers), emits an error event, and RoomManager destroys it. This is the two-owners guard that `game_states.version` used to be.
7. **A bet is not durable until the hand ends.** That is the one guarantee this design gives up, deliberately: a bet lives in memory and in Redis until the hand settles or its player leaves. Losing Redis un-makes those bets — the players keep the chips, PostgreSQL still holds the boots, and the refund returns them. Nothing is created or destroyed in any failure mode.
8. **A seat can never hold more than its wallet.** The boot is debited from the wallet at the deal, the seat only decreases from there as it bets, and a player holds one seat, so `wallet == seat.chips + Σ unbanked bets` throughout a hand. The in-memory balance check is therefore exactly the wallet check the `FOR UPDATE` lock used to make, and a flush can never overdraw (`TestASeatNeverHoldsMoreThanItsAccount`, and the same invariant under random play in `TestChipConservationUnderRandomPlay`).

## Sequence on startup (`app.New` → `Start`)

1. `live.Open` (Redis when `REDIS_URL` set, memory otherwise; fail fast if Redis is unreachable).
2. `rooms.Restore(ctx)`: `ListTables` → for each `LoadTable` → `game.RestoreTable(snapshot, opts)` → register in maps (`playerRooms` from seats) → `PublishTable`. Tables whose snapshot fails to parse are deleted from the store and reported. **This is the only pass there is**: an empty live store restores nothing.
3. `db.RefundOrphanedPots(ctx, liveHandIDs)`: every `pots` row with `closed_at IS NULL` whose `hand_id` is not held by a restored table gets each contributor's boot/bet/show total returned (one ledger row per contributor) and the pot closed with `winner_id NULL`. Logged and counted (`game_refunded_pots_total`). **This is the whole safety net** — the reason a lost Redis costs nobody a chip.
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
| `REDIS_URL` | empty | empty = in-process live store (single instance, nothing survives a restart — the tables are lost and the pots refunded); `redis://127.0.0.1:6379/0` in production |
| `LIVE_STATE_TTL_MS` | 86400000 | snapshot expiry for a table that stops updating |
| `LIVE_INSTANCE_ID` | hostname:pid | presence/matchmaking owner tag |

## Metrics

`game_live_store_operations_total{op,result}`, `game_live_store_duration_seconds{op}` (buckets 0.1 ms … 1 s), `game_restored_tables_total` (**no labels** — the live store is the only source), `game_restored_seats_total`, `game_refunded_pots_total`, `game_refunded_chips_total`, `game_live_store_errors_total{op}`, `game_live_store_reconciles_total{result}`. `/health.live` = `{kind, ok, tables}`.

## Ops

- `ops/install-redis.sh` (sudo): `apt install redis-server`, bind 127.0.0.1, `maxmemory 512mb`, `maxmemory-policy noeviction` (we never want the store to drop a table silently; it is small), RDB `save 60 100` (reconstructable — a minute of loss is acceptable), `appendonly no`, enable + start; adds `REDIS_URL` to `go-server/.env`; installs `redis_exporter` and a Prometheus job; Grafana gets a Redis row.
- `gameplay.service`: `After=redis-server.service postgresql.service`.
- Rollback: unset `REDIS_URL` → memory store, exactly the pre-Redis behaviour.

## The money model: two transactions per hand, not one per bet

PostgreSQL is written at exactly these moments and no others (owner's decisions 2 and 3):

| Moment | What is written | Scope |
|---|---|---|
| **hand start** | boots debited, `pots` row opened, one `boot` ledger row each | every player in the hand |
| **a player leaves or switches mid-hand** | that player's bets so far: wallet debit + their `bet`/`show` ledger rows | that one player only |
| **hand end** | every remaining player's bets, then the settlement rows, the `hands` row, the pot closed | everyone still in the hand |
| bet / chaal / raise / show / see in between | **nothing** — memory and Redis only | — |

```
   deal     → PostgreSQL CollectBoot (users, pots, chip_ledger)     ← durable
            → Redis SaveTable
   bet      → seat + pot in memory, the bet appended to the hand's
              contribution record → Redis SaveTable                 ← THAT IS ALL
   leave    → PostgreSQL FlushBets for that player only             ← durable
            → Redis SaveTable
   settle   → PostgreSQL Settle: the outstanding bets, then the
              payout, the hands row and the pot close, ONE txn      ← durable
```

### Batched, never aggregated

A hand's betting is **not** collapsed into one net figure: the ledger is the audit of every chip
movement and requirement 16's stats hang off it. Each bet is kept on the hand's per-player
contribution record — amount, reason (`bet`/`show`), the client's `actionId`, and a `flushed` flag —
and that record is in the `Snapshot`, so the record of what is staked lives in Redis and survives a
restart. `FlushBets` and `Settle` write those bets as individual rows, in order, under the **same
action ids** the per-bet path used, so the rows are indistinguishable from the ones the old model
produced and the `chip_ledger.action_id` UNIQUE index still makes a replay impossible.

Net effect: the same ledger rows and the same `pots.amount`, from **2 transactions per hand** instead
of 2 + one per bet.

### No double-write

A player who leaves mid-hand has their bets banked at once and each is marked `flushed`, so the
settlement does not send them again. Belt to that brace: `bankBets` inserts with
`ON CONFLICT (action_id) DO NOTHING` and skips the wallet debit and the pot update when the row is
already there — which covers a settle retry, and a flush that committed before its `flushed` marker
reached Redis. If the id collides with a row from a **different** hand (a client reusing its own id)
the chips are still banked, under a fresh server-minted id, rather than dropped: the pot must never
hold chips no ledger row accounts for.

Replaying an id **within** a hand is refused in memory (`duplicate_action`, `Table.handHasActionID`),
which is where the database's UNIQUE index used to catch it.

### What each failure mode costs

| Situation | What happens |
|---|---|
| Hand plays out normally | Identical rows to the per-bet model: boot rows at the deal, one `bet`/`show` row per bet at the settlement, `hand_win`/`hand_loss` as before. |
| **Server dies mid-hand, Redis alive** | The table comes back from Redis with its bets still on the contribution records; the hand continues and settles once. The settle action ids are the guard against a double write. |
| **Redis dies mid-hand** | The hand is gone and the bets were never in PostgreSQL, so they are simply un-made: the players keep those chips. PostgreSQL holds the boots and an open pot; `RefundOrphanedPots` returns the boots. **Net zero.** |
| Server killed between the boot commit and any bet | Same as above. |
| A departed player, then Redis lost | Their flushed bets are in PostgreSQL and stay there; everyone else's are un-made; the pot is refunded. Wallets still equal their ledgers. |

All five are asserted in `tools/crashtest.mjs` and `tools/parity/money.test.js`.

## Losing Redis: the tables are gone, the chips are not

There is no reconstruction path. PostgreSQL cannot rebuild a table because it holds nothing about
one — `game_states` is not in the schema (`db/schema.sql` drops it, guarded, when it exists and is
empty, and never creates it).

| Situation | What happens |
|---|---|
| **Redis dies, server keeps running** | Saves fail, are counted (`game_live_store_errors_total`) and logged; play continues from memory, because memory is the live truth while the process is up. A reconciler ticker (`LIVE_RECONCILE_MS`, default 30000) pings the store; on the transition back to healthy it **re-saves every live table, re-publishes the lobby index and every seat**, so a Redis that came back empty is refilled without waiting for each table's next move. The same ticker heals a `FLUSHALL` or an eviction, and sweeps stray seats and summaries (§ below). |
| **Redis and the server both die (Redis empty on restart)** | Nothing is restored. `game_restored_tables_total` stays 0, every open pot is refunded, and the players re-join into fresh tables. The chat, the hands in progress and the seats are lost; not one chip is. |
| **Redis unset (`REDIS_URL` empty)** | The in-process store dies with the process, which is the same thing: a restart loses the tables and refunds the pots. |

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
| `LIVE_RECONCILE_MS` | 30000 | How often the live store is pinged, refilled from memory after an outage, and swept for strays. |

### Metrics

`game_live_store_reconciles_total{result}`, `game_restored_tables_total` (unlabelled), `game_refunded_pots_total`, `game_refunded_chips_total`. The live-store op labels include `list_seats` and `list_summaries`. `game_db_transaction_duration_seconds{op="bet"}` now times the transaction that BANKS a player's bets (a departure), not one per bet.
