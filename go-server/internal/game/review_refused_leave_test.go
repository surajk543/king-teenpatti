package game

// A leave the ledger REFUSED (review of 27 Sep 2026). A player who leaves mid
// hand is written through by their own hand_left checkpoint, and the hand-end
// settle skips them. When that checkpoint is refused (a database hiccup),
// chipsWritten is not advanced — but nothing else ever wrote it: a checkpoint
// has no retry chain, and the hand end skipped every departed non-winner. The
// stake they had put in stayed in their wallet while the winner was paid a pot
// that included it, and the books gained chips from nothing. The poker rooms
// already carried the owed delta on the settle (DECISIONS.md); these pin the
// Teen Patti table to the same rule, and the duplicate_action reading that
// keeps the carry from charging a leave that had in fact landed.

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
)

// strictBooks is a Ledger that keeps books the way db.Ledger does in every
// respect these tests read: a wallet per player moved by each entry's Delta,
// one row per LedgerRows row, UNIQUE action ids (a replay is duplicate_action
// and changes nothing), a Settle that is all or nothing, and the XP window
// opened only for an Outcome row of a player who did not leave
// (db.Ledger.Settle). It writes no gameplay counter (Player stats v2): the
// counters it keeps are the ones the TABLE hands its StatsRecorder once a
// write has committed (record, wired by strictTable / withStats) — plus, for
// a write simulated as landed in an earlier life (landedAlready), what that
// life's table recorded after its commit. It can refuse chosen checkpoints
// and every settle.
type strictBooks struct {
	mu        sync.Mutex
	wallets   map[string]int64
	spent     map[string]bool
	deltas    map[string]int64 // action id → the delta its row moved
	rows      []strictRow
	stats     map[string]*strictStats
	completed map[string]int // the players whose XP window a settle opened
	settles   []SettleRequest
	// refuse, when set, is asked about every checkpoint; a non-nil answer is
	// the ledger's refusal and nothing is written.
	refuse func(entry SettleEntry) error
	// refuseSettle refuses every hand-end settlement.
	refuseSettle bool
	// landedAlready, when set, names checkpoints whose write already landed
	// in an earlier life of the hand: the row is applied as it was then, and
	// the answer is the duplicate_action a replay of it gets.
	landedAlready func(entry SettleEntry) bool
	// mute makes a replayed checkpoint's duplicate_action bare, as a ledger
	// that cannot read the row back answers (no LandedDelta).
	mute bool
	// lostReply, when set, names checkpoints that COMMIT and are then
	// answered with an error — the acknowledgement lost (a statement timeout
	// after the commit, a dropped connection).
	lostReply func(entry SettleEntry) bool
}

type strictRow struct {
	hand  string
	entry SettleEntry
}

type strictStats struct{ played, won, lost, left int }

func newStrictBooks() *strictBooks {
	return &strictBooks{
		wallets:   map[string]int64{},
		spent:     map[string]bool{},
		deltas:    map[string]int64{},
		stats:     map[string]*strictStats{},
		completed: map[string]int{},
	}
}

func (b *strictBooks) ledger(*harness) Ledger { return b }

func (b *strictBooks) fund(id string, chips int64) {
	b.mu.Lock()
	b.wallets[id] = chips
	b.mu.Unlock()
}

// applyLocked is db.applyCheckpoint for one entry. The caller holds mu and
// has checked every action id.
func (b *strictBooks) applyLocked(handID string, entry SettleEntry) {
	b.wallets[entry.UserID] += entry.Delta
	for _, row := range LedgerRows(handID, entry) {
		b.spent[row.ActionID] = true
		b.deltas[row.ActionID] = row.Delta
		b.rows = append(b.rows, strictRow{hand: handID, entry: row})
	}
}

// countLocked adds one player's committed counters. The caller holds mu.
func (b *strictBooks) countLocked(h HandStats) {
	st := b.stats[h.UserID]
	if st == nil {
		st = &strictStats{}
		b.stats[h.UserID] = st
	}
	st.played += int(h.Played)
	st.won += int(h.Won)
	st.lost += int(h.Lost)
	st.left += int(h.Left)
}

// record is the table's StatsRecorder: the counters of writes that have
// committed, the only way a counter moves (Player stats v2).
func (b *strictBooks) record(stats []HandStats) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, h := range stats {
		b.countLocked(h)
	}
}

func (b *strictBooks) Checkpoint(_ context.Context, req CheckpointRequest) (CheckpointResult, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.refuse != nil {
		if err := b.refuse(req.Entry); err != nil {
			return CheckpointResult{}, &GameError{Code: CodePersistFailed, Message: err.Error(), Cause: err}
		}
	}
	if b.landedAlready != nil && b.landedAlready(req.Entry) && !b.spent[req.Entry.ActionID] {
		b.applyLocked(req.HandID, req.Entry)
		// The earlier life's table heard that commit and recorded its
		// counters (Table.checkpoint), before the process stopped.
		if h, ok := StatsForEntry(req.Entry, StatsTeenPatti); ok && !h.Empty() {
			b.countLocked(h)
		}
	}
	if b.spent[req.Entry.ActionID] {
		// db.Ledger.Checkpoint: the refusal says what the row already holding
		// the id moved the wallet by.
		if b.mute {
			return CheckpointResult{}, NewGameError(CodeDuplicateAction, MsgDuplicateAction)
		}
		return CheckpointResult{}, DuplicateCheckpoint("", b.deltas[req.Entry.ActionID])
	}
	b.applyLocked(req.HandID, req.Entry)
	if b.lostReply != nil && b.lostReply(req.Entry) {
		return CheckpointResult{}, &GameError{Code: CodePersistFailed, Message: "the reply was lost"}
	}
	return CheckpointResult{Balance: b.wallets[req.Entry.UserID]}, nil
}

