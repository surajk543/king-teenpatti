package app

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// One signed-in device per account (owner, 28 Sep 2026: "when someone is
// already logged in with google account in one device and some other guy
// tries to login with same google account in diff device, the first one will
// be auto logout and showing message someone has logged in your account and
// new guy will see the live state of game"). On the real wiring, mid-hand:
// the second sign-in tells the first device's live socket session:replaced
// and ends it before its own answer is written; the first device's token is
// refused session_replaced at every door from then on (a restored session, a
// signed-in request, the handshake), so it can never take the seat back; and
// the second device's connection sits straight down in the hand being played.
func TestASecondSignInSignsTheFirstDeviceOutAndHandsTheNewOneTheLiveTable(t *testing.T) {
	a, _ := newApp(t, func(c *config.Config) { c.Game.TurnTimeout = 20 * time.Second; c.Game.ReconnectGrace = 3 * time.Second })
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	// The first device: a Google account, seated, a hand under way.
	first, id := googleLogin(t, ts.URL, "google-sub-single-session")
	phone := dial(t, ts.URL, first)
	otherToken, _ := login(t, ts.URL, "single-session-other-01", "Opponent")
	other := dial(t, ts.URL, otherToken)
	join := map[string]any{"bootAmount": 200, "category": "seen"}
	joined := mustOK(t, phone, socket.EvRoomQuickJoin, join)
	mustOK(t, other, socket.EvRoomQuickJoin, join)
	roomID, _ := jsonPath(joined.Raw, "roomId").(string)
	live, err := phone.Wait(socket.EvRoomState, func(raw json.RawMessage) bool {
		n, _ := jsonPath(raw, "handNo").(float64)
		return n >= 1 && jsonPath(raw, "state") == "betting"
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("no hand started: %v", err)
	}
	handNo := jsonPath(live, "handNo")

	// Somebody signs in to the same Google account on another device. The
	// first device is told and let go at once — before the new device has
	// even connected.
	second, sameID := googleLogin(t, ts.URL, "google-sub-single-session")
	if sameID != id {
		t.Fatalf("the same Google account signed into %s, want %s", sameID, id)
	}
	if _, err := phone.Wait(socket.EvSessionReplaced, nil, 3*time.Second); err != nil {
		t.Fatalf("the first device was not told: %v", err)
	}
	if !phone.WaitClosed(3 * time.Second) {
		t.Fatal("the first device's connection was not ended")
	}

	// The first device's token is spent: a restored session, any signed-in
	// request and the handshake all answer session_replaced.
	res, body := get(t, a.Handler(), http.MethodGet, "/api/auth/me", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+first) })
	assertReplaced(t, "GET /api/auth/me", res.StatusCode, body)
	answer := postJSON(ts.URL, first, "/api/rewards/daily", map[string]any{})
	if answer.err != nil || answer.status != http.StatusUnauthorized || answer.body["error"] != auth.CodeSessionReplaced {
		t.Errorf("POST /api/rewards/daily with the replaced token: %d %v %v", answer.status, answer.body, answer.err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var ce *testclient.ConnectError
	if again, err := testclient.Dial(ctx, ts.URL, first); err == nil {
		again.Close()
		t.Fatal("the replaced device connected again")
	} else if !errors.As(err, &ce) || ce.Message != auth.CodeSessionReplaced {
		t.Fatalf("handshake with the replaced token: %v, want connect_error session_replaced", err)
	}

	// The new device sees the live table: the same room, the same hand, its
	// own seat and cards.
	newPhone := dial(t, ts.URL, second)
	view, err := newPhone.Wait(socket.EvRoomJoined, nil, 4*time.Second)
	if err != nil {
		t.Fatalf("the new device was not handed the table: %v", err)
	}
	if jsonPath(view, "roomId") != roomID || jsonPath(view, "handNo") != handNo {
		t.Errorf("the new device got room %v hand %v, want %s hand %v", jsonPath(view, "roomId"), jsonPath(view, "handNo"), roomID, handNo)
	}
	if jsonPath(view, "you") == nil {
		t.Errorf("the new device's view has no seat of its own: %s", view)
	}
	// The seat outlives the old device's reconnect grace: it is the new
	// device's now.
	time.Sleep(3500 * time.Millisecond)
	if room := a.Rooms().GetTableForPlayer(id); room == nil || room.ID() != roomID {
		t.Fatalf("the seat was lost after the hand-over: %v", room)
	}
	mustOK(t, newPhone, socket.EvChatMessage, map[string]any{"text": "still here"})

	// And the new device, being the latest sign-in, is never told it was
	// replaced.
	if _, ok := newPhone.Last(socket.EvSessionReplaced); ok {
		t.Error("the new device was told session:replaced")
	}
}

// A token from before sessions were counted carries no sv, which reads as 0 —
// the figure of an account with no user_sessions row — so every player signed
// in on the day of the deploy stays signed in, until that account signs in
// again somewhere; then that old token is refused like any other.
func TestATokenFromBeforeSessionsWereCountedLastsUntilTheNextSignIn(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	_, id := googleLogin(t, ts.URL, "google-sub-legacy-token")
	// As an account last signed in before the table existed: no row.
	if _, err := database.Pool.Exec(context.Background(), `DELETE FROM user_sessions WHERE user_id = $1`, id); err != nil {
		t.Fatal(err)
	}
	user, err := db.NewUsers(database, 0, nil).FindByID(context.Background(), id)
	if err != nil || user == nil || user.SessionVersion != 0 {
		t.Fatalf("an account with no user_sessions row reads %+v %v, want version 0", user, err)
	}
	legacy, err := auth.NewTokens("app-test-secret", time.Hour, nil).Issue(user)
	if err != nil {
		t.Fatal(err)
	}
	claims, err := auth.NewTokens("app-test-secret", time.Hour, nil).Verify(legacy)
	if err != nil || claims.SessionVersion != 0 {
		t.Fatalf("the legacy token: %+v %v", claims, err)
	}
	var payload map[string]any
	if err := json.Unmarshal(jwtPayload(t, legacy), &payload); err != nil {
		t.Fatal(err)
	}
	if _, has := payload["sv"]; has {
		t.Fatalf("a token for version 0 carries sv: %v", payload)
	}

	bearer := func(token string) func(*http.Request) {
		return func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) }
	}
	if res, body := get(t, a.Handler(), http.MethodGet, "/api/auth/me", bearer(legacy)); res.StatusCode != http.StatusOK {
		t.Fatalf("a token from before: %d %s, want 200", res.StatusCode, body)
	}
	dial(t, ts.URL, legacy).Close()

	// The account signs in again: the old token is out.
	fresh, _ := googleLogin(t, ts.URL, "google-sub-legacy-token")
	res, body := get(t, a.Handler(), http.MethodGet, "/api/auth/me", bearer(legacy))
	assertReplaced(t, "the token from before, after a sign-in", res.StatusCode, body)
	if res, body := get(t, a.Handler(), http.MethodGet, "/api/auth/me", bearer(fresh)); res.StatusCode != http.StatusOK {
		t.Fatalf("the new sign-in: %d %s", res.StatusCode, body)
	}
}

