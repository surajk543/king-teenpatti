package bot

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/connection"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/interaction"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/state"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/strategy"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/table"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/timing"
	"github.com/surajk543/king-teenpatti/bot-play/internal/clock"
	"github.com/surajk543/king-teenpatti/bot-play/internal/config"
	"github.com/surajk543/king-teenpatti/bot-play/internal/metrics"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// Deps is what every bot of a fleet shares: the way to the server (or the
// simulator), the menu, the clock, the timing model, the per-table chat
// budget, metrics and the fleet registry. None of it holds per-bot state.
type Deps struct {
	API      protocol.API
	Dialer   protocol.Dialer
	Finder   *table.Finder
	Clock    clock.Clock
	Delay    *timing.HumanDelay
	Budget   *interaction.TableBudget
	Emoter   interaction.Emoter
	Metrics  *metrics.Metrics
	Fleet    *Fleet
	Profiles map[strategy.Kind]strategy.Profile
	Config   config.Config
	Log      *slog.Logger
	// Seed is the fleet's behaviour seed: bot i's decisions are drawn from
	// rng.Derive(Seed, i), so a run with the same seed replays its choices.
	Seed uint64
}

// Bot is one bot player. All of its state is owned by the goroutine running
// Run; the debug view reads a copy (Snapshot) under snapMu.
type Bot struct {
	id      Identity
	d       Deps
	log     *slog.Logger
	rand    *rng.Rand
	persona strategy.Personality
	machine *state.Machine
	chat    *interaction.Chatter
	book    *state.OpponentBook
	sched   *scheduler
	backoff connection.Backoff
	soft    chan struct{} // closed by Stop: finish the hand, leave, go

	// the account
	token  string
	userID string
	chips  int64

	// the connection
	ctx      context.Context // the running loop's context
	sess     protocol.Session
	ready    bool
	resume   *protocol.ResumeOffer
	outcome  outcome
	attempts int
	rejoin   bool // this connection is a reconnection: look for a table unhurried

	// the table
	table        table.Choice // the table it sits at, or is headed for
	seated       bool
	roomID       string
	view         *protocol.RoomState
	handNo       int
	inHand       bool // dealt into handNo
	packed       bool // packed in handNo
	contributed  int64
	memory       *strategy.HandMemory
	tilt         float64
	plannedHands int
	recent       []string
	exclude      []string
	joinedAt     time.Time
	lastHandAt   time.Time
	lastHumanAt  time.Time
	knownSeats   map[string]bool
	answered     map[string]bool // one-shot answers this hand: "variation", "pick", "sideshow:<expiresAt>"
	endAfterHand string          // a reason to get up once the hand in progress ends
	stopping     bool
	replenish    bool // simulation only: the next session is a fresh account
	generation   int

	// the turn
	lastTurnKey string
	refusals    int // refusals on the current turn
	turnKey     string
	turnSeq     uint64
	unacked     *sentAction // a move whose acknowledgement the connection took with it
	lastSent    *sentAction

	session state.Session

	snapMu sync.Mutex
	snap   state.Snapshot
}

// sentAction is a move as sent, kept so a move whose acknowledgement was
// lost with the connection is resent with the SAME action id — the server
// refuses a second copy (duplicate_action), so it can never bet twice.
type sentAction struct {
	turnKey string
	req     protocol.ActionRequest
}

type outcome int

const (
	outNone    outcome = iota
	outEnded           // the session is over: rest
	outLost            // the connection dropped: reconnect
	outStopped         // the fleet is stopping
	outFatal           // this account cannot play (disabled, replaced)
	outRequeue         // (a leave's "then") sit again at the same stake
)

