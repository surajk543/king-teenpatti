package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
)

// The reward programs over HTTP on the real wiring (owner, 30 Sep 2026): GET
// /api/reward-programs and POST /api/reward-programs/claim through
// RequireAuth, the wallet limiter and rooms.WhileUnseated, PostgreSQL
// underneath, on the owner's four seeded programs. The server decides: a
// program, a day or a reward the body names is ignored, every program's today
// is granted once and never again that day, the books balance, and a seated
// player is sent to the lobby — though they may still look.
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
	want := []string{"WEEKLY_LOGIN", "MONTHLY_LOGIN", "WEEKLY_CALENDAR", "MONTHLY_CALENDAR"}
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
	// server decides regardless.
	claim := postJSON(ts.URL, token, "/api/reward-programs/claim", map[string]any{
		"programCode": "WEEKLY_LOGIN", "day": 7, "rewardType": "CHIPS", "rewardValue": 99_999_999,
	})
	if claim.err != nil || claim.status != http.StatusOK {
		t.Fatalf("the claim: %d %v %v", claim.status, claim.body, claim.err)
	}
	granted, _ := claim.body["granted"].([]any)
	// Every seeded day carries a reward, and every catalogue item they name is
	// on this schema: the four programs each give today's.
	if len(granted) != 4 {
		t.Fatalf("%d rewards granted, want 4: %v", len(granted), claim.body["granted"])
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
	if len(codes) != 4 {
		t.Fatalf("the grants' programs: %v", codes)
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
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM user_reward_claims WHERE user_id = $1`, id).Scan(&claims); err != nil || claims != 4 {
		t.Fatalf("%d claims recorded (%v), want 4", claims, err)
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
	if res.StatusCode != http.StatusOK || len(read(body)) != 4 {
		t.Fatalf("a seated look at the programs: %d %s", res.StatusCode, body)
	}
}
