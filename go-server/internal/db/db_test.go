package db_test

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// The embedded migrations are the only copy of the DDL. They are named the
// Flyway way and applied in version order, and every one of them has to be
// idempotent because this server has no schema history table — it runs all of
// them on every boot.
func TestMigrationsAreVersionedOrderedAndSplitByKind(t *testing.T) {
	migrations := db.Migrations()
	// Exactly two scripts (owner, 23 Sep 2026: "merge all DDL and DML into 2
	// files"): every table in the baseline, every row in the seed. The
	// consolidation of 14 Sep 2026 had already folded everything written
	// before production ran the pair — the missiles, the new-account diamonds,
	// the pictures' HAMMER currency, V1.0.2__timed_bonus_milestone.sql and
	// V1.0.3__seed_new_pictures.sql. The two scripts written after it,
	// V1.0.2__chip_ledger_game.sql (19 Sep 2026) and V1.0.3__users_is_bot.sql
	// (22 Sep 2026), are folded in now, each as a column in its CREATE TABLE
	// and a guarded block that adds it to a database that lacks it; and the
	// seed, renamed from V1.0.1__seed_profile_pictures.sql, holds the table
	// catalogue beside the pictures. The baseline keeps its name because
	// ops/DEPLOY.md greps it.
	if len(migrations) != 2 {
		t.Fatalf("expected one DDL script and one DML script, got %d", len(migrations))
	}
	if migrations[0].File != "V1.0.0__baseline.sql" || migrations[1].File != "V1.0.1__seed.sql" {
		t.Fatalf("expected V1.0.0__baseline.sql then V1.0.1__seed.sql, got %s then %s", migrations[0].File, migrations[1].File)
	}

	for i, m := range migrations {
		if i > 0 && !lessVersionForTest(migrations[i-1].Version, m.Version) {
			t.Errorf("migrations out of order: %s before %s", migrations[i-1].File, m.File)
		}
		if m.SQL == "" {
			t.Errorf("%s is empty", m.File)
		}
	}

	// DDL and DML are kept apart: the baseline builds the tables and holds no
	// rows, the seed holds rows and builds nothing.
	//
	// Asserted against the STATEMENTS, not the file: both scripts talk about
	// SQL in their comments — the baseline documents the manual
	// `ALTER TABLE users DISABLE TRIGGER` a superuser needs to delete a row —
	// and a test that reads prose as code fails on documentation.
	baseline, seed := statementsOf(migrations[0].SQL), statementsOf(migrations[1].SQL)
	for _, table := range []string{"users", "chip_ledger", "table_engines", "table_categories", "table_settings", "table_configs"} {
		if !strings.Contains(baseline, "CREATE TABLE IF NOT EXISTS "+table+" (") {
			t.Errorf("the baseline does not create %s", table)
		}
	}
	if strings.Contains(baseline, "INSERT INTO") {
		t.Errorf("%s is DDL and must hold no rows", migrations[0].File)
	}

	// The baseline declares its tables in full, so a fresh schema is built
	// from it alone. The ONLY ALTER TABLE it runs is the EXECUTE string of a
	// catalogue-guarded DO block that adds a column an older database lacks —
	// never `ADD COLUMN IF NOT EXISTS`, which takes ACCESS EXCLUSIVE even when
	// it does nothing, so a restart would queue behind any reader
	// (TestABootSurvivesALongReaderHoldingTheTables), and never anything but an
	// ADD COLUMN: a boot does not change a column that is already there.
	outside, blocks := doBlocksOf(t, baseline)
	if strings.Contains(outside, "ALTER TABLE") {
		t.Error("an ALTER TABLE outside a guarded DO block would run on every boot")
	}
	var alters []string
	for _, block := range blocks {
		if !strings.Contains(block, "ALTER TABLE") {
			continue
		}
		if strings.Count(block, "ALTER TABLE") != strings.Count(block, "EXECUTE 'ALTER TABLE ") {
			t.Errorf("an ALTER TABLE in a DO block must go through EXECUTE (PL/pgSQL plans before it evaluates):\n%s", block)
		}
		if strings.Count(block, "EXECUTE 'ALTER TABLE ") != strings.Count(block, "information_schema.columns") {
			t.Errorf("every ALTER TABLE must sit behind its own information_schema.columns lookup:\n%s", block)
		}
		if strings.Contains(block, "IF NOT EXISTS game") || strings.Contains(block, "IF NOT EXISTS variant") ||
			strings.Contains(block, "IF NOT EXISTS is_bot") || strings.Contains(block, "ADD COLUMN IF NOT EXISTS") {
			t.Errorf("guard with a catalogue lookup, not ADD COLUMN IF NOT EXISTS:\n%s", block)
		}
		for _, line := range strings.Split(block, "\n") {
			if i := strings.Index(line, "EXECUTE 'ALTER TABLE "); i >= 0 {
				alters = append(alters, strings.TrimSpace(line[i:]))
			}
		}
	}
	wantAlters := []string{
		"EXECUTE 'ALTER TABLE users ADD COLUMN is_bot BOOLEAN NOT NULL DEFAULT FALSE';",
		"EXECUTE 'ALTER TABLE users ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT TRUE';",
		"EXECUTE 'ALTER TABLE chip_ledger ADD COLUMN game TEXT';",
		"EXECUTE 'ALTER TABLE chip_ledger ADD COLUMN variant TEXT';",
	}
	if strings.Join(alters, "\n") != strings.Join(wantAlters, "\n") {
		t.Errorf("the baseline brings forward exactly users.is_bot, users.is_active and chip_ledger.game/.variant, got:\n%s", strings.Join(alters, "\n"))
	}
	for _, want := range []string{"column_name = 'is_bot'", "column_name = 'is_active'", "column_name = 'game'", "column_name = 'variant'"} {
		if !strings.Contains(baseline, want) {
			t.Errorf("%s lacks the lookup %q", migrations[0].File, want)
		}
	}
	// Each column the blocks add is declared in its CREATE TABLE too, for a
	// fresh database — the same definition, so fresh and upgraded agree.
	if users := squash(createTableBody(t, baseline, "users")); !strings.Contains(users, "is_bot BOOLEAN NOT NULL DEFAULT FALSE") ||
		!strings.Contains(users, "is_active BOOLEAN NOT NULL DEFAULT TRUE") {
		t.Errorf("CREATE TABLE users must declare is_bot BOOLEAN NOT NULL DEFAULT FALSE and is_active BOOLEAN NOT NULL DEFAULT TRUE:\n%s", users)
	}
	if ledger := squash(createTableBody(t, baseline, "chip_ledger")); !strings.Contains(ledger, "game TEXT") || !strings.Contains(ledger, "variant TEXT") {
		t.Errorf("CREATE TABLE chip_ledger must declare game TEXT and variant TEXT:\n%s", ledger)
	}
	// The table catalogue's key is declared in its CREATE TABLE, generated and
	// UNIQUE, not built by a CREATE INDEX: a boot that changes nothing then
	// takes no SHARE lock on it and makes no ownership check.
	configs := squash(createTableBody(t, baseline, "table_configs"))
	if !strings.Contains(configs, "table_key TEXT GENERATED ALWAYS AS") || !strings.Contains(configs, "STORED UNIQUE") {
		t.Errorf("table_configs must declare its generated UNIQUE table_key:\n%s", configs)
	}
	for _, table := range []string{"table_engines", "table_categories", "table_settings", "table_configs"} {
		if strings.Contains(baseline, "ON "+table) {
			t.Errorf("the table catalogue needs no index beyond the keys its CREATE TABLEs declare: ON %s", table)
		}
	}
	// The taxonomy is held by foreign keys declared in the CREATE TABLEs —
	// the set stays open, a new engine or category being a row — and never by
	// a CHECK listing it; and the four tables are created in the order they
	// reference one another.
	for table, fk := range map[string]string{
		"table_categories": "engine TEXT NOT NULL REFERENCES table_engines (code)",
		"table_settings":   "entry_cap_category TEXT NOT NULL REFERENCES table_categories (code)",
		"table_configs":    "category TEXT NOT NULL REFERENCES table_categories (code)",
	} {
		if body := squash(createTableBody(t, baseline, table)); !strings.Contains(body, fk) {
			t.Errorf("CREATE TABLE %s must declare %s:\n%s", table, fk, body)
		}
	}
	if !inOrder(baseline, "CREATE TABLE IF NOT EXISTS table_engines", "CREATE TABLE IF NOT EXISTS table_categories",
		"CREATE TABLE IF NOT EXISTS table_settings", "CREATE TABLE IF NOT EXISTS table_configs") {
		t.Error("the baseline must create table_engines, table_categories, table_settings, table_configs in that order")
	}

	// The seed holds every row the server seeds — the pictures and the table
	// catalogue — and builds nothing: DDL it depends on lives in the baseline,
	// which runs first. The engines and categories go in before the rows that
	// name them.
	for _, want := range []string{"INSERT INTO profile_pictures", "INSERT INTO table_engines", "INSERT INTO table_categories",
		"INSERT INTO table_settings", "INSERT INTO table_configs"} {
		if !strings.Contains(seed, want) {
			t.Errorf("%s lacks %s", migrations[1].File, want)
		}
	}
	if !inOrder(seed, "INSERT INTO table_engines", "INSERT INTO table_categories", "INSERT INTO table_settings", "INSERT INTO table_configs") {
		t.Errorf("%s must write the engines, then the categories, then the settings and the tables", migrations[1].File)
	}
	for _, ddl := range []string{"CREATE TABLE", "ALTER TABLE", "CREATE INDEX", "CREATE UNIQUE INDEX", "DROP "} {
		if strings.Contains(seed, ddl) {
			t.Errorf("%s is DML and must not %s", migrations[1].File, ddl)
		}
	}

	// The table pictures (owner, 15 Sep 2026) arrived as a pair of their own
	// — V1.0.2__table_pictures.sql and V1.0.3__seed_table_pictures.sql, written
	// while a script that had run somewhere was never edited — and were folded
	// into the two files on 23 Sep 2026 under the rule above: three new tables
	// in the baseline, after the profile pictures they mirror, and their rows in
	// the seed. Nothing of it touches users (which ops/DEPLOY.md §7 may have
	// handed to the superuser): the picture a player has laid is a row of
	// user_table_choice, not a users column, and REFERENCES users (id) needs
	// only the REFERENCES grant.
	for _, want := range []string{
		"CREATE TABLE IF NOT EXISTS table_pictures", "CREATE TABLE IF NOT EXISTS user_table_pictures",
		"CREATE TABLE IF NOT EXISTS user_table_choice", "day_asset_url", "night_asset_url",
	} {
		if !strings.Contains(baseline, want) {
			t.Errorf("%s lacks %q", migrations[0].File, want)
		}
	}
	if !inOrder(baseline, "CREATE TABLE IF NOT EXISTS user_profile_pictures", "CREATE TABLE IF NOT EXISTS table_pictures",
		"CREATE TABLE IF NOT EXISTS user_table_pictures", "CREATE TABLE IF NOT EXISTS user_table_choice", "CREATE TABLE IF NOT EXISTS chip_ledger") {
		t.Error("the baseline must create table_pictures, user_table_pictures and user_table_choice in that order, after user_profile_pictures")
	}
	if pictures := squash(createTableBody(t, baseline, "table_pictures")); !strings.Contains(pictures, "CHECK (currency IN ('COIN', 'DIAMOND', 'HAMMER'))") ||
		!strings.Contains(pictures, "day_asset_url TEXT NOT NULL UNIQUE") {
		t.Errorf("CREATE TABLE table_pictures must declare the three currencies and its UNIQUE day_asset_url:\n%s", pictures)
	}
	for _, table := range []string{"user_table_pictures", "user_table_choice"} {
		if body := squash(createTableBody(t, baseline, table)); !strings.Contains(body, "user_id TEXT") || !strings.Contains(body, "REFERENCES users (id) ON DELETE CASCADE") {
			t.Errorf("CREATE TABLE %s must reference users (id):\n%s", table, body)
		}
	}
	if !strings.Contains(seed, "INSERT INTO table_pictures") || !inOrder(seed, "INSERT INTO profile_pictures", "INSERT INTO table_pictures", "INSERT INTO table_engines") {
		t.Errorf("%s should seed the table pictures, after the profile pictures and before the table catalogue", migrations[1].File)
	}

	// The emoji store (owner, 26 Sep 2026): two more tables in the baseline,
	// after the table pictures and before the ledger, and NO rows in the seed —
	// the owner supplies the art and the rows are added then. Nothing of it
	// touches users: user_emojis references it, which needs only the
	// REFERENCES grant ops/DEPLOY.md §7 gives. An emoji is a Lottie and nothing
	// else, priced by the pictures' FREE/PREMIUM rule in their three
	// currencies.
	if !inOrder(baseline, "CREATE TABLE IF NOT EXISTS user_table_choice", "CREATE TABLE IF NOT EXISTS emojis",
		"CREATE TABLE IF NOT EXISTS user_emojis", "CREATE TABLE IF NOT EXISTS chip_ledger") {
		t.Error("the baseline must create emojis then user_emojis, after the table pictures and before chip_ledger")
	}
	emojis := squash(createTableBody(t, baseline, "emojis"))
	for _, want := range []string{
		"asset_url TEXT NOT NULL UNIQUE", "CHECK (asset_format IN ('LOTTIE'))", "CHECK (currency IN ('COIN', 'DIAMOND', 'HAMMER'))",
		"CHECK (type IN ('FREE', 'PREMIUM'))", "CONSTRAINT free_emoji_cost_check", "duration_hours INTEGER NOT NULL DEFAULT 0",
	} {
		if !strings.Contains(emojis, want) {
			t.Errorf("CREATE TABLE emojis must declare %q:\n%s", want, emojis)
		}
	}
	owned := squash(createTableBody(t, baseline, "user_emojis"))
	for _, want := range []string{"user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE",
		"emoji_id BIGINT NOT NULL REFERENCES emojis (id) ON DELETE CASCADE", "PRIMARY KEY (user_id, emoji_id)"} {
		if !strings.Contains(owned, want) {
			t.Errorf("CREATE TABLE user_emojis must declare %q:\n%s", want, owned)
		}
	}
	// The seed holds the owner's emojis (THE EMOJIS) and never anybody's
	// ownership, and adds a row only where its asset_url is missing, so an
	// owner's UPDATE survives every boot.
	if strings.Contains(seed, "INTO user_emojis") {
		t.Errorf("%s must seed no emoji ownership", migrations[1].File)
	}
	if strings.Contains(seed, "INTO emojis") && !strings.Contains(seed, "ON CONFLICT (asset_url) DO NOTHING;\n") {
		t.Errorf("%s must add emojis ON CONFLICT (asset_url) DO NOTHING", migrations[1].File)
	}

	// Friends V1 (owner, 26 Sep 2026): three more tables in the baseline and
	// nothing on users — player_stats, where the six gameplay counters live
	// now, and the social graph, friend_requests and friendships, each with a
	// foreign key to users (which needs only ops/DEPLOY.md §7's REFERENCES
	// grant) — and one statement in the seed: the backfill that copies every
	// account's retired counters into player_stats once, never over a row
	// that is already there.
	if !inOrder(baseline, "CREATE TABLE IF NOT EXISTS user_milestones", "CREATE TABLE IF NOT EXISTS player_stats",
		"CREATE TABLE IF NOT EXISTS chip_ledger") {
		t.Error("the baseline must create player_stats after user_milestones and before chip_ledger")
	}
	if !inOrder(baseline, "CREATE TABLE IF NOT EXISTS user_lucky_draws", "CREATE TABLE IF NOT EXISTS friend_requests",
		"CREATE TABLE IF NOT EXISTS friendships", "CREATE TABLE IF NOT EXISTS table_engines") {
		t.Error("the baseline must create friend_requests then friendships, after the Lucky Draw and before the table catalogue")
	}
	stats := squash(createTableBody(t, baseline, "player_stats"))
	for _, want := range []string{"user_id TEXT PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE",
		"hands_played BIGINT NOT NULL DEFAULT 0", "hands_won BIGINT NOT NULL DEFAULT 0", "hands_lost BIGINT NOT NULL DEFAULT 0",
		"hands_left BIGINT NOT NULL DEFAULT 0", "total_winnings BIGINT NOT NULL DEFAULT 0", "biggest_pot BIGINT NOT NULL DEFAULT 0"} {
		if !strings.Contains(stats, want) {
			t.Errorf("CREATE TABLE player_stats must declare %q:\n%s", want, stats)
		}
	}
	requests := squash(createTableBody(t, baseline, "friend_requests"))
	for _, want := range []string{"requester_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE",
		"recipient_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE",
		"CHECK (status IN ('PENDING', 'ACCEPTED', 'REJECTED', 'CANCELLED'))", "CHECK (requester_id <> recipient_id)"} {
		if !strings.Contains(requests, want) {
			t.Errorf("CREATE TABLE friend_requests must declare %q:\n%s", want, requests)
		}
	}
	for _, want := range []string{
		"CREATE UNIQUE INDEX IF NOT EXISTS friend_requests_one_pending_per_pair ON friend_requests (LEAST(requester_id, recipient_id), GREATEST(requester_id, recipient_id)) WHERE status = 'PENDING';",
		"CREATE INDEX IF NOT EXISTS friend_requests_incoming ON friend_requests (recipient_id) WHERE status = 'PENDING';",
		"CREATE INDEX IF NOT EXISTS friend_requests_outgoing ON friend_requests (requester_id) WHERE status = 'PENDING';",
	} {
		if !strings.Contains(squash(baseline), want) {
			t.Errorf("the baseline lacks %q", want)
		}
	}
	friendships := squash(createTableBody(t, baseline, "friendships"))
	for _, want := range []string{"user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE",
		"friend_user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE",
		"UNIQUE (user_id, friend_user_id)", "CHECK (user_id <> friend_user_id)"} {
		if !strings.Contains(friendships, want) {
			t.Errorf("CREATE TABLE friendships must declare %q:\n%s", want, friendships)
		}
	}
	for _, table := range []string{"player_stats", "friend_requests", "friendships"} {
		if strings.Contains(outside, "ALTER TABLE "+table) {
			t.Errorf("%s must be declared in full, never altered", table)
		}
	}
	for _, table := range []string{"friend_requests", "friendships"} {
		if strings.Contains(seed, "INTO "+table) {
			t.Errorf("%s seeds %s: the social graph is the players' to write", migrations[1].File, table)
		}
	}
	// The six counters live in player_stats ALONE (owner, 26 Sep 2026: "only
	// store in player_stats table"): users declares none of them, and — this
	// build going onto a fresh database — nothing copies old figures across.
	users := squash(createTableBody(t, baseline, "users"))
	for _, column := range []string{"hands_played", "hands_won", "hands_lost", "hands_left_mid", "total_winnings", "biggest_pot"} {
		if strings.Contains(users, column+" ") {
			t.Errorf("CREATE TABLE users still declares %s: the counters live in player_stats alone", column)
		}
	}
	if strings.Contains(seed, "player_stats") {
		t.Errorf("%s writes player_stats: a player's statistics are the ledger's to write", migrations[1].File)
	}

	// The missile column and tables are the baseline's too (folded in from
	// V1.0.2__missiles.sql on 14 Sep 2026), as are the new-account diamonds
	// (from V1.0.2__new_account_diamonds.sql), the pictures' third currency and
	// the four-hour bonus's TIMED_BONUS milestone (from
	// V1.0.2__timed_bonus_milestone.sql).
	for _, want := range []string{
		"DEFAULT 1 CHECK (missile >= 0)", "CREATE TABLE IF NOT EXISTS missile_purchases", "CREATE TABLE IF NOT EXISTS missile_spends",
		"DEFAULT 9 CHECK (diamond >= 0)", "DEFAULT 20 CHECK (hammer >= 0)",
		"CHECK (currency IN ('COIN', 'DIAMOND', 'HAMMER'))",
		"CHECK (milestone IN ('HANDS_PLAYED', 'TIMED_BONUS', 'DAILY_BONUS'))",
	} {
		if !strings.Contains(baseline, want) {
			t.Errorf("%s lacks %q", migrations[0].File, want)
		}
	}
	if !strings.Contains(db.SchemaSQL(), "chip_ledger_no_rewrite") {
		t.Fatal("the embedded DDL lacks the append-only trigger")
	}
}

