// Package game is the rules engine: the port of server/src/game/ (constants,
// deck, handRank, chat, table, roomManager) plus the Ledger and Clock
// interfaces the Table is built on.
//
// The Table is the single authority. It deals, shuffles with crypto/rand,
// recomputes the bet ladder itself, decides winners and redacts state per
// viewer so no client ever receives a card or a hidden stack it should not
// see. Money is database-first: a move is validated in memory, then written
// as ONE transaction through the injected Ledger, and only after that commit
// does the Table change what it holds and tell anyone (CLAUDE.md §5.1).
//
// Concurrency (PORT_PLAN.md decision 4): every Table is an actor with one
// goroutine; every mutation is posted to it and waited on; events are
// delivered synchronously on that goroutine to one Listener. The Table never
// logs and never touches a socket or the database directly — it emits events
// and calls the Ledger.
package game

// Category is the table category (server/src/game/constants.js TABLE_CATEGORY).
//
// It controls CHIP VISIBILITY, not how betting works: on a seen table every
// stack is public; on a blind table only your own is. SerializeFor enforces it
// by sending other seats' chips as null with chipsHidden:true.
//
// CategoryVariation (Go only; owner, 18 Sep 2026) is the one Teen Patti
// category that does change the game: every hand opens with a window in which
// the player to act first chooses the rules it is decided by
// (table_variation.go, variation.go). Everything else about it is a seen
// table's — the same capped ladder — with a blind table's secrecy.
//
// The four POKER categories (Go only; owner, 19 Sep 2026 — POKER_PLAN.md) name
// a different game family altogether: a table of one of them is not a
// *Table at all but a poker room (internal/poker), built through
// RoomManagerOptions.Factories. The category is still the ONE routing key —
// lobby menu, matchmaking bucket, resume offer, room ack — and Game() says
// which family it belongs to. The set stays CLOSED: seven values, and anything
// unrecognised is still seen (NormalizeCategory, NewTable).
type Category string

const (
	CategoryBlind     Category = "blind"
	CategorySeen      Category = "seen"
	CategoryVariation Category = "variation"

	// The Poker family. Wire values are the lower-case names a LOBBY_TABLES
	// entry, a room:quickJoin payload and a metrics label all carry.
	CategoryThreeCardPoker Category = "three_card_poker"
	CategoryFiveCardDraw   Category = "five_card_draw"
	CategoryTexasHoldem    Category = "texas_holdem"
	CategoryOmaha          Category = "omaha"
)

// Game is a game FAMILY: which rules engine a category's tables run on.
type Game string

const (
	// GameTeenPatti is every table *Table implements: seen, blind, variation.
	// It is the absent value on the wire and in the live store — a Teen Patti
	// snapshot carries no `game` key, so it is byte for byte what it was before
	// poker existed.
	GameTeenPatti Game = "teen_patti"
	// GamePoker is the poker family (internal/poker): 3-Card Poker, 5-Card
	// Draw, Texas Hold'em and Omaha.
	GamePoker Game = "poker"
)

// Game is the family this category's tables belong to.
func (c Category) Game() Game {
	if c.IsPoker() {
		return GamePoker
	}
	return GameTeenPatti
}

// IsPoker reports whether this is one of the four poker categories.
func (c Category) IsPoker() bool {
	switch c {
	case CategoryThreeCardPoker, CategoryFiveCardDraw, CategoryTexasHoldem, CategoryOmaha:
		return true
	}
	return false
}

// PokerCategories lists the poker family in the order the lobby shows it.
var PokerCategories = []Category{CategoryThreeCardPoker, CategoryFiveCardDraw, CategoryTexasHoldem, CategoryOmaha}

// Known reports whether c is one of the seven categories the server knows.
func (c Category) Known() bool {
	switch c {
	case CategoryBlind, CategorySeen, CategoryVariation:
		return true
	}
	return c.IsPoker()
}

// HidesChips reports whether other players' stacks are withheld from a viewer:
// on a blind table, and on a variation one (owner, 18 Sep 2026 — "keep the same
// thing as blind table that no one can see other player amount"). A variation
// table takes its BETTING from the seen table (the two-rung ladder, the rounds,
// a pot cap) and its SECRECY from the blind one; only a seen table shows every
// stack. Every poker table shows every stack: a stack is public information in
// poker, and the pot maths (all-ins, side pots) depend on everyone seeing it.
func (c Category) HidesChips() bool { return c == CategoryBlind || c == CategoryVariation }

// HasVariation reports whether a hand at this table opens with the variation
// window. It IS the switch: there is no second flag that could disagree with
// the category a table was created under.
func (c Category) HasVariation() bool { return c == CategoryVariation }

// TableState is the table lifecycle (TABLE_STATE).
type TableState string

