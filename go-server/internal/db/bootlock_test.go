package db_test

import (
	"context"
	"os"
	"testing"
	"time"

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
}
