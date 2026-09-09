package db_test

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

func TestDeletingAnAccountKeepsTheLedgerAndTheInvariant(t *testing.T) {
	f := newFixture(t)
	u := f.user("Deleter")

	before := len(f.ledgerRows(u.ID))
	if before == 0 {
		t.Fatal("a new account should already have its welcome_bonus row")
	}
	if got := f.ledgerSum(u.ID); got != welcome {
		t.Fatalf("ledger sum before deletion = %d, want %d", got, welcome)
	}

	if err := f.users.DeleteAccount(f.ctx, u.ID); err != nil {
		t.Fatal(err)
	}

	// The money audit survives: the welcome row is still there, plus the row
	// that empties the wallet. Deleting the users row instead would have taken
	// both with it — chip_ledger.user_id is ON DELETE CASCADE.
	rows := f.ledgerRows(u.ID)
	if len(rows) != before+1 {
		t.Fatalf("ledger rows after deletion = %d, want %d", len(rows), before+1)
	}
	if got := f.ledgerSum(u.ID); got != 0 {
		t.Fatalf("ledger sum after deletion = %d, want 0 — the invariant is broken", got)
	}

	if chips := f.chips(u.ID); chips != 0 {
		t.Fatalf("chips after deletion = %d, want 0", chips)
	}
	last := rows[len(rows)-1]
	if last.Reason != game.LedgerReasonAccountDeleted {
		t.Fatalf("last ledger reason = %q, want %q", last.Reason, game.LedgerReasonAccountDeleted)
	}
	if last.Delta != -welcome || last.Balance != 0 {
		t.Fatalf("closing row = delta %d balance %d, want delta %d balance 0", last.Delta, last.Balance, -welcome)
	}

	// The account-wide check the ops runbook uses, run here so a deletion can
	// never be the thing that makes it fail in production.
	f.reconcile()
}

func TestADeletedAccountStopsResolvingSoItsTokenStopsWorking(t *testing.T) {
	f := newFixture(t)
	u := f.user("Ghost")

	if err := f.users.DeleteAccount(f.ctx, u.ID); err != nil {
		t.Fatal(err)
	}

	// A JWT lives 30 days. Deletion has to bite immediately, and it does
	// because every authenticated path resolves the user through this query.
	found, err := f.users.FindByID(f.ctx, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	if found != nil {
		t.Fatalf("FindByID returned a deleted account: %+v", found)
	}
}

func TestDeletingAnAccountErasesWhatIdentifiesThePlayer(t *testing.T) {
	f := newFixture(t)
	u := f.user("Nameless")

	if err := f.users.DeleteAccount(f.ctx, u.ID); err != nil {
		t.Fatal(err)
	}

	var name string
	var email, avatarURL, avatarChoice *string
	var providerUserID string
	var deletedAt int64
	if err := f.d.Pool.QueryRow(f.ctx,
		`SELECT display_name, email, avatar_url, avatar_choice, provider_user_id, deleted_at
		   FROM users WHERE id = $1`, u.ID).
		Scan(&name, &email, &avatarURL, &avatarChoice, &providerUserID, &deletedAt); err != nil {
		t.Fatal(err)
	}
	if name != db.DeletedDisplayName {
		t.Fatalf("display_name = %q, want %q", name, db.DeletedDisplayName)
	}
	for label, value := range map[string]*string{"email": email, "avatar_url": avatarURL, "avatar_choice": avatarChoice} {
		if value != nil {
			t.Errorf("%s survived deletion: %q", label, *value)
		}
	}
	if deletedAt == 0 {
		t.Error("deleted_at was not stamped")
	}
	if providerUserID == u.ID {
		t.Error("provider identity was not replaced")
	}
}

func TestTheSameDeviceSigningInAfterDeletionGetsAFreshAccount(t *testing.T) {
	f := newFixture(t)

	identity := "delete-reuse-" + randomSuffix(t)
	profile := db.Profile{Provider: db.ProviderGuest, ProviderUserID: identity, DisplayName: "Returning"}

	first, isNew, err := f.users.UpsertFromProfile(f.ctx, profile)
	if err != nil {
		t.Fatal(err)
	}
	if !isNew {
		t.Fatal("the first login should have created the account")
	}

	if err := f.users.DeleteAccount(f.ctx, first.ID); err != nil {
		t.Fatal(err)
	}

	// Clearing provider_user_id is what frees (provider, provider_user_id) for
	// reuse. Without it the unique index would hand the deleted account back,
	// which is precisely what deletion must not do.
	second, isNew, err := f.users.UpsertFromProfile(f.ctx, profile)
	if err != nil {
		t.Fatal(err)
	}
	if !isNew {
		t.Fatal("signing in after deletion should create a NEW account, not resurrect the old one")
	}
	if second.ID == first.ID {
		t.Fatal("the new account reused the deleted account's id")
	}
	if second.Chips != welcome {
		t.Fatalf("new account chips = %d, want the welcome grant %d", second.Chips, welcome)
	}
}
