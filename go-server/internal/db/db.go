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
	"embed"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// migrationFS holds the versioned DDL, named the Flyway way:
// V<version>__<description>.sql, applied in ascending version order.
//
// There is no schema history table. Flyway would keep one and skip what it has
// already applied; this server instead applies EVERY script on EVERY boot and
// on every test schema, which works only because every script is idempotent —
// IF NOT EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING, and a catalogue
// lookup in front of anything lacking its own guard. A script that is not
// idempotent will not fail the first time; it will fail the second, on a
// restart, in production.
//
//go:embed migration/*.sql
var migrationFS embed.FS

// Migration is one versioned DDL script.
type Migration struct {
	Version string // "1.0.0"
	Name    string // "baseline"
	File    string // "V1.0.0__baseline.sql"
	SQL     string
}

// migrationPattern is Flyway's: V, a dotted version, two underscores, a
// description. Anything else in the directory is not a migration and is
// ignored rather than guessed at.
var migrationPattern = regexp.MustCompile(`^V(\d+(?:\.\d+)*)__(.+)\.sql$`)

// Migrations returns every embedded script in ascending version order.
// It panics on a malformed name or a duplicate version: both are build-time
// mistakes in a directory this package owns, and neither should be discovered
// by a server that is already serving.
func Migrations() []Migration {
	entries, err := migrationFS.ReadDir("migration")
	if err != nil {
		panic("db: reading embedded migrations: " + err.Error())
	}
	out := make([]Migration, 0, len(entries))
	seen := map[string]string{}
	for _, entry := range entries {
		match := migrationPattern.FindStringSubmatch(entry.Name())
		if match == nil {
			panic("db: migration/" + entry.Name() + " is not named V<version>__<description>.sql")
		}
		if first, dup := seen[match[1]]; dup {
			panic("db: migration version " + match[1] + " is claimed by both " + first + " and " + entry.Name())
		}
		seen[match[1]] = entry.Name()
		body, err := migrationFS.ReadFile("migration/" + entry.Name())
		if err != nil {
			panic("db: reading migration/" + entry.Name() + ": " + err.Error())
		}
		out = append(out, Migration{Version: match[1], Name: match[2], File: entry.Name(), SQL: string(body)})
	}
	sort.Slice(out, func(i, j int) bool { return lessVersion(out[i].Version, out[j].Version) })
	return out
}

// lessVersion orders dotted versions numerically, so 1.0.10 follows 1.0.9
// rather than preceding it as a string sort would have it.
func lessVersion(a, b string) bool {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(as) || i < len(bs); i++ {
		var x, y int
		if i < len(as) {
			x, _ = strconv.Atoi(as[i])
		}
		if i < len(bs) {
			y, _ = strconv.Atoi(bs[i])
		}
		if x != y {
			return x < y
		}
	}
	return false
}

// SchemaSQL returns every migration concatenated in order (tests and tooling).
func SchemaSQL() string {
	var b strings.Builder
	for _, m := range Migrations() {
		b.WriteString(m.SQL)
		b.WriteString("\n")
	}
	return b.String()
}

// schemaIdent is Node's `/^[A-Za-z_][A-Za-z0-9_]*$/` (index.js:35): a schema
// name is interpolated into DDL and into the search_path startup parameter,
// so only a plain identifier is ever accepted.
var schemaIdent = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// Options for Open.
type Options struct {
	URL     string // config.DB.URL
	Schema  string // config.DB.Schema; must match ^[A-Za-z_][A-Za-z0-9_]*$
	PoolMax int    // config.DB.PoolMax → pgxpool MaxConns
	// StatementTimeout bounds every statement on every pooled connection
	// (Postgres statement_timeout). A hung query would otherwise block a
	// table's actor forever, since ledger calls run on it with the table's
	// own context. Zero keeps Postgres' default (no limit), as Node had.
	StatementTimeout time.Duration
	Logger           *slog.Logger
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
	if opts.StatementTimeout > 0 {
		cfg.ConnConfig.RuntimeParams["statement_timeout"] = strconv.FormatInt(opts.StatementTimeout.Milliseconds(), 10)
	}

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
	// Fail fast, and say why, when DDL cannot get its lock.
	//
	// schema.sql runs on EVERY boot, and some of it needs locks that queue
	// behind ordinary readers. Without this the wait is bounded only by
	// PG_STATEMENT_TIMEOUT_MS, so a single long report turns a restart into a
	// crash loop whose only symptom is "canceling statement due to statement
	// timeout" — true, and useless. Three seconds is far longer than any lock
	// this file legitimately waits for, and lock_timeout raises 55P03, which
	// is specific enough to explain itself below.
	if _, err := conn.Exec(ctx, "SET lock_timeout = '3s'"); err != nil {
		return fmt.Errorf("set lock_timeout: %w", err)
	}
	// One Exec per script, in version order. No arguments → simple protocol →
	// each file runs as one multi-statement query, $$ bodies included.
	for _, migration := range Migrations() {
		if _, err := conn.Exec(ctx, migration.SQL); err != nil {
			return fmt.Errorf("run %s: %w%s", migration.File, err, blockingActivity(ctx, conn, err))
		}
	}
	return nil
}

// blockingActivity names what is holding the lock schema.sql could not take,
// as a suffix for the startup error. Best effort: it runs after a failure, on
// a connection that has just had one, so anything it hits is swallowed — a
// diagnostic that fails must not replace the diagnosis.
//
// It exists because the answer to "why will the server not start" was once a
// fifteen-minute hunt through pg_stat_activity, and it is the first thing
// anyone would have asked for.
func blockingActivity(ctx context.Context, conn *pgxpool.Conn, cause error) string {
	// 55P03 lock_not_available (lock_timeout) and 57014 query_canceled
	// (statement_timeout) are the two failures a lock holder explains. Any
	// other error is about the SQL itself and a list of readers would mislead.
	var pgErr *pgconn.PgError
	if !errors.As(cause, &pgErr) || (pgErr.Code != "55P03" && pgErr.Code != "57014") {
		return ""
	}
	rows, err := conn.Query(context.WithoutCancel(ctx), `
		SELECT pid, state, EXTRACT(epoch FROM now() - query_start)::bigint,
		       left(regexp_replace(query, E'\s+', ' ', 'g'), 120)
		  FROM pg_stat_activity
		 WHERE datname = current_database()
		   AND pid <> pg_backend_pid()
		   AND query_start < now() - interval '3 seconds'
		 ORDER BY query_start
		 LIMIT 3`)
	if err != nil {
		return ""
	}
	defer rows.Close()
	var b strings.Builder
	for rows.Next() {
		var pid int
		var state, query string
		var age int64
		if err := rows.Scan(&pid, &state, &age, &query); err != nil {
			return ""
		}
		fmt.Fprintf(&b, "\n  possibly blocking: pid=%d state=%s age=%ds query=%q", pid, state, age, query)
	}
	return b.String()
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
