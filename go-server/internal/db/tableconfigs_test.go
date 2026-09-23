package db_test

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// The table catalogue (owner, 23 Sep 2026): table_engines, table_categories,
// table_settings and table_configs, declared by V1.0.0__baseline.sql and
// filled by V1.0.1__seed.sql.

// defaultCatalogue is what the defaults compose, as a database catalogue.
func defaultCatalogue() config.TableCatalogue {
	cat := config.Defaults().Game.EffectiveCatalogue()
	cat.Source = config.TableConfigSourceDB
	return cat
}

func loadTables(t *testing.T, d *db.DB) config.TableCatalogue {
	t.Helper()
	cat, err := db.NewTableConfigs(d).Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	return cat
}

func execSQL(t *testing.T, d *db.DB, sql string, args ...any) {
	t.Helper()
	if _, err := d.Pool.Exec(context.Background(), sql, args...); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

func countOf(t *testing.T, d *db.DB, sql string, args ...any) int64 {
	t.Helper()
	var n int64
	if err := d.Pool.QueryRow(context.Background(), sql, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return n
}

// reboot runs every migration on d's schema again, as a restart does.
func reboot(t *testing.T, d *db.DB) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	again, err := db.Open(ctx, db.Options{URL: testURL(), Schema: d.Schema, PoolMax: 2})
	if err != nil {
		t.Fatalf("reboot %s: %v", d.Schema, err)
	}
	again.Close()
}

// TestTheSeededTableCatalogueIsTheDefaults: a fresh database holds exactly
// what the server composed from its defaults before the catalogue existed —
// the two engines and the seven categories under them, the settings, the
// twelve default tables in menu order and the seven private templates, every
// figure — so switching TABLE_CONFIG_SOURCE to db on the seed changes nothing a
// player can see. The VALUES in V1.0.1__seed.sql were generated from this
// composition; this is what proves them.
func TestTheSeededTableCatalogueIsTheDefaults(t *testing.T) {
	d := dbtest.Open(t, "tables")
	got, want := loadTables(t, d), defaultCatalogue()

	if !reflect.DeepEqual(got.Engines, config.DefaultTableEngines()) || !reflect.DeepEqual(got.Categories, config.DefaultTableCategories()) {
		t.Errorf("the taxonomy:\n got %+v\n     %+v\nwant %+v\n     %+v", got.Engines, got.Categories,
			config.DefaultTableEngines(), config.DefaultTableCategories())
	}
	if !reflect.DeepEqual(got.Settings, want.Settings) {
		t.Errorf("table_settings:\n got %+v\nwant %+v", got.Settings, want.Settings)
	}
	compare := func(kind string, got, want []config.TableSpec) {
		t.Helper()
		if len(got) != len(want) {
			t.Errorf("%d %s rows, want %d", len(got), kind, len(want))
		}
		for i := 0; i < len(got) && i < len(want); i++ {
			if got[i] != want[i] {
				t.Errorf("%s row %d, %s:\n got %+v\nwant %+v", kind, i, want[i].Key, got[i], want[i])
			}
		}
	}
	compare("public", got.Public, want.Public)
	compare("private", got.Private, want.Private)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("the seeded catalogue is not the defaults:\n got %+v\nwant %+v", got, want)
	}

	// And it is a catalogue the server takes as it is: nothing left out,
	// nothing zeroed, nothing to warn about.
	valid, problems, err := got.Validate()
	if err != nil || len(problems) != 0 {
		t.Fatalf("the seeded catalogue does not validate: %v %v", err, problems)
	}
	if !reflect.DeepEqual(valid, want) {
		t.Fatalf("Validate changed the seeded catalogue:\n got %+v\nwant %+v", valid, want)
	}
	if n := countOf(t, d, `SELECT (SELECT count(*) FROM table_configs WHERE NOT is_active)
	      + (SELECT count(*) FROM table_categories WHERE NOT is_active)
	      + (SELECT count(*) FROM table_engines WHERE NOT is_active)`); n != 0 {
		t.Fatalf("a fresh database must get every row active, %d are not", n)
	}
}

