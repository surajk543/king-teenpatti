package db_test

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Missiles (owner, 14 Sep 2026): users.missile, spent one per missile fired
// under a key that names the hand, the player and the client's actionId, and
// filled from users.diamond at 2 missiles a diamond under a key that names the
// player and the client's requestId. Neither ever touches chips or chip_ledger.

// missilesOf and diamondsOf read the wallet straight from the row.
func (f *fixture) missilesOf(userID string) int64 {
	f.t.Helper()
	return f.scalar(`SELECT missile FROM users WHERE id = $1`, userID)
}

func (f *fixture) diamondsOf(userID string) int64 {
	f.t.Helper()
	return f.scalar(`SELECT diamond FROM users WHERE id = $1`, userID)
}

func (f *fixture) missileStore() *db.Missiles {
	return db.NewMissiles(f.d, f.users, nil, nil)
}

// A missile is taken once per key and never below zero: a retry of a committed
// spend charges nothing (even when that spend took the last missile), an empty
// wallet is refused no_missiles with nothing recorded, the same client id in
// another hand or from another player is a spend of its own, and chips and
// chip_ledger never move.
func TestAMissileSpendIsChargedOncePerActionIdAndNeverGoesBelowZero(t *testing.T) {
	f := newFixture(t)
	u, other := f.user("firer"), f.user("other-firer")
	wallet := f.missileStore()
	startRows := len(f.ledgerRows(u.ID))
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE users SET missile = 2 WHERE id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}
	spend := func(user *db.User, hand, key string) (game.MissileSpendResult, error) {
		return wallet.SpendMissile(f.ctx, game.MissileSpend{
			RoomID: "room-m", HandID: hand, UserID: user.ID,
			ActionID: game.MissileSpendID(hand, user.ID, key),
		})
	}
	rows := func(user *db.User) int64 {
		return f.count(`SELECT count(*) FROM missile_spends WHERE user_id = $1`, user.ID)
	}

	first, err := spend(u, "hand-1", "a")
	if err != nil || !first.Charged || first.Remaining != 1 || f.missilesOf(u.ID) != 1 || rows(u) != 1 {
		t.Fatalf("first spend: %+v %v, missiles %d, rows %d", first, err, f.missilesOf(u.ID), rows(u))
	}
	if n := f.count(`SELECT count(*) FROM missile_spends WHERE user_id = $1 AND hand_id = 'hand-1'`, u.ID); n != 1 {
		t.Fatalf("the spend records its hand: %d rows", n)
	}
	again, err := spend(u, "hand-1", "a")
	if err != nil || again.Charged || again.Remaining != 1 || f.missilesOf(u.ID) != 1 || rows(u) != 1 {
		t.Fatalf("a retried key was charged again: %+v %v, missiles %d", again, err, f.missilesOf(u.ID))
	}

	// The same client id in the next hand is a new missile …
	last, err := spend(u, "hand-2", "a")
	if err != nil || !last.Charged || last.Remaining != 0 {
		t.Fatalf("the same id in the next hand: %+v %v", last, err)
	}
	// … an empty wallet is refused and records nothing …
	if _, err := spend(u, "hand-3", "a"); game.CodeOf(err, "") != game.CodeNoMissiles {
		t.Fatalf("an empty wallet: %v, want no_missiles", err)
	}
	if f.missilesOf(u.ID) != 0 || rows(u) != 2 {
		t.Fatalf("a refused spend left missiles %d and %d rows", f.missilesOf(u.ID), rows(u))
	}
	// … the retry of the spend that took the last missile is paid for already …
	if retried, err := spend(u, "hand-2", "a"); err != nil || retried.Charged || retried.Remaining != 0 {
		t.Fatalf("retry of a paid key at zero: %+v %v", retried, err)
	}
	// … and another player's identical id is their own missile.
	theirs, err := spend(other, "hand-1", "a")
	if err != nil || !theirs.Charged || theirs.Remaining != 0 || f.missilesOf(other.ID) != 0 {
		t.Fatalf("another player's spend with the same id: %+v %v", theirs, err)
	}

	// The CHECK is the last line.
	_, err = f.d.Pool.Exec(f.ctx, `UPDATE users SET missile = missile - 1 WHERE id = $1`, u.ID)
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
		t.Fatalf("users.missile below zero must violate its CHECK, got %v", err)
	}
	if _, err := wallet.SpendMissile(f.ctx, game.MissileSpend{HandID: "h", UserID: "no-such-user", ActionID: "k"}); game.CodeOf(err, "") != game.CodeUnknownUser {
		t.Fatalf("an unknown account: %v", err)
	}
	if f.chips(u.ID) != welcome || len(f.ledgerRows(u.ID)) != startRows {
		t.Fatalf("missiles moved chips (%d) or wrote %d chip_ledger rows", f.chips(u.ID), len(f.ledgerRows(u.ID))-startRows)
	}
	f.reconcile()
}

