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

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

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

// DefaultPublicDir is where the browser client lives relative to the Go
// binary's working directory (go-server/): go-server/public.
// DECISIONS.md §5 (new env key PUBLIC_DIR).
const DefaultPublicDir = "./public"

// FallbackPublicDir is what Load() uses when PUBLIC_DIR is unset and
// DefaultPublicDir does not exist — the binary started from the repository
// root instead of go-server/ (PORT_PLAN.md §9).
const FallbackPublicDir = "go-server/public"

// Table categories as the config layer spells them (game.Category has the
// same values; config cannot import game). LOBBY_TABLES and
// ENTRY_CAP_CATEGORY are compared against these.
const (
	CategorySeen  = "seen"
	CategoryBlind = "blind"
)

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
	// Play is the Google Play in-app purchase configuration. Empty credentials
	// mean the store endpoint refuses every request — a server with no way to
	// verify a receipt must never credit one.
	Play PlayConfig

	// LogLevel is LOG_LEVEL (info). Node's util/logger.js reads it directly.
	LogLevel string
	// PublicDir is where the bundled browser client (go-server/public) lives so
	// the Go binary can serve it at "/". Env PUBLIC_DIR; when unset, Load()
	// picks DefaultPublicDir ("./public") if that directory exists
	// and FallbackPublicDir ("go-server/public") otherwise (DECISIONS.md §5,
	// PORT_PLAN.md §9). Defaults()/FromEnv() carry DefaultPublicDir — they do
	// not touch the filesystem. This variable does not exist in Node (it
	// derived rootDir from the module path) — recorded in PORT_PLAN.md as the
	// one added env key.
	PublicDir string
	// RootRedirect is ROOT_REDIRECT (empty). Set, it takes the browser client
	// off the internet: GET / answers 302 to this URL (production points it at
	// the Grafana login, "/dashboard/"), the client's own files — every file
	// at the top level of PublicDir, plus the Socket.IO browser bundle — are
	// not served (404), and only PublicDir's subdirectories remain reachable:
	// the pages Google Play links to (privacy/, account-deletion/) and the
	// avatars the Flutter client fetches (profiles/). Empty keeps the browser
	// client at "/" for development and the parity harness. Go-only key, like
	// PUBLIC_DIR (DECISIONS.md §5).
	RootRedirect string
	// RedisURL is REDIS_URL: the live-state store (LIVE_STATE_PLAN.md). Empty
	// → the in-process store (single instance; nothing survives a restart);
	// set → Redis, and the server refuses to start when it is unreachable.
	RedisURL string
	// LiveStateTTL is LIVE_STATE_TTL_MS (86400000 = 24 h): how long a table
	// snapshot that stops updating survives in the live store.
	LiveStateTTL time.Duration
	// LiveInstanceID is LIVE_INSTANCE_ID: the tag this process writes into
	// presence and matchmaking entries. Load() defaults it to "<hostname>:<pid>"
	// when unset or empty; Defaults()/FromEnv() carry "" (they do not consult
	// the host), exactly like PublicDir's filesystem-dependent default.
	LiveInstanceID string
	// LiveReconcile is LIVE_RECONCILE_MS (30000): how often the live store is
	// pinged and, once it answers again after an outage, refilled from memory
	// (every table re-saved, seats and lobby index re-published). 0 disables
	// the reconciler.
	LiveReconcile time.Duration
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
	// StatementTimeoutMs is PG_STATEMENT_TIMEOUT_MS (15000): Postgres
	// statement_timeout for every pooled connection, so a hung query fails
	// the one ledger write (persist_failed) instead of freezing that table's
	// actor for good. 0 disables the limit (Node's behaviour). Go-only key.
	StatementTimeoutMs int
	// LedgerPurgeInterval is LEDGER_PURGE_INTERVAL_MS (1h): how often
	// db.PurgeLedger runs. 0 disables the purge job entirely — no rows are
	// ever removed unless this is set.
	LedgerPurgeInterval time.Duration
	// LedgerPurgeAfter is LEDGER_PURGE_AFTER_MS (24h): a purgeable chip_ledger
	// row (see db.purgeableReasons — checkpoint rows only, never purchase or
	// reward rows) is deleted once it is older than this. 24h is a wide
	// margin over RESUME_OFFER_MS (10 min, the longest a reconnecting client
	// can still legitimately retry a stale action against).
	LedgerPurgeAfter time.Duration
}

