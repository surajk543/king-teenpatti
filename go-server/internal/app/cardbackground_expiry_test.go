package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// The owner's rule on the real wiring (3 Oct 2026: "when validity of premium
// card expires, it restores default card"): a seated player puts on a rented
// card back whose term has a moment left to run, and at that moment it leaves
// every viewer's room:state — the server alone, with no request from anybody
// (the owner's app may be closed) — while the hand plays on untouched. Until
// then the account and the seat both say when it runs out (expiresAt), and the
// choice row is left for the sweeps: the table did not need one.
func TestARentedCardBackLeavesEveryViewersTableAtItsMomentWithNoRequest(t *testing.T) {
	a, database := newApp(t, func(cfg *config.Config) { cfg.Game.TurnTimeout = 60 * time.Second })
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	brutal := cardNamed(t, cardCatalogue(t, ts.URL, ""), "Brutal Demon")

	renterToken, renterID := login(t, ts.URL, "card-expiry-renter", "Card Renter")
	otherToken, otherID := login(t, ts.URL, "card-expiry-other", "Card Other")
	c := dial(t, ts.URL, renterToken)
	ack := mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	var joined struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(ack.Raw, &joined); err != nil || joined.Code == "" {
		t.Fatalf("the quick-join ack carries no code: %s %v", ack.Raw, err)
	}
	c2 := dial(t, ts.URL, otherToken)
	mustOK(t, c2, socket.EvRoomJoinCode, map[string]any{"code": joined.Code})
	live, err := c2.Wait(socket.EvRoomState, func(raw json.RawMessage) bool {
		_, state, _ := handOf(t, raw)
		return state == string(game.TableBetting)
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("no hand began: %v", err)
	}
	handNo, _, pot := handOf(t, live)

	// Rented at the table for five hammers — and, so that the test need not
	// wait ten days, its term then cut to a couple of seconds from now.
	if res := postJSON(ts.URL, renterToken, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": brutal.ID}); res.status != http.StatusOK || res.body["charged"] != true {
		t.Fatalf("a seated hammer buy: %d %v %v", res.status, res.body, res.err)
	}
	ends := time.Now().UnixMilli() + 2_500
	if _, err := database.Pool.Exec(ctx, `UPDATE user_cards_background SET expires_at = $3 WHERE user_id = $1 AND card_background_id = $2`,
		renterID, brutal.ID, ends); err != nil {
		t.Fatal(err)
	}

	// Put on: the account says when it runs out, and so does the seat, for
	// every viewer.
	markA, markB := c.Mark(), c2.Mark()
	res := postJSON(ts.URL, renterToken, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": brutal.ID})
	if res.status != http.StatusOK {
		t.Fatalf("choosing at the table: %d %v %v", res.status, res.body, res.err)
	}
	if present, back := accountCardBack(t, res); !present || !sameBack(back, brutal) || back.ExpiresAt != ends {
		t.Fatalf("the account after choosing: %+v, want the Brutal Demon until %d", back, ends)
	}
	clients := map[string]*testclient.Client{"the renter": c, "the other player": c2}
	marks := map[*testclient.Client]int{c: markA, c2: markB}
	for who, client := range clients {
		raw := waitSeatCardBack(t, client, marks[client], renterID, brutal.ID)
		if _, back := seatCardBack(t, raw, renterID); back.ExpiresAt != ends || !strings.Contains(string(raw), fmt.Sprintf(`"expiresAt":%d}`, ends)) {
			t.Fatalf("%s's room:state carries %+v on the renter's seat, want the term %d: %s", who, back, ends, raw)
		}
		marks[client] = client.Mark()
	}

	// Nobody asks for anything now. At the moment, every viewer is sent the
	// table without it — and the hand as it was.
	for who, client := range clients {
		raw, err := client.WaitFrom(marks[client], socket.EvRoomState, func(raw json.RawMessage) bool {
			present, _ := seatCardBack(t, raw, renterID)
			return !present
		}, time.Until(time.UnixMilli(ends))+6*time.Second)
		if err != nil {
			t.Fatalf("%s was never sent the table without the lapsed back: %v", who, err)
		}
		if seen := time.Now().UnixMilli(); seen < ends {
			t.Fatalf("%s was sent the default back %d ms before the term ended", who, ends-seen)
		}
		if gotHand, state, gotPot := handOf(t, raw); gotHand != handNo || state != string(game.TableBetting) || gotPot != pot {
			t.Errorf("%s: the back running out touched the hand: hand %d %s pot %d, was hand %d pot %d", who, gotHand, state, gotPot, handNo, pot)
		}
		if present, _ := seatCardBack(t, raw, otherID); present {
			t.Errorf("%s sees a card back on the other seat, which never had one: %s", who, raw)
		}
	}
	// The table let go of it alone: no sweep ran, so the choice row is still
	// there for the next one to tidy.
	if n := countOf(t, database, `SELECT count(*) FROM user_cards_background_choice WHERE user_id = $1`, renterID); n != 1 {
		t.Fatalf("the choice row: %d, want it untouched by the table", n)
	}
	// And the account reads the default back too, now that the term is over.
	status, raw := shelfGet(t, ts.URL, "/api/auth/me", renterToken)
	var me struct {
		User map[string]json.RawMessage `json:"user"`
	}
	if err := json.Unmarshal(raw, &me); status != http.StatusOK || err != nil || string(me.User["cardBackground"]) != "null" {
		t.Fatalf("/api/auth/me after the term ended: %d %s", status, raw)
	}

	mustOK(t, c, socket.EvRoomLeave, map[string]any{})
	mustOK(t, c2, socket.EvRoomLeave, map[string]any{})
}
