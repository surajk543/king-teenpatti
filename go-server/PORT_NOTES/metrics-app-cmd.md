# PORT_NOTES — internal/metrics, internal/app, cmd/gameplay

Owner scope: `internal/metrics/` (`metrics.go`, `names.go` untouched, `metrics_test.go`),
`internal/app/` (`app.go`, `health.go`, `static.go`, `cpu_unix.go`, `cpu_other.go`, `app_test.go`,
`assets/socket.io.min.js`, `assets/LICENSE`), `cmd/gameplay/main.go`.

## What is ported

### internal/metrics (← `server/src/metrics/index.js`)

| Node | Go | Notes |
|---|---|---|
| `registry.setDefaultLabels({service})` | `prometheus.WrapRegistererWith({service: "king-teenpatti"}, reg)`; everything (process, Go runtime, game) is registered through the wrapper | every sample carries `service="king-teenpatti"` — asserted for the whole exposition |
| `collectDefaultMetrics({prefix})` | `collectors.NewProcessCollector{Namespace: TrimSuffix(prefix,"_")}` → `game_server_process_{cpu_seconds_total, resident_memory_bytes, virtual_memory_bytes, open_fds, max_fds, start_time_seconds, …}`; `collectors.NewGoCollector(WithGoCollectorRuntimeMetrics(MetricsGC, MetricsScheduler))` under `WrapRegistererWithPrefix(prefix)` → `game_server_go_*` incl. `go_sched_latencies_seconds` | DECISIONS §6: `game_server_nodejs_*` not emulated |
| `${PREFIX}process_uptime_seconds` | `GaugeFunc` from `Options.StartedAt` | kept (project-defined) |
| `nodejs_heap_size_limit_bytes`, `nodejs_array_buffers_bytes`, `nodejs_eventloop_utilization` | not emitted | DECISIONS §6 |
| every `game_*` counter/gauge/histogram | exported fields on `*Metrics`, names from `names.go`, help strings verbatim, `LatencyBuckets` | catalogue test compares type + help + label set for all 35 |
| `game_players_online/active_games/waiting_games` | `GaugeFunc` over `RoomsSource.LiveTables()` using only lock-free `Table` getters | 0 until `BindRooms` |
| `game_tables{category,stake}` (`reset()` + `inc` per table at collect) | custom `Collector` emitting one const gauge per live (category, stake) pair | pairs with no table disappear, as in Node; `stake` = decimal boot; `category` raw, no SafeLabel (Node did not) |
| `game_db_pool_*` | `GaugeFunc` over `BindPool` func; panics swallowed → 0 | Node `poolStat` try/catch |
| `safeLabel(value, known, fallback)` | `SafeLabel` (skeleton) | |
| `timed`/`timedSync` | `Timed(obs, fn)` (observes in `defer`, error still returned) + `Observe(obs, d)` | |
| `httpMetricsMiddleware` | `HTTPMiddleware(metricsPath, routeLabel, next)`: skips `r.URL.Path == metricsPath` before timing; wraps the writer to capture status (default 200); labels `method` via `SafeLabel(HTTPMethods, "OTHER")`, `route` via `routeLabel`, `status_code` decimal | a hijacked (WebSocket) response is not counted — Node never saw Socket.IO traffic in Express |
| `routeLabel(req)` | `RouteLabelFor`: `r.Pattern` minus `"METHOD "` and host → the pattern path; a pattern ending in `/` (subtree catch-all: `/`, `/api/`) is not a route match → extension rule (`/` or `\.[a-zA-Z0-9]{2,5}$` → `static`, else `unmatched`) | |
| `metricsHandler()` | `Handler(Guard)`: IP allow-list (RemoteAddr host, `::ffff:` stripped, no proxy headers) → 403 `forbidden`; then exact `"Bearer "+token` → 401 `unauthorized`; then `promhttp.HandlerFor(reg, HandlerOpts{})` | text format `text/plain; version=0.0.4; charset=utf-8`; `le="1"`, `+Inf` present |

