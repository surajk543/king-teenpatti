package db

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
)

// TableConfigs is the table catalogue in PostgreSQL (owner, 23 Sep 2026: "all
// table related config store in database"): the four configuration tables
// V1.0.0__baseline.sql declares and V1.0.1__seed.sql fills — the engines and
// the categories under them, the one table_settings row, and the table_configs
// rows. With TABLE_CONFIG_SOURCE=db the server reads it ONCE, at boot, and
// every table it opens is built from what it read (config.GameConfig.Spec);
// nothing here is game state and nothing at a table ever writes to it.
type TableConfigs struct {
	db *DB
}

// NewTableConfigs builds the reader.
func NewTableConfigs(d *DB) *TableConfigs {
	return &TableConfigs{db: d}
}

// Load reads the catalogue as the database holds it: the settings row — an
// error when it is missing, since no lobby can run without it — every active
// engine, every active category of an active engine (each in (sort_order,
// code) order), and every table_configs row whose row, category AND engine are
// all active, the public tables and the private templates each in (sort_order,
// id) order, which is the menu's order. So one UPDATE of a category or an
// engine hides every table under it — all of Poker at once — without a word:
// what is switched off on purpose is not a problem to report. Durations come
// back from their milliseconds, every spec's Key is its table_key and its
// Engine its category row's, and every spec carries the settings' MaxPlayers
// and MinPlayers, as config.TableSpec says. Source is
// config.TableConfigSourceDB.
//
// NOT validated: a row PostgreSQL accepted can still be one the engine must
// not open (a category this build does not know, one filed under the wrong
// engine, a poker buy-in below the boot), and deciding what to leave out is
// config.TableCatalogue.Validate's job — every caller runs it, the boot and
// -check-table-config alike.
//
// Every read runs in one read-only REPEATABLE READ transaction, so an edit
// committed between them cannot hand the server a taxonomy, a settings row and
// a menu that never existed together. The tables are qualified with the schema
// the pool was opened on: search_path ends in public, and a schema that lacks
// the tables (one opened with SkipMigrations, say) must fail here rather than
// quietly read public's.
func (s *TableConfigs) Load(ctx context.Context) (config.TableCatalogue, error) {
	tx, err := s.db.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return config.TableCatalogue{}, err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()

	settings, err := s.loadSettings(ctx, tx)
	if err != nil {
		return config.TableCatalogue{}, err
	}
	cat := config.TableCatalogue{
		Source:   config.TableConfigSourceDB,
		Settings: settings,
		Public:   []config.TableSpec{},
		Private:  []config.TableSpec{},
	}
	if cat.Engines, cat.Categories, err = s.loadTaxonomy(ctx, tx); err != nil {
		return config.TableCatalogue{}, err
	}

	rows, err := tx.Query(ctx, `SELECT t.table_key, t.category, c.engine, t.boot_amount, t.is_private, t.min_chips, t.max_chips,
       t.max_pot, t.max_raise_steps, t.max_bet_rounds, t.pot_limit_multiplier, t.max_blind_moves,
       t.turn_timeout_ms, t.max_missed_turns, t.sideshow_timeout_ms, t.sideshow_min_players,
       t.next_hand_delay_ms, t.unfunded_grace_ms, t.missile_reveal_extra_ms,
       t.variation_select_timeout_ms, t.five_card_pick_timeout_ms, t.min_buy_in, t.max_discards, t.sort_order
  FROM `+s.table("table_configs")+` t
  JOIN `+s.table("table_categories")+` c ON c.code = t.category
  JOIN `+s.table("table_engines")+` e ON e.code = c.engine
 WHERE t.is_active AND c.is_active AND e.is_active
 ORDER BY t.is_private, t.sort_order, t.id`)
	if err != nil {
		return config.TableCatalogue{}, fmt.Errorf("read table_configs: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var spec config.TableSpec
		var turn, sideshow, nextHand, grace, missile, selectWindow, pickWindow int64
		if err := rows.Scan(&spec.Key, &spec.Category, &spec.Engine, &spec.BootAmount, &spec.Private, &spec.MinChips, &spec.MaxChips,
			&spec.MaxPot, &spec.MaxRaiseSteps, &spec.MaxBetRounds, &spec.PotLimitMultiplier, &spec.MaxBlindMoves,
			&turn, &spec.MaxMissedTurns, &sideshow, &spec.SideshowMinPlayers,
			&nextHand, &grace, &missile,
			&selectWindow, &pickWindow, &spec.MinBuyIn, &spec.MaxDiscards, &spec.SortOrder); err != nil {
			return config.TableCatalogue{}, fmt.Errorf("read table_configs: %w", err)
		}
		spec.TurnTimeout = millis(turn)
		spec.SideshowTimeout = millis(sideshow)
		spec.NextHandDelay = millis(nextHand)
		spec.UnfundedGrace = millis(grace)
		spec.MissileRevealExtra = millis(missile)
		spec.VariationSelectTimeout = millis(selectWindow)
		spec.FiveCardPickTimeout = millis(pickWindow)
		spec.MaxPlayers = settings.MaxPlayers
		spec.MinPlayers = settings.MinPlayers
		if spec.Private {
			cat.Private = append(cat.Private, spec)
		} else {
			cat.Public = append(cat.Public, spec)
		}
	}
	if err := rows.Err(); err != nil {
		return config.TableCatalogue{}, fmt.Errorf("read table_configs: %w", err)
	}
	return cat, nil
}

// loadSettings reads the one table_settings row.
func (s *TableConfigs) loadSettings(ctx context.Context, tx pgx.Tx) (config.TableSettings, error) {
	var st config.TableSettings
	var turn, sideshow int64
	err := tx.QueryRow(ctx, `SELECT default_boot_amount, stakes, max_players, min_players, turn_timeout_ms,
       max_bet_rounds, sideshow_timeout_ms, sideshow_min_players,
       entry_cap_boot, entry_cap_category, entry_cap_max_chips
  FROM `+s.table("table_settings")+`
 WHERE id = 1`).Scan(&st.DefaultBootAmount, &st.Stakes, &st.MaxPlayers, &st.MinPlayers, &turn,
		&st.MaxBetRounds, &sideshow, &st.SideshowMinPlayers,
		&st.EntryCapBoot, &st.EntryCapCategory, &st.EntryCapMaxChips)
	if errors.Is(err, pgx.ErrNoRows) {
		return config.TableSettings{}, errors.New("table_settings has no row: the seed (V1.0.1__seed.sql) has not run on this schema, or the row was deleted")
	}
	if err != nil {
		return config.TableSettings{}, fmt.Errorf("read table_settings: %w", err)
	}
	if st.Stakes == nil {
		st.Stakes = []int64{} // an empty array is "any stake", never nil
	}
	st.TurnTimeout = millis(turn)
	st.SideshowTimeout = millis(sideshow)
	return st, nil
}

// loadTaxonomy reads every active engine and every active category of an
// active engine, each in (sort_order, code) order. Never nil.
func (s *TableConfigs) loadTaxonomy(ctx context.Context, tx pgx.Tx) ([]config.TableEngine, []config.TableCategory, error) {
	engines := []config.TableEngine{}
	rows, err := tx.Query(ctx, `SELECT code, name, sort_order FROM `+s.table("table_engines")+`
 WHERE is_active
 ORDER BY sort_order, code`)
	if err != nil {
		return nil, nil, fmt.Errorf("read table_engines: %w", err)
	}
	for rows.Next() {
		var e config.TableEngine
		if err := rows.Scan(&e.Code, &e.Name, &e.SortOrder); err != nil {
			rows.Close()
			return nil, nil, fmt.Errorf("read table_engines: %w", err)
		}
		engines = append(engines, e)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, nil, fmt.Errorf("read table_engines: %w", err)
	}

	categories := []config.TableCategory{}
	rows, err = tx.Query(ctx, `SELECT c.code, c.engine, c.name, c.sort_order
  FROM `+s.table("table_categories")+` c
  JOIN `+s.table("table_engines")+` e ON e.code = c.engine
 WHERE c.is_active AND e.is_active
 ORDER BY c.sort_order, c.code`)
	if err != nil {
		return nil, nil, fmt.Errorf("read table_categories: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var c config.TableCategory
		if err := rows.Scan(&c.Code, &c.Engine, &c.Name, &c.SortOrder); err != nil {
			return nil, nil, fmt.Errorf("read table_categories: %w", err)
		}
		categories = append(categories, c)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, fmt.Errorf("read table_categories: %w", err)
	}
	return engines, categories, nil
}

// table is name qualified with the schema the pool was opened on (Load's
// comment says why), or bare for a DB built without one.
func (s *TableConfigs) table(name string) string {
	if s.db.Schema == "" {
		return name
	}
	return pgx.Identifier{s.db.Schema, name}.Sanitize()
}

func millis(ms int64) time.Duration { return time.Duration(ms) * time.Millisecond }

// ExportTableConfigSQL is the psql script that makes a database hold exactly
// cat — what `gameplay -export-table-config` prints. Its purpose is the switch
// to TABLE_CONFIG_SOURCE=db on a deployment whose .env configures its tables:
// run with that .env and TABLE_CONFIG_SOURCE=env, the export is the menu the
// deployment plays today, and piping it into psql before the switch means the
// database holds that menu rather than the code's defaults.
//
// The script, in order: each header line as a `--` comment; `\set
// ON_ERROR_STOP on`, so psql stops at the first refusal instead of carrying on
// outside the transaction; BEGIN; every engine of cat, then every category,
// upserted on its code (ON CONFLICT (code) DO UPDATE SET the engine, the name,
// the place, is_active = TRUE and updated_at) — first, because every row after
// them names a category; the settings row upserted (ON CONFLICT (id) DO
// UPDATE); every spec of cat, public then private, upserted on its table_key
// (ON CONFLICT (table_key) DO UPDATE SET the boot and every figure, is_active =
// TRUE and updated_at) — the first of a repeated key or code only, which is
// the one the engine reads; every OTHER active table, category and engine
// deactivated, since the export is the whole catalogue and a row it does not
// name is one the deployment does not offer; COMMIT. So the database holds cat
// and nothing else active, and running the script twice is running it once.
// Rows are retired, never deleted (V1.0.0's table_configs).
//
// Tables are named bare, so the script runs on whatever schema psql's
// search_path leads with (PGOPTIONS='-c search_path=<schema>' for one that is
// not public). Every figure is written as its column holds it — durations in
// milliseconds — and every column the table declares without a DEFAULT is
// stated. The database's CHECKs and foreign keys have the last word: a figure
// they refuse (a turn clock under five seconds, an entry cap naming no
// category) stops the script and changes nothing.
func ExportTableConfigSQL(cat config.TableCatalogue, header []string) string {
	var b strings.Builder
	for _, h := range header {
		for _, line := range strings.Split(h, "\n") {
			b.WriteString(strings.TrimRight("-- "+line, " "))
			b.WriteString("\n")
		}
	}
	b.WriteString("--\n")
	b.WriteString("-- Makes table_engines, table_categories, table_settings and table_configs\n")
	b.WriteString("-- hold exactly this catalogue: every engine, category and table below and\n")
	b.WriteString("-- the settings row are written, and every other active engine, category and\n")
	b.WriteString("-- table is retired (is_active = FALSE). One transaction; a refusal changes\n")
	b.WriteString("-- nothing. A server reads it at its next start with TABLE_CONFIG_SOURCE=db.\n")
	b.WriteString(`\set ON_ERROR_STOP on` + "\n")
	b.WriteString("BEGIN;\n\n")

	// The taxonomy first: the settings row and every table name a category.
	b.WriteString("-- The engines, and the categories under them.\n")
	var engineCodes, categoryCodes []string
	writtenCode := map[string]bool{}
	for _, engine := range cat.Engines {
		if writtenCode["engine:"+engine.Code] {
			fmt.Fprintf(&b, "-- engine %s is listed twice; the first, above, is the one a server reads.\n", engine.Code)
			continue
		}
		writtenCode["engine:"+engine.Code] = true
		engineCodes = append(engineCodes, sqlLiteral(engine.Code))
		fmt.Fprintf(&b, "INSERT INTO table_engines (code, name, sort_order, is_active)\nVALUES (%s, %s, %d, TRUE)\n"+
			"ON CONFLICT (code) DO UPDATE SET\n  name = EXCLUDED.name, sort_order = EXCLUDED.sort_order, is_active = TRUE, updated_at = %s;\n",
			sqlLiteral(engine.Code), sqlLiteral(engine.Name), engine.SortOrder, nowMillisSQL)
	}
	for _, category := range cat.Categories {
		if writtenCode["category:"+category.Code] {
			fmt.Fprintf(&b, "-- category %s is listed twice; the first, above, is the one a server reads.\n", category.Code)
			continue
		}
		writtenCode["category:"+category.Code] = true
		categoryCodes = append(categoryCodes, sqlLiteral(category.Code))
		fmt.Fprintf(&b, "INSERT INTO table_categories (code, engine, name, sort_order, is_active)\nVALUES (%s, %s, %s, %d, TRUE)\n"+
			"ON CONFLICT (code) DO UPDATE SET\n  engine = EXCLUDED.engine, name = EXCLUDED.name, sort_order = EXCLUDED.sort_order, is_active = TRUE, updated_at = %s;\n",
			sqlLiteral(category.Code), sqlLiteral(category.Engine), sqlLiteral(category.Name), category.SortOrder, nowMillisSQL)
	}
	b.WriteString("\n")

	st := cat.Settings
	stakes := make([]string, len(st.Stakes))
	for i, stake := range st.Stakes {
		stakes[i] = strconv.FormatInt(stake, 10)
	}
	stakesSQL := "'{}'::bigint[]"
	if len(stakes) > 0 {
		stakesSQL = "ARRAY[" + strings.Join(stakes, ", ") + "]::bigint[]"
	}
	fmt.Fprintf(&b, `INSERT INTO table_settings (id, default_boot_amount, stakes, max_players, min_players, turn_timeout_ms,
                            max_bet_rounds, sideshow_timeout_ms, sideshow_min_players,
                            entry_cap_boot, entry_cap_category, entry_cap_max_chips)
VALUES (1, %d, %s, %d, %d, %d,
        %d, %d, %d,
        %d, %s, %d)
ON CONFLICT (id) DO UPDATE SET
  default_boot_amount = EXCLUDED.default_boot_amount, stakes = EXCLUDED.stakes,
  max_players = EXCLUDED.max_players, min_players = EXCLUDED.min_players,
  turn_timeout_ms = EXCLUDED.turn_timeout_ms, max_bet_rounds = EXCLUDED.max_bet_rounds,
  sideshow_timeout_ms = EXCLUDED.sideshow_timeout_ms, sideshow_min_players = EXCLUDED.sideshow_min_players,
  entry_cap_boot = EXCLUDED.entry_cap_boot, entry_cap_category = EXCLUDED.entry_cap_category,
  entry_cap_max_chips = EXCLUDED.entry_cap_max_chips,
  updated_at = %s;
`,
		st.DefaultBootAmount, stakesSQL, st.MaxPlayers, st.MinPlayers, st.TurnTimeout.Milliseconds(),
		st.MaxBetRounds, st.SideshowTimeout.Milliseconds(), st.SideshowMinPlayers,
		st.EntryCapBoot, sqlLiteral(st.EntryCapCategory), st.EntryCapMaxChips,
		nowMillisSQL)

	figures := tableConfigFigureColumns()
	// boot_amount is in a public table's key, so updating it there changes
	// nothing — but a private template's key is its category alone, and its
	// boot is a figure like any other.
	updates := []string{"boot_amount = EXCLUDED.boot_amount"}
	for _, column := range figures {
		updates = append(updates, column+" = EXCLUDED."+column)
	}
	columns := append(append([]string{"category", "boot_amount", "is_private"}, figures...), "sort_order", "is_active")
	var keys []string
	written := map[string]bool{}
	specs := append(append([]config.TableSpec{}, cat.Public...), cat.Private...)
	for _, spec := range specs {
		key := tableKeyOf(spec)
		if written[key] {
			fmt.Fprintf(&b, "\n-- %s is listed twice; the first, above, is the one a server reads.\n", key)
			continue
		}
		written[key] = true
		keys = append(keys, sqlLiteral(key))
		values := append(append([]string{sqlLiteral(spec.Category), strconv.FormatInt(spec.BootAmount, 10), sqlBool(spec.Private)},
			tableConfigFigures(spec)...), strconv.Itoa(spec.SortOrder), "TRUE")
		fmt.Fprintf(&b, "\n-- %s\nINSERT INTO table_configs (%s)\nVALUES (%s)\nON CONFLICT (table_key) DO UPDATE SET\n  %s,\n  sort_order = EXCLUDED.sort_order, is_active = TRUE, updated_at = %s;\n",
			key, wrapList(columns, 5, "                           "), wrapList(values, 5, "        "), wrapList(updates, 3, "  "), nowMillisSQL)
	}

	b.WriteString("\n-- Every table, category and engine the catalogue above does not name is retired.\n")
	retire(&b, "table_configs", "table_key", keys)
	retire(&b, "table_categories", "code", categoryCodes)
	retire(&b, "table_engines", "code", engineCodes)
	b.WriteString("\nCOMMIT;\n")
	return b.String()
}

// retire writes the UPDATE that deactivates every active row of table whose
// column is not one of kept (SQL literals) — every active row, when kept is
// empty.
func retire(b *strings.Builder, table, column string, kept []string) {
	fmt.Fprintf(b, "UPDATE %s SET is_active = FALSE, updated_at = %s\n WHERE is_active", table, nowMillisSQL)
	if len(kept) > 0 {
		b.WriteString(" AND " + column + " NOT IN (\n   " + wrapList(kept, 4, "   ") + "\n )")
	}
	b.WriteString(";\n")
}

// wrapList joins items with ", ", perLine to a line, continuing each line
// after the first with indent.
func wrapList(items []string, perLine int, indent string) string {
	var lines []string
	for i := 0; i < len(items); i += perLine {
		lines = append(lines, strings.Join(items[i:min(i+perLine, len(items))], ", "))
	}
	return strings.Join(lines, ",\n"+indent)
}

// sqlBool is b as SQL writes it.
func sqlBool(b bool) string {
	if b {
		return "TRUE"
	}
	return "FALSE"
}

// nowMillisSQL is "now" in epoch milliseconds, the unit every timestamp in
// this schema is kept in (V1.0.0's header). now() is the transaction's start,
// so every row one export touches carries the same updated_at.
const nowMillisSQL = "(EXTRACT(EPOCH FROM now()) * 1000)::bigint"

// tableConfigFigureColumns is every table_configs column that holds a figure a
// table plays by, in DDL order: everything but the identity (category,
// boot_amount, is_private and the key made of them), the menu position, the
// flag and the timestamps. A fresh slice each call.
func tableConfigFigureColumns() []string {
	return []string{
		"min_chips", "max_chips",
		"max_pot", "max_raise_steps", "max_bet_rounds", "pot_limit_multiplier", "max_blind_moves",
		"turn_timeout_ms", "max_missed_turns", "sideshow_timeout_ms", "sideshow_min_players",
		"next_hand_delay_ms", "unfunded_grace_ms", "missile_reveal_extra_ms",
		"variation_select_timeout_ms", "five_card_pick_timeout_ms",
		"min_buy_in", "max_discards",
	}
}

// tableConfigFigures is spec's value for each of tableConfigFigureColumns, as
// SQL literals in the same order.
func tableConfigFigures(spec config.TableSpec) []string {
	values := []int64{
		spec.MinChips, spec.MaxChips,
		spec.MaxPot, int64(spec.MaxRaiseSteps), int64(spec.MaxBetRounds), spec.PotLimitMultiplier, int64(spec.MaxBlindMoves),
		spec.TurnTimeout.Milliseconds(), int64(spec.MaxMissedTurns), spec.SideshowTimeout.Milliseconds(), int64(spec.SideshowMinPlayers),
		spec.NextHandDelay.Milliseconds(), spec.UnfundedGrace.Milliseconds(), spec.MissileRevealExtra.Milliseconds(),
		spec.VariationSelectTimeout.Milliseconds(), spec.FiveCardPickTimeout.Milliseconds(),
		spec.MinBuyIn, int64(spec.MaxDiscards),
	}
	out := make([]string, len(values))
	for i, v := range values {
		out[i] = strconv.FormatInt(v, 10)
	}
	return out
}

// tableKeyOf is the table_key PostgreSQL generates for spec's row. Computed
// from the columns, as the database computes it, never taken from spec.Key:
// the key the export conflicts on and retires by must be the one the row
// will actually carry.
func tableKeyOf(spec config.TableSpec) string {
	if spec.Private {
		return config.PrivateTableKey(spec.Category)
	}
	return config.PublicTableKey(spec.Category, spec.BootAmount)
}

// sqlLiteral quotes s as an SQL string literal. With standard_conforming_strings
// on — PostgreSQL's default since 9.1 — a backslash is an ordinary character in
// '…', so doubling the single quotes is the whole of it.
func sqlLiteral(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}
