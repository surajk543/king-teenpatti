package decision

import (
	"crypto/sha256"
	"fmt"
	"strings"
	"testing"
)

// The server's fingerprint: every 3-card hand of Deck() in index order, as
// "<cards> <score>\n", scored by go-server/internal/game.Evaluate (27 Sep 2026).
const (
	serverRankingSHA256 = "a2095f9d70a85b83527e8e4a39c5533be5bd62c5710bd97f44afe8054fb135e0"
	serverHands         = 22100
)

var serverCategoryCounts = map[int]int{0: 16440, 1: 3744, 2: 1096, 3: 720, 4: 48, 5: 52}

func TestRankingIsTheServers(t *testing.T) {
	var b strings.Builder
	counts := map[int]int{}
	n := 0
	for _, combo := range Combinations3(Deck()) {
		h, err := Rank(combo)
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(&b, "%s%s%s %v\n", combo[0], combo[1], combo[2], h.Score)
		counts[h.Category]++
		n++
	}
	if n != serverHands {
		t.Fatalf("%d hands, want %d", n, serverHands)
	}
	for c, want := range serverCategoryCounts {
		if counts[c] != want {
			t.Errorf("%s: %d hands, the server has %d", CategoryNames[c], counts[c], want)
		}
	}
	if got := fmt.Sprintf("%x", sha256.Sum256([]byte(b.String()))); got != serverRankingSHA256 {
		t.Fatalf("the ranking differs from the server's: fingerprint %s, want %s", got, serverRankingSHA256)
	}
}

func TestTheRankingsKnownOrders(t *testing.T) {
	cases := []struct{ better, worse []string }{
		{[]string{"Ah", "Ad", "Ac"}, []string{"Kh", "Kd", "Kc"}}, // trail over trail
		{[]string{"2h", "2d", "2c"}, []string{"Ah", "Kh", "Qh"}}, // any trail over a pure sequence
		{[]string{"Ah", "Kh", "Qh"}, []string{"Ah", "2h", "3h"}}, // A-K-Q over A-2-3
		{[]string{"As", "2h", "3d"}, []string{"Ks", "Qh", "Jd"}}, // A-2-3 over K-Q-J
		{[]string{"4s", "3h", "2d"}, []string{"As", "Ks", "Js"}}, // any sequence over a colour
		{[]string{"Ks", "Kh", "2d"}, []string{"Qs", "Qh", "Ad"}}, // higher pair first
		{[]string{"As", "Kh", "Jd"}, []string{"As", "Qh", "Jd"}}, // high cards in turn
	}
	for _, c := range cases {
		a, _ := Rank(c.better)
		b, _ := Rank(c.worse)
		if Compare(a, b) <= 0 {
			t.Errorf("%v (%s) should beat %v (%s)", c.better, a.Name, c.worse, b.Name)
		}
	}
	if a, _ := Rank([]string{"As", "Kh", "Qd"}); Percentile(a) <= 0.9 || Percentile(a) >= 1 {
		t.Errorf("A-K-Q off-suit percentile %.3f", Percentile(a))
	}
	if Strength([]string{"Ah", "Ad", "Ac"}) < 0.999 || Strength([]string{"5s", "3h", "2d"}) > 0.005 {
		t.Error("the best and worst hands should sit at the ends")
	}
}

func TestBestThreeKeepsTheFirstOfEqualHands(t *testing.T) {
	best, err := BestThree([]string{"9s", "9h", "2d", "9d", "3c"})
	if err != nil || best.Category != 5 {
		t.Fatalf("a trail of nines among five: %+v %v", best, err)
	}
	// Two equal pairs of kings: the first combination in index order is named.
	best, _ = BestThree([]string{"Ks", "Kh", "4d", "4c", "2s"})
	if strings.Join(best.Cards, ",") != "Ks,Kh,4d" {
		t.Fatalf("named %v", best.Cards)
	}
}
