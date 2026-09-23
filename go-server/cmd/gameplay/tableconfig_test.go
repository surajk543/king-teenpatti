package main

import (
	"bytes"
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// The two table-catalogue tools (tableconfig.go): -export-table-config writes
// the SQL that puts the env-composed catalogue in the database, and
// -check-table-config judges the database's catalogue as a db boot would.

// envOf is a config.Lookup over a map — the environment the tool is run in.
func envOf(env map[string]string) config.Lookup {
	return func(key string) (string, bool) {
		v, ok := env[key]
		return v, ok
	}
}

// exported runs -export-table-config in env and returns its exit code,
// stdout and stderr.
func exported(env map[string]string) (int, string, string) {
	var out, errs bytes.Buffer
	code := exportTableConfig(envOf(env), "no .env here", time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC), &out, &errs)
	return code, out.String(), errs.String()
}

// checked runs -check-table-config in env.
func checked(t *testing.T, env map[string]string) (int, string, string) {
	t.Helper()
	var out, errs bytes.Buffer
	code := checkTableConfig(context.Background(), envOf(env), "no .env here", &out, &errs)
	return code, out.String(), errs.String()
}

// testDatabaseURL is the database dbtest.Open connects to.
func testDatabaseURL() string {
	if url := os.Getenv("TEST_DATABASE_URL"); url != "" {
		return url
	}
	if url := os.Getenv("DATABASE_URL"); url != "" {
		return url
	}
	return config.Defaults().DB.URL
}

