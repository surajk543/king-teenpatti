# Spec: database layer, ledger transactions and user store

Behavioural specification of the Node server's `server/src/db/` directory as it exists in the
working tree on 2026‑09‑08. Everything a Go port must reproduce so that the **database contents**
(rows, values, ordering, idempotency keys) and the **JSON the user store returns to callers** are
indistinguishable from the Node server's.

Source files (all paths relative to `/home/suraj/Project/king-teenpatti/server/`):

| File | Role | Lines |
|---|---|---|
| `src/db/index.js` | pool, schema bootstrap, `query`, `withTransaction`, `dropSchema`, `closeDatabase` | 1–123 |
| `src/db/schema.sql` | DDL (idempotent) | 1–128 |
| `src/db/ledger.js` | `bet`, `collectBoot`, `settle`, `LedgerError`, `createLedger` | 1–332 |
| `src/db/users.js` | login upsert, `findById`, rewards, names, avatars, `applyChipDelta`, `recentHands` | 1–345 |
| `src/config/index.js` | `config.db.*`, `config.game.welcomeChips`, `config.game.displayNameMaxLength` | 60–74, 77, 137 |
| `src/util/ids.js` | `uuid()` = `crypto.randomUUID()` | 1–3 |
| `src/metrics/index.js` | `timed`, `safeLabel`, the four ledger histograms/counters | 264–290, 368–382 |
| Callers | `src/game/table.js` (ledger consumer), `src/auth/routes.js` (users consumer), `src/socket/index.js` (findById), `src/auth/providers.js` (profile shape fed to upsert) | cited inline |

Legend used throughout:

- **MUST MATCH** — wire or database behaviour that clients, data, tests or the reconciliation
  invariant depend on.
- **INCIDENTAL** — internal naming, logging, metrics labels; a port may differ without breaking anything
  observable to clients or the DB, but the metrics names are consumed by the Grafana bundle so they are
  listed for completeness.

---

## 1. Connection pool and process-level setup (`db/index.js`)

### 1.1 Type parsing — MUST MATCH (semantics)

`index.js:14` and `index.js:17` register two global `pg` type parsers **at module import**:

| OID | Postgres type | Parser | Why |
|---|---|---|---|
| 20 | `int8` / BIGINT | `Number(value)` | every BIGINT is chips or epoch‑ms, both within 2^53 |
| 1700 | `numeric` | `Number(value)` | `SUM(delta)` over BIGINT returns NUMERIC |

Consequence for callers: `users.chips`, `chip_ledger.delta/balance`, `*_at` columns, `pots.amount`,
`hands.pot`, `game_states.version` and `SUM()`/`COUNT()` results are **JS numbers**, never strings.
Every JSON field produced from those columns is therefore a JSON number (e.g. `"chips": 200000`).
A port must return integers for these fields — not strings, not floats with fractions.

Note `COUNT(*)` returns int8 → number too (used by `invalidMoves.test.js:271-272`, which asserts
`rows[0].n === 1` with strict equality).

### 1.2 Configuration (`config/index.js:60-74`) — MUST MATCH defaults

| Key | Env | Default | Notes |
|---|---|---|---|
| `config.db.url` | `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/gameplay` | libpq-style URL |
| `config.db.schema` | `PG_SCHEMA` | `public` | must match `/^[A-Za-z_][A-Za-z0-9_]*$/` (`index.js:35-37`), else `openDatabase` throws `PG_SCHEMA must be a plain identifier, got "<schema>"` |
| `config.db.poolMax` | `PG_POOL_MAX` | `10` | parsed with `parseInt(…,10)`; non-numeric → default |

Config is read **once at import**; `.env` is loaded through `dotenv/config` (`config/index.js:1`). There
is no `server/.env` in the repo; production runs on the defaults above plus whatever the systemd/nginx
deployment exports.

### 1.3 `openDatabase({url, schema})` (`index.js:32-64`)

Order of operations — MUST MATCH (the DB side effects):

1. If a pool already exists, return it (idempotent, `index.js:33`). The `url`/`schema` arguments are
   ignored on the second call.
2. Validate `schema` against `/^[A-Za-z_][A-Za-z0-9_]*$/`; throw otherwise (`index.js:35-37`).
3. Remember `schemaName = schema` (module-level; used by `dropSchema`).
4. Create the pool with:
   - `connectionString: url`
   - `max: config.db.poolMax`
   - `options: "-c search_path=<schema>,public"` — the schema is passed as a **libpq startup parameter**
     (`options` connection parameter), so every connection the pool opens already has the right
     `search_path` before it is handed out. **Not** a per-connection `SET` (CLAUDE.md §12.2: a `SET` on
     `pool.on('connect')` races the pool). A Go port using pgx should set `runtime_params["search_path"]`
     or the `options` DSN key equivalently. The schema name is interpolated **unquoted** here (safe
     because of the identifier check).
   - `created.on('error', …)` logs `postgres pool error {error: message}` — INCIDENTAL.
5. Take one client and, on it, run in order (`index.js:51-59`):
   1. `CREATE SCHEMA IF NOT EXISTS "<schema>"` (identifier quoted by doubling `"`; `index.js:23`)
   2. `SET search_path TO "<schema>", public`
   3. the **entire contents of `schema.sql` as one multi-statement query** (`client.query(ddl)` — pg's
      simple-query protocol allows multiple statements in one call; a Go port must execute the file as
      one simple-protocol `Exec`, or split it correctly on the `$$` bodies).
   4. release the client (`finally`).
6. Publish the pool; log `database ready {url: <redacted>, schema}`. `redact()` (`index.js:119-121`)
   replaces `//user:password@` with `//user:***@` — INCIDENTAL.

Failure at any point in step 5 rejects `openDatabase` and leaves `pool === null` (the created pool is
leaked but unreferenced). `createServer()` awaits `openDatabase()` as its very first statement
(`src/index.js:17`), so a DB failure prevents the HTTP server from starting.

### 1.4 `getPool()` (`index.js:66-69`)

Throws `Error('database not open — call openDatabase() first')` when no pool exists. Also handed to
metrics as `bindPool(getPool)` (`src/index.js:33`) which reads `pool.totalCount/idleCount/waitingCount`
for the `game_db_pool_*` gauges — INCIDENTAL.

### 1.5 `query(text, params = [])` (`index.js:72-74`)

One-shot query on the pool. Returns the pg result (`{rows, rowCount, …}`); rows are objects keyed by
**snake_case column names** exactly as in the DDL. Used by `users.js` outside transactions and by the
tests for direct row checks.

### 1.6 `withTransaction(fn)` (`index.js:82-99`) — MUST MATCH

```
client = pool.connect()
try:
  client.query('BEGIN')
  result = await fn(client)
  client.query('COMMIT')
  return result
catch (error):
  try client.query('ROLLBACK') catch {}   -- swallow rollback failure
  rethrow error
finally:
  client.release()
```

- Default isolation level (READ COMMITTED). No retry on serialization failures (none can occur at
  READ COMMITTED with the FOR UPDATE pattern used).
- `fn` **may throw a `LedgerError`** before any SQL; the rollback still runs.
- A failed `COMMIT` is also caught → ROLLBACK attempted → error rethrown.
- Nothing in the codebase nests `withTransaction` calls.

### 1.7 `dropSchema()` (`index.js:105-109`)

- No pool → returns silently.
- `schemaName === 'public'` → throws `Error('refusing to drop the public schema')`.
- Otherwise `DROP SCHEMA IF EXISTS "<schema>" CASCADE`.
- Test-only (teardown of every process suite). MUST MATCH for the Go test harness if it mirrors the
  per-suite-schema strategy.

### 1.8 `closeDatabase()` (`index.js:111-116`)

Sets the module `pool` to `null` **before** awaiting `pool.end()`, so a concurrent `getPool()` during
shutdown throws rather than using a closing pool. Called after `rooms.shutdown()` in `src/index.js:161`
(live hands are settled — pots paid — before the pool closes).

---

## 2. Schema (`db/schema.sql`) — MUST MATCH verbatim

The whole file is re-run on every boot and on every test-suite start. Every statement is
`IF NOT EXISTS` / `CREATE OR REPLACE` / an existence-guarded `DO` block, so re-running is a no-op.
Timestamps everywhere are **epoch milliseconds as BIGINT** (`Date.now()`), never `timestamptz`.

