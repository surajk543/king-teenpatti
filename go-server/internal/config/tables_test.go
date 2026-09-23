package config

import (
	"math"
	"reflect"
	"strings"
	"testing"
	"time"
)

// TestTheTableSourceResolvesFromTheEnvironment: an explicit
// TABLE_CONFIG_SOURCE wins; unset, a table key in the environment — even one
// set to "" — means env, so a deployment whose .env pins its menu changes
// nothing until the database is chosen on purpose; with none, db.
func TestTheTableSourceResolvesFromTheEnvironment(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want string
		keys []string
	}{
		{"nothing set", map[string]string{}, TableConfigSourceDB, nil},
		{"a pinned menu", map[string]string{"LOBBY_TABLES": "seen:200"}, TableConfigSourceEnv, []string{"LOBBY_TABLES"}},
		{"the harness's open menu", map[string]string{"LOBBY_TABLES": "", "TABLE_STAKES": ""}, TableConfigSourceEnv, []string{"TABLE_STAKES", "LOBBY_TABLES"}},
		{"db chosen over pinned keys", map[string]string{"TABLE_CONFIG_SOURCE": "db", "TURN_TIMEOUT_MS": "1200"}, TableConfigSourceDB, []string{"TURN_TIMEOUT_MS"}},
		{"env chosen", map[string]string{"TABLE_CONFIG_SOURCE": "env"}, TableConfigSourceEnv, nil},
		{"empty is unset", map[string]string{"TABLE_CONFIG_SOURCE": ""}, TableConfigSourceDB, nil},
		{"a key that is not a table key", map[string]string{"WELCOME_CHIPS": "1"}, TableConfigSourceDB, nil},
	}
	for _, tc := range cases {
		cfg := mustLoad(t, tc.env)
		if cfg.TableConfigSource != tc.want || !reflect.DeepEqual(cfg.TableEnvKeysSet, tc.keys) {
			t.Errorf("%s: source %q keys %v, want %q %v", tc.name, cfg.TableConfigSource, cfg.TableEnvKeysSet, tc.want, tc.keys)
		}
	}
	if _, err := FromEnv(mapLookup(map[string]string{"TABLE_CONFIG_SOURCE": "postgres"})); err == nil ||
		!strings.Contains(err.Error(), "TABLE_CONFIG_SOURCE") {
		t.Errorf("an unknown source must stop the boot, got %v", err)
	}
	if got := Defaults().TableConfigSource; got != TableConfigSourceDB {
		t.Errorf("Defaults() source %q", got)
	}
}

