package db_test

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// TestABootBringsAnOlderDatabaseForward is the path production takes.
//
// Since 23 Sep 2026 there are two scripts, and the columns that used to arrive
// in their own V1.0.2 and V1.0.3 are declared in the baseline's CREATE TABLEs
// — which do nothing on a database that already has the table. What reaches
// such a database is the catalogue-guarded block after each CREATE TABLE.
// Production's database, built by go-server/v1.1.2, has chip_ledger.game and
// .variant but not users.is_bot, and has none of the four configuration tables
// (table_engines, table_categories, table_settings, table_configs); an older
// one lacks the ledger columns too. So this builds a
// schema, takes all of that away as its owner would find it missing, boots
// again, and checks that everything is back and that the paths which write the
// restored columns — a login, a poker room's checkpoint — work on it.
func TestABootBringsAnOlderDatabaseForward(t *testing.T) {
	older := dbtest.Open(t, "upgrade")
	ctx := context.Background()

	// An account that already exists, with its ledger, from before the
	// upgrade. Signed in on the current shape: this build's login writes
	// is_bot, which is exactly why the boot must restore it before anyone
	// signs in.
	before, _, err := db.NewUsers(older, welcome, nil).UpsertFromProfile(ctx, db.Profile{
		Provider: db.ProviderGuest, ProviderUserID: "upgrade-before-" + randomSuffix(t), DisplayName: "Before",
	})
	if err != nil {
		t.Fatal(err)
	}

	execSQL(t, older, `ALTER TABLE users DROP COLUMN is_bot`)
	// users.is_active (26 Sep 2026) is missing from production's go-server/v1.4.0.
	execSQL(t, older, `ALTER TABLE users DROP COLUMN is_active`)
	execSQL(t, older, `ALTER TABLE chip_ledger DROP COLUMN game, DROP COLUMN variant`)
	execSQL(t, older, `DROP TABLE table_configs`)
	execSQL(t, older, `DROP TABLE table_settings`)
	execSQL(t, older, `DROP TABLE table_categories`)
	execSQL(t, older, `DROP TABLE table_engines`)
	// The table pictures (merged 23 Sep 2026) are three more tables production
	// lacks until its next boot: dependents first.
	execSQL(t, older, `DROP TABLE user_table_choice`)
	execSQL(t, older, `DROP TABLE user_table_pictures`)
	execSQL(t, older, `DROP TABLE table_pictures`)
	// So are the emoji store's two (26 Sep 2026).
	execSQL(t, older, `DROP TABLE user_emojis`)
	execSQL(t, older, `DROP TABLE emojis`)
	// And Friends V1's three (26 Sep 2026). This build goes onto a FRESH
	// database (owner, 26 Sep 2026), so nothing is copied from anywhere: a boot
	// on an older one just creates them, and its players' statistics start at 0.
	execSQL(t, older, `DROP TABLE friendships`)
	execSQL(t, older, `DROP TABLE friend_requests`)
	execSQL(t, older, `DROP TABLE player_stats`)
	column := func(d *db.DB, table, name string) int64 {
		t.Helper()
		return countOf(t, d, `SELECT count(*) FROM information_schema.columns
             WHERE table_schema = $1 AND table_name = $2 AND column_name = $3`, d.Schema, table, name)
	}
	if column(older, "users", "is_bot")+column(older, "users", "is_active")+column(older, "chip_ledger", "game")+column(older, "chip_ledger", "variant") != 0 {
		t.Fatal("the columns were not dropped")
	}

	bootCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	d, err := db.Open(bootCtx, db.Options{URL: testURL(), Schema: older.Schema, PoolMax: 2})
	if err != nil {
		t.Fatalf("the boot that brings the database forward: %v", err)
	}
	t.Cleanup(d.Close)

	for _, c := range [][2]string{{"users", "is_bot"}, {"users", "is_active"}, {"chip_ledger", "game"}, {"chip_ledger", "variant"}} {
		if column(d, c[0], c[1]) != 1 {
			t.Errorf("%s.%s is not back", c[0], c[1])
		}
	}
	// The account that was already there is a person, as the DEFAULT says.
	if isBotOf(t, d, before.ID) {
		t.Error("an existing account must read is_bot = FALSE after the upgrade")
	}
	// …and enabled, as users.is_active's DEFAULT says: an upgrade disables nobody.
	if got, err := db.NewUsers(d, welcome, nil).FindByID(ctx, before.ID); err != nil || got == nil || got.Disabled {
		t.Errorf("the existing account after the upgrade: %+v %v, want it enabled", got, err)
	}
	// The catalogue tables were created and, being empty, seeded active — the
	// engines and categories with them.
	if got, want := loadTables(t, d), defaultCatalogue(); len(got.Public) != len(want.Public) || len(got.Private) != len(want.Private) ||
		!reflect.DeepEqual(got.Engines, want.Engines) || !reflect.DeepEqual(got.Categories, want.Categories) {
		t.Errorf("the upgraded catalogue: %d public, %d private, %+v, %+v; want %d and %d and the default taxonomy",
			len(got.Public), len(got.Private), got.Engines, got.Categories, len(want.Public), len(want.Private))
	}
	if n := countOf(t, d, `SELECT count(*) FROM table_configs WHERE NOT is_active`); n != 0 {
		t.Errorf("%d rows arrived inactive in an empty catalogue", n)
	}
	// The table pictures were created and seeded, and the account that was
	// already there reads with none laid.
	if n := countOf(t, d, `SELECT count(*) FROM table_pictures WHERE is_active`); n != 5 {
		t.Errorf("%d table pictures after the upgrade, want the seed's 5", n)
	}
	if got, err := db.NewUsers(d, welcome, nil).FindByID(ctx, before.ID); err != nil || got == nil || got.TablePicture != nil {
		t.Errorf("the existing account after the upgrade: %+v %v, want it read with no table picture laid", got, err)
	}

	// The emoji tables were created and seeded with the owner's nineteen, and an
	// emoji added to them can be bought by the account that was already there.
	if n := countOf(t, d, `SELECT count(*) FROM emojis WHERE is_active`); n != 19 {
		t.Errorf("%d emojis after the upgrade, want the seed's 19", n)
	}
	var emojiID int64
	if err := d.Pool.QueryRow(ctx, `INSERT INTO emojis (name, asset_url, type, currency, cost, created_at, updated_at)
	     VALUES ('Upgrade', '/emojis/upgrade.json', 'PREMIUM', 'DIAMOND', 1, 0, 0) RETURNING id`).Scan(&emojiID); err != nil {
		t.Fatalf("an emoji after the upgrade: %v", err)
	}
	if bought, err := db.NewEmojis(d, db.NewUsers(d, welcome, nil), nil).Buy(ctx, before.ID, emojiID); err != nil || !bought.Charged {
		t.Errorf("buying an emoji after the upgrade: %+v %v", bought, err)
	}

	// Friends V1: the three tables are there, empty — nothing is copied — and
	// the account that was already there reads its statistics as zeros.
	for _, table := range []string{"player_stats", "friend_requests", "friendships"} {
		if n := countOf(t, d, `SELECT count(*) FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2`, d.Schema, table); n != 1 {
			t.Errorf("%s was not created by the upgrade", table)
		}
	}
	if n := countOf(t, d, `SELECT count(*) FROM player_stats`); n != 0 {
		t.Errorf("%d player_stats rows after the upgrade: nothing is copied into it", n)
	}
	if got, err := db.NewUsers(d, welcome, nil).FindByID(ctx, before.ID); err != nil || got == nil ||
		got.HandsPlayed != 0 || got.HandsWon != 0 || got.HandsLost != 0 || got.HandsLeftMid != 0 || got.TotalWinnings != 0 || got.BiggestPot != 0 {
		t.Errorf("the old account reads %+v %v, want zero statistics", got, err)
	}

	// A bot's login writes the restored column.
	bot, isNew, err := db.NewUsers(d, welcome, nil).UpsertFromProfile(ctx, db.Profile{
		Provider: db.ProviderGuest, ProviderUserID: "upgrade-bot-" + randomSuffix(t), DisplayName: "Kavya", IsBot: true,
	})
	if err != nil || !isNew {
		t.Fatalf("a first login after the upgrade: isNew=%v err=%v", isNew, err)
	}
	if !isBotOf(t, d, bot.ID) {
		t.Error("a bot login after the upgrade must be recorded as one")
	}

	// A poker room's checkpoint writes the restored ledger columns.
	handID := "upgrade-hand-" + randomSuffix(t)
	if _, err := db.NewLedger(d, nil, nil).Checkpoint(ctx, game.CheckpointRequest{
		RoomID: "upgrade-room", HandID: handID,
		Entry: game.SettleEntry{
			UserID: bot.ID, Delta: -500, Reason: game.LedgerReasonHandPacked,
			ActionID: game.PackedActionID(handID, bot.ID),
			Game:     game.GamePoker, Variant: game.Category("texas_holdem"),
		},
	}); err != nil {
		t.Fatalf("a poker checkpoint after the upgrade: %v", err)
	}
	var family, variant *string
	if err := d.Pool.QueryRow(ctx, `SELECT game, variant FROM chip_ledger WHERE hand_id = $1`, handID).Scan(&family, &variant); err != nil {
		t.Fatal(err)
	}
	if family == nil || *family != "poker" || variant == nil || *variant != "texas_holdem" {
		t.Errorf("the poker row reads game %v, variant %v", family, variant)
	}
	// And the wallets still reconcile with their ledgers.
	if n := countOf(t, d, `SELECT count(*) FROM users u
         JOIN (SELECT user_id, SUM(delta) s FROM chip_ledger GROUP BY user_id) l ON l.user_id = u.id
        WHERE l.s <> u.chips`); n != 0 {
		t.Errorf("%d wallets disagree with their ledgers", n)
	}

	// A second boot on the upgraded database is a no-op, statistics included:
	// a hand played since the upgrade survives it.
	if _, err := db.NewLedger(d, nil, nil).Settle(ctx, game.SettleRequest{
		RoomID: "upgrade-room", HandID: "upgrade-settle-" + randomSuffix(t),
		Entries: []game.SettleEntry{{UserID: before.ID, Delta: 0, Reason: game.LedgerReasonHandLoss,
			ActionID: game.SettleActionID("upgrade-settle", before.ID), Outcome: true, DidChaal: true}},
	}); err != nil {
		t.Fatal(err)
	}
	reboot(t, d)
	if n := countOf(t, d, `SELECT hands_played FROM player_stats WHERE user_id = $1`, before.ID); n != 1 {
		t.Errorf("hands_played after a second boot = %d, want 1", n)
	}
	for _, c := range [][2]string{{"users", "is_bot"}, {"users", "is_active"}, {"chip_ledger", "game"}, {"chip_ledger", "variant"}} {
		if column(d, c[0], c[1]) != 1 {
			t.Errorf("%s.%s after a second boot", c[0], c[1])
		}
	}
}
