package config

import (
	"fmt"
	"math"
	"net"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
)

// The vocabularies the free-form mappings and the word-valued keys are
// checked against. Each mirrors a list owned by another package, which this
// one does not import (config is read before anything else is built, and
// must not depend on the game logic): keep them equal to
//
//	PersonalityKinds  strategy.Kinds
//	TimingKinds       the timing.Kind constants
//	ChatMoments       the interaction.Moment constants
//	Categories        the Teen Patti categories the bots play (protocol.Category*)
//
// A name outside its list is refused at start-up rather than silently
// ignored by the package that would have read it.
var (
	PersonalityKinds = []string{"CAUTIOUS", "BALANCED", "AGGRESSIVE", "LOOSE", "RANDOM", "BEGINNER"}

	TimingKinds = []string{
		"see", "chaal", "blind_chaal", "fold", "small_raise", "large_raise", "show", "sideshow",
		"difficult", "join_table", "leave_table", "search_table", "chat", "answer_sideshow",
		"pick_variation", "pick_cards", "look_early",
	}

	ChatMoments = []string{
		"join", "welcome", "win", "big_win", "loss", "big_loss", "nice_hand", "strong_hand",
		"big_raise", "playing_blind", "sideshow_won", "sideshow_lost", "packed", "low_chips",
		"leave", "reply_hi", "reply_name", "variation", "five_card",
	}

	Categories = []string{"seen", "blind", "variation"}

	Languages  = []string{"mixed", "english", "hinglish"}
	LogLevels  = []string{"debug", "info", "warn", "error"}
	LogFormats = []string{"json", "text"}
)

// maxDevicePrefix bounds the device-id prefix; with the six-digit index it
// keeps a device id a reasonable length for the server's accounts table.
const maxDevicePrefix = 48

// maxIndex is the largest bot index the six-digit identity (%06d) holds.
const maxIndex = 999999

// Validate reports the first setting that is out of range or inconsistent
// with another, naming its key (and its environment variable, where it has
// one). It changes nothing: Load has already normalised case and the seed.
func (c *Config) Validate() error {
	checks := []func() error{
		c.validateTop,
		c.validateBots,
		c.validateSession,
		c.validateTable,
		c.validateTiming,
		c.validateStrategy,
		c.validateInteraction,
		c.validateReconnect,
		c.validateBankroll,
		c.validateAddrs,
		c.validateLog,
	}
	for _, check := range checks {
		if err := check(); err != nil {
			return err
		}
	}
	return nil
}

func (c *Config) validateTop() error {
	if !slices.Contains([]string{ModeServer, ModeSimulation}, c.Mode) {
		return fmt.Errorf("mode (BOT_MODE) is %q: want %q or %q", c.Mode, ModeServer, ModeSimulation)
	}
	if err := checkURL("server_url (SERVER_URL)", c.ServerURL, "http", "https"); err != nil {
		return err
	}
	if c.WSURL != "" {
		if err := checkURL("ws_url (WS_URL)", c.WSURL, "ws", "wss"); err != nil {
			return err
		}
	}
	return nil
}

func (c *Config) validateBots() error {
	b := c.Bots
	if b.Count < 0 || b.Count > MaxBots {
		return fmt.Errorf("bots.count (BOT_COUNT) is %d: want 0 to %d", b.Count, MaxBots)
	}
	if !strings.HasPrefix(b.DevicePrefix, RequiredDevicePrefix) {
		return fmt.Errorf("bots.device_prefix (BOT_DEVICE_PREFIX) is %q: it must start with %q, the namespace the game "+
			"server marks is_bot from (a bot outside it would be recorded as a human player)", b.DevicePrefix, RequiredDevicePrefix)
	}
	if len(b.DevicePrefix) > maxDevicePrefix {
		return fmt.Errorf("bots.device_prefix (BOT_DEVICE_PREFIX) is %d characters: at most %d", len(b.DevicePrefix), maxDevicePrefix)
	}
	for _, r := range b.DevicePrefix {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' || r == '.') {
			return fmt.Errorf("bots.device_prefix (BOT_DEVICE_PREFIX) is %q: letters, digits, '-', '_' and '.' only", b.DevicePrefix)
		}
	}
	if b.StartIndex < 0 {
		return fmt.Errorf("bots.start_index (BOT_START_INDEX) is %d: want 0 or more", b.StartIndex)
	}
	if last := b.StartIndex + b.Count - 1; b.Count > 0 && last > maxIndex {
		return fmt.Errorf("bots.start_index (BOT_START_INDEX) %d with bots.count %d reaches bot %d: the six-digit identity "+
			"stops at %d", b.StartIndex, b.Count, last, maxIndex)
	}
	if err := checkDurationRange("bots.start_stagger", b.StartStagger[0], b.StartStagger[1]); err != nil {
		return err
	}
	return checkWeights("bots.personality_mix", b.PersonalityMix, PersonalityKinds, "personality")
}

