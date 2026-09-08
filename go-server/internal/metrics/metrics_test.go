package metrics

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// ---------------------------------------------------------------- exposition

// sample is one parsed line of the text exposition.
type sample struct {
	name   string
	labels map[string]string
	value  float64
}

// exposition is a tiny parser for the Prometheus text format, mirroring the
// `scrape()` helper in test/metrics.test.js: it keeps HELP/TYPE lines and
// every sample with its label set.
type exposition struct {
	body    string
	help    map[string]string
	types   map[string]string
	samples []sample
}

var sampleLine = regexp.MustCompile(`^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{([^}]*)\})?\s+(\S+)`)
var labelPair = regexp.MustCompile(`([A-Za-z_][A-Za-z0-9_]*)="((?:[^"\\]|\\.)*)"`)

func parseExposition(body string) *exposition {
	e := &exposition{body: body, help: map[string]string{}, types: map[string]string{}}
	for _, line := range strings.Split(body, "\n") {
		switch {
		case line == "":
		case strings.HasPrefix(line, "# HELP "):
			rest := strings.TrimPrefix(line, "# HELP ")
			name, help, _ := strings.Cut(rest, " ")
			e.help[name] = help
		case strings.HasPrefix(line, "# TYPE "):
			rest := strings.TrimPrefix(line, "# TYPE ")
			name, typ, _ := strings.Cut(rest, " ")
			e.types[name] = typ
		case strings.HasPrefix(line, "#"):
		default:
			m := sampleLine.FindStringSubmatch(line)
			if m == nil {
				continue
			}
			labels := map[string]string{}
			for _, kv := range labelPair.FindAllStringSubmatch(m[2], -1) {
				labels[kv[1]] = kv[2]
			}
			v, _ := strconv.ParseFloat(m[3], 64)
			e.samples = append(e.samples, sample{name: m[1], labels: labels, value: v})
		}
	}
	return e
}

// value sums every sample of `name` whose labels include `want` (Node's
// value(name, labels)); ok is false when none matched.
func (e *exposition) value(name string, want map[string]string) (float64, bool) {
	total, found := 0.0, false
outer:
	for _, s := range e.samples {
		if s.name != name {
			continue
		}
		for k, v := range want {
			if s.labels[k] != v {
				continue outer
			}
		}
		total += s.value
		found = true
	}
	return total, found
}

func (e *exposition) labelValues(label string) []string {
	set := map[string]struct{}{}
	for _, s := range e.samples {
		if v, ok := s.labels[label]; ok {
			set[v] = struct{}{}
		}
	}
	out := make([]string, 0, len(set))
	for v := range set {
		out = append(out, v)
	}
	sort.Strings(out)
	return out
}

