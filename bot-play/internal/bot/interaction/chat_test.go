package interaction

import (
	"context"
	"fmt"
	"math"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

var t0 = time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)

// always is a configuration where every moment is spoken at.
func always(language string) Config {
	probs := map[Moment][2]float64{}
	for _, m := range Moments() {
		probs[m] = [2]float64{1, 1}
	}
	return Config{Enabled: true, Probabilities: probs, Language: language}
}

func TestEveryMomentHasLinesAndAChance(t *testing.T) {
	all := []Moment{Join, Welcome, Win, BigWin, Loss, BigLoss, NiceHand, StrongHand, BigRaise, PlayingBlind,
		SideshowWon, SideshowLost, Packed, LowChips, Leave, ReplyHi, ReplyName, Variation, FiveCard}
	if len(Moments()) != len(all) || len(lines) != len(all) {
		t.Fatalf("%d moments with chances, %d with lines, %d declared", len(Moments()), len(lines), len(all))
	}
	for _, m := range all {
		p, ok := DefaultProbabilities[m]
		if !ok || p[0] <= 0 || p[1] < p[0] || p[1] > 1 {
			t.Errorf("%s: default chance %v", m, p)
		}
		if len(lines[m].english) < 3 || len(lines[m].hinglish) < 2 {
			t.Errorf("%s: %d English and %d Hinglish lines", m, len(lines[m].english), len(lines[m].hinglish))
		}
	}
	// The brief's ranges.
	brief := map[Moment][2]float64{Join: {0.10, 0.25}, Win: {0.05, 0.15}, Loss: {0.03, 0.10}, Leave: {0.20, 0.40}}
	for m, want := range brief {
		if DefaultProbabilities[m] != want {
			t.Errorf("%s: %v, the brief says %v", m, DefaultProbabilities[m], want)
		}
	}
	if DefaultProbabilities[BigWin][1] <= DefaultProbabilities[Win][1] || DefaultProbabilities[BigLoss][1] <= DefaultProbabilities[Loss][1] {
		t.Error("a big result should draw a word more often than a small one")
	}
	for _, m := range []Moment{ReplyHi, ReplyName} {
		if DefaultProbabilities[m][0] <= DefaultProbabilities[Join][0] || DefaultProbabilities[m][1] <= DefaultProbabilities[Join][1] {
			t.Errorf("%s: a person addressing a bot should get an answer more often than a join does", m)
		}
	}
	// The brief's English lines are all there.
	want := map[Moment][]string{
		Join: {"Hey", "Good luck"}, Win: {"Nice hand", "GG"}, Loss: {"Ahh", "Good one"},
		StrongHand: {"Let's go"}, Leave: {"GG", "Good game"},
	}
	for m, ws := range want {
		for _, w := range ws {
			if !slices.Contains(lines[m].english, w) {
				t.Errorf("%s has no %q", m, w)
			}
		}
	}
}

var botWord = regexp.MustCompile(`(?i)\b(bots?|robot|ai|auto(mated)?|script(ed)?|program)\b`)

func TestEveryLineIsShortNaturalAndNeverSaysBot(t *testing.T) {
	placeholder := regexp.MustCompile(`\{[^{}]*\}`)
	for m, p := range lines {
		seen := map[string]bool{}
		for _, l := range append(append([]string(nil), p.english...), p.hinglish...) {
			if strings.TrimSpace(l) != l || l == "" {
				t.Errorf("%s: %q is blank or padded", m, l)
			}
			if utf8.RuneCountInString(l) > 40 {
				t.Errorf("%s: %q is not a short line", m, l)
			}
			if strings.ContainsAny(l, "\n\r\t") {
				t.Errorf("%s: %q spans lines", m, l)
			}
			if botWord.MatchString(l) {
				t.Errorf("%s: %q gives the game away", m, l)
			}
			for _, ph := range placeholder.FindAllString(l, -1) {
				if ph != "{name}" {
					t.Errorf("%s: %q has an unknown placeholder %s", m, l, ph)
				}
			}
			if seen[l] {
				t.Errorf("%s: %q twice", m, l)
			}
			seen[l] = true
		}
	}
	// Filled with the longest name the server allows and far more, a line is
	// still within the server's 140 characters.
	c := NewChatter(always("mixed"), 1, nil, rng.New(1))
	now := t0
	long := strings.Repeat("Vikramaditya", 20)
	for i := range 500 {
		now = now.Add(time.Minute + time.Second)
		line, ok := c.Maybe(NiceHand, "room", map[string]string{"name": long}, now)
		if !ok {
			t.Fatalf("#%d: nothing said with a certain chance", i)
		}
		if utf8.RuneCountInString(line) > MaxLineLength {
			t.Fatalf("%d characters: %q", utf8.RuneCountInString(line), line)
		}
	}
}

