package db_test

import (
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// takeOffPlay takes a seeded badge off Play, as an owner's UPDATE setting its
// product to NULL would: its store key goes back to asking support.
func (f *fixture) takeOffPlay(code string) {
	f.t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE badges SET play_product_id = NULL WHERE code = $1`, code); err != nil {
		f.t.Fatal(err)
	}
}

// Every Royal badge is sold under the Play product the owner created for it
// (27 Sep 2026), and only while it is active and keeps that product; nothing
// else — Regular, a badge's code, a pack's product, a near miss — sells a badge.
func TestAStoreBadgeIsFoundByItsPlayProduct(t *testing.T) {
	f := newFixture(t)
	for _, id := range []string{"", "REGULAR", "ROYAL_KING", "chips_a_99", "badge_royal_king", "BADGE_ROYAL_KING_999"} {
		if b, ok, err := db.BadgeForProduct(f.ctx, f.d, id); err != nil || ok {
			t.Errorf("%q sells %+v (%v)", id, b, err)
		}
	}
	king, ok, err := db.BadgeForProduct(f.ctx, f.d, "badge_royal_king_999")
	if err != nil || !ok || king.Code != "ROYAL_KING" || king.ValidityDays != 15 || king.PriceInr == nil || *king.PriceInr != 1000 ||
		king.ProductID != "badge_royal_king_999" || king.Title != "Royal King" {
		t.Fatalf("the king: %+v %v %v", king, ok, err)
	}
	ace, ok, err := db.BadgeForProduct(f.ctx, f.d, "badge_royal_ace_499")
	if err != nil || !ok || ace.Code != "ROYAL_ACE" || ace.ValidityDays != 7 || *ace.PriceInr != 500 {
		t.Fatalf("the ace: %+v %v %v", ace, ok, err)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE badges SET is_active = FALSE WHERE code = 'ROYAL_ACE'`); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := db.BadgeForProduct(f.ctx, f.d, "badge_royal_ace_499"); ok {
		t.Error("a retired badge is not for sale")
	}
	f.takeOffPlay("ROYAL_KING")
	if _, ok, _ := db.BadgeForProduct(f.ctx, f.d, "badge_royal_king_999"); ok {
		t.Error("a badge taken off Play is sold by nothing")
	}
}

// A purchase grants the badge once per receipt, in its validity — and its
// rate, 0%, is what the player pays at once; a replayed receipt grants
// nothing and reports the grant the first left; a second purchase while one
// runs adds its days on; one after the grant has lapsed starts again from
// now. Every purchase is a badge_purchases row with the price it was bought
// at, and chip_ledger never hears of any of it.
func TestABadgeBoughtInTheStoreIsGrantedOncePerReceiptAndExtendsARunningGrant(t *testing.T) {
	f := newFixture(t)
	u := f.user("buyer")
	// Royal King, 15 days at ₹1,000, sold on Play as seeded.
	king, _, err := db.BadgeForProduct(f.ctx, f.d, "badge_royal_king_999")
	if err != nil {
		t.Fatal(err)
	}
	const day = int64(24 * time.Hour / time.Millisecond)
	now := time.Now().UnixMilli()
	ledgerBefore := len(f.ledgerRows(u.ID))

	first, err := db.CreditBadgePurchase(f.ctx, f.d, f.users, u.ID, king, "king-receipt-1", now)
	if err != nil || !first.Credited || first.Badge != "ROYAL_KING" || first.ExpiresAt != now+15*day {
		t.Fatalf("the first purchase: %+v %v", first, err)
	}
	if first.User == nil || first.User.TaxBps != 0 || !holds(first.User, "ROYAL_KING", now+15*day) {
		t.Fatalf("the account after it holds the badge at 0%%: %+v", first.User)
	}

	replay, err := db.CreditBadgePurchase(f.ctx, f.d, f.users, u.ID, king, "king-receipt-1", now+day)
	if err != nil || replay.Credited || replay.ExpiresAt != now+15*day {
		t.Fatalf("a replayed receipt: %+v %v", replay, err)
	}
	if got := f.scalar(`SELECT expires_at FROM user_badges WHERE user_id = $1 AND badge_code = 'ROYAL_KING'`, u.ID); got != now+15*day {
		t.Fatalf("a replay moved the grant to %d", got)
	}

	second, err := db.CreditBadgePurchase(f.ctx, f.d, f.users, u.ID, king, "king-receipt-2", now+day)
	if err != nil || !second.Credited || second.ExpiresAt != now+30*day {
		t.Fatalf("a second purchase while the first runs: %+v %v, want its days added on", second, err)
	}

	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE user_badges SET expires_at = $2 WHERE user_id = $1`, u.ID, now-day); err != nil {
		t.Fatal(err)
	}
	third, err := db.CreditBadgePurchase(f.ctx, f.d, f.users, u.ID, king, "king-receipt-3", now)
	if err != nil || !third.Credited || third.ExpiresAt != now+15*day {
		t.Fatalf("a purchase after the grant lapsed: %+v %v, want fifteen days from now", third, err)
	}

	if n := f.count(`SELECT count(*) FROM badge_purchases WHERE user_id = $1 AND badge_code = 'ROYAL_KING'
	      AND price_inr = 1000 AND product_id = 'badge_royal_king_999'`, u.ID); n != 3 {
		t.Fatalf("%d receipts, want 3", n)
	}
	if got := len(f.ledgerRows(u.ID)); got != ledgerBefore {
		t.Fatalf("a badge purchase wrote %d chip_ledger rows", got-ledgerBefore)
	}

	// The same receipt sent from another account grants that account nothing.
	other := f.user("other")
	stolen, err := db.CreditBadgePurchase(f.ctx, f.d, f.users, other.ID, king, "king-receipt-1", now)
	if err != nil || stolen.Credited || holds(stolen.User, "ROYAL_KING", 0) {
		t.Fatalf("a receipt replayed from another account: %+v %v", stolen, err)
	}
}

// BadgeExpiry is the one rule a purchase's grant follows.
func TestABadgePurchaseExtendsARunningGrantAndStartsALapsedOneAgain(t *testing.T) {
	const now, day = int64(1_000_000_000_000), int64(86_400_000)
	ptr := func(v int64) *int64 { return &v }
	for _, tc := range []struct {
		name    string
		current *int64
		days    int
		want    int64
	}{
		{"no grant", nil, 15, now + 15*day},
		{"a running grant", ptr(now + 5*day), 30, now + 35*day},
		{"a lapsed grant", ptr(now - day), 30, now + 30*day},
		{"one ending this instant", ptr(now), 15, now + 15*day},
		{"a grant held for ever", ptr(0), 30, 0},
		{"a badge that lasts for ever", ptr(now + day), 0, 0},
	} {
		if got := db.BadgeExpiry(tc.current, tc.days, now); got != tc.want {
			t.Errorf("%s: %d, want %d", tc.name, got, tc.want)
		}
	}
}

// holds says whether user holds the badge code — until exactly until, where
// until is not 0.
func holds(user *db.User, code string, until int64) bool {
	if user == nil {
		return false
	}
	for _, b := range user.Badges {
		if b.Code == code {
			return until == 0 || b.ExpiresAt == until
		}
	}
	return false
}