```sql
-- King Teen Patti — PostgreSQL schema.
--
-- Written so it can run on every boot: every statement is IF NOT EXISTS or
-- CREATE OR REPLACE. Timestamps are epoch milliseconds (BIGINT) to match the
-- Date.now() values the server works in everywhere else.

CREATE TABLE IF NOT EXISTS users (
  id                TEXT PRIMARY KEY,
  provider          TEXT NOT NULL CHECK (provider IN ('google', 'facebook', 'guest')),
  -- Provider-scoped identity: Google "sub", Facebook user id, or the hashed device id for guests.
  provider_user_id  TEXT NOT NULL,
  display_name      TEXT NOT NULL,
  email             TEXT,
  avatar_url        TEXT,
  -- The wallet. Every change goes through a transaction that locks this row,
  -- and the CHECK is the last line of defence against an overdraft.
  chips             BIGINT NOT NULL DEFAULT 0 CHECK (chips >= 0),
  -- A hand only counts as "played" once the player has made a voluntary bet;
  -- posting the boot and folding immediately does not count.
  hands_played      INTEGER NOT NULL DEFAULT 0,
  hands_won         INTEGER NOT NULL DEFAULT 0,
  hands_lost        INTEGER NOT NULL DEFAULT 0,
  -- Hands abandoned before they finished, tracked separately from losses.
  hands_left_mid    INTEGER NOT NULL DEFAULT 0,
  -- Gross chips taken in pots won, over the account's lifetime.
  total_winnings    BIGINT NOT NULL DEFAULT 0,
  biggest_pot       BIGINT NOT NULL DEFAULT 0,
  -- Highest "hands played" milestone already collected (a multiple of 25).
  milestone_claimed INTEGER NOT NULL DEFAULT 0,
  -- Epoch ms when the timed bonus may next be collected. 0 = collectable now.
  next_bonus_at     BIGINT NOT NULL DEFAULT 0,
  -- Picture chosen from the bundled profiles folder; overrides avatar_url.
  avatar_choice     TEXT,
  created_at        BIGINT NOT NULL,
  updated_at        BIGINT NOT NULL,
  last_login_at     BIGINT NOT NULL,
  UNIQUE (provider, provider_user_id)
);

CREATE INDEX IF NOT EXISTS idx_users_last_login ON users (last_login_at DESC);

-- One row per completed hand, for auditing and dispute resolution.
CREATE TABLE IF NOT EXISTS hands (
  id           TEXT PRIMARY KEY,
  room_id      TEXT NOT NULL,
  hand_no      INTEGER NOT NULL,
  pot          BIGINT NOT NULL,
  winner_id    TEXT REFERENCES users (id) ON DELETE SET NULL,
  win_reason   TEXT,
  boot_amount  BIGINT NOT NULL,
  started_at   BIGINT NOT NULL,
  ended_at     BIGINT NOT NULL,
  -- Every seat with its cards, contribution and final status.
  summary_json JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_hands_room ON hands (room_id, hand_no);
CREATE INDEX IF NOT EXISTS idx_hands_ended ON hands (ended_at DESC);

-- The pot, as the database sees it. Opened when the boots are collected,
-- grown by every bet, closed when the hand settles. Its amount and the sum of
-- the hand's ledger rows must agree — that is the reconciliation check.
CREATE TABLE IF NOT EXISTS pots (
  hand_id     TEXT PRIMARY KEY,
  room_id     TEXT NOT NULL,
  boot_amount BIGINT NOT NULL,
  amount      BIGINT NOT NULL DEFAULT 0 CHECK (amount >= 0),
  winner_id   TEXT REFERENCES users (id) ON DELETE SET NULL,
  opened_at   BIGINT NOT NULL,
  closed_at   BIGINT
);

CREATE INDEX IF NOT EXISTS idx_pots_room ON pots (room_id, opened_at DESC);

-- Per-player ledger. Chip movements are only ever written through this table
-- so users.chips can be reconciled against it. Rows are never updated or
-- deleted (see the trigger below).
CREATE TABLE IF NOT EXISTS chip_ledger (
  id         BIGSERIAL PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  hand_id    TEXT,
  -- The client's id for the move that caused this row. UNIQUE, so a retried
  -- request cannot deduct twice: the second insert fails and nothing changes.
  action_id  TEXT UNIQUE,
  -- Negative for bets/antes, positive for pot winnings and grants.
  delta      BIGINT NOT NULL,
  -- users.chips immediately after this row was applied.
  balance    BIGINT NOT NULL,
  reason     TEXT NOT NULL,
  created_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ledger_user ON chip_ledger (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_hand ON chip_ledger (hand_id);

-- The ledger is append-only. An UPDATE or DELETE is a bug or an intrusion,
-- and either way the database refuses it.
CREATE OR REPLACE FUNCTION chip_ledger_immutable() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'chip_ledger is append-only (attempted %)', TG_OP;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgname = 'chip_ledger_no_rewrite'
       AND tgrelid = 'chip_ledger'::regclass
  ) THEN
    CREATE TRIGGER chip_ledger_no_rewrite
      BEFORE UPDATE OR DELETE ON chip_ledger
      FOR EACH ROW EXECUTE FUNCTION chip_ledger_immutable();
  END IF;
END;
$$;

-- The authoritative snapshot of each live table, saved inside the same
-- transaction as every chip movement. `version` only ever goes up; a write
-- carrying an older version than the row already holds is refused, which is
-- how two processes are stopped from both believing they own a table.
CREATE TABLE IF NOT EXISTS game_states (
  room_id    TEXT PRIMARY KEY,
  hand_id    TEXT,
  version    BIGINT NOT NULL,
  state      JSONB NOT NULL,
  updated_at BIGINT NOT NULL
);
```

Notes a porter needs:

- **Constraint names** are Postgres defaults: `users_pkey`, `users_provider_provider_user_id_key`,
  `users_chips_check`, `users_provider_check`, `hands_pkey`, `pots_pkey`, `pots_amount_check`,
  `chip_ledger_pkey`, `chip_ledger_action_id_key`, `game_states_pkey`. The ledger's
  `duplicate_action` classification (§3.3) matches on the string `action_id` appearing in the error's
  `detail` (e.g. `Key (action_id)=(x) already exists.`) or `constraint` (`chip_ledger_action_id_key`).
- `chip_ledger.action_id` is nullable and UNIQUE; Postgres treats NULLs as distinct so any number of
  rows may have `action_id IS NULL` (welcome bonus, timed bonus, legacy rows).
- The append-only trigger fires on UPDATE **and** DELETE; `ON DELETE CASCADE` from `users` would
  therefore **fail** when a user row is deleted while ledger rows exist (the cascade's DELETE hits the
  trigger). Nothing in the code deletes users; test teardown drops the whole schema instead.
- The `DO $$ … $$` block is required because `CREATE TRIGGER IF NOT EXISTS` does not exist in
  Postgres 18; `'chip_ledger'::regclass` resolves through the connection's `search_path`, which is why
  `openDatabase` runs `SET search_path` before the DDL even though the pool option already sets it.
- No `hands.summary_json` schema is enforced by the DB; the shape is in §3.6.
- `hands.winner_id` and `pots.winner_id` are FKs to `users(id)`: settling with a `winnerId` that is
  not a real user id fails the transaction (→ `persist_failed`). Only ever relevant to tests.

---

## 3. Ledger transactions (`db/ledger.js`)

### 3.1 `LedgerError` (`ledger.js:30-36`) — MUST MATCH codes

```
class LedgerError extends Error { name = 'LedgerError'; code: string }
```

Codes that can leave the module (`KNOWN_LEDGER_CODES`, `ledger.js:59-67`):

| code | thrown by | meaning |
|---|---|---|
| `invalid_amount` | `bet` | `amount` not a positive integer |
| `unknown_user` | `bet`, `collectBoot` (via `lockWallet`) | no `users` row for the id |
| `insufficient_chips` | `bet`, `collectBoot` | wallet < amount; in `collectBoot` the error additionally carries `error.userId = <offender>` |
| `no_pot` | `bet` | `UPDATE pots` matched 0 rows |
| `stale_state` | `bet`, `collectBoot`, `settle` (via `saveState`) | `game_states` upsert matched 0 rows (stored version ≥ new) |
| `duplicate_action` | any (via `classify`) | unique violation whose detail/constraint mentions `action_id` |
| `persist_failed` | any (via `classify`) | anything else; `wrapped.cause = original` |

Every rejection out of `bet`/`collectBoot`/`settle` is a `LedgerError` (`transact`, `ledger.js:74-82`).

### 3.2 How the Table maps LedgerError → GameError (`table.js:891-900`) — MUST MATCH (wire)

`_refusal(error)`:

| LedgerError.code | GameError sent to the client |
|---|---|
| `insufficient_chips` | `GameError('insufficient_chips', 'Not enough chips for that bet')` |
| `duplicate_action` | `GameError('duplicate_action', 'That move was already applied')` |
| anything else (`stale_state`, `no_pot`, `unknown_user`, `invalid_amount`, `persist_failed`) | `GameError('persist_failed', 'The move could not be recorded, so nothing was changed')` |

Used only for `bet()` failures (`_chargeToPot`, `table.js:840-858`). Boot failures go through
`_startRefused` (§3.5), settle failures through the retry loop (§3.6). Before the GameError is thrown
the table emits `persistError {userId, delta: -amount, reason, error}` (`table.js:856`), which
RoomManager logs as `warn 'table write refused' {roomId, reason, error: message}`
(`roomManager.js:155-156`) — INCIDENTAL.

### 3.3 Error classification (`classify`, `ledger.js:48-56`) — MUST MATCH

```
if error is LedgerError                                  → return as-is
if error.code === '23505' (unique_violation)
   and /action_id/.test(error.detail ?? error.constraint ?? '')
                                                          → LedgerError('duplicate_action', 'That move has already been applied')
else                                                      → LedgerError('persist_failed', error.message ?? 'database write failed'), .cause = error
```

Corollary: a unique violation on **any other** constraint (e.g. `pots_pkey` when the same `handId`
boot is inserted twice, or `hands_pkey` — though that one is `ON CONFLICT DO NOTHING`) is
`persist_failed`, not `duplicate_action`.

