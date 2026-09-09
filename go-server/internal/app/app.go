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
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase"
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
	// Live is the live-state store (LIVE_STATE_PLAN.md). nil → New opens one
	// from Config: Redis when REDIS_URL is set (failing fast when it is
	// unreachable), the in-process store otherwise — and Shutdown closes it
	// last. An injected store (tests; several apps replaying a restart on one
	// store) stays open: its owner closes it, as with DB.
	Live live.Store
}

// App is the assembled server.
type App struct {
	cfg     *config.Config
	log     *slog.Logger
	db      *db.DB
	metrics *metrics.Metrics
	live    live.Store
	// ownsLive: New opened the store (Options.Live was nil) and Shutdown
	// closes it.
	ownsLive bool
	rooms    *game.RoomManager
	sio      *sio.Server
	sockets  *socket.Handler
	// restore records what the startup sequence did (logged once; Restore()
	// exposes it to tests and tooling).
	restore game.RestoreReport
	// reconcileStop/Done drive the live-store reconciler (LIVE_RECONCILE_MS);
	// Shutdown stops it.
	reconcileStop chan struct{}
	reconcileDone chan struct{}
	// ledgerPurgeStop/Done drive the chip_ledger purge job
	// (LEDGER_PURGE_INTERVAL_MS); Shutdown stops it.
	ledgerPurgeStop chan struct{}
	ledgerPurgeDone chan struct{}
	mux           *http.ServeMux
	http          *http.Server
	started       time.Time
	clock         game.Clock
	vitals        *vitals
	handler       http.Handler

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
	// maxHeaderBytes is Node's default http.maxHeaderSize (16 KiB): the
	// largest request-line + header block accepted; bigger → 431.
	maxHeaderBytes = 16 << 10
	sioMaxPayload  = 100000 // maxHttpBufferSize: 1e5
)

// Live-store timings owned by the app.
const (
	// liveOpenTimeout bounds live.Open (one Redis ping) — fail fast.
	liveOpenTimeout = 5 * time.Second
	// liveRoundTrip is live.Options.Timeout, one Redis round trip.
	liveRoundTrip = 500 * time.Millisecond
	// restoreTimeout bounds the whole startup sequence against the store and
	// the database (Restore + RefundOrphanedPots); generous because a large
	// store means many round trips, still finite so a hung backend cannot
	// hold the process in "starting" forever.
	restoreTimeout = 60 * time.Second
	// healthLiveTimeout bounds the two store calls /health makes.
	healthLiveTimeout = time.Second
	// reconcileTimeout bounds one reconciler pass.
	reconcileTimeout = 20 * time.Second
	// ledgerPurgeTimeout bounds one PurgeLedger pass.
	ledgerPurgeTimeout = 30 * time.Second
)

