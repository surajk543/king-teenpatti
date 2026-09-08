package game

// Listener receives every Table event — one method per Node event name
// (table.js header comment). Calls are made SYNCHRONOUSLY on the table's
// actor goroutine, in the exact order Node emitted them, with a *View that is
// valid ONLY for the duration of the call.
//
// Rules for implementers (PORT_PLAN.md §Concurrency):
//   - never call a posting method of the same Table from inside a callback
//     (Act, AddPlayer, RemovePlayer, StartHand, Destroy, RespondToSideshow,
//     SetConnected, SetChips, PostChat, Snapshot, SerializeFor, Seats,
//     FindSeat, ChatHistory, Settled) — it deadlocks; use the View instead;
//   - never block (no DB, no network waits, no lock that a Table caller may
//     hold); a slow listener stalls the table's clock;
//   - never retain the *View past the callback;
//   - anything that must call back into the Table or the RoomManager (a kick
//     → RoomManager.Leave, an all-left hand → sweep) goes in a new goroutine.
//
// The socket layer implements the game-facing methods; RoomManager wraps the
// listener to handle OnKick / OnPersistError / OnError itself (roommanager.go).
type Listener interface {
	// OnState: something changed — re-send every viewer its TableView. Node
	// emitted 'state' after nearly every mutation, often twice in one action
	// (e.g. _bet → _advanceTurn emits state, then _bet emits state again);
	// preserve the count where tests may observe it, but clients tolerate
	// duplicates.
	OnState(v *View)
	// OnSeatUpdated: a seat was filled, vacated, or its connection flag or
	// chips changed. Node had no listener for it; kept for completeness.
	OnSeatUpdated(v *View, seatIndex int)
	// OnChat: a player or system line was appended (msg is the stored copy).
	OnChat(v *View, msg *ChatMessage)
	// OnHandStarted: boots committed, cards dealt (cards not included).
	OnHandStarted(v *View, e HandStartedEvent)
	// OnCards: PRIVATE — deliver to e.UserID only (player:cards).
	OnCards(v *View, e CardsEvent)
	// OnTurn: a seat is on turn (fresh or re-issued after a SEE / sideshow).
	// The socket layer sends game:turn to the room WITHOUT options and
	// game:yourTurn WITH options to the player only.
	OnTurn(v *View, e TurnEvent)
	// OnAction: a move was applied (see/chaal/raise/pack/show; a leave
	// mid-hand is a pack with Reason = leave reason).
	OnAction(v *View, e ActionEvent)
	// OnSideshowRequested: public — who asked whom and until when; no cards.
	OnSideshowRequested(v *View, e SideshowRequestedEvent)
	// OnSideshowReveal: PRIVATE — deliver to both e.UserIDs only.
	OnSideshowReveal(v *View, e SideshowRevealEvent)
	// OnSideshowResolved: public outcome.
	OnSideshowResolved(v *View, e SideshowResolvedEvent)
	// OnShowdown: cards revealed before the hand is settled.
	OnShowdown(v *View, e ShowdownEvent)
	// OnHandEnded: settled (or settlement retrying in the background).
	OnHandEnded(v *View, e HandEndedEvent)
	// OnKick: the Table wants a seat vacated (idle / insufficient_chips). The
	// Table only ANNOUNCES it; RoomManager removes the player (in a goroutine)
	// and then tells the socket layer via RoomListener.OnPlayerKicked.
	OnKick(v *View, e KickEvent)
	// OnPersistError: a ledger write failed (boot / bet / show refused, or a
	// settlement attempt failed and will be retried). RoomManager logs it at
	// warn: `table write refused {roomId, reason, error}`.
	OnPersistError(v *View, e PersistErrorEvent)
	// OnError: settlement was abandoned after 10 attempts. RoomManager logs
	// it at error: `table error {roomId, error}`.
	OnError(v *View, err error)
}

// NopListener implements Listener with no-ops; embed it to implement a subset.
type NopListener struct{}

func (NopListener) OnState(*View)                                     {}
func (NopListener) OnSeatUpdated(*View, int)                          {}
func (NopListener) OnChat(*View, *ChatMessage)                        {}
func (NopListener) OnHandStarted(*View, HandStartedEvent)             {}
func (NopListener) OnCards(*View, CardsEvent)                         {}
func (NopListener) OnTurn(*View, TurnEvent)                           {}
func (NopListener) OnAction(*View, ActionEvent)                       {}
func (NopListener) OnSideshowRequested(*View, SideshowRequestedEvent) {}
func (NopListener) OnSideshowReveal(*View, SideshowRevealEvent)       {}
func (NopListener) OnSideshowResolved(*View, SideshowResolvedEvent)   {}
func (NopListener) OnShowdown(*View, ShowdownEvent)                   {}
func (NopListener) OnHandEnded(*View, HandEndedEvent)                 {}
func (NopListener) OnKick(*View, KickEvent)                           {}
func (NopListener) OnPersistError(*View, PersistErrorEvent)           {}
func (NopListener) OnError(*View, error)                              {}

var _ Listener = NopListener{}

// HandStartedEvent ← 'handStarted'. The socket layer adds roomId and sends
// game:handStarted to the room, then player:hand {roomId, dealt:true,
// cardsHidden:true} to every viewer socket.
type HandStartedEvent struct {
	HandID       string   `json:"handId"`
	HandNo       int      `json:"handNo"`
	DealerSeat   int      `json:"dealerSeat"`
	BootAmount   int64    `json:"bootAmount"`
	Pot          int64    `json:"pot"`
	Stake        int64    `json:"stake"`
	Participants []string `json:"participants"` // userIds dealt in, seat order
}

