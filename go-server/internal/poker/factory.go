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

// ConfigFor composes a poker room's Config from the deployment's config and
// a category + boot: the variant's fixed table plus the few PokerConfig
// knobs. Exported for tests and the menu.
func ConfigFor(category game.Category, bootAmount int64, g config.GameConfig, chat config.ChatConfig) (Config, error) {
	v, ok := VariantOf(category)
	if !ok {
		return Config{}, fmt.Errorf("%q is not a poker category", category)
	}
	if bootAmount <= 0 {
		bootAmount = g.BootAmount
	}
	turn := g.Poker.TurnTimeout
	if turn <= 0 {
		turn = g.TurnTimeout
	}
	buyInBoots := g.Poker.MinBuyInBoots
	if buyInBoots < 1 {
		buyInBoots = 1
	}
	discards := g.Poker.MaxDiscards
	if discards < 0 {
		discards = 0
	}
	if discards > 5 {
		discards = 5
	}
	return Config{
		Category:       category,
		Variant:        Variants[v],
		BootAmount:     bootAmount,
		MaxPlayers:     g.MaxPlayers,
		MinPlayers:     g.MinPlayers,
		TurnTimeout:    turn,
		NextHandDelay:  g.NextHandDelay,
		UnfundedGrace:  g.UnfundedGrace,
		MaxMissedTurns: g.MaxMissedTurns,
		MinBuyIn:       bootAmount * buyInBoots,
		MaxDiscards:    discards,
		ChatMaxHistory: chat.MaxHistory,
		ChatMaxLength:  chat.MaxLength,
	}, nil
}

// New opens a fresh room for spec.
func (f *Factory) New(spec game.RoomSpec, deps game.RoomDeps) (game.Room, error) {
	cfg, err := ConfigFor(spec.Category, spec.BootAmount, deps.Game, deps.Chat)
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
// the hole cards and the draw limit, from the same ConfigFor the room is
// built with, so a card never promises rules its table does not play.
func (f *Factory) MenuEntry(entry config.LobbyTable, g config.GameConfig, option *game.LobbyTableOption) {
	cfg, err := ConfigFor(game.Category(entry.Category), entry.BootAmount, g, config.ChatConfig{})
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
