package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Report Player (owner, 27 Sep 2026) on the real wiring: players seated over
// real sockets, POST /api/reports through RequireAuth and the limiters, the
// room's own answer for where the two met, and PostgreSQL. What the report
// row holds is the server's — the table, its game and category, the hand in
// play — and a report changes nothing at the table: the hand plays on, the
// seats stay, no wallet moves.

const reportFiled = `{"success":true,"message":"Report submitted successfully.",` +
	`"limit":{"max":2,"used":1,"remaining":1,"windowMs":86400000,"availableAt":0,"waitMs":0}}`

// reportLimitOf is the limit an answer carries: {limit:{…}}.
func reportLimitOf(t *testing.T, label string, raw []byte) auth.ReportLimitView {
	t.Helper()
	var body struct {
		Limit *auth.ReportLimitView `json:"limit"`
	}
	if err := json.Unmarshal(raw, &body); err != nil || body.Limit == nil {
		t.Fatalf("%s: no limit in %s (%v)", label, raw, err)
	}
	return *body.Limit
}

// mustBeSpentForADay holds a limit to both reports used, the next opening a
// whole window (24 h) after the first of them — at most, and no more than a
// minute less, for the time the test itself takes.
func mustBeSpentForADay(t *testing.T, label string, l auth.ReportLimitView) {
	t.Helper()
	day := (24 * time.Hour).Milliseconds()
	if l.Max != 2 || l.Used != 2 || l.Remaining != 0 || l.WindowMs != day ||
		l.WaitMs > day || l.WaitMs < day-time.Minute.Milliseconds() || l.AvailableAt == 0 {
		t.Fatalf("%s: %+v, want both reports used for about 24 h", label, l)
	}
}

// reportRow is one player_reports row as a moderator would read it.
type reportRow struct {
	Reporter, Reported, Reason, Game, Category, TableID, Status string
	Description, Variant, HandID                                *string
	CreatedAt, UpdatedAt                                        int64
}

