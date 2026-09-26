package poker

import (
	"fmt"
	"sync/atomic"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Config is one poker room's immutable configuration (Factory.configFor).
type Config struct {
	Category game.Category
	Variant  VariantConfig
	// BootAmount is the stake: the big blind (Blinds variants) or the ante.
	BootAmount int64
	MaxPlayers int
	MinPlayers int
	// TurnTimeout is how long each decision has (POKER_TURN_TIMEOUT_MS, else
	// TURN_TIMEOUT_MS).
	TurnTimeout    time.Duration
	NextHandDelay  time.Duration
	UnfundedGrace  time.Duration
	MaxMissedTurns int
	// MinBuyIn is the smallest stack that may sit down and be dealt in
	// (POKER_MIN_BUYIN_BOOTS × BootAmount).
	MinBuyIn int64
	// MaxDiscards is 5-Card Draw's exchange limit (POKER_MAX_DISCARDS).
	MaxDiscards    int
	ChatMaxHistory int
	ChatMaxLength  int
}

// Table is one poker room: a game.Room built on game.Actor, game.LiveState
// and game.Settler — the shell Teen Patti's Table is built on — with the
// poker family's own seats, hand, streets, view, snapshot and settlement.
// Every rule of that shell holds here: exported methods post to the actor;
// unexported internals never do; Listener and RoomHooks callbacks run on the
// actor and never call back in.
type Table struct {
	id        string
	code      string
	cfg       Config
	isPrivate bool
	ledger    game.Ledger
	clock     game.Clock
	listener  Listener
	hooks     game.RoomHooks
	createdAt time.Time

	onHandStart func(d time.Duration)

	*game.Actor
	*game.LiveState
	*game.Settler

	playerCount atomic.Int32
	hasHand     atomic.Bool
	state       atomic.Value // game.TableState
	version     atomic.Int64

	// ---- actor-owned ----
	seats    []*seat
	handNo   int
	hand     *hand
	button   int // -1 before the first hand
	startsAt *time.Time
	chat     *game.RoomChat
	// lastResult is the previous hand's outcome, shown until the next deal.
	lastResult *ResultView

	turnTimer        game.Timer
	startTimer       game.Timer
	startTimerGen    uint64
	unfundedTimer    game.Timer
	unfundedTimerGen uint64

	view *View
}

// seat is one occupied seat, actor-owned.
type seat struct {
	seatIndex   int
	userID      string
	displayName string
	avatarURL   *string
	chips       int64
	socketID    string
	connected   bool
	status      game.SeatState
	cards       []game.Card
	contributed int64 // this hand
	streetBet   int64 // this street
	allIn       bool
	acted       bool // has acted on this street since the last bet or raise
	drew        bool // has had the draw
	played      bool // 3-Card Poker: has placed the play bet
	missedTurns int
	lastAction  *Action
	joinedAt    time.Time

	disconnectedAt *time.Time
	kickPending    bool
	unfundedUntil  *time.Time
}

// inHand: dealt in and neither folded nor resolved.
func (s *seat) inHand() bool { return s.status == game.SeatActive }

// canAct: in the hand and not all-in — somebody a street still waits for.
func (s *seat) canAct() bool { return s.inHand() && !s.allIn }

// contribution is hand.contributions[userId] — owned by the HAND, not the
// seat, so a player who leaves mid-hand is still settled and audited.
type contribution struct {
	userID      string
	displayName string
	seatIndex   int
	contributed int64
	status      game.SeatState
	cards       []game.Card
	played      bool // a voluntary bet beyond the blinds/ante — hands_played (requirement 16)
	folded      bool
	leftMidHand bool
	allIn       bool
	won         int64 // taken from the pots at the hand's end
	// chips / chipsWritten: the three-checkpoint money model (CLAUDE.md
	// §5.1), exactly as game.Table keeps them.
	chips        int64
	chipsWritten int64
}

// hand is the live hand.
type hand struct {
	id        string
	handNo    int
	startedAt time.Time
	pot       int64 // everything contributed so far
	// streets are the variant's, copied at the deal; streetIndex indexes them
	// and len(streets) is the showdown.
	streets       []Street
	streetIndex   int
	deck          []game.Card // the stub after the deal, dealt from in order
	community     []game.Card
	dealerCards   []game.Card // 3-Card Poker
	dealerHand    *Hand       // set at the reveal
	button        int
	currentBet    int64
	minRaise      int64
	turnSeat      int
	turnDeadline  time.Time
	turnToken     string
	contributions map[string]*contribution
	contribOrder  []string
	actionIDs     map[string]struct{}
	lastDeparture *string
}

// street is the current phase; StreetShowdown once the streets are done.
func (h *hand) street() Street {
	if h.streetIndex < 0 || h.streetIndex >= len(h.streets) {
		return StreetShowdown
	}
	return h.streets[h.streetIndex]
}

// ---------------------------------------------------------- constructing

// TableOptions builds a Table.
type TableOptions struct {
	ID        string
	Code      string
	Config    Config
	IsPrivate bool
	Listener  Listener
	Deps      game.RoomDeps
}

// NewTable constructs the room and starts its actor goroutine.
func NewTable(opts TableOptions) *Table {
	t := newTableCore(opts)
	go t.Loop()
	return t
}

// newTableCore is NewTable without starting the actor (restore fills the
// actor-owned fields in first).
func newTableCore(opts TableOptions) *Table {
	deps := opts.Deps
	clock := deps.Clock
	if clock == nil {
		clock = game.RealClock{}
	}
	listener := opts.Listener
	if listener == nil {
		listener = NopListener{}
	}
	ledger := deps.Ledger
	if ledger == nil {
		ledger = game.NewMemoryLedger(game.MemoryLedgerHooks{})
	}
	hooks := deps.Hooks
	if hooks == nil {
		hooks = nopHooks{}
	}
	cfg := opts.Config
	if cfg.MaxPlayers < 0 {
		cfg.MaxPlayers = 0
	}
	if cfg.Variant.Variant == "" {
		if v, ok := VariantOf(cfg.Category); ok {
			cfg.Variant = Variants[v]
		} else {
			cfg.Variant = Variants[TexasHoldem]
			cfg.Category = TexasHoldem.Category()
		}
	}
	chatHistory, chatLength := cfg.ChatMaxHistory, cfg.ChatMaxLength
	if chatHistory <= 0 {
		chatHistory = 100
	}
	if chatLength <= 0 {
		chatLength = 140
	}
	t := &Table{
		id:          opts.ID,
		code:        opts.Code,
		cfg:         cfg,
		isPrivate:   opts.IsPrivate,
		ledger:      ledger,
		clock:       clock,
		listener:    listener,
		hooks:       hooks,
		createdAt:   clock.Now(),
		onHandStart: deps.ObserveHandStart,
		seats:       make([]*seat, cfg.MaxPlayers),
		button:      -1,
		chat:        game.NewRoomChat(chatHistory, chatLength, clock),
	}
	t.Actor = game.NewActor(opts.ID, t.flushLive)
	t.LiveState = game.NewLiveState(opts.ID, deps.Live, deps.LiveTTL, deps.LiveErrors, t.Actor, game.LiveHooks{
		Snapshot: func(seq int64) ([]byte, error) { return t.marshalSnapshot(seq) },
		Fenced:   t.onFenced,
		Failed: func(reason string, err error) {
			t.hooks.OnRoomPersistError(t, game.PersistErrorEvent{Reason: reason, Err: err})
		},
	})
	t.Settler = game.NewSettler(ledger, clock, t.Actor, cfg.NextHandDelay, &t.version, deps.SettlementOwed, game.SettlerHooks{
		Landed:      t.onSettleLanded,
		RetryFailed: t.onSettleRetryFailed,
		Abandoned:   t.onSettleAbandoned,
	})
	t.state.Store(game.TableWaiting)
	t.view = &View{t: t}
	return t
}

// nopHooks is the RoomHooks of a room built without a manager (unit tests).
type nopHooks struct{}

func (nopHooks) OnRoomState(game.Room)                                {}
func (nopHooks) OnRoomKick(game.Room, game.KickEvent)                 {}
func (nopHooks) OnRoomPersistError(game.Room, game.PersistErrorEvent) {}
func (nopHooks) OnRoomError(game.Room, error)                         {}

func (t *Table) run(fn func()) error { return t.Actor.Run(fn) }

// flushLive is Actor.after: LiveState.Flush.
func (t *Table) flushLive() { t.LiveState.Flush() }

// onFenced: another process owns this room — stop every clock and report.
func (t *Table) onFenced(err *game.FencedError) {
	t.clearTurnTimer()
	t.clearStartTimer()
	t.clearUnfundedTimer()
	t.hooks.OnRoomError(t, err)
}

func (t *Table) onSettleLanded(req game.SettleRequest, balances game.SettleResult) {
	for userID, balance := range balances {
		s := t.findSeat(userID)
		if s != nil && !s.inHand() {
			s.chips = balance
		}
	}
	t.emitState()
}

func (t *Table) onSettleRetryFailed(req game.SettleRequest, attempt int, err error) {
	t.hooks.OnRoomPersistError(t, game.PersistErrorEvent{Reason: "settle_retry", HandID: req.HandID, Attempt: attempt, Err: err})
}

func (t *Table) onSettleAbandoned(req game.SettleRequest, err error) {
	t.hooks.OnRoomError(t, err)
}

// ------------------------------------------------------- lock-free reads

func (t *Table) ID() string              { return t.id }
func (t *Table) Code() string            { return t.code }
func (t *Table) Category() game.Category { return t.cfg.Category }
func (t *Table) Game() game.Game         { return game.GamePoker }
func (t *Table) IsPrivate() bool         { return t.isPrivate }
func (t *Table) Config() Config          { return t.cfg }
func (t *Table) Variant() Variant        { return t.cfg.Variant.Variant }
func (t *Table) BootAmount() int64       { return t.cfg.BootAmount }
func (t *Table) MaxPot() int64           { return 0 }
func (t *Table) MaxPlayers() int         { return t.cfg.MaxPlayers }
func (t *Table) CreatedAt() time.Time    { return t.createdAt }
func (t *Table) PlayerCount() int        { return int(t.playerCount.Load()) }
func (t *Table) IsFull() bool            { return t.PlayerCount() >= t.cfg.MaxPlayers }
func (t *Table) IsEmpty() bool           { return t.PlayerCount() == 0 }
func (t *Table) HasHand() bool           { return t.hasHand.Load() }
func (t *Table) Version() int64          { return t.version.Load() }

func (t *Table) State() game.TableState {
	if v, ok := t.state.Load().(game.TableState); ok {
		return v
	}
	return game.TableWaiting
}

// SaveLive posts a save of the current snapshot whether or not anything
// changed (RoomManager.ReconcileLive).
func (t *Table) SaveLive() error { return t.run(func() { t.MarkDirty() }) }

// Settled posts a no-op and waits (tests).
func (t *Table) Settled() error { return t.run(func() {}) }

var _ game.Room = (*Table)(nil)

// --------------------------------------------------------- posted reads

// SerializeFor posts a read and returns the viewer's redacted TableView.
func (t *Table) SerializeFor(viewerID string) (*TableView, error) {
	var view *TableView
	err := t.run(func() { view = t.serializeFor(viewerID) })
	return view, err
}

// ViewFor is SerializeFor for the Room interface.
func (t *Table) ViewFor(viewerID string) (any, error) {
	view, err := t.SerializeFor(viewerID)
	if err != nil {
		return nil, err
	}
	return view, nil
}

func (t *Table) Summary() (game.TableSummary, error) {
	var summary game.TableSummary
	err := t.run(func() { summary = t.summary() })
	return summary, err
}

func (t *Table) Seats() ([]game.SeatInfo, error) {
	var seats []game.SeatInfo
	err := t.run(func() { seats = t.seatInfos() })
	return seats, err
}

func (t *Table) FindSeat(userID string) (*game.SeatInfo, error) {
	var info *game.SeatInfo
	err := t.run(func() {
		if s := t.findSeat(userID); s != nil {
			info = s.info()
		}
	})
	return info, err
}

func (t *Table) ChatHistory() ([]game.ChatMessage, error) {
	var history []game.ChatMessage
	err := t.run(func() { history = t.chat.History() })
	return history, err
}

// Snapshot posts a read and returns the full server-side document (cards
// included). Never send it to a client.
func (t *Table) Snapshot() (*Snapshot, error) {
	var snap *Snapshot
	err := t.run(func() { snap = t.snapshot() })
	return snap, err
}

// ----------------------------------------------------------- mutations

// AddPlayer seats a player: already_seated, table_full, and — poker only —
// insufficient_chips below the buy-in. Sitting down moves no chips.
func (t *Table) AddPlayer(p game.NewPlayer) (*game.SeatInfo, error) {
	var info *game.SeatInfo
	var failure error
	err := t.run(func() { info, failure = t.addPlayer(p) })
	if err != nil {
		return nil, err
	}
	return info, failure
}

// RemovePlayer takes a player off the room; a player in a live hand folds
// and is checkpointed (hand_left). nil, nil when not seated.
func (t *Table) RemovePlayer(userID, reason string) (*game.SeatInfo, error) {
	var info *game.SeatInfo
	err := t.run(func() { info = t.removePlayer(userID, reason) })
	return info, err
}

// SetConnected flags a seat connected/disconnected; socketID "" leaves the
// stored id unchanged.
func (t *Table) SetConnected(userID string, connected bool, socketID string) (*game.SeatInfo, error) {
	var info *game.SeatInfo
	err := t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			return
		}
		s.connected = connected
		if connected {
			s.disconnectedAt = nil
		} else {
			now := t.clock.Now()
			s.disconnectedAt = &now
		}
		if socketID != "" {
			s.socketID = socketID
		}
		t.emitState()
		info = s.info()
	})
	return info, err
}

