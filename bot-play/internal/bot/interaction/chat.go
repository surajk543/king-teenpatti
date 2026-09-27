// Package interaction is what a bot says at a table: short, context-specific
// lines, mostly none. Rate-limited per bot (a cooldown and no immediate
// repeats) and per table (a budget shared by the whole fleet), and only over
// the protocol the server has — chat:message. Emojis (chat:emoji) must be
// owned, and the bots own none, so emotes are an interface a later version
// can connect (emote.go).
//
// Chat is the fastest way to give a fleet away, in both directions: silence
// at every table is odd, and a canned line after every hand is worse. So a
// moment only sometimes gets a word (a quiet bot rarely, a talkative one more
// often), the words are the register people actually type in an Indian card
// room — short, lowercase, Hinglish and English mixed — and no table becomes
// a group chat however many talkative bots sit at it.
//
// The server allows 5 lines per 5 seconds per socket and 140 characters a
// line (CHAT_RATE_LIMIT, CHAT_MAX_LENGTH); a bot's cooldown and the table
// budget keep every bot far inside both.
package interaction

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// Moment is what just happened that a person might remark on.
type Moment string

// The moments a bot may speak at. The caller decides which one it is (a win
// and a big win are both the caller's call — ResultMoment is the fleet's
// rule); this package decides whether anything is said.
const (
	Join         Moment = "join"    // this bot sat down
	Welcome      Moment = "welcome" // someone else sat down ({name})
	Win          Moment = "win"
	BigWin       Moment = "big_win"
	Loss         Moment = "loss"
	BigLoss      Moment = "big_loss"
	NiceHand     Moment = "nice_hand"   // someone won with a strong hand ({name})
	StrongHand   Moment = "strong_hand" // this bot is holding something good ("let's go")
	BigRaise     Moment = "big_raise"   // someone raised big
	PlayingBlind Moment = "playing_blind"
	SideshowWon  Moment = "sideshow_won"
	SideshowLost Moment = "sideshow_lost"
	Packed       Moment = "packed"
	LowChips     Moment = "low_chips"
	Leave        Moment = "leave"      // this bot is getting up
	ReplyHi      Moment = "reply_hi"   // someone said hi
	ReplyName    Moment = "reply_name" // someone said this bot's name
	Variation    Moment = "variation"  // a variation was announced
	FiveCard     Moment = "five_card"
)

// DefaultProbabilities is the chance of a line at each moment, [lo, hi]: a
// bot of ChatRate 0 speaks with lo, one of ChatRate 1 with hi, the rest in
// proportion. Sitting down and getting up are when people talk most; a big
// result moves people more than a small one; a person addressed directly
// usually answers.
var DefaultProbabilities = map[Moment][2]float64{
	Join:         {0.10, 0.25},
	Welcome:      {0.03, 0.10},
	Win:          {0.05, 0.15},
	BigWin:       {0.10, 0.25},
	Loss:         {0.03, 0.10},
	BigLoss:      {0.06, 0.16},
	NiceHand:     {0.03, 0.10},
	StrongHand:   {0.02, 0.06},
	BigRaise:     {0.03, 0.10},
	PlayingBlind: {0.02, 0.08},
	SideshowWon:  {0.04, 0.10},
	SideshowLost: {0.03, 0.08},
	Packed:       {0.02, 0.06},
	LowChips:     {0.04, 0.10},
	Leave:        {0.20, 0.40},
	ReplyHi:      {0.20, 0.50},
	ReplyName:    {0.40, 0.70},
	Variation:    {0.02, 0.08},
	FiveCard:     {0.02, 0.08},
}

// The rate limits' defaults.
const (
	DefaultCooldown     = 12 * time.Second // per bot, between two of its lines
	DefaultTableGap     = 6 * time.Second  // per table, between any two bot lines
	DefaultTablePerMin  = 6                // per table, bot lines a minute
	MaxLineLength       = 140              // the server's CHAT_MAX_LENGTH, in characters
	recentLines         = 3                // a bot's last lines, none of which it says again next
	budgetWindow        = time.Minute
	minSweepRooms       = 256
	languageMixed       = "mixed"
	languageEnglish     = "english"
	languageHinglish    = "hinglish"
	defaultEnglishShare = 0.5
)

