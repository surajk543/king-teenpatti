package game

// The three pieces of a room that have nothing to do with which game it
// plays, lifted out of Table (POKER_PLAN.md §4) so that a room of another
// family — internal/poker — is built on exactly the same mechanism rather than
// a copy of it: the ACTOR (one goroutine, every mutation a posted closure),
// the LIVE STATE (one snapshot saved to the live store after every closure
// that changed something, and the two-owners fence) and the SETTLER (the
// hand-end settlement retried until it lands, on the actor while the room
// lives and off it after Destroy). Table embeds all three; every line of
// behaviour is the one it had when these were Table's own fields and methods.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// ---------------------------------------------------------------- Actor

// Actor is a room's mailbox (PORT_PLAN.md decision 4): one goroutine (Loop)
// owns the room's state; every mutation and every read of it is a closure
// posted with Run, which blocks until the closure has finished — Node's
// `_run` promise queue made synchronous. Consequences:
//
//   - a Ledger round-trip inside a move can never interleave with a timer:
//     the timer's closure simply queues behind it;
//   - Listener callbacks run ON the actor goroutine and must not post back;
//   - after MarkDestroyed + Cancel, every post returns ErrTableDestroyed;
//   - once fenced (MarkFenced), every post but a forced one is refused too.
//
// Entry points post; internals never do — re-entering Run from the actor
// goroutine deadlocks, exactly as Node's `_run` would wait on itself.
type Actor struct {
	id     string
	ctx    context.Context
	cancel context.CancelFunc
	posts  chan func()
	// after runs at the end of every posted closure, after the closure's own
	// events have been delivered (Table: flushLive).
	after func()

	destroyed atomic.Bool
	// fenced is set when the live store refused a save with live.ErrStale:
	// another process owns this room. Every post but a forced one (Destroy)
	// is refused.
	fenced atomic.Bool
}

// NewActor builds the mailbox for room id; after runs at the end of every
// posted closure (nil for none). The goroutine is started with Loop.
func NewActor(id string, after func()) *Actor {
	a := &Actor{id: id, posts: make(chan func()), after: after}
	a.ctx, a.cancel = context.WithCancel(context.Background())
	return a
}

// Run posts fn to the actor and waits for it to finish. Returns
// ErrTableDestroyed (without running fn) once the room is destroyed — or
// fenced: a room another process owns accepts nothing but Destroy. NEVER call
// from inside a closure already running on the actor (deadlock).
//
// A panic inside fn is recovered on the actor and handed back to the poster
// as an internal_error GameError, so a programming error in one move rejects
// that move (as Node's promise rejection did) instead of taking the whole
// process down with it. The actor keeps running.
func (a *Actor) Run(fn func()) error { return a.Post(fn, false) }

// Post is Run; force lets Destroy through the fence.
func (a *Actor) Post(fn func(), force bool) error {
	if a.destroyed.Load() || (!force && a.fenced.Load()) {
		return ErrTableDestroyed
	}
	done := make(chan struct{})
	var failure error
	job := func() {
		defer close(done)
		if a.after != nil {
			defer a.after()
		}
		defer func() {
			if r := recover(); r != nil {
				failure = &GameError{
					Code:    CodeInternalError,
					Message: fmt.Sprintf("table %s: %v", a.id, r),
					Cause:   &actorPanic{value: r, stack: debug.Stack()},
				}
			}
		}()
		fn()
	}
	// Blocked senders on an unbuffered channel are served first-in first-out,
	// which is exactly Node's `_queue` ordering.
	select {
	case a.posts <- job:
	case <-a.ctx.Done():
		return ErrTableDestroyed
	}
	<-done
	return failure
}

// actorPanic is the Cause of the internal_error a recovered panic becomes.
type actorPanic struct {
	value any
	stack []byte
}

func (p *actorPanic) Error() string { return fmt.Sprintf("panic: %v\n%s", p.value, p.stack) }