func (b *strictBooks) Settle(_ context.Context, req SettleRequest) (SettleResult, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.settles = append(b.settles, req)
	if b.refuseSettle {
		return SettleResult{}, &GameError{Code: CodePersistFailed, Message: "settle down"}
	}
	// One transaction: a single spent id rolls the whole of it back.
	for _, entry := range req.Entries {
		for _, row := range LedgerRows(req.HandID, entry) {
			if b.spent[row.ActionID] {
				return SettleResult{}, NewGameError(CodeDuplicateAction, MsgDuplicateAction)
			}
		}
	}
	result := SettleResult{Balances: map[string]int64{}}
	for _, entry := range req.Entries {
		b.applyLocked(req.HandID, entry)
		result.Balances[entry.UserID] = b.wallets[entry.UserID]
		if entry.Outcome && !entry.LeftMidHand {
			b.completed[entry.UserID]++
		}
	}
	return result, nil
}

var _ Ledger = (*strictBooks)(nil)

func (b *strictBooks) total() int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	var sum int64
	for _, v := range b.wallets {
		sum += v
	}
	return sum
}

func (b *strictBooks) wallet(id string) int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.wallets[id]
}

func (b *strictBooks) counters(id string) strictStats {
	b.mu.Lock()
	defer b.mu.Unlock()
	if st := b.stats[id]; st != nil {
		return *st
	}
	return strictStats{}
}

// rowsOf is every row written for one player in one hand, in order.
func (b *strictBooks) rowsOf(hand, id string) []SettleEntry {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []SettleEntry
	for _, r := range b.rows {
		if r.hand == hand && r.entry.UserID == id {
			out = append(out, r.entry)
		}
	}
	return out
}

// resolutions is how the money audits (tools/parity/money.test.js,
// tools/crashtest.mjs doubleClosed) count one player's resolutions of one
// hand: every hand_win, hand_loss and hand_left row, except that a hand_loss
// that moves chips beside that player's own hand_left row of the same hand is
// the leave's CATCH-UP — the stake the leave did not bank, written by the
// hand end — and not a second resolution. Any other count is a player
// resolved twice (or never).
func (b *strictBooks) resolutions(hand, id string) int {
	rows := b.rowsOf(hand, id)
	left := false
	for _, r := range rows {
		if r.Reason == LedgerReasonHandLeft {
			left = true
		}
	}
	n := 0
	for _, r := range rows {
		switch r.Reason {
		case LedgerReasonHandWin, LedgerReasonHandLeft:
			n++
		case LedgerReasonHandLoss:
			if !(left && r.Delta != 0) {
				n++
			}
		}
	}
	return n
}

// caughtUp holds the quitter's rows of the hand to the one shape a leave and
// its catch-up may take in the books: the hand_left row under the leave's own
// action id, then a hand_loss under the settle's that moves chips — the pair
// the audits read as ONE resolution.
func (b *strictBooks) caughtUp(t *testing.T, hand, id string) {
	t.Helper()
	rows := b.rowsOf(hand, id)
	var outcome []SettleEntry
	for _, r := range rows {
		if r.Reason != LedgerReasonHandPacked {
			outcome = append(outcome, r)
		}
	}
	if len(outcome) != 2 ||
		outcome[0].Reason != LedgerReasonHandLeft || outcome[0].ActionID != LeftActionID(hand, id) ||
		outcome[1].Reason != LedgerReasonHandLoss || outcome[1].ActionID != SettleActionID(hand, id) ||
		outcome[1].Delta == 0 {
		b.dump(t)
		t.Fatalf("%s's rows of hand %s are not a leave and its catch-up", id, hand)
	}
	eq(t, b.resolutions(hand, id), 1, "the audits read the leave and its catch-up as one resolution")
}

// handSum is Σ delta of a hand's hand_* rows — zero for every Teen Patti hand
// (the table tax is a row of its own).
func (b *strictBooks) handSum(hand string) int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	var sum int64
	for _, r := range b.rows {
		if r.hand == hand && r.entry.Reason != LedgerReasonTableTax {
			sum += r.entry.Delta
		}
	}
	return sum
}

// windowsOpened is how many settles opened id's XP window.
func (b *strictBooks) windowsOpened(id string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.completed[id]
}

// settleOf is the index-th settle request sent for hand (every attempt of it,
// the retries included).
func (b *strictBooks) settleOf(t *testing.T, hand string, index int) SettleRequest {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	var seen []SettleRequest
	for _, req := range b.settles {
		if req.HandID == hand {
			seen = append(seen, req)
		}
	}
	if index >= len(seen) {
		t.Fatalf("hand %s was settled %d time(s); wanted attempt %d", hand, len(seen), index+1)
	}
	return seen[index]
}

func (b *strictBooks) dump(t *testing.T) {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	ids := make([]string, 0, len(b.wallets))
	for id := range b.wallets {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		t.Logf("wallet %s = %d", id, b.wallets[id])
	}
	for _, r := range b.rows {
		t.Logf("row %s %s %s delta=%d outcome=%v", r.entry.UserID, r.entry.Reason, r.entry.ActionID, r.entry.Delta, r.entry.Outcome)
	}
}

// refuseLeaveOf refuses exactly the hand_left checkpoint of one player.
func refuseLeaveOf(userID string) func(SettleEntry) error {
	return func(e SettleEntry) error {
		if e.UserID == userID && e.Reason == LedgerReasonHandLeft {
			return errors.New("connection reset")
		}
		return nil
	}
}

