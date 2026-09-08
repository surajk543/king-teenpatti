// Package app assembles the server (the port of server/src/index.js
// createServer + the entrypoint block): HTTP mux, static browser client,
// /health, /metrics, the REST API, the Socket.IO endpoint, the RoomManager,
// and orderly Start / Shutdown.
package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
	"github.com/surajk543/king-teenpatti/go-server/internal/sio"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
)

// Options builds an App. DB must already be open (cmd/gameplay opens it and
// closes it after Shutdown, mirroring index.js: openDatabase first,
// closeDatabase last).
type Options struct {
	Config *config.Config
	DB     *db.DB
	Logger *slog.Logger
	Clock  game.Clock // nil → game.RealClock{}
	// StartedAt feeds /health uptime and the uptime gauge; zero → now.
	StartedAt time.Time
}

// App is the assembled server.
type App struct {
	cfg     *config.Config
	log     *slog.Logger
	db      *db.DB
	metrics *metrics.Metrics
	rooms   *game.RoomManager
	sio     *sio.Server
	sockets *socket.Handler
	mux     *http.ServeMux
	http    *http.Server
	started time.Time
	clock   game.Clock
	vitals  *vitals
	handler http.Handler

	mu       sync.Mutex
	addr     string
	serving  bool
	shutDown bool
}

// Socket.IO engine settings (index.js:113-123): the values every shipped
// client was tuned against; sio.Options documents them as its defaults too.
const (
	sioPath         = "/socket.io/"
	sioPingInterval = 20 * time.Second
	sioPingTimeout  = 25 * time.Second
	sioMaxPayload   = 100000 // maxHttpBufferSize: 1e5
)