// TestASeedRowAppendedToAnExistingCatalogueArrivesInactive: the seed writes
// active rows only into an EMPTY catalogue. A row a database does not have —
// one appended in a later release, or a seeded row somebody deleted — comes
// in inactive, so a restart never puts a new table in front of players the
// owner has not turned on; a row the database has is never touched, so an
// owner's edit survives every restart.
func TestASeedRowAppendedToAnExistingCatalogueArrivesInactive(t *testing.T) {
	d := dbtest.Open(t, "tables")

	// The owner edits a table, retires one, re-prices the default boot,
	// renames a category…
	execSQL(t, d, `UPDATE table_configs SET max_blind_moves = 2 WHERE table_key = 'blind:200'`)
	execSQL(t, d, `UPDATE table_configs SET is_active = FALSE WHERE table_key = 'omaha:50000'`)
	execSQL(t, d, `UPDATE table_settings SET default_boot_amount = 5000`)
	execSQL(t, d, `UPDATE table_categories SET name = 'Open', sort_order = 15 WHERE code = 'seen'`)
	// …and two rows go missing, as a row appended to the seed later is
	// missing from every database that booted before it.
	execSQL(t, d, `DELETE FROM table_configs WHERE table_key IN ('seen:50000', 'private:blind')`)

	reboot(t, d)

	active := func(key string) (bool, bool) {
		t.Helper()
		var on bool
		err := d.Pool.QueryRow(context.Background(), `SELECT is_active FROM table_configs WHERE table_key = $1`, key).Scan(&on)
		if errors.Is(err, pgx.ErrNoRows) {
			return false, false
		}
		if err != nil {
			t.Fatal(err)
		}
		return on, true
	}
	for _, key := range []string{"seen:50000", "private:blind"} {
		if on, there := active(key); !there || on {
			t.Errorf("%s: present %v, active %v — a row added to an existing catalogue must arrive inactive", key, there, on)
		}
	}
	if on, _ := active("omaha:50000"); on {
		t.Error("a retired table must stay retired across a restart")
	}
	if on, _ := active("seen:200"); !on {
		t.Error("an untouched table must stay active")
	}
	if n := countOf(t, d, `SELECT max_blind_moves FROM table_configs WHERE table_key = 'blind:200'`); n != 2 {
		t.Errorf("the owner's edit was undone: max_blind_moves %d", n)
	}
	if n := countOf(t, d, `SELECT default_boot_amount FROM table_settings`); n != 5000 {
		t.Errorf("the owner's settings edit was undone: default_boot_amount %d", n)
	}
	if n := countOf(t, d, `SELECT count(*) FROM table_categories WHERE code = 'seen' AND name = 'Open' AND sort_order = 15`); n != 1 {
		t.Error("the owner's category edit was undone")
	}
	if n := countOf(t, d, `SELECT count(*) FROM table_configs`); n != 19 {
		t.Errorf("%d rows, want 19", n)
	}

	// What the server loads is what is active.
	cat := loadTables(t, d)
	for _, spec := range append(append([]config.TableSpec{}, cat.Public...), cat.Private...) {
		switch spec.Key {
		case "seen:50000", "private:blind", "omaha:50000":
			t.Errorf("Load returned the inactive %s", spec.Key)
		}
	}
	if len(cat.Public) != 10 || len(cat.Private) != 6 {
		t.Errorf("Load: %d public, %d private, want 10 and 6", len(cat.Public), len(cat.Private))
	}

	// Public and private are asked about separately: a catalogue whose public
	// tables are all gone is empty for the public rows, which come back active,
	// while the templates it still has are left alone.
	execSQL(t, d, `DELETE FROM table_configs WHERE NOT is_private`)
	reboot(t, d)
	if n := countOf(t, d, `SELECT count(*) FROM table_configs WHERE NOT is_private AND is_active`); n != 12 {
		t.Errorf("an empty public catalogue must be refilled, all active: %d active", n)
	}
	if on, _ := active("private:blind"); on {
		t.Error("the private templates were not empty, so private:blind must stay inactive")
	}
}

// TestLoadReturnsTheRowsAsTheDatabaseHoldsThem: the menu order is sort_order,
// the durations are the milliseconds read back, every spec carries the
// settings' player counts and its category row's engine — and nothing is
// validated: a row the engine must not open is returned for Validate to leave
// out, with its reason.
func TestLoadReturnsTheRowsAsTheDatabaseHoldsThem(t *testing.T) {
	d := dbtest.Open(t, "tables")
	execSQL(t, d, `UPDATE table_configs SET sort_order = 5, turn_timeout_ms = 90000 WHERE table_key = 'omaha:50000'`)
	execSQL(t, d, `UPDATE table_settings SET max_players = 4, stakes = '{}'`)
	// PostgreSQL accepts any category that has a row: the set is data as well
	// as code, and the server is what refuses one it cannot play.
	execSQL(t, d, `INSERT INTO table_categories (code, engine, name, sort_order) VALUES ('rummy', 'teen_patti', 'Rummy', 80)`)
	execSQL(t, d, `INSERT INTO table_configs (category, boot_amount, max_pot, max_raise_steps, max_bet_rounds,
            pot_limit_multiplier, max_blind_moves, turn_timeout_ms, max_missed_turns, sideshow_timeout_ms,
            sideshow_min_players, next_hand_delay_ms, unfunded_grace_ms, missile_reveal_extra_ms,
            variation_select_timeout_ms, five_card_pick_timeout_ms, min_buy_in, max_discards, sort_order)
        VALUES ('rummy', 200, 0, 0, 0, 0, 0, 25000, 3, 0, 0, 4000, 30000, 0, 0, 0, 0, 0, 125)`)

	cat := loadTables(t, d)
	if cat.Source != config.TableConfigSourceDB {
		t.Errorf("source %q", cat.Source)
	}
	if first := cat.Public[0]; first.Key != "omaha:50000" || first.TurnTimeout != 90*time.Second || first.Engine != config.EnginePoker {
		t.Errorf("the menu is in sort_order, a clock is its milliseconds and the engine its category's: first %+v", first)
	}
	if last := cat.Public[len(cat.Public)-1]; last.Key != "rummy:200" || last.Category != "rummy" || last.Engine != config.EngineTeenPatti {
		t.Errorf("Load must return every active row, known category or not: last %+v", last)
	}
	if last := cat.Categories[len(cat.Categories)-1]; last.Code != "rummy" || len(cat.Categories) != 8 || len(cat.Engines) != 2 {
		t.Errorf("Load must return every active category, known or not: %+v", cat.Categories)
	}
	if cat.Settings.MaxPlayers != 4 || cat.Settings.Stakes == nil || len(cat.Settings.Stakes) != 0 {
		t.Errorf("settings %+v", cat.Settings)
	}
	for _, spec := range append(append([]config.TableSpec{}, cat.Public...), cat.Private...) {
		if spec.MaxPlayers != 4 || spec.MinPlayers != 2 {
			t.Errorf("%s carries %d-%d players, want the settings' 2-4", spec.Key, spec.MinPlayers, spec.MaxPlayers)
		}
	}
	for i := 1; i < len(cat.Private); i++ {
		if cat.Private[i-1].SortOrder > cat.Private[i].SortOrder {
			t.Errorf("private templates out of order: %s before %s", cat.Private[i-1].Key, cat.Private[i].Key)
		}
	}

	valid, problems, err := cat.Validate()
	want := []string{`category rummy left out: unknown category "rummy"`, `table rummy:200 left out: unknown category "rummy"`}
	if err != nil || strings.Join(problems, "\n") != strings.Join(want, "\n") {
		t.Fatalf("Validate must leave the unknown category and its table out and say so: %v\n%s", err, strings.Join(problems, "\n"))
	}
	if len(valid.Public) != len(cat.Public)-1 || len(valid.Categories) != 7 {
		t.Errorf("Validate kept %d of %d public rows and %d categories", len(valid.Public), len(cat.Public), len(valid.Categories))
	}
}

