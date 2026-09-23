package config

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// Where a server takes its table configuration from (TABLE_CONFIG_SOURCE;
// owner, 23 Sep 2026: "all table related config store in database").
//
//   - TableConfigSourceDB: the table_settings row and the active table_configs
//     rows in PostgreSQL (V1.0.0__baseline.sql declares them, V1.0.1__seed.sql
//     fills a fresh database with exactly the Defaults() composition). Every
//     table env key is ignored — see TableEnvKeys.
//   - TableConfigSourceEnv: the env keys and Defaults(), composed exactly as the
//     server always has (TableRules, the poker knobs). The database rows are
//     seeded but not read. Tests, the parity harness and a deployment whose
//     .env still lists its menu run this way.
//
// Unset, the source is resolved by FromEnv: env when ANY table env key is set
// (so a deployment whose .env pins LOBBY_TABLES keeps exactly the menu it had
// until someone switches it on purpose), db otherwise.
const (
	TableConfigSourceDB  = "db"
	TableConfigSourceEnv = "env"
)

// TableEnvKeys is every env key that configures a table — the keys a
// db-sourced server ignores. A fresh slice each call: config holds no
// package-level mutable state.
func TableEnvKeys() []string {
	return []string{
		"BOOT_AMOUNT", "TABLE_STAKES", "LOBBY_TABLES",
		"MAX_PLAYERS_PER_ROOM", "MIN_PLAYERS_TO_START", "TURN_TIMEOUT_MS",
		"MAX_BET_ROUNDS", "POT_LIMIT_MULTIPLIER", "MAX_RAISE_STEPS",
		"SEEN_MAX_RAISE_STEPS", "SEEN_MAX_BET_ROUNDS", "SEEN_MAX_POT",
		"BLIND_MAX_RAISE_STEPS", "BLIND_MAX_BET_ROUNDS", "BLIND_POT_LIMIT_MULTIPLIER",
		"MAX_BLIND_MOVES", "ENTRY_CAP_BOOT", "ENTRY_CAP_CATEGORY", "ENTRY_CAP_MAX_CHIPS",
		"MAX_MISSED_TURNS", "SIDESHOW_TIMEOUT_MS", "SIDESHOW_MIN_PLAYERS",
		"PRIVATE_MAX_POT", "PRIVATE_MAX_RAISE_STEPS", "PRIVATE_BOOT",
		"NEXT_HAND_DELAY_MS", "UNFUNDED_GRACE_MS", "MISSILE_REVEAL_EXTRA_MS",
		"VARIATION_SELECT_TIMEOUT_MS", "VARIATION_MAX_POT_BOOTS", "FIVE_CARD_PICK_TIMEOUT_MS",
		"POKER_TURN_TIMEOUT_MS", "POKER_MIN_BUYIN_BOOTS", "POKER_MAX_DISCARDS",
	}
}

// Categories is every table category the engine knows, in the order the
// lobby and the private templates are listed: the three Teen Patti ones, then
// the poker family. The set is code, not data — a category is an engine
// (game.Category.Game, poker.Variants) — so the database stores the string
// and this package validates it (a CHECK listing them would freeze the set on
// every existing database, the trap V1.0.0's header describes for HAMMER).
func Categories() []string {
	return []string{
		CategorySeen, CategoryBlind, CategoryVariation,
		CategoryThreeCardPoker, CategoryFiveCardDraw, CategoryTexasHoldem, CategoryOmaha,
	}
}

// IsKnownCategory reports whether c is exactly one of Categories().
func IsKnownCategory(c string) bool {
	for _, known := range Categories() {
		if c == known {
			return true
		}
	}
	return false
}

// TableSettings is the one table_settings row: the figures that belong to no
// single table. MaxPlayers and MinPlayers are here, not on each table, because
// every installed client lays its seats out from the ONE maxPlayers that
// session:ready advertises; the rest are what session:ready advertises too.
type TableSettings struct {
	DefaultBootAmount  int64         // BOOT_AMOUNT: the stake a quick-join without one gets
	Stakes             []int64       // TABLE_STAKES, verbatim (order and duplicates kept); empty = any stake
	MaxPlayers         int           // MAX_PLAYERS_PER_ROOM
	MinPlayers         int           // MIN_PLAYERS_TO_START
	TurnTimeout        time.Duration // TURN_TIMEOUT_MS as advertised (each table has its own)
	MaxBetRounds       int           // MAX_BET_ROUNDS as advertised (the generic figure; each table has its own)
	SideshowTimeout    time.Duration // SIDESHOW_TIMEOUT_MS as advertised
	SideshowMinPlayers int           // SIDESHOW_MIN_PLAYERS as advertised
	EntryCapBoot       int64         // ENTRY_CAP_BOOT (requirement 30)
	EntryCapCategory   string        // ENTRY_CAP_CATEGORY
	EntryCapMaxChips   int64         // ENTRY_CAP_MAX_CHIPS; 0 disables
}

