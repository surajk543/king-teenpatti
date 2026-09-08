package metrics

import (
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Options builds a Metrics.
type Options struct {
	// Prefix for process/runtime metrics (config.Metrics.Prefix, "game_server_").
	Prefix string
	// Registry to register into; nil → a fresh prometheus.NewRegistry(). The
	// app passes nil; tests may pass their own to inspect it.
	Registry *prometheus.Registry
	// StartedAt feeds process_uptime_seconds; zero → time.Now() at New.
	StartedAt time.Time
}

// Guard is the /metrics access policy (config.Metrics.Token / AllowIP).
type Guard struct {
	// Token, when non-empty, requires `Authorization: Bearer <Token>`
	// (else 401 text/plain "unauthorized").
	Token string
	// AllowIPs, when non-empty, requires the client IP (RemoteAddr host with
	// any "::ffff:" prefix stripped) to be listed (else 403 "forbidden"). The
	// IP check runs BEFORE the token check, as in Node.
	AllowIPs []string
}

// PoolStats is what the pool gauges read (db.DB.PoolStats).
type PoolStats struct {
	Total   int // pgxpool TotalConns
	Idle    int // IdleConns
	Waiting int // pgxpool has no waiting-count; report EmptyAcquireCount delta or 0 — see db.PoolStats
}

// RoomsSource is what the table gauges read at scrape time.
type RoomsSource interface {
	LiveTables() []*game.Table
}

// Metrics holds every collector. Fields are exported so the socket layer,
// db.Ledger and app can observe directly; nothing else is global.
type Metrics struct {
	Registry *prometheus.Registry
	prefix   string

	// Sockets
	ConnectedSockets     prometheus.Gauge
	ConnectedSocketsPeak prometheus.Gauge
	ConnectionsTotal     prometheus.Counter
	DisconnectionsTotal  *prometheus.CounterVec // reason
	ReconnectsTotal      *prometheus.CounterVec // kind
	SocketErrorsTotal    *prometheus.CounterVec // code
	SocketMessagesTotal  *prometheus.CounterVec // event
	SocketEmitsTotal     *prometheus.CounterVec // event
	SessionReplacedTotal prometheus.Counter

	// Game
	GamesStartedTotal   *prometheus.CounterVec // category
	GamesCompletedTotal *prometheus.CounterVec // category, reason
	GamesAbandonedTotal *prometheus.CounterVec // category
	MovesTotal          *prometheus.CounterVec // action
	InvalidMovesTotal   *prometheus.CounterVec // code
	TurnTimeoutsTotal   prometheus.Counter
	KicksTotal          *prometheus.CounterVec // reason
	ChatMessagesTotal   prometheus.Counter
	PotSettledTotal     prometheus.Counter

	// Latency
	MoveDuration          *prometheus.HistogramVec // action
	CreationDuration      prometheus.Histogram
	JoinDuration          *prometheus.HistogramVec // route
	StateUpdateDuration   prometheus.Histogram
	HandStartDuration     prometheus.Histogram
	SettlementDuration    prometheus.Histogram
	DBTransactionDuration *prometheus.HistogramVec // op
	DBTransactionErrors   *prometheus.CounterVec   // op, code

	// HTTP
	HTTPRequestsTotal   *prometheus.CounterVec   // method, route, status_code
	HTTPRequestDuration *prometheus.HistogramVec // method, route, status_code

	rooms RoomsSource
	pool  func() PoolStats
}

// New creates and registers every collector (Node: module load). Registers:
// the default label {service="king-teenpatti"} (via prometheus.WrapRegistererWith
// on the registry — every series, including process/go ones, carries it);
// the process collector with Namespace = strings.TrimSuffix(prefix, "_");
// the Go collector wrapped with WrapRegistererWithPrefix(prefix); the custom
// uptime gauge; the table gauges (GaugeFunc reading BindRooms' source, 0 until
// bound); the pool gauges (reading BindPool's func, 0 until bound); and all
// the fields above with the exact help strings from metrics/index.js.
func New(opts Options) *Metrics {
	panic("not ported: metrics.New")
}

// BindRooms gives the table gauges their source (Node bindRooms). Before it
// is called they report 0.
func (m *Metrics) BindRooms(rooms RoomsSource) {
	panic("not ported: (*Metrics).BindRooms")
}

// BindPool gives the pool gauges their source (Node bindPool). Errors/panics
// from fn are swallowed and read as 0.
func (m *Metrics) BindPool(fn func() PoolStats) {
	panic("not ported: (*Metrics).BindPool")
}

// Handler is the /metrics endpoint with the Guard applied, wrapping
// promhttp.HandlerFor(m.Registry, promhttp.HandlerOpts{}).
func (m *Metrics) Handler(guard Guard) http.Handler {
	panic("not ported: (*Metrics).Handler")
}

// HTTPMiddleware counts and times every response by (method, route pattern,
// status_code) — Node httpMetricsMiddleware. It MUST run outside body
// parsing, and skips requests whose path equals metricsPath.
//
// routeLabel decides the `route` label and MUST return a PATTERN, never the
// raw URL: with Go 1.22+ ServeMux the app passes a func that reads
// r.Pattern after routing (strip the "METHOD " prefix and the host, e.g.
// "POST /api/auth/login" → "/api/auth/login"); when no API pattern matched:
// RouteStatic for "/" or a path ending in a 2–5 character extension, else
// RouteUnmatched. Method label is the method if in HTTPMethods else
// MethodOther.
func (m *Metrics) HTTPMiddleware(metricsPath string, routeLabel func(r *http.Request) string, next http.Handler) http.Handler {
	panic("not ported: (*Metrics).HTTPMiddleware")
}

// RouteLabelFor is the default routeLabel for a Go 1.22 ServeMux: uses
// r.Pattern when set (pattern "GET /health" → "/health"; a catch-all "/" →
// RouteStatic), else RouteStatic / RouteUnmatched by the extension rule.
func RouteLabelFor(r *http.Request) string {
	panic("not ported: metrics.RouteLabelFor")
}

// SafeLabel folds a value outside `known` into fallback (Node safeLabel).
// Callers pass OtherLabel as the fallback unless Node used another.
func SafeLabel(value string, known map[string]struct{}, fallback string) string {
	if _, ok := known[value]; ok {
		return value
	}
	return fallback
}

// Timed runs fn and observes its duration in seconds into obs (Node
// timed/timedSync), observing even when fn returns an error. Use
// h.WithLabelValues(...) to obtain the Observer for a vec.
func Timed(obs prometheus.Observer, fn func() error) error {
	started := time.Now()
	defer func() { obs.Observe(time.Since(started).Seconds()) }()
	return fn()
}

// Observe records a duration into an Observer in seconds.
func Observe(obs prometheus.Observer, d time.Duration) {
	obs.Observe(d.Seconds())
}
