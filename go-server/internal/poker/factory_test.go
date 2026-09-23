package poker

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/testclock"
)

// TestConfigForStillComposesWhatItAlwaysDid: ConfigFor is now ConfigFromSpec
// over config.GameConfig.Spec, and from env it must give every variant exactly
// the figures it composed before the table catalogue existed — the deployed
// rooms' snapshots are built from it, byte for byte.
func TestConfigForStillComposesWhatItAlwaysDid(t *testing.T) {
	g := config.Defaults().Game
	chat := config.Defaults().Chat
	for _, v := range []Variant{ThreeCardPoker, FiveCardDraw, TexasHoldem, Omaha} {
		for _, boot := range []int64{0, 200, 50000} {
			got, err := ConfigFor(v.Category(), boot, g, chat)
			if err != nil {
				t.Fatalf("%s %d: %v", v, boot, err)
			}
			wantBoot := boot
			if wantBoot == 0 {
				wantBoot = g.BootAmount
			}
			want := Config{
				Category: v.Category(), Variant: Variants[v], BootAmount: wantBoot,
				MaxPlayers: 5, MinPlayers: 2, TurnTimeout: 25 * time.Second, NextHandDelay: 4 * time.Second,
				UnfundedGrace: 30 * time.Second, MaxMissedTurns: 3,
				// Ten boots, and POKER_MAX_DISCARDS on EVERY variant, as ever.
				MinBuyIn: wantBoot * 10, MaxDiscards: 3,
				ChatMaxHistory: chat.MaxHistory, ChatMaxLength: chat.MaxLength,
			}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("%s %d:\n got %+v\nwant %+v", v, boot, got, want)
			}
		}
	}
	// The three knobs: POKER_TURN_TIMEOUT_MS wins over the table clock, the
	// buy-in is at least one boot, the exchange limit is clamped to 0..5.
	g.Poker = config.PokerConfig{TurnTimeout: 90 * time.Second, MinBuyInBoots: 0, MaxDiscards: 9}
	got, err := ConfigFor(game.CategoryFiveCardDraw, 1000, g, chat)
	if err != nil || got.TurnTimeout != 90*time.Second || got.MinBuyIn != 1000 || got.MaxDiscards != 5 {
		t.Errorf("knobs: %+v %v", got, err)
	}
	if _, err := ConfigFor(game.CategorySeen, 200, g, chat); err == nil {
		t.Error("a Teen Patti category is not a poker room")
	}
}

// TestConfigFromSpecTakesEveryFigureFromTheSpec: a table_configs row's own
// figures are what the room plays by — none of them is re-derived from the
// env keys — and a spec that cannot open the room asked for is refused.
func TestConfigFromSpecTakesEveryFigureFromTheSpec(t *testing.T) {
	spec := config.TableSpec{
		Key: "omaha:7000", Category: "omaha", BootAmount: 7000,
		MaxPlayers: 4, MinPlayers: 3, TurnTimeout: 33 * time.Second, MaxMissedTurns: 2,
		NextHandDelay: 2 * time.Second, UnfundedGrace: 9 * time.Second, MinBuyIn: 123456, MaxDiscards: 1,
	}
	cfg, err := ConfigFromSpec(game.CategoryOmaha, spec, config.ChatConfig{MaxHistory: 7, MaxLength: 70})
	if err != nil {
		t.Fatal(err)
	}
	want := Config{
		Category: game.CategoryOmaha, Variant: Variants[Omaha], BootAmount: 7000, MaxPlayers: 4, MinPlayers: 3,
		TurnTimeout: 33 * time.Second, NextHandDelay: 2 * time.Second, UnfundedGrace: 9 * time.Second,
		MaxMissedTurns: 2, MinBuyIn: 123456, MaxDiscards: 1, ChatMaxHistory: 7, ChatMaxLength: 70,
	}
	if !reflect.DeepEqual(cfg, want) {
		t.Errorf("\n got %+v\nwant %+v", cfg, want)
	}

	refused := []struct {
		name     string
		category game.Category
		edit     func(*config.TableSpec)
		want     string
	}{
		{"a Teen Patti category", game.CategorySeen, func(*config.TableSpec) {}, "not a poker category"},
		{"another variant's spec", game.CategoryTexasHoldem, func(*config.TableSpec) {}, "cannot open"},
		{"no boot", game.CategoryOmaha, func(s *config.TableSpec) { s.BootAmount = 0 }, "boot"},
		{"too many discards", game.CategoryOmaha, func(s *config.TableSpec) { s.MaxDiscards = 6 }, "discards"},
	}
	for _, tc := range refused {
		s := spec
		tc.edit(&s)
		if _, err := ConfigFromSpec(tc.category, s, config.ChatConfig{}); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: %v", tc.name, err)
		}
	}
}

