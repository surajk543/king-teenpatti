package db_test

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// TestUserRowsAreNeverDeleted: a `DELETE FROM users` is refused by a trigger,
// whatever the row holds. The server never deletes one — DELETE /api/account
// pseudonymises — so the only thing a delete can be is a mistake or a hand on
// the wrong console, and it must take a deliberate privileged step (disable
// the trigger as the table owner or a superuser) rather than one statement.
// Owner's decision, 10 Sep 2026.
func TestUserRowsAreNeverDeleted(t *testing.T) {
	f := newFixture(t)

	// A bare row with no ledger rows: nothing else stands in the delete's
	// way, so only the users trigger can refuse it.
	now := time.Now().UnixMilli()
	if _, err := f.d.Pool.Exec(f.ctx, `
		INSERT INTO users (id, provider, provider_user_id, display_name, created_at, updated_at, last_login_at)
		VALUES ('bare-user', 'guest', 'bare-device', 'Bare', $1, $1, $1)`, now); err != nil {
		t.Fatal(err)
	}
	refused := func(id string) {
		t.Helper()
		_, err := f.d.Pool.Exec(f.ctx, `DELETE FROM users WHERE id = $1`, id)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || !strings.Contains(pgErr.Message, "users rows are never deleted") {
			t.Fatalf("DELETE users %s: expected the users trigger, got %v", id, err)
		}
		if n := f.count(`SELECT COUNT(*) FROM users WHERE id = $1`, id); n != 1 {
			t.Fatalf("row %s gone (%d)", id, n)
		}
	}
	refused("bare-user")

	// A real account, ledger rows and all: the users trigger answers before
	// the cascade ever reaches chip_ledger's.
	u := f.user("Deletable")
	refused(u.ID)

	// The player's own route still works: it pseudonymises the row in place.
	if err := f.users.DeleteAccount(f.ctx, u.ID); err != nil {
		t.Fatalf("DeleteAccount: %v", err)
	}
	if n := f.count(`SELECT COUNT(*) FROM users WHERE id = $1 AND deleted_at > 0`, u.ID); n != 1 {
		t.Fatalf("pseudonymised row missing (%d)", n)
	}
}
