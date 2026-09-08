package app

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

const metricsToken = "metrics-test-token"

// publicDir builds a stand-in for server/public: index.html, a stylesheet, a
// profile picture, a dotfile and an index-less directory.
func publicDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.WriteFile(filepath.Join(dir, "index.html"), []byte("<!doctype html><title>King Teen Patti</title>"), 0o644))
	must(os.WriteFile(filepath.Join(dir, "style.css"), []byte("body{margin:0}"), 0o644))
	must(os.WriteFile(filepath.Join(dir, ".env"), []byte("SECRET=1"), 0o644))
	must(os.MkdirAll(filepath.Join(dir, "profiles"), 0o755))
	must(os.WriteFile(filepath.Join(dir, "profiles", "bear.svg"), []byte(`<svg xmlns="http://www.w3.org/2000/svg"/>`), 0o644))
	must(os.WriteFile(filepath.Join(dir, "profiles", "NOTICE.txt"), []byte("Noto Emoji, Apache 2.0"), 0o644))
	return dir
}

// testConfig is the process suites' environment: unrestricted stakes, fake
// providers, short timers, a bearer on /metrics, an ephemeral port.
func testConfig(t *testing.T, public string) *config.Config {
	t.Helper()
	cfg := config.Defaults()
	cfg.Env = config.EnvTest
	cfg.Host = "127.0.0.1"
	cfg.Port = 0
	cfg.AllowFakeProviders = true
	cfg.JWT.Secret = "app-test-secret"
	cfg.Game.TableStakes = []int64{}
	cfg.Game.LobbyTables = []config.LobbyTable{}
	cfg.Game.TurnTimeout = 4 * time.Second
	cfg.Game.NextHandDelay = 150 * time.Millisecond
	cfg.Game.ReconnectGrace = 400 * time.Millisecond
	cfg.Metrics.Token = metricsToken
	cfg.PublicDir = public
	return cfg
}

// newApp builds an App on a throwaway schema; it skips when Postgres is
// unreachable and shuts the app down in Cleanup.
func newApp(t *testing.T, mutate func(*config.Config)) (*App, *db.DB) {
	t.Helper()
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	if mutate != nil {
		mutate(cfg)
	}
	a, err := New(Options{Config: cfg, DB: database, Logger: util.NewLogger("error", io.Discard)})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		if err := a.Shutdown(ctx); err != nil {
			t.Errorf("Shutdown: %v", err)
		}
	})
	return a, database
}