### 3.4 `transact(op, fn)` + metrics (`ledger.js:74-82`) — INCIDENTAL, but names are consumed by Grafana

- Observes `game_db_transaction_duration_seconds{op}` for every call, success or failure
  (`timed`, `metrics/index.js:374-382`, `process.hrtime` seconds, buckets 1 ms … 1 s).
- On failure increments `game_db_transaction_errors_total{op, code}` where `code = safeLabel(refusal.code,
  KNOWN_LEDGER_CODES)` → one of the seven codes or `other`.
- `op` is `bet`, `boot` or `settle`.
- Additionally `collectBoot` is wrapped in `game_hand_start_duration_seconds` (no labels) and `settle` in
  `game_settlement_duration_seconds` (no labels) — the **same span** as the transaction
  (`ledger.js:182`, `235`). `test/metrics.test.js:450-452, 456, 510` assert these counters exist with
  `op: 'boot'` / `op: 'bet'` and a positive `_sum` for `bet`.

### 3.5 Shared helpers — MUST MATCH

**`lockWallet(client, userId)`** (`ledger.js:88-95`)

```sql
SELECT chips FROM users WHERE id = $1 FOR UPDATE
```
0 rows → `LedgerError('unknown_user', 'unknown user <userId>')`. Returns `rows[0].chips` (number).

**`appendLedger(client, {userId, handId, actionId, delta, balance, reason, at})`** (`ledger.js:97-103`)

```sql
INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
VALUES ($1, $2, $3, $4, $5, $6, $7)
```
params `[userId, handId ?? null, actionId ?? null, delta, balance, reason, at]`.

**`saveState(client, {roomId, handId, version, state, at})`** (`ledger.js:112-128`)

- If `version` is `undefined` or `null` → **return without writing** (lets callers such as
  `statsAndRewards.test.js` settle without a table state).
- Otherwise:
```sql
INSERT INTO game_states (room_id, hand_id, version, state, updated_at)
VALUES ($1, $2, $3, $4::jsonb, $5)
ON CONFLICT (room_id) DO UPDATE
   SET hand_id = EXCLUDED.hand_id,
       version = EXCLUDED.version,
       state = EXCLUDED.state,
       updated_at = EXCLUDED.updated_at
 WHERE game_states.version < EXCLUDED.version
```
params `[roomId, handId ?? null, version, JSON.stringify(state ?? {}), at]`.
- `rowCount === 0` (the row existed with `version >= new`) →
  `LedgerError('stale_state', 'state version <version> is not newer than the stored one')`.
- Note the conflict path updates only when strictly newer: **equal version is stale**.
- `state` is serialised with `JSON.stringify` — key order is the Table's `_snapshot()` insertion order
  (§3.9). Postgres JSONB reorders keys on storage, so byte-order is not observable in the DB; only the
  content matters.

`now()` = `Date.now()` (`ledger.js:38`), captured **once per transaction** as `at` and used for every
`updated_at`, `created_at`, `opened_at`, `closed_at` written in that transaction — all rows of one
transaction share one timestamp. MUST MATCH (tests compare `rows[0].next_bonus_at === result.readyAt`
etc. in users.js; the ledger tests do not compare timestamps but the reconciliation queries group by
nothing timestamp-related).

### 3.6 `bet({userId, amount, roomId, handId, actionId, reason = 'bet', version, state})` (`ledger.js:135-169`) — MUST MATCH

Called by `Table._chargeToPot` (`table.js:840-858`) for **chaal, raise (reason `'bet'`) and show
(reason `'show'`)**. The table also passes `balanceBefore: seat.chips`, which the Postgres ledger
ignores (only `memoryLedger` reads it).

Order inside `transact('bet', …)`:

1. **Before BEGIN**: `if (!Number.isInteger(amount) || amount <= 0)` →
   `LedgerError('invalid_amount', 'bet amount must be a positive integer')`. No transaction is opened.
   (Table has already validated the amount against the ladder, so this is defence in depth.)
2. `BEGIN`; `at = Date.now()`.
3. `SELECT chips FROM users WHERE id = $1 FOR UPDATE` → `unknown_user` if none.
4. `if (chips < amount)` → `LedgerError('insufficient_chips', 'insufficient chips for <userId>')`.
5. `balance = chips - amount`.
6. `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3` — params `[balance, at, userId]`.
   (Absolute value, not `chips - $1`; the row is locked so it is equivalent.)
7. `UPDATE pots SET amount = amount + $1 WHERE hand_id = $2` — params `[amount, handId]`.
   `rowCount === 0` → `LedgerError('no_pot', 'no open pot for hand <handId>')`.
   Note: a pot whose `closed_at` is set is still updated — there is no "open" check beyond existence.
8. `appendLedger` with `{userId, handId, actionId, delta: -amount, balance, reason, at}`. A duplicate
   `actionId` fails here (→ `duplicate_action` after classification); because it is after the wallet
   UPDATE the whole thing rolls back and the wallet is untouched.
9. `saveState({roomId, handId, version, state, at})` → may throw `stale_state`.
10. `COMMIT`; return **`{ balance, persisted: amount }`**.

`actionId`: the Table passes the client's id if it was a non-empty string of ≤ 64 chars
(`socket/index.js:617-619`), otherwise a fresh `uuid()` (`table.js:848`). So every bet/show ledger row
has a non-null `action_id`.

`reason` values written here: `'bet'` (chaal/raise) and `'show'`.

What the Table does with the result (`table.js:859-889`): sets `this.version = version`;
`seat.chips = result.balance` (fallback `seat.chips - amount` if not finite);
`persisted = result.persisted` (fallback `amount`); `seat.contributed += amount`;
`hand.pot += amount`; the hand's contribution record gets `contributed` synced and
`persisted += persisted`. Memory is changed **only after** the commit.

### 3.7 `collectBoot({roomId, handId, bootAmount, entries, version, state})` (`ledger.js:179-222`) — MUST MATCH

Called once per hand start by `Table._startHand` (`table.js:423-434`) with
`entries = participants.map(seat => ({userId, amount: bootAmount, balanceBefore: seat.chips}))`
(every entry's `amount` equals `bootAmount`), `version = table.version + 1`, and `state` = the
pre-deal snapshot (§3.9, with `deals`/`participants`/`bootAmount` supplied so seats already show
`chips - boot`, `contributed = boot`, `isBlind = true`, cards dealt).

Order inside `transact('boot', …)` (wrapped in `handStartDuration`):

1. `BEGIN`; `at = Date.now()`.
2. `ordered = entries sorted by userId ascending` using the comparator `(a, b) => (a.userId < b.userId ? -1 : 1)`
   — JS string `<` = UTF‑16 code-unit order. User ids are RFC‑4122 UUID strings (ASCII), so plain
   byte-wise ordering is identical. **Lock order is by user id** so two tables sharing a player cannot
   deadlock (`ledger.js:185`).
3. For each entry **in that order**:
   1. `SELECT chips FROM users WHERE id = $1 FOR UPDATE` (→ `unknown_user`).
   2. `if (chips < amount)` → `LedgerError('insufficient_chips', 'insufficient chips for <userId>')`
      **with `error.userId = userId`** attached (`ledger.js:191-193`). Everything already updated in this
      loop rolls back.
   3. `balances[userId] = chips - amount`.
   4. `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3` — `[balances[userId], at, userId]`.
4. `total = Σ entry.amount`.
5. `INSERT INTO pots (hand_id, room_id, boot_amount, amount, opened_at) VALUES ($1, $2, $3, $4, $5)`
   — `[handId, roomId, bootAmount, total, at]`. `winner_id` and `closed_at` are left NULL.
   (A duplicate `handId` violates `pots_pkey` → `persist_failed`.)
6. For each entry, again in sorted order: `appendLedger({userId, handId, actionId: `${handId}:boot:${userId}`, delta: -amount, balance: balances[userId], reason: 'boot', at})`.
   The **deterministic action id** `"<handId>:boot:<userId>"` makes a retried start idempotent at the
   ledger (`ledger.js:211`).
7. `saveState({roomId, handId, version, state, at})`.
8. `COMMIT`; return **`{ balances: {userId: balance, …}, persisted: bootAmount }`**.

Row order in `chip_ledger` for one boot is therefore: all wallets updated first, then the pot, then one
ledger row per participant in ascending user-id order (ascending `chip_ledger.id`).

What the Table does with the result (`table.js:435-466`): `this.version += 1`; every contribution
record's `persisted = persistedBoot` (= `bootAmount` from the ledger, defaulting to `bootAmount` if the
ledger omits it); each participant seat's `chips = balances[userId]` **if the key exists**
(`hasOwnProperty`), else `seat.chips -= bootAmount`. Then the hand becomes live.

What the Table does on failure — `_startRefused(error)` (`table.js:494-520`):

1. emit `persistError {reason: 'boot', error}` (logged as warn — INCIDENTAL).
2. `state = WAITING`, `startsAt = null`.
3. If `error.code === 'insufficient_chips' && error.userId`: find that seat; set
   `seat.chips = min(seat.chips, bootAmount - 1)`; emit `kick {userId, displayName, reason:
   'insufficient_chips', message: "You don't have enough coins to remain in this table"}` — the room
   manager/socket layer removes the player and the client receives `room:kicked`.