// SetAvatar puts a newly worn picture on a player's seat.
func (t *Table) SetAvatar(userID string, avatarURL *string) error {
	var url *string
	if avatarURL != nil {
		u := *avatarURL
		url = &u
	}
	return t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			return
		}
		s.avatarURL = url
		t.emitState()
	})
}

// CreditChips adds bought chips to a seated player's live stack, moving
// chipsWritten with it so the purchase is not written twice (the delta model
// of CLAUDE.md §5.1; see game.Table.CreditChips).
func (t *Table) CreditChips(userID string, amount int64) bool {
	if amount <= 0 {
		return false
	}
	var credited bool
	_ = t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			return
		}
		s.chips += amount
		if t.hand != nil {
			if entry := t.hand.contributions[userID]; entry != nil {
				entry.chips += amount
				entry.chipsWritten += amount
			}
		}
		credited = true
		if s.unfundedUntil != nil && s.chips >= t.cfg.MinBuyIn {
			s.unfundedUntil = nil
			t.armUnfundedTimer()
		}
		t.emitState()
		if t.hand == nil {
			t.maybeStart()
		}
	})
	return credited
}

// PostChat appends a player line; not_in_room when unseated.
func (t *Table) PostChat(userID, text string) (*game.ChatMessage, error) {
	var msg *game.ChatMessage
	var failure error
	err := t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			failure = game.NewGameError(game.CodeNotInRoom, game.MsgNotInRoom)
			return
		}
		msg = t.chat.Add(userID, s.displayName, text)
		if msg == nil {
			return
		}
		t.listener.OnChat(t.view, msg)
		t.LiveState.AppendChat(msg, t.chat.MaxHistory)
	})
	if err != nil {
		return nil, err
	}
	return msg, failure
}