// TestSpecComposesWhatTheServerAlwaysBuilt: with no catalogue, Spec is the
// composition newTableLocked and poker.ConfigFor made before the catalogue
// existed — pinned here figure by figure for the default menu and every
// private category, so the seed that is generated from it plays exactly as
// the server did.
func TestSpecComposesWhatTheServerAlwaysBuilt(t *testing.T) {
	g := Defaults().Game
	common := func(s TableSpec) TableSpec {
		s.MaxPlayers, s.MinPlayers = 5, 2
		s.TurnTimeout = 25 * time.Second
		s.MaxMissedTurns = 3
		s.NextHandDelay = 4 * time.Second
		s.UnfundedGrace = 30 * time.Second
		return s
	}
	teenPatti := func(s TableSpec) TableSpec {
		s = common(s)
		s.MaxBlindMoves = 4
		s.SideshowTimeout = 6 * time.Second
		s.SideshowMinPlayers = 3
		s.MissileRevealExtra = 3 * time.Second
		return s
	}
	seen := func(s TableSpec) TableSpec {
		s = teenPatti(s)
		s.MaxRaiseSteps, s.MaxBetRounds, s.PotLimitMultiplier = 2, 7, 1024
		return s
	}
	poker := func(s TableSpec) TableSpec {
		s = common(s)
		s.MinBuyIn = s.BootAmount * 10
		s.MaxDiscards = 3
		return s
	}
	variation := func(s TableSpec) TableSpec {
		s = seen(s)
		s.VariationSelectTimeout = 10 * time.Second
		s.FiveCardPickTimeout = 8 * time.Second
		return s
	}
	want := []TableSpec{
		seen(TableSpec{Key: "seen:200", Category: "seen", BootAmount: 200, MaxPot: 2000000, SortOrder: 10}),
		teenPatti(TableSpec{Key: "blind:200", Category: "blind", BootAmount: 200, SortOrder: 20}),
		teenPatti(TableSpec{Key: "blind:5000", Category: "blind", BootAmount: 5000, MaxChips: 50000000, SortOrder: 30}),
		teenPatti(TableSpec{Key: "blind:50000", Category: "blind", BootAmount: 50000, MaxChips: 1000000000, SortOrder: 40}),
		teenPatti(TableSpec{Key: "blind:1000000", Category: "blind", BootAmount: 1000000, MinChips: 500000000, SortOrder: 50}),
		variation(TableSpec{Key: "variation:50000", Category: "variation", BootAmount: 50000, MaxChips: 1000000000, SortOrder: 60}),
		variation(TableSpec{Key: "variation:1000000", Category: "variation", BootAmount: 1000000, MinChips: 500000000, SortOrder: 70}),
		seen(TableSpec{Key: "seen:50000", Category: "seen", BootAmount: 50000, MaxPot: 50000000, SortOrder: 80}),
		poker(TableSpec{Key: "three_card_poker:50000", Category: "three_card_poker", BootAmount: 50000, SortOrder: 90}),
		poker(TableSpec{Key: "five_card_draw:50000", Category: "five_card_draw", BootAmount: 50000, SortOrder: 100}),
		poker(TableSpec{Key: "texas_holdem:50000", Category: "texas_holdem", BootAmount: 50000, SortOrder: 110}),
		poker(TableSpec{Key: "omaha:50000", Category: "omaha", BootAmount: 50000, SortOrder: 120}),
	}
	for _, w := range want {
		if got := g.Spec(w.Category, w.BootAmount, false); got != w {
			t.Errorf("%s:\n got %+v\nwant %+v", w.Key, got, w)
		}
	}
	private := func(s TableSpec) TableSpec {
		s.Private, s.BootAmount, s.Key = true, 200, PrivateTableKey(s.Category)
		return s
	}
	wantPrivate := []TableSpec{
		private(seen(TableSpec{Category: "seen", MaxPot: 500000})),
		private(teenPatti(TableSpec{Category: "blind", MaxPot: 500000, MaxRaiseSteps: 2})),
		private(variation(TableSpec{Category: "variation", MaxPot: 500000})),
	}
	for _, c := range []string{"three_card_poker", "five_card_draw", "texas_holdem", "omaha"} {
		s := private(TableSpec{Category: c})
		wantPrivate = append(wantPrivate, poker(s))
	}
	for _, w := range wantPrivate {
		// A private create names no boot; whatever it names, the private boot wins.
		for _, boot := range []int64{0, 5000} {
			if got := g.Spec(w.Category, boot, true); got != w {
				t.Errorf("%s (boot %d):\n got %+v\nwant %+v", w.Key, boot, got, w)
			}
		}
	}
	// It IS TableRules for a Teen Patti table, at every boot, public and private.
	for _, c := range []string{"seen", "blind", "variation", "nonsense"} {
		for _, boot := range []int64{0, 200, 700, 50000} {
			for _, private := range []bool{false, true} {
				s, r := g.Spec(c, boot, private), g.TableRules(c, boot, private)
				if s.BootAmount != r.BootAmount || s.MaxPot != r.MaxPot || s.MaxRaiseSteps != r.MaxRaiseSteps ||
					s.MaxBetRounds != r.MaxBetRounds || s.PotLimitMultiplier != r.PotLimitMultiplier {
					t.Errorf("%s %d private=%v: spec %+v rules %+v", c, boot, private, s, r)
				}
			}
		}
	}
	// A pair off the menu has no band; an unknown category is seen.
	if s := g.Spec("seen", 700, false); s.Key != "seen:700" || s.MinChips != 0 || s.MaxChips != 0 || s.SortOrder != 0 {
		t.Errorf("off-menu %+v", s)
	}
	if s := g.Spec("nonsense", 200, false); s.Category != "seen" || s.MaxPot != 2000000 {
		t.Errorf("unknown category %+v", s)
	}
	// POKER_TURN_TIMEOUT_MS, the buy-in floor and the discard clamp.
	g.Poker = PokerConfig{TurnTimeout: 90 * time.Second, MinBuyInBoots: 0, MaxDiscards: 9}
	if s := g.Spec("omaha", 1000, false); s.TurnTimeout != 90*time.Second || s.MinBuyIn != 1000 || s.MaxDiscards != 5 {
		t.Errorf("poker knobs %+v", s)
	}
}

