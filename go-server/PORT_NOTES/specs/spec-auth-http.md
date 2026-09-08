# Spec: HTTP surface — Express app, REST routes, auth providers, JWT

Behavioural specification of the Node server's HTTP layer **as implemented in the working tree on
2026‑09‑08** (`server/src/index.js`, `server/src/auth/{routes,providers,tokens}.js`,
`server/src/db/{index,users}.js`, `server/src/util/logger.js`, `server/src/config/index.js`,
`server/src/metrics/index.js` where it sits in the HTTP path). Everything below was read from the
source and, where marked **[probed]**, confirmed against a live instance of the Node server running
on a throwaway Postgres schema.

Library versions that shape the wire behaviour (from `server/node_modules/*/package.json`):
express 4.22.2, body-parser 1.20.6, serve-static 1.16.3, send 0.19.2, finalhandler 1.3.2,
jsonwebtoken 9.0.3, jws 4.0.1, google-auth-library 9.15.1, prom-client 15.1.3, pg 8.23.0,
socket.io 4.8.3, ms 2.1.3, mime 1.6.0.

Legend used throughout:

| Tag | Meaning |
|---|---|
| **MUST** | wire or database behaviour a client, a test, or existing data depends on — reproduce exactly |
| **INCIDENTAL** | internal naming, logging, header trivia — reproduce if cheap, deviation is safe |
| **[probed]** | verified against the running Node server, not only read from source |

All file:line citations are into `/home/suraj/Project/king-teenpatti/server/src/…` unless another
root is given.

---

## 1. Process lifecycle

### 1.1 Configuration (config/index.js) — read once at import

`import 'dotenv/config'` (config/index.js:1) loads `<cwd>/.env` — **relative to the process working
directory, not the source tree** — and never overrides variables already in the environment. There is
no `server/.env` in the repo; production runs on defaults plus whatever the host exports.

Parsing helpers (config/index.js:7‑21):

| Helper | Rule |
|---|---|
| `num(v, fallback)` | `Number.parseInt(v ?? '', 10)`; non‑finite → fallback. So `"12abc"` → 12, `"abc"` → fallback, `"1e3"` → 1, `""` → fallback |
| `bool(v, fallback=false)` | undefined or `""` → fallback; otherwise true iff lower‑cased value ∈ {`1`,`true`,`yes`,`on`} |
| `list(v)` | `String(v ?? '')` split on `,`, each trimmed, empties dropped |

Keys the HTTP layer reads (defaults in parentheses; full table in CLAUDE.md §7.4):

| `config.` | Env | Default | Notes |
|---|---|---|---|
| `env` | `NODE_ENV` | `development` | config/index.js:24 |
| `port` / `host` | `PORT` / `HOST` | 3000 / `0.0.0.0` | :25‑26 |
| `corsOrigin` | `CORS_ORIGIN` | `'*'` | `'*'` or unset → the string `'*'`; otherwise `list()` → array. **Only Socket.IO uses it. Express has no CORS middleware at all** (see §2.3). :27 |
| `jwt.secret` | `JWT_SECRET` | `dev-only-insecure-secret` | :30 |
| `jwt.expiresIn` | `JWT_EXPIRES_IN` | `'30d'` | always a **string** (env values are strings) — see §5.1 for the parsing trap. :31 |
| `google.clientIds` | `GOOGLE_CLIENT_IDS` | `[]` | `list()` :35 |
| `facebook.appId` / `appSecret` | `FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET` | `''` / `''` | :39‑40 |
| `allowFakeProviders` | `AUTH_ALLOW_FAKE_PROVIDERS` | false | `bool()` :43 |
| `db.url` | `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/gameplay` | :52 |
| `db.schema` | `PG_SCHEMA` | `public` | :58 |
| `db.poolMax` | `PG_POOL_MAX` | 10 | :59 |
| `game.welcomeChips` | `WELCOME_CHIPS` | 200000 | :63 |
| `game.tableStakes` | `TABLE_STAKES` | `[200, 5000]` | `list()` → parseInt → keep integers > 0. :70‑72 |
| `game.lobbyTables` | `LOBBY_TABLES` | `[{seen,200},{blind,200},{blind,5000}]` | each entry `category:boot`; kept when category non‑empty and boot is an integer. :85‑90 |
| `game.seenMaxPot` | `SEEN_MAX_POT` | 1200000 | :114 |
| `game.maxBlindMoves` | `MAX_BLIND_MOVES` | 4 | :129 |
| `game.entryCapBoot/Category/MaxChips` | `ENTRY_CAP_*` | 200 / `blind` / 500000 | :139‑141 |
| `game.displayNameMaxLength` | `DISPLAY_NAME_MAX` | 24 | :160 |
| `game.privateMaxPot` / `privateBoot` | `PRIVATE_MAX_POT` / `PRIVATE_BOOT` | 500000 / 200 | :166,168 |
| `metrics.enabled` | `METRICS_ENABLED` | true | **true unless the string is exactly `false`** (not `bool()`): `(v ?? 'true') !== 'false'` :189 |
| `metrics.path` / `prefix` / `token` | `METRICS_PATH` / `METRICS_PREFIX` / `METRICS_TOKEN` | `/metrics` / `game_server_` / `''` | :190‑192 |
| `metrics.allowIps` | `METRICS_ALLOW_IPS` | `[]` | split/trim/filter :193‑196 |
| `redisUrl` | `REDIS_URL` | `''` | :209 |
| `rootDir` | — | `server/` (two levels above `src/config/`) | :5 — static dir and profiles dir derive from it |

**Production guard (MUST, config/index.js:213‑220):** when `env === 'production'`, the module throws
at import (process refuses to start) if `jwt.secret === 'dev-only-insecure-secret'`
(`'JWT_SECRET must be set in production'`) or `allowFakeProviders` is true
(`'AUTH_ALLOW_FAKE_PROVIDERS must be false in production'`).

### 1.2 Startup order (index.js:16‑138, 140‑152)

`createServer()`:

1. `await openDatabase()` (index.js:17) — see §1.4. Nothing else is built until the DB is ready.
2. Express app: `app.disable('x-powered-by')` (:20), `app.set('query parser', 'simple')` (:25).
3. `if (config.metrics.enabled) app.use(httpMetricsMiddleware())` (:27).
4. `app.use(express.json({ limit: '32kb' }))` (:28).
5. `rooms = new RoomManager()` (:30) — starts its sweeper interval; `bindRooms(rooms)`; `bindPool(getPool)` (:31‑32).
6. `if (config.metrics.enabled) app.get(config.metrics.path, metricsHandler())` (:33).
7. Event‑loop delay histogram `monitorEventLoopDelay({ resolution: 20 })` enabled; CPU marks taken (:40‑43).
8. `app.get('/health', …)` (:44‑80).
9. `app.use('/api/auth', authRoutes())` (:82).
10. `app.use('/api', playerRoutes({ isSeated: (userId) => Boolean(rooms.getTableForPlayer(userId)) }))` (:85).
11. `app.get('/api/rooms', …)` (:87‑97).
12. `app.use(express.static(path.join(config.rootDir, 'public')))` (:100).
13. Error handler `(error, req, res, next)` (:102‑111).
14. `http.createServer(app)`; `new Server(server, {cors:{origin: config.corsOrigin, methods:['GET','POST']}, transports:['websocket','polling'], pingInterval:20000, pingTimeout:25000, maxHttpBufferSize:1e5})` (:113‑123).
15. If `config.redisUrl`: dynamic‑import `@socket.io/redis-adapter` + `redis`, connect pub/sub clients, `io.adapter(...)`, log `'socket.io redis adapter enabled'` (:125‑133).
16. `attachSocketHandlers(io, rooms)` (:135). Returns `{ app, server, io, rooms }`.

Entrypoint check (index.js:140): the file only listens when `process.argv[1]` resolves to this file
(`import.meta.url === 'file://' + path.resolve(process.argv[1])`). Tests import `createServer` and
listen on port 0 themselves.

When it is the entrypoint (index.js:142‑168):

- `server.listen(config.port, config.host, cb)`; cb logs **info** `'king-teenpatti server listening'`
  with meta `{ url: 'http://<host>:<port>', env, welcomeChips, boot }` (:145‑152). INCIDENTAL.
- `process.on('SIGINT'|'SIGTERM')` → `shutdown(signal)`.
- `process.on('unhandledRejection', reason => logger.error('unhandled rejection', { reason: String(reason) }))` — the process does **not** exit on an unhandled rejection. No `uncaughtException` handler.

### 1.3 Graceful shutdown (index.js:154‑163) — MUST for ordering, INCIDENTAL for messages

