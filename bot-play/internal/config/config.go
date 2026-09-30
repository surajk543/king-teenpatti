// Package config is bot-play's configuration: a YAML file (configs/bot.yaml)
// with environment variables layered on top, in the go-server's style — every
// key has a default, integers and durations parse strictly, and a bad value
// stops the process naming the key.
//
// The order is: Default(), then the YAML file (yaml.go: a strict walk that
// refuses an unknown key, a value of the wrong type, and two spellings of the
// same setting), then the environment (env.go), then Validate
// (validate.go). Nothing is read again after Load returns.
package config

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// DefaultPath is where Load looks when it is given the default location.
// A file missing THERE is not an error (the defaults and the environment are
// a complete configuration); a missing file anywhere else is, because a path
// somebody typed is a file they expect to be read.
const DefaultPath = "configs/bot.yaml"

// SimulationSeed is the seed a simulation runs with when none is given, so a
// simulation is repeatable by default (a server-mode fleet with seed 0 draws
// its seed from the clock instead).
const SimulationSeed uint64 = 12345

// MaxBots is the most bots one process runs (bots.count / BOT_COUNT).
const MaxBots = 10000

// RequiredDevicePrefix is the namespace every bot's device id must be in: the
// game server marks an account is_bot from its guest device id's prefix
// (go-server BOT_DEVICE_PREFIX, "botplay-" among its defaults), and a bot
// outside it would be recorded as a human player.
const RequiredDevicePrefix = "botplay-"

// Modes a fleet runs in.
const (
	ModeServer     = "server"     // against a real game server at ServerURL
	ModeSimulation = "simulation" // against the in-process simulated server (internal/sim)
)

// Config is everything bot-play reads.
type Config struct {
	Mode      string // BOT_MODE: "server" (default) | "simulation"
	ServerURL string // SERVER_URL: http(s)://host[:port], default http://127.0.0.1:3000
	WSURL     string // WS_URL: optional websocket override
	Seed      uint64 // BOT_SEED: 0 = from the clock (simulation defaults to 12345)

	Bots struct {
		Count          int                // BOT_COUNT, default 20
		DevicePrefix   string             // BOT_DEVICE_PREFIX, default "botplay-"
		StartIndex     int                // BOT_START_INDEX, default 1: bot i is <prefix><%06d of StartIndex+i>
		StartStagger   [2]time.Duration   // gap between starting bots, drawn per bot; default 0.4–2.5 s
		PersonalityMix map[string]float64 // kind → weight; empty = even
	}
	Session struct {
		MinDuration time.Duration // default 20 m
		MaxDuration time.Duration // default 2 h
		RestMin     time.Duration // between sessions, default 5 m
		RestMax     time.Duration // default 45 m
	}
	Table struct {
		MinHands        int                // default 3
		MaxHands        int                // default 20
		Categories      []string           // default seen, blind, variation
		CategoryWeights map[string]float64 // default even
		BootsToSit      float64            // default 25
		SearchDelay     [2]time.Duration   // idle before looking for a table, default 2.5–8 s
		MaxBotsPerTable int                // default 0 (no limit)
		NoHumanPatience time.Duration      // default 0 (bots may play among themselves)
		// LobbyTables are the lobby tables the fleet plays, by key
		// ("seen:200", "blind:50000"); empty = every table of Categories.
		// An entry as written may carry its own fleet size after the key
		// ("blind:200:fleet=50-80", ParseLobbyTable): the key is kept here,
		// the size in FleetByTable.
		LobbyTables []string
		// FleetPerTable is how many of the fleet's bots each lobby table (a
		// category and a boot, however many rooms it runs) should hold:
		// [floor, ceiling]. Tables under their floor are filled first; one at
		// its ceiling takes no more. 0 = none for either.
		FleetPerTable [2]int
		// FleetByTable is, per lobby table key, that table's own [floor,
		// ceiling] — the fleet= option of its LobbyTables entry (owner, 30 Sep
		// 2026: more of the fleet at Blind 200 and Blind 50,000 than at the
		// other tables). A table it does not name takes FleetPerTable.
		FleetByTable map[string][2]int
	}
	Timing struct {
		MinReaction  time.Duration     // default 700 ms
		MaxReaction  time.Duration     // default 5 s
		SafetyMargin time.Duration     // default 3 s
		Ranges       map[string][2]int // kind → [min_ms, max_ms]
	}
	Strategy struct {
		EnableBlind bool                             // default true
		EnableSeen  bool                             // default true
		Tuning      map[string]map[string][2]float64 // kind → trait → [lo, hi]
	}
	Interaction struct {
		EnableChat    bool                  // default true
		EnableEmotes  bool                  // default false (the bots own no emojis)
		Probabilities map[string][2]float64 // moment → [lo, hi]
		Cooldown      time.Duration         // default 12 s
		TableGap      time.Duration         // default 6 s
		TablePerMin   int                   // default 6
		Language      string                // default "mixed"
	}
	Reconnect struct {
		BaseDelay   time.Duration // default 1 s
		MaxDelay    time.Duration // default 30 s
		MaxAttempts int           // 0 = forever
	}
	Bankroll struct {
		CollectBonus bool // default true: a broke bot collects the 6-hour bonus, as any player
		DevReplenish bool // default false; refused unless Mode is "simulation" (no chip minting against a real server)
	}
	Debug struct {
		Addr      string // BOT_DEBUG_ADDR, default "" (off); e.g. 127.0.0.1:9101 — loopback only
		ShowCards bool   // BOT_DEBUG_SHOW_CARDS, default false
	}
	Metrics struct {
		Addr string // BOT_METRICS_ADDR, default "" (off); e.g. 127.0.0.1:9101 (9100 is node_exporter's in go-server/ops/monitoring)
	}
	Log struct {
		Level  string // LOG_LEVEL, default info
		Format string // LOG_FORMAT: json (default) | text
	}
}