// entryFor is userID's entry in req, or nil.
func entryFor(req SettleRequest, userID string) *SettleEntry {
	for i := range req.Entries {
		if req.Entries[i].UserID == userID {
			return &req.Entries[i]
		}
	}
	return nil
}

// strictTable is three players at a table on strict books, dealt in, with
// the first to act having played a chaal: the quitter-to-be.
func strictTable(t *testing.T, cfg TableConfig, books *strictBooks, opts ...harnessOption) (h *harness, quitter, hand string) {
	t.Helper()
	h = newHarness(t, cfg, append([]harnessOption{withLedger(books.ledger), withStats(books.record)}, opts...)...)
	for _, id := range []string{"a", "b", "c"} {
		books.fund(id, settleStart)
		if _, err := h.table.AddPlayer(NewPlayer{UserID: id, DisplayName: strings.ToUpper(id), Chips: settleStart, SocketID: "s-" + id, TaxBps: 2000}); err != nil {
			t.Fatalf("seat %s: %v", id, err)
		}
	}
	h.advance(cfg.NextHandDelay)
	hand = h.lastHandStarted().HandID
	quitter = h.turnUser()
	h.mustAct(quitter, ActionChaal, ActRequest{})
	return h, quitter, hand
}

// finish plays the hand out with packs: the last player standing wins it.
func finish(h *harness) {
	h.t.Helper()
	for i := 0; i < 10 && h.hasHand(); i++ {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	if h.hasHand() {
		h.t.Fatal("the hand did not end")
	}
}

// TestALeaveTheLedgerRefusedIsBankedAtTheHandEnd is the bug. The ledger
// refuses the quitter's hand_left write; the hand plays out; the settle must
// carry what they still owe — their whole stake — or the winner is paid a pot
// that includes chips no wallet ever gave up. The carried row is never under
// the leave's action id and carries no XP and no tax; it is the quitter's
// OUTCOME (Player stats v2): the refused leave recorded no counters, so the
// hand is counted for them here — hands_left and hands_played, once — when
// the settle commits.
func TestALeaveTheLedgerRefusedIsBankedAtTheHandEnd(t *testing.T) {
	for _, taxed := range []bool{false, true} {
		t.Run(fmt.Sprintf("taxed=%v", taxed), func(t *testing.T) {
			cfg := settleConfig()
			cfg.WinnerTax = taxed
			books := newStrictBooks()
			books.refuse = func(SettleEntry) error { return nil }
			h, quitter, hand := strictTable(t, cfg, books)
			staked := h.mustSeat(quitter).Contributed

			books.refuse = refuseLeaveOf(quitter)
			h.remove(quitter, LeaveReasonLeft)
			pe := h.rec.last("persistError").(PersistErrorEvent)
			eq(t, pe.Reason, LedgerReasonHandLeft, "the refused leave is reported")
			eq(t, pe.UserID, quitter, "for the quitter")
			eq(t, books.wallet(quitter), settleStart, "nothing reached their wallet")
			books.refuse = nil

			finish(h)
			ended := h.lastEnded()
			if ended.WinnerID == nil {
				t.Fatal("nobody won")
			}
			winner := *ended.WinnerID

			req := books.settleOf(t, hand, 0)
			carried := entryFor(req, quitter)
			if carried == nil {
				books.dump(t)
				t.Fatalf("the settle does not carry the quitter's unbanked stake of %d: the books hold %d, want %d",
					staked, books.total(), 3*settleStart-ended.Tax)
			}
			eq(t, carried.Delta, -staked, "the carried row is exactly what the refused leave owed")
			eq(t, carried.ActionID, SettleActionID(hand, quitter), "under the settle's own action id, never the leave's")
			eq(t, carried.Reason, LedgerReasonHandLoss, "a :settle: row is hand_win or hand_loss (the parity audit's rule)")
			eq(t, carried.Outcome, true, "their outcome: the refused leave counted nothing")
			eq(t, carried.LeftMidHand, true, "and it is still a departed player's")
			eq(t, carried.IsWinner, false, "not the winner")
			eq(t, carried.Pot, int64(0), "no pot")
			eq(t, carried.Tax, int64(0), "no tax")
			eq(t, carried.WonWith, "", "no hand won with")

			eq(t, books.wallet(quitter), settleStart-staked, "their stake stays in the pot, and now their wallet says so")
			eq(t, books.total(), 3*settleStart-ended.Tax, "the books hold what they did, less only the winner's tax")
			eq(t, books.handSum(hand), int64(0), "the hand's hand_* rows sum to zero")
			if taxed {
				if ended.Tax <= 0 {
					t.Fatal("the taxed table took no tax")
				}
				win := entryFor(req, winner)
				eq(t, win.Tax, ended.Tax, "the winner alone carries the tax")
			}
			rows := books.rowsOf(hand, quitter)
			eq(t, len(rows), 1, "one row for the quitter in this hand")
			eq(t, books.counters(quitter), strictStats{played: 1, left: 1}, "the hand counted once for the quitter, as their leave would have")
			var counted []HandStats
			for _, st := range req.Stats {
				if st.UserID == quitter {
					counted = append(counted, st)
				}
			}
			if len(counted) != 1 {
				t.Fatalf("the settle's stats count the quitter %d times: %+v", len(counted), req.Stats)
			}
			eq(t, counted[0].HasHeld, false, "no held hand: they did not finish it")
			eq(t, counted[0].Lost, int64(0), "a leaver is never a loss")
			eq(t, books.windowsOpened(quitter), 0, "and opened no XP window")
			eq(t, books.windowsOpened(winner), 1, "as the winner's outcome row did")
			eq(t, h.mustSeat(winner).Chips, books.wallet(winner), "the winner's seat is their wallet")
		})
	}
}

// TestALeaverIsWrittenOnceWhateverTheirLeaveCheckpointAnswered: committed,
// refused, or answered duplicate_action because it had landed already — in
// every case the quitter's stake leaves their wallet exactly once and the
// books balance. A committed leave (and a landed one) is written NOTHING more
// at the hand end: it resolved them, counters included, and a zero-delta row
// there would be a second outcome row for one player in one hand. And in
// every case the hand counts for them exactly once (hands_left, hands_played):
// at the leave when it was heard to commit, in the earlier life when it had
// landed already, and at the hand end's catch-up when it was refused.
func TestALeaverIsWrittenOnceWhateverTheirLeaveCheckpointAnswered(t *testing.T) {
	for _, tc := range []struct {
		name       string
		answer     func(b *strictBooks, quitter string)
		carried    bool
		wantReason string
		wantLeft   int
	}{
		{name: "committed", answer: func(*strictBooks, string) {}, wantReason: LedgerReasonHandLeft, wantLeft: 1},
		{name: "refused", answer: func(b *strictBooks, q string) { b.refuse = refuseLeaveOf(q) }, carried: true, wantReason: LedgerReasonHandLoss, wantLeft: 1},
		{name: "already landed", answer: func(b *strictBooks, q string) {
			b.landedAlready = func(e SettleEntry) bool { return e.UserID == q && e.Reason == LedgerReasonHandLeft }
		}, wantReason: LedgerReasonHandLeft, wantLeft: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			books := newStrictBooks()
			h, quitter, hand := strictTable(t, settleConfig(), books)
			staked := h.mustSeat(quitter).Contributed
			tc.answer(books, quitter)
			h.remove(quitter, LeaveReasonLeft)
			books.refuse, books.landedAlready = nil, nil
			finish(h)

			carried := entryFor(books.settleOf(t, hand, 0), quitter)
			eq(t, carried != nil, tc.carried, "the settle carries the quitter")
			eq(t, books.wallet(quitter), settleStart-staked, "their stake left their wallet exactly once")
			eq(t, books.total(), 3*settleStart, "the books balance")
			rows := books.rowsOf(hand, quitter)
			if len(rows) != 1 {
				books.dump(t)
				t.Fatalf("%d rows for the quitter, want 1", len(rows))
			}
			eq(t, rows[0].Reason, tc.wantReason, "the one row")
			eq(t, books.resolutions(hand, quitter), 1, "resolved once, as the audits count it")
			eq(t, books.counters(quitter).left, tc.wantLeft, "hands_left, exactly once")
			eq(t, books.counters(quitter).played, 1, "hands_played, exactly once")
			eq(t, books.counters(quitter).lost, 0, "a leaver is never counted a loss")
			if len(h.rec.all("persistError")) != boolToCount(tc.carried) {
				t.Fatalf("persistErrors %v: only a refusal is one", h.rec.all("persistError"))
			}
		})
	}
}