// New wires everything (createServer) and runs the live-state startup
// sequence (LIVE_STATE_PLAN.md):
//
//  1. metrics.New (if config.Metrics.Enabled; else a Metrics that observes
//     into an unexposed registry — the counters are still safe to call);
//  2. the live store: Options.Live, else live.Open (Redis when REDIS_URL is
//     set — unreachable → New fails and the process exits; memory otherwise),
//     wrapped with live.WithHooks(store, m.LiveHooks()) so every call feeds
//     game_live_store_*;
//  3. users := db.NewUsers(DB, WelcomeChips); ledger := db.NewLedger(DB, m);
//     tokens := auth.NewTokens(JWT); verifier := auth.NewVerifier(cfg);
//     sio.NewServer{PingInterval 20s, PingTimeout 25s, MaxPayload 1e5,
//     CheckOrigin from cfg.CORSOrigin / AllowAnyOrigin};
//  4. sockets := socket.New(Deps{Live, Instance, …}); rooms :=
//     game.NewRoomManager{TableListener: sockets, Listener: sockets, Ledger,
//     Clock, Live, Instance, LiveTTL, Metrics: {ObserveCreation}};
//     sockets.SetRooms(rooms); sockets.Attach(sio) — this order because the
//     RoomManager needs the Handler as its listeners at construction and the
//     Handler needs the RoomManager only at request time;
//  5. m.BindRooms(rooms); m.BindPool(DB.Stats);
//  6. the restart sequence: rooms.Restore(ctx) (tables rebuilt from the
//     store; a store that cannot be listed is fatal) →
//     DB.RefundOrphanedPots(ctx, restored hand ids) (open pots no live table
//     holds go back to their contributors; a failure is logged, the next
//     start retries) → sockets.RestoreSeats(rooms.RestoredSeats()) (every
//     restored seat held for RECONNECT_GRACE_MS) → one summary log line
//     `live state restored`; then rooms.StartSweeper(). The listener opens in
//     Start, after all of this.
//  7. mux routes (Go 1.22 patterns):
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

	// 1. metrics — always built so the counters the socket layer, ledger and
	// RoomManager touch exist; only exposed when enabled.
	a.metrics = metrics.New(metrics.Options{Prefix: cfg.Metrics.Prefix, StartedAt: started})

	// 2. the live store, before anything that depends on it. Redis
	// unreachable → fail fast (LIVE_STATE_PLAN.md startup step 1).
	store := opts.Live
	if store == nil {
		octx, cancel := context.WithTimeout(context.Background(), liveOpenTimeout)
		defer cancel()
		opened, err := live.Open(octx, live.Options{URL: cfg.RedisURL, Instance: cfg.LiveInstanceID, Timeout: liveRoundTrip})
		if err != nil {
			return nil, fmt.Errorf("live store: %w", err)
		}
		store = opened
		a.ownsLive = true
	}
	a.live = live.WithHooks(store, a.metrics.LiveHooks())
	logger.Info("live store ready", "kind", a.live.Kind(), "instance", cfg.LiveInstanceID, "url", db.Redact(cfg.RedisURL))

	// 3. stores, tokens, providers.
	users := db.NewUsers(opts.DB, cfg.Game.WelcomeChips, clock.Now)
	ledger := db.NewLedger(opts.DB, a.metrics, clock.Now)
	tokens := auth.NewTokens(cfg.JWT.Secret, cfg.JWT.ExpiresIn, clock.Now)
	verifier := auth.NewVerifier(cfg)

	// The Socket.IO server.
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
		Config:   cfg,
		Users:    users,
		Tokens:   tokens,
		Metrics:  a.metrics,
		Clock:    clock,
		Logger:   logger,
		Live:     a.live,
		Instance: cfg.LiveInstanceID,
	})
	roomOpts := game.RoomManagerOptions{
		Game:          cfg.Game,
		Chat:          cfg.Chat,
		Ledger:        ledger,
		Clock:         clock,
		TableListener: a.sockets,
		Listener:      a.sockets,
		Logger:        logger,
		Live:          a.live,
		Instance:      cfg.LiveInstanceID,
		LiveTTL:       cfg.LiveStateTTL,
		Metrics: game.MetricsHooks{
			ObserveCreation: func(d time.Duration) { metrics.Observe(a.metrics.CreationDuration, d) },
			// game_hand_start_duration_seconds used to be timed around the
			// boot transaction; the deal writes nothing to PostgreSQL since
			// 9 Sep 2026, so the table times its own work.
			ObserveHandStart: func(d time.Duration) { metrics.Observe(a.metrics.HandStartDuration, d) },
			// ObserveLiveError stays nil: the WithHooks wrapper already
			// counts every failed store call in game_live_store_errors_total.
		},
	}
	a.rooms = game.NewRoomManager(roomOpts)
	a.sockets.SetRooms(a.rooms)
	a.sockets.Attach(a.sio)

	// 5. late-bound metric sources.
	a.metrics.BindRooms(a.rooms)
	if opts.DB != nil {
		a.metrics.BindPool(func() metrics.PoolStats {
			s := opts.DB.Stats()
			return metrics.PoolStats{Total: s.Total, Idle: s.Idle, Waiting: s.Waiting}
		})
	}

	// 6. the restart sequence, then the sweeper and the reconciler.
	if err := a.restoreLiveState(); err != nil {
		if a.ownsLive {
			_ = a.live.Close()
		}
		return nil, err
	}
	a.rooms.StartSweeper()
	a.startReconciler()
	a.startLedgerPurge()

	// 7. routes.
	//
	// The chip store is wired only when Play credentials are present. With
	// none, `store` stays nil and the endpoint answers 503: a server that
	// cannot verify a receipt must refuse rather than take the client's word.
	// A broken credential disables the STORE. It must never stop the server.
	//
	// This first refused to start, on the reasoning that a server with bad
	// payment credentials would otherwise fail only once a player had been
	// charged. That reasoning is right about the store and badly wrong about
	// the game: on 9 Sep 2026 a service-account key pasted across several
	// lines — which godotenv cannot parse — crash-looped production and took
	// every table down for a feature nobody was using yet. The safe state for
	// an unverifiable store is closed (503), which is exactly what a nil
	// gateway gives, and the game is unaffected either way. Loud log, carry on.
	var chipStore auth.PurchaseGateway
	creds := cfg.Play.Credentials
	if path := cfg.Play.CredentialsFile; path != "" {
		// A path is preferred precisely because it cannot be mangled by an
		// env-file parser on the way in — see config.PlayConfig.
		b, err := os.ReadFile(path)
		if err != nil {
			logger.Error("chip store disabled: cannot read Google Play credentials file",
				"path", path, "err", err.Error())
			creds = ""
		} else {
			creds = string(b)
		}
	}
	if pv, err := purchase.NewGoogleVerifier(cfg.Play.Package, creds); err != nil {
		logger.Error("chip store disabled: Google Play credentials are unusable",
			"err", err.Error(),
			"hint", "GOOGLE_PLAY_CREDENTIALS must be the service-account JSON on ONE line")
	} else if pv != nil {
		chipStore = &playStore{
			verifier:   pv,
			db:         opts.DB,
			users:      users,
			creditSeat: func(id string, n int64) bool { return a.rooms.CreditChips(id, n) },
			logger:     logger,
		}
		logger.Info("chip store enabled", "package", cfg.Play.Package, "products", len(purchase.Catalogue))
	}

	api := auth.NewHandler(auth.Deps{
		Config:      cfg,
		Users:       users,
		Tokens:      tokens,
		Verifier:    verifier,
		IsSeated:    func(userID string) bool { return a.rooms.GetTableForPlayer(userID) != nil },
		Purchases:   chipStore,
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
		// Node's http.maxHeaderSize (16 KiB, --max-http-header-size). Go's
		// default is 1 MiB, and sio keeps every upgrade request's headers for
		// the life of the WebSocket (Handshake.Headers), so without this a
		// client holding a free guest token could pin 1 MiB per connection.
		MaxHeaderBytes: maxHeaderBytes,
		ErrorLog:       slog.NewLogLogger(logger.Handler(), slog.LevelWarn),
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

// restoreLiveState is startup steps 2–4 of LIVE_STATE_PLAN.md, run by New
// before the sweeper starts and the listener opens:
//
//	rooms.Restore(ctx)                            every table the live store holds
//	sockets.RestoreSeats(rooms.RestoredSeats())   every restored seat held for the grace
//
// The live store is the only source: PostgreSQL holds money and audit and no
// game state at all, so a lost live store means the hand never happened —
// the players re-join and whatever PostgreSQL holds is their balance. There
// is nothing to refund because PostgreSQL never holds pot money.
//
// A store that cannot even be listed is fatal (the process must not start
// half-blind and let the next process fight it over the same tables).
// Counters: game_restored_tables_total, game_restored_seats_total (the
// handler adds it). One summary line is logged:
//
//	restored tables=N seats=C
func (a *App) restoreLiveState() error {
	ctx, cancel := context.WithTimeout(context.Background(), restoreTimeout)
	defer cancel()

	report, err := a.rooms.Restore(ctx)
	if err != nil {
		return fmt.Errorf("restore tables: %w", err)
	}
	a.restore = report
	if report.Tables > 0 {
		a.metrics.RestoredTablesTotal.Add(float64(report.Tables))
	}

	restored := a.rooms.RestoredSeats()
	seats := make([]socket.RestoredSeat, 0, len(restored))
	for _, s := range restored {
		seats = append(seats, socket.RestoredSeat{UserID: s.UserID, RoomID: s.RoomID})
	}
	held := a.sockets.RestoreSeats(seats)

	a.log.Info(fmt.Sprintf("restored tables=%d seats=%d", report.Tables, held),
		"store", a.live.Kind(),
		"handsInProgress", report.HandsInProgress,
		"snapshotsDropped", report.Dropped,
		"loadsFailed", report.Failed,
		"graceMs", a.cfg.Game.ReconnectGrace.Milliseconds(),
	)
	return nil
}

// startReconciler runs one reconcile pass every LIVE_RECONCILE_MS
// (LIVE_STATE_PLAN.md "Redis dies, server keeps running"): the store is
// pinged and, on the transition back to healthy, every live table is
// re-saved and the seats and lobby index re-published, so a Redis that came
// back empty is refilled without waiting for each table's next move. Counted
// in game_live_store_reconciles_total{result}. A non-positive interval
// disables it.
func (a *App) startReconciler() {
	interval := a.cfg.LiveReconcile
	if interval <= 0 {
		return
	}
	a.reconcileStop = make(chan struct{})
	a.reconcileDone = make(chan struct{})
	go func() {
		defer close(a.reconcileDone)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				ctx, cancel := context.WithTimeout(context.Background(), reconcileTimeout)
				err := a.reconcileLive(ctx)
				cancel()
				if err != nil {
					a.metrics.LiveStoreReconciles.WithLabelValues(metrics.ResultError).Inc()
					a.log.Warn("live store reconcile failed", "error", err.Error())
				} else {
					a.metrics.LiveStoreReconciles.WithLabelValues(metrics.ResultOK).Inc()
				}
			case <-a.reconcileStop:
				return
			}
		}
	}()
}