// Spends from one wallet racing each other queue on the wallet lock: exactly as
// many succeed as there were missiles.
func TestConcurrentMissileSpendsNeverTakeMoreThanTheWalletHolds(t *testing.T) {
	f := newFixture(t)
	u := f.user("missile-racer")
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE users SET missile = 3 WHERE id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}
	wallet := f.missileStore()
	const attempts = 12
	var wg sync.WaitGroup
	var mu sync.Mutex
	ok, refused := 0, 0
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := wallet.SpendMissile(context.Background(), game.MissileSpend{
				HandID: "race", UserID: u.ID, ActionID: game.MissileSpendID("race", u.ID, fmt.Sprint(i)),
			})
			mu.Lock()
			defer mu.Unlock()
			switch {
			case err == nil:
				ok++
			case game.CodeOf(err, "") == game.CodeNoMissiles:
				refused++
			default:
				t.Errorf("spend %d: %v", i, err)
			}
		}(i)
	}
	wg.Wait()
	if ok != 3 || refused != attempts-3 || f.missilesOf(u.ID) != 0 {
		t.Fatalf("%d went through, %d refused, %d left; want 3, %d, 0", ok, refused, f.missilesOf(u.ID), attempts-3)
	}
}

// A trade takes the pack's diamonds and gives its missiles exactly once per
// requestId: a replay — the same pack or another — moves nothing and answers
// the wallet as it stands, the trade is recorded under the player's own key so
// another player's identical requestId is their own trade, and the chips and
// chip_ledger never move.
func TestAMissileTradeDebitsDiamondsAndCreditsMissilesExactlyOncePerRequestId(t *testing.T) {
	f := newFixture(t)
	u, other := f.user("trader"), f.user("other-trader")
	store := f.missileStore()
	startRows := len(f.ledgerRows(u.ID))
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE users SET diamond = 12 WHERE id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}

	first, err := store.TradeMissiles(f.ctx, u.ID, "missiles_10", "req-1")
	if err != nil {
		t.Fatal(err)
	}
	if !first.Charged || first.Diamonds != 5 || first.Missiles != 10 || first.User == nil || first.User.Diamond != 7 || first.User.Missile != 11 {
		t.Fatalf("first trade: %+v (user %+v)", first, first.User)
	}
	if f.diamondsOf(u.ID) != 7 || f.missilesOf(u.ID) != 11 {
		t.Fatalf("wallet after the trade: %d diamonds, %d missiles", f.diamondsOf(u.ID), f.missilesOf(u.ID))
	}
	if n := f.count(`SELECT count(*) FROM missile_purchases WHERE request_id = $1 AND user_id = $2 AND diamonds = 5 AND missiles = 10`,
		db.MissileTradeID(u.ID, "req-1"), u.ID); n != 1 {
		t.Fatalf("missile_purchases rows %d", n)
	}

	for _, pack := range []string{"missiles_10", "missiles_2"} {
		replay, err := store.TradeMissiles(f.ctx, u.ID, pack, "req-1")
		if err != nil || replay.Charged || replay.Diamonds != 0 || replay.Missiles != 0 || replay.User.Diamond != 7 || replay.User.Missile != 11 {
			t.Fatalf("a replay (%s) moved something: %+v %v", pack, replay, err)
		}
	}
	if f.diamondsOf(u.ID) != 7 || f.missilesOf(u.ID) != 11 || f.count(`SELECT count(*) FROM missile_purchases WHERE user_id = $1`, u.ID) != 1 {
		t.Fatal("a replay moved the wallet or recorded a second trade")
	}

	// Every pack is exactly 1 diamond = 2 missiles.
	for id, pack := range db.MissilePacks {
		if pack.ID != id || pack.Missiles != pack.Diamonds*db.MissilesPerDiamond {
			t.Fatalf("pack %s = %+v", id, pack)
		}
	}
	if len(db.MissilePacks) != 4 {
		t.Fatalf("%d packs, want 4", len(db.MissilePacks))
	}

	theirs, err := store.TradeMissiles(f.ctx, other.ID, "missiles_2", "req-1")
	if err != nil || !theirs.Charged || theirs.User.Diamond != 1 || theirs.User.Missile != 3 {
		t.Fatalf("another player's requestId is their own trade: %+v %v", theirs, err)
	}

	// The same requestId sent at once from several requests trades once.
	var wg sync.WaitGroup
	var mu sync.Mutex
	charged := 0
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			got, err := store.TradeMissiles(context.Background(), u.ID, "missiles_2", "req-race")
			if err != nil {
				t.Errorf("racing trade: %v", err)
				return
			}
			mu.Lock()
			defer mu.Unlock()
			if got.Charged {
				charged++
			}
		}()
	}
	wg.Wait()
	if charged != 1 || f.diamondsOf(u.ID) != 6 || f.missilesOf(u.ID) != 13 {
		t.Fatalf("%d racing trades charged; wallet %d diamonds, %d missiles", charged, f.diamondsOf(u.ID), f.missilesOf(u.ID))
	}

	if f.chips(u.ID) != welcome || len(f.ledgerRows(u.ID)) != startRows {
		t.Fatal("a missile trade moved chips or chip_ledger")
	}
	f.reconcile()
}