Exposition differences that Prometheus/Grafana do not observe (INCIDENTAL in the spec): Go's
gatherer orders metric families by name and label pairs by name (`method,route,service,status_code`),
not registration/declaration order; a labelled metric with no series prints **no** HELP/TYPE lines
(prom-client printed bare header lines). `game_tables` therefore only appears once a table exists.

### internal/app (← `server/src/index.js` `createServer` + `/health`)

`New` builds, in order: `metrics.New` (always — the counters must exist even when the endpoint is
off), `db.NewUsers`, `db.NewLedger(db, m, clock)`, `auth.NewTokens`, `auth.NewVerifier`,
`sio.NewServer{/socket.io/, 20 s, 25 s, 1e5, CheckOrigin}`, `socket.New` → `game.NewRoomManager
{TableListener: h, Listener: h, Metrics.ObserveCreation → m.CreationDuration}` → `SetRooms` → `Attach`,
`BindRooms`, `BindPool(DB.Stats)`, `StartSweeper`, then the mux:

```
GET {METRICS_PATH}   m.Handler(Guard{Token, AllowIPs})        (only when METRICS_ENABLED)
GET /health          App.Health
auth.Handler.Register(mux)                                     (8 API routes)
GET /api/rooms       {tables: ListTables({category}), options: LobbyOptions()}
/api/                auth.NotFoundHandler()  → 404 JSON {error:"not_found", message:"Cannot GET /x"}
/                    staticHandler(PUBLIC_DIR)
```
wrapped in `m.HTTPMiddleware` when metrics are enabled. **Outside** the middleware, in front of it:
`/socket.io/socket.io.js` and `/socket.io/socket.io.min.js` → the embedded socket.io-client 4.8.3
bundle (`assets/socket.io.min.js`, MIT, `assets/LICENSE`; copied verbatim from
`server/node_modules/socket.io/client-dist/socket.io.min.js`), and any other `/socket.io/…` →
`sio.Server`. That mirrors Node, where Socket.IO intercepted `/socket.io/` on the `http.Server`
before Express, so handshakes and the bundle were never in `game_http_requests_total`.

`CORS_ORIGIN`: `AllowAnyOrigin` → gorilla allows every origin; a list → exact `Origin` match, and
requests with no `Origin` header (native clients) pass. No CORS headers on REST (Node had none).

Static (`staticHandler`, spec-auth-http §2.5): GET/HEAD only; `index.html` at a directory URL with a
trailing slash; directory without slash → 301 to `path/`; directory without index → 404; dotfile
segments → 404; traversal impossible (`http.Dir` under a cleaned path); `Cache-Control: public,
max-age=0`, weak `ETag W/"<size hex>-<mtime hex>"`, `Last-Modified`, conditional/Range via
`http.ServeContent`; content types from a serve-static table (`.html/.js/.css/.txt` with
`charset=UTF-8`, `.svg` → `image/svg+xml`). Misses are `text/plain` `Cannot <METHOD> <path>` 404s
(DECISIONS §5).

`/health` (`HealthResponse`): key order `ok, uptime, tables, players, activeHands, sockets, process,
db` (embedding `game.Stats`), `sockets = sio.ClientsCount()`, `db = DB.Stats()` with `waiting` = the
pgxpool `EmptyAcquireCount` delta since the previous call (DECISIONS §5), `null` when no pool.
`process` (`ProcessHealth`, DECISIONS §5): `pid`; `node = runtime.Version()`; `rssMb` from
`/proc/self/statm` (fallback runtime/metrics `/memory/classes/total:bytes`); `heapUsedMb` =
`/memory/classes/heap/objects:bytes`; `heapTotalMb` = objects+unused+free+released (= HeapSys);
`externalMb = 0`; `cpuPercent` = getrusage(user+system) delta / wall delta × 100 since the previous
`/health` call, 1 dp, 0 on a zero window; `loopLagP50Ms/P99Ms/MaxMs` = percentiles of the
runtime/metrics `/sched/latencies:seconds` histogram **delta** since the previous call (bucket upper
bound; open bucket → lower bound), in ms 1 dp; plus the Go-only `goroutines`, `numCpu`, `gomaxprocs`
appended after the Node keys. All rounding is `Math.round(x*10)/10`. Marks are re-taken on every
call under a mutex, so two pollers see each other's windows exactly as in Node.

