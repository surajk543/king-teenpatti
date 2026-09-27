package timing

import (
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

var t0 = time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)

func draws(h *HumanDelay, ctx Context, r *rng.Rand, n int) []time.Duration {
	out := make([]time.Duration, n)
	for i := range out {
		out[i] = h.For(ctx, r)
	}
	return out
}

func median(ds []time.Duration) time.Duration {
	s := append([]time.Duration(nil), ds...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	return s[len(s)/2]
}

func mean(ds []time.Duration) time.Duration {
	var sum time.Duration
	for _, d := range ds {
		sum += d
	}
	return sum / time.Duration(len(ds))
}

func TestEveryKindHasADefaultRangeInsideTheBrief(t *testing.T) {
	brief := map[Kind]Range{
		Chaal:       {800, 2500},
		Fold:        {700, 2200},
		SmallRaise:  {1000, 3000},
		LargeRaise:  {1500, 4000},
		Difficult:   {2000, 5000},
		JoinTable:   {1000, 4000},
		LeaveTable:  {1500, 5000},
		SearchTable: {2500, 8000},
	}
	for k, want := range brief {
		if got := DefaultRanges[k]; got != want {
			t.Errorf("%s: default %v, the brief says %v", k, got, want)
		}
	}
	all := []Kind{See, Chaal, BlindChaal, Fold, SmallRaise, LargeRaise, Show, Sideshow, Difficult,
		JoinTable, LeaveTable, SearchTable, Chat, AnswerSideshow, PickVariation, PickCards, LookEarly}
	for _, k := range all {
		rg, ok := DefaultRanges[k]
		if !ok {
			t.Errorf("%s has no default range", k)
			continue
		}
		if rg.MinMs <= 0 || rg.MaxMs <= rg.MinMs {
			t.Errorf("%s: %v is not a window", k, rg)
		}
	}
	if len(DefaultRanges) != len(all) {
		t.Errorf("%d default ranges for %d kinds", len(DefaultRanges), len(all))
	}
	// A glance is quicker than a call; a blind chaal is routine.
	if DefaultRanges[See].MaxMs >= DefaultRanges[Chaal].MaxMs || DefaultRanges[BlindChaal].MaxMs >= DefaultRanges[Chaal].MaxMs {
		t.Error("a look and a blind chaal should be quicker than a call")
	}
}

func TestDrawsStayInsideTheirWindowForEveryKind(t *testing.T) {
	h := New(Config{})
	r := rng.New(1)
	for _, k := range Kinds() {
		lo, hi := h.Bounds(k)
		for i := range 4000 {
			ctx := Context{
				Kind:       k,
				Pace:       r.Float64(),
				Complexity: r.Float64(),
				Strength:   r.Float64(),
				FacedRaise: i%3 == 0,
				IsBlind:    i%4 == 0,
			}
			d := h.For(ctx, r)
			if d < lo || d > hi {
				t.Fatalf("%s: %v outside [%v, %v]", k, d, lo, hi)
			}
		}
	}
}

func TestReactionsAreSkewedQuickWithASlowTail(t *testing.T) {
	h := New(Config{})
	r := rng.New(2)
	for _, k := range Kinds() {
		lo, hi := h.Bounds(k)
		ds := draws(h, Context{Kind: k, Pace: 0.5, Complexity: 0.3, Strength: 0.8}, r, 6000)
		med, avg := median(ds), mean(ds)
		if med >= avg {
			t.Errorf("%s: median %v not below mean %v — not skewed", k, med, avg)
		}
		mid := lo + (hi-lo)/2
		if med >= mid {
			t.Errorf("%s: median %v not in the quick half of [%v, %v]", k, med, lo, hi)
		}
		// Not uniform: the lower half holds well over half the draws, and a
		// few land in the top fifth.
		low, top := 0, 0
		for _, d := range ds {
			if d < mid {
				low++
			}
			if d > hi-(hi-lo)/5 {
				top++
			}
		}
		if float64(low)/float64(len(ds)) < 0.65 {
			t.Errorf("%s: only %d of %d draws in the quick half", k, low, len(ds))
		}
		if top == 0 {
			t.Errorf("%s: no draw in the slow tail", k)
		}
	}
}

func TestDeliberatePlayersAreSlowerThanSnapOnes(t *testing.T) {
	h := New(Config{})
	for _, k := range []Kind{Chaal, LargeRaise, Fold, JoinTable, SearchTable} {
		var meds []time.Duration
		for _, pace := range []float64{0, 0.5, 1} {
			meds = append(meds, median(draws(h, Context{Kind: k, Pace: pace, Strength: 0.9}, rng.New(3), 5000)))
		}
		if !(meds[0] < meds[1] && meds[1] < meds[2]) {
			t.Errorf("%s: medians by pace 0/0.5/1 = %v, want increasing", k, meds)
		}
	}
}

func TestTheDecisionShapesTheReaction(t *testing.T) {
	h := New(Config{})
	base := Context{Kind: Chaal, Pace: 0.5, Complexity: 0.3, Strength: 0.9}
	med := func(c Context) time.Duration { return median(draws(h, c, rng.New(4), 5000)) }

	plain := med(base)
	faced := base
	faced.FacedRaise = true
	if m := med(faced); m <= plain {
		t.Errorf("facing a raise %v, not slower than %v", m, plain)
	}
	blind := base
	blind.IsBlind = true
	if m := med(blind); m >= plain {
		t.Errorf("a blind chaal %v, not quicker than %v", m, plain)
	}
	hard := base
	hard.Complexity = 1
	if m := med(hard); m <= plain {
		t.Errorf("a hard decision %v, not slower than %v", m, plain)
	}
	marginalHand := base
	marginalHand.Strength = 0.5
	clearHand := base
	clearHand.Strength = 1
	if m, c := med(marginalHand), med(clearHand); m <= c {
		t.Errorf("a marginal hand %v, not slower than a clear one %v", m, c)
	}
}

func TestNoDelayIsARoundFigure(t *testing.T) {
	h := New(Config{Ranges: map[Kind]Range{Chat: {2000, 2000}}}) // a window of one round figure
	r := rng.New(5)
	check := func(d time.Duration, what string) {
		t.Helper()
		if d%time.Millisecond == 0 {
			t.Fatalf("%s: %v is a whole number of milliseconds", what, d)
		}
		if d%time.Second == 0 || d%(100*time.Millisecond) == 0 {
			t.Fatalf("%s: %v is a round figure", what, d)
		}
	}
	for _, k := range append(Kinds(), Kind("unheard_of")) {
		for range 3000 {
			check(h.For(Context{Kind: k, Pace: r.Float64(), Distracted: 0.3}, r), string(k))
		}
	}
	// Capped by a deadline, and the last-moment beat.
	for i := range 3000 {
		left := time.Duration(i) * 3 * time.Millisecond
		check(h.For(Context{Kind: LargeRaise, Now: t0, Deadline: t0.Add(left)}, r), "capped")
		check(h.For(Context{Kind: LargeRaise, Now: t0, Deadline: t0.Add(3*time.Second + left)}, r), "capped")
	}
	// The source's zero is a legal draw: the one-figure window still comes out
	// off the round figure.
	z := rng.From(&rng.Script{Values: []float64{0}})
	check(h.For(Context{Kind: Chat}, z), "scripted zero")
}

func TestADelayNeverEatsTheDeadline(t *testing.T) {
	h := New(Config{})
	r := rng.New(6)
	margin := h.SafetyMargin()
	for _, k := range Kinds() {
		for i := range 3000 {
			left := time.Duration(r.Between(3.2, 8) * float64(time.Second))
			ctx := Context{Kind: k, Pace: 1, Complexity: 1, Strength: 0.5, FacedRaise: true, Distracted: 0.5, Now: t0, Deadline: t0.Add(left)}
			d := h.For(ctx, r)
			if d > left-margin {
				t.Fatalf("%s #%d: %v with %v left and a %v margin", k, i, d, left, margin)
			}
			if d < MinBeat {
				t.Fatalf("%s: %v under the minimum beat", k, d)
			}
		}
	}
	// The whole turn clock with a distracted player: the pause fits inside it.
	for range 3000 {
		d := h.For(Context{Kind: Chaal, Distracted: 0.5, Now: t0, Deadline: t0.Add(25 * time.Second)}, r)
		if d > 22*time.Second {
			t.Fatalf("%v past a 25 s clock's 22 s", d)
		}
	}
}

func TestANearDeadlineGetsAShortBeat(t *testing.T) {
	h := New(Config{})
	r := rng.New(7)
	// The margin has already gone: a short beat, still before the deadline.
	for range 2000 {
		left := 3*time.Second + time.Duration(r.Between(0, 140))*time.Millisecond
		d := h.For(Context{Kind: Difficult, Now: t0, Deadline: t0.Add(left)}, r)
		if d < MinBeat || d > 360*time.Millisecond {
			t.Fatalf("%v with %v left: not a short beat", d, left)
		}
		if d >= left {
			t.Fatalf("%v with %v left: past the deadline", d, left)
		}
	}
	// Only a little more than a beat left: still before the deadline.
	for range 2000 {
		left := time.Duration(r.Between(190, 400)) * time.Millisecond
		d := h.For(Context{Kind: Chaal, Now: t0, Deadline: t0.Add(left)}, r)
		if d < MinBeat || d >= left {
			t.Fatalf("%v with %v left", d, left)
		}
	}
	// The deadline is on it (or gone): the beat is the minimum, not zero.
	for _, left := range []time.Duration{100 * time.Millisecond, 0, -time.Second} {
		d := h.For(Context{Kind: Chaal, Now: t0, Deadline: t0.Add(left)}, r)
		if d < MinBeat || d > MinBeat+time.Millisecond {
			t.Fatalf("%v with %v left, want about %v", d, left, MinBeat)
		}
	}
}

func TestADistractedPauseIsRareLongAndHeld(t *testing.T) {
	h := New(Config{})
	r := rng.New(8)
	lo, hi := h.Bounds(Chaal)
	long := 0
	n := 20000
	for range n {
		d := h.For(Context{Kind: Chaal, Distracted: 0.05}, r)
		if d > hi {
			long++
			if d < lo+pauseMin {
				t.Fatalf("a distracted pause of only %v", d)
			}
		}
		if d > DefaultMaxPause {
			t.Fatalf("%v past the %v pause ceiling", d, DefaultMaxPause)
		}
	}
	if share := float64(long) / float64(n); share < 0.035 || share > 0.065 {
		t.Errorf("distracted on %.3f of decisions, want about 0.05", share)
	}
	// Only decisions are interrupted.
	for _, k := range []Kind{See, JoinTable, SearchTable, Chat} {
		_, top := h.Bounds(k)
		for range 3000 {
			if d := h.For(Context{Kind: k, Distracted: 0.5}, r); d > top {
				t.Fatalf("%s: a %v pause", k, d)
			}
		}
	}
	// A configured ceiling holds.
	h2 := New(Config{MaxPause: 6 * time.Second})
	for range 5000 {
		if d := h2.For(Context{Kind: LargeRaise, Distracted: 0.5}, r); d > 6*time.Second {
			t.Fatalf("%v past a 6 s pause ceiling", d)
		}
	}
}

func TestTheSameSeedGivesTheSameDelays(t *testing.T) {
	h := New(Config{})
	ctx := Context{Kind: SmallRaise, Pace: 0.4, Distracted: 0.1, Complexity: 0.6, Strength: 0.55, FacedRaise: true}
	a := draws(h, ctx, rng.New(42), 500)
	b := draws(h, ctx, rng.New(42), 500)
	c := draws(h, ctx, rng.New(43), 500)
	same := true
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("draw %d: %v then %v from the same seed", i, a[i], b[i])
		}
		same = same && a[i] == c[i]
	}
	if same {
		t.Error("two seeds gave the same delays")
	}
}

