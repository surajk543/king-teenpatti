package config

import (
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

// env is a getenv over a fixed map.
func env(vars map[string]string) func(string) string {
	return func(k string) string { return vars[k] }
}

// write puts a YAML file in a temporary directory and returns its path.
func write(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "bot.yaml")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func load(t *testing.T, body string, vars map[string]string) Config {
	t.Helper()
	c, err := Load(write(t, body), env(vars))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	return c
}

// loadErr loads and wants an error containing every one of wants.
func loadErr(t *testing.T, body string, vars map[string]string, wants ...string) {
	t.Helper()
	_, err := Load(write(t, body), env(vars))
	if err == nil {
		t.Fatalf("Load accepted:\n%s\nenv %v", body, vars)
	}
	t.Log(err)
	for _, w := range wants {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("error %q does not name %q", err, w)
		}
	}
}

func TestDefaultFillsEveryDocumentedDefault(t *testing.T) {
	c := Default()
	checks := []struct {
		name      string
		got, want any
	}{
		{"mode", c.Mode, "server"},
		{"server_url", c.ServerURL, "http://127.0.0.1:3000"},
		{"ws_url", c.WSURL, ""},
		{"seed", c.Seed, uint64(0)},
		{"bots.count", c.Bots.Count, 20},
		{"bots.device_prefix", c.Bots.DevicePrefix, "botplay-"},
		{"bots.start_index", c.Bots.StartIndex, 1},
		{"bots.start_stagger", c.Bots.StartStagger, [2]time.Duration{400 * time.Millisecond, 2500 * time.Millisecond}},
		{"bots.personality_mix", len(c.Bots.PersonalityMix), 0},
		{"session.min_duration", c.Session.MinDuration, 20 * time.Minute},
		{"session.max_duration", c.Session.MaxDuration, 2 * time.Hour},
		{"session.rest_min", c.Session.RestMin, 5 * time.Minute},
		{"session.rest_max", c.Session.RestMax, 45 * time.Minute},
		{"table.min_hands", c.Table.MinHands, 3},
		{"table.max_hands", c.Table.MaxHands, 20},
		{"table.categories", c.Table.Categories, []string{"seen", "blind", "variation"}},
		{"table.category_weights", len(c.Table.CategoryWeights), 0},
		{"table.boots_to_sit", c.Table.BootsToSit, 25.0},
		{"table.search_delay", c.Table.SearchDelay, [2]time.Duration{2500 * time.Millisecond, 8 * time.Second}},
		{"table.max_bots_per_table", c.Table.MaxBotsPerTable, 0},
		{"table.no_human_patience", c.Table.NoHumanPatience, time.Duration(0)},
		{"timing.min_reaction", c.Timing.MinReaction, 700 * time.Millisecond},
		{"timing.max_reaction", c.Timing.MaxReaction, 5 * time.Second},
		{"timing.safety_margin", c.Timing.SafetyMargin, 3 * time.Second},
		{"timing.ranges", len(c.Timing.Ranges), 0},
		{"strategy.enable_blind", c.Strategy.EnableBlind, true},
		{"strategy.enable_seen", c.Strategy.EnableSeen, true},
		{"strategy.tuning", len(c.Strategy.Tuning), 0},
		{"interaction.enable_chat", c.Interaction.EnableChat, true},
		{"interaction.enable_emotes", c.Interaction.EnableEmotes, false},
		{"interaction.probabilities", len(c.Interaction.Probabilities), 0},
		{"interaction.cooldown", c.Interaction.Cooldown, 12 * time.Second},
		{"interaction.table_gap", c.Interaction.TableGap, 6 * time.Second},
		{"interaction.table_per_min", c.Interaction.TablePerMin, 6},
		{"interaction.language", c.Interaction.Language, "mixed"},
		{"reconnect.base_delay", c.Reconnect.BaseDelay, time.Second},
		{"reconnect.max_delay", c.Reconnect.MaxDelay, 30 * time.Second},
		{"reconnect.max_attempts", c.Reconnect.MaxAttempts, 0},
		{"bankroll.collect_bonus", c.Bankroll.CollectBonus, true},
		{"bankroll.dev_replenish", c.Bankroll.DevReplenish, false},
		{"debug.addr", c.Debug.Addr, ""},
		{"debug.show_cards", c.Debug.ShowCards, false},
		{"metrics.addr", c.Metrics.Addr, ""},
		{"log.level", c.Log.Level, "info"},
		{"log.format", c.Log.Format, "json"},
	}
	for _, ch := range checks {
		if !reflect.DeepEqual(ch.got, ch.want) {
			t.Errorf("%s = %v, want %v", ch.name, ch.got, ch.want)
		}
	}
	if err := c.Validate(); err != nil {
		t.Errorf("the defaults do not validate: %v", err)
	}
	// Maps are empty, not nil, so a caller can range and index them.
	if c.Bots.PersonalityMix == nil || c.Table.CategoryWeights == nil || c.Timing.Ranges == nil ||
		c.Strategy.Tuning == nil || c.Interaction.Probabilities == nil {
		t.Error("a default map is nil")
	}
}

