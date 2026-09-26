package app

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// Friends at the table (owner, 26 Sep 2026) on the real wiring: a friend
// request made over REST reaches its recipient's live socket as
// friend:request, and its accept reaches the sender's as friend:accepted —
// wherever each is, in the lobby or seated mid-hand — once committed; a
// reject, a removal or a refusal reaches nobody; nothing is kept for a player
// with no socket; and no push carries a wallet or a table.

const pushWait = 4 * time.Second

// pingBarrier is a ping:rtt round trip on c: every frame the server queued for
// c before it answered — a push included — has arrived once the ack has.
func pingBarrier(t *testing.T, c *testclient.Client) {
	t.Helper()
	if _, err := c.Request(socket.EvPingRTT, 1, pushWait); err != nil {
		t.Fatalf("ping: %v", err)
	}
}

// friendPushes is every friend:* event c has received, "name payload".
func friendPushes(c *testclient.Client) []string {
	var out []string
	for _, e := range c.Events() {
		if e.Name == socket.EvFriendRequest || e.Name == socket.EvFriendAccepted {
			out = append(out, e.Name+" "+string(e.Payload))
		}
	}
	return out
}

// requestIDOf is the requestId of a 201 or a push.
func requestIDOf(t *testing.T, raw []byte) int64 {
	t.Helper()
	id, ok := jsonPath(raw, "requestId").(float64)
	if !ok || id <= 0 {
		t.Fatalf("no requestId in %s", raw)
	}
	return int64(id)
}

// sendRequest is POST /api/friends/requests, which must answer 201.
func sendRequest(t *testing.T, baseURL, token, to string) int64 {
	t.Helper()
	status, raw := friendsCall(t, baseURL, token, http.MethodPost, "/api/friends/requests", `{"userId":"`+to+`"}`)
	mustStatus(t, "send", status, http.StatusCreated, raw)
	return requestIDOf(t, raw)
}

// incomingItem is the recipient's GET /api/friends/requests' incoming item
// for requestID, as its raw JSON.
func incomingItem(t *testing.T, baseURL, token string, requestID int64) string {
	t.Helper()
	status, raw := friendsCall(t, baseURL, token, http.MethodGet, "/api/friends/requests", "")
	mustStatus(t, "requests", status, http.StatusOK, raw)
	var body struct {
		Incoming []json.RawMessage `json:"incoming"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatal(err)
	}
	for _, item := range body.Incoming {
		if requestIDOf(t, item) == requestID {
			return string(item)
		}
	}
	t.Fatalf("request %d is not in %s", requestID, raw)
	return ""
}

// friendInList is the sender's GET /api/friends item for friendID, decoded.
func friendInList(t *testing.T, baseURL, token, friendID string) map[string]any {
	t.Helper()
	status, raw := friendsCall(t, baseURL, token, http.MethodGet, "/api/friends", "")
	mustStatus(t, "friends", status, http.StatusOK, raw)
	var body struct {
		Friends []map[string]any `json:"friends"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatal(err)
	}
	for _, f := range body.Friends {
		if f["userId"] == friendID {
			return f
		}
	}
	t.Fatalf("%s is not in %s", friendID, raw)
	return nil
}

// checkAccepted holds a friend:accepted payload to the sender's own friend
// list: the accepter's card, exactly as the list shows it, and the list's
// friendsSince.
func checkAccepted(t *testing.T, payload json.RawMessage, requestID int64, listed map[string]any) {
	t.Helper()
	var push struct {
		RequestID    int64          `json:"requestId"`
		Player       map[string]any `json:"player"`
		FriendsSince float64        `json:"friendsSince"`
	}
	if err := json.Unmarshal(payload, &push); err != nil {
		t.Fatal(err)
	}
	var keys []string
	for k := range push.Player {
		keys = append(keys, k)
	}
	if push.RequestID != requestID || len(push.Player) != 3 || push.FriendsSince <= 0 || push.FriendsSince != listed["friendsSince"] {
		t.Fatalf("friend:accepted %s against the list's %v (player keys %v)", payload, listed, keys)
	}
	for _, k := range []string{"userId", "displayName", "profilePicture"} {
		if fmt.Sprint(push.Player[k]) != fmt.Sprint(listed[k]) {
			t.Fatalf("friend:accepted's %s = %v, the list says %v", k, push.Player[k], listed[k])
		}
	}
}

