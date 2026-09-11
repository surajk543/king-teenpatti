package game

import "encoding/json"

// TableView is the per-viewer snapshot (table.js serializeFor) — the payload
// of room:joined and room:state. It is REDACTED for one viewer and must never
// be sent to anyone else (CLAUDE.md §6.1 "serializeFor redaction (do not break)"):
//
//   - You.Cards only when the viewer has seen (else []);
//   - other seats carry only CardCount, never cards;
//   - on a BLIND table other seats' Chips is null (not 0) and ChipsHidden is true;
//   - MissedTurns / MaxMissedTurns / Options only inside You;
//   - Sideshow carries ids, seats and expiresAt — never cards.
//
// Public everywhere: lastBet, lastAction, contributed, isBlind, connected, status.
type TableView struct {
	RoomID   string   `json:"roomId"`
	Code     string   `json:"code"`
	Category Category `json:"category"`
	// ChipsHidden is true on blind tables: other players' stacks are withheld.
	ChipsHidden bool       `json:"chipsHidden"`
	State       TableState `json:"state"`
	HandNo      int        `json:"handNo"`
	DealerSeat  int        `json:"dealerSeat"` // -1 before the first hand
	MaxPlayers  int        `json:"maxPlayers"`
	MinPlayers  int        `json:"minPlayers"`
	BootAmount  int64      `json:"bootAmount"`
	// TurnTimeoutMs is TableConfig.TurnTimeout in ms.
	TurnTimeoutMs int64 `json:"turnTimeoutMs"`
	// StartsAt is the countdown target (epoch ms) while State == starting, else null.
	StartsAt *int64 `json:"startsAt"`
	Pot      int64  `json:"pot"` // hand.pot, or 0 between hands
	// MaxPot is the pot ceiling, 0 when uncapped.
	MaxPot int64 `json:"maxPot"`
	// Stake is hand.stake (blind units) or BootAmount between hands.
	Stake int64 `json:"stake"`
	Round int   `json:"round"` // hand.round or 0
	// Sideshow is the request awaiting an answer, or null.
	Sideshow *SideshowView `json:"sideshow"`
	// Turn is null between hands.
	Turn *TurnView `json:"turn"`
	// You is null for a viewer who is not seated (a spectator socket never
	// exists in practice, but the shape allows it).
	You *YouView `json:"you"`
	// Seats has exactly MaxPlayers entries; empty seats are {seatIndex, status:"empty"}.
	Seats []SeatView `json:"seats"`
}

// SideshowView is TableView.sideshow: public facts only.
type SideshowView struct {
	FromUserID string `json:"fromUserId"`
	FromSeat   int    `json:"fromSeat"`
	ToUserID   string `json:"toUserId"`
	ToSeat     int    `json:"toSeat"`
	ExpiresAt  int64  `json:"expiresAt"` // epoch ms
}

// TurnView is TableView.turn.
type TurnView struct {
	SeatIndex int `json:"seatIndex"`
	// UserID is null if the turn seat is somehow empty (Node: `?.userId ?? null`).
	UserID *string `json:"userId"`
	// Deadline is hand.turnDeadline (epoch ms) or null before the first turn.
	Deadline *int64 `json:"deadline"`
}

// YouView is TableView.you — the viewer's own private facts.
type YouView struct {
	SeatIndex int       `json:"seatIndex"`
	Chips     int64     `json:"chips"`
	Status    SeatState `json:"status"`
	IsBlind   bool      `json:"isBlind"`
	// BlindMovesLeft = max(0, MaxBlindMoves - blindMoves) while blind, else 0.
	BlindMovesLeft int   `json:"blindMovesLeft"`
	Contributed    int64 `json:"contributed"`
	// Requirement 31: warning to this player only.
	MissedTurns    int `json:"missedTurns"`
	MaxMissedTurns int `json:"maxMissedTurns"`
	// UnfundedDeadline (epoch ms) is set while this player cannot cover the
	// boot and the table is holding their seat for a chip purchase
	// (UNFUNDED_GRACE_MS); absent otherwise.
	UnfundedDeadline *int64 `json:"unfundedDeadline,omitempty"`
	// Cards is the viewer's hand once seen, else [] — NEVER null (Flutter
	// reads it as a list). Marshal an empty non-nil slice.
	Cards []string `json:"cards"`
	// Options is non-nil only when a hand is live, it is this viewer's turn
	// and they are active. Flutter derives its whole action bar from it.
	Options *TurnOptions `json:"options"`
}

