package auth

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Report Player (owner, 27 Sep 2026; reports.go): POST /api/reports on a fake
// store and a fake table state. The server derives everything but who, why
// and what happened; every refusal is its own code; the answer is the brief's
// {success, message} and nothing else; and nothing the client sends about a
// table, a hand, a status, a time or a reporter is read.

// fakeReports records every report Submit is asked to file.
type fakeReports struct {
	mu      sync.Mutex
	filed   []db.PlayerReport
	limits  []db.ReportLimits
	failure error
}

func (f *fakeReports) Submit(_ context.Context, report db.PlayerReport, limits db.ReportLimits) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failure != nil {
		return 0, f.failure
	}
	f.filed = append(f.filed, report)
	f.limits = append(f.limits, limits)
	return int64(len(f.filed)), nil
}

// reportHarness is the harness's mux with the report route mounted: the fake
// accounts, the fake report store and a table the test seats players at.
type reportHarness struct {
	*harness
	reports *fakeReports
	// together is who shares a table with whom: reporter → reported → where.
	together map[string]map[string]game.ReportContext
}

func newReportHarness(t *testing.T, mutate func(*config.Config)) *reportHarness {
	t.Helper()
	cfg := config.Defaults()
	cfg.AllowFakeProviders = true
	// The per-account attempt limit has a test of its own; the rest make more
	// requests in a minute than it allows.
	cfg.Reports.AttemptLimit = 0
	if mutate != nil {
		mutate(cfg)
	}
	h := &harness{t: t, mux: http.NewServeMux(), store: newFakeStore(), cfg: cfg, seated: map[string]bool{}, logs: &bytes.Buffer{}}
	h.tokens = NewTokens(cfg.JWT.Secret, cfg.JWT.ExpiresIn, time.Now)
	rh := &reportHarness{harness: h, reports: &fakeReports{}, together: map[string]map[string]game.ReportContext{}}
	handler := NewHandler(Deps{
		Config:   cfg,
		Users:    h.store,
		Tokens:   h.tokens,
		Verifier: NewVerifier(cfg),
		Reports:  rh.reports,
		ReportContext: func(reporter, reported string) (game.ReportContext, bool) {
			ctx, ok := rh.together[reporter][reported]
			return ctx, ok
		},
		Logger: slog.New(slog.NewJSONHandler(h.logs, nil)),
	})
	handler.Register(h.mux)
	h.mux.Handle("/api/", NotFoundHandler())
	return rh
}

// seatTogether puts a and b at one table, in one hand.
func (rh *reportHarness) seatTogether(a, b string, where game.ReportContext) {
	for _, pair := range [][2]string{{a, b}, {b, a}} {
		if rh.together[pair[0]] == nil {
			rh.together[pair[0]] = map[string]game.ReportContext{}
		}
		rh.together[pair[0]][pair[1]] = where
	}
}

var atSeen200 = game.ReportContext{RoomID: "room-5d1f", Game: game.GameTeenPatti, Category: game.CategorySeen, HandID: "hand-77aa"}

func (rh *reportHarness) report(token string, body any) response {
	rh.t.Helper()
	return rh.do(http.MethodPost, "/api/reports", body, bearer(token)...)
}

