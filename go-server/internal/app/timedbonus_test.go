package app

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
)

// Two of the three lobby rewards stay gone (owner, 30 Sep 2026: "Remove
// 24-hour daily reward, 4-hour bonus, and milestone reward"), and the third
// is back the same evening as the 6-hour bonus ("IN Top left Add Again Every
// 6 hours bonus 25000 Coins"), end to end on the real wiring: the milestone's
// and the daily bonus's paths answer the app's JSON 404 like any unknown /api
// path and move no chips; POST /api/rewards/bonus pays 25,000 chips through
// the ledger, refuses a second claim inside six hours with reward_not_ready
// and the unlock time, and refuses a seated player; and the account a client
// is handed — at GET /api/auth/me and in session:ready — carries `rewards`
// with the bonus's clock, which is what the lobby's top-left chip is drawn
// from.
func TestTheSixHourBonusIsBackAndTheOtherTwoRewardsStayGone(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	token, id := login(t, ts.URL, "rewards-bonus-device-01", "Bonus Back")
	bearer := func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) }

	// A new account: the bonus is ready now.
	res, body := get(t, a.Handler(), http.MethodGet, "/api/auth/me", bearer)
	var me struct {
		User struct {
			Rewards db.Rewards `json:"rewards"`
		} `json:"user"`
	}
	if res.StatusCode != http.StatusOK || json.Unmarshal(body, &me) != nil || !me.User.Rewards.BonusAvailable ||
		me.User.Rewards.BonusReward != 25000 || me.User.Rewards.BonusIntervalMs != 6*60*60*1000 || me.User.Rewards.BonusReadyAt != 0 {
		t.Fatalf("GET /api/auth/me: %d %s", res.StatusCode, body)
	}

	before, _ := walletAndLedger(t, database, id)
	for _, path := range []string{"/api/rewards/milestone", "/api/rewards/daily"} {
		answer := postJSON(ts.URL, token, path, map[string]any{})
		if answer.err != nil || answer.status != http.StatusNotFound || answer.body["error"] != auth.CodeNotFound ||
			answer.body["message"] != "Cannot POST "+path {
			t.Errorf("POST %s: %d %v %v", path, answer.status, answer.body, answer.err)
		}
	}
	if after, ledger := walletAndLedger(t, database, id); after != before || ledger != after {
		t.Fatalf("a removed reward path moved chips: wallet %d → %d, ledger %d", before, after, ledger)
	}

	// The bonus: paid once, through the ledger; a forged body changes nothing.
	claimedAt := time.Now().UnixMilli()
	answer := postJSON(ts.URL, token, "/api/rewards/bonus", map[string]any{"amount": 9_999_999, "readyAt": 0})
	if answer.err != nil || answer.status != http.StatusOK || answer.body["claimed"] != true || answer.body["amount"] != float64(25000) {
		t.Fatalf("POST /api/rewards/bonus: %d %v %v", answer.status, answer.body, answer.err)
	}
	readyAt, _ := answer.body["readyAt"].(float64)
	sixHours := float64(6 * 60 * 60 * 1000)
	if readyAt < float64(claimedAt)+sixHours-2000 || readyAt > float64(time.Now().UnixMilli())+sixHours+2000 {
		t.Fatalf("readyAt %v is not six hours out", readyAt)
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != before+25000 || ledger != wallet {
		t.Fatalf("after the bonus: wallet %d, ledger %d, want both %d", wallet, ledger, before+25000)
	}
	var reason string
	if err := database.Pool.QueryRow(t.Context(), `SELECT reason FROM chip_ledger WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT 1`, id).Scan(&reason); err != nil || reason != "timed_bonus" {
		t.Fatalf("the ledger's last row: %q %v", reason, err)
	}

	// Again, inside the six hours: refused, with the clock and the account.
	again := postJSON(ts.URL, token, "/api/rewards/bonus", map[string]any{})
	if again.err != nil || again.status != http.StatusConflict || again.body["error"] != auth.CodeRewardNotReady ||
		again.body["readyAt"] != readyAt || again.body["user"] == nil {
		t.Fatalf("a second claim: %d %v %v", again.status, again.body, again.err)
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != before+25000 || ledger != wallet {
		t.Fatalf("a refused claim moved chips: wallet %d, ledger %d", wallet, ledger)
	}

	// session:ready's account carries the clock the chip counts down from.
	c := dial(t, ts.URL, token)
	ready, err := c.Wait(socket.EvSessionReady, nil, 4*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	var payload struct {
		User struct {
			Chips   int64      `json:"chips"`
			Rewards db.Rewards `json:"rewards"`
		} `json:"user"`
	}
	if err := json.Unmarshal(ready, &payload); err != nil || payload.User.Chips != before+25000 ||
		payload.User.Rewards.BonusAvailable || payload.User.Rewards.BonusReadyAt != int64(readyAt) {
		t.Fatalf("session:ready's rewards: %v %s", err, ready)
	}

	// Seated, the bonus is the lobby's: 409 seated, nothing moved — the rule
	// every lobby-only credit follows (CLAUDE.md §5.1).
	if err := database.Exec(t.Context(), `UPDATE user_milestones SET next_claim_at = 0 WHERE user_id = $1`, id); err != nil {
		t.Fatal(err)
	}
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	seated := postJSON(ts.URL, token, "/api/rewards/bonus", map[string]any{})
	if seated.err != nil || seated.status != http.StatusConflict || seated.body["error"] != auth.CodeSeated ||
		!bytes.Contains([]byte(seated.body["message"].(string)), []byte("lobby")) {
		t.Fatalf("seated claim: %d %v %v", seated.status, seated.body, seated.err)
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != before+25000 || ledger != wallet {
		t.Fatalf("a seated claim moved chips: wallet %d, ledger %d", wallet, ledger)
	}
	mustOK(t, c, socket.EvRoomLeave, map[string]any{})
	back := postJSON(ts.URL, token, "/api/rewards/bonus", map[string]any{})
	if back.err != nil || back.status != http.StatusOK || back.body["claimed"] != true {
		t.Fatalf("back in the lobby: %d %v %v", back.status, back.body, back.err)
	}
}
