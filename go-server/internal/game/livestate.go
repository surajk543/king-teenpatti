package game

// The Table's side of the live-state store (LIVE_STATE_PLAN.md): saving a
// Snapshot after every mutation, mirroring chat, the two-owners fence, and
// RestoreTable — rebuilding a table from a stored Snapshot and re-arming its
// clocks. Money never depends on any of this: a live-store failure is
// counted and reported, never turned into a refused move.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"runtime/debug"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/live"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// DefaultLiveTTL is the snapshot expiry when TableOptions.LiveTTL is 0
// (LIVE_STATE_TTL_MS default 86400000).
const DefaultLiveTTL = 24 * time.Hour

// liveCallTimeout bounds one live-store round trip from the game package.
// The store has its own per-call timeout (live.Options.Timeout, 500 ms); this
// is the belt to that brace so an actor can never hang on the store.
const liveCallTimeout = 2 * time.Second

// Live-store operation names, as handed to TableOptions.LiveErrors /
// MetricsHooks.ObserveLiveError (the op label of
// game_live_store_errors_total). Kept identical to the live.Store method
// names in snake_case so they line up with the store's own counting.
const (
	LiveOpSaveTable     = "save_table"
	LiveOpLoadTable     = "load_table"
	LiveOpDeleteTable   = "delete_table"
	LiveOpListTables    = "list_tables"
	LiveOpAppendChat    = "append_chat"
	LiveOpLoadChat      = "load_chat"
	LiveOpDeleteChat    = "delete_chat"
	LiveOpSetSeated     = "set_seated"
	LiveOpClearSeated   = "clear_seated"
	LiveOpListSeats     = "list_seats"
	LiveOpPublishTable  = "publish_table"
	LiveOpRetireTable   = "retire_table"
	LiveOpListSummaries = "list_summaries"
)

// PersistErrorEvent.Reason values for live-store failures. They travel the
// same OnPersistError path as a refused ledger write so the socket layer's
// existing plumbing sees them, but nothing was refused: the move stood, only
// the store's copy is behind. RoomManager logs them as `live store write
// failed`.
const (
	PersistReasonLiveSave   = "live_save"
	PersistReasonLiveChat   = "live_chat"
	PersistReasonLiveDelete = "live_delete"
)

// FencedError is the error OnError carries when the live store refused a
// snapshot with live.ErrStale: another process has saved a newer sequence
// for this table, so this process no longer owns it. It unwraps to
// live.ErrStale. RoomManager's tableHooks recognise it and destroy the table.
type FencedError struct {
	RoomID string
	Seq    int64
	Err    error
}

func (e *FencedError) Error() string {
	return fmt.Sprintf("table %s is fenced: the live store refused snapshot seq %d, another process owns this table (%v)", e.RoomID, e.Seq, e.Err)
}

// Unwrap exposes live.ErrStale to errors.Is.
func (e *FencedError) Unwrap() error { return e.Err }

// ---------------------------------------------------------------- saving

// markDurable asks for the snapshot of the CURRENT closure to reach the
// durable backstop (PostgreSQL game_states) as well as the live store. It is
// called from exactly two places, both in table.go and both commented there:
//
//  1. startHand, once the boots are collected and the cards are dealt — the
//     hand's opening state;
//  2. endHand, once settlement is done and the hand is gone — the table at
//     rest.
//
// Nowhere else. Writing a durable snapshot of every table every second cost
// the money transactions the disk they needed (measured on production, 9 Sep
// 2026: committed transactions/s fell from 1,258 to 654 at 7,000 players and
// the usable ceiling halved), and PostgreSQL is only ever read back when
// BOTH Redis and the process are gone. Between the boundaries the ledger is
// the record of what has been staked, and ReconcileWithLedger rebuilds the
// difference. A table that never deals therefore writes nothing durable at
// all: nothing is at stake and its players simply re-join.
//
// It sets liveDirty too, so the durable copy is always a snapshot the live
// store was offered under the same seq (the seq is what both version guards
// compare).
func (t *Table) markDurable() {
	t.liveDirty = true
	t.durableDirty = true
}

