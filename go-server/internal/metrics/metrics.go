package metrics

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/common/expfmt"

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
	// headers is the catalogue of labelled families (vectors and the tables
	// collector). prom-client prints "# HELP"/"# TYPE" for a registered
	// metric even before it has a series; client_golang drops such families
	// from Gather(), so Handler appends these headers for the missing ones.
	headers []familyHeader

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

	// mu guards the two late-bound sources; the scrape-time collectors read
	// them under it, so BindRooms/BindPool may be called while a scrape runs.
	mu    sync.RWMutex
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
	reg := opts.Registry
	if reg == nil {
		reg = prometheus.NewRegistry()
	}
	prefix := opts.Prefix
	if prefix == "" {
		prefix = "game_server_"
	}
	startedAt := opts.StartedAt
	if startedAt.IsZero() {
		startedAt = time.Now()
	}

	m := &Metrics{Registry: reg, prefix: prefix}

	// Node: registry.setDefaultLabels({ service: 'king-teenpatti' }) — every
	// sample, the runtime ones included, carries the label. WrapRegistererWith
	// adds it as a const label to everything registered through `svc`.
	svc := prometheus.WrapRegistererWith(prometheus.Labels{ServiceLabelName: ServiceLabelValue}, reg)

	// ---------------------------------------------------------------- defaults
	// Node: client.collectDefaultMetrics({ prefix }). The process family keeps
	// the same names (game_server_process_cpu_seconds_total, …_open_fds,
	// …_resident_memory_bytes, …_start_time_seconds); the Node-runtime family
	// (game_server_nodejs_*) has no Go equivalent and is replaced by the Go
	// runtime collector under game_server_go_* (DECISIONS.md §6).
	svc.MustRegister(collectors.NewProcessCollector(collectors.ProcessCollectorOpts{
		Namespace: strings.TrimSuffix(prefix, "_"),
	}))
	prometheus.WrapRegistererWithPrefix(prefix, svc).MustRegister(collectors.NewGoCollector(
		collectors.WithGoCollectorRuntimeMetrics(collectors.MetricsGC, collectors.MetricsScheduler),
	))
	svc.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: prefix + NameProcessUptimeSeconds,
		Help: "Seconds since the process started.",
	}, func() float64 { return time.Since(startedAt).Seconds() }))
	// prom-client splits CPU into user and system counters
	// (process_cpu_user_seconds_total / process_cpu_system_seconds_total) next
	// to process_cpu_seconds_total; the Go process collector only has the
	// total, so the two halves come from getrusage (0 where unsupported).
	svc.MustRegister(prometheus.NewCounterFunc(prometheus.CounterOpts{
		Name: prefix + "process_cpu_user_seconds_total",
		Help: "Total user CPU time spent in seconds.",
	}, func() float64 { user, _ := rusageCPU(); return user }))
	svc.MustRegister(prometheus.NewCounterFunc(prometheus.CounterOpts{
		Name: prefix + "process_cpu_system_seconds_total",
		Help: "Total system CPU time spent in seconds.",
	}, func() float64 { _, system := rusageCPU(); return system }))

	// ----------------------------------------------------------------- sockets
	m.ConnectedSockets = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: NameConnectedSockets,
		Help: "Socket.IO connections open right now.",
	})
	m.ConnectedSocketsPeak = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: NameConnectedSocketsPeak,
		Help: "Highest number of Socket.IO connections open at once since the process started.",
	})
	m.ConnectionsTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: NameConnectionsTotal,
		Help: "Socket.IO connections accepted since the process started.",
	})
	m.DisconnectionsTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameDisconnectionsTotal,
		Help: "Socket.IO disconnections since the process started, by Socket.IO reason.",
	}, []string{"reason"})
	m.ReconnectsTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameReconnectsTotal,
		Help: "Connections from a player whose seat was still being held after a drop, or who was offered their table back.",
	}, []string{"kind"})
	m.SocketErrorsTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameSocketErrorsTotal,
		Help: "Requests refused on the socket, by error code.",
	}, []string{"code"})
	m.SocketMessagesTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameSocketMessagesTotal,
		Help: "Messages received from clients, by event name.",
	}, []string{"event"})
	m.SocketEmitsTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameSocketEmitsTotal,
		Help: "Messages sent to clients, by event name (a room broadcast counts once).",
	}, []string{"event"})
	m.SessionReplacedTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: NameSessionReplacedTotal,
		Help: "Times a second sign-in displaced an existing socket for the same account.",
	})
	svc.MustRegister(m.ConnectedSockets, m.ConnectedSocketsPeak, m.ConnectionsTotal, m.DisconnectionsTotal,
		m.ReconnectsTotal, m.SocketErrorsTotal, m.SocketMessagesTotal, m.SocketEmitsTotal, m.SessionReplacedTotal)

	// -------------------------------------------------------------------- game
	// Scrape-time gauges over the live RoomManager (Node collect() callbacks);
	// they read only the Table's lock-free getters and report 0 until bound.
	svc.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: NamePlayersOnline,
		Help: "Players seated at a table right now.",
	}, func() float64 {
		sum := 0
		for _, t := range m.liveTables() {
			sum += t.PlayerCount()
		}
		return float64(sum)
	}))
	svc.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: NameActiveGames,
		Help: "Tables with a hand in progress (betting or showdown).",
	}, func() float64 {
		n := 0
		for _, t := range m.liveTables() {
			if t.HasHand() {
				n++
			}
		}
		return float64(n)
	}))
	svc.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: NameWaitingGames,
		Help: "Tables that exist but have no hand in progress (waiting for players or between hands).",
	}, func() float64 {
		n := 0
		for _, t := range m.liveTables() {
			if !t.HasHand() {
				n++
			}
		}
		return float64(n)
	}))
	svc.MustRegister(&tablesCollector{m: m, desc: prometheus.NewDesc(
		NameTables, "Open tables by category and stake.", []string{"category", "stake"}, nil,
	)})
	m.headers = append(m.headers, familyHeader{name: NameTables, help: "Open tables by category and stake.", typ: "gauge"})

	m.GamesStartedTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameGamesStartedTotal,
		Help: "Hands dealt since the process started.",
	}, []string{"category"})
	m.GamesCompletedTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameGamesCompletedTotal,
		Help: "Hands that ended with a winner, by how they ended.",
	}, []string{"category", "reason"})
	m.GamesAbandonedTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameGamesAbandonedTotal,
		Help: "Hands that ended because every player left, or a table destroyed mid-hand.",
	}, []string{"category"})
	m.MovesTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameMovesTotal,
		Help: "Player actions accepted by the rules engine, by action.",
	}, []string{"action"})
	m.InvalidMovesTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameInvalidMovesTotal,
		Help: "Player actions refused by the rules engine, by refusal code.",
	}, []string{"code"})
	m.TurnTimeoutsTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: NameTurnTimeoutsTotal,
		Help: "Turns that ran out the clock and were packed automatically.",
	})
	m.KicksTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameKicksTotal,
		Help: "Players removed from a table by the server, by reason.",
	}, []string{"reason"})
	m.ChatMessagesTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: NameChatMessagesTotal,
		Help: "Chat messages posted to a table.",
	})
	m.PotSettledTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: NamePotSettledTotal,
		Help: "Chips paid out to hand winners since the process started.",
	})
	svc.MustRegister(m.GamesStartedTotal, m.GamesCompletedTotal, m.GamesAbandonedTotal, m.MovesTotal,
		m.InvalidMovesTotal, m.TurnTimeoutsTotal, m.KicksTotal, m.ChatMessagesTotal, m.PotSettledTotal)

	// ----------------------------------------------------------------- latency
	m.MoveDuration = m.histogramVec(prometheus.HistogramOpts{
		Name:    NameMoveDuration,
		Help:    "Time to validate a move, commit it to the database and update the table, by action.",
		Buckets: LatencyBuckets,
	}, []string{"action"})
	m.CreationDuration = prometheus.NewHistogram(prometheus.HistogramOpts{
		Name:    NameCreationDuration,
		Help:    "Time to create a table (lobby quick-join that opened a new one, or a private room).",
		Buckets: LatencyBuckets,
	})
	m.JoinDuration = m.histogramVec(prometheus.HistogramOpts{
		Name:    NameJoinDuration,
		Help:    "Time from a join request to the player being seated and sent the table, by entry route.",
		Buckets: LatencyBuckets,
	}, []string{"route"})
	m.StateUpdateDuration = prometheus.NewHistogram(prometheus.HistogramOpts{
		Name:    NameStateUpdateDuration,
		Help:    "Time to serialise and send one table state change to every viewer at the table.",
		Buckets: LatencyBuckets,
	})
	m.HandStartDuration = prometheus.NewHistogram(prometheus.HistogramOpts{
		Name:    NameHandStartDuration,
		Help:    "Time to collect the boot and deal a hand (one database transaction).",
		Buckets: LatencyBuckets,
	})
	m.SettlementDuration = prometheus.NewHistogram(prometheus.HistogramOpts{
		Name:    NameSettlementDuration,
		Help:    "Time to settle a finished hand in the database.",
		Buckets: LatencyBuckets,
	})
	m.DBTransactionDuration = m.histogramVec(prometheus.HistogramOpts{
		Name:    NameDBTransactionDuration,
		Help:    "Duration of the ledger transactions that move chips, by operation.",
		Buckets: LatencyBuckets,
	}, []string{"op"})
	m.DBTransactionErrors = m.counterVec(prometheus.CounterOpts{
		Name: NameDBTransactionErrors,
		Help: "Ledger transactions that rolled back, by operation and error code.",
	}, []string{"op", "code"})
	svc.MustRegister(m.MoveDuration, m.CreationDuration, m.JoinDuration, m.StateUpdateDuration,
		m.HandStartDuration, m.SettlementDuration, m.DBTransactionDuration, m.DBTransactionErrors)

	// ---------------------------------------------------------- database pool
	// Everything deeper than the pool counts is postgres_exporter's job.
	svc.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: NameDBPoolConnections,
		Help: "Connections held by the pg pool.",
	}, func() float64 { return float64(m.poolStats().Total) }))
	svc.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: NameDBPoolIdleConnections,
		Help: "Pool connections not in use.",
	}, func() float64 { return float64(m.poolStats().Idle) }))
	svc.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: NameDBPoolWaitingRequests,
		Help: "Queries waiting for a pool connection.",
	}, func() float64 { return float64(m.poolStats().Waiting) }))

	// -------------------------------------------------------------------- HTTP
	m.HTTPRequestsTotal = m.counterVec(prometheus.CounterOpts{
		Name: NameHTTPRequestsTotal,
		Help: "HTTP requests served, by method, route pattern and status code.",
	}, []string{"method", "route", "status_code"})
	m.HTTPRequestDuration = m.histogramVec(prometheus.HistogramOpts{
		Name:    NameHTTPRequestDuration,
		Help:    "HTTP request duration, by method, route pattern and status code.",
		Buckets: LatencyBuckets,
	}, []string{"method", "route", "status_code"})
	svc.MustRegister(m.HTTPRequestsTotal, m.HTTPRequestDuration)

	return m
}

