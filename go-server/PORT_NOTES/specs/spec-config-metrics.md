# Spec: Configuration, Prometheus metrics, logger and id generation

Behavioural specification of the Node server's configuration layer, Prometheus exposition, JSON logger
and id helpers, as implemented in the working tree of `/home/suraj/Project/king-teenpatti/server` on
2026-09-08 (branch `go-server`, HEAD `db2ae22`). Every rule cites `file:line` in `server/src/` unless
another directory is named. "MUST MATCH" marks wire/DB/exposition behaviour that clients, Prometheus,
Grafana or the alert rules depend on; "INCIDENTAL" marks internal naming and logging that the port
may reproduce but nothing external observes.

Sources read in full: `config/index.js`, `.env.example`, `metrics/index.js`, `util/logger.js`,
`util/ids.js`, `index.js`, `socket/index.js` (metric call sites), `game/roomManager.js` (config
consumers, `lobbyOptions`, `createTable`), `db/ledger.js` (ledger metric wiring), `db/index.js`
(pool config), `auth/tokens.js`, `game/constants.js`, `test/metrics.test.js`, `test/stakes.test.js`,
`test/lobbyRules.test.js`, `test/privateTables.test.js`, `test/integration.test.js` (config
assertions), `ops/monitoring/prometheus/alerts.yml`, `ops/monitoring/prometheus/prometheus.yml`,
`ops/monitoring/grafana/dashboards/king-teenpatti.json`, `ops/monitoring/nginx/king-teenpatti.conf.example`,
`ops/monitoring/MONITORING.md`. Library versions that shape the output: `prom-client` 15.1.3,
`dotenv` 16.6.1, Node v22.22.1.

---

## 1. Configuration (`config/index.js`)

### 1.1 Loading model

| Rule | Source |
|---|---|
| The first statement is `import 'dotenv/config'`. dotenv 16 reads the file `path.resolve(process.cwd(), '.env')` — **relative to the process working directory, not to the source tree** — and sets each `KEY=value` into `process.env` **only if the key is not already set**. A missing `.env` is silent. There is no `server/.env` in the repo, so the shipped server runs on defaults. | config/index.js:1; dotenv 16.6.1 default behaviour |
| The whole `config` object is built **once, at module import**, from `process.env`. Nothing re-reads the environment later. Tests therefore set `process.env.*` *before* `await import(...)`. | config/index.js:23-211; test/metrics.test.js:16-38 |
| `rootDir` = the directory two levels above `src/config/` → the `server/` directory. It is used for `express.static(path.join(rootDir, 'public'))` (index.js:100) and by `auth/routes.js:20` (profiles directory). | config/index.js:5, 210 |
| `LOG_LEVEL` is **not** part of `config`; `util/logger.js:2` reads `process.env.LOG_LEVEL` directly at its own import. | util/logger.js:2 |

### 1.2 Parsers (MUST MATCH — these decide what a given env string becomes)

```
num(value, fallback):   parsed = Number.parseInt(value ?? '', 10); Number.isFinite(parsed) ? parsed : fallback
bool(value, fallback=false): (value === undefined || value === '') → fallback;
                             else ['1','true','yes','on'].includes(String(value).toLowerCase())
list(value):            String(value ?? '').split(',').map(trim).filter(nonEmpty)
```
(config/index.js:7-21)

Exact consequences of `num` (JavaScript `parseInt` semantics, base 10):

| Input | Result |
|---|---|
| unset / `''` / `'abc'` / `'  '` | fallback |
| `'200'`, `' 200 '` (leading whitespace ok), `'+200'`, `'-5'` | 200, 200, 200, **-5** (negatives are accepted; nothing validates sign or range) |
| `'200.9'` | **200** (truncated, not rounded) |
| `'12abc'`, `'1e3'`, `'0x10'`, `'1_000'` | **12**, **1**, **0**, **1** (parse stops at the first non-digit) |
| `'Infinity'` | fallback (parseInt → NaN) |

Exact consequences of `bool`: only unset or the empty string yield the fallback; any other string is
lower-cased and compared against the four truthy words, so `'TRUE'`, `'Yes'`, `'on'`, `'1'` → true and
`'false'`, `'0'`, `'no'`, `'off'`, `'garbage'` → false.

`list`: `'a, b,,c '` → `['a','b','c']`; `''` → `[]`; `', ,'` → `[]`.

### 1.3 Every env key

`??` means "used only when the variable is **undefined**"; an empty string is *not* undefined, so
`FOO=` in `.env` passes `''` through (which `num` turns into the fallback, but which string keys keep as
`''`). Column "Type" is the JS type of the resulting field.

#### Top level

| Env | Field | Parse | Default | Type | Notes / consumer |
|---|---|---|---|---|---|
| `NODE_ENV` | `env` | raw `??` | `'development'` | string | `'production'` arms §1.5 guards. `'test'` has no special meaning inside config. Logged at startup (index.js:148). |
| `PORT` | `port` | `num` | `3000` | int | `server.listen(port, host)` (index.js:145). Tests use `'0'`. |
| `HOST` | `host` | raw `??` | `'0.0.0.0'` | string | index.js:145 |
| `CORS_ORIGIN` | `corsOrigin` | see §1.4.1 | `'*'` | `'*'` or string[] | Socket.IO `cors.origin` only (index.js:116). Express has **no** CORS middleware. |
| `JWT_SECRET` | `jwt.secret` | raw `??` | `'dev-only-insecure-secret'` | string | HMAC key for `jsonwebtoken.sign/verify` (auth/tokens.js:9,17). |
| `JWT_EXPIRES_IN` | `jwt.expiresIn` | raw `??` | `'30d'` | string | passed verbatim as `expiresIn` to `jwt.sign` (auth/tokens.js:10): a string is parsed by the `ms` grammar (`'30d'`, `'12h'`, `'60s'`), a numeric string like `'3600'` is **seconds**. |
| `GOOGLE_CLIENT_IDS` | `google.clientIds` | `list` | `[]` | string[] | empty → google login answers 503 `provider_unconfigured` (auth/providers.js:24). |
| `FACEBOOK_APP_ID` | `facebook.appId` | raw `??` | `''` | string | auth/providers.js:73 |
| `FACEBOOK_APP_SECRET` | `facebook.appSecret` | raw `??` | `''` | string | auth/providers.js:59,63 |
| `AUTH_ALLOW_FAKE_PROVIDERS` | `allowFakeProviders` | `bool(…, false)` | `false` | bool | auth/providers.js:131,147,151; §1.5 guard |
| `REDIS_URL` | `redisUrl` | raw `??` | `''` | string | truthy → Socket.IO redis adapter is dynamically imported and attached (index.js:125-133). RoomManager stays process-local, so multi-process is not functional. |
| — | `rootDir` | computed | `<repo>/server` | string | §1.1 |

#### `db`

| Env | Field | Parse | Default | Notes |
|---|---|---|---|---|
| `DATABASE_URL` | `db.url` | raw `??` | `'postgres://postgres:postgres@localhost:5432/gameplay'` | `pg.Pool({connectionString})` (db/index.js:44). Logged **redacted**: `url.replace(/\/\/([^:]+):[^@]+@/, '//$1:***@')` (db/index.js:119-121). |
| `PG_SCHEMA` | `db.schema` | raw `??` | `'public'` | Validated at `openDatabase`: must match `/^[A-Za-z_][A-Za-z0-9_]*$/` else `throw new Error('PG_SCHEMA must be a plain identifier, got "<schema>"')` (db/index.js:35-37). Applied as a pool **connection option** `-c search_path=<schema>,public` (db/index.js:47), plus `CREATE SCHEMA IF NOT EXISTS "<schema>"` and `SET search_path TO "<schema>", public` on the bootstrap client (db/index.js:52-53). Tests use `test_<suite>_<6 base36 chars>`. |
| `PG_POOL_MAX` | `db.poolMax` | `num` | `10` | `pg.Pool({max})` (db/index.js:46). |

#### `game` (every key is copied into every `Table`'s config via `...config.game` — see §1.6.1)

| Env | Field | Parse | Default | Notes |
|---|---|---|---|---|
| `WELCOME_CHIPS` | `welcomeChips` | `num` | `200000` | new-account grant (db/users.js:118); echoed in login response `welcomeChips` (auth/routes.js:75); `publicGameConfig.welcomeChips`. |
| `BOOT_AMOUNT` | `bootAmount` | `num` | `200` | default boot when a join/create omits `bootAmount` (socket/index.js:493,510; roomManager.js:100,232); `publicGameConfig.bootAmount`. |
| `TABLE_STAKES` | `tableStakes` | §1.4.2 | `[200, 5000]` | allowed boots for quick-join; **empty list = no restriction**. |
| `LOBBY_TABLES` | `lobbyTables` | §1.4.3 | `[{seen,200},{blind,200},{blind,5000}]` | the lobby menu, in order; **empty list = any pair**. |
| `MAX_PLAYERS_PER_ROOM` | `maxPlayers` | `num` | `5` | Table seats; `publicGameConfig.maxPlayers`. |
| `MIN_PLAYERS_TO_START` | `minPlayers` | `num` | `2` | `publicGameConfig.minPlayers`. |
| `TURN_TIMEOUT_MS` | `turnTimeoutMs` | `num` | `25000` | `publicGameConfig.turnTimeoutMs`. |
| `MAX_BET_ROUNDS` | `maxBetRounds` | `num` | `20` | **Default only** — overridden per category at table creation (§1.6.2). Still what `publicGameConfig.maxBetRounds` reports. |
| `POT_LIMIT_MULTIPLIER` | `potLimitMultiplier` | `num` | `1024` | default; blind tables override to `blindPotLimitMultiplier`; seen tables **keep** this value. |
| `MAX_RAISE_STEPS` | `maxRaiseSteps` | `num` | `8` | default; overridden by seen/blind/private rules. |
| `SEEN_MAX_RAISE_STEPS` | `seenMaxRaiseSteps` | `num` | `2` | |
| `SEEN_MAX_BET_ROUNDS` | `seenMaxBetRounds` | `num` | `7` | |
| `SEEN_MAX_POT` | `seenMaxPot` | `num` | `1200000` | `0` = uncapped. Reported per menu entry as `tables[i].maxPot` for seen entries. |
| `BLIND_MAX_RAISE_STEPS` | `blindMaxRaiseSteps` | `num` | `0` | 0 = unlimited |
| `BLIND_MAX_BET_ROUNDS` | `blindMaxBetRounds` | `num` | `0` | 0 = no forced showdown |
| `BLIND_POT_LIMIT_MULTIPLIER` | `blindPotLimitMultiplier` | `num` | `0` | 0 = no per-bet ceiling |
| `MAX_BLIND_MOVES` | `maxBlindMoves` | `num` | `4` | reported as `tables[i].maxBlindMoves` on every menu entry. |
| `ENTRY_CAP_BOOT` | `entryCapBoot` | `num` | `200` | §1.6.5 |
| `ENTRY_CAP_CATEGORY` | `entryCapCategory` | raw `??` | `'blind'` | **not validated** against `seen`/`blind`; compared with `!==` to the resolved category. |
| `ENTRY_CAP_MAX_CHIPS` | `entryCapMaxChips` | `num` | `500000` | `0` disables the cap (`if (!cap) return`). |
| `MAX_MISSED_TURNS` | `maxMissedTurns` | `num` | `3` | |
| `SIDESHOW_TIMEOUT_MS` | `sideshowTimeoutMs` | `num` | `6000` | `publicGameConfig.sideshowTimeoutMs` |
| `SIDESHOW_MIN_PLAYERS` | `sideshowMinPlayers` | `num` | `3` | `publicGameConfig.sideshowMinPlayers` |
| `DISPLAY_NAME_MAX` | `displayNameMaxLength` | `num` | `24` | auth/routes.js:208,213 (rename endpoint). |
| `PRIVATE_MAX_POT` | `privateMaxPot` | `num` | `500000` | `lobbyOptions.privateMaxPot` |
| `PRIVATE_MAX_RAISE_STEPS` | `privateMaxRaiseSteps` | `num` | `2` | |
| `PRIVATE_BOOT` | `privateBoot` | `num` | `200` | `lobbyOptions.privateBoot`; forced boot of every private table. |
| `NEXT_HAND_DELAY_MS` | `nextHandDelayMs` | `num` | `4000` | |
| `CONSOLIDATE_INTERVAL_MS` | `consolidateIntervalMs` | `num` | `15000` | RoomManager sweeper `setInterval` (roomManager.js:37-43), `unref`'d. |
| `RECONNECT_GRACE_MS` | `reconnectGraceMs` | `num` | `60000` | disconnect grace timer (socket/index.js:717). |
| `RESUME_OFFER_MS` | `resumeOfferMs` | `num` | `600000` (`10*60*1000`) | resume offer freshness (socket/index.js:141). `.env.example` says "0 disables" — with 0, `Date.now() - offer.at > 0` is true after ≥1 ms, so an offer effectively never survives. |