// apply runs an exported script on d's schema as psql would, less its one
// psql meta-command (`\set ON_ERROR_STOP on`, which only psql understands).
func apply(t *testing.T, d *db.DB, script string) {
	t.Helper()
	var kept []string
	for _, line := range strings.Split(script, "\n") {
		if !strings.HasPrefix(line, `\`) {
			kept = append(kept, line)
		}
	}
	if _, err := d.Pool.Exec(context.Background(), strings.Join(kept, "\n")); err != nil {
		t.Fatalf("the exported script did not apply: %v", err)
	}
}

// TestTheExportIsSQLAloneOnStdoutAndTheDiagnosticsOnStderr: stdout is a psql
// script and nothing else — so it can be piped straight into psql — and
// everything said about it goes to stderr: which .env, which table keys are
// set, how many tables were written, and the command that applies it, with
// the search_path psql needs on a schema other than public.
func TestTheExportIsSQLAloneOnStdoutAndTheDiagnosticsOnStderr(t *testing.T) {
	code, stdout, stderr := exported(map[string]string{
		"LOBBY_TABLES": "seen:200,blind:5000:max=50000000,texas_holdem:50000",
		"PG_SCHEMA":    "gameplay_live",
	})
	if code != exitTablesClean {
		t.Fatalf("exit %d, stderr:\n%s", code, stderr)
	}
	lines := strings.Split(strings.TrimSuffix(stdout, "\n"), "\n")
	if !strings.HasPrefix(lines[0], "-- King Teen Patti table configuration: gameplay -export-table-config") {
		t.Errorf("the script does not open with its header: %q", lines[0])
	}
	if !strings.Contains(stdout, "\n\\set ON_ERROR_STOP on\nBEGIN;\n") || !strings.HasSuffix(stdout, "\nCOMMIT;\n") {
		t.Errorf("not one transaction under ON_ERROR_STOP:\n%s", stdout)
	}
	for _, line := range lines {
		for _, diagnostic := range []string{"no .env here", "table env keys set", "exported ", "apply with", "warning", "{\"time\""} {
			if strings.HasPrefix(line, diagnostic) {
				t.Errorf("a diagnostic reached stdout: %q", line)
			}
		}
	}
	// Three public tables and the six private templates a menu without
	// variation can open, under the default engines and categories.
	if n := strings.Count(stdout, "INSERT INTO table_configs"); n != 9 {
		t.Errorf("%d table rows written, want 9", n)
	}
	if n := strings.Count(stdout, "INSERT INTO table_engines"); n != 2 {
		t.Errorf("%d engines written, want 2", n)
	}
	if n := strings.Count(stdout, "INSERT INTO table_categories"); n != 7 {
		t.Errorf("%d categories written, want 7", n)
	}
	if !strings.Contains(stdout, "-- Apply: PGOPTIONS='-c search_path=gameplay_live' psql") {
		t.Errorf("the header does not say how to apply it on gameplay_live:\n%s", stdout)
	}

	for _, want := range []string{
		"no .env here\n",
		"table env keys set: LOBBY_TABLES\n",
		"exported 3 public tables and 6 private templates, under 2 engines and 7 categories\n",
		"apply with: PGOPTIONS='-c search_path=gameplay_live' psql \"$DATABASE_URL\" -f <this file>\n",
		"PG_SCHEMA is gameplay_live, not public",
	} {
		if !strings.Contains(stderr, want) {
			t.Errorf("stderr does not say %q:\n%s", want, stderr)
		}
	}
}

// TestTheExportOfNoTableKeyIsTheDefaultsAndSaysSo: with no table key set the
// export is the code's default catalogue — the seed's — which is worth a
// warning (the operator most likely ran it without the deployment's .env);
// on public there is no search_path to set.
func TestTheExportOfNoTableKeyIsTheDefaultsAndSaysSo(t *testing.T) {
	code, stdout, stderr := exported(map[string]string{})
	if code != exitTablesClean {
		t.Fatalf("exit %d, stderr:\n%s", code, stderr)
	}
	if !strings.Contains(stderr, "warning: no table env key is set") {
		t.Errorf("no warning that this is the default catalogue:\n%s", stderr)
	}
	if strings.Contains(stderr+stdout, "PGOPTIONS") {
		t.Errorf("a search_path hint for the public schema:\n%s", stderr)
	}
	if n := strings.Count(stdout, "INSERT INTO table_configs"); n != 19 {
		t.Errorf("%d table rows written, want the defaults' 12 public and 7 private", n)
	}
}

// TestTheExportRefusesACatalogueNoLobbyCouldRunFrom: an empty menu (LOBBY_TABLES
// set to nothing, which a server reads as "any pair") is no catalogue at all;
// piped into psql it would retire every table in the database. So nothing
// reaches stdout and the exit code says so.
func TestTheExportRefusesACatalogueNoLobbyCouldRunFrom(t *testing.T) {
	code, stdout, stderr := exported(map[string]string{"LOBBY_TABLES": ""})
	if code != exitTablesLeftOut || stdout != "" {
		t.Fatalf("exit %d with %d bytes on stdout, want %d and nothing", code, len(stdout), exitTablesLeftOut)
	}
	if !strings.Contains(stderr, "nothing exported") {
		t.Errorf("stderr does not say why:\n%s", stderr)
	}
}

// TestTheCheckJudgesTheDatabaseAsADbBootWould: 0 when a boot would use every
// active row (the seed), 1 when it would leave some out (each named on
// stderr), 2 when it would fall back to the env composition — and 2 for a
// schema no server has booted on, which the check neither creates nor
// migrates.
func TestTheCheckJudgesTheDatabaseAsADbBootWould(t *testing.T) {
	d := dbtest.Open(t, "gameplay")
	env := map[string]string{"DATABASE_URL": testDatabaseURL(), "PG_SCHEMA": d.Schema, "TABLE_CONFIG_SOURCE": "db"}
	exec := func(sql string) {
		t.Helper()
		if _, err := d.Pool.Exec(context.Background(), sql); err != nil {
			t.Fatal(err)
		}
	}

	code, stdout, stderr := checked(t, env)
	if code != exitTablesClean {
		t.Fatalf("the seed: exit %d\n%s", code, stderr)
	}
	for _, want := range []string{
		"2 engines, 7 categories, 12 public tables, 7 private templates, 0 problems",
		"engine teen_patti            seen, blind, variation",
		"engine poker                 three_card_poker, five_card_draw, texas_holdem, omaha",
		"  seen:200 ", "  omaha:50000 ", "  private:seen ",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("the report does not say %q:\n%s", want, stdout)
		}
	}

	exec(`UPDATE table_configs SET pot_limit_multiplier = 9223372036854775807 WHERE table_key = 'seen:50000'`)
	code, stdout, stderr = checked(t, env)
	if code != exitTablesLeftOut || !strings.Contains(stderr, "problem: table seen:50000 left out") || !strings.Contains(stdout, "11 public tables") {
		t.Fatalf("a row left out: exit %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}

	exec(`UPDATE table_categories SET is_active = FALSE WHERE code = 'seen'`)
	code, _, stderr = checked(t, env)
	if code != exitTablesUnusable || !strings.Contains(stderr, "unusable: no usable private seen template") {
		t.Fatalf("no private seen template: exit %d\n%s", code, stderr)
	}

	missing := d.Schema + "_missing"
	env["PG_SCHEMA"] = missing
	code, _, stderr = checked(t, env)
	if code != exitTablesUnusable || !strings.Contains(stderr, "does not exist") {
		t.Fatalf("a schema no server booted on: exit %d\n%s", code, stderr)
	}
	var created bool
	if err := d.Pool.QueryRow(context.Background(), `SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = $1)`, missing).Scan(&created); err != nil || created {
		t.Fatalf("the check created schema %s (%v)", missing, err)
	}
}

// TestAnExportAppliedThenCheckedIsTheMenuTheEnvComposes: the switch an
// operator makes, end to end — export with the deployment's table keys, apply
// it to a database the seed filled, check — leaves exactly that menu active
// and nothing to report.
func TestAnExportAppliedThenCheckedIsTheMenuTheEnvComposes(t *testing.T) {
	d := dbtest.Open(t, "gameplay")
	menu := "seen:200,blind:5000:max=50000000"
	code, script, stderr := exported(map[string]string{"LOBBY_TABLES": menu})
	if code != exitTablesClean {
		t.Fatalf("export: exit %d\n%s", code, stderr)
	}
	apply(t, d, script)

	// Checked with the same .env, which still pins the menu.
	code, stdout, stderr := checked(t, map[string]string{"DATABASE_URL": testDatabaseURL(), "PG_SCHEMA": d.Schema, "LOBBY_TABLES": menu})
	if code != exitTablesClean {
		t.Fatalf("check: exit %d\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "2 engines, 7 categories, 2 public tables, 6 private templates, 0 problems") ||
		!strings.Contains(stdout, "  seen:200 ") || !strings.Contains(stdout, "  blind:5000 ") || strings.Contains(stdout, "private:variation") {
		t.Fatalf("the database does not hold the exported menu:\n%s", stdout)
	}
	// That environment names no source and sets a table key, so a server run
	// with it would still be on env until TABLE_CONFIG_SOURCE=db is set: the
	// check says so.
	if !strings.Contains(stderr, "TABLE_CONFIG_SOURCE resolves to env here") {
		t.Errorf("no note that this environment does not read the rows:\n%s", stderr)
	}
}
