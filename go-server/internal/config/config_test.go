package config

import (
	"bufio"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// env builds a Lookup over a map; a key absent from the map is unset.
func env(m map[string]string) Lookup {
	return func(key string) (string, bool) {
		v, ok := m[key]
		return v, ok
	}
}

func mustLoad(t *testing.T, m map[string]string) *Config {
	t.Helper()
	cfg, err := FromEnv(env(m))
	if err != nil {
		t.Fatalf("FromEnv(%v): %v", m, err)
	}
	return cfg
}

func TestDefaultsMatchNode(t *testing.T) {
	// Every value in server/src/config/index.js and CLAUDE.md §7.4.
	cfg := Defaults()
	want := map[string]any{
		"Env": "development", "Port": 3000, "Host": "0.0.0.0", "AllowAnyOrigin": true,
		"JWT.Secret": "dev-only-insecure-secret", "JWT.ExpiresIn": 30 * 24 * time.Hour,
		"Facebook.AppID": "", "Facebook.AppSecret": "", "AllowFakeProviders": false,
		"DB.URL": "postgres://postgres:postgres@localhost:5432/gameplay", "DB.Schema": "public", "DB.PoolMax": 10,
		"Game.WelcomeChips": int64(200000), "Game.BootAmount": int64(200),
		"Game.TableStakes": []int64{200, 5000},
		"Game.LobbyTables": []LobbyTable{{"seen", 200}, {"blind", 200}, {"blind", 5000}},
		"Game.MaxPlayers":  5, "Game.MinPlayers": 2, "Game.TurnTimeout": 25 * time.Second,
		"Game.MaxBetRounds": 20, "Game.PotLimitMultiplier": int64(1024), "Game.MaxRaiseSteps": 8,
		"Game.SeenMaxRaiseSteps": 2, "Game.SeenMaxBetRounds": 7, "Game.SeenMaxPot": int64(1200000),
		"Game.BlindMaxRaiseSteps": 0, "Game.BlindMaxBetRounds": 0, "Game.BlindPotLimitMultiplier": int64(0),
		"Game.MaxBlindMoves": 4,
		"Game.EntryCapBoot":  int64(200), "Game.EntryCapCategory": "blind", "Game.EntryCapMaxChips": int64(500000),
		"Game.MaxMissedTurns": 3, "Game.SideshowTimeout": 6 * time.Second, "Game.SideshowMinPlayers": 3,
		"Game.DisplayNameMaxLength": 24,
		"Game.PrivateMaxPot":        int64(500000), "Game.PrivateMaxRaiseSteps": 2, "Game.PrivateBoot": int64(200),
		"Game.NextHandDelay": 4 * time.Second, "Game.ConsolidateInterval": 15 * time.Second,
		"Game.ReconnectGrace": 60 * time.Second, "Game.ResumeOffer": 10 * time.Minute,
		"Metrics.Enabled": true, "Metrics.Path": "/metrics", "Metrics.Prefix": "game_server_", "Metrics.Token": "",
		"Chat.MaxHistory": 100, "Chat.MaxLength": 140, "Chat.RateLimit": 5, "Chat.RateWindow": 5 * time.Second,
		"LogLevel": "info", "PublicDir": "./public", "RedisURL": "",
	}
	for path, expected := range want {
		if got := field(t, cfg, path); !reflect.DeepEqual(got, expected) {
			t.Errorf("Defaults().%s = %#v, want %#v", path, got, expected)
		}
	}
	if len(cfg.CORSOrigin) != 0 || len(cfg.Google.ClientIDs) != 0 || len(cfg.Metrics.AllowIP) != 0 {
		t.Errorf("default lists must be empty: cors=%v google=%v ips=%v", cfg.CORSOrigin, cfg.Google.ClientIDs, cfg.Metrics.AllowIP)
	}
	// An empty environment yields exactly the defaults.
	if got := mustLoad(t, nil); !reflect.DeepEqual(got, cfg) {
		t.Errorf("FromEnv(empty) differs from Defaults():\n got %+v\nwant %+v", got, cfg)
	}
}

// field walks "Game.MaxPlayers"-style paths by reflection.
func field(t *testing.T, cfg *Config, path string) any {
	t.Helper()
	v := reflect.ValueOf(cfg).Elem()
	for _, part := range strings.Split(path, ".") {
		v = v.FieldByName(part)
		if !v.IsValid() {
			t.Fatalf("no field %s", path)
		}
	}
	return v.Interface()
}

// TestEveryKey is the table: one row per env key with a value that differs
// from the default, and the field it must land in.
func TestEveryKey(t *testing.T) {
	rows := []struct {
		key, value, path string
		want             any
	}{
		{"NODE_ENV", "test", "Env", "test"},
		{"PORT", "0", "Port", 0},
		{"PORT", " 8080 ", "Port", 8080},
		{"HOST", "127.0.0.1", "Host", "127.0.0.1"},
		{"JWT_SECRET", "s3cret", "JWT.Secret", "s3cret"},
		{"JWT_SECRET", "", "JWT.Secret", ""}, // `?? default` keeps a set-but-empty string
		{"JWT_EXPIRES_IN", "12h", "JWT.ExpiresIn", 12 * time.Hour},
		{"JWT_EXPIRES_IN", "3600", "JWT.ExpiresIn", 3600 * time.Millisecond}, // ms grammar: bare number = milliseconds
		{"GOOGLE_CLIENT_IDS", "a.apps, b.apps,,", "Google.ClientIDs", []string{"a.apps", "b.apps"}},
		{"FACEBOOK_APP_ID", "123", "Facebook.AppID", "123"},
		{"FACEBOOK_APP_SECRET", "shh", "Facebook.AppSecret", "shh"},
		{"AUTH_ALLOW_FAKE_PROVIDERS", "true", "AllowFakeProviders", true},
		{"AUTH_ALLOW_FAKE_PROVIDERS", "YES", "AllowFakeProviders", true},
		{"AUTH_ALLOW_FAKE_PROVIDERS", "on", "AllowFakeProviders", true},
		{"AUTH_ALLOW_FAKE_PROVIDERS", "1", "AllowFakeProviders", true},
		{"AUTH_ALLOW_FAKE_PROVIDERS", "0", "AllowFakeProviders", false},
		{"AUTH_ALLOW_FAKE_PROVIDERS", "garbage", "AllowFakeProviders", false},
		{"AUTH_ALLOW_FAKE_PROVIDERS", "", "AllowFakeProviders", false},
		{"DATABASE_URL", "postgres://u:p@h:1/d", "DB.URL", "postgres://u:p@h:1/d"},
		{"PG_SCHEMA", "test_auth_ab12", "DB.Schema", "test_auth_ab12"},
		{"PG_POOL_MAX", "3", "DB.PoolMax", 3},
		{"PG_STATEMENT_TIMEOUT_MS", "2500", "DB.StatementTimeoutMs", 2500},
		{"WELCOME_CHIPS", "1000", "Game.WelcomeChips", int64(1000)},
		{"BOOT_AMOUNT", "100", "Game.BootAmount", int64(100)},
		{"TABLE_STAKES", "", "Game.TableStakes", []int64{}},
		{"TABLE_STAKES", "100, 200,0,-3,200", "Game.TableStakes", []int64{100, 200, 200}},
		{"LOBBY_TABLES", "", "Game.LobbyTables", []LobbyTable{}},
		{"LOBBY_TABLES", " blind : 5000 ,seen:100", "Game.LobbyTables", []LobbyTable{{"blind", 5000}, {"seen", 100}}},
		{"LOBBY_TABLES", "seen:0", "Game.LobbyTables", []LobbyTable{{"seen", 0}}},
		{"MAX_PLAYERS_PER_ROOM", "3", "Game.MaxPlayers", 3},
		{"MIN_PLAYERS_TO_START", "3", "Game.MinPlayers", 3},
		{"TURN_TIMEOUT_MS", "500", "Game.TurnTimeout", 500 * time.Millisecond},
		{"MAX_BET_ROUNDS", "3", "Game.MaxBetRounds", 3},
		{"POT_LIMIT_MULTIPLIER", "16", "Game.PotLimitMultiplier", int64(16)},
		{"MAX_RAISE_STEPS", "4", "Game.MaxRaiseSteps", 4},
		{"SEEN_MAX_RAISE_STEPS", "3", "Game.SeenMaxRaiseSteps", 3},
		{"SEEN_MAX_BET_ROUNDS", "10", "Game.SeenMaxBetRounds", 10},
		{"SEEN_MAX_POT", "0", "Game.SeenMaxPot", int64(0)},
		{"BLIND_MAX_RAISE_STEPS", "5", "Game.BlindMaxRaiseSteps", 5},
		{"BLIND_MAX_BET_ROUNDS", "9", "Game.BlindMaxBetRounds", 9},
		{"BLIND_POT_LIMIT_MULTIPLIER", "64", "Game.BlindPotLimitMultiplier", int64(64)},
		{"MAX_BLIND_MOVES", "2", "Game.MaxBlindMoves", 2},
		{"ENTRY_CAP_BOOT", "5000", "Game.EntryCapBoot", int64(5000)},
		{"ENTRY_CAP_CATEGORY", "seen", "Game.EntryCapCategory", "seen"},
		{"ENTRY_CAP_MAX_CHIPS", "0", "Game.EntryCapMaxChips", int64(0)},
		{"MAX_MISSED_TURNS", "1", "Game.MaxMissedTurns", 1},
		{"SIDESHOW_TIMEOUT_MS", "250", "Game.SideshowTimeout", 250 * time.Millisecond},
		{"SIDESHOW_MIN_PLAYERS", "2", "Game.SideshowMinPlayers", 2},
		{"DISPLAY_NAME_MAX", "12", "Game.DisplayNameMaxLength", 12},
		{"PRIVATE_MAX_POT", "1000", "Game.PrivateMaxPot", int64(1000)},
		{"PRIVATE_MAX_RAISE_STEPS", "1", "Game.PrivateMaxRaiseSteps", 1},
		{"PRIVATE_BOOT", "50", "Game.PrivateBoot", int64(50)},
		{"NEXT_HAND_DELAY_MS", "10", "Game.NextHandDelay", 10 * time.Millisecond},
		{"CONSOLIDATE_INTERVAL_MS", "40", "Game.ConsolidateInterval", 40 * time.Millisecond},
		{"RECONNECT_GRACE_MS", "150", "Game.ReconnectGrace", 150 * time.Millisecond},
		{"RESUME_OFFER_MS", "0", "Game.ResumeOffer", time.Duration(0)},
		{"METRICS_ENABLED", "false", "Metrics.Enabled", false},
		{"METRICS_ENABLED", "FALSE", "Metrics.Enabled", true}, // only the exact string "false" disables
		{"METRICS_ENABLED", "0", "Metrics.Enabled", true},
		{"METRICS_ENABLED", "", "Metrics.Enabled", true},
		{"METRICS_PATH", "/m", "Metrics.Path", "/m"},
		{"METRICS_PREFIX", "tp_", "Metrics.Prefix", "tp_"},
		{"METRICS_TOKEN", "tok", "Metrics.Token", "tok"},
		{"METRICS_ALLOW_IPS", "10.0.0.1, ::1", "Metrics.AllowIP", []string{"10.0.0.1", "::1"}},
		{"CHAT_MAX_HISTORY", "5", "Chat.MaxHistory", 5},
		{"CHAT_MAX_LENGTH", "20", "Chat.MaxLength", 20},
		{"CHAT_RATE_LIMIT", "2", "Chat.RateLimit", 2},
		{"CHAT_RATE_WINDOW_MS", "999", "Chat.RateWindow", 999 * time.Millisecond},
		{"LOG_LEVEL", "debug", "LogLevel", "debug"},
		{"PUBLIC_DIR", "/srv/public", "PublicDir", "/srv/public"},
		{"REDIS_URL", "redis://localhost", "RedisURL", "redis://localhost"},
	}
	for _, row := range rows {
		t.Run(row.key+"="+row.value, func(t *testing.T) {
			cfg := mustLoad(t, map[string]string{row.key: row.value})
			if got := field(t, cfg, row.path); !reflect.DeepEqual(got, row.want) {
				t.Errorf("%s=%q → %s = %#v, want %#v", row.key, row.value, row.path, got, row.want)
			}
		})
	}
}

func TestEmptyIntegerKeepsDefault(t *testing.T) {
	// Node: Number.parseInt('') is NaN → fallback. `PORT=` in a .env is harmless.
	cfg := mustLoad(t, map[string]string{"PORT": "", "TURN_TIMEOUT_MS": "", "WELCOME_CHIPS": ""})
	if cfg.Port != 3000 || cfg.Game.TurnTimeout != 25*time.Second || cfg.Game.WelcomeChips != 200000 {
		t.Errorf("empty integers must keep defaults: %+v", cfg)
	}
}

func TestMalformedIntegersFailStartup(t *testing.T) {
	// DECISIONS.md §5: strict decimal integers. Node would have read "12abc"
	// as 12, "1e3" as 1 and "abc" as the default without a word.
	for _, bad := range []map[string]string{
		{"PORT": "abc"},
		{"TURN_TIMEOUT_MS": "12abc"},
		{"WELCOME_CHIPS": "1e3"},
		{"PG_POOL_MAX": "10.5"},
		{"MAX_PLAYERS_PER_ROOM": "0x10"},
		{"TABLE_STAKES": "200,abc"},
		{"TABLE_STAKES": "200.5"},
		{"LOBBY_TABLES": "seen:abc"},
		{"LOBBY_TABLES": "seen"},
		{"LOBBY_TABLES": ":200"},
		{"LOBBY_TABLES": "seen:200:extra"},
		{"LOBBY_TABLES": "foo:200"}, // DECISIONS.md §3: unknown category
		{"JWT_EXPIRES_IN": "soon"},
		{"JWT_EXPIRES_IN": ""},
		{"JWT_EXPIRES_IN": "0"},
		{"JWT_EXPIRES_IN": "-5d"},
	} {
		if _, err := FromEnv(env(bad)); err == nil {
			t.Errorf("FromEnv(%v) must fail", bad)
		} else {
			for k := range bad {
				if !strings.Contains(err.Error(), k) {
					t.Errorf("error for %v must name the key: %v", bad, err)
				}
			}
		}
	}
}

func TestCORSOrigin(t *testing.T) {
	for _, tc := range []struct {
		value *string
		any   bool
		list  []string
	}{
		{nil, true, nil},
		{ptr(""), true, nil},
		{ptr("*"), true, nil},
		{ptr("https://a.com, https://b.com"), false, []string{"https://a.com", "https://b.com"}},
	} {
		m := map[string]string{}
		if tc.value != nil {
			m["CORS_ORIGIN"] = *tc.value
		}
		cfg := mustLoad(t, m)
		if cfg.AllowAnyOrigin != tc.any || !reflect.DeepEqual(cfg.CORSOrigin, tc.list) {
			t.Errorf("CORS_ORIGIN=%v → any=%v list=%v", tc.value, cfg.AllowAnyOrigin, cfg.CORSOrigin)
		}
	}
}

func ptr(s string) *string { return &s }

func TestProductionGuards(t *testing.T) {
	_, err := FromEnv(env(map[string]string{"NODE_ENV": "production"}))
	if err == nil || err.Error() != "JWT_SECRET must be set in production" {
		t.Errorf("default secret in production: %v", err)
	}
	_, err = FromEnv(env(map[string]string{"NODE_ENV": "production", "JWT_SECRET": "x", "AUTH_ALLOW_FAKE_PROVIDERS": "true"}))
	if err == nil || err.Error() != "AUTH_ALLOW_FAKE_PROVIDERS must be false in production" {
		t.Errorf("fake providers in production: %v", err)
	}
	// Node: an empty JWT_SECRET is not the sentinel, so it passes the guard.
	if _, err := FromEnv(env(map[string]string{"NODE_ENV": "production", "JWT_SECRET": ""})); err != nil {
		t.Errorf("empty secret passes Node's guard: %v", err)
	}
	if _, err := FromEnv(env(map[string]string{"NODE_ENV": "production", "JWT_SECRET": "long-random"})); err != nil {
		t.Errorf("valid production config: %v", err)
	}
	// Outside production both are fine.
	if _, err := FromEnv(env(map[string]string{"AUTH_ALLOW_FAKE_PROVIDERS": "true"})); err != nil {
		t.Errorf("development with fake providers: %v", err)
	}
}

func TestSchemaMustBePlainIdentifier(t *testing.T) {
	for _, bad := range []string{"", "1abc", "public; drop", "te-st", "a b"} {
		_, err := FromEnv(env(map[string]string{"PG_SCHEMA": bad}))
		if err == nil || !strings.Contains(err.Error(), "PG_SCHEMA must be a plain identifier") {
			t.Errorf("PG_SCHEMA=%q: %v", bad, err)
		}
	}
	for _, good := range []string{"public", "_x", "test_auth_1a2b3c", "Schema9"} {
		if _, err := FromEnv(env(map[string]string{"PG_SCHEMA": good})); err != nil {
			t.Errorf("PG_SCHEMA=%q: %v", good, err)
		}
	}
}

func TestParseDuration(t *testing.T) {
	day := 24 * time.Hour
	for _, tc := range []struct {
		in   string
		want time.Duration
	}{
		{"30d", 30 * day}, {"12h", 12 * time.Hour}, {"15m", 15 * time.Minute}, {"45s", 45 * time.Second},
		{"2w", 14 * day}, {"1y", time.Duration(365.25 * float64(day))},
		{"100", 100 * time.Millisecond}, {"100ms", 100 * time.Millisecond}, {"3600", 3600 * time.Millisecond},
		{"30 days", 30 * day}, {"1 Hour", time.Hour}, {"2 hrs", 2 * time.Hour}, {"5 mins", 5 * time.Minute},
		{"10 secs", 10 * time.Second}, {"1.5h", 90 * time.Minute}, {".5s", 500 * time.Millisecond},
		{"1 Y", time.Duration(365.25 * float64(day))}, {"2 msecs", 2 * time.Millisecond},
	} {
		got, err := ParseDuration(tc.in)
		if err != nil || got != tc.want {
			t.Errorf("ParseDuration(%q) = %v, %v; want %v", tc.in, got, err, tc.want)
		}
	}
	for _, bad := range []string{"", "abc", "30dd", "1 fortnight", "0", "-1h", "1e3", strings.Repeat("1", 101), "1..5s", "h"} {
		if _, err := ParseDuration(bad); err == nil {
			t.Errorf("ParseDuration(%q) must fail", bad)
		}
	}
}

func TestTableRules(t *testing.T) {
	// roomManager.js _createTable with defaults — the four kinds of table.
	g := Defaults().Game
	for _, tc := range []struct {
		name     string
		category string
		boot     int64
		private  bool
		want     TableRules
	}{
		{"public seen", "seen", 200, false, TableRules{200, 2, 7, 1024, 1200000}},
		{"public blind 200", "blind", 200, false, TableRules{200, 0, 0, 0, 0}},
		{"public blind 5000", "blind", 5000, false, TableRules{5000, 0, 0, 0, 0}},
		{"private seen ignores the asked boot", "seen", 5000, true, TableRules{200, 2, 7, 1024, 500000}},
		{"private blind", "blind", 5000, true, TableRules{200, 2, 0, 0, 500000}},
		{"unknown category is seen", "BLIND", 200, false, TableRules{200, 2, 7, 1024, 1200000}},
		{"zero boot is the default", "seen", 0, false, TableRules{200, 2, 7, 1024, 1200000}},
	} {
		if got := g.TableRules(tc.category, tc.boot, tc.private); got != tc.want {
			t.Errorf("%s: %+v, want %+v", tc.name, got, tc.want)
		}
	}
	// Overrides flow through: a custom PRIVATE_BOOT / SEEN_MAX_POT / global multiplier.
	cfg := mustLoad(t, map[string]string{"PRIVATE_BOOT": "50", "SEEN_MAX_POT": "0", "POT_LIMIT_MULTIPLIER": "8", "BLIND_MAX_RAISE_STEPS": "3"})
	if got := cfg.Game.TableRules("seen", 200, true); got != (TableRules{50, 2, 7, 8, 500000}) {
		t.Errorf("private seen with overrides: %+v", got)
	}
	if got := cfg.Game.TableRules("blind", 200, false); got != (TableRules{200, 3, 0, 0, 0}) {
		t.Errorf("blind with overrides: %+v", got)
	}
	if NormalizeCategory("blind") != "blind" || NormalizeCategory("seen") != "seen" || NormalizeCategory("") != "seen" || NormalizeCategory("Blind") != "seen" {
		t.Error("NormalizeCategory")
	}
	if g.MenuMaxPot("seen") != 1200000 || g.MenuMaxPot("blind") != 0 {
		t.Error("MenuMaxPot")
	}
}

// TestPublicGameConfigValues pins the scalar values session:ready.config
// (socket/index.js publicGameConfig) and lobbyOptions() read from config,
// including that maxBetRounds is the GLOBAL 20 and not a table's 7/0.
func TestPublicGameConfigValues(t *testing.T) {
	g := mustLoad(t, nil).Game
	if g.MaxPlayers != 5 || g.MinPlayers != 2 || g.BootAmount != 200 || g.TurnTimeout.Milliseconds() != 25000 ||
		g.WelcomeChips != 200000 || g.MaxBetRounds != 20 || g.SideshowTimeout.Milliseconds() != 6000 || g.SideshowMinPlayers != 3 ||
		g.EntryCapBoot != 200 || g.EntryCapCategory != "blind" || g.EntryCapMaxChips != 500000 || g.PrivateBoot != 200 || g.PrivateMaxPot != 500000 ||
		g.MaxBlindMoves != 4 {
		t.Errorf("public game config scalars drifted: %+v", g)
	}
	if !reflect.DeepEqual(g.TableStakes, []int64{200, 5000}) {
		t.Errorf("stakes %v", g.TableStakes)
	}
	menu := []LobbyTable{{"seen", 200}, {"blind", 200}, {"blind", 5000}}
	if !reflect.DeepEqual(g.LobbyTables, menu) {
		t.Errorf("menu %v", g.LobbyTables)
	}
	for i, entry := range g.LobbyTables {
		wantPot := int64(0)
		if i == 0 {
			wantPot = 1200000
		}
		if g.MenuMaxPot(entry.Category) != wantPot {
			t.Errorf("tables[%d].maxPot = %d, want %d", i, g.MenuMaxPot(entry.Category), wantPot)
		}
	}
}

// TestEnvExampleIsTheDefaults reads go-server/.env.example, applies it through
// FromEnv and expects the defaults back (JWT_SECRET is the one deliberate
// difference — the example tells operators to change it).
func TestEnvExampleIsTheDefaults(t *testing.T) {
	path := filepath.Join("..", "..", ".env.example")
	f, err := os.Open(path)
	if err != nil {
		t.Skipf("no %s: %v", path, err)
	}
	defer f.Close()
	m := map[string]string{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			t.Fatalf("unparsable line %q", line)
		}
		m[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	got := mustLoad(t, m)
	if got.JWT.Secret != "change-me-to-a-long-random-string" {
		t.Errorf("JWT_SECRET from example: %q", got.JWT.Secret)
	}
	want := Defaults()
	want.JWT.Secret = got.JWT.Secret
	if !reflect.DeepEqual(got, want) {
		t.Errorf(".env.example drifted from Defaults():\n got %+v\nwant %+v", got, want)
	}
	// Every key the loader reads is documented in the example, and vice versa.
	for _, key := range readKeys() {
		if key == "PUBLIC_DIR" {
			continue // the one Go-only key
		}
		if _, ok := m[key]; !ok {
			t.Errorf("%s is read by FromEnv but missing from .env.example", key)
		}
	}
	known := map[string]bool{}
	for _, key := range readKeys() {
		known[key] = true
	}
	for key := range m {
		if !known[key] {
			t.Errorf("%s is in .env.example but FromEnv never reads it", key)
		}
	}
}

// readKeys lists every variable FromEnv consults, captured through the Lookup.
func readKeys() []string {
	seen := map[string]bool{}
	var keys []string
	_, _ = FromEnv(func(key string) (string, bool) {
		if !seen[key] {
			seen[key] = true
			keys = append(keys, key)
		}
		return "", false
	})
	return keys
}

func TestLoadReadsTheProcessEnvironment(t *testing.T) {
	t.Setenv("PORT", "4321")
	t.Setenv("PUBLIC_DIR", "/tmp/pub")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Port != 4321 || cfg.PublicDir != "/tmp/pub" {
		t.Errorf("Load: %+v", cfg)
	}
	t.Setenv("PORT", "nope")
	if _, err := Load(); err == nil {
		t.Error("Load must fail on a malformed PORT")
	}
}

// TestLoadPublicDirDefault: PUBLIC_DIR unset → "./public" when that
// directory exists (cwd = go-server/), else "go-server/public" (cwd = repo
// root) (DECISIONS.md §5, PORT_PLAN.md §9). An
// explicit PUBLIC_DIR is never second-guessed, even when it does not exist.
func TestLoadPublicDirDefault(t *testing.T) {
	if got := resolvePublicDir(func(dir string) bool { return dir == DefaultPublicDir }); got != DefaultPublicDir {
		t.Errorf("default present → %q", got)
	}
	if got := resolvePublicDir(func(string) bool { return false }); got != FallbackPublicDir {
		t.Errorf("default missing → %q", got)
	}
	// Through Load, from a scratch working directory.
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "go-server", "public"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(filepath.Join(root, "go-server"))
	os.Unsetenv("PUBLIC_DIR")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PublicDir != DefaultPublicDir {
		t.Errorf("./public present: %q", cfg.PublicDir)
	}
	if err := os.RemoveAll(filepath.Join(root, "go-server", "public")); err != nil {
		t.Fatal(err)
	}
	cfg, err = Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PublicDir != FallbackPublicDir {
		t.Errorf("no sibling: %q", cfg.PublicDir)
	}
	// A file (not a directory) at the default path does not count.
	if err := os.MkdirAll(filepath.Join(root, "server"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "server", "public"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if cfg, _ = Load(); cfg.PublicDir != FallbackPublicDir {
		t.Errorf("file at the default path: %q", cfg.PublicDir)
	}
	t.Setenv("PUBLIC_DIR", "/nowhere/at/all")
	if cfg, _ = Load(); cfg.PublicDir != "/nowhere/at/all" {
		t.Errorf("explicit PUBLIC_DIR must win: %q", cfg.PublicDir)
	}
}
