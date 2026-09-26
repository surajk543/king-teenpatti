package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Friends V1 (owner, 26 Sep 2026) on the real wiring: the eight REST routes
// through RequireAuth, the wallet limiter and PostgreSQL, each friend's
// presence read from the live store the socket layer and the RoomManager
// write — kt:online, and the playing record beside every seat — and nothing
// of a wallet or a table in any answer.

// friendsCall is one signed-in REST call: status and raw body.
func friendsCall(t *testing.T, baseURL, token, method, path, body string) (int, []byte) {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, baseURL+path, rd)
	if err != nil {
		t.Fatal(err)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	return res.StatusCode, raw
}

// friendsBodies keeps every friends answer a test saw, to be scanned for
// what must never be in one.
type friendsBodies struct{ seen [][]byte }

func (b *friendsBodies) call(t *testing.T, baseURL, token, method, path, body string) (int, []byte) {
	t.Helper()
	status, raw := friendsCall(t, baseURL, token, method, path, body)
	b.seen = append(b.seen, raw)
	return status, raw
}

// assertNothingLeaks: no wallet, no purchase, no table or room id, no live
// store key, in any friends answer.
func (b *friendsBodies) assertNothingLeaks(t *testing.T, roomIDs ...string) {
	t.Helper()
	forbidden := []string{"chips", "diamond", "hammer", "missile", "wallet", "purchase", "ledger", "email", "provider",
		"roomid", "tableid", "room_id", "table_id", "\"code\"", "kt:", "seat:", "playing:"}
	for _, raw := range b.seen {
		lower := strings.ToLower(string(raw))
		for _, word := range forbidden {
			if strings.Contains(lower, word) {
				t.Errorf("a friends answer carries %q: %s", word, raw)
			}
		}
		for _, id := range roomIDs {
			if id != "" && strings.Contains(string(raw), id) {
				t.Errorf("a friends answer names room %s: %s", id, raw)
			}
		}
	}
}

// jsonField reads one top-level number or string field of a JSON body.
func jsonField(t *testing.T, raw []byte, path string) any {
	t.Helper()
	return jsonPath(raw, path)
}

func mustStatus(t *testing.T, what string, status, want int, raw []byte) {
	t.Helper()
	if status != want {
		t.Fatalf("%s: %d %s, want %d", what, status, raw, want)
	}
}

func mustBody(t *testing.T, what string, raw []byte, want string) {
	t.Helper()
	if string(raw) != want {
		t.Fatalf("%s:\n got %s\nwant %s", what, raw, want)
	}
}