// Loop is the actor goroutine: executes posted closures one at a time until
// the room is destroyed, then returns so blocked posters wake with
// ErrTableDestroyed (Cancel cancelled the context).
func (a *Actor) Loop() {
	for job := range a.posts {
		job()
		if a.destroyed.Load() {
			return
		}
	}
}

// Context is cancelled by Cancel (Destroy); it is the context handed to the
// Ledger for every write made while the room lives.
func (a *Actor) Context() context.Context { return a.ctx }

// Destroyed reports whether the room has been destroyed (or suspended).
func (a *Actor) Destroyed() bool { return a.destroyed.Load() }

// Fenced reports that the live store refused a save with live.ErrStale —
// another process owns this room — so every post but Destroy is refused.
func (a *Actor) Fenced() bool { return a.fenced.Load() }

// MarkDestroyed refuses every later post. Cancel wakes the posters already
// waiting; destroy() calls both, in that order, after its own work.
func (a *Actor) MarkDestroyed() { a.destroyed.Store(true) }

// MarkFenced refuses every later unforced post.
func (a *Actor) MarkFenced() { a.fenced.Store(true) }

// Cancel cancels Context, waking every poster blocked in Run.
func (a *Actor) Cancel() { a.cancel() }

// ------------------------------------------------------------ LiveState

// LiveHooks is what a LiveState needs from its room, on the actor.
type LiveHooks struct {
	// Snapshot marshals the room's full document as the live store keeps it,
	// under seq (Table.snapshot; poker.Table.snapshot).
	Snapshot func(seq int64) ([]byte, error)
	// Fenced runs after MarkFenced when a save was refused with
	// live.ErrStale: stop every clock and tell the listener (a *FencedError,
	// which the RoomManager destroys the room on). err is that FencedError.
	Fenced func(err *FencedError)
	// Failed reports one failed store call to the listener as an
	// OnPersistError with reason PersistReasonLive* (nothing was refused).
	Failed func(reason string, err error)
}

// LiveState is the room's side of the live-state store (LIVE_STATE_PLAN.md):
// saving a snapshot after every mutation, mirroring chat, and the fence. Money
// never depends on any of this: a store failure is counted and reported,
// never turned into a refused move. The live store is the ONLY home of game
// state — nothing about a room is ever written to PostgreSQL.
type LiveState struct {
	id     string
	store  live.Store
	ttl    time.Duration
	errors func(op string, err error)
	actor  *Actor
	hooks  LiveHooks

	// liveSeq is the sequence number of the last snapshot saved to the live
	// store (restored from the snapshot; 0 for a room never saved).
	liveSeq atomic.Int64
	// liveDirty marks that observable state changed inside the running
	// closure; Flush saves one snapshot when the closure ends. Actor-owned.
	liveDirty bool
}

// NewLiveState builds the room's live-state side. store nil → nothing is
// saved (unit tests; a room that need not survive a restart); ttl ≤ 0 →
// DefaultLiveTTL.
func NewLiveState(id string, store live.Store, ttl time.Duration, errors func(op string, err error), actor *Actor, hooks LiveHooks) *LiveState {
	if ttl <= 0 {
		ttl = DefaultLiveTTL
	}
	return &LiveState{id: id, store: store, ttl: ttl, errors: errors, actor: actor, hooks: hooks}
}

// Store is the live store, nil when there is none.
func (l *LiveState) Store() live.Store { return l.store }

// LiveSeq is the sequence number of the last snapshot the actor offered to
// the live store (0 before the first; restored rooms continue from the stored
// value). Every attempt takes a number, landed or not, so the store's version
// guard stays monotonic; gaps are harmless.
func (l *LiveState) LiveSeq() int64 { return l.liveSeq.Load() }

// SetSeq continues from a restored snapshot's seq.
func (l *LiveState) SetSeq(seq int64) { l.liveSeq.Store(seq) }

// MarkDirty says the running closure changed observable state. Actor only.
func (l *LiveState) MarkDirty() { l.liveDirty = true }