func reportsAbout(t *testing.T, database *db.DB, reported string) []reportRow {
	t.Helper()
	rows, err := database.Pool.Query(context.Background(), `SELECT reporter_user_id, reported_user_id, reason, game,
	       category, table_id, status, description, variant, hand_id, created_at, updated_at
	  FROM player_reports WHERE reported_user_id = $1 ORDER BY id`, reported)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []reportRow
	for rows.Next() {
		var r reportRow
		if err := rows.Scan(&r.Reporter, &r.Reported, &r.Reason, &r.Game, &r.Category, &r.TableID, &r.Status,
			&r.Description, &r.Variant, &r.HandID, &r.CreatedAt, &r.UpdatedAt); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	return out
}

func reportBody(reported, reason, description string) string {
	raw, _ := json.Marshal(map[string]any{"reportedUserId": reported, "reason": reason, "description": description})
	return string(raw)
}

func handStartedID(t *testing.T, raw json.RawMessage) string {
	t.Helper()
	id, _ := jsonPath(raw, "handId").(string)
	if id == "" {
		t.Fatalf("game:handStarted without a hand id: %s", raw)
	}
	return id
}

func reportTestConfig(t *testing.T) *config.Config {
	cfg := testConfig(t, publicDir(t))
	// The hand stays on its first turn, and a dropped socket keeps its seat,
	// for as long as a test takes.
	cfg.Game.TurnTimeout = 30 * time.Second
	cfg.Game.ReconnectGrace = 30 * time.Second
	return cfg
}

func TestAReportFromTheTableIsFiledWithTheTableAndTheHandAndChangesNothing(t *testing.T) {
	database := dbtest.Open(t, "app")
	cfg := reportTestConfig(t)
	a := newAppOn(t, cfg, database, livetest.New())
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	tokA, idA := login(t, ts.URL, "report-device-alice-01", "Alice")
	tokB, idB := login(t, ts.URL, "report-device-bobby-01", "Bobby")
	tokC, idC := login(t, ts.URL, "report-device-carla-01", "Carla")
	ca, cb := dial(t, ts.URL, tokA), dial(t, ts.URL, tokB)
	dial(t, ts.URL, tokC) // in the lobby
	join := map[string]any{"bootAmount": 200, "category": "seen"}
	joined := mustOK(t, ca, socket.EvRoomQuickJoin, join)
	mustOK(t, cb, socket.EvRoomQuickJoin, join)
	roomID, _ := jsonPath(joined.Raw, "roomId").(string)
	code, _ := jsonPath(joined.Raw, "code").(string)
	started, err := ca.Wait(socket.EvGameHandStarted, nil, 4*time.Second)
	if err != nil {
		t.Fatalf("no hand: %v", err)
	}
	handID := handStartedID(t, started)
	chipsBefore := map[string]int64{}
	for _, id := range []string{idA, idB} {
		var chips int64
		_ = database.Pool.QueryRow(ctx, `SELECT chips FROM users WHERE id = $1`, id).Scan(&chips)
		chipsBefore[id] = chips
	}
	table := game.AsTable(a.Rooms().GetTable(roomID))
	version := table.Version()

	// Alice reports Bob from the table: the brief's answer, nothing more.
	status, raw := friendsCall(t, ts.URL, tokA, http.MethodPost, "/api/reports",
		reportBody(idB, "SUSPICIOUS_GAMEPLAY", "Raises blind every hand"))
	mustStatus(t, "Alice reports Bob", status, http.StatusCreated, raw)
	mustBody(t, "Alice reports Bob", raw, reportFiled)
	for _, secret := range []string{roomID, code, handID} {
		if strings.Contains(string(raw), secret) {
			t.Fatalf("the answer names %s: %s", secret, raw)
		}
	}
	rows := reportsAbout(t, database, idB)
	if len(rows) != 1 {
		t.Fatalf("%d reports about Bob", len(rows))
	}
	// Alice's own list names Bobby — by name, never by id — and nothing of
	// the table or the hand.
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodGet, "/api/reports/mine", "")
	mustStatus(t, "Alice's reports", status, http.StatusOK, raw)
	var mine auth.MyReportsAnswer
	if err := json.Unmarshal(raw, &mine); err != nil || len(mine.Reports) != 1 {
		t.Fatalf("Alice's reports: %s (%v)", raw, err)
	}
	if r := mine.Reports[0]; r.Player.DisplayName != "Bobby" || r.Reason != "SUSPICIOUS_GAMEPLAY" ||
		r.Description != "Raises blind every hand" || r.Status != "PENDING" || r.Game != "teen_patti" ||
		r.Category != "seen" || r.CreatedAt == 0 {
		t.Fatalf("Alice's report: %+v", r)
	}
	for _, secret := range []string{idB, roomID, code, handID} {
		if strings.Contains(string(raw), secret) {
			t.Fatalf("Alice's list names %s: %s", secret, raw)
		}
	}
	r := rows[0]
	if r.Reporter != idA || r.Reason != "SUSPICIOUS_GAMEPLAY" || r.Game != "teen_patti" || r.Category != "seen" ||
		r.TableID != roomID || r.HandID == nil || *r.HandID != handID || r.Variant != nil || r.Status != "PENDING" ||
		r.Description == nil || *r.Description != "Raises blind every hand" || r.CreatedAt == 0 || r.UpdatedAt != r.CreatedAt {
		t.Fatalf("the report row: %+v", r)
	}

	// Nothing at the table moved: the hand plays on, both stay seated, no
	// wallet or ledger row changed.
	if !table.HasHand() || mustSnapshotOfApp(t, a, roomID) == nil || table.Version() != version {
		t.Fatal("the report touched the hand")
	}
	if jsonPath(mustSnapshotOfApp(t, a, roomID), "hand.id") != handID {
		t.Fatal("the hand in play changed")
	}
	for _, id := range []string{idA, idB} {
		if a.Rooms().GetTableForPlayer(id) == nil {
			t.Fatalf("%s was unseated", id)
		}
		var chips int64
		_ = database.Pool.QueryRow(ctx, `SELECT chips FROM users WHERE id = $1`, id).Scan(&chips)
		if chips != chipsBefore[id] {
			t.Fatalf("%s's wallet moved: %d → %d", id, chipsBefore[id], chips)
		}
	}

	// The same hand again → already_reported; Bob may report Alice; Carla, in
	// the lobby, may report neither; nobody reports themselves.
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodPost, "/api/reports", reportBody(idB, "CHEATING", ""))
	mustStatus(t, "Alice reports Bob again", status, http.StatusConflict, raw)
	mustBody(t, "Alice reports Bob again", raw, `{"error":"already_reported","message":"You have already reported this player."}`)
	status, raw = friendsCall(t, ts.URL, tokB, http.MethodPost, "/api/reports", reportBody(idA, "HARASSMENT", ""))
	mustStatus(t, "Bob reports Alice", status, http.StatusCreated, raw)
	status, raw = friendsCall(t, ts.URL, tokC, http.MethodPost, "/api/reports", reportBody(idA, "CHEATING", ""))
	mustStatus(t, "Carla, in the lobby", status, http.StatusConflict, raw)
	mustBody(t, "Carla, in the lobby", raw, `{"error":"player_not_at_table","message":"You can only report a player you are playing with."}`)
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodPost, "/api/reports", reportBody(idC, "CHEATING", ""))
	mustStatus(t, "a player in the lobby", status, http.StatusConflict, raw)
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodPost, "/api/reports", reportBody(idA, "CHEATING", ""))
	mustStatus(t, "oneself", status, http.StatusBadRequest, raw)
	status, raw = friendsCall(t, ts.URL, "", http.MethodPost, "/api/reports", reportBody(idB, "CHEATING", ""))
	mustStatus(t, "no session", status, http.StatusUnauthorized, raw)
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodPost, "/api/reports", `{"reportedUserId":`)
	mustStatus(t, "a malformed body", status, http.StatusBadRequest, raw)

	// The database failing files nothing, answers the plain 500, and the table
	// is none the worse for it.
	if _, err := database.Pool.Exec(ctx, `ALTER TABLE player_reports RENAME TO player_reports_away`); err != nil {
		t.Fatal(err)
	}
	status, raw = friendsCall(t, ts.URL, tokB, http.MethodPost, "/api/reports", reportBody(idA, "SPAM", ""))
	if _, err := database.Pool.Exec(ctx, `ALTER TABLE player_reports_away RENAME TO player_reports`); err != nil {
		t.Fatal(err)
	}
	mustStatus(t, "the database down", status, http.StatusInternalServerError, raw)
	mustBody(t, "the database down", raw, `{"error":"internal_error","message":"Something went wrong"}`)
	if !table.HasHand() || a.Rooms().GetTableForPlayer(idB) == nil {
		t.Fatal("a failed report touched the table")
	}
	if n := len(reportsAbout(t, database, idA)); n != 1 {
		t.Fatalf("%d reports about Alice, want Bob's one", n)
	}
}