4. Else (any other code, table not destroyed): re-arm a `nextHandDelayMs` timer that calls
   `_maybeStart()` again — i.e. **boot failures other than an unfunded player retry indefinitely every
   `nextHandDelayMs` (4 s)** while ≥ 2 funded players sit there.
5. emit `state`; return `null`.

### 3.8 `settle({hand, entries, version, state})` (`ledger.js:234-322`) — MUST MATCH

Called by `Table._endHand` (`table.js:1467-1480`) and retried by `_retrySettle` (`table.js:1529-1559`).
Also exported by `users.js` as `settleHand(args)` (`users.js:180-182`) for tests.

Inputs:

- `hand` = the **hand record** (`table.js:1454-1465`):
  ```
  {
    id: string,             // hand uuid
    roomId: string,
    handNo: number,
    pot: number,
    winnerId: string|null,  // userId, or null when nobody can be paid
    winReason: string,      // 'last_standing' | 'show' | 'forced_showdown' | 'all_left' | 'pot_limit'
    bootAmount: number,     // table.config.bootAmount
    startedAt: number,      // epoch ms
    endedAt: number,        // epoch ms
    summary: [ … ]          // §3.10
  }
  ```
- `entries` = one per **contributor** (`hand.contributions` with `contributed > 0` — i.e. every
  participant of the hand including players who have since left the table; `table.js:1417`):
  ```
  { userId, delta: number, isWinner: boolean, didChaal: boolean, leftMidHand: boolean }
  ```
  where `delta = net + persisted`, `net = isWinner ? pot - contributed : -contributed` when there is a
  winner, `0` when `winnerId` is null (`table.js:1421-1441`). With the Postgres ledger every stake was
  already banked (`persisted === contributed`), so **in production `delta` is `+pot` for the winner and
  `0` for every loser**; with no winner each contributor's `delta` is `+contributed` (refund). In
  bookless unit tests (`persisted = 0`) the deltas are the nets and sum to zero.
- `version` = `table.version + 1`; `state` = snapshot with `hand: null`, `state: 'waiting'`.

Order inside `transact('settle', …)` (wrapped in `settlementDuration`):

1. `BEGIN`; `at = Date.now()`.
2. Hand record:
   ```sql
   INSERT INTO hands (id, room_id, hand_no, pot, winner_id, win_reason,
                      boot_amount, started_at, ended_at, summary_json)
   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb)
   ON CONFLICT (id) DO NOTHING
   ```
   params `[hand.id, hand.roomId, hand.handNo, hand.pot, hand.winnerId ?? null, hand.winReason ?? null,
   hand.bootAmount, hand.startedAt, hand.endedAt, JSON.stringify(hand.summary ?? [])]`.
3. `ordered = entries sorted by userId ascending` (same comparator as boot).
4. For each entry in that order:
   1. `SELECT chips FROM users WHERE id = $1 FOR UPDATE`; **0 rows → `continue`** (silently skipped; no
      ledger row, no key in the returned balances).
   2. `balance = Math.max(0, chips + entry.delta)` — clamped at zero, never throws for a negative delta.
   3. `played = didChaal ? 1 : 0`; `left = leftMidHand ? 1 : 0`;
      `lost = (!isWinner && !leftMidHand) ? 1 : 0`; `won = isWinner ? 1 : 0`.
   4. ```sql
      UPDATE users
         SET chips          = $1,
             hands_played   = hands_played + $2,
             hands_won      = hands_won + $3,
             hands_lost     = hands_lost + $4,
             hands_left_mid = hands_left_mid + $5,
             total_winnings = total_winnings + $6,
             biggest_pot    = GREATEST(biggest_pot, $7),
             updated_at     = $8
       WHERE id = $9
      ```
      params `[balance, played, won, lost, left, isWinner ? hand.pot : 0, isWinner ? hand.pot : 0, at, userId]`.
      So `total_winnings` accumulates the **gross pot** (not net), and `biggest_pot` is the largest pot
      won, both only for winners.
   5. `appendLedger({userId, handId: hand.id, actionId: `${hand.id}:settle:${userId}`, delta: entry.delta,
      balance, reason: isWinner ? 'hand_win' : 'hand_loss', at})`. **A zero delta still gets a row**
      (`ledger.js:299-309`) — this is how the ledger records participation. A player who left mid-hand
      (not winner) is written as `hand_loss` even though `hands_lost` is not incremented for them.
   6. `balances[userId] = balance`.
5. `UPDATE pots SET closed_at = $1, winner_id = $2 WHERE hand_id = $3` — `[at, hand.winnerId ?? null, hand.id]`.
   No rowCount check (a missing pot row is tolerated).
6. `saveState({roomId: hand.roomId, handId: null, version, state, at})` — note **`hand_id` is written
   as NULL** on settlement.
7. `COMMIT`; return **`balances`** = `{ [userId]: balance }` for every entry whose user row existed.

Idempotency key per player: `"<handId>:settle:<userId>"`. A repeat settle of a hand already committed
fails on that key → `duplicate_action` → (in the table) treated as a failed retry and retried again;
see §3.11.

What the Table does with the result (`table.js:1472-1499`):

- success: `this.version = version`; `settledInDb = true`; for every `[userId, balance]` in `balances`
  the seat (if still seated) gets `seat.chips = balance`.
- **winner fallback**: if the winner is still seated and `balances` **lacks the key** (`hasOwnProperty`,
  not truthiness — a balance of exactly `0` counts as present; `settlement.test.js:187-208`), then
  `winnerSeat.chips += hand.pot`.
- failure: emit `persistError {reason: 'settle', handId, error}`; seats keep their in-memory books (the
  winner is credited in memory by the fallback above); `_retrySettle(args, 1)` is scheduled.

### 3.9 `game_states.state` — the snapshot shape (`table.js:1568-1617`) — MUST MATCH content

Written by every ledger transaction. Never sent to a client. Cards are **included** (2-char codes,
`deck.js:14`: rank code `2…9 T J Q K A` + suit `s h d c`, e.g. `"As"`, `"Td"`).

```
{
  roomId: string,
  code: string,                 // 6-char room code
  category: 'seen' | 'blind',
  state: 'waiting'|'starting'|'betting'|'showdown',   // stateOverride ?? (hand ? 'betting' : table.state)
  handNo: number,
  dealerSeat: number,           // -1 before the first hand
  hand: null | {
    id, handNo, pot, stake, round, turnSeat, startSeat, startedAt,
    showRequestedBy: string|null,
    contributions: [ { userId, contributed, persisted, status, didChaal: bool, leftMidHand: bool } ]
  },
  seats: [ null | {
    seatIndex, userId, displayName, chips, status, isBlind, blindMoves, contributed,
    cards: [ "As", "Td", "7h" ] | []
  } ]                           // length = config.maxPlayers (5); null for empty seats
}
```

Variants:

- **boot** (`_snapshot({hand, handNo, dealerSeat, deals, participants, bootAmount})`, `table.js:433`):
  participants are shown *as they will be after the deal*: `chips = seat.chips - bootAmount`,
  `status = 'active'`, `isBlind = true`, `blindMoves = 0`, `contributed = bootAmount`, `cards` = the
  dealt hand; `hand.contributions[*].persisted = 0` (not yet updated in memory);
  `state = 'betting'`, `hand.turnSeat = -1`, `startSeat = -1`.
- **bet/show** (`_snapshotAfterBet(seat, amount)`, `table.js:1619-1633`): the current snapshot with
  `hand.pot += amount`, the bettor's seat `chips -= amount`, `contributed += amount`, and the bettor's
  contribution `contributed += amount`, `persisted += amount`.
- **settle** (`_snapshot({hand: null, stateOverride: 'waiting'})`): `hand: null`, `state: 'waiting'`;
  seats show their post-hand statuses (`won`/`lost`/`packed`) and pre-payout chips (the winner's seat
  balance is updated only after the transaction returns).

### 3.10 `hands.summary_json` shape (`table.js:1443-1452`) — MUST MATCH

Array with one element per contributor (same set as `entries`), in `hand.contributions` insertion
order (participants in seat order at deal time, then any later additions — in practice only
participants):

```
[
  {
    userId: string,
    displayName: string,
    seatIndex: number,
    contributed: number,
    status: 'active'|'packed'|'lost'|'won'|'waiting',
    sawCards: boolean,
    cards: ["As","Td","7h"] | null     // codes only if this user was in `reveals` (showdown), else null
  }
]
```

`reveals` is empty for `last_standing`/`all_left` (so every `cards` is `null`) and contains every
contender at a show/forced showdown/pot limit. `recentHands` (§4.9) returns this array as `summary`.

### 3.11 Settlement retry semantics expected by the Table (`table.js:1529-1559`) — MUST MATCH behaviour

- Triggered only when the first `ledger.settle` **threw**.
- Attempt `n` (1‑based) waits `min(30000, nextHandDelayMs * n)` ms (4 s, 8 s, … 28 s, 30 s, 30 s) then
  calls `ledger.settle({...args, version: table.version + 1})` — the **version is recomputed** from the
  table's current version at retry time so the snapshot check still reads "newer than stored"
  (`table.js:1543-1546`). The `state` snapshot is **not** recomputed (it is the post-hand snapshot from
  the original attempt, possibly stale by now).
- Success: `table.version = version`; every returned balance is applied to a seat **only if the seat is
  not `active`** (a live stake in a newer hand is left alone); emit `state`.