// flushLive runs at the end of every posted closure (run): if the closure
// changed observable state (liveDirty, set by emitState and the few
// mutations that do not emit state) the full Snapshot is serialised ONCE
// under the next sequence number and saved to the LIVE store. The same
// bytes, under the same seq, also go to the durable sink (MarkDirty) — but
// only when the closure asked for it with markDurable, which is the two hand
// boundaries and nothing else. One save per closure however many state
// events were emitted, after the Listener has seen them all.
//
// Failure handling: a live-store error is counted (LiveErrors), reported
// (OnPersistError live_save) and the table stays dirty so the next post —
// any post, a read included — tries again under a fresh seq; a durable
// snapshot due in that closure still reaches the sink, which is exactly the
// case it exists for. live.ErrStale fences the table (see fence) and the
// sink gets nothing: the owner writes that row. Nothing here ever refuses a
// move; the move is already committed and applied.
func (t *Table) flushLive() {
	defer func() {
		// The stores are somebody else's code running on our actor; a panic
		// in them must not take the table down with it.
		if r := recover(); r != nil {
			t.liveFailed(LiveOpSaveTable, PersistReasonLiveSave, fmt.Errorf("live store panicked: %v\n%s", r, debug.Stack()))
		}
	}()
	if !t.liveDirty && !t.durableDirty {
		return
	}
	if t.destroyed.Load() || t.fenced.Load() {
		t.liveDirty, t.durableDirty = false, false
		return
	}
	if t.live == nil && (t.snapshots == nil || !t.durableDirty) {
		// Nowhere to put it: with no live store the snapshot is only ever
		// taken for a hand boundary, so an ordinary move costs nothing.
		t.liveDirty = false
		return
	}
	seq := t.liveSeq.Add(1)
	snap := t.snapshot()
	snap.Seq = seq
	data, err := json.Marshal(snap)
	if err != nil {
		// Will never marshal better; do not loop on it.
		t.liveDirty, t.durableDirty = false, false
		t.liveFailed(LiveOpSaveTable, PersistReasonLiveSave, err)
		return
	}
	handID := ""
	if snap.Hand != nil {
		handID = snap.Hand.ID
	}
	if t.live != nil {
		ctx, cancel := context.WithTimeout(context.Background(), liveCallTimeout)
		err = t.live.SaveTable(ctx, t.id, seq, data, t.liveTTL)
		cancel()
		switch {
		case err == nil:
			t.liveDirty = false
		case errors.Is(err, live.ErrStale):
			t.liveDirty, t.durableDirty = false, false
			t.fence(seq, err)
			return
		default:
			// Stay dirty: the next post retries.
			t.liveFailed(LiveOpSaveTable, PersistReasonLiveSave, err)
		}
	} else {
		t.liveDirty = false
	}
	if t.durableDirty && t.snapshots != nil {
		t.snapshots.MarkDirty(t.id, seq, handID, data)
	}
	t.durableDirty = false
}

// fence marks the table as owned by another process (live.ErrStale on a
// save): every clock is stopped, every later post but Destroy is refused
// with ErrTableDestroyed, and OnError carries a *FencedError so the
// RoomManager destroys the table. The hand in progress is not settled here
// and the store's copy is not deleted — both are the owner's now
// (LIVE_STATE_PLAN.md invariant 5).
func (t *Table) fence(seq int64, cause error) {
	t.fenced.Store(true)
	t.clearTurnTimer()
	t.clearStartTimer()
	if t.hand != nil && t.hand.sideshow != nil && t.hand.sideshow.timer != nil {
		t.hand.sideshow.timer.Stop()
		t.hand.sideshow.timer = nil
	}
	err := &FencedError{RoomID: t.id, Seq: seq, Err: cause}
	if t.liveErrors != nil {
		t.liveErrors(LiveOpSaveTable, err)
	}
	t.listener.OnError(t.view, err)
}

