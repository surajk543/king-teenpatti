package config

import (
	"strings"
	"testing"
)

// TestATableTaxesItsWinnersOnlyWhereTheMenuSaysSo: LOBBY_TABLES's tax=1
// (owner, 26 Sep 2026) switches a table's winning tax on, beside its band and
// pot cap; tax=0 or no option leaves it off; any other figure stops the boot,
// since the rate is the winner's own and a figure here would be a promise the
// table does not keep. The switch reaches the public Teen Patti table of that
// pair and nothing else — not the other tables, not a private one, never a
// poker room — with the table-wide minimum winnings beside it, and a catalogue
// row's is held to the same rule.
func TestATableTaxesItsWinnersOnlyWhereTheMenuSaysSo(t *testing.T) {
	tables, err := parseLobbyTables("blind:1000000:min=500000000:tax=1,variation:1000000:tax=0,seen:200,omaha:50000:tax=1")
	if err != nil {
		t.Fatal(err)
	}
	if !tables[0].WinnerTax || tables[0].MinChips != 500000000 || tables[1].WinnerTax || tables[2].WinnerTax || !tables[3].WinnerTax {
		t.Fatalf("parsed %+v", tables)
	}
	for _, bad := range []string{"blind:1000000:tax=2", "blind:1000000:tax=20", "blind:1000000:tax=-1", "blind:1000000:tax=yes", "blind:1000000:tax",
		"blind:1000000:viptax=5"} {
		if _, err := parseLobbyTables(bad); err == nil {
			t.Errorf("%q parsed", bad)
		}
	}
	if _, err := FromEnv(mapLookup(map[string]string{"LOBBY_TABLES": "blind:1000000:tax=20"})); err == nil ||
		!strings.Contains(err.Error(), "LOBBY_TABLES") {
		t.Errorf("a rate in LOBBY_TABLES must stop the boot naming the key, got %v", err)
	}

	g := mustLoad(t, map[string]string{"LOBBY_TABLES": "blind:1000000:tax=1,seen:200,omaha:50000:tax=1", "TABLE_STAKES": "",
		"WINNER_TAX_MIN_WINNINGS": "2500000"}).Game
	if s := g.Spec("blind", 1000000, false); !s.WinnerTax || s.WinnerTaxMinWinnings != 2500000 {
		t.Errorf("the listed table taxes its winners from the table-wide minimum: %+v", s)
	}
	for _, s := range []TableSpec{g.Spec("blind", 1000000, true), g.Spec("seen", 200, false), g.Spec("blind", 5000, false)} {
		if s.WinnerTax || s.WinnerTaxMinWinnings != 0 {
			t.Errorf("a private table, another table and a pair off the menu never tax their winners: %+v", s)
		}
	}
	if s := g.Spec("omaha", 50000, false); s.WinnerTax || s.WinnerTaxMinWinnings != 0 {
		t.Error("a poker room never taxes its winners, whatever its entry says")
	}
	if _, err := FromEnv(mapLookup(map[string]string{"WINNER_TAX_MIN_WINNINGS": "-1"})); err == nil ||
		!strings.Contains(err.Error(), "WINNER_TAX_MIN_WINNINGS") {
		t.Errorf("a negative minimum must stop the boot naming the key, got %v", err)
	}
	if g := mustLoad(t, map[string]string{"LOBBY_TABLES": "seen:200:tax=1", "TABLE_STAKES": "", "WINNER_TAX_MIN_WINNINGS": "0"}).Game; !g.Spec("seen", 200, false).WinnerTax ||
		g.Spec("seen", 200, false).WinnerTaxMinWinnings != 0 {
		t.Error("a minimum of 0 taxes any winnings")
	}

	// The defaults tax every public Seen, Blind and Variation table (owner,
	// 27 Sep 2026: "Apply this tax rule on all the tables, blind, seen,
	// variation"), on winnings of 50 Lakh or more ("no tax for winning amount
	// less than 50 Lakh"); no poker room and no private table.
	d := Defaults().Game
	for _, spec := range d.EffectiveCatalogue().Public {
		want := spec.Engine == EngineTeenPatti
		if spec.WinnerTax != want || (want && spec.WinnerTaxMinWinnings != 5000000) || (!want && spec.WinnerTaxMinWinnings != 0) {
			t.Errorf("%s: winnerTax %v from %d, want %v from 50 Lakh", spec.Key, spec.WinnerTax, spec.WinnerTaxMinWinnings, want)
		}
	}
	for _, spec := range d.EffectiveCatalogue().Private {
		if spec.WinnerTax || spec.WinnerTaxMinWinnings != 0 {
			t.Errorf("the private template %s must not tax its winners", spec.Key)
		}
	}

	// A catalogue row: kept on a Teen Patti table, zeroed on a poker one.
	cat := d.EffectiveCatalogue()
	cat.Source = TableConfigSourceDB
	for i := range cat.Public {
		if cat.Public[i].Category == CategoryOmaha {
			cat.Public[i].WinnerTax, cat.Public[i].WinnerTaxMinWinnings = true, 100
		}
		if cat.Public[i].Key == "seen:200" {
			cat.Public[i].WinnerTax, cat.Public[i].WinnerTaxMinWinnings = false, 100
		}
	}
	for i := range cat.Private {
		cat.Private[i].WinnerTax, cat.Private[i].WinnerTaxMinWinnings = true, 100
	}
	valid, problems, err := cat.Validate()
	if err != nil || len(problems) != 0 {
		t.Fatalf("validate: %v %v", err, problems)
	}
	for _, spec := range valid.Public {
		if spec.Category == CategoryOmaha && (spec.WinnerTax || spec.WinnerTaxMinWinnings != 0) {
			t.Error("a poker row's winner_tax and tax_min_winnings are figures its family does not read: zeroed")
		}
		if spec.Key == "blind:2000000" && (!spec.WinnerTax || spec.WinnerTaxMinWinnings != 5000000) {
			t.Error("a Teen Patti row's winner_tax and tax_min_winnings are kept")
		}
		if spec.Key == "seen:200" && (spec.WinnerTax || spec.WinnerTaxMinWinnings != 0) {
			t.Error("a row that does not tax carries no minimum")
		}
	}
	for _, spec := range valid.Private {
		if spec.WinnerTax || spec.WinnerTaxMinWinnings != 0 {
			t.Errorf("the private template %s never taxes its winners, whatever its row says", spec.Key)
		}
	}
	bad := d.EffectiveCatalogue()
	bad.Source = TableConfigSourceDB
	for i := range bad.Public {
		if bad.Public[i].Key == "blind:5000" {
			bad.Public[i].WinnerTaxMinWinnings = -1
		}
	}
	if valid, problems, err := bad.Validate(); err != nil || len(problems) != 1 || !strings.Contains(problems[0], "tax_min_winnings") {
		t.Errorf("a negative minimum leaves its row out naming the column: %v %+v", err, problems)
	} else {
		for _, spec := range valid.Public {
			if spec.Key == "blind:5000" {
				t.Error("the row with a negative minimum must be left out")
			}
		}
	}

	// SameRules compares it: a table whose switch changed is drained.
	a := d.Spec("blind", 2000000, false)
	b := a
	b.WinnerTax = false
	if a.SameRules(b) {
		t.Error("two specs that differ in winner tax do not play by the same rules")
	}
}