// statementsOf strips whole-line SQL comments, leaving what the database
// actually executes.
func statementsOf(sql string) string {
	var kept []string
	for _, line := range strings.Split(sql, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "--") {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

// doBlocksOf splits statements into the bodies of its `DO $$ … $$;` blocks
// and everything outside them.
func doBlocksOf(t *testing.T, statements string) (outside string, blocks []string) {
	t.Helper()
	var rest strings.Builder
	for {
		start := strings.Index(statements, "DO $$")
		if start < 0 {
			rest.WriteString(statements)
			return rest.String(), blocks
		}
		rest.WriteString(statements[:start])
		body := statements[start+len("DO $$"):]
		end := strings.Index(body, "$$;")
		if end < 0 {
			t.Fatal("a DO $$ block is not closed by $$;")
		}
		blocks = append(blocks, body[:end])
		statements = body[end+len("$$;"):]
	}
}

// createTableBody is the column list of `CREATE TABLE IF NOT EXISTS <name> (`
// in statements, up to the `);` that closes it.
func createTableBody(t *testing.T, statements, name string) string {
	t.Helper()
	open := "CREATE TABLE IF NOT EXISTS " + name + " ("
	start := strings.Index(statements, open)
	if start < 0 {
		t.Fatalf("no %q", open)
	}
	body := statements[start+len(open):]
	end := strings.Index(body, "\n);")
	if end < 0 {
		t.Fatalf("CREATE TABLE %s is not closed by a line starting \");\"", name)
	}
	return body[:end]
}

// squash collapses every run of whitespace to one space, so a test can look
// for a column definition however the file aligns it.
func squash(s string) string { return strings.Join(strings.Fields(s), " ") }

// inOrder reports whether each of parts first appears in s after the one
// before it.
func inOrder(s string, parts ...string) bool {
	last := -1
	for _, part := range parts {
		i := strings.Index(s, part)
		if i <= last {
			return false
		}
		last = i
	}
	return true
}

// lessVersionForTest mirrors the package's own dotted-version ordering.
func lessVersionForTest(a, b string) bool {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(as) || i < len(bs); i++ {
		var x, y int
		if i < len(as) {
			x, _ = strconv.Atoi(as[i])
		}
		if i < len(bs) {
			y, _ = strconv.Atoi(bs[i])
		}
		if x != y {
			return x < y
		}
	}
	return false
}

func TestOpenRejectsANonIdentifierSchemaBeforeConnecting(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	for _, bad := range []string{"", "bad-name", "1abc", `x"y`, "a b", "s;drop"} {
		_, err := db.Open(ctx, db.Options{URL: "postgres://nobody@127.0.0.1:1/none", Schema: bad})
		if err == nil || !strings.Contains(err.Error(), "PG_SCHEMA must be a plain identifier") {
			t.Fatalf("schema %q: expected the identifier error, got %v", bad, err)
		}
	}
}

func TestBootstrapCreatesEveryTableAndSetsSearchPathPerConnection(t *testing.T) {
	f := newFixture(t)

	// Exactly these tables: money and audit (users, chip_ledger and the
	// purchase and spend records), the two picture catalogues (profile and
	// table, with who owns and has laid what), the emoji catalogue and who
	// owns which (26 Sep 2026), the Lucky Draw's three, the four
	// configuration tables, and Friends V1's three (26 Sep 2026: the
	// gameplay counters moved off users into player_stats, and the social
	// graph, friend_requests and friendships) — twenty-five, and no game
	// state (the baseline's header).
	rows, err := f.d.Pool.Query(f.ctx, `SELECT table_name FROM information_schema.tables
         WHERE table_schema = $1 AND table_type = 'BASE TABLE' ORDER BY table_name`, f.d.Schema)
	if err != nil {
		t.Fatal(err)
	}
	var tables []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		tables = append(tables, name)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	want := []string{"chip_ledger", "diamond_purchases", "emojis", "friend_requests", "friendships", "hammer_purchases", "hammer_spends",
		"lucky_draw_slots", "lucky_draws", "missile_purchases", "missile_spends", "player_stats",
		"profile_pictures", "table_categories", "table_configs", "table_engines", "table_pictures", "table_settings",
		"user_emojis", "user_lucky_draws", "user_milestones", "user_profile_pictures", "user_table_choice", "user_table_pictures", "users"}
	if strings.Join(tables, ",") != strings.Join(want, ",") {
		t.Fatalf("schema %s has tables\n %v\nwant\n %v", f.d.Schema, tables, want)
	}

	// Every pooled connection resolves unqualified names in the test schema
	// first — a startup parameter, not a SET.
	var searchPath string
	if err := f.d.Pool.QueryRow(f.ctx, `SHOW search_path`).Scan(&searchPath); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(searchPath, f.d.Schema) || !strings.Contains(searchPath, "public") {
		t.Fatalf("search_path = %q, want it to lead with %s then public", searchPath, f.d.Schema)
	}
	var resolved string
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT 'chip_ledger'::regclass::text`).Scan(&resolved); err != nil {
		t.Fatal(err)
	}
	if resolved != "chip_ledger" {
		t.Fatalf("chip_ledger resolved to %q from the pool", resolved)
	}
}

// schema.sql runs on every boot; a second bootstrap of the same schema must
// be a no-op (IF NOT EXISTS / CREATE OR REPLACE / guarded trigger).
func TestBootstrapIsIdempotent(t *testing.T) {
	f := newFixture(t)

	again, err := db.Open(f.ctx, db.Options{URL: testURL(), Schema: f.d.Schema, PoolMax: 2})
	if err != nil {
		t.Fatalf("second Open on %s: %v", f.d.Schema, err)
	}
	defer again.Close()

	triggers := f.scalar(`SELECT COUNT(*) FROM pg_trigger WHERE tgname = 'chip_ledger_no_rewrite' AND tgrelid = 'chip_ledger'::regclass`)
	if triggers != 1 {
		t.Fatalf("expected exactly one append-only trigger, found %d", triggers)
	}
	// The seed ran twice and wrote each row once: 45 pictures, two engines and
	// seven categories, one settings row, the twelve default tables and seven
	// private templates, all active.
	if n := f.scalar(`SELECT COUNT(*) FROM profile_pictures`); n != 45 {
		t.Fatalf("profile_pictures holds %d rows after a second boot, want 45", n)
	}
	if n := f.scalar(`SELECT COUNT(*) FROM table_engines WHERE is_active`); n != 2 {
		t.Fatalf("table_engines holds %d active rows after a second boot, want 2", n)
	}
	if n := f.scalar(`SELECT COUNT(*) FROM table_categories WHERE is_active`); n != 7 {
		t.Fatalf("table_categories holds %d active rows after a second boot, want 7", n)
	}
	if n := f.scalar(`SELECT COUNT(*) FROM table_settings`); n != 1 {
		t.Fatalf("table_settings holds %d rows after a second boot, want 1", n)
	}
	if n := f.scalar(`SELECT COUNT(*) FROM table_configs WHERE is_active`); n != 19 {
		t.Fatalf("table_configs holds %d active rows after a second boot, want 19", n)
	}
	if n := f.scalar(`SELECT COUNT(*) FROM table_configs`); n != 19 {
		t.Fatalf("table_configs holds %d rows after a second boot, want 19", n)
	}
	// Data written before the re-run survives it.
	u := f.user("Survivor")
	if got := f.chips(u.ID); got != welcome {
		t.Fatalf("chips after re-bootstrap = %d", got)
	}
}

// Two processes (or two test binaries) bootstrapping one fresh schema at the
// same time must both succeed: the advisory lock serialises CREATE SCHEMA and
// the DDL, which otherwise race into pg_namespace / pg_type unique violations.
func TestParallelOpenOnAFreshSchemaSucceeds(t *testing.T) {
	// Probe reachability first (skips when Postgres is down).
	_ = dbtest.Open(t, "db")

	schema := "test_db_parallel_" + randomSuffix(t)
	const openers = 4
	var wg sync.WaitGroup
	results := make([]*db.DB, openers)
	errs := make([]error, openers)
	for i := range openers {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			results[i], errs[i] = db.Open(ctx, db.Options{URL: testURL(), Schema: schema, PoolMax: 2})
		}(i)
	}
	wg.Wait()

	t.Cleanup(func() {
		for _, d := range results {
			if d != nil {
				_ = d.DropSchema(context.Background())
				d.Close()
			}
		}
	})
	for i, err := range errs {
		if err != nil {
			t.Fatalf("opener %d failed: %v", i, err)
		}
	}
	var triggers int64
	if err := results[0].Pool.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM pg_trigger WHERE tgname = 'chip_ledger_no_rewrite' AND tgrelid = 'chip_ledger'::regclass`).Scan(&triggers); err != nil {
		t.Fatal(err)
	}
	if triggers != 1 {
		t.Fatalf("expected one trigger after %d parallel bootstraps, found %d", openers, triggers)
	}
}

func TestWithTxCommitsOnSuccessAndRollsBackOnError(t *testing.T) {
	f := newFixture(t)
	u := f.user("Tx")

	err := f.d.WithTx(f.ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(f.ctx, `UPDATE users SET display_name = 'Committed' WHERE id = $1`, u.ID)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if f.find(u.ID).DisplayName != "Committed" {
		t.Fatal("committed write not visible")
	}

	boom := errors.New("boom")
	err = f.d.WithTx(f.ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(f.ctx, `UPDATE users SET display_name = 'RolledBack' WHERE id = $1`, u.ID); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("expected fn's error back, got %v", err)
	}
	if f.find(u.ID).DisplayName != "Committed" {
		t.Fatal("a failed transaction leaked its write")
	}

	// A statement error inside fn (the transaction is aborted server-side)
	// is returned as-is and the earlier write is gone.
	err = f.d.WithTx(f.ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(f.ctx, `UPDATE users SET display_name = 'Half' WHERE id = $1`, u.ID); err != nil {
			return err
		}
		_, err := tx.Exec(f.ctx, `INSERT INTO users (id) VALUES ($1)`, u.ID) // NOT NULL violations
		return err
	})
	if err == nil {
		t.Fatal("expected the statement error")
	}
	if f.find(u.ID).DisplayName != "Committed" {
		t.Fatal("aborted transaction leaked its write")
	}
}

func TestWithTxRollsBackOnPanicAndRepanics(t *testing.T) {
	f := newFixture(t)
	u := f.user("Panic")

	defer func() {
		p := recover()
		if p == nil {
			t.Fatal("expected the panic to propagate")
		}
		if f.find(u.ID).DisplayName != "Panic" {
			t.Fatal("panicking transaction leaked its write")
		}
		// The pool is still usable afterwards.
		if got := f.chips(u.ID); got != welcome {
			t.Fatalf("chips = %d", got)
		}
	}()
	_ = f.d.WithTx(f.ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(f.ctx, `UPDATE users SET display_name = 'Doomed' WHERE id = $1`, u.ID); err != nil {
			return err
		}
		panic("mid-transaction")
	})
}