- Failure: emit `persistError {reason: 'settle_retry', handId, attempt, error}`; schedule attempt `n+1`.
- After 10 failed attempts: `Error('settlement of hand <id> failed after 10 attempts')` is emitted as
  `'error'` if a listener exists (RoomManager attaches one and logs `table error`) else as
  `persistError {reason: 'settle_abandoned', …}`. No further retries.
- A destroyed table (`_destroyed`) never retries.
- The retry does **not** special-case `duplicate_action`: if the original settle actually committed but
  its promise rejected (e.g. connection dropped between COMMIT and the response), every retry hits the
  `:settle:` unique key, fails as `duplicate_action`, and the loop runs to 10 attempts. The database
  is nevertheless correct (paid exactly once).

### 3.12 `createLedger()` (`ledger.js:328-330`)

Returns `{ bet, collectBoot, settle }`. `RoomManager` constructs one when it is given neither a `ledger`
nor the legacy `settle`/`persistChips` hooks (`roomManager.js:32`) and passes it to every `Table`
(`roomManager.js:147`). The Table's `memoryLedger` (`table.js:1803-1835`) is the test stand-in:

| method | memoryLedger behaviour |
|---|---|
| `bet` | calls `persistChips({userId, delta: -amount, reason, roomId, handId, actionId})` if provided (a throw refuses the move); returns `{balance: balanceBefore - amount, persisted: persistChips ? amount : 0}` |
| `collectBoot` | per entry calls `persistChips({…, reason: 'boot', actionId: `${handId}:boot:${userId}`})`; returns `{balances, persisted: persistChips ? entries[0].amount : 0}` |
| `settle` | returns `settle({hand, entries}) ?? {}` or `{}` when no hook |

The `persisted` figure is what lets the same `_endHand` arithmetic produce zero-sum net deltas in
bookless tests and payout-only deltas in production (CLAUDE.md §12.2 last bullet).

### 3.13 Pot row lifecycle — MUST MATCH

| Stage | `pots` row |
|---|---|
| after `collectBoot` | `{hand_id, room_id, boot_amount, amount: boot × participants, winner_id: NULL, opened_at: at, closed_at: NULL}` |
| after each `bet` | `amount += bet` (also for `show`) |
| after `settle` | `closed_at = at`, `winner_id = hand.winnerId` (may be NULL); `amount` unchanged |

Invariant: `pots.amount == -SUM(chip_ledger.delta) WHERE hand_id = pot.hand_id AND reason IN
('boot','bet','show')` and, after settlement with a winner, `== SUM(delta) WHERE reason = 'hand_win'`.

---

## 4. User store (`db/users.js`)

### 4.1 Constants (`users.js:8-15`) — MUST MATCH

| Export | Value |
|---|---|
| `MILESTONE_REWARD` | `25000` |
| `MILESTONE_EVERY` | `25` |
| `TIMED_BONUS_REWARD` | `10000` |
| `TIMED_BONUS_INTERVAL_MS` | `14400000` (4 h) |

`milestoneFor(handsPlayed) = floor(handsPlayed / 25) * 25` (`users.js:18-19`).

### 4.2 The public user object — `publicUser(row)` (`users.js:21-60`) — MUST MATCH exactly

Returned by `findById`, `findByProvider`, `upsertFromProfile`, both claim functions, `setDisplayName`,
`setAvatarChoice`; emitted on the wire as `POST /api/auth/login → user`, `GET /api/auth/me → {user}`,
`POST /api/profile/* → {user}`, `POST /api/rewards/* → {…, user}`, and Socket.IO `session:ready.user`.
`null` when the row is missing.

```
{
  "id":                string,                 // users.id (uuid v4)
  "provider":          "google"|"facebook"|"guest",
  "displayName":       string,
  "email":             string|null,
  "avatarUrl":         string|null,            // avatar_choice || avatar_url  (JS ||: '' falls through to avatar_url)
  "providerAvatarUrl": string|null,            // avatar_url verbatim
  "avatarChoice":      string|null,            // avatar_choice ?? null
  "chips":             number,
  "handsPlayed":       number,
  "handsWon":          number,
  "handsLost":         number,                 // ?? 0 (column is NOT NULL so always a number)
  "handsLeftMid":      number,                 // ?? 0
  "totalWinnings":     number,                 // ?? 0
  "biggestPot":        number,
  "rewards": {
    "milestoneAvailable":   boolean,           // milestoneFor(hands_played) > milestone_claimed
    "milestoneAt":          number,            // milestoneFor(hands_played)  (0, 25, 50, …)
    "milestoneReward":      25000,
    "milestoneEvery":       25,
    "handsToNextMilestone": number,            // 25 - (hands_played % 25)  → 25 at an exact multiple, never 0
    "bonusReadyAt":         number,            // next_bonus_at ?? 0  (0 = ready)
    "bonusAvailable":       boolean,           // Date.now() >= bonusReadyAt  (evaluated at serialisation time)
    "bonusReward":          10000,
    "bonusIntervalMs":      14400000
  },
  "createdAt":         number,                 // epoch ms
  "lastLoginAt":       number                  // epoch ms
}
```

Key order above is the emission order (`res.json` preserves insertion order). Fields **never present**:
`providerUserId`, `updatedAt`, `milestoneClaimed`, `nextBonusAt` (only via `rewards.bonusReadyAt`).
Downstream consumers read `id`, `displayName`, `avatarUrl`, `chips`, `provider` (`roomManager.js:334-339`,
`tokens.js:8`).

### 4.3 `findById(id)` / `findByProvider(provider, providerUserId)` (`users.js:67-78`)

```sql
SELECT * FROM users WHERE id = $1
SELECT * FROM users WHERE provider = $1 AND provider_user_id = $2
```
→ `publicUser(rows[0])` (null if none). `findById` is called on every REST `requireAuth`
(`routes.js:35-45`; a null → `AuthError('unknown_user', 'This account no longer exists')` → HTTP 401),
on every socket handshake (`socket/index.js:384-385`; null → `connect_error` `unknown_user`), and
**freshly before every join** (`socket/index.js:489, 509, 527, 543`) so the seat is created with the
DB balance, not the JWT-time balance.

### 4.4 `upsertFromProfile(profile)` (`users.js:87-144`) — MUST MATCH

`profile` comes from `auth/providers.js` and is always
`{provider, providerUserId: string, displayName: string, email: string|null, avatarUrl: string|null}`:

- guest (`providers.js:100-116`): `providerUserId = sha256hex('teenpatti:' + trimmedDeviceId)`
  (deviceId trimmed, ≥ 8 chars else `AuthError('invalid_device_id', …, 400)`);
  `displayName = sanitizeName(displayName) || 'Guest' + hash.slice(0,5).toUpperCase()`;
  `sanitizeName` strips `\p{C}` (control/format chars), trims, `.slice(0, 24)`, and returns `''` if
  shorter than 2 chars (`providers.js:118-124`). `email`/`avatarUrl` null.
- google: `{sub, name || given_name || 'Player', email ?? null, picture ?? null}`.
- facebook: `{String(id), name || 'Player', email ?? null, picture.data.url ?? null}`.
- fake (tests, `AUTH_ALLOW_FAKE_PROVIDERS`): `providerUserId = String(providerUserId ?? displayName ?? 'fake')`,
  `displayName = sanitizeName(displayName) || 'Player'`.

Transaction (`withTransaction`), `timestamp = Date.now()` captured before BEGIN:

1. ```sql
   SELECT * FROM users WHERE provider = $1 AND provider_user_id = $2 FOR UPDATE
   ```
2. **Existing row:**
   ```sql
   UPDATE users
      SET display_name  = $1,
          email         = COALESCE($2, email),
          avatar_url    = COALESCE($3, avatar_url),
          updated_at    = $4,
          last_login_at = $4
    WHERE id = $5
   ```
   params `[profile.displayName || existing.display_name, profile.email ?? null, profile.avatarUrl ?? null, timestamp, existing.id]`.
   - **`display_name` is overwritten on every login** with the provider's name (a `POST /api/profile/name`
     rename is clobbered on the next login — CLAUDE.md §12.2, known/unresolved). Only an empty provider
     name keeps the stored one.
   - `email`/`avatar_url` are only replaced when the provider supplied a non-null value.
   - `chips`, counters, `avatar_choice`, `milestone_claimed`, `next_bonus_at` untouched.
   - Re-`SELECT * FROM users WHERE id = $1` on the same client → `{ user: publicUser(row), isNew: false }`.
3. **No row:**
   - `id = uuid()` (`crypto.randomUUID()`, lowercase hyphenated v4).
   - `chips = config.game.welcomeChips` (default `200000`, env `WELCOME_CHIPS`).
   - ```sql
     INSERT INTO users (id, provider, provider_user_id, display_name, email, avatar_url,
                        chips, created_at, updated_at, last_login_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8, $8)
     ```
     params `[id, provider, providerUserId, displayName, email ?? null, avatarUrl ?? null, chips, timestamp]`
     — all three timestamps equal.
   - ```sql
     INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
     VALUES ($1, NULL, NULL, $2, $2, 'welcome_bonus', $3)
     ```
     params `[id, chips, timestamp]` — `delta == balance == welcomeChips`, `action_id` NULL.
   - Re-select → `{ user: publicUser(row), isNew: true }`.