// stopReconciler stops the ticker and waits for a pass in flight.
func (a *App) stopReconciler() {
	if a.reconcileStop == nil {
		return
	}
	close(a.reconcileStop)
	<-a.reconcileDone
	a.reconcileStop = nil
}

// startLedgerPurge runs db.PurgeLedger every LEDGER_PURGE_INTERVAL_MS,
// removing chip_ledger checkpoint rows (hand_win/hand_loss/hand_packed/
// hand_left only — see db.purgeableReasons) once they are older than
// LEDGER_PURGE_AFTER_MS. purchase/milestone_reward/timed_bonus/welcome_bonus
// rows are never touched by this job; their UNIQUE action_id is a standing
// double-credit guard, not a short-lived retry guard, and PurgeLedger's WHERE
// clause is hardcoded to exclude them regardless of what this loop does.
//
// A non-positive interval disables the job entirely — the default keeps
// every row forever, same as before this existed.
func (a *App) startLedgerPurge() {
	interval := a.cfg.DB.LedgerPurgeInterval
	if interval <= 0 || a.db == nil {
		return
	}
	a.ledgerPurgeStop = make(chan struct{})
	a.ledgerPurgeDone = make(chan struct{})
	go func() {
		defer close(a.ledgerPurgeDone)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				ctx, cancel := context.WithTimeout(context.Background(), ledgerPurgeTimeout)
				cutoff := a.clock.Now().Add(-a.cfg.DB.LedgerPurgeAfter).UnixMilli()
				deleted, err := a.db.PurgeLedger(ctx, cutoff)
				cancel()
				if err != nil {
					a.log.Warn("chip_ledger purge failed", "error", err.Error())
				} else if deleted > 0 {
					a.log.Info("chip_ledger purge complete", "rows", deleted)
				}
			case <-a.ledgerPurgeStop:
				return
			}
		}
	}()
}

