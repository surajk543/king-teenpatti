package main

import (
	"bytes"
	"context"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// -migrate (migrate.go): every embedded migration applied through db.Open —
// what a boot applies — reported script by script, and nothing else.

// migrated runs -migrate in env and returns its exit code, stdout and stderr.
func migrated(t *testing.T, env map[string]string) (int, string, string) {
	t.Helper()
	var out, errs bytes.Buffer
	code := migrateDatabase(context.Background(), envOf(env), "no .env here", &out, &errs)
	return code, out.String(), errs.String()
}

// freshSchema is a schema no process has created yet, dropped when the test
// ends, beside the reference schema dbtest built through db.Open — the one a
// boot would have left.
func freshSchema(t *testing.T) (reference *db.DB, fresh string) {
	t.Helper()
	reference = dbtest.Open(t, "gameplay")
	fresh = reference.Schema + "_migrate"
	t.Cleanup(func() {
		if _, err := reference.Pool.Exec(context.Background(), "DROP SCHEMA IF EXISTS "+pgx.Identifier{fresh}.Sanitize()+" CASCADE"); err != nil {
			t.Errorf("drop schema %s: %v", fresh, err)
		}
	})
	return reference, fresh
}

// tablesOf lists schema's base tables, in name order, with their row counts.
func tablesOf(t *testing.T, d *db.DB, schema string) map[string]int64 {
	t.Helper()
	ctx := context.Background()
	rows, err := d.Pool.Query(ctx, `SELECT table_name FROM information_schema.tables
	     WHERE table_schema = $1 AND table_type = 'BASE TABLE' ORDER BY table_name`, schema)
	if err != nil {
		t.Fatal(err)
	}
	names, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	counts := make(map[string]int64, len(names))
	for _, name := range names {
		var n int64
		if err := d.Pool.QueryRow(ctx, "SELECT COUNT(*) FROM "+pgx.Identifier{schema, name}.Sanitize()).Scan(&n); err != nil {
			t.Fatal(err)
		}
		counts[name] = n
	}
	return counts
}

// appliedLines are the "applied <file>" lines of a report, in order.
var appliedLine = regexp.MustCompile(`(?m)^  applied  (\S+)\s+\d+ ms$`)

func appliedFiles(stdout string) []string {
	var files []string
	for _, match := range appliedLine.FindAllStringSubmatch(stdout, -1) {
		files = append(files, match[1])
	}
	return files
}

func embeddedFiles() []string {
	var files []string
	for _, m := range db.Migrations() {
		files = append(files, m.File)
	}
	return files
}

// TestMigrateBuildsAFreshSchemaExactlyAsABootWould: on a schema nobody has
// created, -migrate creates it and leaves what a boot leaves — the thirty-nine
// tables and every seeded row, table for table and count for count the schema
// db.Open built for dbtest — and its report names every embedded script, in
// version order, and the schema, the count and the time.
func TestMigrateBuildsAFreshSchemaExactlyAsABootWould(t *testing.T) {
	reference, fresh := freshSchema(t)
	code, stdout, stderr := migrated(t, map[string]string{"DATABASE_URL": testDatabaseURL(), "PG_SCHEMA": fresh})
	if code != exitMigrated {
		t.Fatalf("exit %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}

	if got, want := strings.Join(appliedFiles(stdout), ","), strings.Join(embeddedFiles(), ","); got != want {
		t.Fatalf("the report applied %s, want every embedded script in order: %s\n%s", got, want, stdout)
	}
	for _, want := range []string{
		"gameplay -migrate: build " + version + ", schema " + fresh + " on ",
		"migrated schema " + fresh + ": " + strconv.Itoa(len(db.Migrations())) + " of " + strconv.Itoa(len(db.Migrations())) + " scripts applied in ",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("the report does not say %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "postgres:postgres@") {
		t.Errorf("the report prints the database password:\n%s", stdout)
	}
	if strings.Contains(stderr, "error") {
		t.Errorf("stderr reports an error on success:\n%s", stderr)
	}

	got, want := tablesOf(t, reference, fresh), tablesOf(t, reference, reference.Schema)
	if len(got) != 39 {
		t.Errorf("schema %s has %d tables, want the thirty-nine a boot creates", fresh, len(got))
	}
	for name, rows := range want {
		if _, ok := got[name]; !ok {
			t.Errorf("table %s is missing", name)
		} else if got[name] != rows {
			t.Errorf("table %s holds %d rows, a boot's holds %d", name, got[name], rows)
		}
	}
	for name := range got {
		if _, ok := want[name]; !ok {
			t.Errorf("table %s is not one a boot creates", name)
		}
	}
	// The seeds really ran: the catalogues a fresh database starts with.
	for _, seeded := range []string{"profile_pictures", "table_engines", "table_categories", "table_settings", "table_configs",
		"emojis", "lucky_draws", "lucky_draw_slots", "player_levels", "badges", "xp_sources", "app_versions"} {
		if got[seeded] == 0 {
			t.Errorf("seeded table %s is empty", seeded)
		}
	}
}

// TestMigrateTwiceChangesNothingAndStillSucceeds: every script is idempotent,
// so a second run — the deploy that finds nothing new, or the boot after a
// deploy — applies every script again, changes no row and exits 0.
func TestMigrateTwiceChangesNothingAndStillSucceeds(t *testing.T) {
	reference, fresh := freshSchema(t)
	env := map[string]string{"DATABASE_URL": testDatabaseURL(), "PG_SCHEMA": fresh}
	if code, stdout, stderr := migrated(t, env); code != exitMigrated {
		t.Fatalf("first run: exit %d\n%s\n%s", code, stdout, stderr)
	}
	before := tablesOf(t, reference, fresh)

	code, stdout, stderr := migrated(t, env)
	if code != exitMigrated {
		t.Fatalf("second run: exit %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if got, want := strings.Join(appliedFiles(stdout), ","), strings.Join(embeddedFiles(), ","); got != want {
		t.Errorf("the second report applied %s, want %s", got, want)
	}
	after := tablesOf(t, reference, fresh)
	for name, rows := range before {
		if after[name] != rows {
			t.Errorf("table %s went from %d rows to %d on the second run", name, rows, after[name])
		}
	}
	if len(after) != len(before) {
		t.Errorf("%d tables after the second run, %d before", len(after), len(before))
	}
}

// TestMigrateFailsOnAnEnvironmentItCannotUse: a DATABASE_URL that does not
// parse or reaches nobody, a malformed integer key and a production .env the
// server would refuse to boot on all exit 1 with the reason on stderr and no
// script reported applied. None of them needs a database.
func TestMigrateFailsOnAnEnvironmentItCannotUse(t *testing.T) {
	for _, tc := range []struct {
		name string
		env  map[string]string
		says string
	}{
		{"nobody listening", map[string]string{"DATABASE_URL": "postgres://nobody:secret@127.0.0.1:1/none", "PG_SCHEMA": "test_nowhere"}, "cannot migrate schema test_nowhere on postgres://nobody:***@127.0.0.1:1/none"},
		{"an unparsable URL", map[string]string{"DATABASE_URL": "postgres://[::1", "PG_SCHEMA": "test_nowhere"}, "parse DATABASE_URL"},
		{"a malformed statement timeout", map[string]string{"PG_STATEMENT_TIMEOUT_MS": "15s"}, "error: configuration:"},
		{"a schema that is not an identifier", map[string]string{"PG_SCHEMA": "bad-name"}, "PG_SCHEMA must be a plain identifier"},
		{"production on a short JWT secret", map[string]string{"NODE_ENV": "production", "JWT_SECRET": "short"}, "JWT_SECRET must be at least 32 bytes in production"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			code, stdout, stderr := migrated(t, tc.env)
			if code != exitMigrateFailed {
				t.Fatalf("exit %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitMigrateFailed, stdout, stderr)
			}
			if !strings.Contains(stderr, tc.says) {
				t.Errorf("stderr does not say %q:\n%s", tc.says, stderr)
			}
			if files := appliedFiles(stdout); len(files) != 0 {
				t.Errorf("scripts reported applied: %v", files)
			}
			if strings.Contains(stdout+stderr, "secret@") {
				t.Errorf("the password was printed:\n%s\n%s", stdout, stderr)
			}
		})
	}
}

// TestMigrateNamesTheScriptThatFailsAndStopsThere: a script that fails is
// named on stderr with the reason; the scripts before it are reported applied
// and the ones after it did not run; exit 1. Here the seed fails on a schema
// whose app_versions refuses every insert — the baseline runs, V1.0.1 does
// not, and, being one transaction, leaves none of its rows behind.
func TestMigrateNamesTheScriptThatFailsAndStopsThere(t *testing.T) {
	reference, fresh := freshSchema(t)
	env := map[string]string{"DATABASE_URL": testDatabaseURL(), "PG_SCHEMA": fresh}
	if code, stdout, stderr := migrated(t, env); code != exitMigrated {
		t.Fatalf("first run: exit %d\n%s\n%s", code, stdout, stderr)
	}
	ctx := context.Background()
	for _, sql := range []string{
		`CREATE FUNCTION ` + pgx.Identifier{fresh, "refuse_insert"}.Sanitize() + `() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'no inserts into %', TG_TABLE_NAME; END $$`,
		`CREATE TRIGGER refuse_insert BEFORE INSERT ON ` + pgx.Identifier{fresh, "app_versions"}.Sanitize() + ` FOR EACH ROW EXECUTE FUNCTION ` + pgx.Identifier{fresh, "refuse_insert"}.Sanitize() + `()`,
		`DELETE FROM ` + pgx.Identifier{fresh, "profile_pictures"}.Sanitize() + ` WHERE name = 'Bear'`,
	} {
		if _, err := reference.Pool.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}

	code, stdout, stderr := migrated(t, env)
	if code != exitMigrateFailed {
		t.Fatalf("exit %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitMigrateFailed, stdout, stderr)
	}
	scripts := embeddedFiles()
	if got := appliedFiles(stdout); strings.Join(got, ",") != scripts[0] {
		t.Errorf("reported applied %v, want the baseline alone", got)
	}
	for _, want := range []string{
		"error: V1.0.1__seed.sql failed: ERROR: no inserts into app_versions",
		"migration of schema " + fresh + " stopped: 1 of " + strconv.Itoa(len(scripts)) + " scripts applied; V1.0.1__seed.sql rolled back as a whole",
		"not run: " + strings.Join(scripts[2:], ", "),
	} {
		if !strings.Contains(stderr, want) {
			t.Errorf("stderr does not say %q:\n%s", want, stderr)
		}
	}
	if strings.Contains(stdout, "migrated schema") {
		t.Errorf("a failed run reports success:\n%s", stdout)
	}
	// The seed's picture rows went back with the rest of it: Bear, deleted
	// above and re-inserted by V1.0.1 before its app_versions insert failed,
	// is still gone.
	var bears int
	if err := reference.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM `+pgx.Identifier{fresh, "profile_pictures"}.Sanitize()+` WHERE name = 'Bear'`).Scan(&bears); err != nil || bears != 0 {
		t.Errorf("%d Bear rows after the failed seed (%v): the script was not rolled back as a whole", bears, err)
	}
}
