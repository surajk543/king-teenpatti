package table

import (
	"math"
	"slices"
	"testing"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/strategy"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// persona is a personality literal: the fields the table package reads.
func persona(kind strategy.Kind, appetite, moves float64) strategy.Personality {
	return strategy.Personality{
		Kind:            kind,
		StakeAppetite:   appetite,
		TableMoves:      moves,
		Noise:           0.1,
		HandsAtTable:    [2]int{5, 17},
		StopLossBoots:   40,
		TakeProfitBoots: 60,
	}
}

func liveMenu() Menu { return FromCatalogue(liveCatalogue(), nil) }

func TestSelectOnlyPicksTablesThatAdmitTheStackAndItsBoots(t *testing.T) {
	m := liveMenu()
	r := rng.New(7)
	stacks := []int64{
		200, 1_000, 1_599, 1_600, 50_000, 400_000, 1_000_000, 2_000_000, 2_000_001, 16_000_000,
		100_000_000, 200_000_001, 499_999_999, 500_000_000, 2_000_000_000, 2_000_000_001, 90_000_000_000,
	}
	kinds := []strategy.Kind{strategy.Cautious, strategy.Balanced, strategy.Aggressive, strategy.Loose, strategy.Random, strategy.Beginner}
	for _, chips := range stacks {
		deepExists := false
		for _, c := range m.Tables {
			if m.Admits(c, chips) && affords(chips, c.Boot, 8) {
				deepExists = true
			}
		}
		for i := range 300 {
			p := persona(kinds[i%len(kinds)], r.Float64(), r.Float64())
			p.Noise = r.Float64()
			c, ok := Select(m, SelectInput{Chips: chips, Personality: p, BootsToSit: 8}, r)
			if !ok {
				t.Fatalf("chips %d: nothing picked", chips)
			}
			if !m.Admits(c, chips) || !IsTeenPatti(c.Category) {
				t.Fatalf("chips %d: picked %+v which does not admit it", chips, c)
			}
			if deepExists && !affords(chips, c.Boot, 8) {
				t.Fatalf("chips %d: picked %s without 8 boots while a deeper table exists", chips, c.Key)
			}
			if !deepExists && c.Boot != 200 {
				t.Fatalf("chips %d: the fallback is the cheapest admitting table, got %s", chips, c.Key)
			}
		}
	}
}

func TestSelectAnswersNotOkWhenNothingAdmitsTheStack(t *testing.T) {
	m := liveMenu()
	r := rng.New(1)
	if _, ok := Select(m, SelectInput{Chips: 199, Personality: persona(strategy.Balanced, 0.5, 0.5), BootsToSit: 8}, r); ok {
		t.Fatal("199 chips cover no boot")
	}
	if _, ok := Select(Menu{}, SelectInput{Chips: 1_000_000}, r); ok {
		t.Fatal("an empty menu offers nothing")
	}
	// Only the 200 tables admit 1,000 chips; excluding both leaves nothing.
	if _, ok := Select(m, SelectInput{Chips: 1_000, BootsToSit: 8, Exclude: []string{"seen:200", "blind:200"}}, r); ok {
		t.Fatal("excluded tables are never picked")
	}
}

func TestSelectNeverPicksPoker(t *testing.T) {
	m := liveMenu()
	// Even a menu that somehow carries a poker room never yields it.
	m.Tables = append(m.Tables,
		Choice{Key: "texas_holdem:50000", Category: "texas_holdem", Boot: 50000},
		Choice{Key: "omaha:200", Category: "omaha", Boot: 200},
	)
	r := rng.New(99)
	for i := range 5000 {
		chips := int64(math.Pow(10, 3+r.Float64()*9))
		p := persona(strategy.Kinds[i%len(strategy.Kinds)], r.Float64(), 0.5)
		c, ok := Select(m, SelectInput{Chips: chips, Personality: p, BootsToSit: 8}, r)
		if ok && !IsTeenPatti(c.Category) {
			t.Fatalf("picked %s", c.Key)
		}
	}
}

// meanPosition is the mean ladder position (0 lowest boot … 1 highest) of n
// picks for p at chips.
func meanPosition(t *testing.T, p strategy.Personality, chips int64, n int, seed uint64) float64 {
	t.Helper()
	m := liveMenu()
	r := rng.New(seed)
	levels := []int64{200, 5000, 50000}
	sum := 0.0
	for range n {
		c, ok := Select(m, SelectInput{Chips: chips, Personality: p, BootsToSit: 8}, r)
		if !ok {
			t.Fatal("nothing picked")
		}
		sum += ladderPosition(c.Boot, levels)
	}
	return sum / float64(n)
}

func TestCautiousBotsPickLowerStakesThanAggressiveOnes(t *testing.T) {
	const chips = 1_000_000 // 10 Lakh: 200, 5,000 and 50,000 are all 8 boots deep
	cautious := meanPosition(t, persona(strategy.Cautious, 0.3, 0.5), chips, 3000, 11)
	balanced := meanPosition(t, persona(strategy.Balanced, 0.5, 0.5), chips, 3000, 12)
	aggressive := meanPosition(t, persona(strategy.Aggressive, 0.7, 0.5), chips, 3000, 13)
	beginner := meanPosition(t, persona(strategy.Beginner, 0.5, 0.5), chips, 3000, 14)
	t.Logf("mean ladder position: cautious %.2f beginner %.2f balanced %.2f aggressive %.2f", cautious, beginner, balanced, aggressive)
	if !(cautious+0.2 < aggressive) {
		t.Fatalf("cautious %.2f should sit well below aggressive %.2f", cautious, aggressive)
	}
	if !(beginner < balanced && balanced < aggressive) {
		t.Fatalf("beginner %.2f < balanced %.2f < aggressive %.2f expected", beginner, balanced, aggressive)
	}
	// Even at the same trait value, the family shapes the appetite.
	if c, a := meanPosition(t, persona(strategy.Cautious, 0.5, 0.5), chips, 2000, 15),
		meanPosition(t, persona(strategy.Aggressive, 0.5, 0.5), chips, 2000, 16); !(c < a) {
		t.Fatalf("family shaping: cautious %.2f aggressive %.2f", c, a)
	}
}

func TestSelectVariesItsPicksButIsDeterministicForASeed(t *testing.T) {
	m := liveMenu()
	in := SelectInput{Chips: 1_000_000, Personality: persona(strategy.Balanced, 0.5, 0.5), BootsToSit: 8}
	run := func(seed uint64) []string {
		r := rng.New(seed)
		var keys []string
		for range 200 {
			c, _ := Select(m, in, r)
			keys = append(keys, c.Key)
		}
		return keys
	}
	a, b := run(42), run(42)
	distinct := map[string]bool{}
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("draw %d differs for one seed: %s vs %s", i, a[i], b[i])
		}
		distinct[a[i]] = true
	}
	if len(distinct) < 4 {
		t.Fatalf("a balanced bot should spread over the tables, got %v", distinct)
	}
}