// PostEmoji is PostChat for an animated emoji (game.Room.PostEmoji; owner,
// 26 Sep 2026): the same line a Teen Patti table posts — its text the emoji's
// name, the emoji beside it — stored, emitted and mirrored as a typed line is.
func (t *Table) PostEmoji(userID string, emoji game.ChatEmoji) (*game.ChatMessage, error) {
	var msg *game.ChatMessage
	var failure error
	err := t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			failure = game.NewGameError(game.CodeNotInRoom, game.MsgNotInRoom)
			return
		}
		msg = t.chat.AddEmoji(userID, s.displayName, emoji)
		t.listener.OnChat(t.view, msg)
		t.LiveState.AppendChat(msg, t.chat.MaxHistory)
	})
	if err != nil {
		return nil, err
	}
	return msg, failure
}

// StartHand deals now instead of waiting for the countdown (tests).
func (t *Table) StartHand() error { return t.run(func() { t.startHand() }) }

// ActRequest is what a client sends with poker:action beside the action.
type ActRequest struct {
	// Amount is the total street bet for bet/raise; ignored otherwise.
	Amount int64
	// HasAmount says an amount was sent at all.
	HasAmount bool
	// Cards names the cards to discard on a draw (wire codes).
	Cards []string
	// ActionID is the client's idempotency key (may be "").
	ActionID string
}

