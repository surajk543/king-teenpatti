package app

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// signedIn logs a guest in through the handler and returns a request mutator
// carrying its token.
func signedIn(t *testing.T, h http.Handler, deviceID string) func(*http.Request) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/auth/login",
		bytes.NewBufferString(`{"provider":"guest","deviceId":"`+deviceID+`","displayName":"Rooms"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var out struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil || out.Token == "" {
		t.Fatalf("login: %d %s", rec.Code, rec.Body.String())
	}
	return func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+out.Token) }
}

// OpenRoomIDs names every registered room — what a shutdown that ran out of
// budget left behind, which cmd/gameplay logs (chaos-F1, 24 Sep 2026).
func TestOpenRoomIDsNamesEveryRegisteredRoom(t *testing.T) {
	a, _ := newApp(t, nil)
	if got := a.OpenRoomIDs(); len(got) != 0 {
		t.Fatalf("a fresh app has rooms %v", got)
	}
	room := a.Rooms().CreateTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})
	if got := a.OpenRoomIDs(); len(got) != 1 || got[0] != room.ID() {
		t.Fatalf("OpenRoomIDs = %v, want [%s]", got, room.ID())
	}
}

// GET /api/rooms is for signed-in players only and names no join code and
// no pot (secrecy-F2, 24 Sep 2026): served to anyone, it let a scraper watch
// every live public table's code and pot.
func TestTheRoomsListNeedsASessionAndCarriesNoCodeOrPot(t *testing.T) {
	a, _ := newApp(t, nil)
	h := a.Handler()
	a.Rooms().CreateTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})

	res, body := get(t, h, http.MethodGet, "/api/rooms", nil)
	if res.StatusCode != http.StatusUnauthorized || !strings.Contains(string(body), `"missing_token"`) {
		t.Fatalf("no token: %d %s", res.StatusCode, body)
	}

	res, body = get(t, h, http.MethodGet, "/api/rooms", signedIn(t, h, "rooms-auth-device-01"))
	if res.StatusCode != http.StatusOK {
		t.Fatalf("signed in: %d %s", res.StatusCode, body)
	}
	var out struct {
		Tables []map[string]json.RawMessage `json:"tables"`
	}
	if err := json.Unmarshal(body, &out); err != nil || len(out.Tables) != 1 {
		t.Fatalf("tables: %v %s", err, body)
	}
	for _, key := range []string{"code", "pot"} {
		if _, ok := out.Tables[0][key]; ok {
			t.Errorf("a listed table carries %q: %s", key, body)
		}
	}
	for _, key := range []string{"roomId", "category", "state", "players", "maxPlayers", "bootAmount"} {
		if _, ok := out.Tables[0][key]; !ok {
			t.Errorf("a listed table lacks %q: %s", key, body)
		}
	}
}
