package game

// Snapshot is the table as the DATABASE should remember it (table.js
// _snapshot): everything needed to audit or rebuild a hand, cards included.
// It is saved as game_states.state (JSONB) inside every ledger transaction.
// Server-side only — NEVER sent to a client, which gets TableView instead.
//
// JSON keys are the contract with the existing rows in production (the Go
// server must write what the Node server wrote, so mixed-version audits and
// tooling keep working).
type Snapshot struct {
	RoomID     string          `json:"roomId"`
	Code       string          `json:"code"`
	Category   Category        `json:"category"`
	State      TableState      `json:"state"`
	HandNo     int             `json:"handNo"`
	DealerSeat int             `json:"dealerSeat"`
	Hand       *SnapshotHand   `json:"hand"`  // null between hands
	Seats      []*SnapshotSeat `json:"seats"` // len == MaxPlayers; nil entries marshal as null (empty seats)
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
}

// SnapshotContribution is one entry of SnapshotHand.contributions.
type SnapshotContribution struct {
	UserID      string    `json:"userId"`
	Contributed int64     `json:"contributed"`
	Persisted   int64     `json:"persisted"`
	Status      SeatState `json:"status"`
	DidChaal    bool      `json:"didChaal"`
	LeftMidHand bool      `json:"leftMidHand"`
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
}

// HandRecord is the completed hand handed to Ledger.Settle (table.js
// _endHand `record`) and written to the `hands` table.
type HandRecord struct {
	ID         string
	RoomID     string
	HandNo     int
	Pot        int64
	WinnerID   *string // nil when every player vanished (pot refunded)
	WinReason  WinReason
	BootAmount int64
	StartedAt  int64 // epoch ms
	EndedAt    int64 // epoch ms
	Summary    []HandSummaryEntry
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