// share is how often key is picked from the two 200 tables.
func share(key string, in SelectInput, n int, seed uint64) float64 {
	m := Menu{Tables: []Choice{
		{Key: "seen:200", Category: "seen", Boot: 200},
		{Key: "blind:200", Category: "blind", Boot: 200},
	}}
	r := rng.New(seed)
	hits := 0
	for range n {
		if c, _ := Select(m, in, r); c.Key == key {
			hits++
		}
	}
	return float64(hits) / float64(n)
}

func TestSelectMildlyAvoidsTheTableJustPlayed(t *testing.T) {
	base := SelectInput{Chips: 100_000, Personality: persona(strategy.Balanced, 0.5, 0.5), BootsToSit: 8}
	even := share("seen:200", base, 4000, 3)
	recent := base
	recent.Recent = []string{"seen:200", "blind:200"}
	again := share("seen:200", recent, 4000, 3)
	t.Logf("seen:200 share: %.2f without history, %.2f just played", even, again)
	if math.Abs(even-0.5) > 0.05 {
		t.Fatalf("two identical tables should split evenly, got %.2f", even)
	}
	if !(again < 0.45 && again > 0.2) {
		t.Fatalf("the table just played is avoided mildly, got %.2f", again)
	}
}

func TestSelectHonoursExcludeOccupancyAndCategoryWeights(t *testing.T) {
	base := SelectInput{Chips: 100_000, Personality: persona(strategy.Balanced, 0.5, 0.5), BootsToSit: 8}

	ex := base
	ex.Exclude = []string{"blind:200"}
	if s := share("seen:200", ex, 500, 4); s != 1 {
		t.Fatalf("with blind:200 excluded seen:200 is the only pick, got %.2f", s)
	}

	crowded := base
	crowded.Occupancy = map[string]float64{"seen:200": 0.30, "blind:200": 0.02}
	if s := share("seen:200", crowded, 4000, 5); s > 0.35 {
		t.Fatalf("the table the fleet crowds should be picked less, got %.2f", s)
	}

	weighted := base
	weighted.CategoryWeights = map[string]float64{"seen": 3}
	if s := share("seen:200", weighted, 4000, 6); !(s > 0.68 && s < 0.82) {
		t.Fatalf("seen weighted 3 against an unnamed blind (1) should take ~75%%, got %.2f", s)
	}
	weighted.CategoryWeights = map[string]float64{"seen": 0}
	if s := share("seen:200", weighted, 1000, 7); s != 0 {
		t.Fatalf("a category weighted 0 is not picked while another fits, got %.2f", s)
	}
	weighted.CategoryWeights = map[string]float64{"seen": 0, "blind": 0}
	if s := share("seen:200", weighted, 2000, 8); s < 0.4 || s > 0.6 {
		t.Fatalf("every category weighted 0 still picks, evenly: %.2f", s)
	}
}