// ActResult is poker:action's ack.
type ActResult struct {
	Action Action `json:"action"`
	// Amount is the player's street bet after a bet/raise/call/all-in, the
	// play bet after play; absent otherwise.
	Amount *int64 `json:"amount,omitempty"`
	// Discarded is how many cards a draw exchanged; absent otherwise.
	Discarded *int `json:"discarded,omitempty"`
	// AllIn marks a move that put the last chip in.
	AllIn bool `json:"allIn,omitempty"`
}

// Act applies a player action. Errors in order: no_hand, not_seated,
// not_in_hand, not_your_turn, then the street's own refusals.
func (t *Table) Act(userID string, action Action, req ActRequest) (ActResult, error) {
	var result ActResult
	var failure error
	err := t.run(func() { result, failure = t.act(userID, action, req) })
	if err != nil {
		return ActResult{}, err
	}
	return result, failure
}

// Destroy tears the room down: a live hand ends all_left (every contribution
// refunded, since no showdown was reached), timers stop, the live store's
// copy is deleted. A fenced room is torn down without settling.
func (t *Table) Destroy() error { return t.Post(func() { t.destroy() }, true) }

// Suspend stops the room for a graceful restart without ending its hand.
func (t *Table) Suspend() error { return t.Post(func() { t.suspend() }, true) }

// RestoreChat loads the mirrored chat log (RoomManager.Restore).
func (t *Table) RestoreChat(history []game.ChatMessage) error {
	return t.run(func() { t.chat.Restore(history) })
}

// Resume re-arms a restored room's clocks (RoomManager.Restore).
func (t *Table) Resume() error { return t.run(func() { t.resumeTimers() }) }

// ------------------------------------------------------------ internals

func (t *Table) emitState() {
	t.MarkDirty()
	t.listener.OnState(t.view)
	t.hooks.OnRoomState(t)
}

func (t *Table) setState(s game.TableState) { t.state.Store(s) }

func (t *Table) setHand(h *hand) {
	t.hand = h
	t.hasHand.Store(h != nil)
}

func (t *Table) occupiedSeats() []*seat {
	out := make([]*seat, 0, len(t.seats))
	for _, s := range t.seats {
		if s != nil {
			out = append(out, s)
		}
	}
	return out
}

// seatsInHand: dealt in and still in, ascending.
func (t *Table) seatsInHand() []*seat {
	out := make([]*seat, 0, len(t.seats))
	for _, s := range t.seats {
		if s != nil && s.inHand() {
			out = append(out, s)
		}
	}
	return out
}