func TestTheEightFriendsRoutesAnswerTheContract(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	var b friendsBodies

	tokA, idA := login(t, ts.URL, "friends-device-alice-01", "Alice")
	tokB, idB := login(t, ts.URL, "friends-device-bobby-01", "Bobby")
	tokC, idC := login(t, ts.URL, "friends-device-carla-01", "Carla")

	// ---- 1. GET /api/players/{playerId}
	status, raw := b.call(t, ts.URL, tokA, http.MethodGet, "/api/players/"+idB, "")
	mustStatus(t, "look B up", status, http.StatusOK, raw)
	mustBody(t, "look B up", raw, fmt.Sprintf(`{"player":{"userId":"%s","displayName":"Bobby","profilePicture":{"id":null,"url":null}},"friendStatus":"NONE"}`, idB))
	t.Logf("GET /api/players/{playerId} (NONE): %s", raw)
	// Trimmed and compared case-insensitively.
	status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/players/%20"+strings.ToUpper(idB)+"%20", "")
	if status != http.StatusOK || jsonField(t, raw, "player.userId") != idB {
		t.Fatalf("an upper-cased, spaced Player ID: %d %s", status, raw)
	}
	status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/players/"+idA, "")
	mustStatus(t, "look yourself up", status, http.StatusOK, raw)
	if jsonField(t, raw, "friendStatus") != "SELF" || strings.Contains(string(raw), "requestId") {
		t.Fatalf("yourself: %s", raw)
	}
	for _, bad := range []string{"%20%20", strings.Repeat("x", 65)} {
		status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/players/"+bad, "")
		mustStatus(t, "an invalid Player ID", status, http.StatusBadRequest, raw)
		mustBody(t, "an invalid Player ID", raw, `{"error":"invalid_player_id","message":"That is not a valid Player ID."}`)
	}
	status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/players/00000000-0000-4000-8000-000000000000", "")
	mustStatus(t, "nobody", status, http.StatusNotFound, raw)
	mustBody(t, "nobody", raw, `{"error":"player_not_found","message":"Player not found."}`)
	status, raw = friendsCall(t, ts.URL, "", http.MethodGet, "/api/players/"+idB, "")
	mustStatus(t, "no session", status, http.StatusUnauthorized, raw)

	// ---- 5. POST /api/friends/requests
	status, raw = b.call(t, ts.URL, tokA, http.MethodPost, "/api/friends/requests", `{"userId":"`+idB+`"}`)
	mustStatus(t, "A → B", status, http.StatusCreated, raw)
	requestAB := int64(jsonField(t, raw, "requestId").(float64))
	mustBody(t, "A → B", raw, fmt.Sprintf(`{"requestId":%d,"friendStatus":"PENDING_SENT"}`, requestAB))
	t.Logf("POST /api/friends/requests (201): %s", raw)
	for _, c := range []struct {
		what, token, body string
		status            int
		want              string
	}{
		{"again", tokA, `{"userId":"` + idB + `"}`, http.StatusConflict, `{"error":"request_already_sent","message":"Friend request already sent."}`},
		{"the reverse", tokB, `{"userId":"` + strings.ToUpper(idA) + `"}`, http.StatusConflict,
			fmt.Sprintf(`{"error":"request_already_received","message":"This player already sent you a request — accept it.","requestId":%d}`, requestAB)},
		{"yourself", tokA, `{"userId":" ` + idA + `"}`, http.StatusBadRequest, `{"error":"self_request","message":"You cannot add yourself."}`},
		{"nobody", tokA, `{"userId":"no-such-player"}`, http.StatusNotFound, `{"error":"player_not_found","message":"Player not found."}`},
		{"no id", tokA, `{}`, http.StatusBadRequest, `{"error":"invalid_player_id","message":"That is not a valid Player ID."}`},
		{"a number", tokA, `{"userId":42}`, http.StatusBadRequest, `{"error":"invalid_player_id","message":"That is not a valid Player ID."}`},
	} {
		status, raw = b.call(t, ts.URL, c.token, http.MethodPost, "/api/friends/requests", c.body)
		mustStatus(t, c.what, status, c.status, raw)
		mustBody(t, c.what, raw, c.want)
		t.Logf("POST /api/friends/requests (%s): %d %s", c.what, status, raw)
	}
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodPost, "/api/friends/requests", `{"userId":`)
	if status != http.StatusBadRequest || jsonField(t, raw, "error") != "invalid_json" {
		t.Fatalf("a broken body: %d %s", status, raw)
	}

	// Both sides see the pending request, with its id.
	status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/players/"+idB, "")
	mustBody(t, "the sender's view", raw, fmt.Sprintf(`{"player":{"userId":"%s","displayName":"Bobby","profilePicture":{"id":null,"url":null}},"friendStatus":"PENDING_SENT","requestId":%d}`, idB, requestAB))
	status, raw = b.call(t, ts.URL, tokB, http.MethodGet, "/api/players/"+idA, "")
	mustBody(t, "the recipient's view", raw, fmt.Sprintf(`{"player":{"userId":"%s","displayName":"Alice","profilePicture":{"id":null,"url":null}},"friendStatus":"PENDING_RECEIVED","requestId":%d}`, idA, requestAB))
	t.Logf("GET /api/players/{playerId} (PENDING_RECEIVED): %s", raw)

	// ---- 4. GET /api/friends/requests
	status, raw = b.call(t, ts.URL, tokB, http.MethodGet, "/api/friends/requests", "")
	mustStatus(t, "B's requests", status, http.StatusOK, raw)
	sentAt := int64(jsonField(t, raw, "incoming").([]any)[0].(map[string]any)["createdAt"].(float64))
	mustBody(t, "B's requests", raw, fmt.Sprintf(`{"incoming":[{"requestId":%d,"player":{"userId":"%s","displayName":"Alice","profilePicture":{"id":null,"url":null}},"createdAt":%d}],"outgoing":[]}`, requestAB, idA, sentAt))
	t.Logf("GET /api/friends/requests (recipient): %s", raw)
	status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/friends/requests", "")
	mustBody(t, "A's requests", raw, fmt.Sprintf(`{"incoming":[],"outgoing":[{"requestId":%d,"player":{"userId":"%s","displayName":"Bobby","profilePicture":{"id":null,"url":null}},"createdAt":%d}]}`, requestAB, idB, sentAt))
	t.Logf("GET /api/friends/requests (sender): %s", raw)

	// ---- 6. POST /api/friends/requests/{requestId}/accept
	accept := fmt.Sprintf("/api/friends/requests/%d/accept", requestAB)
	for _, c := range []struct{ what, token, path string }{
		{"by its sender", tokA, accept},
		{"by a stranger", tokC, accept},
		{"an unknown id", tokB, "/api/friends/requests/987654321/accept"},
		{"not an id", tokB, "/api/friends/requests/abc/accept"},
		{"a padded id", tokB, fmt.Sprintf("/api/friends/requests/0%d/accept", requestAB)},
	} {
		status, raw = b.call(t, ts.URL, c.token, http.MethodPost, c.path, "")
		mustStatus(t, "accept "+c.what, status, http.StatusNotFound, raw)
		mustBody(t, "accept "+c.what, raw, `{"error":"request_not_found","message":"Friend request not found."}`)
	}
	status, raw = b.call(t, ts.URL, tokB, http.MethodPost, accept, "")
	mustStatus(t, "B accepts", status, http.StatusOK, raw)
	since := int64(jsonField(t, raw, "friend.friendsSince").(float64))
	mustBody(t, "B accepts", raw, fmt.Sprintf(`{"friend":{"userId":"%s","displayName":"Alice","profilePicture":{"id":null,"url":null},"status":"OFFLINE","online":false,"playing":false,"friendsSince":%d}}`, idA, since))
	t.Logf("POST /api/friends/requests/{requestId}/accept: %s", raw)
	status, raw = b.call(t, ts.URL, tokB, http.MethodPost, accept, "")
	mustStatus(t, "accept twice", status, http.StatusConflict, raw)
	mustBody(t, "accept twice", raw, `{"error":"request_not_pending","message":"This friend request has already been answered."}`)
	status, raw = b.call(t, ts.URL, tokA, http.MethodPost, "/api/friends/requests", `{"userId":"`+idB+`"}`)
	mustStatus(t, "a request to a friend", status, http.StatusConflict, raw)
	mustBody(t, "a request to a friend", raw, `{"error":"already_friends","message":"You are already friends."}`)

	// ---- 7. POST /api/friends/requests/{requestId}/reject
	status, raw = b.call(t, ts.URL, tokC, http.MethodPost, "/api/friends/requests", `{"userId":"`+idA+`"}`)
	mustStatus(t, "C → A", status, http.StatusCreated, raw)
	requestCA := int64(jsonField(t, raw, "requestId").(float64))
	reject := fmt.Sprintf("/api/friends/requests/%d/reject", requestCA)
	status, raw = b.call(t, ts.URL, tokC, http.MethodPost, reject, "")
	mustStatus(t, "reject by its sender", status, http.StatusNotFound, raw)
	status, raw = b.call(t, ts.URL, tokA, http.MethodPost, reject, "")
	mustStatus(t, "A rejects", status, http.StatusOK, raw)
	mustBody(t, "A rejects", raw, fmt.Sprintf(`{"requestId":%d,"status":"REJECTED"}`, requestCA))
	t.Logf("POST /api/friends/requests/{requestId}/reject: %s", raw)
	status, raw = b.call(t, ts.URL, tokA, http.MethodPost, reject, "")
	mustStatus(t, "reject twice", status, http.StatusConflict, raw)
	mustBody(t, "reject twice", raw, `{"error":"request_not_pending","message":"This friend request has already been answered."}`)
	status, raw = b.call(t, ts.URL, tokA, http.MethodPost, accept, "")
	mustStatus(t, "an accepted request is answered", status, http.StatusNotFound, raw) // not addressed to A

	// ---- 3. GET /api/friends
	status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/friends", "")
	mustStatus(t, "A's friends", status, http.StatusOK, raw)
	mustBody(t, "A's friends", raw, fmt.Sprintf(`{"friends":[{"userId":"%s","displayName":"Bobby","profilePicture":{"id":null,"url":null},"status":"OFFLINE","online":false,"playing":false,"friendsSince":%d}]}`, idB, since))
	t.Logf("GET /api/friends: %s", raw)
	status, raw = b.call(t, ts.URL, tokC, http.MethodGet, "/api/friends", "")
	mustBody(t, "no friends", raw, `{"friends":[]}`)

	// ---- 2. GET /api/players/{playerId}/profile
	// A hand's statistics first: B wins one of two counted hands.
	if _, err := database.Pool.Exec(ctx, `INSERT INTO player_stats (user_id, hands_played, hands_won, hands_lost, hands_left, total_winnings, biggest_pot)
	     VALUES ($1, 3, 1, 1, 1, 75000, 50000)`, idB); err != nil {
		t.Fatal(err)
	}
	status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/players/"+idB+"/profile", "")
	mustStatus(t, "B's profile", status, http.StatusOK, raw)
	mustBody(t, "B's profile, a friend's", raw, fmt.Sprintf(`{"profile":{"userId":"%s","displayName":"Bobby","profilePicture":{"id":null,"url":null},"friendStatus":"FRIENDS","presence":{"status":"OFFLINE","online":false,"playing":false},"stats":{"handsPlayed":3,"handsWon":1,"handsLost":1,"handsLeft":1,"winRate":33.33}}}`, idB))
	t.Logf("GET /api/players/{playerId}/profile (FRIENDS): %s", raw)
	// A stranger's profile: stats, and no presence.
	status, raw = b.call(t, ts.URL, tokC, http.MethodGet, "/api/players/"+idB+"/profile", "")
	mustBody(t, "B's profile, a stranger's", raw, fmt.Sprintf(`{"profile":{"userId":"%s","displayName":"Bobby","profilePicture":{"id":null,"url":null},"friendStatus":"NONE","stats":{"handsPlayed":3,"handsWon":1,"handsLost":1,"handsLeft":1,"winRate":33.33}}}`, idB))
	t.Logf("GET /api/players/{playerId}/profile (NONE): %s", raw)
	// Your own: presence, and a win rate of 0 before any hand.
	status, raw = b.call(t, ts.URL, tokC, http.MethodGet, "/api/players/"+idC+"/profile", "")
	mustBody(t, "your own profile", raw, fmt.Sprintf(`{"profile":{"userId":"%s","displayName":"Carla","profilePicture":{"id":null,"url":null},"friendStatus":"SELF","presence":{"status":"OFFLINE","online":false,"playing":false},"stats":{"handsPlayed":0,"handsWon":0,"handsLost":0,"handsLeft":0,"winRate":0}}}`, idC))
	status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/players/nobody-at-all/profile", "")
	mustStatus(t, "a profile of nobody", status, http.StatusNotFound, raw)
	mustBody(t, "a profile of nobody", raw, `{"error":"player_not_found","message":"Player not found."}`)

	// ---- 8. DELETE /api/friends/{friendUserId}
	status, raw = b.call(t, ts.URL, tokA, http.MethodDelete, "/api/friends/"+idB, "")
	mustStatus(t, "A removes B", status, http.StatusOK, raw)
	mustBody(t, "A removes B", raw, `{"removed":true}`)
	t.Logf("DELETE /api/friends/{friendUserId}: %s", raw)
	for _, who := range []string{idB, idC, "nobody"} {
		status, raw = b.call(t, ts.URL, tokA, http.MethodDelete, "/api/friends/"+who, "")
		mustStatus(t, "removing a non-friend", status, http.StatusNotFound, raw)
		mustBody(t, "removing a non-friend", raw, `{"error":"not_friends","message":"You are not friends with this player."}`)
	}
	var rows int64
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM friendships WHERE $1 IN (user_id, friend_user_id)`, idB).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("%d friendship rows survive the removal (%v)", rows, err)
	}
	status, raw = b.call(t, ts.URL, tokB, http.MethodGet, "/api/friends", "")
	mustBody(t, "B's friends after", raw, `{"friends":[]}`)

	// Wrong methods answer the JSON 404; the wildcard never matches an empty id.
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodPut, "/api/friends/requests", "")
	if status != http.StatusNotFound || jsonField(t, raw, "error") != "not_found" {
		t.Fatalf("PUT /api/friends/requests: %d %s", status, raw)
	}
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodGet, "/api/players/", "")
	if status != http.StatusNotFound || jsonField(t, raw, "error") != "not_found" {
		t.Fatalf("GET /api/players/: %d %s", status, raw)
	}

	b.assertNothingLeaks(t)
}

// A deleted or disabled account is invisible to Friends: not found, left
// out of every list, and a deleted one's friendships and pending requests go
// with it (DELETE /api/account).
func TestADeletedOrDisabledAccountDisappearsFromFriends(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	var b friendsBodies

	tokA, idA := login(t, ts.URL, "friends-gone-anna-0001", "Anna")
	tokB, idB := login(t, ts.URL, "friends-gone-ben-00001", "Ben")
	tokD, idD := login(t, ts.URL, "friends-gone-dora-0001", "Dora")
	_, idE := login(t, ts.URL, "friends-gone-eve-00001", "Eve")
	befriend := func(tokFrom, idTo, tokTo string) {
		t.Helper()
		status, raw := b.call(t, ts.URL, tokFrom, http.MethodPost, "/api/friends/requests", `{"userId":"`+idTo+`"}`)
		mustStatus(t, "send", status, http.StatusCreated, raw)
		id := int64(jsonField(t, raw, "requestId").(float64))
		status, raw = b.call(t, ts.URL, tokTo, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", id), "")
		mustStatus(t, "accept", status, http.StatusOK, raw)
	}
	befriend(tokA, idB, tokB)
	befriend(tokA, idD, tokD)
	status, raw := b.call(t, ts.URL, tokB, http.MethodPost, "/api/friends/requests", `{"userId":"`+idE+`"}`)
	mustStatus(t, "B → E", status, http.StatusCreated, raw)

	// Disabled: gone from A's list, not found — and back when enabled.
	setActive(t, database, idD, false)
	_, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/friends", "")
	if names := len(jsonField(t, raw, "friends").([]any)); names != 1 || !strings.Contains(string(raw), `"Ben"`) {
		t.Fatalf("A's friends with Dora disabled: %s", raw)
	}
	status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/players/"+idD, "")
	mustStatus(t, "a disabled friend", status, http.StatusNotFound, raw)
	setActive(t, database, idD, true)
	_, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/friends", "")
	if names := len(jsonField(t, raw, "friends").([]any)); names != 2 {
		t.Fatalf("A's friends with Dora enabled again: %s", raw)
	}

	// B deletes the account: A keeps D only, E's incoming request is gone.
	status, raw = friendsCall(t, ts.URL, tokB, http.MethodDelete, "/api/account", "")
	mustStatus(t, "delete B", status, http.StatusOK, raw)
	_, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/friends", "")
	if strings.Contains(string(raw), idB) || !strings.Contains(string(raw), idD) {
		t.Fatalf("A's friends after B deleted the account: %s", raw)
	}
	status, raw = b.call(t, ts.URL, tokA, http.MethodGet, "/api/players/"+idB, "")
	mustStatus(t, "a deleted player", status, http.StatusNotFound, raw)
	var friendships, pending, cancelled int64
	if err := database.Pool.QueryRow(context.Background(),
		`SELECT (SELECT count(*) FROM friendships WHERE $1 IN (user_id, friend_user_id)),
		        (SELECT count(*) FROM friend_requests WHERE status = 'PENDING' AND $1 IN (requester_id, recipient_id)),
		        (SELECT count(*) FROM friend_requests WHERE status = 'CANCELLED' AND requester_id = $1 AND recipient_id = $2)`,
		idB, idE).Scan(&friendships, &pending, &cancelled); err != nil {
		t.Fatal(err)
	}
	if friendships != 0 || pending != 0 || cancelled != 1 {
		t.Fatalf("after the deletion: %d friendships, %d pending, %d cancelled", friendships, pending, cancelled)
	}
	_ = idA
	b.assertNothingLeaks(t)
}

// Presence end to end, over real sockets: OFFLINE, ONLINE with a socket,
// PLAYING at a Teen Patti table with its variant, back to ONLINE on leaving,
// PLAYING poker, a move keeping (and rewriting) it, the reconnect grace
// keeping PLAYING with no socket, OFFLINE once the seat lapses — and the list
// ordered PLAYING, ONLINE, OFFLINE, then by name.
func TestFriendsSeeOnlineOfflineAndPlayingWithTheGameAndVariant(t *testing.T) {
	store := livetest.New()
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	cfg.Game.ReconnectGrace = 700 * time.Millisecond
	a := newAppOn(t, cfg, database, store)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	var b friendsBodies

	tokMe, idMe := login(t, ts.URL, "presence-device-me-0001", "Me")
	tokP, idP := login(t, ts.URL, "presence-device-pat-001", "pat")
	tokQ, idQ := login(t, ts.URL, "presence-device-quin-01", "Quinn")
	tokR, idR := login(t, ts.URL, "presence-device-rosa-01", "Rosa")
	_, idS := login(t, ts.URL, "presence-device-sam-001", "Sam")
	for _, other := range []struct{ token, id string }{{tokP, idP}, {tokQ, idQ}, {tokR, idR}} {
		status, raw := b.call(t, ts.URL, other.token, http.MethodPost, "/api/friends/requests", `{"userId":"`+idMe+`"}`)
		mustStatus(t, "send", status, http.StatusCreated, raw)
		status, raw = b.call(t, ts.URL, tokMe, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", int64(jsonField(t, raw, "requestId").(float64))), "")
		mustStatus(t, "accept", status, http.StatusOK, raw)
	}
	_ = idS

	type seen struct{ status, game, variant string }
	friendsOf := func() map[string]seen {
		t.Helper()
		status, raw := b.call(t, ts.URL, tokMe, http.MethodGet, "/api/friends", "")
		mustStatus(t, "list", status, http.StatusOK, raw)
		var body struct {
			Friends []struct {
				UserID  string `json:"userId"`
				Status  string `json:"status"`
				Online  bool   `json:"online"`
				Playing bool   `json:"playing"`
				Game    string `json:"game"`
				Variant string `json:"variant"`
			} `json:"friends"`
		}
		if err := json.Unmarshal(raw, &body); err != nil {
			t.Fatal(err)
		}
		out := map[string]seen{}
		for _, f := range body.Friends {
			if f.Online != (f.Status != "OFFLINE") || f.Playing != (f.Status == "PLAYING") || (f.Game != "") != f.Playing {
				t.Fatalf("an inconsistent presence: %s", raw)
			}
			out[f.UserID] = seen{f.Status, f.Game, f.Variant}
		}
		return out
	}
	waitFor := func(what, id string, want seen) {
		t.Helper()
		deadline := time.Now().Add(4 * time.Second)
		for {
			got := friendsOf()[id]
			if got == want {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("%s: %+v, want %+v", what, got, want)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}

	offline := seen{status: "OFFLINE"}
	online := seen{status: "ONLINE"}
	waitFor("pat, never connected", idP, offline)

	// A socket: ONLINE.
	p := dial(t, ts.URL, tokP)
	waitFor("pat with a socket", idP, online)

	// A seen table: PLAYING Teen Patti · Seen.
	joined := mustOK(t, p, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	seenRoom, _ := jsonPath(joined.Raw, "roomId").(string)
	waitFor("pat at a seen table", idP, seen{"PLAYING", "TEEN_PATTI", "SEEN"})
	record, ok := store.Playing(idP)
	if !ok || record.UpdatedAt <= 0 || record.Game != "TEEN_PATTI" {
		t.Fatalf("the playing record = %+v %v", record, ok)
	}

	// A switch rewrites the record for the new table, still Seen.
	first := record.UpdatedAt
	time.Sleep(5 * time.Millisecond)
	moved := mustOK(t, p, socket.EvRoomSwitch, map[string]any{})
	movedRoom, _ := jsonPath(moved.Raw, "roomId").(string)
	if movedRoom == "" || movedRoom == seenRoom {
		t.Fatalf("the switch: %s", moved.Raw)
	}
	waitFor("pat after the switch", idP, seen{"PLAYING", "TEEN_PATTI", "SEEN"})
	if again, _ := store.Playing(idP); again.UpdatedAt <= first {
		t.Fatalf("the switch did not rewrite the record: %d then %d", first, again.UpdatedAt)
	}

	// Leaving the table: back to ONLINE.
	mustOK(t, p, socket.EvRoomLeave, map[string]any{})
	waitFor("pat back in the lobby", idP, online)

	// Poker: PLAYING Poker · Texas Hold'em, and the other three variants.
	q := dial(t, ts.URL, tokQ)
	pokerJoin := mustOK(t, q, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "texas_holdem"})
	pokerRoom, _ := jsonPath(pokerJoin.Raw, "roomId").(string)
	waitFor("quinn at hold'em", idQ, seen{"PLAYING", "POKER", "TEXAS_HOLDEM"})
	mustOK(t, q, socket.EvRoomLeave, map[string]any{})
	for _, variant := range []string{"omaha", "five_card_draw", "three_card_poker"} {
		mustOK(t, q, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": variant})
		waitFor("quinn at "+variant, idQ, seen{"PLAYING", "POKER", strings.ToUpper(variant)})
		mustOK(t, q, socket.EvRoomLeave, map[string]any{})
	}
	mustOK(t, q, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "blind"})
	waitFor("quinn at blind", idQ, seen{"PLAYING", "TEEN_PATTI", "BLIND"})

	// The list's order: PLAYING, then ONLINE, then OFFLINE, each by name
	// whatever its case ("pat" before "Rosa" were both online).
	r := dial(t, ts.URL, tokR)
	waitFor("rosa online", idR, online)
	_, raw := b.call(t, ts.URL, tokMe, http.MethodGet, "/api/friends", "")
	order := regexp.MustCompile(`"displayName":"([^"]+)"`).FindAllStringSubmatch(string(raw), -1)
	if len(order) != 3 || order[0][1] != "Quinn" || order[1][1] != "pat" || order[2][1] != "Rosa" {
		t.Fatalf("the list's order: %s", raw)
	}
	r.Close()
	waitFor("rosa's socket closed", idR, offline)
	_, raw = b.call(t, ts.URL, tokMe, http.MethodGet, "/api/friends", "")
	order = regexp.MustCompile(`"displayName":"([^"]+)"`).FindAllStringSubmatch(string(raw), -1)
	if len(order) != 3 || order[0][1] != "Quinn" || order[1][1] != "pat" || order[2][1] != "Rosa" {
		t.Fatalf("the list's order with Rosa offline: %s", raw)
	}

	// The reconnect grace: Quinn's socket drops, the seat is held — PLAYING
	// and online, though kt:online is cleared — until the seat lapses.
	q.Close()
	if _, live := store.Online(idQ); live {
		deadline := time.Now().Add(2 * time.Second)
		for live && time.Now().Before(deadline) {
			time.Sleep(10 * time.Millisecond)
			_, live = store.Online(idQ)
		}
	}
	if _, live := store.Online(idQ); live {
		t.Fatal("the dropped socket's presence entry was never cleared")
	}
	if got := friendsOf()[idQ]; got != (seen{"PLAYING", "TEEN_PATTI", "BLIND"}) {
		t.Fatalf("inside the reconnect grace: %+v, want PLAYING", got)
	}
	status, raw := b.call(t, ts.URL, tokMe, http.MethodGet, "/api/players/"+idQ+"/profile", "")
	mustStatus(t, "quinn's profile in the grace", status, http.StatusOK, raw)
	if jsonField(t, raw, "profile.presence.status") != "PLAYING" || jsonField(t, raw, "profile.presence.online") != true ||
		jsonField(t, raw, "profile.presence.game") != "TEEN_PATTI" || jsonField(t, raw, "profile.presence.variant") != "BLIND" {
		t.Fatalf("quinn's profile in the grace: %s", raw)
	}
	t.Logf("GET /api/players/{playerId}/profile (PLAYING, in the grace): %s", raw)
	waitFor("quinn after the grace", idQ, offline)

	t.Logf("GET /api/friends (with presence): %s", func() []byte {
		_, raw := friendsCall(t, ts.URL, tokMe, http.MethodGet, "/api/friends", "")
		return raw
	}())
	b.assertNothingLeaks(t, seenRoom, movedRoom, pokerRoom)
}