func TestADisabledBotNeverSpeaks(t *testing.T) {
	cfg := always("mixed")
	cfg.Enabled = false
	c := NewChatter(cfg, 1, nil, rng.New(2))
	now := t0
	for _, m := range Moments() {
		for range 200 {
			now = now.Add(2 * time.Minute)
			if line, ok := c.Maybe(m, "room", map[string]string{"name": "Ravi"}, now); ok || line != "" {
				t.Fatalf("a disabled bot said %q", line)
			}
		}
	}
	if (&Config{}).Enabled {
		t.Fatal("the zero configuration is enabled")
	}
}

func TestTheCooldownSpacesABotsLines(t *testing.T) {
	b := NewTableBudget(time.Second, 100)
	c := NewChatter(always("mixed"), 1, b, rng.New(3))
	if _, ok := c.Maybe(Join, "a", nil, t0); !ok {
		t.Fatal("first line refused")
	}
	// Another table, so only the bot's own cooldown can stop it.
	if _, ok := c.Maybe(Join, "b", nil, t0.Add(11*time.Second)); ok {
		t.Fatal("spoke again inside the 12 s cooldown")
	}
	if _, ok := c.Maybe(Join, "b", nil, t0.Add(12*time.Second)); !ok {
		t.Fatal("still quiet once the cooldown was over")
	}
	// A configured cooldown.
	cfg := always("mixed")
	cfg.Cooldown = 30 * time.Second
	c2 := NewChatter(cfg, 1, b, rng.New(4))
	c2.Maybe(Join, "c", nil, t0)
	if _, ok := c2.Maybe(Join, "d", nil, t0.Add(29*time.Second)); ok {
		t.Fatal("spoke inside a 30 s cooldown")
	}
	if _, ok := c2.Maybe(Join, "d", nil, t0.Add(30*time.Second)); !ok {
		t.Fatal("quiet after a 30 s cooldown")
	}
}

func TestNothingIsSpentUnlessALineIsSaid(t *testing.T) {
	b := NewTableBudget(0, 0)
	other := NewChatter(always("mixed"), 1, b, rng.New(5))
	c := NewChatter(always("mixed"), 1, b, rng.New(6))
	if _, ok := other.Maybe(Join, "room", nil, t0); !ok {
		t.Fatal("first line refused")
	}
	// The table's budget refuses c a second later …
	if _, ok := c.Maybe(Join, "room", nil, t0.Add(time.Second)); ok {
		t.Fatal("a second line a second after the first at one table")
	}
	// … which cost c nothing: its cooldown is untouched, so it speaks as soon
	// as the table allows.
	if _, ok := c.Maybe(Join, "room", nil, t0.Add(7*time.Second)); !ok {
		t.Fatal("a refused line spent the bot's cooldown")
	}
	// A moment with no line to say (Welcome, English only, no name given)
	// spends neither the cooldown nor the table.
	quiet := NewChatter(always("english"), 1, b, rng.New(7))
	for range 50 {
		if _, ok := quiet.Maybe(Welcome, "fresh", nil, t0); ok {
			t.Fatal("welcomed nobody")
		}
	}
	if !b.Allows("fresh", t0) {
		t.Fatal("a line never said spent the table's budget")
	}
	if _, ok := quiet.Maybe(Join, "fresh", nil, t0); !ok {
		t.Fatal("a line never said spent the bot's cooldown")
	}
	// A chance that did not come up spends nothing either.
	never := NewChatter(Config{Enabled: true, Probabilities: map[Moment][2]float64{Join: {0, 0}}}, 1, b, rng.New(8))
	for range 100 {
		never.Maybe(Join, "other", nil, t0)
	}
	if !b.Allows("other", t0) || b.Rooms() != 2 {
		t.Fatalf("an unlucky roll spent the budget (%d tables held)", b.Rooms())
	}
}

