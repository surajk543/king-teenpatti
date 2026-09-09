# Port decisions

Answers to every ambiguity the behavioural specs raised about the Node server. Porters follow
these without re-deciding; reviewers check against them. The rule behind them:

> **Anything a shipped client or the database can observe on a success path is reproduced
> exactly. Latent bugs that no client relies on are fixed, and every fix is listed here.**

"Node" below means `server/src` as it was before the Node server was removed from the repository
(8 Sep 2026; `git log -- server/`, last commit carrying it `c19963b`). "Deviation" means the Go
server behaves differently from Node on purpose.

## 1. Wire format

| Topic | Decision |
|---|---|
| JSON key order | Not required. Field *sets*, names, types and null/absent/empty rules are required. Go structs give a stable order anyway. |
| Duplicate consecutive `room:state` | Not required to match in count. The final snapshot must match. The parity harness collapses consecutive identical `room:state` per viewer. |
| Join-side event order (`room:state` before `room:joined`, leaver's traffic before `room:left`, mover's `room:closed` before `room:moved`/`room:joined`) | **Reproduce exactly.** Flutter's screen switching depends on `room:closed` never arriving *after* the new `room:joined`. |
| Spurious `game:turn` for an asker who leaves during a pending sideshow | Either behaviour is acceptable; not asserted. Port the Node sequence and let it fall out. |
| Long polling | **Deviation.** Not implemented. `transport=polling` gets HTTP 400 `{"code":0,"message":"Transport unknown"}`. Every shipped client is websocket-only or websocket-first without fallback. |
| `/socket.io/socket.io.js` | Served by the Go server from an embedded copy of the socket.io client bundle (`internal/app/assets/socket.io.min.js` + its MIT `LICENSE`, copied from the former `server/node_modules/socket.io/client-dist/socket.io.min.js`), so the browser reference client works unchanged. `.min.js` also served. |
| Engine.IO `sid` | Opaque 20-char base64url id; alphabet need not match `base64id`. |
| `?token=` query on the handshake | Kept (Node accepts `handshake.query.token`). |
| Handshake failure message | **Deviation.** Always the auth code (`missing_token`, `invalid_session`, `unknown_user`, `unauthorized`). A database error during `findById` is `unauthorized`, never a SQLSTATE. |
| Unknown inbound event | Never acked (same as Node). Malformed packet closes the connection. |
| `REDIS_URL` | Read, logged as ignored. No adapter. |

## 2. Rules engine

| Topic | Decision |
|---|---|
| Ladder first rung `min(base, perBetCeiling)` | Reproduce (the tests exercise it). |
| Config keys Node leaves undefined to disable a feature (`maxBlindMoves`, `maxMissedTurns`, `sideshowMinPlayers`, `sideshowTimeoutMs`) | In Go, **0 means disabled/never triggers** for those four, and 0 means **unlimited** for `MaxBetRounds`, `PotLimitMultiplier`, `MaxRaiseSteps`, `MaxPot`. RoomManager always sets every field explicitly. Go unit tests pass explicit values. |
| Settle retry hitting `duplicate_action` | **Deviation.** Treated as success (the write already landed). Retries recompute `version` from the live table and resend the original snapshot, as Node does. |
| `_startRefused` when the unfunded user is not seated | Same as Node: no retry timer; the next add/remove restarts the table. |
| `pickWinner` in handRank | Ported (exported, unit-tested), Table keeps its own tie loop as Node does. Both must agree; a test checks that. |
| Boot refusal for errors other than `insufficient_chips` | Same as Node: retry every `nextHandDelayMs`. |
| `collectBoot` statement order (pots row after wallet updates) | Same as Node. |
| Lock ordering of wallets | Byte-wise ascending user id (ids are ASCII uuids). |
| Missing-key semantics of `balances` | Key presence, never truthiness. A balance of 0 is valid. |
| Settle retry pending when the table is destroyed (last player leaves, consolidation, sweep, shutdown) | **Deviation (money).** Node's retry callback returned on `_destroyed` and the pot was never banked. Go continues the idempotent write off the actor (`Table.settleDetached`, same back-off and 10-attempt cap, no Listener events); `RoomManager.Shutdown` waits for it within its budget and `destroyTable` logs the outcome (`Table.WaitSettlements`). |
| `settle` statement order | **Deviation (money).** Wallet locks (ascending) come first; `INSERT INTO hands` follows them. Node inserted the hands row first, whose `winner_id` FK took a KEY SHARE on the winner's row out of order and could deadlock against another table's `collectBoot` (`db/review_money_test.go`). Rows written are identical. |
| Client `actionId` containing `:` | **Deviation (money).** Dropped (fresh uuid) in the socket layer and again in `Table.chargeToPot`. Every server-generated `chip_ledger.action_id` is colon-separated and `<userId>:milestone:<n>` fits in 64 chars, so Node let one player pre-occupy another's milestone key with a bet and block that reward for good. Real clients send uuids / plain tokens. |

## 3. RoomManager

| Topic | Decision |
|---|---|
| `room:create {isPrivate:false}` (public table at any boot, no chips check) | **Deviation (security).** A public create is validated like `quickJoin`: `invalid_stake`, `table_not_offered`, `insufficient_chips`, `over_entry_cap`, in that order. Private create is unchanged (boot forced to `privateBoot`). |
| `room:create` by a seated player | **Deviation.** `already_in_room` is checked *before* any table is created. No orphan table. |
| `switchTable` failure after leaving | **Deviation.** The seat on the source table is restored (as `_movePlayer` does). If the source is gone, the player gets `room:left` and the error. |
| Room code collisions | **Deviation.** Codes are regenerated until unique among live tables. |
| `LOBBY_TABLES` with an unknown category | **Deviation.** Rejected at config load with a clear error. |
| Consolidation order and copying chips from the seat | Same as Node. |
| Sweeper interval and the hardcoded 30 s empty-table age | Same as Node; the sweeper uses the injected Clock. |

