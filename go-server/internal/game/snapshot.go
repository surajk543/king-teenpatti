package game

// Snapshot is the table as the LIVE STORE remembers it (LIVE_STATE_PLAN.md):
// everything a lossless RestoreTable needs, cards included. The table actor
// saves one after every mutation (Table.flushLive → live.Store.SaveTable)
// under a strictly increasing per-table Seq. Server-side only — NEVER sent to
// a client, which gets TableView instead.
//
// History: this was table.js _snapshot, written to game_states inside every
// ledger transaction. That column is gone; the JSON keys Node wrote are kept
// (roomId, code, category, state, handNo, dealerSeat, hand, seats and their
// members) and the rest was added for the restore. Snapshot ⇄ RestoreTable ⇄
// Snapshot must be an identity (TestSnapshotRoundTripIsLossless).
//
// Not in the snapshot, on purpose: seat connectivity (connected, socketId,
// disconnectedAt) — a restored process has no sockets, every restored seat is
// disconnected and the socket layer arms the reconnect grace timer; the turn
// token (a fresh one names the re-armed clock); and the CHAT LOG. Chat is
// deliberately excluded (LIVE_STATE_PLAN.md invariant 5): messages must never
// reach PostgreSQL, and the snapshot is also the durable game_states row.
// Chat lives in the live store only (Table.PostChat mirrors it, Destroy
// deletes it) and is the one thing allowed to vanish when that store dies; a
// table rebuilt from a snapshot alone starts with an empty room log.
// TestSnapshotNeverCarriesChat pins this.
type Snapshot struct {
	RoomID     string          `json:"roomId"`
	Code       string          `json:"code"`
	Category   Category        `json:"category"`
	State      TableState      `json:"state"`
	HandNo     int             `json:"handNo"`
	DealerSeat int             `json:"dealerSeat"`
	Hand       *SnapshotHand   `json:"hand"`  // null between hands
	Seats      []*SnapshotSeat `json:"seats"` // len == MaxPlayers; nil entries marshal as null (empty seats)

	// ---- added for the live store / restore ----

	// Seq is the live-store sequence number this snapshot was saved under
	// (0 before the first save). Separate from Version.
	Seq int64 `json:"seq"`
	// Version is the count of committed ledger writes (Table.Version).
	Version   int64          `json:"version"`
	IsPrivate bool           `json:"isPrivate"`
	CreatedAt int64          `json:"createdAt"` // epoch ms
	Config    SnapshotConfig `json:"config"`
	// StartsAt is the countdown target (epoch ms) while State == starting,
	// else null.
	StartsAt *int64 `json:"startsAt"`
}

// SnapshotConfig is TableConfig in JSON (durations in ms, as everywhere on
// the wire and in the store).
type SnapshotConfig struct {
	Category           Category `json:"category"`
	BootAmount         int64    `json:"bootAmount"`
	MaxPlayers         int      `json:"maxPlayers"`
	MinPlayers         int      `json:"minPlayers"`
	TurnTimeoutMs      int64    `json:"turnTimeoutMs"`
	MaxBetRounds       int      `json:"maxBetRounds"`
	PotLimitMultiplier int64    `json:"potLimitMultiplier"`
	MaxRaiseSteps      int      `json:"maxRaiseSteps"`
	MaxPot             int64    `json:"maxPot"`
	MaxBlindMoves      int      `json:"maxBlindMoves"`
	MaxMissedTurns     int      `json:"maxMissedTurns"`
	SideshowTimeoutMs  int64    `json:"sideshowTimeoutMs"`
	SideshowMinPlayers int      `json:"sideshowMinPlayers"`
	NextHandDelayMs    int64    `json:"nextHandDelayMs"`
	UnfundedGraceMs    int64    `json:"unfundedGraceMs,omitempty"`
	ChatMaxHistory     int      `json:"chatMaxHistory"`
	ChatMaxLength      int      `json:"chatMaxLength"`
}

