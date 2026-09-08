# PORT_NOTES — internal/auth and internal/config

Owner scope: `internal/auth/` (errors.go, handlers.go, http.go, providers.go, text.go, tokens.go
+ tests) and `internal/config/` (config.go, parse.go + tests). Ported from
`server/src/auth/{routes,providers,tokens}.js`, the error middleware and `express.json` setup in
`server/src/index.js`, and `server/src/config/index.js` / `server/.env.example`.

Verified against: Node 22, express 4.22.2 (body-parser 1.20.6), jsonwebtoken 9.0.3,
google-auth-library 9.15.1 (read, not run). Go 1.27.1, golang-jwt/jwt v5.3.1. No new module
dependencies.

## The failing test (TestLoginRefusals, http_test.go:342) — root cause and fix

Input: `{"provider":"guest"}` sent as `Content-Type: application/json; charset=utf-16`. The test
expected `400 invalid_json`; the handler answered `400 invalid_device_id`.

`ReadJSONBody` let any `utf-*` charset through (body-parser's own prefix check) and then decoded
the bytes as UTF-8, so a well-formed object came out and the guest path refused the missing
deviceId. Node does something different: body-parser passes the charset to iconv-lite, decodes the
UTF-8 bytes *as UTF-16* (`≻牰癯摩牥…`) and `JSON.parse` fails — confirmed by running
`express.json()` on Node 22. So for that input "malformed body" is the right answer and the Go side
was wrong.

Fix (handlers.go `ReadJSONBody`): the Go server only ever decodes UTF-8, so a `charset` parameter
other than `utf-8` (case-insensitive) is refused with `400 invalid_json "unsupported charset
\"UTF-16\""`. body-parser 415'd everything outside `utf-*` and transcoded utf-16/utf-32; both now
land on `invalid_json`. No client sends a non-UTF-8 JSON body (deviation, see table).

## Other bugs fixed

| Where | Was | Now | Why |
|---|---|---|---|
| `ReadJSONBody` check order | Content-Length checked before the media type | type → charset → length → read, as body-parser | a `text/plain` body over 32 kB was 413; body-parser skips non-JSON bodies whatever their size (`req.body = {}`) |
| `ReadJSONBody` empty body | any whitespace-only body → `{}` | only a **zero-length** body → `{}`; `"  \n"` → `400 invalid_json` | body-parser special-cases `body.length === 0` only; strict mode then finds no `{`/`[` |
| `ReadJSONBody` strict mode | skipped Go `TrimSpace` (incl. `\v`, `\f`, NBSP) | skips JSON whitespace only (`\x20 \t \n \r`) | body-parser's `firstchar()`; `"\v{}"` is a strict violation in Node |
| `Verifier` default HTTP client | `http.DefaultClient` (no timeout) | per-call `http.Client{Timeout: ProviderTimeout (15 s)}` over the shared DefaultTransport | a hung Google/Facebook endpoint pinned the login goroutine; no package-level state (PORT_PLAN §7) |
| `config.Load()` PUBLIC_DIR default | `./public` only when `../server/public` is missing **and** `./public` exists; otherwise the missing default stayed | `../server/public` when it is an existing directory, else `./public` | the rule in PORT_PLAN §9 / DECISIONS §5; deterministic, and the app's "directory not found" warning now names the path actually tried |

## What is ported

### internal/config
| Node | Go |
|---|---|
| `config` object, every key | `Config` (`Env, Port, Host, CORSOrigin/AllowAnyOrigin, JWT, Google, Facebook, AllowFakeProviders, DB, Game, Metrics, Chat, LogLevel, PublicDir, RedisURL`); `Defaults()` is byte-identical to `.env.example` and CLAUDE.md §7.4 (`TestDefaultsMatchNode`, `TestEnvExampleIsTheDefaults` parses the real `.env.example` and requires the defaults back, and requires the key sets to match both ways) |
| `num()` | `reader.int64/integer/millis`: unset or `""` → default; else strict decimal integer (sign and surrounding spaces allowed) or startup error `KEY="raw": expected a decimal integer` |
| `bool()` | `reader.boolean`: unset/`""` → default; true iff lower-case ∈ {1,true,yes,on} |
| `list()` | `list`: split `,`, trim, drop empties |
| `process.env.X ?? default` | `reader.str`: a set-but-empty string is honoured (`JWT_SECRET=` → `""`) |
| `TABLE_STAKES` | `parseTableStakes`: `TABLE_STAKES=` → `[]int64{}` (unrestricted, never nil); entries ≤ 0 dropped as Node's filter did; a non-integer entry fails startup |
| `LOBBY_TABLES` | `parseLobbyTables`: `LOBBY_TABLES=` → `[]LobbyTable{}`; each entry `category:boot`, trimmed; category must be `seen`/`blind`; boot must be an integer (0 or negative passes, as `Number.isInteger` did) |
| `METRICS_ENABLED` | true unless the value is exactly `"false"` (`FALSE`, `0`, `""` all keep it on) |
| `CORS_ORIGIN` | unset / `""` / `*` → `AllowAnyOrigin`; else the list |
| `JWT_EXPIRES_IN` | `ParseDuration` — vercel/ms 2.1.3 grammar as jsonwebtoken applies it to a string: bare number = **milliseconds**, units `ms s m h d w y` (long forms, plurals, spaces, decimals, case-insensitive, ≤ 100 chars); year = 365.25 d |
| `*_MS` | `time.Duration`; use `.Milliseconds()` on the wire |
| production guards | `Validate()`: `JWT_SECRET must be set in production`, `AUTH_ALLOW_FAKE_PROVIDERS must be false in production` (Node's exact messages); an empty `JWT_SECRET` passes the guard as in Node |
| `PG_SCHEMA` regex (db/index.js) | `Validate()` also refuses a non-identifier schema at load |
| `_createTable` rule composition | `GameConfig.TableRules(category, boot, isPrivate)` → `{BootAmount, MaxRaiseSteps, MaxBetRounds, PotLimitMultiplier, MaxPot}`: public seen 2/7/1024/1.2M, public blind 0/0/0/0 (`maxPot ?? 0`), private 200 boot + `PrivateMaxPot`/`PrivateMaxRaiseSteps` over either category; seen keeps the **generic** `PotLimitMultiplier` |
| `lobbyOptions().tables[].maxPot` | `GameConfig.MenuMaxPot(category)`: `SeenMaxPot` for seen, 0 otherwise |
| `normalizeCategory` | `config.NormalizeCategory` (blind iff exactly `"blind"`) — `game.NormalizeCategory` is the one the socket layer uses; both agree |
| `publicGameConfig` values | `TestPublicGameConfigValues` pins every scalar the socket layer copies, including `maxBetRounds` = the **global 20** |
| `REDIS_URL` | read into `RedisURL`; `internal/app` logs it as ignored |
| `PUBLIC_DIR` (new) | see fix table |

### internal/auth
| Node | Go |
|---|---|
| `AuthError(code, message, status=401)` | `AuthError{Code, Message, Status}`, `NewAuthError` (0 → 401), `Is` on Code |
| `issueToken` | `Tokens.Issue`: HS256, header exactly `{"alg":"HS256","typ":"JWT"}`, claims **only** `sub, provider, name, iat, exp`; `iat = floor(now)`, `exp = floor(iat + expiresIn)` as jsonwebtoken's `timespan()` |
| `verifyToken` | `Tokens.Verify`: `""` → `missing_token` "A session token is required"; else `invalid_session` "Session token rejected: …" with jsonwebtoken's wording where one exists (`jwt malformed`, `jwt expired`, `invalid signature`, `jwt not active`, `invalid algorithm`); `exp` optional, `nbf` honoured, no leeway, HS256 only |
| `tokenFromRequest` | `TokenFromRequest`: `Authorization: Bearer <t>`, scheme case-insensitive, needs the space, trimmed |
| `requireAuth` | `Handler.RequireAuth`: Verify → `Users.FindByID(sub)` → nil → `unknown_user` "This account no longer exists"; store error → 500; user in the context (`UserFrom`) |
| `verifyLogin` | `Verifier.VerifyLogin`: google/facebook take the fake path only when `AllowFakeProviders` **and** the credential is absent; guest; else `unknown_provider` 400 `Unsupported login provider "<p>"` (`"undefined"` when the key is absent/null, as Node stringified it) |
| `verifyGoogle` | `Verifier.VerifyGoogle`: `missing_token` / `provider_unconfigured` 503 / RS256 against Google's JWKS `https://www.googleapis.com/oauth2/v3/certs` (cached for `Cache-Control: max-age`, refetched otherwise), `kid` must match, `iat`+`exp` required, 300 s skew, `exp` < now + 1 day, `iss ∈ {accounts.google.com, https://accounts.google.com}`, `aud ∈ GOOGLE_CLIENT_IDS`; failures → `invalid_token` "Google token rejected: <google-auth-library wording>"; no `sub` → "Google token had no subject"; profile `name || given_name || "Player"`, `email`, `picture` (not sanitised, as Node) |
| `verifyFacebook` | `Verifier.VerifyFacebook`: `debug_token?input_token=&access_token=<appId>|<appSecret>` (no `appsecret_proof` — Node sent none) → `is_valid`, `app_id` compared as text → `GET /v20.0/<user_id>?fields=id,name,email,picture.type(large)&access_token=`; the four `invalid_token` messages verbatim; a 2xx non-JSON body is a plain error → 500 as Node's SyntaxError |
| `verifyGuest` | `VerifyGuest`: JS `trim()`, UTF-16 length ≥ 8 else `invalid_device_id` 400; id = lower-hex `sha256("teenpatti:" + trimmed)`; name = `SanitizeName(displayName) || "Guest" + upper(hash[:5])` |
| `sanitizeName` | `SanitizeName`: strip `\p{C}` (Cc Cf Co Cs **and unassigned**), JS trim, `slice(0,24)` in UTF-16 units never splitting a pair, `≥ 2` units else `""`; interior spaces and punctuation kept (unlike `db.NormalizeDisplayName`) |
| `verifyFake` | `verifyFake`: 503 unless enabled; `providerUserId = providerUserId ?? RAW displayName ?? "fake"`; name sanitised or `"Player"` |
| routes | `Handler.Register(mux)`: `POST /api/auth/login`, `GET /api/auth/me`, `GET /api/auth/me/hands`, `POST /api/rewards/milestone|bonus`, `GET /api/profiles`, `POST /api/profile/avatar|name`; HEAD served for GETs; wrong method → the JSON 404 (Express fell through to its 404, never 405); `NotFoundHandler()` for `/api/` |
| login response | `{token, user, isNew, welcomeChips}` (`WelcomeChips` when `isNew` else 0); logs `account created` / `login {userId, provider}` |
| `/me/hands?limit` | `parseInt`-style read of the first value (`"3abc"` → 3, `"1e3"` → 1, `"abc"`/`"0"` → 20), clamped to [1, 100]; `[]` never null |
| rewards | 200 = the `db.RewardResult` as-is (`{claimed, amount, milestone, user}` / `{claimed, amount, readyAt, user}`); 409 `{error:"reward_not_available", message, user}` / `{error:"reward_not_ready", message, readyAt, user}` with Node's messages; logs `milestone reward claimed {userId, milestone}` / `timed bonus claimed {userId}` |
| `/profiles` | live `ReadDir` of `Deps.ProfilesDir`, `(?i)\.(svg|png|jpg|jpeg|webp)$`, JS default sort (UTF-16 code units, upper case first; dotfiles listed as `readdirSync` listed them), `[]` when unreadable |
| `/profile/avatar` | seated → 409 "You cannot change your picture while you are at a table."; `avatar` absent/null clears; a non-string value is its literal text and so `unknown_avatar` like `entry.id === 0` was; must `===` a listed id else 400 `unknown_avatar` "That picture is not available."; stored `/profiles/<name>` |
| `/profile/name` | seated → 409 "You can only change your name in the lobby."; `db.NormalizeDisplayName(name, DisplayNameMaxLength)` → 400 `empty_name` / `name_too_long` ("Keep it to N characters or fewer.") / `invalid_name` with Node's messages |
| error middleware (index.js) | `WriteError`: `*AuthError` → its status; `*game.GameError` → 400; else log `request failed {path, error}` and 500 `{error:"internal_error", message:"Something went wrong"}`; `WriteJSON` = compact `JSON.stringify`, no HTML escaping, `application/json; charset=utf-8`, Content-Length set |
| body coercions (DECISIONS §4) | `coerceText`/`jsString`: numbers → decimal text, objects/arrays/booleans/null → `""`; guest `deviceId` additionally must be a JSON string |

## Test summary

`go build ./... && go vet ./internal/auth/... ./internal/config/... && go test -race ./internal/auth/... ./internal/config/...` — green; `gofmt -l` empty. 45 top-level tests (32 auth, 13 config), no Postgres needed.

**config (13):** `TestDefaultsMatchNode` (every field vs Node + empty env == Defaults), `TestEveryKey` (table-driven: one row per env key, 70 rows incl. the empty-string and `METRICS_ENABLED` variants), `TestEmptyIntegerKeepsDefault`, `TestMalformedIntegersFailStartup` (16 bad values incl. `LOBBY_TABLES=foo:200`, `JWT_EXPIRES_IN=0/-5d/soon`; error names the key), `TestCORSOrigin`, `TestProductionGuards`, `TestSchemaMustBePlainIdentifier`, `TestParseDuration` (18 good / 10 bad), `TestTableRules` (the four table kinds + overrides + `NormalizeCategory` + `MenuMaxPot`), `TestPublicGameConfigValues`, `TestEnvExampleIsTheDefaults` (reads `server/.env.example`), `TestLoadReadsTheProcessEnvironment`, `TestLoadPublicDirDefault` (new: `t.Chdir` into a scratch tree; sibling present / absent / a file at the path / explicit `PUBLIC_DIR` wins).

**auth (32):**
- Tokens: `TestIssueProducesNodeShapedToken` (header bytes, exactly 5 claims, values), `TestVerifyRefusals` (empty, garbage, 2 segments, wrong secret, expired, HS384, `alg:none`, `nbf`, no-`exp` accepted, exactly-at-`exp` refused, `errors.Is` by code), `TestTokenFromRequest`, **`TestNodeIssuedTokenVerifiesInGo` and `TestGoIssuedTokenVerifiesInNode`** — run `node -e` with `NODE_PATH=server/node_modules` (jsonwebtoken 9.0.3); they `t.Skip` when `node` or the modules are missing (they ran here).
- Providers: `TestVerifyGuest`, **`TestGuestHashMatchesNode`** (Node's `createHash('sha256')` over 4 device ids incl. padded and non-ASCII), `TestSanitizeName` (16 cases: NUL/ZWSP/BOM/ZWJ/NEL/NBSP, marks, 24-unit cut, surrogate pairs), **`TestSanitizeNameMatchesNode`** (12 inputs through the exact Node expression), `TestVerifyLoginDispatch`, `TestFakeProviders` (incl. the raw-displayName fallback), `TestLoginRequestDecoding`, **`TestVerifyGoogle`** (httptest JWKS with a locally generated RSA-2048 key: valid, name/given_name/Player fallbacks, bare issuer, aud array, skew, 10 refusals incl. unknown kid / HS256 / no aud / exp too far / used too early, tampered signature, segment count, no sub), `TestGoogleCertsCache` (1 fetch within max-age, refetch after, per-call without the header, endpoint down), `TestCacheMaxAge`, `TestVerifyFacebook` (exact request URIs incl. escaping, numeric ids, the four refusals in order, non-JSON 2xx → plain error, unconfigured halves).
- Routes (fake `UserStore`, real mux + `NotFoundHandler`): `TestGuestLoginCreatesAnAccountWithTheWelcomeGrant` (key set, log line, token names the account), `TestLoggingInAgainReturnsTheSameAccount`, `TestTheRawDeviceIDIsNeverStored`, `TestLoginRefusals` (device id too short / absent / number, unknown provider, `"undefined"`, malformed/`"x"`/`null`/trailing/`[]`, 413, utf-16, ignored content types, empty body, 500 + log), `TestGoogleAndFacebookFakeLoginsCreateProviderScopedAccounts`, `TestMeReturnsThePersistedProfile` (fresh per call, lower-case bearer, HEAD), `TestBadSessionTokensAreRefused` (each 401 code + message, auth before seated, store failure → 500), `TestHandsLimit` (12 query forms, `[]` never null), `TestMilestoneReward`, `TestTimedBonus` (200/409 shapes and key counts, absent `reason`), `TestProfilesListsTheBundledPictures` (exact JSON, unreadable dir, the real 15 animals), `TestAvatarChoice` (8 refused values, null/absent clear, seated first, bad JSON, no token), `TestDisplayNameChange` (Hindi with marks, numbers as text, 9 refusals, seated, custom max), `TestUnknownAPIPathsAndMethodsAre404JSON`, `TestWriteErrorAndWriteJSON`, `TestRequireAuthStoresTheUserInTheContext`, **`TestReadJSONBodyMirrorsBodyParser`** (new: parsed / ignored / 400 / charsets / 413 by Content-Length and by stream / exactly 32 KiB ok).

## Deviations from Node (all deliberate; the ones without a DECISIONS reference are new here)

| Behaviour | Node | Go | Source |
|---|---|---|---|
| JWT algorithms accepted on verify | HS256/HS384/HS512 | HS256 only | DECISIONS §5 |
| `JWT_EXPIRES_IN` malformed / `0` / negative | `jwt.sign` threw per login (500); `0` and negatives minted already-expired tokens | startup error | DECISIONS §5 (strict env parsing), ParseDuration doc |
| Body parse failure | 500 `internal_error` (parser error fell through the middleware) | 400 `invalid_json`; > 32 kB → 413 same envelope | DECISIONS §5 |
| Non-UTF-8 `charset` on a JSON body | 415 for non-`utf-*`; utf-16/utf-32 transcoded via iconv-lite | all → 400 `invalid_json "unsupported charset …"` | this note (fix #1); no client sends one |
| Refusal order on authenticated routes | body parsed first, app-wide (a malformed body beat a bad token) | auth 401 → seated 409 → body 400/413 → validation | this note; keeps parser behaviour from anonymous callers; not on any success path |
| Unknown `/api/*` path or method | Express HTML 404 | JSON 404 `{error:"not_found", message:"Cannot GET /path"}` | DECISIONS §5 |
| `OPTIONS` on an API route | Express auto-answered `200 Allow: GET,HEAD` | JSON 404 | this note; the browser client is same-origin (no preflight), Flutter never preflights |
| `?limit` | `Math.min(parseInt||20, 100)` — negatives reached SQL | clamped to [1, 100] | DECISIONS §5 |
| Guest `deviceId` non-string | coerced (`String(12345678)` was a valid id) | 400 `invalid_device_id` | DECISIONS §5 |
| Booleans in `displayName`/`name` | `String(true)` = `"true"` (a valid name) | `""` → `empty_name` | DECISIONS §4 |
| Name/chat truncation | could split a surrogate pair | drops the lone high half | DECISIONS §4 |
| Google certificate source | PEM map at `/oauth2/v1/certs` | JWK set at `/oauth2/v3/certs` (same keys, same kids) | PORT_PLAN §9 (JWKS by hand) |
| Google `aud` as an array | library `indexOf(array)` → rejected | accepted iff any member ∈ `GOOGLE_CLIENT_IDS` | this note; Google never issues array audiences; not weaker |
| Google issuer `googleapis.com` (library's universe domain) | accepted | refused | this note; never issued on ID tokens |
| Provider HTTP timeout | none | 15 s (`auth.ProviderTimeout`) unless `Verifier.HTTP` is injected | this note |
| `LOBBY_TABLES` unknown category | kept as an unjoinable menu entry | startup error | DECISIONS §3 |
| Malformed integer env values | `parseInt` prefix or silent default | startup error naming the key | DECISIONS §5 |
| `PG_SCHEMA` validation | at `openDatabase` | at config load (same message) | this note |
| `PUBLIC_DIR` | did not exist (`rootDir` from the module path) | new key; default `../server/public` if present else `./public` | DECISIONS §5, PORT_PLAN §9 |
| Session-token rejection reasons | jsonwebtoken's messages | mapped to the same five phrases; other golang-jwt texts pass through | this note (message parity for logs/clients) |

## Requests for other packages

- **internal/app** — nothing to change: `mux.HandleFunc("GET /api/rooms", …)` together with `mux.Handle("/api/", auth.NotFoundHandler())` already sends `POST`/`OPTIONS /api/rooms` to the JSON 404 (verified on Go 1.27: the `/api/` pattern wins over the mux's 405 because it matches the request), and HEAD is served. Keep the `/api/` catch-all registered — without it those methods would get a plain-text 405. Errors from the rooms handler go through `auth.WriteError(w, r, logger, err)`.
- **internal/game (RoomManager)** — `LobbyOptions.Stakes` and `.Tables` must marshal as `[]`, never `null`: `config.FromEnv` already returns non-nil slices for `TABLE_STAKES=`/`LOBBY_TABLES=`, but a hand-built `config.Config` in a test can carry nil — copy through `append([]int64{}, cfg.Game.TableStakes...)` or guard. `GameConfig.TableRules` / `MenuMaxPot` / `NormalizeCategory` are there for `_createTable` / `lobbyOptions()` so the seen/blind/private composition is not re-derived.
- **internal/socket** — `publicGameConfig.maxBetRounds` is `config.Game.MaxBetRounds` (global 20), which handler.go:1173 already does; `TestPublicGameConfigValues` pins the scalars, so a change to those defaults will show up here first.
- **cmd/gameplay** — nothing; `godotenv.Load()` then `config.Load()` is the right order (dotenv never overrides real env).

## Integrator notes

- Build order (unchanged from PORT_PLAN §8): `tokens := auth.NewTokens(cfg.JWT.Secret, cfg.JWT.ExpiresIn, clock.Now)`; `verifier := auth.NewVerifier(cfg)`; `api := auth.NewHandler(auth.Deps{Config, Users, Tokens, Verifier, IsSeated, ProfilesDir: filepath.Join(cfg.PublicDir, "profiles"), Logger})`; `api.Register(mux)`; `mux.Handle("/api/", auth.NotFoundHandler())`. `Verifier.HTTP` is exported so the app or a test can inject a client; nil → 15 s timeout over `http.DefaultTransport`.
- **Rolling deploy is safe for sessions**: a token minted by the Node server (jsonwebtoken 9.0.3, `dev-only-insecure-secret` in the test) verifies in Go and vice versa, with identical claim sets; set the same `JWT_SECRET` on both. Only HS256 tokens are accepted — Node never minted anything else.
- The four Node-interop tests need `node` on PATH and `server/node_modules` (jsonwebtoken); they skip cleanly otherwise, so `go test ./...` passes on a machine without Node.
- Google login needs `GOOGLE_CLIENT_IDS`; Facebook needs both `FACEBOOK_APP_ID` and `FACEBOOK_APP_SECRET`; otherwise those providers answer 503 `provider_unconfigured` (or, with `AUTH_ALLOW_FAKE_PROVIDERS=true` and no credential, the fake path). Production refuses to start with fake providers on or the default JWT secret, exactly as Node did.
- `config.Load()` fails fast with `KEY="value": reason` for any malformed integer, duration, stake, lobby entry or schema; `.env` values are subject to the same rules, so `PORT=` (empty) is harmless but `PORT=abc` stops the boot.
- The `session:ready.config` / `lobbyOptions` values come from `config.Game` via the socket and game packages; nothing in `auth` or `config` serialises them.