1. log info `'shutting down'` `{ signal }`.
2. `setTimeout(() => process.exit(1), 8000).unref()` — hard exit code 1 after 8 s if the rest hangs.
3. `io.close()` — disconnects every socket **and closes the underlying HTTP listener** (Socket.IO's `Server.close` calls `httpServer.close`).
4. `await rooms.shutdown()` — every table is destroyed; a live hand's pot is paid out (settled) before the pool closes.
5. `await new Promise(resolve => server.close(resolve))` — resolves even though the server is already closing (the callback receives `ERR_SERVER_NOT_RUNNING`; the code ignores it).
6. `await closeDatabase()` — `pool.end()`.
7. `process.exit(0)`.

### 1.4 Database open (db/index.js:32‑64)

- Global pg type parsers, set at module import (db/index.js:14,17): OID 20 (int8) and OID 1700
  (numeric) → `Number(value)`. **MUST**: every BIGINT column (`chips`, all `*_at` timestamps,
  `total_winnings`, `biggest_pot`, `next_bonus_at`, ledger `delta`/`balance`) and every `SUM()`
  reaches JSON as a **number**, never a string.
- `openDatabase({url, schema})`: idempotent (returns the existing pool if open). Schema must match
  `/^[A-Za-z_][A-Za-z0-9_]*$/` else throws `PG_SCHEMA must be a plain identifier, got "<schema>"`.
- Pool: `new pg.Pool({ connectionString: url, max: config.db.poolMax, options: '-c search_path=<schema>,public' })`.
  The search path is a **connection startup option**, not a per‑connection `SET`. `pool.on('error')`
  logs error `'postgres pool error'` `{error}`.
- With one connection: `CREATE SCHEMA IF NOT EXISTS "<schema>"` (identifier quoted, `"` doubled),
  `SET search_path TO "<schema>", public`, then executes the whole of `db/schema.sql` as one multi‑statement
  query. `schema.sql` is fully idempotent (IF NOT EXISTS / CREATE OR REPLACE / DO block that creates the
  `chip_ledger_no_rewrite` trigger only if absent).
- Log info `'database ready'` `{ url: redact(url), schema }` where `redact` replaces `//user:password@`
  with `//user:***@` (db/index.js:119‑121).
- `withTransaction(fn)` (db/index.js:82‑99): `BEGIN` → `fn(client)` → `COMMIT`; on throw `ROLLBACK`
  (its own failure swallowed) and rethrow; client always released.
- `dropSchema()` refuses `public` (`'refusing to drop the public schema'`); `DROP SCHEMA IF EXISTS "<schema>" CASCADE`. Test‑only.
- `closeDatabase()` nulls the pool then `end()`s it.

### 1.5 Logger (util/logger.js) — INCIDENTAL format, but the fields are what ops greps

One JSON object per line:

```
{"t":"<new Date().toISOString()>","level":"<error|warn|info|debug>","msg":"<message>","meta":{...}}
```

- `meta` key is present **only when a meta argument was passed** (`meta !== undefined`) (logger.js:7‑8).
- Key order: `t`, `level`, `msg`, `meta`.
- `error` → stderr; everything else → stdout (logger.js:9).
- Threshold from `process.env.LOG_LEVEL` (read directly, not through config), default `info`;
  unknown level name → `info`. Levels: `error 0 < warn 1 < info 2 < debug 3`; a message is written iff
  `LEVELS[level] <= threshold`.

Messages emitted by the HTTP layer:

| Level | msg | meta | Source |
|---|---|---|---|
| info | `database ready` | `{url (redacted), schema}` | db/index.js:62 |
| error | `postgres pool error` | `{error}` | db/index.js:49 |
| info | `king-teenpatti server listening` | `{url, env, welcomeChips, boot}` | index.js:146 |
| info | `shutting down` | `{signal}` | index.js:155 |
| error | `unhandled rejection` | `{reason}` | index.js:167 |
| info | `account created` **or** `login` | `{userId, provider}` | routes.js:66‑69 |
| info | `milestone reward claimed` | `{userId, milestone}` | routes.js:124 |
| info | `timed bonus claimed` | `{userId}` | routes.js:146 |
| error | `request failed` | `{path: req.path, error: error.message, stack: error.stack}` | index.js:109 |
| info | `socket.io redis adapter enabled` | — | index.js:132 |

---

## 2. Express application settings and middleware chain

### 2.1 Settings (MUST where marked)

| Setting | Value | Effect | Tag |
|---|---|---|---|
| `x-powered-by` | disabled (index.js:20) | no `X-Powered-By` header | INCIDENTAL |
| `query parser` | `'simple'` (index.js:25) | Node `querystring.parse`: no nested objects; a repeated key becomes an **array** (`?a=1&a=2` → `['1','2']`) | MUST (see §4.7, §4.9) |
| `etag` | Express default `weak` | every `res.json`/`res.send` body gets `ETag: W/"<hex len>-<base64 sha1 (27 chars)>"`; a GET/HEAD carrying a matching `If-None-Match` gets **304** with no body **[probed]** | INCIDENTAL (no client sends conditionals) |
| `trust proxy` | default `false` | `req.ip` is the TCP peer address (IPv4‑mapped IPv6 like `::ffff:127.0.0.1` when the listener is dual‑stack) — matters only for the `/metrics` IP allow‑list | INCIDENTAL |
| `json spaces` | unset | `res.json` output is compact `JSON.stringify` (no whitespace) | MUST (bodies compared byte‑for‑byte by ETag; clients don't care) |
| `case sensitive routing` / `strict routing` | defaults off | `/API/Auth/me/` matches `/api/auth/me` **[probed]**; a trailing slash is accepted on every route | MUST‑ish (harmless to keep) |

Response headers on a `res.json` (express response.js:250‑282 → `res.send`): `Content-Type:
application/json; charset=utf-8`, `Content-Length`, `ETag` (weak), plus Node's `Date`,
`Connection: keep-alive`, `Keep-Alive: timeout=5`. **[probed]**. `res.json(obj)` is
`JSON.stringify(obj)` — `undefined` properties are dropped, `null` kept, `NaN`/`Infinity` become `null`.

`HEAD` is served for every `GET` route with the same headers and an empty body **[probed]**.
`OPTIONS` on a routed path is answered by Express itself: `200`, `Allow: GET,HEAD` (or `POST`),
`Content-Type: text/html; charset=utf-8`, body = the same comma list **[probed]** — INCIDENTAL.

### 2.2 Middleware / route order (MUST — determines which handler sees a request first)

```
1. httpMetricsMiddleware()          (only if metrics.enabled; skips req.path === metrics.path)  index.js:27
2. express.json({ limit: '32kb' })  index.js:28
3. GET  <metrics.path>              (only if metrics.enabled)                                   index.js:33
4. GET  /health                                                                                 index.js:44
5. router /api/auth  → POST /login, GET /me, GET /me/hands                                     index.js:82
6. router /api       → POST /rewards/milestone, POST /rewards/bonus, GET /profiles,
                       POST /profile/avatar, POST /profile/name                                 index.js:85
7. GET  /api/rooms                                                                              index.js:87
8. express.static(<rootDir>/public)   GET/HEAD only, falls through                              index.js:100
9. error handler (4‑arity)                                                                      index.js:102
10. Express finalhandler → 404 HTML                                                             (implicit)
```

Consequences:

- The JSON body parser runs for **every** request, including `GET /health` and static files. A
  `POST /health` with a malformed JSON body is a **500** (parser error → error handler), not a 404.
- A request to `/api/auth/login` with method `GET` falls through routers 5‑7, static (no such file) and
  lands on the **404 HTML** page (`Cannot GET /api/auth/login`) **[probed]**.
- Router mount prefixes match whole path segments: `/api/authx/me` is **not** under `/api/auth` **[probed]** → 404.

### 2.3 CORS — MUST (by absence)

There is **no** CORS middleware on the Express app. No `Access-Control-*` headers are ever sent on
REST responses, and preflights get the Express default `OPTIONS` answer above (no ACAO). The
`CORS_ORIGIN` value is passed **only** to the Socket.IO engine (index.js:116), which handles CORS for
`/socket.io/*` itself. The bundled browser client is same‑origin; Flutter is native. A port that adds
CORS headers changes observable behaviour; a port that omits them matches.

### 2.4 JSON body parsing (body-parser 1.20.6 `json`, index.js:28) — MUST

- Applies when the request has a body (`Content-Length` > 0 or `Transfer-Encoding`) **and**
  `Content-Type` matches `application/json` (parameters like `; charset=utf-8` allowed;
  `application/vnd.api+json` does **not** match → body skipped, `req.body = {}` **[probed]**).
- No body / non‑matching type → `req.body = {}` (never `undefined` after this middleware).
  A `text/plain` body carrying valid JSON is **ignored** → `req.body = {}` **[probed]**.
- Empty body with a JSON content‑type → `{}` (special‑cased).
- `strict: true` (default): the first non‑whitespace char must be `{` or `[`. `"x"`, `123`, `null`,
  `true` → `SyntaxError` → **HTTP 500 `internal_error`** (see §3.1) **[probed]**.
- Malformed JSON → `SyntaxError` → **500 `internal_error`** **[probed]** and an error log line `request failed`.
- Body larger than **32 kB (32768 bytes)** → `PayloadTooLargeError` (`request entity too large`) → **500 `internal_error`** **[probed]**.
  The check is on `Content-Length` when present, otherwise on the streamed byte count.
- Charset other than `utf-*` (e.g. `; charset=utf-16`) → 415 error object → **500 `internal_error`** **[probed]**.
- `inflate: true`: `Content-Encoding: gzip|deflate|br` bodies are decompressed before the limit is applied
  to the *inflated* size; unsupported encodings → 415 → 500.
- A JSON **array** body parses successfully; the login route then reads `provider` off an array →
  `undefined` → `unknown_provider` **[probed]**.

The important rule: **every body‑parser failure surfaces as 500 `{"error":"internal_error","message":"Something went wrong"}`**
because the custom error handler only special‑cases `AuthError`/`GameError` and ignores `error.status`.

### 2.5 Static files (serve-static 1.16.3 defaults, index.js:100) — MUST for the browser client

Root: `<rootDir>/public` = `server/public/` containing `index.html`, `client.js`, `style.css`,
`theme.css`, `profiles/` (15 SVGs + `NOTICE.txt`).

| Behaviour | Detail |
|---|---|
| Methods | `GET` and `HEAD` only; other methods fall through to the 404 **[probed]** (`POST /index.html` → 404 HTML) |
| Index | `GET /` serves `index.html` (default `index: ['index.html']`) **[probed]** |
| Directory without slash | `GET /profiles` → **301** `Location: /profiles/`, body `<!DOCTYPE html>…<pre>Redirecting to /profiles/</pre>…`, `Content-Type: text/html; charset=UTF-8`, `Content-Security-Policy: default-src 'none'`, `X-Content-Type-Options: nosniff` **[probed]** |
| Directory with slash, no index | `GET /profiles/` → falls through → **404** HTML **[probed]** |
| Dotfiles | `dotfiles: 'ignore'` → 404 |
| Traversal | `..` segments are normalised away by the URL parser (`/../package.json` → `/package.json` → 404); `%2e%2e` decoded then rejected → 404 **[probed]** |
| Headers on a hit | `Accept-Ranges: bytes`, `Cache-Control: public, max-age=0`, `Last-Modified`, `ETag: W/"<size hex>-<mtime hex>"`, `Content-Length` **[probed]** |
| Content types (mime 1.6) | `.html` → `text/html; charset=UTF-8`, `.js` → `application/javascript; charset=UTF-8`, `.css` → `text/css; charset=UTF-8`, `.svg` → `image/svg+xml` (no charset), `.txt` → `text/plain; charset=UTF-8` **[probed for html/svg/txt]** |
| Conditional / range | `If-None-Match` / `If-Modified-Since` → 304; `Range` honoured (206). INCIDENTAL |

The Flutter client loads avatar images from `<SERVER_URL>/profiles/<name>.svg` using the `url`
field returned by `/api/profiles`, so `/profiles/*.svg` **must** be served.

### 2.6 404 (finalhandler 1.3.2) — MUST shape for HTML clients, INCIDENTAL for API clients

Any unmatched request (unknown path, wrong method on a known path, static miss):

```
HTTP/1.1 404 Not Found
Content-Security-Policy: default-src 'none'
X-Content-Type-Options: nosniff
Content-Type: text/html; charset=utf-8
Content-Length: <n>

<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Error</title>
</head>
<body>
<pre>Cannot GET /nothing-here</pre>
</body>
</html>
```

`Cannot <METHOD> <req.path — HTML‑escaped, query string excluded>` **[probed]**. The body is HTML, **not JSON** —
the Flutter `ApiClient._decode` handles this by failing `jsonDecode` (it never hits a 404 in practice).
There is no JSON 404 anywhere under `/api`.

---

## 3. Error handling

### 3.1 Error handler (index.js:102‑111) — MUST

```
if (error instanceof AuthError)  → status error.status, body {"error": error.code, "message": error.message}
if (error instanceof GameError)  → status 400,          body {"error": error.code, "message": error.message}
else → logger.error('request failed', {path, error: message, stack}); status 500,
       body {"error":"internal_error","message":"Something went wrong"}
```

Key order is always `error` then `message`. No other keys on 5xx. Nothing in the HTTP layer
currently throws `GameError` (it is game‑engine only), so in practice the 400 branch is unused by REST.

`AuthError(code, message, status = 401)` (providers.js:5‑12): `name = 'AuthError'`, `.code`, `.status`.

### 3.2 Complete error catalogue for the REST surface

| HTTP | `error` | `message` | Where |
|---|---|---|---|
| 400 | `unknown_provider` | `Unsupported login provider "<provider>"` — `<provider>` is the raw value stringified, so `"undefined"` when absent **[probed]** | providers.js:157 |
| 400 | `invalid_device_id` | `A deviceId of at least 8 characters is required` | providers.js:103 |
| 401 | `missing_token` | `idToken is required for Google login` | providers.js:23 (only reachable when fake providers are off, or on with… never: see §6.4) |
| 401 | `missing_token` | `accessToken is required for Facebook login` | providers.js:58 (same) |
| 503 | `provider_unconfigured` | `Google login is not configured on this server` | providers.js:25 |
| 503 | `provider_unconfigured` | `Facebook login is not configured on this server` | providers.js:60 |
| 503 | `provider_unconfigured` | `<provider> login is not configured on this server` (`google`/`facebook` lowercase as sent) | providers.js:132 |
| 401 | `invalid_token` | `Google token rejected: <google-auth-library message>` | providers.js:36 |
| 401 | `invalid_token` | `Google token had no subject` | providers.js:39 |
| 401 | `invalid_token` | `Facebook rejected the access token` | providers.js:69 |
| 401 | `invalid_token` | `Facebook access token is not valid` | providers.js:72 |
| 401 | `invalid_token` | `Facebook token was issued for a different app` | providers.js:74 |
| 401 | `invalid_token` | `Could not read the Facebook profile` | providers.js:81 |
| 401 | `missing_token` | `A session token is required` | tokens.js:15 |
| 401 | `invalid_session` | `Session token rejected: <jsonwebtoken message>` (see §5.3) | tokens.js:19 |
| 401 | `unknown_user` | `This account no longer exists` | routes.js:39 |
| 409 | `reward_not_available` | `No milestone reward is waiting yet.` (+ `user`) | routes.js:118‑122 |
| 409 | `reward_not_ready` | `The bonus is still recharging.` (+ `readyAt`, `user`) | routes.js:139‑144 |
| 409 | `seated` | `You cannot change your picture while you are at a table.` | routes.js:167‑170 |
| 409 | `seated` | `You can only change your name in the lobby.` | routes.js:199‑202 |
| 400 | `unknown_avatar` | `That picture is not available.` | routes.js:178 |
| 400 | `empty_name` | `Your name cannot be empty.` | routes.js:211‑219 |
| 400 | `name_too_long` | `Keep it to <displayNameMaxLength> characters or fewer.` (`24` by default) | routes.js:213 |
| 400 | `invalid_name` | `Letters, numbers and spaces only.` | routes.js:214 |
| 500 | `internal_error` | `Something went wrong` | index.js:110 — body‑parser failures, DB errors, `unknown user <id>` throws, unique‑violation races, Facebook JSON parse failures, anything unexpected |

How clients consume errors (MUST keep `message` human‑readable):

- Flutter `ApiClient._decode` (flutter-client/lib/net/api_client.dart:33‑46): on status ≥ 400 reads
  `map['error']`; **if `error` is a Map** it uses `error['message']`, otherwise `map['message']`; empty/null →
  `Request failed (<status>)`. So the server's top‑level `message` is what the player sees.
- Browser `login()` (public/client.js:142‑150): `data.message || data.error || 'Login failed'`.
- Browser `claimReward` (client.js:820‑834): on `!ok` shows `data.message ?? …` and applies `data.user` if present.

---

## 4. Routes

Common conventions: every success is `res.json(...)` → 200 with the headers in §2.1. Every `user`
object is the **public user** shape of §7.1. Timestamps are epoch **milliseconds** as JSON numbers.

### 4.1 `POST /api/auth/login` (routes.js:61‑80) — MUST

Auth: none. Body (JSON object):

```
{ "provider": "google" | "facebook" | "guest",
  "idToken"?: string,          // google
  "accessToken"?: string,      // facebook
  "deviceId"?: any,            // guest
  "displayName"?: any,         // guest, and fake google/facebook
  "providerUserId"?: any }     // fake google/facebook only
```

Flow:

1. `profile = await verifyLogin(req.body ?? {})` (§6) — throws `AuthError`.
2. `{ user, isNew } = await upsertFromProfile(profile)` (§7.2).
3. Log info `account created` (isNew) or `login`, meta `{ userId: user.id, provider: user.provider }`.
4. Respond **200**:

```json
{ "token": "<JWT>", "user": { …public user… }, "isNew": true|false, "welcomeChips": 200000|0 }
```

`welcomeChips` is `config.game.welcomeChips` when `isNew`, else **`0`** (routes.js:75). Key order:
`token`, `user`, `isNew`, `welcomeChips`.

Clients: Flutter `loginGuest` sends `{provider:'guest', deviceId, displayName?}` (`displayName`
omitted when blank; trimmed) and reads `token`, `user`, `isNew == true`, `welcomeChips` (api_client.dart:50‑71).
Browser sends guest, or fake `google`/`facebook` with `providerUserId: 'web-google-<deviceId>'` and
`displayName` (client.js:166‑181). Bots/loadtest/ramptest send guest logins with fixed device ids.

### 4.2 `GET /api/auth/me` (routes.js:83‑85) — MUST

Auth: bearer (§5.4). Response **200** `{ "user": { …public user… } }`. The user is re‑read from the DB
by `requireAuth` on every call (fresh chips/stats). Flutter calls this on cold start with the saved
token (game_state.dart:193) and after rewards/renames; the browser `refreshProfile()` does too.

### 4.3 `GET /api/auth/me/hands?limit=N` (routes.js:88‑95) — MUST shape (no client calls it; the metrics test hits it)

Auth: bearer. `limit = Math.min(Number.parseInt(req.query.limit ?? '20', 10) || 20, 100)`:

| `?limit=` | effective |
|---|---|
| absent, `abc`, `0`, `NaN` | 20 (`parseInt` → NaN or 0 → `|| 20`) |
| `3`, `3.9`, `3abc` | 3 |
| `1e3` | 1 |
| `500` | 100 |
| `-5` | **−5** → `Array.slice(0, -5)` → *all hands except the last five* (bug, preserve or decide — see open questions) |
| `limit=3&limit=5` (array) | `parseInt(['3','5'])` → `parseInt('3,5')` → 3 |

Query (users.js:184‑208):

```sql
SELECT DISTINCT ON (h.id) h.*
  FROM hands h
  JOIN chip_ledger l ON l.hand_id = h.id
 WHERE l.user_id = $1
 ORDER BY h.id, h.ended_at DESC
```

then in JS: stable sort by `ended_at` **descending**, `slice(0, limit)`, map to:

```json
{ "hands": [ { "id": string, "roomId": string, "handNo": int, "pot": int, "winnerId": string|null,
               "winReason": string|null, "endedAt": int, "summary": <summary_json> } ] }
```

`summary` is the JSONB `summary_json` already parsed by pg (an array of
`{userId, displayName, seatIndex, contributed, status, sawCards, cards: string[]|null}` — table.js:1444‑1452);
the `typeof === 'string' ? JSON.parse : as‑is` guard is legacy. `bootAmount` and `startedAt` are **not**
returned. A player appears in a hand iff they have **any** `chip_ledger` row with that `hand_id`
(boot, bet, show, hand_win, hand_loss).

### 4.4 `POST /api/rewards/milestone` (routes.js:114‑129) — MUST

Auth: bearer. Body ignored (browser sends none; Flutter sends `{}`). Calls `claimMilestoneReward(userId)` (§7.4).

- Claimed → **200** `{ "claimed": true, "amount": 25000, "milestone": <int>, "user": {…} }` and log info
  `milestone reward claimed` `{userId, milestone}`.
- Not claimed → **409** `{ "error": "reward_not_available", "message": "No milestone reward is waiting yet.", "user": {…} }`.
  The internal `reason: 'not_available'` is **not** sent.

### 4.5 `POST /api/rewards/bonus` (routes.js:135‑151) — MUST

Auth: bearer. Calls `claimTimedBonus(userId)` (§7.5).

- Claimed → **200** `{ "claimed": true, "amount": 10000, "readyAt": <epoch ms>, "user": {…} }`, log info `timed bonus claimed` `{userId}`.
- Not ready → **409** `{ "error": "reward_not_ready", "message": "The bonus is still recharging.", "readyAt": <epoch ms>, "user": {…} }` **[probed]**.

Client note (MUST NOT "fix" silently): Flutter's `claimReward` reads **`awarded`** from the response
(api_client.dart:135) — a field the server never sends — so on success it shows the `message` fallback
(`'Not ready yet.'` when `message` is absent) while still applying `user`. The browser reads `amount`
(client.js:833). The wire field is `amount`.

### 4.6 `GET /api/profiles` (routes.js:154‑156, 23‑33) — MUST

Auth: none. Reads the directory `<rootDir>/public/profiles` **on every request** (`fs.readdirSync`),
keeps names matching `/\.(svg|png|jpg|jpeg|webp)$/i`, sorts with JS default sort (UTF‑16 code‑unit
order — uppercase before lowercase), maps to `{ id: <filename>, url: '/profiles/<filename>' }`.
Directory unreadable → `[]`.

Response **200** `{ "profiles": [ {"id":"bear.svg","url":"/profiles/bear.svg"}, … ] }` — currently
15 entries: bear, cat, dog, fox, frog, horse, koala, lion, monkey, owl, panda, penguin, rabbit,
tiger, wolf (`NOTICE.txt` excluded) **[probed]**. `url` is **relative**; clients prefix their base URL.

### 4.7 `POST /api/profile/avatar` (routes.js:164‑187) — MUST

Auth: bearer. Body `{ "avatar": "<id>" | null }`. Check order:

1. `isSeated(req.user.id)` → **409** `{"error":"seated","message":"You cannot change your picture while you are at a table."}`.
   `isSeated` = `Boolean(rooms.getTableForPlayer(userId))` (index.js:85; roomManager.js:183‑186 —
   `playerRooms.get(userId)` then `tables.get(roomId) ?? null`, so a stale map entry for a destroyed table is *not* seated).
2. `requested = req.body?.avatar ?? null` (`undefined`/missing → null).
3. If `requested !== null`: must strictly equal (`===`) an `id` from the live directory listing (§4.6).
   `''`, `0`, `false`, `'nope.svg'`, `'/profiles/bear.svg'`, `'BEAR.SVG'` → **400** `{"error":"unknown_avatar","message":"That picture is not available."}` **[probed for '' and nope.svg]**.
4. `setAvatarChoice(userId, requested ? '/profiles/' + requested : null)`:
   `UPDATE users SET avatar_choice = $1, updated_at = $2 WHERE id = $3` then re‑read (users.js:328‑331).
   Stored value is the **URL form** `/profiles/bear.svg`, not the bare id.
5. **200** `{ "user": {…} }` — `avatarChoice` = `/profiles/bear.svg`, `avatarUrl` = the same (choice wins);
   after clearing, `avatarChoice: null`, `avatarUrl` = provider picture or null **[probed]**.

### 4.8 `POST /api/profile/name` (routes.js:196‑226) — MUST

Auth: bearer. Body `{ "name": any }`. Check order:

1. `isSeated` → **409** `{"error":"seated","message":"You can only change your name in the lobby."}`.
2. `normalizeDisplayName(req.body?.name, { maxLength: config.game.displayNameMaxLength })` (users.js:305‑320):
   - `trimmed = `${raw ?? ''}`.trim().replace(/\s+/g, ' ')` — template‑literal stringification
     (number `123` → `"123"` → **accepted, name becomes "123"** [probed]; object → `"[object Object]"` → invalid;
     array `['a','b']` → `"a,b"` → invalid). `\s` is JS Unicode whitespace (includes NBSP, ` `, `\t`, `\n`…);
     any run collapses to **one ASCII space** (`' सुरज\t\tकुमार '` → `'सुरज कुमार'` **[probed]**).
   - empty → `Error('empty_name')`.
   - `trimmed.length > maxLength` (**UTF‑16 code units**, so an astral character counts 2, a Devanagari
     syllable with a vowel sign counts 2+) → `Error('name_too_long')`.
   - `!/^[\p{L}\p{N}][\p{L}\p{N}\p{M} ]*$/u.test(trimmed)` → `Error('invalid_name')`. First char must be a
     letter or number (`\p{N}` = Nd+Nl+No, so `½`, `Ⅻ`, `²` pass); later chars may also be combining marks
     (`\p{M}` — **essential** for Indic vowel signs) or ASCII space. Hyphen, underscore, dot, emoji → invalid.
3. On error → **400** `{ "error": <empty_name|name_too_long|invalid_name>, "message": <see §3.2> }`.
   The `messages[...] ?? 'That name cannot be used.'` fallback is unreachable (only three codes exist).
4. `setDisplayName`: `UPDATE users SET display_name = $1, updated_at = $2 WHERE id = $3` then re‑read (users.js:322‑325).
5. **200** `{ "user": {…} }`.

Note the asymmetry with login: names accepted at guest login are only `sanitizeName`d (§6.3) — punctuation
is allowed there and internal double spaces survive — while `/api/profile/name` applies `NAME_PATTERN`.

### 4.9 `GET /api/rooms?category=` (index.js:87‑97) — MUST shape (no client calls it; `peek-tmp.mjs`/ops do)

Auth: none. `category = req.query.category === 'blind' || === 'seen' ? that : null` — case‑sensitive;
`BLIND`, arrays (`?category=blind&category=seen`), anything else → `null` = no filter **[probed]**.

```json
{ "tables": [ { "roomId": string, "code": string, "category": "seen"|"blind", "state": "waiting"|"starting"|"betting"|"showdown",
                "players": int, "maxPlayers": int, "bootAmount": int, "pot": int } ],
  "options": { "categories": ["seen","blind"], "stakes": [200,5000],
               "tables": [ {"category":"seen","bootAmount":200,"maxPot":1200000,"maxBlindMoves":4},
                           {"category":"blind","bootAmount":200,"maxPot":0,"maxBlindMoves":4},
                           {"category":"blind","bootAmount":5000,"maxPot":0,"maxBlindMoves":4} ],
               "entryCapBoot": 200, "entryCapCategory": "blind", "entryCapMaxChips": 500000,
               "privateBoot": 200, "privateMaxPot": 500000 } }
```

`tables` = `rooms.listTables({ category })` (roomManager.js:188‑193): **public tables only**
(`isPrivate` excluded), filtered by category, each `table.summary()` (table.js:1742‑1753; `pot` is
`hand?.pot ?? 0`). `options` = `RoomManager.lobbyOptions()` (roomManager.js:196‑223):
`maxPot` = `seenMaxPot` for seen entries, `0` for blind; `maxBlindMoves` = `config.game.maxBlindMoves`.
The same `options` object is what Socket.IO sends as `session:ready.config` (see the socket spec), so
Flutter's `LobbyTable.fromJson` expects exactly these keys.

### 4.10 `GET /health` (index.js:44‑80) — MUST shape (bots, loadtest, ramptest, ops poll it)

Auth: none. Key order and types **[probed]**:

```json
{ "ok": true,
  "uptime": 0.518896432,          // process.uptime(), float seconds
  "tables": 0,                    // rooms.stats(): tables.size
  "players": 0,                   //   playerRooms.size (seated users incl. disconnected‑in‑grace)
  "activeHands": 0,               //   tables with hand !== null
  "sockets": 0,                   // io.engine.clientsCount, or null if the engine is absent
  "process": {
    "pid": 12527,
    "node": "v22.22.1",           // process.version — literal Node version string
    "rssMb": 114.8, "heapUsedMb": 21.1, "heapTotalMb": 52.5, "externalMb": 4.6,   // bytes/1048576, 1 dp
    "cpuPercent": 145.5,          // (user+system µs since previous /health) / elapsed µs * 100, 1 dp; 0 when elapsed ≤ 0
    "loopLagP50Ms": 20.2, "loopLagP99Ms": 22.8, "loopLagMaxMs": 22.8   // ns/1e6, 1 dp; histogram reset after each response
  },
  "db": { "total": 1, "idle": 1, "waiting": 0 } }   // pg pool counts; null if getPool() throws
```

Rounding helpers: `mb = Math.round(bytes / 1048576 * 10) / 10`, `ns = Math.round(v / 1e6 * 10) / 10`,
`cpuPercent = Math.round((cpu.user + cpu.system) / elapsedUs * 1000) / 10`. CPU and loop‑lag are
**windowed between consecutive `/health` calls** (marks reset on every call), so the first call after
boot reports since‑start and a rapid second call reports a tiny window. `monitorEventLoopDelay`
resolution 20 ms means an idle loop shows ≈20 ms, not 0. Consumers: `tools/bot.js:184` (prints
`players`/`tables`), `test/loadtest.js:148‑195` and `tools/ramptest.mjs:106,204` (uses `ok`,
`players`, `tables`, and the whole `process` block when present), integration test asserts
`ok === true` and numeric `tables`/`players`.

### 4.11 `GET /metrics` (metrics/index.js:391‑406) — MUST for the ops bundle

Auth: optional. Check order: (1) if `allowIps` non‑empty and `req.ip` (with a leading `::ffff:` stripped)
not in the list → **403** `text/plain` body `forbidden`; (2) if `token` set and
`Authorization !== 'Bearer <token>'` (exact string compare, case‑sensitive `Bearer`) → **401**
`text/plain` body `unauthorized`; (3) `Content-Type: text/plain; version=0.0.4; charset=utf-8`
(prom‑client's `registry.contentType`; Express normalises to `text/plain; charset=utf-8; version=0.0.4`
**[probed]**) and the exposition text. The scrape itself is excluded from HTTP metrics (`req.path === metrics.path`
short‑circuit, metrics/index.js:357). The metric catalogue is out of scope here (see CLAUDE.md §7.5 and
`test/metrics.test.js`), but the HTTP middleware is in scope:

`httpMetricsMiddleware()` (metrics/index.js:355‑372): on `res 'finish'` increments
`game_http_requests_total{method, route, status_code}` and observes
`game_http_request_duration_seconds` (buckets 1 ms…1 s). `method` ∈ {GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS} else `OTHER`.
`route` = `routeLabel(req)` (metrics/index.js:339‑347): if a route matched → `req.baseUrl + route path`
(`/api/auth/me`, `/api/auth/me/hands`, `/api/rewards/bonus`, `/health`, `/api/rooms`; a route whose path is
`/` under a non‑empty base yields the base alone); else `static` when `req.path === '/'` or ends in
`.<2‑5 alnum>`; else `unmatched`. **Never the raw URL, never a query string, never an id.** A body‑parser
failure has no `req.route` so it lands in `unmatched` with status 500.

### 4.12 Dead / unreferenced surface (INCIDENTAL, keep for parity)

`GET /api/auth/me/hands`, `GET /api/rooms` have no client caller. `requireAuth` is exported but only
used inside routes.js. `findByProvider`, `applyChipDelta`, `settleHand` in users.js are not reached by HTTP.

---

## 5. Session tokens (JWT) — tokens.js, jsonwebtoken 9.0.3

### 5.1 Issue (tokens.js:6‑12) — MUST

```
jwt.sign({ sub: user.id, provider: user.provider, name: user.displayName }, config.jwt.secret, { expiresIn: config.jwt.expiresIn })
```

- Header, exactly: `{"alg":"HS256","typ":"JWT"}` (jsonwebtoken adds `kid` only when given; `undefined` is dropped) **[probed]**.
- Payload, key order: `{"sub":"<uuid>","provider":"guest|google|facebook","name":"<displayName>","iat":<int>,"exp":<int>}` **[probed]**.
  `iat = Math.floor(Date.now()/1000)`; `exp = Math.floor(iat + ms(expiresIn)/1000)` (jsonwebtoken/lib/timespan.js).
- Signature: HMAC‑SHA256 over `base64url(header) + "." + base64url(payload)` with the secret as UTF‑8 bytes; base64url without padding.
- `expiresIn` parsing (`ms` 2.1.3): `"30d"` → 2 592 000 s. **Because the config value is always a string**,
  a numeric env value such as `JWT_EXPIRES_IN=3600` is parsed by `ms('3600')` as **3600 milliseconds → 3 s**, not 3600 s.
  An unparseable string (`ms()` → undefined) makes `expiresIn` invalid → `jwt.sign` throws
  `'"expiresIn" should be a number of seconds or string representing a timespan'` → login returns **500**.
- `name` is the display name **at login time**; it is never re‑checked (a rename does not invalidate tokens).
  Nothing reads `provider`/`name` from the token server‑side; only `sub` is used.

### 5.2 Extract (tokens.js:24‑28) — MUST

`tokenFromRequest(req)`: `header = req.headers.authorization ?? ''`; if `header.toLowerCase().startsWith('bearer ')`
return `header.slice(7).trim()`, else `null`.

- `bearer <t>`, `BEARER <t>`, `Bearer  <t> ` (extra spaces) all yield `<t>` **[probed]**.
- `Bearer` alone (no space), `Basic …`, `Token …`, missing header → `null` → `missing_token`.
- `Bearer ` followed by only spaces → `''` → falsy → `missing_token`.
- Only the `Authorization` header is consulted (no query‑string token on REST; the socket handshake also
  accepts `handshake.query.token`, socket/index.js:382).

### 5.3 Verify (tokens.js:14‑21) — MUST

`verifyToken(token)`: falsy → `AuthError('missing_token', 'A session token is required')`.
Otherwise `jwt.verify(token, secret)` with **default options**; any throw →
`AuthError('invalid_session', 'Session token rejected: ' + error.message)` (401). Returns the decoded payload.

jsonwebtoken 9 semantics with a string secret and no `algorithms` option (verify.js:57‑200):

| Condition | `error.message` → wire message suffix |
|---|---|
| not exactly 3 dot‑separated parts | `jwt malformed` **[probed]** (`nonsense`, `a.b`) |
| header/payload not decodable JSON | `invalid token` |
| empty signature part (alg `none`) | `jwt signature is required` **[probed]** |
| `header.alg` ∉ {`HS256`,`HS384`,`HS512`} | `invalid algorithm` |
| HMAC mismatch | `invalid signature` **[probed]** |
| `payload.nbf` present, not a number | `invalid nbf value` |
| `nbf > now` | `jwt not active` |
| `payload.exp` present, not a number | `invalid exp value` |
| `now >= exp` (clockTolerance 0, `now = Math.floor(Date.now()/1000)`) | `jwt expired` **[probed]** |

**A token signed with HS384 or HS512 using the same secret verifies successfully** **[probed]** — the
default algorithm set for a symmetric secret is all three HMAC variants. `exp` is optional at verify
time: a token without `exp` never expires. `iat` is not validated (no `maxAge`). Payload claims are
not otherwise validated — `sub` may be absent (then `findById(undefined)` → pg binds NULL → no row →
`unknown_user`).

### 5.4 `requireAuth` middleware (routes.js:35‑45) — MUST

1. `claims = verifyToken(tokenFromRequest(req))` — 401 `missing_token` / `invalid_session`.
2. `user = await findById(claims.sub)` — `SELECT * FROM users WHERE id = $1` → public user; `null` →
   `AuthError('unknown_user', 'This account no longer exists')` (401) **[probed]**.
3. `req.user = user` (the **public** shape, so handlers see `req.user.id`, `.chips`, etc.), `next()`.

Ordering consequence: authentication runs **before** any body validation or seated check on every
protected route, and a DB error inside `findById` becomes a 500.

The Socket.IO handshake (socket/index.js:380‑391) reuses `verifyToken` + `findById`: failures become
`connect_error` with message `error.code ?? 'unauthorized'` → `missing_token` / `invalid_session` / `unknown_user`.

---

## 6. Login providers (providers.js)

### 6.1 Dispatch — `verifyLogin({ provider, ...payload })` (providers.js:144‑159) — MUST

`req.body ?? {}` is destructured: `provider` is read as a property (so an array body or a body without
the key gives `undefined`). Switch on the **exact** string:

| `provider` | Branch |
|---|---|
| `'google'` | `config.allowFakeProviders && !payload.idToken` ? `verifyFake({provider, ...payload})` : `verifyGoogle(payload)` |
| `'facebook'` | `config.allowFakeProviders && !payload.accessToken` ? `verifyFake(...)` : `verifyFacebook(payload)` |
| `'guest'` | `verifyGuest(payload)` |
| anything else (incl. `'Google'`, `undefined`, numbers) | `AuthError('unknown_provider', 'Unsupported login provider "<String(provider)>"', 400)` |

Note the fake branch is taken only when the real credential is **absent/falsy**. With
`AUTH_ALLOW_FAKE_PROVIDERS=true` and an `idToken` present, the *real* Google path runs (and with no
client ids configured returns 503 `provider_unconfigured`) **[probed]**. The literal `missing_token`
errors in `verifyGoogle`/`verifyFacebook` are therefore reachable only when fake providers are **off**.

All three verifiers return a **provider profile**:
`{ provider, providerUserId: string, displayName: string (non‑empty), email: string|null, avatarUrl: string|null }`.

### 6.2 Google — `verifyGoogle({ idToken })` (providers.js:22‑48) — MUST

1. `!idToken` → 401 `missing_token` `idToken is required for Google login`.
2. `config.google.clientIds.length === 0` → **503** `provider_unconfigured` `Google login is not configured on this server`.
3. `googleClient.verifyIdToken({ idToken, audience: config.google.clientIds })` with a module‑level
   `new OAuth2Client()` (no client id/secret). Any throw → 401 `invalid_token` `Google token rejected: <message>`.
4. `payload = ticket.getPayload()`; `!payload?.sub` → 401 `invalid_token` `Google token had no subject`.
5. Profile: `providerUserId = payload.sub`, `displayName = payload.name || payload.given_name || 'Player'`,
   `email = payload.email ?? null`, `avatarUrl = payload.picture ?? null`. **Not sanitised, not truncated**
   (the DB column is TEXT; the 24‑char limit is enforced only on `/api/profile/name` and in `sanitizeName`).
   `email_verified` is **not** checked.

google-auth-library 9.15.1 `verifyIdToken` semantics (oauth2client.js:503‑510, 544‑608, 648‑756) — a
port must reproduce these checks:

- Fetch Google's certificates from `https://www.googleapis.com/oauth2/v1/certs` (PEM map `{kid: pem}`
  on Node; the JWK URL `https://www.googleapis.com/oauth2/v3/certs` is used only in browsers). Cached
  until `max-age` from the response `Cache-Control` elapses; no cache when the header is missing.
  Uses the library's retry config for the fetch. Fetch failure message: `Failed to retrieve verification certificates: …`.
- Token must have exactly 3 segments (`Wrong number of segments in token: …`).
- Envelope (header) and payload are base64‑decoded and JSON‑parsed (`Can't parse token envelope…` / `…payload…`).
- `certs[envelope.kid]` must exist (`No pem found for envelope: …`). `alg` `ES256` signatures are DER‑converted; otherwise RS256 verify over `segments[0] + '.' + segments[1]`. Failure: `Invalid token signature: …`.
- `payload.iat` and `payload.exp` must be present and numeric (`No issue time in token`, `No expiration time in token`, `iat field using invalid format`, `exp field using invalid format`).
- `exp >= now + 86400` → `Expiration time too far in future` (`DEFAULT_MAX_TOKEN_LIFETIME_SECS_ = 86400`).
- `now < iat - 300` → `Token used too early…`; `now > exp + 300` → `Token used too late…` (`CLOCK_SKEW_SECS_ = 300`, `now` in float seconds).
- `iss` must be one of `['accounts.google.com', 'https://accounts.google.com', 'googleapis.com']` (the third is the default `universeDomain`) → else `Invalid issuer, expected one of […], but got <iss>`.
- Audience: `requiredAudience` is the **array** `config.google.clientIds`; the token's single `aud` string must be **an element of it** (`indexOf(aud) > -1`) → else `Wrong recipient, payload audience != requiredAudience`. `azp` is not checked.
- Returns `LoginTicket(envelope, payload)`; `getPayload()` is the raw payload object (`sub`, `name`, `given_name`, `email`, `picture`, …).

### 6.3 Facebook — `verifyFacebook({ accessToken })` (providers.js:57‑91) — MUST

1. `!accessToken` → 401 `missing_token` `accessToken is required for Facebook login`.
2. `!appId || !appSecret` → **503** `provider_unconfigured` `Facebook login is not configured on this server`.
3. `appToken = appId + '|' + appSecret`.
   `GET https://graph.facebook.com/debug_token?input_token=<encodeURIComponent(accessToken)>&access_token=<encodeURIComponent(appToken)>`
   (global `fetch`, no extra headers, no `appsecret_proof`).
   - `!response.ok` (non‑2xx) → 401 `invalid_token` `Facebook rejected the access token`.
   - body JSON `{ data }`; `!data?.is_valid` → 401 `invalid_token` `Facebook access token is not valid`.
   - `String(data.app_id) !== String(config.facebook.appId)` → 401 `invalid_token` `Facebook token was issued for a different app`.
   - a non‑JSON 2xx body → `SyntaxError` → **500**.
4. `GET https://graph.facebook.com/v20.0/<data.user_id>?fields=id,name,email,picture.type(large)&access_token=<encodeURIComponent(accessToken)>`
   (note: `user_id` is interpolated **unencoded**; `fields=` value is literal, the parentheses are not percent‑encoded).
   - `!response.ok` → 401 `invalid_token` `Could not read the Facebook profile`.
5. Profile: `providerUserId = String(profile.id)`, `displayName = profile.name || 'Player'`,
   `email = profile.email ?? null`, `avatarUrl = profile.picture?.data?.url ?? null`.

`data.scopes`, `expires_at`, `type` are not checked. No timeout on either fetch.

### 6.4 Fake providers — `verifyFake({ provider, providerUserId, displayName })` (providers.js:130‑141) — MUST in test/dev

- `!config.allowFakeProviders` → **503** `provider_unconfigured` `<provider> login is not configured on this server`
  (this is what production returns to a `{provider:'google'}` body with no `idToken`).
- Otherwise: `providerUserId = String(providerUserId ?? displayName ?? 'fake')` — the **raw** display name,
  not the sanitised one, is the fallback identity; a number `42` becomes `"42"` **[probed]**; a body with
  neither field always maps to the single account `fake`.
- `displayName = sanitizeName(displayName) || 'Player'`; `email: null`, `avatarUrl: null`; `provider` as sent (`google`/`facebook`).

The browser stubs and the integration/metrics/socket tests depend on this branch.

### 6.5 Guest — `verifyGuest({ deviceId, displayName })` (providers.js:100‑115) — MUST

1. `trimmed = String(deviceId ?? '').trim()` — **any JSON type is stringified**: `12345678` → `"12345678"` (accepted),
   `{a:1}` → `"[object Object]"` (15 chars, accepted, one shared account for every object!) **[probed]**,
   `true` → `"true"` (too short), `null`/missing → `""`.
2. `trimmed.length < 8` (UTF‑16 code units) → **400** `invalid_device_id` `A deviceId of at least 8 characters is required`.
3. `hashed = sha256("teenpatti:" + trimmed)` as **lowercase hex** (64 chars) — this is `provider_user_id`;
   the raw device id is never stored (integration test asserts `/^[0-9a-f]{64}$/`).
4. `displayName = sanitizeName(displayName) || 'Guest' + hashed.slice(0, 5).toUpperCase()`
   (e.g. `Guest8D049`) **[probed]**. `email: null`, `avatarUrl: null`.

`sanitizeName(name)` (providers.js:117‑123):
`String(name ?? '').replace(/[\p{C}]/gu, '').trim().slice(0, 24)`; result kept iff `length >= 2`, else `''`.

- Removes every code point in Unicode category **C** (Cc control, Cf format incl. ZWSP/ZWJ/BOM, Cs surrogates, Co private use, Cn unassigned). **[probed]**: `"A<U+0000>b<U+200B>c-d!"` (a NUL and a zero-width space) → stored name `"Abc-d!"` — the NUL and the zero‑width space vanish, the hyphen and `!` survive. Ordinary spaces (`\p{Zs}`) are **not** category C and are kept.
- `trim()` then **`slice(0, 24)` in UTF‑16 code units** (may split a surrogate pair → lone surrogate in the stored name; JSON.stringify emits it as `\udXXX`). Interior whitespace is **not** collapsed (`'  Suraj  K  '` → `'Suraj  K'` **[probed]**).
- Punctuation is allowed (`'Abc-d!'` stored) — unlike `/api/profile/name`.
- One character (`'A'`) → `''` → default `Guest…` name **[probed]**; 30 chars → first 24 **[probed]**.

---

## 7. User store (db/users.js) as seen through HTTP

### 7.1 Public user shape — `publicUser(row)` (users.js:21‑60) — MUST (every `user` in every response)

Key order and types exactly:

```json
{ "id": "<uuid v4>",
  "provider": "guest"|"google"|"facebook",
  "displayName": string,
  "email": string|null,
  "avatarUrl": string|null,          // row.avatar_choice || row.avatar_url  (JS ||: '' falls through)
  "providerAvatarUrl": string|null,  // row.avatar_url
  "avatarChoice": string|null,       // row.avatar_choice ?? null
  "chips": int,
  "handsPlayed": int, "handsWon": int,
  "handsLost": int,                  // ?? 0 (column is NOT NULL, so never null in practice)
  "handsLeftMid": int,               // ?? 0
  "totalWinnings": int,              // ?? 0
  "biggestPot": int,
  "rewards": {
    "milestoneAvailable": bool,      // milestone > (milestone_claimed ?? 0)
    "milestoneAt": int,              // floor(hands_played / 25) * 25
    "milestoneReward": 25000,
    "milestoneEvery": 25,
    "handsToNextMilestone": int,     // 25 - (hands_played % 25)  → 25 (not 0) at an exact multiple
    "bonusReadyAt": int,             // next_bonus_at ?? 0 ; 0 = ready now
    "bonusAvailable": bool,          // Date.now() >= bonusReadyAt  (evaluated at serialisation time)
    "bonusReward": 10000,
    "bonusIntervalMs": 14400000 },
  "createdAt": int, "lastLoginAt": int }   // epoch ms
```

**[probed]** verbatim. Not exposed: `provider_user_id`, `updated_at`, `milestone_claimed` (only via
`milestoneAvailable`). Constants (users.js:9‑15): `MILESTONE_REWARD 25000`, `MILESTONE_EVERY 25`,
`TIMED_BONUS_REWARD 10000`, `TIMED_BONUS_INTERVAL_MS 14 400 000`. Flutter's `User.fromJson`
(dtos.dart:116‑133) reads `id, provider, displayName, chips, avatarUrl, providerAvatarUrl, avatarChoice,
handsPlayed, handsWon, handsLost, handsLeftMid, totalWinnings, biggestPot, rewards{milestoneAvailable,
milestoneReward, handsToNextMilestone, bonusReward, bonusReadyAt, bonusAvailable}`; missing ints fall to 0.

### 7.2 Login upsert — `upsertFromProfile(profile)` (users.js:87‑147) — MUST (DB rows)

One transaction (`withTransaction`), `timestamp = Date.now()` taken **before** BEGIN:

```sql
SELECT * FROM users WHERE provider = $1 AND provider_user_id = $2 FOR UPDATE
```

**Existing row:**

```sql
UPDATE users
   SET display_name  = $1,                -- profile.displayName || existing.display_name
       email         = COALESCE($2, email),   -- profile.email ?? null
       avatar_url    = COALESCE($3, avatar_url),
       updated_at    = $4,
       last_login_at = $4
 WHERE id = $5
```

then `SELECT * FROM users WHERE id = $1` → `{ user, isNew: false }`. Because every verifier yields a
non‑empty `displayName`, **every login overwrites `display_name`** — a guest who renamed via
`/api/profile/name` and logs in again without a `displayName` gets `Guest<XXXXX>` back **[probed]**
(known, unresolved vs requirement 29). `email`/`avatar_url` are only ever *set*, never cleared, by login.
`avatar_choice`, chips, counters are untouched.

**New row:**

```sql
INSERT INTO users (id, provider, provider_user_id, display_name, email, avatar_url,
                   chips, created_at, updated_at, last_login_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8, $8)
-- $1 = randomUUID() (util/ids.js:3), $7 = config.game.welcomeChips, $8 = timestamp

INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
VALUES ($1, NULL, NULL, $2, $2, 'welcome_bonus', $3)
-- $2 = welcomeChips (delta == balance), $3 = timestamp
```

then re‑select → `{ user, isNew: true }`. Invariant preserved: `SUM(chip_ledger.delta) == users.chips`
from the very first row. A `welcome_bonus` row is written even when `welcomeChips` is 0.

Race: two simultaneous first logins for the same identity both miss the `FOR UPDATE` select and both
insert; the loser hits `UNIQUE (provider, provider_user_id)` → **500 `internal_error`** on that request.
`users.provider` has `CHECK (provider IN ('google','facebook','guest'))` (schema.sql:8).

### 7.3 Lookups

- `findById(id)`: `SELECT * FROM users WHERE id = $1` → public user or `null` (users.js:67‑70).
- `findByProvider` (users.js:72‑78): unused by HTTP.

### 7.4 Milestone claim — `claimMilestoneReward(userId)` (users.js:215‑252) — MUST

Transaction: `SELECT * FROM users WHERE id = $1 FOR UPDATE`; no row → `throw Error('unknown user <id>')` → 500.
`milestone = floor(hands_played / 25) * 25`; if `milestone <= (milestone_claimed ?? 0)` →
`{ claimed: false, reason: 'not_available', user: publicUser(row) }` (no writes). Else:

```sql
UPDATE users SET chips = $1, milestone_claimed = $2, updated_at = $3 WHERE id = $4
-- $1 = chips + 25000, $2 = milestone
INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
VALUES ($1, NULL, $2, $3, $4, 'milestone_reward', $5)
-- $2 = '<userId>:milestone:<milestone>'  (UNIQUE action_id → idempotent per milestone), $3 = 25000, $4 = new balance
```

→ `{ claimed: true, amount: 25000, milestone, user: <re‑selected> }`. Claiming pays **one** milestone
(the current one) even if several were skipped; `milestone_claimed` jumps straight to the current value.

### 7.5 Timed bonus — `claimTimedBonus(userId)` (users.js:254‑297) — MUST

Transaction: lock row; `timestamp = Date.now()`; if `timestamp < (next_bonus_at ?? 0)` →
`{ claimed: false, reason: 'not_ready', readyAt: next_bonus_at, user }`. Else:

```sql
UPDATE users SET chips = $1, next_bonus_at = $2, updated_at = $3 WHERE id = $4
-- $1 = chips + 10000, $2 = timestamp + 14400000
INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
VALUES ($1, NULL, NULL, $2, $3, 'timed_bonus', $4)   -- action_id NULL (not idempotent by key; guarded by the row lock)
```

→ `{ claimed: true, amount: 10000, readyAt, user }`. A fresh account (`next_bonus_at = 0`) can claim immediately.

### 7.6 Name / avatar writes

`setDisplayName` (users.js:322‑325) and `setAvatarChoice` (users.js:328‑331): plain `UPDATE … updated_at = Date.now()`
outside a transaction, then `findById`. No ledger involvement.

---

## 8. Data model touched by the HTTP layer (schema.sql) — MUST

```sql
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL CHECK (provider IN ('google', 'facebook', 'guest')),
  provider_user_id TEXT NOT NULL,
  display_name TEXT NOT NULL,
  email TEXT, avatar_url TEXT,
  chips BIGINT NOT NULL DEFAULT 0 CHECK (chips >= 0),
  hands_played INTEGER NOT NULL DEFAULT 0, hands_won INTEGER NOT NULL DEFAULT 0,
  hands_lost INTEGER NOT NULL DEFAULT 0, hands_left_mid INTEGER NOT NULL DEFAULT 0,
  total_winnings BIGINT NOT NULL DEFAULT 0, biggest_pot BIGINT NOT NULL DEFAULT 0,
  milestone_claimed INTEGER NOT NULL DEFAULT 0,
  next_bonus_at BIGINT NOT NULL DEFAULT 0,
  avatar_choice TEXT,
  created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL, last_login_at BIGINT NOT NULL,
  UNIQUE (provider, provider_user_id));
CREATE INDEX IF NOT EXISTS idx_users_last_login ON users (last_login_at DESC);

CREATE TABLE IF NOT EXISTS chip_ledger (
  id BIGSERIAL PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  hand_id TEXT, action_id TEXT UNIQUE,
  delta BIGINT NOT NULL, balance BIGINT NOT NULL, reason TEXT NOT NULL, created_at BIGINT NOT NULL);
-- + idx_ledger_user (user_id, created_at DESC), idx_ledger_hand (hand_id), BEFORE UPDATE OR DELETE trigger raising
--   'chip_ledger is append-only (attempted %)'
```

`hands` (read by `/me/hands`): `id TEXT PK, room_id, hand_no INTEGER, pot BIGINT, winner_id TEXT REFERENCES users ON DELETE SET NULL,
win_reason TEXT, boot_amount BIGINT, started_at BIGINT, ended_at BIGINT, summary_json JSONB NOT NULL`.

Ledger `reason` values written by this layer: `welcome_bonus`, `milestone_reward`, `timed_bonus`.
`action_id` conventions: `NULL` for welcome/bonus; `<userId>:milestone:<n>` for milestones
(gameplay uses client uuids, `<handId>:boot:<userId>`, `<handId>:settle:<userId>`).

---

## 9. Client expectations summary (what the port must satisfy)

| Client | Calls | Reads |
|---|---|---|
| Flutter `ApiClient` | `POST /api/auth/login` (guest), `GET /api/auth/me`, `GET /api/profiles`, `POST /api/profile/avatar {avatar}`, `POST /api/profile/name {name}`, `POST /api/rewards/{milestone|bonus}` body `{}` | `token`, `user`, `isNew`, `welcomeChips`; `user`; `profiles[].id/url`; `user`; `user`; `user`, `awarded` (never present), `message`. Errors: top‑level `message` |
| Browser `client.js` | login (guest / fake google / fake facebook), `GET /api/auth/me`, `GET /api/profiles`, `POST /api/profile/avatar`, `POST /api/rewards/*` (no body, no content‑type) | `token`, `user`, `isNew`, `welcomeChips.toLocaleString()`; `user.avatarUrl`, `user.chips`; `amount`; error `message`/`error` |
| bots / loadtest / ramptest / kicktest / peek | `POST /api/auth/login` guest, `GET /health` | `token`, `user.id`, `user.displayName`; `ok`, `players`, `tables`, `process.*` |
| Prometheus | `GET /metrics` with optional bearer | text exposition |

Headers clients send: `Content-Type: application/json` and `Authorization: Bearer <token>` (Flutter always
sends `Content-Type` even on GET; browser reward POSTs send **no** body and **no** content‑type → `req.body = {}`).

---

## 10. Test cases to mirror

All process‑level suites set env **before** importing the server: `NODE_ENV=test`,
`PG_SCHEMA=test_<suite>_<rand>`, `JWT_SECRET=<suite>-test-secret`, `AUTH_ALLOW_FAKE_PROVIDERS=true`,
`WELCOME_CHIPS=200000`, `BOOT_AMOUNT=100`, `PORT=0`, `TABLE_STAKES=''`, `LOBBY_TABLES=''`, short timers;
`createServer()` then `server.listen(0, '127.0.0.1')`; teardown `rooms.shutdown()` → `io.close()` →
`server.closeAllConnections()` → `server.close()` → `dropSchema()` → `closeDatabase()`.

### 10.1 `test/integration.test.js` (REST‑relevant cases)

| Test name | Setup | Asserts |
|---|---|---|
| `guest login creates an account with the welcome chip grant` | `POST /api/auth/login {provider:'guest', deviceId:'device-guest-0001', displayName:'Suraj'}` | `token` truthy; `isNew === true`; `welcomeChips === 200000`; `user.chips === 200000`; `user.provider === 'guest'`; `user.displayName === 'Suraj'` |
| `logging in again from the same device returns the same saved account` | two logins, same device id `device-again-0002` | second: `isNew === false`, `welcomeChips === 0`, same `user.id`, same `user.chips` |
| `a different device is a different account` | `device-alpha-0003` vs `device-beta-0004` | different `user.id` |
| `the raw device id is never stored` | `SELECT provider_user_id FROM users WHERE provider='guest'` | ≥1 row; none equals `device-guest-0001`; all match `/^[0-9a-f]{64}$/` |
| `a short or missing device id is rejected` | `{provider:'guest', deviceId:'abc'}`; `{provider:'guest'}` | 400 + `error === 'invalid_device_id'`; 400 |
| `an unknown provider is rejected` | `{provider:'myspace', deviceId:'device-xxxx-9999'}` | 400, `error === 'unknown_provider'` |
| `google and facebook logins create provider-scoped accounts` | fake `{provider:'google', providerUserId:'google-sub-123', displayName:'G Player'}`, `{provider:'facebook', providerUserId:'fb-123', displayName:'F Player'}`, google again | both 200; providers echoed; google `chips === 200000`; ids differ; re‑login returns the same google id |
| `/api/auth/me returns the persisted profile` | guest login, `GET /api/auth/me` with `authorization: Bearer <token>` | 200; `user.id` matches; `user.chips === 200000` |
| `a bad session token is refused` | `GET /api/auth/me` with `Bearer nonsense` | 401 |
| `a socket without a valid token cannot connect` | socket.io‑client with `auth.token='garbage'` | `connect_error.message` matches `/invalid_session|unauthorized/` |
| `a full hand plays out…` (tail) | after a settled hand, `GET /api/auth/me` for winner and for the show‑payer | winner `user.chips > 200000`, `handsWon === 1`; payer `handsPlayed === 1` |
| `health reports live table and player counts` | `GET /health` | `ok === true`; `typeof tables === 'number'`; `typeof players === 'number'` |

### 10.2 `test/metrics.test.js` (HTTP‑relevant cases; `METRICS_TOKEN=metrics-test-token`)

| Test name | Asserts |
|---|---|
| `/metrics requires the bearer token and serves the text exposition` | no header → 401; `Bearer not-the-token` → 401; correct → 200, `content-type` starts with `text/plain`, body matches `/^# HELP /m` and `/^# TYPE game_connected_sockets gauge$/m` |
| `http: requests are counted by route pattern, never by raw path` | after login, `GET /api/auth/me` (200), `GET /health` (200), `GET /api/auth/me/hands?limit=3` (200), `GET /nothing-here-123` (404): series `game_http_requests_total{method="POST",route="/api/auth/login",status_code="200"}`, `{GET,/api/auth/me,200}`, `{GET,/health,200}`, `{GET,/api/auth/me/hands,200}`, `{GET,unmatched,404}` ≥ 1; `game_http_request_duration_seconds_bucket{route="/health",le="+Inf"}` ≥ 1; no route label contains `/nothing-here-123`, `?`, `limit=`, or `/<digits>`; no `route="/metrics"` series |
| `cardinality: …` | no label value is a UUID, IPv4/IPv6, or 64‑hex; `method` labels match `/^[A-Z]+$/` |

### 10.3 `test/statsAndRewards.test.js` (store‑level, no HTTP; drives §7.4/7.5/7.1)

| Test name | Setup | Asserts |
|---|---|---|
| `the milestone reward unlocks every 25 played hands` | new guest via `upsertFromProfile`; `UPDATE users SET hands_played = 24 / 25` | at 0: `milestoneAvailable false`, `handsToNextMilestone 25`; at 24: false, 1; at 25: true, `milestoneAt 25`, `milestoneReward 25000` |
| `collecting the milestone reward grants 25,000 chips exactly once` | hands_played 50 | first claim: `claimed true`, `amount 25000`, `milestone 50`, `user.chips === before + 25000`, `milestoneAvailable false`; second: `claimed false`, `reason 'not_available'`, chips unchanged |
| `reaching the next milestone unlocks the reward again` | 25 → claim → 49 → 50 | available false at 49, true at 50, claim succeeds |
| `the milestone reward is written to the chip ledger` | claim at 25 | a `chip_ledger` row with `reason='milestone_reward'`, `delta === 25000` |
| `a new account can collect the timed bonus straight away` | fresh | `bonusAvailable true`, `bonusReward 10000`, `bonusIntervalMs 14400000` |
| `collecting the bonus grants 10,000 chips and starts a 4-hour countdown` | claim | `claimed true`, `amount 10000`, `user.chips === before + 10000`, `readyAt` within ±1 s of now+4 h, `bonusAvailable false` |
| `the bonus cannot be collected twice inside the countdown` | claim twice | second `claimed false`, `reason 'not_ready'`, `readyAt > now`, chips unchanged |
| `the countdown lives in the database, so it survives a restart` | claim; read `next_bonus_at`; set it to `now-1` | column equals `readyAt`; then `bonusAvailable true` and claim succeeds |
| `a provider picture is kept and used by default` | google profile with `avatarUrl` | `avatarUrl` and `providerAvatarUrl` equal it; `avatarChoice null` |
| `a chosen picture overrides the provider one, and clearing restores it` | facebook profile; `setAvatarChoice(id,'/profiles/ace.svg')`; then `null` | `avatarUrl '/profiles/ace.svg'`, `providerAvatarUrl` kept; cleared → `avatarUrl` back to provider |
| statistics tests (`a hand only counts as played once…`, `wins, losses and abandoned…`, `total winnings…`) | `settleHand` fixtures | counters on `findById` — they belong to the ledger spec but read through `publicUser` |

### 10.4 Other suites touching REST

`socketProtocol.test.js:58`, `invalidMoves.test.js:58`: guest login helper only (`token`, `user`).
`stakes.test.js` runs with the **default** `TABLE_STAKES`/`LOBBY_TABLES` (it deletes those env vars) —
so a port's `/api/rooms` `options` under defaults must equal the JSON in §4.9.

### 10.5 Probed behaviours worth turning into Go tests (not currently in the Node suite)

- `POST /api/auth/login` with body `{bad`, `"x"`, `null`, `[]`, 40 kB, `charset=utf-16` → 500/500/500/**400 unknown_provider**/500/500.
- `GET /API/Auth/me/` with `bearer  <t> ` → 200. `Authorization: Bearer` → 401 `missing_token`.
- `Bearer a.b` → `jwt malformed`; expired → `jwt expired`; wrong secret → `invalid signature`; `alg:none` → `jwt signature is required`; unknown `sub` → `unknown_user`; HS384 with the right secret → **200**.
- Guest: `deviceId: 12345678` (number) → 200; second login without `displayName` renames the account to `Guest<5 hex upper>`.
- `/api/profile/name` with `123` → 200 `"123"`; `'a-b'` → `invalid_name`; 25 × `a` → `name_too_long`; `'   '` → `empty_name`.
- `/api/profile/avatar` with `''` → 400 `unknown_avatar`; `'bear.svg'` → `avatarChoice '/profiles/bear.svg'`.
- `GET /profiles` → 301 `/profiles/`; `GET /profiles/` → 404; `POST /index.html` → 404 HTML.
- `GET /api/rooms` twice with `If-None-Match` → 304 empty body.

---

## 11. Traps for the port

1. **Body‑parser failures are 500, not 400/413/415.** The custom error handler ignores `error.status`. A
   Go port that returns 400 for malformed JSON is *more correct* but *different*; decide explicitly (see open questions).
2. **`req.body` is `{}` for a missing or non‑JSON body**, never nil. Reward POSTs from the browser carry no
   body and no content‑type and must succeed.
3. **Every login overwrites `display_name`** (`profile.displayName || existing.display_name`, and the
   profile name is never empty). Guests who renamed lose the rename on the next app start unless the client resends the name. Reproduce; do not "fix" silently.
4. **`sanitizeName` ≠ `normalizeDisplayName`.** Login: strip `\p{C}`, trim, `slice(0,24)`, min length 2, punctuation OK, interior spaces preserved.
   Rename: collapse all Unicode whitespace to one space, max 24, regex `^[\p{L}\p{N}][\p{L}\p{N}\p{M} ]*$`. Both measure **UTF‑16 code units**, not runes or graphemes — Go `len()` (bytes) and `utf8.RuneCountInString` both differ. Use `len(utf16.Encode([]rune(s)))`.
5. **`\p{M}` in the rename pattern** is what lets Devanagari/Bengali/Gujarati/Gurmukhi names through; Go's RE2 supports `\p{M}`, `\p{L}`, `\p{N}` but be sure the first‑char class excludes `\p{M}` and that the space is an ASCII space only (whitespace was already collapsed to ASCII).
6. **JS `\s`** (used to collapse whitespace in `normalizeDisplayName`) is Unicode `White_Space` **plus U+FEFF (BOM)**: `\t \n \v \f \r`, U+0020, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF. Go's RE2 `\s` is ASCII-only and `unicode.IsSpace` excludes U+FEFF; build the class explicitly. U+200B (ZWSP) is **not** `\s` in JS (it is `\p{Cf}`), so on a rename it survives the collapse and then fails the regex (`invalid_name`), whereas at login `sanitizeName` strips it.
7. **`deviceId` stringification**: `String(x)` of a number/boolean/object/array. An object is `[object Object]` (15 chars) — one shared account. Arrays join with commas. Mirror `String()` or document the divergence.
8. **sha256 input is `"teenpatti:" + trimmed`**, hex lowercase; the default guest name uses the **first 5 hex chars upper‑cased**, prefixed `Guest`.
9. **JWT**: HS256 issue; verify accepts HS256/HS384/HS512; `exp` optional; no clock tolerance; `iat` not checked;
   payload key order `sub, provider, name, iat, exp`; header `{"alg":"HS256","typ":"JWT"}` byte‑exact if tokens are ever compared. The `Session token rejected: <msg>` suffixes are jsonwebtoken's strings (`jwt malformed`, `jwt expired`, `invalid signature`, `jwt signature is required`, `invalid token`, `invalid algorithm`, `jwt not active`).
10. **`expiresIn` is a string parsed by `ms`**: `"30d"` = 30 days; a bare number string is **milliseconds**. `ms` accepts `ms|s|m|h|d|w|y` with long forms and decimals (`"1.5h"`), case‑insensitive, optional space.
11. **Bearer extraction**: case‑insensitive `bearer ` prefix, then `trim()` — tolerate extra spaces around the token.
12. **Auth runs first**: `unknown_user`/`invalid_session` beat `seated`/validation errors on every protected route.
13. **`avatarUrl = avatar_choice || avatar_url`** uses JS `||` (empty string falls through) while `avatarChoice = avatar_choice ?? null`. The stored choice is the URL `/profiles/<id>`; the request carries the bare `<id>`; validation is `===` against the live directory listing (case‑sensitive, re‑read per request).
14. **`handsToNextMilestone` is 25 at an exact multiple** (never 0); `milestoneAt` is the floor multiple; `milestoneAvailable` compares against `milestone_claimed`. Claiming pays one milestone and jumps `milestone_claimed` to the current multiple.
15. **`bonusAvailable` is computed at serialisation time** (`Date.now() >= next_bonus_at`) — two `user` objects in one response window can differ by a millisecond; `bonusReadyAt` is `0` (not null) for a fresh account.
16. **Timestamps are epoch ms integers** everywhere (`created_at`, `lastLoginAt`, `readyAt`, `endedAt`) — the `upsert` takes `Date.now()` **before** `BEGIN` and uses the same value for `created_at`, `updated_at`, `last_login_at`.
17. **BIGINT/NUMERIC → number**: without the pg type parsers `chips` would serialise as `"200000"`. In Go, scan into int64 and emit JSON numbers. Nothing here exceeds 2^53.
18. **Milestone ledger row has an idempotency key** `<userId>:milestone:<n>`; welcome and bonus rows have `action_id NULL`. `UNIQUE` on `action_id` tolerates many NULLs.
19. **Race on first login**: `SELECT … FOR UPDATE` on a non‑existent row locks nothing; the duplicate insert fails with a unique violation → 500. Acceptable (client retries) but note it.
20. **`/me/hands` limit**: `parseInt || 20` turns `0` into 20; negative values slice from the end; the whole history is fetched then sorted/sliced in memory (the SQL `ORDER BY h.id` is only for `DISTINCT ON`).
21. **`/api/rooms` and the 404**: unknown `/api/*` paths return **HTML**, not JSON; `GET /api/auth/login` is a 404, not 405.
22. **Static serving must expose `/profiles/*.svg`** with `image/svg+xml`, and `/` must serve `index.html`; directory URLs redirect 301 when the slash is missing. Dotfiles are hidden.
23. **`/health` `cpuPercent` and loop‑lag are deltas since the previous `/health` call** and the histogram is reset after each response; `sockets` is `null` (not 0) if the engine is missing; `db` is `null` before the pool exists. `node` is the literal Node version string — a Go port must decide what to put there (ramptest only prints it).
24. **Metrics middleware excludes `/metrics` and labels by route pattern**; body‑parser errors count as `unmatched`/500; static hits as `static`. Label values must never contain ids, paths with ids, or query strings (enforced by `test/metrics.test.js`).
25. **Production guard throws at config load** — a Go port should refuse to start under the same two conditions with the same messages.
26. **Shutdown order** (io.close → rooms.shutdown (settles live hands) → server.close → db close → exit 0; hard exit 1 after 8 s) matters for the ledger invariant: pots must be paid before the pool closes.
27. **Weak ETag + 304** on JSON responses is Express default behaviour; harmless to drop, but `Content-Type: application/json; charset=utf-8` (with the charset) should be kept — Flutter's `http` decodes by charset.
28. **Facebook `debug_token` uses `app_id|app_secret` as the app access token** and compares `String(data.app_id)` to the configured id; the profile call interpolates `user_id` unencoded and requests `picture.type(large)`. No `appsecret_proof`, no timeouts.
29. **Google audience is a list membership test** on the single `aud` string; issuers include the bare `googleapis.com`; `email_verified` is ignored; the display name falls back `name → given_name → 'Player'`.
30. **Fake providers**: only when the real credential is absent; `providerUserId` falls back to the *raw* `displayName`, then `'fake'`; everything stored as `String(...)`.

---

## 12. Open questions the port must decide

1. Keep body‑parser failures as **500 `internal_error`** (byte‑exact parity) or return 400/413/415 with the same JSON envelope? No client depends on the 500.
2. Keep the negative‑`limit` slicing quirk on `/api/auth/me/hands`, or clamp to `[1, 100]`? No caller exists.
3. `/health.process.node`: emit the Go runtime version string, a fixed `"go"`, or omit? `ramptest.mjs` only echoes it.
4. Accept HS384/HS512 tokens signed with the same secret (Node does) or pin to HS256? Pinning breaks nothing (the server only ever issues HS256).
5. `deviceId` non‑string coercion (`[object Object]`, `12345678`): mirror JS `String()` or reject non‑strings with `invalid_device_id`? The clients always send strings.
6. Should a rename survive the next login (requirement 29)? Node clobbers it; CLAUDE.md lists this as known/unresolved.
7. The fake‑provider `providerUserId` fallback uses the raw (unsanitised) `displayName` — keep, or use the sanitised one?
