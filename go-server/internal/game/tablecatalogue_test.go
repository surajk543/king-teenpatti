package game_test

// The table catalogue in the engine (owner, 23 Sep 2026: "all table related
// config store in database"): a table_configs row's figures reach the table it
// opens and the lobby card that sends players there, a private create folds
// to seen where no template exists, the entry cap becomes the band, a table
// restored with rules the configuration no longer opens is drained, and the
// catalogue payload a client caches is versioned by its own bytes.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/poker"
)

// dbCatalogue is the fixture mutation that runs the manager in db mode: the
// Defaults() composition (what V1.0.1__seed.sql writes) with edit applied to
// its rows, through Validate and WithCatalogue — the path app.New takes with
// the rows it loaded.
func dbCatalogue(t *testing.T, edit func(*config.TableCatalogue)) func(*config.GameConfig, *game.RoomManagerOptions) {
	return func(g *config.GameConfig, _ *game.RoomManagerOptions) {
		t.Helper()
		cat := g.EffectiveCatalogue()
		cat.Source = config.TableConfigSourceDB
		if edit != nil {
			edit(&cat)
		}
		valid, problems, err := cat.Validate()
		if err != nil || len(problems) != 0 {
			t.Fatalf("the test's catalogue is not valid: %v %v", err, problems)
		}
		*g = g.WithCatalogue(valid)
	}
}

// catalogueRow is the row of cat whose key is key.
func catalogueRow(t *testing.T, cat *config.TableCatalogue, key string) *config.TableSpec {
	t.Helper()
	for i := range cat.Public {
		if cat.Public[i].Key == key {
			return &cat.Public[i]
		}
	}
	for i := range cat.Private {
		if cat.Private[i].Key == key {
			return &cat.Private[i]
		}
	}
	t.Fatalf("no catalogue row %s", key)
	return nil
}

// lobbyEntry is the menu entry of the pair.
func lobbyEntry(t *testing.T, o game.LobbyOptions, category string, boot int64) game.LobbyTableOption {
	t.Helper()
	for _, entry := range o.Tables {
		if entry.Category == category && entry.BootAmount == boot {
			return entry
		}
	}
	t.Fatalf("no menu entry %s %d", category, boot)
	return game.LobbyTableOption{}
}

// payloadEntry is the catalogue payload's entry with key.
func payloadEntry(t *testing.T, entries []game.TableConfigEntry, key string) game.TableConfigEntry {
	t.Helper()
	for _, entry := range entries {
		if entry.Key == key {
			return entry
		}
	}
	t.Fatalf("no payload entry %s", key)
	return game.TableConfigEntry{}
}

// TestATableSaysWhatItPlaysBy: every table the default configuration opens —
// every menu entry of both families and every private template — gives back,
// as its RulesSpec, the spec it was built from (band and menu position aside,
// which are the lobby's). Draining compares exactly these two, so a lossy
// round trip would drain every table on every restart.
func TestATableSaysWhatItPlaysBy(t *testing.T) {
	f := newRoomsFixture(t, nil)
	cat := f.cfg.EffectiveCatalogue()
	for _, want := range append(append([]config.TableSpec{}, cat.Public...), cat.Private...) {
		room := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: want.BootAmount, Category: want.Category, IsPrivate: want.Private})
		got := room.RulesSpec()
		if got.Key != want.Key || !got.SameRules(want) || got.MinChips != 0 || got.MaxChips != 0 || got.SortOrder != 0 {
			t.Errorf("%s:\n got %+v\nwant %+v", want.Key, got, want)
		}
		if err := f.rooms.DestroyTable(room.ID()); err != nil {
			t.Fatal(err)
		}
	}
}

