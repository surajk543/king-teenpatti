// Package config is the port of server/src/config/index.js: every environment
// variable the server reads, parsed once into one immutable struct.
//
// Node snapshots `process.env` at import time and every module reads the
// shared `config` object. The Go port keeps the same "read once" rule but
// passes the *Config explicitly — there is no package-level singleton, so a
// test can build two servers with two configs in one process.
//
// Defaults are the shared vocabulary between the two servers: every value in
// Defaults() MUST match server/.env.example and CLAUDE.md §7.4.
package config

import "time"

// Env values. Only "production" changes behaviour (Validate refuses the
// default JWT secret and fake providers there, as Node throws at import).
const (
	EnvDevelopment = "development"
	EnvProduction  = "production"
	EnvTest        = "test"
)

// DefaultJWTSecret is the insecure development secret Node ships with.
// Validate() rejects it when Env == EnvProduction.
const DefaultJWTSecret = "dev-only-insecure-secret"

// Config is the whole configuration. Field groups mirror the Node object
// one-to-one (config.jwt → JWT, config.game → Game, …) so a porter can find
// any value by the same name.
type Config struct {
	// Env is NODE_ENV (default "development").
	Env string
	// Port / Host: PORT (3000) and HOST ("0.0.0.0").
	Port int
	Host string
	// CORSOrigin is CORS_ORIGIN parsed as a comma list. AllowAnyOrigin is true
	// when the variable is unset or "*" (Node: corsOrigin === '*'). Only the
	// Socket.IO handshake honours it (gorilla CheckOrigin); the REST API sets
	// no CORS headers in Node either.
	CORSOrigin     []string
	AllowAnyOrigin bool

	JWT      JWTConfig
	Google   GoogleConfig
	Facebook FacebookConfig
	// AllowFakeProviders is AUTH_ALLOW_FAKE_PROVIDERS (false). Lets google /
	// facebook logins without a token through as trusted profiles (tests, the
	// browser stubs). Validate() refuses it in production.
	AllowFakeProviders bool

	DB      DBConfig
	Game    GameConfig
	Metrics MetricsConfig
	Chat    ChatConfig

	// LogLevel is LOG_LEVEL (info). Node's util/logger.js reads it directly.
	LogLevel string
	// PublicDir is where the bundled browser client (server/public) lives so
	// the Go binary can serve it at "/". Env PUBLIC_DIR, default "./public".
	// This variable does not exist in Node (it derived rootDir from the module
	// path) — recorded in PORT_PLAN.md as the one added env key.
	PublicDir string
	// RedisURL is REDIS_URL. Read for parity and logged as ignored: the Go
	// server is a single process (PORT_PLAN.md decision 1).
	RedisURL string
}

// JWTConfig ← config.jwt.
type JWTConfig struct {
	// Secret is JWT_SECRET (DefaultJWTSecret). HS256 signing key.
	Secret string
	// ExpiresIn is JWT_EXPIRES_IN parsed by ParseDuration (default "30d").
	ExpiresIn time.Duration
}

// GoogleConfig ← config.google. Empty ClientIDs → 503 provider_unconfigured.
type GoogleConfig struct {
	ClientIDs []string // GOOGLE_CLIENT_IDS, comma list
}

// FacebookConfig ← config.facebook. Either empty → 503 provider_unconfigured.
type FacebookConfig struct {
	AppID     string // FACEBOOK_APP_ID
	AppSecret string // FACEBOOK_APP_SECRET
}

// DBConfig ← config.db.
type DBConfig struct {
	// URL is DATABASE_URL (postgres://postgres:postgres@localhost:5432/gameplay).
	URL string
	// Schema is PG_SCHEMA ("public"). Tests use test_<pkg>_<rand> and drop it.
	// Must match ^[A-Za-z_][A-Za-z0-9_]*$ — db.Open refuses anything else.
	Schema string
	// PoolMax is PG_POOL_MAX (10) → pgxpool MaxConns.
	PoolMax int
}

// LobbyTable is one "category:boot" entry of LOBBY_TABLES, in menu order.
// Category is kept as the raw string (Node does not normalise it here; an
// unknown category simply never matches a join).
type LobbyTable struct {
	Category   string `json:"category"`
	BootAmount int64  `json:"bootAmount"`
}