// Default is the configuration with every default filled in. Every call
// returns fresh maps and slices, so a caller may change its copy freely.
func Default() Config {
	var c Config
	c.Mode = ModeServer
	c.ServerURL = "http://127.0.0.1:3000"
	c.WSURL = ""
	c.Seed = 0

	c.Bots.Count = 20
	c.Bots.DevicePrefix = RequiredDevicePrefix
	c.Bots.StartIndex = 1
	c.Bots.StartStagger = [2]time.Duration{400 * time.Millisecond, 2500 * time.Millisecond}
	c.Bots.PersonalityMix = map[string]float64{}

	c.Session.MinDuration = 20 * time.Minute
	c.Session.MaxDuration = 2 * time.Hour
	c.Session.RestMin = 5 * time.Minute
	c.Session.RestMax = 45 * time.Minute

	c.Table.MinHands = 3
	c.Table.MaxHands = 20
	c.Table.Categories = []string{"seen", "blind", "variation"}
	c.Table.CategoryWeights = map[string]float64{}
	c.Table.BootsToSit = 25
	c.Table.SearchDelay = [2]time.Duration{2500 * time.Millisecond, 8 * time.Second}
	c.Table.MaxBotsPerTable = 0
	c.Table.NoHumanPatience = 0
	c.Table.LobbyTables = []string{}
	c.Table.FleetPerTable = [2]int{0, 0}
	c.Table.FleetByTable = map[string][2]int{}

	c.Timing.MinReaction = 700 * time.Millisecond
	c.Timing.MaxReaction = 5 * time.Second
	c.Timing.SafetyMargin = 3 * time.Second
	c.Timing.Ranges = map[string][2]int{}

	c.Strategy.EnableBlind = true
	c.Strategy.EnableSeen = true
	c.Strategy.Tuning = map[string]map[string][2]float64{}

	c.Interaction.EnableChat = true
	c.Interaction.EnableEmotes = false
	c.Interaction.Probabilities = map[string][2]float64{}
	c.Interaction.Cooldown = 12 * time.Second
	c.Interaction.TableGap = 6 * time.Second
	c.Interaction.TablePerMin = 6
	c.Interaction.Language = "mixed"

	c.Reconnect.BaseDelay = time.Second
	c.Reconnect.MaxDelay = 30 * time.Second
	c.Reconnect.MaxAttempts = 0

	c.Bankroll.CollectBonus = true
	c.Bankroll.DevReplenish = false

	c.Debug.Addr = ""
	c.Debug.ShowCards = false
	c.Metrics.Addr = ""
	c.Log.Level = "info"
	c.Log.Format = "json"
	return c
}

// Load reads path, then applies environment overrides read through getenv
// (nil reads nothing; a variable read as "" counts as unset), then validates.
//
// An empty path reads no file. A missing file at DefaultPath is skipped — the
// defaults and the environment are a complete configuration — but a missing
// file at any other path is an error. Every error names the key (for the
// file, its dotted path and line; for the environment, the variable).
func Load(path string, getenv func(string) string) (Config, error) {
	c := Default()
	if path != "" {
		data, err := os.ReadFile(path)
		switch {
		case err == nil:
			if err := decodeYAML(&c, data); err != nil {
				return Config{}, fmt.Errorf("config %s: %w", path, err)
			}
		case errors.Is(err, fs.ErrNotExist) && filepath.Clean(path) == filepath.Clean(DefaultPath):
			// The default file is optional.
		default:
			return Config{}, fmt.Errorf("config: %w", err)
		}
	}
	if getenv != nil {
		if err := applyEnv(&c, getenv); err != nil {
			return Config{}, fmt.Errorf("config: environment %w", err)
		}
	}
	c.finish()
	if err := c.Validate(); err != nil {
		return Config{}, fmt.Errorf("config: %w", err)
	}
	return c, nil
}

