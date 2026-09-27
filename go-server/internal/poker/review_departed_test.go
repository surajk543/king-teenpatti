package poker

// The Teen Patti table's review of 27 Sep 2026, held to the poker rooms,
// which share its checkpoint rule and its Settler: a replayed checkpoint
// advances what is counted as written by exactly what landed, and a player
// who leaves still owed part of a live hand is marked owed until the settle
// has written it (game.Settler.OweDeparted).

import (
	"sync"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// A leave that landed in an earlier life of the hand, when the player had
// put in less than they hold in now: the replay's duplicate_action says what
// landed, the rest rides the settle's catch-up row, and the books balance.
// Counting the whole current stack as written left the difference unwritten
// while the winner was paid it.
func TestAReplayThatLandedLessThanTheStakeIsCaughtUpAtTheHandEnd(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.mustAct("a", ActionRaise, 1_000)
	h.mustAct("b", ActionCall)
	handID := h.handID()

	earlier := int64(-200) // what the earlier life's leave wrote: the blinds' worth
	h.books.mu.Lock()
	h.books.duplicate, h.books.landed = true, &earlier
	h.books.mu.Unlock()
	if _, err := h.table.RemovePlayer("b", game.LeaveReasonLeft); err != nil {
		t.Fatal(err)
	}
	h.books.mu.Lock()
	h.books.duplicate, h.books.landed = false, nil
	h.books.mu.Unlock()
	h.mustAct("c", ActionFold)

	if got := h.books.wallets["b"]; got != 9_000 {
		t.Fatalf("the leaver is banked at %d, want 9,000: the stake beyond what landed was not written", got)
	}
	if total := h.books.total(); total != 30_000 {
		t.Fatalf("the books hold %d, want 30,000", total)
	}
	h.books.caughtUp(t, handID, "b")
}

// A duplicate_action that does not say what landed is treated as refused:
// the stake is written again at the hand end — which can at worst charge it
// twice, and never creates a chip.
func TestABareDuplicateNeverCreatesChips(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.mustAct("a", ActionRaise, 1_000)
	h.mustAct("b", ActionCall)
	handID := h.handID()

	h.books.mu.Lock()
	h.books.duplicate, h.books.bare = true, true
	h.books.mu.Unlock()
	if _, err := h.table.RemovePlayer("b", game.LeaveReasonLeft); err != nil {
		t.Fatal(err)
	}
	h.books.mu.Lock()
	h.books.duplicate, h.books.bare = false, false
	h.books.mu.Unlock()
	h.mustAct("c", ActionFold)

	if total := h.books.total(); total > 30_000 {
		t.Fatalf("the books hold %d, more than the 30,000 they started with: a chip was created", total)
	}
	h.books.caughtUp(t, handID, "b")
}

// A leave that COMMITTED but whose acknowledgement was lost reads as refused:
// the settle's catch-up debits the stake a second time (the residual hazard
// DECISIONS.md names — a wallet short by a stake, never a chip created), the
// hand is counted for the leaver exactly once (by the catch-up, since the
// leave counted nothing), and the books read the leave and its catch-up as
// one resolution.
func TestALeaveWhoseReplyWasLostIsCaughtUpAndResolvedOnce(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.mustAct("a", ActionRaise, 1_000)
	h.mustAct("b", ActionCall)
	handID := h.handID()

	h.books.mu.Lock()
	h.books.lost = true
	h.books.mu.Unlock()
	if _, err := h.table.RemovePlayer("b", game.LeaveReasonLeft); err != nil {
		t.Fatal(err)
	}
	h.books.mu.Lock()
	h.books.lost = false
	h.books.mu.Unlock()
	for _, s := range h.stats.all() {
		if s.UserID == "b" {
			t.Fatalf("a leave whose answer was an error counted %+v", s)
		}
	}
	h.mustAct("c", ActionFold)

	if got := h.books.wallets["b"]; got != 8_000 {
		t.Fatalf("the leaver is banked at %d, want 8,000: the stake debited twice is the known residual", got)
	}
	if total := h.books.total(); total != 29_000 {
		t.Fatalf("the books hold %d, want 29,000: never a chip created", total)
	}
	var left, played int64
	for _, s := range h.stats.all() {
		if s.UserID == "b" {
			left += s.Left
			played += s.Played
		}
	}
	if left != 1 || played != 1 {
		t.Fatalf("the leaver counted left %d, played %d; want each exactly once", left, played)
	}
	h.books.caughtUp(t, handID, "b")
}

// A refused leave is owed from the moment the player is off the table to the
// settle that writes it — at once, or when its retry lands — and no longer.
func TestARefusedLeaveIsOwedUntilTheSettleHasWrittenIt(t *testing.T) {
	for _, settleRefused := range []bool{false, true} {
		name := "the settle lands"
		if settleRefused {
			name = "the settle is retried"
		}
		t.Run(name, func(t *testing.T) {
			var mu sync.Mutex
			owed := map[string]int{}
			h := newHarnessOwed(t, TexasHoldem, func(req game.SettleRequest, isOwed bool) {
				mu.Lock()
				defer mu.Unlock()
				for _, e := range req.Entries {
					if e.Delta == 0 {
						continue
					}
					if isOwed {
						owed[e.UserID]++
					} else {
						owed[e.UserID]--
					}
				}
			})
			of := func(id string) int {
				mu.Lock()
				defer mu.Unlock()
				return owed[id]
			}
			h.seat("a", 10_000)
			h.seat("b", 10_000)
			h.seat("c", 10_000)
			h.deal()
			h.mustAct("a", ActionRaise, 1_000)
			h.mustAct("b", ActionCall)

			h.books.mu.Lock()
			h.books.refuse = true
			h.books.mu.Unlock()
			if _, err := h.table.RemovePlayer("b", game.LeaveReasonLeft); err != nil {
				t.Fatal(err)
			}
			h.books.mu.Lock()
			h.books.refuse = settleRefused
			h.books.mu.Unlock()
			if got := of("b"); got != 1 {
				t.Fatalf("b is owed %d write(s) once off the table, want 1", got)
			}

			h.mustAct("c", ActionFold)
			if settleRefused {
				if got := of("b"); got != 1 {
					t.Fatalf("b is owed %d write(s) while the settle is retried, want 1", got)
				}
				h.books.mu.Lock()
				h.books.refuse = false
				h.books.mu.Unlock()
				h.clock.Advance(h.cfg.NextHandDelay)
			}
			for _, id := range []string{"a", "b", "c"} {
				if got := of(id); got != 0 {
					t.Fatalf("%s is still owed %d write(s) after the settle landed", id, got)
				}
			}
			if got := h.books.wallets["b"]; got != 9_000 {
				t.Fatalf("the leaver is banked at %d, want 9,000", got)
			}
		})
	}
}