// GameConfig ← config.game. Durations replace Node's *Ms integers; convert
// with .Milliseconds() wherever the value goes on the wire (turnTimeoutMs,
// sideshowTimeoutMs, …) — see PORT_PLAN.md §Time.
type GameConfig struct {
	WelcomeChips int64 // WELCOME_CHIPS 200000 (requirement 5)
	BootAmount   int64 // BOOT_AMOUNT 200 — the default stake

	// TableStakes is TABLE_STAKES (200,5000): the stakes quick-join accepts.
	// Empty = any stake (tests). Non-integers and ≤0 entries are dropped.
	TableStakes []int64
	// LobbyTables is LOBBY_TABLES (seen:200,blind:200,blind:5000): the exact
	// menu, in display order. Empty = any pair (tests). Entries whose boot
	// does not parse as an integer are dropped.
	LobbyTables []LobbyTable

	MaxPlayers  int           // MAX_PLAYERS_PER_ROOM 5 (requirement 3; also hardcoded in Flutter _places)
	MinPlayers  int           // MIN_PLAYERS_TO_START 2 (requirement 4)
	TurnTimeout time.Duration // TURN_TIMEOUT_MS 25000

	// Generic betting limits — defaults only. RoomManager.CreateTable
	// overrides all three per category (seen: 7 / 1024 / 2, blind: 0 / 0 / 0).
	MaxBetRounds       int   // MAX_BET_ROUNDS 20 (0 = never force a showdown)
	PotLimitMultiplier int64 // POT_LIMIT_MULTIPLIER 1024 (per-bet ceiling = boot × this; 0 = none)
	MaxRaiseSteps      int   // MAX_RAISE_STEPS 8 (ladder rungs; 0 = unlimited)

	// Requirement 19: seen tables — one double per turn, forced showdown
	// after 7 rounds (the brief says "10 moves"), pot capped at 1.2M.
	SeenMaxRaiseSteps int   // SEEN_MAX_RAISE_STEPS 2
	SeenMaxBetRounds  int   // SEEN_MAX_BET_ROUNDS 7
	SeenMaxPot        int64 // SEEN_MAX_POT 1200000 (0 = uncapped)

	// Blind tables (200 and 5000) are open-ended: 0 means "no limit" for each.
	BlindMaxRaiseSteps      int   // BLIND_MAX_RAISE_STEPS 0
	BlindMaxBetRounds       int   // BLIND_MAX_BET_ROUNDS 0
	BlindPotLimitMultiplier int64 // BLIND_POT_LIMIT_MULTIPLIER 0

	// MaxBlindMoves is MAX_BLIND_MOVES 4: blind bets before the cards auto-reveal.
	MaxBlindMoves int

	// Requirement 30: entry cap on the cheapest blind table.
	EntryCapBoot     int64  // ENTRY_CAP_BOOT 200
	EntryCapCategory string // ENTRY_CAP_CATEGORY "blind"
	EntryCapMaxChips int64  // ENTRY_CAP_MAX_CHIPS 500000 (0 disables)

	// Requirement 31: consecutive timed-out turns before the seat is given up.
	MaxMissedTurns int // MAX_MISSED_TURNS 3

	// Requirement 33: sideshow.
	SideshowTimeout    time.Duration // SIDESHOW_TIMEOUT_MS 6000
	SideshowMinPlayers int           // SIDESHOW_MIN_PLAYERS 3

	// Requirement 29: longest display name. Also hardcoded as 24 in
	// providers.js sanitizeName and the Flutter login/lobby fields.
	DisplayNameMaxLength int // DISPLAY_NAME_MAX 24

	// Requirement 22: private tables.
	PrivateMaxPot        int64 // PRIVATE_MAX_POT 500000
	PrivateMaxRaiseSteps int   // PRIVATE_MAX_RAISE_STEPS 2
	PrivateBoot          int64 // PRIVATE_BOOT 200

	NextHandDelay       time.Duration // NEXT_HAND_DELAY_MS 4000 ("starting in N")
	ConsolidateInterval time.Duration // CONSOLIDATE_INTERVAL_MS 15000 (requirement 24 sweeper)
	ReconnectGrace      time.Duration // RECONNECT_GRACE_MS 60000 (seat held after a drop)
	// ResumeOffer is RESUME_OFFER_MS 600000: after the held seat lapses, how
	// long session:ready.resume still offers the table back. 0 disables.
	ResumeOffer time.Duration
}

// MetricsConfig ← config.metrics (requirement 35).
type MetricsConfig struct {
	Enabled bool     // METRICS_ENABLED: anything but the string "false" is true
	Path    string   // METRICS_PATH "/metrics"
	Prefix  string   // METRICS_PREFIX "game_server_" — process/runtime metrics only
	Token   string   // METRICS_TOKEN "" → no bearer check
	AllowIP []string // METRICS_ALLOW_IPS "" → no IP check
}

// ChatConfig ← config.chat.
type ChatConfig struct {
	MaxHistory int           // CHAT_MAX_HISTORY 100 messages kept per room
	MaxLength  int           // CHAT_MAX_LENGTH 140 characters (Flutter allows 200; 141–200 are cut here)
	RateLimit  int           // CHAT_RATE_LIMIT 5 messages …
	RateWindow time.Duration // … per CHAT_RATE_WINDOW_MS 5000, per socket
}

