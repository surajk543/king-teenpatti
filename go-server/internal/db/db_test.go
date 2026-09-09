package db_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// The Go binary embeds its own copy of schema.sql; it must stay a verbatim
// copy of the Node file so both servers bootstrap identical databases.
func TestSchemaSQLIsAVerbatimCopyOfTheNodeFile(t *testing.T) {
	nodePath := filepath.Join("..", "..", "..", "server", "src", "db", "schema.sql")
	nodeSQL, err := os.ReadFile(nodePath)
	if err != nil {
		t.Skipf("Node schema not present at %s: %v", nodePath, err)
	}
	if string(nodeSQL) != db.SchemaSQL() {
		t.Fatalf("internal/db/schema.sql differs from %s — copy it verbatim", nodePath)
	}
	if !strings.Contains(db.SchemaSQL(), "chip_ledger_no_rewrite") {
		t.Fatal("embedded schema lacks the append-only trigger")
	}
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
