package db_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// welcome is the welcome grant every fixture account starts with
// (requirement 5; config default WELCOME_CHIPS=200000).
const welcome int64 = 200000

// fixture is one throwaway schema with a Users store and a Ledger on it.
type fixture struct {
	t      *testing.T
	ctx    context.Context
	d      *db.DB
	users  *db.Users
	ledger *db.Ledger
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	d := dbtest.Open(t, "db")
	return &fixture{
		t:      t,
		ctx:    context.Background(),
		d:      d,
		users:  db.NewUsers(d, welcome, nil),
		ledger: db.NewLedger(d, nil, nil),
	}
}

// testURL mirrors dbtest.Open's URL resolution for tests that open extra
// pools of their own.
func testURL() string {
	if u := os.Getenv("TEST_DATABASE_URL"); u != "" {
		return u
	}
	if u := os.Getenv("DATABASE_URL"); u != "" {
		return u
	}
	return config.Defaults().DB.URL
}

func randomSuffix(t *testing.T) string {
	t.Helper()
	var raw [4]byte
	if _, err := rand.Read(raw[:]); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(raw[:])
}

// user creates a guest account with a fresh provider identity (the
// statsAndRewards makeUser helper).
func (f *fixture) user(name string) *db.User {
	f.t.Helper()
	u, isNew, err := f.users.UpsertFromProfile(f.ctx, db.Profile{
		Provider:       db.ProviderGuest,
		ProviderUserID: "stats-" + name + "-" + randomSuffix(f.t),
		DisplayName:    name,
	})
	if err != nil {
		f.t.Fatalf("make user %s: %v", name, err)
	}
	if !isNew {
		f.t.Fatalf("make user %s: expected a new account", name)
	}
	return u
}

// find is FindByID that fails the test on a missing account.
func (f *fixture) find(id string) *db.User {
	f.t.Helper()
	u, err := f.users.FindByID(f.ctx, id)
	if err != nil {
		f.t.Fatalf("find %s: %v", id, err)
	}
	if u == nil {
		f.t.Fatalf("find %s: no such user", id)
	}
	return u
}

// scalar runs a query expected to return one int64.
func (f *fixture) scalar(sql string, args ...any) int64 {
	f.t.Helper()
	var n int64
	if err := f.d.Pool.QueryRow(f.ctx, sql, args...).Scan(&n); err != nil {
		f.t.Fatalf("scalar %q: %v", sql, err)
	}
	return n
}

// chips reads users.chips straight from the row.
func (f *fixture) chips(userID string) int64 {
	f.t.Helper()
	return f.scalar(`SELECT chips FROM users WHERE id = $1`, userID)
}

// ledgerSum is SUM(chip_ledger.delta) for one user (NUMERIC cast to bigint).
func (f *fixture) ledgerSum(userID string) int64 {
	f.t.Helper()
	return f.scalar(`SELECT COALESCE(SUM(delta), 0)::bigint FROM chip_ledger WHERE user_id = $1`, userID)
}

// count is COUNT(*) for an arbitrary predicate.
func (f *fixture) count(sql string, args ...any) int64 {
	f.t.Helper()
	return f.scalar(sql, args...)
}

// reconcile asserts the invariant every money path must keep: for every
// user, SUM(chip_ledger.delta) == users.chips (CLAUDE.md §4 psql check).
func (f *fixture) reconcile() {
	f.t.Helper()
	n := f.scalar(`SELECT COUNT(*) FROM users u
	  JOIN (SELECT user_id, SUM(delta) s FROM chip_ledger GROUP BY user_id) l ON l.user_id = u.id
	 WHERE l.s <> u.chips`)
	if n != 0 {
		f.t.Fatalf("%d wallet(s) disagree with their ledger", n)
	}
	// And no wallet without any ledger row at all.
	orphans := f.scalar(`SELECT COUNT(*) FROM users u WHERE NOT EXISTS (SELECT 1 FROM chip_ledger l WHERE l.user_id = u.id)`)
	if orphans != 0 {
		f.t.Fatalf("%d wallet(s) have no ledger rows", orphans)
	}
}

// ledgerRow is one chip_ledger row as the tests read it back.
type ledgerRow struct {
	UserID   string
	HandID   *string
	ActionID *string
	Delta    int64
	Balance  int64
	Reason   string
	Created  int64
}

// ledgerRows returns a user's ledger rows in insertion (id) order, optionally
// restricted to a hand.
func (f *fixture) ledgerRows(userID string) []ledgerRow {
	f.t.Helper()
	rows, err := f.d.Pool.Query(f.ctx, `SELECT user_id, hand_id, action_id, delta, balance, reason, created_at
	   FROM chip_ledger WHERE user_id = $1 ORDER BY id`, userID)
	if err != nil {
		f.t.Fatal(err)
	}
	defer rows.Close()
	var out []ledgerRow
	for rows.Next() {
		var r ledgerRow
		if err := rows.Scan(&r.UserID, &r.HandID, &r.ActionID, &r.Delta, &r.Balance, &r.Reason, &r.Created); err != nil {
			f.t.Fatal(err)
		}
		out = append(out, r)
	}
	return out
}

// handLedgerRows returns every ledger row of one hand in insertion order.
func (f *fixture) handLedgerRows(handID string) []ledgerRow {
	f.t.Helper()
	rows, err := f.d.Pool.Query(f.ctx, `SELECT user_id, hand_id, action_id, delta, balance, reason, created_at
	   FROM chip_ledger WHERE hand_id = $1 ORDER BY id`, handID)
	if err != nil {
		f.t.Fatal(err)
	}
	defer rows.Close()
	var out []ledgerRow
	for rows.Next() {
		var r ledgerRow
		if err := rows.Scan(&r.UserID, &r.HandID, &r.ActionID, &r.Delta, &r.Balance, &r.Reason, &r.Created); err != nil {
			f.t.Fatal(err)
		}
		out = append(out, r)
	}
	return out
}

// boot collects the boot from every given user for a new hand.
func (f *fixture) boot(roomID, handID string, bootAmount int64, users ...*db.User) game.CollectBootResult {
	f.t.Helper()
	entries := make([]game.BootEntry, 0, len(users))
	for _, u := range users {
		entries = append(entries, game.BootEntry{UserID: u.ID, Amount: bootAmount, BalanceBefore: u.Chips})
	}
	res, err := f.ledger.CollectBoot(f.ctx, game.CollectBootRequest{
		RoomID: roomID, HandID: handID, BootAmount: bootAmount, Entries: entries,
	})
	if err != nil {
		f.t.Fatalf("collectBoot: %v", err)
	}
	return res
}

// codeOf extracts the GameError code, failing the test when err is not one.
func codeOf(t *testing.T, err error) string {
	t.Helper()
	if err == nil {
		t.Fatal("expected an error")
	}
	code := game.CodeOf(err, "")
	if code == "" {
		t.Fatalf("expected a GameError, got %T: %v", err, err)
	}
	return code
}

func ptr(s string) *string { return &s }

// approxNow is a clock-based tolerance for timestamp assertions (ms).
func withinMs(a, b, tolerance int64) bool {
	d := a - b
	if d < 0 {
		d = -d
	}
	return d <= tolerance
}

func nowMs() int64 { return time.Now().UnixMilli() }
