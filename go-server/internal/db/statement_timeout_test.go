package db_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// A hung statement must fail after StatementTimeout instead of holding the
// caller (in production: a table's actor) forever. Postgres reports it as
// SQLSTATE 57014 (query_canceled).
func TestStatementTimeoutCutsOffAHungQuery(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		url = os.Getenv("DATABASE_URL")
	}
	if url == "" {
		url = config.Defaults().DB.URL
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	d, err := db.Open(ctx, db.Options{URL: url, Schema: "test_db_stmt_timeout", PoolMax: 2, StatementTimeout: 300 * time.Millisecond})
	if err != nil {
		t.Skipf("postgres unreachable: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = d.DropSchema(ctx)
		d.Close()
	})

	started := time.Now()
	_, err = d.Pool.Exec(ctx, "select pg_sleep(5)")
	elapsed := time.Since(started)
	if err == nil {
		t.Fatalf("pg_sleep(5) completed in %v; statement_timeout was not applied", elapsed)
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "57014" {
		t.Fatalf("want SQLSTATE 57014 query_canceled, got %v", err)
	}
	if elapsed > 3*time.Second {
		t.Fatalf("statement took %v to fail; the timeout did not bound it", elapsed)
	}

	// The pool is still usable afterwards: the cancelled statement did not
	// poison the connection.
	var one int
	if err := d.Pool.QueryRow(ctx, "select 1").Scan(&one); err != nil || one != 1 {
		t.Fatalf("pool unusable after a timed-out statement: %v", err)
	}
}