// BindRooms gives the table gauges their source (Node bindRooms). Before it
// is called they report 0.
func (m *Metrics) BindRooms(rooms RoomsSource) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.rooms = rooms
}

// BindPool gives the pool gauges their source (Node bindPool). Errors/panics
// from fn are swallowed and read as 0.
func (m *Metrics) BindPool(fn func() PoolStats) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.pool = fn
}

// liveTables is Node's liveTables(): every table, or none before BindRooms.
func (m *Metrics) liveTables() []*game.Table {
	m.mu.RLock()
	rooms := m.rooms
	m.mu.RUnlock()
	if rooms == nil {
		return nil
	}
	return rooms.LiveTables()
}

// poolStats is Node's poolStat(): the bound source's figures, or zeros when
// nothing is bound or the source fails.
func (m *Metrics) poolStats() (stats PoolStats) {
	m.mu.RLock()
	fn := m.pool
	m.mu.RUnlock()
	if fn == nil {
		return PoolStats{}
	}
	defer func() {
		if recover() != nil {
			stats = PoolStats{}
		}
	}()
	return fn()
}

// tablesCollector is game_tables{category,stake}: Node reset the gauge and
// re-counted every table on each scrape, so a category/stake pair with no
// table disappears from the exposition rather than reading 0. A custom
// Collector emitting one const metric per live pair has exactly that shape.
// `category` is the raw table category (always seen/blind) and `stake` the
// boot as a decimal string, as in Node — neither goes through SafeLabel.
type tablesCollector struct {
	m    *Metrics
	desc *prometheus.Desc
}