// SnapshotHand is Snapshot.hand.
type SnapshotHand struct {
	ID              string                 `json:"id"`
	HandNo          int                    `json:"handNo"`
	Pot             int64                  `json:"pot"`
	Stake           int64                  `json:"stake"`
	Round           int                    `json:"round"`
	TurnSeat        int                    `json:"turnSeat"`
	StartSeat       int                    `json:"startSeat"`
	StartedAt       int64                  `json:"startedAt"`
	ShowRequestedBy *string                `json:"showRequestedBy"` // null until a show is paid
	Contributions   []SnapshotContribution `json:"contributions"`   // hand.contributions.values() in insertion order

	// ---- added for the live store / restore ----

	// PackedUserIDs is hand.packedUserIds, sorted (a set).
	PackedUserIDs []string `json:"packedUserIds"`
	// SeatOrder is the seat indices dealt in, in seat order.
	SeatOrder []int `json:"seatOrder"`
	// Sideshow is the request awaiting an answer, or null.
	Sideshow *SnapshotSideshow `json:"sideshow"`
	// LastDeparture is the last player to leave mid-hand (requirement 15), or null.
	LastDeparture *string `json:"lastDeparture"`
	// TurnDeadline is hand.turnDeadline (epoch ms), or null before the first turn.
	TurnDeadline *int64 `json:"turnDeadline"`
	// ActionIDs are the client action ids this hand has already accepted for
	// a bet, sorted (a set). A bet writes nothing to PostgreSQL, so the
	// chip_ledger UNIQUE index no longer refuses a replay — this does, and it
	// has to survive a restart to keep doing it. Never nil.
	ActionIDs []string `json:"actionIds"`
}

// SnapshotSideshow is SnapshotHand.sideshow (hand.sideshow without the timer).
type SnapshotSideshow struct {
	FromUserID string `json:"fromUserId"`
	FromSeat   int    `json:"fromSeat"`
	ToUserID   string `json:"toUserId"`
	ToSeat     int    `json:"toSeat"`
	ExpiresAt  int64  `json:"expiresAt"` // epoch ms
}

// SnapshotContribution is one entry of SnapshotHand.contributions.
type SnapshotContribution struct {
	UserID      string    `json:"userId"`
	Contributed int64     `json:"contributed"`
	Status      SeatState `json:"status"`
	DidChaal    bool      `json:"didChaal"`
	LeftMidHand bool      `json:"leftMidHand"`

	// ---- added for the live store / restore ----

	DisplayName string   `json:"displayName"`
	SeatIndex   int      `json:"seatIndex"`
	SawCards    bool     `json:"sawCards"`
	Cards       []string `json:"cards"` // wire codes; never nil
	// Chips is this player's stack as the LIVE state has it.
	Chips int64 `json:"chips"`
	// ChipsWritten is the stack as PostgreSQL last had it. The next
	// checkpoint writes `Chips - ChipsWritten`, so this is what makes the
	// three-moment money model survive a restart: without it a rebuilt table
	// could not tell how much of a player's stake had already been banked.
	ChipsWritten int64 `json:"chipsWritten"`
}

// SnapshotSeat is one occupied seat in Snapshot.seats.
type SnapshotSeat struct {
	SeatIndex   int       `json:"seatIndex"`
	UserID      string    `json:"userId"`
	DisplayName string    `json:"displayName"`
	Chips       int64     `json:"chips"`
	Status      SeatState `json:"status"`
	IsBlind     bool      `json:"isBlind"`
	BlindMoves  int       `json:"blindMoves"`
	Contributed int64     `json:"contributed"`
	Cards       []string  `json:"cards"` // wire codes; never nil — marshal [] not null

	// ---- added for the live store / restore ----

	AvatarURL             *string `json:"avatarUrl"`
	LastBet               int64   `json:"lastBet"`
	LastAction            *Action `json:"lastAction"`
	MissedTurns           int     `json:"missedTurns"`
	SideshowAskedThisTurn bool    `json:"sideshowAskedThisTurn"`
	KickPending           bool    `json:"kickPending"`
	UnfundedUntil         *int64  `json:"unfundedUntil,omitempty"` // epoch ms: end of the unfunded grace
	JoinedAt              int64   `json:"joinedAt"`                // epoch ms
}

// HandSummaryEntry is one contributor in hands.summary_json and in the
// game:handEnded `summary` array — the same shape in both places.
type HandSummaryEntry struct {
	UserID      string    `json:"userId"`
	DisplayName string    `json:"displayName"`
	SeatIndex   int       `json:"seatIndex"`
	Contributed int64     `json:"contributed"`
	Status      SeatState `json:"status"`
	SawCards    bool      `json:"sawCards"`
	// Cards is the hand for players who were revealed at showdown, null for
	// everyone else (Node: `revealed.has(userId) ? codes : null`).
	Cards []string `json:"cards"`
}
