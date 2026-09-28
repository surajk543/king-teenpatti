package db_test

import (
	"context"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// A restart must survive somebody reading the tables.
//
// schema.sql runs on every boot, and an `ALTER TABLE ... ADD COLUMN IF NOT
// EXISTS` takes ACCESS EXCLUSIVE even when the column is already there, so it
// queues behind any reader. On 9 Sep 2026 a long-running report over users and
// chip_ledger held ACCESS SHARE for fifteen minutes; every start waited on it,
// hit PG_STATEMENT_TIMEOUT_MS and exited, and systemd restarted the server
// into the same wall seven times. Production was down while nothing was
// actually wrong with it.
//
// A boot that changes nothing must now take no lock a plain SELECT can block.
func TestABootSurvivesALongReaderHoldingTheTables(t *testing.T) {
	first := dbtest.Open(t, "bootlock")
	ctx := context.Background()

	// A reader that stays open for the whole test, exactly as a long report
	// would: inside a transaction, so its ACCESS SHARE is genuinely held.
	reader, err := first.Pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire reader: %v", err)
	}
	defer reader.Release()
	tx, err := reader.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	var n int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&n); err != nil {
		t.Fatalf("read users: %v", err)
	}
	if _, err := tx.Exec(ctx, `SELECT 1 FROM chip_ledger LIMIT 1`); err != nil {
		t.Fatalf("read chip_ledger: %v", err)
	}
	// The table catalogue too (23 Sep 2026), all four tables: the seed writes
	// into them on every boot, the baseline declares their keys and the
	// foreign keys between them, and none of that may need a lock a report
	// over the lobby's configuration would hold.
	// And the emoji store's two (26 Sep 2026): a boot finds them there and
	// does nothing to them. Nor to Friends V1's three (26 Sep 2026), nor to
	// Player stats v2's statistics and receipts (27 Sep 2026), nor to Report
	// Player's player_reports (27 Sep 2026), nor to the sign-ins each token
	// must match (user_sessions, 28 Sep 2026), nor to the XP sources — whose
	// three one-time mission columns (28 Sep 2026) a boot adds only where
	// they are missing — and each player's missions, nor to the app version
	// gate's rows (app_versions, 28 Sep 2026: its trigger is created only when
	// missing).
	for _, table := range []string{"table_engines", "table_categories", "table_settings", "table_configs", "emojis", "user_emojis",
		"player_stats", "player_variation_stats", "stats_flushes", "friend_requests", "friendships", "player_reports", "user_sessions",
		"xp_sources", "player_xp_missions", "app_versions"} {
		if _, err := tx.Exec(ctx, `SELECT 1 FROM `+table+` LIMIT 1`); err != nil {
			t.Fatalf("read %s: %v", table, err)
		}
	}

	// Now boot a second time against the same schema, as a restart would,
	// with a statement timeout as tight as production's is generous.
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		url = os.Getenv("DATABASE_URL")
	}
	if url == "" {
		url = config.Defaults().DB.URL
	}

	booted := make(chan error, 1)
	go func() {
		bootCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		second, err := db.Open(bootCtx, db.Options{
			URL:              url,
			Schema:           first.Schema,
			PoolMax:          2,
			StatementTimeout: 5 * time.Second,
		})
		if second != nil {
			second.Close()
		}
		booted <- err
	}()

	select {
	case err := <-booted:
		if err != nil {
			t.Fatalf("a restart must not be blocked by a reader: %v", err)
		}
	case <-time.After(25 * time.Second):
		t.Fatal("the boot hung behind the reader — this is the crash loop of 9 Sep 2026")
	}

	// The reader was untouched throughout: the boot did not need its lock.
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&n); err != nil {
		t.Fatalf("the reader was disturbed by the boot: %v", err)
	}
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM table_configs`).Scan(&n); err != nil || n != 19 {
		t.Fatalf("the reader was disturbed by the boot, or the seed wrote twice: %d rows, %v", n, err)
	}
	if err := tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM table_engines) + (SELECT count(*) FROM table_categories)`).Scan(&n); err != nil || n != 9 {
		t.Fatalf("the reader was disturbed by the boot, or the seed wrote the taxonomy twice: %d rows, %v", n, err)
	}
}