func TestDropSchemaRefusesPublic(t *testing.T) {
	f := newFixture(t)
	guard := &db.DB{Pool: f.d.Pool, Schema: "public"}
	err := guard.DropSchema(f.ctx)
	if err == nil || err.Error() != "refusing to drop the public schema" {
		t.Fatalf("expected the public refusal, got %v", err)
	}
	// public is still there.
	if n := f.scalar(`SELECT COUNT(*) FROM pg_namespace WHERE nspname = 'public'`); n != 1 {
		t.Fatal("public schema vanished")
	}
}

func TestStatsReportsPoolFiguresWithZeroWaiting(t *testing.T) {
	f := newFixture(t)
	_ = f.scalar(`SELECT 1`)
	s := f.d.Stats()
	if s.Total < 1 {
		t.Fatalf("expected at least one connection, got %+v", s)
	}
	if s.Waiting != 0 {
		t.Fatalf("waiting must always be 0 (pgx has no waiter count), got %+v", s)
	}
	if s.Idle > s.Total {
		t.Fatalf("idle > total: %+v", s)
	}
}

func TestCloseIsIdempotent(t *testing.T) {
	_ = dbtest.Open(t, "db")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	schema := "test_db_close_" + randomSuffix(t)
	d, err := db.Open(ctx, db.Options{URL: testURL(), Schema: schema, PoolMax: 2})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.DropSchema(ctx); err != nil {
		t.Fatal(err)
	}
	d.Close()
	d.Close() // second close must not panic
	var nilDB *db.DB
	nilDB.Close() // nor a nil receiver
}

