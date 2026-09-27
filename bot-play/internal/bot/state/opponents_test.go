package state

import (
	"math"
	"testing"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

func act(b *OpponentBook, user, action string, blind bool) {
	b.Observe(protocol.ActionEvent{UserID: user, Action: action}, blind)
}

func packFor(b *OpponentBook, user, reason string) {
	b.Observe(protocol.ActionEvent{UserID: user, Action: protocol.ActionPack, Reason: reason}, false)
}

// play records n hands for user: in each, the moves given, then a fold when
// fold(i) says so.
func play(b *OpponentBook, user string, n int, moves []string, fold func(i int) bool) {
	for i := range n {
		b.HandDealt([]string{user})
		for _, m := range moves {
			act(b, user, m, false)
		}
		if fold != nil && fold(i) {
			packFor(b, user, "pack")
		}
	}
}

func near(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestAStrangerReadsNeutralAndUnknown(t *testing.T) {
	b := NewOpponentBook(0)
	r := b.Read("nobody")
	if r.Style != StyleUnknown || r.Hands != 0 || r.Actions != 0 ||
		!near(r.Aggression, Neutral) || !near(r.Looseness, Neutral) || !near(r.FoldRate, Neutral) || !near(r.BlindRate, Neutral) {
		t.Fatalf("stranger %+v", r)
	}
	if s := b.Summary([]string{"a", "b"}); s != r {
		t.Fatalf("summary of strangers %+v", s)
	}
}

func TestReadsShrinkTowardsNeutralOnFewObservations(t *testing.T) {
	b := NewOpponentBook(0)
	act(b, "r", protocol.ActionRaise, false)
	one := b.Read("r").Aggression
	if !near(one, (1+Neutral*PriorWeight)/(1+PriorWeight)) || one <= Neutral || one >= 1 {
		t.Fatalf("one raise: aggression %.3f should sit between neutral and 1", one)
	}
	for range 99 {
		act(b, "r", protocol.ActionRaise, false)
	}
	many := b.Read("r").Aggression
	if !(many > one && many > 0.97) {
		t.Fatalf("a hundred raises: %.3f", many)
	}
	// Folds: two hands, two folds is far from certain.
	play(b, "f", 2, nil, func(int) bool { return true })
	if fr := b.Read("f").FoldRate; !near(fr, (2+2.0)/(2+4.0)) {
		t.Fatalf("fold rate %.3f", fr)
	}
	if st := b.Read("f").Style; st != StyleUnknown {
		t.Fatalf("two folds name no style, got %s", st)
	}
}

func TestStyles(t *testing.T) {
	b := NewOpponentBook(0)
	// Passive: calls every hand it plays, folds half, never raises.
	play(b, "passive", 10, []string{protocol.ActionChaal, protocol.ActionChaal}, func(i int) bool { return i%2 == 0 })
	// Aggressive: raises most of its bets.
	play(b, "aggressive", 10, []string{protocol.ActionRaise, protocol.ActionRaise, protocol.ActionChaal}, func(i int) bool { return i%2 == 0 })
	// Tight: folds nine hands of twelve; shows down only a trail.
	play(b, "tight", 12, nil, func(i int) bool { return i < 9 })
	act(b, "tight", protocol.ActionRaise, false)
	act(b, "tight", protocol.ActionChaal, false)
	act(b, "tight", protocol.ActionChaal, false)
	b.Showdown([]protocol.Reveal{{UserID: "tight", Category: protocol.HandTrail}})
	// Loose: never folds, shows down weak hands.
	play(b, "loose", 10, []string{protocol.ActionChaal, protocol.ActionRaise}, nil)
	for range 3 {
		b.Showdown([]protocol.Reveal{{UserID: "loose", Category: protocol.HandHighCard}})
	}
	for user, want := range map[string]string{
		"passive": StylePassive, "aggressive": StyleAggressive, "tight": StyleTight, "loose": StyleLoose,
	} {
		r := b.Read(user)
		if r.Style != want {
			t.Errorf("%s read as %s: %+v", user, r.Style, r)
		}
	}
	// Too few actions name no style, however extreme.
	for range 5 {
		act(b, "brief", protocol.ActionRaise, false)
	}
	if r := b.Read("brief"); r.Style != StyleUnknown || r.Aggression <= 0.55 {
		t.Fatalf("five raises: %+v", r)
	}
	// Middling in every way: nothing stands out.
	play(b, "middling", 12, []string{protocol.ActionChaal, protocol.ActionChaal, protocol.ActionRaise}, func(i int) bool { return i%2 == 0 })
	if r := b.Read("middling"); r.Style != StyleUnknown {
		t.Fatalf("middling read as %s: %+v", r.Style, r)
	}
}

func TestOnlyChosenPacksAreFoldsAndBlindBetsAreCounted(t *testing.T) {
	b := NewOpponentBook(0)
	b.HandDealt([]string{"p"})
	packFor(b, "p", "timeout")
	packFor(b, "p", "sideshow")
	packFor(b, "p", "left")
	packFor(b, "p", "disconnected")
	if r := b.Read("p"); r.Actions != 0 || !near(r.FoldRate, 2.0/5) {
		t.Fatalf("no chosen fold yet: %+v", r)
	}
	packFor(b, "p", "")
	if r := b.Read("p"); r.Actions != 1 || !near(r.FoldRate, 3.0/5) {
		t.Fatalf("one chosen fold in one hand: %+v", r)
	}

	act(b, "blind", protocol.ActionChaal, true)
	act(b, "blind", protocol.ActionRaise, true)
	act(b, "blind", protocol.ActionChaal, true)
	act(b, "blind", protocol.ActionChaal, false)
	if r := b.Read("blind"); !near(r.BlindRate, (3+2.0)/(4+4)) || !near(r.Aggression, (1+2.0)/(4+4)) {
		t.Fatalf("blind bets: %+v", r)
	}
	// Looks, and moves this book does not read, are not actions.
	auto := true
	b.Observe(protocol.ActionEvent{UserID: "blind", Action: protocol.ActionSee}, true)
	b.Observe(protocol.ActionEvent{UserID: "blind", Action: protocol.ActionSee, Auto: &auto}, true)
	b.Observe(protocol.ActionEvent{UserID: "blind", Action: "dance"}, true)
	act(b, "blind", protocol.ActionSideshow, false)
	if r := b.Read("blind"); r.Actions != 5 {
		t.Fatalf("four bets and a sideshow ask are five actions, got %+v", r)
	}
}

func TestTheLeastRecentlySeenAreForgottenPastCapacity(t *testing.T) {
	b := NewOpponentBook(3)
	b.HandDealt([]string{"a", "b", "c"})
	act(b, "a", protocol.ActionChaal, false) // a seen again: b is now the oldest
	b.HandDealt([]string{"d"})
	if b.Len() != 3 {
		t.Fatalf("len %d", b.Len())
	}
	if r := b.Read("b"); r.Hands != 0 {
		t.Fatalf("b should be forgotten: %+v", r)
	}
	for _, id := range []string{"a", "c", "d"} {
		if r := b.Read(id); r.Hands != 1 {
			t.Fatalf("%s forgotten: %+v", id, r)
		}
	}
	// Reading is not seeing: c, read but not seen, goes next.
	b.Read("c")
	b.Showdown([]protocol.Reveal{{UserID: "e", Category: protocol.HandPair}})
	if b.Read("c").Hands != 0 || b.Read("a").Hands != 1 {
		t.Fatal("a read refreshed c's place in the book")
	}
	if NewOpponentBook(-1).capacity != 256 {
		t.Fatal("default capacity")
	}
}

func TestTheBotItselfAndEmptyIDsAreNeverRecorded(t *testing.T) {
	b := NewOpponentBook(0)
	b.HandDealt([]string{"me", "x", "", "x"})
	b.Ignore("me")
	act(b, "me", protocol.ActionRaise, false)
	act(b, "", protocol.ActionRaise, false)
	b.Showdown([]protocol.Reveal{{UserID: "me"}, {UserID: "x", Category: protocol.HandHighCard}})
	if b.Len() != 1 {
		t.Fatalf("only x is an opponent, book holds %d", b.Len())
	}
	if r := b.Read("me"); r.Hands != 0 {
		t.Fatalf("own record %+v", r)
	}
	if r := b.Read("x"); r.Hands != 1 {
		t.Fatalf("x named twice in one deal counts once: %+v", r)
	}
}

func TestSummaryWeighsEachPlayerByHowMuchTheyHaveBeenSeen(t *testing.T) {
	b := NewOpponentBook(0)
	play(b, "heavy", 30, []string{protocol.ActionRaise, protocol.ActionRaise}, nil) // well known, aggressive
	play(b, "light", 1, []string{protocol.ActionChaal}, nil)                        // barely seen
	heavy, light := b.Read("heavy"), b.Read("light")
	s := b.Summary([]string{"heavy", "light", "light", "stranger"})
	if s.Hands != heavy.Hands+light.Hands || s.Actions != heavy.Actions+light.Actions {
		t.Fatalf("sums %+v", s)
	}
	mid := (heavy.Aggression + light.Aggression) / 2
	if !(s.Aggression > mid && s.Aggression < heavy.Aggression) {
		t.Fatalf("weighted aggression %.3f should lean to heavy %.3f past the plain mean %.3f", s.Aggression, heavy.Aggression, mid)
	}
	if s.Style != StyleAggressive && s.Style != StyleLoose {
		t.Fatalf("summary style %s", s.Style)
	}
}