// TestAnInactiveCategoryOrEngineHidesEveryTableUnderIt: is_active works at
// every level. One UPDATE of a category takes every table of it — the private
// template included — off the menu, and one UPDATE of an engine takes every
// category and table under it (all of Poker), with nothing for Validate to
// complain about: what is switched off on purpose is not a problem. The
// switch survives a restart, and turning it back on brings the tables back
// exactly as they were.
func TestAnInactiveCategoryOrEngineHidesEveryTableUnderIt(t *testing.T) {
	d := dbtest.Open(t, "tables")
	categories := func(cat config.TableCatalogue) string {
		var codes []string
		for _, c := range cat.Categories {
			codes = append(codes, c.Code)
		}
		return strings.Join(codes, ",")
	}
	count := func(cat config.TableCatalogue, keep func(config.TableSpec) bool) int {
		n := 0
		for _, spec := range append(append([]config.TableSpec{}, cat.Public...), cat.Private...) {
			if keep(spec) {
				n++
			}
		}
		return n
	}
	clean := func(cat config.TableCatalogue) config.TableCatalogue {
		t.Helper()
		valid, problems, err := cat.Validate()
		if err != nil || len(problems) != 0 {
			t.Fatalf("a catalogue switched off on purpose must validate cleanly: %v %v", err, problems)
		}
		return valid
	}

	execSQL(t, d, `UPDATE table_categories SET is_active = FALSE WHERE code = 'variation'`)
	cat := loadTables(t, d)
	if categories(cat) != "seen,blind,three_card_poker,five_card_draw,texas_holdem,omaha" ||
		count(cat, func(s config.TableSpec) bool { return s.Category == "variation" }) != 0 || len(cat.Public) != 10 || len(cat.Private) != 6 {
		t.Errorf("no variation: categories %s, %d public, %d private", categories(cat), len(cat.Public), len(cat.Private))
	}
	clean(cat)

	execSQL(t, d, `UPDATE table_engines SET is_active = FALSE WHERE code = 'poker'`)
	reboot(t, d) // the owner's switches are data: a restart keeps them
	cat = loadTables(t, d)
	if len(cat.Engines) != 1 || cat.Engines[0].Code != config.EngineTeenPatti || categories(cat) != "seen,blind" ||
		count(cat, func(s config.TableSpec) bool { return s.Engine != config.EngineTeenPatti }) != 0 ||
		len(cat.Public) != 6 || len(cat.Private) != 2 {
		t.Errorf("no poker, no variation: %+v, categories %s, %d public, %d private", cat.Engines, categories(cat), len(cat.Public), len(cat.Private))
	}
	clean(cat)

	execSQL(t, d, `UPDATE table_engines SET is_active = TRUE`)
	execSQL(t, d, `UPDATE table_categories SET is_active = TRUE`)
	if got, want := clean(loadTables(t, d)), defaultCatalogue(); !reflect.DeepEqual(got, want) {
		t.Errorf("switched back on, the catalogue is not what it was:\n got %+v\nwant %+v", got, want)
	}

	// A category filed under the wrong engine is not switched off on purpose:
	// Load returns it as the database has it, and Validate leaves it — and
	// every table of it — out, and says why.
	execSQL(t, d, `UPDATE table_categories SET engine = 'poker' WHERE code = 'blind'`)
	valid, problems, err := loadTables(t, d).Validate()
	if err != nil || len(problems) != 6 || !strings.Contains(problems[0], "category blind left out: blind is a teen_patti category, not poker") ||
		count(valid, func(s config.TableSpec) bool { return s.Category == "blind" }) != 0 {
		t.Errorf("blind under poker: %v\n%s", err, strings.Join(problems, "\n"))
	}
}