func TestTheTableBudgetHoldsTheGapAndTheMinute(t *testing.T) {
	b := NewTableBudget(6*time.Second, 6)
	take := func(at time.Duration) bool { return b.Take("room", t0.Add(at)) }
	if !take(0) {
		t.Fatal("first line refused")
	}
	if take(5*time.Second + 999*time.Millisecond) {
		t.Fatal("a line inside the 6 s gap")
	}
	for i := 1; i < 6; i++ {
		if !take(time.Duration(i) * 6 * time.Second) {
			t.Fatalf("line %d refused", i+1)
		}
	}
	// Six in the last minute: the seventh waits, gap or no gap …
	if take(50 * time.Second) {
		t.Fatal("a seventh line inside the minute")
	}
	// … until the first is a minute old.
	if !take(60 * time.Second) {
		t.Fatal("still refused once the first line was a minute old")
	}
	// Tables are rationed apart.
	if !b.Take("another", t0.Add(60*time.Second)) {
		t.Fatal("one table's budget spent another's")
	}
	// A line stamped earlier than the table's last counts against the gap.
	if b.Take("room", t0.Add(59*time.Second)) {
		t.Fatal("a line from a clock running behind jumped the gap")
	}
	// No table, no line.
	if b.Take("", t0) || b.Allows("", t0) {
		t.Fatal("an empty room id has a budget")
	}
	// The defaults.
	d := NewTableBudget(-1, -1)
	if d.gap != DefaultTableGap || d.perMinute != DefaultTablePerMin {
		t.Fatalf("defaults %v, %d", d.gap, d.perMinute)
	}
	// Forget.
	b.Forget("room")
	if !b.Allows("room", t0.Add(61*time.Second)) {
		t.Fatal("a forgotten table is still rationed")
	}
}

func TestTheTableBudgetForgetsQuietTables(t *testing.T) {
	b := NewTableBudget(0, 0)
	const live = 300
	for batch := range 40 {
		now := t0.Add(time.Duration(batch) * 2 * time.Minute)
		for i := range live {
			b.Take(fmt.Sprintf("room-%d-%d", batch, i), now)
			if n := b.Rooms(); n > max(minSweepRooms, 2*live)+1 {
				t.Fatalf("batch %d: holding %d tables with %d live", batch, n, live)
			}
		}
	}
	// A table's own old lines go as it is used.
	b2 := NewTableBudget(time.Second, 100)
	for i := range 1000 {
		b2.Take("room", t0.Add(time.Duration(i)*2*time.Second))
	}
	b2.mu.Lock()
	n := len(b2.rooms["room"])
	b2.mu.Unlock()
	if n > 30 {
		t.Fatalf("a table holds %d lines from its last minute", n)
	}
}

func TestTheTableBudgetIsSafeAndExactUnderContention(t *testing.T) {
	b := NewTableBudget(6*time.Second, 6)
	rooms := []string{"r1", "r2", "r3", "r4"}
	var mu sync.Mutex
	said := map[string][]time.Time{}
	var wg sync.WaitGroup
	for g := range 64 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c := NewChatter(always("mixed"), 1, b, rng.Derive(99, g))
			for i := range 400 {
				room := rooms[(g+i)%len(rooms)]
				now := t0.Add(time.Duration(i)*250*time.Millisecond + time.Duration(g)*time.Millisecond)
				if b.Take(room, now) {
					mu.Lock()
					said[room] = append(said[room], now)
					mu.Unlock()
				}
				c.Maybe(Join, room, nil, now) // chatters on the same budget
				_ = b.Allows(room, now)
				_ = b.Rooms()
			}
		}()
	}
	wg.Wait()
	for room, ts := range said {
		sort.Slice(ts, func(i, j int) bool { return ts[i].Before(ts[j]) })
		for i := 1; i < len(ts); i++ {
			if ts[i].Sub(ts[i-1]) < 6*time.Second {
				t.Fatalf("%s: two lines %v apart", room, ts[i].Sub(ts[i-1]))
			}
			if i >= 6 && ts[i].Sub(ts[i-6]) < time.Minute {
				t.Fatalf("%s: seven lines inside a minute", room)
			}
		}
		if len(ts) == 0 {
			t.Fatalf("%s: nobody could speak", room)
		}
	}
}