// Config is the interaction section of the configuration.
type Config struct {
	Enabled       bool
	Probabilities map[Moment][2]float64 // [lo, hi] chance for a moment, scaled into the range by the bot's ChatRate; unset moments keep DefaultProbabilities
	Cooldown      time.Duration         // per bot, between two lines (default 12 s)
	Language      string                // "mixed" (Hinglish + English, the default) | "english" | "hinglish"
}

// TableBudget rations lines per table across the whole fleet: at most one
// every Gap and PerMinute a minute. Safe for concurrent use.
//
// A table that has heard nothing from the fleet for a minute is forgotten,
// so the budget holds only the tables talked at in the last minute however
// many the fleet passes through.
type TableBudget struct {
	mu        sync.Mutex
	gap       time.Duration
	perMinute int
	rooms     map[string][]time.Time // each table's bot lines in the last minute, oldest first
	sweepAt   int                    // sweep for quiet tables once this many are held
}

// NewTableBudget: gap ≤ 0 → 6 s; perMinute ≤ 0 → 6.
func NewTableBudget(gap time.Duration, perMinute int) *TableBudget {
	if gap <= 0 {
		gap = DefaultTableGap
	}
	if perMinute <= 0 {
		perMinute = DefaultTablePerMin
	}
	return &TableBudget{gap: gap, perMinute: perMinute, rooms: make(map[string][]time.Time), sweepAt: minSweepRooms}
}

// Allows reports whether table roomID could take a line at now, spending
// nothing.
func (b *TableBudget) Allows(roomID string, now time.Time) bool {
	if roomID == "" {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.allows(b.recent(roomID, now), now)
}

// Take spends a line of table roomID's budget at now when there is one,
// reporting whether there was. An empty roomID never has one.
func (b *TableBudget) Take(roomID string, now time.Time) bool {
	if roomID == "" {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	sent := b.recent(roomID, now)
	if !b.allows(sent, now) {
		return false
	}
	b.rooms[roomID] = append(sent, now)
	if len(b.rooms) > b.sweepAt {
		b.sweep(now)
	}
	return true
}

// Rooms is how many tables the budget is holding (for tests and metrics).
func (b *TableBudget) Rooms() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.rooms)
}

// Forget drops a table's record — a table the server has closed.
func (b *TableBudget) Forget(roomID string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.rooms, roomID)
}

// recent is roomID's lines within the minute before now, pruned in place
// (the table is dropped when none is left). Called with mu held.
func (b *TableBudget) recent(roomID string, now time.Time) []time.Time {
	sent := b.rooms[roomID]
	i := 0
	for i < len(sent) && now.Sub(sent[i]) >= budgetWindow {
		i++
	}
	if i == 0 {
		return sent
	}
	if i == len(sent) {
		delete(b.rooms, roomID)
		return nil
	}
	kept := append(sent[:0], sent[i:]...)
	b.rooms[roomID] = kept
	return kept
}

// allows is the rule: the gap since the table's last line, and the count in
// the last minute. A line stamped after now (another bot's clock ran ahead)
// counts as just said. Called with mu held.
func (b *TableBudget) allows(sent []time.Time, now time.Time) bool {
	if len(sent) >= b.perMinute {
		return false
	}
	return len(sent) == 0 || now.Sub(sent[len(sent)-1]) >= b.gap
}

// sweep forgets every table quiet for a minute, and sets the next sweep at
// twice what is left, so sweeping stays cheap however many tables are live.
// Called with mu held.
func (b *TableBudget) sweep(now time.Time) {
	for room, sent := range b.rooms {
		if len(sent) == 0 || now.Sub(sent[len(sent)-1]) >= budgetWindow {
			delete(b.rooms, room)
		}
	}
	b.sweepAt = max(minSweepRooms, 2*len(b.rooms))
}

// Chatter is one bot's voice. Not safe for concurrent use: like the bot's
// *rng.Rand, it belongs to the bot's one event loop.
type Chatter struct {
	enabled      bool
	rate         float64
	probs        map[Moment][2]float64
	cooldown     time.Duration
	language     string
	englishShare float64 // under "mixed", how often this bot reaches for an English line
	budget       *TableBudget
	r            *rng.Rand
	lastAt       time.Time
	recent       []string // its last few templates, oldest first
}