// A boot that changes nothing must not wait for a WRITER either, nor make one
// wait.
//
// Since 29 Sep 2026 ops/deploy.sh runs every migration (`gameplay -migrate`)
// while the previous build is still serving, so the scripts meet live
// writers, not only readers: a hand-end settle inserting into chip_ledger, a
// purchase writing its ledger row and then an ownership row. CREATE INDEX IF
// NOT EXISTS takes SHARE on its table BEFORE it looks for the index, and SHARE
// waits for every open writer and makes every later writer queue behind it —
// the ledger frozen for up to lock_timeout at every table, and, since the
// baseline reached user_profile_pictures before chip_ledger while a purchase
// writes them the other way round, a deadlock that aborted a purchase. Every
// index is therefore built behind a catalogue lookup, as idx_users_last_login
// always was, and a database that has it takes no lock for it at all.
//
// Checked twice: every table held ROW EXCLUSIVE (what an INSERT, UPDATE or
// DELETE holds) by an open transaction while a second boot runs; and every
// script replayed inside a transaction on an up-to-date schema, whose relation
// locks must include none that conflicts with ROW EXCLUSIVE.
func TestABootThatChangesNothingWaitsForNoWriter(t *testing.T) {
	first := dbtest.Open(t, "bootwriter")
	ctx := context.Background()

	var tables []string
	rows, err := first.Pool.Query(ctx, `SELECT table_name FROM information_schema.tables
	     WHERE table_schema = $1 AND table_type = 'BASE TABLE' ORDER BY table_name`, first.Schema)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		tables = append(tables, name)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(tables) < 39 {
		t.Fatalf("the schema holds %d tables, want every one a boot creates", len(tables))
	}

	// The lookups guard, and never skip: every index the baseline names was
	// built on this fresh schema, although the database's public schema (the
	// dev server's) holds indexes of the same names — the lookup is qualified
	// with the schema being migrated, never left to the search_path.
	named := regexp.MustCompile(`INDEX IF NOT EXISTS (\w+)`).FindAllStringSubmatch(db.Migrations()[0].SQL, -1)
	if len(named) < 19 {
		t.Fatalf("the baseline names %d indexes, want the nineteen it builds", len(named))
	}
	for _, m := range named {
		var found bool
		if err := first.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = $2)`,
			first.Schema, m[1]).Scan(&found); err != nil {
			t.Fatal(err)
		}
		if !found {
			t.Errorf("index %s was not built on a fresh schema", m[1])
		}
	}

	// The replay first, on a schema nobody else is using: it names every
	// table a no-op migration would stall, not only the first one a boot
	// would trip over.
	conn, err := first.Pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tx, err := conn.Begin(ctx)
	if err != nil {
		conn.Release()
		t.Fatal(err)
	}
	for _, m := range db.Migrations() {
		if _, err := tx.Exec(ctx, m.SQL); err != nil {
			_ = tx.Rollback(ctx)
			conn.Release()
			t.Fatalf("replay %s: %v", m.File, err)
		}
	}
	var held []string
	lockRows, err := tx.Query(ctx, `
		SELECT c.relname || ' ' || l.mode
		  FROM pg_locks l
		  JOIN pg_class c ON c.oid = l.relation
		  JOIN pg_namespace n ON n.oid = c.relnamespace
		 WHERE l.pid = pg_backend_pid() AND l.locktype = 'relation' AND l.granted
		   AND n.nspname = $1
		   AND l.mode IN ('ShareLock', 'ShareRowExclusiveLock', 'ExclusiveLock', 'AccessExclusiveLock')
		 ORDER BY 1`, first.Schema)
	if err == nil {
		for lockRows.Next() {
			var lock string
			if err = lockRows.Scan(&lock); err != nil {
				break
			}
			held = append(held, lock)
		}
		lockRows.Close()
		if err == nil {
			err = lockRows.Err()
		}
	}
	_ = tx.Rollback(ctx)
	conn.Release()
	if err != nil {
		t.Fatal(err)
	}
	if len(held) > 0 {
		t.Errorf("a migration that changes nothing takes %d lock(s) every writer waits for — guard the statement with a catalogue lookup:\n  %s",
			len(held), strings.Join(held, "\n  "))
	}

	// Then the boot itself, beside a writer on every table.
	writer, err := first.Pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire writer: %v", err)
	}
	defer writer.Release()
	wtx, err := writer.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	defer func() { _ = wtx.Rollback(context.WithoutCancel(ctx)) }()
	for _, table := range tables {
		if _, err := wtx.Exec(ctx, `LOCK TABLE `+pgx.Identifier{first.Schema, table}.Sanitize()+` IN ROW EXCLUSIVE MODE`); err != nil {
			t.Fatalf("lock %s: %v", table, err)
		}
	}

	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		url = os.Getenv("DATABASE_URL")
	}
	if url == "" {
		url = config.Defaults().DB.URL
	}
	booted := make(chan error, 1)
	go func() {
		bootCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		second, err := db.Open(bootCtx, db.Options{URL: url, Schema: first.Schema, PoolMax: 2, StatementTimeout: 5 * time.Second})
		if second != nil {
			second.Close()
		}
		booted <- err
	}()
	select {
	case err := <-booted:
		if err != nil {
			t.Fatalf("a boot that changes nothing waited for a writer: %v", err)
		}
	case <-time.After(25 * time.Second):
		t.Fatal("the boot hung behind a writer")
	}
}