func TestAReportIsFiledWithWhatTheServerKnowsAndAnsweredWithTheBriefsBody(t *testing.T) {
	rh := newReportHarness(t, nil)
	tokA, alice := rh.login("report-device-alice", "Alice")
	_, bob := rh.login("report-device-bobby", "Bob")
	aliceID, bobID := alice["id"].(string), bob["id"].(string)
	rh.seatTogether(aliceID, bobID, atSeen200)

	// Everything but the three fields is the server's to say — a client that
	// names a table, a hand, a status, a time, a game or a reporter is ignored.
	res := rh.report(tokA, map[string]any{
		"reportedUserId": "  " + strings.ToUpper(bobID) + " ", "reason": "COLLUSION",
		"description":    "  Always calls with Ravi\r\nand never folds \u202e ",
		"reporterUserId": bobID, "tableId": "room-forged", "handId": "hand-forged", "status": "DISMISSED",
		"createdAt": 1, "updatedAt": 1, "game": "poker", "category": "omaha", "variant": "MUFLIS",
	})
	if res.status != http.StatusCreated || string(res.raw) != `{"success":true,"message":"Report submitted successfully."}` {
		t.Fatalf("the answer: %d %s", res.status, res.raw)
	}
	if len(rh.reports.filed) != 1 {
		t.Fatalf("%d reports filed", len(rh.reports.filed))
	}
	got := rh.reports.filed[0]
	want := db.PlayerReport{ReporterID: aliceID, ReportedID: bobID, Reason: "COLLUSION",
		Description: "Always calls with Ravi\nand never folds", Game: "teen_patti", Category: "seen",
		TableID: "room-5d1f", HandID: "hand-77aa"}
	if got != want {
		t.Fatalf("filed %+v\nwant  %+v", got, want)
	}
	if lim := rh.reports.limits[0]; lim != (db.ReportLimits{MaxPerReporter: 2, Window: 24 * time.Hour, PairWindow: 24 * time.Hour}) {
		t.Fatalf("the limits handed to the store: %+v", lim)
	}

	// Every reason the brief lists is accepted.
	for _, reason := range ReportReasons {
		body := map[string]any{"reportedUserId": bobID, "reason": reason}
		if reason == ReportReasonOther {
			body["description"] = "Something else happened"
		}
		if res := rh.report(tokA, body); res.status != http.StatusCreated {
			t.Errorf("%s: %d %s", reason, res.status, res.raw)
		}
	}
	if !strings.Contains(rh.logs.String(), "player report filed") {
		t.Error("a filed report is logged")
	}
}

func TestAReportNeedsASignedInPlayer(t *testing.T) {
	rh := newReportHarness(t, nil)
	body := map[string]any{"reportedUserId": "user-2", "reason": "SPAM"}
	expectError(t, rh.do(http.MethodPost, "/api/reports", body), http.StatusUnauthorized, CodeMissingToken)
	expectError(t, rh.do(http.MethodPost, "/api/reports", body, bearer("not-a-token")...), http.StatusUnauthorized, CodeInvalidSession)
	if len(rh.reports.filed) != 0 {
		t.Fatal("an anonymous report was filed")
	}
}