// NewChatter: chatRate is the personality's ChatRate (0..1).
//
// A nil budget gives the bot one of its own (the default limits), and a nil
// r a stream seeded from the clock; the fleet passes its shared budget and
// the bot's own stream. Under "mixed" each bot leans its own way — some type
// mostly Hinglish, some mostly English — drawn once here from r.
func NewChatter(cfg Config, chatRate float64, budget *TableBudget, r *rng.Rand) *Chatter {
	if budget == nil {
		budget = NewTableBudget(0, 0)
	}
	if r == nil {
		r = rng.New(uint64(time.Now().UnixNano()))
	}
	c := &Chatter{
		enabled:      cfg.Enabled,
		rate:         clamp01(chatRate),
		probs:        make(map[Moment][2]float64, len(DefaultProbabilities)+len(cfg.Probabilities)),
		cooldown:     cfg.Cooldown,
		language:     normaliseLanguage(cfg.Language),
		englishShare: defaultEnglishShare,
		budget:       budget,
		r:            r,
	}
	for m, p := range DefaultProbabilities {
		c.probs[m] = p
	}
	for m, p := range cfg.Probabilities {
		c.probs[m] = tidyProbability(p)
	}
	if c.cooldown <= 0 {
		c.cooldown = DefaultCooldown
	}
	if c.language == languageMixed {
		c.englishShare = r.Between(0.15, 0.85)
	}
	return c
}

// Chance is the probability this bot says something at m: its place between
// the moment's lo and hi, by its ChatRate.
func (c *Chatter) Chance(m Moment) float64 {
	p, ok := c.probs[m]
	if !ok {
		return 0
	}
	return p[0] + (p[1]-p[0])*c.rate
}

// Maybe decides whether to say something about m at table roomID now, and
// what. vars fills placeholders ({name}). It spends the cooldown and the
// table budget only when it returns ok. Most calls return ok=false.
//
// The line is decided when the moment happens and meant to be sent after a
// short human pause (timing.Chat); the table's budget is already spent for
// it, so the pause cannot let a second bot talk over it.
func (c *Chatter) Maybe(m Moment, roomID string, vars map[string]string, now time.Time) (line string, ok bool) {
	return c.MaybeScaled(m, roomID, vars, now, 1)
}

// MaybeScaled is Maybe with the chance multiplied by scale — how the caller
// makes a moment rarer than usual (0.1 for a hello from another bot of the
// fleet, so bots do not keep a conversation going among themselves) or more
// likely. The result is held to [0, 1].
func (c *Chatter) MaybeScaled(m Moment, roomID string, vars map[string]string, now time.Time, scale float64) (line string, ok bool) {
	if !c.enabled || roomID == "" {
		return "", false
	}
	if !c.lastAt.IsZero() && now.Sub(c.lastAt) < c.cooldown {
		return "", false
	}
	if !c.r.Chance(clamp01(c.Chance(m) * scale)) {
		return "", false
	}
	template, line, ok := c.pick(m, vars)
	if !ok {
		return "", false
	}
	if !c.budget.Take(roomID, now) {
		return "", false
	}
	c.lastAt = now
	c.remember(template)
	return line, true
}

// pick chooses a line for m: from the bot's language (under "mixed", English
// or Hinglish by its lean, the other when its pool has nothing to offer),
// with every placeholder filled, and none of its last few lines.
func (c *Chatter) pick(m Moment, vars map[string]string) (template, line string, ok bool) {
	p, known := lines[m]
	if !known {
		return "", "", false
	}
	var first, second []string
	switch c.language {
	case languageEnglish:
		first = p.english
	case languageHinglish:
		first = p.hinglish
	default:
		first, second = p.hinglish, p.english
		if c.r.Chance(c.englishShare) {
			first, second = second, first
		}
	}
	for _, pool := range [][]string{first, second} {
		if template, line, ok = c.pickFrom(pool, vars); ok {
			return template, line, true
		}
	}
	return "", "", false
}

