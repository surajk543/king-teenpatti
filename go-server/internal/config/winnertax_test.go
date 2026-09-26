package config

import (
	"strings"
	"testing"
)

// TestATableTaxesItsWinnersOnlyWhereTheMenuSaysSo: LOBBY_TABLES's tax=1
// (owner, 26 Sep 2026) switches a table's winning tax on, beside its band and
// pot cap; tax=0 or no option leaves it off; any other figure stops the boot,
// since the rate is the winner's level's and a figure here would be a promise
// the table does not keep. The switch reaches the public Teen Patti table of
// that pair and nothing else — not the other tables, not a private one, never
// a poker room — and a catalogue row's is held to the same rule.
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

	g := mustLoad(t, map[string]string{"LOBBY_TABLES": "blind:1000000:tax=1,seen:200,omaha:50000:tax=1", "TABLE_STAKES": ""}).Game
	if !g.Spec("blind", 1000000, false).WinnerTax {
		t.Error("the listed table taxes its winners")
	}
	if g.Spec("blind", 1000000, true).WinnerTax || g.Spec("seen", 200, false).WinnerTax || g.Spec("blind", 5000, false).WinnerTax {
		t.Error("a private table, another table and a pair off the menu never tax their winners")
	}
	if g.Spec("omaha", 50000, false).WinnerTax {
		t.Error("a poker room never taxes its winners, whatever its entry says")
	}

	// The defaults tax exactly the two 10 Lakh tables.
	d := Defaults().Game
	for _, spec := range d.EffectiveCatalogue().Public {
		want := spec.Key == "blind:1000000" || spec.Key == "variation:1000000"
		if spec.WinnerTax != want {
			t.Errorf("%s: winnerTax %v, want %v", spec.Key, spec.WinnerTax, want)
		}
	}
	for _, spec := range d.EffectiveCatalogue().Private {
		if spec.WinnerTax {
			t.Errorf("the private template %s must not tax its winners", spec.Key)
		}
	}

	// A catalogue row: kept on a Teen Patti table, zeroed on a poker one.
	cat := d.EffectiveCatalogue()
	cat.Source = TableConfigSourceDB
	for i := range cat.Public {
		if cat.Public[i].Category == CategoryOmaha {
			cat.Public[i].WinnerTax = true
		}
	}
	valid, problems, err := cat.Validate()
	if err != nil || len(problems) != 0 {
		t.Fatalf("validate: %v %v", err, problems)
	}
	for _, spec := range valid.Public {
		if spec.Category == CategoryOmaha && spec.WinnerTax {
			t.Error("a poker row's winner_tax is a figure its family does not read: zeroed")
		}
		if spec.Key == "blind:1000000" && !spec.WinnerTax {
			t.Error("a Teen Patti row's winner_tax is kept")
		}
	}

	// SameRules compares it: a table whose switch changed is drained.
	a := d.Spec("blind", 1000000, false)
	b := a
	b.WinnerTax = false
	if a.SameRules(b) {
		t.Error("two specs that differ in winner tax do not play by the same rules")
	}
}