// A wallet short of the pack's diamonds is refused with nothing taken and
// nothing recorded, so the very same request goes through once the diamonds are
// there. An unknown pack or an empty requestId is refused before any work.
func TestAShortDiamondWalletIsRefusedAndRecordsNoTrade(t *testing.T) {
	f := newFixture(t)
	u := f.user("short-trader")
	store := f.missileStore()

	if _, err := store.TradeMissiles(f.ctx, u.ID, "missiles_20", "short-1"); !errors.Is(err, db.ErrNotEnoughDiamonds) {
		t.Fatalf("10 diamonds from a wallet of 2: %v, want ErrNotEnoughDiamonds", err)
	}
	if f.diamondsOf(u.ID) != 2 || f.missilesOf(u.ID) != 1 || f.count(`SELECT count(*) FROM missile_purchases WHERE user_id = $1`, u.ID) != 0 {
		t.Fatal("a refused trade moved the wallet or recorded a trade")
	}

	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE users SET diamond = 10 WHERE id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}
	done, err := store.TradeMissiles(f.ctx, u.ID, "missiles_20", "short-1")
	if err != nil || !done.Charged || f.diamondsOf(u.ID) != 0 || f.missilesOf(u.ID) != 21 {
		t.Fatalf("the same request with the diamonds there: %+v %v", done, err)
	}

	if _, err := store.TradeMissiles(f.ctx, u.ID, "missiles_3", "x"); !errors.Is(err, db.ErrMissilePackUnknown) {
		t.Fatalf("unknown pack: %v", err)
	}
	if _, err := store.TradeMissiles(f.ctx, u.ID, "missiles_2", ""); !errors.Is(err, db.ErrMissileRequestID) {
		t.Fatalf("empty requestId: %v", err)
	}
	if _, err := store.TradeMissiles(f.ctx, "no-such-user", "missiles_2", "x"); game.CodeOf(err, "") != game.CodeUnknownUser {
		t.Fatalf("unknown account: %v", err)
	}
}

// A new account holds 2 diamonds and 1 missile, and booting again adds no
// second CHECK and changes neither default.
func TestANewAccountHoldsTwoDiamondsAndOneMissile(t *testing.T) {
	f := newFixture(t)
	u := f.user("missile-fresh")
	if u.Diamond != 2 || u.Missile != 1 || f.diamondsOf(u.ID) != 2 || f.missilesOf(u.ID) != 1 {
		t.Fatalf("a new account holds %d diamonds and %d missiles (wire %d, %d), want 2 and 1",
			f.diamondsOf(u.ID), f.missilesOf(u.ID), u.Diamond, u.Missile)
	}
	again, err := db.Open(f.ctx, db.Options{URL: testURL(), Schema: f.d.Schema, PoolMax: 2})
	if err != nil {
		t.Fatalf("second boot: %v", err)
	}
	again.Close()
	checks := f.scalar(`SELECT count(*) FROM pg_constraint
		WHERE conrelid = 'users'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%missile%'`)
	if checks != 1 {
		t.Fatalf("%d CHECKs on users.missile after two boots, want 1", checks)
	}
	if later := f.user("missile-later"); later.Diamond != 2 || later.Missile != 1 {
		t.Fatalf("after a second boot a new account holds %d diamonds and %d missiles", later.Diamond, later.Missile)
	}
}

