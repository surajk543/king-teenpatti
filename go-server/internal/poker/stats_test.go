package poker

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Player stats v2 (owner, 27 Sep 2026): a poker room's hands count in the
// POKER bucket — played, won, lost, left and the winnings — with no hand held
// (poker hands are not ranked on the Teen Patti ladder) and no variation.

func TestAPokerHandCountsInThePokerBucketWithNoHandHeld(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.deal()
	h.mustAct("a", ActionRaise, 600)
	h.mustAct("b", ActionFold)
	got := map[string]game.HandStats{}
	for _, s := range h.stats.all() {
		got[s.UserID] = s
	}
	if len(got) != 2 {
		t.Fatalf("the hand end counted %+v, want both players", h.stats.all())
	}
	for id, s := range got {
		if s.Bucket != game.StatsPoker || s.HasHeld || s.Variation != "" {
			t.Errorf("%s counted %+v: poker, no hand held, no variation", id, s)
		}
	}
	if a := got["a"]; a.Won != 1 || a.Played != 1 || a.Lost != 0 || a.Winnings <= 0 {
		t.Errorf("the winner counted %+v", a)
	}
	if b := got["b"]; b.Lost != 1 || b.Won != 0 || b.Winnings != 0 {
		t.Errorf("the folder counted %+v", b)
	}
}

func TestAPokerDepartureIsCountedAtItsCheckpointOnce(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.mustAct("a", ActionRaise, 1_000)
	if _, err := h.table.RemovePlayer("b", game.LeaveReasonLeft); err != nil {
		t.Fatal(err)
	}
	left := h.stats.all()
	if len(left) != 1 || left[0] != (game.HandStats{UserID: "b", Bucket: game.StatsPoker, Left: 1}) {
		t.Fatalf("the departure counted %+v, want b left (the blind is not a hand played)", left)
	}
	h.mustAct("c", ActionFold)
	for _, s := range h.stats.all()[1:] {
		if s.UserID == "b" {
			t.Fatalf("the departed player was counted again at the hand end: %+v", s)
		}
	}
}

// A departure whose write landed unheard (duplicate_action) moves the seat's
// books on — the money moved once — but its counters were never this write's
// to count.
func TestAPokerDepartureReplayedIsNotCounted(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.mustAct("a", ActionRaise, 1_000)
	h.books.mu.Lock()
	h.books.duplicate = true
	h.books.mu.Unlock()
	if _, err := h.table.RemovePlayer("b", game.LeaveReasonLeft); err != nil {
		t.Fatal(err)
	}
	if got := h.stats.all(); len(got) != 0 {
		t.Fatalf("a replayed departure counted %+v", got)
	}
}
