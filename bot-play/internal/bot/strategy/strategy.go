package strategy

import (
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// HandMemory is what a bot remembers of the hand in progress. Reset for
// every new hand (NewHandMemory); Decide updates it.
//
// Decide counts the move it returns as made: a blind bet adds to
// BlindTurns, a seen one (chaal, raise, show, pack) to SeenTurns, a raise to
// RaisedThisHand, and any bet clears RaisesFaced and BiggestRaiseFaced,
// which count the raises since this bot last acted. A look (see) and a
// sideshow ask count as neither: the turn is still this bot's afterwards.
// The bot adds opponents' raises to RaisesFaced / BiggestRaiseFaced as it
// sees them (game:action).
type HandMemory struct {
	PlannedBlindTurns int   // how many blind bets it means to make before looking (0 = look at once)
	BlindTurns        int   // blind turns taken so far
	SeenTurns         int   // turns taken after looking
	RaisesFaced       int   // opponents' raises since this bot last acted
	BiggestRaiseFaced int64 // the largest of them
	RaisedThisHand    int   // this bot's own raises this hand
	ChangedMind       bool  // a "change of mind" already happened this hand (imperfection)
}

// DecisionContext is everything a turn's decision is made from — all of it
// what this seat's player is shown (brief §31).
type DecisionContext struct {
	Category      string // protocol.CategorySeen | CategoryBlind | CategoryVariation
	Variation     string // the hand's chosen variation, "" when none
	Options       protocol.TurnOptions
	IsBlind       bool
	Hand          decision.HandEvaluation // Known == false while blind
	Pot           int64
	Boot          int64
	Chips         int64
	Contribution  int64 // this bot's chips in this pot
	ActivePlayers int   // players still in the hand, this bot included
	Pressure      decision.Pressure
	Tilt          float64 // 0..1: a stung player plays looser for a while
	Personality   Personality
	Memory        *HandMemory
	EnableBlind   bool // config strategy.enable_blind: false → look at the first chance
	EnableSeen    bool // config strategy.enable_seen: false → never look voluntarily (the server still turns the cards up at the blind limit)
}

// Decision is what to do on this turn.
type Decision struct {
	Action     string  // a protocol.Action* the options allow
	Amount     int64   // for chaal and raise: a rung of Options.RaiseSteps; 0 otherwise
	Confidence float64 // 0..1
	Reason     string  // UPPER_SNAKE, e.g. "MEDIUM_HAND_LOW_PRESSURE" — logged and shown in debug
	Bluff      bool
	Mistake    bool    // this decision is a deliberate imperfection
	Complexity float64 // 0..1: how hard the decision was (timing uses it)
}

// Reasons a Decision gives. They are what the debug view and the logs show,
// so each names the situation, not only the move.
const (
	// Nothing to do.
	ReasonNoLegalMove  = "NO_LEGAL_MOVE" // the options allow no move at all (a sideshow the bot asked stands): wait
	ReasonSafeFallback = "SAFE_FALLBACK" // the plainest legal move, when a choice was somehow not legal

	// Blind.
	ReasonBlindStay         = "BLIND_STAY"          // another blind chaal, as planned
	ReasonBlindLookPlanned  = "BLIND_LOOK_PLANNED"  // the planned blind turns are done
	ReasonBlindLookPressure = "BLIND_LOOK_PRESSURE" // raises and a leaning table make it time to look
	ReasonBlindLookCost     = "BLIND_LOOK_EXPENSIVE"
	ReasonBlindLookWhim     = "BLIND_LOOK_WHIM"
	ReasonBlindLookBroke    = "BLIND_LOOK_CAN_NOT_AFFORD" // the blind chaal is out of reach: look before anything else
	ReasonBlindDisabled     = "BLIND_DISABLED_LOOK"       // configuration says never play blind
	ReasonBlindRaise        = "BLIND_RAISE"
	ReasonBlindShow         = "BLIND_SHOW"
	ReasonBlindPack         = "BLIND_PACK"

	// Seen.
	ReasonStrongHighPressure = "STRONG_HAND_HIGH_PRESSURE"
	ReasonStrongLowPressure  = "STRONG_HAND_LOW_PRESSURE"
	ReasonStrongChaal        = "STRONG_HAND_CHAAL" // strong, but the ladder has no raise to offer
	ReasonSlowPlay           = "SLOW_PLAY"
	ReasonMediumHighPressure = "MEDIUM_HAND_HIGH_PRESSURE"
	ReasonMediumLowPressure  = "MEDIUM_HAND_LOW_PRESSURE"
	ReasonMediumRaise        = "MEDIUM_HAND_RAISE"
	ReasonPressureFold       = "MEDIUM_HAND_FOLD_PRESSURE" // would have stayed in against a quiet table
	ReasonWeakFold           = "WEAK_HAND_FOLD"
	ReasonWeakCheapChaal     = "WEAK_HAND_CHEAP_CHAAL"
	ReasonBluffRaise         = "BLUFF_RAISE"
	ReasonBluffChaal         = "BLUFF_CHAAL"
	ReasonSideshowSettle     = "SIDESHOW_SETTLE"
	ReasonSideshowLongShot   = "SIDESHOW_LONG_SHOT" // a weak hand's free chance instead of folding
	ReasonShowHeadsUp        = "SHOW_HEADS_UP"
	ReasonShowShortStack     = "SHOW_SHORT_STACK"
	ReasonShowPatience       = "SHOW_PATIENCE"
	ReasonShowPressure       = "SHOW_UNDER_PRESSURE"
	ReasonShowCurious        = "SHOW_CURIOUS"
	ReasonBrokeShow          = "CAN_NOT_AFFORD_SHOW"
	ReasonBrokePack          = "CAN_NOT_AFFORD_PACK"
	ReasonUnknownChaal       = "UNKNOWN_HAND_CHAAL" // seen, but no evaluation yet (a 5-Card pick, a variation not chosen)
	ReasonUnknownPack        = "UNKNOWN_HAND_PACK"

	// Imperfections (Decision.Mistake is set).
	ReasonMistakeBadCall      = "MISTAKE_BAD_CALL"
	ReasonMistakeNeedlessFold = "MISTAKE_NEEDLESS_FOLD"
	ReasonMistakeWeakRaise    = "MISTAKE_WEAK_RAISE"
	ReasonMistakeUnderplay    = "MISTAKE_UNDERPLAY" // a big hand not made to pay
	ReasonMistakeChangeOfMind = "MISTAKE_CHANGE_OF_MIND"
	ReasonRandomWhim          = "RANDOM_WHIM" // a noisy player's move on a whim, from the legal ones
)
