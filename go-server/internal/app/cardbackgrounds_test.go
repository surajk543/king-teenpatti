package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// The card backs on the real wiring (owner, 3 Oct 2026: "Add a table
// cards_background which users can buy just like user can buy
// profile_pictures … add one more tab Cards in Store which user can buy …
// keep the price of all cards 5 Hammers validity 10 days"): the catalogue over
// REST, a buy with hammers, and the card back a player chooses on their seat —
// on every viewer's room:state — over real sockets.

// brutalDemon is the first of the seed's card backs, as a location: the
// owner's file in the bucket's cards/ folder, its spaces written %20.
const brutalDemon = seededAssets + "cards/Brutal%20Demon.jpg"

// seededCardBacks is how many card backs the seed lists (V1.0.1__seed.sql,
// THE CARD BACKS; internal/db's seededCards pins each one): the owner's eight,
// and the five Flower backs they added that evening.
const seededCardBacks = 13

// seededCardCost is what the seed prices a card back at, in hammers: 2 for a
// Flower back (owner, 3 Oct 2026: "keep the cost of those 2 hammer validity 10
// days"), 5 for each of the first eight.
func seededCardCost(name string) int64 {
	if strings.HasPrefix(name, "Flower ") {
		return 2
	}
	return 5
}

// cardCatalogue is GET /api/card-backgrounds as this token (or, with "", a
// signed-out client) reads it.
func cardCatalogue(t *testing.T, baseURL, token string) []db.CardBackground {
	t.Helper()
	status, raw := shelfGet(t, baseURL, "/api/card-backgrounds", token)
	if status != http.StatusOK || !strings.HasPrefix(string(raw), `{"cardBackgrounds":[`) {
		t.Fatalf("GET /api/card-backgrounds: %d %s", status, raw)
	}
	var body struct {
		CardBackgrounds []db.CardBackground `json:"cardBackgrounds"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatal(err)
	}
	return body.CardBackgrounds
}

// cardNamed is the catalogue row of that name, failing the test without one.
func cardNamed(t *testing.T, shelf []db.CardBackground, name string) db.CardBackground {
	t.Helper()
	for _, cb := range shelf {
		if cb.Name == name {
			return cb
		}
	}
	t.Fatalf("the catalogue has no %s", name)
	return db.CardBackground{}
}

// seatCardBack reads one room:state the way a client does: the seat of
// userID, whether it carries the cardBackground key at all, and its value.
func seatCardBack(t *testing.T, raw json.RawMessage, userID string) (present bool, back *game.CardBackground) {
	t.Helper()
	var view struct {
		Seats []map[string]json.RawMessage `json:"seats"`
	}
	if err := json.Unmarshal(raw, &view); err != nil {
		t.Fatal(err)
	}
	for _, seat := range view.Seats {
		var id string
		if json.Unmarshal(seat["userId"], &id) != nil || id != userID {
			continue
		}
		value, ok := seat["cardBackground"]
		if !ok {
			return false, nil
		}
		if err := json.Unmarshal(value, &back); err != nil {
			t.Fatal(err)
		}
		return true, back
	}
	t.Fatalf("room:state has no seat for %s: %s", userID, raw)
	return false, nil
}

// handOf is a room:state's hand number, table state and pot.
func handOf(t *testing.T, raw json.RawMessage) (handNo int, state string, pot int64) {
	t.Helper()
	var view struct {
		HandNo int    `json:"handNo"`
		State  string `json:"state"`
		Pot    int64  `json:"pot"`
	}
	if err := json.Unmarshal(raw, &view); err != nil {
		t.Fatal(err)
	}
	return view.HandNo, view.State, view.Pot
}

// waitSeatCardBack waits on c, from mark, for a room:state whose seat of
// userID carries the card back with that id — or, with 0, carries none (the
// key absent) — and returns it.
func waitSeatCardBack(t *testing.T, c *testclient.Client, mark int, userID string, id int64) json.RawMessage {
	t.Helper()
	raw, err := c.WaitFrom(mark, socket.EvRoomState, func(raw json.RawMessage) bool {
		present, back := seatCardBack(t, raw, userID)
		if id == 0 {
			return !present
		}
		return present && back != nil && back.ID == id
	}, 4*time.Second)
	if err != nil {
		t.Fatalf("no room:state with %s's card back %d: %v", userID, id, err)
	}
	return raw
}

// sameBack reports whether a seat's or an account's card back is the
// catalogue row's: its id, its location, IMAGE and its crop.
func sameBack(got *game.CardBackground, want db.CardBackground) bool {
	return got != nil && got.ID == want.ID && got.URL == want.URL && got.Format == "IMAGE" &&
		got.Crop != nil && want.Crop != nil && *got.Crop == *want.Crop
}

// accountCardBack is the cardBackground of a REST answer's user.
func accountCardBack(t *testing.T, res restAnswer) (present bool, back *game.CardBackground) {
	t.Helper()
	user, _ := res.body["user"].(map[string]any)
	value, ok := user["cardBackground"]
	if !ok {
		return false, nil
	}
	raw, _ := json.Marshal(value)
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	return true, back
}

// The catalogue is public and per viewer: signed out, every one of the seed's
// thirteen reads as nobody's, at its seeded price, crop and all; a buyer's
// token marks theirs owned until its term; a stranger's marks nothing; a bad
// token is ignored, not refused. Off the shelf (is_listed), a card back is
// listed to its owner alone and sold to nobody, though its owner's second tap
// is still a success.
func TestTheCardBackCatalogueIsServedSignedOutToAStrangerAndToItsOwner(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	shelf := cardCatalogue(t, ts.URL, "")
	if len(shelf) != seededCardBacks {
		t.Fatalf("the catalogue lists %d card backs, want the seed's %d", len(shelf), seededCardBacks)
	}
	for _, cb := range shelf {
		if cb.Owned || cb.ExpiresAt != 0 || cb.Currency != db.PictureCurrencyHammer || cb.Cost != seededCardCost(cb.Name) ||
			cb.DurationDays != 10 || cb.AssetFormat != "IMAGE" || cb.Crop == nil || !strings.HasPrefix(cb.URL, seededAssets+"cards/") {
			t.Errorf("signed out, %+v", cb)
		}
	}
	brutal := cardNamed(t, shelf, "Brutal Demon")
	if brutal.URL != brutalDemon || brutal.SortOrder != 10 || *brutal.Crop != (game.CardCrop{X: 0.2035, Y: 0.0805, W: 0.6007, H: 0.841}) {
		t.Fatalf("Brutal Demon = %+v", brutal)
	}

	ownerToken, ownerID := login(t, ts.URL, "card-shelf-owner", "Card Owner")
	strangerToken, _ := login(t, ts.URL, "card-shelf-stranger", "Card Stranger")
	status, raw := postRaw(t, ts.URL, ownerToken, "/api/card-backgrounds/buy", fmt.Sprintf(`{"cardBackgroundId":%d}`, brutal.ID))
	var bought map[string]json.RawMessage
	if err := json.Unmarshal(raw, &bought); status != http.StatusOK || err != nil {
		t.Fatalf("a buy: %d %s %v", status, raw, err)
	}
	var keys []string
	for k := range bought {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if strings.Join(keys, ",") != "cardBackground,charged,spent,user" || string(bought["charged"]) != "true" || string(bought["spent"]) != "5" {
		t.Fatalf("the buy's answer: %s", raw)
	}
	if mine := cardNamed(t, cardCatalogue(t, ts.URL, ownerToken), "Brutal Demon"); !mine.Owned || mine.ExpiresAt <= time.Now().UnixMilli() {
		t.Fatalf("the owner's shelf: %+v", mine)
	}
	if theirs := cardNamed(t, cardCatalogue(t, ts.URL, strangerToken), "Brutal Demon"); theirs.Owned {
		t.Fatalf("a stranger's shelf marks the owner's card back owned: %+v", theirs)
	}

	if _, err := database.Pool.Exec(context.Background(), `UPDATE cards_background SET is_listed = FALSE WHERE id = $1`, brutal.ID); err != nil {
		t.Fatal(err)
	}
	for who, token := range map[string]string{"signed out": "", "a stranger": strangerToken, "a bad token": "not-a-token"} {
		listed := cardCatalogue(t, ts.URL, token)
		if len(listed) != seededCardBacks-1 {
			t.Errorf("%s, the unlisted catalogue lists %d, want %d", who, len(listed), seededCardBacks-1)
		}
		for _, cb := range listed {
			if cb.ID == brutal.ID {
				t.Errorf("%s is shown the unlisted Brutal Demon", who)
			}
		}
	}
	if mine := cardCatalogue(t, ts.URL, ownerToken); len(mine) != seededCardBacks || !cardNamed(t, mine, "Brutal Demon").Owned {
		t.Errorf("the owner's shelf after unlisting: %d rows, want %d", len(mine), seededCardBacks)
	}
	res := postJSON(ts.URL, strangerToken, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": brutal.ID})
	if res.status != http.StatusBadRequest || res.body["error"] != auth.CodePictureRetired || res.body["message"] != "That card back is no longer available." {
		t.Errorf("a stranger buying an unlisted card back: %d %v", res.status, res.body)
	}
	res = postJSON(ts.URL, ownerToken, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": brutal.ID})
	if res.status != http.StatusOK || res.body["charged"] != false {
		t.Errorf("the owner's second tap: %d %v", res.status, res.body)
	}
	_ = ownerID
}

// A seated player buys a seeded card back with five hammers — no chip moves,
// no ledger row, the seat's stack untouched — and chooses it in the middle of
// a hand: the hand goes on exactly as it was, and EVERY viewer's room:state
// carries it on that player's seat (their own included), the other seat
// carrying none (the key absent). Taken off, it leaves every view; chosen
// again and lapsed, the sweep at /api/auth/me takes it off the seat. Every
// refusal is the pictures' code with the card back's words.
func TestACardBackChosenMidHandIsOnThatPlayersSeatForEveryViewer(t *testing.T) {
	// A turn clock long enough that the first hand is still being played
	// when the card back is chosen.
	a, database := newApp(t, func(cfg *config.Config) { cfg.Game.TurnTimeout = 60 * time.Second })
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	welcome := a.cfg.Game.WelcomeChips
	shelf := cardCatalogue(t, ts.URL, "")
	brutal, dragon, hell := cardNamed(t, shelf, "Brutal Demon"), cardNamed(t, shelf, "Dragon Hunter"), cardNamed(t, shelf, "Demon Hell")

	buyerToken, buyerID := login(t, ts.URL, "card-seated-buyer", "Card Buyer")
	otherToken, otherID := login(t, ts.URL, "card-seated-other", "Card Other")
	c := dial(t, ts.URL, buyerToken)
	joinAck := mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	var joined struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(joinAck.Raw, &joined); err != nil || joined.Code == "" {
		t.Fatalf("the quick-join ack carries no code: %s %v", joinAck.Raw, err)
	}
	c2 := dial(t, ts.URL, otherToken)
	mustOK(t, c2, socket.EvRoomJoinCode, map[string]any{"code": joined.Code})
	table := game.AsTable(a.Rooms().GetTableForPlayer(buyerID))
	if table == nil {
		t.Fatal("the buyer is not at a Teen Patti table")
	}
	live, err := c2.Wait(socket.EvRoomState, func(raw json.RawMessage) bool {
		_, state, _ := handOf(t, raw)
		return state == string(game.TableBetting)
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("no hand began: %v", err)
	}
	handNo, _, pot := handOf(t, live)
	if present, _ := seatCardBack(t, live, buyerID); present {
		t.Fatalf("a seat whose player has chosen nothing carries a card back: %s", live)
	}
	startHammers, _, _ := hammerBooks(t, database, buyerID)
	seatChips := seatOf(t, a, buyerID)

	// Bought at the table with hammers.
	res := postJSON(ts.URL, buyerToken, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": brutal.ID})
	if res.err != nil || res.status != http.StatusOK || res.body["charged"] != true || res.body["spent"] != float64(5) {
		t.Fatalf("a seated hammer buy: %d %v %v", res.status, res.body, res.err)
	}
	if hammers, spends, _ := hammerBooks(t, database, buyerID); hammers != startHammers-5 || spends != 0 {
		t.Errorf("after the buy: hammers %d (from %d), hammer_spends %d", hammers, startHammers, spends)
	}
	if wallet, ledger := walletAndLedger(t, database, buyerID); wallet != welcome || ledger != welcome || seatOf(t, a, buyerID) != seatChips {
		t.Errorf("chips moved: wallet %d, ledger %d, seat %d (was %d)", wallet, ledger, seatOf(t, a, buyerID), seatChips)
	}
	if present, back := accountCardBack(t, res); !present || back != nil {
		t.Errorf("buying put the card back on: %v %+v", present, back)
	}

	// Chosen mid-hand: on the account, and on the seat for both viewers.
	markA, markB := c.Mark(), c2.Mark()
	res = postJSON(ts.URL, buyerToken, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": brutal.ID})
	if res.err != nil || res.status != http.StatusOK {
		t.Fatalf("choosing at the table: %d %v %v", res.status, res.body, res.err)
	}
	if present, back := accountCardBack(t, res); !present || !sameBack(back, brutal) {
		t.Fatalf("the account after choosing: %+v", back)
	}
	// A rental: the seat carries its term, the ownership row's expires_at.
	var ends int64
	if err := database.Pool.QueryRow(ctx, `SELECT expires_at FROM user_cards_background WHERE user_id = $1 AND card_background_id = $2`,
		buyerID, brutal.ID).Scan(&ends); err != nil || ends <= time.Now().UnixMilli() {
		t.Fatalf("the rental's term: %d %v", ends, err)
	}
	for who, client := range map[string]*testclient.Client{"the buyer": c, "the other player": c2} {
		mark := markA
		if client == c2 {
			mark = markB
		}
		raw := waitSeatCardBack(t, client, mark, buyerID, brutal.ID)
		_, back := seatCardBack(t, raw, buyerID)
		if !sameBack(back, brutal) {
			t.Errorf("%s sees %+v on the buyer's seat", who, back)
		}
		if present, _ := seatCardBack(t, raw, otherID); present {
			t.Errorf("%s sees a card back on the other seat, which has none: %s", who, raw)
		}
		if gotHand, state, gotPot := handOf(t, raw); gotHand != handNo || state != string(game.TableBetting) || gotPot != pot {
			t.Errorf("%s: choosing a card back touched the hand: hand %d %s pot %d, was hand %d pot %d", who, gotHand, state, gotPot, handNo, pot)
		}
		if !strings.Contains(string(raw), `"cardBackground":{"id":`+fmt.Sprint(brutal.ID)+`,"url":"`+brutalDemon+`","assetFormat":"IMAGE","crop":{"x":0.2035,"y":0.0805,"w":0.6007,"h":0.841},"expiresAt":`+fmt.Sprint(ends)+`}`) {
			t.Errorf("%s's room:state on the wire: %s", who, raw)
		}
	}
	for _, viewer := range []string{buyerID, otherID} {
		view, err := table.SerializeFor(viewer)
		if err != nil {
			t.Fatal(err)
		}
		for _, seat := range view.Seats {
			switch seat.UserID {
			case buyerID:
				if !sameBack(seat.CardBackground, brutal) {
					t.Errorf("%s's view of the buyer's seat: %+v", viewer, seat.CardBackground)
				}
			case otherID:
				if seat.CardBackground != nil {
					t.Errorf("%s's view of the other seat: %+v", viewer, seat.CardBackground)
				}
			}
		}
	}

	// Refusals, each the pictures' code in the card back's words.
	refused := func(name, token, path string, body any, status int, code, message string) {
		t.Helper()
		got := postJSON(ts.URL, token, path, body)
		if got.err != nil || got.status != status || got.body["error"] != code || (message != "" && got.body["message"] != message) {
			t.Errorf("%s: %d %v %v, want %d %s %q", name, got.status, got.body, got.err, status, code, message)
		}
	}
	refused("an unbought card back", buyerToken, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": dragon.ID},
		http.StatusForbidden, auth.CodePictureLocked, "Unlock that card back before you can use it.")
	refused("an unknown id", buyerToken, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": 987654},
		http.StatusBadRequest, auth.CodeUnknownCardBackground, "That card back is not available.")
	refused("an id that is not one", buyerToken, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": "royal"},
		http.StatusBadRequest, auth.CodeUnknownCardBackground, "That card back is not available.")
	refused("a buy naming nothing", buyerToken, "/api/card-backgrounds/buy", map[string]any{},
		http.StatusBadRequest, auth.CodeUnknownCardBackground, "That card back is not available.")
	refused("signed out", "", "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": brutal.ID},
		http.StatusUnauthorized, auth.CodeMissingToken, "")
	if _, err := database.Pool.Exec(ctx, `UPDATE users SET hammer = 4 WHERE id = $1`, buyerID); err != nil {
		t.Fatal(err)
	}
	refused("four hammers for a five-hammer card back", buyerToken, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": dragon.ID},
		http.StatusConflict, auth.CodePictureChips, "You need 5 hammers to unlock this card back.")
	var coin, free int64
	if err := database.Pool.QueryRow(ctx, `INSERT INTO cards_background (name, asset_url, crop_x, crop_y, crop_w, crop_h, currency, type, cost, duration_days, sort_order, created_at, updated_at)
	     VALUES ('Gold Leaf', $1, 0.2, 0.1, 0.6, 0.84, 'COIN', 'PREMIUM', 1000, 7, 900, 0, 0) RETURNING id`, seededAssets+"cards/Gold%20Leaf.jpg").Scan(&coin); err != nil {
		t.Fatal(err)
	}
	if err := database.Pool.QueryRow(ctx, `INSERT INTO cards_background (name, asset_url, currency, type, cost, sort_order, created_at, updated_at)
	     VALUES ('Plain', $1, 'COIN', 'FREE', 0, 910, 0, 0) RETURNING id`, seededAssets+"cards/Plain.jpg").Scan(&free); err != nil {
		t.Fatal(err)
	}
	refused("a chip-priced card back at a table", buyerToken, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": coin},
		http.StatusConflict, auth.CodeSeated, "You can only buy a chip-priced card back in the lobby.")
	refused("a free card back", buyerToken, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": free},
		http.StatusBadRequest, auth.CodePictureFree, "That card back is free — just choose it.")
	if _, err := database.Pool.Exec(ctx, `UPDATE cards_background SET is_active = FALSE WHERE id = $1`, hell.ID); err != nil {
		t.Fatal(err)
	}
	refused("a retired card back's buy", buyerToken, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": hell.ID},
		http.StatusBadRequest, auth.CodePictureRetired, "That card back is no longer available.")
	refused("a retired card back's use", buyerToken, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": hell.ID},
		http.StatusBadRequest, auth.CodePictureRetired, "That card back is no longer available.")
	if wallet, ledger := walletAndLedger(t, database, buyerID); wallet != welcome || ledger != welcome {
		t.Errorf("a refusal moved chips: wallet %d, ledger %d", wallet, ledger)
	}
	if present, back := seatCardBack(t, mustState(t, table, otherID), buyerID); !present || !sameBack(back, brutal) {
		t.Errorf("a refusal changed the seat's card back: %+v", back)
	}

	// Taken off (null): the default back, on the account and every view.
	markA, markB = c.Mark(), c2.Mark()
	res = postJSON(ts.URL, buyerToken, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": nil})
	if present, back := accountCardBack(t, res); res.status != http.StatusOK || !present || back != nil {
		t.Fatalf("taking it off: %d %v", res.status, res.body)
	}
	waitSeatCardBack(t, c, markA, buyerID, 0)
	waitSeatCardBack(t, c2, markB, buyerID, 0)

	// Chosen again, then lapsed: the account reads the default back at once,
	// and the sweep at /api/auth/me takes it off the seat for everybody.
	if res := postJSON(ts.URL, buyerToken, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": fmt.Sprint(brutal.ID)}); res.status != http.StatusOK {
		t.Fatalf("choosing it again, by its text: %d %v", res.status, res.body)
	}
	waitSeatCardBack(t, c2, markB, buyerID, brutal.ID)
	if _, err := database.Pool.Exec(ctx, `UPDATE user_cards_background SET expires_at = 1 WHERE user_id = $1`, buyerID); err != nil {
		t.Fatal(err)
	}
	markB = c2.Mark()
	status, raw := shelfGet(t, ts.URL, "/api/auth/me", buyerToken)
	var me struct {
		User map[string]json.RawMessage `json:"user"`
	}
	if err := json.Unmarshal(raw, &me); status != http.StatusOK || err != nil || string(me.User["cardBackground"]) != "null" {
		t.Fatalf("/api/auth/me after the rental lapsed: %d %s", status, raw)
	}
	waitSeatCardBack(t, c2, markB, buyerID, 0)
	if n := countOf(t, database, `SELECT count(*) FROM user_cards_background_choice WHERE user_id = $1`, buyerID); n != 0 {
		t.Errorf("the sweep left the lapsed choice: %d row(s)", n)
	}

	mustOK(t, c, socket.EvRoomLeave, map[string]any{})
	mustOK(t, c2, socket.EvRoomLeave, map[string]any{})
}

// mustState is the room:state viewer would be sent now.
func mustState(t *testing.T, table *game.Table, viewer string) json.RawMessage {
	t.Helper()
	view, err := table.SerializeFor(viewer)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// countOf is one count(*) over the test's schema.
func countOf(t *testing.T, database *db.DB, sql string, args ...any) int64 {
	t.Helper()
	var n int64
	if err := database.Pool.QueryRow(context.Background(), sql, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// A card back chosen in the lobby is on the account, so it is on the seat the
// player sits down in — the account is what every seat is built from — and
// the player already there sees it on theirs at once. Deleting the account
// takes it off with the rest.
func TestACardBackChosenInTheLobbyIsOnTheSeatThePlayerSitsDownIn(t *testing.T) {
	a, database := newApp(t, func(cfg *config.Config) { cfg.Game.TurnTimeout = 60 * time.Second })
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	owl := cardNamed(t, cardCatalogue(t, ts.URL, ""), "Royal Owl with Fox")

	hostToken, hostID := login(t, ts.URL, "card-lobby-host", "Card Host")
	chooserToken, chooserID := login(t, ts.URL, "card-lobby-chooser", "Card Chooser")
	if res := postJSON(ts.URL, chooserToken, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": owl.ID}); res.status != http.StatusOK {
		t.Fatalf("a lobby buy: %d %v", res.status, res.body)
	}
	if res := postJSON(ts.URL, chooserToken, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": owl.ID}); res.status != http.StatusOK {
		t.Fatalf("a lobby choice: %d %v", res.status, res.body)
	}

	host := dial(t, ts.URL, hostToken)
	ack := mustOK(t, host, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	var joined struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(ack.Raw, &joined); err != nil {
		t.Fatal(err)
	}
	mark := host.Mark()
	chooser := dial(t, ts.URL, chooserToken)
	mustOK(t, chooser, socket.EvRoomJoinCode, map[string]any{"code": joined.Code})
	raw, err := chooser.Wait(socket.EvRoomJoined, nil, 4*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if present, back := seatCardBack(t, raw, chooserID); !present || !sameBack(back, owl) {
		t.Fatalf("the chooser's own room:joined: %+v", back)
	}
	if present, _ := seatCardBack(t, raw, hostID); present {
		t.Errorf("the host's seat carries a card back: %s", raw)
	}
	raw = waitSeatCardBack(t, host, mark, chooserID, owl.ID)
	if _, back := seatCardBack(t, raw, chooserID); !strings.Contains(back.URL, "/cards/Royal%20Owl%20with%20fox.jpg") {
		t.Errorf("the host sees %+v", back)
	}

	mustOK(t, chooser, socket.EvRoomLeave, map[string]any{})
	mustOK(t, host, socket.EvRoomLeave, map[string]any{})
	status, body := deleteAccount(t, ts.URL, chooserToken)
	if status != http.StatusOK {
		t.Fatalf("DELETE /api/account: %d %s", status, body)
	}
	if n := countOf(t, database, `SELECT count(*) FROM user_cards_background_choice WHERE user_id = $1`, chooserID); n != 0 {
		t.Errorf("the deleted account still has a card back chosen")
	}
}

// deleteAccount is DELETE /api/account as this token.
func deleteAccount(t *testing.T, baseURL, token string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodDelete, baseURL+"/api/account", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res.StatusCode, body
}

// The card-back routes are counted under their PATTERNS (the metrics label
// rule): three fixed paths, never an id.
func TestTheCardBackRoutesAreLabelledByPattern(t *testing.T) {
	a, _ := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	token, _ := login(t, ts.URL, "card-labels-device", "Card Labels")
	brutal := cardNamed(t, cardCatalogue(t, ts.URL, token), "Brutal Demon")
	postJSON(ts.URL, token, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": brutal.ID})
	postJSON(ts.URL, token, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": brutal.ID})

	res, body := get(t, a.Handler(), http.MethodGet, "/metrics", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+metricsToken) })
	if res.StatusCode != http.StatusOK {
		t.Fatalf("/metrics: %d", res.StatusCode)
	}
	text := string(body)
	for _, want := range []string{
		`method="GET",route="/api/card-backgrounds",service="king-teenpatti",status_code="200"`,
		`method="POST",route="/api/card-backgrounds/buy",service="king-teenpatti",status_code="200"`,
		`method="POST",route="/api/card-backgrounds/use",service="king-teenpatti",status_code="200"`,
	} {
		if !strings.Contains(text, want) {
			t.Errorf("the exposition lacks %q", want)
		}
	}
	if strings.Contains(text, fmt.Sprintf("/api/card-backgrounds/%d", brutal.ID)) {
		t.Error("a card back's id reached a label")
	}
}

// A seeded card back's location — the owner's file name, spaces written %20 —
// is one the sign route signs, and only as the catalogue stores it: the raw
// spaces, and the bundled default no row names, are left out. The signed URL
// is the location with the signature after it, the key encoded once.
func TestTheSignRouteSignsASeededCardBacksLocation(t *testing.T) {
	a, _ := newApp(t, withR2)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	token, _ := login(t, ts.URL, "card-sign-device", "Card Signer")
	asked := []string{
		brutalDemon,
		seededAssets + "cards/Royal%20Owl%20with%20fox.jpg",
		seededAssets + "cards/Brutal Demon.jpg",     // raw spaces: not a location
		seededAssets + "cards/Royal%20Fox.jpg",      // the bundled default: no row names it
		seededAssets + "cards/Brutal%2520Demon.jpg", // escaped twice
	}
	body, _ := json.Marshal(auth.SignAssetsRequest{URLs: asked})
	status, raw := postRaw(t, ts.URL, token, "/api/assets/sign", string(body))
	var answer auth.SignAssetsResponse
	if err := json.Unmarshal(raw, &answer); status != http.StatusOK || err != nil {
		t.Fatalf("POST /api/assets/sign: %d %s %v", status, raw, err)
	}
	if len(answer.URLs) != 2 {
		t.Fatalf("signed %d URLs, want the two seeded card backs: %s", len(answer.URLs), raw)
	}
	for _, location := range asked[:2] {
		signed := answer.URLs[location]
		if !strings.HasPrefix(signed, location+"?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIDTEST%2F") {
			t.Errorf("%s came back as %q", location, signed)
			continue
		}
		u, err := url.Parse(signed)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(u.EscapedPath(), "/king-teenpatti/cards/") || strings.Contains(u.EscapedPath(), " ") ||
			strings.Contains(u.EscapedPath(), "%25") || u.Query().Get("X-Amz-Signature") == "" {
			t.Errorf("%s signed as %s", location, signed)
		}
	}
	if !strings.Contains(answer.URLs[brutalDemon], "/king-teenpatti/cards/Brutal%20Demon.jpg?") {
		t.Errorf("Brutal Demon's signed path: %s", answer.URLs[brutalDemon])
	}
}

// With the real keys in the environment, a seeded card back's signed URL opens
// the owner's real JPEG in the real bucket. Skipped unless R2_ACCOUNT_ID and
// the rest are set (set -a; . ./.env; set +a).
func TestASignedCardBackOpensTheOwnersRealJPEG(t *testing.T) {
	if os.Getenv("R2_ACCOUNT_ID") == "" || os.Getenv("R2_SECRET_ACCESS_KEY") == "" {
		t.Skip("set the R2_* keys to open a real file")
	}
	a, _ := newApp(t, func(cfg *config.Config) {
		cfg.Assets = config.AssetsConfig{R2AccountID: os.Getenv("R2_ACCOUNT_ID"), R2AccessKeyID: os.Getenv("R2_ACCESS_KEY_ID"),
			R2SecretAccessKey: os.Getenv("R2_SECRET_ACCESS_KEY"), R2Bucket: os.Getenv("R2_BUCKET_NAME")}
	})
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	token, _ := login(t, ts.URL, "card-live-device", "Card Live")
	shelf := cardCatalogue(t, ts.URL, token)
	var asked []string
	for _, cb := range shelf {
		asked = append(asked, cb.URL)
	}
	body, _ := json.Marshal(auth.SignAssetsRequest{URLs: asked})
	status, raw := postRaw(t, ts.URL, token, "/api/assets/sign", string(body))
	var answer auth.SignAssetsResponse
	if err := json.Unmarshal(raw, &answer); status != http.StatusOK || err != nil || len(answer.URLs) != len(shelf) {
		t.Fatalf("signing the card backs: %d, %d signed of %d, %v", status, len(answer.URLs), len(shelf), err)
	}
	for _, cb := range shelf {
		res, err := http.Get(answer.URLs[cb.URL])
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != http.StatusOK || len(data) < 3 || data[0] != 0xFF || data[1] != 0xD8 || data[2] != 0xFF {
			t.Errorf("%s: GET of the signed URL: %d, %d bytes, not a JPEG", cb.Name, res.StatusCode, len(data))
			continue
		}
		t.Logf("%s: %d bytes of JPEG", cb.Name, len(data))
	}
	// Unsigned, the location is refused: the bucket is private.
	res, err := http.Get(brutalDemon)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode == http.StatusOK {
		t.Error("the bucket answers an unsigned GET of a card back")
	}
}