// fiveTables are the lobby tables the fleet plays in production (owner, 27
// Sep 2026).
var fiveTables = []string{"seen:200", "seen:50000", "blind:200", "blind:50000", "variation:50000"}

func TestSelectPlaysOnlyTheNamedLobbyTables(t *testing.T) {
	m := liveMenu()
	r := rng.New(3)
	kinds := []strategy.Kind{strategy.Cautious, strategy.Balanced, strategy.Aggressive, strategy.Loose, strategy.Random, strategy.Beginner}
	picked := map[string]int{}
	for i := range 3000 {
		p := persona(kinds[i%len(kinds)], r.Float64(), r.Float64())
		c, ok := Select(m, SelectInput{Chips: 1_000_000, Personality: p, BootsToSit: 20, Only: fiveTables}, r)
		if !ok {
			t.Fatal("a fresh 10 Lakh bot found nothing among the five")
		}
		if !slices.Contains(fiveTables, c.Key) {
			t.Fatalf("picked %s, which is not one of %v", c.Key, fiveTables)
		}
		picked[c.Key]++
	}
	// With 20 boots to sit, a fresh 10 Lakh account reaches all five —
	// the 50,000 tables included.
	for _, k := range fiveTables {
		if picked[k] == 0 {
			t.Errorf("never picked %s: %v", k, picked)
		}
	}
}

func TestATableAtItsCeilingTakesNoMoreOfTheFleet(t *testing.T) {
	m := liveMenu()
	r := rng.New(5)
	held := map[string]int{"seen:200": 50, "blind:200": 50, "seen:50000": 49, "blind:50000": 50, "variation:50000": 50}
	for range 500 {
		c, ok := Select(m, SelectInput{
			Chips: 1_000_000, Personality: persona(strategy.Balanced, 0.2, 0.5), BootsToSit: 20,
			Only: fiveTables, Held: held, Fleet: FleetLayout{Default: [2]int{30, 50}},
		}, r)
		if !ok || c.Key != "seen:50000" {
			t.Fatalf("the one table under its ceiling is seen:50000, got %s %v", c.Key, ok)
		}
	}
	held["seen:50000"] = 50
	in := SelectInput{
		Chips: 1_000_000, Personality: persona(strategy.Balanced, 0.2, 0.5), BootsToSit: 20,
		Only: fiveTables, Held: held, Fleet: FleetLayout{Default: [2]int{30, 50}},
	}
	if _, ok := Select(m, in, r); ok {
		t.Fatal("every table holds its ceiling: nothing to pick")
	}
	if !FullOfFleet(m, in) {
		t.Fatal("FullOfFleet should say the fleet is simply big enough")
	}
	// A stack nothing admits is not "full of the fleet".
	broke := in
	broke.Chips = 100
	if FullOfFleet(m, broke) {
		t.Fatal("a broke bot is not refused for want of room")
	}
	// No ceiling: never full.
	open := in
	open.Fleet = FleetLayout{Default: [2]int{30, 0}}
	if FullOfFleet(m, open) {
		t.Fatal("without a ceiling nothing is full")
	}
}