// TestALeaveWhoseReplyWasLostIsCountedOnce: the quitter's hand_left COMMITTED
// but its acknowledgement was lost, so the table read it as refused. The
// counters are recorded only after a heard commit, so the leave counted
// nothing, and the hand end's catch-up — an outcome, since the leave is
// marked uncounted — counts the hand exactly once. The money is the residual
// hazard DECISIONS.md names (the stake is debited a second time: a wallet
// short by a stake, never a chip created).
func TestALeaveWhoseReplyWasLostIsCountedOnce(t *testing.T) {
	books := newStrictBooks()
	h, quitter, hand := strictTable(t, settleConfig(), books)
	staked := h.mustSeat(quitter).Contributed
	books.lostReply = func(e SettleEntry) bool { return e.UserID == quitter && e.Reason == LedgerReasonHandLeft }
	h.remove(quitter, LeaveReasonLeft)
	books.lostReply = nil
	eq(t, books.counters(quitter), strictStats{}, "nothing counted at a leave whose answer was an error")
	finish(h)

	carried := entryFor(books.settleOf(t, hand, 0), quitter)
	if carried == nil {
		t.Fatal("the settle does not carry the quitter")
	}
	eq(t, carried.Outcome, true, "the catch-up is their outcome")
	eq(t, books.counters(quitter), strictStats{played: 1, left: 1}, "the hand counted exactly once")
	eq(t, books.wallet(quitter), settleStart-2*staked, "the stake debited twice: the known residual")
	eq(t, books.total(), 3*settleStart-staked, "never a chip created")
	books.caughtUp(t, hand, quitter)
}

func boolToCount(b bool) int {
	if b {
		return 1
	}
	return 0
}

