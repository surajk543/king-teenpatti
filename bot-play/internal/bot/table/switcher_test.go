package table

import (
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/strategy"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// seated is a bot at blind:5000 with 10 Lakh, past its minimum hands, among
// a full table with a human, nothing prompting a move.
func seated(t *testing.T) SwitchInput {
	t.Helper()
	m := liveMenu()
	cur, ok := m.Lookup("blind:5000")
	if !ok {
		t.Fatal("blind:5000 missing")
	}
	return SwitchInput{
		Personality:  persona(strategy.Balanced, 0.5, 0), // TableMoves 0: the rarest random move
		Current:      cur,
		Menu:         m,
		Chips:        1_000_000,
		HandsAtTable: 6,
		PlannedHands: 12,
		MinHands:     3,
		MaxHands:     20,
		Players:      5,
		FleetBots:    3,
		BootsToSit:   8,
	}
}

// decide runs AfterHand over n seeds and counts each decision.
func decide(in SwitchInput, n int) map[Decision]int {
	out := map[Decision]int{}
	for i := range n {
		out[AfterHand(in, rng.New(uint64(i)+1))]++
	}
	return out
}

// only asserts that every one of n seeds decides want.
func only(t *testing.T, in SwitchInput, want Decision) {
	t.Helper()
	got := decide(in, 200)
	if len(got) != 1 || got[want] != 200 {
		t.Fatalf("want always %+v, got %v", want, got)
	}
}

func TestAQuietTableMostlyKeepsItsBots(t *testing.T) {
	got := decide(seated(t), 2000)
	stays := got[Decision{Stay, ReasonStay}]
	if stays < 1900 {
		t.Fatalf("nothing prompting a move should mostly stay, got %v", got)
	}
	for d := range got {
		if d.Move != Stay && d != (Decision{SwitchSame, ReasonRandom}) {
			t.Fatalf("unexpected %+v", d)
		}
	}
}

func TestNeverMovesBeforeMinHandsUnlessForced(t *testing.T) {
	r := rng.New(2026)
	for i := range 3000 {
		in := seated(t)
		in.Personality = persona(strategy.Kinds[i%len(strategy.Kinds)], r.Float64(), r.Float64())
		in.MinHands = 2 + r.IntN(6)
		in.HandsAtTable = r.IntN(in.MinHands)
		in.MaxHands = in.MinHands + 10
		in.PlannedHands = r.IntN(in.MinHands + 1) // already reached
		// Every unforced reason at once.
		in.TableNet = []int64{-1e12, 1e12}[r.IntN(2)]
		in.MaxBotsHere, in.FleetBots, in.Players = 1, 2, 2
		in.NoHumanPatience, in.SinceHuman = time.Second, time.Hour
		in.Chips = in.Current.Boot * int64(1+r.IntN(3)) // thin for this stake: UNSUITABLE if it could
		d := AfterHand(in, r)
		if d != (Decision{Stay, ReasonStay}) {
			t.Fatalf("case %d (hands %d < min %d): %+v", i, in.HandsAtTable, in.MinHands, d)
		}
	}
}

func TestForcedReasonsMoveBeforeMinHands(t *testing.T) {
	base := seated(t)
	base.HandsAtTable, base.MinHands = 0, 5

	over := base
	over.SessionOver = true
	only(t, over, Decision{EndSession, ReasonSessionOver})

	gone := base
	gone.Menu.Tables = append([]Choice(nil), base.Menu.Tables...)
	gone.Menu.Tables = append(gone.Menu.Tables[:2:2], gone.Menu.Tables[3:]...) // blind:5000 off the menu
	only(t, gone, Decision{Hop, ReasonNotOffered})

	rich := base
	rich.Chips = 200_000_001 // past blind:5000's 20 Crore cap
	only(t, rich, Decision{Hop, ReasonNotAdmitted})

	// The menu's current band wins over the one the bot sat down under.
	stale := base
	stale.Current.MaxChips = 0
	stale.Chips = 250_000_000
	only(t, stale, Decision{Hop, ReasonNotAdmitted})

	short := base
	short.Chips = 4_999
	only(t, short, Decision{Hop, ReasonShortStack})

	broke := base
	broke.Chips = 150 // covers no boot anywhere
	only(t, broke, Decision{EndSession, ReasonShortStack})

	idle := base
	idle.Idle = 3 * time.Minute
	only(t, idle, Decision{Hop, ReasonIdleTable})

	// A menu not yet known says nothing about whether the table is offered.
	unknown := base
	unknown.Menu = Menu{}
	only(t, unknown, Decision{Stay, ReasonStay})
}

func TestAlwaysMovesAtMaxHands(t *testing.T) {
	in := seated(t)
	in.HandsAtTable, in.MaxHands, in.MinHands = 20, 20, 30 // max wins over a misconfigured min
	for d, n := range decide(in, 500) {
		if d.Move == Stay || d.Reason != ReasonMaxHands {
			t.Fatalf("at MaxHands: %+v ×%d", d, n)
		}
	}
}

func TestStopLossAndTakeProfitHop(t *testing.T) {
	in := seated(t) // StopLossBoots 40, TakeProfitBoots 60, boot 5,000
	in.TableNet = -40 * 5000
	only(t, in, Decision{Hop, ReasonStopLoss})
	in.TableNet = -40*5000 + 1
	if got := decide(in, 200); got[Decision{Hop, ReasonStopLoss}] != 0 {
		t.Fatalf("one chip short of the stop-loss: %v", got)
	}
	in.TableNet = 60 * 5000
	only(t, in, Decision{Hop, ReasonTakeProfit})

	// With nowhere else to go, a switch within the stake instead.
	solo := in
	solo.Menu = Menu{Tables: []Choice{in.Current}}
	only(t, solo, Decision{SwitchSame, ReasonTakeProfit})
}

func TestCrowdedAndHumanlessTablesSwitchWithinTheStake(t *testing.T) {
	bots := seated(t)
	bots.MaxBotsHere, bots.FleetBots = 3, 4
	only(t, bots, Decision{SwitchSame, ReasonTooManyBots})
	bots.FleetBots = 3
	if got := decide(bots, 200); got[Decision{SwitchSame, ReasonTooManyBots}] != 0 {
		t.Fatalf("at the limit is not over it: %v", got)
	}

	humanless := seated(t)
	humanless.NoHumanPatience, humanless.SinceHuman = 5*time.Minute, 5*time.Minute
	only(t, humanless, Decision{SwitchSame, ReasonNoHumans})
	humanless.SinceHuman = 0 // one is here now
	if got := decide(humanless, 200); got[Decision{SwitchSame, ReasonNoHumans}] != 0 {
		t.Fatalf("a human is here: %v", got)
	}
}

func TestAnEmptyingTableIsLeftButAHumanIsNeverAbandonedHeadsUp(t *testing.T) {
	alone := seated(t)
	alone.Players, alone.FleetBots, alone.SinceHuman = 1, 1, time.Minute
	only(t, alone, Decision{SwitchSame, ReasonTableEmptying})

	twoBots := seated(t)
	twoBots.Players, twoBots.FleetBots, twoBots.SinceHuman = 2, 2, 0
	if got := decide(twoBots, 1000); got[Decision{SwitchSame, ReasonTableEmptying}] < 250 {
		t.Fatalf("two bots alone should often break up: %v", got)
	}

	withHuman := seated(t)
	withHuman.Players, withHuman.FleetBots, withHuman.SinceHuman = 2, 1, 0
	if got := decide(withHuman, 1000); got[Decision{SwitchSame, ReasonTableEmptying}] != 0 {
		t.Fatalf("a human heads-up is never abandoned: %v", got)
	}
}

func TestPlannedHandsEndTheSittingWithASwitchOrAHop(t *testing.T) {
	in := seated(t)
	in.HandsAtTable, in.PlannedHands = 12, 12
	got := decide(in, 2000)
	sw, hop := got[Decision{SwitchSame, ReasonPlannedHands}], got[Decision{Hop, ReasonPlannedHands}]
	if sw+hop != 2000 || sw < hop || hop == 0 {
		t.Fatalf("a sitting that suits ends mostly in a switch, now and then a hop: %v", got)
	}

	// A high-stakes bot whose sitting ends at the lowest stake always hops (the
	// stake is far from its appetite) — usually as the sitting ends, now and
	// then a hand earlier, having noticed.
	astray := seated(t)
	astray.Personality = persona(strategy.Aggressive, 1, 0)
	astray.Current, _ = astray.Menu.Lookup("seen:200")
	astray.Chips = 1_000_000
	astray.HandsAtTable, astray.PlannedHands = 12, 12
	got = decide(astray, 1000)
	if got[Decision{Hop, ReasonPlannedHands}]+got[Decision{Hop, ReasonUnsuitable}] != 1000 ||
		got[Decision{Hop, ReasonPlannedHands}] < 900 {
		t.Fatalf("a sitting ending at a stake astray hops: %v", got)
	}
}

func TestAStakeThatNoLongerSuitsIsLeftForAnother(t *testing.T) {
	thin := seated(t)
	thin.Chips = 15_000 // three boots at 5,000, where eight are wanted
	only(t, thin, Decision{Hop, ReasonUnsuitable})

	// Thin at the cheapest stake: nowhere cheaper to go, so it plays on.
	cheapest := seated(t)
	cheapest.Current, _ = cheapest.Menu.Lookup("seen:200")
	cheapest.Chips = 600
	if got := decide(cheapest, 200); got[Decision{Hop, ReasonUnsuitable}] != 0 {
		t.Fatalf("no cheaper table: %v", got)
	}

	astray := seated(t)
	astray.Personality = persona(strategy.Aggressive, 1, 1)
	astray.Current, _ = astray.Menu.Lookup("seen:200")
	got := decide(astray, 2000)
	if n := got[Decision{Hop, ReasonUnsuitable}]; n < 200 || n > 700 {
		t.Fatalf("a stake astray is acted on now and then (~20%% a hand), got %v", got)
	}
}

func TestIdlePatienceFollowsTableMoves(t *testing.T) {
	if a, b := IdlePatience(persona(strategy.Balanced, 0.5, 0)), IdlePatience(persona(strategy.Balanced, 0.5, 1)); a != 120*time.Second || b != 60*time.Second {
		t.Fatalf("idle patience %v / %v", a, b)
	}
	in := seated(t)
	in.Idle = 59 * time.Second
	if got := decide(in, 200); got[Decision{Hop, ReasonIdleTable}] != 0 {
		t.Fatalf("under a minute is not idle: %v", got)
	}
	solo := seated(t)
	solo.Menu = Menu{Tables: []Choice{solo.Current}}
	solo.Idle = time.Hour
	only(t, solo, Decision{EndSession, ReasonIdleTable})
}

func TestPlanHandsStaysInRangeVariesAndFollowsTheBotsRestlessness(t *testing.T) {
	r := rng.New(5)
	mean := func(p strategy.Personality) (float64, map[int]int) {
		counts := map[int]int{}
		sum := 0
		for range 3000 {
			n := PlanHands(p, 3, 20, r)
			if n < 3 || n > 20 {
				t.Fatalf("PlanHands %d outside [3,20]", n)
			}
			counts[n]++
			sum += n
		}
		return float64(sum) / 3000, counts
	}
	settled, sc := mean(persona(strategy.Cautious, 0.5, 0))
	restless, rc := mean(persona(strategy.Loose, 0.5, 1))
	t.Logf("mean planned hands: settled %.1f, restless %.1f", settled, restless)
	if !(restless+3 < settled) {
		t.Fatalf("a restless bot plans shorter sittings: settled %.1f restless %.1f", settled, restless)
	}
	if len(sc) < 12 || len(rc) < 12 {
		t.Fatalf("sittings should vary: %d / %d distinct lengths", len(sc), len(rc))
	}
	for _, n := range []int{5, 11, 17} {
		if sc[n]+rc[n] == 0 {
			t.Fatalf("no sitting of %d hands", n)
		}
	}
	// Out-of-order and unset ranges.
	for range 200 {
		if n := PlanHands(strategy.Personality{HandsAtTable: [2]int{30, 1}}, 4, 9, r); n < 4 || n > 9 {
			t.Fatalf("reversed personality range: %d", n)
		}
		if n := PlanHands(strategy.Personality{}, 0, -3, r); n != 1 {
			t.Fatalf("degenerate config: %d", n)
		}
	}
	a, b := rng.New(77), rng.New(77)
	for range 100 {
		p := persona(strategy.Balanced, 0.5, 0.5)
		if PlanHands(p, 3, 20, a) != PlanHands(p, 3, 20, b) {
			t.Fatal("PlanHands is deterministic for a seed")
		}
	}
}
