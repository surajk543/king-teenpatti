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

// welcomeGrant is what a new account is given of one of the wallets without a
// ledger — db.RewardDiamond, db.RewardHammer or db.RewardMissile — read from
// the ACTIVE welcome_rewards rows of that type (V1.0.1__seed.sql's THE
// WELCOME; the chips are `welcome`, which this package's WELCOME_CHIPS sets).
// The tests of what a new account holds read it rather than repeat the seed's
// figures, which one test pins:
// TestTheSeedHoldsFiveLakhChipsTheDiamondsHammersAndMissile. It fails the test
// when the rows give none, since every caller's premise is a wallet with
// something in it.
func welcomeGrant(t *testing.T, d *db.DB, rewardType string) int64 {
	t.Helper()
	var n int64
	if err := d.Pool.QueryRow(context.Background(),
		`SELECT COALESCE(SUM(reward_value), 0)::bigint FROM welcome_rewards WHERE reward_type = $1 AND is_active`,
		rewardType).Scan(&n); err != nil {
		t.Fatalf("the welcome's %s: %v", rewardType, err)
	}
	if n <= 0 {
		t.Fatalf("the welcome gives no %s", rewardType)
	}
	return n
}

// welcomeGrant is the package helper on the fixture's schema.
func (f *fixture) welcomeGrant(rewardType string) int64 {
	f.t.Helper()
	return welcomeGrant(f.t, f.d, rewardType)
}

// fixture is one throwaway schema with a Users store and a Ledger on it.
type fixture struct {
	t        *testing.T
	ctx      context.Context
	d        *db.DB
	users    *db.Users
	pictures *db.Pictures
	// tables is the table-picture catalogue (owner, 15 Sep 2026).
	tables *db.TablePictures
	// cards is the card-back catalogue (owner, 3 Oct 2026).
	cards  *db.CardBackgrounds
	ledger *db.Ledger
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	d := dbtest.Open(t, "db")
	users := db.NewUsers(d, welcome, nil)
	return &fixture{
		t:        t,
		ctx:      context.Background(),
		d:        d,
		users:    users,
		pictures: db.NewPictures(d, users, nil),
		tables:   db.NewTablePictures(d, users, nil),
		cards:    db.NewCardBackgrounds(d, users, nil),
		ledger:   db.NewLedger(d, nil, nil),
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

// user creates a guest account with a fresh provider identity (Node's
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

// pack is the pack checkpoint for one player: delta chips, no counters.
func (f *fixture) pack(roomID, handID string, u *db.User, delta int64) (game.CheckpointResult, error) {
	f.t.Helper()
	return f.ledger.Checkpoint(f.ctx, game.CheckpointRequest{
		RoomID: roomID, HandID: handID,
		Entry: game.SettleEntry{
			UserID: u.ID, Delta: delta, Reason: game.LedgerReasonHandPacked,
			ActionID: game.PackedActionID(handID, u.ID),
		},
	})
}

// left is the leave/switch checkpoint: it resolves the player, so it is the
// entry their departure is counted from (hands_left, and hands_played when
// they had chaaled) — by the game, once it commits; the ledger writes money
// only (Player stats v2).
func (f *fixture) left(roomID, handID string, u *db.User, delta int64, didChaal bool) (game.CheckpointResult, error) {
	f.t.Helper()
	return f.ledger.Checkpoint(f.ctx, game.CheckpointRequest{
		RoomID: roomID, HandID: handID,
		Entry: leftEntry(handID, u.ID, delta, didChaal),
	})
}

// leftEntry builds one leave checkpoint's entry.
func leftEntry(handID, userID string, delta int64, didChaal bool) game.SettleEntry {
	return game.SettleEntry{
		UserID: userID, Delta: delta, Reason: game.LedgerReasonHandLeft,
		ActionID: game.LeftActionID(handID, userID),
		Outcome:  true, LeftMidHand: true, DidChaal: didChaal,
	}
}

// settleEntry builds one hand-end entry.
func settleEntry(handID, userID string, delta int64, isWinner, didChaal bool, pot int64) game.SettleEntry {
	reason := game.LedgerReasonHandLoss
	if isWinner {
		reason = game.LedgerReasonHandWin
	}
	e := game.SettleEntry{
		UserID: userID, Delta: delta, Reason: reason,
		ActionID: game.SettleActionID(handID, userID),
		Outcome:  true, IsWinner: isWinner, DidChaal: didChaal,
	}
	if isWinner {
		e.Pot = pot
	}
	return e
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