func (c *tablesCollector) Describe(ch chan<- *prometheus.Desc) { ch <- c.desc }

func (c *tablesCollector) Collect(ch chan<- prometheus.Metric) {
	type key struct{ category, stake string }
	counts := map[key]int{}
	order := []key{}
	for _, t := range c.m.liveTables() {
		k := key{string(t.Category()), strconv.FormatInt(t.BootAmount(), 10)}
		if _, seen := counts[k]; !seen {
			order = append(order, k)
		}
		counts[k]++
	}
	for _, k := range order {
		ch <- prometheus.MustNewConstMetric(c.desc, prometheus.GaugeValue, float64(counts[k]), k.category, k.stake)
	}
}

// Handler is the /metrics endpoint with the Guard applied, wrapping
// promhttp.HandlerFor(m.Registry, promhttp.HandlerOpts{}).
//
// Check order is Node's metricsHandler(): the IP allow-list first (403
// text/plain "forbidden"), then the bearer token — an exact, case-sensitive
// comparison against "Bearer <token>" (401 text/plain "unauthorized"). With
// neither configured the endpoint is open. The IP is the raw TCP peer
// (RemoteAddr), never X-Forwarded-For, exactly like Express with `trust
// proxy` off; an IPv4-mapped IPv6 peer (::ffff:10.0.0.5) is compared as
// 10.0.0.5.
func (m *Metrics) Handler(guard Guard) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(guard.AllowIPs) > 0 {
			ip := peerIP(r.RemoteAddr)
			allowed := false
			for _, candidate := range guard.AllowIPs {
				if candidate == ip {
					allowed = true
					break
				}
			}
			if !allowed {
				w.Header().Set("Content-Type", "text/plain; charset=utf-8")
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte("forbidden"))
				return
			}
		}
		if guard.Token != "" {
			if r.Header.Get("Authorization") != "Bearer "+guard.Token {
				w.Header().Set("Content-Type", "text/plain; charset=utf-8")
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = w.Write([]byte("unauthorized"))
				return
			}
		}
		m.writeExposition(w)
	})
}

