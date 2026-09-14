package db_test

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase"
)

// A premium package (owner, 14 Sep 2026) is banked in one transaction exactly
// once per Play token: its chips through one `purchase` chip_ledger row, and
// its missiles and hammers into users.missile and users.hammer beside it —
// never into chip_ledger, and with no guard table of their own. A replayed
// receipt, or the same token from a second account, moves none of the three;
// the diamonds never move; and every wallet still equals its ledger.
func TestAPremiumPackageBanksItsChipsMissilesAndHammersOnce(t *testing.T) {
	f := newFixture(t)
	u := f.user("premium-buyer")
	p, err := purchase.Lookup("premium_5_49999")
	if err != nil {
		t.Fatal(err)
	}
	token := "premium-token-" + randomSuffix(t)
	startRows := len(f.ledgerRows(u.ID))
	missiles, hammers, diamonds := f.missilesOf(u.ID), f.hammersOf(u.ID), f.diamondsOf(u.ID)
	const chips int64 = 47_500_000_000

	first, err := db.CreditPurchase(f.ctx, f.d, f.users, u.ID, p, token)
	if err != nil {
		t.Fatalf("credit: %v", err)
	}
	if !first.Credited || first.Chips != chips || first.Missiles != 11 || first.Hammers != 45 || first.Diamonds != 0 ||
		first.Balance != welcome+chips || first.User == nil || first.User.Chips != welcome+chips ||
		first.User.Missile != int(missiles)+11 || first.User.Hammer != int(hammers)+45 {
		t.Fatalf("first credit: %+v (user %+v)", first, first.User)
	}
	if f.chips(u.ID) != welcome+chips || f.missilesOf(u.ID) != missiles+11 || f.hammersOf(u.ID) != hammers+45 || f.diamondsOf(u.ID) != diamonds {
		t.Fatalf("wallets after the credit: chips %d, missiles %d, hammers %d, diamonds %d",
			f.chips(u.ID), f.missilesOf(u.ID), f.hammersOf(u.ID), f.diamondsOf(u.ID))
	}
	rows := f.ledgerRows(u.ID)
	if len(rows) != startRows+1 {
		t.Fatalf("a premium package wrote %d chip_ledger rows, want 1", len(rows)-startRows)
	}
	last := rows[len(rows)-1]
	if last.Reason != game.LedgerReasonPurchase || last.Delta != chips ||
		last.ActionID == nil || *last.ActionID != purchase.ActionID(token) {
		t.Fatalf("purchase ledger row: %+v", last)
	}
	if n := f.count(`SELECT count(*) FROM hammer_purchases WHERE purchase_token = $1`, token) +
		f.count(`SELECT count(*) FROM missile_purchases WHERE user_id = $1`, u.ID); n != 0 {
		t.Fatalf("a premium package wrote %d rows to a soft-pack guard; the ledger row is its only record", n)
	}

	// The same receipt again — a retry after a lost reply, or Play restoring it.
	again, err := db.CreditPurchase(f.ctx, f.d, f.users, u.ID, p, token)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if again.Credited || again.Chips != chips || again.Missiles != 11 || again.Hammers != 45 ||
		again.Balance != welcome+chips || again.User == nil || again.User.Missile != int(missiles)+11 || again.User.Hammer != int(hammers)+45 {
		t.Fatalf("replay: %+v (user %+v), want the product's figures with nothing credited", again, again.User)
	}
	if f.chips(u.ID) != welcome+chips || f.missilesOf(u.ID) != missiles+11 || f.hammersOf(u.ID) != hammers+45 || len(f.ledgerRows(u.ID)) != startRows+1 {
		t.Fatalf("a replayed receipt moved a wallet: chips %d, missiles %d, hammers %d, ledger rows %d",
			f.chips(u.ID), f.missilesOf(u.ID), f.hammersOf(u.ID), len(f.ledgerRows(u.ID))-startRows)
	}

	// The same token from another account pays nobody anything.
	other := f.user("premium-thief")
	stolen, err := db.CreditPurchase(f.ctx, f.d, f.users, other.ID, p, token)
	if err != nil || stolen.Credited {
		t.Fatalf("a token already banked was credited to another account: %+v %v", stolen, err)
	}
	if f.chips(other.ID) != welcome || f.missilesOf(other.ID) != 1 || f.hammersOf(other.ID) != 20 || f.diamondsOf(other.ID) != 9 {
		t.Fatalf("the second account's wallets moved: chips %d, missiles %d, hammers %d, diamonds %d",
			f.chips(other.ID), f.missilesOf(other.ID), f.hammersOf(other.ID), f.diamondsOf(other.ID))
	}
	f.reconcile()
}