// TestTheForeignKeysHoldTheTaxonomyTogether: a table, the entry cap and a
// category can name only what has a row — a category, a category, an engine —
// and nothing that is named can be deleted from under the row naming it. The
// set itself stays open: a new category is an INSERT, with no constraint to
// change.
func TestTheForeignKeysHoldTheTaxonomyTogether(t *testing.T) {
	d := dbtest.Open(t, "tables")
	ctx := context.Background()
	var pgErr *pgconn.PgError
	refused := map[string]string{
		"a table naming no category": `INSERT INTO table_configs (category, boot_amount, max_pot, max_raise_steps, max_bet_rounds,
            pot_limit_multiplier, max_blind_moves, turn_timeout_ms, max_missed_turns, sideshow_timeout_ms,
            sideshow_min_players, next_hand_delay_ms, unfunded_grace_ms, missile_reveal_extra_ms,
            variation_select_timeout_ms, five_card_pick_timeout_ms, min_buy_in, max_discards, sort_order)
        VALUES ('rummy', 200, 0, 0, 0, 0, 0, 25000, 3, 0, 0, 4000, 30000, 0, 0, 0, 0, 0, 125)`,
		"an entry cap naming no category":    `UPDATE table_settings SET entry_cap_category = 'rummy'`,
		"a category naming no engine":        `INSERT INTO table_categories (code, engine, name, sort_order) VALUES ('rummy', 'rummy', 'Rummy', 80)`,
		"a category deleted under a table":   `DELETE FROM table_categories WHERE code = 'omaha'`,
		"an engine deleted under a category": `DELETE FROM table_engines WHERE code = 'poker'`,
	}
	for name, sql := range refused {
		if _, err := d.Pool.Exec(ctx, sql); !errors.As(err, &pgErr) || pgErr.Code != "23503" {
			t.Errorf("%s must be refused by a foreign key, got %v", name, err)
		}
	}
	// Open: a new engine and a category under it are rows.
	execSQL(t, d, `INSERT INTO table_engines (code, name, sort_order) VALUES ('rummy', 'Rummy', 30)`)
	execSQL(t, d, `INSERT INTO table_categories (code, engine, name, sort_order) VALUES ('rummy', 'rummy', 'Rummy', 80)`)
	// And every column a taxonomy row describes itself with must be stated.
	for table, columns := range map[string][]string{"table_engines": {"name", "sort_order"}, "table_categories": {"engine", "name", "sort_order"}} {
		for _, column := range columns {
			var def *string
			if err := d.Pool.QueryRow(ctx, `SELECT column_default FROM information_schema.columns
                 WHERE table_schema = $1 AND table_name = $2 AND column_name = $3 AND is_nullable = 'NO'`, d.Schema, table, column).Scan(&def); err != nil {
				t.Fatalf("%s.%s must be NOT NULL: %v", table, column, err)
			}
			if def != nil {
				t.Errorf("%s.%s must have no DEFAULT, has %s", table, column, *def)
			}
		}
	}
}

// TestLoadWithoutASettingsRowIsAnError: no lobby can run without the settings
// row, and the error says where it comes from.
func TestLoadWithoutASettingsRowIsAnError(t *testing.T) {
	d := dbtest.Open(t, "tables")
	execSQL(t, d, `DELETE FROM table_settings`)
	_, err := db.NewTableConfigs(d).Load(context.Background())
	if err == nil || !strings.Contains(err.Error(), "table_settings has no row") {
		t.Fatalf("expected the missing-settings error, got %v", err)
	}
}