// Defaults returns the configuration the server runs with when no environment
// variable is set — byte-for-byte the defaults in server/src/config/index.js.
// Load() starts from this and overlays the environment.
func Defaults() *Config {
	return &Config{
		Env:            EnvDevelopment,
		Port:           3000,
		Host:           "0.0.0.0",
		CORSOrigin:     nil,
		AllowAnyOrigin: true,
		JWT: JWTConfig{
			Secret:    DefaultJWTSecret,
			ExpiresIn: 30 * 24 * time.Hour,
		},
		Google:             GoogleConfig{ClientIDs: nil},
		Facebook:           FacebookConfig{},
		AllowFakeProviders: false,
		DB: DBConfig{
			URL:     "postgres://postgres:postgres@localhost:5432/gameplay",
			Schema:  "public",
			PoolMax: 10,
		},
		Game: GameConfig{
			WelcomeChips: 200000,
			BootAmount:   200,
			TableStakes:  []int64{200, 5000},
			LobbyTables: []LobbyTable{
				{Category: "seen", BootAmount: 200},
				{Category: "blind", BootAmount: 200},
				{Category: "blind", BootAmount: 5000},
			},
			MaxPlayers:              5,
			MinPlayers:              2,
			TurnTimeout:             25 * time.Second,
			MaxBetRounds:            20,
			PotLimitMultiplier:      1024,
			MaxRaiseSteps:           8,
			SeenMaxRaiseSteps:       2,
			SeenMaxBetRounds:        7,
			SeenMaxPot:              1200000,
			BlindMaxRaiseSteps:      0,
			BlindMaxBetRounds:       0,
			BlindPotLimitMultiplier: 0,
			MaxBlindMoves:           4,
			EntryCapBoot:            200,
			EntryCapCategory:        "blind",
			EntryCapMaxChips:        500000,
			MaxMissedTurns:          3,
			SideshowTimeout:         6 * time.Second,
			SideshowMinPlayers:      3,
			DisplayNameMaxLength:    24,
			PrivateMaxPot:           500000,
			PrivateMaxRaiseSteps:    2,
			PrivateBoot:             200,
			NextHandDelay:           4 * time.Second,
			ConsolidateInterval:     15 * time.Second,
			ReconnectGrace:          60 * time.Second,
			ResumeOffer:             10 * time.Minute,
		},
		Metrics: MetricsConfig{
			Enabled: true,
			Path:    "/metrics",
			Prefix:  "game_server_",
			Token:   "",
			AllowIP: nil,
		},
		Chat: ChatConfig{
			MaxHistory: 100,
			MaxLength:  140,
			RateLimit:  5,
			RateWindow: 5 * time.Second,
		},
		LogLevel:  "info",
		PublicDir: "./public",
		RedisURL:  "",
	}
}

// Lookup is the environment accessor Load reads through — os.LookupEnv in
// production, a map-backed closure in tests.
type Lookup func(key string) (string, bool)

// Load reads the process environment (after cmd/gameplay has applied .env via
// godotenv) and returns the configuration, validated. Equivalent to importing
// server/src/config/index.js.
func Load() (*Config, error) {
	panic("not ported: config.Load")
}

// FromEnv builds a Config from `lookup`, starting at Defaults(). Parsing rules
// are Node's exactly (server/src/config/index.js `num`, `bool`, `list`):
//
//   - integers: parseInt base 10; unparsable → keep the default (so
//     TURN_TIMEOUT_MS=abc silently stays 25000);
//   - booleans: unset or "" → default; else true iff the lower-cased value is
//     one of "1", "true", "yes", "on";
//   - lists: split on ",", trim, drop empties;
//   - METRICS_ENABLED is the odd one out: true unless the value is exactly
//     "false";
//   - TABLE_STAKES="" and LOBBY_TABLES="" must produce EMPTY slices (the tests
//     rely on "empty = unrestricted"); note `?? default` in Node means an
//     unset variable takes the default but a set-but-empty one is honoured;
//   - CORS_ORIGIN unset or "*" → AllowAnyOrigin=true, else the list;
//   - JWT_EXPIRES_IN goes through ParseDuration;
//   - *_MS integers become time.Duration milliseconds.
//
// It then calls Validate and returns its error, if any.
func FromEnv(lookup Lookup) (*Config, error) {
	panic("not ported: config.FromEnv")
}

// Validate applies the two production guards Node enforces at import:
// in production the JWT secret must not be DefaultJWTSecret and
// AllowFakeProviders must be false. Returns a descriptive error otherwise.
// It also rejects a DB.Schema that is not a plain identifier.
func (c *Config) Validate() error {
	panic("not ported: (*Config).Validate")
}

// ParseDuration parses the `expiresIn` grammar jsonwebtoken accepts (the
// vercel/ms format): a bare integer is milliseconds; "30d", "12h", "15m",
// "45s", "2w", "1y" carry a unit (ms, s, m, h, d, w, y). Whitespace between
// number and unit is allowed ("30 days"), units may be spelled out or plural.
// Returns an error for anything else so a typo in JWT_EXPIRES_IN fails at
// boot rather than issuing tokens that never expire.
func ParseDuration(text string) (time.Duration, error) {
	panic("not ported: config.ParseDuration")
}