// liveFailed counts and reports one failed live-store call.
func (t *Table) liveFailed(op, reason string, err error) {
	if t.liveErrors != nil {
		t.liveErrors(op, err)
	}
	t.listener.OnPersistError(t.view, PersistErrorEvent{Reason: reason, Err: err})
}

// liveAppendChat mirrors one chat line (player or system) to the store,
// capped at the room's ChatMaxHistory. Actor only.
func (t *Table) liveAppendChat(msg *ChatMessage) {
	if t.live == nil || msg == nil || t.destroyed.Load() || t.fenced.Load() {
		return
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.liveFailed(LiveOpAppendChat, PersistReasonLiveChat, err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), liveCallTimeout)
	err = t.live.AppendChat(ctx, t.id, data, t.chat.MaxHistory)
	cancel()
	if err != nil {
		t.liveFailed(LiveOpAppendChat, PersistReasonLiveChat, err)
	}
}

// liveDelete forgets the table in the store (destroy): snapshot and chat.
func (t *Table) liveDelete() {
	if t.live == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), liveCallTimeout)
	defer cancel()
	if err := t.live.DeleteTable(ctx, t.id); err != nil {
		t.liveFailed(LiveOpDeleteTable, PersistReasonLiveDelete, err)
	}
	if err := t.live.DeleteChat(ctx, t.id); err != nil {
		t.liveFailed(LiveOpDeleteChat, PersistReasonLiveDelete, err)
	}
}

// Suspend stops the table for a graceful restart WITHOUT ending its hand or
// forgetting it in the live store: a final snapshot is saved, every clock is
// stopped, and from then on every post returns ErrTableDestroyed. The next
// process restores the table from that snapshot and re-arms the clocks
// (RestoreTable). Settle retries still owed continue off the actor exactly
// as after Destroy (WaitSettlements). Nothing is emitted. A table with no
// live store (or one already fenced) is simply destroyed — there would be
// nothing to come back from.
func (t *Table) Suspend() error {
	return t.post(func() { t.suspend() }, true)
}

// suspend is Suspend's actor body.
func (t *Table) suspend() {
	if t.live == nil || t.fenced.Load() {
		t.destroy()
		return
	}
	t.clearTurnTimer()
	t.clearStartTimer()
	if t.hand != nil && t.hand.sideshow != nil && t.hand.sideshow.timer != nil {
		t.hand.sideshow.timer.Stop()
		t.hand.sideshow.timer = nil
	}
	for gen, entry := range t.retryTimers {
		delete(t.retryTimers, gen)
		stopped := entry.timer.Stop()
		t.claimDetached(entry)
		if stopped {
			t.settleDetachedFrom(entry.req, entry.attempt)
		}
	}
	// The last word on this table before the process goes: saved now, while
	// the table is still ours (run's flushLive would skip a destroyed table).
	t.liveDirty = true
	t.flushLive()
	t.destroyed.Store(true)
	t.cancel()
}

// restoreChat replaces the room log with the lines loaded from the store
// (oldest first), capped at MaxHistory.
func (c *RoomChat) restore(history []ChatMessage) {
	if excess := len(history) - c.MaxHistory; excess > 0 && c.MaxHistory > 0 {
		history = history[excess:]
	}
	c.messages = make([]ChatMessage, len(history))
	copy(c.messages, history)
}

// restoreChat posts the loaded chat history onto the actor (RoomManager.Restore).
func (t *Table) restoreChat(history []ChatMessage) error {
	return t.run(func() { t.chat.restore(history) })
}

// --------------------------------------------------------------- restore

