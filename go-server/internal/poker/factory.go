package poker

import (
	"fmt"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Factory opens and restores poker rooms for the RoomManager
// (game.RoomFactory; RoomManagerOptions.Factories[game.GamePoker]). The app
// builds one with the socket layer as its Listener.
type Factory struct {
	Listener Listener
}

var _ game.RoomFactory = (*Factory)(nil)

// ConfigFor composes a public poker room's Config from the deployment's config
// and a category + boot (0 = BOOT_AMOUNT): ConfigFromSpec over
// config.GameConfig.Spec, which is the table_configs row in db mode and, from
// env, the variant's fixed table plus the few PokerConfig knobs. Exported for
// tests.
func ConfigFor(category game.Category, bootAmount int64, g config.GameConfig, chat config.ChatConfig) (Config, error) {
	if _, ok := VariantOf(category); !ok {
		return Config{}, fmt.Errorf("%q is not a poker category", category)
	}
	return ConfigFromSpec(category, g.Spec(string(category), bootAmount, false), chat)
}

// ConfigFromSpec is the Config of a poker room of category that plays by spec
// (config.TableSpec: its boot — the big blind or the ante —, the players, the
// clocks, the buy-in and 5-Card Draw's exchange limit), with the variant's
// fixed table and the server's chat caps. Every variant carries MaxDiscards,
// as the env composition always gave it; only a draw table reads it. spec must
// be for category — the RoomManager asks Spec for the category it opens.
func ConfigFromSpec(category game.Category, spec config.TableSpec, chat config.ChatConfig) (Config, error) {
	v, ok := VariantOf(category)
	if !ok {
		return Config{}, fmt.Errorf("%q is not a poker category", category)
	}
	if spec.Category != string(category) {
		return Config{}, fmt.Errorf("a %s spec cannot open a %s room", spec.Category, category)
	}
	if spec.BootAmount <= 0 {
		return Config{}, fmt.Errorf("%s: the boot must be more than 0, got %d", category, spec.BootAmount)
	}
	if spec.MaxDiscards < 0 || spec.MaxDiscards > 5 {
		return Config{}, fmt.Errorf("%s: max discards must be between 0 and 5, got %d", category, spec.MaxDiscards)
	}
	return Config{
		Category:       category,
		Variant:        Variants[v],
		BootAmount:     spec.BootAmount,
		MaxPlayers:     spec.MaxPlayers,
		MinPlayers:     spec.MinPlayers,
		TurnTimeout:    spec.TurnTimeout,
		NextHandDelay:  spec.NextHandDelay,
		UnfundedGrace:  spec.UnfundedGrace,
		MaxMissedTurns: spec.MaxMissedTurns,
		MinBuyIn:       spec.MinBuyIn,
		MaxDiscards:    spec.MaxDiscards,
		ChatMaxHistory: chat.MaxHistory,
		ChatMaxLength:  chat.MaxLength,
	}, nil
}

// New opens a fresh room for spec: from spec.Table when the RoomManager
// resolved one (always, since the table catalogue), else composed from
// deps.Game as ConfigFor does.
func (f *Factory) New(spec game.RoomSpec, deps game.RoomDeps) (game.Room, error) {
	var cfg Config
	var err error
	if spec.Table.Key != "" {
		cfg, err = ConfigFromSpec(spec.Category, spec.Table, deps.Chat)
	} else {
		cfg, err = ConfigFor(spec.Category, spec.BootAmount, deps.Game, deps.Chat)
	}
	if err != nil {
		return nil, err
	}
	if cfg.MaxPlayers*cfg.Variant.HoleCards+cfg.Variant.CommunityCards+cfg.Variant.HoleCards > 52 {
		return nil, fmt.Errorf("%s at %d seats does not fit one deck", cfg.Variant.Name, cfg.MaxPlayers)
	}
	id, code := spec.ID, spec.Code
	if id == "" {
		id = util.UUID()
	}
	if code == "" {
		code = util.RoomCode(util.DefaultRoomCodeLength)
	}
	return NewTable(TableOptions{ID: id, Code: code, Config: cfg, IsPrivate: spec.IsPrivate, Listener: f.Listener, Deps: deps}), nil
}

// Restore rebuilds a room from its stored document, without arming clocks.
func (f *Factory) Restore(data []byte, deps game.RoomDeps) (game.Room, game.RestoredRoom, error) {
	snap, err := ParseSnapshot(data)
	if err != nil {
		return nil, game.RestoredRoom{}, err
	}
	t, err := restoreTable(snap, TableOptions{Listener: f.Listener, Deps: deps})
	if err != nil {
		return nil, game.RestoredRoom{}, err
	}
	info := game.RestoredRoom{}
	for _, s := range snap.Seats {
		if s != nil {
			info.Seats = append(info.Seats, s.UserID)
		}
	}
	if snap.Hand != nil {
		info.HandID = snap.Hand.ID
	}
	return t, info, nil
}

// MenuEntry fills a poker lobby entry: the blinds or the ante, the buy-in,
// the hole cards and the draw limit, from the same spec — through the same
// ConfigFromSpec — the room is built with, so a card never promises rules its
// table does not play.
func (f *Factory) MenuEntry(spec config.TableSpec, option *game.LobbyTableOption) {
	cfg, err := ConfigFromSpec(game.Category(spec.Category), spec, config.ChatConfig{})
	if err != nil {
		return
	}
	option.Game = game.GamePoker
	option.MinBuyIn = cfg.MinBuyIn
	option.HoleCards = cfg.Variant.HoleCards
	if cfg.Variant.Blinds {
		option.SmallBlind = cfg.BootAmount / 2
		option.BigBlind = cfg.BootAmount
	} else {
		option.Ante = cfg.BootAmount
	}
	if cfg.Variant.HasDraw {
		option.MaxDiscards = cfg.MaxDiscards
	}
}

// turnTimeoutOf is the decision clock a room runs (for the socket layer's
// public config, where a poker room's differs from a Teen Patti table's).
func (t *Table) TurnTimeout() time.Duration { return t.cfg.TurnTimeout }

// RulesSpec is the room's frozen Config as a config.TableSpec (game.Room):
// its key, category and boot, the players, the clocks, the buy-in and the
// exchange limit. Everything a poker room does not have — the Teen Patti
// ladder, pot cap, blind moves, sideshow, missile and variation figures — is
// 0, as a poker spec's always is (config.TableCatalogue.Validate), and so are
// the band and the menu position, which are the lobby's.
func (t *Table) RulesSpec() config.TableSpec {
	c := t.cfg
	spec := config.TableSpec{
		Category:       string(c.Category),
		BootAmount:     c.BootAmount,
		Private:        t.isPrivate,
		MaxPlayers:     c.MaxPlayers,
		MinPlayers:     c.MinPlayers,
		TurnTimeout:    c.TurnTimeout,
		MaxMissedTurns: c.MaxMissedTurns,
		NextHandDelay:  c.NextHandDelay,
		UnfundedGrace:  c.UnfundedGrace,
		MinBuyIn:       c.MinBuyIn,
		MaxDiscards:    c.MaxDiscards,
	}
	if t.isPrivate {
		spec.Key = config.PrivateTableKey(spec.Category)
	} else {
		spec.Key = config.PublicTableKey(spec.Category, spec.BootAmount)
	}
	return spec
}
