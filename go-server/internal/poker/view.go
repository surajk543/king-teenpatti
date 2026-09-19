package poker

import (
	"encoding/json"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// TableView is a poker room's room:joined / room:state: the redacted,
// per-viewer snapshot (POKER_PLAN.md §8). Every key a Teen Patti TableView has
// for the same concept keeps the same name and shape — roomId, code,
// isPrivate, category, chipsHidden, state, handNo, dealerSeat, maxPlayers,
// minPlayers, bootAmount, turnTimeoutMs, startsAt, pot, turn, you, seats — so
// the client parses the common part with one DTO; `game` says which family,
// and `poker` carries the rest. Nothing here reaches a Teen Patti table.
//
// Redaction: `you.cards` are the viewer's own hole cards and nobody else's;
// other seats carry `cardCount`; the dealer's cards and every revealed hand
// are on `poker.result` only after the showdown, and the board is public.
type TableView struct {
	RoomID    string        `json:"roomId"`
	Code      string        `json:"code"`
	IsPrivate bool          `json:"isPrivate"`
	Game      game.Game     `json:"game"` // always "poker"
	Category  game.Category `json:"category"`
	// ChipsHidden is true at every poker room (owner, 19 Sep 2026): a viewer
	// is told their own stack and nobody else's, as at a blind or variation
	// Teen Patti table (Category.HidesChips).
	ChipsHidden bool            `json:"chipsHidden"`
	State       game.TableState `json:"state"`
	HandNo      int             `json:"handNo"`
	DealerSeat  int             `json:"dealerSeat"` // the button; -1 before the first hand
	MaxPlayers  int             `json:"maxPlayers"`
	MinPlayers  int             `json:"minPlayers"`
	BootAmount  int64           `json:"bootAmount"` // the big blind or the ante
	// TurnTimeoutMs is how long each decision has.
	TurnTimeoutMs int64 `json:"turnTimeoutMs"`
	// StartsAt is the countdown target (epoch ms) while State == starting, else null.
	StartsAt *int64 `json:"startsAt"`
	// Pot is everything on the table this hand (every pot, every street bet).
	Pot int64 `json:"pot"`
	// Turn is null between hands and while nobody is to act.
	Turn *game.TurnView `json:"turn"`
	// You is null for a viewer who is not seated.
	You *YouView `json:"you"`
	// Seats has exactly MaxPlayers entries; empty seats are {seatIndex, status:"empty"}.
	Seats []SeatView `json:"seats"`
	// Poker is the family's own state.
	Poker PokerView `json:"poker"`
}

// PokerView is TableView.poker.
type PokerView struct {
	Variant Variant `json:"variant"`
	// Street is the current phase, "" between hands.
	Street Street `json:"street"`
	// Community is the board so far — [] on a game with none. Never null.
	Community []string `json:"community"`
	// Pots are the pots as they stand (main first), [] between hands.
	Pots []Pot `json:"pots"`
	// CurrentBet is the street's bet to match; MinRaise the least a raise
	// adds to it.
	CurrentBet int64 `json:"currentBet"`
	MinRaise   int64 `json:"minRaise"`
	SmallBlind int64 `json:"smallBlind"` // 0 for an ante game
	BigBlind   int64 `json:"bigBlind"`
	Ante       int64 `json:"ante"` // 0 for a blinds game
	HoleCards  int   `json:"holeCards"`
	// MaxDiscards is 5-Card Draw's exchange limit; 0 elsewhere.
	MaxDiscards int `json:"maxDiscards"`
	// MinBuyIn is the smallest stack that may sit down.
	MinBuyIn int64 `json:"minBuyIn"`
	// Dealer is the house's seat in 3-Card Poker: its card count during the
	// hand, its cards at the reveal. Absent elsewhere.
	Dealer *DealerView `json:"dealer,omitempty"`
	// Result is the last hand's outcome, kept until the next deal so a client
	// arriving mid-celebration (or reconnecting) can draw it. Absent otherwise.
	Result *ResultView `json:"result,omitempty"`
}

// DealerView is PokerView.dealer.
type DealerView struct {
	CardCount int      `json:"cardCount"`
	Cards     []string `json:"cards"` // [] until the reveal
	HandName  string   `json:"handName,omitempty"`
	Qualified *bool    `json:"qualified,omitempty"`
}

// ResultView is PokerView.result: what the hand's end looked like.
type ResultView struct {
	HandID    string        `json:"handId"`
	Reason    WinReason     `json:"reason"`
	Pots      []PotResult   `json:"pots"`
	Reveals   []Reveal      `json:"reveals"`
	Community []string      `json:"community"`
	Dealer    *DealerReveal `json:"dealer,omitempty"`
}

// YouView is TableView.you — the viewer's own private facts.
type YouView struct {
	SeatIndex   int            `json:"seatIndex"`
	Chips       int64          `json:"chips"`
	Status      game.SeatState `json:"status"`
	Cards       []string       `json:"cards"` // hole cards; [] between hands. Never null.
	Contributed int64          `json:"contributed"`
	StreetBet   int64          `json:"streetBet"`
	AllIn       bool           `json:"allIn"`
	// Requirement 31: warning to this player only.
	MissedTurns    int `json:"missedTurns"`
	MaxMissedTurns int `json:"maxMissedTurns"`
	// UnfundedDeadline (epoch ms) is set while this player cannot cover the
	// buy-in and the room is holding their seat for a chip purchase.
	UnfundedDeadline *int64 `json:"unfundedDeadline,omitempty"`
	// Options is non-nil only when it is this viewer's turn.
	Options *Options `json:"options"`
	// Hand is what the viewer's own cards make right now (with the board where
	// there is one): absent before there are enough cards to say.
	Hand *Hand `json:"hand,omitempty"`
}

// Options is what the player on turn may do, with every amount the server
// will accept (POKER_PLAN.md §8). The client draws its keys from this and
// nothing else; the server validates the move against the same figures.
type Options struct {
	Street Street `json:"street"`
	Fold   bool   `json:"fold"`
	Check  bool   `json:"check"`
	// Call with CallAmount (the chips it costs; less than the bet when it is
	// an all-in call).
	Call       bool  `json:"call"`
	CallAmount int64 `json:"callAmount"`
	// Bet opens the street's betting: amount in [MinBet, MaxBet].
	Bet    bool  `json:"bet"`
	MinBet int64 `json:"minBet"`
	MaxBet int64 `json:"maxBet"`
	// Raise TO an amount in [MinRaise, MaxRaise] (the player's whole street
	// bet after the raise).
	Raise    bool  `json:"raise"`
	MinRaise int64 `json:"minRaise"`
	MaxRaise int64 `json:"maxRaise"`
	// Play is 3-Card Poker's play bet of PlayAmount against the dealer.
	Play       bool  `json:"play"`
	PlayAmount int64 `json:"playAmount"`
	// Draw: name up to MaxDiscards of your cards to exchange (none = stand pat).
	Draw        bool `json:"draw"`
	MaxDiscards int  `json:"maxDiscards"`
}

// SeatView is one entry of TableView.seats.
type SeatView struct {
	// Empty selects the two-field form. Never on the wire itself.
	Empty bool `json:"-"`

	SeatIndex   int     `json:"seatIndex"`
	UserID      string  `json:"userId"`
	DisplayName string  `json:"displayName"`
	AvatarURL   *string `json:"avatarUrl"`
	// Chips is null for everyone but the viewer while the room hides stacks
	// (ChipsHidden) — null, never 0, so a client cannot draw a figure that
	// was withheld as if it were a number.
	Chips       *int64         `json:"chips"`
	Status      game.SeatState `json:"status"`
	Connected   bool           `json:"connected"`
	CardCount   int            `json:"cardCount"` // never the cards
	Contributed int64          `json:"contributed"`
	StreetBet   int64          `json:"streetBet"`
	AllIn       bool           `json:"allIn"`
	LastAction  *Action        `json:"lastAction"` // null until the player acts this hand
	Dealer      bool           `json:"dealer"`     // holds the button
}

// MarshalJSON gives an empty seat its two-field form.
func (s SeatView) MarshalJSON() ([]byte, error) {
	if s.Empty {
		return json.Marshal(struct {
			SeatIndex int            `json:"seatIndex"`
			Status    game.SeatState `json:"status"`
		}{s.SeatIndex, game.SeatEmpty})
	}
	type plain SeatView
	return json.Marshal(plain(s))
}

// serializeFor builds the viewer's redacted TableView. Actor only.
func (t *Table) serializeFor(viewerID string) *TableView {
	viewer := t.findSeat(viewerID)
	v := t.cfg.Variant
	view := &TableView{
		RoomID:        t.id,
		Code:          t.code,
		IsPrivate:     t.isPrivate,
		Game:          game.GamePoker,
		Category:      t.cfg.Category,
		ChipsHidden:   t.cfg.Category.HidesChips(),
		State:         t.State(),
		HandNo:        t.handNo,
		DealerSeat:    t.button,
		MaxPlayers:    t.cfg.MaxPlayers,
		MinPlayers:    t.cfg.MinPlayers,
		BootAmount:    t.cfg.BootAmount,
		TurnTimeoutMs: t.cfg.TurnTimeout.Milliseconds(),
		Poker: PokerView{
			Variant:     v.Variant,
			Community:   []string{},
			Pots:        []Pot{},
			SmallBlind:  t.smallBlind(),
			BigBlind:    t.bigBlind(),
			Ante:        t.ante(),
			HoleCards:   v.HoleCards,
			MaxDiscards: t.maxDiscards(),
			MinBuyIn:    t.cfg.MinBuyIn,
		},
	}
	if t.startsAt != nil {
		view.StartsAt = game.Int64Ptr(game.Millis(*t.startsAt))
	}
	if h := t.hand; h != nil {
		view.Pot = h.pot
		view.Poker.Street = h.street()
		view.Poker.Community = game.CardCodes(h.community)
		view.Poker.Pots = t.potsNow()
		view.Poker.CurrentBet = h.currentBet
		view.Poker.MinRaise = h.minRaise
		if v.HasDealer {
			dealer := &DealerView{CardCount: len(h.dealerCards), Cards: []string{}}
			if h.dealerHand != nil {
				dealer.Cards = game.CardCodes(h.dealerCards)
				dealer.HandName = h.dealerHand.Name
				qualified := DealerQualifies(*h.dealerHand)
				dealer.Qualified = &qualified
			}
			view.Poker.Dealer = dealer
		}
		turn := &game.TurnView{SeatIndex: h.turnSeat}
		if h.turnSeat >= 0 && h.turnSeat < len(t.seats) {
			if s := t.seats[h.turnSeat]; s != nil {
				turn.UserID = game.StrPtr(s.userID)
			}
		}
		if !h.turnDeadline.IsZero() {
			turn.Deadline = game.Int64Ptr(game.Millis(h.turnDeadline))
		}
		view.Turn = turn
	} else if v.HasDealer {
		view.Poker.Dealer = &DealerView{Cards: []string{}}
	}
	if r := t.lastResult; r != nil {
		view.Poker.Result = r
	}

	if viewer != nil {
		you := &YouView{
			SeatIndex:      viewer.seatIndex,
			Chips:          viewer.chips,
			Status:         viewer.status,
			Cards:          game.CardCodes(viewer.cards),
			Contributed:    viewer.contributed,
			StreetBet:      viewer.streetBet,
			AllIn:          viewer.allIn,
			MissedTurns:    viewer.missedTurns,
			MaxMissedTurns: t.cfg.MaxMissedTurns,
		}
		if viewer.unfundedUntil != nil && !viewer.kickPending {
			you.UnfundedDeadline = game.Int64Ptr(game.Millis(*viewer.unfundedUntil))
		}
		if t.hand != nil && t.hand.turnSeat == viewer.seatIndex && viewer.inHand() {
			options := t.options(viewer)
			you.Options = &options
		}
		if t.hand != nil && viewer.inHand() {
			if h, ok := t.handOf(viewer.cards); ok {
				you.Hand = &h
			}
		}
		view.You = you
	}

	hideChips := t.cfg.Category.HidesChips()
	view.Seats = make([]SeatView, len(t.seats))
	for index, s := range t.seats {
		if s == nil {
			view.Seats[index] = SeatView{Empty: true, SeatIndex: index, Status: game.SeatEmpty}
			continue
		}
		entry := SeatView{
			SeatIndex:   index,
			UserID:      s.userID,
			DisplayName: s.displayName,
			Chips:       game.Int64Ptr(s.chips),
			// Filled in below; a hidden stack is null rather than a figure.
			Status:      s.status,
			Connected:   s.connected,
			CardCount:   len(s.cards),
			Contributed: s.contributed,
			StreetBet:   s.streetBet,
			AllIn:       s.allIn,
			Dealer:      t.hand != nil && t.button == index,
		}
		if hideChips && (viewer == nil || s.userID != viewer.userID) {
			entry.Chips = nil
		}
		if s.avatarURL != nil {
			entry.AvatarURL = game.StrPtr(*s.avatarURL)
		}
		if s.lastAction != nil {
			a := *s.lastAction
			entry.LastAction = &a
		}
		view.Seats[index] = entry
	}
	return view
}

// potsNow is the pots as a viewer sees them mid-hand: the chips COLLECTED at
// the end of each street, open to the seats still in — what a card room
// pushes into the middle, with the current street's bets still in front of
// the players (seats[].streetBet). The hand's end pays out of pots(true).
func (t *Table) potsNow() []Pot { return t.pots(false) }

// pots builds the pots from the hand's contributions: every chip when
// withStreet is true (the settlement), the collected ones only otherwise.
func (t *Table) pots(withStreet bool) []Pot {
	h := t.hand
	if h == nil {
		return []Pot{}
	}
	contrib := map[int]int64{}
	inHand := map[int]bool{}
	for _, c := range h.contributions {
		amount := c.contributed
		if !withStreet {
			if s := t.seats[c.seatIndex]; s != nil && s.userID == c.userID {
				amount -= s.streetBet
			}
		}
		if amount > 0 {
			contrib[c.seatIndex] = amount
		}
		if !c.folded && !c.leftMidHand {
			inHand[c.seatIndex] = true
		}
	}
	pots := SidePots(contrib, inHand)
	if pots == nil {
		pots = []Pot{}
	}
	return pots
}

// summary (Room.Summary): the lobby row.
func (t *Table) summary() game.TableSummary {
	var pot int64
	if t.hand != nil {
		pot = t.hand.pot
	}
	return game.TableSummary{
		RoomID:     t.id,
		Code:       t.code,
		Category:   t.cfg.Category,
		State:      t.State(),
		Players:    len(t.occupiedSeats()),
		MaxPlayers: t.cfg.MaxPlayers,
		BootAmount: t.cfg.BootAmount,
		Pot:        pot,
	}
}
