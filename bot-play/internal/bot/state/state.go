// Package state is what one bot knows about itself: where it is in its
// lifecycle (an explicit state machine whose every transition is logged),
// how its session is going, and — in opponents.go — what it has noticed about
// the other players this session.
//
// None of it is persisted. Live game state belongs to the game server and
// its Redis; a bot's own memory lives only as long as its process.
package state

import (
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// State is a bot's place in its lifecycle.
type State string

// The lifecycle (the brief's §22):
//
//	OFFLINE → CONNECTING → ONLINE → SEARCHING_TABLE → JOINING_TABLE →
//	WAITING_FOR_HAND ⇄ PLAYING ⇄ WAITING_FOR_ACTION → PROCESSING_RESULT →
//	(WAITING_FOR_HAND | LEAVING_TABLE → SWITCHING_TABLE → SEARCHING_TABLE)
//
// with RECONNECTING reachable from anywhere a connection can drop, and
// STOPPING from anywhere.
const (
	Offline          State = "OFFLINE"
	Connecting       State = "CONNECTING"
	Online           State = "ONLINE"
	SearchingTable   State = "SEARCHING_TABLE"
	JoiningTable     State = "JOINING_TABLE"
	WaitingForHand   State = "WAITING_FOR_HAND"
	Playing          State = "PLAYING"            // dealt in, not on turn
	WaitingForAction State = "WAITING_FOR_ACTION" // on turn: deciding, then acting
	ProcessingResult State = "PROCESSING_RESULT"  // the hand ended; settling what it means
	LeavingTable     State = "LEAVING_TABLE"
	SwitchingTable   State = "SWITCHING_TABLE"
	Reconnecting     State = "RECONNECTING"
	Resting          State = "RESTING" // between sessions, offline on purpose
	Stopping         State = "STOPPING"
)

// allowed is the transition table. A transition not listed is a bug in the
// bot's lifecycle code: Machine.To logs it at WARN and makes it anyway, so a
// surprise never wedges a bot — it shows up in the log instead.
var allowed = map[State][]State{
	Offline:          {Connecting, Resting, Stopping},
	Connecting:       {Online, Reconnecting, Offline, Stopping, WaitingForHand},
	Online:           {SearchingTable, JoiningTable, WaitingForHand, Reconnecting, Offline, Resting, Stopping},
	SearchingTable:   {JoiningTable, WaitingForHand, Playing, WaitingForAction, Online, Resting, Reconnecting, Offline, Stopping},
	JoiningTable:     {WaitingForHand, Playing, WaitingForAction, SearchingTable, Online, Resting, Reconnecting, Offline, Stopping},
	WaitingForHand:   {Playing, WaitingForAction, ProcessingResult, LeavingTable, SwitchingTable, SearchingTable, Reconnecting, Offline, Stopping},
	Playing:          {WaitingForAction, ProcessingResult, WaitingForHand, LeavingTable, SearchingTable, Reconnecting, Offline, Stopping},
	WaitingForAction: {Playing, ProcessingResult, WaitingForHand, LeavingTable, SearchingTable, Reconnecting, Offline, Stopping},
	ProcessingResult: {WaitingForHand, Playing, LeavingTable, SwitchingTable, SearchingTable, Reconnecting, Offline, Stopping},
	LeavingTable:     {SearchingTable, SwitchingTable, Online, Resting, Offline, Reconnecting, Stopping},
	SwitchingTable:   {WaitingForHand, Playing, WaitingForAction, SearchingTable, JoiningTable, Online, Reconnecting, Offline, Stopping},
	Reconnecting:     {Connecting, Online, WaitingForHand, SearchingTable, Offline, Resting, Stopping},
	Resting:          {Connecting, Offline, Stopping},
	Stopping:         {Offline},
}

// Allowed reports whether from → to is a transition the lifecycle expects.
func Allowed(from, to State) bool {
	for _, s := range allowed[from] {
		if s == to {
			return true
		}
	}
	return false
}

// Machine holds a bot's current state and logs every change.
// Safe for concurrent use (the debug view reads it from another goroutine).
type Machine struct {
	mu      sync.Mutex
	current State
	since   time.Time
	log     *slog.Logger
	now     func() time.Time
	onEnter func(from, to State)
}

// NewMachine starts in Offline. log carries the bot's attributes already
// (bot, user); every transition is one INFO line "state" with from/to and any
// attrs passed to To. onEnter (optional) is told of every change — metrics.
func NewMachine(log *slog.Logger, now func() time.Time, onEnter func(from, to State)) *Machine {
	if now == nil {
		now = time.Now
	}
	return &Machine{current: Offline, since: now(), log: log, now: now, onEnter: onEnter}
}

// Current is the state now.
func (m *Machine) Current() State {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.current
}

// Since is when the current state was entered.
func (m *Machine) Since() time.Time {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.since
}

// To moves to next (a no-op when already there) and logs it, with attrs
// (for example "table", "variation:50000"). An unexpected transition is
// logged at WARN and still made.
func (m *Machine) To(next State, attrs ...any) {
	m.mu.Lock()
	from := m.current
	if from == next {
		m.mu.Unlock()
		return
	}
	m.current = next
	m.since = m.now()
	m.mu.Unlock()
	if m.log != nil {
		args := append([]any{"from", string(from), "to", string(next)}, attrs...)
		if Allowed(from, next) {
			m.log.Info("state", args...)
		} else {
			m.log.Warn("state (unexpected transition)", args...)
		}
	}
	if m.onEnter != nil {
		m.onEnter(from, next)
	}
}

// Session is one bot's running record: this session's and this table's
// hands, results and money. Owned by the bot's loop; the debug view reads a
// copy through Snapshot.
type Session struct {
	StartedAt      time.Time
	PlannedEnd     time.Time // the session's length, decided when it starts
	StartChips     int64
	Chips          int64
	Hands          int // hands dealt in, this session
	Wins           int
	Losses         int
	Folds          int
	BiggestWin     int64
	TableHands     int // hands dealt in at the current table
	TableJoinedAt  time.Time
	TableStartChip int64
	LastHandAt     time.Time
}

// Net is the session's result in chips so far.
func (s Session) Net() int64 { return s.Chips - s.StartChips }

// TableNet is the result at the current table so far.
func (s Session) TableNet() int64 { return s.Chips - s.TableStartChip }

// Snapshot is one bot as the debug view shows it. Cards is filled only when
// debug explicitly allows cards (config debug.show_cards); otherwise nil.
type Snapshot struct {
	Bot          string    `json:"bot"`
	UserID       string    `json:"userId"`
	Personality  string    `json:"personality"`
	State        State     `json:"state"`
	StateSince   time.Time `json:"stateSince"`
	Table        string    `json:"table,omitempty"` // "variation:50000"
	RoomID       string    `json:"roomId,omitempty"`
	HandNo       int       `json:"hand,omitempty"`
	IsBlind      bool      `json:"isBlind"`
	Cards        []string  `json:"cards,omitempty"`
	LastDecision string    `json:"decision,omitempty"`
	LastReason   string    `json:"reason,omitempty"`
	LastReaction string    `json:"reaction,omitempty"` // "2.1s"
	Chips        int64     `json:"chips"`
	SessionHands int       `json:"sessionHands"`
	Wins         int       `json:"wins"`
	Losses       int       `json:"losses"`
	Reconnects   int       `json:"reconnects"`
	LastError    string    `json:"lastError,omitempty"`
}

// String is the debug view's text form (the brief's §34).
func (s Snapshot) String() string {
	cards := "hidden"
	if len(s.Cards) > 0 {
		cards = fmt.Sprint(s.Cards)
	}
	return fmt.Sprintf("Bot: %s\nPersonality: %s\nState: %s\nTable: %s\nHand: %d\nCards: %s\nDecision: %s\nReason: %s\nReaction: %s\nSession hands: %d\nWins: %d\nLosses: %d\nChips: %d\n",
		s.Bot, s.Personality, s.State, orDash(s.Table), s.HandNo, cards, orDash(s.LastDecision), orDash(s.LastReason),
		orDash(s.LastReaction), s.SessionHands, s.Wins, s.Losses, s.Chips)
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