func TestATableUnderItsFloorIsChosenFirst(t *testing.T) {
	m := liveMenu()
	r := rng.New(11)
	// A CAUTIOUS bot leans to low stakes; the floor still sends it to the
	// one table the fleet is short at, a 50,000 one.
	held := map[string]int{"seen:200": 40, "blind:200": 38, "seen:50000": 35, "blind:50000": 12, "variation:50000": 31}
	for range 500 {
		c, ok := Select(m, SelectInput{
			Chips: 1_000_000, Personality: persona(strategy.Cautious, 0.1, 0.5), BootsToSit: 20,
			Only: fiveTables, Held: held, Fleet: FleetLayout{Default: [2]int{30, 50}},
		}, r)
		if !ok || c.Key != "blind:50000" {
			t.Fatalf("the table under its floor goes first, got %s %v", c.Key, ok)
		}
	}
	// A bot that cannot afford the short table is not sent there: it
	// chooses among those it can sit at.
	for range 200 {
		c, ok := Select(m, SelectInput{
			Chips: 100_000, Personality: persona(strategy.Cautious, 0.1, 0.5), BootsToSit: 20,
			Only: fiveTables, Held: held, Fleet: FleetLayout{Default: [2]int{30, 50}},
		}, r)
		if !ok || (c.Key != "seen:200" && c.Key != "blind:200") {
			t.Fatalf("1 Lakh sits at a 200 table, got %s %v", c.Key, ok)
		}
	}
}

// The owner's layout of 30 Sep 2026: "add some bots which plays blind 50000,
// blind 200 also" — more of the fleet at Blind 200 and Blind 50,000 than at
// the other three tables, each lobby table with its own floor and ceiling.
var ownersLayout = FleetLayout{
	Default: [2]int{30, 50},
	ByTable: map[string][2]int{"blind:200": {50, 80}, "blind:50000": {50, 80}},
}

func TestAFleetLayoutGivesEachTableItsOwnSizeAndTheRestTheDefault(t *testing.T) {
	for key, want := range map[string][2]int{
		"blind:200": {50, 80}, "blind:50000": {50, 80},
		"seen:200": {30, 50}, "seen:50000": {30, 50}, "variation:50000": {30, 50},
		"blind:5000": {30, 50}, // a table the layout does not name takes the default
	} {
		if f, c := ownersLayout.For(key); [2]int{f, c} != want {
			t.Errorf("%s: %d-%d, want %v", key, f, c, want)
		}
	}
	if f, c := (FleetLayout{}).For("seen:200"); f != 0 || c != 0 {
		t.Errorf("the zero layout is %d-%d: want no floor and no ceiling", f, c)
	}
	// A table's own 0-0 takes it out of the default band.
	free := FleetLayout{Default: [2]int{30, 50}, ByTable: map[string][2]int{"seen:200": {0, 0}}}
	if f, c := free.For("seen:200"); f != 0 || c != 0 {
		t.Errorf("seen:200 with its own 0-0 is %d-%d", f, c)
	}
}

