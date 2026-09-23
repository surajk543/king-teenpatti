package db_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// users.is_bot (owner, 22 Sep 2026). Declared in V1.0.0__baseline.sql, into
// which V1.0.3__users_is_bot.sql was folded on 23 Sep 2026;
// TestABootBringsAnOlderDatabaseForward covers a database built before it.
//
// The column exists so a question about real players can leave the resident
// fleet out. That only works if the value is right on the way in and stays
// right afterwards, which is what these pin.

func isBotOf(t *testing.T, store *db.DB, userID string) bool {
	t.Helper()
	rows, err := store.Query(context.Background(), `SELECT is_bot FROM users WHERE id = $1`, userID)
	if err != nil {
		t.Fatalf("reading is_bot: %v", err)
	}
	defer rows.Close()
	if !rows.Next() {
		t.Fatalf("no user row for %s", userID)
	}
	var isBot bool
	if err := rows.Scan(&isBot); err != nil {
		t.Fatalf("scanning is_bot: %v", err)
	}
	return isBot
}

func TestAnAccountIsNotABotUnlessTheLoginSaysSo(t *testing.T) {
	store := dbtest.Open(t, "isbot")
	users := db.NewUsers(store, 200_000, nil)
	ctx := context.Background()

	person, _, err := users.UpsertFromProfile(ctx, db.Profile{
		Provider:       db.ProviderGuest,
		ProviderUserID: "hash-of-a-real-phone",
		DisplayName:    "Suraj",
	})
	if err != nil {
		t.Fatal(err)
	}
	if isBotOf(t, store, person.ID) {
		t.Error("a profile with IsBot unset must default to false")
	}
}

func TestABotProfileIsRecordedAsOne(t *testing.T) {
	store := dbtest.Open(t, "isbot")
	users := db.NewUsers(store, 200_000, nil)
	ctx := context.Background()

	bot, isNew, err := users.UpsertFromProfile(ctx, db.Profile{
		Provider:       db.ProviderGuest,
		ProviderUserID: "hash-of-botplay-v1-7",
		DisplayName:    "Kavya",
		IsBot:          true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !isNew {
		t.Fatal("expected a fresh account")
	}
	if !isBotOf(t, store, bot.ID) {
		t.Error("a bot login should be recorded as a bot")
	}
}

func TestTheBotMarkIsNeverCleared(t *testing.T) {
	// The fleet's device ids are stable, so in practice every login for a bot
	// account arrives marked. But the column's whole value is that it can be
	// trusted, and an account quietly cleared would be indistinguishable from
	// a person for ever after — so the update ORs rather than assigns.
	store := dbtest.Open(t, "isbot")
	users := db.NewUsers(store, 200_000, nil)
	ctx := context.Background()

	profile := db.Profile{
		Provider:       db.ProviderGuest,
		ProviderUserID: "hash-of-botplay-v1-12",
		DisplayName:    "Ansh",
		IsBot:          true,
	}
	bot, _, err := users.UpsertFromProfile(ctx, profile)
	if err != nil {
		t.Fatal(err)
	}

	// The same account signing in again without the mark — a prefix that was
	// reconfigured, or BOT_DEVICE_PREFIX blanked.
	profile.IsBot = false
	again, _, err := users.UpsertFromProfile(ctx, profile)
	if err != nil {
		t.Fatal(err)
	}
	if again.ID != bot.ID {
		t.Fatal("expected the same account back")
	}
	if !isBotOf(t, store, bot.ID) {
		t.Error("the bot mark must survive a login that does not carry it")
	}
}

func TestMarkingABotDoesNotLeakToTheClient(t *testing.T) {
	// A seat that announced itself as a bot would tell a player exactly what
	// the fleet exists not to tell them, so the flag must not be on the public
	// user at all — this is the guard against someone adding it "for
	// completeness" when the struct next grows a field.
	store := dbtest.Open(t, "isbot")
	users := db.NewUsers(store, 200_000, nil)
	ctx := context.Background()

	bot, _, err := users.UpsertFromProfile(ctx, db.Profile{
		Provider:       db.ProviderGuest,
		ProviderUserID: "hash-of-botplay-v1-31",
		DisplayName:    "Neha",
		IsBot:          true,
	})
	if err != nil {
		t.Fatal(err)
	}

	encoded, err := json.Marshal(bot)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"is_bot", "isBot"} {
		if strings.Contains(strings.ToLower(string(encoded)), strings.ToLower(forbidden)) {
			t.Errorf("the public user JSON mentions %q: %s", forbidden, encoded)
		}
	}
}