#### `metrics`

| Env | Field | Parse | Default | Notes |
|---|---|---|---|---|
| `METRICS_ENABLED` | `metrics.enabled` | `(env ?? 'true') !== 'false'` | `true` | **Only the exact lowercase string `false` disables.** `'FALSE'`, `'0'`, `'no'`, `''` all leave it enabled. (config/index.js:189) |
| `METRICS_PATH` | `metrics.path` | raw `??` | `'/metrics'` | route of the exposition **and** the path excluded from HTTP metrics (metrics/index.js:346). |
| `METRICS_PREFIX` | `metrics.prefix` | raw `??` | `'game_server_'` | prefix of the process/default collectors and the four extra process gauges **only**; the `game_*` metrics are literal names. |
| `METRICS_TOKEN` | `metrics.token` | raw `??` | `''` | non-empty → bearer required (§2.11). |
| `METRICS_ALLOW_IPS` | `metrics.allowIps` | `(env ?? '').split(',').map(trim).filter(Boolean)` (same as `list`) | `[]` | non-empty → IP allow-list (§2.11). |

#### `chat`

| Env | Field | Parse | Default | Notes |
|---|---|---|---|---|
| `CHAT_MAX_HISTORY` | `chat.maxHistory` | `num` | `100` | copied into Table config as `chatMaxHistory` (roomManager.js:144). |
| `CHAT_MAX_LENGTH` | `chat.maxLength` | `num` | `140` | Table config `chatMaxLength` (roomManager.js:145); game/chat.js:15,82. |
| `CHAT_RATE_LIMIT` | `chat.rateLimit` | `num` | `5` | per-socket chat limiter (socket/index.js:645-648). |
| `CHAT_RATE_WINDOW_MS` | `chat.rateWindowMs` | `num` | `5000` | |

Keys present in `.env.example` but read nowhere else: none beyond the above (`LOG_LEVEL` is read by the
logger). Keys read by code but absent from `.env.example`: none.

### 1.4 Derived structures

#### 1.4.1 `corsOrigin` (config/index.js:27)
```
process.env.CORS_ORIGIN === '*' || !process.env.CORS_ORIGIN  →  '*'
otherwise                                                     →  list(CORS_ORIGIN)   (string[])
```
So unset, `''` and `'*'` all give the string `'*'`; `'https://a.com, https://b.com'` gives
`['https://a.com','https://b.com']`. Passed to Socket.IO as `cors: { origin, methods: ['GET','POST'] }`.

#### 1.4.2 `game.tableStakes` (config/index.js:70-72)
```
list(TABLE_STAKES ?? '200,5000')
  .map(entry => Number.parseInt(entry, 10))
  .filter(entry => Number.isInteger(entry) && entry > 0)
```
- `TABLE_STAKES=''` → `[]` → `assertStakeAllowed` skips the membership check (roomManager.js:64-65).
- `'200,abc,5000,0,-3,200.5'` → `[200, 5000, 200]` (`200.5` → 200; duplicates kept; order kept).
- The array is what `lobbyOptions().stakes` returns **verbatim** (MUST MATCH).

#### 1.4.3 `game.lobbyTables` (config/index.js:85-90)
```
list(LOBBY_TABLES ?? 'seen:200,blind:200,blind:5000')
  .map(entry => { const [category, boot] = entry.split(':');
                  return { category: category?.trim(), bootAmount: Number.parseInt(boot, 10) }; })
  .filter(entry => entry.category && Number.isInteger(entry.bootAmount))
```
- Each element is `{ category: string, bootAmount: int }` in that key order.
- **The category is not validated** — `'foo:200'` survives as `{category:'foo', bootAmount:200}` and is
  rendered by clients and used by `assertTableOffered`; it can never be quick-joined because
  `normalizeCategory` only ever yields `seen`/`blind`.
- `bootAmount` may be 0 or negative (`Number.isInteger` passes); `'seen'` (no colon) → `NaN` → dropped;
  `'seen:200:extra'` → boot `200` (third segment ignored); `':200'` → category `''` → dropped;
  `' blind : 5000 '` → `list` trims the whole entry, `category?.trim()` trims the category again,
  `parseInt(' 5000 ')` = 5000 → kept.
- `LOBBY_TABLES=''` → `[]` → `assertTableOffered` returns immediately (roomManager.js:80).

#### 1.4.4 `metrics.allowIps` — see table above; identical semantics to `list`.

### 1.5 Production-mode guards (config/index.js:213-220) — MUST MATCH (startup refusal)

Evaluated once at import, in this order, only when `config.env === 'production'`:
1. `config.jwt.secret === 'dev-only-insecure-secret'` → `throw new Error('JWT_SECRET must be set in production')`.
2. `config.allowFakeProviders === true` → `throw new Error('AUTH_ALLOW_FAKE_PROVIDERS must be false in production')`.

Either throw aborts module evaluation → the process exits non-zero before listening. Setting
`JWT_SECRET` to any other string (even `''`? — no: `'' ?? default` keeps `''`, which is not the sentinel, so
an **empty** `JWT_SECRET=` in production passes the guard and signs tokens with an empty key) satisfies
guard 1. Nothing else is validated in production (no check on `METRICS_TOKEN`, `CORS_ORIGIN`, DB URL).

### 1.6 Where config flows

#### 1.6.1 Table configuration composition (roomManager.js:100-146) — MUST MATCH (rules engine input)

`RoomManager._createTable({ bootAmount = config.game.bootAmount, isPrivate = false, category })`:

```
resolved = normalizeCategory(category)            // 'blind' iff category === 'blind', else 'seen'
boot     = isPrivate ? config.game.privateBoot : bootAmount

categoryRules = resolved === 'seen'
  ? { maxRaiseSteps: seenMaxRaiseSteps, maxBetRounds: seenMaxBetRounds, maxPot: seenMaxPot }
  : { maxRaiseSteps: blindMaxRaiseSteps, maxBetRounds: blindMaxBetRounds, potLimitMultiplier: blindPotLimitMultiplier }

privateRules = isPrivate ? { maxPot: privateMaxPot, maxRaiseSteps: privateMaxRaiseSteps } : {}

tableConfig = { ...config.game, ...categoryRules, ...privateRules,
                bootAmount: boot, category: resolved,
                chatMaxHistory: config.chat.maxHistory, chatMaxLength: config.chat.maxLength }
```

Resulting effective values with defaults:

