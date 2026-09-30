package config

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// EnvKeys is every environment variable Load reads, in the order it reads
// them. Each overrides the file's value for its key.
var EnvKeys = []string{
	"BOT_MODE",                        // mode
	"SERVER_URL",                      // server_url
	"WS_URL",                          // ws_url
	"BOT_SEED",                        // seed
	"BOT_COUNT",                       // bots.count
	"BOT_DEVICE_PREFIX",               // bots.device_prefix
	"BOT_START_INDEX",                 // bots.start_index
	"BOT_MIN_HANDS",                   // table.min_hands
	"BOT_MAX_HANDS",                   // table.max_hands
	"BOT_SESSION_MIN_MINUTES",         // session.min_duration, whole minutes
	"BOT_SESSION_MAX_MINUTES",         // session.max_duration, whole minutes
	"BOT_CATEGORIES",                  // table.categories, comma-separated
	"BOT_ENABLE_CHAT",                 // interaction.enable_chat
	"BOT_DEBUG_ADDR",                  // debug.addr
	"BOT_DEBUG_SHOW_CARDS",            // debug.show_cards
	"BOT_METRICS_ADDR",                // metrics.addr
	"LOG_LEVEL",                       // log.level
	"LOG_FORMAT",                      // log.format
	"BOT_RECONNECT_MAX_DELAY_SECONDS", // reconnect.max_delay, whole seconds
	"BOT_COLLECT_BONUS",               // bankroll.collect_bonus
	"BOT_DEV_REPLENISH",               // bankroll.dev_replenish
	"BOT_BOOTS_TO_SIT",                // table.boots_to_sit
	"BOT_LOBBY_TABLES",                // table.lobby_tables, comma-separated entries (seen:200,blind:50000:fleet=50-80)
	"BOT_FLEET_PER_TABLE",             // table.fleet_per_table, "floor,ceiling" (30,50)
}

// envReader reads the overrides through getenv, strictly, and keeps the
// first failure so the operator sees one clear message (the go-server's rule).
// A variable read as "" is unset: getenv cannot tell the two apart.
type envReader struct {
	getenv func(string) string
	err    error
}

func (r *envReader) fail(key, raw, why string) {
	if r.err == nil {
		r.err = fmt.Errorf("%s=%q: %s", key, raw, why)
	}
}

func (r *envReader) raw(key string) (string, bool) {
	v := r.getenv(key)
	return v, v != ""
}

// str sets *dst to the variable's value when it is set.
func (r *envReader) str(key string, dst *string) {
	if v, ok := r.raw(key); ok {
		*dst = strings.TrimSpace(v)
	}
}

// whole sets *dst to a decimal integer (surrounding spaces and a sign
// allowed, nothing else).
func (r *envReader) whole(key string, dst *int) {
	v, ok := r.raw(key)
	if !ok {
		return
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		r.fail(key, v, "expected a whole number")
		return
	}
	*dst = n
}

// unsigned sets *dst to a decimal integer from 0 up.
func (r *envReader) unsigned(key string, dst *uint64) {
	v, ok := r.raw(key)
	if !ok {
		return
	}
	n, err := strconv.ParseUint(strings.TrimSpace(v), 10, 64)
	if err != nil {
		r.fail(key, v, "expected a whole number from 0 up")
		return
	}
	*dst = n
}

// number sets *dst to a finite decimal number.
func (r *envReader) number(key string, dst *float64) {
	v, ok := r.raw(key)
	if !ok {
		return
	}
	n, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
	if err != nil || math.IsNaN(n) || math.IsInf(n, 0) {
		r.fail(key, v, "expected a number")
		return
	}
	*dst = n
}

// wholePair sets *dst to two comma-separated whole numbers, "low,high".
func (r *envReader) wholePair(key string, dst *[2]int) {
	v, ok := r.raw(key)
	if !ok {
		return
	}
	parts := strings.Split(v, ",")
	if len(parts) != 2 {
		r.fail(key, v, "expected two whole numbers, low,high")
		return
	}
	var out [2]int
	for i, part := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil {
			r.fail(key, v, "expected two whole numbers, low,high")
			return
		}
		out[i] = n
	}
	*dst = out
}