// TestADatabaseRowsFiguresReachTheTableAndItsCard: the point of the whole
// exercise. A figure changed on one table_configs row is what the table that
// row opens plays by — through quick-join, a create, either family — and what
// the lobby card and the catalogue payload say, while every other table plays
// exactly as before.
func TestADatabaseRowsFiguresReachTheTableAndItsCard(t *testing.T) {
	f := newRoomsFixture(t, dbCatalogue(t, func(cat *config.TableCatalogue) {
		blind := catalogueRow(t, cat, "blind:5000")
		blind.MaxBlindMoves, blind.MaxRaiseSteps, blind.MaxBetRounds = 2, 3, 5
		blind.PotLimitMultiplier, blind.MaxPot = 64, 7000000
		blind.TurnTimeout, blind.SideshowTimeout, blind.SideshowMinPlayers = 40*time.Second, 9*time.Second, 2
		blind.NextHandDelay, blind.MissileRevealExtra, blind.MaxMissedTurns = 2*time.Second, time.Second, 2
		blind.UnfundedGrace = 5 * time.Second
		catalogueRow(t, cat, "seen:200").MaxPot = 0 // no pot limit, NOT SEEN_MAX_POT
		variation := catalogueRow(t, cat, "variation:50000")
		variation.VariationSelectTimeout, variation.FiveCardPickTimeout = 12*time.Second, 6*time.Second
		draw := catalogueRow(t, cat, "five_card_draw:50000")
		draw.MinBuyIn, draw.MaxDiscards, draw.TurnTimeout = 150000, 2, 45*time.Second
	}))
	if !f.cfg.FromDatabase() {
		t.Fatal("the fixture is not in db mode")
	}
	chat := config.Defaults().Chat

	blind := f.mustQuickJoin(f.player("Q", 1000000), 5000, "blind")
	want := game.TableConfig{
		Category: game.CategoryBlind, BootAmount: 5000, MaxPlayers: 5, MinPlayers: 2,
		TurnTimeout: 40 * time.Second, MaxBetRounds: 5, PotLimitMultiplier: 64, MaxRaiseSteps: 3, MaxPot: 7000000,
		MaxBlindMoves: 2, MaxMissedTurns: 2, SideshowTimeout: 9 * time.Second, SideshowMinPlayers: 2,
		NextHandDelay: 2 * time.Second, UnfundedGrace: 5 * time.Second, MissileRevealExtra: time.Second,
		ChatMaxHistory: chat.MaxHistory, ChatMaxLength: chat.MaxLength,
	}
	if got := blind.Config(); got != want {
		t.Errorf("blind 5000:\n got %+v\nwant %+v", got, want)
	}
	if got := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"}).Config(); got.MaxPot != 0 || got.MaxRaiseSteps != 2 {
		t.Errorf("seen 200 must be uncapped by its row: %+v", got)
	}
	if got := f.createTable(game.CreateTableOptions{BootAmount: 50000, Category: "variation"}).Config(); got.VariationSelectTimeout != 12*time.Second || got.FiveCardPickTimeout != 6*time.Second {
		t.Errorf("variation 50000: %+v", got)
	}
	// A row nobody edited plays exactly as the env composition did.
	if got, want := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "blind"}).RulesSpec(), config.Defaults().Game.Spec("blind", 200, false); !got.SameRules(func() config.TableSpec { want.UnfundedGrace = 0; return want }()) {
		t.Errorf("blind 200 moved:\n got %+v\nwant %+v", got, want)
	}
	room := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 50000, Category: "five_card_draw"})
	pt, ok := room.(*poker.Table)
	if !ok {
		t.Fatalf("five_card_draw opened a %T", room)
	}
	if cfg := pt.Config(); cfg.MinBuyIn != 150000 || cfg.MaxDiscards != 2 || cfg.TurnTimeout != 45*time.Second || cfg.BootAmount != 50000 {
		t.Errorf("five_card_draw: %+v", cfg)
	}

	// The card is the table.
	o := f.rooms.LobbyOptions()
	if e := lobbyEntry(t, o, "blind", 5000); e.MaxPot != 7000000 || e.MaxBlindMoves != 2 || e.MaxChips != 50000000 {
		t.Errorf("blind 5000 card %+v", e)
	}
	if e := lobbyEntry(t, o, "seen", 200); e.MaxPot != 0 {
		t.Errorf("seen 200 card %+v", e)
	}
	if e := lobbyEntry(t, o, "five_card_draw", 50000); e.MinBuyIn != 150000 || e.MinChips != 150000 || e.MaxDiscards != 2 || e.Ante != 50000 {
		t.Errorf("five_card_draw card %+v", e)
	}
	p := f.rooms.TableConfig()
	if p.Source != config.TableConfigSourceDB {
		t.Errorf("source %q", p.Source)
	}
	e := payloadEntry(t, p.Tables, "blind:5000")
	if e.TurnTimeoutMs != 40000 || e.MaxRaiseSteps != 3 || e.MaxBetRounds != 5 || e.PotLimitMultiplier != 64 ||
		e.SideshowTimeoutMs != 9000 || e.SideshowMinPlayers != 2 || e.NextHandDelayMs != 2000 || e.MissileRevealExtraMs != 1000 ||
		e.UnfundedGraceMs != 5000 || e.MaxMissedTurns != 2 || e.MaxPot != 7000000 || e.MaxBlindMoves != 2 {
		t.Errorf("blind 5000 in the payload %+v", e)
	}
	if e := payloadEntry(t, p.Tables, "five_card_draw:50000"); e.TurnTimeoutMs != 45000 || e.MinBuyIn != 150000 {
		t.Errorf("five_card_draw in the payload %+v", e)
	}
}

