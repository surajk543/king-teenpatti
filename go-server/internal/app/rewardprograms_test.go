package app

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
)

// The reward programs over HTTP on the real wiring (owner, 30 Sep 2026): GET
// /api/reward-programs and POST /api/reward-programs/claim through
// RequireAuth, the wallet limiter and rooms.WhileUnseated, PostgreSQL
// underneath, on the owner's seeded programs. The server decides: a day or a
// reward the body names is ignored, every program's today is granted once
// and never again that day, the books balance, and a seated player is sent to
// the lobby — though they may still look.
func TestTheRewardProgramsAreClaimedFromTheLobbyOnceADay(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	token, id := login(t, ts.URL, "reward-player", "Rewarded")
	authed := func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) }

	type program struct {
		Program struct {
			Code       string `json:"code"`
			Mode       string `json:"mode"`
			PeriodType string `json:"periodType"`
		} `json:"program"`
		CurrentDay   int  `json:"currentDay"`
		ClaimedToday bool `json:"claimedToday"`
		ClaimedDays  int  `json:"claimedDays"`
		PeriodDays   int  `json:"periodDays"`
		Rewards      []struct {
			Day        int    `json:"day"`
			RewardType string `json:"rewardType"`
			Claimed    bool   `json:"claimed"`
		} `json:"rewards"`
	}
	read := func(body []byte) []program {
		var state struct {
			Programs []program `json:"programs"`
		}
		if err := json.Unmarshal(body, &state); err != nil {
			t.Fatalf("%v: %s", err, body)
		}
		return state.Programs
	}

	// Before any claim: the four programs, nothing claimed.
	res, body := get(t, a.Handler(), http.MethodGet, "/api/reward-programs", authed)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/reward-programs: %d %s", res.StatusCode, body)
	}
	programs := read(body)
	// The seed runs the weekly login streak alone (the other three wait,
	// inactive, for their days).
	want := []string{"WEEKLY_LOGIN"}
	if len(programs) != len(want) {
		t.Fatalf("%d programs: %s", len(programs), body)
	}
	for i, p := range programs {
		if p.Program.Code != want[i] || p.ClaimedToday || p.ClaimedDays != 0 || len(p.Rewards) == 0 {
			t.Fatalf("program %d before any claim: %+v", i, p)
		}
	}
	if programs[0].CurrentDay != 1 || programs[0].PeriodDays != 7 || len(programs[0].Rewards) != 7 || programs[0].Program.Mode != "LOGIN_STREAK" {
		t.Fatalf("the weekly streak before any claim: %+v", programs[0])
	}
	if res, _ := get(t, a.Handler(), http.MethodGet, "/api/reward-programs", nil); res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("an anonymous look at the programs: %d", res.StatusCode)
	}

	wallet := func(column string) int64 {
		var v int64
		if err := database.Pool.QueryRow(ctx, `SELECT `+column+` FROM users WHERE id = $1`, id).Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	chips := wallet("chips")

	// A claim whose body names a program, a day and a reward of its own: the
	// program is honoured (since 1 Oct 2026 a claim may name the one it
	// collects), the day and the reward are the server's regardless.
	claim := postJSON(ts.URL, token, "/api/reward-programs/claim", map[string]any{
		"programCode": "WEEKLY_LOGIN", "day": 7, "rewardType": "CHIPS", "rewardValue": 99_999_999,
	})
	if claim.err != nil || claim.status != http.StatusOK {
		t.Fatalf("the claim: %d %v %v", claim.status, claim.body, claim.err)
	}
	granted, _ := claim.body["granted"].([]any)
	// The one program the seed runs, the owner's weekly login streak, gives
	// today's — its Day 1, the chips its seeded row names (the other three are
	// seeded inactive, with no days).
	if len(granted) != 1 {
		t.Fatalf("%d rewards granted, want 1: %v", len(granted), claim.body["granted"])
	}
	var chipsGranted int64
	codes := map[string]bool{}
	for _, g := range granted {
		grant := g.(map[string]any)
		codes[grant["programCode"].(string)] = true
		if grant["rewardType"] == "CHIPS" {
			chipsGranted += int64(grant["rewardValue"].(float64))
		}
		if _, ok := grant["day"].(float64); !ok || grant["mode"] == nil {
			t.Fatalf("a grant names its day and its program's mode: %v", grant)
		}
	}
	if len(codes) != 1 || !codes["WEEKLY_LOGIN"] {
		t.Fatalf("the grants' programs: %v", codes)
	}
	var day1 int64
	if err := database.Pool.QueryRow(ctx, `SELECT r.reward_value FROM reward_program_rewards r JOIN reward_programs p ON p.id = r.program_id
	      WHERE p.code = 'WEEKLY_LOGIN' AND r.day_number = 1 AND r.reward_type = 'CHIPS'`).Scan(&day1); err != nil {
		t.Fatalf("the seed's WEEKLY_LOGIN Day 1: %v", err)
	}
	if chipsGranted != day1 {
		t.Fatalf("chips granted %d, want Day 1's %d", chipsGranted, day1)
	}
	if got := wallet("chips"); got != chips+chipsGranted {
		t.Fatalf("chips %d, want %d after grants of %d", got, chips+chipsGranted, chipsGranted)
	}
	if user, ok := claim.body["user"].(map[string]any); !ok || user["id"] != id {
		t.Fatalf("the claim answers with the account: %v", claim.body["user"])
	}
	after, _ := json.Marshal(claim.body)
	for i, p := range read(after) {
		if !p.ClaimedToday || p.ClaimedDays == 0 {
			t.Fatalf("program %d after the claim: %+v", i, p)
		}
	}

	// Again, and again: nothing more today.
	for i := 0; i < 2; i++ {
		again := postJSON(ts.URL, token, "/api/reward-programs/claim", map[string]any{})
		if again.err != nil || again.status != http.StatusOK {
			t.Fatalf("claim %d: %d %v %v", i+2, again.status, again.body, again.err)
		}
		if granted, _ := again.body["granted"].([]any); len(granted) != 0 {
			t.Fatalf("claim %d granted %v", i+2, granted)
		}
	}
	if got := wallet("chips"); got != chips+chipsGranted {
		t.Fatalf("chips moved on a repeated claim: %d", got)
	}
	var claims, ledgerRows int64
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM user_reward_claims WHERE user_id = $1`, id).Scan(&claims); err != nil || claims != 1 {
		t.Fatalf("%d claims recorded (%v), want 1", claims, err)
	}
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM chip_ledger WHERE user_id = $1 AND reason = 'reward_program'`, id).Scan(&ledgerRows); err != nil {
		t.Fatal(err)
	}
	var ledger int64
	if err := database.Pool.QueryRow(ctx, `SELECT COALESCE(SUM(delta), 0)::bigint FROM chip_ledger WHERE user_id = $1`, id).Scan(&ledger); err != nil {
		t.Fatal(err)
	}
	if ledger != wallet("chips") || (chipsGranted > 0 && ledgerRows == 0) {
		t.Fatalf("the wallet (%d) no longer equals its ledger (%d); %d reward rows", wallet("chips"), ledger, ledgerRows)
	}
	// The state read after says the same as the claim's answer.
	_, body = get(t, a.Handler(), http.MethodGet, "/api/reward-programs", authed)
	for i, p := range read(body) {
		if !p.ClaimedToday {
			t.Fatalf("program %d read after the claim: %+v", i, p)
		}
	}

	// Seated: sent to the lobby, and nothing claimed; looking is allowed.
	seatedToken, seatedID := login(t, ts.URL, "reward-sitter", "Sitter")
	c := dial(t, ts.URL, seatedToken)
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	if a.Rooms().GetTableForPlayer(seatedID) == nil {
		t.Fatal("the sitter is not seated")
	}
	seated := postJSON(ts.URL, seatedToken, "/api/reward-programs/claim", map[string]any{})
	if seated.err != nil || seated.status != http.StatusConflict || seated.body["error"] != auth.CodeSeated {
		t.Fatalf("a seated claim: %d %v %v", seated.status, seated.body, seated.err)
	}
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM user_reward_claims WHERE user_id = $1`, seatedID).Scan(&claims); err != nil || claims != 0 {
		t.Fatalf("a seated claim was recorded: %d %v", claims, err)
	}
	res, body = get(t, a.Handler(), http.MethodGet, "/api/reward-programs", func(r *http.Request) {
		r.Header.Set("Authorization", "Bearer "+seatedToken)
	})
	if res.StatusCode != http.StatusOK || len(read(body)) != 1 {
		t.Fatalf("a seated look at the programs: %d %s", res.StatusCode, body)
	}
}

// The progression types over HTTP (owner, 1 Oct 2026): the look carries the
// server's clock, each program's progression, status and cycles and each
// day's standing; a claim may name one program and is refused, by name, one
// that does not run or whose cycle is broken; a retry is answered with the
// claim it repeats; a body that is not JSON is refused before anything moves.
func TestARewardClaimCanNameOneProgramAndIsRefusedOneItCannotClaim(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	token, id := login(t, ts.URL, "reward-namer", "Namer")
	authed := func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) }
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := database.Pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}

	// The look.
	res, body := get(t, a.Handler(), http.MethodGet, "/api/reward-programs", authed)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET: %d %s", res.StatusCode, body)
	}
	var view struct {
		ServerTime int64 `json:"serverTime"`
		Programs   []struct {
			Program struct {
				Code            string `json:"code"`
				ProgressionType string `json:"progressionType"`
			} `json:"program"`
			Status   string `json:"status"`
			CanClaim bool   `json:"canClaim"`
			NextDay  int    `json:"nextDay"`
			Period   struct {
				StartAt   int64  `json:"startAt"`
				EndAt     int64  `json:"endAt"`
				StartDate string `json:"startDate"`
				EndDate   string `json:"endDate"`
			} `json:"period"`
			NextPeriod *struct {
				StartAt    int64 `json:"startAt"`
				StartsInMs int64 `json:"startsInMs"`
			} `json:"nextPeriod"`
			Rewards []struct {
				State string `json:"state"`
			} `json:"rewards"`
		} `json:"programs"`
	}
	if err := json.Unmarshal(body, &view); err != nil {
		t.Fatal(err)
	}
	if view.ServerTime <= 0 || len(view.Programs) != 1 {
		t.Fatalf("the look: %s", body)
	}
	w := view.Programs[0]
	if w.Program.Code != "WEEKLY_LOGIN" || w.Program.ProgressionType != "RESET" || w.Status != "ACTIVE" || !w.CanClaim ||
		w.NextDay != 1 || w.Period.StartDate == "" || w.Period.EndDate == "" || w.Period.EndAt <= w.Period.StartAt ||
		w.NextPeriod == nil || w.NextPeriod.StartAt != w.Period.EndAt || w.NextPeriod.StartsInMs <= 0 ||
		len(w.Rewards) != 7 || w.Rewards[0].State != "AVAILABLE" || w.Rewards[1].State != "LOCKED" {
		t.Fatalf("WEEKLY_LOGIN as the app reads it: %s", body)
	}

	// A body that is not JSON.
	res, body = get(t, a.Handler(), http.MethodPost, "/api/reward-programs/claim", func(r *http.Request) {
		authed(r)
		r.Header.Set("Content-Type", "application/json")
		r.Body = io.NopCloser(strings.NewReader(`{"programCode": 5}`))
	})
	if res.StatusCode != http.StatusBadRequest || !strings.Contains(string(body), auth.CodeInvalidJSON) {
		t.Fatalf("a programCode that is not text: %d %s", res.StatusCode, body)
	}

	// Named claims of programs it cannot claim.
	exec(`UPDATE reward_programs SET is_active = TRUE, ends_at = 1 WHERE code = 'MONTHLY_LOGIN'`)
	// WEEKLY_SEQUENTIAL_CAL, switched on with its week starting two days ago
	// in its zone, whatever today is: Days 1 and 2 were required and missed,
	// so its cycle is broken before the player first looks.
	kolkata, err := time.LoadLocation("Asia/Kolkata")
	if err != nil {
		t.Fatal(err)
	}
	today := int(time.Now().In(kolkata).Weekday()) // 0 Sunday
	if today == 0 {
		today = 7
	}
	weekStart := (today-2+6)%7 + 1
	exec(`UPDATE reward_programs SET is_active = TRUE, week_start_day = $1 WHERE code = 'WEEKLY_SEQUENTIAL_CAL'`, weekStart)
	for code, want := range map[string][2]any{
		"NO_SUCH_PROGRAM":       {http.StatusNotFound, auth.CodeRewardProgramNotFound},
		"WEEKLY_SEQUENTIAL":     {http.StatusNotFound, auth.CodeRewardProgramNotFound},
		"MONTHLY_LOGIN":         {http.StatusConflict, auth.CodeRewardProgramNotRunning},
		"WEEKLY_SEQUENTIAL_CAL": {http.StatusConflict, auth.CodeRewardCycleBroken},
	} {
		out := postJSON(ts.URL, token, "/api/reward-programs/claim", map[string]any{"programCode": code})
		if out.err != nil || out.status != want[0] || out.body["error"] != want[1] {
			t.Errorf("%s: %d %v %v, want %d %s", code, out.status, out.body, out.err, want[0], want[1])
		}
	}

	// The one it can, by name — then again: answered with that claim.
	first := postJSON(ts.URL, token, "/api/reward-programs/claim", map[string]any{"programCode": "WEEKLY_LOGIN"})
	results, _ := first.body["results"].([]any)
	if first.status != http.StatusOK || len(results) != 1 || results[0].(map[string]any)["outcome"] != "GRANTED" {
		t.Fatalf("the named claim: %d %v", first.status, first.body)
	}
	again := postJSON(ts.URL, token, "/api/reward-programs/claim", map[string]any{"programCode": "WEEKLY_LOGIN"})
	results, _ = again.body["results"].([]any)
	if again.status != http.StatusOK || len(results) != 1 {
		t.Fatalf("the retry: %d %v", again.status, again.body)
	}
	r := results[0].(map[string]any)
	if r["outcome"] != "ALREADY_CLAIMED" || r["day"] != float64(1) || r["rewardType"] != "CHIPS" || r["claimedAt"] == nil {
		t.Fatalf("the retry's result: %v", r)
	}
	if granted, _ := again.body["granted"].([]any); len(granted) != 0 {
		t.Fatalf("the retry granted %v", granted)
	}
	// A claim of every program: WEEKLY_LOGIN already claimed, the broken
	// calendar BROKEN, MONTHLY_LOGIN not running and so not there at all.
	all := postJSON(ts.URL, token, "/api/reward-programs/claim", map[string]any{})
	results, _ = all.body["results"].([]any)
	outcomes := map[string]any{}
	for _, x := range results {
		m := x.(map[string]any)
		outcomes[m["programCode"].(string)] = m["outcome"]
	}
	if all.status != http.StatusOK || len(outcomes) != 2 || outcomes["WEEKLY_LOGIN"] != "ALREADY_CLAIMED" || outcomes["WEEKLY_SEQUENTIAL_CAL"] != "BROKEN" {
		t.Fatalf("every program: %d %v", all.status, all.body["results"])
	}
	var claims, progress int64
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM user_reward_claims WHERE user_id = $1`, id).Scan(&claims); err != nil || claims != 1 {
		t.Fatalf("%d claims (%v), want 1", claims, err)
	}
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM user_reward_progress WHERE user_id = $1 AND status = 'BROKEN'`, id).Scan(&progress); err != nil || progress != 1 {
		t.Fatalf("%d broken progress rows (%v), want the calendar's", progress, err)
	}
}