// A live store that cannot answer does not take Friends down: every friend
// reads OFFLINE, and one WARN says why.
func TestFriendsAnswerEveryoneOfflineWhenTheLiveStoreFails(t *testing.T) {
	store := livetest.New()
	database := dbtest.Open(t, "app")
	logs := &syncBuffer{}
	a, err := New(Options{Config: testConfig(t, publicDir(t)), DB: database, Logger: util.NewLogger("info", logs), Live: store})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		_ = a.Shutdown(ctx)
	})
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	tokA, idA := login(t, ts.URL, "presence-fail-anna-01", "Anna")
	tokB, idB := login(t, ts.URL, "presence-fail-ben-001", "Ben")
	status, raw := friendsCall(t, ts.URL, tokA, http.MethodPost, "/api/friends/requests", `{"userId":"`+idB+`"}`)
	mustStatus(t, "send", status, http.StatusCreated, raw)
	status, raw = friendsCall(t, ts.URL, tokB, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", int64(jsonField(t, raw, "requestId").(float64))), "")
	mustStatus(t, "accept", status, http.StatusOK, raw)
	b := dial(t, ts.URL, tokB)
	mustOK(t, b, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	if _, ok := store.Playing(idB); !ok {
		t.Fatal("B is not playing")
	}

	store.Fail(livetest.OpPresence, errors.New("redis: connection refused"))
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodGet, "/api/friends", "")
	mustStatus(t, "the list with the store down", status, http.StatusOK, raw)
	if jsonField(t, raw, "friends").([]any)[0].(map[string]any)["status"] != "OFFLINE" {
		t.Fatalf("the list with the store down: %s", raw)
	}
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodGet, "/api/players/"+idB+"/profile", "")
	if status != http.StatusOK || jsonField(t, raw, "profile.presence.status") != "OFFLINE" {
		t.Fatalf("the profile with the store down: %d %s", status, raw)
	}
	warned := logs.logLines("friends presence unavailable; answering every friend offline")
	if len(warned) != 2 || warned[0]["level"] != "WARN" {
		t.Fatalf("one WARN per answer, got %d: %s", len(warned), logs.String())
	}

	store.Fail(livetest.OpPresence, nil)
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodGet, "/api/friends", "")
	if status != http.StatusOK || jsonField(t, raw, "friends").([]any)[0].(map[string]any)["status"] != "PLAYING" {
		t.Fatalf("the list with the store back: %d %s", status, raw)
	}
	_ = idA
}

