package config

import (
	"slices"
	"testing"
)

// BOT_DEVICE_PREFIX is a comma-separated list since 27 Sep 2026 (owner: "any
// bot who plays that should be marked is_bot true"): unset is every bot the
// project runs, each entry is trimmed, an empty one is dropped, and an empty
// value marks nobody — never everybody.
func TestTheBotDevicePrefixesAreAListAndEmptyMarksNobody(t *testing.T) {
	for raw, want := range map[string][]string{
		"botplay-":                         {"botplay-"},
		" botplay- , practice-bot- ,, ":    {"botplay-", "practice-bot-"},
		"botplay-,practice-bot-,ramp-bot-": {"botplay-", "practice-bot-", "ramp-bot-"},
		"":                                 {},
		" , ":                              {},
	} {
		cfg, err := FromEnv(env(map[string]string{"BOT_DEVICE_PREFIX": raw}))
		if err != nil {
			t.Fatalf("%q: %v", raw, err)
		}
		if !slices.Equal(cfg.BotDevicePrefixes, want) || cfg.BotDevicePrefixes == nil {
			t.Errorf("BOT_DEVICE_PREFIX=%q read as %q, want %q", raw, cfg.BotDevicePrefixes, want)
		}
	}
	cfg, err := FromEnv(env(map[string]string{}))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"botplay-", "practice-bot-", "ramp-bot-"}; !slices.Equal(cfg.BotDevicePrefixes, want) {
		t.Errorf("unset reads as %q, want %q", cfg.BotDevicePrefixes, want)
	}
}