## 4. Text handling (chat, names)

| Topic | Decision |
|---|---|
| Length caps (140 chat, 24 names) | Counted in **UTF-16 code units** as Node does, so emoji count as 2. Truncation never splits a surrogate pair: the lone high half is dropped. |
| Stripping `\p{C}` | Strip every rune in Unicode category C (Cc, Cf, Co, Cs) **and** every unassigned rune (no category at all). ZWJ is stripped, as in Node. |
| Whitespace class for collapsing | Go `unicode.IsSpace` **plus** U+FEFF, matching JS `\s`. |
| Non-string `text`/`displayName` on the wire | Numbers are coerced to their decimal string as Node's `String()` does; objects/arrays/booleans/null are treated as empty. |
| Unicode-version differences between V8 and Go tables | Accepted. |
| Display name overwritten on every login (requirement 29) | Same as Node. Known and still unresolved; outside this port's scope. |

## 5. Auth and REST

| Topic | Decision |
|---|---|
| JWT | HS256 only for both signing and verification (**deviation**: Node also accepted HS384/HS512 with the same secret). Claims `sub`, `provider`, `name`, `iat`, `exp`. Tokens minted by Node must verify in Go and vice versa. |
| `JWT_EXPIRES_IN` | Parsed with `ms` grammar: a bare number string is **milliseconds**; `s m h d w y` units supported; `30d` default. |
| Body parse failures | **Deviation.** HTTP 400 `{"error":"invalid_json","message":...}`; bodies over 32 kB → 413 with the same envelope. Missing or empty body → `{}`. |
| Unknown `/api/*` path or method | **Deviation.** JSON 404 `{"error":"not_found","message":"Cannot GET /path"}`. Static 404s are plain text. |
| `GET /api/rooms` | Ported (no client calls it; cheap). `GET /api/auth/me/hands` was ported too, then **removed on 9 Sep 2026** with the `hands` table it read — it now 404s. |
| Guest `deviceId` | Must be a JSON string of at least 8 chars after trim; anything else → 400 `invalid_device_id`. (**Deviation**: Node coerced numbers/objects.) |
| Concurrent first logins for one identity | **Deviation.** Handled: on a unique violation the insert is retried as an update path; exactly one welcome bonus is ever written. |
| Fake providers (`AUTH_ALLOW_FAKE_PROVIDERS`) | Kept, including the raw-displayName-then-`fake` provider-user-id fallback. Production refuses to start with it on. |
| `/health` | Same keys. `process.node` = Go runtime version (e.g. `go1.27.1`); `heapUsedMb`/`heapTotalMb` from `runtime.MemStats`; `externalMb` = 0; `cpuPercent` = share of one core since the previous call; `loopLagP50Ms/P99Ms/MaxMs` = Go scheduler latency percentiles since the previous call (`runtime/metrics` `/sched/latencies:seconds`). Extra fields `goroutines`, `numCpu`, `gomaxprocs`. `db.waiting` = pool `EmptyAcquireCount` delta or 0. |
| Static files | Same behaviour as `express.static` for GET/HEAD, index.html at `/`, dotfiles hidden, `.svg` as `image/svg+xml`. The browser client lives in `go-server/public`; `PUBLIC_DIR` (new env key) defaults to `./public` relative to the working directory (`go-server/`), falling back to `go-server/public` when the binary is started from the repository root. |
| `METRICS_ALLOW_IPS` | Raw TCP peer address, no `X-Forwarded-For` (same as Node). |
| `.env` | Loaded from the working directory if present, never overriding real env (same as dotenv). |
| Env integer parsing | **Deviation.** Strict decimal integers; malformed values fail startup with a clear error. Empty string keeps Node's meaning (`TABLE_STAKES=` and `LOBBY_TABLES=` mean unrestricted). |
| `METRICS_PREFIX` | Kept configurable, default `game_server_`. |
| Hung database statements | **Deviation (Go-only key).** `PG_STATEMENT_TIMEOUT_MS` (default 15000) sets Postgres `statement_timeout` on every pooled connection, so a hung query fails one ledger write (`persist_failed`, the move is refused) instead of freezing that table's actor for good. Node had no limit; `0` restores that. |

## 6. Metrics

| Topic | Decision |
|---|---|
| `game_*` metrics | Identical names, types, labels, help and buckets. `game_tables` is a scrape-time collector (reset-and-recount). Labelled series appear on first use, as in Node. |
| Node runtime metrics (`game_server_nodejs_*`) | Not emitted. Instead the Go process collector under `game_server_process_*` and the Go runtime collector under `game_server_go_*` (goroutines, GC, heap, `go_sched_latencies_seconds`). `game_server_process_uptime_seconds` kept. |
| Dashboard and alerts | The Grafana "Node.js" row becomes a "Go runtime" row and the three Node-only alerts are rewritten in a later ops phase; the game rows work unchanged. |

## 7. Tests

| Topic | Decision |
|---|---|
| Chat history cap (100) | White-box Go unit test on the chat buffer. |
| `bootAmount: null` on `room:quickJoin` | Wire behaviour is authoritative: null = default boot. |
| Node metrics test #2 (nodejs names) | Rewritten for the Go names above. |
