package main

// The migration tool the binary carries (owner, 29 Sep 2026: "Create a script
// whenever i run it applies all ddl/dml from migration folder and then it
// takes latest pull and deploy backend tag"), handled by main BEFORE run, like
// the table tools (tableconfig.go): no server, no live store, nothing logged
// on stdout.
//
//	gameplay -migrate   applies every embedded migration to DATABASE_URL /
//	                    PG_SCHEMA — exactly what a boot applies — and exits
//
// It is the first half of a boot and nothing after it. ops/deploy.sh runs it
// with the NEW binary before it restarts the service, so a script that fails
// stops the deploy while the previous build is still serving, and the restart
// that follows finds nothing left to do.
//
// There is no second migration runner here. The database is opened through
// the same db.Open a boot uses — CREATE SCHEMA IF NOT EXISTS, the schema's
// advisory lock, lock_timeout, then every V*.sql embedded in the binary, in
// version order, on one connection, each script one implicit transaction —
// and only told to report each script as it commits (db.Options.Applied).
// There is no schema history table either (internal/db's migrationFS): every
// script runs every time, which is safe only because every script is
// idempotent, so a second -migrate, and the boot after it, change nothing.
//
// It must run as the role the SERVER connects as — the DATABASE_URL of the
// server's own .env, as the service's user in the service's working directory
// — never as postgres through psql: a table belongs to whoever creates it, and
// a table postgres owns is one the server cannot write to (DEPLOY.md §7).
//
// The environment is the server's: ./.env through godotenv (never overriding
// what the process already has), then config.FromEnv — config.Load less the
// two defaults it adds, PUBLIC_DIR and LIVE_INSTANCE_ID, which touch no
// database. DATABASE_URL, PG_SCHEMA and PG_STATEMENT_TIMEOUT_MS are honoured
// as the server honours them, and the production guards apply, so a .env the
// new build would refuse to boot on is refused here, before any restart.
// Nothing else is opened: no Redis, no listener, no table catalogue, no
// background job.
//
// stdout: a header, one line per script applied, a summary. stderr: where the
// environment came from and any error, naming the script that failed. Exit
// exitMigrated when every script applied, exitMigrateFailed on anything else —
// the configuration, the connection, the lock or a script.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Exit codes of -migrate.
const (
	exitMigrated      = 0 // every embedded script applied
	exitMigrateFailed = 1 // the configuration, the connection or a script failed
)

// migrateTimeout bounds the whole of -migrate — connect, schema lock and every
// script — so a deploy never hangs on it, whatever PG_STATEMENT_TIMEOUT_MS
// says (0 bounds nothing). Every script on this database takes seconds; the
// lock_timeout db.Open sets fails a blocked lock in three.
const migrateTimeout = 5 * time.Minute

// migrateDatabase is -migrate: DATABASE_URL / PG_SCHEMA opened through
// db.Open, which applies every embedded migration in version order, with each
// one reported on stdout as it commits. See the file comment.
func migrateDatabase(ctx context.Context, lookup config.Lookup, envNote string, stdout, stderr io.Writer) int {
	began := time.Now()
	fmt.Fprintln(stderr, envNote)
	cfg, err := config.FromEnv(lookup)
	if err != nil {
		fmt.Fprintln(stderr, "error: configuration:", err)
		return exitMigrateFailed
	}

	scripts := db.Migrations()
	width := 0
	for _, script := range scripts {
		width = max(width, len(script.File))
	}
	fmt.Fprintf(stdout, "gameplay -migrate: build %s, schema %s on %s, %d scripts embedded\n",
		version, cfg.DB.Schema, db.Redact(cfg.DB.URL), len(scripts))

	ctx, cancel := context.WithTimeout(ctx, migrateTimeout)
	defer cancel()
	applied := 0
	database, err := db.Open(ctx, db.Options{
		URL:              cfg.DB.URL,
		Schema:           cfg.DB.Schema,
		PoolMax:          2,
		StatementTimeout: time.Duration(cfg.DB.StatementTimeoutMs) * time.Millisecond,
		Logger:           util.NewLogger("warn", stderr),
		Applied: func(m db.Migration, took time.Duration) {
			applied++
			fmt.Fprintf(stdout, "  applied  %-*s  %6d ms\n", width, m.File, took.Milliseconds())
		},
	})
	if err != nil {
		var failed *db.MigrationError
		if !errors.As(err, &failed) {
			// Before any script: the URL, the connection, the schema or its lock.
			fmt.Fprintf(stderr, "error: cannot migrate schema %s on %s: %v\n", cfg.DB.Schema, db.Redact(cfg.DB.URL), err)
			return exitMigrateFailed
		}
		// err reads "run <file>: <cause>[, what holds the lock]"; the file is named once.
		fmt.Fprintf(stderr, "error: %s failed: %s\n", failed.Migration.File,
			strings.TrimPrefix(err.Error(), "run "+failed.Migration.File+": "))
		var notRun []string
		for _, script := range scripts[min(applied+1, len(scripts)):] {
			notRun = append(notRun, script.File)
		}
		after := "none after it"
		if len(notRun) > 0 {
			after = "not run: " + strings.Join(notRun, ", ")
		}
		fmt.Fprintf(stderr, "migration of schema %s stopped: %d of %d scripts applied; %s rolled back as a whole (each script is one transaction); %s\n",
			cfg.DB.Schema, applied, len(scripts), failed.Migration.File, after)
		return exitMigrateFailed
	}
	database.Close()
	fmt.Fprintf(stdout, "migrated schema %s: %d of %d scripts applied in %d ms\n",
		cfg.DB.Schema, applied, len(scripts), time.Since(began).Milliseconds())
	return exitMigrated
}