func (c *Config) validateSession() error {
	s := c.Session
	if s.MinDuration <= 0 {
		return fmt.Errorf("session.min_duration (BOT_SESSION_MIN_MINUTES) is %s: want more than 0", s.MinDuration)
	}
	if s.MaxDuration < s.MinDuration {
		return fmt.Errorf("session.max_duration (BOT_SESSION_MAX_MINUTES) %s is below session.min_duration %s",
			s.MaxDuration, s.MinDuration)
	}
	if s.RestMin < 0 {
		return fmt.Errorf("session.rest_min is %s: want 0 or more", s.RestMin)
	}
	if s.RestMax < s.RestMin {
		return fmt.Errorf("session.rest_max %s is below session.rest_min %s", s.RestMax, s.RestMin)
	}
	return nil
}

func (c *Config) validateTable() error {
	t := c.Table
	if t.MinHands < 1 {
		return fmt.Errorf("table.min_hands (BOT_MIN_HANDS) is %d: want 1 or more", t.MinHands)
	}
	if t.MaxHands < t.MinHands {
		return fmt.Errorf("table.max_hands (BOT_MAX_HANDS) %d is below table.min_hands %d", t.MaxHands, t.MinHands)
	}
	if len(t.Categories) == 0 {
		return fmt.Errorf("table.categories (BOT_CATEGORIES) is empty: name at least one of %s", strings.Join(Categories, ", "))
	}
	for i, cat := range t.Categories {
		if !slices.Contains(Categories, cat) {
			return fmt.Errorf("table.categories (BOT_CATEGORIES) names %q: the bots play %s", cat, strings.Join(Categories, ", "))
		}
		if slices.Contains(t.Categories[:i], cat) {
			return fmt.Errorf("table.categories (BOT_CATEGORIES) names %q twice", cat)
		}
	}
	// A weight for a category the bots are not playing (BOT_CATEGORIES can
	// narrow the file's list) is inert, not an error.
	if err := checkWeights("table.category_weights", t.CategoryWeights, Categories, "category"); err != nil {
		return err
	}
	if !(t.BootsToSit > 0) || math.IsInf(t.BootsToSit, 0) {
		return fmt.Errorf("table.boots_to_sit is %v: want a number above 0", t.BootsToSit)
	}
	if err := checkDurationRange("table.search_delay", t.SearchDelay[0], t.SearchDelay[1]); err != nil {
		return err
	}
	if t.MaxBotsPerTable < 0 {
		return fmt.Errorf("table.max_bots_per_table is %d: want 0 (no limit) or more", t.MaxBotsPerTable)
	}
	if t.NoHumanPatience < 0 {
		return fmt.Errorf("table.no_human_patience is %s: want 0 (never) or more", t.NoHumanPatience)
	}
	for i, key := range t.LobbyTables {
		cat, boot, ok := strings.Cut(key, ":")
		n, err := strconv.ParseInt(boot, 10, 64)
		if !ok || err != nil || n <= 0 {
			return fmt.Errorf("table.lobby_tables (BOT_LOBBY_TABLES) names %q: want category:boot, such as seen:200", key)
		}
		if !slices.Contains(t.Categories, cat) {
			return fmt.Errorf("table.lobby_tables (BOT_LOBBY_TABLES) names %q: its category is not one table.categories plays (%s)", key, strings.Join(t.Categories, ", "))
		}
		if slices.Contains(t.LobbyTables[:i], key) {
			return fmt.Errorf("table.lobby_tables (BOT_LOBBY_TABLES) names %q twice", key)
		}
	}
	if f := t.FleetPerTable; !fleetSizeOK(f) {
		return fmt.Errorf("table.fleet_per_table (BOT_FLEET_PER_TABLE) is [%d, %d]: want [floor, ceiling], 0 or more, the floor no higher than the ceiling (a ceiling of 0 is none)", f[0], f[1])
	}
	// A table's own fleet= size (ParseLobbyTable has refused a bad one
	// already; this holds a Config built any other way to the same rule).
	for _, key := range sortedKeys(t.FleetByTable) {
		if !slices.Contains(t.LobbyTables, key) {
			return fmt.Errorf("table.lobby_tables (BOT_LOBBY_TABLES) gives %q a fleet= size but does not list it", key)
		}
		if f := t.FleetByTable[key]; !fleetSizeOK(f) {
			return fmt.Errorf("table.lobby_tables (BOT_LOBBY_TABLES) gives %s fleet=%d-%d: want FLOOR-CEILING, 0 or more, the floor no higher than the ceiling (a ceiling of 0 is none)", key, f[0], f[1])
		}
	}
	return nil
}

