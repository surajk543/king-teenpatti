package db_test

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// deployGuide is the runbook whose §7 this file executes, relative to this
// package's directory (where go test runs).
const deployGuide = "../../ops/DEPLOY.md"

// The migrations must boot as the app role — twice — both while it owns every
// table and after ops/DEPLOY.md §7 has handed users to the superuser.
//
// Production runs every migration on every boot as gameplay_app, a role that
// is not a superuser. §7 gives users and its trigger function to postgres and
// grants the app role back only what it uses, so that deleting a player takes
// sudo on the host. Under that arrangement a statement that needs to OWN users
// fails, and PostgreSQL checks ownership before IF NOT EXISTS: the baseline's
// `CREATE INDEX IF NOT EXISTS idx_users_last_login ON users` failed on every
// boot although it had nothing to do, and diamond_purchases, created
// with a foreign key to users, failed for want of REFERENCES. Neither shows
// while the app role owns everything — which is what production and every
// other test here run as — so following §7 and restarting would have left the
// server in a crash loop.
//
// The SQL applied is read out of DEPLOY.md itself, so the runbook and the test
// cannot drift apart: what §7 tells an operator to run is what is proved to
// boot.
func TestTheAppRoleBootsTwiceBeforeAndAfterUsersIsHandedToTheSuperuser(t *testing.T) {
	_ = dbtest.Open(t, "db") // skips when Postgres is unreachable
	ctx := context.Background()
	base := testURL()

	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Skipf("connect to %s: %v", db.Redact(base), err)
	}
	t.Cleanup(func() { _ = admin.Close(context.Background()) })
	var superuser bool
	var database string
	if err := admin.QueryRow(ctx, `SELECT rolsuper, current_database() FROM pg_roles WHERE rolname = current_user`).Scan(&superuser, &database); err != nil {
		t.Fatal(err)
	}
	if !superuser {
		t.Skip("needs a superuser: it creates a login role and takes users away from it, as §7 does with postgres")
	}

	suffix := randomSuffix(t)
	role := "test_db_app_" + suffix
	// Not derived from the role name: a run killed before its cleanup leaves the
	// role behind, and its password must not be readable off pg_roles.
	password := "pw_" + randomSuffix(t) + randomSuffix(t)
	schema := "test_db_handover_" + suffix
	roleIdent := pgx.Identifier{role}.Sanitize()
	schemaIdent := pgx.Identifier{schema}.Sanitize()
	qualified := func(name string) string { return pgx.Identifier{schema, name}.Sanitize() }

	// §7 names two roles: postgres, which here is whichever superuser the test
	// connected as, and gameplay_app, which is the throwaway role.
	section7 := strings.ReplaceAll(section7SQL(t), "OWNER TO postgres", "OWNER TO CURRENT_USER")
	section7 = strings.ReplaceAll(section7, "gameplay_app", roleIdent)
	if strings.Contains(section7, "postgres") {
		t.Fatalf("%s §7 names postgres in a form this test does not map:\n%s", deployGuide, section7)
	}

	if _, err := admin.Exec(ctx, `CREATE ROLE `+roleIdent+` LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '`+password+`'`); err != nil {
		t.Fatalf("create role: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if _, err := admin.Exec(ctx, `DROP SCHEMA IF EXISTS `+schemaIdent+` CASCADE`); err != nil {
			t.Errorf("drop schema %s: %v", schema, err)
		}
		// DROP OWNED BY also revokes the CREATE ON DATABASE granted below.
		if err := execUnderDatabaseACLLock(ctx, admin, `DROP OWNED BY `+roleIdent, `DROP ROLE `+roleIdent); err != nil {
			t.Errorf("drop role %s: %v", role, err)
		}
	})
	// The app role creates its own schema, as gameplay_app does, and the
	// bootstrap's CREATE SCHEMA IF NOT EXISTS needs CREATE on the database even
	// when the schema is already there.
	if err := execUnderDatabaseACLLock(ctx, admin, `GRANT CREATE ON DATABASE `+pgx.Identifier{database}.Sanitize()+` TO `+roleIdent); err != nil {
		t.Fatalf("grant create on database: %v", err)
	}

	asRole := withLogin(t, base, role, password)
	probe, err := pgx.Connect(ctx, asRole)
	if err != nil {
		t.Skipf("cannot log in as a password role (pg_hba.conf?): %v", err)
	}
	_ = probe.Close(ctx)

	// boot is one server start as the app role: db.Open runs every migration.
	boot := func(when, hint string) *db.DB {
		t.Helper()
		bootCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		d, err := db.Open(bootCtx, db.Options{URL: asRole, Schema: schema, PoolMax: 2})
		if err != nil {
			t.Fatalf("boot %s, as %s: %v%s", when, role, err, hint)
		}
		t.Cleanup(d.Close)
		return d
	}
	usersIndexes := func() int64 {
		t.Helper()
		var n int64
		if err := admin.QueryRow(ctx, `
			SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
			 WHERE i.indrelid = $1::text::regclass AND c.relname = 'idx_users_last_login'`, qualified("users")).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	ownerOfUsers := func() string {
		t.Helper()
		var owner string
		if err := admin.QueryRow(ctx, `SELECT relowner::regrole::text FROM pg_class WHERE oid = $1::text::regclass`, qualified("users")).Scan(&owner); err != nil {
			t.Fatal(err)
		}
		return owner
	}

	// 1. The app role owns everything, as production does today.
	boot("the first time, owning every table", "")
	boot("the second time, owning every table", "")
	if owner := ownerOfUsers(); owner != role {
		t.Fatalf("before §7 users belongs to %s, want %s", owner, role)
	}
	if n := usersIndexes(); n != 1 {
		t.Fatalf("a fresh database must get idx_users_last_login once, found %d", n)
	}

	// 2. §7, exactly as DEPLOY.md has it, run as the superuser.
	tx, err := admin.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	if _, err := tx.Exec(ctx, `SET LOCAL search_path TO `+schemaIdent); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, section7); err != nil {
		t.Fatalf("%s §7: %v\n%s", deployGuide, err, section7)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if owner := ownerOfUsers(); owner == role {
		t.Fatalf("§7 left users with the app role")
	}

	// 3. The same scripts, now that the app role no longer owns users.
	const ownerHint = "\n  a statement that needs to own users must sit behind a catalogue lookup (DEPLOY.md §7)"
	boot("the first time after §7", ownerHint)
	d := boot("the second time after §7", ownerHint)

	// The arrangement is really in force, and still enough to sign a player in.
	var pgErr *pgconn.PgError
	_, err = d.Pool.Exec(ctx, `ALTER TABLE users DISABLE TRIGGER users_no_delete`)
	if !errors.As(err, &pgErr) || pgErr.Code != "42501" {
		t.Fatalf("after §7 the app role must not be able to disable the trigger, got %v", err)
	}
	u, isNew, err := db.NewUsers(d, welcome, nil).UpsertFromProfile(ctx, db.Profile{
		Provider:       db.ProviderGuest,
		ProviderUserID: "handover-" + suffix,
		DisplayName:    "Handover",
	})
	if err != nil || !isNew {
		t.Fatalf("a first login must work on §7's grants: isNew=%v err=%v", isNew, err)
	}
	_, err = d.Pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, u.ID)
	if !errors.As(err, &pgErr) || pgErr.Code != "42501" {
		t.Fatalf("after §7 the app role must not be able to delete a user, got %v", err)
	}

	// 4. Tables created while postgres owns users, with a foreign key to it.
	// diamond_purchases, hammer_purchases, hammer_spends, missile_purchases and
	// missile_spends stand in for every such table a later release adds:
	// dropped here, the migrations create them again on the next boot. That
	// takes REFERENCES on users, which an owner has and a grantee must be given.
	referencing := []string{"diamond_purchases", "hammer_purchases", "hammer_spends", "missile_purchases", "missile_spends"}
	for _, table := range referencing {
		if _, err := admin.Exec(ctx, `DROP TABLE `+qualified(table)); err != nil {
			t.Fatal(err)
		}
	}
	const referencesHint = "\n  a table with a foreign key to users needs GRANT REFERENCES ON users (DEPLOY.md §7)"
	boot("creating the tables that reference users, after §7", referencesHint)
	d = boot("once more after that", referencesHint)
	for _, table := range referencing {
		var foreignKeys int64
		if err := admin.QueryRow(ctx, `
			SELECT count(*) FROM pg_constraint
			 WHERE contype = 'f' AND conrelid = $1::text::regclass AND confrelid = $2::text::regclass`,
			qualified(table), qualified("users")).Scan(&foreignKeys); err != nil {
			t.Fatal(err)
		}
		if foreignKeys != 1 {
			t.Fatalf("%s should reference users once, found %d foreign keys", table, foreignKeys)
		}
	}
	if n := usersIndexes(); n != 1 {
		t.Fatalf("boots under §7 must leave exactly one idx_users_last_login, found %d", n)
	}

	// 5. Hammers work on §7's grants: the account signed in above holds the 20
	// every account starts with, and a Force Sideshow can spend one.
	var hammers int64
	if err := admin.QueryRow(ctx, `SELECT hammer FROM `+qualified("users")+` WHERE id = $1`, u.ID).Scan(&hammers); err != nil {
		t.Fatal(err)
	}
	if hammers != 20 {
		t.Fatalf("a new account holds %d hammers, want 20", hammers)
	}
	spent, err := db.NewHammers(d, nil, nil).SpendHammer(ctx, game.HammerSpend{
		HandID: "handover", UserID: u.ID, ActionID: game.ForceSideshowSpendID("handover", u.ID, suffix),
	})
	if err != nil || spent.Remaining != 19 {
		t.Fatalf("a Force Sideshow's hammer must be spendable on §7's grants: %+v %v", spent, err)
	}

	// 6. Missiles too: the account holds the 9 diamonds and 1 missile every
	// new account gets, can fire it, and can trade for more — the superuser
	// sets its wallet to the cheapest pack's 5 diamonds first, so the trade's
	// result is exact.
	var diamonds, missiles int64
	if err := admin.QueryRow(ctx, `SELECT diamond, missile FROM `+qualified("users")+` WHERE id = $1`, u.ID).Scan(&diamonds, &missiles); err != nil {
		t.Fatal(err)
	}
	if diamonds != 9 || missiles != 1 {
		t.Fatalf("a new account holds %d diamonds and %d missiles, want 9 and 1", diamonds, missiles)
	}
	store := db.NewMissiles(d, db.NewUsers(d, welcome, nil), nil, nil)
	fired, err := store.SpendMissile(ctx, game.MissileSpend{
		HandID: "handover", UserID: u.ID, ActionID: game.MissileSpendID("handover", u.ID, suffix),
	})
	if err != nil || fired.Remaining != 0 {
		t.Fatalf("a missile must be spendable on §7's grants: %+v %v", fired, err)
	}
	if _, err := admin.Exec(ctx, `UPDATE `+qualified("users")+` SET diamond = 5 WHERE id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}
	if trade, err := store.TradeMissiles(ctx, u.ID, "missiles_1", "handover-"+suffix); err != nil || !trade.Charged || trade.User.Diamond != 0 || trade.User.Missile != 1 {
		t.Fatalf("a missile trade must work on §7's grants: %+v %v", trade, err)
	}
}

// section7SQL returns what ops/DEPLOY.md §7 has an operator feed to
// `sudo -u postgres psql gameplay` first: the handover itself.
func section7SQL(t *testing.T) string {
	t.Helper()
	return section7Blocks(t)[0]
}

// section7Blocks returns every SQL body §7 feeds to
// `sudo -u postgres psql gameplay <<'SQL'`, in order, with the indentation a
// block inside a list item carries taken off.
func section7Blocks(t *testing.T) []string {
	t.Helper()
	guide, err := os.ReadFile(deployGuide)
	if err != nil {
		t.Fatalf("read %s: %v", deployGuide, err)
	}
	text := string(guide)
	start := strings.Index(text, "\n## 7. ")
	if start < 0 {
		t.Fatalf("%s has no §7", deployGuide)
	}
	section := text[start+1:]
	if end := strings.Index(section, "\n## "); end >= 0 {
		section = section[:end]
	}
	const open = "sudo -u postgres psql gameplay <<'SQL'"
	var blocks []string
	lines := strings.Split(section, "\n")
	for i := 0; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) != open {
			continue
		}
		indent := lines[i][:len(lines[i])-len(strings.TrimLeft(lines[i], " "))]
		var body []string
		closed := false
		for i++; i < len(lines); i++ {
			if strings.TrimSpace(lines[i]) == "SQL" {
				closed = true
				break
			}
			body = append(body, strings.TrimPrefix(lines[i], indent))
		}
		if !closed {
			t.Fatalf("%s §7: an SQL block is not closed", deployGuide)
		}
		blocks = append(blocks, strings.Join(body, "\n"))
	}
	if len(blocks) == 0 {
		t.Fatalf("%s §7 no longer feeds its SQL to `%s`; update this test with it", deployGuide, open)
	}
	return blocks
}

// withLogin returns base with its login replaced by role's, in whichever of
// the two connection-string forms pgx accepts base was written.
func withLogin(t *testing.T, base, role, password string) string {
	t.Helper()
	if strings.HasPrefix(base, "postgres://") || strings.HasPrefix(base, "postgresql://") {
		u, err := url.Parse(base)
		if err != nil {
			t.Fatalf("parse %s: %v", db.Redact(base), err)
		}
		u.User = url.UserPassword(role, password)
		// A user or password in the query string would override the userinfo.
		q := u.Query()
		q.Del("user")
		q.Del("password")
		u.RawQuery = q.Encode()
		return u.String()
	}
	// Keyword/value form: a later keyword overrides an earlier one.
	return base + " user=" + role + " password=" + password
}

// execUnderDatabaseACLLock runs stmts in one transaction that first takes an
// advisory lock every run of this test shares. GRANT … ON DATABASE and DROP
// OWNED both rewrite the database's own row in pg_database, and several
// checkouts' test runs share one local database. Two sessions rewriting that
// row at once do not queue: one fails with "tuple concurrently updated" (six
// sessions granting and revoking in a loop on PostgreSQL 18 failed 228 times
// in 480), so the lock makes them take turns.
func execUnderDatabaseACLLock(ctx context.Context, conn *pgx.Conn, stmts ...string) error {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('king-teenpatti:test:database-acl'))`); err != nil {
		return err
	}
	for _, stmt := range stmts {
		if _, err := tx.Exec(ctx, stmt); err != nil {
			return fmt.Errorf("%s: %w", stmt, err)
		}
	}
	return tx.Commit(ctx)
}