// Flush runs at the end of every posted closure (Actor.after): if the closure
// changed observable state (liveDirty) the full document is serialised ONCE
// under the next sequence number and saved to the LIVE store. One save per
// closure however many state events were emitted, after the Listener has seen
// them all. Reads never save.
//
// Failure handling: a live-store error is counted (errors), reported
// (Failed, live_save) and the room stays dirty so the next post — any post, a
// read included — tries again under a fresh seq. live.ErrStale fences the
// room (MarkFenced + Fenced). Nothing here ever refuses a move; the move is
// already committed and applied.
func (l *LiveState) Flush() {
	defer func() {
		// The store is somebody else's code running on our actor; a panic
		// in it must not take the room down with it.
		if r := recover(); r != nil {
			l.failed(LiveOpSaveTable, PersistReasonLiveSave, fmt.Errorf("live store panicked: %v\n%s", r, debug.Stack()))
		}
	}()
	if !l.liveDirty {
		return
	}
	if l.store == nil || l.actor.Destroyed() || l.actor.Fenced() {
		l.liveDirty = false
		return
	}
	seq := l.liveSeq.Add(1)
	data, err := l.hooks.Snapshot(seq)
	if err != nil {
		// Will never marshal better; do not loop on it.
		l.liveDirty = false
		l.failed(LiveOpSaveTable, PersistReasonLiveSave, err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), liveCallTimeout)
	err = l.store.SaveTable(ctx, l.id, seq, data, l.ttl)
	cancel()
	switch {
	case err == nil:
		l.liveDirty = false
	case errors.Is(err, live.ErrStale):
		l.liveDirty = false
		l.fence(seq, err)
	default:
		// Stay dirty: the next post retries.
		l.failed(LiveOpSaveTable, PersistReasonLiveSave, err)
	}
}

// fence marks the room as owned by another process (live.ErrStale on a
// save): every later post but Destroy is refused, and the room's Fenced hook
// stops its clocks and reports a *FencedError so the RoomManager destroys it.
// The hand in progress is not settled here and the store's copy is not
// deleted — both are the owner's now (LIVE_STATE_PLAN.md invariant 5).
func (l *LiveState) fence(seq int64, cause error) {
	l.actor.MarkFenced()
	err := &FencedError{RoomID: l.id, Seq: seq, Err: cause}
	if l.errors != nil {
		l.errors(LiveOpSaveTable, err)
	}
	if l.hooks.Fenced != nil {
		l.hooks.Fenced(err)
	}
}

// failed counts and reports one failed live-store call.
func (l *LiveState) failed(op, reason string, err error) {
	if l.errors != nil {
		l.errors(op, err)
	}
	if l.hooks.Failed != nil {
		l.hooks.Failed(reason, err)
	}
}

// AppendChat mirrors one chat line (player or system) to the store, capped at
// the room's ChatMaxHistory. Actor only.
func (l *LiveState) AppendChat(msg *ChatMessage, maxHistory int) {
	if l.store == nil || msg == nil || l.actor.Destroyed() || l.actor.Fenced() {
		return
	}
	data, err := json.Marshal(msg)
	if err != nil {
		l.failed(LiveOpAppendChat, PersistReasonLiveChat, err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), liveCallTimeout)
	err = l.store.AppendChat(ctx, l.id, data, maxHistory)
	cancel()
	if err != nil {
		l.failed(LiveOpAppendChat, PersistReasonLiveChat, err)
	}
}

// Delete forgets the room in the store (destroy): snapshot and chat.
func (l *LiveState) Delete() {
	if l.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), liveCallTimeout)
	defer cancel()
	if err := l.store.DeleteTable(ctx, l.id); err != nil {
		l.failed(LiveOpDeleteTable, PersistReasonLiveDelete, err)
	}
	if err := l.store.DeleteChat(ctx, l.id); err != nil {
		l.failed(LiveOpDeleteChat, PersistReasonLiveDelete, err)
	}
}

// -------------------------------------------------------------- Settler