// TestTheDefaultCatalogueSurvivesTheDatabaseRoundTrip: the env composition,
// validated as rows read back from table_configs would be and laid over a
// configuration with WithCatalogue, answers every question the engine asks
// exactly as the composition did. This is the in-memory half of "the seed
// plays as the defaults did"; internal/db proves the SQL half.
func TestTheDefaultCatalogueSurvivesTheDatabaseRoundTrip(t *testing.T) {
	g := Defaults().Game
	cat := g.EffectiveCatalogue()
	if cat.Source != TableConfigSourceEnv || len(cat.Public) != 12 || len(cat.Private) != 7 {
		t.Fatalf("catalogue %s: %d public, %d private", cat.Source, len(cat.Public), len(cat.Private))
	}
	cat.Source = TableConfigSourceDB
	valid, problems, err := cat.Validate()
	if err != nil || len(problems) != 0 {
		t.Fatalf("the default catalogue is not valid: %v %v", err, problems)
	}
	if !reflect.DeepEqual(valid, cat) {
		t.Fatalf("Validate changed the default catalogue:\n got %+v\nwant %+v", valid, cat)
	}
	db := g.WithCatalogue(valid)
	if !db.FromDatabase() || g.FromDatabase() {
		t.Fatal("FromDatabase")
	}
	for _, spec := range cat.Public {
		if got := db.Spec(spec.Category, spec.BootAmount, false); got != spec {
			t.Errorf("%s: %+v", spec.Key, got)
		}
	}
	for _, spec := range cat.Private {
		if got := db.Spec(spec.Category, 0, true); got != spec {
			t.Errorf("%s: %+v", spec.Key, got)
		}
	}
	// Every field an existing check reads is what it was — except the menu's
	// own pot cap, which is read through Spec and left 0 on purpose.
	wantMenu := make([]LobbyTable, len(g.LobbyTables))
	for i, entry := range g.LobbyTables {
		entry.MaxPot = 0
		wantMenu[i] = entry
	}
	if !reflect.DeepEqual(db.LobbyTables, wantMenu) || !reflect.DeepEqual(db.TableStakes, g.TableStakes) ||
		db.BootAmount != g.BootAmount || db.MaxPlayers != g.MaxPlayers || db.MinPlayers != g.MinPlayers ||
		db.TurnTimeout != g.TurnTimeout || db.MaxBetRounds != g.MaxBetRounds || db.SideshowTimeout != g.SideshowTimeout ||
		db.SideshowMinPlayers != g.SideshowMinPlayers || db.EntryCapBoot != g.EntryCapBoot ||
		db.EntryCapCategory != g.EntryCapCategory || db.EntryCapMaxChips != g.EntryCapMaxChips ||
		db.PrivateBoot != g.PrivateBoot || db.PrivateMaxPot != g.PrivateMaxPot || db.PrivateMaxRaiseSteps != g.PrivateMaxRaiseSteps {
		t.Errorf("the overlay moved a field:\n got %+v\nwant %+v", db, g)
	}
	// The catalogue is the catalogue it was built from, and a copy.
	back := db.EffectiveCatalogue()
	if !reflect.DeepEqual(back, valid) {
		t.Errorf("EffectiveCatalogue in db mode:\n got %+v\nwant %+v", back, valid)
	}
	back.Public[0].MaxPot = 1
	if db.Spec("seen", 200, false).MaxPot == 1 {
		t.Error("EffectiveCatalogue must return a copy")
	}
}

