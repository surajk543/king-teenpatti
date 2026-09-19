package poker

import "github.com/surajk543/king-teenpatti/go-server/internal/game"

// Listener is the poker room's outward event surface — its own interface,
// not a widening of game.Listener, so no Teen Patti implementer changes
// (POKER_PLAN.md §4). The socket layer implements it beside game.Listener.
// Every method is called ON the room's actor goroutine and must not call back
// into the room; v is the room's live View for per-viewer snapshots.
//
// Kicks, refused writes and fences are not here: they go to the manager's
// game.RoomHooks, exactly as a Teen Patti table's do through tableHooks.
type Listener interface {
	// OnState: something changed — re-send every viewer its TableView.
	OnState(v *View)
	// OnChat: a player or system line was appended.
	OnChat(v *View, msg *game.ChatMessage)
	// OnHandStarted: blinds or antes posted, hole cards dealt (not included).
	OnHandStarted(v *View, e HandStartedEvent)
	// OnCards: PRIVATE — this player's hole cards (at the deal, and after a
	// draw); deliver to e.UserID only.
	OnCards(v *View, e CardsEvent)
	// OnTurn: a seat is on turn. The room hears who and until when; the
	// player alone hears their options.
	OnTurn(v *View, e TurnEvent)
	// OnAction: a move was applied (a leave mid-hand is a fold with Reason).
	OnAction(v *View, e ActionEvent)
	// OnStreet: a street began — community cards dealt (Hold'em, Omaha) or
	// the draw / a betting round opened.
	OnStreet(v *View, e StreetEvent)
	// OnDraw: public — a player exchanged n cards (never which).
	OnDraw(v *View, e DrawEvent)
	// OnShowdown: cards revealed before the hand is settled.
	OnShowdown(v *View, e ShowdownEvent)
	// OnHandEnded: settled (or settlement retrying in the background).
	OnHandEnded(v *View, e HandEndedEvent)
}

// NopListener is a no-op Listener to embed.
type NopListener struct{}

func (NopListener) OnState(*View)                         {}
func (NopListener) OnChat(*View, *game.ChatMessage)       {}
func (NopListener) OnHandStarted(*View, HandStartedEvent) {}
func (NopListener) OnCards(*View, CardsEvent)             {}
func (NopListener) OnTurn(*View, TurnEvent)               {}
func (NopListener) OnAction(*View, ActionEvent)           {}
func (NopListener) OnStreet(*View, StreetEvent)           {}
func (NopListener) OnDraw(*View, DrawEvent)               {}
func (NopListener) OnShowdown(*View, ShowdownEvent)       {}
func (NopListener) OnHandEnded(*View, HandEndedEvent)     {}

var _ Listener = NopListener{}

// HandStartedEvent is poker:handStarted.
type HandStartedEvent struct {
	HandID       string   `json:"handId"`
	HandNo       int      `json:"handNo"`
	Variant      Variant  `json:"variant"`
	DealerSeat   int      `json:"dealerSeat"` // the button
	SmallBlind   int64    `json:"smallBlind"` // 0 for an ante game
	BigBlind     int64    `json:"bigBlind"`
	Ante         int64    `json:"ante"` // 0 for a blinds game
	Pot          int64    `json:"pot"`
	Participants []string `json:"participants"` // userIds dealt in, seat order
}

// CardsEvent is poker:cards, to its owner only.
type CardsEvent struct {
	UserID string
	Cards  []string
}

// TurnEvent is poker:turn (room, no options) and poker:yourTurn (options).
type TurnEvent struct {
	UserID    string
	SeatIndex int
	Street    Street
	Deadline  int64 // epoch ms
	TimeoutMs int64
	Options   Options
}