// New wires everything (createServer):
//
//  1. metrics.New (if config.Metrics.Enabled; else a Metrics that observes
//     into an unexposed registry — the counters are still safe to call);
//  2. users := db.NewUsers(DB, WelcomeChips); ledger := db.NewLedger(DB, m);
//     tokens := auth.NewTokens(JWT); verifier := auth.NewVerifier(cfg);
//  3. sio.NewServer{PingInterval 20s, PingTimeout 25s, MaxPayload 1e5,
//     CheckOrigin from cfg.CORSOrigin / AllowAnyOrigin};
//  4. sockets := socket.New(Deps{Rooms: nil, …}); rooms := game.NewRoomManager
//     {TableListener: sockets, Listener: sockets, Ledger, Clock, Metrics:
//     {ObserveCreation: m.CreationDuration}}; sockets.SetRooms(rooms);
//     sockets.Attach(sio) — this order because the RoomManager needs the
//     Handler as its listeners at construction and the Handler needs the
//     RoomManager only at request time;
//  5. m.BindRooms(rooms); m.BindPool(DB.Stats); rooms.StartSweeper();
//  6. mux routes (Go 1.22 patterns):
//     GET  {metricsPath}     → m.Handler(Guard{Token, AllowIPs})
//     GET  /health           → Health
//     auth.Handler.Register(mux)   (the 8 API routes)
//     GET  /api/rooms        → {tables: ListTables({category: ?category if blind|seen}), options}
//     /socket.io/            → sio
//     /                      → the browser client from cfg.PublicDir (staticHandler)
//     wrapped in m.HTTPMiddleware(metricsPath, metrics.RouteLabelFor, mux)
//     when metrics are enabled; unknown /api paths → 404 JSON
//     {error:"not_found"} — Express returned its HTML 404, which nothing
//     depends on.
//
// The Socket.IO endpoint and its client bundle (/socket.io/socket.io.js,
// embedded) sit OUTSIDE the metrics middleware: in Node, Socket.IO attached to
// the http.Server and intercepted /socket.io/ before Express, so handshakes
// were never counted in game_http_requests_total.
func New(opts Options) (*App, error) {
	cfg := opts.Config
	if cfg == nil {
		return nil, errors.New("app: Options.Config is required")
	}
	if cfg.Metrics.Enabled && !strings.HasPrefix(cfg.Metrics.Path, "/") {
		return nil, fmt.Errorf("app: METRICS_PATH must start with '/', got %q", cfg.Metrics.Path)
	}
	logger := opts.Logger
	if logger == nil {
		logger = slog.Default()
	}
	clock := opts.Clock
	if clock == nil {
		clock = game.RealClock{}
	}
	started := opts.StartedAt
	if started.IsZero() {
		started = clock.Now()
	}

	a := &App{cfg: cfg, log: logger, db: opts.DB, started: started, clock: clock}
	a.vitals = newVitals(started)

	if cfg.RedisURL != "" {
		// PORT_PLAN.md decision 1: single process, no adapter.
		logger.Warn("REDIS_URL is ignored: the Go server is a single process with no Socket.IO adapter")
	}

	// 1. metrics — always built so the counters the socket layer, ledger and
	// RoomManager touch exist; only exposed when enabled.
	a.metrics = metrics.New(metrics.Options{Prefix: cfg.Metrics.Prefix, StartedAt: started})

	// 2. stores, tokens, providers.
	users := db.NewUsers(opts.DB, cfg.Game.WelcomeChips, clock.Now)
	ledger := db.NewLedger(opts.DB, a.metrics, clock.Now)
	tokens := auth.NewTokens(cfg.JWT.Secret, cfg.JWT.ExpiresIn, clock.Now)
	verifier := auth.NewVerifier(cfg)

	// 3. the Socket.IO server.
	a.sio = sio.NewServer(sio.Options{
		Path:         sioPath,
		PingInterval: sioPingInterval,
		PingTimeout:  sioPingTimeout,
		MaxPayload:   sioMaxPayload,
		CheckOrigin:  originChecker(cfg),
		Logger:       logger,
		Now:          clock.Now,
	})

	// 4. realtime handler ↔ room manager (mutual dependency, see the doc).
	a.sockets = socket.New(socket.Deps{
		Config:  cfg,
		Users:   users,
		Tokens:  tokens,
		Metrics: a.metrics,
		Clock:   clock,
		Logger:  logger,
	})
	a.rooms = game.NewRoomManager(game.RoomManagerOptions{
		Game:          cfg.Game,
		Chat:          cfg.Chat,
		Ledger:        ledger,
		Clock:         clock,
		TableListener: a.sockets,
		Listener:      a.sockets,
		Logger:        logger,
		Metrics: game.MetricsHooks{
			ObserveCreation: func(d time.Duration) { metrics.Observe(a.metrics.CreationDuration, d) },
		},
	})
	a.sockets.SetRooms(a.rooms)
	a.sockets.Attach(a.sio)

	// 5. late-bound metric sources and the consolidation sweeper.
	a.metrics.BindRooms(a.rooms)
	if opts.DB != nil {
		a.metrics.BindPool(func() metrics.PoolStats {
			s := opts.DB.Stats()
			return metrics.PoolStats{Total: s.Total, Idle: s.Idle, Waiting: s.Waiting}
		})
	}
	a.rooms.StartSweeper()

	// 6. routes.
	api := auth.NewHandler(auth.Deps{
		Config:      cfg,
		Users:       users,
		Tokens:      tokens,
		Verifier:    verifier,
		IsSeated:    func(userID string) bool { return a.rooms.GetTableForPlayer(userID) != nil },
		ProfilesDir: filepath.Join(cfg.PublicDir, "profiles"),
		Logger:      logger,
	})
	mux := http.NewServeMux()
	if cfg.Metrics.Enabled {
		mux.Handle("GET "+cfg.Metrics.Path, a.metrics.Handler(metrics.Guard{Token: cfg.Metrics.Token, AllowIPs: cfg.Metrics.AllowIP}))
	}
	mux.HandleFunc("GET /health", a.Health)
	api.Register(mux)
	mux.HandleFunc("GET /api/rooms", a.roomsHandler)
	mux.Handle("/api/", auth.NotFoundHandler())
	if !publicDirExists(cfg.PublicDir) {
		logger.Warn("browser client directory not found; static requests will 404", "publicDir", cfg.PublicDir)
	}
	mux.Handle("/", staticHandler{root: http.Dir(cfg.PublicDir)})
	a.mux = mux

	var web http.Handler = mux
	if cfg.Metrics.Enabled {
		web = a.metrics.HTTPMiddleware(cfg.Metrics.Path, metrics.RouteLabelFor, mux)
	}
	a.handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if clientBundlePaths[r.URL.Path] {
			a.serveClientBundle(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, sioPath) {
			a.sio.ServeHTTP(w, r)
			return
		}
		web.ServeHTTP(w, r)
	})
	a.http = &http.Server{
		Handler: a.handler,
		// Node's http.Server headersTimeout (60 s); no other timeouts, because
		// WebSocket upgrades are hijacked and long polls do not exist.
		ReadHeaderTimeout: 60 * time.Second,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelWarn),
	}
	return a, nil
}