`Start(ctx)`: `net.Listen(HOST:PORT)` (PORT=0 allowed; `Addr()` reports the bound port), logs
`king-teenpatti server listening {url, env, welcomeChips, boot}` with the real port, then
`http.Server.Serve` (`ReadHeaderTimeout` 60 s = Node's `headersTimeout`); returns
`http.ErrServerClosed` after `Shutdown`. `Shutdown(ctx)`: `sio.Close()` → `rooms.Shutdown(ctx)`
(live pots settled) → `http.Shutdown(ctx)` → `sio.Shutdown(ctx)` (wait for socket goroutines);
idempotent (second call returns nil); `Start` after `Shutdown` returns `ErrServerClosed`.

### cmd/gameplay (← the entrypoint block)

`godotenv.Load()` (silent when absent, never overrides) → `config.Load` → `util.NewLogger` →
`db.Open` → `app.New` → `Start` in a goroutine; `SIGINT`/`SIGTERM` observed by name → log
`shutting down {signal}` → `app.Shutdown` with an 8 s budget → `db.Close` → exit 0; budget exceeded →
stderr + exit 1 (Node's `setTimeout(process.exit(1), 8000)`). A listener failure exits 1 with the
error. `REDIS_URL` set → one warning from `app.New` that it is ignored (PORT_PLAN decision 1).

## Doc-comment / skeleton changes

- `metrics.RouteLabelFor` doc said "a catch-all `/` → RouteStatic". That contradicts Node
  (`GET /nothing-here-123` must be `unmatched`; `test/metrics.test.js:522-531`). Fixed: a subtree
  pattern (ending in `/`) falls to the extension rule. Signature unchanged.
- `app.ProcessHealth` gained `Goroutines`, `NumCPU`, `GOMAXPROCS` (`goroutines`, `numCpu`,
  `gomaxprocs`) per DECISIONS §5 ("Extra fields …"), and its doc now describes the DECISIONS
  sources (`externalMb = 0`, `/sched/latencies` delta) instead of the skeleton's 20 ms ticker.
- `app.App` gained unexported fields (`clock`, `vitals`, `handler`, `mu`, `addr`, `serving`,
  `shutDown`); `apiNotFound` was dropped in favour of `auth.NotFoundHandler()` (the auth owner
  shipped one).

## Deliberate deviations (each traces to DECISIONS.md)

| Behaviour | Node | Go | Why |
|---|---|---|---|
| Node runtime metrics | `game_server_nodejs_*` | `game_server_go_*` + `game_server_process_*` | DECISIONS §6 |
| `/health.process.node` | `v22.22.1` | `go1.27.1` | DECISIONS §5 |
| `/health.process.externalMb` | V8 external bytes | `0` | DECISIONS §5 |
| `/health.process.loopLag*` | event-loop delay | scheduler latency delta | DECISIONS §5 |
| `/health.process` extra keys | — | `goroutines`, `numCpu`, `gomaxprocs` | DECISIONS §5 |
| `/health.db.waiting` | live `pool.waitingCount` | `EmptyAcquireCount` delta between calls | DECISIONS §5 |
| Unknown `/api/*` | HTML 404 | JSON 404 `{error:"not_found"}` | DECISIONS §5 |
| Static miss | HTML 404 | `text/plain` `Cannot GET /x` | DECISIONS §5 |
| `/socket.io/socket.io.js` | Socket.IO `serveClient` | embedded copy of the same file | DECISIONS §1 |
| `REDIS_URL` | adapter | logged as ignored | PORT_PLAN decision 1 |
| Wrong method on a known `/api` route | `unmatched` HTTP metric label (no Express route matched) | the route's pattern label (the auth owner registered method-less patterns with an inner method check) | INCIDENTAL; recorded so nobody hunts it |
| `cpuPercent` source | `process.cpuUsage()` (getrusage) | `syscall.Getrusage` on Unix; 0 elsewhere | same figures; the runtime/metrics CPU classes exclude time in blocking syscalls, so getrusage is the faithful one |

## How it was tested

`internal/metrics` (no DB): catalogue (type, help, exact label set of all 35 `game_*` metrics),
every sample prefixed `game_` and carrying `service`, process/Go families present under the prefix,
bucket boundaries print `0.001 … 1 +Inf` with `le="1"`, unlabelled series appear at 0 and labelled
ones only on first use, `game_tables` absent until a table exists, `SafeLabel` folding (uuid, code,
IPv4/IPv6, sha256, "teleport", case) → `other`, the full cardinality sweep of Node's last test
(forbidden label names, `_id`/`code_`, UUID/IPv4/IPv6/SHA-256 values, `code`/`event`/`category`/
`method`/`reason` shapes), guard order (401 no header / wrong token / lower-case scheme, 403 wrong IP
before token, `::ffff:` normalisation, verbatim IPv6, open endpoint), `RouteLabelFor` table (16
cases), end-to-end middleware over a ServeMux (route patterns, `static`, `unmatched`, `OTHER`
method, body left unread, `/metrics` and `/metrics?x=1` never counted, no raw URL/query/id in any
route), pool gauges (bound values, panic → 0), `game_tables` reset-and-recount with live
`game.Table`s (skips while `game.NewTable` is unported), `Timed` observing on error, caller registry
adoption + double-registration panic.

`internal/app` (Postgres via `dbtest.Open(t, "app")`, skipped when unreachable): `/health` exact key
order regex + every `process` key + value sanity + second-call re-marking; `histogramPercentiles`
and rounding helpers; static index/css/svg/txt content types, cache headers, 304 on `If-None-Match`,
dotfile 404, directory 301/404, `POST /index.html` 404, plain-text miss body, HEAD; both socket.io
bundle paths (content type, byte length, banner) and the polling handshake reaching sio (400 code 0);
JSON 404 for `/api/unknown` and `GET /api/auth/login`, `/api/profiles` served; `/api/rooms` shape
(`tables: []` never null, all option keys); `/metrics` 401 → 200 with bearer, route labels
`/health`, `unmatched`, `/api/rooms`, `static` present, `/metrics` and `/socket.io` absent, pool
gauge bound; `METRICS_ENABLED=false` removes the endpoint; `Start` on PORT=0 → `Addr()` → real TCP
`/health` → `Shutdown` → `Start` returns `ErrServerClosed` → second `Shutdown` nil → listener closed
→ `Start` again refused.

Final `go test` summary: see the bottom of this file (filled in after the last run).

## Requests for other packages

- **internal/auth** (informational): `Register` uses method-less patterns + an inner method check, so
  `GET /api/auth/login` is labelled `route="/api/auth/login"` (Node: `unmatched`). Harmless; if you
  ever switch to `"POST /api/auth/login"` patterns the label becomes Node's automatically.
- **internal/config**: `PublicDir` defaults to `./public`; PORT_PLAN §9 says `../server/public` with a
  `./public` fallback. `app.New` warns once when the directory is missing; the default is yours.
- **internal/game**: nothing needed — `LiveTables`, `Stats`, `ListTables`, `LobbyOptions`,
  `GetTableForPlayer`, `StartSweeper`, `Shutdown` and the lock-free `Table` getters are exactly what
  the app/metrics use.

## Notes for the integrator

- `metrics.New` registers into a fresh registry per call; never call it twice on one registry.
- The app never mounts `/socket.io/` on the mux: the outer handler dispatches it (and the two bundle
  paths) before the metrics middleware. If you add routes, add them to `mux` in `New`.
- `/health` mutates its CPU/scheduler marks on every call (as Node did); tests that assert exact
  `cpuPercent`/`loopLag*` numbers will be flaky by design — assert shape and ranges.
- `cmd/gameplay` returns exit 1 (after printing the error) when `Shutdown` exceeds 8 s; `db.Close`
  is skipped in that path exactly as Node's `process.exit(1)` skipped `closeDatabase()`.
- Grafana: the "Node.js" row and the three `nodejs_*` alerts need re-pointing at `game_server_go_*`
  (`go_sched_latencies_seconds` is exported for a latency panel) — DECISIONS §6 defers this to ops.
