# PORT_NOTES — internal/live (the live-state store)

Owner scope: everything under `internal/live/` except `store.go`, which is the contract
(`Store`, `Options`, `Open`, `ErrNotFound`, `ErrStale`, `TableRef`, `TableSummary`, `ResumeOffer`)
and was not modified. Architecture and invariants: `../LIVE_STATE_PLAN.md`.

## What is implemented

| File | Contents |
|---|---|
| `memory.go` | `Memory` — `NewMemory()` / `NewMemoryWithClock(func() time.Time)`. One mutex over seven maps; identical semantics to Redis (CAS on seq, lazy ttl expiry, capped chat, atomic take, fullest-first matchmaking). `Kind() == "memory"`. |
| `redis.go` | `Redis` — `OpenRedis(ctx, opts)` via `redis.ParseURL`; key prefix `opts.KeyPrefix` (default `kt:`), per-call `context.WithTimeout(opts.Timeout)` (default 500 ms) plus matching dial/read/write socket timeouts, `MaxRetries = 1`; pings on open and fails fast with `live: redis at <addr> (db N) unreachable: …`. `Kind() == "redis"`. |
| `hooks.go` | `Hooks{Observe func(op string, err error, d time.Duration)}` and `WithHooks(Store, Hooks) Store` — times every method except `Kind`; `Unwrap() Store` on the decorator. No prometheus import. |
| `common.go` | `ErrClosed`, `DefaultKeyPrefix`, `DefaultTimeout`, `auxTTL` (24 h), `HandIDOf(snapshot)`, shared bucket naming and candidate ordering. |
| `*_test.go` | Conformance suite (`conformance_test.go`) run by `memory_test.go`, `redis_test.go` (miniredis + real server); Redis key-schema, index-repair, corrupt-value, fail-fast and per-call-timeout tests; hooks test; `HandIDOf` test; `bench_test.go`. |

`deps_keep.go` is deleted (the real files import go-redis and miniredis).

## Key schema as built (prefix `kt:`)

| Key | Type | Content | Expiry |
|---|---|---|---|
| `kt:table:<roomId>` | hash | `seq`, `snapshot` (JSON bytes), `handId` (from `snapshot.hand.id`, empty between hands), `updatedAt` (epoch ms, process clock) | `PEXPIRE ttl` on every save (`ttl <= 0` → `PERSIST`) |
| `kt:tables` | set | room ids with a stored snapshot | none; `ListTables` `SREM`s members whose hash has expired |
| `kt:chat:<roomId>` | list | serialised messages, oldest first; `RPUSH` + `LTRIM -max -1` (`max <= 0` → uncapped) | `PEXPIRE 24h` refreshed on every append (safety net, see decisions) |
| `kt:seat:<userId>` | string | roomId | **none** — `ClearSeated` is the only way out |
| `kt:online` | hash | userId → `<instance>\|<expiresAtMs>` | per entry, by stamp; `OnlineCount` reaps |
| `kt:resume:<userId>` | string | `ResumeOffer` JSON (`{"roomId","code","category","bootAmount","at"}`) | `SET PX ttl` |
| `kt:lobby:<category>:<boot>` | zset | roomId scored by `Players`; private tables are `ZREM`med, never added | none |
| `kt:summary:<roomId>` | hash | `roomId code category bootAmount players maxPlayers isPrivate(0/1) state createdAt instance` | `PEXPIRE 24h` refreshed on every publish |

Atomicity: `SaveTable` and `OnlineCount` are Lua scripts (`redis.NewScript`, EVALSHA with EVAL
fallback); `TakeResumeOffer` is `GETDEL`; `DeleteTable`, `AppendChat`, `PublishTable`, `RetireTable`
are `MULTI`/`EXEC` (`TxPipelined`); `ListTables` and `Candidates` are `SMEMBERS`/`ZREVRANGE WITHSCORES`
followed by one pipeline of `HGET`/`HGETALL`.

```lua
-- SaveTable  KEYS: table hash, tables set   ARGV: seq, snapshot, handId, updatedAt, ttlMs, roomId
local stored = redis.call('HGET', KEYS[1], 'seq')
if stored and tonumber(stored) >= tonumber(ARGV[1]) then return 0 end        -- → ErrStale
redis.call('HSET', KEYS[1], 'seq', ARGV[1], 'snapshot', ARGV[2], 'handId', ARGV[3], 'updatedAt', ARGV[4])
if tonumber(ARGV[5]) > 0 then redis.call('PEXPIRE', KEYS[1], ARGV[5]) else redis.call('PERSIST', KEYS[1]) end
redis.call('SADD', KEYS[2], ARGV[6])
return 1

-- OnlineCount  KEYS: online hash   ARGV: nowMs
-- HGETALL; count entries whose "<instance>|<expiresAtMs>" stamp is > now; HDEL the rest; return count
```

