package game

// The lobby menu and the table catalogue as the RoomManager serves them
// (owner, 23 Sep 2026: "the UI fetches it, stores it on the phone, and
// re-fetches it at every login"). Both are built from config.GameConfig.Spec
// — the one answer newTableLocked builds a table from — so what a client is
// told a table plays by is what that table plays by.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
)

// menuRow is one lobby menu entry with the TableSpec the table behind it is
// opened with.
type menuRow struct {
	option LobbyTableOption
	spec   config.TableSpec
}

// menuRows is the lobby menu in display order: one row per LobbyTables entry
// (a repeated pair repeats, as the menu always has), each carrying the rules
// of the table that entry opens and the stack band it is for. It reads only
// the immutable config, so it needs no lock.
func (rm *RoomManager) menuRows() []menuRow {
	g := rm.game
	rows := make([]menuRow, 0, len(g.LobbyTables))
	for _, entry := range g.LobbyTables {
		spec := g.Spec(entry.Category, entry.BootAmount, false)
		// The category and boot as the entry states them — byte for byte
		// what the menu has always sent — and the band the doors enforce
		// (the entry cap folded in, tableMaxChips).
		option := rm.menuOption(spec, entry.Category, entry.BootAmount, rm.tableMinChips(entry), rm.tableMaxChips(entry))
		rows = append(rows, menuRow{option: option, spec: spec})
	}
	return rows
}

// menuOption is the lobby entry for a table opened from spec. A poker entry
// carries its family's own facts (blinds, ante, buy-in, hole cards) instead
// of the Teen Patti ones, which mean nothing at a poker table: its factory
// fills them in from the same spec the room is built from and the Teen Patti
// figures are zeroed; a public poker entry's floor is raised to the buy-in,
// so the band and the buy-in agree (a private template has no band).
func (rm *RoomManager) menuOption(spec config.TableSpec, category string, bootAmount, minChips, maxChips int64) LobbyTableOption {
	option := LobbyTableOption{
		Category:      category,
		BootAmount:    bootAmount,
		MaxPot:        spec.MaxPot, // 0 means the pot is uncapped
		MaxBlindMoves: spec.MaxBlindMoves,
		MinChips:      minChips,
		MaxChips:      maxChips,
	}
	if c := Category(category); c.IsPoker() {
		option.Game = GamePoker
		option.MaxPot = 0
		option.MaxBlindMoves = 0
		if factory := rm.factoryFor(c); factory != nil {
			factory.MenuEntry(spec, &option)
		}
		if !spec.Private && option.MinChips < option.MinBuyIn {
			option.MinChips = option.MinBuyIn
		}
	}
	return option
}

// TableConfigPayload is the table catalogue as a client stores it — the body
// of GET /api/tables — and, through Version, what session:ready's
// tableConfigVersion names. Its scalars and Categories, Stakes, EntryCap* and
// Private* are session:ready.config's own (so a client can parse either with
// one reader); Tables is session:ready.config.tables entry for entry with
// every other figure the table plays by beside it; PrivateTables is the
// private template of every category a room:create can open; Engines is the
// taxonomy the lobby groups them by (owner, 23 Sep 2026: "Teen Patti engines /
// Poker engines"). Nothing session-scoped is here (no welcomeChips, no
// minClientBuild): a client caches this across sessions and players. Every
// slice is non-nil.
type TableConfigPayload struct {
	// Version is the hex sha256 of this payload marshalled with Version "":
	// it changes exactly when anything a client would read here changes.
	Version string `json:"version"`
	// Source is where the catalogue came from: "db" (table_configs) or
	// "env" (the env keys composed; config.TableConfigSourceEnv).
	Source string `json:"source"`

	MaxPlayers         int   `json:"maxPlayers"`
	MinPlayers         int   `json:"minPlayers"`
	BootAmount         int64 `json:"bootAmount"`
	TurnTimeoutMs      int64 `json:"turnTimeoutMs"`
	MaxBetRounds       int   `json:"maxBetRounds"`
	SideshowTimeoutMs  int64 `json:"sideshowTimeoutMs"`
	SideshowMinPlayers int   `json:"sideshowMinPlayers"`

	Categories       []Category `json:"categories"`
	Stakes           []int64    `json:"stakes"`
	EntryCapBoot     int64      `json:"entryCapBoot"`
	EntryCapCategory string     `json:"entryCapCategory"`
	EntryCapMaxChips int64      `json:"entryCapMaxChips"`
	PrivateBoot      int64      `json:"privateBoot"`
	PrivateMaxPot    int64      `json:"privateMaxPot"`

	Tables        []TableConfigEntry `json:"tables"`
	PrivateTables []TableConfigEntry `json:"privateTables"`
	// Engines is every active engine, in its order, each with its active
	// categories in theirs (config.TableCatalogue's Engines and Categories:
	// table_engines and table_categories in db mode, the defaults from env).
	Engines []TableConfigEngine `json:"engines"`
}