// TestARefusedLeaveRidesTheSettlesRetryChain: the database is down when the
// player leaves AND when the hand ends. A checkpoint has no retry chain, so
// the owed stake must ride the settle's — the manager hears of it as owed
// (so the leaver cannot seat that stake elsewhere while the retries run), and
// the retry lands it with everyone else's.
func TestARefusedLeaveRidesTheSettlesRetryChain(t *testing.T) {
	books := newStrictBooks()
	var mu sync.Mutex
	owed := map[string]int{}
	h, quitter, hand := strictTable(t, settleConfig(), books, withSettlementOwed(func(req SettleRequest, isOwed bool) {
		mu.Lock()
		defer mu.Unlock()
		for _, e := range req.Entries {
			if e.Delta == 0 {
				continue
			}
			if isOwed {
				owed[e.UserID]++
			} else {
				owed[e.UserID]--
			}
		}
	}))
	staked := h.mustSeat(quitter).Contributed

	books.refuse = refuseLeaveOf(quitter)
	books.refuseSettle = true
	h.remove(quitter, LeaveReasonLeft)
	// Keep the table from dealing again: the one player left after the pack
	// stays, and only the retries are on the clock.
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	eq(t, h.hasHand(), false, "the hand is over whatever the database says")
	eq(t, books.wallet(quitter), settleStart, "nothing has landed yet")
	first := books.settleOf(t, hand, 0)
	carried := entryFor(first, quitter)
	if carried == nil {
		t.Fatal("the refused settle did not carry the quitter's stake")
	}
	eq(t, carried.Delta, -staked, "their stake")
	mu.Lock()
	eq(t, owed[quitter], 1, "the quitter's wallet is owed a write while the retries run")
	mu.Unlock()

	books.mu.Lock()
	books.refuse = nil
	books.refuseSettle = false
	books.mu.Unlock()
	h.advance(settleConfig().NextHandDelay) // retry 1

	retry := books.settleOf(t, hand, 1)
	eq(t, len(retry.Entries), len(first.Entries), "the retry re-sends the request unchanged")
	eq(t, *entryFor(retry, quitter), *carried, "the carried row with it")
	eq(t, books.wallet(quitter), settleStart-staked, "the retry banked the stake")
	eq(t, books.total(), 3*settleStart, "the books balance")
	mu.Lock()
	eq(t, owed[quitter], 0, "and the wallet is owed nothing more")
	mu.Unlock()
}

// TestARestoreAfterARefusedLeaveStillBanksTheStake: the process goes down
// after the refused leave and the hand is restored from the live store. The
// snapshot keeps the quitter's contribution — leftMidHand, and chipsWritten
// not advanced — so the restored hand's end carries the stake exactly as the
// original would have.
func TestARestoreAfterARefusedLeaveStillBanksTheStake(t *testing.T) {
	books := newStrictBooks()
	h, quitter, hand := strictTable(t, liveConfig(), books, withLive(livetest.New()))
	staked := h.mustSeat(quitter).Contributed
	books.refuse = refuseLeaveOf(quitter)
	h.remove(quitter, LeaveReasonLeft)
	books.refuse = nil

	snap := roundTrip(t, mustSnapshot(h))
	var saved *SnapshotContribution
	for i := range snap.Hand.Contributions {
		if snap.Hand.Contributions[i].UserID == quitter {
			saved = &snap.Hand.Contributions[i]
		}
	}
	if saved == nil {
		t.Fatal("the snapshot lost the quitter's contribution")
	}
	eq(t, saved.LeftMidHand, true, "saved as having left")
	eq(t, saved.ChipsWritten-saved.Chips, staked, "saved with the stake still unwritten")
	eq(t, saved.LeftUncounted, true, "saved as not yet counted")
	if err := h.table.Suspend(); err != nil {
		t.Fatal(err)
	}

	r := restoreHarness(t, snap, newFakeClock(h.clock.Now()), withLedger(books.ledger), withStats(books.record))
	finish(r)
	carried := entryFor(books.settleOf(t, hand, 0), quitter)
	if carried == nil {
		books.dump(t)
		t.Fatal("the restored hand's end forgot the quitter's unbanked stake")
	}
	eq(t, carried.Outcome, true, "the restored catch-up still counts them")
	eq(t, books.counters(quitter), strictStats{played: 1, left: 1}, "counted once, across the restart")
	eq(t, books.wallet(quitter), settleStart-staked, "banked once")
	eq(t, books.total(), 3*settleStart, "the books balance")
}

// TestASnapshotFromBeforeTheMarkCountsARefusedLeaveNowhere: a hand saved by a
// build that did not keep leftUncounted restores with it false. The stake is
// still banked (the money never depended on the mark); the hand is counted
// for the leaver nowhere — at most once, never twice.
func TestASnapshotFromBeforeTheMarkCountsARefusedLeaveNowhere(t *testing.T) {
	books := newStrictBooks()
	h, quitter, hand := strictTable(t, liveConfig(), books, withLive(livetest.New()))
	staked := h.mustSeat(quitter).Contributed
	books.refuse = refuseLeaveOf(quitter)
	h.remove(quitter, LeaveReasonLeft)
	books.refuse = nil

	snap := roundTrip(t, mustSnapshot(h))
	for i := range snap.Hand.Contributions {
		snap.Hand.Contributions[i].LeftUncounted = false // an older build's save
	}
	if err := h.table.Suspend(); err != nil {
		t.Fatal(err)
	}
	r := restoreHarness(t, snap, newFakeClock(h.clock.Now()), withLedger(books.ledger), withStats(books.record))
	finish(r)
	carried := entryFor(books.settleOf(t, hand, 0), quitter)
	if carried == nil {
		t.Fatal("the stake was not carried")
	}
	eq(t, carried.Outcome, false, "money only")
	eq(t, books.counters(quitter), strictStats{}, "counted nowhere")
	eq(t, books.wallet(quitter), settleStart-staked, "banked once")
	eq(t, books.total(), 3*settleStart, "the books balance")
}