// New builds bot index of the fleet. Its personality is drawn from its
// identity (stable across runs); its behaviour from the fleet's seed.
func New(id Identity, d Deps) *Bot {
	personaRand := rng.New(id.Seed())
	kind := strategy.PickKind(d.Config.Bots.PersonalityMix, rng.From(&rng.Script{Values: []float64{familySlot(id.Number)}}))
	persona := strategy.NewPersonality(kind, d.Profiles, personaRand)
	behaviour := rng.Derive(d.Seed, id.Number)
	log := d.Log.With("bot", id.DeviceID)
	b := &Bot{
		id:         id,
		d:          d,
		log:        log,
		rand:       behaviour,
		persona:    persona,
		book:       state.NewOpponentBook(256),
		sched:      newScheduler(d.Clock),
		soft:       make(chan struct{}),
		knownSeats: map[string]bool{},
		answered:   map[string]bool{},
		backoff: connection.Backoff{
			Base:   d.Config.Reconnect.BaseDelay,
			Max:    d.Config.Reconnect.MaxDelay,
			Factor: 2,
			Jitter: 0.3,
		},
	}
	d.Metrics.Track(state.Offline) // a new machine starts OFFLINE without calling its hook
	b.machine = state.NewMachine(log, d.Clock.Now, func(from, to state.State) {
		d.Metrics.State(from, to)
		b.snapMu.Lock()
		b.snap.State = to
		b.snap.StateSince = d.Clock.Now()
		b.snapMu.Unlock()
	})
	b.chat = interaction.NewChatter(interaction.Config{
		Enabled:       d.Config.Interaction.EnableChat,
		Probabilities: momentRanges(d.Config.Interaction.Probabilities),
		Cooldown:      d.Config.Interaction.Cooldown,
		Language:      d.Config.Interaction.Language,
	}, persona.ChatRate, d.Budget, rng.Derive(d.Seed^0xc4a7, id.Number))
	b.snap = state.Snapshot{Bot: id.DeviceID, Personality: string(persona.Kind), State: state.Offline}
	return b
}

// familySlot places bot number n on [0,1) with the golden-ratio sequence, so
// the families (drawn by weight from this point) spread evenly over any run of
// bot numbers: a fleet of ten has every family, where independent draws left
// three of six out. The traits inside the family are still the bot's own.
func familySlot(n int) float64 {
	const phi = 0.6180339887498949
	x := float64(n)*phi + 0.1234
	return x - float64(int(x))
}

// ID is the bot's device id ("botplay-000017").
func (b *Bot) ID() string { return b.id.DeviceID }

// Personality is the bot's drawn personality.
func (b *Bot) Personality() strategy.Personality { return b.persona }

// Stop asks the bot to finish its hand, leave its table and stop. Safe to
// call from any goroutine, more than once.
func (b *Bot) Stop() {
	defer func() { _ = recover() }() // closing twice
	close(b.soft)
}

// Snapshot is the bot as the debug view shows it (cards included; the debug
// server strips them unless configured to show them).
func (b *Bot) Snapshot() state.Snapshot {
	b.snapMu.Lock()
	defer b.snapMu.Unlock()
	s := b.snap
	s.Cards = append([]string(nil), b.snap.Cards...)
	return s
}

// publish copies the loop's view of itself into the snapshot.
func (b *Bot) publish() {
	b.snapMu.Lock()
	defer b.snapMu.Unlock()
	b.snap.UserID = b.userID
	b.snap.Chips = b.chips
	b.snap.Table = ""
	if b.seated || b.table.Key != "" {
		b.snap.Table = b.table.Key
	}
	b.snap.RoomID = b.roomID
	b.snap.HandNo = b.handNo
	b.snap.SessionHands = b.session.Hands
	b.snap.Wins = b.session.Wins
	b.snap.Losses = b.session.Losses
	b.snap.Cards = nil
	b.snap.IsBlind = false
	if b.view != nil && b.view.You != nil {
		b.snap.IsBlind = b.view.You.IsBlind
		b.snap.Cards = append([]string(nil), b.view.You.Cards...)
	}
}

func (b *Bot) noteDecision(action, reason string, reaction time.Duration) {
	b.snapMu.Lock()
	b.snap.LastDecision = action
	b.snap.LastReason = reason
	b.snap.LastReaction = fmt.Sprintf("%.1fs", reaction.Seconds())
	b.snapMu.Unlock()
}

func (b *Bot) noteError(err error) {
	if err == nil {
		return
	}
	b.snapMu.Lock()
	b.snap.LastError = err.Error()
	b.snapMu.Unlock()
}

// newActionID is a fresh idempotency key for a move (32 hex characters).
func newActionID() string {
	var buf [16]byte
	_, _ = rand.Read(buf[:])
	return hex.EncodeToString(buf[:])
}

// momentRanges is config interaction.probabilities as the Chatter takes it
// (checked at start-up by main; an invalid entry here reads as the defaults).
func momentRanges(in map[string][2]float64) map[interaction.Moment][2]float64 {
	out, err := interaction.ParseProbabilities(in)
	if err != nil {
		return nil
	}
	return out
}

func (b *Bot) now() time.Time { return b.d.Clock.Now() }