// TestATableConfigRowMustStateEveryFigure: the rule and timer columns have no
// DEFAULT, so a row typed by hand that forgets one is refused there and then
// rather than playing by a number nobody chose — and the category is held by a
// foreign key, never an enumerated CHECK that would freeze the set (the HAMMER
// trap).
func TestATableConfigRowMustStateEveryFigure(t *testing.T) {
	d := dbtest.Open(t, "tables")
	ctx := context.Background()

	figures := []string{
		"max_pot", "max_raise_steps", "max_bet_rounds", "pot_limit_multiplier", "max_blind_moves",
		"turn_timeout_ms", "max_missed_turns", "sideshow_timeout_ms", "sideshow_min_players",
		"next_hand_delay_ms", "unfunded_grace_ms", "missile_reveal_extra_ms",
		"variation_select_timeout_ms", "five_card_pick_timeout_ms", "min_buy_in", "max_discards", "sort_order",
	}
	settings := []string{
		"default_boot_amount", "stakes", "max_players", "min_players", "turn_timeout_ms", "max_bet_rounds",
		"sideshow_timeout_ms", "sideshow_min_players", "entry_cap_boot", "entry_cap_category", "entry_cap_max_chips",
	}
	for table, columns := range map[string][]string{"table_configs": figures, "table_settings": settings} {
		for _, column := range columns {
			var def *string
			var nullable string
			if err := d.Pool.QueryRow(ctx, `SELECT column_default, is_nullable FROM information_schema.columns
                 WHERE table_schema = $1 AND table_name = $2 AND column_name = $3`, d.Schema, table, column).Scan(&def, &nullable); err != nil {
				t.Fatalf("%s.%s: %v", table, column, err)
			}
			if def != nil || nullable != "NO" {
				shown := "none"
				if def != nil {
					shown = *def
				}
				t.Errorf("%s.%s must be NOT NULL with no DEFAULT, has default %s, nullable %s", table, column, shown, nullable)
			}
		}
	}

	var pgErr *pgconn.PgError
	_, err := d.Pool.Exec(ctx, `INSERT INTO table_configs (category, boot_amount, sort_order) VALUES ('seen', 700, 1)`)
	if !errors.As(err, &pgErr) || pgErr.Code != "23502" {
		t.Fatalf("a row that states no figures must be refused NOT NULL, got %v", err)
	}

	// No CHECK names the categories or the engines as a set: the foreign keys
	// to table_categories and table_engines are what hold them, and those keep
	// the set open.
	var regclasses []any
	for _, table := range []string{"table_engines", "table_categories", "table_settings", "table_configs"} {
		regclasses = append(regclasses, pgx.Identifier{d.Schema, table}.Sanitize())
	}
	rows, err := d.Pool.Query(ctx, `SELECT contype::text, pg_get_constraintdef(oid) FROM pg_constraint
         WHERE conrelid IN ($1::text::regclass, $2::text::regclass, $3::text::regclass, $4::text::regclass)`, regclasses...)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	foreign := 0
	for rows.Next() {
		var kind, def string
		if err := rows.Scan(&kind, &def); err != nil {
			t.Fatal(err)
		}
		if kind == "f" {
			foreign++
		}
		if strings.Contains(def, "'seen'") || strings.Contains(def, "'blind'") || strings.Contains(def, "'teen_patti'") {
			t.Errorf("a CHECK enumerates the taxonomy, which would freeze the set on every existing database: %s", def)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if foreign != 3 {
		t.Errorf("%d foreign keys, want 3: category → engine, settings → category, table → category", foreign)
	}
}

// TestTheTableKeyIsTheIdentityAndTheChecksHoldTheFloor: table_key is made of
// the columns, one row per key, and a figure no table could be played by is
// refused by the database itself.
func TestTheTableKeyIsTheIdentityAndTheChecksHoldTheFloor(t *testing.T) {
	d := dbtest.Open(t, "tables")
	ctx := context.Background()

	var public, private string
	if err := d.Pool.QueryRow(ctx, `SELECT
            (SELECT table_key FROM table_configs WHERE category = 'blind' AND boot_amount = 5000 AND NOT is_private),
            (SELECT table_key FROM table_configs WHERE category = 'texas_holdem' AND is_private)`).Scan(&public, &private); err != nil {
		t.Fatal(err)
	}
	if public != config.PublicTableKey("blind", 5000) || private != config.PrivateTableKey("texas_holdem") {
		t.Errorf("table_key %q and %q", public, private)
	}

	// row writes one table_configs row: a seen table at 700 that every CHECK
	// accepts, with the named columns changed.
	row := func(changes map[string]any) error {
		values := map[string]any{
			"category": "seen", "boot_amount": 700, "is_private": false, "min_chips": 0, "max_chips": 0,
			"max_pot": 0, "max_raise_steps": 2, "max_bet_rounds": 7, "pot_limit_multiplier": 1024, "max_blind_moves": 4,
			"turn_timeout_ms": 25000, "max_missed_turns": 3, "sideshow_timeout_ms": 6000, "sideshow_min_players": 3,
			"next_hand_delay_ms": 4000, "unfunded_grace_ms": 30000, "missile_reveal_extra_ms": 3000,
			"variation_select_timeout_ms": 0, "five_card_pick_timeout_ms": 0, "min_buy_in": 0, "max_discards": 0,
			"sort_order": 500,
		}
		for column, value := range changes {
			values[column] = value
		}
		columns := make([]string, 0, len(values))
		for column := range values {
			columns = append(columns, column)
		}
		sort.Strings(columns)
		args := make([]any, len(columns))
		params := make([]string, len(columns))
		for i, column := range columns {
			args[i] = values[column]
			params[i] = fmt.Sprintf("$%d", i+1)
		}
		_, err := d.Pool.Exec(ctx, `INSERT INTO table_configs (`+strings.Join(columns, ", ")+`)
            VALUES (`+strings.Join(params, ", ")+`)`, args...)
		return err
	}
	if err := row(nil); err != nil {
		t.Fatalf("the base row must be accepted: %v", err)
	}
	var pgErr *pgconn.PgError
	if err := row(nil); !errors.As(err, &pgErr) || pgErr.Code != "23505" {
		t.Errorf("a second row for seen:700 must be a unique violation, got %v", err)
	}
	poker := map[string]any{"max_raise_steps": 0, "max_bet_rounds": 0, "pot_limit_multiplier": 0, "max_blind_moves": 0,
		"sideshow_timeout_ms": 0, "sideshow_min_players": 0, "missile_reveal_extra_ms": 0, "max_discards": 3}
	with := func(base map[string]any, changes map[string]any) map[string]any {
		out := map[string]any{}
		for k, v := range base {
			out[k] = v
		}
		for k, v := range changes {
			out[k] = v
		}
		return out
	}
	refused := map[string]map[string]any{
		"a turn under five seconds":       {"boot_amount": 701, "turn_timeout_ms": 1200},
		"a sideshow clock under a second": {"boot_amount": 702, "sideshow_timeout_ms": 500},
		"a band nobody could join":        {"boot_amount": 703, "min_chips": 10, "max_chips": 5},
		"a private table with a band":     {"category": "blind", "is_private": true, "boot_amount": 200, "max_chips": 5},
		"a variation window of 0":         {"category": "variation", "boot_amount": 704, "five_card_pick_timeout_ms": 8000},
		"a poker buy-in under the boot":   with(poker, map[string]any{"category": "omaha", "boot_amount": 705, "min_buy_in": 704}),
		"six cards to exchange":           with(poker, map[string]any{"category": "five_card_draw", "boot_amount": 706, "min_buy_in": 7060, "max_discards": 6}),
	}
	for name, changes := range refused {
		if err := row(changes); !errors.As(err, &pgErr) || pgErr.Code != "23514" {
			t.Errorf("%s must be refused by a CHECK, got %v", name, err)
		}
	}
	// And the same poker and variation rows, put right, are taken.
	if err := row(with(poker, map[string]any{"category": "omaha", "boot_amount": 705, "min_buy_in": 705})); err != nil {
		t.Errorf("a poker row whose buy-in covers the boot must be accepted: %v", err)
	}
	if err := row(map[string]any{"category": "variation", "boot_amount": 704, "variation_select_timeout_ms": 10000, "five_card_pick_timeout_ms": 8000}); err != nil {
		t.Errorf("a variation row with both windows must be accepted: %v", err)
	}
	if _, err := d.Pool.Exec(ctx, `UPDATE table_configs SET table_key = 'seen:1' WHERE table_key = 'seen:700'`); err == nil {
		t.Error("table_key is generated and must not be writable")
	}
	if _, err := d.Pool.Exec(ctx, `INSERT INTO table_settings (id, default_boot_amount, stakes, max_players, min_players,
            turn_timeout_ms, max_bet_rounds, sideshow_timeout_ms, sideshow_min_players, entry_cap_boot,
            entry_cap_category, entry_cap_max_chips)
        VALUES (2, 200, '{}', 5, 2, 25000, 20, 6000, 3, 0, 'blind', 0)`); !errors.As(err, &pgErr) || pgErr.Code != "23514" {
		t.Errorf("a second settings row must be refused, got %v", err)
	}
}

// TestTheExportRoundTripsAnEnvCatalogue: what -export-table-config prints for
// a deployment's env menu, applied to a seeded database and read back, is
// that menu exactly — its own figures, the first of a repeated pair, and
// every seeded table it does not list retired (here all of variation) — and
// applying it a second time changes nothing.
func TestTheExportRoundTripsAnEnvCatalogue(t *testing.T) {
	env := map[string]string{
		"TABLE_CONFIG_SOURCE":   "env",
		"TABLE_STAKES":          "200,1000,5000",
		"BOOT_AMOUNT":           "1000",
		"LOBBY_TABLES":          "blind:1000:max=90000000,seen:200:pot=400000,blind:1000,texas_holdem:5000,seen:5000,five_card_draw:1000",
		"TURN_TIMEOUT_MS":       "30000",
		"MAX_BLIND_MOVES":       "3",
		"SIDESHOW_TIMEOUT_MS":   "0",
		"POKER_MAX_DISCARDS":    "2",
		"POKER_MIN_BUYIN_BOOTS": "4",
		"PRIVATE_BOOT":          "1000",
		"PRIVATE_MAX_POT":       "900000",
		"ENTRY_CAP_CATEGORY":    "seen",
		"ENTRY_CAP_MAX_CHIPS":   "700000",
	}
	cfg, err := config.FromEnv(func(key string) (string, bool) {
		v, ok := env[key]
		return v, ok
	})
	if err != nil {
		t.Fatal(err)
	}
	want := cfg.Game.EffectiveCatalogue()
	if want.Source != config.TableConfigSourceEnv || len(want.Public) != 5 || len(want.Private) != 6 {
		t.Fatalf("the env catalogue: %s, %d public, %d private", want.Source, len(want.Public), len(want.Private))
	}
	script := db.ExportTableConfigSQL(want, []string{"Exported for TestTheExportRoundTripsAnEnvCatalogue"})
	want.Source = config.TableConfigSourceDB

	d := dbtest.Open(t, "tables")
	for range 2 {
		execSQL(t, d, withoutMetaCommands(script))
		got := loadTables(t, d)
		valid, problems, err := got.Validate()
		if err != nil || len(problems) != 0 {
			t.Fatalf("the exported catalogue does not validate: %v %v", err, problems)
		}
		if !reflect.DeepEqual(valid, want) {
			t.Fatalf("the database does not hold the exported catalogue:\n got %+v\nwant %+v", valid, want)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("Load needed Validate to match the export:\n got %+v\nwant %+v", got, want)
		}
	}
	// Retired, never deleted: the 19 seeded rows are all still there, beside
	// the four pairs the default menu does not have.
	if n := countOf(t, d, `SELECT count(*) FROM table_configs`); n != 23 {
		t.Errorf("%d rows, want the 19 seeded and 4 new", n)
	}
	if n := countOf(t, d, `SELECT count(*) FROM table_configs WHERE is_active`); n != 11 {
		t.Errorf("%d active rows, want the 11 exported", n)
	}
	// The env keys say nothing of engines and categories, so the export
	// writes the default taxonomy — every one of the nine rows, active, none
	// added.
	if n := countOf(t, d, `SELECT (SELECT count(*) FROM table_engines WHERE is_active) * 100 + (SELECT count(*) FROM table_categories WHERE is_active)
	      + (SELECT count(*) FROM table_engines WHERE NOT is_active) + (SELECT count(*) FROM table_categories WHERE NOT is_active)`); n != 207 {
		t.Errorf("the taxonomy after the export: %d, want 2 engines and 7 categories, all active", n)
	}
	// A restart does not bring the defaults back.
	reboot(t, d)
	if got := loadTables(t, d); !reflect.DeepEqual(got, want) {
		t.Fatalf("a restart changed the exported catalogue:\n got %+v\nwant %+v", got, want)
	}
}

// TestTheExportRoundTripsTheTaxonomy: the export writes the engines and
// categories as the catalogue has them — renamed, re-ordered, Poker ahead of
// Teen Patti — and retires one it does not name, so the database holds
// exactly the catalogue; and an export of the defaults puts it all back.
func TestTheExportRoundTripsTheTaxonomy(t *testing.T) {
	want := defaultCatalogue()
	want.Engines = []config.TableEngine{
		{Code: config.EnginePoker, Name: "Poker Room", SortOrder: 5},
		{Code: config.EngineTeenPatti, Name: "Teen Patti", SortOrder: 10},
	}
	// Variation is not named (retired, and its tables with it); blind is
	// renamed and moved between 3-Card Poker (40) and 5-Card Draw (50), in
	// the order a Load gives back: by sort_order.
	c := config.DefaultTableCategories()
	blind := c[1]
	blind.Name, blind.SortOrder = "Blind (no peeking)", 45
	want.Categories = []config.TableCategory{c[0], c[3], blind, c[4], c[5], c[6]}
	var public, private []config.TableSpec
	for _, spec := range want.Public {
		if spec.Category != config.CategoryVariation {
			public = append(public, spec)
		}
	}
	for _, spec := range want.Private {
		if spec.Category != config.CategoryVariation {
			private = append(private, spec)
		}
	}
	want.Public, want.Private = public, private
	valid, problems, err := want.Validate()
	if err != nil || len(problems) != 0 || !reflect.DeepEqual(valid, want) {
		t.Fatalf("the test's catalogue is not a valid one: %v %v", err, problems)
	}

	d := dbtest.Open(t, "tables")
	execSQL(t, d, withoutMetaCommands(db.ExportTableConfigSQL(want, nil)))
	if got := loadTables(t, d); !reflect.DeepEqual(got, want) {
		t.Fatalf("the database does not hold the exported taxonomy:\n got %+v\n     %+v\nwant %+v\n     %+v", got.Engines, got.Categories, want.Engines, want.Categories)
	}
	if n := countOf(t, d, `SELECT count(*) FROM table_categories WHERE code = 'variation' AND NOT is_active`); n != 1 {
		t.Error("a category the export does not name must be retired, not deleted")
	}

	execSQL(t, d, withoutMetaCommands(db.ExportTableConfigSQL(defaultCatalogue(), nil)))
	if got := loadTables(t, d); !reflect.DeepEqual(got, defaultCatalogue()) {
		t.Fatalf("an export of the defaults must bring them back:\n got %+v\nwant %+v", got, defaultCatalogue())
	}
}

// TestTheExportIsAPsqlScriptInOneTransaction: the header is commented out,
// psql is told to stop at the first error, everything is between BEGIN and
// COMMIT, the engines and categories are written before anything that names
// them, strings are quoted, an empty stake list is an empty array, and a
// repeated key or code is written once.
func TestTheExportIsAPsqlScriptInOneTransaction(t *testing.T) {
	cat := defaultCatalogue()
	cat.Settings.Stakes = []int64{}
	cat.Settings.EntryCapCategory = "it's"
	cat.Public = append(cat.Public, cat.Public[1])
	cat.Engines = append(cat.Engines, cat.Engines[0])
	cat.Categories = append(cat.Categories, cat.Categories[2])
	script := db.ExportTableConfigSQL(cat, []string{"line one", "line two\nand three", ""})

	lines := strings.Split(script, "\n")
	for i, want := range []string{"-- line one", "-- line two", "-- and three", "--"} {
		if lines[i] != want {
			t.Errorf("header line %d = %q, want %q", i, lines[i], want)
		}
	}
	begin, commit := strings.Index(script, "\nBEGIN;\n"), strings.Index(script, "\nCOMMIT;\n")
	stop := strings.Index(script, "\n\\set ON_ERROR_STOP on\n")
	if stop < 0 || begin < stop || commit < begin || !strings.HasSuffix(script, "COMMIT;\n") {
		t.Errorf("want \\set ON_ERROR_STOP, then BEGIN … COMMIT:\n%s", script)
	}
	for _, want := range []string{"'{}'::bigint[]", "'it''s'", "'Texas Hold''em'", "ON CONFLICT (id) DO UPDATE", "ON CONFLICT (table_key) DO UPDATE",
		"ON CONFLICT (code) DO UPDATE", "-- blind:200 is listed twice", "-- engine teen_patti is listed twice", "-- category variation is listed twice",
		"UPDATE table_configs SET is_active = FALSE", "UPDATE table_categories SET is_active = FALSE", "UPDATE table_engines SET is_active = FALSE"} {
		if !strings.Contains(script, want) {
			t.Errorf("the script lacks %q", want)
		}
	}
	if n := strings.Count(script, "INSERT INTO table_configs"); n != len(cat.Public)-1+len(cat.Private) {
		t.Errorf("%d table INSERTs, want one per key", n)
	}
	if e, c := strings.Count(script, "INSERT INTO table_engines"), strings.Count(script, "INSERT INTO table_categories"); e != 2 || c != 7 {
		t.Errorf("%d engine and %d category INSERTs, want one per code: 2 and 7", e, c)
	}
	order := []string{"INSERT INTO table_engines", "INSERT INTO table_categories", "INSERT INTO table_settings", "INSERT INTO table_configs"}
	for i := 1; i < len(order); i++ {
		if strings.LastIndex(script, order[i-1]) > strings.Index(script, order[i]) {
			t.Errorf("every %s must come before the first %s", order[i-1], order[i])
		}
	}
}

// TestOpeningWithoutMigrationsChangesNothing: SkipMigrations — what
// -check-table-config reads through — creates no schema, runs no script and
// reads no other schema's tables.
func TestOpeningWithoutMigrationsChangesNothing(t *testing.T) {
	seeded := dbtest.Open(t, "tables")
	ctx := context.Background()
	open := func(schema string) (*db.DB, error) {
		ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		return db.Open(ctx, db.Options{URL: testURL(), Schema: schema, PoolMax: 2, SkipMigrations: true})
	}

	// A schema nobody booted is refused, and not created.
	missing := "test_tables_missing_" + randomSuffix(t)
	if d, err := open(missing); err == nil || !strings.Contains(err.Error(), "does not exist") {
		if d != nil {
			d.Close()
		}
		t.Fatalf("a missing schema must be refused, got %v", err)
	}
	if n := countOf(t, seeded, `SELECT count(*) FROM pg_namespace WHERE nspname = $1`, missing); n != 0 {
		t.Fatalf("SkipMigrations created schema %s", missing)
	}

	// On a seeded schema it reads what is there, and puts nothing back.
	execSQL(t, seeded, `DELETE FROM table_configs WHERE table_key = 'seen:200'`)
	d, err := open(seeded.Schema)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	cat, err := db.NewTableConfigs(d).Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(cat.Public) != 11 || cat.Public[0].Key != "blind:200" {
		t.Errorf("Load through SkipMigrations: %d public, first %s", len(cat.Public), cat.Public[0].Key)
	}
	if n := countOf(t, seeded, `SELECT count(*) FROM table_configs WHERE table_key = 'seen:200'`); n != 0 {
		t.Error("SkipMigrations ran the seed")
	}

	// A schema that exists but was never booted has no catalogue — and Load
	// says so rather than reading public's through the search_path.
	empty := "test_tables_empty_" + randomSuffix(t)
	execSQL(t, seeded, `CREATE SCHEMA `+pgx.Identifier{empty}.Sanitize())
	t.Cleanup(func() {
		_, _ = seeded.Pool.Exec(context.Background(), `DROP SCHEMA IF EXISTS `+pgx.Identifier{empty}.Sanitize()+` CASCADE`)
	})
	bare, err := open(empty)
	if err != nil {
		t.Fatal(err)
	}
	defer bare.Close()
	if _, err := db.NewTableConfigs(bare).Load(ctx); err == nil || !strings.Contains(err.Error(), "does not exist") {
		t.Fatalf("Load on a schema without the tables must fail, got %v", err)
	}
}

// withoutMetaCommands drops psql's backslash lines, which only psql
// understands, so a script can run through pgx.
func withoutMetaCommands(script string) string {
	var kept []string
	for _, line := range strings.Split(script, "\n") {
		if strings.HasPrefix(line, `\`) {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}
