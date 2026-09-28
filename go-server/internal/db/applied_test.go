package db_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// Options.Applied and MigrationError are what `gameplay -migrate` reports
// from (cmd/gameplay/migrate.go): Open tells the caller of each script as it
// commits, in version order, and names the one that failed — through the one
// bootstrap every boot runs, never a second runner.
func TestOpenReportsEachScriptAsItCommitsAndNamesTheOneThatFails(t *testing.T) {
	reference := dbtest.Open(t, "db") // skips without PostgreSQL
	ctx := context.Background()
	schema := reference.Schema + "_applied"
	t.Cleanup(func() {
		_, _ = reference.Pool.Exec(context.Background(), "DROP SCHEMA IF EXISTS "+pgx.Identifier{schema}.Sanitize()+" CASCADE")
	})

	var applied []string
	open := func(opts db.Options) (*db.DB, error) {
		applied = nil
		opts.URL, opts.Schema, opts.PoolMax = testURL(), schema, 2
		opts.Applied = func(m db.Migration, took time.Duration) {
			if took < 0 {
				t.Errorf("%s took %v", m.File, took)
			}
			applied = append(applied, m.File)
		}
		return db.Open(ctx, opts)
	}
	var want []string
	for _, m := range db.Migrations() {
		want = append(want, m.File)
	}

	d, err := open(db.Options{})
	if err != nil {
		t.Fatal(err)
	}
	d.Close()
	if strings.Join(applied, ",") != strings.Join(want, ",") {
		t.Fatalf("Applied saw %v, want every script in version order %v", applied, want)
	}

	// SkipMigrations runs no script, so it reports none.
	d, err = open(db.Options{SkipMigrations: true})
	if err != nil {
		t.Fatal(err)
	}
	d.Close()
	if len(applied) != 0 {
		t.Fatalf("SkipMigrations reported %v", applied)
	}

	// The seed refused: the baseline is reported, the seed is named in a
	// MigrationError whose text is Open's as ever and whose cause is the
	// PostgreSQL error, and nothing after it runs.
	for _, sql := range []string{
		`CREATE FUNCTION ` + pgx.Identifier{schema, "refuse_insert"}.Sanitize() + `() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'refused'; END $$`,
		`CREATE TRIGGER refuse_insert BEFORE INSERT ON ` + pgx.Identifier{schema, "app_versions"}.Sanitize() + ` FOR EACH ROW EXECUTE FUNCTION ` + pgx.Identifier{schema, "refuse_insert"}.Sanitize() + `()`,
	} {
		if _, err := reference.Pool.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	_, err = open(db.Options{})
	var failed *db.MigrationError
	if !errors.As(err, &failed) || failed.Migration.File != "V1.0.1__seed.sql" {
		t.Fatalf("Open: %v, want a MigrationError naming V1.0.1__seed.sql", err)
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Message != "refused" {
		t.Errorf("the cause is not reachable through the MigrationError: %v", err)
	}
	if !strings.HasPrefix(err.Error(), "run V1.0.1__seed.sql: ERROR: refused") {
		t.Errorf("error text %q, want Open's \"run <file>: <cause>\"", err.Error())
	}
	if strings.Join(applied, ",") != want[0] {
		t.Errorf("Applied saw %v, want the baseline alone", applied)
	}
}