// RestoreTable rebuilds a table from a Snapshot the live store returned and
// re-arms its clocks; the result behaves exactly like a table that was never
// interrupted. The snapshot is authoritative for everything it carries —
// opts.ID, Code, Config and IsPrivate are ignored; Ledger, Clock, Listener,
// Live, LiveTTL and LiveErrors are taken from opts. Every seat comes back
// connected=false with no socket (the socket layer holds the seats for the
// reconnect grace period). Restore ⇄ Snapshot is lossless: Snapshot() of the
// restored table equals the input (TestSnapshotRoundTripIsLossless).
//
// Clocks are re-armed against opts.Clock.Now(), on the actor, before
// RestoreTable returns:
//
//   - a live hand with a pending sideshow: expiresAt in the past → it lapses
//     (resolveSideshow timeout; the asker's clock restarts full), otherwise
//     the sideshow timer is armed for what is left;
//   - a live hand on turn: turnDeadline in the past → the timeout fires now
//     through onTurnTimeout (missedTurns++, pack, kick at MaxMissedTurns —
//     the ordinary semantics), otherwise the turn timer is armed for what is
//     left under a fresh turnToken; the deadline itself is unchanged, so
//     clients see the same clock;
//   - starting: startsAt in the past → startHand now (boots go through the
//     Ledger as for any deal), otherwise the countdown is armed for what is
//     left;
//   - waiting: maybeStart — a no-op unless enough funded seats are present,
//     which at rest can only mean a boot refusal whose retry timer died with
//     the process (table.js _startRefused);
//   - seats marked kickPending (a kick whose removal was in flight) are
//     kicked again so the RoomManager's hook can finish the job.
//
// With a live store the restored table saves one snapshot straight away
// (seq + 1), which is how a process that is still writing this table learns
// it has lost it (ErrStale → fenced).
//
// A snapshot that cannot be rebuilt (missing config, a seat out of range, a
// card code that is not a card, a hand naming a seat that is empty…) is
// refused with a descriptive error and nothing is constructed.
func RestoreTable(snap *Snapshot, opts TableOptions) (*Table, error) {
	t, err := restoreTable(snap, opts)
	if err != nil {
		return nil, err
	}
	if err := t.resume(); err != nil {
		return nil, err
	}
	return t, nil
}