// fundedSeats: seats that can be dealt in — at least the buy-in, or, once
// seated, at least dealInChips (a short stack may play down; it is the door
// that asks for the buy-in).
func (t *Table) fundedSeats() []*seat {
	out := make([]*seat, 0, len(t.seats))
	for _, s := range t.seats {
		if s != nil && s.chips >= t.dealInChips() {
			out = append(out, s)
		}
	}
	return out
}

// dealInChips is the smallest stack dealt into a hand, and so the line below
// which a seat is unfunded (sweepUnfunded, expireUnfunded): one boot — the
// big blind or the ante — except against the house, where a hand costs the
// ante AND the play bet (2 × ante). A 3-Card Poker stack of exactly one ante
// used to be dealt in, put all of it in as the ante and be offered only a
// fold: the ante lost with certainty (24 Sep 2026 review, PM-3).
func (t *Table) dealInChips() int64 {
	if t.cfg.Variant.HasDealer {
		return 2 * t.cfg.BootAmount
	}
	return t.cfg.BootAmount
}

func (t *Table) findSeat(userID string) *seat {
	for _, s := range t.seats {
		if s != nil && s.userID == userID {
			return s
		}
	}
	return nil
}

func (t *Table) isFull() bool { return len(t.occupiedSeats()) >= t.cfg.MaxPlayers }

func (t *Table) refreshPlayerCount() { t.playerCount.Store(int32(len(t.occupiedSeats()))) }

func (t *Table) seatInfos() []game.SeatInfo {
	occupied := t.occupiedSeats()
	out := make([]game.SeatInfo, 0, len(occupied))
	for _, s := range occupied {
		out = append(out, *s.info())
	}
	return out
}

// info copies a seat into the family-neutral game.SeatInfo (what the
// RoomManager and the socket layer read: chips, socket, status, cards).
func (s *seat) info() *game.SeatInfo {
	cards := make([]game.Card, len(s.cards))
	copy(cards, s.cards)
	var avatar *string
	if s.avatarURL != nil {
		a := *s.avatarURL
		avatar = &a
	}
	var disconnectedAt *int64
	if s.disconnectedAt != nil {
		ms := game.Millis(*s.disconnectedAt)
		disconnectedAt = &ms
	}
	return &game.SeatInfo{
		SeatIndex:      s.seatIndex,
		UserID:         s.userID,
		DisplayName:    s.displayName,
		AvatarURL:      avatar,
		Chips:          s.chips,
		SocketID:       s.socketID,
		Connected:      s.connected,
		Status:         s.status,
		Cards:          cards,
		IsBlind:        false,
		MissedTurns:    s.missedTurns,
		Contributed:    s.contributed,
		JoinedAt:       game.Millis(s.joinedAt),
		DisconnectedAt: disconnectedAt,
		KickPending:    s.kickPending,
	}
}

// addPlayer — see AddPlayer.
func (t *Table) addPlayer(p game.NewPlayer) (*game.SeatInfo, error) {
	if t.findSeat(p.UserID) != nil {
		return nil, game.NewGameError(game.CodeAlreadySeated, game.MsgAlreadySeated)
	}
	if t.isFull() {
		return nil, game.NewGameError(game.CodeTableFull, game.MsgTableFull)
	}
	if p.Chips < t.cfg.MinBuyIn {
		return nil, game.NewGameError(game.CodeInsufficientChips, MsgInsufficientToSit)
	}
	seatIndex := -1
	for i, s := range t.seats {
		if s == nil {
			seatIndex = i
			break
		}
	}
	if seatIndex < 0 {
		return nil, game.NewGameError(game.CodeTableFull, game.MsgTableFull)
	}
	var avatar *string
	if p.AvatarURL != nil {
		a := *p.AvatarURL
		avatar = &a
	}
	s := &seat{
		seatIndex:   seatIndex,
		userID:      p.UserID,
		displayName: p.DisplayName,
		avatarURL:   avatar,
		chips:       p.Chips,
		socketID:    p.SocketID,
		connected:   true,
		status:      game.SeatWaiting,
		cards:       []game.Card{},
		joinedAt:    t.clock.Now(),
	}
	t.seats[seatIndex] = s
	t.refreshPlayerCount()
	if msg := t.chat.AddSystem(fmt.Sprintf(game.ChatJoinedFormat, s.displayName)); msg != nil {
		t.listener.OnChat(t.view, msg)
		t.LiveState.AppendChat(msg, t.chat.MaxHistory)
	}
	t.maybeStart()
	t.emitState()
	return s.info(), nil
}