// count sets *dst to a whole number of unit, 0 or more.
func (r *envReader) count(key string, dst *time.Duration, unit time.Duration, unitName string) {
	v, ok := r.raw(key)
	if !ok {
		return
	}
	n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
	if err != nil || n < 0 || n > int64(^uint64(0)>>1)/int64(unit) {
		r.fail(key, v, "expected a whole number of "+unitName+", 0 or more")
		return
	}
	*dst = time.Duration(n) * unit
}

// flag sets *dst from 1/true/yes/on or 0/false/no/off (any case). Anything
// else is an error: a switch typed wrong must not silently read as off.
func (r *envReader) flag(key string, dst *bool) {
	v, ok := r.raw(key)
	if !ok {
		return
	}
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		*dst = true
	case "0", "false", "no", "off":
		*dst = false
	default:
		r.fail(key, v, "expected true or false (1/0, yes/no, on/off)")
	}
}

// list sets *dst to the comma-separated entries, each trimmed, empty ones
// dropped.
func (r *envReader) list(key string, dst *[]string) {
	v, ok := r.raw(key)
	if !ok {
		return
	}
	out := []string{}
	for _, part := range strings.Split(v, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	*dst = out
}

// lobbyTables sets *keys and *fleet from table.lobby_tables' comma-separated
// entries, each a key with an optional fleet= option (ParseLobbyTable). Set,
// it replaces the file's list and the file's fleet sizes with it.
func (r *envReader) lobbyTables(key string, keys *[]string, fleet *map[string][2]int) {
	v, ok := r.raw(key)
	if !ok {
		return
	}
	var entries []string
	r.list(key, &entries)
	k, f, err := readLobbyTables(entries, func(_ int, err error) error { return err })
	if err != nil {
		r.fail(key, v, err.Error())
		return
	}
	*keys, *fleet = k, f
}

// applyEnv lays the environment over c (every key in EnvKeys).
func applyEnv(c *Config, getenv func(string) string) error {
	r := &envReader{getenv: getenv}
	r.str("BOT_MODE", &c.Mode)
	r.str("SERVER_URL", &c.ServerURL)
	r.str("WS_URL", &c.WSURL)
	r.unsigned("BOT_SEED", &c.Seed)
	r.whole("BOT_COUNT", &c.Bots.Count)
	r.str("BOT_DEVICE_PREFIX", &c.Bots.DevicePrefix)
	r.whole("BOT_START_INDEX", &c.Bots.StartIndex)
	r.whole("BOT_MIN_HANDS", &c.Table.MinHands)
	r.whole("BOT_MAX_HANDS", &c.Table.MaxHands)
	r.count("BOT_SESSION_MIN_MINUTES", &c.Session.MinDuration, time.Minute, "minutes")
	r.count("BOT_SESSION_MAX_MINUTES", &c.Session.MaxDuration, time.Minute, "minutes")
	r.list("BOT_CATEGORIES", &c.Table.Categories)
	r.flag("BOT_ENABLE_CHAT", &c.Interaction.EnableChat)
	r.str("BOT_DEBUG_ADDR", &c.Debug.Addr)
	r.flag("BOT_DEBUG_SHOW_CARDS", &c.Debug.ShowCards)
	r.str("BOT_METRICS_ADDR", &c.Metrics.Addr)
	r.str("LOG_LEVEL", &c.Log.Level)
	r.str("LOG_FORMAT", &c.Log.Format)
	r.count("BOT_RECONNECT_MAX_DELAY_SECONDS", &c.Reconnect.MaxDelay, time.Second, "seconds")
	r.flag("BOT_COLLECT_BONUS", &c.Bankroll.CollectBonus)
	r.flag("BOT_DEV_REPLENISH", &c.Bankroll.DevReplenish)
	r.number("BOT_BOOTS_TO_SIT", &c.Table.BootsToSit)
	r.lobbyTables("BOT_LOBBY_TABLES", &c.Table.LobbyTables, &c.Table.FleetByTable)
	r.wholePair("BOT_FLEET_PER_TABLE", &c.Table.FleetPerTable)
	return r.err
}