// Each sign-in replaces the one before it — the last device to sign in is the
// one that plays — and a new account's first sign-in starts at 1.
func TestEverySignInReplacesTheOneBefore(t *testing.T) {
	a, _ := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	var tokens []string
	for i := 0; i < 3; i++ {
		token, _ := googleLogin(t, ts.URL, "google-sub-three-devices")
		tokens = append(tokens, token)
	}
	for i, token := range tokens {
		claims, err := auth.NewTokens("app-test-secret", time.Hour, nil).Verify(token)
		if err != nil || claims.SessionVersion != int64(i+1) {
			t.Fatalf("sign-in %d carries %+v %v, want sv %d", i+1, claims, err, i+1)
		}
		res, body := get(t, a.Handler(), http.MethodGet, "/api/auth/me", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) })
		if i < len(tokens)-1 {
			assertReplaced(t, "an earlier sign-in", res.StatusCode, body)
		} else if res.StatusCode != http.StatusOK {
			t.Fatalf("the latest sign-in: %d %s", res.StatusCode, body)
		}
	}
}

// A socket of the CURRENT sign-in is never ended by a login's hand-over, even
// when the login's call lands after that socket connected: only an earlier
// sign-in's socket is replaced.
func TestTheHandOverNeverEndsTheLatestSignInsSocket(t *testing.T) {
	a, _ := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	token, id := googleLogin(t, ts.URL, "google-sub-late-call")
	c := dial(t, ts.URL, token)
	claims, err := auth.NewTokens("app-test-secret", time.Hour, nil).Verify(token)
	if err != nil {
		t.Fatal(err)
	}
	// The same call a login makes, arriving late: nothing happens.
	a.sockets.ReplaceSessions(id, claims.SessionVersion)
	if c.WaitClosed(500 * time.Millisecond) {
		t.Fatal("the latest sign-in's socket was ended")
	}
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
}

func googleLogin(t *testing.T, baseURL, sub string) (token, userID string) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"provider": "google", "providerUserId": sub, "displayName": "Google Player"})
	res, err := http.Post(baseURL+"/api/auth/login", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out struct {
		Token string `json:"token"`
		User  struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil || res.StatusCode != http.StatusOK || out.Token == "" {
		t.Fatalf("google login %s: %d %v %+v", sub, res.StatusCode, err, out)
	}
	return out.Token, out.User.ID
}

func assertReplaced(t *testing.T, what string, status int, body []byte) {
	t.Helper()
	var out struct {
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(body, &out); err != nil || status != http.StatusUnauthorized ||
		out.Error != auth.CodeSessionReplaced || out.Message != auth.MsgSessionReplaced {
		t.Errorf("%s: %d %s, want 401 session_replaced", what, status, body)
	}
}

// jwtPayload is a token's claims as the JSON it carries.
func jwtPayload(t *testing.T, token string) []byte {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("not a JWT: %q", token)
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	return payload
}