// removePlayer — see RemovePlayer. A player in a live hand folds (their
// stake stays), is written through (hand_left, CHECKPOINT 2 of 3) and, if
// they were on turn, the turn moves on.
func (t *Table) removePlayer(userID, reason string) *game.SeatInfo {
	s := t.findSeat(userID)
	if s == nil {
		return nil
	}
	wasInHand := t.hand != nil && s.inHand()
	wasOnTurn := t.hand != nil && t.hand.turnSeat == s.seatIndex

	t.seats[s.seatIndex] = nil
	t.refreshPlayerCount()
	if s.unfundedUntil != nil {
		s.unfundedUntil = nil
		t.armUnfundedTimer()
	}
	if msg := t.chat.AddSystem(fmt.Sprintf(game.ChatLeftFormat, s.displayName)); msg != nil {
		t.listener.OnChat(t.view, msg)
		t.LiveState.AppendChat(msg, t.chat.MaxHistory)
	}

	if wasInHand {
		h := t.hand
		s.status = game.SeatPacked
		s.lastAction = actionPtr(ActionFold)
		entry := h.contributions[userID]
		if entry != nil {
			entry.status = game.SeatPacked
			entry.folded = true
			entry.leftMidHand = true
			entry.chips = s.chips
			entry.contributed = s.contributed
			entry.cards = s.cards
		}
		h.lastDeparture = game.StrPtr(userID)
		t.checkpoint(entry, game.LedgerReasonHandLeft, game.LeftActionID(h.id, userID), true)
		t.listener.OnAction(t.view, ActionEvent{
			UserID: userID, SeatIndex: s.seatIndex, Action: ActionFold, Street: h.street(), Pot: h.pot, Reason: reason,
		})
		if t.resolveIfOnlyOneLeft() {
			// The hand ended; the seat was vacated above.
		} else if wasOnTurn {
			t.clearTurnTimer()
			t.advanceAfter(s.seatIndex)
		} else if !t.streetHasSomeoneToAct() {
			// They were the last to act on this street.
			t.clearTurnTimer()
			t.endStreet()
		}
	} else if t.State() == game.TableStarting && len(t.fundedSeats()) < t.cfg.MinPlayers {
		t.cancelStart()
	} else if t.State() == game.TableWaiting {
		t.maybeStart()
	}
	t.emitState()
	return s.info()
}

func actionPtr(a Action) *Action { return &a }

// checkpoint writes ONE player's chips through (a fold, a departure):
// delta = chips now − chips as PostgreSQL last had them. A failure is
// reported and never refuses the move; chipsWritten stays put, so the next
// checkpoint carries the delta.
func (t *Table) checkpoint(entry *contribution, reason, actionID string, outcome bool) {
	if entry == nil || t.hand == nil {
		return
	}
	delta := entry.chips - entry.chipsWritten
	req := game.CheckpointRequest{
		RoomID: t.id,
		HandID: t.hand.id,
		Entry: game.SettleEntry{
			UserID:      entry.userID,
			Delta:       delta,
			ActionID:    actionID,
			Reason:      reason,
			Outcome:     outcome,
			DidChaal:    entry.played,
			LeftMidHand: entry.leftMidHand,
			Game:        game.GamePoker,
			Variant:     t.cfg.Category,
		},
	}
	if _, err := t.ledger.Checkpoint(t.Context(), req); err != nil {
		// duplicate_action is the UNIQUE action_id refusing a write that
		// already landed and whose acknowledgement was lost (CLAUDE.md §5.1):
		// the money moved exactly once, so the seat IS written through and
		// the delta must not be computed against a stale chipsWritten again.
		if game.CodeOf(err, "") != game.CodeDuplicateAction {
			t.hooks.OnRoomPersistError(t, game.PersistErrorEvent{UserID: entry.userID, Delta: delta, Reason: reason, HandID: t.hand.id, Err: err})
			return
		}
	}
	t.version.Add(1)
	entry.chipsWritten = entry.chips
}

// ------------------------------------------------------------- lifecycle

// maybeStart: with state waiting and no countdown, sweep the unfunded, and
// with MinPlayers funded seats arm the countdown (NextHandDelay).
func (t *Table) maybeStart() {
	if t.Destroyed() || t.State() != game.TableWaiting || t.startTimer != nil {
		return
	}
	t.sweepUnfunded()
	if len(t.fundedSeats()) < t.cfg.MinPlayers {
		return
	}
	t.setState(game.TableStarting)
	now := t.clock.Now()
	startsAt := now.Add(t.cfg.NextHandDelay)
	t.startsAt = &startsAt
	t.emitState()
	t.armStartTimerAfter(startsAt.Sub(now), func() { t.startHand() })
}

func (t *Table) armStartTimerAfter(d time.Duration, then func()) {
	t.startTimerGen++
	gen := t.startTimerGen
	t.startTimer = t.clock.AfterFunc(d, func() {
		_ = t.run(func() {
			if t.startTimerGen != gen || t.startTimer == nil {
				return
			}
			t.startTimer = nil
			then()
		})
	})
}