// ActionEvent is poker:action.
type ActionEvent struct {
	UserID    string `json:"userId"`
	SeatIndex int    `json:"seatIndex"`
	Action    Action `json:"action"`
	// Amount is the player's street bet after the move for a bet, raise, call
	// or all-in; the play bet for play; 0 for fold, check and draw.
	Amount int64  `json:"amount"`
	Street Street `json:"street"`
	Pot    int64  `json:"pot"`
	// AllIn marks a move that put the player's last chip in.
	AllIn bool `json:"allIn,omitempty"`
	// Reason is present only on a fold the player did not choose: "timeout",
	// or a leave reason.
	Reason string `json:"reason,omitempty"`
	// Discarded is present only on a draw: how many cards were exchanged.
	Discarded *int `json:"discarded,omitempty"`
}

// StreetEvent is poker:street.
type StreetEvent struct {
	Street    Street   `json:"street"`
	Community []string `json:"community"` // the whole board so far; [] on a game with none
	Pot       int64    `json:"pot"`
}

// DrawEvent is poker:draw.
type DrawEvent struct {
	UserID    string `json:"userId"`
	SeatIndex int    `json:"seatIndex"`
	Discarded int    `json:"discarded"`
}

// Reveal is one revealed hand at a showdown.
type Reveal struct {
	UserID    string   `json:"userId"`
	SeatIndex int      `json:"seatIndex"`
	Cards     []string `json:"cards"` // the hole cards
	Best      []string `json:"best"`  // the counted cards (hole and board)
	HandName  string   `json:"handName"`
	Category  int      `json:"category"`
	Won       int64    `json:"won"` // chips taken from the pots (0 for a loser)
	// Outcome is 3-Card Poker's verdict against the dealer: win, lose, push,
	// or fold; absent elsewhere.
	Outcome string `json:"outcome,omitempty"`
}

// DealerReveal is the house's hand at a 3-Card Poker showdown.
type DealerReveal struct {
	Cards     []string `json:"cards"`
	HandName  string   `json:"handName"`
	Category  int      `json:"category"`
	Qualified bool     `json:"qualified"`
}

// PotResult is one pot as it was paid.
type PotResult struct {
	Amount   int64       `json:"amount"`
	Eligible []int       `json:"eligible"`
	Winners  []PotWinner `json:"winners"`
}

// PotWinner is one share of one pot.
type PotWinner struct {
	UserID    string `json:"userId"`
	SeatIndex int    `json:"seatIndex"`
	Amount    int64  `json:"amount"`
	HandName  string `json:"handName,omitempty"`
}

// ShowdownEvent is poker:showdown.
type ShowdownEvent struct {
	Reveals   []Reveal      `json:"reveals"`
	Community []string      `json:"community"`
	Dealer    *DealerReveal `json:"dealer,omitempty"`
	Reason    WinReason     `json:"reason"`
}

// HandSummaryEntry is one contributor on poker:handEnded.
type HandSummaryEntry struct {
	UserID      string         `json:"userId"`
	DisplayName string         `json:"displayName"`
	SeatIndex   int            `json:"seatIndex"`
	Contributed int64          `json:"contributed"`
	Won         int64          `json:"won"`
	Status      game.SeatState `json:"status"`
}

// HandEndedEvent is poker:handEnded.
type HandEndedEvent struct {
	HandID     string             `json:"handId"`
	HandNo     int                `json:"handNo"`
	Variant    Variant            `json:"variant"`
	Reason     WinReason          `json:"reason"`
	Pot        int64              `json:"pot"` // everything that was on the table
	Pots       []PotResult        `json:"pots"`
	Reveals    []Reveal           `json:"reveals"`
	Community  []string           `json:"community"`
	Dealer     *DealerReveal      `json:"dealer,omitempty"`
	Summary    []HandSummaryEntry `json:"summary"`
	NextHandAt int64              `json:"nextHandAt"`
}

// View is the handle a Listener receives: read-only access to the room from
// inside its own callbacks (on the actor, so no posting).
type View struct {
	t *Table
}

// ID is the roomId.
func (v *View) ID() string { return v.t.id }

// Category is the poker category.
func (v *View) Category() game.Category { return v.t.cfg.Category }

// SerializeFor is the viewer's redacted TableView, computed inline.
func (v *View) SerializeFor(viewerID string) *TableView { return v.t.serializeFor(viewerID) }

// Room is the room itself, for hooks that need the game.Room.
func (v *View) Room() game.Room { return v.t }