// TestARestoreThatReplaysACheckpointThatLandedChargesItOnce: the process
// went down between a checkpoint's commit and the snapshot that would have
// recorded it, so the restored hand still has the player in it and replays
// the move. The ledger refuses the replay duplicate_action — the write had
// landed — and the table must read that as written through: otherwise the
// hand end charges the same stake a second time (the packer's outcome row, or
// a leaver's catch-up row).
func TestARestoreThatReplaysACheckpointThatLandedChargesItOnce(t *testing.T) {
	for _, tc := range []struct {
		name   string
		replay func(h *harness, id string)
	}{
		{name: "a leave", replay: func(h *harness, id string) { h.remove(id, LeaveReasonDisconnected) }},
		{name: "a pack", replay: func(h *harness, id string) {
			for i := 0; i < 6 && h.turnUser() != id; i++ {
				h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
			}
			h.mustAct(id, ActionPack, ActRequest{})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			books := newStrictBooks()
			h, player, hand := strictTable(t, liveConfig(), books, withLive(livetest.New()))
			before := roundTrip(t, mustSnapshot(h)) // the last save the process made
			tc.replay(h, player)
			staked := settleStart - books.wallet(player)
			if staked <= 0 {
				t.Fatalf("the first %s wrote nothing", tc.name)
			}
			if err := h.table.Suspend(); err != nil {
				t.Fatal(err)
			}

			r := restoreHarness(t, before, newFakeClock(h.clock.Now()), withLedger(books.ledger), withStats(books.record))
			tc.replay(r, player)
			finish(r)

			if got := books.wallet(player); got != settleStart-staked {
				books.dump(t)
				t.Fatalf("%s is banked at %d, want %d: the landed write was charged again", player, got, settleStart-staked)
			}
			eq(t, books.total(), 3*settleStart, "the books balance")
			eq(t, books.handSum(hand), int64(0), "the hand's rows sum to zero")
			if got := len(r.rec.all("persistError")); got != 0 {
				t.Fatalf("a replay of a landed write was reported as a failure (%d)", got)
			}
			if tc.name == "a leave" {
				// The earlier life counted the leave after its commit; the
				// replay counts nothing, and nothing is left to catch up.
				eq(t, books.counters(player), strictStats{played: 1, left: 1}, "the leave counted once")
				eq(t, len(books.rowsOf(hand, player)), 1, "the landed leave is the one row: nothing to catch up")
				eq(t, books.resolutions(hand, player), 1, "resolved once, as the audits count it")
			}
		})
	}
}

// TestALeaverWhoWinsIsPaidOnceWhetherTheirLeaveLandedOrNot: the pot of a
// hand everyone left goes to the last to leave (ALL_LEFT), from outside the
// table. The winner's entry has always carried the whole of their delta —
// the pot less the tax, less any stake a refused leave did not bank — so the
// catch-up rule leaves it alone; the other leaver's refused leave rides the
// same settle.
func TestALeaverWhoWinsIsPaidOnceWhetherTheirLeaveLandedOrNot(t *testing.T) {
	for _, tc := range []struct {
		name                     string
		refuseLoser, refuseWinnr bool
	}{
		{name: "both leaves landed"},
		{name: "the loser's leave was refused", refuseLoser: true},
		{name: "the winner's leave was refused", refuseWinnr: true},
		{name: "both leaves were refused", refuseLoser: true, refuseWinnr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := settleConfig()
			cfg.WinnerTax = true
			books := newStrictBooks()
			h := newHarness(t, cfg, withLedger(books.ledger), withStats(books.record))
			for _, id := range []string{"a", "b"} {
				books.fund(id, settleStart)
				if _, err := h.table.AddPlayer(NewPlayer{UserID: id, DisplayName: strings.ToUpper(id), Chips: settleStart, SocketID: "s-" + id, TaxBps: 2000}); err != nil {
					t.Fatal(err)
				}
			}
			h.advance(cfg.NextHandDelay)
			hand := h.lastHandStarted().HandID
			h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
			books.refuse = func(e SettleEntry) error {
				if e.Reason == LedgerReasonHandLeft && ((e.UserID == "a" && tc.refuseLoser) || (e.UserID == "b" && tc.refuseWinnr)) {
					return errors.New("connection reset")
				}
				return nil
			}
			var stakes = map[string]int64{}
			// Both seats vacated without ending the hand, b the last to go —
			// the seam TestATaxingTableTaxesTheWinnerOfEveryKindOfHandEnd's
			// "the last to leave" uses.
			h.read(func() {
				for _, id := range []string{"a", "b"} {
					s := h.table.findSeat(id)
					stakes[id] = s.contributed
					s.status = SeatPacked
					h.table.syncContribution(s, SeatPacked)
					entry := h.table.hand.contributions[id]
					entry.leftMidHand = true
					entry.chips = s.chips
					h.table.checkpoint(entry, LedgerReasonHandLeft, LeftActionID(h.table.hand.id, id), true)
					h.table.seats[s.seatIndex] = nil
				}
				h.table.refreshPlayerCount()
				departed := "b"
				h.table.hand.lastDeparture = &departed
				h.table.resolveIfOnlyOneLeft()
			})
			books.refuse = nil
			if h.hasHand() {
				if err := h.table.Destroy(); err != nil {
					t.Fatal(err)
				}
			}
			ended := h.lastEnded()
			if ended.WinnerID == nil || *ended.WinnerID != "b" {
				t.Fatalf("winner %v, want b (the last to leave)", ended.WinnerID)
			}
			pot := stakes["a"] + stakes["b"]
			eq(t, ended.Pot, pot, "the pot")
			tax := TableTax(WinnerWinnings(pot, stakes["b"]), 2000)
			eq(t, ended.Tax, tax, "the winner pays their rate of what they won")

			req := books.settleOf(t, hand, 0)
			win := entryFor(req, "b")
			if win == nil {
				t.Fatal("the winner who left was not paid")
			}
			eq(t, win.IsWinner, true, "b wins")
			eq(t, win.Outcome, true, "the winner's row is an outcome, as it always was")
			eq(t, win.Tax, tax, "and carries the tax")
			wantWin := pot - tax
			if tc.refuseWinnr {
				wantWin -= stakes["b"]
			}
			eq(t, win.Delta, wantWin, "the winner's delta covers whatever their leave did not bank")

			loser := entryFor(req, "a")
			eq(t, loser != nil, tc.refuseLoser, "the loser is carried exactly when their leave was refused")
			if loser != nil {
				eq(t, loser.Delta, -stakes["a"], "their stake")
				eq(t, loser.Outcome, true, "their outcome: the refused leave counted nothing")
			}
			eq(t, books.counters("a").left, 1, "the loser's departure counted exactly once")
			eq(t, books.counters("a").lost, 0, "and never as a loss")
			eq(t, books.wallet("a"), settleStart-stakes["a"], "a's stake left a's wallet once")
			eq(t, books.wallet("b"), settleStart-stakes["b"]+pot-tax, "b was paid the pot less the tax, once")
			eq(t, books.total(), 2*settleStart-tax, "the books lose exactly the tax")
			eq(t, books.handSum(hand), int64(0), "the hand's hand_* rows sum to zero")
		})
	}
}