// LobbyTable is one "category:boot" entry of LOBBY_TABLES, in menu order.
// Category is the trimmed string as written and is always "seen" or "blind":
// FromEnv rejects anything else (DECISIONS.md §3; Node kept unknown
// categories as unjoinable menu items).
type LobbyTable struct {
	Category   string `json:"category"`
	BootAmount int64  `json:"bootAmount"`
	// MinChips is the smallest stack allowed through the door, 0 for no floor.
	// It is what makes a table exclusive rather than merely expensive: the
	// 10-lakh blind table is for players who have already won big, and the
	// boot alone would not keep anyone else out — a player with 20 lakh could
	// cover the boot and be broke in two hands.
	MinChips int64
	// MaxChips is the largest stack allowed, 0 for no ceiling. This is the
	// generalisation of requirement 30's entry cap: a player who has outgrown
	// a table is moved up rather than left to farm the smaller stakes.
	// Exactly the limit is allowed at both ends — the rules are "more than"
	// and "less than", not "at least" and "at most".
	MaxChips int64
}

// GameConfig ← config.game. Durations replace Node's *Ms integers; convert
// with .Milliseconds() wherever the value goes on the wire (turnTimeoutMs,
// sideshowTimeoutMs, …) — see PORT_PLAN.md §Time.
type GameConfig struct {
	WelcomeChips int64 // WELCOME_CHIPS 200000 (requirement 5)
	BootAmount   int64 // BOOT_AMOUNT 200 — the default stake

	// TableStakes is TABLE_STAKES (200,5000): the stakes quick-join accepts.
	// Empty = any stake (tests). Entries ≤ 0 are dropped as Node's filter
	// does; an entry that is not a decimal integer fails FromEnv
	// (DECISIONS.md §5 strict integers — Node silently dropped it).
	TableStakes []int64
	// LobbyTables is LOBBY_TABLES (seen:200,blind:200,blind:5000): the exact
	// menu, in display order. Empty = any pair (tests). An entry whose boot is
	// not a decimal integer or whose category is not seen|blind fails FromEnv
	// (DECISIONS.md §3 and §5 — Node dropped the former silently and let the
	// latter through as an unjoinable menu item).
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

	// MinClientBuild is the oldest Android versionCode allowed to play.
	//
	// MIN_CLIENT_BUILD, 0 = no floor (the default, and what every environment
	// that is not production should use). The client compares its own build
	// number against this on session:ready and sends the player to the update
	// screen below it.
	//
	// This exists because Play's own update check cannot answer the question
	// that matters. Play knows a newer build exists; it does not know that the
	// server changed the wire this morning, and its answer lags a release by
	// hours. Only the server knows which clients it can still talk to, so only
	// the server can set the floor. Raise it in the same deploy that ships a
	// breaking change, never before — every player below it is locked out
	// until they update.
	MinClientBuild int // MIN_CLIENT_BUILD 0

	// Requirement 29: longest display name. Also hardcoded as 24 in
	// providers.js sanitizeName and the Flutter login/lobby fields.
	DisplayNameMaxLength int // DISPLAY_NAME_MAX 24

	// Requirement 22: private tables.
	PrivateMaxPot        int64 // PRIVATE_MAX_POT 500000
	PrivateMaxRaiseSteps int   // PRIVATE_MAX_RAISE_STEPS 2
	PrivateBoot          int64 // PRIVATE_BOOT 200

	NextHandDelay time.Duration // NEXT_HAND_DELAY_MS 4000 ("starting in N")
	// UnfundedGrace is UNFUNDED_GRACE_MS 30000: how long a seat that can no
	// longer cover the boot is held between hands before the
	// insufficient_chips kick (requirements 31/32), so a player buying chips
	// has time to finish the purchase and stay. 0 = at once (Node's rule).
	UnfundedGrace       time.Duration
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
// PlayConfig is Google Play in-app purchases.
//
// The credentials are a service-account JSON key and are therefore a SECRET:
// they belong in the environment (production's go-server/.env, which is
// git-ignored), never in the repository. A key that has been pasted anywhere
// else — a chat, a ticket, a screenshot — should be rotated in Google Cloud
// rather than reused.
type PlayConfig struct {
	// Package is GOOGLE_PLAY_PACKAGE, the applicationId purchases are checked
	// against: com.sungamestudio.kingteenpatti. A receipt minted for another
	// package is refused.
	Package string
	// CredentialsFile is GOOGLE_PLAY_CREDENTIALS_FILE, a path to the
	// service-account JSON. PREFER THIS over the inline form.
	//
	// The inline form does not survive systemd. The unit loads the same .env
	// through EnvironmentFile=, and systemd's parser mangles the \n escapes
	// inside private_key, so the JSON still parses but the PEM inside it is no
	// longer a key ("Key must be a PEM encoded PKCS1 or PKCS8 key", production,
	// 9 Sep 2026). godotenv handles it correctly and never gets the chance,
	// because systemd has already set the variable and godotenv does not
	// override real env. A path has no escapes to mangle.
	//
	// It is also the safer shape: a 2.3 KB private key in the environment is
	// readable from /proc/<pid>/environ, while a file can be chmod 400.
	CredentialsFile string
	// Credentials is GOOGLE_PLAY_CREDENTIALS, the whole service-account JSON
	// as one value. Kept for a deployment that has no file to point at; see
	// the warning on CredentialsFile. Empty disables the store (503).
	Credentials string
}

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
			URL:                 "postgres://postgres:postgres@localhost:5432/gameplay",
			Schema:              "public",
			PoolMax:             10,
			StatementTimeoutMs:  15000,
			LedgerPurgeInterval: time.Hour,
			LedgerPurgeAfter:    24 * time.Hour,
		},
		Game: GameConfig{
			WelcomeChips: 200000,
			BootAmount:   200,
			TableStakes:  []int64{200, 5000, 50000, 1000000},
			// The blind ladder is banded by stack as well as by stake, so a
			// player sits where their money belongs: outgrow a table and it
			// closes behind you, and the top one opens only once you could
			// lose a hand there and still be playing. Indian numbering, since
			// that is how these were specified: 5 Cr = 5,00,00,000.
			LobbyTables: []LobbyTable{
				{Category: "seen", BootAmount: 200},
				{Category: "blind", BootAmount: 200},
				{Category: "blind", BootAmount: 5000, MaxChips: 50000000},     // over 5 Cr must move up
				{Category: "blind", BootAmount: 50000, MaxChips: 1000000000},  // over 100 Cr must move up
				{Category: "blind", BootAmount: 1000000, MinChips: 500000000}, // 50 Cr or more to enter
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
			MinClientBuild:          0,
			DisplayNameMaxLength:    24,
			PrivateMaxPot:           500000,
			PrivateMaxRaiseSteps:    2,
			PrivateBoot:             200,
			NextHandDelay:           4 * time.Second,
			UnfundedGrace:           30 * time.Second,
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
		// The package is a constant of this app, so it is the default rather
		// than something every deployment has to set and can get wrong. The
		// credentials are a secret and have no default: without them the store
		// endpoint refuses.
		Play:           PlayConfig{Package: "com.sungamestudio.kingteenpatti"},
		LogLevel:       "info",
		PublicDir:      DefaultPublicDir,
		RedisURL:       "",
		LiveStateTTL:   24 * time.Hour,
		LiveInstanceID: "",
		LiveReconcile:  30 * time.Second,
	}
}