const (
	TableWaiting  TableState = "waiting"  // fewer than MinPlayers funded seats
	TableStarting TableState = "starting" // countdown (NextHandDelay) before the deal
	TableBetting  TableState = "betting"  // a hand is live, someone is on turn
	TableShowdown TableState = "showdown" // cards revealed, winner being resolved
)

// SeatState is a seat's status inside the current hand (SEAT_STATE).
type SeatState string

const (
	SeatEmpty   SeatState = "empty"
	SeatWaiting SeatState = "waiting" // seated, sitting out this hand (joined late / short on chips)
	SeatActive  SeatState = "active"  // in the hand and still betting
	SeatPacked  SeatState = "packed"  // folded
	SeatLost    SeatState = "lost"    // reached showdown and lost
	SeatWon     SeatState = "won"
)

// Action is a move a client may send with game:action (ACTION).
type Action string

const (
	ActionSee      Action = "see"      // reveal own cards — free, off-turn, does not end the turn
	ActionChaal    Action = "chaal"    // bet the current amount (steps[0])
	ActionRaise    Action = "raise"    // bet a higher rung (≥ 2 × steps[0])
	ActionPack     Action = "pack"     // fold
	ActionShow     Action = "show"     // pay chaal to compare, only with exactly two left
	ActionSideshow Action = "sideshow" // ask the player on your right to compare privately
	// ActionForceSideshow compares with the player on your right WITHOUT
	// asking: no request, no answer, it resolves at once as an accepted
	// sideshow would. It costs ForceSideshowCost hammers (owner, 13 Sep 2026;
	// Go only — Node had no such action, DECISIONS.md §2).
	ActionForceSideshow Action = "forceSideshow"
	// ActionMissile shows every hand still in and pays the best of them, at
	// once: a showdown the player on turn forces, paid for with MissileCost
	// missiles (owner, 14 Sep 2026; Go only — DECISIONS.md §2). It needs
	// MissileMinPlayers still in the hand and moves no chips of its own.
	ActionMissile Action = "missile"
)

// AllActions is the set game:action validates against (socket VALID_ACTIONS,
// plus forceSideshow and missile).
var AllActions = map[Action]struct{}{
	ActionSee: {}, ActionChaal: {}, ActionRaise: {}, ActionPack: {}, ActionShow: {}, ActionSideshow: {},
	ActionForceSideshow: {}, ActionMissile: {},
}

// BetKind names the two bet flavours _bet() distinguishes ("chaal" | "raise").
// The value travels in ActResult.Action for bets.
type BetKind string

const (
	BetChaal BetKind = "chaal"
	BetRaise BetKind = "raise"
)

// WinReason says why a hand ended (WIN_REASON). Sent to clients in
// game:showdown / game:handEnded and stored on hands.win_reason.
type WinReason string

const (
	WinLastStanding   WinReason = "last_standing"   // everyone else packed
	WinShow           WinReason = "show"            // a player paid for a show
	WinForcedShowdown WinReason = "forced_showdown" // the round cap was reached
	WinAllLeft        WinReason = "all_left"        // everyone abandoned the hand; last leaver takes it (req. 15)
	WinPotLimit       WinReason = "pot_limit"       // the table's maximum pot was reached (req. 22)
	// WinMissile: a player fired a missile, every hand still in was shown and
	// the best took the pot (owner, 14 Sep 2026; Go only).
	WinMissile WinReason = "missile"
)

// Pack reasons (plain strings in Node, carried in ActionEvent.Reason on a
// pack). "timeout" also drives game_turn_timeouts_total.
const (
	PackReasonPack     = "pack"     // the player chose to fold
	PackReasonTimeout  = "timeout"  // the turn clock ran out (requirement 6d)
	PackReasonSideshow = "sideshow" // lost a sideshow
	// A player leaving mid-hand is announced as a PACK whose reason is the
	// leave reason itself: "left", "moved", "disconnected", or a kick reason.
)

// Leave reasons passed to Table.RemovePlayer / RoomManager.Leave.
const (
	LeaveReasonLeft         = "left"         // voluntary room:leave
	LeaveReasonMoved        = "moved"        // room:switch or consolidation (no merge sweep afterwards)
	LeaveReasonDisconnected = "disconnected" // reconnect grace expired
)

// Kick reasons (KickEvent.Reason, room:kicked.reason, game_kicks_total{reason}).
const (
	KickReasonIdle              = "idle"               // MaxMissedTurns timeouts in a row (requirement 31)
	KickReasonInsufficientChips = "insufficient_chips" // cannot cover the boot (requirements 31/32)
)