// restoreTable is RestoreTable's first phase: validate, construct, fill the
// actor-owned state in and start the loop — without arming a clock. The
// RoomManager registers the table (index, seats) between this and resume, so
// a kick or a timeout that fires on resume finds the player indexed.
func restoreTable(snap *Snapshot, opts TableOptions) (*Table, error) {
	if err := validateSnapshot(snap); err != nil {
		return nil, fmt.Errorf("restore table: %w", err)
	}
	cfg := tableConfigFrom(snap.Config)
	if cfg.Category == "" {
		cfg.Category = snap.Category
	}
	opts.ID = snap.RoomID
	opts.Code = snap.Code
	opts.Config = cfg
	opts.IsPrivate = snap.IsPrivate
	t := newTableCore(opts)
	t.createdAt = FromMillis(snap.CreatedAt)
	t.handNo = snap.HandNo
	t.dealerSeat = snap.DealerSeat
	t.version.Store(snap.Version)
	t.liveSeq.Store(snap.Seq)

	for index, ss := range snap.Seats {
		if ss == nil {
			continue
		}
		s := &seat{
			seatIndex:             index,
			userID:                ss.UserID,
			displayName:           ss.DisplayName,
			chips:                 ss.Chips,
			connected:             false,
			status:                ss.Status,
			cards:                 ParseCards(ss.Cards),
			isBlind:               ss.IsBlind,
			blindMoves:            ss.BlindMoves,
			missedTurns:           ss.MissedTurns,
			sideshowAskedThisTurn: ss.SideshowAskedThisTurn,
			lastBet:               ss.LastBet,
			contributed:           ss.Contributed,
			joinedAt:              FromMillis(ss.JoinedAt),
			kickPending:           ss.KickPending,
		}
		if ss.AvatarURL != nil {
			s.avatarURL = StrPtr(*ss.AvatarURL)
		}
		if ss.LastAction != nil {
			s.lastAction = ActionPtr(*ss.LastAction)
		}
		t.seats[index] = s
	}
	t.refreshPlayerCount()

	if sh := snap.Hand; sh != nil {
		h := &hand{
			id:            sh.ID,
			handNo:        sh.HandNo,
			startedAt:     FromMillis(sh.StartedAt),
			pot:           sh.Pot,
			stake:         sh.Stake,
			round:         sh.Round,
			packedUserIDs: make(map[string]struct{}, len(sh.PackedUserIDs)),
			turnSeat:      sh.TurnSeat,
			startSeat:     sh.StartSeat,
			seatOrder:     append([]int{}, sh.SeatOrder...),
			contributions: make(map[string]*contribution, len(sh.Contributions)),
			contribOrder:  make([]string, 0, len(sh.Contributions)),
		}
		for _, id := range sh.PackedUserIDs {
			h.packedUserIDs[id] = struct{}{}
		}
		for _, c := range sh.Contributions {
			h.contributions[c.UserID] = &contribution{
				userID:      c.UserID,
				displayName: c.DisplayName,
				seatIndex:   c.SeatIndex,
				contributed: c.Contributed,
				status:      c.Status,
				sawCards:    c.SawCards,
				cards:       ParseCards(c.Cards),
				didChaal:    c.DidChaal,
				leftMidHand: c.LeftMidHand,
				persisted:   c.Persisted,
			}
			h.contribOrder = append(h.contribOrder, c.UserID)
		}
		if sh.ShowRequestedBy != nil {
			h.showRequestedBy = StrPtr(*sh.ShowRequestedBy)
		}
		if sh.LastDeparture != nil {
			h.lastDeparture = StrPtr(*sh.LastDeparture)
		}
		if sh.TurnDeadline != nil {
			h.turnDeadline = FromMillis(*sh.TurnDeadline)
		}
		if p := sh.Sideshow; p != nil {
			h.sideshow = &pendingSideshow{
				fromUserID: p.FromUserID,
				fromSeat:   p.FromSeat,
				toUserID:   p.ToUserID,
				toSeat:     p.ToSeat,
				expiresAt:  FromMillis(p.ExpiresAt),
			}
		}
		t.setHand(h)
		t.setState(TableBetting)
	} else if snap.State == TableStarting {
		t.setState(TableStarting)
		startsAt := t.clock.Now()
		if snap.StartsAt != nil {
			startsAt = FromMillis(*snap.StartsAt)
		}
		t.startsAt = &startsAt
	} else {
		t.setState(TableWaiting)
	}

	go t.loop()
	return t, nil
}

// resume is RestoreTable's second phase: re-arm every clock against the
// current time, on the actor (see RestoreTable for the rules).
func (t *Table) resume() error {
	return t.run(func() { t.resumeTimers() })
}