// TableSpec is every figure one table plays by, fully resolved: a public lobby
// table (one table_configs row, or one LOBBY_TABLES entry composed with the
// category rules), or the private-table template of one category. It is what
// a new Teen Patti TableConfig and a new poker Config are built from, what the
// lobby advertises and what GET /api/tables serves, so the card and the table
// can never disagree.
//
// Fields that mean nothing to a table's family are zero: a poker spec carries
// no ladder, pot cap, blind moves, sideshow or missile figures; a Teen Patti
// spec no buy-in or discards; only a variation spec has the two window
// lengths — which keeps a seen or blind table's TableConfig, and so its Redis
// snapshot, byte for byte what it always was.
type TableSpec struct {
	// Key is the table's identity: "category:boot" for a public table,
	// "private:category" for a private template — table_configs.table_key.
	Key        string
	Category   string
	BootAmount int64
	Private    bool

	// MinChips / MaxChips are the table's OWN stack band as written (0 = no
	// limit at that end); the entry cap is folded in by the RoomManager, not
	// here. Always 0 on a private template.
	MinChips int64
	MaxChips int64

	// Teen Patti betting: 0 means "no limit" for each (the blind rule).
	MaxPot             int64
	MaxRaiseSteps      int
	MaxBetRounds       int
	PotLimitMultiplier int64
	MaxBlindMoves      int

	// From TableSettings, carried here so a table is built from one value.
	MaxPlayers int
	MinPlayers int

	TurnTimeout        time.Duration
	MaxMissedTurns     int
	SideshowTimeout    time.Duration
	SideshowMinPlayers int
	NextHandDelay      time.Duration
	UnfundedGrace      time.Duration
	MissileRevealExtra time.Duration

	// Variation only.
	VariationSelectTimeout time.Duration
	FiveCardPickTimeout    time.Duration

	// Poker only: the smallest stack that may sit (absolute chips) and
	// 5-Card Draw's exchange limit (carried by every poker spec, as the env
	// composition always gave every variant POKER_MAX_DISCARDS; only a draw
	// table reads it).
	MinBuyIn    int64
	MaxDiscards int

	// SortOrder is the menu position (public) — the order the lobby shows.
	SortOrder int
}

// PublicTableKey / PrivateTableKey are table_configs.table_key for a spec.
func PublicTableKey(category string, bootAmount int64) string {
	return category + ":" + strconv.FormatInt(bootAmount, 10)
}

// PrivateTableKey is the key of a category's private template.
func PrivateTableKey(category string) string { return "private:" + category }

// TableCatalogue is the whole table configuration a server runs with.
type TableCatalogue struct {
	// Source is TableConfigSourceDB or TableConfigSourceEnv.
	Source   string
	Settings TableSettings
	// Public is the lobby menu in display order; Private one template per
	// category (a category with none folds a private create to seen).
	Public  []TableSpec
	Private []TableSpec
}

// Spec is THE answer to "what does a new table of this category and boot play
// by". With a catalogue (db mode) it is the matching row — a public table by
// (category, boot), a private one by category alone (the template's own boot);
// otherwise, and for a pair a db catalogue does not list (no production path
// opens one: quick-join and a public create are refused table_not_offered
// first), it is composed from the env fields exactly as the server always
// composed it. Category is normalised; a boot of 0 means BootAmount.
func (g GameConfig) Spec(category string, bootAmount int64, private bool) TableSpec {
	category = NormalizeCategory(category)
	if bootAmount <= 0 {
		bootAmount = g.BootAmount
	}
	if g.Catalogue != nil {
		if private {
			if spec, ok := g.Catalogue.privateFor(category); ok {
				return spec
			}
		} else if spec, ok := g.Catalogue.publicFor(category, bootAmount); ok {
			return spec
		}
	}
	return g.composeSpec(category, bootAmount, private)
}

// HasPrivate reports whether a private table of category may be opened: in db
// mode only where an active private template exists (a create naming any
// other category folds to seen); from env, always.
func (g GameConfig) HasPrivate(category string) bool {
	if g.Catalogue == nil {
		return true
	}
	_, ok := g.Catalogue.privateFor(NormalizeCategory(category))
	return ok
}