// settleMaxAttempts / settleRetryMaxDelay: retrySettle gives up after 10
// attempts; the back-off is min(30s, NextHandDelay × attempt).
const settleMaxAttempts = 10
const settleRetryMaxDelay = 30 * time.Second

// SettlerHooks is what a Settler needs from its room, each called ON the
// actor while the room lives (never after Destroy: a detached chain reports
// to WaitSettlements instead).
type SettlerHooks struct {
	// Landed: a retry landed (or was found already landed — duplicate_action);
	// the room adopts the returned balances onto seats that are not mid-hand
	// and emits state. Version has already been bumped.
	Landed func(req SettleRequest, balances SettleResult)
	// RetryFailed: attempt n failed and the next is armed (OnPersistError
	// settle_retry).
	RetryFailed func(req SettleRequest, attempt int, err error)
	// Abandoned: the attempt cap was reached (OnError).
	Abandoned func(req SettleRequest, err error)
}

// Settler is the hand-end settlement's retry chain (Table.retrySettle,
// settleDetached, WaitSettlements — DECISIONS.md §2): a refused Settle is
// re-sent unchanged with a back-off until it lands, on the actor while the
// room lives and OFF it once the room is destroyed or suspended (a pot the
// database has not accepted yet is owed whatever happens to the room). The
// per-player action ids are UNIQUE, so a replay of a write whose
// acknowledgement was lost comes back duplicate_action, which counts as
// landed.
type Settler struct {
	ledger    Ledger
	clock     Clock
	actor     *Actor
	baseDelay time.Duration
	// version rises by one per landed write (Room.Version).
	version *atomic.Int64
	// owed is TableOptions.SettlementOwed (nil → nobody to tell).
	owed  func(req SettleRequest, owed bool)
	hooks SettlerHooks

	// retryTimers are the armed settle back-offs (timer + the write it owes),
	// so Detach can stop them and hand the writes to the detached chain rather
	// than lose them (Node let them fire into `_destroyed` checks and the pot
	// was never banked). Actor-owned.
	retryTimers map[uint64]*settleRetry
	retryGen    uint64
	// detachedMu guards the bookkeeping of settlement chains still being
	// retried after Destroy: detachedOpen is how many are running,
	// detachedDone is broadcast when one finishes, landed/abandoned record
	// the outcomes for WaitSettlements.
	detachedMu   sync.Mutex
	detachedDone *sync.Cond
	detachedOpen int
	landed       []string // hand ids settled after Destroy
	abandoned    []string // hand ids given up after settleMaxAttempts
}

// settleRetry is one armed settlement back-off: the timer and the exact
// write it will attempt when it fires. claimed (under detachedMu) records
// that the retry has been counted as a detached chain — by Detach or by the
// timer's own callback, whichever reaches it first when the room goes down
// with the write still owed — so it is counted exactly once.
type settleRetry struct {
	timer   Timer
	req     SettleRequest
	attempt int
	claimed bool
}

// NewSettler builds the chain for a room. baseDelay is NextHandDelay (the
// back-off base); version the room's write counter; owed the manager's hook.
func NewSettler(ledger Ledger, clock Clock, actor *Actor, baseDelay time.Duration, version *atomic.Int64, owed func(req SettleRequest, owed bool), hooks SettlerHooks) *Settler {
	s := &Settler{
		ledger: ledger, clock: clock, actor: actor, baseDelay: baseDelay, version: version, owed: owed, hooks: hooks,
		retryTimers: map[uint64]*settleRetry{},
	}
	s.detachedDone = sync.NewCond(&s.detachedMu)
	return s
}

// Owe reports a refused settlement to the manager: owed as its retries begin
// (the room's hand end), !owed when they end. Every chain is reported once
// each way, because it begins in exactly one place and ends at exactly one of
// three: a retry that landed on the actor, the attempt cap reached on the
// actor, or finishDetached for a chain that outlived its room. A chain the
// timer's callback and Detach both reach is still one chain (claimDetached).
func (s *Settler) Owe(req SettleRequest, owed bool) {
	if s.owed != nil {
		s.owed(req, owed)
	}
}