// familyHeader is what prom-client prints for a registered metric with no
// series yet: its "# HELP" and "# TYPE" lines.
type familyHeader struct {
	name, help, typ string
}

func (m *Metrics) counterVec(opts prometheus.CounterOpts, labels []string) *prometheus.CounterVec {
	m.headers = append(m.headers, familyHeader{name: opts.Name, help: opts.Help, typ: "counter"})
	return prometheus.NewCounterVec(opts, labels)
}

func (m *Metrics) histogramVec(opts prometheus.HistogramOpts, labels []string) *prometheus.HistogramVec {
	m.headers = append(m.headers, familyHeader{name: opts.Name, help: opts.Help, typ: "histogram"})
	return prometheus.NewHistogramVec(opts, labels)
}

// writeExposition renders the registry in the Prometheus text format (the
// only format Node served) and then appends header-only entries for every
// labelled family that has no series yet, so the exposition lists the whole
// catalogue from the first scrape exactly as prom-client's did.
func (m *Metrics) writeExposition(w http.ResponseWriter) {
	families, err := m.Registry.Gather()
	if err != nil && len(families) == 0 {
		http.Error(w, "An error has occurred while serving metrics:\n\n"+err.Error(), http.StatusInternalServerError)
		return
	}
	format := expfmt.NewFormat(expfmt.TypeTextPlain)
	w.Header().Set("Content-Type", string(format))
	var buf bytes.Buffer
	enc := expfmt.NewEncoder(&buf, format)
	present := make(map[string]bool, len(families))
	for _, family := range families {
		present[family.GetName()] = true
		if err := enc.Encode(family); err != nil {
			http.Error(w, "An error has occurred while serving metrics:\n\n"+err.Error(), http.StatusInternalServerError)
			return
		}
	}
	for _, h := range m.headers {
		if present[h.name] {
			continue
		}
		fmt.Fprintf(&buf, "# HELP %s %s\n# TYPE %s %s\n", h.name, escapeHelp(h.help), h.name, h.typ)
	}
	_, _ = w.Write(buf.Bytes())
}