// resumeTimers is resume's actor body.
func (t *Table) resumeTimers() {
	// Claim the table in the store straight away (seq + 1), whatever else
	// happens below.
	t.liveDirty = true
	now := t.clock.Now()

	switch {
	case t.hand != nil:
		h := t.hand
		if p := h.sideshow; p != nil {
			// The turn clock is stopped while a request stands; the answer
			// (or the lapse) restarts it through resolveSideshow.
			if t.cfg.SideshowTimeout > 0 && !p.expiresAt.After(now) {
				t.resolveSideshow(false, SideshowTimeout)
			} else if t.cfg.SideshowTimeout > 0 {
				t.armSideshowTimer(p, p.expiresAt.Sub(now))
			}
		} else if h.turnSeat >= 0 && h.turnSeat < len(t.seats) && t.seats[h.turnSeat] != nil {
			token := util.UUID()
			h.turnToken = token
			if h.turnDeadline.IsZero() {
				h.turnDeadline = now.Add(t.cfg.TurnTimeout)
			}
			if !h.turnDeadline.After(now) {
				t.onTurnTimeout(h.turnSeat, token)
			} else {
				seatIndex := h.turnSeat
				t.clearTurnTimer()
				t.turnTimer = t.clock.AfterFunc(h.turnDeadline.Sub(now), func() {
					_ = t.run(func() { t.onTurnTimeout(seatIndex, token) })
				})
			}
		} else {
			// No turn recorded (never the case for a hand startHand dealt):
			// open play to the dealer's left as startHand would have.
			first := t.nextActiveSeat(t.dealerSeat)
			if first >= 0 {
				if h.startSeat < 0 {
					h.startSeat = first
				}
				t.setTurn(first, true)
				t.emitState()
			} else {
				t.resolveIfOnlyOneLeft()
			}
		}
	case t.State() == TableStarting:
		if t.startsAt == nil || !t.startsAt.After(now) {
			t.startHand()
		} else {
			t.armStartTimerAfter(t.startsAt.Sub(now), func() { t.startHand() })
		}
	default:
		t.maybeStart()
	}

	// A kick announced before the process went down was never carried out
	// (its removal ran in a RoomManager goroutine). Announce it again.
	for _, s := range t.occupiedSeats() {
		if s.kickPending {
			t.kick(s, KickReasonInsufficientChips, KickMessageInsufficientChips)
		}
	}
}

// armSideshowTimer arms the expiry of a pending request for d (requestSideshow
// uses the full SideshowTimeout; a restored request has less left).
func (t *Table) armSideshowTimer(pending *pendingSideshow, d time.Duration) {
	if d < 0 {
		d = 0
	}
	pending.timer = t.clock.AfterFunc(d, func() {
		_ = t.run(func() {
			// A timer stopped a moment too late must not expire a newer
			// request that has since been opened.
			if t.hand == nil || t.hand.sideshow != pending {
				return
			}
			t.resolveSideshow(false, SideshowTimeout)
		})
	})
}