func TestEveryReportRefusalHasItsOwnCode(t *testing.T) {
	rh := newReportHarness(t, nil)
	tokA, alice := rh.login("report-device-alice", "Alice")
	_, bob := rh.login("report-device-bobby", "Bob")
	_, carla := rh.login("report-device-carla", "Carla")
	aliceID, bobID, carlaID := alice["id"].(string), bob["id"].(string), carla["id"].(string)
	rh.seatTogether(aliceID, bobID, atSeen200)

	for _, c := range []struct {
		what   string
		body   any
		status int
		code   string
	}{
		{"not JSON", `{"reportedUserId":`, http.StatusBadRequest, CodeInvalidJSON},
		{"an array", `[{"reportedUserId":"x"}]`, http.StatusBadRequest, CodeInvalidJSON},
		{"no player", map[string]any{"reason": "SPAM"}, http.StatusBadRequest, CodeInvalidPlayerID},
		{"a number for a player", map[string]any{"reportedUserId": 7, "reason": "SPAM"}, http.StatusBadRequest, CodeInvalidPlayerID},
		{"a player id too long", map[string]any{"reportedUserId": strings.Repeat("a", 65), "reason": "SPAM"}, http.StatusBadRequest, CodeInvalidPlayerID},
		{"oneself", map[string]any{"reportedUserId": aliceID, "reason": "SPAM"}, http.StatusBadRequest, CodeSelfReport},
		{"oneself, shouted", map[string]any{"reportedUserId": strings.ToUpper(aliceID), "reason": "SPAM"}, http.StatusBadRequest, CodeSelfReport},
		{"no reason", map[string]any{"reportedUserId": bobID}, http.StatusBadRequest, CodeInvalidReportReason},
		{"a reason in lower case", map[string]any{"reportedUserId": bobID, "reason": "cheating"}, http.StatusBadRequest, CodeInvalidReportReason},
		{"a reason not on the list", map[string]any{"reportedUserId": bobID, "reason": "BAN_HIM"}, http.StatusBadRequest, CodeInvalidReportReason},
		{"a number for a reason", map[string]any{"reportedUserId": bobID, "reason": 1}, http.StatusBadRequest, CodeInvalidReportReason},
		{"OTHER with no description", map[string]any{"reportedUserId": bobID, "reason": "OTHER"}, http.StatusBadRequest, CodeDescriptionRequired},
		{"OTHER with blank lines", map[string]any{"reportedUserId": bobID, "reason": "OTHER", "description": " \n\t "}, http.StatusBadRequest, CodeDescriptionRequired},
		{"OTHER with a number", map[string]any{"reportedUserId": bobID, "reason": "OTHER", "description": 12}, http.StatusBadRequest, CodeDescriptionRequired},
		{"a description too long", map[string]any{"reportedUserId": bobID, "reason": "SPAM", "description": strings.Repeat("x", 501)}, http.StatusBadRequest, CodeDescriptionTooLong},
		{"too long in emoji", map[string]any{"reportedUserId": bobID, "reason": "SPAM", "description": strings.Repeat("😡", 501)}, http.StatusBadRequest, CodeDescriptionTooLong},
		{"a player at no table of hers", map[string]any{"reportedUserId": carlaID, "reason": "SPAM"}, http.StatusConflict, CodePlayerNotAtTable},
		{"an id nobody has", map[string]any{"reportedUserId": "0000-no-such-player", "reason": "SPAM"}, http.StatusConflict, CodePlayerNotAtTable},
	} {
		expectError(t, rh.report(tokA, c.body), c.status, c.code)
		if t.Failed() {
			t.Fatalf("%s", c.what)
		}
	}
	if len(rh.reports.filed) != 0 {
		t.Fatalf("%d refused reports were filed", len(rh.reports.filed))
	}
	// Exactly the limit is allowed, counted in characters, not bytes.
	for _, ok := range []string{strings.Repeat("x", 500), strings.Repeat("😡", 500)} {
		if res := rh.report(tokA, map[string]any{"reportedUserId": bobID, "reason": "SPAM", "description": ok}); res.status != http.StatusCreated {
			t.Fatalf("a description of exactly 500: %d %s", res.status, res.raw)
		}
	}
}

// The store's refusals: the report already made, the limit reached (with
// when to try again), the player gone, and a database that failed — which
// files nothing and answers the plain 500.
func TestTheStoresRefusalsAreWordedForThePlayer(t *testing.T) {
	rh := newReportHarness(t, nil)
	tokA, alice := rh.login("report-device-alice", "Alice")
	_, bob := rh.login("report-device-bobby", "Bob")
	rh.seatTogether(alice["id"].(string), bob["id"].(string), atSeen200)
	body := map[string]any{"reportedUserId": bob["id"], "reason": "SPAM"}

	rh.reports.failure = db.ErrAlreadyReported
	expectError(t, rh.report(tokA, body), http.StatusConflict, CodeAlreadyReported)
	rh.reports.failure = &db.ReportLimitReached{RetryAt: time.Now().Add(90 * time.Minute).UnixMilli()}
	res := rh.report(tokA, body)
	expectError(t, res, http.StatusTooManyRequests, CodeReportLimitReached)
	if ra := res.header.Get("Retry-After"); ra != "5400" && ra != "5399" {
		t.Errorf("Retry-After %q, want about 90 minutes", ra)
	}
	rh.reports.failure = db.ErrReportedNotFound
	expectError(t, rh.report(tokA, body), http.StatusNotFound, CodePlayerNotFound)
	rh.reports.failure = errors.New("connection refused")
	res = rh.report(tokA, body)
	expectError(t, res, http.StatusInternalServerError, CodeInternalError)
	if strings.Contains(string(res.raw), "connection refused") {
		t.Fatalf("a database failure leaks its cause: %s", res.raw)
	}
	if !strings.Contains(rh.logs.String(), "connection refused") {
		t.Error("a database failure is logged")
	}
}

