package poker

import (
	"strings"
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
	h.books.mu.Lock()
	h.books.duplicate = false
	h.books.mu.Unlock()
	h.mustAct("c", ActionFold)
	for _, s := range h.stats.all() {
		if s.UserID == "b" {
			t.Fatalf("the replayed departure was counted at the hand end: %+v", s)
		}
	}
}

// The same with a BARE duplicate_action (the ledger could not read the row
// back): the money is caught up at the hand end as if refused, but the write
// landed in an earlier life, which counted it — the catch-up counts nothing.
func TestAPokerDepartureReplayedBareIsNotCountedAtTheHandEnd(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.mustAct("a", ActionRaise, 1_000)
	h.mustAct("b", ActionCall)
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
	for _, s := range h.stats.all() {
		if s.UserID == "b" {
			t.Fatalf("a departure that landed in an earlier life was counted again: %+v", s)
		}
	}
}

// A departure the ledger REFUSED counted nothing at its checkpoint, so the
// settle's catch-up row is its outcome and counts it — once, left and played
// — when the settle commits.
func TestAPokerDepartureRefusedIsCountedOnceByTheSettle(t *testing.T) {
	h := newHarness(t, TexasHoldem)
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
	h.books.refuse = false
	h.books.mu.Unlock()
	if got := h.stats.all(); len(got) != 0 {
		t.Fatalf("a refused departure counted %+v at its checkpoint", got)
	}
	h.mustAct("c", ActionFold)
	var b []game.HandStats
	for _, s := range h.stats.all() {
		if s.UserID == "b" {
			b = append(b, s)
		}
	}
	if len(b) != 1 || b[0] != (game.HandStats{UserID: "b", Bucket: game.StatsPoker, Played: 1, Left: 1}) {
		t.Fatalf("the refused departure counted %+v, want once: left and played", b)
	}
	if got := h.books.wallets["b"]; got != 9_000 {
		t.Fatalf("the leaver is banked at %d, want 9,000", got)
	}
}

// A player who leaves before putting a chip in (the button, first to act
// preflop three-handed) with the leave refused is still written — a zero-delta
// catch-up row — so the departure counts once at the settle.
func TestAPokerDepartureRefusedWithNothingStakedIsStillCountedOnce(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	quitter := h.turn()
	var staked int64
	h.read(func() { staked = h.table.hand.contributions[quitter].contributed })
	if staked != 0 {
		t.Fatalf("%s, first to act, has %d in: want the button with nothing staked", quitter, staked)
	}
	h.books.mu.Lock()
	h.books.refuse = true
	h.books.mu.Unlock()
	if _, err := h.table.RemovePlayer(quitter, game.LeaveReasonLeft); err != nil {
		t.Fatal(err)
	}
	h.books.mu.Lock()
	h.books.refuse = false
	h.books.mu.Unlock()
	for i := 0; i < 5 && h.turn() != ""; i++ {
		h.mustAct(h.turn(), ActionFold)
	}
	var got []game.HandStats
	for _, s := range h.stats.all() {
		if s.UserID == quitter {
			got = append(got, s)
		}
	}
	if len(got) != 1 || got[0] != (game.HandStats{UserID: quitter, Bucket: game.StatsPoker, Left: 1}) {
		t.Fatalf("the refused departure counted %+v, want left once", got)
	}
	if w := h.books.wallets[quitter]; w != 10_000 {
		t.Fatalf("the quitter who staked nothing is banked at %d", w)
	}
}

// The mark survives a restart: the restored hand's settle still counts the
// refused departure, once.
func TestAPokerRefusedDepartureIsCountedOnceAcrossARestore(t *testing.T) {
	h := newHarness(t, TexasHoldem)
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
	h.books.refuse = false
	h.books.mu.Unlock()
	snap, err := h.table.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	data, err := h.table.marshalSnapshot(snap.Seq)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"leftUncounted":true`) {
		t.Fatalf("the snapshot does not keep the mark: %s", data)
	}
	parsed, err := ParseSnapshot(data)
	if err != nil {
		t.Fatal(err)
	}
	// The first process stops here (a harness room has no live store to
	// suspend into, so it is simply left alone and never touched again).
	log := &statsLog{}
	restored, err := RestoreTable(parsed, TableOptions{Listener: newRecorder(), Deps: game.RoomDeps{Clock: h.clock, Ledger: h.books.ledger(), Stats: log.record}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = restored.Destroy() })
	if _, err := restored.Act("c", ActionFold, ActRequest{}); err != nil {
		t.Fatal(err)
	}
	var b []game.HandStats
	for _, s := range log.all() {
		if s.UserID == "b" {
			b = append(b, s)
		}
	}
	if len(b) != 1 || b[0] != (game.HandStats{UserID: "b", Bucket: game.StatsPoker, Played: 1, Left: 1}) {
		t.Fatalf("the restored settle counted b %+v, want once: left and played", b)
	}
	if got := h.books.wallets["b"]; got != 9_000 {
		t.Fatalf("the leaver is banked at %d, want 9,000", got)
	}
}