// stopLedgerPurge stops the ticker and waits for a pass in flight.
func (a *App) stopLedgerPurge() {
	if a.ledgerPurgeStop == nil {
		return
	}
	close(a.ledgerPurgeStop)
	<-a.ledgerPurgeDone
	a.ledgerPurgeStop = nil
}

// Handler returns the root http.Handler (for httptest in integration tests).
func (a *App) Handler() http.Handler {
	return a.handler
}

// Rooms exposes the RoomManager (tests, tooling).
func (a *App) Rooms() *game.RoomManager { return a.rooms }

// Live exposes the (hooked) live store (tests, tooling).
func (a *App) Live() live.Store { return a.live }

// Restore is what rooms.Restore did at startup.
func (a *App) Restore() game.RestoreReport { return a.restore }

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
// (every socket gets "server shutting down"; each disconnect marks its seat
// and clears its presence); the tables — rooms.Suspend(ctx) when the store
// outlives this process (Redis, or an injected store: a final snapshot each,
// clocks stopped, pots left open for the next process to continue the hands
// with the seats held), rooms.Shutdown(ctx) with the in-process store (LIVE
// HANDS ARE SETTLED, pots paid out — the pre-Redis behaviour, and the
// rollback path when REDIS_URL is unset); http Shutdown(ctx); sio.Shutdown
// (socket goroutines); sockets.Close() (presence heartbeat); the reconciler
// stops; and the store, when New opened it, is closed LAST, after every user
// of it.
// cmd/gameplay bounds the whole thing with 8 s, as Node's
// setTimeout(process.exit(1), 8000). A second call is a no-op returning nil.
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
	// 2. The tables: suspended into a durable store, else destroyed (settled).
	var roomsErr error
	if a.live.Kind() != "memory" {
		roomsErr = a.rooms.Suspend(ctx)
	} else {
		roomsErr = a.rooms.Shutdown(ctx)
	}
	// 3. Stop accepting and drain the HTTP listener.
	var httpErr error
	if serving {
		httpErr = a.http.Shutdown(ctx)
	}
	// 4. Wait for the socket goroutines to wind down (bounded by ctx).
	sioErr := a.sio.Shutdown(ctx)
	// 5. Stop the presence heartbeat and the reconciler, then close the store
	// (when it is ours) — nothing above touches it any more.
	a.sockets.Close()
	a.stopReconciler()
	a.stopLedgerPurge()
	var liveErr error
	if a.ownsLive {
		liveErr = a.live.Close()
	}
	return errors.Join(roomsErr, httpErr, sioErr, liveErr)
}