// validateSnapshot refuses a snapshot RestoreTable could not turn into a
// consistent table. It is deliberately strict about references (seat
// indices, user ids, card codes) and lenient about everything the table
// can derive.
func validateSnapshot(snap *Snapshot) error {
	if snap == nil {
		return errors.New("nil snapshot")
	}
	if snap.RoomID == "" {
		return errors.New("snapshot has no roomId")
	}
	cfg := snap.Config
	if cfg.MaxPlayers <= 0 {
		return fmt.Errorf("snapshot %s has no config (maxPlayers %d)", snap.RoomID, cfg.MaxPlayers)
	}
	if cfg.BootAmount <= 0 {
		return fmt.Errorf("snapshot %s has bootAmount %d", snap.RoomID, cfg.BootAmount)
	}
	if len(snap.Seats) > cfg.MaxPlayers {
		return fmt.Errorf("snapshot %s has %d seats for maxPlayers %d", snap.RoomID, len(snap.Seats), cfg.MaxPlayers)
	}
	switch snap.State {
	case TableWaiting, TableStarting, TableBetting, TableShowdown:
	default:
		return fmt.Errorf("snapshot %s has state %q", snap.RoomID, snap.State)
	}
	users := make(map[string]int, len(snap.Seats))
	for index, s := range snap.Seats {
		if s == nil {
			continue
		}
		if s.SeatIndex != index {
			return fmt.Errorf("snapshot %s: seat at position %d says seatIndex %d", snap.RoomID, index, s.SeatIndex)
		}
		if s.UserID == "" {
			return fmt.Errorf("snapshot %s: seat %d has no userId", snap.RoomID, index)
		}
		if _, dup := users[s.UserID]; dup {
			return fmt.Errorf("snapshot %s: user %s holds two seats", snap.RoomID, s.UserID)
		}
		users[s.UserID] = index
		if !validSeatState(s.Status) {
			return fmt.Errorf("snapshot %s: seat %d has status %q", snap.RoomID, index, s.Status)
		}
		if err := validCardCodes(s.Cards); err != nil {
			return fmt.Errorf("snapshot %s: seat %d: %w", snap.RoomID, index, err)
		}
	}
	h := snap.Hand
	if h == nil {
		return nil
	}
	if h.ID == "" {
		return fmt.Errorf("snapshot %s: hand has no id", snap.RoomID)
	}
	seatOK := func(index int) bool {
		return index >= 0 && index < len(snap.Seats) && snap.Seats[index] != nil
	}
	if h.TurnSeat != -1 && !seatOK(h.TurnSeat) {
		return fmt.Errorf("snapshot %s: turnSeat %d is not an occupied seat", snap.RoomID, h.TurnSeat)
	}
	if h.StartSeat != -1 && (h.StartSeat < 0 || h.StartSeat >= cfg.MaxPlayers) {
		return fmt.Errorf("snapshot %s: startSeat %d out of range", snap.RoomID, h.StartSeat)
	}
	if snap.DealerSeat < -1 || snap.DealerSeat >= cfg.MaxPlayers {
		return fmt.Errorf("snapshot %s: dealerSeat %d out of range", snap.RoomID, snap.DealerSeat)
	}
	for _, index := range h.SeatOrder {
		if index < 0 || index >= cfg.MaxPlayers {
			return fmt.Errorf("snapshot %s: seatOrder names seat %d", snap.RoomID, index)
		}
	}
	seen := make(map[string]bool, len(h.Contributions))
	for _, c := range h.Contributions {
		if c.UserID == "" {
			return fmt.Errorf("snapshot %s: a contribution has no userId", snap.RoomID)
		}
		if seen[c.UserID] {
			return fmt.Errorf("snapshot %s: user %s contributes twice", snap.RoomID, c.UserID)
		}
		seen[c.UserID] = true
		if !validSeatState(c.Status) {
			return fmt.Errorf("snapshot %s: contribution of %s has status %q", snap.RoomID, c.UserID, c.Status)
		}
		if err := validCardCodes(c.Cards); err != nil {
			return fmt.Errorf("snapshot %s: contribution of %s: %w", snap.RoomID, c.UserID, err)
		}
	}
	if p := h.Sideshow; p != nil {
		if !seatOK(p.FromSeat) || snap.Seats[p.FromSeat].UserID != p.FromUserID {
			return fmt.Errorf("snapshot %s: sideshow asker %s is not at seat %d", snap.RoomID, p.FromUserID, p.FromSeat)
		}
		if !seatOK(p.ToSeat) || snap.Seats[p.ToSeat].UserID != p.ToUserID {
			return fmt.Errorf("snapshot %s: sideshow target %s is not at seat %d", snap.RoomID, p.ToUserID, p.ToSeat)
		}
	}
	return nil
}

func validSeatState(s SeatState) bool {
	switch s {
	case SeatWaiting, SeatActive, SeatPacked, SeatLost, SeatWon:
		return true
	}
	return false
}

// validCardCodes accepts [] or exactly parseable 2-char codes (ParseCard
// trusts its input; a restore must not).
func validCardCodes(codes []string) error {
	for _, code := range codes {
		if len(code) != 2 {
			return fmt.Errorf("card %q is not a card code", code)
		}
		if _, ok := codeRanks[code[0]]; !ok {
			return fmt.Errorf("card %q has no rank", code)
		}
		suitOK := false
		for _, suit := range Suits {
			if code[1] == suit {
				suitOK = true
				break
			}
		}
		if !suitOK {
			return fmt.Errorf("card %q has no suit", code)
		}
	}
	return nil
}