// TestTheFactoryOpensARoomFromTheManagersSpec: the RoomManager hands the
// factory the spec it resolved (RoomSpec.Table) and the room plays by it, not
// by a second composition from RoomDeps.Game; with no spec (a caller from
// before the catalogue) the factory composes as it always did. Either way the
// room says what it plays by (RulesSpec), which is the spec it was built from.
func TestTheFactoryOpensARoomFromTheManagersSpec(t *testing.T) {
	g := config.Defaults().Game
	deps := game.RoomDeps{Game: g, Chat: config.Defaults().Chat, Clock: testclock.New(start)}
	f := &Factory{}

	spec := g.Spec("texas_holdem", 50000, false)
	spec.MinBuyIn, spec.TurnTimeout = 200000, 40*time.Second
	room, err := f.New(game.RoomSpec{ID: "r1", Code: "ROOMCODE", Category: game.CategoryTexasHoldem, BootAmount: 50000, Table: spec}, deps)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = room.Destroy() }()
	cfg := room.(*Table).Config()
	if cfg.MinBuyIn != 200000 || cfg.TurnTimeout != 40*time.Second || cfg.BootAmount != 50000 {
		t.Errorf("the spec's figures were not used: %+v", cfg)
	}
	got := room.RulesSpec()
	if got.Key != "texas_holdem:50000" || !got.SameRules(spec) || got.MinChips != 0 || got.MaxChips != 0 || got.SortOrder != 0 {
		t.Errorf("RulesSpec\n got %+v\nwant %+v", got, spec)
	}

	composed, err := f.New(game.RoomSpec{ID: "r2", Code: "ROOMCOD2", Category: game.CategoryFiveCardDraw, BootAmount: 200, IsPrivate: true}, deps)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = composed.Destroy() }()
	if cfg := composed.(*Table).Config(); cfg.MinBuyIn != 2000 || cfg.MaxDiscards != 3 || cfg.TurnTimeout != 25*time.Second {
		t.Errorf("composed: %+v", cfg)
	}
	if got := composed.RulesSpec(); got.Key != "private:five_card_draw" || !got.Private {
		t.Errorf("a private room's key: %+v", got)
	}

	// A restored room says the same as the room it was saved from.
	h := newHarness(t, FiveCardDraw)
	var data []byte
	h.read(func() { data, err = h.table.marshalSnapshot(1) })
	if err != nil {
		t.Fatal(err)
	}
	back, _, err := f.Restore(data, deps)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = back.Destroy() }()
	if a, b := h.table.RulesSpec(), back.RulesSpec(); a != b {
		t.Errorf("restored\n got %+v\nwant %+v", b, a)
	}
}

// TestAMenuEntryIsFilledFromTheSpec: the lobby card is the room's own
// figures — blinds or the ante from the spec's boot, its buy-in, its hole
// cards and (a draw table only) its exchange limit.
func TestAMenuEntryIsFilledFromTheSpec(t *testing.T) {
	f := &Factory{}
	g := config.Defaults().Game

	holdem := g.Spec("texas_holdem", 5000, false)
	holdem.MinBuyIn = 12345
	var o game.LobbyTableOption
	f.MenuEntry(holdem, &o)
	if o.Game != game.GamePoker || o.SmallBlind != 2500 || o.BigBlind != 5000 || o.Ante != 0 || o.MinBuyIn != 12345 || o.HoleCards != 2 || o.MaxDiscards != 0 {
		t.Errorf("hold'em %+v", o)
	}

	draw := g.Spec("five_card_draw", 200, false)
	draw.MaxDiscards = 2
	o = game.LobbyTableOption{}
	f.MenuEntry(draw, &o)
	if o.Ante != 200 || o.BigBlind != 0 || o.HoleCards != 5 || o.MaxDiscards != 2 || o.MinBuyIn != 2000 {
		t.Errorf("draw %+v", o)
	}

	// A spec that cannot open a room fills nothing.
	o = game.LobbyTableOption{}
	f.MenuEntry(g.Spec("seen", 200, false), &o)
	if o != (game.LobbyTableOption{}) {
		t.Errorf("a Teen Patti spec filled %+v", o)
	}
}