func TestEveryDefaultIsAFreshCopy(t *testing.T) {
	a := Default()
	a.Table.Categories[0] = "changed"
	a.Bots.PersonalityMix["CAUTIOUS"] = 5
	b := Default()
	if b.Table.Categories[0] != "seen" || len(b.Bots.PersonalityMix) != 0 {
		t.Error("changing one Default changed the next")
	}
}

func TestNoFileAndNoEnvironmentIsTheDefaults(t *testing.T) {
	for _, path := range []string{"", DefaultPath} {
		t.Chdir(t.TempDir()) // no configs/bot.yaml here
		c, err := Load(path, nil)
		if err != nil {
			t.Fatalf("Load(%q): %v", path, err)
		}
		if !reflect.DeepEqual(c, Default()) {
			t.Errorf("Load(%q) differs from Default():\n%+v", path, c)
		}
	}
}

func TestAMissingFileNamedExplicitlyIsAnError(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nope.yaml")
	_, err := Load(missing, nil)
	if err == nil || !strings.Contains(err.Error(), "nope.yaml") {
		t.Fatalf("Load(missing) = %v, want an error naming the file", err)
	}
}

func TestAnEmptyOrCommentOnlyFileIsTheDefaults(t *testing.T) {
	for _, body := range []string{"", "# nothing here\n", "---\n"} {
		c := load(t, body, nil)
		if !reflect.DeepEqual(c, Default()) {
			t.Errorf("%q is not the defaults: %+v", body, c)
		}
	}
}