// TestAPrivateCreateOfACategoryWithNoTemplateFoldsToSeen: in db mode a
// category can be opened privately only where the operator has given it a
// private template; anything else is a private SEEN table playing by the seen
// template — the fold an unknown category has always had.
func TestAPrivateCreateOfACategoryWithNoTemplateFoldsToSeen(t *testing.T) {
	f := newRoomsFixture(t, dbCatalogue(t, func(cat *config.TableCatalogue) {
		seen := *catalogueRow(t, cat, "private:seen")
		blind := *catalogueRow(t, cat, "private:blind")
		seen.BootAmount, seen.MaxPot, seen.MaxRaiseSteps = 300, 900000, 3
		blind.BootAmount, blind.MaxPot = 300, 123000
		cat.Private = []config.TableSpec{seen, blind} // no variation, no poker template
	}))
	for _, category := range []string{"seen", "variation", "texas_holdem", "nonsense"} {
		room := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true, Category: category})
		table := game.AsTable(room)
		if table == nil {
			t.Fatalf("private %s opened a %T", category, room)
		}
		cfg := table.Config()
		if cfg.Category != game.CategorySeen || cfg.BootAmount != 300 || cfg.MaxPot != 900000 || cfg.MaxRaiseSteps != 3 || !table.IsPrivate() {
			t.Errorf("private %s: %+v", category, cfg)
		}
	}
	// A category WITH a template plays by it.
	if cfg := f.createTable(game.CreateTableOptions{IsPrivate: true, Category: "blind", BootAmount: 5000}).Config(); cfg.Category != game.CategoryBlind || cfg.BootAmount != 300 || cfg.MaxPot != 123000 {
		t.Errorf("private blind: %+v", cfg)
	}
	// The lobby advertises the seen template's boot and cap, and the payload
	// lists exactly the templates there are.
	if o := f.rooms.LobbyOptions(); o.PrivateBoot != 300 || o.PrivateMaxPot != 900000 {
		t.Errorf("privateBoot %d privateMaxPot %d", o.PrivateBoot, o.PrivateMaxPot)
	}
	p := f.rooms.TableConfig()
	if len(p.PrivateTables) != 2 || p.PrivateTables[0].Key != "private:seen" || p.PrivateTables[1].Key != "private:blind" ||
		!p.PrivateTables[0].IsPrivate || p.PrivateTables[1].MaxPot != 123000 {
		t.Errorf("private templates %+v", p.PrivateTables)
	}

	// From env nothing folds: every category opens privately.
	env := newRoomsFixture(t, nil)
	if room := env.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true, Category: "texas_holdem"}); room.Category() != game.CategoryTexasHoldem {
		t.Errorf("env private hold'em opened %s", room.Category())
	}
}