// Lookup is the environment accessor Load reads through — os.LookupEnv in
// production, a map-backed closure in tests.
type Lookup func(key string) (string, bool)

// Load reads the process environment (after cmd/gameplay has applied .env via
// godotenv) and returns the configuration, validated. Equivalent to importing
// server/src/config/index.js.
//
// Two keys have host-dependent defaults that only Load applies:
//
//   - PUBLIC_DIR unset → DefaultPublicDir if it is a directory that exists,
//     else FallbackPublicDir (a binary deployed next to a copied `public/`).
//     The app warns at start-up when the chosen directory is missing.
//   - LIVE_INSTANCE_ID unset or empty → DefaultInstanceID() ("<hostname>:<pid>").
func Load() (*Config, error) {
	cfg, err := FromEnv(os.LookupEnv)
	if err != nil {
		return nil, err
	}
	if _, set := os.LookupEnv("PUBLIC_DIR"); !set {
		cfg.PublicDir = resolvePublicDir(func(dir string) bool {
			info, err := os.Stat(dir)
			return err == nil && info.IsDir()
		})
	}
	if cfg.LiveInstanceID == "" {
		cfg.LiveInstanceID = DefaultInstanceID()
	}
	return cfg, nil
}

// DefaultInstanceID is Load's LIVE_INSTANCE_ID default: "<hostname>:<pid>"
// ("unknown:<pid>" when the hostname cannot be read). It names this process
// in the live store's presence and matchmaking entries so a restarted (or a
// second) instance can tell its own entries from a dead one's.
func DefaultInstanceID() string {
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "unknown"
	}
	return host + ":" + strconv.Itoa(os.Getpid())
}

