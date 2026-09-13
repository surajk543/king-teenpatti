package purchase

import "testing"

// Every product fills exactly one wallet, and says so with a positive figure:
// the gateway branches on Diamonds > 0, so a product with both (or neither)
// would credit the wrong wallet or nothing at all.
func TestEveryProductFillsExactlyOneWallet(t *testing.T) {
	for id, p := range Catalogue {
		if p.ID != id {
			t.Errorf("%s: ID %q does not match its key", id, p.ID)
		}
		if (p.Chips > 0) == (p.Diamonds > 0) {
			t.Errorf("%s: chips %d, diamonds %d — want exactly one positive", id, p.Chips, p.Diamonds)
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
		if p.Diamonds != w[0] || int64(p.Rupees) != w[1] || p.Chips != 0 {
			t.Errorf("%s: %+v, want %d diamonds for ₹%d", id, p, w[0], w[1])
		}
	}
	if _, err := Lookup("diamonds_1000_1"); err == nil {
		t.Error("an unknown diamond id must be refused, not defaulted")
	}
}