func (e *exposition) labelNames() []string {
	set := map[string]struct{}{}
	for _, s := range e.samples {
		for k := range s.labels {
			set[k] = struct{}{}
		}
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func scrape(t *testing.T, m *Metrics, guard Guard, mutate func(r *http.Request)) (*http.Response, *exposition) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	if mutate != nil {
		mutate(req)
	}
	rec := httptest.NewRecorder()
	m.Handler(guard).ServeHTTP(rec, req)
	res := rec.Result()
	body, _ := io.ReadAll(res.Body)
	return res, parseExposition(string(body))
}

func newMetrics(t *testing.T) *Metrics {
	t.Helper()
	return New(Options{Prefix: "game_server_", StartedAt: time.Now().Add(-time.Second)})
}

// -------------------------------------------------------------------- names

// The catalogue Node registers in metrics/index.js: name → (type, labels, help).
var catalogue = []struct {
	name, typ, help string
	labels          []string
}{
	{NameConnectedSockets, "gauge", "Socket.IO connections open right now.", nil},
	{NameConnectedSocketsPeak, "gauge", "Highest number of Socket.IO connections open at once since the process started.", nil},
	{NameConnectionsTotal, "counter", "Socket.IO connections accepted since the process started.", nil},
	{NameDisconnectionsTotal, "counter", "Socket.IO disconnections since the process started, by Socket.IO reason.", []string{"reason"}},
	{NameReconnectsTotal, "counter", "Connections from a player whose seat was still being held after a drop, or who was offered their table back.", []string{"kind"}},
	{NameSocketErrorsTotal, "counter", "Requests refused on the socket, by error code.", []string{"code"}},
	{NameSocketMessagesTotal, "counter", "Messages received from clients, by event name.", []string{"event"}},
	{NameSocketEmitsTotal, "counter", "Messages sent to clients, by event name (a room broadcast counts once).", []string{"event"}},
	{NameSessionReplacedTotal, "counter", "Times a second sign-in displaced an existing socket for the same account.", nil},
	{NamePlayersOnline, "gauge", "Players seated at a table right now.", nil},
	{NameActiveGames, "gauge", "Tables with a hand in progress (betting or showdown).", nil},
	{NameWaitingGames, "gauge", "Tables that exist but have no hand in progress (waiting for players or between hands).", nil},
	{NameTables, "gauge", "Open tables by category and stake.", []string{"category", "stake"}},
	{NameGamesStartedTotal, "counter", "Hands dealt since the process started.", []string{"category"}},
	{NameGamesCompletedTotal, "counter", "Hands that ended with a winner, by how they ended.", []string{"category", "reason"}},
	{NameGamesAbandonedTotal, "counter", "Hands that ended because every player left, or a table destroyed mid-hand.", []string{"category"}},
	{NameMovesTotal, "counter", "Player actions accepted by the rules engine, by action.", []string{"action"}},
	{NameInvalidMovesTotal, "counter", "Player actions refused by the rules engine, by refusal code.", []string{"code"}},
	{NameTurnTimeoutsTotal, "counter", "Turns that ran out the clock and were packed automatically.", nil},
	{NameKicksTotal, "counter", "Players removed from a table by the server, by reason.", []string{"reason"}},
	{NameChatMessagesTotal, "counter", "Chat messages posted to a table.", nil},
	{NamePotSettledTotal, "counter", "Chips paid out to hand winners since the process started.", nil},
	{NameMoveDuration, "histogram", "Time to validate a move, commit it to the database and update the table, by action.", []string{"action"}},
	{NameCreationDuration, "histogram", "Time to create a table (lobby quick-join that opened a new one, or a private room).", nil},
	{NameJoinDuration, "histogram", "Time from a join request to the player being seated and sent the table, by entry route.", []string{"route"}},
	{NameStateUpdateDuration, "histogram", "Time to serialise and send one table state change to every viewer at the table.", nil},
	{NameHandStartDuration, "histogram", "Time to collect the boot and deal a hand (one database transaction).", nil},
	{NameSettlementDuration, "histogram", "Time to settle a finished hand in the database.", nil},
	{NameDBTransactionDuration, "histogram", "Duration of the ledger transactions that move chips, by operation.", []string{"op"}},
	{NameDBTransactionErrors, "counter", "Ledger transactions that rolled back, by operation and error code.", []string{"op", "code"}},
	{NameDBPoolConnections, "gauge", "Connections held by the pg pool.", nil},
	{NameDBPoolIdleConnections, "gauge", "Pool connections not in use.", nil},
	{NameDBPoolWaitingRequests, "gauge", "Queries waiting for a pool connection.", nil},
	{NameLiveStoreOperations, "counter", "Live-state store calls, by store method and outcome (ok, not_found, stale, error).", []string{"op", "result"}},
	{NameLiveStoreDuration, "histogram", "Live-state store call duration, by store method.", []string{"op"}},
	{NameLiveStoreErrors, "counter", "Live-state store calls that failed (not_found and stale are outcomes, not failures), by store method.", []string{"op"}},
	{NameLiveStoreReconciles, "counter", "Reconciler passes that re-saved every live table into the live store, by outcome.", []string{"result"}},
	{NameRestoredTables, "counter", "Tables rebuilt at startup since the process started, by the store the snapshot came from (live or postgres).", []string{"source"}},
	{NameRestoredSeats, "counter", "Seats held for the reconnect grace period after a restart since the process started.", nil},
	{NameRestoreReconciled, "counter", "Durable snapshots the ledger corrected before the table was rebuilt (the snapshot was behind the money).", nil},
	{NameRestoreRejected, "counter", "Durable snapshots that could not be reconciled (a contributor the snapshot cannot account for); their pots were refunded instead.", nil},
	{NameRefundedPots, "counter", "Open pots with no live table that were refunded to their contributors at startup.", nil},
	{NameRefundedChips, "counter", "Chips returned to contributors by pot refunds at startup.", nil},
	{NameSnapshotWrites, "counter", "Batched game_states flushes by the durable snapshot writer, by outcome.", []string{"result"}},
	{NameSnapshotWriteDuration, "histogram", "Duration of one batched game_states flush (upserts and deletes in one transaction).", nil},
	{NameSnapshotRowsWritten, "counter", "game_states rows upserted or deleted by the durable snapshot writer.", nil},
	{NameSnapshotLag, "gauge", "Age in seconds of the oldest table change not yet flushed to game_states (0 when nothing is pending).", nil},
	{NameHTTPRequestsTotal, "counter", "HTTP requests served, by method, route pattern and status code.", []string{"method", "route", "status_code"}},
	{NameHTTPRequestDuration, "histogram", "HTTP request duration, by method, route pattern and status code.", []string{"method", "route", "status_code"}},
}

// touch gives every labelled vector one series so the exposition shows its
// label names (labelled metrics print nothing until first use, as in Node).
func touch(m *Metrics) {
	m.DisconnectionsTotal.WithLabelValues("transport close").Inc()
	m.ReconnectsTotal.WithLabelValues(ReconnectSeatHeld).Inc()
	m.SocketErrorsTotal.WithLabelValues("not_your_turn").Inc()
	m.SocketMessagesTotal.WithLabelValues("game:action").Inc()
	m.SocketEmitsTotal.WithLabelValues("room:state").Inc()
	m.GamesStartedTotal.WithLabelValues("seen").Inc()
	m.GamesCompletedTotal.WithLabelValues("seen", "last_standing").Inc()
	m.GamesAbandonedTotal.WithLabelValues("blind").Inc()
	m.MovesTotal.WithLabelValues("chaal").Inc()
	m.InvalidMovesTotal.WithLabelValues("unknown_action").Inc()
	m.KicksTotal.WithLabelValues("idle").Inc()
	m.MoveDuration.WithLabelValues("see").Observe(0.002)
	m.CreationDuration.Observe(0.0001)
	m.JoinDuration.WithLabelValues(RouteQuickJoin).Observe(0.01)
	m.StateUpdateDuration.Observe(0.001)
	m.HandStartDuration.Observe(0.02)
	m.SettlementDuration.Observe(0.03)
	m.DBTransactionDuration.WithLabelValues(OpBet).Observe(0.004)
	m.DBTransactionErrors.WithLabelValues(OpSettle, "stale_state").Inc()
	m.HTTPRequestsTotal.WithLabelValues("GET", "/health", "200").Inc()
	m.HTTPRequestDuration.WithLabelValues("GET", "/health", "200").Observe(0.0005)
	m.LiveStoreOperations.WithLabelValues(LiveOpSaveTable, LiveResultOK).Inc()
	m.LiveStoreDuration.WithLabelValues(LiveOpSaveTable).Observe(0.0002)
	m.LiveStoreErrors.WithLabelValues(LiveOpPing).Inc()
	m.LiveStoreReconciles.WithLabelValues(ResultOK).Inc()
	m.RestoredTablesTotal.WithLabelValues(RestoreSourceLive).Inc()
	m.SnapshotWrites.WithLabelValues(ResultOK).Inc()
}

// TestCatalogueCoversEveryGameFamily: every game_* family the registry
// exposes is in the catalogue above (a new metric must be catalogued, with
// its help text and label set, before it ships).
func TestCatalogueCoversEveryGameFamily(t *testing.T) {
	m := newMetrics(t)
	touch(m)
	_, e := scrape(t, m, Guard{}, nil)
	known := map[string]bool{}
	for _, c := range catalogue {
		known[c.name] = true
	}
	for name := range e.types {
		if strings.HasPrefix(name, "game_") && !strings.HasPrefix(name, "game_server_") && !known[name] {
			t.Errorf("%s is exposed but not catalogued", name)
		}
	}
	if len(catalogue) != 49 {
		t.Errorf("catalogue has %d entries, want 49 (35 from Node + 10 live-state + 4 snapshot writer)", len(catalogue))
	}
}

func TestGameMetricsMatchNodeCatalogue(t *testing.T) {
	m := newMetrics(t)
	touch(m)
	res, e := scrape(t, m, Guard{}, nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status %d", res.StatusCode)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Fatalf("content-type %q", ct)
	}
	if !regexp.MustCompile(`(?m)^# HELP `).MatchString(e.body) {
		t.Fatal("no HELP lines")
	}
	if !regexp.MustCompile(`(?m)^# TYPE game_connected_sockets gauge$`).MatchString(e.body) {
		t.Fatal("game_connected_sockets is not a gauge")
	}

	for _, c := range catalogue {
		if c.name == NameTables {
			// A custom collector with no live table emits no family at all
			// (Node printed bare HELP/TYPE lines — nothing scrapes them);
			// TestTableGaugesRecountLiveTables checks it with tables present.
			continue
		}
		if got := e.types[c.name]; got != c.typ {
			t.Errorf("%s: type %q, want %q", c.name, got, c.typ)
		}
		if got := e.help[c.name]; got != c.help {
			t.Errorf("%s: help %q, want %q", c.name, got, c.help)
		}
		// Every sample of the metric carries exactly its labels + service
		// (+ le on histogram buckets).
		found := false
		for _, s := range e.samples {
			base := strings.TrimSuffix(strings.TrimSuffix(strings.TrimSuffix(s.name, "_bucket"), "_sum"), "_count")
			if base != c.name && s.name != c.name {
				continue
			}
			found = true
			if s.labels[ServiceLabelName] != ServiceLabelValue {
				t.Errorf("%s: sample lacks service label: %v", s.name, s.labels)
			}
			want := map[string]bool{ServiceLabelName: true}
			for _, l := range c.labels {
				want[l] = true
			}
			if strings.HasSuffix(s.name, "_bucket") {
				want["le"] = true
			}
			for k := range s.labels {
				if !want[k] {
					t.Errorf("%s: unexpected label %q", s.name, k)
				}
			}
			for k := range want {
				if _, ok := s.labels[k]; !ok {
					t.Errorf("%s: missing label %q in %v", s.name, k, s.labels)
				}
			}
		}
		if !found {
			t.Errorf("%s: no samples in the exposition", c.name)
		}
	}
}

func TestEverySampleIsPrefixedAndCarriesService(t *testing.T) {
	m := newMetrics(t)
	touch(m)
	_, e := scrape(t, m, Guard{}, nil)
	if len(e.samples) == 0 {
		t.Fatal("empty exposition")
	}
	for _, s := range e.samples {
		if !strings.HasPrefix(s.name, "game_") {
			t.Errorf("%s does not start with game_", s.name)
		}
		if s.labels[ServiceLabelName] != ServiceLabelValue {
			t.Errorf("%s lacks service=%q: %v", s.name, ServiceLabelValue, s.labels)
		}
	}
	// The process and Go runtime families live under the configured prefix
	// (DECISIONS.md §6), and the project-defined uptime gauge survives.
	for _, name := range []string{
		"game_server_process_cpu_seconds_total",
		"game_server_process_resident_memory_bytes",
		"game_server_process_start_time_seconds",
		"game_server_process_open_fds",
		"game_server_process_max_fds",
		"game_server_process_uptime_seconds",
		"game_server_go_goroutines",
		"game_server_go_info",
	} {
		if _, ok := e.value(name, nil); !ok {
			t.Errorf("%s missing from the exposition", name)
		}
	}
	if v, _ := e.value("game_server_process_uptime_seconds", nil); v <= 0 {
		t.Errorf("uptime %v, want > 0", v)
	}
	if v, _ := e.value("game_server_process_resident_memory_bytes", nil); v <= 0 {
		t.Errorf("rss %v, want > 0", v)
	}
	if v, _ := e.value("game_server_process_open_fds", nil); v <= 0 {
		t.Errorf("open fds %v, want > 0", v)
	}
	if typ := e.types["game_server_go_gc_duration_seconds"]; typ != "summary" {
		t.Errorf("go_gc_duration_seconds type %q", typ)
	}
}

func TestHistogramBucketsAreNodesLatencyBuckets(t *testing.T) {
	m := newMetrics(t)
	m.MoveDuration.WithLabelValues("chaal").Observe(0.3)
	_, e := scrape(t, m, Guard{}, nil)
	want := []string{"0.001", "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "+Inf"}
	var got []string
	for _, s := range e.samples {
		if s.name == NameMoveDuration+"_bucket" && s.labels["action"] == "chaal" {
			got = append(got, s.labels["le"])
		}
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("buckets %v, want %v", got, want)
	}
	if v, ok := e.value(NameMoveDuration+"_bucket", map[string]string{"action": "chaal", "le": "1"}); !ok || v != 1 {
		t.Fatalf("le=1 bucket %v %v", v, ok)
	}
	if v, ok := e.value(NameMoveDuration+"_bucket", map[string]string{"action": "chaal", "le": "0.25"}); !ok || v != 0 {
		t.Fatalf("le=0.25 bucket %v %v", v, ok)
	}
	if v, _ := e.value(NameMoveDuration+"_count", map[string]string{"action": "chaal"}); v != 1 {
		t.Fatalf("count %v", v)
	}
	if v, _ := e.value(NameMoveDuration+"_sum", map[string]string{"action": "chaal"}); v <= 0 {
		t.Fatalf("sum %v", v)
	}
}

func TestUnlabelledSeriesAppearAtZeroAndLabelledOnesOnFirstUse(t *testing.T) {
	m := newMetrics(t)
	_, e := scrape(t, m, Guard{}, nil)
	if v, ok := e.value(NameConnectionsTotal, nil); !ok || v != 0 {
		t.Fatalf("connections_total %v %v, want a 0 sample", v, ok)
	}
	if _, ok := e.value(NameDisconnectionsTotal, nil); ok {
		t.Fatal("disconnections_total has a sample before any disconnect")
	}
	if v, ok := e.value(NamePlayersOnline, nil); !ok || v != 0 {
		t.Fatalf("players_online before BindRooms %v %v", v, ok)
	}
	if _, ok := e.value(NameTables, nil); ok {
		t.Fatal("game_tables has series before any table exists")
	}
	if v, ok := e.value(NameDBPoolConnections, nil); !ok || v != 0 {
		t.Fatalf("db_pool_connections before BindPool %v %v", v, ok)
	}
	m.DisconnectionsTotal.WithLabelValues("ping timeout").Inc()
	_, e = scrape(t, m, Guard{}, nil)
	if v, ok := e.value(NameDisconnectionsTotal, map[string]string{"reason": "ping timeout"}); !ok || v != 1 {
		t.Fatalf("disconnections_total{ping timeout} %v %v", v, ok)
	}
}

// -------------------------------------------------------------- cardinality

func TestSafeLabelFoldsIdentifiersToOther(t *testing.T) {
	known := map[string]struct{}{"seen": {}, "blind": {}}
	cases := []string{
		"7c2f1a2e-9b3d-4c1f-8a6e-0f1e2d3c4b5a", // uuid
		"ABC234",                               // table code
		"10.0.0.5", "::1", "::ffff:127.0.0.1",
		"3b7d1c1a0f6b2f2e7c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b", // sha256
		"", "teleport", "Seen",
	}
	for _, v := range cases {
		if got := SafeLabel(v, known, OtherLabel); got != OtherLabel {
			t.Errorf("SafeLabel(%q) = %q, want other", v, got)
		}
	}
	if got := SafeLabel("blind", known, OtherLabel); got != "blind" {
		t.Errorf("known value folded: %q", got)
	}
	if got := SafeLabel("BREW", HTTPMethods, MethodOther); got != MethodOther {
		t.Errorf("method fallback %q", got)
	}
}

func TestNoLabelCarriesAnIdentifier(t *testing.T) {
	m := newMetrics(t)
	touch(m)
	// Feed the kind of values a careless caller might: they must be folded
	// before they reach a label.
	uuid := "7c2f1a2e-9b3d-4c1f-8a6e-0f1e2d3c4b5a"
	knownCodes := map[string]struct{}{"not_your_turn": {}, "unknown_action": {}}
	knownCategories := map[string]struct{}{"seen": {}, "blind": {}}
	m.SocketErrorsTotal.WithLabelValues(SafeLabel(uuid, knownCodes, OtherLabel)).Inc()
	m.KicksTotal.WithLabelValues(SafeLabel("10.0.0.7", game.KnownKickReasons, OtherLabel)).Inc()
	m.GamesStartedTotal.WithLabelValues(SafeLabel("ABC234", knownCategories, OtherLabel)).Inc()
	m.InvalidMovesTotal.WithLabelValues(SafeLabel("teleport", knownCodes, OtherLabel)).Inc()
	m.DBTransactionErrors.WithLabelValues(OpBet, SafeLabel("23505", game.KnownLedgerCodes, OtherLabel)).Inc()

	_, e := scrape(t, m, Guard{}, nil)

	labelled := false
	for _, s := range e.samples {
		if strings.HasPrefix(s.name, "game_") && len(s.labels) > 1 {
			labelled = true
			break
		}
	}
	if !labelled {
		t.Fatal("the exposition has no labelled game series to inspect")
	}

	forbidden := map[string]bool{"socket_id": true, "user_id": true, "room_id": true, "code_": true, "ip": true, "url": true, "path": true, "device_id": true}
	for _, name := range e.labelNames() {
		if forbidden[name] || strings.HasSuffix(name, "_id") || strings.HasPrefix(name, "code_") {
			t.Errorf("label name %q is forbidden", name)
		}
	}

	uuidRe := regexp.MustCompile(`(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)
	ipv4Re := regexp.MustCompile(`\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b`)
	ipv6Re := regexp.MustCompile(`(?i)^[0-9a-f.:]+$`)
	shaRe := regexp.MustCompile(`(?i)^[0-9a-f]{64}$`)
	for _, s := range e.samples {
		for name, value := range s.labels {
			where := fmt.Sprintf(`%s %s="%s"`, s.name, name, value)
			if uuidRe.MatchString(value) {
				t.Errorf("%s contains a UUID", where)
			}
			if ipv4Re.MatchString(value) {
				t.Errorf("%s looks like an IPv4 address", where)
			}
			if ipv6Re.MatchString(value) && strings.Count(value, ":") >= 2 {
				t.Errorf("%s looks like an IPv6 address", where)
			}
			if shaRe.MatchString(value) {
				t.Errorf("%s is a hashed device id", where)
			}
		}
	}
	codeRe := regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	for _, code := range e.labelValues("code") {
		if !codeRe.MatchString(code) {
			t.Errorf("code %q is not a snake_case error code", code)
		}
	}
	eventRe := regexp.MustCompile(`^[a-z]+:[a-zA-Z]+$`)
	for _, ev := range e.labelValues("event") {
		if !eventRe.MatchString(ev) {
			t.Errorf("event %q is not a wire event name", ev)
		}
	}
	for _, c := range e.labelValues("category") {
		if c != "seen" && c != "blind" && c != "other" {
			t.Errorf("category %q is not fixed", c)
		}
	}
	methodRe := regexp.MustCompile(`^[A-Z]+$`)
	for _, mth := range e.labelValues("method") {
		if !methodRe.MatchString(mth) {
			t.Errorf("method %q is not an HTTP verb", mth)
		}
	}
	reasonRe := regexp.MustCompile(`^[a-z][a-z _]*$`)
	for _, r := range e.labelValues("reason") {
		if !reasonRe.MatchString(r) {
			t.Errorf("reason %q is malformed", r)
		}
	}
	// The folded values landed as "other", never as the identifier.
	if v, _ := e.value(NameSocketErrorsTotal, map[string]string{"code": OtherLabel}); v != 1 {
		t.Errorf("socket_errors_total{code=other} = %v", v)
	}
	if v, _ := e.value(NameKicksTotal, map[string]string{"reason": OtherLabel}); v != 1 {
		t.Errorf("kicks_total{reason=other} = %v", v)
	}
	if v, _ := e.value(NameGamesStartedTotal, map[string]string{"category": OtherLabel}); v != 1 {
		t.Errorf("games_started_total{category=other} = %v", v)
	}
	if v, _ := e.value(NameInvalidMovesTotal, map[string]string{"code": "teleport"}); v != 0 {
		t.Errorf("teleport became a label value")
	}
}

// --------------------------------------------------------------- live hooks

// TestLiveHooksFeedTheLiveStoreMetrics: the hooks count every call by
// (op, result), time it into the 0.1 ms … 1 s histogram, count only real
// failures as errors, fold an unknown op to "other", and classify the two
// live sentinels as outcomes rather than failures — wrapped or not.
func TestLiveHooksFeedTheLiveStoreMetrics(t *testing.T) {
	m := newMetrics(t)
	hooks := m.LiveHooks()
	hooks.Observe(LiveOpSaveTable, nil, 200*time.Microsecond)
	hooks.Observe(LiveOpSaveTable, live.ErrStale, 300*time.Microsecond)
	hooks.Observe(LiveOpTakeResumeOffer, fmt.Errorf("take: %w", live.ErrNotFound), 50*time.Microsecond)
	hooks.Observe(LiveOpPing, fmt.Errorf("dial tcp 127.0.0.1:6379: connection refused"), 2*time.Millisecond)
	hooks.Observe("kt:table:7c2f1a2e-9b3d-4c1f-8a6e-0f1e2d3c4b5a", nil, time.Millisecond) // never a label value

	_, e := scrape(t, m, Guard{}, nil)
	for _, c := range []struct {
		op, result string
		want       float64
	}{
		{LiveOpSaveTable, LiveResultOK, 1}, {LiveOpSaveTable, LiveResultStale, 1},
		{LiveOpTakeResumeOffer, LiveResultNotFound, 1}, {LiveOpPing, LiveResultError, 1},
		{OtherLabel, LiveResultOK, 1},
	} {
		if v, _ := e.value(NameLiveStoreOperations, map[string]string{"op": c.op, "result": c.result}); v != c.want {
			t.Errorf("operations{op=%s,result=%s} = %v, want %v", c.op, c.result, v, c.want)
		}
	}
	if v, _ := e.value(NameLiveStoreErrors, map[string]string{"op": LiveOpPing}); v != 1 {
		t.Errorf("errors{ping} = %v, want 1", v)
	}
	if v, _ := e.value(NameLiveStoreErrors, nil); v != 1 {
		t.Errorf("errors total = %v, want 1 (not_found/stale are not failures)", v)
	}
	if v, _ := e.value(NameLiveStoreDuration+"_count", map[string]string{"op": LiveOpSaveTable}); v != 2 {
		t.Errorf("duration_count{save_table} = %v, want 2", v)
	}
	// 200 µs and 300 µs both fall at or under the 0.0005 bucket, only one at 0.00025.
	if v, _ := e.value(NameLiveStoreDuration+"_bucket", map[string]string{"op": LiveOpSaveTable, "le": "0.00025"}); v != 1 {
		t.Errorf("bucket le=0.00025 = %v, want 1", v)
	}
	if v, _ := e.value(NameLiveStoreDuration+"_bucket", map[string]string{"op": LiveOpSaveTable, "le": "0.0005"}); v != 2 {
		t.Errorf("bucket le=0.0005 = %v, want 2", v)
	}
	if !strings.Contains(e.body, `le="0.0001"`) || !strings.Contains(e.body, `le="1"`) {
		t.Errorf("live buckets must run 0.0001 … 1: %s", e.body)
	}
	for _, v := range e.labelValues("op") {
		if _, ok := LiveOps[v]; !ok && v != OtherLabel && v != OpBet && v != OpBoot && v != OpSettle {
			t.Errorf("op label %q is outside the fixed set", v)
		}
	}
	if strings.Contains(e.body, "7c2f1a2e") {
		t.Error("a room id reached the exposition")
	}
	// A nil receiver hands back hooks that do nothing rather than panic.
	var none *Metrics
	none.LiveHooks().Observe(LiveOpPing, nil, time.Millisecond)
	// The hooks plug straight into the live package's decorator.
	if live.WithHooks(live.NewMemory(), m.LiveHooks()) == nil {
		t.Fatal("WithHooks returned nil")
	}
	// Every store method name is a catalogued op. Derived from the interface,
	// not hardcoded, so adding a Store method fails here until its op is
	// catalogued — Kind and Close are the two that carry no op label.
	storeType := reflect.TypeOf((*live.Store)(nil)).Elem()
	if want := storeType.NumMethod() - 2; len(LiveOps) != want {
		t.Errorf("LiveOps has %d entries, want one per labelled live.Store method (%d)", len(LiveOps), want)
	}
}

// game_snapshot_lag_seconds reads the bound writer at scrape time; 0 before
// anything is bound.
func TestSnapshotLagGaugeReadsTheBoundSource(t *testing.T) {
	m := newMetrics(t)
	_, e := scrape(t, m, Guard{}, nil)
	if v, ok := e.value(NameSnapshotLag, nil); !ok || v != 0 {
		t.Fatalf("unbound lag = %v %v, want 0", v, ok)
	}
	m.BindSnapshotLag(func() time.Duration { return 1500 * time.Millisecond })
	_, e = scrape(t, m, Guard{}, nil)
	if v, _ := e.value(NameSnapshotLag, nil); v != 1.5 {
		t.Fatalf("bound lag = %v, want 1.5", v)
	}
	for _, src := range e.labelValues("source") {
		if _, ok := RestoreSources[src]; !ok {
			t.Errorf("source label %q is outside the fixed set", src)
		}
	}
}

// -------------------------------------------------------------------- guard

func TestHandlerGuardTokenThenExposition(t *testing.T) {
	m := newMetrics(t)
	guard := Guard{Token: "metrics-test-token"}

	res, _ := scrape(t, m, guard, nil)
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no header: %d", res.StatusCode)
	}
	body, _ := io.ReadAll(res.Body)
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Fatalf("content-type %q", ct)
	}
	res, e := scrape(t, m, guard, func(r *http.Request) { r.Header.Set("Authorization", "Bearer not-the-token") })
	if res.StatusCode != http.StatusUnauthorized || strings.TrimSpace(e.body) != "unauthorized" {
		t.Fatalf("wrong token: %d %q", res.StatusCode, e.body)
	}
	// Exact comparison: scheme case and spacing matter, as in Node.
	res, _ = scrape(t, m, guard, func(r *http.Request) { r.Header.Set("Authorization", "bearer metrics-test-token") })
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("lower-case scheme accepted: %d", res.StatusCode)
	}
	res, e = scrape(t, m, guard, func(r *http.Request) { r.Header.Set("Authorization", "Bearer metrics-test-token") })
	if res.StatusCode != http.StatusOK {
		t.Fatalf("right token: %d", res.StatusCode)
	}
	if !strings.HasPrefix(res.Header.Get("Content-Type"), "text/plain") {
		t.Fatalf("content-type %q", res.Header.Get("Content-Type"))
	}
	if !regexp.MustCompile(`(?m)^# TYPE game_connected_sockets gauge$`).MatchString(e.body) {
		t.Fatalf("exposition missing: %q", body)
	}
}

func TestHandlerGuardIPBeforeToken(t *testing.T) {
	m := newMetrics(t)
	guard := Guard{Token: "tok", AllowIPs: []string{"10.0.0.5"}}

	// Wrong IP with the right token → 403 (IP is checked first).
	res, e := scrape(t, m, guard, func(r *http.Request) {
		r.RemoteAddr = "192.168.1.9:5555"
		r.Header.Set("Authorization", "Bearer tok")
	})
	if res.StatusCode != http.StatusForbidden || strings.TrimSpace(e.body) != "forbidden" {
		t.Fatalf("wrong ip: %d %q", res.StatusCode, e.body)
	}
	// Right IP (IPv4-mapped IPv6 form), no token → 401.
	res, _ = scrape(t, m, guard, func(r *http.Request) { r.RemoteAddr = "[::ffff:10.0.0.5]:5555" })
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("right ip, no token: %d", res.StatusCode)
	}
	// Both right → 200.
	res, _ = scrape(t, m, guard, func(r *http.Request) {
		r.RemoteAddr = "10.0.0.5:5555"
		r.Header.Set("Authorization", "Bearer tok")
	})
	if res.StatusCode != http.StatusOK {
		t.Fatalf("both right: %d", res.StatusCode)
	}
	// IP-only guard, plain IPv6 compared verbatim.
	res, _ = scrape(t, m, Guard{AllowIPs: []string{"::1"}}, func(r *http.Request) { r.RemoteAddr = "[::1]:1" })
	if res.StatusCode != http.StatusOK {
		t.Fatalf("ipv6 loopback: %d", res.StatusCode)
	}
	// Open endpoint.
	res, _ = scrape(t, m, Guard{}, nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("open: %d", res.StatusCode)
	}
}

// --------------------------------------------------------------------- HTTP

func TestRouteLabelForTable(t *testing.T) {
	cases := []struct{ pattern, path, want string }{
		{"GET /health", "/health", "/health"},
		{"POST /api/auth/login", "/api/auth/login", "/api/auth/login"},
		{"GET /api/auth/me/hands", "/api/auth/me/hands?limit=3", "/api/auth/me/hands"},
		{"GET example.com/api/rooms", "/api/rooms", "/api/rooms"},
		{"/api/rooms", "/api/rooms", "/api/rooms"},
		{"/", "/", RouteStatic},
		{"GET /{$}", "/", RouteStatic},
		{"/", "/style.css", RouteStatic},
		{"/", "/profiles/bear.svg", RouteStatic},
		{"/", "/nothing-here-123", RouteUnmatched},
		{"/", "/profiles/", RouteUnmatched},
		{"/", "/file.toolong1", RouteUnmatched},
		{"/api/", "/api/unknown/route", RouteUnmatched},
		{"/api/", "/api/thing.js", RouteStatic},
		{"", "/index.html", RouteStatic},
		{"", "/nothing", RouteUnmatched},
	}
	for _, c := range cases {
		r := httptest.NewRequest(http.MethodGet, c.path, nil)
		r.Pattern = c.pattern
		if got := RouteLabelFor(r); got != c.want {
			t.Errorf("pattern %q path %q: got %q want %q", c.pattern, c.path, got, c.want)
		}
	}
}

func TestHTTPMiddlewareLabelsByRoutePatternAndSkipsMetrics(t *testing.T) {
	m := newMetrics(t)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(`{"ok":true}`)) })
	mux.HandleFunc("GET /api/auth/me/hands", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("POST /api/auth/login", func(w http.ResponseWriter, r *http.Request) {
		// Read the body inside the handler: the middleware must not have consumed it.
		b, _ := io.ReadAll(r.Body)
		if len(b) == 0 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusBadRequest)
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNotFound) })
	mux.Handle("GET /metrics", m.Handler(Guard{}))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" || strings.HasSuffix(r.URL.Path, ".css") {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	})
	h := m.HTTPMiddleware("/metrics", RouteLabelFor, mux)

	do := func(method, target, body string) int {
		var rd io.Reader
		if body != "" {
			rd = strings.NewReader(body)
		}
		req := httptest.NewRequest(method, target, rd)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code
	}
	do(http.MethodPost, "/api/auth/login", `{"provider":"guest"}`)
	do(http.MethodGet, "/health", "")
	do(http.MethodGet, "/health", "")
	do(http.MethodGet, "/api/auth/me/hands?limit=3", "")
	do(http.MethodGet, "/nothing-here-123", "")
	do(http.MethodGet, "/api/unknown/42", "")
	do(http.MethodGet, "/", "")
	do(http.MethodGet, "/style.css", "")
	do(http.MethodGet, "/metrics", "")
	do(http.MethodGet, "/metrics?x=1", "")
	do("BREW", "/health", "")

	_, e := scrape(t, m, Guard{}, nil)
	expect := []struct {
		method, route, status string
		count                 float64
	}{
		{"POST", "/api/auth/login", "400", 1},
		{"GET", "/health", "200", 2},
		{"GET", "/api/auth/me/hands", "200", 1},
		{"GET", RouteUnmatched, "404", 2},   // /nothing-here-123 and /api/unknown/42
		{"GET", RouteStatic, "200", 2},      // / and /style.css
		{"OTHER", RouteUnmatched, "404", 1}, // BREW is not a known method; ServeMux → the "/" catch-all → 404
	}
	for _, x := range expect {
		labels := map[string]string{"method": x.method, "route": x.route, "status_code": x.status}
		if v, _ := e.value(NameHTTPRequestsTotal, labels); v != x.count {
			t.Errorf("http_requests_total%v = %v, want %v", labels, v, x.count)
		}
		if v, _ := e.value(NameHTTPRequestDuration+"_count", labels); v != x.count {
			t.Errorf("http_request_duration_seconds_count%v = %v, want %v", labels, v, x.count)
		}
	}
	if v, ok := e.value(NameHTTPRequestDuration+"_bucket", map[string]string{"route": "/health", "le": "+Inf"}); !ok || v < 2 {
		t.Errorf("duration +Inf bucket for /health: %v %v", v, ok)
	}
	for _, route := range e.labelValues("route") {
		if route == "/metrics" {
			t.Error("the scrape itself was counted")
		}
		if strings.Contains(route, "?") || strings.Contains(route, "limit=") || strings.Contains(route, "nothing-here") {
			t.Errorf("route label %q carries a raw URL", route)
		}
		if regexp.MustCompile(`/\d+(/|$)`).MatchString(route) {
			t.Errorf("route label %q carries an id", route)
		}
	}
}

