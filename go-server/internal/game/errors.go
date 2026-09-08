package game

import (
	"errors"
	"fmt"
)

// GameError is the refusal a client is told about: a snake_case Code that is
// the wire contract (ack `{ok:false, code, message}` and `game:error`) and a
// human Message. Port of `class GameError` in table.js and of LedgerError in
// db/ledger.js — the Go Ledger returns *GameError directly (decision 6).
//
// Always compare by Code (errors.As + .Code); never by message text.
type GameError struct {
	Code    string
	Message string
	// UserID is set only on the insufficient_chips refusal CollectBoot raises,
	// naming the seat whose wallet could not cover the boot so _startRefused
	// can show that player out (ledger.js `error.userId = userId`). Never on
	// the wire.
	UserID string
	// Cause is the underlying database/driver error for persist_failed, kept
	// for logs (ledger.js `wrapped.cause = error`). Unwrap returns it.
	Cause error
}

// Error implements error. The text is Message (Node: `error.message`).
func (e *GameError) Error() string { return e.Message }

// Unwrap exposes Cause for errors.Is / errors.As chains.
func (e *GameError) Unwrap() error { return e.Cause }

// Is lets `errors.Is(err, &GameError{Code: "x"})` match on Code alone.
func (e *GameError) Is(target error) bool {
	var t *GameError
	if !errors.As(target, &t) {
		return false
	}
	return t.Code == e.Code
}

// NewGameError builds a GameError. Use the Code* constants below.
func NewGameError(code, message string) *GameError {
	return &GameError{Code: code, Message: message}
}

// Errorf is NewGameError with a formatted message.
func Errorf(code, format string, args ...any) *GameError {
	return &GameError{Code: code, Message: fmt.Sprintf(format, args...)}
}

// CodeOf returns the GameError code inside err, or fallback when err is not a
// GameError (the socket layer uses "internal_error").
func CodeOf(err error, fallback string) string {
	var ge *GameError
	if errors.As(err, &ge) {
		return ge.Code
	}
	return fallback
}

// ErrTableDestroyed is returned by every posting method once Destroy has run
// (decision 4). It is a GameError so the socket layer can ack it like any
// other refusal.
var ErrTableDestroyed = &GameError{Code: CodeTableDestroyed, Message: "This table has been closed"}

// Every GameError code the server can produce, grouped as in
// socket/index.js KNOWN_ERROR_CODES. These strings are the wire contract.
const (
	// Rooms and seating (roomManager.js, socket/index.js)
	CodeAlreadyInRoom     = "already_in_room"    // one seat per player
	CodeAlreadySeated     = "already_seated"     // Table.AddPlayer: same user twice
	CodeInsufficientChips = "insufficient_chips" // join: chips < boot; bet: cannot afford; show: no affordable cost; boot refused by DB
	CodeInvalidStake      = "invalid_stake"      // boot not an integer > 0, or not in TableStakes
	CodeNoOtherTable      = "no_other_table"     // room:switch found nowhere to go
	CodeNotInRoom         = "not_in_room"        // not seated anywhere / postChat by a non-seat
	CodeNotSeated         = "not_seated"         // Table.Act by a user not at this table
	CodeOverEntryCap      = "over_entry_cap"     // requirement 30
	CodePrivateTable      = "private_table"      // room:switch from a private table
	CodeRoomNotFound      = "room_not_found"     // unknown code
	CodeTableFull         = "table_full"
	CodeTableNotOffered   = "table_not_offered" // category:boot pair not on LobbyTables
	CodeUnknownAction     = "unknown_action"

	// Moves (table.js)
	CodeAlreadySeen     = "already_seen"
	CodeDuplicateAction = "duplicate_action" // ledger action_id UNIQUE violation
	CodeInvalidBet      = "invalid_bet"      // not an integer / not a rung / raise < 2×chaal / non-number JSON
	CodeNoHand          = "no_hand"
	CodeNotInHand       = "not_in_hand"
	CodeNotYourTurn     = "not_your_turn"
	CodePersistFailed   = "persist_failed"   // any other ledger failure — nothing changed
	CodeShowUnavailable = "show_unavailable" // show with ≠ 2 active seats

	// Sideshow (table.js sideshowBlockedReason + respondToSideshow)
	CodeAlreadyAsked     = SideshowBlockedAlreadyAsked
	CodeNeighbourIsBlind = SideshowBlockedNeighbourIsBlind
	CodeNoNeighbour      = SideshowBlockedNoNeighbour
	CodeNoSideshow       = "no_sideshow"       // respond with nothing pending
	CodeNotYourSideshow  = "not_your_sideshow" // respond by someone other than toUserId
	CodeSideshowPending  = SideshowBlockedPending
	CodeTooFewPlayers    = SideshowBlockedTooFewPlayers
	CodeYouAreBlind      = SideshowBlockedYouAreBlind

	// Chat
	CodeChatRateLimited = "chat_rate_limited"

	// Ledger-only codes (db/ledger.js KNOWN_LEDGER_CODES) — these never reach
	// a client: Table._refusal maps everything but insufficient_chips and
	// duplicate_action onto persist_failed.
	CodeStaleState    = "stale_state"    // game_states.version did not rise
	CodeNoPot         = "no_pot"         // UPDATE pots matched no row
	CodeUnknownUser   = "unknown_user"   // wallet row missing (also an auth code)
	CodeInvalidAmount = "invalid_amount" // bet amount ≤ 0

	// The socket layer's own refusals
	CodeRateLimited   = "rate_limited"
	CodeInternalError = "internal_error"

	// Go-only: a post to a destroyed table (decision 4). Not in Node's set;
	// safeLabel folds it into "other" for metrics.
	CodeTableDestroyed = "table_destroyed"
)