// pickFrom draws a fillable line from pool, avoiding the bot's recent lines,
// or — when the pool is too small for that — at least the very last one.
func (c *Chatter) pickFrom(pool []string, vars map[string]string) (template, line string, ok bool) {
	type option struct{ template, line string }
	var fresh, notLast []option
	last := ""
	if n := len(c.recent); n > 0 {
		last = c.recent[n-1]
	}
	for _, t := range pool {
		filled, ok := fill(t, vars)
		if !ok || t == last {
			continue
		}
		o := option{t, filled}
		notLast = append(notLast, o)
		if !c.saidRecently(t) {
			fresh = append(fresh, o)
		}
	}
	choice := fresh
	if len(choice) == 0 {
		choice = notLast
	}
	if len(choice) == 0 {
		return "", "", false
	}
	o := choice[c.r.IntN(len(choice))]
	return o.template, o.line, true
}

func (c *Chatter) saidRecently(template string) bool {
	for _, t := range c.recent {
		if t == template {
			return true
		}
	}
	return false
}

func (c *Chatter) remember(template string) {
	c.recent = append(c.recent, template)
	if len(c.recent) > recentLines {
		c.recent = append(c.recent[:0], c.recent[len(c.recent)-recentLines:]...)
	}
}

// fill replaces each {key} in template with vars[key], trimmed and on one
// line; a placeholder with no value (or an empty one) means the template
// cannot be used. The result is held to MaxLineLength characters.
func fill(template string, vars map[string]string) (string, bool) {
	var b strings.Builder
	rest := template
	for {
		open := strings.IndexByte(rest, '{')
		if open < 0 {
			b.WriteString(rest)
			break
		}
		end := strings.IndexByte(rest[open:], '}')
		if end < 0 {
			b.WriteString(rest)
			break
		}
		key := rest[open+1 : open+end]
		value := strings.Join(strings.Fields(vars[key]), " ")
		if value == "" {
			return "", false
		}
		b.WriteString(rest[:open])
		b.WriteString(value)
		rest = rest[open+end+1:]
	}
	line := strings.TrimSpace(b.String())
	if line == "" {
		return "", false
	}
	if r := []rune(line); len(r) > MaxLineLength {
		line = strings.TrimSpace(string(r[:MaxLineLength]))
	}
	return line, true
}

// normaliseLanguage reads the configuration's language: "english" (or
// "en") and "hinglish" as themselves, anything else — "mixed", nothing, a
// word it does not know — as mixed.
func normaliseLanguage(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case languageEnglish, "en":
		return languageEnglish
	case languageHinglish:
		return languageHinglish
	}
	return languageMixed
}

// ValidLanguage reports whether s is a language the configuration may name.
func ValidLanguage(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", languageMixed, languageEnglish, "en", languageHinglish:
		return true
	}
	return false
}

// ParseProbabilities turns the configuration's interaction.probabilities
// (moment name → [lo, hi]) into Config.Probabilities. An unknown moment, or
// a bound outside [0, 1] or a lo above its hi, is an error naming it.
func ParseProbabilities(in map[string][2]float64) (map[Moment][2]float64, error) {
	if len(in) == 0 {
		return nil, nil
	}
	out := make(map[Moment][2]float64, len(in))
	var bad []string
	for name, p := range in {
		m := Moment(strings.ToLower(strings.TrimSpace(name)))
		if _, ok := DefaultProbabilities[m]; !ok {
			bad = append(bad, fmt.Sprintf("unknown moment %q", name))
			continue
		}
		if p[0] < 0 || p[1] > 1 || p[0] > p[1] {
			bad = append(bad, fmt.Sprintf("%s: [%g, %g] is not a range of chances", name, p[0], p[1]))
			continue
		}
		out[m] = p
	}
	if len(bad) > 0 {
		sort.Strings(bad)
		return nil, fmt.Errorf("interaction.probabilities: %s", strings.Join(bad, "; "))
	}
	return out, nil
}

// Moments is every moment, in a fixed order.
func Moments() []Moment {
	ms := make([]Moment, 0, len(DefaultProbabilities))
	for m := range DefaultProbabilities {
		ms = append(ms, m)
	}
	sort.Slice(ms, func(i, j int) bool { return ms[i] < ms[j] })
	return ms
}

func tidyProbability(p [2]float64) [2]float64 {
	p[0], p[1] = clamp01(p[0]), clamp01(p[1])
	if p[0] > p[1] {
		p[0], p[1] = p[1], p[0]
	}
	return p
}

func clamp01(x float64) float64 {
	if !(x > 0) { // NaN included
		return 0
	}
	if x > 1 {
		return 1
	}
	return x
}