Concurrency note (MUST MATCH failure mode, or improve consciously): two simultaneous first logins for the
same identity both see no row (the `FOR UPDATE` locks nothing when there is nothing to lock); the second
INSERT violates `users_provider_provider_user_id_key`, the error propagates un-classified, and the
route answers HTTP 500 `{error: 'internal_error', message: 'Something went wrong'}` (`src/index.js:109-110`).

Route response (`routes.js:60-80`): `{ token, user, isNew, welcomeChips: isNew ? config.game.welcomeChips : 0 }`.

### 4.5 `applyChipDelta({userId, delta, reason, handId = null, actionId = null})` (`users.js:155-173`)

Not used by gameplay; used by tests/tooling (`invalidMoves.test.js:339` with `reason: 'test_fixture'`,
`actionId: 'poor-fixture'`). Transaction:

1. `SELECT chips FROM users WHERE id = $1 FOR UPDATE` → 0 rows → plain `Error('unknown user <id>')`.
2. `balance = chips + delta`; `balance < 0` → plain `Error('insufficient chips for <id>')`.
3. `timestamp = Date.now()` (captured **after** the lock, unlike the ledger).
4. `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3` — `[balance, timestamp, userId]`.
5. `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at) VALUES ($1,$2,$3,$4,$5,$6,$7)`
   — `[userId, handId, actionId, delta, balance, reason, timestamp]`.
6. Returns `balance` (number).

Errors are plain `Error`s, not `LedgerError`/`GameError`; the counters are untouched.

### 4.6 `claimMilestoneReward(userId)` (`users.js:215-246`) — MUST MATCH

Transaction:

1. `SELECT * FROM users WHERE id = $1 FOR UPDATE`; none → `Error('unknown user <id>')` (→ HTTP 500).
2. `milestone = milestoneFor(hands_played)`; if `milestone <= (milestone_claimed ?? 0)` →
   return **`{ claimed: false, reason: 'not_available', user: publicUser(row) }`** (no writes; the route
   turns this into HTTP 409 `{error: 'reward_not_available', message: 'No milestone reward is waiting yet.', user}`,
   `routes.js:113-119`).
3. `timestamp = Date.now()`; `balance = chips + 25000`.
4. `UPDATE users SET chips = $1, milestone_claimed = $2, updated_at = $3 WHERE id = $4` — `[balance, milestone, timestamp, userId]`.
   `milestone_claimed` jumps straight to the **current** milestone (claiming at 75 hands after last
   claiming at 25 pays once, not twice — the skipped 50 is forfeited).
5. `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at) VALUES ($1, NULL, $2, $3, $4, 'milestone_reward', $5)`
   — `[userId, `${userId}:milestone:${milestone}`, 25000, balance, timestamp]`. The deterministic
   `action_id` `"<userId>:milestone:<milestone>"` makes the same milestone unrepeatable at the DB even if
   the `milestone_claimed` check were bypassed.
6. Re-select → return **`{ claimed: true, amount: 25000, milestone: number, user }`** (HTTP 200 body verbatim).

### 4.7 `claimTimedBonus(userId)` (`users.js:254-290`) — MUST MATCH

Transaction:

1. `SELECT * FROM users WHERE id = $1 FOR UPDATE`; none → `Error('unknown user <id>')`.
2. `timestamp = Date.now()`; if `timestamp < (next_bonus_at ?? 0)` → return
   **`{ claimed: false, reason: 'not_ready', readyAt: next_bonus_at, user: publicUser(row) }`**
   (route → HTTP 409 `{error: 'reward_not_ready', message: 'The bonus is still recharging.', readyAt, user}`,
   `routes.js:133-140`).
3. `balance = chips + 10000`; `readyAt = timestamp + 14400000`.
4. `UPDATE users SET chips = $1, next_bonus_at = $2, updated_at = $3 WHERE id = $4` — `[balance, readyAt, timestamp, userId]`.
5. `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at) VALUES ($1, NULL, NULL, $2, $3, 'timed_bonus', $4)`
   — `[userId, 10000, balance, timestamp]`. **No action_id** (the `next_bonus_at` check is the only guard;
   the row lock makes it safe).
6. Re-select → return **`{ claimed: true, amount: 10000, readyAt: number, user }`**.

A brand-new account has `next_bonus_at = 0` → collectable immediately (`statsAndRewards.test.js:206-213`).

### 4.8 Display names — `normalizeDisplayName(raw, {maxLength = 24})` (`users.js:305-320`) — MUST MATCH

```
NAME_PATTERN = /^[\p{L}\p{N}][\p{L}\p{N}\p{M} ]*$/u
```

1. `trimmed = String(raw ?? '').trim().replace(/\s+/g, ' ')` — null/undefined → `''`; any run of
   Unicode whitespace (JS `\s`: includes `\t\n\v\f\r`, NBSP U+00A0, U+FEFF, U+2000–200A, U+2028/2029,
   U+202F, U+205F, U+3000, U+1680) collapses to one ASCII space.
2. `trimmed === ''` → `throw new Error('empty_name')`.
3. `trimmed.length > maxLength` → `throw new Error('name_too_long')`. **`length` is UTF‑16 code units**
   (an astral character counts 2; a Devanagari conjunct counts per code point). The route passes
   `maxLength: config.game.displayNameMaxLength` (default 24, env `DISPLAY_NAME_MAX`).
4. `!NAME_PATTERN.test(trimmed)` → `throw new Error('invalid_name')`. First char must be a letter (`\p{L}`)
   or a number (`\p{N}` — includes digits in any script and things like Roman numerals `Ⅳ`, `²`);
   subsequent chars may also be combining marks (`\p{M}`, essential for Indic vowel signs) or the ASCII
   space. Underscore, hyphen, punctuation, emoji (`\p{So}`) are refused. Go's `regexp` supports `\p{L}`,
   `\p{N}`, `\p{M}` with the same Unicode general categories; the Unicode version may differ slightly.
5. Returns `trimmed`.

The route (`routes.js:161-193`) maps thrown messages to HTTP 400
`{error: <message>, message: …}` with messages `empty_name → 'Your name cannot be empty.'`,
`name_too_long → 'Keep it to <max> characters or fewer.'`, `invalid_name → 'Letters, numbers and spaces only.'`,
and refuses with HTTP 409 `{error: 'seated', message: 'You can only change your name in the lobby.'}` while seated.

`setDisplayName(userId, displayName)` (`users.js:322-325`):
`UPDATE users SET display_name = $1, updated_at = $2 WHERE id = $3` — `[displayName, Date.now(), userId]`
(outside any transaction) then `findById(userId)`. Route returns `{user}`.

### 4.9 Avatars (`users.js:328-331`, `routes.js:19-33, 150-176`) — MUST MATCH

Catalogue = the files in `server/public/profiles/` matching `/\.(svg|png|jpg|jpeg|webp)$/i`, sorted
(`Array.prototype.sort` default = UTF‑16 code-unit order), each as `{id: filename, url: '/profiles/' + filename}`.
Read from disk on **every** request (`listProfilePictures()`); unreadable dir → `[]`. Current contents
(15 Noto Emoji animals, Apache 2.0, `NOTICE.txt` excluded by the extension filter):

```
bear.svg cat.svg dog.svg fox.svg frog.svg horse.svg koala.svg lion.svg
monkey.svg owl.svg panda.svg penguin.svg rabbit.svg tiger.svg wolf.svg
```

- `GET /api/profiles` (unauthenticated) → `{ profiles: [ {id, url}, … ] }`.
- `POST /api/profile/avatar {avatar: "<id>" | null}`:
  - seated → 409 `{error: 'seated', message: 'You cannot change your picture while you are at a table.'}`.
  - `requested = body.avatar ?? null`; if not null and not an `id` in the catalogue → 400
    `{error: 'unknown_avatar', message: 'That picture is not available.'}`.
  - `setAvatarChoice(userId, requested ? '/profiles/' + requested : null)` — **the stored value is the
    URL path** (`/profiles/ace.svg`), not the bare id. An empty string `''` is falsy → stored as NULL.
  - `setAvatarChoice`: `UPDATE users SET avatar_choice = $1, updated_at = $2 WHERE id = $3` then
    `findById` → `{user}`.
- Effect on the public object: `avatarUrl = avatar_choice || avatar_url`; `providerAvatarUrl` keeps the
  provider picture; `avatarChoice` is the stored path or null (`statsAndRewards.test.js:263-289`).

### 4.10 `recentHands(userId, limit = 20)` (`users.js:184-206`)

```sql
SELECT DISTINCT ON (h.id) h.*
  FROM hands h
  JOIN chip_ledger l ON l.hand_id = h.id
 WHERE l.user_id = $1
 ORDER BY h.id, h.ended_at DESC
```
then in JS: sort by `ended_at` descending, `slice(0, limit)`, map to
`{ id, roomId, handNo, pot, winnerId, winReason, endedAt, summary }` where `summary` is the parsed
`summary_json` (pg already returns JSONB as an object; the `typeof === 'string'` branch is dead).
Route `GET /api/auth/me/hands?limit=` clamps `limit` to `parseInt(limit) || 20`, max 100
(`routes.js:86-93`) → `{hands: […]}`. **No client calls it** (dead surface; CLAUDE.md §12.2). Note the
query fetches every hand the user ever touched before slicing — not paginated in SQL.

