package poker

import "github.com/surajk543/king-teenpatti/go-server/internal/game"

// Refusal codes a poker room answers with (game.GameError, snake_case,
// compared by code). The ones a Teen Patti table already has — no_hand,
// not_seated, not_in_hand, not_your_turn, duplicate_action, insufficient_chips,
// persist_failed, table_full, already_seated, not_in_room — are reused with
// their own messages; these are the poker-only ones.
const (
	// CodeInvalidAction: the action is not one the current street allows for
	// this player (a check facing a bet, a raise with no chips beyond the
	// call, a draw outside the draw, a play outside 3-Card Poker…).
	CodeInvalidAction = "invalid_action"
	// CodeInvalidAmount: a bet or raise outside [min, max], or not a whole
	// number.
	CodeInvalidAmount = "invalid_amount"
	// CodeInvalidDiscard: a draw naming a card the player does not hold, one
	// twice, or more than the table's MaxDiscards.
	CodeInvalidDiscard = "invalid_discard"
	// CodeUnknownAction: the action string is not one AllActions knows.
	CodeUnknownAction = game.CodeUnknownAction
)

// Messages (the verbatim wire text).
const (
	MsgNoHand             = "No hand in progress"
	MsgNotSeated          = "You are not at this table"
	MsgNotInHand          = "You are not in this hand"
	MsgNotYourTurn        = "It is not your turn"
	MsgCannotCheck        = "You cannot check: there is a bet to call"
	MsgNothingToCall      = "There is nothing to call"
	MsgCannotBet          = "There is already a bet on this street; raise instead"
	MsgCannotRaise        = "Nothing to raise; bet instead"
	MsgNoChipsToRaise     = "You have no chips beyond the call"
	MsgAmountNotWhole     = "Bet must be a whole number"
	MsgAmountRangeFormat  = "Bet must be between %s and %s"
	MsgNotDrawing         = "It is not the draw"
	MsgTooManyDiscards    = "You may exchange at most %d cards"
	MsgNotYourCard        = "That is not one of your cards"
	MsgDuplicateDiscard   = "A card was named twice"
	MsgNotDecision        = "There is nothing to play against"
	MsgActionOffStreet    = "That move is not available now"
	MsgInsufficientToPlay = "Not enough chips to play"
	MsgDuplicateAction    = "That move was already received"
	MsgPersistFailed      = "Your move could not be saved; please try again"
	MsgInsufficientToSit  = "Not enough chips to sit at this table"
	MsgUnknownActionFmt   = game.MsgUnknownActionFormat
)

func errNoHand() error      { return game.NewGameError(game.CodeNoHand, MsgNoHand) }
func errNotSeated() error   { return game.NewGameError(game.CodeNotSeated, MsgNotSeated) }
func errNotInHand() error   { return game.NewGameError(game.CodeNotInHand, MsgNotInHand) }
func errNotYourTurn() error { return game.NewGameError(game.CodeNotYourTurn, MsgNotYourTurn) }
func errInvalid(msg string) error {
	return game.NewGameError(CodeInvalidAction, msg)
}
func errDuplicateAction() error {
	return game.NewGameError(game.CodeDuplicateAction, MsgDuplicateAction)
}
