// Package dbtest opens a throwaway Postgres schema for one test and drops it
// afterwards (PORT_PLAN.md §Testing). Postgres-backed tests call
// dbtest.Open(t) first; when the database is unreachable the test is SKIPPED,
// never failed, so `go test ./...` passes on a machine without Postgres.
package dbtest

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// Open connects using TEST_DATABASE_URL, else DATABASE_URL, else the default
// config.Defaults().DB.URL, on schema "test_<pkg>_<6 hex>" (pkg = the test
// package's short name, e.g. "ledger"), runs the bootstrap, and registers a
// Cleanup that drops the schema and closes the pool. Skips the test when
// Open fails within 5 s.
func Open(t testing.TB, pkg string) *db.DB {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		url = os.Getenv("DATABASE_URL")
	}
	if url == "" {
		url = config.Defaults().DB.URL
	}
	var raw [3]byte
	if _, err := rand.Read(raw[:]); err != nil {
		t.Fatalf("dbtest: random schema suffix: %v", err)
	}
	schema := "test_" + pkg + "_" + hex.EncodeToString(raw[:])

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	d, err := db.Open(ctx, db.Options{URL: url, Schema: schema, PoolMax: 4})
	if err != nil {
		t.Skipf("dbtest: postgres unreachable at %s: %v", db.Redact(url), err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := d.DropSchema(ctx); err != nil {
			t.Errorf("dbtest: drop schema %s: %v", schema, err)
		}
		d.Close()
	})
	return d
}