func TestConfigurationOverridesAndBounds(t *testing.T) {
	h := New(Config{
		Ranges:      map[Kind]Range{Chaal: {1200, 1800}, See: {900, 300}, JoinTable: {6000, 9000}},
		MinReaction: 1000 * time.Millisecond,
		MaxReaction: 3 * time.Second,
	})
	if lo, hi := h.Bounds(Chaal); lo != 1200*time.Millisecond || hi != 1800*time.Millisecond {
		t.Errorf("chaal window [%v, %v]", lo, hi)
	}
	if lo, hi := h.Bounds(See); lo != 300*time.Millisecond || hi != 900*time.Millisecond {
		t.Errorf("a reversed range was not righted: [%v, %v]", lo, hi)
	}
	// Decisions are held inside [MinReaction, MaxReaction]; the rest are not.
	if lo, hi := h.Bounds(Difficult); lo != 2*time.Second || hi != 3*time.Second {
		t.Errorf("difficult window [%v, %v], want [2s, 3s]", lo, hi)
	}
	if lo, _ := h.Bounds(Fold); lo != time.Second {
		t.Errorf("fold floor %v, want the 1 s MinReaction", lo)
	}
	if lo, hi := h.Bounds(JoinTable); lo != 6*time.Second || hi != 9*time.Second {
		t.Errorf("join window [%v, %v]: MaxReaction bounds decisions only", lo, hi)
	}
	// Defaults.
	d := New(Config{})
	if lo, hi := d.Bounds(Difficult); lo != 2*time.Second || hi != 5*time.Second {
		t.Errorf("default difficult window [%v, %v]", lo, hi)
	}
	if lo, _ := d.Bounds(See); lo != 500*time.Millisecond {
		t.Errorf("a glance is floored at %v: MinReaction bounds decisions only", lo)
	}
	if d.SafetyMargin() != 3*time.Second {
		t.Errorf("default margin %v", d.SafetyMargin())
	}
	// Changing the defaults after New changes nothing already built.
	before, _ := d.Bounds(Chaal)
	saved := DefaultRanges[Chaal]
	DefaultRanges[Chaal] = Range{1, 2}
	after, _ := d.Bounds(Chaal)
	DefaultRanges[Chaal] = saved
	if before != after {
		t.Error("a built HumanDelay follows later edits to DefaultRanges")
	}
}