// TestInDatabaseModeTheEntryCapIsTheBand: requirement 30's cap is the
// matching row's band in db mode — the same refusal, with the same code and
// message, at the same stack — and a row's own max_chips wins over it at the
// card AND at the door. From env the cap is still checked on its own, so a
// LOBBY_TABLES max above it is shown on the card and refused at the door, as
// it always was.
func TestInDatabaseModeTheEntryCapIsTheBand(t *testing.T) {
	f := newRoomsFixture(t, dbCatalogue(t, nil))
	if e := lobbyEntry(t, f.rooms.LobbyOptions(), "blind", 200); e.MaxChips != 500000 {
		t.Fatalf("the cap is the card's band: %+v", e)
	}
	_, err := f.rooms.QuickJoin(f.player("Rich", 600000), game.QuickJoinOptions{BootAmount: 200, Category: "blind"})
	expectCode(t, err, game.CodeOverEntryCap)
	if !strings.Contains(err.Error(), "more than 500,000 chips") {
		t.Errorf("message %q", err.Error())
	}
	f.mustQuickJoin(f.player("AtTheCap", 500000), 200, "blind")

	raised := newRoomsFixture(t, dbCatalogue(t, func(cat *config.TableCatalogue) {
		catalogueRow(t, cat, "blind:200").MaxChips = 1000000
	}))
	if e := lobbyEntry(t, raised.rooms.LobbyOptions(), "blind", 200); e.MaxChips != 1000000 {
		t.Fatalf("the row's band is the card's: %+v", e)
	}
	table := raised.mustQuickJoin(raised.player("Rich", 600000), 200, "blind")
	if _, err := raised.rooms.JoinByCode(raised.player("AlsoRich", 900000), table.Code()); err != nil {
		t.Fatalf("join by code under the row's band: %v", err)
	}
	_, err = raised.rooms.QuickJoin(raised.player("TooRich", 1000001), game.QuickJoinOptions{BootAmount: 200, Category: "blind"})
	expectCode(t, err, game.CodeOverEntryCap)
	if !strings.Contains(err.Error(), "more than 1,000,000 chips") {
		t.Errorf("message %q", err.Error())
	}

	env := newRoomsFixture(t, func(g *config.GameConfig, _ *game.RoomManagerOptions) {
		for i := range g.LobbyTables {
			if g.LobbyTables[i].Category == "blind" && g.LobbyTables[i].BootAmount == 200 {
				g.LobbyTables[i].MaxChips = 1000000
			}
		}
	})
	_, err = env.rooms.QuickJoin(env.player("Rich", 600000), game.QuickJoinOptions{BootAmount: 200, Category: "blind"})
	expectCode(t, err, game.CodeOverEntryCap)
}

// withStoreAndMenu attaches a live store and keeps the default menu.
func withStoreAndMenu(store *livetest.Store, instance string, then func(*config.GameConfig, *game.RoomManagerOptions)) func(*config.GameConfig, *game.RoomManagerOptions) {
	return func(g *config.GameConfig, o *game.RoomManagerOptions) {
		o.Live = store
		o.Instance = instance
		if then != nil {
			then(g, o)
		}
	}
}

// TestARestoredTableWhoseRulesChangedIsDrained: an edit to the table
// configuration applies to tables opened after the restart that brings it in;
// a table the live store brings back keeps the rules in its snapshot, and so
// matchmaking must stop sending players to it — the card describes the new
// rules. It plays on, it is joined by its code, it empties and goes like any
// other; it is simply never picked, switched to or merged.
func TestARestoredTableWhoseRulesChangedIsDrained(t *testing.T) {
	store := livetest.New()
	f1, ids, players := playingFixture(t, store)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := f1.rooms.Suspend(ctx); err != nil {
		t.Fatal(err)
	}

	// The same configuration drains nothing.
	f2 := newRoomsFixture(t, withStore(store, "same"))
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch))
	if _, err := f2.rooms.Restore(ctx); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		if f2.rooms.Draining(id) {
			t.Fatalf("%s drained by an unchanged configuration", id)
		}
	}
	eq(t, strings.Count(f2.logText(), "table draining"), 0, "nothing drained")
	if err := f2.rooms.Suspend(ctx); err != nil {
		t.Fatal(err)
	}

	// The clock is changed before the next restart.
	f3 := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		withStore(store, "changed")(g, o)
		g.TurnTimeout = 40 * time.Second
	})
	f3.clock.Advance(f2.clock.Now().Sub(rmEpoch))
	report, err := f3.rooms.Restore(ctx)
	if err != nil || report.Tables != 5 {
		t.Fatalf("restore: %+v %v", report, err)
	}
	// Every public table is drained; the private one is reached by code only
	// and never matched, so it is left alone.
	for i, id := range ids {
		eq(t, f3.rooms.Draining(id), i != 3, "draining "+id)
	}
	eq(t, strings.Count(f3.logText(), "table draining"), 4, "one line per drained table")
	eq(t, strings.Contains(f3.logText(), "the table configuration has changed since it was opened"), true, "the reason logged")
	// The hand in progress plays on by the rules it was dealt with.
	eq(t, game.AsTable(f3.rooms.GetTable(ids[0])).Config().TurnTimeout, 25*time.Second, "frozen clock")

	// Consolidation neither empties a drained table nor fills one: C (t2) and
	// E (t3) stay where they are.
	eq(t, len(f3.mustConsolidate()), 0, "no merge")

	// Quick-join opens a table with the new rules rather than seat F there.
	fp := f3.player("F", rmStart)
	fresh := f3.mustQuickJoin(fp, rmBoot, "seen")
	if fresh.ID() == ids[1] || fresh.ID() == ids[2] {
		t.Fatal("quick-join picked a drained table")
	}
	eq(t, fresh.Config().TurnTimeout, 40*time.Second, "the new table has the new clock")
	eq(t, f3.rooms.Draining(fresh.ID()), false, "a new table is not drained")
	// A switch finds nowhere to go: the other seen 200 tables are drained.
	_, err = f3.rooms.SwitchTable(fp)
	expectCode(t, err, game.CodeNoOtherTable)
	// A switch AWAY from a drained table is allowed: C goes to F's table.
	c := players["C"]
	moved, err := f3.rooms.SwitchTable(c)
	if err != nil {
		t.Fatalf("switch from a drained table: %v", err)
	}
	eq(t, moved.To.ID(), fresh.ID(), "onto the undrained table")

	// Its code still works.
	g := f3.player("G", rmStart)
	joined, err := f3.rooms.JoinByCode(g, f3.rooms.GetTable(ids[2]).Code())
	if err != nil || joined.ID() != ids[2] {
		t.Fatalf("join a drained table by its code: %v", err)
	}
	// Emptied, it goes like any table, and its mark with it.
	f3.mustLeave(g.ID, game.LeaveReasonLeft)
	f3.mustLeave(players["E"].ID, game.LeaveReasonLeft)
	if f3.rooms.GetTable(ids[2]) != nil {
		t.Fatal("the emptied drained table was not destroyed")
	}
	eq(t, f3.rooms.Draining(ids[2]), false, "the mark goes with the table")
}