// toTurn has everyone else chaal until id is on turn.
func toTurn(h *harness, id string) {
	h.t.Helper()
	for i := 0; i < 8 && h.turnUser() != id; i++ {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	if h.turnUser() != id {
		h.t.Fatalf("%s never came on turn", id)
	}
}

// TestARestoredPlayerWhoPlaysOnBeforeTheReplayIsChargedTheDifference (the
// skeptic's probe of 27 Sep 2026): a pack or leave landed and the process
// stopped before the snapshot recorded it; the restored hand still has the
// player in it, and this time they chaal once more BEFORE packing or leaving
// again. The replay is refused duplicate_action, and the table must advance
// what it counts as written by exactly what landed — not to the stack it
// holds now, which would leave that chaal unwritten while the winner is paid
// it. The rest reaches the wallet at the hand end: a packer's outcome row, a
// leaver's catch-up row.
func TestARestoredPlayerWhoPlaysOnBeforeTheReplayIsChargedTheDifference(t *testing.T) {
	for _, tc := range []struct {
		name  string
		first func(h *harness, id string)
		again func(h *harness, id string)
	}{
		{
			name:  "a pack",
			first: func(h *harness, id string) { toTurn(h, id); h.mustAct(id, ActionPack, ActRequest{}) },
			again: func(h *harness, id string) { h.mustAct(id, ActionPack, ActRequest{}) },
		},
		{
			name:  "a leave",
			first: func(h *harness, id string) { h.remove(id, LeaveReasonLeft) },
			again: func(h *harness, id string) { h.remove(id, LeaveReasonDisconnected) },
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			books := newStrictBooks()
			h, player, hand := strictTable(t, liveConfig(), books, withLive(livetest.New()))
			before := roundTrip(t, mustSnapshot(h)) // the last save the process made
			tc.first(h, player)
			landed := settleStart - books.wallet(player)
			if landed <= 0 {
				t.Fatalf("the first %s wrote nothing", tc.name)
			}
			if err := h.table.Suspend(); err != nil {
				t.Fatal(err)
			}

			r := restoreHarness(t, before, newFakeClock(h.clock.Now()), withLedger(books.ledger), withStats(books.record))
			toTurn(r, player)
			r.mustAct(player, ActionChaal, ActRequest{}) // the earlier life never saw this
			toTurn(r, player)
			staked := r.mustSeat(player).Contributed
			if staked <= landed {
				t.Fatalf("the restored life staked %d, no more than the %d that landed", staked, landed)
			}
			tc.again(r, player)
			if got := len(r.rec.all("persistError")); got != 0 {
				t.Fatalf("a replay that says what landed was reported as a failure (%d)", got)
			}
			finish(r)

			if got := books.wallet(player); got != settleStart-staked {
				books.dump(t)
				t.Fatalf("%s is banked at %d, want %d: the chaal made after the restore was not written", player, got, settleStart-staked)
			}
			eq(t, books.total(), 3*settleStart, "the books balance: no chip created")
			eq(t, books.handSum(hand), int64(0), "the hand's rows sum to zero")
			if tc.name == "a leave" {
				// The earlier life counted the leave; the replay and the
				// catch-up of the chaal it never saw count nothing more.
				eq(t, books.counters(player), strictStats{played: 1, left: 1}, "the leave counted once, never twice")
				books.caughtUp(t, hand, player)
			} else {
				eq(t, books.counters(player).lost, 1, "the packer's loss counted once, at the hand end")
				eq(t, books.counters(player).left, 0, "and never as a departure")
			}
		})
	}
}

// TestADuplicateThatDoesNotSayWhatLandedIsARefusal: a ledger that cannot
// read the row back answers a bare duplicate_action. The table cannot know
// how much of the stake is banked, so it treats the write as refused —
// reported, nothing advanced — which can at worst charge the stake twice and
// can never create a chip.
func TestADuplicateThatDoesNotSayWhatLandedIsARefusal(t *testing.T) {
	books := newStrictBooks()
	h, player, hand := strictTable(t, liveConfig(), books, withLive(livetest.New()))
	before := roundTrip(t, mustSnapshot(h))
	h.remove(player, LeaveReasonLeft)
	if err := h.table.Suspend(); err != nil {
		t.Fatal(err)
	}

	books.mute = true
	r := restoreHarness(t, before, newFakeClock(h.clock.Now()), withLedger(books.ledger), withStats(books.record))
	r.remove(player, LeaveReasonDisconnected)
	pe, ok := r.rec.last("persistError").(PersistErrorEvent)
	if !ok || pe.UserID != player || CodeOf(pe.Err, "") != CodeDuplicateAction {
		t.Fatalf("a bare duplicate_action was not reported as the refusal it is treated as: %+v", r.rec.all("persistError"))
	}
	finish(r)
	if total := books.total(); total > 3*settleStart {
		books.dump(t)
		t.Fatalf("the books hold %d, more than the %d they started with: a chip was created", total, 3*settleStart)
	}
	// The bare duplicate is a refusal for the money only: its write landed in
	// the earlier life, which counted it, so the catch-up counts nothing.
	eq(t, books.counters(player), strictStats{played: 1, left: 1}, "counted once, never twice")
	books.caughtUp(t, hand, player)
}