// fleetSizeOK reports whether [floor, ceiling] is a size the fleet can keep:
// both 0 or more, the floor no higher than the ceiling unless the ceiling is
// 0 (none).
func fleetSizeOK(f [2]int) bool {
	return f[0] >= 0 && f[1] >= 0 && (f[1] == 0 || f[0] <= f[1])
}

func (c *Config) validateTiming() error {
	t := c.Timing
	if t.MinReaction <= 0 {
		return fmt.Errorf("timing.min_reaction is %s: want more than 0", t.MinReaction)
	}
	if t.MaxReaction < t.MinReaction {
		return fmt.Errorf("timing.max_reaction %s is below timing.min_reaction %s", t.MaxReaction, t.MinReaction)
	}
	if t.SafetyMargin <= 0 {
		// 0 would let a move land on the turn clock's last millisecond (and
		// the timing model reads 0 as "the default" anyway): refuse it.
		return fmt.Errorf("timing.safety_margin is %s: want more than 0", t.SafetyMargin)
	}
	for _, name := range sortedKeys(t.Ranges) {
		if !slices.Contains(TimingKinds, name) {
			return fmt.Errorf("timing.ranges.%s: unknown kind %q (want one of %s)", name, name, strings.Join(TimingKinds, ", "))
		}
		r := t.Ranges[name]
		if r[0] < 0 || r[1] < r[0] {
			return fmt.Errorf("timing.ranges.%s is [%d, %d] ms: want 0 ≤ min ≤ max", name, r[0], r[1])
		}
	}
	return nil
}

func (c *Config) validateStrategy() error {
	s := c.Strategy
	if !s.EnableBlind && !s.EnableSeen {
		return fmt.Errorf("strategy.enable_blind and strategy.enable_seen are both false: a bot must either stay blind or look at its cards")
	}
	for _, kind := range sortedKeys(s.Tuning) {
		if !slices.Contains(PersonalityKinds, kind) {
			return fmt.Errorf("strategy.tuning.%s: unknown personality %q (want one of %s)", kind, kind, strings.Join(PersonalityKinds, ", "))
		}
		traits := s.Tuning[kind]
		for _, trait := range sortedKeys(traits) {
			r := traits[trait]
			if !finite(r[0]) || !finite(r[1]) || r[1] < r[0] {
				return fmt.Errorf("strategy.tuning.%s.%s is [%v, %v]: want low ≤ high", kind, trait, r[0], r[1])
			}
		}
	}
	return nil
}

func (c *Config) validateInteraction() error {
	in := c.Interaction
	for _, name := range sortedKeys(in.Probabilities) {
		if !slices.Contains(ChatMoments, name) {
			return fmt.Errorf("interaction.probabilities.%s: unknown moment %q (want one of %s)", name, name, strings.Join(ChatMoments, ", "))
		}
		r := in.Probabilities[name]
		if !(r[0] >= 0 && r[0] <= r[1] && r[1] <= 1) {
			return fmt.Errorf("interaction.probabilities.%s is [%v, %v]: want 0 ≤ low ≤ high ≤ 1", name, r[0], r[1])
		}
	}
	if in.Cooldown < 0 {
		return fmt.Errorf("interaction.cooldown is %s: want 0 or more", in.Cooldown)
	}
	if in.TableGap < 0 {
		return fmt.Errorf("interaction.table_gap is %s: want 0 or more", in.TableGap)
	}
	if in.TablePerMin < 0 {
		return fmt.Errorf("interaction.table_per_min is %d: want 0 or more", in.TablePerMin)
	}
	if !slices.Contains(Languages, in.Language) {
		return fmt.Errorf("interaction.language is %q: want %s", in.Language, strings.Join(Languages, " or "))
	}
	return nil
}

func (c *Config) validateReconnect() error {
	r := c.Reconnect
	if r.BaseDelay <= 0 {
		return fmt.Errorf("reconnect.base_delay is %s: want more than 0", r.BaseDelay)
	}
	if r.MaxDelay < r.BaseDelay {
		return fmt.Errorf("reconnect.max_delay (BOT_RECONNECT_MAX_DELAY_SECONDS) %s is below reconnect.base_delay %s",
			r.MaxDelay, r.BaseDelay)
	}
	if r.MaxAttempts < 0 {
		return fmt.Errorf("reconnect.max_attempts is %d: want 0 (for ever) or more", r.MaxAttempts)
	}
	return nil
}

