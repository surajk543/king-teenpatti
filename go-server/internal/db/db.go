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
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
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

// schemaIdent is Node's `/^[A-Za-z_][A-Za-z0-9_]*$/` (index.js:35): a schema
// name is interpolated into DDL and into the search_path startup parameter,
// so only a plain identifier is ever accepted.
var schemaIdent = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

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
// §12.2). Bootstrap: acquire one conn; take
// pg_advisory_lock(hashtext('king-teenpatti:schema:<schema>')) so two
// processes (or two test binaries) bootstrapping the same schema at once
// serialise instead of racing CREATE SCHEMA / CREATE TABLE into a unique
// violation; `CREATE SCHEMA IF NOT EXISTS "<schema>"` (identifier quoted with
// pgx.Identifier); `SET search_path TO "<schema>", public` on that conn (the
// DO block's 'chip_ledger'::regclass resolves through it); Exec(schemaSQL) as
// one multi-statement batch (pgx simple protocol: Exec with no args runs the
// whole script — splitting on ';' would break the $$ bodies); unlock. Logs
// `database ready {url: Redact(url), schema}`.
func Open(ctx context.Context, opts Options) (*DB, error) {
	if !schemaIdent.MatchString(opts.Schema) {
		return nil, fmt.Errorf("PG_SCHEMA must be a plain identifier, got %q", opts.Schema)
	}
	log := opts.Logger
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}

	cfg, err := pgxpool.ParseConfig(opts.URL)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
	}
	if opts.PoolMax > 0 {
		cfg.MaxConns = int32(opts.PoolMax)
	}
	// Every connection the pool opens looks in this schema first, so the SQL
	// in the rest of this package can name tables without a prefix. A startup
	// parameter, not a query per connection, so it is in place before the
	// connection is ever handed out. Quoted so a mixed-case schema is not
	// case-folded away (Node interpolated it bare; see PORT_NOTES/db.md).
	if cfg.ConnConfig.RuntimeParams == nil {
		cfg.ConnConfig.RuntimeParams = map[string]string{}
	}
	quoted := pgx.Identifier{opts.Schema}.Sanitize()
	cfg.ConnConfig.RuntimeParams["search_path"] = quoted + ",public"

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}
	if err := bootstrap(ctx, pool, opts.Schema, quoted); err != nil {
		pool.Close()
		return nil, err
	}

	log.Info("database ready", "url", Redact(opts.URL), "schema", opts.Schema)
	return &DB{Pool: pool, Schema: opts.Schema, log: log}, nil
}

// bootstrap creates the schema and runs schema.sql on one connection under
// the advisory lock described in Open.
func bootstrap(ctx context.Context, pool *pgxpool.Pool, schema, quoted string) (err error) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer conn.Release()

	lockKey := "king-teenpatti:schema:" + schema
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock(hashtext($1))", lockKey); err != nil {
		return fmt.Errorf("schema lock: %w", err)
	}
	defer func() {
		// The lock is session-level: release it on the same connection. A
		// failure here would only matter if the connection survived, and a
		// connection that cannot run a statement is discarded by the pool.
		if _, unlockErr := conn.Exec(context.WithoutCancel(ctx), "SELECT pg_advisory_unlock(hashtext($1))", lockKey); unlockErr != nil && err == nil {
			err = fmt.Errorf("schema unlock: %w", unlockErr)
		}
	}()

	if _, err := conn.Exec(ctx, "CREATE SCHEMA IF NOT EXISTS "+quoted); err != nil {
		return fmt.Errorf("create schema: %w", err)
	}
	if _, err := conn.Exec(ctx, "SET search_path TO "+quoted+", public"); err != nil {
		return fmt.Errorf("set search_path: %w", err)
	}
	// No arguments → simple protocol → the whole file runs as one
	// multi-statement query, $$ bodies included.
	if _, err := conn.Exec(ctx, schemaSQL); err != nil {
		return fmt.Errorf("run schema.sql: %w", err)
	}
	return nil
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
// as Node. A failed COMMIT is rolled back and reported; a failed ROLLBACK is
// swallowed (the connection is probably gone and the pool discards it).
func (d *DB) WithTx(ctx context.Context, fn func(tx pgx.Tx) error) error {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	// Roll back with a context that survives the caller's cancellation so
	// the connection is left clean for the pool rather than torn down.
	rollback := func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }

	defer func() {
		if p := recover(); p != nil {
			rollback()
			panic(p)
		}
	}()

	if err := fn(tx); err != nil {
		rollback()
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		rollback()
		return err
	}
	return nil
}

// DropSchema removes the schema and everything in it — test teardown only.
// Refuses "public" with an error, as Node does.
func (d *DB) DropSchema(ctx context.Context) error {
	if d == nil || d.Pool == nil {
		return nil
	}
	if d.Schema == "public" {
		return errors.New("refusing to drop the public schema")
	}
	_, err := d.Pool.Exec(ctx, "DROP SCHEMA IF EXISTS "+pgx.Identifier{d.Schema}.Sanitize()+" CASCADE")
	return err
}

// Close closes the pool (closeDatabase). Idempotent.
func (d *DB) Close() {
	if d == nil || d.Pool == nil {
		return
	}
	d.Pool.Close()
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
	if d == nil || d.Pool == nil {
		return PoolStats{}
	}
	s := d.Pool.Stat()
	return PoolStats{Total: int(s.TotalConns()), Idle: int(s.IdleConns()), Waiting: 0}
}

// redactPattern is Node's `/\/\/([^:]+):[^@]+@/` (index.js:120) — the first
// user:password@ pair after a scheme separator.
var redactPattern = regexp.MustCompile(`//([^:]+):[^@]+@`)

// Redact strips the password from a connection string before it reaches a
// log: "postgres://u:p@h/db" → "postgres://u:***@h/db". Only the first match
// is replaced (Node's replace without the g flag).
func Redact(url string) string {
	m := redactPattern.FindStringSubmatchIndex(url)
	if m == nil {
		return url
	}
	return url[:m[0]] + "//" + url[m[2]:m[3]] + ":***@" + url[m[1]:]
}

// now is the epoch-ms timestamp every write stamps (Node `Date.now()`). A nil
// clock means time.Now.
func now(clock func() time.Time) int64 {
	if clock == nil {
		return time.Now().UnixMilli()
	}
	return clock().UnixMilli()
}

// nullIfEmpty maps Go's "" (the zero value standing in for Node's undefined /
// null) to a SQL NULL for the nullable TEXT columns hand_id and action_id.
func nullIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// isUniqueViolationOn reports whether err is a PostgreSQL unique_violation
// whose Detail or ConstraintName mentions needle (e.g. "action_id").
func isUniqueViolationOn(err error, needle string) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != UniqueViolation {
		return false
	}
	return containsAny(needle, pgErr.Detail, pgErr.ConstraintName)
}