func (t *Table) clearStartTimer() {
	if t.startTimer != nil {
		t.startTimer.Stop()
		t.startTimer = nil
	}
}

func (t *Table) cancelStart() {
	t.clearStartTimer()
	t.startsAt = nil
	t.setState(game.TableWaiting)
	t.emitState()
}

// sweepUnfunded (requirements 31/32): between hands, a seat below
// dealInChips (the boot; 2 × ante against the house) is held for UnfundedGrace and then shown out with insufficient_chips.
func (t *Table) sweepUnfunded() {
	if t.hand != nil {
		return
	}
	now := t.clock.Now()
	granted := false
	for _, s := range t.occupiedSeats() {
		if s.chips >= t.dealInChips() {
			if s.unfundedUntil != nil {
				s.unfundedUntil = nil
				t.MarkDirty()
			}
			continue
		}
		if s.kickPending {
			continue
		}
		if t.cfg.UnfundedGrace > 0 {
			if s.unfundedUntil == nil {
				until := now.Add(t.cfg.UnfundedGrace)
				s.unfundedUntil = &until
				t.MarkDirty()
				granted = true
			}
			if s.unfundedUntil.After(now) {
				continue
			}
		}
		t.kickUnfunded(s)
	}
	t.armUnfundedTimer()
	if granted {
		t.emitState()
	}
}

func (t *Table) kickUnfunded(s *seat) {
	s.kickPending = true
	s.unfundedUntil = nil
	t.MarkDirty()
	t.kick(s, game.KickReasonInsufficientChips, game.KickMessageInsufficientChips)
}

func (t *Table) expireUnfunded() {
	now := t.clock.Now()
	for _, s := range t.occupiedSeats() {
		if s.unfundedUntil == nil || s.unfundedUntil.After(now) || s.kickPending {
			continue
		}
		if s.chips >= t.dealInChips() {
			s.unfundedUntil = nil
			t.MarkDirty()
			continue
		}
		if t.hand != nil && s.inHand() {
			continue
		}
		t.kickUnfunded(s)
	}
	t.armUnfundedTimer()
}

func (t *Table) armUnfundedTimer() {
	t.clearUnfundedTimer()
	if t.Destroyed() {
		return
	}
	var next *time.Time
	for _, s := range t.occupiedSeats() {
		if s.unfundedUntil == nil || s.kickPending || (t.hand != nil && s.inHand()) {
			continue
		}
		if next == nil || s.unfundedUntil.Before(*next) {
			next = s.unfundedUntil
		}
	}
	if next == nil {
		return
	}
	d := max(next.Sub(t.clock.Now()), 0)
	t.unfundedTimerGen++
	gen := t.unfundedTimerGen
	t.unfundedTimer = t.clock.AfterFunc(d, func() {
		_ = t.run(func() {
			if t.unfundedTimerGen != gen || t.unfundedTimer == nil {
				return
			}
			t.unfundedTimer = nil
			t.expireUnfunded()
		})
	})
}

func (t *Table) clearUnfundedTimer() {
	if t.unfundedTimer != nil {
		t.unfundedTimer.Stop()
		t.unfundedTimer = nil
	}
}

// kick only ANNOUNCES; the RoomManager removes the player (RoomHooks).
func (t *Table) kick(s *seat, reason, message string) {
	t.hooks.OnRoomKick(t, game.KickEvent{UserID: s.userID, DisplayName: s.displayName, Reason: reason, Message: message})
}

// ---------------------------------------------------------------- turns

// setTurn puts a seat on turn with a fresh clock and tells the room.
func (t *Table) setTurn(seatIndex int) {
	h := t.hand
	if h == nil || seatIndex < 0 || seatIndex >= len(t.seats) {
		return
	}
	s := t.seats[seatIndex]
	if s == nil {
		return
	}
	h.turnSeat = seatIndex
	deadline := t.clock.Now().Add(t.cfg.TurnTimeout)
	h.turnDeadline = deadline
	token := util.UUID()
	h.turnToken = token
	t.listener.OnTurn(t.view, TurnEvent{
		UserID:    s.userID,
		SeatIndex: seatIndex,
		Street:    h.street(),
		Deadline:  game.Millis(deadline),
		TimeoutMs: t.cfg.TurnTimeout.Milliseconds(),
		Options:   t.options(s),
	})
	t.clearTurnTimer()
	t.turnTimer = t.clock.AfterFunc(t.cfg.TurnTimeout, func() {
		_ = t.run(func() { t.onTurnTimeout(seatIndex, token) })
	})
}

func (t *Table) clearTurnTimer() {
	if t.turnTimer != nil {
		t.turnTimer.Stop()
		t.turnTimer = nil
	}
}

