package purchase

import "testing"

// Every product fills exactly one wallet, and says so with a positive figure:
// the gateway branches on Diamonds > 0 and Hammers > 0, so a product with two
// (or none) would credit the wrong wallet or nothing at all.
func TestEveryProductFillsExactlyOneWallet(t *testing.T) {
	for id, p := range Catalogue {
		if p.ID != id {
			t.Errorf("%s: ID %q does not match its key", id, p.ID)
		}
		positive := 0
		for _, n := range []int64{p.Chips, p.Diamonds, p.Hammers} {
			if n > 0 {
				positive++
			}
			if n < 0 {
				t.Errorf("%s: a negative figure in %+v", id, p)
			}
		}
		if positive != 1 {
			t.Errorf("%s: chips %d, diamonds %d, hammers %d — want exactly one positive", id, p.Chips, p.Diamonds, p.Hammers)
		}
		if p.Rupees <= 0 {
			t.Errorf("%s: rupees %d", id, p.Rupees)
		}
	}
}

// The diamond shelf the owner set on 13 Sep 2026.
func TestTheDiamondPacksAreTheOwnersShelf(t *testing.T) {
	want := map[string][2]int64{ // id → {diamonds, rupees}
		"diamonds_1_49":     {1, 49},
		"diamonds_5_199":    {5, 199},
		"diamonds_20_699":   {20, 699},
		"diamonds_100_2999": {100, 2999},
	}
	for id, w := range want {
		p, err := Lookup(id)
		if err != nil {
			t.Fatalf("%s: %v", id, err)
		}
		if p.Diamonds != w[0] || int64(p.Rupees) != w[1] || p.Chips != 0 || p.Hammers != 0 {
			t.Errorf("%s: %+v, want %d diamonds for ₹%d", id, p, w[0], w[1])
		}
	}
	if _, err := Lookup("diamonds_1000_1"); err == nil {
		t.Error("an unknown diamond id must be refused, not defaulted")
	}
}

// The hammer shelf the owner set on 13 Sep 2026: 20 for ₹300, 50 for ₹699,
// 100 for ₹1,299 and 250 for ₹2,999 — and nothing else sells hammers.
func TestTheHammerPacksAreTheOwnersShelf(t *testing.T) {
	want := map[string][2]int64{ // id → {hammers, rupees}
		"hammers_20_300":   {20, 300},
		"hammers_50_699":   {50, 699},
		"hammers_100_1299": {100, 1299},
		"hammers_250_2999": {250, 2999},
	}
	for id, w := range want {
		p, err := Lookup(id)
		if err != nil {
			t.Fatalf("%s: %v", id, err)
		}
		if p.Hammers != w[0] || int64(p.Rupees) != w[1] || p.Chips != 0 || p.Diamonds != 0 {
			t.Errorf("%s: %+v, want %d hammers for ₹%d", id, p, w[0], w[1])
		}
	}
	for id, p := range Catalogue {
		if _, onShelf := want[id]; p.Hammers > 0 && !onShelf {
			t.Errorf("%s sells %d hammers but is not on the owner's shelf", id, p.Hammers)
		}
	}
	if _, err := Lookup("hammers_1000_1"); err == nil {
		t.Error("an unknown hammer id must be refused, not defaulted")
	}
}