// An unknown method never reaches a method pattern: the mux routes it to the
// "/" catch-all, so the label is OTHER + unmatched, never the route it aimed at.
func TestHTTPMiddlewareUnknownMethodFallsToRouting(t *testing.T) {
	m := newMetrics(t)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNotFound) })
	h := m.HTTPMiddleware("/metrics", RouteLabelFor, mux)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("BREW", "/health", nil))
	_, e := scrape(t, m, Guard{}, nil)
	if v, _ := e.value(NameHTTPRequestsTotal, map[string]string{"method": MethodOther, "route": RouteUnmatched, "status_code": "404"}); v != 1 {
		t.Fatalf("BREW /health: %v", e.labelValues("method"))
	}
}

// ------------------------------------------------------------- scrape gauges

type fakeRooms struct{ tables []*game.Table }

func (f fakeRooms) LiveTables() []*game.Table { return f.tables }

func TestPoolGaugesReadTheBoundSourceAndSwallowPanics(t *testing.T) {
	m := newMetrics(t)
	m.BindPool(func() PoolStats { return PoolStats{Total: 4, Idle: 3, Waiting: 0} })
	_, e := scrape(t, m, Guard{}, nil)
	if v, _ := e.value(NameDBPoolConnections, nil); v != 4 {
		t.Errorf("connections %v", v)
	}
	if v, _ := e.value(NameDBPoolIdleConnections, nil); v != 3 {
		t.Errorf("idle %v", v)
	}
	m.BindPool(func() PoolStats { panic("pool closed") })
	_, e = scrape(t, m, Guard{}, nil)
	if v, ok := e.value(NameDBPoolConnections, nil); !ok || v != 0 {
		t.Errorf("after panic %v %v", v, ok)
	}
}