// onTurnTimeout: the clock ran out. A betting street checks when it can and
// folds otherwise; the draw stands pat; the decision folds. missedTurns++,
// and at MaxMissedTurns the seat is kicked (requirement 31).
func (t *Table) onTurnTimeout(seatIndex int, token string) {
	h := t.hand
	if h == nil || seatIndex < 0 || seatIndex >= len(t.seats) {
		return
	}
	s := t.seats[seatIndex]
	if s == nil || h.turnSeat != seatIndex || (token != "" && h.turnToken != token) || !s.inHand() {
		return
	}
	s.missedTurns++
	street := h.street()
	switch {
	case street.IsBetting():
		if s.streetBet >= h.currentBet {
			_, _ = t.applyCheck(s, "timeout")
		} else {
			t.fold(s, "timeout")
		}
	case street == StreetDraw:
		_, _ = t.applyDraw(s, nil, "timeout")
	case street == StreetDecision:
		t.fold(s, "timeout")
	}
	if t.cfg.MaxMissedTurns > 0 && s.missedTurns >= t.cfg.MaxMissedTurns && t.findSeat(s.userID) == s {
		t.kick(s, game.KickReasonIdle, fmt.Sprintf(game.KickMessageIdleFormat, s.missedTurns))
	}
}

// nextSeat is the first seat strictly clockwise from `from` for which ok
// holds; -1 when none.
func (t *Table) nextSeat(from int, ok func(*seat) bool) int {
	n := len(t.seats)
	if n == 0 {
		return -1
	}
	for step := 1; step <= n; step++ {
		index := ((from+step)%n + n) % n
		if s := t.seats[index]; s != nil && ok(s) {
			return index
		}
	}
	return -1
}

// --------------------------------------------------------------- destroy

// destroy ends a live hand all_left — every contribution goes back to its
// contributor, nothing was decided — then stops the clocks, hands the settle
// retries to the detached chain and forgets the room in the store.
func (t *Table) destroy() {
	fenced := t.Fenced()
	if t.hand != nil && !fenced {
		t.endHandRefunded(WinAllLeft)
	}
	t.MarkDestroyed()
	t.clearTurnTimer()
	t.clearStartTimer()
	t.clearUnfundedTimer()
	t.Settler.Detach()
	t.chat.Clear()
	if !fenced {
		t.LiveState.Delete()
	}
	t.Cancel()
}

// suspend saves a final snapshot and stops (RoomManager.Suspend).
func (t *Table) suspend() {
	if t.LiveState.Store() == nil || t.Fenced() {
		t.destroy()
		return
	}
	t.clearTurnTimer()
	t.clearStartTimer()
	t.clearUnfundedTimer()
	t.Settler.Detach()
	t.MarkDirty()
	t.flushLive()
	t.MarkDestroyed()
	t.Cancel()
}

// resumeTimers re-arms every clock against the current time (Resume).
func (t *Table) resumeTimers() {
	t.MarkDirty()
	now := t.clock.Now()
	switch {
	case t.hand != nil:
		h := t.hand
		if h.turnSeat >= 0 && h.turnSeat < len(t.seats) && t.seats[h.turnSeat] != nil {
			token := util.UUID()
			h.turnToken = token
			if h.turnDeadline.IsZero() {
				h.turnDeadline = now.Add(t.cfg.TurnTimeout)
			}
			if !h.turnDeadline.After(now) {
				t.onTurnTimeout(h.turnSeat, token)
			} else {
				seatIndex := h.turnSeat
				t.clearTurnTimer()
				t.turnTimer = t.clock.AfterFunc(h.turnDeadline.Sub(now), func() {
					_ = t.run(func() { t.onTurnTimeout(seatIndex, token) })
				})
			}
		} else if !t.resolveIfOnlyOneLeft() {
			// No turn recorded: open the street to whoever should act.
			if !t.streetHasSomeoneToAct() {
				t.endStreet()
			} else {
				t.setTurn(t.nextSeat(h.button, t.needsAction))
				t.emitState()
			}
		}
	case t.State() == game.TableStarting:
		if t.startsAt == nil || !t.startsAt.After(now) {
			t.startHand()
		} else {
			t.armStartTimerAfter(t.startsAt.Sub(now), func() { t.startHand() })
		}
	default:
		t.maybeStart()
	}
	for _, s := range t.occupiedSeats() {
		if s.kickPending {
			t.kick(s, game.KickReasonInsufficientChips, game.KickMessageInsufficientChips)
		}
	}
	t.armUnfundedTimer()
}

// --------------------------------------------------------------- stakes

func (t *Table) smallBlind() int64 {
	if !t.cfg.Variant.Blinds {
		return 0
	}
	return t.cfg.BootAmount / 2
}

func (t *Table) bigBlind() int64 {
	if !t.cfg.Variant.Blinds {
		return 0
	}
	return t.cfg.BootAmount
}

func (t *Table) ante() int64 {
	if t.cfg.Variant.Blinds {
		return 0
	}
	return t.cfg.BootAmount
}

func (t *Table) maxDiscards() int {
	if !t.cfg.Variant.HasDraw {
		return 0
	}
	return t.cfg.MaxDiscards
}