// A restart keeps a seated friend PLAYING: the seat and its record are handed
// to the next process, whose restore writes the record again.
func TestARestartKeepsAFriendPlaying(t *testing.T) {
	database := dbtest.Open(t, "app")
	store := livetest.New()
	cfg := testConfig(t, publicDir(t))
	cfg.Game.ReconnectGrace = 3 * time.Second

	first := newAppOn(t, cfg, database, store)
	ts1 := httptest.NewServer(first.Handler())
	tokA, idA := login(t, ts1.URL, "restart-friend-anna-01", "Anna")
	tokB, idB := login(t, ts1.URL, "restart-friend-ben-001", "Ben")
	status, raw := friendsCall(t, ts1.URL, tokA, http.MethodPost, "/api/friends/requests", `{"userId":"`+idB+`"}`)
	mustStatus(t, "send", status, http.StatusCreated, raw)
	status, raw = friendsCall(t, ts1.URL, tokB, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", int64(jsonField(t, raw, "requestId").(float64))), "")
	mustStatus(t, "accept", status, http.StatusOK, raw)
	b1 := dial(t, ts1.URL, tokB)
	mustOK(t, b1, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "variation"})
	before, ok := store.Playing(idB)
	if !ok || before.Variant != "VARIATION" {
		t.Fatalf("before the restart: %+v %v", before, ok)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := first.Shutdown(ctx); err != nil {
		t.Fatalf("shutdown: %v", err)
	}
	ts1.Close()

	second := newAppOn(t, cfg, database, store)
	ts2 := httptest.NewServer(second.Handler())
	defer ts2.Close()
	if second.Restore().Seats != 1 {
		t.Fatalf("restore: %+v", second.Restore())
	}
	after, ok := store.Playing(idB)
	if !ok || after.Game != "TEEN_PATTI" || after.Variant != "VARIATION" || after.UpdatedAt < before.UpdatedAt {
		t.Fatalf("after the restart: %+v %v", after, ok)
	}
	status, raw = friendsCall(t, ts2.URL, tokA, http.MethodGet, "/api/friends", "")
	if status != http.StatusOK || jsonField(t, raw, "friends").([]any)[0].(map[string]any)["status"] != "PLAYING" {
		t.Fatalf("A's list after the restart: %d %s", status, raw)
	}
	_ = idA
}

// The friends routes are counted under their PATTERNS — never an id in a
// label (the metrics label rule).
func TestTheFriendsRoutesAreLabelledByPattern(t *testing.T) {
	a, _ := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	tokA, idA := login(t, ts.URL, "labels-device-anna-001", "Anna")
	tokB, idB := login(t, ts.URL, "labels-device-ben-0001", "Ben")
	friendsCall(t, ts.URL, tokA, http.MethodGet, "/api/players/"+idB, "")
	friendsCall(t, ts.URL, tokA, http.MethodGet, "/api/players/"+idB+"/profile", "")
	_, raw := friendsCall(t, ts.URL, tokA, http.MethodPost, "/api/friends/requests", `{"userId":"`+idB+`"}`)
	id := int64(jsonField(t, raw, "requestId").(float64))
	friendsCall(t, ts.URL, tokA, http.MethodGet, "/api/friends/requests", "")
	friendsCall(t, ts.URL, tokB, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", id), "")
	friendsCall(t, ts.URL, tokB, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/reject", id), "")
	friendsCall(t, ts.URL, tokA, http.MethodGet, "/api/friends", "")
	friendsCall(t, ts.URL, tokA, http.MethodDelete, "/api/friends/"+idB, "")

	res, body := get(t, a.Handler(), http.MethodGet, "/metrics", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+metricsToken) })
	if res.StatusCode != http.StatusOK {
		t.Fatalf("/metrics: %d", res.StatusCode)
	}
	text := string(body)
	for _, want := range []string{
		`route="/api/players/{playerId}",service="king-teenpatti",status_code="200"`,
		`route="/api/players/{playerId}/profile",service="king-teenpatti",status_code="200"`,
		`method="POST",route="/api/friends/requests",service="king-teenpatti",status_code="201"`,
		`method="GET",route="/api/friends/requests",service="king-teenpatti",status_code="200"`,
		`route="/api/friends/requests/{requestId}/accept",service="king-teenpatti",status_code="200"`,
		`route="/api/friends/requests/{requestId}/reject",service="king-teenpatti",status_code="409"`,
		`method="GET",route="/api/friends",service="king-teenpatti",status_code="200"`,
		`method="DELETE",route="/api/friends/{friendUserId}",service="king-teenpatti",status_code="200"`,
		`game_live_store_operations_total{op="presence",result="ok",service="king-teenpatti"}`,
	} {
		if !strings.Contains(text, want) {
			t.Errorf("the exposition lacks %q", want)
		}
	}
	// Every route label is a pattern: no player id, no request id.
	for _, m := range regexp.MustCompile(`route="([^"]*)"`).FindAllStringSubmatch(text, -1) {
		route := m[1]
		if strings.Contains(route, idA) || strings.Contains(route, idB) || regexp.MustCompile(`/\d+(/|$)`).MatchString(route) {
			t.Errorf("route label %q carries an id (request %d)", route, id)
		}
	}
	if regexp.MustCompile(`(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`).MatchString(text) {
		t.Error("a UUID reached the exposition")
	}
}