// resolvePublicDir is Load's PUBLIC_DIR default: DefaultPublicDir when
// isDir reports it present, else FallbackPublicDir.
func resolvePublicDir(isDir func(string) bool) string {
	if isDir(DefaultPublicDir) {
		return DefaultPublicDir
	}
	return FallbackPublicDir
}

// FromEnv builds a Config from `lookup`, starting at Defaults(). Parsing rules
// follow Node's `num`, `bool`, `list` (server/src/config/index.js) with the
// one tightening DECISIONS.md §5 asks for:
//
//   - integers: an unset variable or the empty string keeps the default
//     (Node: parseInt of an empty string is NaN → fallback); anything else must be a decimal
//     integer, optionally signed, else FromEnv fails with a clear error
//     (Node's parseInt would have read "12abc" as 12 and "abc" as the default);
//   - booleans: unset or "" → default; else true iff the lower-cased value is
//     one of "1", "true", "yes", "on";
//   - lists: split on ",", trim, drop empties;
//   - METRICS_ENABLED is the odd one out: true unless the value is exactly
//     "false";
//   - TABLE_STAKES="" and LOBBY_TABLES="" must produce EMPTY slices (the tests
//     rely on "empty = unrestricted"); note `?? default` in Node means an
//     unset variable takes the default but a set-but-empty one is honoured;
//   - LOBBY_TABLES categories must be seen|blind (DECISIONS.md §3);
//   - CORS_ORIGIN unset, "" or "*" → AllowAnyOrigin=true, else the list;
//   - JWT_EXPIRES_IN goes through ParseDuration;
//   - *_MS integers become time.Duration milliseconds;
//   - string keys are taken verbatim (`??`): a set-but-empty JWT_SECRET is
//     the empty string, exactly as in Node.
//
// It then calls Validate and returns its error, if any.
func FromEnv(lookup Lookup) (*Config, error) {
	c := Defaults()
	r := &reader{lookup: lookup}

	c.Env = r.str("NODE_ENV", c.Env)
	c.Port = r.integer("PORT", c.Port)
	c.Host = r.str("HOST", c.Host)
	if origin, ok := lookup("CORS_ORIGIN"); ok && origin != "" && origin != "*" {
		c.CORSOrigin = list(origin)
		c.AllowAnyOrigin = false
	}

	c.JWT.Secret = r.str("JWT_SECRET", c.JWT.Secret)
	if raw, ok := lookup("JWT_EXPIRES_IN"); ok {
		d, err := ParseDuration(raw)
		if err != nil {
			r.fail("JWT_EXPIRES_IN", raw, err.Error())
		} else {
			c.JWT.ExpiresIn = d
		}
	}
	c.Google.ClientIDs = r.list("GOOGLE_CLIENT_IDS", c.Google.ClientIDs)
	c.Facebook.AppID = r.str("FACEBOOK_APP_ID", c.Facebook.AppID)
	c.Facebook.AppSecret = r.str("FACEBOOK_APP_SECRET", c.Facebook.AppSecret)
	c.AllowFakeProviders = r.boolean("AUTH_ALLOW_FAKE_PROVIDERS", c.AllowFakeProviders)

	c.DB.URL = r.str("DATABASE_URL", c.DB.URL)
	c.DB.Schema = r.str("PG_SCHEMA", c.DB.Schema)
	c.DB.PoolMax = r.integer("PG_POOL_MAX", c.DB.PoolMax)
	c.DB.StatementTimeoutMs = r.integer("PG_STATEMENT_TIMEOUT_MS", c.DB.StatementTimeoutMs)
	c.DB.LedgerPurgeInterval = r.millis("LEDGER_PURGE_INTERVAL_MS", c.DB.LedgerPurgeInterval)
	c.DB.LedgerPurgeAfter = r.millis("LEDGER_PURGE_AFTER_MS", c.DB.LedgerPurgeAfter)

	g := &c.Game
	g.WelcomeChips = r.int64("WELCOME_CHIPS", g.WelcomeChips)
	g.BootAmount = r.int64("BOOT_AMOUNT", g.BootAmount)
	if raw, ok := lookup("TABLE_STAKES"); ok {
		stakes, err := parseTableStakes(raw)
		if err != nil {
			r.fail("TABLE_STAKES", raw, err.Error())
		} else {
			g.TableStakes = stakes
		}
	}
	if raw, ok := lookup("LOBBY_TABLES"); ok {
		tables, err := parseLobbyTables(raw)
		if err != nil {
			r.fail("LOBBY_TABLES", raw, err.Error())
		} else {
			g.LobbyTables = tables
		}
	}
	g.MaxPlayers = r.integer("MAX_PLAYERS_PER_ROOM", g.MaxPlayers)
	g.MinPlayers = r.integer("MIN_PLAYERS_TO_START", g.MinPlayers)
	g.TurnTimeout = r.millis("TURN_TIMEOUT_MS", g.TurnTimeout)
	g.MaxBetRounds = r.integer("MAX_BET_ROUNDS", g.MaxBetRounds)
	g.PotLimitMultiplier = r.int64("POT_LIMIT_MULTIPLIER", g.PotLimitMultiplier)
	g.MaxRaiseSteps = r.integer("MAX_RAISE_STEPS", g.MaxRaiseSteps)
	g.SeenMaxRaiseSteps = r.integer("SEEN_MAX_RAISE_STEPS", g.SeenMaxRaiseSteps)
	g.SeenMaxBetRounds = r.integer("SEEN_MAX_BET_ROUNDS", g.SeenMaxBetRounds)
	g.SeenMaxPot = r.int64("SEEN_MAX_POT", g.SeenMaxPot)
	g.BlindMaxRaiseSteps = r.integer("BLIND_MAX_RAISE_STEPS", g.BlindMaxRaiseSteps)
	g.BlindMaxBetRounds = r.integer("BLIND_MAX_BET_ROUNDS", g.BlindMaxBetRounds)
	g.BlindPotLimitMultiplier = r.int64("BLIND_POT_LIMIT_MULTIPLIER", g.BlindPotLimitMultiplier)
	g.MaxBlindMoves = r.integer("MAX_BLIND_MOVES", g.MaxBlindMoves)
	g.EntryCapBoot = r.int64("ENTRY_CAP_BOOT", g.EntryCapBoot)
	g.EntryCapCategory = r.str("ENTRY_CAP_CATEGORY", g.EntryCapCategory)
	g.EntryCapMaxChips = r.int64("ENTRY_CAP_MAX_CHIPS", g.EntryCapMaxChips)
	g.MaxMissedTurns = r.integer("MAX_MISSED_TURNS", g.MaxMissedTurns)
	g.SideshowTimeout = r.millis("SIDESHOW_TIMEOUT_MS", g.SideshowTimeout)
	g.SideshowMinPlayers = r.integer("SIDESHOW_MIN_PLAYERS", g.SideshowMinPlayers)
	g.MinClientBuild = r.integer("MIN_CLIENT_BUILD", g.MinClientBuild)
	g.DisplayNameMaxLength = r.integer("DISPLAY_NAME_MAX", g.DisplayNameMaxLength)
	g.PrivateMaxPot = r.int64("PRIVATE_MAX_POT", g.PrivateMaxPot)
	g.PrivateMaxRaiseSteps = r.integer("PRIVATE_MAX_RAISE_STEPS", g.PrivateMaxRaiseSteps)
	g.PrivateBoot = r.int64("PRIVATE_BOOT", g.PrivateBoot)
	g.NextHandDelay = r.millis("NEXT_HAND_DELAY_MS", g.NextHandDelay)
	g.UnfundedGrace = r.millis("UNFUNDED_GRACE_MS", g.UnfundedGrace)
	g.ConsolidateInterval = r.millis("CONSOLIDATE_INTERVAL_MS", g.ConsolidateInterval)
	g.ReconnectGrace = r.millis("RECONNECT_GRACE_MS", g.ReconnectGrace)
	g.ResumeOffer = r.millis("RESUME_OFFER_MS", g.ResumeOffer)

	// (process.env.METRICS_ENABLED ?? 'true') !== 'false' — only the exact
	// lower-case string "false" switches the exposition off.
	if raw, ok := lookup("METRICS_ENABLED"); ok {
		c.Metrics.Enabled = raw != "false"
	}
	c.Metrics.Path = r.str("METRICS_PATH", c.Metrics.Path)
	c.Metrics.Prefix = r.str("METRICS_PREFIX", c.Metrics.Prefix)
	c.Metrics.Token = r.str("METRICS_TOKEN", c.Metrics.Token)
	c.Metrics.AllowIP = r.list("METRICS_ALLOW_IPS", c.Metrics.AllowIP)

	c.Chat.MaxHistory = r.integer("CHAT_MAX_HISTORY", c.Chat.MaxHistory)
	c.Chat.MaxLength = r.integer("CHAT_MAX_LENGTH", c.Chat.MaxLength)
	c.Chat.RateLimit = r.integer("CHAT_RATE_LIMIT", c.Chat.RateLimit)
	c.Chat.RateWindow = r.millis("CHAT_RATE_WINDOW_MS", c.Chat.RateWindow)

	c.Play.Package = r.str("GOOGLE_PLAY_PACKAGE", c.Play.Package)
	c.Play.CredentialsFile = r.str("GOOGLE_PLAY_CREDENTIALS_FILE", c.Play.CredentialsFile)
	c.Play.Credentials = r.str("GOOGLE_PLAY_CREDENTIALS", c.Play.Credentials)

	c.LogLevel = r.str("LOG_LEVEL", c.LogLevel)
	c.PublicDir = r.str("PUBLIC_DIR", c.PublicDir)
	c.RootRedirect = r.str("ROOT_REDIRECT", c.RootRedirect)
	c.RedisURL = r.str("REDIS_URL", c.RedisURL)
	c.LiveStateTTL = r.millis("LIVE_STATE_TTL_MS", c.LiveStateTTL)
	c.LiveInstanceID = r.str("LIVE_INSTANCE_ID", c.LiveInstanceID)
	c.LiveReconcile = r.millis("LIVE_RECONCILE_MS", c.LiveReconcile)

	if r.err != nil {
		return nil, r.err
	}
	if err := c.Validate(); err != nil {
		return nil, err
	}
	return c, nil
}