// assertNoWalletOrTable: no push names a wallet, a table, a seat or a room.
func assertNoWalletOrTable(t *testing.T, pushes []string, roomIDs ...string) {
	t.Helper()
	forbidden := []string{"chips", "diamond", "hammer", "missile", "wallet", "room", "table", "seat", "code", "pot", "stake", "boot"}
	for _, p := range pushes {
		lower := strings.ToLower(p)
		for _, word := range forbidden {
			if strings.Contains(lower, word) {
				t.Errorf("a push carries %q: %s", word, p)
			}
		}
		for _, id := range roomIDs {
			if id != "" && strings.Contains(p, id) {
				t.Errorf("a push names room %s: %s", id, p)
			}
		}
	}
}

func TestAFriendRequestAndItsAcceptReachTheOtherPlayersSocket(t *testing.T) {
	a, _ := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	tokA, idA := login(t, ts.URL, "push-device-alice-0001", "Alice")
	tokB, idB := login(t, ts.URL, "push-device-bobby-0001", "Bobby")
	ca, cb := dial(t, ts.URL, tokA), dial(t, ts.URL, tokB)

	// A asks: B is told, with A's card and the id the 201 carried — byte for
	// byte the item B's own GET /api/friends/requests lists.
	requestID := sendRequest(t, ts.URL, tokA, idB)
	pushed, err := cb.Wait(socket.EvFriendRequest, nil, pushWait)
	if err != nil {
		t.Fatalf("B was not told: %v", err)
	}
	if requestIDOf(t, pushed) != requestID || jsonPath(pushed, "player.userId") != idA || jsonPath(pushed, "player.displayName") != "Alice" {
		t.Fatalf("friend:request = %s", pushed)
	}
	if item := incomingItem(t, ts.URL, tokB, requestID); string(pushed) != item {
		t.Fatalf("friend:request\n %s\nB's incoming item\n %s", pushed, item)
	}
	t.Logf("friend:request: %s", pushed)

	// B accepts: A is told, with B's card and friendsSince as A's list says.
	status, raw := friendsCall(t, ts.URL, tokB, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", requestID), "")
	mustStatus(t, "B accepts", status, http.StatusOK, raw)
	accepted, err := ca.Wait(socket.EvFriendAccepted, nil, pushWait)
	if err != nil {
		t.Fatalf("A was not told: %v", err)
	}
	checkAccepted(t, accepted, requestID, friendInList(t, ts.URL, tokA, idB))
	if jsonPath(accepted, "player.userId") != idB || jsonPath(accepted, "player.displayName") != "Bobby" ||
		jsonPath(accepted, "friendsSince") != jsonPath(raw, "friend.friendsSince") {
		t.Fatalf("friend:accepted = %s, the accept answered %s", accepted, raw)
	}
	t.Logf("friend:accepted: %s", accepted)

	// Each was told exactly once, and only of what concerns them.
	pingBarrier(t, ca)
	pingBarrier(t, cb)
	if got := friendPushes(ca); len(got) != 1 || !strings.HasPrefix(got[0], socket.EvFriendAccepted+" ") {
		t.Fatalf("A received %q", got)
	}
	if got := friendPushes(cb); len(got) != 1 || !strings.HasPrefix(got[0], socket.EvFriendRequest+" ") {
		t.Fatalf("B received %q", got)
	}
	assertNoWalletOrTable(t, append(friendPushes(ca), friendPushes(cb)...))
}

// A reject, a removal and every refusal reach nobody.
func TestARejectARemovalOrARefusalIsNeverAnnounced(t *testing.T) {
	a, _ := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	tokA, idA := login(t, ts.URL, "push-quiet-alice-00001", "Alice")
	tokB, idB := login(t, ts.URL, "push-quiet-bobby-00001", "Bobby")
	ca, cb := dial(t, ts.URL, tokA), dial(t, ts.URL, tokB)

	// B rejects A's request: A hears nothing.
	first := sendRequest(t, ts.URL, tokA, idB)
	status, raw := friendsCall(t, ts.URL, tokB, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/reject", first), "")
	mustStatus(t, "B rejects", status, http.StatusOK, raw)
	pingBarrier(t, ca)
	if got := friendPushes(ca); len(got) != 0 {
		t.Fatalf("a rejection was announced to A: %q", got)
	}

	// A asks again; then the refusals — A again, B the other way, A to
	// themselves, nobody, answering twice — and a removal.
	second := sendRequest(t, ts.URL, tokA, idB)
	for _, c := range []struct {
		what, token, method, path, body string
		status                          int
	}{
		{"A again", tokA, http.MethodPost, "/api/friends/requests", `{"userId":"` + idB + `"}`, http.StatusConflict},
		{"B the other way", tokB, http.MethodPost, "/api/friends/requests", `{"userId":"` + idA + `"}`, http.StatusConflict},
		{"A to themselves", tokA, http.MethodPost, "/api/friends/requests", `{"userId":"` + idA + `"}`, http.StatusBadRequest},
		{"to nobody", tokA, http.MethodPost, "/api/friends/requests", `{"userId":"no-such-player"}`, http.StatusNotFound},
		{"the rejected one accepted", tokB, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", first), "", http.StatusConflict},
		{"accepted by its sender", tokA, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", second), "", http.StatusNotFound},
	} {
		status, raw := friendsCall(t, ts.URL, c.token, c.method, c.path, c.body)
		mustStatus(t, c.what, status, c.status, raw)
	}
	status, raw = friendsCall(t, ts.URL, tokB, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", second), "")
	mustStatus(t, "B accepts", status, http.StatusOK, raw)
	status, raw = friendsCall(t, ts.URL, tokB, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", second), "")
	mustStatus(t, "B accepts twice", status, http.StatusConflict, raw)
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodDelete, "/api/friends/"+idB, "")
	mustStatus(t, "A removes B", status, http.StatusOK, raw)
	status, raw = friendsCall(t, ts.URL, tokA, http.MethodDelete, "/api/friends/"+idB, "")
	mustStatus(t, "A removes B again", status, http.StatusNotFound, raw)

	// B was told of the two requests, A of the one accept — nothing else.
	pingBarrier(t, ca)
	pingBarrier(t, cb)
	gotB := friendPushes(cb)
	if len(gotB) != 2 || !strings.HasPrefix(gotB[0], socket.EvFriendRequest+" ") || !strings.HasPrefix(gotB[1], socket.EvFriendRequest+" ") ||
		!strings.Contains(gotB[0], fmt.Sprintf(`"requestId":%d,`, first)) || !strings.Contains(gotB[1], fmt.Sprintf(`"requestId":%d,`, second)) {
		t.Fatalf("B received %q", gotB)
	}
	gotA := friendPushes(ca)
	if len(gotA) != 1 || !strings.HasPrefix(gotA[0], socket.EvFriendAccepted+" ") || !strings.Contains(gotA[0], fmt.Sprintf(`"requestId":%d,`, second)) {
		t.Fatalf("A received %q", gotA)
	}
}

// A request to a player with no socket is made all the same, and nothing is
// sent anywhere — nor kept for when they connect: their list has it.
func TestARequestToAPlayerWithNoSocketIsMadeAndNothingIsSent(t *testing.T) {
	a, _ := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	tokA, _ := login(t, ts.URL, "push-away-alice-000001", "Alice")
	tokB, idB := login(t, ts.URL, "push-away-bobby-000001", "Bobby")
	ca := dial(t, ts.URL, tokA)

	requestID := sendRequest(t, ts.URL, tokA, idB)
	pingBarrier(t, ca)
	if got := friendPushes(ca); len(got) != 0 {
		t.Fatalf("the sender was told of their own request: %q", got)
	}
	res, body := get(t, a.Handler(), http.MethodGet, "/metrics", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+metricsToken) })
	if res.StatusCode != http.StatusOK {
		t.Fatalf("/metrics: %d", res.StatusCode)
	}
	if strings.Contains(string(body), "friend:") {
		t.Fatalf("a push was sent: %s", grepLines(string(body), "friend:"))
	}

	cb := dial(t, ts.URL, tokB)
	pingBarrier(t, cb)
	if got := friendPushes(cb); len(got) != 0 {
		t.Fatalf("a push was kept for B: %q", got)
	}
	incomingItem(t, ts.URL, tokB, requestID) // …and B's list has it
}

// The table rule: two players seated at one table, mid-hand, befriend each
// other — no `seated` refusal — and each is told on their table socket, while
// the hand plays on and no push names the table.
func TestTwoPlayersSeatedAtOneTableBefriendEachOtherMidHand(t *testing.T) {
	a, _ := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	tokA, idA := login(t, ts.URL, "push-table-alice-00001", "Alice")
	tokB, idB := login(t, ts.URL, "push-table-bobby-00001", "Bobby")
	ca, cb := dial(t, ts.URL, tokA), dial(t, ts.URL, tokB)

	join := map[string]any{"bootAmount": 200, "category": "seen"}
	joinedA := mustOK(t, ca, socket.EvRoomQuickJoin, join)
	joinedB := mustOK(t, cb, socket.EvRoomQuickJoin, join)
	roomID, _ := jsonPath(joinedA.Raw, "roomId").(string)
	code, _ := jsonPath(joinedA.Raw, "code").(string)
	if roomID == "" || jsonPath(joinedB.Raw, "roomId") != roomID {
		t.Fatalf("not one table: %s / %s", joinedA.Raw, joinedB.Raw)
	}
	if _, err := ca.Wait(socket.EvGameHandStarted, nil, pushWait); err != nil {
		t.Fatalf("no hand: %v", err)
	}

	requestID := sendRequest(t, ts.URL, tokA, idB)
	pushed, err := cb.Wait(socket.EvFriendRequest, nil, pushWait)
	if err != nil {
		t.Fatalf("B, seated, was not told: %v", err)
	}
	if requestIDOf(t, pushed) != requestID || jsonPath(pushed, "player.userId") != idA {
		t.Fatalf("friend:request = %s", pushed)
	}
	status, raw := friendsCall(t, ts.URL, tokB, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", requestID), "")
	mustStatus(t, "B accepts, seated", status, http.StatusOK, raw)
	accepted, err := ca.Wait(socket.EvFriendAccepted, nil, pushWait)
	if err != nil {
		t.Fatalf("A, seated, was not told: %v", err)
	}
	checkAccepted(t, accepted, requestID, friendInList(t, ts.URL, tokA, idB))

	// Both still seated at that table, neither moved, kicked or closed out.
	for _, id := range []string{idA, idB} {
		if room := a.rooms.GetTableForPlayer(id); room == nil || room.ID() != roomID {
			t.Fatalf("%s is no longer at the table", id)
		}
	}
	pingBarrier(t, ca)
	pingBarrier(t, cb)
	for _, c := range []*testclient.Client{ca, cb} {
		for _, e := range c.Events() {
			switch e.Name {
			case socket.EvRoomLeft, socket.EvRoomKicked, socket.EvRoomClosed, socket.EvRoomMoved:
				t.Fatalf("a friend action moved a player: %s %s", e.Name, e.Payload)
			}
		}
	}
	pushes := append(friendPushes(ca), friendPushes(cb)...)
	if len(pushes) != 2 {
		t.Fatalf("pushes = %q", pushes)
	}
	assertNoWalletOrTable(t, pushes, roomID, code)
}

// grepLines is the lines of text containing needle.
func grepLines(text, needle string) string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		if strings.Contains(line, needle) {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}