// V1.0.2 on a database V1.0.0 and V1.0.1 built — production's, the day it
// shipped: every account that already exists gets 0 missiles and keeps its
// diamonds, and only accounts created afterwards start with 2 diamonds and
// 1 missile. A boot after that is a no-op.
func TestAnAccountFromBeforeV102GetsNoMissilesAndKeepsItsDiamonds(t *testing.T) {
	_ = dbtest.Open(t, "db") // skips when Postgres is unreachable
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	migrations := db.Migrations()
	if len(migrations) < 3 || !strings.HasPrefix(migrations[2].File, "V1.0.2__") {
		t.Fatalf("expected V1.0.2 third, got %d scripts", len(migrations))
	}
	schema := "test_db_v102_" + randomSuffix(t)
	conn, err := pgx.Connect(ctx, testURL())
	if err != nil {
		t.Skipf("connect: %v", err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	ident := pgx.Identifier{schema}.Sanitize()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		c, err := pgx.Connect(ctx, testURL())
		if err != nil {
			t.Errorf("cleanup connect: %v", err)
			return
		}
		defer func() { _ = c.Close(ctx) }()
		if _, err := c.Exec(ctx, `DROP SCHEMA IF EXISTS `+ident+` CASCADE`); err != nil {
			t.Errorf("drop schema %s: %v", schema, err)
		}
	})

	// The database production had before this release: V1.0.0 and V1.0.1 only.
	for _, stmt := range []string{`CREATE SCHEMA ` + ident, `SET search_path TO ` + ident + `, public`, migrations[0].SQL, migrations[1].SQL} {
		if _, err := conn.Exec(ctx, stmt); err != nil {
			t.Fatalf("building the pre-V1.0.2 database: %v", err)
		}
	}
	var hasMissile bool
	if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM information_schema.columns
		WHERE table_schema = $1 AND table_name = 'users' AND column_name = 'missile')`, schema).Scan(&hasMissile); err != nil {
		t.Fatal(err)
	}
	if hasMissile {
		t.Fatal("V1.0.0 already declares users.missile; this test builds the wrong database")
	}
	const oldID = "pre-v102-account"
	if _, err := conn.Exec(ctx, `INSERT INTO users (id, provider, provider_user_id, display_name, chips, created_at, updated_at, last_login_at)
		VALUES ($1, 'guest', $1, 'Old Timer', 1000, 1, 1, 1)`, oldID); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `UPDATE users SET diamond = 7 WHERE id = $1`, oldID); err != nil {
		t.Fatal(err)
	}

	// The boot that ships V1.0.2, and one after it.
	for boot := 1; boot <= 2; boot++ {
		d, err := db.Open(ctx, db.Options{URL: testURL(), Schema: schema, PoolMax: 2})
		if err != nil {
			t.Fatalf("boot %d with V1.0.2: %v", boot, err)
		}
		users := db.NewUsers(d, welcome, nil)
		old, err := users.FindByID(ctx, oldID)
		if err != nil || old == nil {
			d.Close()
			t.Fatalf("boot %d: the old account: %+v %v", boot, old, err)
		}
		if old.Missile != 0 || old.Diamond != 7 {
			d.Close()
			t.Fatalf("boot %d: the old account holds %d missiles and %d diamonds, want 0 and 7", boot, old.Missile, old.Diamond)
		}
		fresh, _, err := users.UpsertFromProfile(ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: fmt.Sprintf("post-v102-%d", boot), DisplayName: "New"})
		if err != nil || fresh.Diamond != 2 || fresh.Missile != 1 {
			d.Close()
			t.Fatalf("boot %d: a new account %+v %v, want 2 diamonds and 1 missile", boot, fresh, err)
		}
		var missileDefault, diamondDefault string
		if err := d.Pool.QueryRow(ctx, `SELECT
			(SELECT column_default FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'users' AND column_name = 'missile'),
			(SELECT column_default FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'users' AND column_name = 'diamond')`,
			schema).Scan(&missileDefault, &diamondDefault); err != nil {
			d.Close()
			t.Fatal(err)
		}
		d.Close()
		if missileDefault != "1" || diamondDefault != "2" {
			t.Fatalf("boot %d: defaults missile=%s diamond=%s, want 1 and 2", boot, missileDefault, diamondDefault)
		}
	}
}