// Every report request of an account counts, refused or not, and past the
// attempt limit is refused before anything is read — another account's are
// its own.
func TestRapidReportRequestsAreRefusedPerAccount(t *testing.T) {
	rh := newReportHarness(t, func(c *config.Config) {
		c.Reports.AttemptLimit = 3
		c.Reports.AttemptWindow = time.Minute
	})
	tokA, alice := rh.login("report-device-alice", "Alice")
	tokB, bob := rh.login("report-device-bobby", "Bob")
	rh.seatTogether(alice["id"].(string), bob["id"].(string), atSeen200)
	for range 3 {
		expectError(t, rh.report(tokA, `{"broken"`), http.StatusBadRequest, CodeInvalidJSON)
	}
	res := rh.report(tokA, map[string]any{"reportedUserId": bob["id"], "reason": "SPAM"})
	expectError(t, res, http.StatusTooManyRequests, CodeRateLimited)
	if res.header.Get("Retry-After") == "" {
		t.Error("no Retry-After on the attempt limit")
	}
	if res := rh.report(tokB, map[string]any{"reportedUserId": alice["id"], "reason": "SPAM"}); res.status != http.StatusCreated {
		t.Fatalf("another account: %d %s", res.status, res.raw)
	}
}

// There is one report route, POST: no report is listed, read, changed or
// deleted through the API, so no player sets a status or touches another's.
func TestNoRouteReadsOrChangesAReport(t *testing.T) {
	rh := newReportHarness(t, nil)
	tokA, _ := rh.login("report-device-alice", "Alice")
	for _, c := range []struct{ method, path string }{
		{http.MethodGet, "/api/reports"},
		{http.MethodPut, "/api/reports"},
		{http.MethodPatch, "/api/reports"},
		{http.MethodDelete, "/api/reports"},
		{http.MethodGet, "/api/reports/1"},
		{http.MethodPatch, "/api/reports/1"},
		{http.MethodPost, "/api/reports/1/status"},
	} {
		expectError(t, rh.do(c.method, c.path, map[string]any{"status": "DISMISSED"}, bearer(tokA)...), http.StatusNotFound, CodeNotFound)
	}
}

// The answer to a report — filed or refused — never carries a room, a hand, a
// report id or a status.
func TestAReportAnswerNamesNoTableHandOrStatus(t *testing.T) {
	rh := newReportHarness(t, nil)
	tokA, alice := rh.login("report-device-alice", "Alice")
	_, bob := rh.login("report-device-bobby", "Bob")
	rh.seatTogether(alice["id"].(string), bob["id"].(string), atSeen200)
	var answers [][]byte
	answers = append(answers, rh.report(tokA, map[string]any{"reportedUserId": bob["id"], "reason": "SPAM"}).raw)
	rh.reports.failure = db.ErrAlreadyReported
	answers = append(answers, rh.report(tokA, map[string]any{"reportedUserId": bob["id"], "reason": "SPAM"}).raw)
	rh.reports.failure = &db.ReportLimitReached{RetryAt: time.Now().Add(time.Hour).UnixMilli()}
	answers = append(answers, rh.report(tokA, map[string]any{"reportedUserId": bob["id"], "reason": "SPAM"}).raw)
	for _, raw := range answers {
		lower := strings.ToLower(string(raw))
		for _, word := range []string{"room", "table", "hand", "status", "pending", "reportid", "\"id\"", "moderat", "ban"} {
			if strings.Contains(lower, word) {
				t.Errorf("a report answer carries %q: %s", word, raw)
			}
		}
	}
}

func TestADescriptionKeepsItsLinesAndLosesItsControlCharacters(t *testing.T) {
	for raw, want := range map[string]string{
		"":                            "",
		"   ":                         "",
		" plain ":                     "plain",
		"one\r\ntwo\rthree\nfour":     "one\ntwo\nthree\nfour",
		"tab\there":                   "tab here",
		"bell\a and \x00nul":          "bell  and  nul",
		"rtl \u202eevil\u202c":        "rtl  evil",
		"👨\u200d👩\u200d👧 family kept": "👨\u200d👩\u200d👧 family kept",
	} {
		if got := NormalizeReportDescription(raw); got != want {
			t.Errorf("NormalizeReportDescription(%q) = %q, want %q", raw, got, want)
		}
	}
}