// FromDatabase reports whether this configuration came from table_configs.
func (g GameConfig) FromDatabase() bool {
	return g.Catalogue != nil && g.Catalogue.Source == TableConfigSourceDB
}

func (c *TableCatalogue) publicFor(category string, bootAmount int64) (TableSpec, bool) {
	for _, spec := range c.Public {
		if spec.Category == category && spec.BootAmount == bootAmount {
			return spec, true
		}
	}
	return TableSpec{}, false
}

func (c *TableCatalogue) privateFor(category string) (TableSpec, bool) {
	for _, spec := range c.Private {
		if spec.Category == category {
			return spec, true
		}
	}
	return TableSpec{}, false
}

// composeSpec is the env composition — newTableLocked's TableRules + globals
// for Teen Patti, poker.ConfigFor's rules for poker — written once.
func (g GameConfig) composeSpec(category string, bootAmount int64, private bool) TableSpec {
	if IsPokerCategory(category) {
		boot := bootAmount
		if private {
			boot = g.PrivateBoot
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
		spec := TableSpec{
			Category:       category,
			BootAmount:     boot,
			Private:        private,
			MaxPlayers:     g.MaxPlayers,
			MinPlayers:     g.MinPlayers,
			TurnTimeout:    turn,
			MaxMissedTurns: g.MaxMissedTurns,
			NextHandDelay:  g.NextHandDelay,
			UnfundedGrace:  g.UnfundedGrace,
			MinBuyIn:       boot * buyInBoots,
			MaxDiscards:    discards,
		}
		g.fillIdentity(&spec)
		return spec
	}
	rules := g.TableRules(category, bootAmount, private)
	spec := TableSpec{
		Category:           category,
		BootAmount:         rules.BootAmount,
		Private:            private,
		MaxPot:             rules.MaxPot,
		MaxRaiseSteps:      rules.MaxRaiseSteps,
		MaxBetRounds:       rules.MaxBetRounds,
		PotLimitMultiplier: rules.PotLimitMultiplier,
		MaxBlindMoves:      g.MaxBlindMoves,
		MaxPlayers:         g.MaxPlayers,
		MinPlayers:         g.MinPlayers,
		TurnTimeout:        g.TurnTimeout,
		MaxMissedTurns:     g.MaxMissedTurns,
		SideshowTimeout:    g.SideshowTimeout,
		SideshowMinPlayers: g.SideshowMinPlayers,
		NextHandDelay:      g.NextHandDelay,
		UnfundedGrace:      g.UnfundedGrace,
		MissileRevealExtra: g.MissileRevealExtra,
	}
	if category == CategoryVariation {
		spec.VariationSelectTimeout = g.VariationSelectTimeout
		spec.FiveCardPickTimeout = g.FiveCardPickTimeout
	}
	g.fillIdentity(&spec)
	return spec
}

// fillIdentity sets Key, and for a public spec the band and menu position of
// the FIRST LOBBY_TABLES entry for its pair (the engine reads the first, as
// menuPotFor and assertWithinTableBand do).
func (g GameConfig) fillIdentity(spec *TableSpec) {
	if spec.Private {
		spec.Key = PrivateTableKey(spec.Category)
		return
	}
	spec.Key = PublicTableKey(spec.Category, spec.BootAmount)
	for i, entry := range g.LobbyTables {
		if NormalizeCategory(entry.Category) == spec.Category && entry.BootAmount == spec.BootAmount {
			spec.MinChips = entry.MinChips
			spec.MaxChips = entry.MaxChips
			spec.SortOrder = (i + 1) * 10
			return
		}
	}
}

// Settings is the TableSettings this configuration runs with.
func (g GameConfig) Settings() TableSettings {
	stakes := make([]int64, len(g.TableStakes))
	copy(stakes, g.TableStakes)
	return TableSettings{
		DefaultBootAmount:  g.BootAmount,
		Stakes:             stakes,
		MaxPlayers:         g.MaxPlayers,
		MinPlayers:         g.MinPlayers,
		TurnTimeout:        g.TurnTimeout,
		MaxBetRounds:       g.MaxBetRounds,
		SideshowTimeout:    g.SideshowTimeout,
		SideshowMinPlayers: g.SideshowMinPlayers,
		EntryCapBoot:       g.EntryCapBoot,
		EntryCapCategory:   g.EntryCapCategory,
		EntryCapMaxChips:   g.EntryCapMaxChips,
	}
}

// EffectiveCatalogue is the catalogue this configuration plays by: the loaded
// one in db mode, else the env composition — every LOBBY_TABLES entry (the
// first of a repeated pair, as the engine reads it; a boot of 0 read as
// BootAmount) and the private template of every category a private create can
// open (variation only where the menu offers it, as newTableLocked folds it
// otherwise). It is what -export-table-config writes and what GET /api/tables
// serves in env mode.
func (g GameConfig) EffectiveCatalogue() TableCatalogue {
	if g.Catalogue != nil {
		return g.Catalogue.clone()
	}
	cat := TableCatalogue{Source: TableConfigSourceEnv, Settings: g.Settings(), Public: []TableSpec{}, Private: []TableSpec{}}
	seen := map[string]bool{}
	for _, entry := range g.LobbyTables {
		spec := g.Spec(entry.Category, entry.BootAmount, false)
		if seen[spec.Key] {
			continue
		}
		seen[spec.Key] = true
		cat.Public = append(cat.Public, spec)
	}
	offersVariation := len(g.LobbyTables) == 0
	for _, entry := range g.LobbyTables {
		if entry.Category == CategoryVariation {
			offersVariation = true
		}
	}
	for i, category := range Categories() {
		if category == CategoryVariation && !offersVariation {
			continue
		}
		spec := g.Spec(category, 0, true)
		spec.SortOrder = 1000 + (i+1)*10
		cat.Private = append(cat.Private, spec)
	}
	return cat
}

func (c *TableCatalogue) clone() TableCatalogue {
	out := *c
	out.Settings.Stakes = append([]int64{}, c.Settings.Stakes...)
	out.Public = append([]TableSpec{}, c.Public...)
	out.Private = append([]TableSpec{}, c.Private...)
	return out
}

// WithCatalogue returns a copy of g that plays by cat (db mode). Every field
// an existing check reads is taken from it, so none of those checks changes:
// LobbyTables (public rows, in order: category, boot and the OWN band — MaxPot
// left 0 because every pot figure is read through Spec), TableStakes and the
// advertised scalars (settings), the entry cap (settings) and the private
// figures (the private seen template: what the Flutter app creates). cat must
// have been through Validate.
func (g GameConfig) WithCatalogue(cat TableCatalogue) GameConfig {
	c := cat.clone()
	out := g
	out.Catalogue = &c
	s := c.Settings
	out.BootAmount = s.DefaultBootAmount
	out.TableStakes = append([]int64{}, s.Stakes...)
	out.MaxPlayers = s.MaxPlayers
	out.MinPlayers = s.MinPlayers
	out.TurnTimeout = s.TurnTimeout
	out.MaxBetRounds = s.MaxBetRounds
	out.SideshowTimeout = s.SideshowTimeout
	out.SideshowMinPlayers = s.SideshowMinPlayers
	out.EntryCapBoot = s.EntryCapBoot
	out.EntryCapCategory = s.EntryCapCategory
	out.EntryCapMaxChips = s.EntryCapMaxChips
	out.LobbyTables = make([]LobbyTable, 0, len(c.Public))
	for _, spec := range c.Public {
		out.LobbyTables = append(out.LobbyTables, LobbyTable{
			Category:   spec.Category,
			BootAmount: spec.BootAmount,
			MinChips:   spec.MinChips,
			MaxChips:   spec.MaxChips,
		})
	}
	if seen, ok := c.privateFor(CategorySeen); ok {
		out.PrivateBoot = seen.BootAmount
		out.PrivateMaxPot = seen.MaxPot
		out.PrivateMaxRaiseSteps = seen.MaxRaiseSteps
	}
	return out
}

// Validate checks a catalogue read from the database, as FromEnv checks
// LOBBY_TABLES. A row that is wrong is LEFT OUT and described in problems
// (the server logs each and keeps booting — a hand edit PostgreSQL accepted
// must not turn the next, unrelated restart into a crash loop); a row's
// family-irrelevant figures are zeroed so a table built from it is exactly
// what the env composition would build. err is non-nil only when what is left
// cannot run a lobby: an invalid settings row, no public table, or no private
// seen template.
func (c TableCatalogue) Validate() (TableCatalogue, []string, error) {
	var problems []string
	s := c.Settings
	if err := s.validate(); err != nil {
		return TableCatalogue{}, nil, err
	}
	out := TableCatalogue{Source: c.Source, Settings: s, Public: []TableSpec{}, Private: []TableSpec{}}
	out.Settings.Stakes = append([]int64{}, s.Stakes...)
	keys := map[string]bool{}
	for _, row := range append(append([]TableSpec{}, c.Public...), c.Private...) {
		spec, err := row.normalised(s)
		if err == nil && keys[spec.Key] {
			err = fmt.Errorf("a second row for %s", spec.Key)
		}
		if err != nil {
			problems = append(problems, fmt.Sprintf("table %s left out: %v", row.describe(), err))
			continue
		}
		keys[spec.Key] = true
		if spec.Private {
			out.Private = append(out.Private, spec)
		} else {
			out.Public = append(out.Public, spec)
		}
	}
	hasPublicVariation := false
	for _, spec := range out.Public {
		if spec.Category == CategoryVariation {
			hasPublicVariation = true
		}
	}
	if _, ok := out.privateFor(CategoryVariation); ok && !hasPublicVariation {
		problems = append(problems, "the private variation template is active but no public variation table is: a private create naming variation still folds to seen while the lobby offers none")
	}
	if seen, ok := out.privateFor(CategorySeen); ok {
		for _, spec := range out.Private {
			if spec.BootAmount != seen.BootAmount {
				problems = append(problems, fmt.Sprintf("%s has boot %d but the lobby advertises the private seen template's %d as privateBoot", spec.Key, spec.BootAmount, seen.BootAmount))
			}
		}
	}
	if len(out.Public) == 0 {
		return TableCatalogue{}, problems, fmt.Errorf("no usable public table: the lobby would be empty")
	}
	if _, ok := out.privateFor(CategorySeen); !ok {
		return TableCatalogue{}, problems, fmt.Errorf("no usable private seen template: room:create would have nothing to open")
	}
	return out, problems, nil
}

func (s TableSettings) validate() error {
	switch {
	case s.DefaultBootAmount <= 0:
		return fmt.Errorf("table_settings.default_boot_amount must be more than 0")
	case s.MaxPlayers < 2 || s.MaxPlayers > 5:
		return fmt.Errorf("table_settings.max_players must be between 2 and 5 (the clients draw five places)")
	case s.MinPlayers < 2 || s.MinPlayers > s.MaxPlayers:
		return fmt.Errorf("table_settings.min_players must be between 2 and max_players")
	case s.TurnTimeout <= 0:
		return fmt.Errorf("table_settings.turn_timeout_ms must be more than 0")
	case s.MaxBetRounds < 0 || s.SideshowTimeout < 0 || s.SideshowMinPlayers < 0 || s.EntryCapBoot < 0 || s.EntryCapMaxChips < 0:
		return fmt.Errorf("table_settings has a negative figure")
	case s.EntryCapCategory != "" && !IsKnownCategory(s.EntryCapCategory):
		return fmt.Errorf("table_settings.entry_cap_category %q is not a category this server knows", s.EntryCapCategory)
	}
	for _, stake := range s.Stakes {
		if stake <= 0 {
			return fmt.Errorf("table_settings.stakes must all be more than 0")
		}
	}
	return nil
}

// normalised checks one row and returns it as the engine will read it: the
// key set, the players from the settings, and every figure its family does not
// read set to 0.
func (spec TableSpec) normalised(s TableSettings) (TableSpec, error) {
	if !IsKnownCategory(spec.Category) {
		return TableSpec{}, fmt.Errorf("unknown category %q", spec.Category)
	}
	if spec.BootAmount <= 0 {
		return TableSpec{}, fmt.Errorf("boot_amount must be more than 0")
	}
	if spec.MinChips < 0 || spec.MaxChips < 0 {
		return TableSpec{}, fmt.Errorf("negative stack band")
	}
	if spec.MaxChips > 0 && spec.MinChips > spec.MaxChips {
		return TableSpec{}, fmt.Errorf("min_chips %d is more than max_chips %d: nobody could sit", spec.MinChips, spec.MaxChips)
	}
	if spec.Private && (spec.MinChips != 0 || spec.MaxChips != 0) {
		return TableSpec{}, fmt.Errorf("a private template has no stack band")
	}
	if spec.TurnTimeout <= 0 {
		return TableSpec{}, fmt.Errorf("turn_timeout_ms must be more than 0")
	}
	if spec.MaxMissedTurns < 0 || spec.NextHandDelay < 0 || spec.UnfundedGrace < 0 {
		return TableSpec{}, fmt.Errorf("negative figure")
	}
	spec.MaxPlayers = s.MaxPlayers
	spec.MinPlayers = s.MinPlayers
	if spec.Private {
		spec.Key = PrivateTableKey(spec.Category)
	} else {
		spec.Key = PublicTableKey(spec.Category, spec.BootAmount)
	}
	if IsPokerCategory(spec.Category) {
		if spec.MinBuyIn < spec.BootAmount {
			return TableSpec{}, fmt.Errorf("min_buy_in %d is less than the boot %d", spec.MinBuyIn, spec.BootAmount)
		}
		if spec.MaxDiscards < 0 || spec.MaxDiscards > 5 {
			return TableSpec{}, fmt.Errorf("max_discards must be between 0 and 5")
		}
		spec.MaxPot, spec.MaxRaiseSteps, spec.MaxBetRounds, spec.PotLimitMultiplier, spec.MaxBlindMoves = 0, 0, 0, 0, 0
		spec.SideshowTimeout, spec.SideshowMinPlayers, spec.MissileRevealExtra = 0, 0, 0
		spec.VariationSelectTimeout, spec.FiveCardPickTimeout = 0, 0
		return spec, nil
	}
	if spec.MaxPot < 0 || spec.MaxRaiseSteps < 0 || spec.MaxBetRounds < 0 || spec.PotLimitMultiplier < 0 ||
		spec.MaxBlindMoves < 0 || spec.SideshowTimeout < 0 || spec.SideshowMinPlayers < 0 || spec.MissileRevealExtra < 0 {
		return TableSpec{}, fmt.Errorf("negative figure")
	}
	// The per-bet ceiling is boot × multiplier (Table.betOptions); one that
	// overflows would wrap negative and leave no rung at all.
	if spec.PotLimitMultiplier > 0 && spec.BootAmount > math.MaxInt64/spec.PotLimitMultiplier {
		return TableSpec{}, fmt.Errorf("boot_amount × pot_limit_multiplier overflows")
	}
	spec.MinBuyIn, spec.MaxDiscards = 0, 0
	if spec.Category == CategoryVariation {
		if spec.VariationSelectTimeout <= 0 || spec.FiveCardPickTimeout <= 0 {
			return TableSpec{}, fmt.Errorf("a variation table needs variation_select_timeout_ms and five_card_pick_timeout_ms above 0")
		}
	} else {
		spec.VariationSelectTimeout, spec.FiveCardPickTimeout = 0, 0
	}
	return spec, nil
}

func (spec TableSpec) describe() string {
	if spec.Key != "" {
		return spec.Key
	}
	if spec.Private {
		return PrivateTableKey(spec.Category)
	}
	return PublicTableKey(spec.Category, spec.BootAmount)
}

// SameRules reports whether a table built from a and one built from b play
// by the same figures — everything but the band, the key and the menu
// position. The RoomManager asks it of every table restored from the live
// store: one whose frozen rules the current configuration would no longer
// open is drained (never matched into) rather than left to take players the
// lobby card describes differently.
func (a TableSpec) SameRules(b TableSpec) bool {
	a.Key, b.Key = "", ""
	a.MinChips, b.MinChips = 0, 0
	a.MaxChips, b.MaxChips = 0, 0
	a.SortOrder, b.SortOrder = 0, 0
	return a == b
}

// resolveTableConfigSource is FromEnv's TABLE_CONFIG_SOURCE rule: an explicit
// db or env wins; anything else is an error; unset or empty resolves to env
// when any table env key is set (set, even to "" — the parity harness's
// LOBBY_TABLES=” is a statement about tables), db otherwise. It also returns
// the table keys that are set, in TableEnvKeys order, for the boot's WARN.
func resolveTableConfigSource(lookup Lookup) (source string, keysSet []string, err error) {
	for _, key := range TableEnvKeys() {
		if _, ok := lookup(key); ok {
			keysSet = append(keysSet, key)
		}
	}
	raw, _ := lookup("TABLE_CONFIG_SOURCE")
	switch strings.TrimSpace(raw) {
	case TableConfigSourceDB:
		return TableConfigSourceDB, keysSet, nil
	case TableConfigSourceEnv:
		return TableConfigSourceEnv, keysSet, nil
	case "":
		if len(keysSet) > 0 {
			return TableConfigSourceEnv, keysSet, nil
		}
		return TableConfigSourceDB, keysSet, nil
	}
	return "", keysSet, fmt.Errorf("TABLE_CONFIG_SOURCE=%q: must be db or env", raw)
}