### 4.11 Ledger `reason` catalogue — MUST MATCH strings

| reason | writer | delta sign | action_id |
|---|---|---|---|
| `welcome_bonus` | `upsertFromProfile` | + | NULL |
| `boot` | `collectBoot` | − | `<handId>:boot:<userId>` |
| `bet` | `bet` (chaal/raise) | − | client id (≤ 64 chars) or server uuid |
| `show` | `bet` (show) | − | client id or server uuid |
| `hand_win` | `settle` (winner) | + (pot) or 0 in bookless tests | `<handId>:settle:<userId>` |
| `hand_loss` | `settle` (everyone else, incl. mid-hand leavers) | 0 in production (net already banked); + when refunding a void hand | `<handId>:settle:<userId>` |
| `milestone_reward` | `claimMilestoneReward` | +25000 | `<userId>:milestone:<milestone>` |
| `timed_bonus` | `claimTimedBonus` | +10000 | NULL |
| `test_fixture` | `applyChipDelta` in tests; `kicktest.mjs:22-26` | ± | test-chosen or NULL |
| `legacy_reconciliation` | one-off import 2026‑09‑07 (12 rows) | ± | NULL |
| older SQLite-era reasons | import | — | — |

Live production counts on 2026‑09‑08 (for a sense of proportions): bet 13,854 · hand_loss 12,768 ·
boot 11,712 · hand_win 9,391 · show 4,229 · welcome_bonus 125 · legacy_reconciliation 12 · timed_bonus 5 ·
test_fixture 2 · milestone_reward 1.

### 4.12 The reconciliation invariant — MUST MATCH

For every user: `SUM(chip_ledger.delta) == users.chips`, and every ledger row's `balance` equals the
wallet immediately after it. Every code path that changes `users.chips` writes exactly one ledger row in
the same transaction with `balance = new chips`. Check (CLAUDE.md §4):

```sql
select count(*) from users u
  join (select user_id, sum(delta) s from chip_ledger group by user_id) l on l.user_id = u.id
 where l.s <> u.chips;   -- expect 0
```

`invalidMoves.test.js:449-454` asserts it across the whole schema at the end of the suite.

The `settle` clamp `Math.max(0, chips + delta)` can in theory break the invariant if a negative delta
exceeded the balance — in production deltas are never negative at settlement (all stakes banked as bet),
and bookless unit tests never reach Postgres.

---

## 5. Consumers' expectations of the module API (for parity, not design)

| Caller | Call | Expects |
|---|---|---|
| `Table._startHand` | `ledger.collectBoot({roomId, handId, bootAmount, entries:[{userId, amount, balanceBefore}], version, state})` | `{balances, persisted}`; throws with `.code` and (for `insufficient_chips`) `.userId` |
| `Table._chargeToPot` | `ledger.bet({userId, amount, roomId, handId, actionId, reason, balanceBefore, version, state})` | `{balance, persisted}`; throws with `.code` |
| `Table._endHand` / `_retrySettle` | `ledger.settle({hand, entries, version, state})` | `{userId: balance}` (may be `{}`); throws |
| `RoomManager` | `createLedger()` | `{bet, collectBoot, settle}` |
| `auth/routes.js` | `upsertFromProfile`, `findById`, `recentHands`, `claimMilestoneReward`, `claimTimedBonus`, `setAvatarChoice`, `setDisplayName`, `normalizeDisplayName` | shapes in §4 |
| `socket/index.js` | `findById` | public user or null |
| `src/index.js` | `openDatabase()`, `closeDatabase()`, `getPool()` | — |
| tests | `query`, `dropSchema`, `applyChipDelta`, `settleHand`, `MILESTONE_*`, `TIMED_BONUS_*` | — |

---

## 6. Test cases to mirror

### 6.1 `test/statsAndRewards.test.js` (process suite, own schema `test_stats_<rand>`, `NODE_ENV=test`, `JWT_SECRET` set)

Setup: `openDatabase()` at module load; `makeUser(name)` = `upsertFromProfile({provider:'guest', providerUserId: 'stats-<seq>-<rand>', displayName})`;
`settle(entries, pot)` = `settleHand({hand:{id:'hand-<seq>-<rand>', roomId:'room-stats', handNo:1, pot, winnerId: first isWinner entry or null, winReason:'show', bootAmount:200, startedAt: now-1000, endedAt: now, summary: []}, entries})` — **no `version`/`state`**, so `saveState` is skipped and no `pots` row exists (settle tolerates both);
`setHandsPlayed(id, n)` = raw `UPDATE users SET hands_played = $1 WHERE id = $2`. Teardown `dropSchema(); closeDatabase()`.

| Test | Asserts |
|---|---|
| a hand only counts as played once the player bets beyond the boot | winner `{delta:400, isWinner, didChaal:true}` → `handsPlayed 1`; folder `{delta:-200, didChaal:false}` → `handsPlayed 0` |
| wins, losses and abandoned hands are counted separately | winner: won 1/lost 0/leftMid 0; loser (didChaal, not left): lost 1; quitter (didChaal, leftMidHand): leftMid 1, lost 0, played 1 |
| total winnings accumulate the pots taken | two wins with pots 1000 and 2500 → `totalWinnings 3500`, `biggestPot 2500`, `handsWon 2` (gross pot, not delta) |
| the milestone reward unlocks every 25 played hands | at 0: `milestoneAvailable false`, `handsToNextMilestone 25`; at 24: false, 1; at 25: true, `milestoneAt 25`, `milestoneReward 25000` |
| collecting the milestone reward grants 25,000 chips exactly once | hands=50: first claim `{claimed:true, amount:25000, milestone:50, user.chips: before+25000, user.rewards.milestoneAvailable:false}`; second `{claimed:false, reason:'not_available'}`, chips unchanged |
| reaching the next milestone unlocks the reward again | claim at 25 → true; at 49 available false; at 50 available true, claim true |
| the milestone reward is written to the chip ledger | one row `reason='milestone_reward'`, `delta 25000` |
| a new account can collect the timed bonus straight away | `bonusAvailable true`, `bonusReward 10000`, `bonusIntervalMs 14400000` |
| collecting the bonus grants 10,000 chips and starts a 4-hour countdown | `{claimed:true, amount:10000, user.chips: before+10000}`, `readyAt` within ±1 s of now+4h, `user.rewards.bonusAvailable false` |
| the bonus cannot be collected twice inside the countdown | second `{claimed:false, reason:'not_ready', readyAt > now}`, chips unchanged |
| the countdown lives in the database, so it survives a restart | `SELECT next_bonus_at` equals `result.readyAt`; after `UPDATE users SET next_bonus_at = now-1` → available and claim succeeds |
| a provider picture is kept and used by default | google profile with `avatarUrl` → `avatarUrl` and `providerAvatarUrl` equal it, `avatarChoice null` |
| a chosen picture overrides the provider one, and clearing restores it | `setAvatarChoice(id, '/profiles/ace.svg')` → `avatarUrl '/profiles/ace.svg'`, `providerAvatarUrl` unchanged; `setAvatarChoice(id, null)` → `avatarUrl` back to provider's |

### 6.2 `test/invalidMoves.test.js` (full server, schema `test_invalid_<rand>`, `BOOT_AMOUNT=100`, `TABLE_STAKES=''`, `LOBBY_TABLES=''`, fake providers on)

| Test | DB-relevant assertions |
|---|---|
| replaying a move with the same actionId charges nobody twice | chaal with `actionId:'dup-same-id'` ok; replay refused (`ok:false`, code is `not_your_turn` or `duplicate_action` depending on turn); `SELECT COUNT(*) FROM chip_ledger WHERE action_id='dup-same-id'` → `1`; wallet == before − stake |
| a player who cannot cover the boot is not seated | `applyChipDelta({userId, delta: -(chips-50), reason:'test_fixture', actionId:'poor-fixture'})` then quick-join → `insufficient_chips` (RoomManager check on the fresh `findById` balance) |
| after all of the above every wallet still equals its ledger | for every `users` row: `chips === COALESCE(SUM(delta),0)` from `chip_ledger` |

### 6.3 `test/integration.test.js` (full server)

| Test | DB-relevant assertions |
|---|---|
| guest login creates an account with the welcome chip grant | `isNew true`, `welcomeChips 200000`, `user.chips 200000`, `user.provider 'guest'`, `user.displayName 'Suraj'` |
| logging in again from the same device returns the same saved account | `isNew false`, `welcomeChips 0`, same `user.id`, same chips |
| a different device is a different account | different ids |
| the raw device id is never stored | every guest `provider_user_id` matches `/^[0-9a-f]{64}$/` and ≠ the raw device id |
| google and facebook logins create provider-scoped accounts | fake google/facebook each get 200000 chips and distinct ids; repeat google login reuses the id |
| /api/auth/me returns the persisted profile | `body.user.id`, `body.user.chips 200000` |
| a full hand … show (lines ~250-320) | after a show: winner's `/me` `chips > 200000`, `handsWon 1`; the show payer's `handsPlayed 1` ("paying for the show counts as playing") |

### 6.4 `test/lobbyRules.test.js` — `normalizeDisplayName`