func TestABotDoesNotRepeatItself(t *testing.T) {
	for _, lang := range []string{"mixed", "english", "hinglish"} {
		c := NewChatter(always(lang), 1, nil, rng.New(10))
		now := t0
		var said []string
		moments := []Moment{Join, Win, Loss, Leave, BigRaise, Variation}
		for i := range 3000 {
			now = now.Add(61 * time.Second)
			line, ok := c.Maybe(moments[(i/40)%len(moments)], "room", nil, now)
			if !ok {
				t.Fatalf("%s #%d: nothing said with a certain chance", lang, i)
			}
			for j := max(0, len(said)-recentLines); j < len(said); j++ {
				if said[j] == line {
					t.Fatalf("%s: %q again within %d lines", lang, line, len(said)-j)
				}
			}
			said = append(said, line)
		}
	}
	// A pool smaller than the memory still never says the same line twice
	// running (SideshowWon has three English lines).
	c := NewChatter(always("english"), 1, nil, rng.New(11))
	now, last := t0, ""
	for range 500 {
		now = now.Add(61 * time.Second)
		line, ok := c.Maybe(SideshowWon, "room", nil, now)
		if !ok || line == last {
			t.Fatalf("%q after %q (ok=%v)", line, last, ok)
		}
		last = line
	}
}

func TestTheChanceFollowsTheMomentAndTheBot(t *testing.T) {
	const n = 20000
	rate := func(m Moment, chatRate float64, cfg Config, seed uint64) float64 {
		c := NewChatter(cfg, chatRate, nil, rng.New(seed))
		now, said := t0, 0
		for range n {
			now = now.Add(61 * time.Second)
			if _, ok := c.Maybe(m, "room", map[string]string{"name": "Ravi"}, now); ok {
				said++
			}
		}
		return float64(said) / n
	}
	cfg := Config{Enabled: true}
	for _, m := range []Moment{Join, Win, BigWin, Loss, BigLoss, Leave, ReplyHi, ReplyName, Packed} {
		p := DefaultProbabilities[m]
		for _, cr := range []float64{0, 0.5, 1} {
			want := p[0] + (p[1]-p[0])*cr
			got := rate(m, cr, cfg, uint64(100+int(cr*10)))
			tol := 4*math.Sqrt(want*(1-want)/n) + 0.002
			if math.Abs(got-want) > tol {
				t.Errorf("%s at chat rate %.1f: said %.4f of the time, want %.4f ± %.4f", m, cr, got, want, tol)
			}
		}
	}
	// A configured range.
	cfg.Probabilities = map[Moment][2]float64{Join: {0.5, 0.5}, Leave: {0.9, 0.1}}
	if got := rate(Join, 0.2, cfg, 7); math.Abs(got-0.5) > 0.02 {
		t.Errorf("configured 0.5, said %.3f", got)
	}
	c := NewChatter(cfg, 1, nil, rng.New(1))
	if c.Chance(Leave) != 0.9 || c.Chance(Win) != DefaultProbabilities[Win][1] {
		t.Errorf("a reversed range was not righted, or a default was lost: %v, %v", c.Chance(Leave), c.Chance(Win))
	}
	if c.Chance(Moment("nonsense")) != 0 {
		t.Error("an unknown moment has a chance")
	}
	// A quiet bot is quiet; a talkative one talks more.
	quiet, loud := rate(Join, 0, Config{Enabled: true}, 1), rate(Join, 1, Config{Enabled: true}, 1)
	if quiet >= loud {
		t.Errorf("quiet %.3f, talkative %.3f", quiet, loud)
	}
	// Scaled: another bot's hello is answered a tenth as often; scale 0 never.
	cr := 1.0
	scaled := func(scale float64) float64 {
		c := NewChatter(Config{Enabled: true}, cr, nil, rng.New(12))
		now, said := t0, 0
		for range n {
			now = now.Add(61 * time.Second)
			if _, ok := c.MaybeScaled(ReplyHi, "room", nil, now, scale); ok {
				said++
			}
		}
		return float64(said) / n
	}
	if got, want := scaled(0.1), DefaultProbabilities[ReplyHi][1]*0.1; math.Abs(got-want) > 0.01 {
		t.Errorf("scaled by 0.1: %.4f, want %.4f", got, want)
	}
	if got := scaled(0); got != 0 {
		t.Errorf("scaled by 0: %.4f", got)
	}
}

func TestMostMomentsPassInSilence(t *testing.T) {
	// A typical bot over a stream of ordinary table moments.
	c := NewChatter(Config{Enabled: true}, 0.4, nil, rng.New(13))
	now, said, total := t0, 0, 0
	moments := []Moment{Win, Loss, Loss, BigRaise, PlayingBlind, Packed, NiceHand, Variation, FiveCard, StrongHand}
	for i := range 5000 {
		now = now.Add(20 * time.Second)
		total++
		if _, ok := c.Maybe(moments[i%len(moments)], "room", map[string]string{"name": "Ravi"}, now); ok {
			said++
		}
	}
	if share := float64(said) / float64(total); share > 0.1 || said == 0 {
		t.Errorf("spoke at %.3f of moments", share)
	}
}