## Decisions

- **Online presence stores an absolute expiry stamp, not the write time.** The plan's table said
  `instance|epochMs`; the value is `instance|expiresAtMs` = process clock + the `ttl` the caller passed
  to `SetOnline`. `OnlineCount` therefore needs no knowledge of anyone's heartbeat interval — it
  compares stamps with `now` (also the process clock, passed in as `ARGV`) and reaps expired fields in
  the same script, so the hash cannot grow with crashed processes' ghosts and a refresh landing
  between a read and a delete cannot be lost. Consequence: **instances must share a sane wall clock**
  (NTP). With the planned 30 s heartbeat / 90 s ttl, skew of a few seconds is invisible. The memory
  store does the same with the injected clock.
- **Chat lists and lobby summaries carry a 24 h safety-net ttl** (`auxTTL`, refreshed on every write).
  The interface gives those methods no ttl and the plan lists none, but without one a process that
  dies and never comes back leaks its tables' chat and summaries forever once the table hash has
  expired. 24 h matches the default `LIVE_STATE_TTL_MS`; a live table writes far more often than that.
  **Seat keys have no ttl** (as planned): a seated player can sit for days, and `SeatOf` turning into
  `ErrNotFound` for a live seat would be worse than a leaked key — so `ClearSeated` on every
  leave/kick/destroy path is the integrator's job.
- **`DeleteTable` deletes only the hash and the set member.** Chat (`DeleteChat`) and the lobby entry
  (`RetireTable`) have their own methods; destroying a table means calling all three.
- **Candidates ordering is total**: players desc, `createdAt` asc, then `roomId` asc. The sort uses the
  summary's `players`, not the zset score (they agree because publish is one `MULTI`). Zset members
  whose summary is missing are skipped, not removed; corrupt numeric fields read as 0. Full tables are
  returned too — the caller filters `Players < MaxPlayers`.