// finish settles what the sources leave open: the mode, categories and log
// words are compared in lower case, a trailing slash is dropped from the
// server's address, and a simulation with no seed takes SimulationSeed so it
// is repeatable.
func (c *Config) finish() {
	c.Mode = lowerTrim(c.Mode)
	c.ServerURL = trimTrailingSlash(c.ServerURL)
	for i, cat := range c.Table.Categories {
		c.Table.Categories[i] = lowerTrim(cat)
	}
	for i, key := range c.Table.LobbyTables {
		c.Table.LobbyTables[i] = lowerTrim(key)
	}
	c.Interaction.Language = lowerTrim(c.Interaction.Language)
	c.Log.Level = lowerTrim(c.Log.Level)
	c.Log.Format = lowerTrim(c.Log.Format)
	if c.Mode == ModeSimulation && c.Seed == 0 {
		c.Seed = SimulationSeed
	}
}

// fleetOption is the one option a table.lobby_tables entry takes after its
// key: fleet=FLOOR-CEILING.
const fleetOption = "fleet"

// ParseLobbyTable reads one table.lobby_tables entry: a key, category:boot,
// optionally followed by options in the game server's LOBBY_TABLES style
// ("blind:5000:max=200000000"). The one option the fleet knows is
// fleet=FLOOR-CEILING, that table's own floor and ceiling of the fleet's
// bots in place of table.fleet_per_table (a ceiling of 0 is none, as there):
//
//	seen:200               key seen:200, table.fleet_per_table's size
//	blind:200:fleet=50-80  key blind:200, floor 50, ceiling 80
//
// The entry is read in lower case, each option trimmed. An empty option, an
// unknown one, fleet= given twice, or a range that is not two whole numbers
// with the floor no higher than the ceiling is an error naming the entry.
// The key itself — category:boot, a category the fleet plays, listed once —
// is Validate's to check.
func ParseLobbyTable(entry string) (key string, fleet [2]int, hasFleet bool, err error) {
	entry = lowerTrim(entry)
	parts := strings.Split(entry, ":")
	if len(parts) <= 2 {
		return entry, [2]int{}, false, nil
	}
	key = parts[0] + ":" + parts[1]
	for _, opt := range parts[2:] {
		opt = strings.TrimSpace(opt)
		name, value, found := strings.Cut(opt, "=")
		switch name = strings.TrimSpace(name); {
		case opt == "":
			return "", [2]int{}, false, fmt.Errorf("entry %q has an empty option: want %s or %s:fleet=FLOOR-CEILING", entry, key, key)
		case name != fleetOption:
			return "", [2]int{}, false, fmt.Errorf("entry %q: unknown option %q (the one option is fleet=FLOOR-CEILING, such as %s:fleet=50-80)", entry, opt, key)
		case hasFleet:
			return "", [2]int{}, false, fmt.Errorf("entry %q gives fleet= twice", entry)
		case !found:
			return "", [2]int{}, false, fmt.Errorf("entry %q: fleet needs a range, fleet=FLOOR-CEILING (such as fleet=50-80)", entry)
		}
		if fleet, err = parseFleetRange(strings.TrimSpace(value)); err != nil {
			return "", [2]int{}, false, fmt.Errorf("entry %q: %w", entry, err)
		}
		hasFleet = true
	}
	return key, fleet, hasFleet, nil
}

// parseFleetRange reads a fleet= option's FLOOR-CEILING: two whole numbers,
// 0 or more, the floor no higher than the ceiling unless the ceiling is 0
// (none).
func parseFleetRange(v string) ([2]int, error) {
	lo, hi, ok := strings.Cut(v, "-")
	floor, errLo := wholeDigits(lo)
	ceiling, errHi := wholeDigits(hi)
	if !ok || errLo != nil || errHi != nil {
		return [2]int{}, fmt.Errorf("fleet=%s is not FLOOR-CEILING, two whole numbers such as fleet=50-80", v)
	}
	if ceiling > 0 && floor > ceiling {
		return [2]int{}, fmt.Errorf("fleet=%s puts the floor %d above the ceiling %d (a ceiling of 0 is none)", v, floor, ceiling)
	}
	return [2]int{floor, ceiling}, nil
}

// wholeDigits is a whole number written in decimal digits alone (spaces
// around it allowed; no sign).
func wholeDigits(s string) (int, error) {
	s = strings.TrimSpace(s)
	if s == "" || strings.TrimLeft(s, "0123456789") != "" {
		return 0, fmt.Errorf("%q is not a whole number", s)
	}
	return strconv.Atoi(s)
}

// readLobbyTables parses table.lobby_tables entries (ParseLobbyTable) into
// their keys and each one's own fleet size. at names an entry for an error
// (its index in entries).
func readLobbyTables(entries []string, at func(i int, err error) error) ([]string, map[string][2]int, error) {
	keys := make([]string, 0, len(entries))
	fleet := map[string][2]int{}
	for i, e := range entries {
		key, f, has, err := ParseLobbyTable(e)
		if err != nil {
			return nil, nil, at(i, err)
		}
		keys = append(keys, key)
		if has {
			fleet[key] = f
		}
	}
	return keys, fleet, nil
}