// originChecker builds gorilla's CheckOrigin from CORS_ORIGIN: nil (allow
// everything) for "*" / unset, else an exact match of the Origin header
// against the list; requests without an Origin header (native clients) pass,
// as Socket.IO's cors handling let them through.
func originChecker(cfg *config.Config) func(r *http.Request) bool {
	if cfg.AllowAnyOrigin || len(cfg.CORSOrigin) == 0 {
		return nil
	}
	allowed := make(map[string]bool, len(cfg.CORSOrigin))
	for _, o := range cfg.CORSOrigin {
		allowed[o] = true
	}
	return func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		return origin == "" || allowed[origin]
	}
}

// Handler returns the root http.Handler (for httptest in integration tests).
func (a *App) Handler() http.Handler {
	return a.handler
}

// Rooms exposes the RoomManager (tests, tooling).
func (a *App) Rooms() *game.RoomManager { return a.rooms }

// Start listens on cfg.Host:cfg.Port and serves until Shutdown. It logs
// `king-teenpatti server listening {url, env, welcomeChips, boot}` and
// returns http.ErrServerClosed after a clean Shutdown. PORT=0 is allowed —
// Addr() reports the port the kernel picked.
func (a *App) Start(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	a.mu.Lock()
	if a.shutDown {
		a.mu.Unlock()
		return http.ErrServerClosed
	}
	if a.serving {
		a.mu.Unlock()
		return errors.New("app: Start called twice")
	}
	a.serving = true
	a.mu.Unlock()

	ln, err := net.Listen("tcp", net.JoinHostPort(a.cfg.Host, strconv.Itoa(a.cfg.Port)))
	if err != nil {
		a.mu.Lock()
		a.serving = false
		a.mu.Unlock()
		return err
	}
	a.mu.Lock()
	a.addr = ln.Addr().String()
	a.mu.Unlock()

	_, port, _ := net.SplitHostPort(ln.Addr().String())
	a.log.Info("king-teenpatti server listening",
		"url", "http://"+net.JoinHostPort(a.cfg.Host, port),
		"env", a.cfg.Env,
		"welcomeChips", a.cfg.Game.WelcomeChips,
		"boot", a.cfg.Game.BootAmount,
	)
	return a.http.Serve(ln)
}

// Addr is the bound address once Start has listened ("" before).
func (a *App) Addr() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.addr
}

// Shutdown is the entrypoint's `shutdown(signal)`, in this order: sio.Close()
// (every socket gets "server shutting down"); rooms.Shutdown(ctx) — LIVE
// HANDS ARE SETTLED (pots paid out) before anything else closes; http
// Shutdown(ctx). The caller then closes the DB. cmd/gameplay bounds the whole
// thing with 8 s, as Node's setTimeout(process.exit(1), 8000). A second call
// is a no-op returning nil.
func (a *App) Shutdown(ctx context.Context) error {
	a.mu.Lock()
	if a.shutDown {
		a.mu.Unlock()
		return nil
	}
	a.shutDown = true
	serving := a.serving
	a.mu.Unlock()

	// 1. Disconnect every client so no new move can start.
	a.sio.Close()
	// 2. Destroy every table — a live hand is settled and its pot paid out.
	roomsErr := a.rooms.Shutdown(ctx)
	// 3. Stop accepting and drain the HTTP listener.
	var httpErr error
	if serving {
		httpErr = a.http.Shutdown(ctx)
	}
	// 4. Wait for the socket goroutines to wind down (bounded by ctx).
	sioErr := a.sio.Shutdown(ctx)
	return errors.Join(roomsErr, httpErr, sioErr)
}

// HealthResponse is GET /health. Field names are Node's; `node` carries the
// Go runtime version string ("go1.27.1") because the load-test tooling reads
// the key by name. Loop-lag fields report the scheduler-latency proxy
// described in ProcessHealth.
type HealthResponse struct {
	OK     bool    `json:"ok"`
	Uptime float64 `json:"uptime"` // seconds, fractional
	game.Stats
	// Sockets is sio.ClientsCount(); null only if the socket server is absent.
	Sockets *int          `json:"sockets"`
	Process ProcessHealth `json:"process"`
	// DB is null when the pool is not open.
	DB *db.PoolStats `json:"db"`
}

