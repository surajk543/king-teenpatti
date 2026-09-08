// Package app assembles the server (the port of server/src/index.js
// createServer + the entrypoint block): HTTP mux, static browser client,
// /health, /metrics, the REST API, the Socket.IO endpoint, the RoomManager,
// and orderly Start / Shutdown.
package app

import (
	"context"
	"log/slog"
	"net/http"
	"time"

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
}

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
//     /                      → http.FileServer(cfg.PublicDir) (the browser client)
//     wrapped in m.HTTPMiddleware(metricsPath, metrics.RouteLabelFor, mux)
//     when metrics are enabled; unknown /api paths → 404 JSON
//     {error:"not_found"} — Express returned its HTML 404, which nothing
//     depends on.
func New(opts Options) (*App, error) {
	panic("not ported: app.New")
}

// Handler returns the root http.Handler (for httptest in integration tests).
func (a *App) Handler() http.Handler {
	panic("not ported: (*App).Handler")
}

// Rooms exposes the RoomManager (tests, tooling).
func (a *App) Rooms() *game.RoomManager { return a.rooms }

// Start listens on cfg.Host:cfg.Port and serves until Shutdown. It logs
// `king-teenpatti server listening {url, env, welcomeChips, boot}` and
// returns http.ErrServerClosed after a clean Shutdown. ln == nil → listen
// from config; a test passes its own listener (port 0).
func (a *App) Start(ctx context.Context) error {
	panic("not ported: (*App).Start")
}

// Addr is the bound address once Start has listened ("" before).
func (a *App) Addr() string {
	panic("not ported: (*App).Addr")
}

// Shutdown is the entrypoint's `shutdown(signal)`, in this order: sio.Close()
// (every socket gets "server shutting down"); rooms.Shutdown(ctx) — LIVE
// HANDS ARE SETTLED (pots paid out) before anything else closes; http
// Shutdown(ctx). The caller then closes the DB. cmd/gameplay bounds the whole
// thing with 8 s, as Node's setTimeout(process.exit(1), 8000).
func (a *App) Shutdown(ctx context.Context) error {
	panic("not ported: (*App).Shutdown")
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
// process.cpuUsage and monitorEventLoopDelay; the Go equivalents:
//
//	rssMb        runtime/metrics "/memory/classes/total:bytes" (or gopsutil-free
//	             /proc/self/statm) → MiB, 1 dp
//	heapUsedMb   runtime.MemStats.HeapAlloc → MiB
//	heapTotalMb  runtime.MemStats.HeapSys → MiB
//	externalMb   runtime.MemStats.Sys - HeapSys → MiB (off-heap: stacks, GC metadata)
//	cpuPercent   share of one core used since the PREVIOUS /health call
//	             (syscall.Getrusage delta / wall delta × 100), 1 dp
//	loopLagP50Ms / P99Ms / MaxMs
//	             scheduler latency sampled by a background ticker: a 20 ms
//	             time.Ticker records (actual - expected) per tick into a
//	             reservoir reset on every /health read; ≈ 0–1 ms when idle
//	             (Node's read ~20 ms idle because of its resolution).
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
}

// Health serves GET /health (index.js app.get('/health')).
func (a *App) Health(w http.ResponseWriter, r *http.Request) {
	panic("not ported: (*App).Health")
}

// RoomsResponse is GET /api/rooms and lobby:list's ack body.
type RoomsResponse struct {
	Tables  []game.TableSummary `json:"tables"`
	Options game.LobbyOptions   `json:"options"`
}