// escapeHelp applies the text-format escaping for HELP lines (backslash and
// newline), matching expfmt.
func escapeHelp(help string) string {
	help = strings.ReplaceAll(help, "\\", "\\\\")
	return strings.ReplaceAll(help, "\n", "\\n")
}

// peerIP is Node's `req.ip` with a leading "::ffff:" stripped, read from Go's
// "host:port" RemoteAddr.
func peerIP(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	host = strings.TrimPrefix(host, "[")
	host = strings.TrimSuffix(host, "]")
	return strings.TrimPrefix(host, "::ffff:")
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
//
// Node observed on the response `finish` event; here the observation is
// taken when next returns. A hijacked connection (a WebSocket upgrade) is
// not counted — Node never saw Socket.IO's traffic in Express either.
func (m *Metrics) HTTPMiddleware(metricsPath string, routeLabel func(r *http.Request) string, next http.Handler) http.Handler {
	if routeLabel == nil {
		routeLabel = RouteLabelFor
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == metricsPath {
			next.ServeHTTP(w, r)
			return
		}
		started := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		if sw.hijacked {
			return
		}
		seconds := time.Since(started).Seconds()
		method := SafeLabel(r.Method, HTTPMethods, MethodOther)
		route := routeLabel(r)
		status := strconv.Itoa(sw.status)
		m.HTTPRequestsTotal.WithLabelValues(method, route, status).Inc()
		m.HTTPRequestDuration.WithLabelValues(method, route, status).Observe(seconds)
	})
}

// statusWriter remembers the status code a handler wrote (Node
// res.statusCode at `finish`). It forwards Flush and Hijack so streaming and
// WebSocket handlers behind the middleware keep working.
type statusWriter struct {
	http.ResponseWriter
	status   int
	wrote    bool
	hijacked bool
}

func (w *statusWriter) WriteHeader(status int) {
	if !w.wrote {
		w.status = status
		w.wrote = true
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if !w.wrote {
		w.wrote = true
	}
	return w.ResponseWriter.Write(b)
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := w.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("metrics: underlying ResponseWriter does not implement http.Hijacker")
	}
	conn, rw, err := h.Hijack()
	if err == nil {
		w.hijacked = true
	}
	return conn, rw, err
}

// staticExt is Node's `/\.[a-z0-9]{2,5}$/i` — a path that looks like a file.
var staticExt = regexp.MustCompile(`\.[a-zA-Z0-9]{2,5}$`)

// RouteLabelFor is the default routeLabel for a Go 1.22 ServeMux: uses
// r.Pattern when set (pattern "GET /health" → "/health"; a subtree pattern
// ending in "/" — the static catch-all "/" or the "/api/" JSON 404 — is not a
// route match and falls to the extension rule, exactly as Express requests
// that reached no router did), else RouteStatic / RouteUnmatched by the
// extension rule: RouteStatic for "/" or a path ending in a 2–5 character
// extension, RouteUnmatched for anything else.
func RouteLabelFor(r *http.Request) string {
	if pat := patternPath(r.Pattern); pat != "" && !strings.HasSuffix(pat, "/") {
		return pat
	}
	path := r.URL.Path
	if path == "/" || staticExt.MatchString(path) {
		return RouteStatic
	}
	return RouteUnmatched
}

// patternPath strips the optional "METHOD " prefix and host from a ServeMux
// pattern, leaving its path ("POST example.com/api/x" → "/api/x"). "/{$}"
// (exact root) becomes "/".
func patternPath(pattern string) string {
	if pattern == "" {
		return ""
	}
	if i := strings.IndexByte(pattern, ' '); i >= 0 {
		pattern = strings.TrimLeft(pattern[i+1:], " ")
	}
	if j := strings.IndexByte(pattern, '/'); j > 0 {
		pattern = pattern[j:]
	}
	if pattern == "/{$}" {
		return "/"
	}
	return pattern
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