// A player who leaves before the report is sent stays reportable (REPORT_RECENT_MS),
// named for the hand they walked out of; a reporter whose socket drops keeps
// their seat through the grace, and reports from it and after reconnecting.
func TestAPlayerWhoLeftAndAReporterWhoDroppedAreStillInTheGame(t *testing.T) {
	database := dbtest.Open(t, "app")
	cfg := reportTestConfig(t)
	cfg.Reports.MaxPerReporter = 5
	a := newAppOn(t, cfg, database, livetest.New())
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	tokA, idA := login(t, ts.URL, "report-device-alice-02", "Alice")
	tokB, idB := login(t, ts.URL, "report-device-bobby-02", "Bobby")
	tokC, idC := login(t, ts.URL, "report-device-carla-02", "Carla")
	ca, cb, cc := dial(t, ts.URL, tokA), dial(t, ts.URL, tokB), dial(t, ts.URL, tokC)
	join := map[string]any{"bootAmount": 200, "category": "seen"}
	joined := mustOK(t, ca, socket.EvRoomQuickJoin, join)
	roomID, _ := jsonPath(joined.Raw, "roomId").(string)
	mustOK(t, cb, socket.EvRoomQuickJoin, join)
	started, err := ca.Wait(socket.EvGameHandStarted, nil, 4*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	handID := handStartedID(t, started)
	mustOK(t, cc, socket.EvRoomQuickJoin, join) // sits out the hand in play

	// Bob walks out of the hand; Alice's report of him still lands, named for it.
	mustOK(t, cb, socket.EvRoomLeave, map[string]any{})
	if a.Rooms().GetTableForPlayer(idB) != nil {
		t.Fatal("Bob is still seated")
	}
	status, raw := friendsCall(t, ts.URL, tokA, http.MethodPost, "/api/reports", reportBody(idB, "ABUSIVE_LANGUAGE", ""))
	mustStatus(t, "Alice reports Bob, gone", status, http.StatusCreated, raw)
	rows := reportsAbout(t, database, idB)
	if len(rows) != 1 || rows[0].TableID != roomID || rows[0].HandID == nil || *rows[0].HandID != handID {
		t.Fatalf("the report of a player who left: %+v", rows)
	}
	// Carla sat beside Bob; she may report him too — two players, one target.
	status, raw = friendsCall(t, ts.URL, tokC, http.MethodPost, "/api/reports", reportBody(idB, "SPAM", ""))
	mustStatus(t, "Carla reports Bob", status, http.StatusCreated, raw)
	// Carla was dealt no hand, but watched Bob's from her seat: a report names
	// the REPORTED player's hand — the one Bob walked out of.
	if rows := reportsAbout(t, database, idB); len(rows) != 2 || rows[1].HandID == nil || *rows[1].HandID != handID {
		t.Fatalf("Carla's report: %+v", rows)
	}

	// Alice's socket drops: her seat is held, and she reports from it.
	ca.Close()
	if !ca.WaitClosed(4 * time.Second) {
		t.Fatal("the socket did not close")
	}
	time.Sleep(100 * time.Millisecond)
	if a.Rooms().GetTableForPlayer(idA) == nil {
		t.Fatal("Alice lost her seat inside the grace")
	}
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodPost, "/api/reports", reportBody(idC, "CHEATING", ""))
	mustStatus(t, "Alice, disconnected, reports Carla", status, http.StatusCreated, raw)
	// Back again: the same seat, and Carla may report her.
	back := dial(t, ts.URL, tokA)
	if _, err := back.Wait(socket.EvRoomJoined, nil, 4*time.Second); err != nil {
		t.Fatalf("Alice's seat was not resumed: %v", err)
	}
	status, raw = friendsCall(t, ts.URL, tokC, http.MethodPost, "/api/reports", reportBody(idA, "COLLUSION", ""))
	mustStatus(t, "Carla reports Alice", status, http.StatusCreated, raw)
}

