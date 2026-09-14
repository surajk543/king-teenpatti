package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
)

// catalogue is GET /api/profiles as a signed-out client reads it.
func catalogue(t *testing.T, baseURL string) []db.Picture {
	t.Helper()
	res, err := http.Get(baseURL + "/api/profiles")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/profiles: %d", res.StatusCode)
	}
	var body struct {
		Profiles []db.Picture `json:"profiles"`
	}
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return body.Profiles
}

// hammerBooks is one account's users.hammer, its hammer_spends rows and its
// picture ownership rows.
func hammerBooks(t *testing.T, database *db.DB, userID string) (hammers, spends, owned int64) {
	t.Helper()
	if err := database.Pool.QueryRow(context.Background(),
		`SELECT hammer,
		        (SELECT count(*) FROM hammer_spends WHERE user_id = $1),
		        (SELECT count(*) FROM user_profile_pictures WHERE user_id = $1)
		   FROM users WHERE id = $1`, userID).Scan(&hammers, &spends, &owned); err != nil {
		t.Fatal(err)
	}
	return hammers, spends, owned
}

// A picture priced in hammers over REST, on the real wiring (owner, 14 Sep
// 2026). The seeded catalogue lists it as HAMMER. In the lobby the buy answers
// {user, picture, charged, spent} with spent in hammers, and moves no chip, no
// ledger row and no hammer_spends row; buying again charges nothing. A hammer
// wallet short of the price is 409 picture_chips, naming the price. A seated
// player buys one and wears it on the seat, while a chip-priced picture is
// still 409 seated and the seat and wallet keep their chips.
func TestAHammerPictureIsBoughtOverRESTInTheLobbyAndAtATable(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	welcome := a.cfg.Game.WelcomeChips

	var pic, coin db.Picture
	for _, p := range catalogue(t, ts.URL) {
		if pic.ID == 0 && p.Currency == db.PictureCurrencyHammer {
			pic = p
		}
		if coin.ID == 0 && p.Currency == db.PictureCurrencyCoin && p.Type == db.PicturePremium {
			coin = p
		}
	}
	if pic.ID == 0 || coin.ID == 0 {
		t.Fatal("the seeded catalogue lacks a hammer picture or a chip-priced premium one")
	}
	if pic.Type != db.PicturePremium || pic.Cost != 10 || pic.Owned {
		t.Fatalf("seeded hammer picture as listed: %+v", pic)
	}

	// In the lobby.
	token, id := login(t, ts.URL, "hammer-picture-buyer", "Hammer Buyer")
	res := postJSON(ts.URL, token, "/api/profile/picture/buy", map[string]any{"pictureId": pic.ID})
	if res.err != nil || res.status != http.StatusOK || res.body["charged"] != true || res.body["spent"] != float64(pic.Cost) {
		t.Fatalf("lobby hammer buy: %d %v %v", res.status, res.body, res.err)
	}
	if len(res.body) != 4 {
		t.Errorf("the answer is %v, want exactly user, picture, charged and spent", res.body)
	}
	user, _ := res.body["user"].(map[string]any)
	if user["hammer"] != float64(20-pic.Cost) || user["chips"] != float64(welcome) || user["diamond"] != float64(9) {
		t.Errorf("the answer's user after a hammer buy: %v", user)
	}
	picture, _ := res.body["picture"].(map[string]any)
	if picture["id"] != float64(pic.ID) || picture["currency"] != "HAMMER" || picture["owned"] != true {
		t.Errorf("the answer's picture: %v", picture)
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != welcome || ledger != welcome {
		t.Errorf("a hammer picture moved chips: wallet %d, ledger %d, want both %d", wallet, ledger, welcome)
	}
	if hammers, spends, owned := hammerBooks(t, database, id); hammers != 20-pic.Cost || spends != 0 || owned != 1 {
		t.Errorf("after the buy: hammers %d, hammer_spends %d, ownership rows %d", hammers, spends, owned)
	}

	res = postJSON(ts.URL, token, "/api/profile/picture/buy", map[string]any{"pictureId": pic.ID})
	if res.err != nil || res.status != http.StatusOK || res.body["charged"] != false || res.body["spent"] != float64(0) {
		t.Errorf("buying it again: %d %v %v", res.status, res.body, res.err)
	}
	if hammers, _, _ := hammerBooks(t, database, id); hammers != 20-pic.Cost {
		t.Errorf("buying it again took hammers: %d left", hammers)
	}

	// Short of the price.
	shortToken, shortID := login(t, ts.URL, "hammer-picture-short", "Hammer Short")
	if _, err := database.Pool.Exec(ctx, `UPDATE users SET hammer = $2 WHERE id = $1`, shortID, pic.Cost-1); err != nil {
		t.Fatal(err)
	}
	res = postJSON(ts.URL, shortToken, "/api/profile/picture/buy", map[string]any{"pictureId": pic.ID})
	want := fmt.Sprintf("You need %d hammers to unlock this picture.", pic.Cost)
	if res.err != nil || res.status != http.StatusConflict || res.body["error"] != auth.CodePictureChips || res.body["message"] != want {
		t.Errorf("a short hammer wallet: %d %v %v, want 409 %s %q", res.status, res.body, res.err, auth.CodePictureChips, want)
	}
	if hammers, spends, owned := hammerBooks(t, database, shortID); hammers != pic.Cost-1 || spends != 0 || owned != 0 {
		t.Errorf("a refused buy moved something: hammers %d, hammer_spends %d, ownership rows %d", hammers, spends, owned)
	}
	if wallet, ledger := walletAndLedger(t, database, shortID); wallet != welcome || ledger != welcome {
		t.Errorf("a refused hammer buy moved chips: wallet %d, ledger %d", wallet, ledger)
	}

	// At a table.
	seatedToken, seatedID := login(t, ts.URL, "hammer-picture-seated", "Hammer Seated")
	c := dial(t, ts.URL, seatedToken)
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	table := a.Rooms().GetTableForPlayer(seatedID)
	if table == nil {
		t.Fatal("the player is not seated after a quick join")
	}
	res = postJSON(ts.URL, seatedToken, "/api/profile/picture/buy", map[string]any{"pictureId": coin.ID})
	if res.err != nil || res.status != http.StatusConflict || res.body["error"] != auth.CodeSeated {
		t.Errorf("a seated coin buy: %d %v %v, want 409 seated", res.status, res.body, res.err)
	}
	res = postJSON(ts.URL, seatedToken, "/api/profile/picture/buy", map[string]any{"pictureId": pic.ID})
	if res.err != nil || res.status != http.StatusOK || res.body["charged"] != true || res.body["spent"] != float64(pic.Cost) {
		t.Fatalf("a seated hammer buy: %d %v %v", res.status, res.body, res.err)
	}
	res = postJSON(ts.URL, seatedToken, "/api/profile/avatar", map[string]any{"avatar": pic.ID})
	if res.err != nil || res.status != http.StatusOK {
		t.Fatalf("wearing the hammer picture at the table: %d %v %v", res.status, res.body, res.err)
	}
	seat, err := table.FindSeat(seatedID)
	if err != nil || seat == nil {
		t.Fatalf("seat: %v", err)
	}
	if seat.AvatarURL == nil || *seat.AvatarURL != pic.URL {
		t.Errorf("the seat wears %v, want %s", seat.AvatarURL, pic.URL)
	}
	if hammers, spends, _ := hammerBooks(t, database, seatedID); hammers != 20-pic.Cost || spends != 0 {
		t.Errorf("a seated hammer buy: hammers %d, hammer_spends %d", hammers, spends)
	}
	if wallet, ledger := walletAndLedger(t, database, seatedID); seat.Chips != welcome || wallet != welcome || ledger != welcome {
		t.Errorf("chips moved while seated: seat %d, wallet %d, ledger %d, want all %d", seat.Chips, wallet, ledger, welcome)
	}
	mustOK(t, c, socket.EvRoomLeave, map[string]any{})
}