// TestADatabaseCatalogueRulesWhereItHasARow: a row's own figures reach Spec
// — the point of the whole exercise — and a category with no private
// template cannot be opened privately.
func TestADatabaseCatalogueRulesWhereItHasARow(t *testing.T) {
	g := Defaults().Game
	cat := g.EffectiveCatalogue()
	cat.Source = TableConfigSourceDB
	cat.Public[2].MaxBlindMoves = 2      // blind:5000
	cat.Public[0].MaxPot = 0             // seen:200 with no pot limit
	cat.Public[8].MinBuyIn = 200000      // three_card_poker:50000
	cat.Private = cat.Private[:1]        // private seen only
	cat.Private[0].MaxPot = 900000       // private seen
	cat.Settings.DefaultBootAmount = 700 // what a boot of 0 means
	valid, problems, err := cat.Validate()
	if err != nil || len(problems) != 0 {
		t.Fatal(err, problems)
	}
	db := g.WithCatalogue(valid)
	if s := db.Spec("blind", 5000, false); s.MaxBlindMoves != 2 {
		t.Errorf("blind moves %+v", s)
	}
	if s := db.Spec("seen", 200, false); s.MaxPot != 0 {
		t.Errorf("an uncapped seen row must stay uncapped, not fall back to SEEN_MAX_POT: %+v", s)
	}
	if s := db.Spec("three_card_poker", 50000, false); s.MinBuyIn != 200000 {
		t.Errorf("buy-in %+v", s)
	}
	if s := db.Spec("seen", 0, true); s.MaxPot != 900000 || db.PrivateMaxPot != 900000 {
		t.Errorf("private %+v", s)
	}
	if !db.HasPrivate("seen") || db.HasPrivate("blind") || !g.HasPrivate("blind") {
		t.Error("HasPrivate")
	}
	if db.BootAmount != 700 {
		t.Errorf("default boot %d", db.BootAmount)
	}
}

