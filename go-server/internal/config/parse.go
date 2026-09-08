package config

import (
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// reader applies Node's `num` / `bool` / `list` / `??` rules over a Lookup and
// collects the first parse failure (DECISIONS.md §5: malformed integers fail
// startup instead of silently taking the default).
type reader struct {
	lookup Lookup
	err    error
}

// fail records the first error; later ones are dropped so the operator sees
// one clear message per boot.
func (r *reader) fail(key, raw, why string) {
	if r.err == nil {
		r.err = fmt.Errorf("%s=%q: %s", key, raw, why)
	}
}

// str is `process.env.KEY ?? fallback`: an unset variable takes the default,
// a set-but-empty one is honoured as "".
func (r *reader) str(key, fallback string) string {
	if v, ok := r.lookup(key); ok {
		return v
	}
	return fallback
}

// int64 is Node's `num(value, fallback)` under the strict rule: unset or ""
// → fallback; otherwise a decimal integer (surrounding whitespace and a sign
// allowed, as parseInt allowed) or a recorded failure.
func (r *reader) int64(key string, fallback int64) int64 {
	raw, ok := r.lookup(key)
	if !ok || raw == "" {
		return fallback
	}
	n, err := parseInt(raw)
	if err != nil {
		r.fail(key, raw, "expected a decimal integer")
		return fallback
	}
	return n
}

// integer is int64 narrowed to int for counts.
func (r *reader) integer(key string, fallback int) int {
	return int(r.int64(key, int64(fallback)))
}

// millis reads a *_MS integer as a duration.
func (r *reader) millis(key string, fallback time.Duration) time.Duration {
	return time.Duration(r.int64(key, fallback.Milliseconds())) * time.Millisecond
}

// boolean is Node's `bool(value, fallback)`: unset or "" → fallback, else true
// iff the lower-cased value is one of 1 / true / yes / on. Anything else is
// false (Node made no attempt to reject "garbage" here and neither do we).
func (r *reader) boolean(key string, fallback bool) bool {
	raw, ok := r.lookup(key)
	if !ok || raw == "" {
		return fallback
	}
	switch strings.ToLower(raw) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// list is `list(process.env.KEY)` — for GOOGLE_CLIENT_IDS and
// METRICS_ALLOW_IPS an unset variable is the same as an empty one.
func (r *reader) list(key string, fallback []string) []string {
	raw, ok := r.lookup(key)
	if !ok {
		return fallback
	}
	return list(raw)
}

// parseInt is the strict replacement for Number.parseInt(value, 10): the
// whole (trimmed) string must be an optionally signed run of ASCII digits.
func parseInt(raw string) (int64, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return 0, fmt.Errorf("empty")
	}
	return strconv.ParseInt(trimmed, 10, 64)
}

// parseTableStakes is config/index.js:70-72:
//
//	list(v).map(parseInt).filter(isInteger && > 0)
//
// Entries ≤ 0 are dropped as Node's filter dropped them; an entry that is
// not an integer at all is an error (DECISIONS.md §5). Duplicates and order
// are kept — the slice is what lobbyOptions().stakes sends verbatim. The
// result is never nil so it marshals as [] when empty.
func parseTableStakes(raw string) ([]int64, error) {
	stakes := []int64{}
	for _, entry := range list(raw) {
		n, err := parseInt(entry)
		if err != nil {
			return nil, fmt.Errorf("stake %q is not an integer", entry)
		}
		if n > 0 {
			stakes = append(stakes, n)
		}
	}
	return stakes, nil
}

// parseLobbyTables is config/index.js:85-90: each entry is "category:boot",
// both halves trimmed. Under DECISIONS.md §3/§5 an entry without exactly one
// colon, with a category other than seen|blind, or with a non-integer boot is
// an error (Node dropped the NaN cases silently and kept unknown categories).
// A boot of 0 or less passes, as Number.isInteger let it through. The result
// is never nil.
func parseLobbyTables(raw string) ([]LobbyTable, error) {
	tables := []LobbyTable{}
	for _, entry := range list(raw) {
		parts := strings.Split(entry, ":")
		if len(parts) != 2 {
			return nil, fmt.Errorf("entry %q must be category:boot", entry)
		}
		category := strings.TrimSpace(parts[0])
		if category != CategorySeen && category != CategoryBlind {
			return nil, fmt.Errorf("entry %q: category must be seen or blind", entry)
		}
		boot, err := parseInt(parts[1])
		if err != nil {
			return nil, fmt.Errorf("entry %q: boot is not an integer", entry)
		}
		tables = append(tables, LobbyTable{Category: category, BootAmount: boot})
	}
	return tables, nil
}

// msPattern is vercel/ms 2.1.3's grammar: an optionally negative decimal
// (".5", "1.5", "30"), optional spaces, an optional unit. Matched
// case-insensitively; inputs over 100 characters are rejected as ms does.
var msPattern = regexp.MustCompile(`(?i)^(-?(?:\d+)?\.?\d+) *(milliseconds?|msecs?|ms|seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w|years?|yrs?|y)?$`)

// ParseDuration parses the `expiresIn` grammar jsonwebtoken accepts (the
// vercel/ms format): a bare integer is milliseconds; "30d", "12h", "15m",
// "45s", "2w", "1y" carry a unit (ms, s, m, h, d, w, y). Whitespace between
// number and unit is allowed ("30 days"), units may be spelled out or plural,
// decimals are accepted ("1.5h"); a year is 365.25 days as in ms. Returns an
// error for anything else — and for zero or negative spans, which would make
// every token expired on arrival — so a typo in JWT_EXPIRES_IN fails at boot
// rather than at every login (Node's jwt.sign threw → 500 per login).
func ParseDuration(text string) (time.Duration, error) {
	if len(text) > 100 {
		return 0, fmt.Errorf("duration %q is longer than 100 characters", text)
	}
	m := msPattern.FindStringSubmatch(text)
	if m == nil {
		return 0, fmt.Errorf("duration %q is not a number with an optional unit (ms, s, m, h, d, w, y)", text)
	}
	n, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return 0, fmt.Errorf("duration %q: %v", text, err)
	}
	var unit float64
	switch strings.ToLower(m[2]) {
	case "years", "year", "yrs", "yr", "y":
		unit = 365.25 * 24 * 60 * 60 * 1000
	case "weeks", "week", "w":
		unit = 7 * 24 * 60 * 60 * 1000
	case "days", "day", "d":
		unit = 24 * 60 * 60 * 1000
	case "hours", "hour", "hrs", "hr", "h":
		unit = 60 * 60 * 1000
	case "minutes", "minute", "mins", "min", "m":
		unit = 60 * 1000
	case "seconds", "second", "secs", "sec", "s":
		unit = 1000
	default: // "", ms, msec(s), millisecond(s)
		unit = 1
	}
	ms := n * unit
	if math.IsNaN(ms) || math.IsInf(ms, 0) || ms > float64(math.MaxInt64/int64(time.Millisecond)) {
		return 0, fmt.Errorf("duration %q is out of range", text)
	}
	if ms <= 0 {
		return 0, fmt.Errorf("duration %q must be positive", text)
	}
	return time.Duration(math.Round(ms)) * time.Millisecond, nil
}
