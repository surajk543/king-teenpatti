package strategy

import (
	"math"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// unitTraits are a personality's 0..1 traits beside their profile ranges.
func unitTraits(p Personality, prof Profile) map[string][2]any {
	return map[string][2]any{
		"tightness":      {p.Tightness, prof.Tightness},
		"aggression":     {p.Aggression, prof.Aggression},
		"blind_rate":     {p.BlindRate, prof.BlindRate},
		"blind_love":     {p.BlindLove, prof.BlindLove},
		"bluff":          {p.Bluff, prof.Bluff},
		"mistake":        {p.Mistake, prof.Mistake},
		"noise":          {p.Noise, prof.Noise},
		"adapt":          {p.Adapt, prof.Adapt},
		"sideshow_rate":  {p.SideshowRate, prof.SideshowRate},
		"show_rate":      {p.ShowRate, prof.ShowRate},
		"chat_rate":      {p.ChatRate, prof.ChatRate},
		"pace":           {p.Pace, prof.Pace},
		"distracted":     {p.Distracted, prof.Distracted},
		"stake_appetite": {p.StakeAppetite, prof.StakeAppetite},
		"table_moves":    {p.TableMoves, prof.TableMoves},
		"stop_loss":      {p.StopLossBoots, prof.StopLossBoots},
		"take_profit":    {p.TakeProfitBoots, prof.TakeProfitBoots},
	}
}

func TestEveryFamilyHasSaneRanges(t *testing.T) {
	for _, kind := range Kinds {
		prof, ok := DefaultProfiles[kind]
		if !ok {
			t.Fatalf("%s has no default profile", kind)
		}
		for name, v := range unitTraits(Personality{}, prof) {
			g := v[1].(Range)
			if g.Lo > g.Hi || g.Lo < 0 {
				t.Errorf("%s %s: bad range %v", kind, name, g)
			}
			if !strings.HasPrefix(name, "stop") && !strings.HasPrefix(name, "take") && g.Hi > 1 {
				t.Errorf("%s %s: %v leaves 0..1", kind, name, g)
			}
		}
		if prof.HandsAtTable[0] < 1 || prof.HandsAtTable[0] > prof.HandsAtTable[1] {
			t.Errorf("%s hands at table %v", kind, prof.HandsAtTable)
		}
		if prof.SessionMinutes.Lo <= 0 || prof.SessionMinutes.Lo > prof.SessionMinutes.Hi {
			t.Errorf("%s session minutes %v", kind, prof.SessionMinutes)
		}
	}
}

// The brief's blind-play ranges (§10).
func TestBlindRateRangesAreTheBriefs(t *testing.T) {
	want := map[Kind]Range{
		Cautious:   {0.20, 0.35},
		Balanced:   {0.35, 0.50},
		Aggressive: {0.45, 0.65},
		Beginner:   {0.30, 0.55},
	}
	for kind, w := range want {
		if got := DefaultProfiles[kind].BlindRate; got != w {
			t.Errorf("%s blind rate %v, the brief says %v", kind, got, w)
		}
	}
	for _, kind := range []Kind{Loose, Random} {
		g := DefaultProfiles[kind].BlindRate
		if g.Lo < 0.2 || g.Hi > 0.7 {
			t.Errorf("%s blind rate %v is not a plausible range", kind, g)
		}
	}
}

func TestAPersonalityIsDrawnInsideItsFamilysRanges(t *testing.T) {
	r := rng.New(1)
	for _, kind := range Kinds {
		prof := DefaultProfiles[kind]
		for i := 0; i < 300; i++ {
			p := NewPersonality(kind, nil, r)
			if p.Kind != kind {
				t.Fatalf("drew %s for %s", p.Kind, kind)
			}
			for name, v := range unitTraits(p, prof) {
				x, g := v[0].(float64), v[1].(Range)
				if x < g.Lo || x > g.Hi {
					t.Fatalf("%s %s = %v outside %v", kind, name, x, g)
				}
			}
			h := p.HandsAtTable
			if h[0] < prof.HandsAtTable[0] || h[1] > prof.HandsAtTable[1] || h[0] > h[1] {
				t.Fatalf("%s hands at table %v outside %v", kind, h, prof.HandsAtTable)
			}
			s := p.SessionMinutes
			if s[0] < prof.SessionMinutes.Lo || s[1] > prof.SessionMinutes.Hi || s[0] > s[1] {
				t.Fatalf("%s session %v outside %v", kind, s, prof.SessionMinutes)
			}
		}
	}
}

func TestBotsOfOneFamilyAreAlikeButNotTheSame(t *testing.T) {
	for _, kind := range Kinds {
		g := DefaultProfiles[kind].BlindRate
		lo, hi := math.Inf(1), math.Inf(-1)
		seen := map[float64]bool{}
		for i := 0; i < 50; i++ {
			p := NewPersonality(kind, nil, rng.Derive(99, i))
			lo, hi = math.Min(lo, p.BlindRate), math.Max(hi, p.BlindRate)
			seen[p.Aggression] = true
		}
		span := g.Hi - g.Lo
		if hi-lo < 0.6*span {
			t.Errorf("%s: 50 bots' blind rates span only %.3f..%.3f of %v", kind, lo, hi, g)
		}
		if len(seen) < 50 {
			t.Errorf("%s: two bots drew the same aggression", kind)
		}
	}
}

// The families are told apart by their traits: the middle of each range.
func TestFamiliesAreRecognisablyDifferent(t *testing.T) {
	c, b, a, l, rnd, beg := median(Cautious), median(Balanced), median(Aggressive), median(Loose), median(Random), median(Beginner)
	checks := []struct {
		what string
		ok   bool
	}{
		{"cautious is the tightest", c.Tightness > b.Tightness && c.Tightness > a.Tightness && c.Tightness > l.Tightness},
		{"loose is the loosest", l.Tightness < a.Tightness && l.Tightness < b.Tightness && l.Tightness < beg.Tightness},
		{"aggressive raises most", a.Aggression > b.Aggression && b.Aggression > c.Aggression && a.Aggression > l.Aggression},
		{"aggressive bluffs most, cautious least", a.Bluff > b.Bluff && b.Bluff > c.Bluff},
		{"aggressive plays blind most, cautious least", a.BlindRate > b.BlindRate && b.BlindRate > c.BlindRate},
		{"balanced adapts most", b.Adapt > c.Adapt && b.Adapt > a.Adapt && b.Adapt > beg.Adapt && b.Adapt > rnd.Adapt},
		{"random is the noisiest", rnd.Noise > beg.Noise && beg.Noise > l.Noise && l.Noise > c.Noise},
		{"beginners make the most mistakes", beg.Mistake > rnd.Mistake && beg.Mistake > l.Mistake && beg.Mistake > a.Mistake && beg.Mistake > c.Mistake},
		{"cautious sits low, aggressive high", c.StakeAppetite < b.StakeAppetite && b.StakeAppetite < a.StakeAppetite},
		{"cautious stays, aggressive moves", c.TableMoves < b.TableMoves && b.TableMoves < a.TableMoves},
		{"beginners think slowest, aggressive fastest", beg.Pace > b.Pace && b.Pace > a.Pace},
	}
	for _, ch := range checks {
		if !ch.ok {
			t.Errorf("not so: %s", ch.what)
		}
	}
}

func TestNewPersonalityIsDeterministic(t *testing.T) {
	for _, kind := range Kinds {
		a := NewPersonality(kind, nil, rng.New(42))
		b := NewPersonality(kind, nil, rng.New(42))
		if a != b {
			t.Fatalf("%s: the same seed drew %+v and %+v", kind, a, b)
		}
		if c := NewPersonality(kind, nil, rng.New(43)); c == a {
			t.Fatalf("%s: different seeds drew the same personality", kind)
		}
	}
}

func TestAnUnknownKindPlaysBalanced(t *testing.T) {
	p := NewPersonality(Kind("SHARK"), nil, rng.New(1))
	if p.Kind != Balanced {
		t.Fatalf("kind %s, want BALANCED", p.Kind)
	}
	// A kind missing from the given profiles falls back to its default.
	q := NewPersonality(Aggressive, map[Kind]Profile{}, rng.New(1))
	if q.Kind != Aggressive || q.Aggression < DefaultProfiles[Aggressive].Aggression.Lo {
		t.Fatalf("fallback drew %+v", q)
	}
}

func TestParseKind(t *testing.T) {
	for in, want := range map[string]Kind{"cautious": Cautious, " Beginner ": Beginner, "AGGRESSIVE": Aggressive, "rAnDoM": Random} {
		got, err := ParseKind(in)
		if err != nil || got != want {
			t.Errorf("ParseKind(%q) = %s, %v", in, got, err)
		}
	}
	if _, err := ParseKind("shark"); err == nil || !strings.Contains(err.Error(), "shark") {
		t.Errorf("an unknown kind must be an error naming it, got %v", err)
	}
}

func TestPickKindFollowsTheWeights(t *testing.T) {
	r := rng.New(5)
	counts := map[Kind]int{}
	const n = 20000
	for i := 0; i < n; i++ {
		counts[PickKind(map[string]float64{"aggressive": 3, "Cautious": 1, "shark": 50, "loose": 0, "random": -2}, r)]++
	}
	if counts[Loose] != 0 || counts[Random] != 0 || counts[Balanced] != 0 || counts[Beginner] != 0 {
		t.Fatalf("picked an unweighted family: %v", counts)
	}
	if share := float64(counts[Aggressive]) / n; math.Abs(share-0.75) > 0.02 {
		t.Fatalf("aggressive share %.3f, want 0.75", share)
	}
}

func TestPickKindWithNoWeightsIsEven(t *testing.T) {
	for _, w := range []map[string]float64{nil, {}, {"shark": 1}, {"loose": 0}} {
		r := rng.New(6)
		counts := map[Kind]int{}
		const n = 12000
		for i := 0; i < n; i++ {
			counts[PickKind(w, r)]++
		}
		for _, k := range Kinds {
			if share := float64(counts[k]) / n; math.Abs(share-1.0/6) > 0.02 {
				t.Fatalf("weights %v: %s share %.3f, want 1/6", w, k, share)
			}
		}
	}
}

func TestApplyTuningOverridesACopy(t *testing.T) {
	before := DefaultProfiles[Aggressive].BlindRate
	got, err := ApplyTuning(nil, map[string]map[string][2]float64{
		"aggressive": {"blind_rate": {0.5, 0.6}, "Hands_At_Table": {4.4, 9.6}, "stop_loss_boots": {10, 20}},
		"CAUTIOUS":   {"session_minutes": {60, 90}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if g := got[Aggressive].BlindRate; g != (Range{0.5, 0.6}) {
		t.Errorf("blind rate %v", g)
	}
	if g := got[Aggressive].HandsAtTable; g != [2]int{4, 10} {
		t.Errorf("hands at table %v, want rounded [4 10]", g)
	}
	if g := got[Aggressive].StopLossBoots; g != (Range{10, 20}) {
		t.Errorf("stop loss %v", g)
	}
	if g := got[Cautious].SessionMinutes; g != (Range{60, 90}) {
		t.Errorf("session %v", g)
	}
	if got[Balanced] != DefaultProfiles[Balanced] {
		t.Errorf("an untuned family changed")
	}
	if DefaultProfiles[Aggressive].BlindRate != before {
		t.Fatalf("ApplyTuning wrote into DefaultProfiles")
	}
	// Every trait name is accepted.
	for _, name := range TraitNames() {
		v := [2]float64{0.2, 0.4}
		if name == "hands_at_table" || name == "session_minutes" {
			v = [2]float64{2, 4}
		}
		if _, err := ApplyTuning(nil, map[string]map[string][2]float64{"loose": {name: v}}); err != nil {
			t.Errorf("trait %s refused: %v", name, err)
		}
	}
}

func TestApplyTuningNamesWhatItRefuses(t *testing.T) {
	cases := []struct {
		tuning map[string]map[string][2]float64
		names  string
	}{
		{map[string]map[string][2]float64{"shark": {"bluff": {0, 1}}}, "shark"},
		{map[string]map[string][2]float64{"loose": {"courage": {0, 1}}}, "courage"},
		{map[string]map[string][2]float64{"loose": {"bluff": {0.5, 0.2}}}, "bluff"},
		{map[string]map[string][2]float64{"loose": {"tightness": {0.5, 1.2}}}, "tightness"},
		{map[string]map[string][2]float64{"loose": {"stop_loss_boots": {-1, 5}}}, "stop_loss_boots"},
		{map[string]map[string][2]float64{"loose": {"session_minutes": {0, 5}}}, "session_minutes"},
		{map[string]map[string][2]float64{"loose": {"hands_at_table": {0, 5}}}, "hands_at_table"},
		{map[string]map[string][2]float64{"loose": {"noise": {math.NaN(), 0.5}}}, "noise"},
	}
	for _, c := range cases {
		_, err := ApplyTuning(nil, c.tuning)
		if err == nil || !strings.Contains(err.Error(), c.names) {
			t.Errorf("%v: error %v, want one naming %q", c.tuning, err, c.names)
		}
	}
}