// TableConfigEngine is one engine of the catalogue — Teen Patti or Poker —
// and the categories it plays. Name is the database's admin label; a client
// names the engines and categories it knows in its own language and falls
// back to Name for a code it does not.
type TableConfigEngine struct {
	Code       string                `json:"code"`
	Name       string                `json:"name"`
	SortOrder  int                   `json:"sortOrder"`
	Categories []TableConfigCategory `json:"categories"`
}

// TableConfigCategory is one category under its engine.
type TableConfigCategory struct {
	Code      string `json:"code"`
	Name      string `json:"name"`
	SortOrder int    `json:"sortOrder"`
}

// TableConfigEntry is one table of the catalogue: the lobby entry exactly as
// session:ready.config.tables carries it (same keys, same values — a poker
// entry's facts included), then the key, the engine and every figure the
// table plays by. Durations are in ms, as everywhere on the wire. There is no
// per-table maxPlayers or minPlayers: the server has one of each
// (TableSettings), which the payload's own scalars carry.
type TableConfigEntry struct {
	LobbyTableOption

	// Key is table_configs.table_key: "category:boot", or "private:category".
	Key string `json:"key"`
	// Engine is the engine the table's category belongs to, "teen_patti" or
	// "poker" (config.EngineOf) — always present, unlike the poker-only game.
	Engine    string `json:"engine"`
	IsPrivate bool   `json:"isPrivate"`
	// SortOrder is the menu position (public) or the template's (private).
	SortOrder int `json:"sortOrder"`

	MaxRaiseSteps            int   `json:"maxRaiseSteps"`
	MaxBetRounds             int   `json:"maxBetRounds"`
	PotLimitMultiplier       int64 `json:"potLimitMultiplier"`
	TurnTimeoutMs            int64 `json:"turnTimeoutMs"`
	MaxMissedTurns           int   `json:"maxMissedTurns"`
	SideshowTimeoutMs        int64 `json:"sideshowTimeoutMs"`
	SideshowMinPlayers       int   `json:"sideshowMinPlayers"`
	NextHandDelayMs          int64 `json:"nextHandDelayMs"`
	UnfundedGraceMs          int64 `json:"unfundedGraceMs"`
	MissileRevealExtraMs     int64 `json:"missileRevealExtraMs"`
	VariationSelectTimeoutMs int64 `json:"variationSelectTimeoutMs"`
	FiveCardPickTimeoutMs    int64 `json:"fiveCardPickTimeoutMs"`
}

// tableConfigEntry is option with spec's figures beside it.
func tableConfigEntry(option LobbyTableOption, spec config.TableSpec) TableConfigEntry {
	engine := spec.Engine
	if engine == "" {
		engine = config.EngineOf(spec.Category)
	}
	return TableConfigEntry{
		LobbyTableOption:         option,
		Key:                      spec.Key,
		Engine:                   engine,
		IsPrivate:                spec.Private,
		SortOrder:                spec.SortOrder,
		MaxRaiseSteps:            spec.MaxRaiseSteps,
		MaxBetRounds:             spec.MaxBetRounds,
		PotLimitMultiplier:       spec.PotLimitMultiplier,
		TurnTimeoutMs:            spec.TurnTimeout.Milliseconds(),
		MaxMissedTurns:           spec.MaxMissedTurns,
		SideshowTimeoutMs:        spec.SideshowTimeout.Milliseconds(),
		SideshowMinPlayers:       spec.SideshowMinPlayers,
		NextHandDelayMs:          spec.NextHandDelay.Milliseconds(),
		UnfundedGraceMs:          spec.UnfundedGrace.Milliseconds(),
		MissileRevealExtraMs:     spec.MissileRevealExtra.Milliseconds(),
		VariationSelectTimeoutMs: spec.VariationSelectTimeout.Milliseconds(),
		FiveCardPickTimeoutMs:    spec.FiveCardPickTimeout.Milliseconds(),
	}
}