// ProcessHealth is /health.process. Node's values came from process.memoryUsage,
// process.cpuUsage and monitorEventLoopDelay; the Go equivalents (DECISIONS.md §5):
//
//	pid          os.Getpid()
//	node         runtime.Version() — the key is kept for the tooling
//	rssMb        /proc/self/statm resident pages × page size (fallback:
//	             runtime/metrics "/memory/classes/total:bytes") → MiB, 1 dp
//	heapUsedMb   runtime/metrics heap objects bytes (MemStats.HeapAlloc) → MiB
//	heapTotalMb  objects + unused + free + released (MemStats.HeapSys) → MiB
//	externalMb   0 — Go has no off-heap "external" allocation class
//	cpuPercent   share of one core used since the PREVIOUS /health call
//	             (getrusage user+system delta / wall delta × 100), 1 dp
//	loopLagP50Ms / P99Ms / MaxMs
//	             Go scheduler latency (runtime/metrics "/sched/latencies:seconds",
//	             the time goroutines waited to be scheduled) since the PREVIOUS
//	             /health call, as percentiles in ms, 1 dp; ≈ 0 when idle
//	             (Node read ~20 ms idle because of its 20 ms resolution).
//	goroutines / numCpu / gomaxprocs
//	             Go-only extras (DECISIONS.md §5) — appended after the Node keys.
type ProcessHealth struct {
	PID          int     `json:"pid"`
	Node         string  `json:"node"`
	RSSMb        float64 `json:"rssMb"`
	HeapUsedMb   float64 `json:"heapUsedMb"`
	HeapTotalMb  float64 `json:"heapTotalMb"`
	ExternalMb   float64 `json:"externalMb"`
	CPUPercent   float64 `json:"cpuPercent"`
	LoopLagP50Ms float64 `json:"loopLagP50Ms"`
	LoopLagP99Ms float64 `json:"loopLagP99Ms"`
	LoopLagMaxMs float64 `json:"loopLagMaxMs"`
	Goroutines   int     `json:"goroutines"`
	NumCPU       int     `json:"numCpu"`
	GOMAXPROCS   int     `json:"gomaxprocs"`
}

// Health serves GET /health (index.js app.get('/health')).
func (a *App) Health(w http.ResponseWriter, r *http.Request) {
	now := a.clock.Now()
	var emptyAcquire int64 = -1
	if a.db != nil && a.db.Pool != nil {
		emptyAcquire = a.db.Pool.Stat().EmptyAcquireCount()
	}
	process, waiting := a.vitals.read(now, emptyAcquire)

	res := HealthResponse{
		OK:      true,
		Uptime:  now.Sub(a.started).Seconds(),
		Stats:   a.rooms.Stats(),
		Process: process,
	}
	if a.sio != nil {
		count := a.sio.ClientsCount()
		res.Sockets = &count
	}
	if a.db != nil && a.db.Pool != nil {
		stats := a.db.Stats()
		stats.Waiting = waiting
		res.DB = &stats
	}
	auth.WriteJSON(w, http.StatusOK, res)
}

// RoomsResponse is GET /api/rooms and lobby:list's ack body.
type RoomsResponse struct {
	Tables  []game.TableSummary `json:"tables"`
	Options game.LobbyOptions   `json:"options"`
}

// roomsHandler is GET /api/rooms?category= (index.js:87-97): the category
// filter applies only to the exact strings "blind" / "seen" given once —
// Express's 'simple' query parser turned a repeated key into an array, which
// matched neither, so it is no filter either.
func (a *App) roomsHandler(w http.ResponseWriter, r *http.Request) {
	var category game.Category
	if values := r.URL.Query()["category"]; len(values) == 1 {
		switch values[0] {
		case string(game.CategoryBlind):
			category = game.CategoryBlind
		case string(game.CategorySeen):
			category = game.CategorySeen
		}
	}
	tables := a.rooms.ListTables(game.ListOptions{Category: category})
	if tables == nil {
		tables = []game.TableSummary{}
	}
	auth.WriteJSON(w, http.StatusOK, RoomsResponse{Tables: tables, Options: a.rooms.LobbyOptions()})
}
