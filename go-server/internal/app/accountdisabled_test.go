package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// Disabling an account (owner, 26 Sep 2026: users.is_active — "when it is
// marked false, it means user is disabled … he cannot join the table also").
// Every door on the real wiring: the live socket's next join, the socket
// handshake, GET /api/auth/me (a cold start's restored session), any other
// signed-in request, and the login itself — each answers account_disabled,
// and switched back on, the same device is the same account again.
func TestADisabledAccountIsTurnedAwayAtEveryDoor(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	const device = "disabled-account-device-01"
	token, id := login(t, ts.URL, device, "Soon Off")
	c := dial(t, ts.URL, token)
	stale := playerOf(t, database, id)

	// Support switches the account off while its socket is live.
	setActive(t, database, id, false)

	// The live socket's next join is refused, and the session is ended.
	ack, err := c.Call(socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"}, 4*time.Second)
	if err != nil || ack.OK || ack.Code != auth.CodeAccountDisabled || ack.Message != auth.MsgAccountDisabled {
		t.Fatalf("a disabled account's quick join: %v %s", err, ack.Raw)
	}
	if a.Rooms().GetTableForPlayer(id) != nil {
		t.Fatal("a disabled account was seated")
	}
	if !c.WaitClosed(4 * time.Second) {
		t.Error("the disabled account's session was not ended")
	}

	// The RoomManager's own read under the seat lock refuses it too, even
	// for a join handed a Player read before the switch.
	if _, err := a.Rooms().QuickJoin(stale, game.QuickJoinOptions{BootAmount: 200, Category: "seen"}); !isCode(err, auth.CodeAccountDisabled) {
		t.Errorf("QuickJoin with a stale Player: %v, want account_disabled", err)
	}
	if a.Rooms().GetTableForPlayer(id) != nil {
		t.Fatal("a disabled account was seated through the RoomManager")
	}

	// Reconnecting is refused at the handshake with the same code.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var ce *testclient.ConnectError
	if again, err := testclient.Dial(ctx, ts.URL, token); err == nil {
		again.Close()
		t.Error("a disabled account's socket connected")
	} else if !errors.As(err, &ce) || ce.Message != auth.CodeAccountDisabled {
		t.Errorf("handshake: %v, want connect_error account_disabled", err)
	}

	// A restored session (GET /api/auth/me) and every other signed-in
	// request: 403 account_disabled.
	bearer := func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) }
	res, body := get(t, a.Handler(), http.MethodGet, "/api/auth/me", bearer)
	assertDisabled(t, "GET /api/auth/me", res.StatusCode, body)
	answer := postJSON(ts.URL, token, "/api/rewards/daily", map[string]any{})
	if answer.err != nil || answer.status != http.StatusForbidden || answer.body["error"] != auth.CodeAccountDisabled {
		t.Errorf("POST /api/rewards/daily: %d %v %v", answer.status, answer.body, answer.err)
	}

	// The login is refused before the row is touched.
	before := lastLoginOf(t, database, id)
	status, body := loginRaw(t, ts.URL, device)
	assertDisabled(t, "POST /api/auth/login", status, body)
	if after := lastLoginOf(t, database, id); after != before {
		t.Errorf("a refused login moved last_login_at from %d to %d", before, after)
	}
	if n := countUsers(t, database); n != 1 {
		t.Errorf("a refused login left %d accounts, want the one", n)
	}

	// Switched back on, the same device is the same account, and it sits.
	setActive(t, database, id, true)
	token2, id2 := login(t, ts.URL, device, "Back On")
	if id2 != id {
		t.Fatalf("re-enabled, the device signed into %s, want %s", id2, id)
	}
	c2 := dial(t, ts.URL, token2)
	mustOK(t, c2, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	if a.Rooms().GetTableForPlayer(id) == nil {
		t.Error("the re-enabled account was not seated")
	}
	// Never on the wire: the flag is the server's alone.
	res, body = get(t, a.Handler(), http.MethodGet, "/api/auth/me", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token2) })
	if res.StatusCode != http.StatusOK || strings.Contains(string(body), `"active"`) || strings.Contains(string(body), `"isActive"`) {
		t.Errorf("GET /api/auth/me for an enabled account: %d %s", res.StatusCode, body)
	}
}

func setActive(t *testing.T, database *db.DB, userID string, active bool) {
	t.Helper()
	if _, err := database.Pool.Exec(context.Background(), `UPDATE users SET is_active = $2 WHERE id = $1`, userID, active); err != nil {
		t.Fatal(err)
	}
}

func lastLoginOf(t *testing.T, database *db.DB, userID string) (at int64) {
	t.Helper()
	if err := database.Pool.QueryRow(context.Background(), `SELECT last_login_at FROM users WHERE id = $1`, userID).Scan(&at); err != nil {
		t.Fatal(err)
	}
	return at
}

func countUsers(t *testing.T, database *db.DB) (n int64) {
	t.Helper()
	if err := database.Pool.QueryRow(context.Background(), `SELECT count(*) FROM users`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func playerOf(t *testing.T, database *db.DB, userID string) game.Player {
	t.Helper()
	user, err := db.NewUsers(database, 0, nil).FindByID(context.Background(), userID)
	if err != nil || user == nil {
		t.Fatalf("reading %s: %v %v", userID, user, err)
	}
	return user.Player()
}

// loginRaw is a guest login whose refusal the caller reads.
func loginRaw(t *testing.T, baseURL, deviceID string) (int, []byte) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"provider": "guest", "deviceId": deviceID})
	res, err := http.Post(baseURL+"/api/auth/login", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out bytes.Buffer
	_, _ = out.ReadFrom(res.Body)
	return res.StatusCode, out.Bytes()
}

func assertDisabled(t *testing.T, what string, status int, body []byte) {
	t.Helper()
	var out struct {
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(body, &out); err != nil || status != http.StatusForbidden ||
		out.Error != auth.CodeAccountDisabled || out.Message != auth.MsgAccountDisabled {
		t.Errorf("%s: %d %s, want 403 account_disabled", what, status, body)
	}
}

func isCode(err error, code string) bool {
	var ge *game.GameError
	return errors.As(err, &ge) && ge.Code == code
}