func get(t *testing.T, h http.Handler, method, target string, mutate func(*http.Request)) (*http.Response, []byte) {
	t.Helper()
	req := httptest.NewRequest(method, target, nil)
	if mutate != nil {
		mutate(req)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	res := rec.Result()
	body, _ := io.ReadAll(res.Body)
	return res, body
}

// ------------------------------------------------------------------- /health

func TestHealthHasNodesShape(t *testing.T) {
	a, _ := newApp(t, nil)
	res, body := get(t, a.Handler(), http.MethodGet, "/health", nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status %d: %s", res.StatusCode, body)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("content-type %q", ct)
	}

	// Key set and order (spec-auth-http §4.10: ok, uptime, tables, players,
	// activeHands, sockets, process, db).
	keyOrder := regexp.MustCompile(`^\{"ok":true,"uptime":[0-9.e+-]+,"tables":\d+,"players":\d+,"activeHands":\d+,"sockets":\d+,"process":\{.*\},"db":\{"total":\d+,"idle":\d+,"waiting":\d+\}\}$`)
	if !keyOrder.Match(body) {
		t.Fatalf("unexpected /health body: %s", body)
	}

	var h struct {
		OK          bool    `json:"ok"`
		Uptime      float64 `json:"uptime"`
		Tables      int     `json:"tables"`
		Players     int     `json:"players"`
		ActiveHands int     `json:"activeHands"`
		Sockets     *int    `json:"sockets"`
		Process     map[string]json.RawMessage
		DB          *struct{ Total, Idle, Waiting int } `json:"db"`
	}
	if err := json.Unmarshal(body, &h); err != nil {
		t.Fatal(err)
	}
	if !h.OK || h.Uptime < 0 || h.Sockets == nil || *h.Sockets != 0 || h.DB == nil {
		t.Fatalf("fields: %+v", h)
	}
	if h.DB.Total < 1 {
		t.Errorf("db.total %d, want ≥ 1 (bootstrap connection)", h.DB.Total)
	}
	for _, key := range []string{"pid", "node", "rssMb", "heapUsedMb", "heapTotalMb", "externalMb", "cpuPercent",
		"loopLagP50Ms", "loopLagP99Ms", "loopLagMaxMs", "goroutines", "numCpu", "gomaxprocs"} {
		if _, ok := h.Process[key]; !ok {
			t.Errorf("process.%s missing", key)
		}
	}
	var node string
	_ = json.Unmarshal(h.Process["node"], &node)
	if !strings.HasPrefix(node, "go") {
		t.Errorf("process.node %q", node)
	}
	var rss, heapUsed, heapTotal, cpu float64
	_ = json.Unmarshal(h.Process["rssMb"], &rss)
	_ = json.Unmarshal(h.Process["heapUsedMb"], &heapUsed)
	_ = json.Unmarshal(h.Process["heapTotalMb"], &heapTotal)
	_ = json.Unmarshal(h.Process["cpuPercent"], &cpu)
	if rss <= 0 || heapUsed <= 0 || heapTotal < heapUsed || cpu < 0 {
		t.Errorf("vitals rss=%v heapUsed=%v heapTotal=%v cpu=%v", rss, heapUsed, heapTotal, cpu)
	}
	// Second call: the CPU/lag window is re-marked; still well-formed.
	res, body = get(t, a.Handler(), http.MethodGet, "/health", nil)
	if res.StatusCode != http.StatusOK || !keyOrder.Match(body) {
		t.Fatalf("second /health: %d %s", res.StatusCode, body)
	}
}

func TestHistogramPercentiles(t *testing.T) {
	buckets := []float64{0, 0.001, 0.002, 0.004, 1e300, 1e301}
	// Replace the last upper bound with +Inf as runtime/metrics does.
	buckets[len(buckets)-1] = inf()
	counts := []uint64{10, 5, 3, 1, 1}
	p50, p99, max := histogramPercentiles(buckets, counts)
	if p50 != 0.001 { // 10 of 20 fall in [0, 0.001)
		t.Errorf("p50 %v", p50)
	}
	if p99 != 1e300 { // the 20th sample sits in the open-ended bucket → lower bound
		t.Errorf("p99 %v", p99)
	}
	if max != 1e300 {
		t.Errorf("max %v", max)
	}
	if a, b, c := histogramPercentiles(buckets, []uint64{0, 0, 0, 0, 0}); a != 0 || b != 0 || c != 0 {
		t.Errorf("empty histogram %v %v %v", a, b, c)
	}
	if mb(1048576*3+524288) != 3.5 || ms(0.02049) != 20.5 || round1(2.25) != 2.3 {
		t.Errorf("rounding helpers")
	}
}

func inf() float64 {
	var zero float64
	return 1 / zero
}

// -------------------------------------------------------------------- static

func TestStaticBrowserClient(t *testing.T) {
	a, _ := newApp(t, nil)
	h := a.Handler()

	res, body := get(t, h, http.MethodGet, "/", nil)
	if res.StatusCode != http.StatusOK || !strings.Contains(string(body), "King Teen Patti") {
		t.Fatalf("index: %d %s", res.StatusCode, body)
	}
	if ct := res.Header.Get("Content-Type"); ct != "text/html; charset=UTF-8" {
		t.Errorf("index content-type %q", ct)
	}
	if cc := res.Header.Get("Cache-Control"); cc != "public, max-age=0" {
		t.Errorf("cache-control %q", cc)
	}
	if res.Header.Get("ETag") == "" || res.Header.Get("Last-Modified") == "" {
		t.Errorf("missing validators: %v", res.Header)
	}

	res, body = get(t, h, http.MethodGet, "/profiles/bear.svg", nil)
	if res.StatusCode != http.StatusOK || !strings.HasPrefix(string(body), "<svg") {
		t.Fatalf("svg: %d %s", res.StatusCode, body)
	}
	if ct := res.Header.Get("Content-Type"); ct != "image/svg+xml" {
		t.Errorf("svg content-type %q", ct)
	}
	res, _ = get(t, h, http.MethodGet, "/style.css", nil)
	if ct := res.Header.Get("Content-Type"); res.StatusCode != http.StatusOK || ct != "text/css; charset=UTF-8" {
		t.Errorf("css: %d %q", res.StatusCode, ct)
	}
	res, _ = get(t, h, http.MethodGet, "/profiles/NOTICE.txt", nil)
	if ct := res.Header.Get("Content-Type"); res.StatusCode != http.StatusOK || ct != "text/plain; charset=UTF-8" {
		t.Errorf("txt: %d %q", res.StatusCode, ct)
	}

	// Conditional request against the weak ETag → 304.
	res, _ = get(t, h, http.MethodGet, "/", nil)
	etag := res.Header.Get("ETag")
	res, _ = get(t, h, http.MethodGet, "/", func(r *http.Request) { r.Header.Set("If-None-Match", etag) })
	if res.StatusCode != http.StatusNotModified {
		t.Errorf("conditional: %d", res.StatusCode)
	}

	// Dotfiles hidden; directory redirect; directory without index; wrong method.
	res, _ = get(t, h, http.MethodGet, "/.env", nil)
	if res.StatusCode != http.StatusNotFound {
		t.Errorf("dotfile: %d", res.StatusCode)
	}
	res, _ = get(t, h, http.MethodGet, "/profiles", nil)
	if res.StatusCode != http.StatusMovedPermanently || res.Header.Get("Location") != "/profiles/" {
		t.Errorf("dir redirect: %d %q", res.StatusCode, res.Header.Get("Location"))
	}
	res, _ = get(t, h, http.MethodGet, "/profiles/", nil)
	if res.StatusCode != http.StatusNotFound {
		t.Errorf("dir without index: %d", res.StatusCode)
	}
	res, body = get(t, h, http.MethodPost, "/index.html", nil)
	if res.StatusCode != http.StatusNotFound || string(body) != "Cannot POST /index.html" {
		t.Errorf("POST static: %d %s", res.StatusCode, body)
	}
	res, body = get(t, h, http.MethodGet, "/nothing-here-123", nil)
	if res.StatusCode != http.StatusNotFound || !strings.HasPrefix(res.Header.Get("Content-Type"), "text/plain") || string(body) != "Cannot GET /nothing-here-123" {
		t.Errorf("miss: %d %q %s", res.StatusCode, res.Header.Get("Content-Type"), body)
	}
	res, _ = get(t, h, http.MethodHead, "/", nil)
	if res.StatusCode != http.StatusOK {
		t.Errorf("HEAD index: %d", res.StatusCode)
	}
}

func TestSocketIOClientBundleIsServed(t *testing.T) {
	a, _ := newApp(t, nil)
	for _, p := range []string{"/socket.io/socket.io.js", "/socket.io/socket.io.min.js"} {
		res, body := get(t, a.Handler(), http.MethodGet, p, nil)
		if res.StatusCode != http.StatusOK {
			t.Fatalf("%s: %d", p, res.StatusCode)
		}
		if ct := res.Header.Get("Content-Type"); ct != "application/javascript; charset=UTF-8" {
			t.Errorf("%s content-type %q", p, ct)
		}
		if !strings.HasPrefix(string(body), "/*!\n * Socket.IO v4.") || !strings.Contains(string(body), "Released under the MIT License") {
			t.Errorf("%s does not look like the socket.io client bundle: %.80s", p, body)
		}
		if len(body) != len(socketIOClient) {
			t.Errorf("%s: %d bytes, embedded %d", p, len(body), len(socketIOClient))
		}
	}
	// The socket.io handshake path itself is routed to the sio server, not to
	// the static handler: a polling request is refused the Engine.IO way.
	res, body := get(t, a.Handler(), http.MethodGet, "/socket.io/?EIO=4&transport=polling", nil)
	if res.StatusCode != http.StatusBadRequest || !strings.Contains(string(body), `"code":0`) {
		t.Errorf("polling handshake: %d %s", res.StatusCode, body)
	}
}

// ----------------------------------------------------------------------- API

func TestUnknownAPIPathIsJSON404(t *testing.T) {
	a, _ := newApp(t, nil)
	h := a.Handler()
	res, body := get(t, h, http.MethodGet, "/api/unknown", nil)
	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("status %d", res.StatusCode)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("content-type %q", ct)
	}
	var e struct{ Error, Message string }
	if err := json.Unmarshal(body, &e); err != nil || e.Error != "not_found" || e.Message != "Cannot GET /api/unknown" {
		t.Errorf("body %s (%v)", body, err)
	}
	// Wrong method on a real route is a 404 too (Express fell through to its
	// 404 as well; Go answers in JSON).
	res, body = get(t, h, http.MethodGet, "/api/auth/login", nil)
	if res.StatusCode != http.StatusNotFound || !strings.Contains(string(body), `"not_found"`) {
		t.Errorf("GET /api/auth/login: %d %s", res.StatusCode, body)
	}
	// A real route still answers: /api/profiles is unauthenticated.
	res, body = get(t, h, http.MethodGet, "/api/profiles", nil)
	if res.StatusCode != http.StatusOK || !strings.Contains(string(body), `"profiles":[`) {
		t.Errorf("/api/profiles: %d %s", res.StatusCode, body)
	}
}