// TestATableWhosePairLeftTheMenuIsDrained: a table restored for a category
// and boot the menu no longer lists is drained whatever it plays by — nobody
// can be sent to it from the lobby, and it closes when its players go.
func TestATableWhosePairLeftTheMenuIsDrained(t *testing.T) {
	store := livetest.New()
	f1 := newRoomsFixture(t, withStoreAndMenu(store, "old", nil))
	table := f1.mustQuickJoin(f1.player("A", rmStart), 5000, "blind")
	ctx := context.Background()
	if err := f1.rooms.Suspend(ctx); err != nil {
		t.Fatal(err)
	}
	f2 := newRoomsFixture(t, withStoreAndMenu(store, "new", func(g *config.GameConfig, _ *game.RoomManagerOptions) {
		var menu []config.LobbyTable
		for _, entry := range g.LobbyTables {
			if entry.Category != "blind" || entry.BootAmount != 5000 {
				menu = append(menu, entry)
			}
		}
		g.LobbyTables = menu
	}))
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch))
	if _, err := f2.rooms.Restore(ctx); err != nil {
		t.Fatal(err)
	}
	eq(t, f2.rooms.Draining(table.ID()), true, "drained")
	eq(t, strings.Contains(f2.logText(), "its table is no longer on the lobby menu"), true, "the reason logged")
	if _, err := f2.rooms.JoinByCode(f2.player("B", rmStart), table.Code()); err != nil {
		t.Fatalf("its code still works: %v", err)
	}
}

// TestADrainedPokerRoomDoesNotTrapTheBuyIn: the case that made draining
// necessary. A poker room saved with a 5 Lakh buy-in comes back after the
// operator lowered its row's to 2 Lakh; the card now admits a player holding
// 3 Lakh, and had quick-join kept picking the restored room — the fullest at
// that stake — its own frozen buy-in would have refused them every time, with
// no table they could ever sit at. Drained, it is passed by and a room with
// the row's rules is opened. The unchanged catalogue drains nothing: the seed
// plays exactly as the env composition did.
func TestADrainedPokerRoomDoesNotTrapTheBuyIn(t *testing.T) {
	store := livetest.New()
	ctx := context.Background()
	f1 := newRoomsFixture(t, withStoreAndMenu(store, "env", nil))
	room, err := f1.rooms.QuickJoin(f1.player("A", 1000000), game.QuickJoinOptions{BootAmount: 50000, Category: "texas_holdem"})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, room.(*poker.Table).Config().MinBuyIn, int64(500000), "the env buy-in")
	if err := f1.rooms.Suspend(ctx); err != nil {
		t.Fatal(err)
	}

	same := newRoomsFixture(t, withStoreAndMenu(store, "db-seed", dbCatalogue(t, nil)))
	same.clock.Advance(f1.clock.Now().Sub(rmEpoch))
	if _, err := same.rooms.Restore(ctx); err != nil {
		t.Fatal(err)
	}
	eq(t, same.rooms.Draining(room.ID()), false, "the seeded catalogue plays as env did")
	if err := same.rooms.Suspend(ctx); err != nil {
		t.Fatal(err)
	}

	f2 := newRoomsFixture(t, withStoreAndMenu(store, "db-edited", dbCatalogue(t, func(cat *config.TableCatalogue) {
		catalogueRow(t, cat, "texas_holdem:50000").MinBuyIn = 200000
	})))
	f2.clock.Advance(same.clock.Now().Sub(rmEpoch))
	if _, err := f2.rooms.Restore(ctx); err != nil {
		t.Fatal(err)
	}
	eq(t, f2.rooms.Draining(room.ID()), true, "drained")
	if e := lobbyEntry(t, f2.rooms.LobbyOptions(), "texas_holdem", 50000); e.MinBuyIn != 200000 || e.MinChips != 200000 {
		t.Fatalf("the card %+v", e)
	}
	b := f2.player("B", 300000)
	seated, err := f2.rooms.QuickJoin(b, game.QuickJoinOptions{BootAmount: 50000, Category: "texas_holdem"})
	if err != nil {
		t.Fatalf("a player the card admits must find a seat: %v", err)
	}
	if seated.ID() == room.ID() {
		t.Fatal("quick-join picked the drained room")
	}
	eq(t, seated.(*poker.Table).Config().MinBuyIn, int64(200000), "the row's buy-in")
	// The drained room's own rule still stands at its door.
	_, err = f2.rooms.JoinByCode(f2.player("C", 300000), f2.rooms.GetTable(room.ID()).Code())
	expectCode(t, err, game.CodeInsufficientChips)
}

