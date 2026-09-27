// Package metrics is bot-play's observability: Prometheus metrics (the game
// server exports Prometheus too) and the debug view of every bot, served on
// loopback addresses that are off by default.
//
// The label rule is the game server's (go-server internal/metrics): no bot
// id, user id, room id, table code, name or free text ever becomes a label
// value. Every label is drawn from a small vocabulary (vocab below) and
// anything outside it is "other", so a caller passing the wrong string can
// cost a series called "other", never a series per bot.
package metrics

import (
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/state"
)

// Other is the label value for anything outside a label's vocabulary, and
// None the value for an empty string.
const (
	Other = "other"
	None  = "none"
)

// maxLearned is how many values beyond its fixed vocabulary a learning label
// (a reason, a refusal code, …) accepts before every new value is Other.
const maxLearned = 32

// maxLabelLen bounds a learned value's length.
const maxLabelLen = 40

// wordPattern is what a learned value must look like: one word of lower-case
// letters and underscores, or one of upper-case letters and underscores. It
// admits "transport_close" and "MAX_HANDS"; it refuses anything with a digit
// or a hyphen — every bot id (botplay-000001), user id (a uuid), guest name
// (Guest0E00B) and almost every table code — and a name in mixed case
// ("Ravi Kumar" → Ravi_Kumar), so an id or a name passed by mistake is Other
// rather than a series of its own. The learned count is capped as well.
var wordPattern = regexp.MustCompile(`^(?:[a-z][a-z_]*|[A-Z][A-Z_]*)$`)

// vocab is one label's allowed values: a fixed list, plus (when learning) up
// to maxLearned words seen at run time. Safe for concurrent use.
type vocab struct {
	learn bool
	mu    sync.RWMutex
	known map[string]bool
	extra int
}

func newVocab(learn bool, fixed ...string) *vocab {
	v := &vocab{learn: learn, known: make(map[string]bool, len(fixed))}
	for _, f := range fixed {
		v.known[f] = true
	}
	return v
}

