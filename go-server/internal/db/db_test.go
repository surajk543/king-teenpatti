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
	// The consolidation of 14 Sep 2026 left one DDL script and one DML script
	// to build an empty database. V1.0.2__new_account_diamonds.sql, added the
	// same day, was folded back into the baseline with the pictures' HAMMER
	// currency, for another fresh production start (DEPLOY.md §8), and so, after
	// production had run the pair, were V1.0.2__timed_bonus_milestone.sql (into
	// the baseline) and V1.0.3__seed_new_pictures.sql (into the seed).
	// V1.0.2__chip_ledger_game.sql (owner, 19 Sep 2026) is the first script
	// written AFTER production ran the pair, and so the first that must reach
	// an existing database: two ADD COLUMN IF NOT EXISTS on chip_ledger, which
	// the baseline's CREATE TABLE IF NOT EXISTS could never add (POKER_PLAN.md
	// §6).
	// V1.0.3__users_is_bot.sql (owner, 22 Sep 2026) is the second such script:
	// one guarded column on users marking an account as one of the resident
	// bots (bot-play/), so a query about real players can leave them out.
	if len(migrations) != 4 {
		t.Fatalf("expected one DDL script, one DML script, the chip_ledger game columns and users.is_bot, got %d", len(migrations))
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
	baseline, seed, columns := statementsOf(migrations[0].SQL), statementsOf(migrations[1].SQL), statementsOf(migrations[2].SQL)
	// The third script adds two columns to a table the baseline already
	// built, idempotently, and does nothing else.
	for _, want := range []string{
		"EXECUTE 'ALTER TABLE chip_ledger ADD COLUMN game TEXT'",
		"EXECUTE 'ALTER TABLE chip_ledger ADD COLUMN variant TEXT'",
		"column_name = 'game'", "column_name = 'variant'",
	} {
		if !strings.Contains(columns, want) {
			t.Errorf("%s lacks %q", migrations[2].File, want)
		}
	}
	// Guarded by a catalogue lookup, never `ADD COLUMN IF NOT EXISTS`: that
	// form takes ACCESS EXCLUSIVE even when it does nothing, and a restart
	// would queue behind any reader (TestABootSurvivesALongReaderHoldingTheTables).
	if strings.Contains(columns, "IF NOT EXISTS game") || strings.Contains(columns, "IF NOT EXISTS variant") {
		t.Errorf("%s must guard its ALTERs with a catalogue lookup, not ADD COLUMN IF NOT EXISTS", migrations[2].File)
	}
	for _, forbidden := range []string{"CREATE TABLE", "INSERT INTO", "DROP"} {
		if strings.Contains(columns, forbidden) {
			t.Errorf("%s must only add the two columns, found %s", migrations[2].File, forbidden)
		}
	}

	// The fourth script is the same shape for one column on users: guarded by
	// a catalogue lookup, adding nothing else, and defaulting to FALSE so
	// every row that already exists — and every person who signs in — is a
	// person unless something says otherwise.
	isBot := statementsOf(migrations[3].SQL)
	for _, want := range []string{
		"EXECUTE 'ALTER TABLE users ADD COLUMN is_bot BOOLEAN NOT NULL DEFAULT FALSE'",
		"column_name = 'is_bot'",
	} {
		if !strings.Contains(isBot, want) {
			t.Errorf("%s lacks %q", migrations[3].File, want)
		}
	}
	if strings.Contains(isBot, "IF NOT EXISTS is_bot") {
		t.Errorf("%s must guard its ALTER with a catalogue lookup, not ADD COLUMN IF NOT EXISTS", migrations[3].File)
	}
	for _, forbidden := range []string{"CREATE TABLE", "INSERT INTO", "DROP"} {
		if strings.Contains(isBot, forbidden) {
			t.Errorf("%s must only add the one column, found %s", migrations[3].File, forbidden)
		}
	}
	if !strings.Contains(baseline, "CREATE TABLE IF NOT EXISTS users") {
		t.Error("the baseline does not create users")
	}
	if strings.Contains(baseline, "INSERT INTO") {
		t.Errorf("%s is DDL and must hold no rows", migrations[0].File)
	}
	// A fresh schema is built from these alone, so nothing may depend on an
	// ALTER to add a column after the fact.
	if strings.Contains(baseline, "ALTER TABLE") {
		t.Error("the baseline declares its tables in full; it needs no ALTER")
	}
	if !strings.Contains(seed, "INSERT INTO profile_pictures") {
		t.Errorf("%s should seed the catalogue", migrations[1].File)
	}
	for _, ddl := range []string{"CREATE TABLE", "ALTER TABLE", "CREATE INDEX"} {
		if strings.Contains(seed, ddl) {
			t.Errorf("%s is DML and must not %s", migrations[1].File, ddl)
		}
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

	for _, table := range []string{"users", "chip_ledger"} {
		n := f.scalar(`SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2`, f.d.Schema, table)
		if n != 1 {
			t.Fatalf("table %s missing from schema %s", table, f.d.Schema)
		}
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
