package table

import (
	"math"
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