func TestLanguages(t *testing.T) {
	en := map[string]bool{}
	hi := map[string]bool{}
	for _, m := range Moments() {
		for _, l := range lines[m].english {
			en[strings.ReplaceAll(l, "{name}", "Ravi")] = true
		}
		for _, l := range lines[m].hinglish {
			hi[strings.ReplaceAll(l, "{name}", "Ravi")] = true
		}
	}
	speak := func(lang string, seed uint64) (english, hinglish int) {
		c := NewChatter(always(lang), 1, nil, rng.New(seed))
		now := t0
		for i := range 2000 {
			now = now.Add(61 * time.Second)
			m := Moments()[i%len(Moments())]
			line, ok := c.Maybe(m, "room", map[string]string{"name": "Ravi"}, now)
			if !ok {
				t.Fatalf("%s: nothing said at %s", lang, m)
			}
			switch {
			case slices.Contains(Lines(m, "english"), strings.ReplaceAll(line, "Ravi", "{name}")):
				english++
			case slices.Contains(Lines(m, "hinglish"), strings.ReplaceAll(line, "Ravi", "{name}")):
				hinglish++
			default:
				t.Fatalf("%s: %q is not a line of %s", lang, line, m)
			}
		}
		return english, hinglish
	}
	if e, h := speak("english", 1); h != 0 || e == 0 {
		t.Errorf("english only: %d English, %d Hinglish", e, h)
	}
	if e, h := speak("hinglish", 1); e != 0 || h == 0 {
		t.Errorf("hinglish only: %d English, %d Hinglish", e, h)
	}
	for _, lang := range []string{"mixed", "", "MIXED", "klingon"} {
		if e, h := speak(lang, 2); e < 200 || h < 200 {
			t.Errorf("%q: %d English, %d Hinglish — not mixed", lang, e, h)
		}
	}
	// Under mixed, each bot leans its own way.
	var shares []float64
	for seed := range uint64(20) {
		e, h := speak("mixed", seed+100)
		shares = append(shares, float64(e)/float64(e+h))
	}
	sort.Float64s(shares)
	if shares[len(shares)-1]-shares[0] < 0.3 {
		t.Errorf("every bot mixes the same way: %.2f … %.2f", shares[0], shares[len(shares)-1])
	}
	for _, s := range []string{"", "mixed", "english", "EN", "hinglish"} {
		if !ValidLanguage(s) {
			t.Errorf("%q refused", s)
		}
	}
	if ValidLanguage("french") {
		t.Error("french accepted")
	}
	if got := Lines(Join, "mixed"); len(got) != len(lines[Join].english)+len(lines[Join].hinglish) {
		t.Errorf("mixed Join lines: %d", len(got))
	}
	// Lines hands out a copy.
	l := Lines(Join, "english")
	l[0] = "changed"
	if lines[Join].english[0] == "changed" {
		t.Error("Lines exposes the table")
	}
}

func TestPlaceholders(t *testing.T) {
	c := NewChatter(always("mixed"), 1, nil, rng.New(14))
	now := t0
	named := 0
	for range 1000 {
		now = now.Add(61 * time.Second)
		line, ok := c.Maybe(Welcome, "room", map[string]string{"name": "  Ravi \n Kumar "}, now)
		if !ok {
			t.Fatal("nothing said")
		}
		if strings.ContainsAny(line, "{}\n") {
			t.Fatalf("unfilled or multi-line: %q", line)
		}
		if strings.Contains(line, "Ravi Kumar") {
			named++
		}
	}
	if named < 700 {
		t.Errorf("only %d of 1000 welcomes named the player", named)
	}
	// Without a name only the lines that need none are said.
	c2 := NewChatter(always("mixed"), 1, nil, rng.New(15))
	for range 1000 {
		now = now.Add(61 * time.Second)
		line, ok := c2.Maybe(NiceHand, "room", map[string]string{"name": " "}, now)
		if !ok {
			t.Fatal("nothing said")
		}
		if strings.Contains(line, "{") || strings.HasPrefix(line, " ") || strings.HasSuffix(line, " ") {
			t.Fatalf("%q", line)
		}
	}
	if line, ok := fill("gg {name} and {other}", map[string]string{"name": "A", "other": "B"}); !ok || line != "gg A and B" {
		t.Errorf("fill: %q, %v", line, ok)
	}
	if _, ok := fill("gg {other}", map[string]string{"name": "A"}); ok {
		t.Error("filled a placeholder with nothing")
	}
	if line, ok := fill("unbalanced {name", nil); !ok || line != "unbalanced {name" {
		t.Errorf("an unclosed brace: %q, %v", line, ok)
	}
}

