package metrics

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/state"
)

func snapshots() []state.Snapshot {
	return []state.Snapshot{
		{Bot: "botplay-000002", UserID: "u-2", Personality: "LOOSE", State: state.Playing, Table: "blind:200",
			HandNo: 7, IsBlind: false, Cards: []string{"As", "Kd", "4c"}, LastDecision: "chaal",
			LastReason: "MEDIUM_HAND_LOW_PRESSURE", LastReaction: "2.1s", Chips: 5000, SessionHands: 12, Wins: 3, Losses: 8},
		{Bot: "botplay-000001", UserID: "u-1", Personality: "CAUTIOUS", State: state.WaitingForHand, Chips: 100},
	}
}

func get(t *testing.T, h http.Handler, method, target string) (int, http.Header, string) {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, target, nil))
	return rec.Code, rec.Header(), rec.Body.String()
}

func TestMetricsEndpoint(t *testing.T) {
	m := New()
	m.TableJoin("seen")
	code, hdr, body := get(t, Handler(m, snapshots, false), "GET", "/metrics")
	if code != 200 || !strings.Contains(body, `bot_table_join_total{category="seen",service="bot-play"} 1`) {
		t.Errorf("/metrics = %d %s\n%s", code, hdr.Get("Content-Type"), body)
	}
	// The exposition's own error counter is labelled like everything else.
	get(t, Handler(m, nil, false), "GET", "/metrics") // a second handler on the same registry is fine
	for name, series := range gather(t, m.Registry()) {
		for _, s := range series {
			if s.labels["service"] != "bot-play" {
				t.Errorf("%s%v lacks service=\"bot-play\"", name, s.labels)
			}
		}
	}
	if code, _, _ := get(t, Handler(nil, snapshots, false), "GET", "/metrics"); code != 404 {
		t.Errorf("/metrics with no Metrics = %d, want 404", code)
	}
}

func TestHealthz(t *testing.T) {
	code, hdr, body := get(t, Handler(nil, snapshots, false), "GET", "/healthz")
	if code != 200 || hdr.Get("Content-Type") != "application/json" {
		t.Fatalf("/healthz = %d %s", code, hdr.Get("Content-Type"))
	}
	var got struct {
		OK   bool `json:"ok"`
		Bots int  `json:"bots"`
	}
	if err := json.Unmarshal([]byte(body), &got); err != nil || !got.OK || got.Bots != 2 {
		t.Errorf("/healthz = %s (%v)", body, err)
	}
	if _, _, body := get(t, Handler(New(), nil, false), "GET", "/healthz"); !strings.Contains(body, `"bots": 0`) {
		t.Errorf("/healthz with no snapshots = %s", body)
	}
}

func TestTheBotListStripsCardsUnlessAllowed(t *testing.T) {
	code, _, body := get(t, Handler(nil, snapshots, false), "GET", "/debug/bots")
	if code != 200 {
		t.Fatalf("/debug/bots = %d", code)
	}
	var list []state.Snapshot
	if err := json.Unmarshal([]byte(body), &list); err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || list[0].Bot != "botplay-000001" || list[1].Bot != "botplay-000002" {
		t.Errorf("the list is not every bot in bot order: %+v", list)
	}
	if strings.Contains(body, "As") || list[1].Cards != nil {
		t.Errorf("cards were shown without show_cards:\n%s", body)
	}

	_, _, body = get(t, Handler(nil, snapshots, true), "GET", "/debug/bots")
	if !strings.Contains(body, `"As"`) {
		t.Errorf("cards were stripped with show_cards:\n%s", body)
	}

	_, hdr, body := get(t, Handler(nil, snapshots, false), "GET", "/debug/bots?format=text")
	if !strings.HasPrefix(hdr.Get("Content-Type"), "text/plain") || !strings.Contains(body, "Bot: botplay-000001") ||
		!strings.Contains(body, "Bot: botplay-000002") || !strings.Contains(body, "Cards: hidden") {
		t.Errorf("text list:\n%s", body)
	}
	if code, _, _ := get(t, Handler(nil, snapshots, false), "GET", "/debug/bots?format=xml"); code != 400 {
		t.Errorf("?format=xml = %d, want 400", code)
	}
}

func TestAnEmptyFleetIsAnEmptyList(t *testing.T) {
	_, _, body := get(t, Handler(nil, func() []state.Snapshot { return nil }, false), "GET", "/debug/bots")
	if strings.TrimSpace(body) != "[]" {
		t.Errorf("empty fleet = %q, want []", body)
	}
}