// TestEveryCategoryIsPlayedByTheEngineTheDatabaseFilesItUnder: config cannot
// import game, so it answers "which engine plays this category" on its own
// (config.EngineOf) and that answer lands in table_categories.engine and on
// every catalogue entry. It must be game.Category.Game's answer, category for
// category, for the seven the server knows and for anything else (both call
// it Teen Patti, as NormalizeCategory calls it seen) — and the seeded
// taxonomy must file every category under it.
func TestEveryCategoryIsPlayedByTheEngineTheDatabaseFilesItUnder(t *testing.T) {
	eq(t, config.EngineTeenPatti, string(game.GameTeenPatti), "teen_patti")
	eq(t, config.EnginePoker, string(game.GamePoker), "poker")
	for _, c := range append(config.Categories(), "rummy", "", "Seen") {
		eq(t, config.EngineOf(c), string(game.Category(c).Game()), "the engine of "+c)
	}
	known := 0
	for _, c := range config.Categories() {
		if !game.Category(c).Known() {
			t.Errorf("config knows %s, game does not", c)
		}
		known++
	}
	eq(t, known, 3+len(game.PokerCategories), "every category game knows")
	for _, c := range config.DefaultTableCategories() {
		eq(t, c.Engine, string(game.Category(c.Code).Game()), "the seeded engine of "+c.Code)
	}
}