func TestATableBelowItsOwnFloorIsChosenFirstWhileOneAtTheDefaultFloorIsNot(t *testing.T) {
	m := liveMenu()
	r := rng.New(13)
	// Blind 200 holds 45 — above the default floor of 30, below its own 50 —
	// and every other table is at or above its floor (Blind 50,000 above its
	// own 50; seen:200 AT the default 30, which is not under it). A CAUTIOUS
	// bot leaning to the other low stake still goes to Blind 200.
	held := map[string]int{"seen:200": 30, "seen:50000": 30, "blind:200": 45, "blind:50000": 60, "variation:50000": 30}
	for range 500 {
		c, ok := Select(m, SelectInput{
			Chips: 1_000_000, Personality: persona(strategy.Cautious, 0.1, 0.5), BootsToSit: 20,
			Only: fiveTables, Held: held, Fleet: ownersLayout,
		}, r)
		if !ok || c.Key != "blind:200" {
			t.Fatalf("the one table under its own floor is blind:200, got %s %v", c.Key, ok)
		}
	}
	// Under the default alone Blind 200's 45 is not short: nothing is under
	// 30, so there is no short list and the bot spreads across the five
	// (Blind 50,000 brought under the default ceiling of 50 to stay open).
	held["blind:50000"] = 45
	picked := map[string]int{}
	for range 3000 {
		c, ok := Select(m, SelectInput{
			Chips: 1_000_000, Personality: persona(strategy.Balanced, r.Float64(), 0.5), BootsToSit: 20,
			Only: fiveTables, Held: held, Fleet: FleetLayout{Default: [2]int{30, 50}},
		}, r)
		if !ok {
			t.Fatal("nothing picked")
		}
		picked[c.Key]++
	}
	for _, k := range fiveTables {
		if picked[k] == 0 {
			t.Errorf("without its own floor blind:200 is not short-listed, yet %s was never picked: %v", k, picked)
		}
	}
	// Two tables under their own floors share the short list; a table under
	// the default floor joins them.
	held = map[string]int{"seen:200": 29, "seen:50000": 40, "blind:200": 49, "blind:50000": 12, "variation:50000": 45}
	short := map[string]int{}
	for range 3000 {
		c, _ := Select(m, SelectInput{
			Chips: 1_000_000, Personality: persona(strategy.Balanced, r.Float64(), 0.5), BootsToSit: 20,
			Only: fiveTables, Held: held, Fleet: ownersLayout,
		}, r)
		short[c.Key]++
	}
	for _, k := range []string{"seen:200", "blind:200", "blind:50000"} {
		if short[k] == 0 {
			t.Errorf("%s is under its floor and was never picked: %v", k, short)
		}
	}
	for _, k := range []string{"seen:50000", "variation:50000"} {
		if short[k] != 0 {
			t.Errorf("%s is at or above its floor and was picked while others were short: %v", k, short)
		}
	}
}

func TestATableAtItsOwnCeilingIsFullWhileOneUnderAHigherCeilingIsChosen(t *testing.T) {
	m := liveMenu()
	r := rng.New(17)
	// Every table holds 50: the default ceiling for three, and under the
	// blind tables' own 80. Only the two blind tables take more.
	held := map[string]int{"seen:200": 50, "seen:50000": 50, "blind:200": 50, "blind:50000": 50, "variation:50000": 50}
	in := SelectInput{
		Chips: 1_000_000, Personality: persona(strategy.Balanced, 0.5, 0.5), BootsToSit: 20,
		Only: fiveTables, Held: held, Fleet: ownersLayout,
	}
	picked := map[string]int{}
	for range 2000 {
		c, ok := Select(m, in, r)
		if !ok || (c.Key != "blind:200" && c.Key != "blind:50000") {
			t.Fatalf("only the blind tables are under their ceilings, got %s %v", c.Key, ok)
		}
		picked[c.Key]++
	}
	if picked["blind:200"] == 0 || picked["blind:50000"] == 0 {
		t.Fatalf("both blind tables have room: %v", picked)
	}
	if FullOfFleet(m, in) {
		t.Fatal("two tables have room: the fleet is not full")
	}
	// Blind 200 at its own 80: Blind 50,000 alone.
	held["blind:200"] = 80
	for range 500 {
		if c, ok := Select(m, in, r); !ok || c.Key != "blind:50000" {
			t.Fatalf("blind:200 holds its 80; want blind:50000, got %s %v", c.Key, ok)
		}
	}
	// Both at 80, the rest at 50: every table at its own ceiling.
	held["blind:50000"] = 80
	if _, ok := Select(m, in, r); ok {
		t.Fatal("every table holds its own ceiling: nothing to pick")
	}
	if !FullOfFleet(m, in) {
		t.Fatal("FullOfFleet should say the fleet is big enough at every table")
	}
	// The same seats under the default alone would have said so at 50.
	held = map[string]int{"seen:200": 50, "seen:50000": 50, "blind:200": 50, "blind:50000": 50, "variation:50000": 50}
	flat := in
	flat.Held, flat.Fleet = held, FleetLayout{Default: [2]int{30, 50}}
	if _, ok := Select(m, flat, r); ok || !FullOfFleet(m, flat) {
		t.Fatal("without their own ceilings the blind tables are full at 50")
	}
	// A table with its own 0-0 has no ceiling: never full.
	open := flat
	open.Fleet = FleetLayout{Default: [2]int{30, 50}, ByTable: map[string][2]int{"variation:50000": {0, 0}}}
	if c, ok := Select(m, open, r); !ok || c.Key != "variation:50000" || FullOfFleet(m, open) {
		t.Fatalf("variation:50000 has no ceiling of its own: got %s %v", c.Key, ok)
	}
}
