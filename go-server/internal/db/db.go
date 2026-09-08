// Package db is the PostgreSQL layer: the port of server/src/db/index.js
// (pool, schema bootstrap, transaction helper), db/ledger.js (the three money
// transactions, as game.Ledger) and db/users.js (the account store).
//
// pgx v5 returns BIGINT as int64 and NUMERIC as pgtype.Numeric natively, so
// Node's two type parsers have no equivalent here — but keep every chip and
// timestamp column scanned into int64 (never float64), and scan SUM(bigint)
// (NUMERIC) through pgtype.Numeric or `::bigint` casts.
//
// All money is int64; all timestamps are epoch milliseconds (BIGINT), written
// as game.Millis(clock.Now()).
package db

import (
	"context"
	_ "embed"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// schemaSQL is server/src/db/schema.sql, copied VERBATIM (diffed in CI by
// hand: `diff server/src/db/schema.sql go-server/internal/db/schema.sql`).
// Fully idempotent: IF NOT EXISTS / CREATE OR REPLACE / DO-block trigger, so
// it runs on every boot and on every test schema.
//
//go:embed schema.sql
var schemaSQL string

// SchemaSQL returns the embedded DDL (for tests and tooling).
func SchemaSQL() string { return schemaSQL }

// Options for Open.
type Options struct {
	URL     string // config.DB.URL
	Schema  string // config.DB.Schema; must match ^[A-Za-z_][A-Za-z0-9_]*$
	PoolMax int    // config.DB.PoolMax → pgxpool MaxConns
	Logger  *slog.Logger
}

// DB is the open pool plus the schema it was opened on.
type DB struct {
	Pool   *pgxpool.Pool
	Schema string
	log    *slog.Logger
}

// Open connects, creates the schema if missing and runs schema.sql
// (openDatabase). search_path is set as a CONNECTION PARAMETER —
// pgxpool.Config.ConnConfig.RuntimeParams["search_path"] = "<schema>,public"
// — never as a per-connection SET (Node learnt that races the pool; CLAUDE.md
// §12.2). Bootstrap: acquire one conn; `CREATE SCHEMA IF NOT EXISTS "<schema>"`
// (identifier quoted with pgx.Identifier); `SET search_path TO "<schema>",
// public` on that conn; Exec(schemaSQL) as one multi-statement batch (pgx
// simple protocol: Exec with no args runs the whole script). Logs
// `database ready {url: Redact(url), schema}`.
func Open(ctx context.Context, opts Options) (*DB, error) {
	panic("not ported: db.Open")
}

// Query runs a one-shot query on the pool (Node `query`).
func (d *DB) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	return d.Pool.Query(ctx, sql, args...)
}

// Exec runs a statement on the pool.
func (d *DB) Exec(ctx context.Context, sql string, args ...any) error {
	_, err := d.Pool.Exec(ctx, sql, args...)
	return err
}

// WithTx runs fn inside BEGIN … COMMIT, rolling back on error or panic
// (withTransaction). Everything that moves chips goes through here so a bet
// is either wholly in the database — wallet, pot, ledger, state — or not
// there at all. Default isolation (READ COMMITTED) with explicit row locks,
// as Node.
func (d *DB) WithTx(ctx context.Context, fn func(tx pgx.Tx) error) error {
	panic("not ported: (*DB).WithTx")
}

// DropSchema removes the schema and everything in it — test teardown only.
// Refuses "public" with an error, as Node does.
func (d *DB) DropSchema(ctx context.Context) error {
	panic("not ported: (*DB).DropSchema")
}

// Close closes the pool (closeDatabase). Idempotent.
func (d *DB) Close() {
	panic("not ported: (*DB).Close")
}

// PoolStats reports what /health `db` and the game_db_pool_* gauges show:
// Total = pgxpool Stat().TotalConns(), Idle = IdleConns(), Waiting = 0 — pgx
// has no live "waiting acquirers" figure (Node's pool.waitingCount); the
// closest is Stat().EmptyAcquireCount(), a cumulative counter, which is
// deliberately NOT reported as a gauge. Recorded in PORT_PLAN.md.
type PoolStats struct {
	Total   int `json:"total"`
	Idle    int `json:"idle"`
	Waiting int `json:"waiting"`
}

// Stats reads PoolStats from the pool.
func (d *DB) Stats() PoolStats {
	panic("not ported: (*DB).Stats")
}

// Redact strips the password from a connection string before it reaches a
// log: "postgres://u:p@h/db" → "postgres://u:***@h/db".
func Redact(url string) string {
	panic("not ported: db.Redact")
}

// now is the epoch-ms timestamp every write stamps (Node `Date.now()`).
func now(clock func() time.Time) int64 { return clock().UnixMilli() }