// Now that a product can carry missiles, the packs that fill one wallet still
// fill only that one: a chip pack moves no missiles or hammers, a hammer pack
// no chips or missiles, a diamond pack no chips, missiles or hammers. And a
// premium package is banked only through CreditPurchase: the hammer and
// diamond credits refuse it (so its hammers can never be banked alone), as
// CreditPurchase refuses a pack with no chips.
func TestTheSingleWalletPacksAreUnchangedAndAPremiumPackageOnlyBanksThroughChips(t *testing.T) {
	f := newFixture(t)
	u := f.user("single-wallet-buyer")
	missiles, hammers, diamonds := f.missilesOf(u.ID), f.hammersOf(u.ID), f.diamondsOf(u.ID)
	wallets := func() [4]int64 {
		return [4]int64{f.chips(u.ID), f.missilesOf(u.ID), f.hammersOf(u.ID), f.diamondsOf(u.ID)}
	}

	chipPack, _ := purchase.Lookup("chips_a_99")
	out, err := db.CreditPurchase(f.ctx, f.d, f.users, u.ID, chipPack, "single-chips-"+randomSuffix(t))
	if err != nil || !out.Credited || out.Chips != chipPack.Chips || out.Missiles != 0 || out.Hammers != 0 || out.Diamonds != 0 {
		t.Fatalf("chip pack: %+v %v", out, err)
	}
	if got, want := wallets(), [4]int64{welcome + chipPack.Chips, missiles, hammers, diamonds}; got != want {
		t.Fatalf("after a chip pack: %v, want %v", got, want)
	}
	rows := len(f.ledgerRows(u.ID))

	hammerPack, _ := purchase.Lookup("hammers_20_300")
	out, err = db.CreditHammerPurchase(f.ctx, f.d, f.users, u.ID, hammerPack, "single-hammers-"+randomSuffix(t))
	if err != nil || !out.Credited || out.Hammers != 20 || out.Chips != 0 || out.Missiles != 0 || out.Diamonds != 0 {
		t.Fatalf("hammer pack: %+v %v", out, err)
	}
	if got, want := wallets(), [4]int64{welcome + chipPack.Chips, missiles, hammers + 20, diamonds}; got != want {
		t.Fatalf("after a hammer pack: %v, want %v", got, want)
	}

	gemPack, _ := purchase.Lookup("diamonds_1_49")
	out, err = db.CreditDiamondPurchase(f.ctx, f.d, f.users, u.ID, gemPack, "single-gems-"+randomSuffix(t))
	if err != nil || !out.Credited || out.Diamonds != 1 || out.Chips != 0 || out.Missiles != 0 || out.Hammers != 0 {
		t.Fatalf("diamond pack: %+v %v", out, err)
	}
	after := [4]int64{welcome + chipPack.Chips, missiles, hammers + 20, diamonds + 1}
	if got := wallets(); got != after {
		t.Fatalf("after a diamond pack: %v, want %v", got, after)
	}
	if len(f.ledgerRows(u.ID)) != rows {
		t.Fatal("a hammer or diamond pack wrote a chip_ledger row")
	}

	premium, _ := purchase.Lookup("premium_1_9999")
	if _, err := db.CreditHammerPurchase(f.ctx, f.d, f.users, u.ID, premium, "premium-as-hammers-"+randomSuffix(t)); err == nil {
		t.Fatal("a premium package must not be banked as a hammer pack")
	}
	if _, err := db.CreditDiamondPurchase(f.ctx, f.d, f.users, u.ID, premium, "premium-as-gems-"+randomSuffix(t)); err == nil {
		t.Fatal("a premium package must not be banked as a diamond pack")
	}
	if _, err := db.CreditPurchase(f.ctx, f.d, f.users, u.ID, hammerPack, "hammers-as-chips-"+randomSuffix(t)); err == nil {
		t.Fatal("a hammer pack must not be banked as chips")
	}
	if got := wallets(); got != after || len(f.ledgerRows(u.ID)) != rows {
		t.Fatalf("a refused credit moved a wallet: %v, want %v", got, after)
	}
	f.reconcile()
}