// Retry (_retrySettle): if destroyed → continue off the actor. attempt > 10
// → Abandoned ("settlement of hand <id> failed after 10 attempts"). delay =
// min(30s, baseDelay × attempt). AfterFunc(delay) → Run: Settle again; on
// success version++ and Landed; on error RetryFailed and Retry(attempt+1).
// Unlike Node, the retry body runs ON the actor (Node ran it outside the queue
// and mutated seats concurrently — a bug the port does not copy).
//
// DECISIONS.md §2: a retry refused with duplicate_action means the write
// already landed (the per-player settle action ids are UNIQUE), so it counts
// as success and the chain stops.
//
// A retry the room no longer owns — Destroy ran first, or ran while the
// timer's callback was already on its way to the actor — is not dropped: the
// losers' stakes are already banked and the winner is still owed the pot, so
// the write continues off the actor in settleDetached (Node's `if
// (this._destroyed) return` silently orphaned the pot).
func (s *Settler) Retry(req SettleRequest, attempt int) {
	if s.actor.Destroyed() {
		s.settleDetached(req, attempt)
		return
	}
	if attempt > settleMaxAttempts {
		// Given up: nothing will write this hand now, so the wallets as they
		// stand are the last word and nobody need wait for them any longer.
		s.Owe(req, false)
		if s.hooks.Abandoned != nil {
			s.hooks.Abandoned(req, fmt.Errorf("settlement of hand %s failed after %d attempts", req.HandID, settleMaxAttempts))
		}
		return
	}

	s.retryGen++
	gen := s.retryGen
	entry := &settleRetry{req: req, attempt: attempt}
	s.retryTimers[gen] = entry
	entry.timer = s.clock.AfterFunc(s.delay(attempt), func() {
		err := s.actor.Run(func() {
			delete(s.retryTimers, gen)
			balances, err := s.ledger.Settle(s.actor.Context(), req)
			if err != nil && CodeOf(err, "") != CodeDuplicateAction {
				if s.hooks.RetryFailed != nil {
					s.hooks.RetryFailed(req, attempt, err)
				}
				s.Retry(req, attempt+1)
				return
			}
			s.Owe(req, false) // landed: first, so nothing below can skip it
			s.version.Add(1)
			if s.hooks.Landed != nil {
				s.hooks.Landed(req, balances)
			}
		})
		if errors.Is(err, ErrTableDestroyed) {
			// The timer fired in the same instant destroy() was tearing the
			// room down: Stop() reported "already fired" to Detach, so the
			// chain is ours to run. Whichever of us got to the entry first
			// counted it (claimDetached); it is counted once either way.
			s.claimDetached(entry)
			s.settleDetachedFrom(req, attempt)
		}
	})
}

// delay is min(30s, baseDelay × attempt) — Node's back-off.
func (s *Settler) delay(attempt int) time.Duration {
	d := s.baseDelay * time.Duration(attempt)
	if d > settleRetryMaxDelay || d < 0 {
		d = settleRetryMaxDelay
	}
	return d
}

// claimDetached counts a retry as an open detached chain, once.
func (s *Settler) claimDetached(entry *settleRetry) {
	s.detachedMu.Lock()
	if !entry.claimed {
		entry.claimed = true
		s.detachedOpen++
	}
	s.detachedMu.Unlock()
}

// Detach is destroy's and suspend's treatment of the armed retries: a
// settlement the database has not accepted yet is still owed whatever happens
// to the room, so every stopped retry continues off the actor. A timer that
// had already fired is left to its own callback, which finds the room
// destroyed and does the same. Counted here, before Destroy returns, so a
// WaitSettlements that starts the moment it does cannot miss the chain —
// even one whose timer had already fired and whose callback is on its way to
// Run to be told ErrTableDestroyed; that callback then runs the chain. Actor
// only.
func (s *Settler) Detach() {
	for gen, entry := range s.retryTimers {
		delete(s.retryTimers, gen)
		stopped := entry.timer.Stop()
		s.claimDetached(entry)
		if stopped {
			s.settleDetachedFrom(entry.req, entry.attempt)
		}
	}
}