// CardsEvent ← 'cards' (private). Cards are wire codes.
type CardsEvent struct {
	UserID string
	Cards  []string
}

// TurnEvent ← 'turn'.
type TurnEvent struct {
	UserID    string
	SeatIndex int
	Deadline  int64 // epoch ms
	// TimeoutMs is TurnTimeout on a fresh turn; on a SEE re-issue it is the
	// time LEFT (max(0, deadline - now)).
	TimeoutMs int64
	Options   TurnOptions
}

// ActionEvent ← 'action' → game:action {roomId, userId, action, amount, pot,
// stake, reason?, auto?}.
type ActionEvent struct {
	UserID string `json:"userId"`
	Action Action `json:"action"`
	Amount int64  `json:"amount"` // 0 for see / pack
	Pot    int64  `json:"pot"`
	Stake  int64  `json:"stake"`
	// Reason is present only on a pack: PackReason* or a leave reason.
	Reason string `json:"reason,omitempty"`
	// Auto is present (true or false) only on a SEE: true when the cards
	// turned face up by themselves after MaxBlindMoves blind bets.
	Auto *bool `json:"auto,omitempty"`
}

// SideshowRequestedEvent ← 'sideshowRequested' → game:sideshowRequested.
type SideshowRequestedEvent struct {
	FromUserID string `json:"fromUserId"`
	FromName   string `json:"fromName"`
	FromSeat   int    `json:"fromSeat"`
	ToUserID   string `json:"toUserId"`
	ToName     string `json:"toName"`
	ToSeat     int    `json:"toSeat"`
	ExpiresAt  int64  `json:"expiresAt"`
	TimeoutMs  int64  `json:"timeoutMs"` // SideshowTimeout in ms
}

// SideshowHand is one of the two hands in a SideshowReveal.
type SideshowHand struct {
	UserID      string   `json:"userId"`
	DisplayName string   `json:"displayName"`
	Cards       []string `json:"cards"`
	HandName    string   `json:"handName"`
}

// SideshowReveal is the private payload (game:sideshowReveal.reveal).
type SideshowReveal struct {
	Reason       string         `json:"reason"` // always "accepted" here
	PackedUserID string         `json:"packedUserId"`
	Hands        []SideshowHand `json:"hands"` // [asker, asked]
}

// SideshowRevealEvent ← 'sideshowReveal' (private to both UserIDs).
type SideshowRevealEvent struct {
	UserIDs []string // [asker, asked]
	Reveal  SideshowReveal
}

// SideshowResolvedEvent ← 'sideshowResolved' → game:sideshowResolved.
type SideshowResolvedEvent struct {
	FromUserID string `json:"fromUserId"`
	ToUserID   string `json:"toUserId"`
	Accepted   bool   `json:"accepted"`
	Reason     string `json:"reason"` // Sideshow* resolution reason
	// PackedUserID is null unless the sideshow was accepted and compared.
	PackedUserID *string `json:"packedUserId"`
}

// Reveal is one player's cards at showdown (game:showdown.reveals[],
// game:handEnded.reveals[]).
type Reveal struct {
	UserID    string       `json:"userId"`
	SeatIndex int          `json:"seatIndex"`
	Cards     []string     `json:"cards"`
	HandName  string       `json:"handName"`
	Category  HandCategory `json:"category"`
	Won       bool         `json:"won"`
}

// ShowdownEvent ← 'showdown' → game:showdown.
type ShowdownEvent struct {
	Reveals []Reveal  `json:"reveals"`
	Reason  WinReason `json:"reason"`
}

// HandEndedEvent ← 'handEnded' → game:handEnded.
type HandEndedEvent struct {
	HandID string `json:"handId"`
	HandNo int    `json:"handNo"`
	// WinnerID is null when nobody could be paid (every player vanished).
	WinnerID *string `json:"winnerId"`
	// WinnerName is the winner's displayName (from the seat, else the
	// contribution record) or null.
	WinnerName *string   `json:"winnerName"`
	Pot        int64     `json:"pot"`
	Reason     WinReason `json:"reason"`
	// Reveals is [] (never null) for last_standing / all_left.
	Reveals []Reveal           `json:"reveals"`
	Summary []HandSummaryEntry `json:"summary"`
	// NextHandAt is now + NextHandDelay (epoch ms); the client's celebration
	// timer keys off it.
	NextHandAt int64 `json:"nextHandAt"`
}

// KickEvent ← 'kick'.
type KickEvent struct {
	UserID      string
	DisplayName string
	Reason      string // KickReasonIdle | KickReasonInsufficientChips
	Message     string // KickMessage*
}

// PersistErrorEvent ← 'persistError'.
type PersistErrorEvent struct {
	// Reason: "boot" (start refused), "bet" | "show" (move refused),
	// "settle" (first attempt failed), "settle_retry" (attempt n failed),
	// "settle_abandoned" (gave up; only when no OnError consumer — the Go
	// port always has RoomManager, so OnError is used instead).
	Reason  string
	UserID  string // bet/show only
	Delta   int64  // bet/show only (negative)
	HandID  string // settle*
	Attempt int    // settle_retry
	Err     error
}
