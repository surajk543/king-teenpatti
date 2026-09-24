package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
)

// The Lucky Draw over HTTP on the real wiring (owner, 24 Sep 2026): GET
// /api/lucky-draw and POST /api/lucky-draw/spin through RequireAuth, the
// wallet limiter and rooms.WhileUnseated, PostgreSQL underneath, on the seeded
// BEGINNER_LUCKY_DRAW. The server draws: a prize the body names is ignored, a
// retry answers the same spin, a second spin inside the three-day cooldown is
// refused with the moment it recharges, and a seated player is sent to the
// lobby.
func TestTheLuckyDrawSpinsFromTheLobbyOncePerCooldown(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	token, id := login(t, ts.URL, "lucky-draw-player", "Lucky")
	authed := func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) }

	// What the wheel offers: six prizes, no weights, a spin available now.
	res, body := get(t, a.Handler(), http.MethodGet, "/api/lucky-draw", authed)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/lucky-draw: %d %s", res.StatusCode, body)
	}
	var state struct {
		Draw struct {
			Code        string `json:"code"`
			SpinnerType string `json:"spinnerType"`
			CooldownMs  int64  `json:"cooldownMs"`
		} `json:"draw"`
		Slots []struct {
			SlotNumber  int    `json:"slotNumber"`
			RewardType  string `json:"rewardType"`
			RewardValue *int64 `json:"rewardValue"`
		} `json:"slots"`
		NextSpinAt int64 `json:"nextSpinAt"`
	}
	if err := json.Unmarshal(body, &state); err != nil {
		t.Fatal(err)
	}
	if state.Draw.Code != "BEGINNER_LUCKY_DRAW" || state.Draw.SpinnerType != "BEGINNER" ||
		state.Draw.CooldownMs != 3*24*60*60*1000 || len(state.Slots) != 6 || state.NextSpinAt != 0 {
		t.Fatalf("the draw: %s", body)
	}
	if strings.Contains(strings.ToLower(string(body)), "weight") {
		t.Fatalf("the weights reached the wire: %s", body)
	}
	prizes, values := map[int]string{}, map[int]int64{}
	for _, s := range state.Slots {
		prizes[s.SlotNumber] = s.RewardType
		if s.RewardValue != nil {
			values[s.SlotNumber] = *s.RewardValue
		}
	}
	if res, _ := get(t, a.Handler(), http.MethodGet, "/api/lucky-draw", nil); res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("an anonymous look at the draw: %d", res.StatusCode)
	}

	walletBefore := func(column string) int64 {
		var v int64
		if err := database.Pool.QueryRow(ctx, `SELECT `+column+` FROM users WHERE id = $1`, id).Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	chips := walletBefore("chips")

	// A spin whose body names a prize of its own: the server draws regardless.
	spin := postJSON(ts.URL, token, "/api/lucky-draw/spin", map[string]any{
		"actionId": "tap-1", "slotNumber": 6, "rewardType": "CHIPS", "rewardValue": 99_999_999,
	})
	if spin.err != nil || spin.status != http.StatusOK || spin.body["replayed"] != false || spin.body["actionId"] != "tap-1" {
		t.Fatalf("the spin: %d %v %v", spin.status, spin.body, spin.err)
	}
	slot := int(spin.body["slotNumber"].(float64))
	reward := spin.body["reward"].(map[string]any)
	if prizes[slot] == "" || reward["type"] != prizes[slot] {
		t.Fatalf("landed on %d with %v; the wheel holds %v", slot, reward, prizes)
	}
	if user, ok := spin.body["user"].(map[string]any); !ok || user["id"] != id {
		t.Fatalf("the spin answers with the account: %v", spin.body["user"])
	}
	nextSpinAt := int64(spin.body["nextSpinAt"].(float64))
	if nextSpinAt <= 0 {
		t.Fatalf("nextSpinAt %d after a spin of a draw with a cooldown", nextSpinAt)
	}
	// Chips move only for a chips prize, and by what the wheel showed for that
	// slot — never by what the body asked for.
	switch got := walletBefore("chips") - chips; {
	case prizes[slot] == "CHIPS" && got != values[slot], prizes[slot] != "CHIPS" && got != 0:
		t.Fatalf("a %s prize of %d moved chips by %d", prizes[slot], values[slot], got)
	}

	// The same tap again: the same spin, granted once.
	again := postJSON(ts.URL, token, "/api/lucky-draw/spin", map[string]any{"actionId": "tap-1"})
	if again.err != nil || again.status != http.StatusOK || again.body["replayed"] != true ||
		int(again.body["slotNumber"].(float64)) != slot {
		t.Fatalf("the retry: %d %v %v", again.status, again.body, again.err)
	}
	// Another tap inside the cooldown: refused, with when it recharges.
	early := postJSON(ts.URL, token, "/api/lucky-draw/spin", map[string]any{"actionId": "tap-2"})
	if early.err != nil || early.status != http.StatusConflict || early.body["error"] != auth.CodeLuckyDrawNotReady ||
		int64(early.body["readyAt"].(float64)) != nextSpinAt {
		t.Fatalf("a second spin inside the cooldown: %d %v %v", early.status, early.body, early.err)
	}
	// No key, no spin.
	if bad := postJSON(ts.URL, token, "/api/lucky-draw/spin", map[string]any{}); bad.status != http.StatusBadRequest || bad.body["error"] != auth.CodeInvalidActionID {
		t.Fatalf("a spin with no action id: %d %v", bad.status, bad.body)
	}
	var spins int
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM user_lucky_draws WHERE user_id = $1`, id).Scan(&spins); err != nil {
		t.Fatal(err)
	}
	if spins != 1 {
		t.Fatalf("%d spins recorded, want 1", spins)
	}
	var ledger, wallet int64
	if err := database.Pool.QueryRow(ctx,
		`SELECT (SELECT COALESCE(SUM(delta), 0)::bigint FROM chip_ledger WHERE user_id = $1), (SELECT chips FROM users WHERE id = $1)`,
		id).Scan(&ledger, &wallet); err != nil {
		t.Fatal(err)
	}
	if ledger != wallet {
		t.Fatalf("the wallet (%d) no longer equals its ledger (%d)", wallet, ledger)
	}

	// Seated: sent to the lobby, and nothing is drawn.
	seatedToken, seatedID := login(t, ts.URL, "lucky-draw-sitter", "Sitter")
	c := dial(t, ts.URL, seatedToken)
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	if a.Rooms().GetTableForPlayer(seatedID) == nil {
		t.Fatal("the sitter is not seated")
	}
	seated := postJSON(ts.URL, seatedToken, "/api/lucky-draw/spin", map[string]any{"actionId": "seated-tap"})
	if seated.err != nil || seated.status != http.StatusConflict || seated.body["error"] != auth.CodeSeated {
		t.Fatalf("a seated spin: %d %v %v", seated.status, seated.body, seated.err)
	}
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM user_lucky_draws WHERE user_id = $1`, seatedID).Scan(&spins); err != nil || spins != 0 {
		t.Fatalf("a seated spin was recorded: %d %v", spins, err)
	}
	// Looking is allowed at a table; only the spin is the lobby's.
	res, body = get(t, a.Handler(), http.MethodGet, "/api/lucky-draw", func(r *http.Request) {
		r.Header.Set("Authorization", "Bearer "+seatedToken)
	})
	if res.StatusCode != http.StatusOK {
		t.Fatalf("a seated look at the draw: %d %s", res.StatusCode, body)
	}
}
