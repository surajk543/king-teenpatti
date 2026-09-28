package poker

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// A poker room counts down before a deal exactly as a Teen Patti table does
// (game/countdown.go): the countdown alone for a first deal, the celebration
// and then the countdown after a hand, and startsInMs on its snapshot.

func (h *harness) view(id string) *TableView {
	h.t.Helper()
	v, err := h.table.SerializeFor(id)
	if err != nil {
		h.t.Fatal(err)
	}
	return v
}

func TestAPokerRoomCountsDownBeforeEveryDeal(t *testing.T) {
	h := newHarness(t, TexasHoldem) // NextHandDelay 4 s
	h.seat("a", 5000)

	raw, _ := json.Marshal(h.view("a"))
	var keys map[string]json.RawMessage
	_ = json.Unmarshal(raw, &keys)
	if _, ok := keys["startsInMs"]; ok {
		t.Fatal("waiting: startsInMs must be absent")
	}

	h.seat("b", 5000)
	v := h.view("a")
	if v.State != game.TableStarting || v.StartsInMs == nil || *v.StartsInMs != game.StartCountdown.Milliseconds() {
		t.Fatalf("a first deal: state %s, startsInMs %v, want 3000", v.State, v.StartsInMs)
	}
	h.clock.Advance(game.StartCountdown - time.Millisecond)
	if err := h.act("a", ActionCheck); !isCode(err, game.CodeNoHand) {
		t.Fatalf("a move before the deal: %v, want no_hand", err)
	}
	h.clock.Advance(time.Millisecond)
	if h.handID() == "" {
		t.Fatal("dealt at the end of the countdown")
	}

	// A hand's end: the celebration, then the countdown, to nextHandAt.
	h.mustAct(h.turn(), ActionFold)
	if h.handID() != "" {
		t.Fatal("the hand is over")
	}
	v = h.view("a")
	if v.StartsInMs == nil || *v.StartsInMs != h.cfg.NextHandDelay.Milliseconds() {
		t.Fatalf("after a hand: startsInMs %v, want the whole window", v.StartsInMs)
	}
	end := h.clock.Now()

	// A departure cancels it; a return inside the window keeps the hold.
	h.clock.Advance(500 * time.Millisecond)
	if _, err := h.table.RemovePlayer("b", game.LeaveReasonLeft); err != nil {
		t.Fatal(err)
	}
	if v := h.view("a"); v.State != game.TableWaiting || v.StartsAt != nil || v.StartsInMs != nil {
		t.Fatalf("cancelled: %s %v %v", v.State, v.StartsAt, v.StartsInMs)
	}
	h.seat("c", 5000)
	v = h.view("a")
	if v.StartsAt == nil || *v.StartsAt != game.Millis(end.Add(h.cfg.NextHandDelay)) {
		t.Fatalf("held to the last hand's nextHandAt: %v", v.StartsAt)
	}
	h.clock.Advance(end.Add(h.cfg.NextHandDelay).Sub(h.clock.Now()))
	if h.handID() == "" {
		t.Fatal("dealt at the hold")
	}
}

func isCode(err error, code string) bool {
	var ge *game.GameError
	return errors.As(err, &ge) && ge.Code == code
}