// TestValidateLeavesABadRowOutAndRefusesOnlyAnUnusableCatalogue: a hand edit
// PostgreSQL accepted must not stop the next restart — the row is left out
// and described — but a lobby with nothing to offer, or nothing for a private
// create to open, or a settings row nobody could play by, is refused.
func TestValidateLeavesABadRowOutAndRefusesOnlyAnUnusableCatalogue(t *testing.T) {
	base := Defaults().Game.EffectiveCatalogue()
	base.Source = TableConfigSourceDB
	edit := func(mutate func(*TableCatalogue)) TableCatalogue {
		cat := base.clone()
		mutate(&cat)
		return cat
	}
	leftOut := []struct {
		name   string
		mutate func(*TableCatalogue)
		want   string
	}{
		{"unknown category", func(c *TableCatalogue) { c.Public[0].Category = "rummy" }, "unknown category"},
		{"no boot", func(c *TableCatalogue) { c.Public[1].BootAmount = 0 }, "boot_amount"},
		{"inverted band", func(c *TableCatalogue) { c.Public[1].MinChips, c.Public[1].MaxChips = 10, 5 }, "nobody could sit"},
		{"private band", func(c *TableCatalogue) { c.Private[1].MaxChips = 5 }, "no stack band"},
		{"no clock", func(c *TableCatalogue) { c.Public[1].TurnTimeout = 0 }, "turn_timeout_ms"},
		{"buy-in below the boot", func(c *TableCatalogue) { c.Public[8].MinBuyIn = 1 }, "min_buy_in"},
		{"too many discards", func(c *TableCatalogue) { c.Public[9].MaxDiscards = 6 }, "max_discards"},
		{"a variation window that never lapses", func(c *TableCatalogue) { c.Public[5].VariationSelectTimeout = 0 }, "variation_select_timeout_ms"},
		{"an overflowing ceiling", func(c *TableCatalogue) { c.Public[0].PotLimitMultiplier = math.MaxInt64 }, "overflows"},
		{"negative ladder", func(c *TableCatalogue) { c.Public[1].MaxRaiseSteps = -1 }, "negative"},
		{"a repeated pair", func(c *TableCatalogue) { c.Public = append(c.Public, c.Public[1]) }, "a second row for blind:200"},
	}
	for _, tc := range leftOut {
		valid, problems, err := edit(tc.mutate).Validate()
		if err != nil || len(problems) == 0 || !strings.Contains(strings.Join(problems, "; "), tc.want) {
			t.Errorf("%s: err %v problems %v", tc.name, err, problems)
			continue
		}
		if len(valid.Public)+len(valid.Private) != len(base.Public)+len(base.Private)-1 &&
			tc.name != "a repeated pair" {
			t.Errorf("%s: exactly one row must be left out, %d public %d private", tc.name, len(valid.Public), len(valid.Private))
		}
	}
	// Family-irrelevant figures are zeroed, not refused.
	valid, _, _ := edit(func(c *TableCatalogue) {
		c.Public[0].MinBuyIn, c.Public[0].VariationSelectTimeout = 9, time.Second // seen
		c.Public[8].MaxPot, c.Public[8].SideshowTimeout = 9, time.Second          // poker
	}).Validate()
	if s := valid.Public[0]; s.MinBuyIn != 0 || s.VariationSelectTimeout != 0 {
		t.Errorf("seen kept poker/variation figures %+v", s)
	}
	if s := valid.Public[8]; s.MaxPot != 0 || s.SideshowTimeout != 0 {
		t.Errorf("poker kept Teen Patti figures %+v", s)
	}
	// Warnings that leave the row in.
	_, problems, err := edit(func(c *TableCatalogue) {
		c.Public = c.Public[:5] // no public variation, the private template still active
		c.Private[2].BootAmount = 300
	}).Validate()
	if err != nil || len(problems) != 2 {
		t.Errorf("warnings: %v %v", err, problems)
	}
	refused := []struct {
		name   string
		mutate func(*TableCatalogue)
	}{
		{"no public table", func(c *TableCatalogue) { c.Public = nil }},
		{"every public row bad", func(c *TableCatalogue) {
			for i := range c.Public {
				c.Public[i].BootAmount = -1
			}
		}},
		{"no private seen", func(c *TableCatalogue) { c.Private = c.Private[1:] }},
		{"no default boot", func(c *TableCatalogue) { c.Settings.DefaultBootAmount = 0 }},
		{"six players", func(c *TableCatalogue) { c.Settings.MaxPlayers = 6 }},
		{"min above max", func(c *TableCatalogue) { c.Settings.MinPlayers = 5; c.Settings.MaxPlayers = 4 }},
		{"a stake of 0", func(c *TableCatalogue) { c.Settings.Stakes = []int64{200, 0} }},
		{"an unknown entry-cap category", func(c *TableCatalogue) { c.Settings.EntryCapCategory = "rummy" }},
	}
	for _, tc := range refused {
		if _, _, err := edit(tc.mutate).Validate(); err == nil {
			t.Errorf("%s: must be refused", tc.name)
		}
	}
}

// TestSameRulesIgnoresOnlyTheBandAndThePlace: a restored table whose figures
// match its row is left alone whatever its band (the band is the lobby's,
// checked at the door); any figure it plays by differently drains it.
func TestSameRulesIgnoresOnlyTheBandAndThePlace(t *testing.T) {
	a := Defaults().Game.Spec("blind", 5000, false)
	b := a
	b.MinChips, b.MaxChips, b.SortOrder, b.Key = 1, 2, 3, "x"
	if !a.SameRules(b) {
		t.Error("band and place must not count")
	}
	b.MaxBlindMoves = 3
	if a.SameRules(b) {
		t.Error("a changed figure must count")
	}
}

func mapLookup(m map[string]string) Lookup {
	return func(key string) (string, bool) {
		v, ok := m[key]
		return v, ok
	}
}