// schemaPattern is db/index.js's `/^[A-Za-z_][A-Za-z0-9_]*$/` — the schema
// name is interpolated into DDL and a connection option, so it must be a
// plain identifier.
var schemaPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// Validate applies the two production guards Node enforces at import
// (config/index.js:213-220), with Node's messages: in production the JWT
// secret must not be DefaultJWTSecret ("JWT_SECRET must be set in
// production") and AllowFakeProviders must be false
// ("AUTH_ALLOW_FAKE_PROVIDERS must be false in production"). It also rejects
// a DB.Schema that is not a plain identifier (db/index.js:35-37), which Node
// only caught at openDatabase.
func (c *Config) Validate() error {
	if c.Env == EnvProduction {
		if c.JWT.Secret == DefaultJWTSecret {
			return fmt.Errorf("JWT_SECRET must be set in production")
		}
		if c.AllowFakeProviders {
			return fmt.Errorf("AUTH_ALLOW_FAKE_PROVIDERS must be false in production")
		}
	}
	if !schemaPattern.MatchString(c.DB.Schema) {
		return fmt.Errorf("PG_SCHEMA must be a plain identifier, got %q", c.DB.Schema)
	}
	return nil
}

// TableRules is the per-table override RoomManager applies on top of the
// generic GameConfig when it creates a table (roomManager.js _createTable
// 100-146): the composition `{...config.game, ...categoryRules,
// ...privateRules, bootAmount}` reduced to the five fields those spreads
// touch. Everything else on the table copies GameConfig unchanged.
type TableRules struct {
	BootAmount         int64
	MaxRaiseSteps      int
	MaxBetRounds       int
	PotLimitMultiplier int64
	MaxPot             int64
}

