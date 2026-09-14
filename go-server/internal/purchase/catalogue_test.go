package purchase

import "testing"

// A chip, diamond or hammer pack fills exactly one wallet, and says so with a
// positive figure; a premium package fills three — chips, missiles and hammers,
// all positive, and no diamonds. The gateway branches on these figures (a
// premium package down the chip path, never the hammer-only one), so a product
// of any other shape would credit the wrong wallet or nothing at all.
func TestEveryPackFillsOneWalletAndEveryPremiumPackageFillsThree(t *testing.T) {
	for id, p := range Catalogue {
		if p.ID != id {
			t.Errorf("%s: ID %q does not match its key", id, p.ID)
		}
		positive := 0
		for _, n := range []int64{p.Chips, p.Diamonds, p.Hammers, p.Missiles} {
			if n > 0 {
				positive++
			}
			if n < 0 {
				t.Errorf("%s: a negative figure in %+v", id, p)
			}
		}
		switch {
		case p.Premium():
			if p.Chips <= 0 || p.Missiles <= 0 || p.Hammers <= 0 || p.Diamonds != 0 {
				t.Errorf("%s: a premium package must carry chips, missiles and hammers and no diamonds: %+v", id, p)
			}
		case positive != 1 || p.Missiles != 0:
			t.Errorf("%s: chips %d, diamonds %d, hammers %d, missiles %d — want exactly one positive, and never missiles alone",
				id, p.Chips, p.Diamonds, p.Hammers, p.Missiles)
		}
		if p.Rupees <= 0 {
			t.Errorf("%s: rupees %d", id, p.Rupees)
		}
	}
}

// The premium packages the owner set on 14 Sep 2026 (1 Crore = 1,00,00,000
// chips) — and nothing else sells missiles.
func TestThePremiumPackagesAreTheOwnersShelf(t *testing.T) {
	want := map[string]Product{
		"premium_1_9999":  {Pack: "P1", Rupees: 9999, Chips: 6_500_000_000, Missiles: 1, Hammers: 10},
		"premium_2_14999": {Pack: "P2", Rupees: 14999, Chips: 10_500_000_000, Missiles: 2, Hammers: 15},
		"premium_3_19999": {Pack: "P3", Rupees: 19999, Chips: 15_000_000_000, Missiles: 4, Hammers: 21},
		"premium_4_29999": {Pack: "P4", Rupees: 29999, Chips: 25_000_000_000, Missiles: 6, Hammers: 30},
		"premium_5_49999": {Pack: "P5", Rupees: 49999, Chips: 47_500_000_000, Missiles: 11, Hammers: 45},
		"premium_6_99999": {Pack: "P6", Rupees: 99999, Chips: 105_000_000_000, Missiles: 50, Hammers: 100},
	}
	for id, w := range want {
		p, err := Lookup(id)
		if err != nil {
			t.Fatalf("%s: %v", id, err)
		}
		w.ID = id
		if p != w {
			t.Errorf("%s: %+v, want %+v", id, p, w)
		}
		if !p.Premium() {
			t.Errorf("%s is not reported as a premium package", id)
		}
	}
	for id, p := range Catalogue {
		if _, onShelf := want[id]; !onShelf && (p.Missiles > 0 || p.Premium()) {
			t.Errorf("%s sells missiles or a premium package but is not on the owner's shelf: %+v", id, p)
		}
	}
	if len(Catalogue) != 9+4+4+6 {
		t.Errorf("the catalogue holds %d products, want 23 (9 chip, 4 diamond, 4 hammer, 6 premium)", len(Catalogue))
	}
	if _, err := Lookup("premium_7_1"); err == nil {
		t.Error("an unknown premium id must be refused, not defaulted")
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
		if p.Diamonds != w[0] || int64(p.Rupees) != w[1] || p.Chips != 0 || p.Hammers != 0 || p.Missiles != 0 {
			t.Errorf("%s: %+v, want %d diamonds for ₹%d", id, p, w[0], w[1])
		}
	}
	if _, err := Lookup("diamonds_1000_1"); err == nil {
		t.Error("an unknown diamond id must be refused, not defaulted")
	}
}

// The hammer shelf the owner set on 13 Sep 2026: 20 for ₹300, 50 for ₹699,
// 100 for ₹1,299 and 250 for ₹2,999 — and nothing else sells hammers alone
// (a premium package sells them beside its chips and missiles).
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
		if p.Hammers != w[0] || int64(p.Rupees) != w[1] || p.Chips != 0 || p.Diamonds != 0 || p.Missiles != 0 {
			t.Errorf("%s: %+v, want %d hammers for ₹%d", id, p, w[0], w[1])
		}
		if p.Premium() {
			t.Errorf("%s: a hammer pack is reported as a premium package", id)
		}
	}
	for id, p := range Catalogue {
		if _, onShelf := want[id]; p.Hammers > 0 && !onShelf && !p.Premium() {
			t.Errorf("%s sells %d hammers but is not on the owner's shelf", id, p.Hammers)
		}
	}
	if _, err := Lookup("hammers_1000_1"); err == nil {
		t.Error("an unknown hammer id must be refused, not defaulted")
	}
}