// HealthResponse is GET /health. Field names are Node's; `node` carries the
// Go runtime version string ("go1.27.1") because the load-test tooling reads
// the key by name. Loop-lag fields report the scheduler-latency proxy
// described in ProcessHealth. `live` is new with the live-state store
// (LIVE_STATE_PLAN.md §Metrics) and appended after Node's keys.
type HealthResponse struct {
	OK     bool    `json:"ok"`
	Uptime float64 `json:"uptime"` // seconds, fractional
	game.Stats
	// Sockets is sio.ClientsCount(); null only if the socket server is absent.
	Sockets *int          `json:"sockets"`
	Process ProcessHealth `json:"process"`
	// DB is null when the pool is not open.
	DB *db.PoolStats `json:"db"`
	// Live is the live-state store's health.
	Live LiveHealth `json:"live"`
}

// LiveHealth is /health.live: the store's kind ("redis" | "memory"), whether
// it answered a Ping (and the table listing), and how many table snapshots
// it holds — after a restart that is what the next process would rebuild.
// There is no durable copy to lag behind: PostgreSQL holds no game state.
type LiveHealth struct {
	Kind   string `json:"kind"`
	OK     bool   `json:"ok"`
	Tables int    `json:"tables"`
}

// liveHealth probes the store within healthLiveTimeout.
func (a *App) liveHealth() LiveHealth {
	out := LiveHealth{Kind: a.live.Kind()}
	ctx, cancel := context.WithTimeout(context.Background(), healthLiveTimeout)
	defer cancel()
	if err := a.live.Ping(ctx); err != nil {
		return out
	}
	// A count, not a listing: /health is polled by uptime checks and the load
	// generator, and enumerating the store here cost one Redis round trip per
	// table (see live.Store.CountTables).
	n, err := a.live.CountTables(ctx)
	if err != nil {
		return out
	}
	out.OK = true
	out.Tables = n
	return out
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
	res.Live = a.liveHealth()
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