// NormalizeCategory is RoomManager.normalizeCategory: "blind" iff the value
// is exactly "blind", otherwise "seen" (unknown and empty included).
func NormalizeCategory(category string) string {
	if category == CategoryBlind {
		return CategoryBlind
	}
	return CategorySeen
}

// TableRules composes the rules for one table exactly as Node does
// (roomManager.js:100-146; requirements 19 and 22):
//
//   - boot: PrivateBoot when private (never chosen), else bootAmount, else
//     (0) the default BootAmount;
//   - seen: {MaxRaiseSteps: SeenMaxRaiseSteps, MaxBetRounds:
//     SeenMaxBetRounds, MaxPot: SeenMaxPot} and the GENERIC
//     PotLimitMultiplier is kept (Node's seen rules never set it);
//   - blind: {MaxRaiseSteps: BlindMaxRaiseSteps, MaxBetRounds:
//     BlindMaxBetRounds, PotLimitMultiplier: BlindPotLimitMultiplier} and NO
//     maxPot key → the Table reads `config.maxPot ?? 0` → 0 (uncapped);
//   - private (either category) then overrides MaxPot = PrivateMaxPot and
//     MaxRaiseSteps = PrivateMaxRaiseSteps.
//
// With defaults: public seen 2/7/1024/1.2M, public blind 0/0/0/0, private
// seen 200 boot 2/7/1024/500k, private blind 200 boot 2/0/0/500k.
func (g GameConfig) TableRules(category string, bootAmount int64, isPrivate bool) TableRules {
	rules := TableRules{
		BootAmount:         bootAmount,
		MaxRaiseSteps:      g.MaxRaiseSteps,
		MaxBetRounds:       g.MaxBetRounds,
		PotLimitMultiplier: g.PotLimitMultiplier,
		MaxPot:             0,
	}
	if rules.BootAmount == 0 {
		rules.BootAmount = g.BootAmount
	}
	if NormalizeCategory(category) == CategorySeen {
		rules.MaxRaiseSteps = g.SeenMaxRaiseSteps
		rules.MaxBetRounds = g.SeenMaxBetRounds
		rules.MaxPot = g.SeenMaxPot
	} else {
		rules.MaxRaiseSteps = g.BlindMaxRaiseSteps
		rules.MaxBetRounds = g.BlindMaxBetRounds
		rules.PotLimitMultiplier = g.BlindPotLimitMultiplier
	}
	if isPrivate {
		rules.BootAmount = g.PrivateBoot
		rules.MaxPot = g.PrivateMaxPot
		rules.MaxRaiseSteps = g.PrivateMaxRaiseSteps
	}
	return rules
}

// MenuMaxPot is the `maxPot` a lobby menu entry advertises
// (roomManager.js lobbyOptions 196-223): SeenMaxPot for a seen entry, 0 for
// anything else.
func (g GameConfig) MenuMaxPot(category string) int64 {
	if category == CategorySeen {
		return g.SeenMaxPot
	}
	return 0
}

// list is Node's `list()`: split on ",", trim each entry, drop empties.
func list(value string) []string {
	var out []string
	for _, entry := range strings.Split(value, ",") {
		if trimmed := strings.TrimSpace(entry); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}