// owedCounter is a SettlementOwed hook keeping the manager's count per player
// (RoomManager.settlementOwed: a zero delta owes nothing).
type owedCounter struct {
	mu    sync.Mutex
	count map[string]int
}

func newOwedCounter() *owedCounter { return &owedCounter{count: map[string]int{}} }

func (o *owedCounter) hook(req SettleRequest, owed bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	for _, e := range req.Entries {
		if e.Delta == 0 {
			continue
		}
		if owed {
			o.count[e.UserID]++
		} else {
			o.count[e.UserID]--
		}
	}
}

func (o *owedCounter) of(id string) int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.count[id]
}

// TestAPlayerWhoLeavesStillOwedIsMarkedOwedUntilTheHandEnd is the skeptic's
// second finding: between a refused leave and the hand end, nothing marked
// the leaver owed, so a lobby door (a picture, a seat elsewhere) could spend
// the stake their wallet still held, and the hand end's debit then clamped at
// zero. The mark is set as they leave — on the actor, inside the transition
// that holds their stripe — and lifted once the hand end's write has landed
// or handed it to the retry chain's own mark. The same for a player whose
// pack was refused and who then walks out, whose outcome row carries it; and
// nothing at all for a leave that landed.
func TestAPlayerWhoLeavesStillOwedIsMarkedOwedUntilTheHandEnd(t *testing.T) {
	refusedLeave := func(h *harness, b *strictBooks, q string) {
		b.refuse = refuseLeaveOf(q)
		h.remove(q, LeaveReasonLeft)
	}
	destroy := func(h *harness) {
		if err := h.table.Destroy(); err != nil {
			h.t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		name   string
		leave  func(h *harness, b *strictBooks, q string)
		marked bool
		end    func(h *harness)
	}{
		{name: "a refused leave, the hand played out", leave: refusedLeave, marked: true, end: finish},
		{name: "a refused leave, the table destroyed", leave: refusedLeave, marked: true, end: destroy},
		{name: "a refused pack, then a leave", marked: true, end: finish, leave: func(h *harness, b *strictBooks, q string) {
			b.refuse = func(e SettleEntry) error {
				if e.UserID == q && e.Reason == LedgerReasonHandPacked {
					return errors.New("connection reset")
				}
				return nil
			}
			h.mustAct(q, ActionPack, ActRequest{})
			b.refuse = nil
			h.remove(q, LeaveReasonLeft)
		}},
		{name: "a leave that landed", end: finish, leave: func(h *harness, _ *strictBooks, q string) {
			h.remove(q, LeaveReasonLeft)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			books := newStrictBooks()
			owed := newOwedCounter()
			h, _, hand := strictTable(t, settleConfig(), books, withSettlementOwed(owed.hook))
			quitter := h.turnUser()
			staked := h.mustSeat(quitter).Contributed
			tc.leave(h, books, quitter)
			books.refuse = nil
			eq(t, h.hasHand(), true, "the hand plays on without them")
			eq(t, owed.of(quitter), boolToCount(tc.marked), "owed from the moment they are off the table, exactly when a write is still owed")

			tc.end(h)
			for _, id := range []string{"a", "b", "c"} {
				eq(t, owed.of(id), 0, "nobody is owed anything once the hand end's write has landed")
			}
			eq(t, books.wallet(quitter), settleStart-staked, "their stake left their wallet once")
			eq(t, books.total(), 3*settleStart, "the books balance")
			eq(t, books.handSum(hand), int64(0), "the hand's rows sum to zero")
		})
	}
}

// TestADepartedPlayersMarkSurvivesARestartAndASuspendKeepsIt: the mark lives
// in the manager of the process that saw the player go. A suspended table
// keeps it (that process is on its way out, and its lobby doors must not spend
// the stake before it goes); the process that restores the hand marks the
// player again before anything can end it, and lifts the mark at the hand end.
func TestADepartedPlayersMarkSurvivesARestartAndASuspendKeepsIt(t *testing.T) {
	books := newStrictBooks()
	first := newOwedCounter()
	h, quitter, _ := strictTable(t, liveConfig(), books, withLive(livetest.New()), withSettlementOwed(first.hook))
	staked := h.mustSeat(quitter).Contributed
	books.refuse = refuseLeaveOf(quitter)
	h.remove(quitter, LeaveReasonLeft)
	books.refuse = nil
	eq(t, first.of(quitter), 1, "marked as they left")

	snap := roundTrip(t, mustSnapshot(h))
	if err := h.table.Suspend(); err != nil {
		t.Fatal(err)
	}
	eq(t, first.of(quitter), 1, "a suspended table keeps the mark")

	second := newOwedCounter()
	r := restoreHarness(t, snap, newFakeClock(h.clock.Now()), withLedger(books.ledger), withStats(books.record), withSettlementOwed(second.hook))
	eq(t, second.of(quitter), 1, "the restoring process marks them again")
	finish(r)
	eq(t, second.of(quitter), 0, "and lifts it once the hand end has written the stake")
	eq(t, books.wallet(quitter), settleStart-staked, "banked once")
	eq(t, books.total(), 3*settleStart, "the books balance")
}
