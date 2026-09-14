package game

import (
	"context"
	"errors"
	"sync"
)

// MissileCost is what firing one missile costs, in missiles (owner, 14 Sep
// 2026). A constant for the reason ForceSideshowCost is one: the client prints
// the count on its key and the store sells missiles in packs sized around it.
const MissileCost = 1

// MissileMinPlayers is the fewest players who must still be in the hand —
// active, not packed, the one firing included — for a missile to be fired
// (owner: "more than 2 players on the table including himself"). A constant,
// not SIDESHOW_MIN_PLAYERS: the two rules happen to agree today and are not
// the same rule.
const MissileMinPlayers = 3

// PersistReasonMissileSpend is PersistErrorEvent.Reason when the missile
// wallet could not be charged for a reason other than an empty wallet (a
// database failure). The move was refused and nothing resolved.
const PersistReasonMissileSpend = "missile_spend"

// MissileWallet is where missiles are kept: the currency a missile is fired
// with. Production: db.Missiles. Tests: MemoryMissiles. The twin of
// HammerWallet.
//
// Missiles are not chips. Nothing here touches chip_ledger or the three
// checkpoints of the money model (CLAUDE.md §5.1): firing one moves no chips,
// and the showdown it forces settles through the ordinary hand end.
//
// The Table calls SpendMissile from its actor goroutine and blocks on it,
// BEFORE it resolves anything: a missile that was not paid for never flies, and
// no timer or other move can interleave with the spend. ctx is the Table's
// context (cancelled by Destroy).
type MissileWallet interface {
	// SpendMissile takes MissileCost missiles from req.UserID in one
	// transaction, keyed on req.ActionID.
	//
	// A key already paid for charges nothing and succeeds (Charged=false),
	// reporting the balance as it stands: that is a retry whose first attempt
	// committed but whose answer was lost, and it must get the showdown it paid
	// for rather than pay again. A wallet that cannot cover the cost returns a
	// *GameError with Code no_missiles and spends nothing. Any other failure is
	// an error, and the Table refuses the move with persist_failed.
	SpendMissile(ctx context.Context, req MissileSpend) (MissileSpendResult, error)
}

// MissileSpend is one missile's charge.
type MissileSpend struct {
	RoomID string
	HandID string
	UserID string
	// ActionID is the idempotency key: MissileSpendID(hand, user, the client's
	// actionId). The hand and the user are in it so that a client id reused in
	// another hand, or by another player, is a different spend.
	ActionID string
}

// MissileSpendResult is the wallet after a spend.
type MissileSpendResult struct {
	// Remaining is the player's missiles after this call — the figure the ack
	// hands back so the client can update its count without a round trip.
	Remaining int64
	// Charged is false when ActionID had already been paid for.
	Charged bool
}

// MissileSpendID is the key a missile is charged under:
// "<handId>:missile:<userId>:<actionId>". The client's actionId never contains
// a colon (the socket layer and the Table both discard one that does), so the
// key cannot be forged to collide with another player's.
func MissileSpendID(handID, userID, actionID string) string {
	return handID + ":missile:" + userID + ":" + actionID
}

// noMissileWallet is the wallet of a table built without one: nobody has any
// missiles, so every missile is refused no_missiles rather than fired free.
type noMissileWallet struct{}

func (noMissileWallet) SpendMissile(context.Context, MissileSpend) (MissileSpendResult, error) {
	return MissileSpendResult{}, NewGameError(CodeNoMissiles, MsgNoMissiles)
}

// MemoryMissiles is a MissileWallet kept in memory, for tables built without a
// database. It honours the same contract as db.Missiles: a key is charged once,
// a short wallet spends nothing.
type MemoryMissiles struct {
	mu       sync.Mutex
	balances map[string]int64
	paid     map[string]struct{}
	charged  int

	// Fail, if set, is asked before every spend; a non-nil error refuses the
	// spend with nothing charged, as a database that is down would.
	Fail func(req MissileSpend) error
	// LoseAck, if set and true for a request, charges it and THEN reports an
	// error — the commit whose acknowledgement never came back.
	LoseAck func(req MissileSpend) bool
}

// NewMemoryMissiles builds a wallet holding the given balances (nil → empty).
func NewMemoryMissiles(balances map[string]int64) *MemoryMissiles {
	m := &MemoryMissiles{balances: map[string]int64{}, paid: map[string]struct{}{}}
	for id, n := range balances {
		m.balances[id] = n
	}
	return m
}

// SpendMissile implements MissileWallet.
func (m *MemoryMissiles) SpendMissile(_ context.Context, req MissileSpend) (MissileSpendResult, error) {
	if m.Fail != nil {
		if err := m.Fail(req); err != nil {
			var ge *GameError
			if errors.As(err, &ge) {
				return MissileSpendResult{}, ge
			}
			return MissileSpendResult{}, &GameError{Code: CodePersistFailed, Message: err.Error(), Cause: err}
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, done := m.paid[req.ActionID]; done {
		return MissileSpendResult{Remaining: m.balances[req.UserID], Charged: false}, nil
	}
	if m.balances[req.UserID] < MissileCost {
		return MissileSpendResult{}, NewGameError(CodeNoMissiles, MsgNoMissiles)
	}
	m.balances[req.UserID] -= MissileCost
	m.paid[req.ActionID] = struct{}{}
	m.charged++
	if m.LoseAck != nil && m.LoseAck(req) {
		return MissileSpendResult{}, &GameError{Code: CodePersistFailed, Message: "the acknowledgement was lost"}
	}
	return MissileSpendResult{Remaining: m.balances[req.UserID], Charged: true}, nil
}

// Balance is userID's missiles now.
func (m *MemoryMissiles) Balance(userID string) int64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.balances[userID]
}

// Set gives userID exactly n missiles.
func (m *MemoryMissiles) Set(userID string, n int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.balances[userID] = n
}

// Charges is how many spends have actually taken a missile.
func (m *MemoryMissiles) Charges() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.charged
}

var (
	_ MissileWallet = (*MemoryMissiles)(nil)
	_ MissileWallet = noMissileWallet{}
)