func (c *Config) validateBankroll() error {
	if c.Bankroll.DevReplenish && c.Mode != ModeSimulation {
		return fmt.Errorf("bankroll.dev_replenish (BOT_DEV_REPLENISH) is on in %s mode: it is allowed only in simulation "+
			"(no chips are minted against a real server)", c.Mode)
	}
	return nil
}

func (c *Config) validateAddrs() error {
	if c.Debug.Addr != "" {
		host, err := checkAddr("debug.addr (BOT_DEBUG_ADDR)", c.Debug.Addr)
		if err != nil {
			return err
		}
		// The debug view has no authentication and names every bot and its
		// account — exactly what the fleet exists not to tell other players —
		// and, with show_cards, the cards in its hand.
		if !isLoopback(host) {
			return fmt.Errorf("debug.addr (BOT_DEBUG_ADDR) is %q: bind it to loopback (127.0.0.1, ::1 or localhost); "+
				"the debug view has no authentication and names every bot", c.Debug.Addr)
		}
	}
	if c.Metrics.Addr != "" {
		if _, err := checkAddr("metrics.addr (BOT_METRICS_ADDR)", c.Metrics.Addr); err != nil {
			return err
		}
	}
	return nil
}

func (c *Config) validateLog() error {
	if !slices.Contains(LogLevels, c.Log.Level) {
		return fmt.Errorf("log.level (LOG_LEVEL) is %q: want %s", c.Log.Level, strings.Join(LogLevels, ", "))
	}
	if !slices.Contains(LogFormats, c.Log.Format) {
		return fmt.Errorf("log.format (LOG_FORMAT) is %q: want %s", c.Log.Format, strings.Join(LogFormats, " or "))
	}
	return nil
}

// ---------------------------------------------------------------------------
// Helpers.

func checkURL(key, raw string, schemes ...string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("%s is %q: not a URL (%v)", key, raw, err)
	}
	if !slices.Contains(schemes, strings.ToLower(u.Scheme)) {
		return fmt.Errorf("%s is %q: want an address starting %s://", key, raw, strings.Join(schemes, ":// or "))
	}
	if u.Host == "" || u.Hostname() == "" {
		return fmt.Errorf("%s is %q: it names no host", key, raw)
	}
	if u.User != nil {
		return fmt.Errorf("%s is %q: credentials do not belong in the address", key, raw)
	}
	if u.Fragment != "" {
		return fmt.Errorf("%s is %q: an address has no #fragment", key, raw)
	}
	return nil
}

// checkAddr checks host:port (host may be empty, meaning every interface)
// and returns the host.
func checkAddr(key, addr string) (string, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return "", fmt.Errorf("%s is %q: want host:port, e.g. 127.0.0.1:9100", key, addr)
	}
	p, err := strconv.Atoi(port)
	if err != nil || p < 0 || p > 65535 {
		return "", fmt.Errorf("%s is %q: the port must be a number from 0 to 65535", key, addr)
	}
	return host, nil
}

func isLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func checkDurationRange(key string, lo, hi time.Duration) error {
	if lo < 0 {
		return fmt.Errorf("%s starts at %s: want 0 or more", key, lo)
	}
	if hi < lo {
		return fmt.Errorf("%s is [%s, %s]: the high end is below the low", key, lo, hi)
	}
	return nil
}

func checkWeights(key string, w map[string]float64, vocab []string, what string) error {
	total := 0.0
	for _, name := range sortedKeys(w) {
		if !slices.Contains(vocab, name) {
			return fmt.Errorf("%s.%s: unknown %s %q (want one of %s)", key, name, what, name, strings.Join(vocab, ", "))
		}
		v := w[name]
		if !finite(v) || v < 0 {
			return fmt.Errorf("%s.%s is %v: a weight is 0 or more", key, name, v)
		}
		total += v
	}
	if len(w) > 0 && total == 0 {
		return fmt.Errorf("%s: every weight is 0; leave it empty for an even mix", key)
	}
	return nil
}

func finite(f float64) bool { return !math.IsNaN(f) && !math.IsInf(f, 0) }

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

func lowerTrim(s string) string { return strings.ToLower(strings.TrimSpace(s)) }

func trimTrailingSlash(s string) string {
	s = strings.TrimSpace(s)
	for strings.HasSuffix(s, "/") && !strings.HasSuffix(s, "://") {
		s = strings.TrimSuffix(s, "/")
	}
	return s
}
