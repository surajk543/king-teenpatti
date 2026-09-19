// Package poker is the Poker family (go-server/POKER_PLAN.md): 3-Card Poker
// against the house, 5-Card Draw, Texas Hold'em and Omaha, played at rooms
// that live beside the Teen Patti tables in the same RoomManager, settle
// through the same three checkpoints of CLAUDE.md §5.1, save to the same live
// store and reach clients through the same socket layer.
//
// A poker room is a game.Room built on the shell Teen Patti's Table is built
// on — game.Actor (one goroutine, every mutation a posted closure),
// game.LiveState (one snapshot per closure, the two-owners fence) and
// game.Settler (the hand-end settlement retried until it lands). Everything a
// client can observe — the deal, the legal options on each turn, every amount,
// the pots, the winners — is decided here, and ViewFor redacts per viewer: a
// player's own hole cards, other seats' card COUNT, the dealer's cards only at
// the reveal, the board to everyone.
package poker

import (
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Variant is one of the four games, spelled as its game.Category is: the one
// string a LOBBY_TABLES entry, a room:quickJoin payload, a snapshot, a ledger
// row and a metrics label all carry.
type Variant string

const (
	ThreeCardPoker Variant = Variant(game.CategoryThreeCardPoker)
	FiveCardDraw   Variant = Variant(game.CategoryFiveCardDraw)
	TexasHoldem    Variant = Variant(game.CategoryTexasHoldem)
	Omaha          Variant = Variant(game.CategoryOmaha)
)

// Category is the variant as a game.Category.
func (v Variant) Category() game.Category { return game.Category(v) }

// VariantOf is the variant a poker category names; ok is false for a category
// of another family.
func VariantOf(c game.Category) (Variant, bool) {
	v := Variant(c)
	_, ok := Variants[v]
	return v, ok
}

// Street is a phase of a hand. Which streets a hand has is the variant's
// (VariantConfig.Streets); the wire carries the name.
type Street string

const (
	// Hold'em and Omaha: four betting streets, the board growing between them.
	StreetPreflop Street = "preflop"
	StreetFlop    Street = "flop"
	StreetTurn    Street = "turn"
	StreetRiver   Street = "river"
	// 5-Card Draw: a betting street, the draw, a second betting street.
	StreetPredraw  Street = "predraw"
	StreetDraw     Street = "draw"
	StreetPostdraw Street = "postdraw"
	// 3-Card Poker: each player plays or folds against the dealer's hand.
	StreetDecision Street = "decision"
	// StreetShowdown is the hand's end: cards revealed, pots being paid.
	StreetShowdown Street = "showdown"
)

// IsBetting reports whether a street is one players bet on (fold / check /
// call / bet / raise / all-in), as opposed to the draw or the decision.
func (s Street) IsBetting() bool {
	switch s {
	case StreetPreflop, StreetFlop, StreetTurn, StreetRiver, StreetPredraw, StreetPostdraw:
		return true
	}
	return false
}

// VariantConfig is everything that makes one poker game itself. The four are
// fixed in Variants; nothing here is read from the environment (the few
// deployment knobs are config.PokerConfig).
type VariantConfig struct {
	Variant Variant
	// Name is the game's display name, for logs and the rules text.
	Name string
	// HoleCards is how many cards each player is dealt and holds.
	HoleCards int
	// CommunityCards is how many board cards the hand deals in all (5 for
	// Hold'em and Omaha, 0 otherwise); BoardBy says how many are out by the
	// end of each street.
	CommunityCards int
	// UseExactlyTwoHole: the hand is the best of exactly two hole cards and
	// three board cards (Omaha), never any five of the seven-plus.
	UseExactlyTwoHole bool
	// Blinds: the hand opens with a small and a big blind (Hold'em, Omaha);
	// otherwise every participant posts an ante equal to the boot.
	Blinds bool
	// HasDealer: the players play against the house, not each other (3-Card
	// Poker): no pots, no showdown between players, the dealer's hand decides.
	HasDealer bool
	// HasDraw: the hand has a draw street (5-Card Draw).
	HasDraw bool
	// EvaluateCards is how many cards a hand is scored on: 5 for the five-card
	// games, 3 for 3-Card Poker.
	EvaluateCards int
	// Streets are the hand's phases in order, showdown excluded.
	Streets []Street
	// MinDeck is the most cards a hand at MaxPlayers can consume: the guard
	// that keeps every variant inside one 52-card deck.
	MinDeck int
}

// Variants is the closed table of the four games.
var Variants = map[Variant]VariantConfig{
	TexasHoldem: {
		Variant: TexasHoldem, Name: "Texas Hold'em",
		HoleCards: 2, CommunityCards: 5, Blinds: true, EvaluateCards: 5,
		Streets: []Street{StreetPreflop, StreetFlop, StreetTurn, StreetRiver},
		MinDeck: 5*2 + 5,
	},
	Omaha: {
		Variant: Omaha, Name: "Omaha",
		HoleCards: 4, CommunityCards: 5, UseExactlyTwoHole: true, Blinds: true, EvaluateCards: 5,
		Streets: []Street{StreetPreflop, StreetFlop, StreetTurn, StreetRiver},
		MinDeck: 5*4 + 5,
	},
	FiveCardDraw: {
		Variant: FiveCardDraw, Name: "5-Card Draw",
		HoleCards: 5, HasDraw: true, EvaluateCards: 5,
		Streets: []Street{StreetPredraw, StreetDraw, StreetPostdraw},
		MinDeck: 5*5 + 5*5, // five hands, and every card of every hand exchanged
	},
	ThreeCardPoker: {
		Variant: ThreeCardPoker, Name: "3-Card Poker",
		HoleCards: 3, HasDealer: true, EvaluateCards: 3,
		Streets: []Street{StreetDecision},
		MinDeck: 5*3 + 3,
	},
}

// VariantOrder lists the variants as the lobby shows them (game.PokerCategories).
var VariantOrder = []Variant{ThreeCardPoker, FiveCardDraw, TexasHoldem, Omaha}

// boardBy is how many community cards are on the table by the END of a
// street: none preflop, three on the flop, four on the turn, five on the
// river; 0 on any street of a game with no board.
func boardBy(street Street) int {
	switch street {
	case StreetFlop:
		return 3
	case StreetTurn:
		return 4
	case StreetRiver:
		return 5
	}
	return 0
}

// Action is a move a client may send with poker:action.
type Action string

const (
	ActionFold  Action = "fold"
	ActionCheck Action = "check"
	ActionCall  Action = "call"
	// ActionBet opens the betting on a street nobody has bet on; amount is the
	// total to bet.
	ActionBet Action = "bet"
	// ActionRaise raises a street somebody has bet on; amount is the total to
	// raise TO (this player's whole street bet after the raise).
	ActionRaise Action = "raise"
	// ActionAllIn puts the whole stack in, whatever the street's bet is: a
	// call, a bet or a raise as the amounts fall.
	ActionAllIn Action = "allIn"
	// ActionPlay is 3-Card Poker's play bet (equal to the ante) against the
	// dealer; the alternative is fold.
	ActionPlay Action = "play"
	// ActionDraw is 5-Card Draw's exchange: `cards` names the ones to discard
	// (none = stand pat).
	ActionDraw Action = "draw"
)

// AllActions is the set poker:action validates against.
var AllActions = map[Action]struct{}{
	ActionFold: {}, ActionCheck: {}, ActionCall: {}, ActionBet: {}, ActionRaise: {},
	ActionAllIn: {}, ActionPlay: {}, ActionDraw: {},
}

// ActionNames lists the actions for metric label sets.
var ActionNames = []string{
	string(ActionFold), string(ActionCheck), string(ActionCall), string(ActionBet), string(ActionRaise),
	string(ActionAllIn), string(ActionPlay), string(ActionDraw),
}

// WinReason is why a hand ended, on poker:handEnded and in the metrics.
type WinReason string

const (
	// WinShowdown: the cards were compared and the best hand(s) took the pots.
	WinShowdown WinReason = "showdown"
	// WinLastStanding: everyone else folded (or left).
	WinLastStanding WinReason = "last_standing"
	// WinDealer: a 3-Card Poker hand was decided against the house.
	WinDealer WinReason = "dealer"
	// WinAllLeft: the room was destroyed with a hand live, or every player
	// walked out; the pots are refunded to their contributors.
	WinAllLeft WinReason = "all_left"
)

// WinReasons lists the reasons for metric label sets.
var WinReasons = []string{string(WinShowdown), string(WinLastStanding), string(WinDealer), string(WinAllLeft)}
