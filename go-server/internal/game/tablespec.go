package game

// A Teen Patti table and config.TableSpec, both ways (owner, 23 Sep 2026:
// "all table related config store in database"). A new table's TableConfig is
// built from the one TableSpec the configuration gives its category and boot
// (config.GameConfig.Spec — the table_configs row in db mode, the env
// composition otherwise), and a table can say what it plays by as a TableSpec
// (RulesSpec), which is how the RoomManager tells a table restored from the
// live store that no longer matches its row from one that does.

import (
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
)

// tableConfigFromSpec is the TableConfig a new table of resolved plays by:
// every figure from spec, the chat caps from chat (they are the server's, not
// a table's). The category is the one the manager resolved — spec is always
// asked for that same category, so they agree. A seen or blind spec carries
// no variation window (Spec composes none and Validate zeroes a row's), so a
// seen or blind table's config — and its snapshot in the live store — is
// exactly what it was before variation tables existed.
func tableConfigFromSpec(resolved Category, spec config.TableSpec, chat config.ChatConfig) TableConfig {
	cfg := TableConfig{
		Category:           resolved,
		BootAmount:         spec.BootAmount,
		MaxPlayers:         spec.MaxPlayers,
		MinPlayers:         spec.MinPlayers,
		TurnTimeout:        spec.TurnTimeout,
		MaxBetRounds:       spec.MaxBetRounds,
		PotLimitMultiplier: spec.PotLimitMultiplier,
		MaxRaiseSteps:      spec.MaxRaiseSteps,
		MaxPot:             spec.MaxPot,
		MaxBlindMoves:      spec.MaxBlindMoves,
		MaxMissedTurns:     spec.MaxMissedTurns,
		SideshowTimeout:    spec.SideshowTimeout,
		SideshowMinPlayers: spec.SideshowMinPlayers,
		NextHandDelay:      spec.NextHandDelay,
		UnfundedGrace:      spec.UnfundedGrace,
		MissileRevealExtra: spec.MissileRevealExtra,
		ChatMaxHistory:     chat.MaxHistory,
		ChatMaxLength:      chat.MaxLength,
	}
	if resolved.HasVariation() {
		cfg.VariationSelectTimeout = spec.VariationSelectTimeout
		cfg.FiveCardPickTimeout = spec.FiveCardPickTimeout
	}
	return cfg
}

// RulesSpec is the table's frozen TableConfig as a config.TableSpec (Room):
// its key, its category and boot, and every figure it plays by. The band and
// the menu position are the lobby's, so they are 0; so are the poker figures,
// which a Teen Patti table has none of. A table built from a spec gives that
// spec back, band and position aside (TestATableSaysWhatItPlaysBy).
func (t *Table) RulesSpec() config.TableSpec {
	c := t.cfg
	spec := config.TableSpec{
		Category:           string(c.Category),
		BootAmount:         c.BootAmount,
		Private:            t.isPrivate,
		MaxPot:             c.MaxPot,
		MaxRaiseSteps:      c.MaxRaiseSteps,
		MaxBetRounds:       c.MaxBetRounds,
		PotLimitMultiplier: c.PotLimitMultiplier,
		MaxBlindMoves:      c.MaxBlindMoves,
		MaxPlayers:         c.MaxPlayers,
		MinPlayers:         c.MinPlayers,
		TurnTimeout:        c.TurnTimeout,
		MaxMissedTurns:     c.MaxMissedTurns,
		SideshowTimeout:    c.SideshowTimeout,
		SideshowMinPlayers: c.SideshowMinPlayers,
		NextHandDelay:      c.NextHandDelay,
		UnfundedGrace:      c.UnfundedGrace,
		MissileRevealExtra: c.MissileRevealExtra,
	}
	if c.Category.HasVariation() {
		spec.VariationSelectTimeout = c.VariationSelectTimeout
		spec.FiveCardPickTimeout = c.FiveCardPickTimeout
	}
	if t.isPrivate {
		spec.Key = config.PrivateTableKey(spec.Category)
	} else {
		spec.Key = config.PublicTableKey(spec.Category, spec.BootAmount)
	}
	return spec
}