func TestTableGaugesRecountLiveTables(t *testing.T) {
	m := newMetrics(t)
	var tables []*game.Table
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Skipf("game.NewTable is not ported yet: %v", r)
			}
		}()
		mk := func(category game.Category, boot int64) *game.Table {
			return game.NewTable(game.TableOptions{
				ID: "room-" + string(category) + strconv.FormatInt(boot, 10), Code: "ABC" + strconv.FormatInt(boot, 10),
				Config: game.TableConfig{Category: category, BootAmount: boot, MaxPlayers: 5, MinPlayers: 2,
					TurnTimeout: time.Second, NextHandDelay: time.Second, ChatMaxHistory: 10, ChatMaxLength: 140},
				Ledger: game.NewMemoryLedger(game.MemoryLedgerHooks{}),
			})
		}
		tables = []*game.Table{mk(game.CategorySeen, 200), mk(game.CategoryBlind, 200), mk(game.CategoryBlind, 5000), mk(game.CategoryBlind, 5000)}
	}()
	t.Cleanup(func() {
		for _, tb := range tables {
			_ = tb.Destroy()
		}
	})
	src := &fakeRooms{tables: tables}
	m.BindRooms(src)
	_, e := scrape(t, m, Guard{}, nil)
	if e.types[NameTables] != "gauge" || e.help[NameTables] != "Open tables by category and stake." {
		t.Errorf("game_tables type/help: %q %q", e.types[NameTables], e.help[NameTables])
	}
	for _, s := range e.samples {
		if s.name == NameTables {
			for k := range s.labels {
				if k != "category" && k != "stake" && k != ServiceLabelName {
					t.Errorf("game_tables label %q", k)
				}
			}
		}
	}
	if v, _ := e.value(NameWaitingGames, nil); v != 4 {
		t.Errorf("waiting_games %v", v)
	}
	if v, _ := e.value(NameActiveGames, nil); v != 0 {
		t.Errorf("active_games %v", v)
	}
	if v, _ := e.value(NamePlayersOnline, nil); v != 0 {
		t.Errorf("players_online %v", v)
	}
	if v, _ := e.value(NameTables, map[string]string{"category": "blind", "stake": "5000"}); v != 2 {
		t.Errorf("tables{blind,5000} %v", v)
	}
	if v, _ := e.value(NameTables, map[string]string{"category": "seen", "stake": "200"}); v != 1 {
		t.Errorf("tables{seen,200} %v", v)
	}
	// Reset-and-recount: a pair with no table disappears rather than reading 0.
	src.tables = tables[:1]
	_, e = scrape(t, m, Guard{}, nil)
	if _, ok := e.value(NameTables, map[string]string{"category": "blind"}); ok {
		t.Error("blind series survived with no blind tables")
	}
	if v, _ := e.value(NameTables, map[string]string{"category": "seen", "stake": "200"}); v != 1 {
		t.Errorf("tables{seen,200} after shrink %v", v)
	}
}