func TestOneBot(t *testing.T) {
	h := Handler(nil, snapshots, false)
	code, hdr, body := get(t, h, "GET", "/debug/bots/botplay-000002")
	want := snapshots()[0]
	want.Cards = nil
	if code != 200 || !strings.HasPrefix(hdr.Get("Content-Type"), "text/plain") || body != want.String() {
		t.Errorf("text view = %d\n%s\nwant\n%s", code, body, want.String())
	}
	if !strings.Contains(body, "Cards: hidden") || !strings.Contains(body, "Reason: MEDIUM_HAND_LOW_PRESSURE") {
		t.Errorf("text view:\n%s", body)
	}

	code, _, body = get(t, h, "GET", "/debug/bots/botplay-000002?format=json")
	var one state.Snapshot
	if err := json.Unmarshal([]byte(body), &one); code != 200 || err != nil || one.Bot != "botplay-000002" || one.Cards != nil {
		t.Errorf("json view = %d %v %+v", code, err, one)
	}

	_, _, body = get(t, Handler(nil, snapshots, true), "GET", "/debug/bots/botplay-000002")
	if !strings.Contains(body, "Cards: [As Kd 4c]") {
		t.Errorf("show_cards text view:\n%s", body)
	}

	if code, _, _ := get(t, h, "GET", "/debug/bots/u-1"); code != 200 {
		t.Errorf("by user id = %d, want 200", code)
	}
	if code, _, _ := get(t, h, "GET", "/debug/bots/botplay-999999"); code != 404 {
		t.Errorf("unknown bot = %d, want 404", code)
	}
	if code, _, _ := get(t, h, "GET", "/debug/bots/botplay-000001?format=yaml"); code != 400 {
		t.Errorf("?format=yaml = %d, want 400", code)
	}
}

func TestTheSnapshotsAreNotChanged(t *testing.T) {
	src := snapshots()
	h := Handler(nil, func() []state.Snapshot { return src }, false)
	get(t, h, "GET", "/debug/bots")
	get(t, h, "GET", "/debug/bots/botplay-000002")
	if src[0].Bot != "botplay-000002" || len(src[0].Cards) != 3 {
		t.Error("serving the view changed the caller's snapshots")
	}
}

func TestTheDebugViewIsOffWithoutSnapshots(t *testing.T) {
	h := Handler(New(), nil, true)
	for _, p := range []string{"/debug/bots", "/debug/bots/botplay-000001"} {
		if code, _, _ := get(t, h, "GET", p); code != 404 {
			t.Errorf("%s with no snapshots = %d, want 404", p, code)
		}
	}
}

func TestOnlyGetIsServed(t *testing.T) {
	h := Handler(New(), snapshots, false)
	if code, _, _ := get(t, h, "POST", "/healthz"); code != http.StatusMethodNotAllowed {
		t.Errorf("POST /healthz = %d, want 405", code)
	}
	if code, _, _ := get(t, h, "GET", "/nothing"); code != 404 {
		t.Errorf("GET /nothing = %d", code)
	}
	if _, hdr, _ := get(t, h, "GET", "/healthz"); hdr.Get("Cache-Control") != "no-store" {
		t.Error("answers may be cached")
	}
}

// captureAddr is a slog handler that hands over Serve's bound address.
type captureAddr struct{ ch chan string }

func (c captureAddr) Enabled(context.Context, slog.Level) bool { return true }
func (c captureAddr) Handle(_ context.Context, r slog.Record) error {
	if r.Message == "observability serving" {
		r.Attrs(func(a slog.Attr) bool {
			if a.Key == "addr" {
				c.ch <- a.Value.String()
			}
			return true
		})
	}
	return nil
}
func (c captureAddr) WithAttrs([]slog.Attr) slog.Handler { return c }
func (c captureAddr) WithGroup(string) slog.Handler      { return c }

func TestServeRunsUntilTheContextEnds(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	addrs := make(chan string, 1)
	done := make(chan error, 1)
	go func() {
		done <- Serve(ctx, "127.0.0.1:0", New(), snapshots, false, slog.New(captureAddr{addrs}))
	}()
	var addr string
	select {
	case addr = <-addrs:
	case err := <-done:
		t.Fatalf("Serve returned early: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("Serve did not start")
	}
	resp, err := http.Get("http://" + addr + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(body), `"bots": 2`) {
		t.Errorf("/healthz = %d %s", resp.StatusCode, body)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("Serve after cancel = %v, want nil", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Serve did not stop")
	}
}

func TestServeWithNoAddressServesNothing(t *testing.T) {
	if err := Serve(context.Background(), "", New(), snapshots, false, nil); err != nil {
		t.Errorf("Serve(\"\") = %v", err)
	}
}

func TestServeReportsABadAddress(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := Serve(ctx, "127.0.0.1:notaport", nil, nil, false, nil); err == nil {
		t.Error("Serve on a bad address returned nil")
	}
}