func TestParseRanges(t *testing.T) {
	got, err := ParseRanges(map[string][2]int{"chaal": {900, 2100}, " Search_Table ": {3000, 9000}})
	if err != nil {
		t.Fatal(err)
	}
	if got[Chaal] != (Range{900, 2100}) || got[SearchTable] != (Range{3000, 9000}) {
		t.Errorf("parsed %v", got)
	}
	if got, err := ParseRanges(nil); err != nil || got != nil {
		t.Errorf("nothing configured: %v, %v", got, err)
	}
	_, err = ParseRanges(map[string][2]int{"chall": {1, 2}, "fold": {3000, 2000}, "see": {-1, 5}})
	if err == nil {
		t.Fatal("bad ranges accepted")
	}
	for _, want := range []string{`"chall"`, "fold", "see"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not name %s", err, want)
		}
	}
}

func TestTheConvenienceDelays(t *testing.T) {
	h := New(Config{})
	r := rng.New(9)
	for range 2000 {
		if d := h.Search(r.Float64(), r); d < 2500*time.Millisecond || d > 8*time.Second {
			t.Fatalf("search gap %v", d)
		}
		if d := h.Join(r.Float64(), r); d < time.Second || d > 4*time.Second {
			t.Fatalf("join %v", d)
		}
		if d := h.Leave(r.Float64(), r); d < 1500*time.Millisecond || d > 5*time.Second {
			t.Fatalf("leave %v", d)
		}
		if d := h.ChatPause(r.Float64(), r); d < time.Second || d > 5*time.Second {
			t.Fatalf("chat pause %v", d)
		}
	}
	if !IsDecision(Chaal) || !IsDecision(AnswerSideshow) || IsDecision(See) || IsDecision(Chat) {
		t.Error("IsDecision")
	}
}

func TestADrawThatAlwaysOvershootsStaysInTheWindow(t *testing.T) {
	// A source that makes every log-normal draw enormous: every redraw
	// overshoots and the fallback still lands inside the window.
	h := New(Config{})
	over := rng.From(&rng.Script{Values: []float64{1e-9}})
	lo, hi := h.Bounds(Difficult)
	d := h.For(Context{Kind: Difficult, Pace: 1, Complexity: 1, Strength: 0.5, FacedRaise: true}, over)
	if d < lo || d > hi {
		t.Fatalf("%v outside [%v, %v]", d, lo, hi)
	}
}