// buildTableConfig computes the payload and its version. NewRoomManager calls
// it once: the configuration it reads never changes after construction.
func (rm *RoomManager) buildTableConfig() TableConfigPayload {
	g := rm.game
	lobby := rm.LobbyOptions()
	cat := g.EffectiveCatalogue()
	payload := TableConfigPayload{
		Source:             cat.Source,
		MaxPlayers:         g.MaxPlayers,
		MinPlayers:         g.MinPlayers,
		BootAmount:         g.BootAmount,
		TurnTimeoutMs:      g.TurnTimeout.Milliseconds(),
		MaxBetRounds:       g.MaxBetRounds,
		SideshowTimeoutMs:  g.SideshowTimeout.Milliseconds(),
		SideshowMinPlayers: g.SideshowMinPlayers,
		Categories:         lobby.Categories,
		Stakes:             lobby.Stakes,
		EntryCapBoot:       lobby.EntryCapBoot,
		EntryCapCategory:   lobby.EntryCapCategory,
		EntryCapMaxChips:   lobby.EntryCapMaxChips,
		PrivateBoot:        lobby.PrivateBoot,
		PrivateMaxPot:      lobby.PrivateMaxPot,
	}
	menu := rm.menuRows()
	payload.Tables = make([]TableConfigEntry, 0, len(menu))
	for _, row := range menu {
		payload.Tables = append(payload.Tables, tableConfigEntry(row.option, row.spec))
	}
	payload.PrivateTables = make([]TableConfigEntry, 0, len(cat.Private))
	for _, spec := range cat.Private {
		option := rm.menuOption(spec, spec.Category, spec.BootAmount, 0, 0)
		payload.PrivateTables = append(payload.PrivateTables, tableConfigEntry(option, spec))
	}
	payload.Engines = make([]TableConfigEngine, 0, len(cat.Engines))
	for _, engine := range cat.Engines {
		entry := TableConfigEngine{Code: engine.Code, Name: engine.Name, SortOrder: engine.SortOrder, Categories: []TableConfigCategory{}}
		for _, category := range cat.Categories {
			if category.Engine == engine.Code {
				entry.Categories = append(entry.Categories, TableConfigCategory{Code: category.Code, Name: category.Name, SortOrder: category.SortOrder})
			}
		}
		payload.Engines = append(payload.Engines, entry)
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		// Plain structs of strings, numbers and slices cannot fail to marshal;
		// should one ever, the payload goes out with no version and the
		// client refetches it every time rather than trusting a stale copy.
		rm.log.Error("table config could not be versioned", "error", err.Error())
		return payload
	}
	sum := sha256.Sum256(raw)
	payload.Version = hex.EncodeToString(sum[:])
	return payload
}

// TableConfig is the table catalogue this manager enforces, as GET
// /api/tables serves it (TableConfigPayload): computed once at construction —
// the configuration is immutable — and handed out as a copy the caller may
// keep.
func (rm *RoomManager) TableConfig() TableConfigPayload {
	p := rm.tableConfig
	p.Categories = append([]Category{}, p.Categories...)
	p.Stakes = append([]int64{}, p.Stakes...)
	p.Tables = append([]TableConfigEntry{}, p.Tables...)
	p.PrivateTables = append([]TableConfigEntry{}, p.PrivateTables...)
	p.Engines = make([]TableConfigEngine, len(rm.tableConfig.Engines))
	for i, engine := range rm.tableConfig.Engines {
		engine.Categories = append([]TableConfigCategory{}, engine.Categories...)
		p.Engines[i] = engine
	}
	return p
}

// TableConfigVersion is TableConfig().Version: what session:ready's
// config.tableConfigVersion carries, so a client knows whether the catalogue
// it holds is the one this server runs.
func (rm *RoomManager) TableConfigVersion() string { return rm.tableConfig.Version }