- **A re-publish that moves buckets** (or flips to private) un-indexes the old entry in the memory
  store; on Redis the old bucket keeps a member with a valid summary (Redis has no cheap "previous
  bucket" lookup) — a table never changes category/boot in this game, so this is theoretical.
- **`max <= 0` in `AppendChat` means uncapped**, `ttl <= 0` in `SaveTable`/`SetOnline`/`PutResumeOffer`
  means no expiry (Redis: `PERSIST` / no `PX`; memory: far future). Nothing validates `seq > 0`: an
  empty table accepts any seq, exactly like the Lua `HGET → nil` path.
- **`ListTables` is sorted by room id** and repairs `kt:tables` as a side effect; `LoadChat`,
  `Candidates`, `ListTables` return empty non-nil slices.
- **Every method honours a cancelled context** (memory checks `ctx.Err()` first) and **fails after
  `Close`** (memory: `ErrClosed`; Redis: go-redis's "client is closed").
- **Memory sweep**: reads expire lazily; additionally any mutation landing ≥ 1 min after the previous
  sweep walks every map once and drops expired entries, so a single instance cannot accumulate
  resume offers nobody ever takes.
- `HandIDOf` streams tokens and stops at the top-level `"hand"` member (which `game.Snapshot` emits
  before `seats`), ~2.7 µs on a 20 KB snapshot versus 25 µs for a full unmarshal.

## Redis requirements

- **Redis ≥ 6.2** for `GETDEL` (Redis 7.4 in production; miniredis v2.39 supports it). Lua scripting
  (`EVAL`/`EVALSHA`/`SCRIPT LOAD`) is 2.6+. Scripts are loaded lazily (first call per process = two
  round trips).
- **Not Redis-Cluster safe as written**: `SaveTable` touches `kt:table:<id>` and `kt:tables` in one
  script, `DeleteTable`/`PublishTable`/`RetireTable` mix keys in one `MULTI`. Hash tags would be needed
  for cluster; the plan is a single instance with `noeviction`.
- `maxmemory-policy noeviction` matters: with an eviction policy Redis could drop a table hash
  silently; nothing here detects that beyond `LoadTable → ErrNotFound`.
- go-redis emits one log line (`connection pool: failed to dial …`) when a server is unreachable;
  `OpenRedis` still returns the wrapped error promptly (tested < 3 s with a 300 ms timeout).

## Tests

`go test -race ./internal/live/...` — 4–5 s, all green; repeated `-count=4` green.

| Suite | Backend | Notes |
|---|---|---|
| `TestMemoryConformance` | `NewMemoryWithClock(fakeClock)` | ttl 1 h, `advance` = clock step |
| `TestMiniredisConformance` | miniredis in-process | ttl 1 h, `advance` = `FastForward` + shifted store clock |
| `TestRealRedisConformance`, `TestRealRedisScripts` | real `redis-server` | uses `REDIS_TEST_URL` when set, else starts `$HOME/.local/bin/redis-server` (or `redis-server` on PATH) on a free port with `--save "" --appendonly no`, kills it in `Cleanup`; skips when neither exists. ttl 300 ms, `advance` = `time.Sleep`. Random key prefix per subtest, prefix keys `SCAN`+`DEL`ed after. |

Conformance subtests (15, each on a fresh store): KindAndPing, SaveTableCAS (1, 2 ok; 2 → `ErrStale`;
1 → `ErrStale`; load = 2), LoadAfterSave (20 KB, store owns its copy), TTLExpiry (expire → `ErrNotFound`,
list empty, seq restarts; a save refreshes the ttl), DeleteThenLoad, ListTables (mixed saves/deletes,
sorted), ChatCapAndOrder (7 in / cap 5 → last five; uncapped; per-room delete), Seats, OnlineCountWithExpiry
(refresh is not a second entry; heartbeat keeps one alive across the boundary; full expiry → 0),
ResumeOffers (put/take/take-again → `ErrNotFound`; delete; replace; expiry), MatchmakingOrder (fullest
first, ties oldest first, private excluded, other bucket separate, re-publish reorders, retire removes,
idempotent), ConcurrentSaves (seqs 1..100 each offered by two goroutines: at most one winner per seq,
seq 100 wins, final load is seq 100's own snapshot), ConcurrentTakeResumeOffer (8 racers × 5 rounds →
exactly one winner), CancelledContext, Closed.

Redis-only: `TestRedisKeySchema` (every key/field/ttl of the table above, on prefix `kt:`),
`TestRedisListTablesRepairsIndex`, `TestRedisCorruptValues` (bad seq → error; bad offer JSON → error
and consumed; junk summary numbers → zeros; ghost zset member skipped), `TestOpenRedisFailsFast`
(bad URL, empty URL, closed port names addr + db, `Open` dispatch, defaults), `TestRedisPerCallTimeout`
(silent server → error in ≈ timeout with a deadline-less context). Memory-only: sweep bounds, `ErrClosed`,
bucket move on re-publish. Hooks: every `Store` method except `Kind` observed under its snake_case op
name, errors passed through unchanged, nil `Observe` returns the store itself.

Benchmarks (`go test -run '^$' -bench . -benchmem ./internal/live/`, 20 KB snapshot, this laptop):

```
BenchmarkSaveTable/memory      2.7 µs/op     20.5 KB/op   2 allocs
BenchmarkSaveTable/miniredis   210 µs/op     257 KB/op    834 allocs   (gopher-lua; not representative)
BenchmarkSaveTable/redis       111 µs/op     1.1 KB/op    25 allocs    (real 7.4.2 on 127.0.0.1, REDIS_TEST_URL set)
BenchmarkHandIDOf              2.7 µs/op
```

## Integrator notes

- `live.Open(ctx, Options{URL: cfg.RedisURL, Instance: cfg.LiveInstanceID, Timeout: 500ms})` — empty
  URL → `*Memory`; set URL → `*Redis` or a fail-fast error to abort startup with.
- Wrap once: `store = live.WithHooks(store, live.Hooks{Observe: func(op string, err error, d time.Duration) {…}})`.
  Classify `err` with `errors.Is`: `nil` → `ok`, `live.ErrNotFound` → `not_found` (a normal miss),
  `live.ErrStale` → `stale` (fencing event, worth its own counter/alert), anything else → `error`
  (feeds `game_live_store_errors_total{op}`). Op names: `save_table load_table delete_table list_tables
  append_chat load_chat delete_chat set_seated clear_seated seat_of set_online set_offline online_count
  put_resume_offer take_resume_offer delete_resume_offer publish_table retire_table candidates ping close`.
- `ErrStale` from `SaveTable` is the two-owners guard (plan invariant 5): the table must fence itself.
  Any other `SaveTable` error is logged and counted, never turned into a refused move (invariant 1).
- On destroy call `DeleteTable` + `DeleteChat` + `RetireTable` + `ClearSeated` for each seat; on
  startup `ListTables` → `LoadTable` → restore; tables that fail to parse → `DeleteTable`.
- `SetOnline` every ~30 s per live socket with `ttl = 90 s`; `SetOffline` on disconnect. `OnlineCount`
  is one script call — fine at scrape rate, not per request.
- `Candidates` includes full tables and tables owned by other instances (`Instance` field); filter
  as needed. Publish on every change (`PublishTable` is idempotent and cheap).
- All ttls are millisecond-granular on Redis (`PEXPIRE`/`PX`); a ttl between 0 and 1 ms rounds to
  "no expiry".
- `NewMemoryWithClock` is exported for other packages' tests that drive expiry from a fake clock.
- `gofmt -l` flags `store.go` (one comment-alignment line in `TableSummary`); it was left untouched
  because it is the shared contract — whoever next edits `store.go` should run gofmt on it.