// KnownKickReasons is the label set the socket layer folds kick reasons into
// (socket/index.js KNOWN_KICK_REASONS); "unfunded" and "other" are legacy
// entries kept so the metric label set is identical.
var KnownKickReasons = map[string]struct{}{
	KickReasonIdle: {}, KickReasonInsufficientChips: {}, "unfunded": {}, "disconnected": {}, "other": {},
}

// Kick messages, verbatim from table.js — clients show them.
const (
	KickMessageInsufficientChips = "You don't have enough coins to remain in this table"
	// KickMessageIdleFormat is fmt.Sprintf'd with seat.MissedTurns.
	KickMessageIdleFormat = "Left the table after %d missed turns"
)

// Sideshow resolution reasons (SideshowResolvedEvent.Reason).
const (
	SideshowAccepted = "accepted"
	SideshowDeclined = "declined"
	SideshowTimeout  = "timeout" // SideshowTimeout elapsed without an answer
	SideshowLeft     = "left"    // a participant left the table
	// SideshowForced is a Force Sideshow: paid for with a hammer, never asked,
	// always compared. Carried in SideshowReveal.Reason too, so the two
	// players can be told it was forced rather than accepted.
	SideshowForced = "forced"
)

// Sideshow blocked reasons, in the exact order sideshowBlockedReason checks
// them (table.js). Each doubles as a GameError code when the ask is refused.
const (
	SideshowBlockedNoHand           = "no_hand"
	SideshowBlockedNotInHand        = "not_in_hand"
	SideshowBlockedNotYourTurn      = "not_your_turn"
	SideshowBlockedPending          = "sideshow_pending"
	SideshowBlockedAlreadyAsked     = "already_asked"
	SideshowBlockedTooFewPlayers    = "too_few_players"
	SideshowBlockedYouAreBlind      = "you_are_blind"
	SideshowBlockedNoNeighbour      = "no_neighbour"
	SideshowBlockedNeighbourIsBlind = "neighbour_is_blind"
)

// Ledger reasons (chip_ledger.reason). Since 9 Sep 2026 a hand writes one row
// per player per CHECKPOINT — hand_packed at a pack, hand_left on a leave or
// switch, hand_win / hand_loss when the hand ends — and nothing at the deal
// or per bet (see the Ledger doc). `boot`, `bet` and `show` are retired: they
// are still in the vocabulary because rows written before that date carry
// them and the money audit must still read. The last three are written by
// tooling only and listed so the vocabulary is complete (CLAUDE.md §7.3).
const (
	LedgerReasonWelcomeBonus = "welcome_bonus"
	LedgerReasonHandWin      = "hand_win"
	LedgerReasonHandLoss     = "hand_loss"
	// Retired 9 Sep 2026; historical rows only.
	LedgerReasonBoot            = "boot"
	LedgerReasonBet             = "bet"
	LedgerReasonShow            = "show"
	LedgerReasonMilestoneReward = "milestone_reward"
	LedgerReasonTimedBonus      = "timed_bonus"
	// LedgerReasonDailyBonus is the chips of the daily bonus, beside the
	// four-hour timed_bonus (owner, 14 Sep 2026; Go only).
	LedgerReasonDailyBonus = "daily_bonus"
	// LedgerReasonPurchase is chips bought with real money through Google
	// Play. Its action_id is "gplay:<purchaseToken>", and the UNIQUE index on
	// action_id is what stops one purchase being credited twice — see
	// db.CreditPurchase. These are the only rows in the ledger that create
	// chips from outside the game, so they are also what an audit of the chip
	// economy has to separate from play.
	LedgerReasonPurchase = "purchase"
	// LedgerReasonPicturePurchase is a premium profile picture bought with
	// chips (db.Pictures.Buy). Its action_id is "picture:<userId>:<pictureId>"
	// — UNIQUE, so a retried click cannot charge twice, and unique per pair
	// because a picture is bought once and owned for good. Unlike a Play
	// purchase this DESTROYS chips rather than creating them: the delta is
	// negative and the chips leave the economy, which is what makes a premium
	// picture a chip sink rather than a transfer.
	LedgerReasonPicturePurchase = "picture_purchase"
	// LedgerReasonAccountDeleted empties a wallet when a player deletes their
	// account. The row is what keeps SUM(delta) == chips true afterwards: the
	// account's chips go to 0, so the ledger has to record the same drop.
	// Chips leave the economy here, which is correct — the player is gone.
	LedgerReasonAccountDeleted       = "account_deleted"
	LedgerReasonLegacyReconciliation = "legacy_reconciliation"
	LedgerReasonTestFixture          = "test_fixture"
)

// Chat system sender: RoomChat.AddSystem stamps displayName "Table".
const ChatSystemDisplayName = "Table"

// Chat system line formats (table.js addPlayer / _removePlayer).
const (
	ChatJoinedFormat = "%s joined the table"
	ChatLeftFormat   = "%s left the table"
)