// The shipped example is every key at its default, and it is COMPLETE: every
// key the schema knows appears in it once (under one of its two spellings).
func TestTheShippedExampleIsCompleteAndAtTheDefaults(t *testing.T) {
	path := filepath.Join("..", "..", "configs", "bot.yaml")
	c, err := Load(path, nil)
	if err != nil {
		t.Fatalf("configs/bot.yaml: %v", err)
	}
	if !reflect.DeepEqual(c, Default()) {
		t.Errorf("configs/bot.yaml is not the defaults:\n got  %+v\n want %+v", c, Default())
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	present := map[string]bool{}
	var walk func(prefix string, n *yaml.Node, depth int)
	walk = func(prefix string, n *yaml.Node, depth int) {
		if n.Kind != yaml.MappingNode || depth > 1 { // the free-form maps' own keys are data
			return
		}
		for i := 0; i+1 < len(n.Content); i += 2 {
			p := join(prefix, n.Content[i].Value)
			present[p] = true
			walk(p, n.Content[i+1], depth+1)
		}
	}
	walk("", doc.Content[0], 0)

	keys, alts := schemaKeys()
	alt := map[string]string{}
	for _, pair := range alts {
		alt[pair[0]], alt[pair[1]] = pair[1], pair[0]
	}
	for _, k := range keys {
		if present[k] {
			continue
		}
		if other, ok := alt[k]; ok && present[other] {
			continue
		}
		t.Errorf("configs/bot.yaml lacks %s", k)
	}
	for k := range present {
		if !slices.Contains(keys, k) {
			t.Errorf("configs/bot.yaml has %s, which the schema does not know", k)
		}
	}
}

func TestIntegerUnitKeys(t *testing.T) {
	c := load(t, `
session:
  min_duration_minutes: 30
  max_duration_minutes: 90
  rest_min_minutes: 1
  rest_max_minutes: 2
table:
  min_hands: 4
  max_hands: 12
  search_delay_ms: [100, 200]
  no_human_patience_seconds: 300
timing:
  min_reaction_ms: 800
  max_reaction_ms: 4000
  safety_margin_ms: 2500
interaction:
  cooldown_seconds: 20
  table_gap_seconds: 9
reconnect:
  base_delay_ms: 500
  max_delay_seconds: 45
bots:
  start_stagger_ms: [0, 1000]
`, nil)
	for name, got := range map[string][2]time.Duration{
		"session":        {c.Session.MinDuration, c.Session.MaxDuration},
		"rest":           {c.Session.RestMin, c.Session.RestMax},
		"search_delay":   c.Table.SearchDelay,
		"reaction":       {c.Timing.MinReaction, c.Timing.MaxReaction},
		"interaction":    {c.Interaction.Cooldown, c.Interaction.TableGap},
		"reconnect":      {c.Reconnect.BaseDelay, c.Reconnect.MaxDelay},
		"start_stagger":  c.Bots.StartStagger,
		"patience+guard": {c.Table.NoHumanPatience, c.Timing.SafetyMargin},
	} {
		want := map[string][2]time.Duration{
			"session":        {30 * time.Minute, 90 * time.Minute},
			"rest":           {time.Minute, 2 * time.Minute},
			"search_delay":   {100 * time.Millisecond, 200 * time.Millisecond},
			"reaction":       {800 * time.Millisecond, 4 * time.Second},
			"interaction":    {20 * time.Second, 9 * time.Second},
			"reconnect":      {500 * time.Millisecond, 45 * time.Second},
			"start_stagger":  {0, time.Second},
			"patience+guard": {5 * time.Minute, 2500 * time.Millisecond},
		}[name]
		if got != want {
			t.Errorf("%s = %v, want %v", name, got, want)
		}
	}
	if c.Table.MinHands != 4 || c.Table.MaxHands != 12 {
		t.Errorf("hands = %d..%d", c.Table.MinHands, c.Table.MaxHands)
	}
}

func TestDurationStrings(t *testing.T) {
	c := load(t, `
session:
  min_duration: 45m
  max_duration: 1h30m
  rest_min: 0
  rest_max: "10m"
table:
  search_delay: ["1.5s", "3s"]
  no_human_patience: 2m
timing:
  min_reaction: 650ms
  max_reaction: 4.5s
  safety_margin: 2s
interaction:
  cooldown: 15s
  table_gap: 7s
reconnect:
  base_delay: 250ms
  max_delay: 1m
bots:
  start_stagger: [100ms, 2s]
`, nil)
	got := []time.Duration{
		c.Session.MinDuration, c.Session.MaxDuration, c.Session.RestMin, c.Session.RestMax,
		c.Table.SearchDelay[0], c.Table.SearchDelay[1], c.Table.NoHumanPatience,
		c.Timing.MinReaction, c.Timing.MaxReaction, c.Timing.SafetyMargin,
		c.Interaction.Cooldown, c.Interaction.TableGap, c.Reconnect.BaseDelay, c.Reconnect.MaxDelay,
		c.Bots.StartStagger[0], c.Bots.StartStagger[1],
	}
	want := []time.Duration{
		45 * time.Minute, 90 * time.Minute, 0, 10 * time.Minute,
		1500 * time.Millisecond, 3 * time.Second, 2 * time.Minute,
		650 * time.Millisecond, 4500 * time.Millisecond, 2 * time.Second,
		15 * time.Second, 7 * time.Second, 250 * time.Millisecond, time.Minute,
		100 * time.Millisecond, 2 * time.Second,
	}
	if !slices.Equal(got, want) {
		t.Errorf("durations\n got  %v\n want %v", got, want)
	}
}

func TestEveryOtherKey(t *testing.T) {
	c := load(t, `
mode: simulation
server_url: https://prod.example.com/
ws_url: wss://prod.example.com/socket.io/
seed: 99
bots:
  count: 7
  device_prefix: botplay-test-
  start_index: 100
  personality_mix: {cautious: 2, AGGRESSIVE: 1.5}
table:
  categories: [blind, variation]
  category_weights: {Blind: 3, variation: 1}
  boots_to_sit: 12.5
  max_bots_per_table: 2
timing:
  ranges: {Chaal: [900, 3500], look_early: [0, 10]}
strategy:
  enable_blind: false
  tuning: {aggressive: {Blind_Rate: [0.4, 0.6]}}
interaction:
  enable_chat: false
  enable_emotes: true
  probabilities: {win: [0.1, 0.3]}
  table_per_min: 3
  language: English
reconnect:
  max_attempts: 5
bankroll:
  collect_bonus: false
  dev_replenish: true
debug:
  addr: 127.0.0.1:9101
  show_cards: true
metrics:
  addr: 0.0.0.0:9100
log:
  level: DEBUG
  format: text
`, nil)
	if c.Mode != "simulation" || c.ServerURL != "https://prod.example.com" || c.WSURL != "wss://prod.example.com/socket.io/" || c.Seed != 99 {
		t.Errorf("top level: %q %q %q %d", c.Mode, c.ServerURL, c.WSURL, c.Seed)
	}
	if c.Bots.Count != 7 || c.Bots.DevicePrefix != "botplay-test-" || c.Bots.StartIndex != 100 {
		t.Errorf("bots: %+v", c.Bots)
	}
	if !reflect.DeepEqual(c.Bots.PersonalityMix, map[string]float64{"CAUTIOUS": 2, "AGGRESSIVE": 1.5}) {
		t.Errorf("personality_mix = %v (families are upper-cased)", c.Bots.PersonalityMix)
	}
	if !slices.Equal(c.Table.Categories, []string{"blind", "variation"}) ||
		!reflect.DeepEqual(c.Table.CategoryWeights, map[string]float64{"blind": 3, "variation": 1}) ||
		c.Table.BootsToSit != 12.5 || c.Table.MaxBotsPerTable != 2 {
		t.Errorf("table: %+v", c.Table)
	}
	if !reflect.DeepEqual(c.Timing.Ranges, map[string][2]int{"chaal": {900, 3500}, "look_early": {0, 10}}) {
		t.Errorf("ranges = %v", c.Timing.Ranges)
	}
	if c.Strategy.EnableBlind || !c.Strategy.EnableSeen ||
		!reflect.DeepEqual(c.Strategy.Tuning, map[string]map[string][2]float64{"AGGRESSIVE": {"blind_rate": {0.4, 0.6}}}) {
		t.Errorf("strategy: %+v", c.Strategy)
	}
	in := c.Interaction
	if in.EnableChat || !in.EnableEmotes || in.TablePerMin != 3 || in.Language != "english" ||
		!reflect.DeepEqual(in.Probabilities, map[string][2]float64{"win": {0.1, 0.3}}) {
		t.Errorf("interaction: %+v", in)
	}
	if c.Reconnect.MaxAttempts != 5 || c.Bankroll.CollectBonus || !c.Bankroll.DevReplenish {
		t.Errorf("reconnect/bankroll: %+v %+v", c.Reconnect, c.Bankroll)
	}
	if c.Debug.Addr != "127.0.0.1:9101" || !c.Debug.ShowCards || c.Metrics.Addr != "0.0.0.0:9100" ||
		c.Log.Level != "debug" || c.Log.Format != "text" {
		t.Errorf("debug/metrics/log: %+v %+v %+v", c.Debug, c.Metrics, c.Log)
	}
}

func TestEmptyValuesAreEmptyWhereThatMeansSomething(t *testing.T) {
	c := load(t, `
ws_url:
bots:
  personality_mix:
debug:
`, nil)
	if c.WSURL != "" || len(c.Bots.PersonalityMix) != 0 || c.Debug.Addr != "" {
		t.Errorf("%+v", c)
	}
	loadErr(t, "bots:\n  count:\n", nil, "bots.count (line 2)", "whole number")
	loadErr(t, "table:\n  categories:\n", nil, "table.categories", "empty")
}

func TestUnknownKeysAreRefusedByName(t *testing.T) {
	loadErr(t, "bots:\n  cout: 3\n", nil, "bots.cout (line 2)", "unknown key", "count")
	loadErr(t, "sesion:\n  min_duration: 5m\n", nil, "sesion (line 1)", "unknown key", "the top level")
	loadErr(t, "log:\n  level: info\n  colour: true\n", nil, "log.colour (line 3)")
	loadErr(t, "bots: {count: 3, count: 4}\n", nil, "bots.count", "twice")
}

func TestTwoSpellingsOfOneSettingAreRefused(t *testing.T) {
	loadErr(t, "session:\n  min_duration: 20m\n  min_duration_minutes: 20\n", nil,
		"session.min_duration (line 2)", "session.min_duration_minutes (line 3)", "same setting")
	loadErr(t, "reconnect:\n  max_delay: 30s\n  max_delay_seconds: 30\n", nil, "reconnect.max_delay", "max_delay_seconds")
}

func TestWrongTypesAreRefusedNamingTheKey(t *testing.T) {
	cases := []struct{ body, want string }{
		{"bots:\n  count: \"20\"\n", "bots.count (line 2): must be a whole number, not the text \"20\""},
		{"table:\n  min_hands: 3.5\n", "table.min_hands (line 2): must be a whole number, not the number 3.5"},
		{"strategy:\n  enable_blind: yes\n", "strategy.enable_blind (line 2): must be true or false"},
		{"strategy:\n  enable_seen: 1\n", "strategy.enable_seen (line 2): must be true or false"},
		{"session:\n  min_duration: 20\n", "session.min_duration (line 2): 20 has no unit"},
		{"session:\n  min_duration: twenty\n", "session.min_duration (line 2): \"twenty\" is not a duration"},
		{"session:\n  min_duration_minutes: 20m\n", "session.min_duration_minutes (line 2): must be a whole number of minutes"},
		{"timing:\n  min_reaction_ms: -5\n", "timing.min_reaction_ms (line 2)"},
		{"seed: -1\n", "seed (line 1)"},
		{"seed: 1.5\n", "seed (line 1): must be a whole number"},
		{"mode: 3\n", "mode (line 1): must be text"},
		{"bots:\n  start_stagger: [1s]\n", "bots.start_stagger (line 2): must be a list of two values"},
		{"bots:\n  start_stagger_ms: [1, 2.5]\n", "bots.start_stagger_ms[1] (line 2)"},
		{"table:\n  categories: seen\n", "table.categories (line 2): must be a list"},
		{"table:\n  boots_to_sit: .nan\n", "table.boots_to_sit (line 2)"},
		{"bots:\n  personality_mix: {CAUTIOUS: lots}\n", "bots.personality_mix.CAUTIOUS (line 2)"},
		{"bots:\n  personality_mix: {cautious: 1, CAUTIOUS: 2}\n", "bots.personality_mix.CAUTIOUS (line 2): is given twice"},
		{"timing:\n  ranges: {chaal: [900, 3.5]}\n", "timing.ranges.chaal[1] (line 2)"},
		{"strategy:\n  tuning: {LOOSE: [1, 2]}\n", "strategy.tuning.LOOSE (line 2)"},
		{"bots: 5\n", "bots (line 1): must be a mapping"},
		{"- a\n- b\n", "the file (line 1): must be a mapping"},
		{"mode: server\n---\nmode: simulation\n", "second YAML document"},
	}
	for _, tc := range cases {
		loadErr(t, tc.body, nil, tc.want)
	}
}

func TestTheEnvironmentOverridesTheFile(t *testing.T) {
	c := load(t, `
mode: server
bots:
  count: 5
table:
  categories: [seen]
`, map[string]string{
		"BOT_MODE":                        "simulation",
		"SERVER_URL":                      "https://preprod.example.com",
		"WS_URL":                          "wss://ws.example.com/socket.io/",
		"BOT_SEED":                        "18446744073709551615",
		"BOT_COUNT":                       " 250 ",
		"BOT_DEVICE_PREFIX":               "botplay-load-",
		"BOT_START_INDEX":                 "1001",
		"BOT_MIN_HANDS":                   "2",
		"BOT_MAX_HANDS":                   "9",
		"BOT_SESSION_MIN_MINUTES":         "10",
		"BOT_SESSION_MAX_MINUTES":         "60",
		"BOT_CATEGORIES":                  " blind, ,variation ",
		"BOT_ENABLE_CHAT":                 "off",
		"BOT_DEBUG_ADDR":                  "[::1]:9101",
		"BOT_DEBUG_SHOW_CARDS":            "TRUE",
		"BOT_METRICS_ADDR":                ":9100",
		"LOG_LEVEL":                       "warn",
		"LOG_FORMAT":                      "text",
		"BOT_RECONNECT_MAX_DELAY_SECONDS": "90",
		"BOT_DEV_REPLENISH":               "1",
	})
	if c.Mode != "simulation" || c.ServerURL != "https://preprod.example.com" || c.WSURL != "wss://ws.example.com/socket.io/" ||
		c.Seed != 18446744073709551615 {
		t.Errorf("top: %q %q %q %d", c.Mode, c.ServerURL, c.WSURL, c.Seed)
	}
	if c.Bots.Count != 250 || c.Bots.DevicePrefix != "botplay-load-" || c.Bots.StartIndex != 1001 {
		t.Errorf("bots: %+v", c.Bots)
	}
	if c.Table.MinHands != 2 || c.Table.MaxHands != 9 || !slices.Equal(c.Table.Categories, []string{"blind", "variation"}) {
		t.Errorf("table: %+v", c.Table)
	}
	if c.Session.MinDuration != 10*time.Minute || c.Session.MaxDuration != time.Hour {
		t.Errorf("session: %+v", c.Session)
	}
	if c.Interaction.EnableChat || c.Debug.Addr != "[::1]:9101" || !c.Debug.ShowCards || c.Metrics.Addr != ":9100" {
		t.Errorf("chat/debug/metrics: %v %+v %+v", c.Interaction.EnableChat, c.Debug, c.Metrics)
	}
	if c.Log.Level != "warn" || c.Log.Format != "text" || c.Reconnect.MaxDelay != 90*time.Second || !c.Bankroll.DevReplenish {
		t.Errorf("log/reconnect/bankroll: %+v %v %v", c.Log, c.Reconnect.MaxDelay, c.Bankroll.DevReplenish)
	}
}

func TestAnEmptyVariableIsUnset(t *testing.T) {
	c := load(t, "bots:\n  count: 5\n", map[string]string{"BOT_COUNT": "", "BOT_CATEGORIES": ""})
	if c.Bots.Count != 5 || len(c.Table.Categories) != 3 {
		t.Errorf("empty variables changed the configuration: %d %v", c.Bots.Count, c.Table.Categories)
	}
}

func TestEveryEnvironmentVariableIsRead(t *testing.T) {
	// Each variable, set to garbage on its own, must be noticed: either
	// refused by name, or change the configuration.
	for _, key := range EnvKeys {
		_, err := Load("", env(map[string]string{key: "\x01garbage"}))
		if err == nil || !strings.Contains(err.Error(), key) {
			// A text variable reads garbage as its value; Validate then names
			// the key's (VAR) — every text key's message carries its variable.
			t.Errorf("%s=garbage: %v, want an error naming %s", key, err, key)
		}
	}
}

func TestBadEnvironmentValuesAreRefusedNamingTheVariable(t *testing.T) {
	cases := map[string]string{
		"BOT_COUNT":                       "twenty",
		"BOT_SEED":                        "-1",
		"BOT_START_INDEX":                 "1.5",
		"BOT_MIN_HANDS":                   "3 hands",
		"BOT_MAX_HANDS":                   "0x10",
		"BOT_SESSION_MIN_MINUTES":         "20m",
		"BOT_SESSION_MAX_MINUTES":         "-5",
		"BOT_ENABLE_CHAT":                 "maybe",
		"BOT_DEBUG_SHOW_CARDS":            "sure",
		"BOT_DEV_REPLENISH":               "2",
		"BOT_RECONNECT_MAX_DELAY_SECONDS": "30s",
	}
	for key, raw := range cases {
		_, err := Load("", env(map[string]string{key: raw}))
		if err == nil || !strings.Contains(err.Error(), key+"=") {
			t.Errorf("%s=%q: %v, want an error naming %s", key, raw, err, key)
		}
	}
}

func TestValidation(t *testing.T) {
	cases := []struct {
		name string
		body string
		vars map[string]string
		want []string
	}{
		{"mode", "mode: live\n", nil, []string{"mode (BOT_MODE)", `"live"`}},
		{"too many bots", "", map[string]string{"BOT_COUNT": "10001"}, []string{"bots.count (BOT_COUNT)", "10000"}},
		{"negative bots", "bots:\n  count: -1\n", nil, []string{"bots.count"}},
		{"prefix", "bots:\n  device_prefix: bot-\n", nil, []string{"bots.device_prefix", "botplay-", "is_bot"}},
		{"prefix charset", "bots:\n  device_prefix: botplay-a/b\n", nil, []string{"bots.device_prefix", "letters"}},
		{"index past six digits", "", map[string]string{"BOT_START_INDEX": "999990", "BOT_COUNT": "20"}, []string{"bots.start_index", "999999"}},
		{"stagger", "bots:\n  start_stagger: [3s, 1s]\n", nil, []string{"bots.start_stagger"}},
		{"unknown family", "bots:\n  personality_mix: {careful: 1}\n", nil, []string{"bots.personality_mix.CAREFUL", "CAUTIOUS"}},
		{"negative weight", "bots:\n  personality_mix: {LOOSE: -1}\n", nil, []string{"bots.personality_mix.LOOSE"}},
		{"all-zero weights", "bots:\n  personality_mix: {LOOSE: 0}\n", nil, []string{"bots.personality_mix", "every weight is 0"}},
		{"session", "", map[string]string{"BOT_SESSION_MIN_MINUTES": "60", "BOT_SESSION_MAX_MINUTES": "30"}, []string{"session.max_duration (BOT_SESSION_MAX_MINUTES)"}},
		{"zero session", "session:\n  min_duration: 0s\n", nil, []string{"session.min_duration"}},
		{"rest", "session:\n  rest_min: 10m\n  rest_max: 5m\n", nil, []string{"session.rest_max"}},
		{"hands", "", map[string]string{"BOT_MIN_HANDS": "8", "BOT_MAX_HANDS": "4"}, []string{"table.max_hands (BOT_MAX_HANDS)"}},
		{"no hands", "table:\n  min_hands: 0\n", nil, []string{"table.min_hands"}},
		{"category", "", map[string]string{"BOT_CATEGORIES": "seen,texas_holdem"}, []string{"table.categories (BOT_CATEGORIES)", "texas_holdem"}},
		{"category twice", "table:\n  categories: [seen, Seen]\n", nil, []string{"table.categories", "twice"}},
		{"no categories", "", map[string]string{"BOT_CATEGORIES": " , "}, []string{"table.categories", "empty"}},
		{"category weight", "table:\n  category_weights: {poker: 1}\n", nil, []string{"table.category_weights.poker"}},
		{"boots", "table:\n  boots_to_sit: 0\n", nil, []string{"table.boots_to_sit"}},
		{"search delay", "table:\n  search_delay_ms: [9000, 8000]\n", nil, []string{"table.search_delay"}},
		{"max bots", "table:\n  max_bots_per_table: -1\n", nil, []string{"table.max_bots_per_table"}},
		{"patience", "table:\n  no_human_patience: -1s\n", nil, []string{"table.no_human_patience"}},
		{"reaction", "timing:\n  min_reaction_ms: 6000\n", nil, []string{"timing.max_reaction", "timing.min_reaction"}},
		{"safety", "timing:\n  safety_margin: -1s\n", nil, []string{"timing.safety_margin"}},
		{"timing kind", "timing:\n  ranges: {chal: [1, 2]}\n", nil, []string{"timing.ranges.chal", "chaal"}},
		{"timing range", "timing:\n  ranges: {chaal: [2, 1]}\n", nil, []string{"timing.ranges.chaal"}},
		{"blind and seen", "strategy:\n  enable_blind: false\n  enable_seen: false\n", nil, []string{"strategy.enable_blind", "strategy.enable_seen"}},
		{"tuning family", "strategy:\n  tuning: {CRAZY: {tightness: [0, 1]}}\n", nil, []string{"strategy.tuning.CRAZY"}},
		{"tuning range", "strategy:\n  tuning: {LOOSE: {tightness: [0.9, 0.1]}}\n", nil, []string{"strategy.tuning.LOOSE.tightness"}},
		{"moment", "interaction:\n  probabilities: {victory: [0, 1]}\n", nil, []string{"interaction.probabilities.victory"}},
		{"probability", "interaction:\n  probabilities: {win: [0.5, 1.5]}\n", nil, []string{"interaction.probabilities.win"}},
		{"language", "interaction:\n  language: french\n", nil, []string{"interaction.language"}},
		{"table per min", "interaction:\n  table_per_min: -1\n", nil, []string{"interaction.table_per_min"}},
		{"cooldown", "interaction:\n  cooldown: -1s\n", nil, []string{"interaction.cooldown"}},
		{"reconnect", "reconnect:\n  base_delay: 1m\n", map[string]string{"BOT_RECONNECT_MAX_DELAY_SECONDS": "30"}, []string{"reconnect.max_delay (BOT_RECONNECT_MAX_DELAY_SECONDS)"}},
		{"reconnect base", "reconnect:\n  base_delay: 0s\n", nil, []string{"reconnect.base_delay"}},
		{"attempts", "reconnect:\n  max_attempts: -1\n", nil, []string{"reconnect.max_attempts"}},
		{"server url scheme", "", map[string]string{"SERVER_URL": "ftp://example.com"}, []string{"server_url (SERVER_URL)", "http"}},
		{"server url host", "server_url: http://\n", nil, []string{"server_url", "host"}},
		{"server url credentials", "server_url: http://a:b@example.com\n", nil, []string{"server_url", "credentials"}},
		{"ws url", "", map[string]string{"WS_URL": "http://example.com"}, []string{"ws_url (WS_URL)", "ws"}},
		{"replenish in server mode", "", map[string]string{"BOT_DEV_REPLENISH": "true"}, []string{"bankroll.dev_replenish (BOT_DEV_REPLENISH)", "simulation"}},
		{"debug addr", "", map[string]string{"BOT_DEBUG_ADDR": "9101"}, []string{"debug.addr (BOT_DEBUG_ADDR)", "host:port"}},
		{"debug public", "", map[string]string{"BOT_DEBUG_ADDR": "0.0.0.0:9101"}, []string{"debug.addr (BOT_DEBUG_ADDR)", "loopback"}},
		{"debug every interface", "debug:\n  addr: :9101\n", nil, []string{"debug.addr", "loopback"}},
		{"metrics addr", "", map[string]string{"BOT_METRICS_ADDR": "localhost:port"}, []string{"metrics.addr (BOT_METRICS_ADDR)"}},
		{"log level", "", map[string]string{"LOG_LEVEL": "verbose"}, []string{"log.level (LOG_LEVEL)"}},
		{"log format", "", map[string]string{"LOG_FORMAT": "xml"}, []string{"log.format (LOG_FORMAT)"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) { loadErr(t, tc.body, tc.vars, tc.want...) })
	}
}

func TestDevReplenishIsAllowedInSimulation(t *testing.T) {
	c := load(t, "mode: simulation\nbankroll:\n  dev_replenish: true\n", nil)
	if !c.Bankroll.DevReplenish {
		t.Error("dev_replenish was not kept in simulation mode")
	}
}

func TestASimulationWithNoSeedIsRepeatable(t *testing.T) {
	c := load(t, "mode: simulation\n", nil)
	if c.Seed != SimulationSeed || SimulationSeed != 12345 {
		t.Errorf("simulation seed = %d, want 12345", c.Seed)
	}
	c = load(t, "mode: simulation\nseed: 7\n", nil)
	if c.Seed != 7 {
		t.Errorf("an explicit simulation seed became %d", c.Seed)
	}
	c = load(t, "", nil)
	if c.Seed != 0 {
		t.Errorf("a server-mode seed of 0 became %d (0 means from the clock there)", c.Seed)
	}
	c = load(t, "", map[string]string{"BOT_MODE": "Simulation"})
	if c.Mode != ModeSimulation || c.Seed != SimulationSeed {
		t.Errorf("BOT_MODE=Simulation → mode %q seed %d", c.Mode, c.Seed)
	}
}

func TestLoopbackDebugAddresses(t *testing.T) {
	for _, addr := range []string{"127.0.0.1:9101", "127.0.0.2:0", "[::1]:9101", "localhost:9101", "LOCALHOST:1"} {
		if _, err := Load("", env(map[string]string{"BOT_DEBUG_ADDR": addr})); err != nil {
			t.Errorf("%s: %v", addr, err)
		}
	}
}

func TestYAMLAnchorsAreFollowed(t *testing.T) {
	c := load(t, `
timing:
  ranges:
    chaal: &quick [900, 3500]
    fold: *quick
`, nil)
	if c.Timing.Ranges["fold"] != [2]int{900, 3500} {
		t.Errorf("ranges = %v", c.Timing.Ranges)
	}
}