func TestRoomsEndpoint(t *testing.T) {
	a, _ := newApp(t, nil)
	res, body := get(t, a.Handler(), http.MethodGet, "/api/rooms?category=blind", nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status %d: %s", res.StatusCode, body)
	}
	var out struct {
		Tables  []json.RawMessage `json:"tables"`
		Options map[string]json.RawMessage
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(body), `{"tables":[],"options":{`) {
		t.Errorf("tables must be [] never null: %s", body)
	}
	for _, key := range []string{"categories", "stakes", "tables", "entryCapBoot", "entryCapCategory", "entryCapMaxChips", "privateBoot", "privateMaxPot"} {
		if _, ok := out.Options[key]; !ok {
			t.Errorf("options.%s missing", key)
		}
	}
}

// ------------------------------------------------------------------- metrics

func TestMetricsEndpointGuardedAndExcludedFromHTTPMetrics(t *testing.T) {
	a, _ := newApp(t, nil)
	h := a.Handler()
	res, _ := get(t, h, http.MethodGet, "/metrics", nil)
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no token: %d", res.StatusCode)
	}
	get(t, h, http.MethodGet, "/health", nil)
	get(t, h, http.MethodGet, "/nothing-here-123", nil)
	get(t, h, http.MethodGet, "/api/rooms?category=seen", nil)
	get(t, h, http.MethodGet, "/style.css", nil)
	get(t, h, http.MethodGet, "/socket.io/socket.io.js", nil)

	bearer := func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+metricsToken) }
	res, body := get(t, h, http.MethodGet, "/metrics", bearer)
	if res.StatusCode != http.StatusOK || !strings.HasPrefix(res.Header.Get("Content-Type"), "text/plain") {
		t.Fatalf("with token: %d %q", res.StatusCode, res.Header.Get("Content-Type"))
	}
	text := string(body)
	for _, want := range []string{
		`game_http_requests_total{method="GET",route="/health",service="king-teenpatti",status_code="200"} 1`,
		`game_http_requests_total{method="GET",route="unmatched",service="king-teenpatti",status_code="404"} 1`,
		`game_http_requests_total{method="GET",route="/api/rooms",service="king-teenpatti",status_code="200"} 1`,
		`game_http_requests_total{method="GET",route="static",service="king-teenpatti",status_code="200"} 1`,
		"# TYPE game_connected_sockets gauge",
		"game_server_process_uptime_seconds",
		"game_db_pool_connections{service=\"king-teenpatti\"}",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("exposition lacks %q", want)
		}
	}
	for _, forbidden := range []string{`route="/metrics"`, `route="/socket.io`, "nothing-here", "category=seen", "style.css"} {
		if strings.Contains(text, forbidden) {
			t.Errorf("exposition carries %q", forbidden)
		}
	}
	if v := regexp.MustCompile(`game_db_pool_connections\{[^}]*\} (\d+)`).FindStringSubmatch(text); v == nil || v[1] == "0" {
		t.Errorf("pool gauge not bound: %v", v)
	}
}

