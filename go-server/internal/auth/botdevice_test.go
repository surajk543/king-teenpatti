package auth

import (
	"context"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// Marking the resident fleet (owner, 22 Sep 2026; users.is_bot, V1.0.3).
//
// The flag is only worth having if it is right in both directions: true for
// every account bot-play opens, and false for everyone else. These pin both,
// plus the two ways a prefix check goes wrong — an empty prefix matching
// everything, and whitespace splitting one device id into two verdicts.

func verifierWithPrefix(t *testing.T, prefix string) *Verifier {
	t.Helper()
	cfg := config.Defaults()
	cfg.BotDevicePrefix = prefix
	return NewVerifier(cfg)
}

func TestAGuestLoginFromTheBotFleetIsMarkedAsABot(t *testing.T) {
	v := verifierWithPrefix(t, "botplay-")

	// Exactly the device ids bot-play mints: identityFor and, for a bot that
	// went broke and was rotated, rotatedIdentity.
	for _, deviceID := range []string{
		"botplay-v1-0",
		"botplay-v1-197",
		"botplay-v1-42-g3",
	} {
		profile, err := v.VerifyLogin(context.Background(), LoginRequest{Provider: db.ProviderGuest, DeviceID: deviceID})
		if err != nil {
			t.Fatalf("%s: %v", deviceID, err)
		}
		if !profile.IsBot {
			t.Errorf("%s should be marked as a bot", deviceID)
		}
	}
}

func TestAnOrdinaryGuestIsNeverMarkedAsABot(t *testing.T) {
	v := verifierWithPrefix(t, "botplay-")

	for _, deviceID := range []string{
		"a1b2c3d4e5f6",          // a real phone's id
		"practice-bot-3-Ravi",   // tools/bot.js — a person's testing, not the fleet
		"ramp-bot-17-device-id", // the ramp test's accounts
		"botplaysomething",      // near miss: no hyphen, so not the namespace
		"not-botplay-v1-0",      // the prefix must be at the START
		"BOTPLAY-V1-0",          // case matters; the fleet is lower case
	} {
		profile, err := v.VerifyLogin(context.Background(), LoginRequest{Provider: db.ProviderGuest, DeviceID: deviceID})
		if err != nil {
			t.Fatalf("%s: %v", deviceID, err)
		}
		if profile.IsBot {
			t.Errorf("%s must not be marked as a bot", deviceID)
		}
	}
}

func TestAnEmptyBotPrefixMarksNobody(t *testing.T) {
	// strings.HasPrefix(anything, "") is true, so a deployment that turned the
	// marking off by blanking the key would otherwise flag every guest on the
	// server as a bot — the exact opposite of what it asked for.
	v := verifierWithPrefix(t, "")

	for _, deviceID := range []string{"botplay-v1-0", "a1b2c3d4e5f6"} {
		profile, err := v.VerifyLogin(context.Background(), LoginRequest{Provider: db.ProviderGuest, DeviceID: deviceID})
		if err != nil {
			t.Fatalf("%s: %v", deviceID, err)
		}
		if profile.IsBot {
			t.Errorf("%s was marked with the prefix disabled", deviceID)
		}
	}
}

func TestTheBotMarkIsDecidedOnTheSameStringTheAccountIsKeyedOn(t *testing.T) {
	// VerifyGuest trims before hashing, so "  botplay-v1-0  " and
	// "botplay-v1-0" are ONE account. If the mark were decided on the untrimmed
	// value they would be one account with two verdicts, and which one it
	// carried would depend on the order the logins happened to arrive in.
	v := verifierWithPrefix(t, "botplay-")

	padded, err := v.VerifyLogin(context.Background(), LoginRequest{Provider: db.ProviderGuest, DeviceID: "  botplay-v1-0  "})
	if err != nil {
		t.Fatal(err)
	}
	plain, err := v.VerifyLogin(context.Background(), LoginRequest{Provider: db.ProviderGuest, DeviceID: "botplay-v1-0"})
	if err != nil {
		t.Fatal(err)
	}
	if padded.ProviderUserID != plain.ProviderUserID {
		t.Fatal("trimming should make these the same account")
	}
	if !padded.IsBot || !plain.IsBot {
		t.Errorf("both should be marked: padded=%v plain=%v", padded.IsBot, plain.IsBot)
	}
}

func TestOnlyGuestLoginsAreEverMarked(t *testing.T) {
	// A bot is a guest, always — the fleet has no Google credentials. A signed-in
	// person carrying a device id that happens to match must not be marked,
	// because for them it is not an identity at all.
	cfg := config.Defaults()
	cfg.BotDevicePrefix = "botplay-"
	cfg.AllowFakeProviders = true
	v := NewVerifier(cfg)

	profile, err := v.VerifyLogin(context.Background(), LoginRequest{
		Provider:    db.ProviderGoogle,
		DeviceID:    "botplay-v1-0",
		DisplayName: "A Real Person",
	})
	if err != nil {
		t.Fatal(err)
	}
	if profile.IsBot {
		t.Error("a google login must never be marked from a device id")
	}
}

func TestTheDefaultPrefixIsTheFleetsNamespace(t *testing.T) {
	// bot-play/src/identities.js mints `botplay-v1-<index>`; if that namespace
	// or this default ever moves without the other, the fleet silently stops
	// being marked and nothing fails.
	if got := config.Defaults().BotDevicePrefix; got != "botplay-" {
		t.Errorf("BOT_DEVICE_PREFIX default = %q, want %q (bot-play's device id namespace)", got, "botplay-")
	}
}