// settleDetached keeps retrying a settlement whose room has been destroyed
// (Go addition; see Retry). It runs entirely off the actor: there are no
// seats to correct, no state to broadcast and — Destroy's contract — no
// Listener event is ever delivered again; the outcome is reported to whoever
// calls WaitSettlements instead. Only the idempotent write itself remains,
// with the same back-off, attempt numbering and cap as Retry, and a context
// that outlives the room's. A landed write still counts in Version.
func (s *Settler) settleDetached(req SettleRequest, attempt int) {
	s.detachedMu.Lock()
	s.detachedOpen++
	s.detachedMu.Unlock()
	s.settleDetachedFrom(req, attempt)
}

// settleDetachedFrom is one link of a settleDetached chain; the chain was
// counted in detachedOpen once, by whoever started it, and is released here
// when it lands or is abandoned.
func (s *Settler) settleDetachedFrom(req SettleRequest, attempt int) {
	if attempt > settleMaxAttempts {
		s.finishDetached(req, false)
		return
	}
	s.clock.AfterFunc(s.delay(attempt), func() {
		_, err := s.ledger.Settle(context.WithoutCancel(s.actor.Context()), req)
		if err != nil && CodeOf(err, "") != CodeDuplicateAction {
			s.settleDetachedFrom(req, attempt+1)
			return
		}
		s.version.Add(1)
		s.finishDetached(req, true)
	})
}

// finishDetached ends a chain: the settlement stops being owed, its outcome
// is recorded, and WaitSettlements wakes. The owed mark goes first, so whoever
// has seen WaitSettlements return also finds the wallets final.
func (s *Settler) finishDetached(req SettleRequest, landed bool) {
	s.Owe(req, false)
	s.detachedMu.Lock()
	if landed {
		s.landed = append(s.landed, req.HandID)
	} else {
		s.abandoned = append(s.abandoned, req.HandID)
	}
	s.detachedOpen--
	s.detachedDone.Broadcast()
	s.detachedMu.Unlock()
}

// PendingSettlements reports how many settlements are still being retried
// off the actor after Destroy (0 before Destroy, and 0 once every one has
// landed or been abandoned).
func (s *Settler) PendingSettlements() int {
	s.detachedMu.Lock()
	defer s.detachedMu.Unlock()
	return s.detachedOpen
}

// WaitSettlements blocks until every settlement still being retried after
// Destroy has landed or been abandoned, or ctx expires (ctx.Err()). It then
// reports the hands whose settlement was abandoned after settleMaxAttempts as
// an error naming them, or nil when everything landed. Before Destroy it
// returns at once. RoomManager.Shutdown calls it so a process does not exit
// with a winner's pot still unbanked while the database is merely slow;
// RoomManager.destroyTable logs its result.
func (s *Settler) WaitSettlements(ctx context.Context) error {
	done := make(chan struct{})
	go func() {
		s.detachedMu.Lock()
		for s.detachedOpen > 0 {
			s.detachedDone.Wait()
		}
		s.detachedMu.Unlock()
		close(done)
	}()
	select {
	case <-done:
	case <-ctx.Done():
		return ctx.Err()
	}
	s.detachedMu.Lock()
	defer s.detachedMu.Unlock()
	if len(s.abandoned) == 0 {
		return nil
	}
	return fmt.Errorf("settlement of hand(s) %s abandoned after %d attempts each", strings.Join(s.abandoned, ", "), settleMaxAttempts)
}

// SettlementsLanded returns the hand ids whose settlement landed only after
// Destroy (for logs and tests).
func (s *Settler) SettlementsLanded() []string {
	s.detachedMu.Lock()
	defer s.detachedMu.Unlock()
	return append([]string(nil), s.landed...)
}