// KnownLedgerCodes is db/ledger.js KNOWN_LEDGER_CODES — the label set for
// game_db_transaction_errors_total{code}.
var KnownLedgerCodes = map[string]struct{}{
	CodeDuplicateAction: {}, CodeInsufficientChips: {}, CodeStaleState: {}, CodeNoPot: {},
	CodeUnknownUser: {}, CodeInvalidAmount: {}, CodePersistFailed: {},
}

// Refusal messages verbatim from table.js, so the client sees the same text.
const (
	MsgAlreadySeated        = "You are already at this table"
	MsgTableFull            = "This table is full"
	MsgNotInRoom            = "You are not at this table"
	MsgNoHand               = "No hand is in progress"
	MsgNotSeated            = "You are not at this table"
	MsgNotInHand            = "You are not in this hand"
	MsgNotYourTurn          = "It is not your turn"
	MsgAlreadySeen          = "You have already seen your cards"
	MsgInsufficientToBet    = "Not enough chips to bet"
	MsgBetNotWhole          = "Bet amount must be a whole number"
	MsgBetNotAvailable      = "That bet amount is not available"
	MsgRaiseTooSmall        = "A raise must be at least double the chaal"
	MsgBetUnavailable       = "That bet is not available"
	MsgInsufficientForBet   = "Not enough chips for that bet"
	MsgDuplicateAction      = "That move was already applied"
	MsgPersistFailed        = "The move could not be recorded, so nothing was changed"
	MsgShowUnavailable      = "A show needs exactly two players left"
	MsgInsufficientForShow  = "Not enough chips to pay for the show"
	MsgNoSideshow           = "There is no sideshow to answer"
	MsgNotYourSideshow      = "That sideshow was not asked of you"
	MsgSideshowPending      = "A sideshow is already in progress"
	MsgSideshowAlreadyAsked = "You have already asked for a sideshow this turn"
	MsgSideshowTooFewFormat = "A sideshow needs at least %d players in the hand" // SideshowMinPlayers
	MsgSideshowYouAreBlind  = "See your cards before asking for a sideshow"
	MsgSideshowNeighbour    = "The player on your right has not seen their cards"
	MsgSideshowNoNeighbour  = "There is nobody on your right to ask"
	MsgSideshowGeneric      = "You cannot ask for a sideshow now"
	MsgUnknownActionFormat  = "Unknown action \"%s\""
)