func TestMetricsDisabledRemovesEndpointAndMiddleware(t *testing.T) {
	a, _ := newApp(t, func(cfg *config.Config) { cfg.Metrics.Enabled = false })
	res, body := get(t, a.Handler(), http.MethodGet, "/metrics", nil)
	if res.StatusCode != http.StatusNotFound || string(body) != "Cannot GET /metrics" {
		t.Fatalf("/metrics with metrics disabled: %d %s", res.StatusCode, body)
	}
	// Counters still exist and are safe to touch.
	a.metrics.ChatMessagesTotal.Inc()
}

// ------------------------------------------------------------ start/shutdown

func TestStartOnPortZeroThenShutdownTwice(t *testing.T) {
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	a, err := New(Options{Config: cfg, DB: database, Logger: util.NewLogger("error", io.Discard)})
	if err != nil {
		t.Fatal(err)
	}
	if a.Addr() != "" {
		t.Fatalf("Addr before Start: %q", a.Addr())
	}
	errCh := make(chan error, 1)
	go func() { errCh <- a.Start(context.Background()) }()

	deadline := time.Now().Add(5 * time.Second)
	for a.Addr() == "" && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	addr := a.Addr()
	if addr == "" || strings.HasSuffix(addr, ":0") {
		t.Fatalf("Addr after Start: %q", addr)
	}
	res, err := http.Get("http://" + addr + "/health")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || !strings.HasPrefix(string(body), `{"ok":true,`) {
		t.Fatalf("/health over TCP: %d %s", res.StatusCode, body)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := a.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			t.Fatalf("Start returned %v, want ErrServerClosed", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Start did not return after Shutdown")
	}
	if err := a.Shutdown(ctx); err != nil {
		t.Fatalf("second Shutdown: %v", err)
	}
	if _, err := http.Get("http://" + addr + "/health"); err == nil {
		t.Fatal("listener still open after Shutdown")
	}
	if err := a.Start(context.Background()); !errors.Is(err, http.ErrServerClosed) {
		t.Fatalf("Start after Shutdown: %v", err)
	}
}