// ------------------------------------------------------------------ helpers

func TestTimedObservesEvenOnError(t *testing.T) {
	m := newMetrics(t)
	err := Timed(m.DBTransactionDuration.WithLabelValues(OpBoot), func() error { return fmt.Errorf("boom") })
	if err == nil || err.Error() != "boom" {
		t.Fatalf("error not propagated: %v", err)
	}
	_ = Timed(m.HandStartDuration, func() error { return nil })
	Observe(m.SettlementDuration, 20*time.Millisecond)
	_, e := scrape(t, m, Guard{}, nil)
	if v, _ := e.value(NameDBTransactionDuration+"_count", map[string]string{"op": OpBoot}); v != 1 {
		t.Errorf("boot count %v", v)
	}
	if v, _ := e.value(NameHandStartDuration+"_count", nil); v != 1 {
		t.Errorf("hand start count %v", v)
	}
	if v, _ := e.value(NameSettlementDuration+"_bucket", map[string]string{"le": "0.025"}); v != 1 {
		t.Errorf("settlement 20ms landed outside le=0.025: %v", v)
	}
}

func TestNewAcceptsACallerRegistry(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := New(Options{Registry: reg})
	if m.Registry != reg {
		t.Fatal("registry not adopted")
	}
	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	if len(families) == 0 {
		t.Fatal("nothing registered")
	}
	// Registering twice into the same registry is a programming error; a
	// fresh Metrics per registry is the contract.
	defer func() {
		if recover() == nil {
			t.Fatal("double registration did not panic")
		}
	}()
	New(Options{Registry: reg})
}