| Table kind | `bootAmount` | `maxRaiseSteps` | `maxBetRounds` | `potLimitMultiplier` | `maxPot` (Table reads `config.maxPot ?? 0`, table.js:78) |
|---|---|---|---|---|---|
| public seen | as asked | 2 | 7 | **1024** (global default, untouched) | 1,200,000 |
| public blind | as asked | 0 (unlimited) | 0 (never forced) | 0 (no ceiling) | **0** (uncapped; `config.maxPot` absent → `?? 0`) |
| private seen | **200** (`privateBoot`, whatever was asked) | 2 (private) | 7 | 1024 | 500,000 (private wins over seen) |
| private blind | 200 | 2 (private overrides blind's 0) | 0 | 0 | 500,000 |

Every other `config.game.*` key (turnTimeoutMs, maxBlindMoves, maxMissedTurns, sideshow*, nextHandDelayMs,
minPlayers, maxPlayers, …) reaches the Table unchanged. Table reads: `bootAmount, maxBetRounds,
maxBlindMoves, maxMissedTurns, maxPlayers, maxRaiseSteps, minPlayers, nextHandDelayMs,
potLimitMultiplier, sideshowMinPlayers, sideshowTimeoutMs, turnTimeoutMs, maxPot, category,
chatMaxHistory, chatMaxLength` (grep of `this.config.`/`config.` in table.js). Also `table.isPrivate = isPrivate`
is set after construction (roomManager.js:153).

#### 1.6.2 `RoomManager.normalizeCategory(category)` (roomManager.js:49-51)
`category === 'blind' ? 'blind' : 'seen'` — `undefined`, `'BLIND'`, `'seen'`, `42` all → `'seen'`.

#### 1.6.3 `RoomManager.assertStakeAllowed(bootAmount)` (roomManager.js:60-69) — MUST MATCH (error codes)
1. `!Number.isInteger(bootAmount) || bootAmount <= 0` → `GameError('invalid_stake', 'That stake is not valid')`.
   Catches `0, -200, 200.5, NaN, 'lots', null, undefined`.
2. `config.game.tableStakes.length > 0 && !tableStakes.includes(bootAmount)` →
   `GameError('invalid_stake', 'Stake must be one of: ' + tableStakes.join(', '))` → with defaults
   `"Stake must be one of: 200, 5000"`.

#### 1.6.4 `RoomManager.assertTableOffered(bootAmount, category)` (roomManager.js:78-90)
- `lobbyTables.length === 0` → return.
- no entry with `entry.bootAmount === bootAmount && entry.category === category` →
  `GameError('table_not_offered', 'The lobby offers: ' + entries.map(e => `${e.category} ${e.bootAmount}`).join(', '))`
  → with defaults `"The lobby offers: seen 200, blind 200, blind 5000"`.

Call order inside `quickJoin` (roomManager.js:232-242): `_assertNotSeated` → `assertStakeAllowed(bootAmount)` →
`normalizeCategory` → `assertTableOffered(bootAmount, resolved)` → chips ≥ boot → `_assertUnderEntryCap`.

#### 1.6.5 Entry cap `_assertUnderEntryCap(user, {bootAmount, category})` (roomManager.js:372-383)
In order: `cap = entryCapMaxChips; if (!cap) return;` → `if (bootAmount !== entryCapBoot) return;` →
`if (category !== entryCapCategory) return;` → `if (user.chips <= cap) return;` → else
`GameError('over_entry_cap', `Players with more than ${cap.toLocaleString('en-US')} chips cannot join this table`)`
→ default message `"Players with more than 500,000 chips cannot join this table"` (en-US grouping,
comma thousands). Exactly-at-cap is allowed. Applied on quick-join and join-by-code, **not** on switch.

#### 1.6.6 `RoomManager.lobbyOptions()` (roomManager.js:196-223) — MUST MATCH (sent to clients verbatim)

```json
{
  "categories": ["seen", "blind"],
  "stakes": <config.game.tableStakes>,
  "tables": [ { "category": "<entry.category>", "bootAmount": <int>,
                "maxPot": <entry.category === 'seen' ? seenMaxPot : 0>,
                "maxBlindMoves": <config.game.maxBlindMoves> }, ... ],
  "entryCapBoot": <int>, "entryCapCategory": "<string>", "entryCapMaxChips": <int>,
  "privateBoot": <int>, "privateMaxPot": <int>
}
```
- `categories` is the literal constant `[TABLE_CATEGORY.SEEN, TABLE_CATEGORY.BLIND]` = `['seen','blind']`,
  in that order, regardless of the menu.
- `tables[i]` key order: `category, bootAmount, maxPot, maxBlindMoves` (spread of the config entry then the
  two extras). With defaults exactly:
  `[{category:'seen',bootAmount:200,maxPot:1200000,maxBlindMoves:4},{category:'blind',bootAmount:200,maxPot:0,maxBlindMoves:4},{category:'blind',bootAmount:5000,maxPot:0,maxBlindMoves:4}]`
  (asserted by test/stakes.test.js:48-56).
- `maxPot` for a non-seen entry is `0` even if the category string is garbage (`'foo'`).
- All numbers are JSON numbers, never strings; nothing here is nullable.
- Used by: `session:ready.config` (via `publicGameConfig`), `lobby:list` ack `options`, `GET /api/rooms`
  `options` (index.js:95).

#### 1.6.7 `publicGameConfig()` (socket/index.js:735-746) — MUST MATCH (`session:ready.config`)

Emitted on every socket connection as `session:ready {user, config, resume?}` (socket/index.js:430-434).
Exact shape and insertion order:

```json
{
  "maxPlayers": 5, "minPlayers": 2, "bootAmount": 200, "turnTimeoutMs": 25000,
  "welcomeChips": 200000, "maxBetRounds": 20,
  "sideshowTimeoutMs": 6000, "sideshowMinPlayers": 3,
  "categories": ["seen","blind"], "stakes": [200,5000],
  "tables": [ ...as §1.6.6... ],
  "entryCapBoot": 200, "entryCapCategory": "blind", "entryCapMaxChips": 500000,
  "privateBoot": 200, "privateMaxPot": 500000
}
```
(values shown are defaults). Notes:
- `maxBetRounds` is the **global** `config.game.maxBetRounds` (20), not the per-category value a table
  actually uses (7 seen / 0 blind). Clients that show "rounds left" from this are already wrong; keep the value.
- Not included (clients guard against it): `maxBlindMoves` at top level (only inside `tables[i]`),
  `maxMissedTurns`, `reconnectGraceMs`, `resumeOfferMs`, `nextHandDelayMs`, `chat.*`, `displayNameMaxLength`.
- The Flutter client's `GameConfig.fromJson` treats missing ints as 0 and guards `maxPlayers == 0 ? 5`; a
  port that omits a key silently changes UI (see CLAUDE.md §12.3).
- The Flutter client hardcodes `maxLength: 24` for names and `5` seats; changing those env defaults
  desynchronises the client (CLAUDE.md §7.4).

#### 1.6.8 Other consumers (for completeness; behaviour specified in their own specs)

| Consumer | Config used | Source |
|---|---|---|
| Express app | `express.json({ limit: '32kb' })`; `app.disable('x-powered-by')`; `app.set('query parser','simple')` — constants, not env | index.js:20-28 |
| Socket.IO server | `cors: {origin: corsOrigin, methods:['GET','POST']}`, `transports:['websocket','polling']`, `pingInterval: 20000`, `pingTimeout: 25000`, `maxHttpBufferSize: 1e5` — the last four are hardcoded | index.js:115-122 |
| Socket guard rate limiter | hardcoded `{limit: 30, windowMs: 5000}` per socket, fixed window (`createRateLimiter`, socket/index.js:442, 749-761): the window restarts when `now - windowStart >= windowMs`; the request that overflows is refused (`count <= limit`). | |
| JWT | `jwt.sign({sub, provider, name}, secret, {expiresIn})` (HS256 default); `verify` failures → `AuthError('invalid_session', 'Session token rejected: <lib message>')`; missing → `AuthError('missing_token', 'A session token is required')` | auth/tokens.js:5-22 |
| Startup log | `logger.info('king-teenpatti server listening', {url:`http://${host}:${port}`, env, welcomeChips, boot})` | index.js:146-151 |
| Shutdown | on `SIGINT`/`SIGTERM`: `logger.info('shutting down', {signal})`; 8 s `setTimeout(process.exit(1)).unref()`; `io.close()`; `await rooms.shutdown()`; `await server.close`; `await closeDatabase()`; `process.exit(0)` | index.js:154-166 |
| `unhandledRejection` | `logger.error('unhandled rejection', {reason: String(reason)})` — process keeps running | index.js:167 |

### 1.7 `GET /health` (index.js:34-80) — related operational surface, MUST MATCH shape

Registered **after** the metrics middleware, so it is counted under route `/health`. Response `res.json(...)`:

```json
{
  "ok": true,
  "uptime": <process.uptime(), float seconds>,
  "tables": <int>, "players": <int>, "activeHands": <int>,          // ...rooms.stats() (roomManager.js:500-507)
  "sockets": <io.engine.clientsCount | null>,
  "process": {
    "pid": <int>, "node": "v22.22.1",
    "rssMb": <float 1dp>, "heapUsedMb": <float 1dp>, "heapTotalMb": <float 1dp>, "externalMb": <float 1dp>,
    "cpuPercent": <float 1dp>,          // (user+system µs since previous /health call) / elapsed µs × 100, rounded to 1 dp; 0 on first call if elapsed == 0
    "loopLagP50Ms": <float 1dp>, "loopLagP99Ms": <float 1dp>, "loopLagMaxMs": <float 1dp>
  },
  "db": { "total": <int>, "idle": <int>, "waiting": <int> } | null
}
```
- `rooms.stats()` = `{tables: tables.size, players: playerRooms.size, activeHands: count(table.hand truthy)}`.
- `mb(bytes) = Math.round(bytes / 1048576 * 10) / 10`; `ns(v) = Math.round(v / 1e6 * 10) / 10` (nanoseconds → ms, 1 dp).
- Event-loop delay histogram `monitorEventLoopDelay({resolution: 20})`, **reset after every /health response**,
  so percentiles cover the interval since the previous call; idle reads ≈ 20 ms because of the resolution.
- CPU mark is taken per call: the reported share is "since the previous /health call".
- `db` is `null` only if `getPool()` throws (database not open).
- Key order as listed. `sockets` is `null` when `io.engine` is absent.

---

## 2. Prometheus metrics (`metrics/index.js`)

### 2.1 Registry and exposition — MUST MATCH

| Rule | Source |
|---|---|
| One registry; default labels `{ service: 'king-teenpatti' }` — **every** sample (default collectors included) carries `service="king-teenpatti"`. Asserted by test/metrics.test.js:346-349. | metrics/index.js:21-22 |
| Content type: `text/plain; version=0.0.4; charset=utf-8` (`registry.contentType`). Test only requires `startsWith('text/plain')`. | metrics/index.js:412; test:298-302 |
| Body is the Prometheus text exposition: for each metric `# HELP <name> <help>` then `# TYPE <name> <type>` then samples. Metrics appear in **registration order** (§2.13 lists it). Test requires `/^# HELP /m` and `/^# TYPE game_connected_sockets gauge$/m`. | prom-client 15.1.3 |
| Every metric name starts with `game_` (either `game_server_` prefixed defaults or literal `game_*`). Asserted test:346. If `METRICS_PREFIX` is changed this assertion (and the dashboard) break — treat `game_server_` as fixed in practice. | |
| Unlabelled counters/gauges/histograms print a sample immediately (value 0) — e.g. `game_connections_total{service="king-teenpatti"} 0` on a fresh process. **Labelled** metrics print no samples until the first `inc`/`observe` for a label set (e.g. no `game_disconnections_total` line until a disconnect). Verified on the live registry. | prom-client behaviour |
| Histogram output per label set: `_bucket{le="0.001"} … _bucket{le="1"} _bucket{le="+Inf"}`, then `_sum`, then `_count`. Bucket boundaries print with JS number formatting: `0.001 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 +Inf` — note `le="1"`, not `1.0` (test:453 looks up `le: '1'`). | test:452-454 |
| Label order inside `{}`: prom-client prints a histogram's `le` first, then `service`, then the metric's own labels; for counters/gauges own labels first then `service`. Tests match on label **subsets**, so order is INCIDENTAL. | test:172-176 |
| No timestamps on samples, no `_created` series, no `# EOF`. | prom-client text format |
| HELP strings are UTF-8; one contains an en dash U+2013 (`0 idle – 1 saturated`). | metrics/index.js:68 |

### 2.2 Default process collectors (prefix `game_server_`) — names MUST MATCH where §2.12 says so; Node-specific semantics have no Go equivalent

`client.collectDefaultMetrics({ register, prefix: PREFIX, eventLoopMonitoringPrecision: 10, gcDurationBuckets: [0.001,0.005,0.01,0.025,0.05,0.1,0.25,0.5,1] })`
(metrics/index.js:28-34). Exact names, types, labels and HELP as emitted by prom-client 15.1.3 on Node 22 / Linux:

| Name (after prefix) | Type | Labels | HELP |
|---|---|---|---|
| `process_cpu_user_seconds_total` | counter | — | `Total user CPU time spent in seconds.` |
| `process_cpu_system_seconds_total` | counter | — | `Total system CPU time spent in seconds.` |
| `process_cpu_seconds_total` | counter | — | `Total user and system CPU time spent in seconds.` |
| `process_start_time_seconds` | gauge | — | `Start time of the process since unix epoch in seconds.` |
| `process_resident_memory_bytes` | gauge | — | `Resident memory size in bytes.` |
| `process_virtual_memory_bytes` | gauge | — | `Virtual memory size in bytes.` (Linux only) |
| `process_heap_bytes` | gauge | — | `Process heap size in bytes.` (Linux only) |
| `process_open_fds` | gauge | — | `Number of open file descriptors.` (Linux only) |
| `process_max_fds` | gauge | — | `Maximum number of open file descriptors.` |
| `nodejs_eventloop_lag_seconds` | gauge | — | `Lag of event loop in seconds.` (measured at scrape by a `setImmediate` round-trip) |
| `nodejs_eventloop_lag_min_seconds` | gauge | — | `The minimum recorded event loop delay.` |
| `nodejs_eventloop_lag_max_seconds` | gauge | — | `The maximum recorded event loop delay.` |
| `nodejs_eventloop_lag_mean_seconds` | gauge | — | `The mean of the recorded event loop delays.` |
| `nodejs_eventloop_lag_stddev_seconds` | gauge | — | `The standard deviation of the recorded event loop delays.` |
| `nodejs_eventloop_lag_p50_seconds` | gauge | — | `The 50th percentile of the recorded event loop delays.` |
| `nodejs_eventloop_lag_p90_seconds` | gauge | — | `The 90th percentile of the recorded event loop delays.` |
| `nodejs_eventloop_lag_p99_seconds` | gauge | — | `The 99th percentile of the recorded event loop delays.` |
| `nodejs_active_resources` | gauge | `type` | `Number of active resources that are currently keeping the event loop alive, grouped by async resource type.` |
| `nodejs_active_resources_total` | gauge | — | `Total number of active resources.` |
| `nodejs_active_handles` | gauge | `type` | `Number of active libuv handles grouped by handle type. Every handle type is C++ class name.` |
| `nodejs_active_handles_total` | gauge | — | `Total number of active handles.` |
| `nodejs_active_requests` | gauge | `type` | `Number of active libuv requests grouped by request type. Every request type is C++ class name.` |
| `nodejs_active_requests_total` | gauge | — | `Total number of active requests.` |
| `nodejs_heap_size_total_bytes` | gauge | — | `Process heap size from Node.js in bytes.` |
| `nodejs_heap_size_used_bytes` | gauge | — | `Process heap size used from Node.js in bytes.` |
| `nodejs_external_memory_bytes` | gauge | — | `Node.js external memory size in bytes.` |
| `nodejs_heap_space_size_total_bytes` | gauge | `space` | `Process heap space size total from Node.js in bytes.` |
| `nodejs_heap_space_size_used_bytes` | gauge | `space` | `Process heap space size used from Node.js in bytes.` |
| `nodejs_heap_space_size_available_bytes` | gauge | `space` | `Process heap space size available from Node.js in bytes.` |
| `nodejs_version_info` | gauge (value 1) | `version, major, minor, patch` | `Node.js version info.` e.g. `{version="v22.22.1",major="22",minor="22",patch="1"}` |
| `nodejs_gc_duration_seconds` | histogram | `kind` ∈ `major, minor, incremental, weakcb` | `Garbage collection duration by kind, one of major, minor, incremental or weakcb.` buckets as configured above |

Event-loop lag semantics (prom-client `lib/metrics/eventLoopLag.js`): `monitorEventLoopDelay({resolution: 10})`
(10 ms); on every scrape the `_min/_max/_mean/_stddev/_p50/_p90/_p99` gauges are set from the histogram and the
histogram is **reset**, so each value covers the interval since the previous scrape.

### 2.3 Extra process gauges (also prefixed, defined by this project) — metrics/index.js:37-76

| Name | Type | HELP | Value (computed in `collect()` at scrape) |
|---|---|---|---|
| `game_server_nodejs_heap_size_limit_bytes` | gauge | `V8 heap size limit in bytes (the point at which the process dies of memory).` | `v8.getHeapStatistics().heap_size_limit` |
| `game_server_nodejs_array_buffers_bytes` | gauge | `Memory allocated for ArrayBuffers and SharedArrayBuffers, in bytes.` | `process.memoryUsage().arrayBuffers` |
| `game_server_process_uptime_seconds` | gauge | `Seconds since the process started.` | `process.uptime()` |
| `game_server_nodejs_eventloop_utilization` | gauge | `Fraction of time the event loop was busy since the previous scrape (0 idle – 1 saturated).` | `performance.eventLoopUtilization(now, lastElu).utilization`, then `lastElu = now`; non-finite → `0`. **Per-scrape delta, not cumulative.** Test requires `0 <= v <= 1`. |

### 2.4 Socket metrics (literal `game_` names) — metrics/index.js:80-129 — MUST MATCH

| Name | Type | Labels | HELP |
|---|---|---|---|
| `game_connected_sockets` | gauge | — | `Socket.IO connections open right now.` |
| `game_connected_sockets_peak` | gauge | — | `Highest number of Socket.IO connections open at once since the process started.` |
| `game_connections_total` | counter | — | `Socket.IO connections accepted since the process started.` |
| `game_disconnections_total` | counter | `reason` | `Socket.IO disconnections since the process started, by Socket.IO reason.` |
| `game_reconnects_total` | counter | `kind` ∈ `seat_held`, `offer` | `Connections from a player whose seat was still being held after a drop, or who was offered their table back.` |
| `game_socket_errors_total` | counter | `code` | `Requests refused on the socket, by error code.` |
| `game_socket_messages_total` | counter | `event` | `Messages received from clients, by event name.` |
| `game_socket_emits_total` | counter | `event` | `Messages sent to clients, by event name (a room broadcast counts once).` |
| `game_session_replaced_total` | counter | — | `Times a second sign-in displaced an existing socket for the same account.` |

### 2.5 Table gauges (computed at scrape from the live RoomManager) — metrics/index.js:133-180

`bindRooms(rooms)` (called once in `createServer`, index.js:31) supplies the source; before that every
gauge reports 0. `liveTables() = [...rooms.tables.values()]`.

| Name | Type | Labels | HELP | Value |
|---|---|---|---|---|
| `game_players_online` | gauge | — | `Players seated at a table right now.` | `Σ table.playerCount` (occupied seats, incl. disconnected seats still held) |
| `game_active_games` | gauge | — | `Tables with a hand in progress (betting or showdown).` | count of `table.hand !== null` |
| `game_waiting_games` | gauge | — | `Tables that exist but have no hand in progress (waiting for players or between hands).` | count of `table.hand === null` |
| `game_tables` | gauge | `category`, `stake` | `Open tables by category and stake.` | `reset()` then `inc({category: table.category, stake: String(table.config.bootAmount)})` per table — a category/stake pair with no tables **disappears** from the exposition rather than reading 0. `category` here is the raw `table.category` (always `seen`/`blind` because `normalizeCategory`), **not** passed through `safeLabel`. `stake` is the boot as a decimal string (`"200"`, `"5000"`). Private tables are counted too. |

### 2.6 Game counters — metrics/index.js:182-232

| Name | Type | Labels | HELP |
|---|---|---|---|
| `game_games_started_total` | counter | `category` | `Hands dealt since the process started.` |
| `game_games_completed_total` | counter | `category`, `reason` | `Hands that ended with a winner, by how they ended.` |
| `game_games_abandoned_total` | counter | `category` | `Hands that ended because every player left, or a table destroyed mid-hand.` |
| `game_moves_total` | counter | `action` | `Player actions accepted by the rules engine, by action.` |
| `game_invalid_moves_total` | counter | `code` | `Player actions refused by the rules engine, by refusal code.` |
| `game_turn_timeouts_total` | counter | — | `Turns that ran out the clock and were packed automatically.` |
| `game_kicks_total` | counter | `reason` | `Players removed from a table by the server, by reason.` |
| `game_chat_messages_total` | counter | — | `Chat messages posted to a table.` |
| `game_pot_settled_chips_total` | counter | — | `Chips paid out to hand winners since the process started.` (incremented **by the pot amount**, not by 1) |

### 2.7 Latency histograms — metrics/index.js:236-288

`LATENCY_BUCKETS = [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1]` for every histogram below.
Observations are seconds as `Number(hrtime.bigint() delta) / 1e9` (nanosecond resolution).

| Name | Labels | HELP |
|---|---|---|
| `game_move_processing_duration_seconds` | `action` | `Time to validate a move, commit it to the database and update the table, by action.` |
| `game_creation_duration_seconds` | — | `Time to create a table (lobby quick-join that opened a new one, or a private room).` |
| `game_join_duration_seconds` | `route` ∈ `quick_join, create, code, switch, resume` | `Time from a join request to the player being seated and sent the table, by entry route.` |
| `game_state_update_duration_seconds` | — | `Time to serialise and send one table state change to every viewer at the table.` |
| `game_hand_start_duration_seconds` | — | `Time to collect the boot and deal a hand (one database transaction).` |
| `game_settlement_duration_seconds` | — | `Time to settle a finished hand in the database.` |
| `game_db_transaction_duration_seconds` | `op` ∈ `bet, boot, settle` | `Duration of the ledger transactions that move chips, by operation.` |
| `game_db_transaction_errors_total` (counter) | `op`, `code` | `Ledger transactions that rolled back, by operation and error code.` |

`timed(histogram, labels, fn)` / `timedSync(...)`: start `hrtime.bigint()`, run `fn`, and in `finally`
observe — **a throwing `fn` is still observed** and the error is rethrown (metrics/index.js:374-391).
`labels ?? {}`.

### 2.8 Database pool gauges — metrics/index.js:292-309

`bindPool(getPool)` (index.js:32). `poolStat(key)` calls `getPool()` inside try/catch and returns
`pool[key]`, `0` when the pool is absent or the getter throws.

| Name | HELP | Value |
|---|---|---|
| `game_db_pool_connections` | `Connections held by the pg pool.` | `pool.totalCount` |
| `game_db_pool_idle_connections` | `Pool connections not in use.` | `pool.idleCount` |
| `game_db_pool_waiting_requests` | `Queries waiting for a pool connection.` | `pool.waitingCount` |

### 2.9 HTTP metrics and route labelling — metrics/index.js:313-360 — MUST MATCH

| Name | Type | Labels | HELP |
|---|---|---|---|
| `game_http_requests_total` | counter | `method, route, status_code` | `HTTP requests served, by method, route pattern and status code.` |
| `game_http_request_duration_seconds` | histogram (LATENCY_BUCKETS) | `method, route, status_code` | `HTTP request duration, by method, route pattern and status code.` |

`httpMetricsMiddleware()` is installed **first** in the Express chain, before `express.json`, only when
`config.metrics.enabled` (index.js:27). Per request:
1. `if (req.path === config.metrics.path) return next();` — the scrape itself is never counted
   (test:531 asserts no `route="/metrics"`). `req.path` excludes the query string.
2. `started = process.hrtime.bigint()`; on the response `finish` event compute seconds and labels:
   - `method`: `req.method` if in `{GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS}`, else `'OTHER'`.
   - `route`: `routeLabel(req)` below.
   - `status_code`: `String(res.statusCode)` (e.g. `"200"`, `"404"`, `"500"`).
3. `httpRequestsTotal.inc(labels)`; `httpRequestDuration.observe(labels, seconds)`.
   A request whose socket dies before `finish` is never counted.

`routeLabel(req)` (metrics/index.js:333-341), evaluated at `finish` time (so it sees the route that
finally handled the request):
```
if (req.route?.path) {
  base = req.baseUrl ?? '';                       // mount point of the router that matched, e.g. '/api/auth'
  path = Array.isArray(req.route.path) ? req.route.path[0] : req.route.path;   // the route *pattern*, e.g. '/me/hands'
  return `${base}${(path === '/' && base) ? '' : path}` || '/';
}
if (req.path === '/' || /\.[a-z0-9]{2,5}$/i.test(req.path)) return 'static';
return 'unmatched';
```
Resulting labels for the shipped routes: `/api/auth/login`, `/api/auth/me`, `/api/auth/me/hands`,
`/api/rewards/milestone`, `/api/rewards/bonus`, `/api/profiles`, `/api/profile/avatar`, `/api/profile/name`,
`/api/rooms`, `/health`. Anything served by `express.static` or the root `/` → `static`; any other
unmatched path (a 404 like `/nothing-here-123`) → `unmatched`. A route pattern is always the pattern,
never the concrete URL, and never carries a query string (test:522-530). `req.route` is set even when the
handler responds 4xx/5xx or forwards to the error handler, so `POST /api/auth/login` returning 400 is
`{method="POST",route="/api/auth/login",status_code="400"}`. Socket.IO's own `/socket.io/*` HTTP
traffic goes through the Express middleware **only if** Express handles it — Socket.IO attaches to the
`http.Server` and intercepts `/socket.io/` before Express, so handshakes are **not** counted here.

### 2.10 `safeLabel()` and the fixed label sets — MUST MATCH (cardinality contract)

```
safeLabel(value, known, fallback = 'other'):
  text = String(value ?? fallback)      // null/undefined → fallback string
  return known.has(text) ? text : fallback
```
(metrics/index.js:368-371). Unknown values fold to `'other'`. Sets, verbatim:

| Set | Where | Members |
|---|---|---|
| `KNOWN_DISCONNECT_REASONS` | socket/index.js:44-52 | `transport close`, `transport error`, `ping timeout`, `client namespace disconnect`, `server namespace disconnect`, `forced close`, `server shutting down` (Socket.IO server-side reasons; note the **spaces**) |
| `KNOWN_ERROR_CODES` | socket/index.js:55-97 | rooms: `already_in_room`, `already_seated`, `insufficient_chips`, `invalid_stake`, `no_other_table`, `not_in_room`, `not_seated`, `over_entry_cap`, `private_table`, `room_not_found`, `table_full`, `table_not_offered`, `unknown_action`; moves: `already_seen`, `duplicate_action`, `invalid_bet`, `no_hand`, `not_in_hand`, `not_your_turn`, `persist_failed`, `show_unavailable`; sideshow: `already_asked`, `neighbour_is_blind`, `no_neighbour`, `no_sideshow`, `not_your_sideshow`, `sideshow_pending`, `too_few_players`, `you_are_blind`; chat: `chat_rate_limited`; auth: `invalid_device_id`, `invalid_session`, `invalid_token`, `missing_token`, `provider_unconfigured`, `unknown_provider`, `unknown_user`; socket layer: `rate_limited`, `internal_error` |
| `KNOWN_WIN_REASONS` | socket/index.js:99; constants.js:47-53 | `last_standing`, `show`, `forced_showdown`, `all_left`, `pot_limit` |
| `KNOWN_CATEGORIES` | socket/index.js:100; constants.js:11-14 | `blind`, `seen` |
| `KNOWN_KICK_REASONS` | socket/index.js:101 | `idle`, `insufficient_chips`, `unfunded`, `disconnected`, `other` |
| `VALID_ACTIONS` | socket/index.js:35; constants.js:37-44 | `see`, `chaal`, `raise`, `pack`, `show`, `sideshow` |
| `KNOWN_LEDGER_CODES` | db/ledger.js:59-67 | `duplicate_action`, `insufficient_chips`, `stale_state`, `no_pot`, `unknown_user`, `invalid_amount`, `persist_failed` |
| `KNOWN_METHODS` | metrics/index.js:327 | `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS` (fallback `OTHER`, not `other`) |
| join `route` values | socket/index.js:437,488,508,526,542 | `resume`, `quick_join`, `create`, `code`, `switch` (literal, no folding) |
| db `op` values | db/ledger.js:136,182,235 | `bet`, `boot`, `settle` |
| `reconnects_total.kind` | socket/index.js:419,428 | `seat_held`, `offer` |
| `event` values | wire event names | received: `lobby:list, room:quickJoin, room:create, room:joinCode, room:switch, room:leave, game:action, game:sideshowRespond, player:requestCards, chat:message, chat:history, ping:rtt`; emitted: `session:ready, session:replaced, room:joined, room:state, room:moved, room:left, room:closed, room:kicked, game:handStarted, player:hand, player:cards, game:turn, game:yourTurn, game:action, game:sideshowRequested, game:sideshowReveal, game:sideshowResolved, game:showdown, game:handEnded, chat:message, chat:history, game:error`. The cardinality test requires every `event` value to match `/^[a-z]+:[a-zA-Z]+$/`. |

Cardinality invariants the test enforces (test/metrics.test.js:572-624): no label **name** equals
`socket_id, user_id, room_id, code_, ip, url, path, device_id`, ends in `_id`, or starts with `code_`;
no label **value** contains a UUID, an IPv4 dotted quad, an IPv6-looking string with ≥2 colons, or a
64-hex SHA-256; every `code` value matches `/^[a-z][a-z0-9_]*$/`; every `category` ∈ `{seen, blind, other}`;
every `method` matches `/^[A-Z]+$/`; every `reason` matches `/^[a-z][a-z _]*$/` (test:416).

### 2.11 `metricsHandler()` — the `GET <METRICS_PATH>` endpoint (metrics/index.js:401-415) — MUST MATCH

Registered with `app.get(config.metrics.path, metricsHandler())` only when enabled (index.js:33). Check
order:
1. **IP allow-list** (if `allowIps.length > 0`): `ip = (req.ip ?? '').replace(/^::ffff:/, '')`; if
   `!allowIps.includes(ip)` → `403`, `Content-Type: text/plain`, body `forbidden`. `req.ip` is Express's
   with **`trust proxy` disabled** (nothing sets it) = the TCP peer address, so behind nginx it is always
   `127.0.0.1` and the allow-list cannot distinguish remote scrapers (documented in
   nginx/king-teenpatti.conf.example:65-68). IPv4-mapped IPv6 (`::ffff:10.0.0.5`) is normalised to `10.0.0.5`;
   plain IPv6 (`::1`) is compared verbatim.
2. **Bearer token** (if `token` non-empty): `req.headers.authorization ?? ''` must equal exactly
   `` `Bearer ${token}` `` (case-sensitive scheme, single space, no trimming) else `401`, `text/plain`,
   body `unauthorized`.
3. Success: `Content-Type: <registry.contentType>` (§2.1) and the exposition body, status 200.
Both guards may apply (IP first, then token). With neither set the endpoint is open. Any HTTP method
other than GET/HEAD is not routed to the handler (Express `app.get`) and falls through to `unmatched` 404.

`METRICS_ENABLED=false` removes both the endpoint and the HTTP middleware; the game counters are still
incremented in memory (the metric objects exist regardless) — they are simply unreachable.

### 2.12 Feeding rules — where each metric changes and in what order (MUST MATCH counts; ordering relative to emits is INCIDENTAL except where the count depends on it)

#### Connection lifecycle (socket/index.js:394-440, 686-726)
| Moment | Effect |
|---|---|
| `io.on('connection')` (after the async auth middleware succeeded) | `game_connections_total +1`; `game_connected_sockets +1`; `liveSockets += 1`; if `liveSockets > peakSockets` → `peakSockets = liveSockets; game_connected_sockets_peak = peakSockets`. The peak is kept in a plain variable, not read back from the gauge; it starts at 0 so the first connection sets it to 1. |
| previous socket for the same user exists with a different id | `game_session_replaced_total +1`; `emitTo(previous,'session:replaced')` (→ `game_socket_emits_total{event="session:replaced"} +1`); `previous.disconnect(true)` (its `disconnect` fires with reason `server namespace disconnect`). |
| a pending grace-removal timer exists for the user | cleared; `game_reconnects_total{kind="seat_held"} +1`. |
| no table for the user and `takeResumeOffer(userId)` returns an offer | `game_reconnects_total{kind="offer"} +1`. |
| always | `emitTo(socket,'session:ready', …)` → `emits{event="session:ready"} +1`. |
| user still seated | `timedSync(game_join_duration_seconds{route="resume"})` around: `wireTable`, `trackRoom`, `setConnected`, `emitTo 'room:joined'` (→ `emits{room:joined} +1`). Then `sendChatHistory` (→ `emits{chat:history} +1`) **outside** the timing. |
| `socket.on('disconnect', reason)` | `game_connected_sockets -1`; `liveSockets = max(0, liveSockets-1)`; `game_disconnections_total{reason=safeLabel(reason, KNOWN_DISCONNECT_REASONS)} +1`. Then seat bookkeeping (no metrics). The grace timer, when it fires and removes the seat, calls `rooms.leave(userId,'disconnected')` — this path does **not** increment `game_kicks_total` (only the table's `kick` event does). |

`game_connected_sockets` counts sockets that passed authentication; the `/health` `sockets` field uses
`io.engine.clientsCount` (engine-level, includes handshakes still in the middleware) — they can differ briefly.
test:381 asserts equality once settled.

#### Request guard (socket/index.js:449-476)
For every guarded event (`lobby:list, room:*, game:action, game:sideshowRespond, player:requestCards, chat:message, chat:history`):
1. `game_socket_messages_total{event} +1` — **before** the rate limit, so refused messages are counted.
2. Rate limit tripped → `game_socket_errors_total{code="rate_limited"} +1`; `emitTo 'game:error' {code:'rate_limited', message:'Slow down'}` (→ `emits{game:error} +1`); ack `{ok:false, code:'rate_limited', message:'Slow down'}`; return. **`game_invalid_moves_total` is not touched** even for `game:action`.
3. Handler resolves → ack `{ok:true, ...result}`; no metric here.
4. Handler throws → `code = safeLabel(error.code ?? 'internal_error', KNOWN_ERROR_CODES)`; `game_socket_errors_total{code} +1`; if `event === 'game:action'` → `game_invalid_moves_total{code} +1`; ack `{ok:false, code: error.code ?? 'internal_error', message}` (**raw** code in the ack, folded code in the label); `fail()` → `emitTo 'game:error'` with `{code, message}` for a `GameError`, else `logger.error('socket handler failed', {error, stack})` and `{code:'internal_error', message:'Something went wrong'}` (→ `emits{game:error} +1` either way).
`ping:rtt` is unguarded: `game_socket_messages_total{event="ping:rtt"} +1` only (socket/index.js:680-683).

#### `game:action` (socket/index.js:605-628)
Order: `unknown_action` check → `not_in_room` check → `invalid_bet` type check → actionId normalisation
→ `label = safeLabel(action, VALID_ACTIONS)` → `timed(game_move_processing_duration_seconds{action=label}, () => table.act(...))`
→ on success `game_moves_total{action=label} +1`. Consequences:
- Pre-checks that throw (`unknown_action`, `not_in_room`, `invalid_bet` from the type check) are counted in
  `invalid_moves_total`/`socket_errors_total` but produce **no** histogram observation and no `moves_total`.
- A `table.act` refusal (e.g. `not_your_turn`) **is** observed in the histogram (finally) and then counted
  in `invalid_moves_total{code}`; `moves_total` unchanged. Hence `move_processing_duration_seconds_count{action}` ≥ `moves_total{action}`.
- `action="teleport"` never becomes a label (rejected before labelling; test:487).

#### Join routes (socket/index.js:486-590)
`timed(game_join_duration_seconds{route})` wraps: `findById(user.id)` (DB read), the RoomManager call
(`quickJoin` / `createTable`+`join` / `joinByCode` / `switchTable`), `wireTable`, `trackRoom`, `setConnected`,
`emitTo 'room:joined'`. Outside the timing: `sendChatHistory` (→ `emits{chat:history}`) and `broadcastState`
(§ below) — `room:create` does **not** call `broadcastState`. A thrown refusal is still observed. For
`room:switch` the vacated table is also broadcast (second `room:state` emit count + second
`state_update` observation).

#### Table creation (roomManager.js:96-98)
`createTable()` = `timedSync(game_creation_duration_seconds, () => _createTable(...))` — covers both a
quick-join that found no table (roomManager.js:256) and `room:create`. Table construction is synchronous
(no DB), so observations are microseconds.

#### `broadcastState(table)` (socket/index.js:192-199)
`game_socket_emits_total{event="room:state"} +1` **once per broadcast** (not per viewer), then
`timedSync(game_state_update_duration_seconds)` around the loop `for socket of socketsIn(table.id): socket.emit('room:state', table.serializeFor(viewerId))`.
An observation is recorded even with zero viewers. Triggered by every Table `state` event and by the
explicit calls in the join/leave/kick/moved handlers.

#### Per-table wiring `wireTable(table)` (socket/index.js:212-331) — guarded by `table._wired`
`category = safeLabel(table.category, KNOWN_CATEGORIES)` once per table.

| Table event | Metrics, in order | Emits counted |
|---|---|---|
| `state` | `broadcastState` (above) | `room:state` |
| `kick {userId, reason, message}` | if the player is no longer seated → nothing. Else `await rooms.leave(userId, reason)`; on failure `logger.error('kick failed', …)` and **no** metric. On success `game_kicks_total{reason=safeLabel(reason, KNOWN_KICK_REASONS)} +1`; `emitToUser 'room:kicked' {roomId, reason, message}` (counted only if the user has a socket); `untrackRoom`; `broadcastState` if the table still exists. | `room:kicked`, `room:state` |
| `handStarted` | `game_games_started_total{category} +1`; `emitToRoom 'game:handStarted'`; `game_socket_emits_total{event="player:hand"} +1` once; then a raw `socket.emit('player:hand', {roomId, dealt:true, cardsHidden:true})` per viewer. | `game:handStarted`, `player:hand` |
| `cards {userId, cards}` | `emitToUser 'player:cards' {roomId, cards}` | `player:cards` |
| `turn` | `emitToRoom 'game:turn' {roomId,userId,seatIndex,deadline,timeoutMs}`; `emitToUser 'game:yourTurn' {roomId,deadline,timeoutMs,options}` | `game:turn`, `game:yourTurn` |
| `action` | if `payload.reason === 'timeout'` → `game_turn_timeouts_total +1`; `emitToRoom 'game:action' {...payload, roomId}` | `game:action` |
| `sideshowRequested` / `sideshowResolved` | `emitToRoom` | `game:sideshowRequested` / `game:sideshowResolved` |
| `sideshowReveal {userIds, reveal}` | `game_socket_emits_total{event="game:sideshowReveal"} +1` once; raw emit to each of the two users' sockets | `game:sideshowReveal` |
| `showdown` | `emitToRoom 'game:showdown'` | `game:showdown` |
| `handEnded {reason, pot, winnerId, …}` | `reason === 'all_left'` → `game_games_abandoned_total{category} +1`; else `game_games_completed_total{category, reason=safeLabel(reason, KNOWN_WIN_REASONS)} +1`. Then **independently**: `if (winnerId && Number.isFinite(pot) && pot > 0) game_pot_settled_chips_total += pot` — so an abandoned hand whose last leaver took the pot **does** add to `pot_settled_chips_total`. Then `emitToRoom 'game:handEnded'`. | `game:handEnded` |
| `chat (message)` | `if (!message) return;` `game_chat_messages_total +1`; `emitToRoom 'chat:message' {...message, roomId}` | `chat:message` |

Other RoomManager events: `playerMoved` → `emitTo 'room:moved'`, `emitTo 'room:joined'`, `sendChatHistory`,
`broadcastState` (socket/index.js:341-362); `tableDestroyed` → `game_socket_emits_total{event="room:closed"} +1`
**only if** at least one viewer socket is tracked, then raw `socket.emit('room:closed', {roomId})` each
(socket/index.js:368-376).

#### Ledger (db/ledger.js:74-81, 136, 182, 235)
`transact(op, fn)`: `timed(game_db_transaction_duration_seconds{op}, fn)`; on any throw →
`refusal = classify(error)` (a `LedgerError` passes through; pg `23505` whose `detail`/`constraint` mentions
`action_id` → `duplicate_action`; anything else → `persist_failed`) → `game_db_transaction_errors_total{op, code=safeLabel(refusal.code, KNOWN_LEDGER_CODES)} +1` → rethrow `refusal`.
- `bet()` → `transact('bet', …)`.
- `collectBoot()` → `timed(game_hand_start_duration_seconds, () => transact('boot', …))` — the same span feeds
  both histograms.
- `settle()` → `timed(game_settlement_duration_seconds, () => transact('settle', …))` — likewise. Settlement
  retries (the table's background retry after a failed settle) each produce another observation and, on
  failure, another error count.

### 2.13 Registration order (INCIDENTAL, but it is the order of the exposition body)

`game_server_process_cpu_user_seconds_total, …_cpu_system_seconds_total, …_cpu_seconds_total,
…_process_start_time_seconds, …_process_resident_memory_bytes, …_process_virtual_memory_bytes,
…_process_heap_bytes, …_process_open_fds, …_process_max_fds, …_nodejs_eventloop_lag_seconds,
…_lag_min, …_lag_max, …_lag_mean, …_lag_stddev, …_lag_p50, …_lag_p90, …_lag_p99,
…_nodejs_active_resources, …_active_resources_total, …_active_handles, …_active_handles_total,
…_active_requests, …_active_requests_total, …_nodejs_heap_size_total_bytes, …_heap_size_used_bytes,
…_nodejs_external_memory_bytes, …_heap_space_size_total_bytes, …_heap_space_size_used_bytes,
…_heap_space_size_available_bytes, …_nodejs_version_info, …_nodejs_gc_duration_seconds,
game_server_nodejs_heap_size_limit_bytes, game_server_nodejs_array_buffers_bytes,
game_server_process_uptime_seconds, game_server_nodejs_eventloop_utilization,
game_connected_sockets, game_connected_sockets_peak, game_connections_total, game_disconnections_total,
game_reconnects_total, game_socket_errors_total, game_socket_messages_total, game_socket_emits_total,
game_session_replaced_total, game_players_online, game_active_games, game_waiting_games, game_tables,
game_games_started_total, game_games_completed_total, game_games_abandoned_total, game_moves_total,
game_invalid_moves_total, game_turn_timeouts_total, game_kicks_total, game_chat_messages_total,
game_pot_settled_chips_total, game_move_processing_duration_seconds, game_creation_duration_seconds,
game_join_duration_seconds, game_state_update_duration_seconds, game_hand_start_duration_seconds,
game_settlement_duration_seconds, game_db_transaction_duration_seconds, game_db_transaction_errors_total,
game_db_pool_connections, game_db_pool_idle_connections, game_db_pool_waiting_requests,
game_http_requests_total, game_http_request_duration_seconds`

### 2.14 What the Grafana dashboard and alert rules query (MUST keep alive)

Extracted from every `expr` in `ops/monitoring/grafana/dashboards/king-teenpatti.json` and
`ops/monitoring/prometheus/alerts.yml`.

**Game metrics queried (all must exist with the same names, types and label names):**
`game_connected_sockets`, `game_connected_sockets_peak`, `game_connections_total`, `game_disconnections_total{reason}`,
`game_session_replaced_total`, `game_reconnects_total{kind}`, `game_socket_messages_total{event}`,
`game_socket_emits_total{event}`, `game_socket_errors_total{code}`, `game_players_online`, `game_active_games`,
`game_waiting_games`, `game_tables{category,stake}`, `game_games_started_total{category}`,
`game_games_completed_total{reason}`, `game_games_abandoned_total{category}`, `game_moves_total{action}`,
`game_invalid_moves_total{code}`, `game_turn_timeouts_total`, `game_kicks_total{reason}`, `game_chat_messages_total`,
`game_pot_settled_chips_total`, `game_move_processing_duration_seconds_bucket{le,action}`,
`game_creation_duration_seconds_bucket`, `game_join_duration_seconds_bucket{le,route}`,
`game_state_update_duration_seconds_bucket`, `game_hand_start_duration_seconds_bucket`,
`game_settlement_duration_seconds_bucket`, `game_db_transaction_duration_seconds_bucket{le,op}`,
`game_db_transaction_errors_total{op,code}`, `game_db_pool_connections`, `game_db_pool_idle_connections`,
`game_db_pool_waiting_requests`, `game_http_requests_total{status_code,route}`,
`game_http_request_duration_seconds_bucket{le,route}`.

**Process metrics queried (prefix `game_server_`):**
`process_open_fds`, `process_max_fds`, `process_uptime_seconds`, `process_start_time_seconds`,
`process_resident_memory_bytes`, `process_cpu_seconds_total`, `process_cpu_user_seconds_total`,
`process_cpu_system_seconds_total`, `nodejs_version_info`, `nodejs_heap_size_used_bytes`, `nodejs_heap_size_total_bytes`,
`nodejs_heap_size_limit_bytes`, `nodejs_heap_space_size_used_bytes`, `nodejs_external_memory_bytes`,
`nodejs_array_buffers_bytes`, `nodejs_eventloop_lag_p50_seconds`, `_p90_`, `_p99_`, `_max_seconds`,
`nodejs_eventloop_utilization`, `nodejs_gc_duration_seconds_sum{kind}`, `_count{kind}`,
`nodejs_active_handles`, `nodejs_active_handles_total`, `nodejs_active_requests`, `nodejs_active_requests_total`.

**Alerts on game-server metrics** (alerts.yml): `up{job="game-server"}`; `game_server_nodejs_eventloop_lag_p99_seconds > 0.2`;
`game_server_nodejs_eventloop_utilization > 0.9`; `game_connected_sockets` vs `king_teenpatti:socket_limit` (`vector(12000)`);
5xx share of `game_http_requests_total{status_code=~"5.."}` (used twice: `GameServerHttp5xxRate` and `Nginx5xxRate`);
`histogram_quantile(0.99, sum by (le)(rate(game_move_processing_duration_seconds_bucket[5m]))) > 0.5`;
`sum by (op,code)(rate(game_db_transaction_errors_total[5m])) > 0`; `game_db_pool_waiting_requests > 0`;
`game_server_nodejs_heap_size_used_bytes / game_server_nodejs_heap_size_limit_bytes > 0.85`;
`game_server_process_open_fds / game_server_process_max_fds > 0.8`. Everything else in the file targets
`pg_*`, `nginx_*`, `node_*` exporters, not this process.

**Node-specific names with no Go equivalent** (dashboard panels/alerts that reference them go blank or must be
re-pointed; the runtime semantics do not exist in Go): `nodejs_eventloop_lag_*` (all nine; the two alerts
`GameServerEventLoopLagHigh` and `GameServerEventLoopSaturated` depend on them), `nodejs_eventloop_utilization`,
`nodejs_heap_size_used/total/limit_bytes` (alert `GameServerHeapNearLimit`), `nodejs_heap_space_size_*{space}`,
`nodejs_external_memory_bytes`, `nodejs_array_buffers_bytes`, `nodejs_gc_duration_seconds{kind}`,
`nodejs_active_handles*`, `nodejs_active_requests*`, `nodejs_active_resources*`, `nodejs_version_info`.
The `process_*` family (`cpu_*`, `start_time`, `resident_memory`, `virtual_memory`, `heap_bytes`,
`open_fds`, `max_fds`) has standard equivalents in other runtimes' process collectors and must keep the
`game_server_` prefix to stay on the dashboard. `game_server_process_uptime_seconds` is project-defined and
trivially reproducible.

---

## 3. Logger (`util/logger.js`) — INCIDENTAL (nothing external parses it), but the format is what ops greps

```
LEVELS = { error: 0, warn: 1, info: 2, debug: 3 }
threshold = LEVELS[process.env.LOG_LEVEL ?? 'info'] ?? LEVELS.info     // unknown value → info; case-sensitive ('INFO' → info by fallback, 'DEBUG' → info!)
write(level, message, meta):
  if (LEVELS[level] > threshold) return
  line = { t: new Date().toISOString(), level, msg: message }        // key order: t, level, msg
  if (meta !== undefined) line.meta = meta                             // meta is any JSON value; omitted entirely when undefined; null is kept ("meta":null)
  stream = level === 'error' ? stderr : stdout
  stream.write(JSON.stringify(line) + '\n')
```
- One JSON object per line; `t` is ISO-8601 UTC with milliseconds (`2026-09-08T10:15:30.123Z`).
- Only `error` goes to stderr; `warn`, `info`, `debug` go to stdout.
- No timestamps other than `t`, no pid, no hostname, no colour.
- `JSON.stringify` drops `undefined`-valued keys inside `meta` and turns functions/symbols into nothing;
  an `Error` object as meta would serialise to `{}` — callers therefore pass `error.message`/`stack` strings.

Call sites (message, meta shape) — reproduce message strings for grep-compatibility:

| Level | `msg` | `meta` | Source |
|---|---|---|---|
| info | `account created` / `login` | `{userId, provider}` | auth/routes.js:66 |
| info | `milestone reward claimed` | `{userId, milestone}` | auth/routes.js:124 |
| info | `timed bonus claimed` | `{userId}` | auth/routes.js:146 |
| info | `database ready` | `{url: <redacted>, schema}` | db/index.js:62 |
| error | `postgres pool error` | `{error}` | db/index.js:49 |
| error | `socket handler failed` | `{error, stack}` | socket/index.js:205 |
| error | `kick failed` | `{userId, reason, error}` | socket/index.js:235 |
| error | `grace removal failed` | `{userId, error}` | socket/index.js:714 |
| debug | `socket disconnected` | `{userId, reason}` | socket/index.js:724 |
| error | `request failed` | `{path, error, stack}` | index.js:109 |
| info | `socket.io redis adapter enabled` | (none) | index.js:132 |
| info | `king-teenpatti server listening` | `{url, env, welcomeChips, boot}` | index.js:146 |
| info | `shutting down` | `{signal}` | index.js:155 |
| error | `unhandled rejection` | `{reason}` | index.js:167 |
| error | `table sweep failed` | `{error}` | roomManager.js:41 |
| error | `table error` | `{roomId, error}` | roomManager.js:154 |
| warn | `table write refused` | `{roomId, reason, error}` | roomManager.js:156 |
| info | `table created` | `{roomId, code, bootAmount, category, isPrivate, maxPot: table.maxPot || null}` | roomManager.js:160 |
| info | `table destroyed` | `{roomId}` | roomManager.js:403 |
| warn | `table consolidation failed, restoring seat` | `{error}` | roomManager.js:477 |
| info | `player moved to a busier table` | `move` object `{userId, fromRoomId, toRoomId, …}` | roomManager.js:486 |

`Table` never logs (it emits events). Metrics code never logs.

---

## 4. Id generation (`util/ids.js`) — MUST MATCH format

```
uuid()            = crypto.randomUUID()          // RFC 4122 v4, lowercase, 36 chars: 8-4-4-4-12 hex
ALPHABET          = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'   // 32 symbols: A–Z minus I and O, digits 2–9 (no 0/1)
roomCode(len = 6) = for each of randomBytes(len): ALPHABET[byte % 32]
```
- `roomCode()` is always 6 characters from the 32-symbol alphabet; because 256 is a multiple of 32 the
  distribution is uniform; 32^6 ≈ 1.07 × 10^9 codes. **No collision check** against live tables
  (roomManager.js:137 just calls `roomCode()`). Tests assert `/^[A-Z2-9]{6}$/` (integration.test.js:392,
  socketProtocol.test.js:233) — that regex is looser than the real alphabet: it excludes `0`/`1` but would
  accept `I` and `O`, which the generator never produces. A port must use the 32-symbol alphabet, not the regex.
- `uuid()` is used for: user ids (db/users.js:117), table/room ids (roomManager.js:101), chat message ids
  (chat.js:31,49), hand ids (table.js:372), turn tokens (table.js:612), and the **server-generated
  `actionId` when a client sends none** (table.js:849 `actionId ?? uuid()`) — that value becomes
  `chip_ledger.action_id`, so it must be unique per move. Idempotency keys for boot/settle are not uuids:
  `${handId}:boot:${userId}` and `${handId}:settle:${userId}` (CLAUDE.md §5.1).
- The deck shuffle uses `crypto.randomInt(i + 1)` (deck.js:37), not `Math.random` — out of scope here but
  the same "CSPRNG everywhere" rule.

---

## 5. Test cases to mirror

All from `server/test/`. Process suites set env before importing (`NODE_ENV=test`, unique `PG_SCHEMA`,
`PORT=0`, etc.) and tear down with `rooms.shutdown()`, `io.close()`, `server.close()`, `dropSchema()`,
`closeDatabase()`.

### metrics.test.js (env: `JWT_SECRET=metrics-test-secret`, `AUTH_ALLOW_FAKE_PROVIDERS=true`, `WELCOME_CHIPS=200000`, `BOOT_AMOUNT=100`, `TURN_TIMEOUT_MS=4000`, `NEXT_HAND_DELAY_MS=150`, `RECONNECT_GRACE_MS=400`, `TABLE_STAKES=''`, `LOBBY_TABLES=''`, `METRICS_TOKEN=metrics-test-token`; stakes per test start at 150 and step by 50)

| Test | Setup | Asserts |
|---|---|---|
| `/metrics requires the bearer token and serves the text exposition` | none | no `Authorization` → 401; `Bearer not-the-token` → 401; correct bearer → 200, `content-type` starts with `text/plain`, body matches `/^# HELP /m` and `/^# TYPE game_connected_sockets gauge$/m`. |
| `default process metrics are exported under the game_server_ prefix` | scrape; then allocate garbage and re-scrape until GC observed | each of 16 names present: `game_server_process_resident_memory_bytes, nodejs_heap_size_used_bytes, nodejs_heap_size_total_bytes, nodejs_heap_size_limit_bytes, nodejs_external_memory_bytes, nodejs_array_buffers_bytes, nodejs_eventloop_lag_seconds, nodejs_eventloop_utilization, nodejs_active_handles_total, nodejs_active_requests_total, process_uptime_seconds, nodejs_version_info, process_start_time_seconds, process_cpu_user_seconds_total, process_cpu_system_seconds_total, process_open_fds`; `# TYPE game_server_nodejs_gc_duration_seconds histogram`; **every** sample name starts with `game_` and has `service="king-teenpatti"`; RSS > 0, heap used > 0, heap limit > heap used, uptime > 0, open fds > 0, `0 <= elu <= 1`; eventually `gc_duration_seconds_count >= 1`. |
| `sockets: the live gauge follows connects and disconnects, and the totals count them` | scrape baseline; log in two guests, open two sockets | `game_connected_sockets == before + 2`; `connections_total >= before + 2`; `connected_sockets_peak >= before + 2`; gauge equals `io.engine.clientsCount`; after `room:leave` + disconnect on both: gauge back to `before`, `disconnections_total >= before + 2`, every `reason` label matches `/^[a-z][a-z _]*$/`. |
| `game: a dealt hand and its moves are counted and timed` | two players quick-join a `seen` table at a unique stake; wait `game:handStarted`; the player on turn sends `see` then `chaal` | `players_online >= 2`; `active_games >= 1`; `game_tables{category="seen",stake="<boot>"} >= 1`; `games_started_total{category="seen"} >= 1`; `moves_total{action="see"} >= 1`, `{action="chaal"} >= 1`; `socket_messages_total{event="game:action"} >= 2`, `{event="room:quickJoin"} >= 2`; `move_processing_duration_seconds_bucket{action="chaal",le="+Inf"} >= 1` and `{le="1"}` present; `…_count{action="see"} >= 1`; `state_update_duration_seconds_count >= 1`; `join_duration_seconds_count{route="quick_join"} >= 2`; `creation_duration_seconds_count >= 1`; `hand_start_duration_seconds_count >= 1`; `db_transaction_duration_seconds_count{op="boot"} >= 1`, `{op="bet"} >= 1`; `move_processing_duration_seconds_sum{action="chaal"} > 0`; `db_transaction_duration_seconds_sum{op="bet"} > 0`. |
| `invalid moves are counted by refusal code` | dealt hand; the **waiting** player sends `chaal` (→ ack `{ok:false, code:'not_your_turn'}`) and `{action:'teleport'}` (→ `unknown_action`) | `invalid_moves_total{code="not_your_turn"} >= 1`; `socket_errors_total{code="not_your_turn"} >= 1`, `{code="unknown_action"} >= 1`; `invalid_moves_total{code="unknown_action"} >= 1`; `socket_emits_total{event="game:error"} >= 2`; `moves_total` total unchanged from before; no `action="teleport"` label value anywhere. |
| `a completed hand is counted with its reason, and the pot it paid out` | dealt hand; player on turn packs; wait `game:handEnded` (`reason == 'last_standing'`, `pot == 2 × boot`, `winnerId` truthy) | `games_completed_total{category="seen",reason="last_standing"} >= 1`; `pot_settled_chips_total >= before + pot`; `socket_emits_total{event="game:handEnded"} >= 1`; `moves_total{action="pack"} >= 1`; `settlement_duration_seconds_count >= 1`. |
| `http: requests are counted by route pattern, never by raw path` | guest login; `GET /api/auth/me` (200), `GET /health` (200), `GET /api/auth/me/hands?limit=3` (200), `GET /nothing-here-123` (404) | `http_requests_total{method="POST",route="/api/auth/login",status_code="200"} >= 1`; `{GET,"/api/auth/me","200"}`, `{GET,"/health","200"}`, `{GET,"/api/auth/me/hands","200"}`, `{GET,"unmatched","404"}` each ≥ 1; `http_request_duration_seconds_bucket{route="/health",le="+Inf"} >= 1`, `_count{route="/health"} >= 1`; no route label `/nothing-here-123`; no route contains `?` or `limit=`; no route matches `/\/\d+(\/|$)/`; no `route="/metrics"`. |
| `chat: a posted message is counted and its broadcast recorded` | two players on one table (default category); A sends `chat:message {text:'good luck all'}` → ack `{ok:true, messageId}`; B receives it | `chat_messages_total >= max(1, before+1)`; `socket_emits_total{event="chat:message"} >= 1`; `socket_messages_total{event="chat:message"} >= 1`. |
| `cardinality: no label carries an identifier, address or raw path` | final scrape | rules listed in §2.10 (forbidden label names, `_id` suffix, `code_` prefix, UUID/IPv4/IPv6/SHA-256 values, `code` snake_case, `event` `/^[a-z]+:[a-zA-Z]+$/`, `category` ∈ {seen,blind,other}, `method` `/^[A-Z]+$/`); at least one `game_*` sample with more than one label exists. |

Helper semantics worth copying: `eventually(check)` re-scrapes every 60 ms for up to 5 s because counters
are bumped server-side after the client has already seen the event; `value(name, labels)` **sums** all
samples whose labels include the given subset.

### stakes.test.js (runs with the **default** `TABLE_STAKES`/`LOBBY_TABLES` — the env vars are `delete`d)

| Test | Asserts |
|---|---|
| `the lobby offers exactly the 200 and 5000 stakes` | `config.game.tableStakes` deepEquals `[200, 5000]`; `lobbyOptions().stakes` same; `lobbyOptions().categories` deepEquals `['seen','blind']`. |
| `the menu is three rooms, in the order the lobby shows them` | `lobbyOptions().tables` deepEquals the three objects in §1.6.6 exactly (key set and values). |
| `the ceiling a card advertises is the one the table is built with` | for each menu entry, `quickJoin(player, entry)` → `table.maxPot === entry.maxPot` and `table.config.maxBlindMoves === entry.maxBlindMoves`. |
| `every room on the menu can be joined` | each entry joinable; `table.config.bootAmount` and `table.category` match; `listTables().length === 3`. |
| `a stake and category that is not a room on the menu is refused` | `quickJoin({bootAmount:5000, category:'seen'})` throws code `table_not_offered`; no table created. |
| `a stake the lobby does not offer is refused` | for `1, 100, 199, 4999, 10000` → `invalid_stake`. |
| `a malformed stake is refused` | for `0, -200, 200.5, NaN, 'lots', null` → `invalid_stake`. |

### lobbyRules.test.js (entry cap; `cap = config.game.entryCapMaxChips`, `capBoot`, `capCategory` from config)

| Test | Asserts |
|---|---|
| `a big stack cannot join the capped table` | chips `cap+1` at `{capBoot, capCategory}` → `over_entry_cap`. |
| `a stack exactly at the cap may still join` | chips `cap` → no throw. |
| `the cap applies only to that stake and category` | `cap+1` at the other category same boot → ok; at the other stake same category → ok. |
| `joining the capped table by code is refused too` | `joinByCode` with `cap+1` → `over_entry_cap`. |
| `the lobby is told the rule so it can grey the table out` | `lobbyOptions().entryCapBoot/entryCapCategory/entryCapMaxChips` equal config. |
| `a switch is not blocked by the entry cap` / `but the lobby route still refuses them` | switch ignores the cap; quick-join still refuses. |

### privateTables.test.js

| Test | Asserts |
|---|---|
| (private boot fixed, lines 30-44) | `createTable({bootAmount: X, isPrivate: true}).config.bootAmount === 200` for any X; public `createTable({bootAmount:100/5000, isPrivate:false})` keeps the asked boot. |
| `every table but a public blind one carries a pot ceiling` | private (any category) `maxPot === 500000`; public seen `1200000`; public blind `0`. |
| (line 120) | `serializeFor(...).maxPot === 500000` on a private table. |

### integration.test.js

| Test | Asserts |
|---|---|
| `the lobby offers the configured categories and stakes` | `session:ready.config.categories` deepEquals `['seen','blind']`; `config.stakes` is an array; `lobby:list` ack `ok:true` with `tables` array. |
| (line 138/149) | login response `welcomeChips === 200000` for a new account, `0` for a returning one. |
| (line 392) | `room:create` ack `code` matches `/^[A-Z2-9]{6}$/`. |
| (line 402) | a private table created with another boot has `config.bootAmount === 200`. |

No test covers: `METRICS_ALLOW_IPS`, `METRICS_ENABLED=false`, `METRICS_PATH`/`METRICS_PREFIX` overrides,
the production-mode throws, the logger, `num`/`bool`/`list` edge cases, `corsOrigin`, or `lobbyTables`
parsing of malformed entries. The Go port should add tests for those from §1.2-1.5.

---

## 6. Traps for the port

1. **`num` is `parseInt`, not strict.** `'200.9'` → 200, `'12abc'` → 12, `'1e3'` → 1, `'-5'` → -5. A strict
   integer parser would reject values the Node server accepts, and a float parser would accept `'200.9'`
   as 200.9. Negative/zero values are never rejected by config; downstream `if (!cap)`-style checks treat 0
   as "disabled".
2. **`??` vs empty string.** `TABLE_STAKES=` (empty) lifts the stake restriction and `LOBBY_TABLES=` opens the
   menu — the test suites rely on this. `JWT_SECRET=` (empty) passes the production guard. `METRICS_TOKEN=`
   disables the bearer check. Only *undefined* falls back to the default.
3. **`METRICS_ENABLED` is only off for the literal `false`.** `0`, `no`, `FALSE` keep metrics on. This is the
   opposite polarity of `bool()`.
4. **`lobbyTables` categories are unvalidated** and boot 0/negative survive; `tables[i].maxPot` is 0 for any
   non-`seen` category string. Reproduce, do not "fix", or the wire payload changes for a given env.
5. **`publicGameConfig.maxBetRounds` is the global 20**, not the per-category value. Same for `bootAmount`
   (the default 200, not any table's). Clients already consume these; keep them.
6. **Table config composition order matters**: `...config.game` → category rules → private rules → then
   `bootAmount`, `category`, `chatMaxHistory`, `chatMaxLength` overwrite last. Seen tables keep the global
   `potLimitMultiplier` (1024); blind tables get 0. Public blind has **no `maxPot` key at all** → Table's
   `config.maxPot ?? 0`. Private always ends with `maxRaiseSteps: 2`, `maxPot: 500000`, `bootAmount: 200`.
7. **Config is a snapshot at import.** Nothing hot-reloads; the tests depend on setting env *before* load. A Go
   port reading env lazily at call time would behave differently under tests that mutate env mid-run (none
   do today, but the stakes suite `delete`s two vars before import).
8. **Exposition details Prometheus tolerates but the test suite checks**: every sample name starts with
   `game_`; every sample carries `service="king-teenpatti"` (a Go registry with `ConstLabels` per metric
   must also apply it to the process collector); `le="1"` not `le="1.0"` (Go's client formats `1` as `1`,
   fine); `+Inf` bucket present; unlabelled metrics show a `0` sample immediately; labelled ones show nothing
   until first use (Go's `CounterVec` behaves the same unless pre-initialised — do **not** pre-initialise
   label sets like `action="see"` or the cardinality/absence assertions still pass but the counts differ
   from Node's "series appears on first use" behaviour).
9. **`game_tables` is a reset-and-recount gauge**: pairs with zero tables vanish. A Go `GaugeVec` that keeps
   stale series at 0 diverges (harmless for Grafana `sum by`, but not identical).
10. **Peak sockets is tracked in a variable**, set only when exceeded; it starts at 0 and never decreases.
11. **Message counters increment before the rate limiter**; a rate-limited `game:action` increments
    `socket_errors_total{rate_limited}` but **not** `invalid_moves_total`. Handler refusals count the
    **folded** code in labels but ack the **raw** code.
12. **`move_processing_duration_seconds` observes refusals too** (finally block), but only `table.act`
    refusals — the pre-checks (`unknown_action`, `not_in_room`, type-check `invalid_bet`) skip the histogram
    entirely. Hence `_count ≥ moves_total` per action, and `_count` can be 0 while `invalid_moves_total` is 3.
13. **`pot_settled_chips_total` is `inc(pot)`**, and it fires for `all_left` hands too when `winnerId` is set
    (the last leaver takes the pot) even though the hand is counted as abandoned rather than completed.
14. **`socket_emits_total` counts a room broadcast once**, per-viewer loops once (`room:state`, `player:hand`,
    `game:sideshowReveal`, `room:closed`), and `room:closed` only if at least one viewer is tracked.
    `emitToUser` with no live socket counts nothing.
15. **Join timing scope**: the `findById` DB read and the `room:joined` emit are inside the timed span; chat
    history and `broadcastState` are outside. `room:create` never broadcasts state. `room:switch` broadcasts
    the vacated table as well (two `room:state` increments).
16. **`hand_start_duration_seconds` and `db_transaction_duration_seconds{op="boot"}` observe the same span**
    (nested `timed`), likewise `settlement_duration_seconds` and `{op="settle"}`. Every settle retry is a fresh
    observation and, on failure, a fresh `db_transaction_errors_total{op="settle", code}`.
17. **Ledger error folding**: pg `23505` on a constraint whose `detail`/`constraint` text contains
    `action_id` → `duplicate_action`; every other unknown error → `persist_failed`. The `code` label uses
    `KNOWN_LEDGER_CODES`, not `KNOWN_ERROR_CODES` (which lacks `stale_state`, `no_pot`, `invalid_amount`).
18. **HTTP route label is the pattern, resolved at response-finish**, `baseUrl + route.path`; `'/'` under a
    mount collapses to the mount; unmatched → `unmatched`; `/` or `*.ext` (2-5 alnum chars) → `static`; the
    scrape path is skipped **before** timing starts. `HEAD` is a known method; `HEAD /metrics` hits the route
    (Express `app.get` serves HEAD) and is likewise not counted. Socket.IO polling/websocket HTTP requests
    never reach Express and are not counted.
19. **`/metrics` auth**: IP check before token check; `req.ip` is the raw peer with `::ffff:` stripped and no
    proxy trust — behind nginx the allow-list sees `127.0.0.1`. Token compare is exact string equality with
    `Bearer <token>` (no case folding, no trim). Failure bodies are plain `forbidden` / `unauthorized`.
20. **Event-loop and heap metrics are Node-only**; two alerts and several panels reference them. The port
    must either emit Go equivalents under *different* names (and update the dashboard/alerts) or accept
    those panels going empty — do not fake the Node names with unrelated Go values.
21. **`/health` mutates state on read**: it resets the loop-delay histogram and re-marks CPU on every call,
    so two pollers interleaving see each other's intervals. Field rounding is 1 dp via
    `Math.round(x*10)/10`; `db` is `null` only if the pool getter throws.
22. **Logger**: `LOG_LEVEL` is case-sensitive and unknown values (including `DEBUG`) fall back to `info`;
    only `error` goes to stderr; `meta` key is omitted when `undefined` but present as `null` when `null`;
    key order `t, level, msg, meta`.
23. **Room codes**: 32-symbol alphabet without `0 1 I O`, 6 chars, uniform via `byte % 32`, **no uniqueness
    check**; `uuid()` is v4 lowercase and doubles as the server-side `action_id` when a client omits one —
    it must be unique per move or the ledger's UNIQUE constraint refuses the bet as `duplicate_action`.
24. **dotenv reads `./.env` relative to the cwd** and never overrides pre-set variables. Running from the
    repo root vs `server/` changes which `.env` (if any) is read.
25. **Startup guard messages** are thrown as plain `Error`s at import in production only; their exact text
    is `JWT_SECRET must be set in production` and `AUTH_ALLOW_FAKE_PROVIDERS must be false in production`,
    checked in that order.
