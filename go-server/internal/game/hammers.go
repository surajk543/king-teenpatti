package game

import (
	"context"
	"errors"
	"sync"
)

// ForceSideshowCost is what one Force Sideshow costs, in hammers (owner,
// 13 Sep 2026). It is a constant rather than configuration because the price
// is printed on the client's key ("🔨 1") and sold in packs sized around it.
const ForceSideshowCost = 1

// PersistReasonHammerSpend is PersistErrorEvent.Reason when the hammer wallet
// could not be charged for a Force Sideshow for a reason other than an empty
// wallet (a database failure). The move was refused and nothing resolved.
const PersistReasonHammerSpend = "hammer_spend"

// HammerWallet is where hammers are kept: the currency a Force Sideshow is
// paid in. Production: db.Hammers. Tests: MemoryHammers.
//
// Hammers are not chips. Nothing here touches chip_ledger or the three
// checkpoints of the money model (CLAUDE.md §5.1) — a seated player's chips
// still move only when they pack, leave or the hand ends — which is why this
// is an interface of its own and not a method on Ledger.
//
// The Table calls SpendHammer from its actor goroutine and blocks on it, BEFORE
// it resolves anything, exactly as it calls the Ledger: a Force Sideshow that
// was not paid for never happens, and no timer or other move can interleave
// with the spend. ctx is the Table's context (cancelled by Destroy).
type HammerWallet interface {
	// SpendHammer takes ForceSideshowCost hammers from req.UserID in one
	// transaction, keyed on req.ActionID.
	//
	// A key already paid for charges nothing and succeeds (Charged=false),
	// reporting the balance as it stands: that is a retry whose first attempt
	// committed but whose answer was lost, and it must get what it paid for
	// rather than pay again. A wallet that cannot cover the cost returns a
	// *GameError with Code no_hammers and spends nothing. Any other failure is
	// an error, and the Table refuses the move with persist_failed.
	SpendHammer(ctx context.Context, req HammerSpend) (HammerSpendResult, error)
}

// HammerSpend is one Force Sideshow's charge.
type HammerSpend struct {
	RoomID string
	HandID string
	UserID string
	// ActionID is the idempotency key: ForceSideshowSpendID(hand, user, the
	// client's actionId). The hand and the user are in it so that a client id
	// reused in another hand, or by another player, is a different spend.
	ActionID string
}

// HammerSpendResult is the wallet after a spend.
type HammerSpendResult struct {
	// Remaining is the player's hammers after this call — the figure the ack
	// hands back so the client can update its count without a round trip.
	Remaining int64
	// Charged is false when ActionID had already been paid for.
	Charged bool
}

// ForceSideshowSpendID is the key a Force Sideshow is charged under:
// "<handId>:force:<userId>:<actionId>". The client's actionId never contains a
// colon (the socket layer and Act both discard one that does), so the key
// cannot be forged to collide with another player's.
func ForceSideshowSpendID(handID, userID, actionID string) string {
	return handID + ":force:" + userID + ":" + actionID
}

// noHammerWallet is the wallet of a table built without one: nobody has any
// hammers, so every Force Sideshow is refused no_hammers rather than handed
// out free.
type noHammerWallet struct{}

func (noHammerWallet) SpendHammer(context.Context, HammerSpend) (HammerSpendResult, error) {
	return HammerSpendResult{}, NewGameError(CodeNoHammers, MsgNoHammers)
}

// MemoryHammers is a HammerWallet kept in memory, for tables built without a
// database. It honours the same contract as db.Hammers: a key is charged once,
// a short wallet spends nothing.
type MemoryHammers struct {
	mu       sync.Mutex
	balances map[string]int64
	paid     map[string]struct{}
	charged  int

	// Fail, if set, is asked before every spend; a non-nil error refuses the
	// spend with nothing charged, as a database that is down would.
	Fail func(req HammerSpend) error
	// LoseAck, if set and true for a request, charges it and THEN reports an
	// error — the commit whose acknowledgement never came back.
	LoseAck func(req HammerSpend) bool
}

// NewMemoryHammers builds a wallet holding the given balances (nil → empty).
func NewMemoryHammers(balances map[string]int64) *MemoryHammers {
	m := &MemoryHammers{balances: map[string]int64{}, paid: map[string]struct{}{}}
	for id, n := range balances {
		m.balances[id] = n
	}
	return m
}

// SpendHammer implements HammerWallet.
func (m *MemoryHammers) SpendHammer(_ context.Context, req HammerSpend) (HammerSpendResult, error) {
	if m.Fail != nil {
		if err := m.Fail(req); err != nil {
			var ge *GameError
			if errors.As(err, &ge) {
				return HammerSpendResult{}, ge
			}
			return HammerSpendResult{}, &GameError{Code: CodePersistFailed, Message: err.Error(), Cause: err}
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, done := m.paid[req.ActionID]; done {
		return HammerSpendResult{Remaining: m.balances[req.UserID], Charged: false}, nil
	}
	if m.balances[req.UserID] < ForceSideshowCost {
		return HammerSpendResult{}, NewGameError(CodeNoHammers, MsgNoHammers)
	}
	m.balances[req.UserID] -= ForceSideshowCost
	m.paid[req.ActionID] = struct{}{}
	m.charged++
	if m.LoseAck != nil && m.LoseAck(req) {
		return HammerSpendResult{}, &GameError{Code: CodePersistFailed, Message: "the acknowledgement was lost"}
	}
	return HammerSpendResult{Remaining: m.balances[req.UserID], Charged: true}, nil
}

// Balance is userID's hammers now.
func (m *MemoryHammers) Balance(userID string) int64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.balances[userID]
}

// Set gives userID exactly n hammers.
func (m *MemoryHammers) Set(userID string, n int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.balances[userID] = n
}

// Charges is how many spends have actually taken a hammer.
func (m *MemoryHammers) Charges() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.charged
}

var (
	_ HammerWallet = (*MemoryHammers)(nil)
	_ HammerWallet = noHammerWallet{}
)