// label maps raw to the value the metric carries.
func (v *vocab) label(raw string) string {
	s := strings.Join(strings.Fields(raw), "_") // "transport close" → "transport_close"
	if s == "" {
		return None
	}
	v.mu.RLock()
	ok := v.known[s]
	v.mu.RUnlock()
	if ok {
		return s
	}
	if !v.learn || len(s) > maxLabelLen || !wordPattern.MatchString(s) {
		return Other
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.known[s] {
		return s
	}
	if v.extra >= maxLearned {
		return Other
	}
	v.known[s] = true
	v.extra++
	return s
}

// The fixed vocabularies. The learning labels start from the values the
// fleet is known to send, so those are never crowded out by later words.
var (
	categories = []string{"seen", "blind", "variation"}
	results    = []string{"win", "loss", "fold", "left"}
	actions    = []string{"see", "chaal", "raise", "pack", "show", "sideshow", "forceSideshow", "missile",
		"sideshow_accept", "sideshow_decline", "select_variation", "select_cards"}
	reactionKinds = []string{"see", "chaal", "blind_chaal", "fold", "small_raise", "large_raise", "show", "sideshow",
		"difficult", "join_table", "leave_table", "search_table", "chat", "answer_sideshow",
		"pick_variation", "pick_cards", "look_early"}
	moments = []string{"join", "welcome", "win", "big_win", "loss", "big_loss", "nice_hand", "strong_hand",
		"big_raise", "playing_blind", "sideshow_won", "sideshow_lost", "packed", "low_chips", "leave",
		"reply_hi", "reply_name", "variation", "five_card"}
	reconnectResults = []string{"ok", "failed", "gave_up", "resumed", "seat_lost"}
	states           = []string{
		string(state.Offline), string(state.Connecting), string(state.Online), string(state.SearchingTable),
		string(state.JoiningTable), string(state.WaitingForHand), string(state.Playing), string(state.WaitingForAction),
		string(state.ProcessingResult), string(state.LeavingTable), string(state.SwitchingTable),
		string(state.Reconnecting), string(state.Resting), string(state.Stopping),
	}
)

// Buckets. A decision is computed in microseconds to milliseconds; a
// reaction is a human's pause, up to the 25 s turn clock.
var (
	decisionBuckets = []float64{.00001, .000025, .00005, .0001, .00025, .0005, .001, .0025, .005, .01, .025, .05, .1, .25, .5, 1}
	reactionBuckets = []float64{.25, .5, .75, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 12.5, 15, 20, 25}
)

// Metrics is the fleet's counters and gauges. All methods are safe for
// concurrent use and tolerate a nil receiver (metrics off).
type Metrics struct {
	reg     *prometheus.Registry
	labeled prometheus.Registerer // reg, adding service="bot-play" to every series

	connected       prometheus.Gauge
	disconnected    *prometheus.CounterVec
	tableJoin       *prometheus.CounterVec
	tableLeave      *prometheus.CounterVec
	handStarted     *prometheus.CounterVec
	handCompleted   *prometheus.CounterVec
	action          *prometheus.CounterVec
	refused         *prometheus.CounterVec
	reconnect       *prometheus.CounterVec
	decisionLatency prometheus.Histogram
	reactionDelay   *prometheus.HistogramVec
	state           *prometheus.GaugeVec
	transitions     *prometheus.CounterVec
	chat            *prometheus.CounterVec

	disconnectReasons *vocab
	leaveReasons      *vocab
	categories        *vocab
	results           *vocab
	actions           *vocab
	codes             *vocab
	reconnectResults  *vocab
	reactionKinds     *vocab
	moments           *vocab
	states            *vocab
}

// New registers every metric on a fresh registry, with the Go runtime and
// process collectors beside them, every series carrying service="bot-play".
func New() *Metrics {
	reg := prometheus.NewRegistry()
	r := prometheus.WrapRegistererWith(prometheus.Labels{"service": "bot-play"}, reg)
	f := factory{r}

	m := &Metrics{
		reg:     reg,
		labeled: r,

		connected: f.gauge("bot_connected", "Bots with a live connection to the game server."),
		disconnected: f.counterVec("bot_disconnected_total",
			"Connections that ended, by reason.", "reason"),
		tableJoin: f.counterVec("bot_table_join_total",
			"Tables sat down at, by category.", "category"),
		tableLeave: f.counterVec("bot_table_leave_total",
			"Tables left, by reason.", "reason"),
		handStarted: f.counterVec("bot_hand_started_total",
			"Hands a bot was dealt into, by category.", "category"),
		handCompleted: f.counterVec("bot_hand_completed_total",
			"Hands a bot finished, by category and result (win, loss, fold, left).", "category", "result"),
		action: f.counterVec("bot_action_total",
			"Moves made, by action and whether the bot was blind.", "action", "blind"),
		refused: f.counterVec("bot_refused_total",
			"Requests the server refused, by refusal code.", "code"),
		reconnect: f.counterVec("bot_reconnect_total",
			"Reconnection attempts, by result.", "result"),
		decisionLatency: f.histogram("bot_decision_latency_seconds",
			"Time spent computing a decision (compute, not the human pause).", decisionBuckets),
		reactionDelay: f.histogramVec("bot_reaction_delay_seconds",
			"The human-like pause drawn before acting, by kind.", reactionBuckets, "kind"),
		state: f.gaugeVec("bot_state",
			"Bots in each lifecycle state.", "state"),
		transitions: f.counterVec("bot_state_transitions_total",
			"Lifecycle transitions, by the state left and the state entered.", "from", "to"),
		chat: f.counterVec("bot_chat_total",
			"Chat lines sent, by the moment that prompted them.", "moment"),

		disconnectReasons: newVocab(true, "closed", "error", "stopping", "session_replaced", "transport_close",
			"transport_error", "ping_timeout", "server_disconnect", "resting", "connect_error"),
		leaveReasons: newVocab(true, "MAX_HANDS", "STOP_LOSS", "TAKE_PROFIT", "TABLE_EMPTYING", "TOO_MANY_BOTS",
			"NO_HUMANS", "IDLE_TABLE", "UNSUITABLE", "SESSION_OVER", "RANDOM", "NOT_ADMITTED",
			"kicked", "idle", "insufficient_chips", "closed", "moved", "disconnected"),
		categories:       newVocab(false, categories...),
		results:          newVocab(false, results...),
		actions:          newVocab(true, actions...),
		codes:            newVocab(true),
		reconnectResults: newVocab(true, reconnectResults...),
		reactionKinds:    newVocab(true, reactionKinds...),
		moments:          newVocab(true, moments...),
		states:           newVocab(false, states...),
	}
	r.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	// Series a dashboard rates over exist from the start, at 0.
	for _, s := range states {
		m.state.WithLabelValues(s)
	}
	for _, c := range categories {
		m.tableJoin.WithLabelValues(c)
		m.handStarted.WithLabelValues(c)
		for _, res := range results {
			m.handCompleted.WithLabelValues(c, res)
		}
	}
	return m
}

// Registry is the registry every metric is on (nil when m is nil).
func (m *Metrics) Registry() *prometheus.Registry {
	if m == nil {
		return nil
	}
	return m.reg
}

// Connected counts a connection that opened: bot_connected +1.
func (m *Metrics) Connected() {
	if m == nil {
		return
	}
	m.connected.Inc()
}

// Disconnected counts a connection that ended: bot_connected −1 and
// bot_disconnected_total{reason}. Call it once for each Connected.
func (m *Metrics) Disconnected(reason string) {
	if m == nil {
		return
	}
	m.connected.Dec()
	m.disconnected.WithLabelValues(m.disconnectReasons.label(reason)).Inc()
}

// TableJoin counts a seat taken: bot_table_join_total{category}.
func (m *Metrics) TableJoin(category string) {
	if m == nil {
		return
	}
	m.tableJoin.WithLabelValues(m.categories.label(category)).Inc()
}

// TableLeave counts a seat given up: bot_table_leave_total{reason} — the
// switcher's reason (MAX_HANDS, STOP_LOSS, …) or the server's (kicked, …).
func (m *Metrics) TableLeave(reason string) {
	if m == nil {
		return
	}
	m.tableLeave.WithLabelValues(m.leaveReasons.label(reason)).Inc()
}

// HandStarted counts a hand dealt in: bot_hand_started_total{category}.
func (m *Metrics) HandStarted(category string) {
	if m == nil {
		return
	}
	m.handStarted.WithLabelValues(m.categories.label(category)).Inc()
}

// HandCompleted counts a hand finished: bot_hand_completed_total
// {category,result}; result is win, loss, fold or left.
func (m *Metrics) HandCompleted(category, result string) {
	if m == nil {
		return
	}
	m.handCompleted.WithLabelValues(m.categories.label(category), m.results.label(result)).Inc()
}

// Action counts a move: bot_action_total{action,blind}.
func (m *Metrics) Action(action string, blind bool) {
	if m == nil {
		return
	}
	m.action.WithLabelValues(m.actions.label(action), strconv.FormatBool(blind)).Inc()
}

// Refused counts a refusal: bot_refused_total{code}, the server's snake_case
// code (never its message).
func (m *Metrics) Refused(code string) {
	if m == nil {
		return
	}
	m.refused.WithLabelValues(m.codes.label(code)).Inc()
}

// Reconnect counts a reconnection attempt: bot_reconnect_total{result}.
func (m *Metrics) Reconnect(result string) {
	if m == nil {
		return
	}
	m.reconnect.WithLabelValues(m.reconnectResults.label(result)).Inc()
}

// DecisionLatency observes the compute time of one decision:
// bot_decision_latency_seconds.
func (m *Metrics) DecisionLatency(d time.Duration) {
	if m == nil {
		return
	}
	m.decisionLatency.Observe(seconds(d))
}

// ReactionDelay observes the pause drawn before an action:
// bot_reaction_delay_seconds{kind}.
func (m *Metrics) ReactionDelay(kind string, d time.Duration) {
	if m == nil {
		return
	}
	m.reactionDelay.WithLabelValues(m.reactionKinds.label(kind)).Observe(seconds(d))
}

// State moves one bot between lifecycle states: bot_state{state} −1 for
// from and +1 for to, and bot_state_transitions_total{from,to}. It is the
// state.Machine's onEnter hook. A Machine starts in Offline without telling
// its hook, so a bot enters the gauge through Track.
func (m *Metrics) State(from, to state.State) {
	if m == nil || from == to {
		return
	}
	f, t := m.states.label(string(from)), m.states.label(string(to))
	m.state.WithLabelValues(f).Dec()
	m.state.WithLabelValues(t).Inc()
	m.transitions.WithLabelValues(f, t).Inc()
}

// Track counts a bot that now exists in s (normally state.Offline, where a
// new state.Machine starts): bot_state{s} +1.
func (m *Metrics) Track(s state.State) {
	if m == nil {
		return
	}
	m.state.WithLabelValues(m.states.label(string(s))).Inc()
}

// Untrack takes a bot that has gone out of the gauge: bot_state{s} −1.
func (m *Metrics) Untrack(s state.State) {
	if m == nil {
		return
	}
	m.state.WithLabelValues(m.states.label(string(s))).Dec()
}

// Chat counts a line sent: bot_chat_total{moment}.
func (m *Metrics) Chat(moment string) {
	if m == nil {
		return
	}
	m.chat.WithLabelValues(m.moments.label(moment)).Inc()
}

func seconds(d time.Duration) float64 {
	if d < 0 {
		return 0
	}
	return d.Seconds()
}

// factory builds and registers metrics on one registerer.
type factory struct{ r prometheus.Registerer }

func (f factory) gauge(name, help string) prometheus.Gauge {
	g := prometheus.NewGauge(prometheus.GaugeOpts{Name: name, Help: help})
	f.r.MustRegister(g)
	return g
}

func (f factory) gaugeVec(name, help string, labels ...string) *prometheus.GaugeVec {
	g := prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: name, Help: help}, labels)
	f.r.MustRegister(g)
	return g
}

func (f factory) counterVec(name, help string, labels ...string) *prometheus.CounterVec {
	c := prometheus.NewCounterVec(prometheus.CounterOpts{Name: name, Help: help}, labels)
	f.r.MustRegister(c)
	return c
}

func (f factory) histogram(name, help string, buckets []float64) prometheus.Histogram {
	h := prometheus.NewHistogram(prometheus.HistogramOpts{Name: name, Help: help, Buckets: buckets})
	f.r.MustRegister(h)
	return h
}

func (f factory) histogramVec(name, help string, buckets []float64, labels ...string) *prometheus.HistogramVec {
	h := prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: name, Help: help, Buckets: buckets}, labels)
	f.r.MustRegister(h)
	return h
}