// TestTheTableConfigPayloadIsTheLobbyAndItsVersionIsItsOwnHash: the body of
// GET /api/tables. Its tables are session:ready's, entry for entry, with the
// rest of every table's figures beside them and the engine that plays each;
// its private templates are the catalogue's; its engines are the taxonomy,
// each with its categories; every slice is an array, never null; and its
// version is the sha256 of the payload itself, the same on every call and
// different the moment anything in it is.
func TestTheTableConfigPayloadIsTheLobbyAndItsVersionIsItsOwnHash(t *testing.T) {
	f := newRoomsFixture(t, nil)
	p := f.rooms.TableConfig()
	if !reflect.DeepEqual(p, f.rooms.TableConfig()) || p.Version != f.rooms.TableConfigVersion() {
		t.Fatal("two calls disagree")
	}
	if len(p.Version) != 64 {
		t.Fatalf("version %q", p.Version)
	}
	unversioned := p
	unversioned.Version = ""
	raw, err := json.Marshal(unversioned)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(raw)
	eq(t, p.Version, hex.EncodeToString(sum[:]), "version = sha256 of the payload without it")
	eq(t, p.Source, config.TableConfigSourceEnv, "source")

	// The lobby, entry for entry.
	o := f.rooms.LobbyOptions()
	if len(p.Tables) != len(o.Tables) {
		t.Fatalf("%d tables, the lobby has %d", len(p.Tables), len(o.Tables))
	}
	for i := range o.Tables {
		if p.Tables[i].LobbyTableOption != o.Tables[i] {
			t.Errorf("table %d: %+v, the lobby says %+v", i, p.Tables[i].LobbyTableOption, o.Tables[i])
		}
	}
	if !reflect.DeepEqual(p.Categories, o.Categories) || !reflect.DeepEqual(p.Stakes, o.Stakes) ||
		p.EntryCapBoot != o.EntryCapBoot || p.EntryCapCategory != o.EntryCapCategory || p.EntryCapMaxChips != o.EntryCapMaxChips ||
		p.PrivateBoot != o.PrivateBoot || p.PrivateMaxPot != o.PrivateMaxPot {
		t.Errorf("the lobby's own fields differ: %+v", p)
	}
	eq(t, p.MaxPlayers, 5, "maxPlayers")
	eq(t, p.BootAmount, int64(200), "bootAmount")
	eq(t, p.TurnTimeoutMs, int64(25000), "turnTimeoutMs")
	eq(t, p.MaxBetRounds, 20, "maxBetRounds (the generic figure)")

	// The contract, key for key (F6).
	raw, err = json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(top))
	for k := range top {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	wantKeys := []string{"bootAmount", "categories", "engines", "entryCapBoot", "entryCapCategory", "entryCapMaxChips", "maxBetRounds",
		"maxPlayers", "minPlayers", "privateBoot", "privateMaxPot", "privateTables", "sideshowMinPlayers", "sideshowTimeoutMs",
		"source", "stakes", "tables", "turnTimeoutMs", "version"}
	eq(t, strings.Join(keys, ","), strings.Join(wantKeys, ","), "top-level keys")
	if !strings.HasPrefix(string(raw), `{"version":"`+p.Version+`","source":"env","maxPlayers":5,`) {
		t.Errorf("payload starts %s", raw[:120])
	}
	first, _ := json.Marshal(p.Tables[0])
	eq(t, string(first), `{"category":"seen","bootAmount":200,"maxPot":2000000,"maxBlindMoves":4,"minChips":0,"maxChips":0,`+
		`"key":"seen:200","engine":"teen_patti","isPrivate":false,"sortOrder":10,"maxRaiseSteps":2,"maxBetRounds":7,"potLimitMultiplier":1024,`+
		`"turnTimeoutMs":25000,"maxMissedTurns":3,"sideshowTimeoutMs":6000,"sideshowMinPlayers":3,"nextHandDelayMs":4000,`+
		`"unfundedGraceMs":0,"missileRevealExtraMs":3000,"variationSelectTimeoutMs":0,"fiveCardPickTimeoutMs":0}`, "seen 200")
	holdem := payloadEntry(t, p.Tables, "texas_holdem:50000")
	if holdem.Game != game.GamePoker || holdem.Engine != config.EnginePoker || holdem.BigBlind != 50000 || holdem.MinBuyIn != 500000 ||
		holdem.MinChips != 500000 || holdem.TurnTimeoutMs != 25000 || holdem.MaxRaiseSteps != 0 {
		t.Errorf("hold'em %+v", holdem)
	}
	// Every entry names its engine, the Teen Patti ones too (game does not).
	for _, e := range append(append([]game.TableConfigEntry{}, p.Tables...), p.PrivateTables...) {
		if e.Engine != string(game.Category(e.Category).Game()) {
			t.Errorf("%s: engine %q", e.Key, e.Engine)
		}
	}
	// The taxonomy after the tables: both engines, each with its categories,
	// in order — from env, the defaults.
	engines, _ := json.Marshal(p.Engines)
	eq(t, string(engines), `[{"code":"teen_patti","name":"Teen Patti","sortOrder":10,"categories":[`+
		`{"code":"seen","name":"Seen","sortOrder":10},{"code":"blind","name":"Blind","sortOrder":20},{"code":"variation","name":"Variation","sortOrder":30}]},`+
		`{"code":"poker","name":"Poker","sortOrder":20,"categories":[`+
		`{"code":"three_card_poker","name":"3-Card Poker","sortOrder":40},{"code":"five_card_draw","name":"5-Card Draw","sortOrder":50},`+
		`{"code":"texas_holdem","name":"Texas Hold'em","sortOrder":60},{"code":"omaha","name":"Omaha","sortOrder":70}]}]`, "engines")
	if !strings.Contains(string(raw), `,"privateTables":[`) || !strings.HasSuffix(string(raw), `"sortOrder":70}]}]}`) {
		t.Error("engines must come last, after privateTables")
	}
	variation := payloadEntry(t, p.Tables, "variation:50000")
	if variation.VariationSelectTimeoutMs != 10000 || variation.FiveCardPickTimeoutMs != 8000 {
		t.Errorf("variation %+v", variation)
	}

	// One private template per category (variation is offered), band 0.
	if len(p.PrivateTables) != 7 {
		t.Fatalf("private templates %+v", p.PrivateTables)
	}
	seen := p.PrivateTables[0]
	if seen.Key != "private:seen" || !seen.IsPrivate || seen.SortOrder != 1010 || seen.BootAmount != 200 || seen.MaxPot != 500000 || seen.MaxRaiseSteps != 2 {
		t.Errorf("private seen %+v", seen)
	}
	for _, e := range p.PrivateTables {
		if e.MinChips != 0 || e.MaxChips != 0 || !e.IsPrivate {
			t.Errorf("a private template has a band: %+v", e)
		}
	}
	if e := payloadEntry(t, p.PrivateTables, "private:omaha"); e.Game != game.GamePoker || e.Engine != config.EnginePoker || e.MinBuyIn != 2000 || e.BigBlind != 200 {
		t.Errorf("private omaha %+v", e)
	}

	// A copy: changing it changes nothing.
	p.Tables[0].MaxPot, p.Stakes[0], p.Categories[0], p.PrivateTables[0].Key = 1, 1, "x", "x"
	p.Engines[0].Name, p.Engines[0].Categories[0].Code = "x", "x"
	if again := f.rooms.TableConfig(); again.Tables[0].MaxPot != 2000000 || again.Stakes[0] != 200 || again.Categories[0] != game.CategorySeen ||
		again.PrivateTables[0].Key != "private:seen" || again.Engines[0].Name != "Teen Patti" || again.Engines[0].Categories[0].Code != "seen" {
		t.Error("TableConfig must hand out a copy")
	}

	// Never null: the lifted menu's empty stakes and tables are arrays, and
	// so is the category list of an engine that has none left.
	open := newRoomsFixture(t, openMenu)
	raw, err = json.Marshal(open.rooms.TableConfig())
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"stakes":[]`, `"tables":[]`, `"privateTables":[{`, `"categories":["seen","blind","variation"]`, `"engines":[{`} {
		if !strings.Contains(string(raw), want) {
			t.Errorf("lifted menu: no %s in %s", want, raw)
		}
	}
	bare := newRoomsFixture(t, dbCatalogue(t, func(cat *config.TableCatalogue) {
		cat.Categories = cat.Categories[:3] // Poker keeps its engine row and loses every category
		var public, private []config.TableSpec
		for _, spec := range cat.Public {
			if spec.Engine == config.EngineTeenPatti {
				public = append(public, spec)
			}
		}
		for _, spec := range cat.Private {
			if spec.Engine == config.EngineTeenPatti {
				private = append(private, spec)
			}
		}
		cat.Public, cat.Private = public, private
	}))
	raw, err = json.Marshal(bare.rooms.TableConfig().Engines)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(string(raw), `{"code":"poker","name":"Poker","sortOrder":20,"categories":[]}]`) {
		t.Errorf("an engine with no category: %s", raw)
	}
	// Any change is a new version: another menu, or the same figures from
	// the database (source db).
	if open.rooms.TableConfigVersion() == f.rooms.TableConfigVersion() {
		t.Error("a different menu kept the version")
	}
	db := newRoomsFixture(t, dbCatalogue(t, nil))
	if db.rooms.TableConfig().Source != config.TableConfigSourceDB || db.rooms.TableConfigVersion() == f.rooms.TableConfigVersion() {
		t.Error("the db catalogue must say so and version differently")
	}
	edited := newRoomsFixture(t, dbCatalogue(t, func(cat *config.TableCatalogue) {
		catalogueRow(t, cat, "blind:200").TurnTimeout = 30 * time.Second
	}))
	if edited.rooms.TableConfigVersion() == db.rooms.TableConfigVersion() {
		t.Error("an edited row kept the version")
	}
	renamed := newRoomsFixture(t, dbCatalogue(t, func(cat *config.TableCatalogue) {
		cat.Categories[0].Name = "Open"
	}))
	if renamed.rooms.TableConfigVersion() == db.rooms.TableConfigVersion() {
		t.Error("a renamed category kept the version")
	}
	eq(t, renamed.rooms.TableConfig().Engines[0].Categories[0].Name, "Open", "the category's own name")
	// ...and the same configuration, the same version, whichever manager.
	eq(t, newRoomsFixture(t, dbCatalogue(t, nil)).rooms.TableConfigVersion(), db.rooms.TableConfigVersion(), "deterministic")
}