// TurnOptions is what the player on turn may do (table.js turnOptions) —
// sent in You.Options and in game:yourTurn.options.
type TurnOptions struct {
	CanSee bool `json:"canSee"` // still blind
	// CanSideshow is sideshowBlockedReason == nil (requirement 33).
	CanSideshow bool `json:"canSideshow"`
	// SideshowWith is the right-hand neighbour's displayName, or null when blocked.
	SideshowWith *string `json:"sideshowWith"`
	// Chaal is steps[0] or null when the player cannot afford the base.
	Chaal *int64 `json:"chaal"`
	// Raise is steps[1] or null.
	Raise *int64 `json:"raise"`
	// RaiseSteps is the full +/− ladder, ascending — NEVER null (marshal []).
	RaiseSteps []int64 `json:"raiseSteps"`
	// MaxBet is the last rung or null.
	MaxBet *int64 `json:"maxBet"`
	// Show is the show cost when exactly two seats are active AND the player
	// can afford it, else null. A show is never free.
	Show         *int64 `json:"show"`
	CanPack      bool   `json:"canPack"` // always true
	IsBlind      bool   `json:"isBlind"`
	CurrentStake int64  `json:"currentStake"` // hand.stake in blind units
	Chips        int64  `json:"chips"`
	Pot          int64  `json:"pot"`
}

// BetOptions is table.js betOptions — the ladder before it is dressed up as
// TurnOptions. Steps ascending; Chaal/Raise/Max nil when unavailable.
//
// Rules: base = stake (blind) or 2*stake (seen); perBetCeiling = boot ×
// PotLimitMultiplier (∞ when the multiplier is 0); ceiling = min(perBetCeiling,
// seat.chips); maxSteps = MaxRaiseSteps (∞ when 0); headroom = MaxPot - pot
// (∞ when MaxPot is 0); amount starts at min(base, perBetCeiling) and
// doubles while amount ≤ ceiling && amount ≤ headroom && len(steps) < maxSteps.
type BetOptions struct {
	Steps []int64
	Chaal *int64
	Raise *int64
	Max   *int64
}

// SeatView is one entry of TableView.seats.
//
// An EMPTY seat is serialised as exactly {"seatIndex":n,"status":"empty"} —
// nothing else — which is why MarshalJSON exists. Set Empty=true for those.
type SeatView struct {
	// Empty selects the two-field form. Never on the wire itself.
	Empty bool `json:"-"`

	SeatIndex   int     `json:"seatIndex"`
	UserID      string  `json:"userId"`
	DisplayName string  `json:"displayName"`
	AvatarURL   *string `json:"avatarUrl"` // null when the player has none
	// Chips is null (not 0) for other players on a blind table; always set
	// for the viewer's own seat and on seen tables.
	Chips       *int64    `json:"chips"`
	Status      SeatState `json:"status"`
	IsBlind     bool      `json:"isBlind"`
	LastBet     int64     `json:"lastBet"`
	LastAction  *Action   `json:"lastAction"` // null until the player acts this hand
	Contributed int64     `json:"contributed"`
	Connected   bool      `json:"connected"`
	CardCount   int       `json:"cardCount"` // 0 or 3; never the cards
}

type seatViewFull SeatView

type seatViewEmpty struct {
	SeatIndex int       `json:"seatIndex"`
	Status    SeatState `json:"status"`
}

// MarshalJSON emits the two-field form for empty seats and the full form for
// occupied ones.
func (s SeatView) MarshalJSON() ([]byte, error) {
	if s.Empty {
		return json.Marshal(seatViewEmpty{SeatIndex: s.SeatIndex, Status: SeatEmpty})
	}
	return json.Marshal(seatViewFull(s))
}

// TableSummary is the lobby row (table.js summary) returned by
// RoomManager.ListTables, lobby:list and GET /api/rooms.
type TableSummary struct {
	RoomID     string     `json:"roomId"`
	Code       string     `json:"code"`
	Category   Category   `json:"category"`
	State      TableState `json:"state"`
	Players    int        `json:"players"`
	MaxPlayers int        `json:"maxPlayers"`
	BootAmount int64      `json:"bootAmount"`
	Pot        int64      `json:"pot"` // hand.pot or 0
}

// SeatInfo is a COPY of one seat's full state, returned by the Table's read
// methods (Seats, FindSeat, View.Seats) and by the mutating methods that
// Node returned the seat object from. Mutating a SeatInfo changes nothing.
type SeatInfo struct {
	SeatIndex   int
	UserID      string
	DisplayName string
	AvatarURL   *string
	Chips       int64
	// SocketID is the sio socket id the seat is currently attached to, or "".
	SocketID  string
	Connected bool
	Status    SeatState
	Cards     []Card
	IsBlind   bool
	// BlindMoves: bets made while blind this hand; at MaxBlindMoves the cards
	// turn face up automatically.
	BlindMoves int
	// MissedTurns: consecutive timed-out turns (requirement 31). Reset to 0
	// only after a successful move of the player's own.
	MissedTurns int
	// SideshowAskedThisTurn: one ask per turn; cleared by a FRESH turn only.
	SideshowAskedThisTurn bool
	LastBet               int64
	LastAction            *Action
	Contributed           int64
	JoinedAt              int64  // epoch ms
	DisconnectedAt        *int64 // epoch ms, nil while connected
	// KickPending marks a seat already asked to be kicked by _sweepUnfunded,
	// so a second sweep before the removal lands does not ask again.
	KickPending bool
}

// Int64Ptr / StrPtr / ActionPtr are tiny helpers for the nullable wire fields.
func Int64Ptr(v int64) *int64    { return &v }
func StrPtr(v string) *string    { return &v }
func ActionPtr(a Action) *Action { return &a }