func TestTheSameSeedSaysTheSameThings(t *testing.T) {
	run := func(seed uint64) []string {
		c := NewChatter(Config{Enabled: true}, 0.8, nil, rng.New(seed))
		now := t0
		var out []string
		for i := range 3000 {
			now = now.Add(7 * time.Second)
			line, ok := c.Maybe(Moments()[i%len(Moments())], fmt.Sprintf("r%d", i%3), map[string]string{"name": "Ravi"}, now)
			out = append(out, fmt.Sprint(ok, line))
		}
		return out
	}
	a, b, c := run(5), run(5), run(6)
	if !slices.Equal(a, b) {
		t.Fatal("the same seed said different things")
	}
	if slices.Equal(a, c) {
		t.Fatal("two seeds said exactly the same things")
	}
}

func TestNoRoomNoWords(t *testing.T) {
	c := NewChatter(always("mixed"), 1, nil, rng.New(16))
	if _, ok := c.Maybe(Join, "", nil, t0); ok {
		t.Fatal("spoke at no table")
	}
	if _, ok := c.Maybe(Moment("unheard"), "room", nil, t0); ok {
		t.Fatal("spoke at an unknown moment")
	}
	// A nil stream and budget still work.
	d := NewChatter(always("mixed"), 1, nil, nil)
	if _, ok := d.Maybe(Join, "room", nil, t0); !ok {
		t.Fatal("a chatter with no stream given said nothing")
	}
}

func TestResultMomentHeardAndFirstName(t *testing.T) {
	cases := []struct {
		won       bool
		pot, boot int64
		want      Moment
	}{
		{true, 2400, 200, BigWin}, {true, 2399, 200, Win}, {false, 2400, 200, BigLoss},
		{false, 1000, 200, Loss}, {true, 1_000_000, 0, Win},
	}
	for _, c := range cases {
		if got := ResultMoment(c.won, c.pot, c.boot); got != c.want {
			t.Errorf("won=%v pot=%d boot=%d: %s, want %s", c.won, c.pot, c.boot, got, c.want)
		}
	}
	heard := []struct {
		text, name string
		want       Moment
		ok         bool
	}{
		{"hi all", "Ravi Kumar", ReplyHi, true},
		{"HIIII", "Ravi", ReplyHi, true},
		{"namaste ji", "Ravi", ReplyHi, true},
		{"ravi kya kar raha hai", "Ravi Kumar", ReplyName, true},
		{"hey Ravi", "Ravi", ReplyName, true},
		{"this is high", "Ravi", "", false},
		{"nice hand", "Ravi", "", false},
		{"dev bhai", "Dev", ReplyName, true},
		{"al is here", "Al", "", false}, // a two-letter name is too easily a word
	}
	for _, h := range heard {
		got, ok := Heard(h.text, h.name)
		if got != h.want || ok != h.ok {
			t.Errorf("Heard(%q, %q) = %q, %v; want %q, %v", h.text, h.name, got, ok, h.want, h.ok)
		}
	}
	for in, want := range map[string]string{"Ravi Kumar": "Ravi", "Ravi, ": "Ravi", "Guest8D049": "Guest8D049", "  ": "", "...": "..."} {
		if got := FirstName(in); got != want {
			t.Errorf("FirstName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseProbabilities(t *testing.T) {
	got, err := ParseProbabilities(map[string][2]float64{"join": {0.2, 0.3}, " Big_Win ": {0, 1}})
	if err != nil {
		t.Fatal(err)
	}
	if got[Join] != [2]float64{0.2, 0.3} || got[BigWin] != [2]float64{0, 1} {
		t.Errorf("parsed %v", got)
	}
	if got, err := ParseProbabilities(nil); got != nil || err != nil {
		t.Errorf("nothing configured: %v, %v", got, err)
	}
	_, err = ParseProbabilities(map[string][2]float64{"joinn": {0, 0.1}, "win": {0.3, 0.2}, "loss": {0, 1.5}})
	if err == nil {
		t.Fatal("bad probabilities accepted")
	}
	for _, want := range []string{`"joinn"`, "win", "loss"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("%q does not name %s", err, want)
		}
	}
}

func TestNoEmotes(t *testing.T) {
	var e Emoter = NoEmotes{}
	if err := e.Emote(context.Background(), Win); err != nil {
		t.Fatal(err)
	}
}