// The owner's limit, end to end: two reports in 24 hours. The third is
// refused report_limit_reached — and still is after a restart, being counted
// from the reports themselves. After the restart, players still seated
// together are reportable (the restored room answers for them); one who left
// before it is not (who had left lived in the old process's memory).
func TestTheLimitAndTheTableSurviveARestartTheDeparturesDoNot(t *testing.T) {
	database := dbtest.Open(t, "app")
	store := livetest.New()
	cfg := reportTestConfig(t)
	first := newAppOn(t, cfg, database, store)
	ts1 := httptest.NewServer(first.Handler())
	defer ts1.Close()

	names := []string{"Alice", "Bobby", "Carla", "Devan", "Esher"}
	tokens, ids := map[string]string{}, map[string]string{}
	for i, name := range names {
		tokens[name], ids[name] = login(t, ts1.URL, fmt.Sprintf("report-device-%s-%02d", strings.ToLower(name), i+3), name)
		c := dial(t, ts1.URL, tokens[name])
		mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	}
	roomID := first.Rooms().GetTableForPlayer(ids["Alice"]).ID()
	for _, name := range names {
		if at := first.Rooms().GetTableForPlayer(ids[name]); at == nil || at.ID() != roomID {
			t.Fatalf("%s is not at Alice's table", name)
		}
	}
	// Esher leaves before the restart.
	if _, err := first.Rooms().Leave(ids["Esher"], game.LeaveReasonLeft); err != nil {
		t.Fatal(err)
	}

	report := func(base, from, about, reason string) (int, []byte) {
		return friendsCall(t, base, tokens[from], http.MethodPost, "/api/reports", reportBody(ids[about], reason, ""))
	}
	status, raw := report(ts1.URL, "Alice", "Bobby", "CHEATING")
	mustStatus(t, "Alice reports Bobby", status, http.StatusCreated, raw)
	// One slot left, two reports at once: exactly one lands.
	type answer struct {
		status int
		raw    []byte
	}
	answers := make(chan answer, 2)
	for _, about := range []string{"Esher", "Carla"} {
		go func() {
			s, r := report(ts1.URL, "Alice", about, "CHEATING")
			answers <- answer{s, r}
		}()
	}
	filed, limited := 0, 0
	for range 2 {
		switch a := <-answers; a.status {
		case http.StatusCreated:
			filed++
		case http.StatusTooManyRequests:
			limited++
			if !strings.HasPrefix(string(a.raw), `{"error":"report_limit_reached","message":"You have reached the report limit. Try again later.","limit":`) {
				t.Fatalf("Alice's third report in 24 h: %s", a.raw)
			}
			mustBeSpentForADay(t, "Alice's third report in 24 h", reportLimitOf(t, "the refusal", a.raw))
		default:
			t.Fatalf("a racing report: %d %s", a.status, a.raw)
		}
	}
	if filed != 1 || limited != 1 {
		t.Fatalf("%d filed and %d refused, want one of each", filed, limited)
	}

	// The process is replaced: suspended into the store, restored by the next.
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := first.Shutdown(ctx); err != nil {
		t.Fatalf("shutdown: %v", err)
	}
	second, err := New(Options{Config: cfg, DB: database, Logger: util.NewLogger("error", io.Discard), Live: store})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = second.Shutdown(context.Background()) })
	if restored := second.Restore(); restored.Tables != 1 || restored.Seats != 4 {
		t.Fatalf("restore: %+v", restored)
	}
	ts2 := httptest.NewServer(second.Handler())
	defer ts2.Close()

	status, raw = report(ts2.URL, "Alice", "Devan", "CHEATING")
	mustStatus(t, "Alice's third report after the restart", status, http.StatusTooManyRequests, raw)
	// …and the app, asking the new process, is told the same wait.
	status, raw = friendsCall(t, ts2.URL, tokens["Alice"], http.MethodGet, "/api/reports/limit", "")
	mustStatus(t, "Alice's limit after the restart", status, http.StatusOK, raw)
	mustBeSpentForADay(t, "Alice's limit after the restart", reportLimitOf(t, "the limit", raw))
	status, raw = friendsCall(t, ts2.URL, tokens["Carla"], http.MethodGet, "/api/reports/limit", "")
	mustStatus(t, "Carla's limit", status, http.StatusOK, raw)
	mustBody(t, "Carla's limit", raw, `{"limit":{"max":2,"used":0,"remaining":2,"windowMs":86400000,"availableAt":0,"waitMs":0}}`)
	status, raw = report(ts2.URL, "Bobby", "Devan", "COLLUSION")
	mustStatus(t, "Bobby reports Devan, both still seated", status, http.StatusCreated, raw)
	rows := reportsAbout(t, database, ids["Devan"])
	if len(rows) != 1 || rows[0].TableID != roomID || rows[0].Category != "seen" {
		t.Fatalf("the report after the restart: %+v", rows)
	}
	status, raw = report(ts2.URL, "Bobby", "Esher", "SPAM")
	mustStatus(t, "Esher left before the restart", status, http.StatusConflict, raw)
}