// BIGINT and COUNT/SUM must come back as integers (Node parsed OIDs 20 and
// 1700 to numbers; pgx scans int8 into int64 and NUMERIC via ::bigint).
func TestBigintColumnsScanAsInt64(t *testing.T) {
	f := newFixture(t)
	u := f.user("Big")
	var chips, count, sum int64
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT chips FROM users WHERE id = $1`, u.ID).Scan(&chips); err != nil {
		t.Fatal(err)
	}
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1`, u.ID).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT SUM(delta)::bigint FROM chip_ledger WHERE user_id = $1`, u.ID).Scan(&sum); err != nil {
		t.Fatal(err)
	}
	if chips != welcome || count != 1 || sum != welcome {
		t.Fatalf("chips=%d count=%d sum=%d", chips, count, sum)
	}
}

func TestRedactHidesOnlyThePassword(t *testing.T) {
	cases := map[string]string{
		"postgres://postgres:postgres@localhost:5432/gameplay": "postgres://postgres:***@localhost:5432/gameplay",
		"postgres://u:p%40ss@h/db":                             "postgres://u:***@h/db",
		"postgres://h/db":                                      "postgres://h/db",
		"postgres://u@h:5432/db":                               "postgres://u@h:5432/db",
		"":                                                     "",
	}
	for in, want := range cases {
		if got := db.Redact(in); got != want {
			t.Errorf("Redact(%q) = %q, want %q", in, got, want)
		}
	}
}
