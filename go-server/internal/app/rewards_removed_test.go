package app

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
)

// The three lobby rewards are gone (owner, 30 Sep 2026: "Remove 24-hour daily
// reward, 4-hour bonus, and milestone reward"), end to end on the real wiring:
// their paths answer the app's JSON 404 like any unknown /api path and move no
// chips, and the account a client is handed — at login, at GET /api/auth/me
// and in session:ready — carries no `rewards` key, which is what takes the
// reward chips off the lobby of an app already installed.
func TestTheLobbyRewardsAreGoneFromTheServer(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	token, id := login(t, ts.URL, "rewards-removed-device-01", "No Rewards")
	bearer := func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) }

	res, body := get(t, a.Handler(), http.MethodGet, "/api/auth/me", bearer)
	if res.StatusCode != http.StatusOK || bytes.Contains(body, []byte(`"rewards"`)) {
		t.Fatalf("GET /api/auth/me: %d %s", res.StatusCode, body)
	}

	before, _ := walletAndLedger(t, database, id)
	for _, path := range []string{"/api/rewards/milestone", "/api/rewards/bonus", "/api/rewards/daily"} {
		answer := postJSON(ts.URL, token, path, map[string]any{})
		if answer.err != nil || answer.status != http.StatusNotFound || answer.body["error"] != auth.CodeNotFound ||
			answer.body["message"] != "Cannot POST "+path {
			t.Errorf("POST %s: %d %v %v", path, answer.status, answer.body, answer.err)
		}
	}
	if after, ledger := walletAndLedger(t, database, id); after != before || ledger != after {
		t.Fatalf("a removed reward path moved chips: wallet %d → %d, ledger %d", before, after, ledger)
	}

	c := dial(t, ts.URL, token)
	ready, err := c.Wait(socket.EvSessionReady, nil, 4*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	var payload struct {
		User map[string]json.RawMessage `json:"user"`
	}
	if err := json.Unmarshal(ready, &payload); err != nil || payload.User == nil {
		t.Fatalf("session:ready: %v %s", err, ready)
	}
	if _, ok := payload.User["rewards"]; ok {
		t.Fatalf("session:ready's user still carries rewards: %s", ready)
	}
	if _, ok := payload.User["chips"]; !ok {
		t.Fatalf("session:ready's user is not the account: %s", ready)
	}
}