| Test | Cases |
|---|---|
| a display name keeps letters, numbers and single spaces | `'  Suraj  Kumar '` → `'Suraj Kumar'`; `'Player7'` unchanged |
| a name may be written in any script | `'सूरज'`, `'সুরজ'` returned unchanged |
| an empty or blank name is refused | `''`, `'   '`, `'\t'`, `null`, `undefined` → `/empty_name/` |
| special characters are refused | `'Su<b>raj'`, `'a@b'`, `'hi!'`, `'--'`, `'x_y'`, `'drop;table'` → `/invalid_name/` |
| a name cannot start with a space or a digit-only decoration | `'   '` → empty_name; `'!Suraj'` → invalid_name |
| an over-long name is refused | `'a'.repeat(30)` with `maxLength 24` → `/name_too_long/` |
| names in Indic scripts survive their vowel marks | `'सूरज'`, `'সুরজ'`, `'સૂરજ'`, `'ਸੂਰਜ'`, `'प्रिया'` unchanged |

### 6.5 `test/chipPersistence.test.js` (unit, `memoryLedger` via `persistChips`/`settle` hooks — defines what the Table expects of *any* ledger)

| Test | Behaviour pinned |
|---|---|
| the boot leaves the account the moment it is posted | after the start timer both accounts are `START − BOOT`, `hand.pot = 2·BOOT`, before any action |
| every chaal is banked as it is made | after a chaal the account fell by `stake`; `seat.chips === account` |
| the winner is paid the pot and nobody is charged twice | winner `+pot`, loser unchanged at settlement, total conserved |
| a player who walks out mid-hand does not get their stake back | account stays `START − contributed` after `removePlayer` and after the hand ends |
| chips are conserved across a long hand of raises | total conserved |
| a seat and its account never disagree | after each chaal every active seat's `chips` equals its account |

`persistChips` receives `{userId, delta: -amount, reason: 'boot'|'bet'|'show', roomId, handId, actionId}`;
a throw refuses the move.

### 6.6 `test/settlement.test.js` — `a settled balance of zero is not treated as a failed settlement`

Table with `settle: () => every entry ↦ 0`; after the hand every seat has `chips === 0` (the winner is
**not** additionally credited the pot in memory). Pins the `hasOwnProperty` check in `_endHand`.

### 6.7 `test/tableRules.test.js` (unit, `settle` hook records `entries`)

`when a player leaves mid-hand …`, `destroying a table mid-hand pays the pot out …`,
`successive departures …` — pin that `Σ entries.delta === 0` for a bookless ledger and that
`entries` carries `leftMidHand`/`didChaal` correctly (`a player who leaves mid-hand is flagged for the
abandoned counter`, `a player who only posts the boot is not marked as having played`, `betting marks the
hand as played`).

### 6.8 `test/metrics.test.js:450-456, 510`

Requires `game_hand_start_duration_seconds_count ≥ 1`, `game_db_transaction_duration_seconds_count{op="boot"} ≥ 1`,
`{op="bet"} ≥ 1` with positive `_sum`, `game_settlement_duration_seconds_count ≥ 1` after real play.

---

## 7. Traps for the port

1. **int8/numeric come back as strings** from Postgres drivers unless told otherwise. Node parses OIDs 20
   and 1700 to numbers globally. In Go, scan BIGINT into `int64` and `SUM()`/`COUNT()` into `int64`
   (or `pgtype.Numeric` → int64) — never emit `"chips":"200000"`.
2. **`search_path` is a startup parameter**, not a `SET` per connection, and `openDatabase` still runs
   an explicit `SET search_path` on the bootstrap client before executing `schema.sql` because
   `'chip_ledger'::regclass` in the `DO` block resolves through it.
3. **`schema.sql` is executed as one multi-statement simple-protocol query.** Splitting on `;` breaks the
   `$$ … $$` function/DO bodies. Use a simple-protocol exec of the whole file.
4. **Timestamps are epoch milliseconds (BIGINT)**, one `Date.now()` per transaction shared by every row in
   it. Tests compare `next_bonus_at` to the returned `readyAt` with strict equality.
5. **`version` semantics**: the Table sends `table.version + 1`; the upsert updates only when
   `stored.version < new` (equal = `stale_state`); `saveState` is **skipped entirely** when `version` is
   `undefined`/`null`; settle writes `hand_id = NULL`; retries recompute `version` from the live table
   but reuse the original `state` snapshot.
6. **Idempotency keys are exact strings**: `"<handId>:boot:<userId>"`, `"<handId>:settle:<userId>"`,
   `"<userId>:milestone:<milestone>"`; client action ids are accepted only as non-empty strings ≤ 64
   chars, else the server invents a uuid; `welcome_bonus` and `timed_bonus` rows have `action_id NULL`.
7. **`duplicate_action` is detected by SQLSTATE `23505` plus the substring `action_id` in `detail` or
   `constraint`.** Any other unique violation is `persist_failed`. Every ledger failure must surface with
   a `.code`; the Table maps only `insufficient_chips` and `duplicate_action` to like-named client
   codes and everything else to `persist_failed`.
8. **`collectBoot`'s `insufficient_chips` must carry `userId`** — without it `_startRefused` does not kick
   the unfunded player and instead retries the start every 4 s forever.
9. **Lock ordering**: boot and settle lock wallets in ascending user-id order (string comparison);
   `bet` locks one wallet. Deadlocks between two tables sharing a player are avoided only by that order.
10. **Order of statements inside a transaction matters for failure semantics**: in `bet` the wallet is
    debited *before* the pot/ledger/state statements, so a duplicate action id or stale state rolls
    back the debit; `no_pot` is checked by `rowCount` of the `UPDATE pots`.
11. **`persisted`** is returned by the ledger (`amount` for bet, `bootAmount` for boot) and drives the
    Table's settlement arithmetic; a ledger returning `0` makes settlement move the whole net. Do not
    return `persisted: 0` from a real DB implementation.
12. **`settle` returns balances only for users that exist**; missing users are skipped, not errors. The
    Table checks **key presence**, not truthiness — a returned balance of `0` must be present as `0`
    (JSON `0`, not omitted), or the winner is paid twice in memory.
13. **Zero-delta ledger rows are written at settlement** for every contributor (`hand_loss`, delta 0).
    Removing them "because nothing moved" breaks the audit trail and `recentHands` (which joins through
    `chip_ledger.hand_id`).
14. **`hands_lost` is *not* incremented for a mid-hand leaver** even though their ledger row says
    `hand_loss`; `hands_left_mid` is. `hands_played` increments only when `didChaal`, which the Table sets after a
    successful chaal/raise (`table.js:1060`) **and** after a paid show (`table.js:1304`); a sideshow is
    free and does not set it. Posting the boot alone never counts.
15. **`total_winnings` and `biggest_pot` take the gross pot** (`hand.pot`), not the winner's net delta.
16. **`display_name` is overwritten on every login** with `profile.displayName || existing.display_name`.
    `email`/`avatar_url` use `COALESCE` (only replaced by non-null). Renames do not survive re-login.
17. **`avatarUrl = avatar_choice || avatar_url`** uses JS `||` — an empty-string `avatar_choice` falls
    through; `avatarChoice` uses `??` (empty string would be returned as `""`). The stored choice is the
    URL path `/profiles/<file>`, not the file id. The catalogue is re-read from disk per request and
    sorted by filename.
18. **`handsToNextMilestone` is `25` (not `0`) at an exact multiple**; use `milestoneAvailable`.
    `milestone_claimed` jumps to the *current* milestone on claim (skipped milestones are forfeited).
19. **`bonusAvailable` is computed at serialisation time** (`Date.now() >= next_bonus_at`) — two reads of
    the same row can differ.
20. **Name validation**: `\s+` → single space uses the JS `\s` class (includes NBSP and other Unicode
    spaces); length is UTF‑16 code units; the pattern uses Unicode categories `L`, `N`, `M` with the `u`
    flag. Error identity is the `Error.message` (`empty_name` / `name_too_long` / `invalid_name`), which
    the route copies into `{error}`.
21. **`upsertFromProfile` race on first login** ends in a raw unique-violation → HTTP 500; not a
    `LedgerError`. Guest ids are `sha256hex("teenpatti:" + trimmed deviceId)`.
22. **`ON DELETE CASCADE` on `chip_ledger.user_id` cannot actually fire** — the append-only trigger
    rejects the cascaded DELETE. Never rely on deleting users.
23. **`dropSchema` refuses `public`**; test suites must pick a unique `PG_SCHEMA` **before** loading
    anything that reads config (config is snapshotted at import).
24. **`closeDatabase` nulls the pool before `end()`** so late `getPool()` calls throw
    `database not open — call openDatabase() first` rather than hang.
25. **JSONB storage reorders keys**; do not test snapshot equality byte-wise against `game_states.state`
    — compare parsed content. `hands.summary_json` `cards` is `null` (JSON null) when not revealed, never
    `[]`.
26. **`recentHands` reads all of a user's hands and slices in memory** with `limit` clamped to 100 by the
    route; the dedupe is `DISTINCT ON (h.id)` because a user has up to N ledger rows per hand.
27. **Every `FOR UPDATE` is on `users` only**; `pots` and `game_states` are updated without an explicit
    lock (row-level lock acquired by the UPDATE itself). `hands` insert is `ON CONFLICT DO NOTHING` so a
    settle retry never fails on the hand record.
