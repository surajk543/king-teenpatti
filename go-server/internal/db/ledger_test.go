package db_test

import (
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/prometheus/client_golang/prometheus"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
)

// -------------------------------------------------------- checkpoints

// The pack checkpoint: one player's delta, one row, no counters. This is
// checkpoint 2 of the three (LIVE_STATE_PLAN.md).
func TestAPackCheckpointMovesTheWalletAndWritesOneRow(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	room, hand := "room-pack", "hand-pack"

	res, err := f.pack(room, hand, a, -25200)
	if err != nil {
		t.Fatal(err)
	}
	if res.Balance != welcome-25200 {
		t.Fatalf("balance = %d", res.Balance)
	}
	if got := f.chips(a.ID); got != welcome-25200 {
		t.Fatalf("wallet = %d, want %d", got, welcome-25200)
	}
	rows := f.handLedgerRows(hand)
	if len(rows) != 1 {
		t.Fatalf("%d rows, want 1", len(rows))
	}
	r := rows[0]
	if r.Reason != game.LedgerReasonHandPacked || r.Delta != -25200 || r.Balance != welcome-25200 {
		t.Fatalf("row %+v", r)
	}
	if r.ActionID == nil || *r.ActionID != hand+":packed:"+a.ID {
		t.Fatalf("action id %v", r.ActionID)
	}
	// A pack carries no counters: the hand-end row resolves the player.
	u := f.find(a.ID)
	if u.HandsPlayed != 0 || u.HandsLost != 0 || u.HandsWon != 0 || u.HandsLeftMid != 0 {
		t.Fatalf("a pack moved the counters: %+v", u)
	}
	f.reconcile()
}

// The leave/switch checkpoint resolves the player: hands_left_mid lands here,
// because they will not be at the hand-end write.
func TestALeaveCheckpointCountsHandsLeftMid(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	room, hand := "room-left", "hand-left"

	if _, err := f.left(room, hand, a, -25200, true); err != nil {
		t.Fatal(err)
	}
	u := f.find(a.ID)
	if u.HandsLeftMid != 1 || u.HandsPlayed != 1 || u.HandsLost != 0 || u.HandsWon != 0 {
		t.Fatalf("counters %+v", u)
	}
	rows := f.handLedgerRows(hand)
	if len(rows) != 1 || rows[0].Reason != game.LedgerReasonHandLeft {
		t.Fatalf("rows %+v", rows)
	}
	f.reconcile()
}

// A replayed checkpoint is refused by the UNIQUE action id, and because the
// wallet update is in the same transaction NOTHING moves.
func TestAReplayedCheckpointIsRefusedAndChangesNothing(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	room, hand := "room-dup", "hand-dup"

	if _, err := f.pack(room, hand, a, -400); err != nil {
		t.Fatal(err)
	}
	before := f.chips(a.ID)

	_, err := f.pack(room, hand, a, -400)
	if code := codeOf(t, err); code != game.CodeDuplicateAction {
		t.Fatalf("code = %s, want duplicate_action", code)
	}
	if err.Error() != "That move has already been applied" {
		t.Fatalf("message = %q", err.Error())
	}
	if got := f.chips(a.ID); got != before {
		t.Fatalf("wallet moved on a replay: %d → %d", before, got)
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE action_id = $1`, hand+":packed:"+a.ID); n != 1 {
		t.Fatalf("%d rows for the action id", n)
	}
	f.reconcile()
}

// THE PACKER IS WRITTEN TWICE AND CHARGED ONCE. Their money moves at the
// pack; the hand-end row has a delta of zero and carries the counters. Two
// distinct action ids, so both rows coexist and neither can be replayed.
func TestAPackerIsWrittenTwiceAndChargedOnce(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	room, hand := "room-two", "hand-two"
	const staked int64 = 25200

	if _, err := f.pack(room, hand, a, -staked); err != nil {
		t.Fatal(err)
	}
	afterPack := f.chips(a.ID)

	// The hand ends: b wins the pot, a's outcome row moves nothing.
	pot := staked * 2
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, a.ID, 0, false, true, 0),
		settleEntry(hand, b.ID, pot-staked, true, true, pot),
	}}); err != nil {
		t.Fatal(err)
	}

	if got := f.chips(a.ID); got != afterPack {
		t.Fatalf("the packer was charged again: %d → %d", afterPack, got)
	}
	if got := f.chips(b.ID); got != welcome+pot-staked {
		t.Fatalf("winner wallet = %d, want %d", got, welcome+pot-staked)
	}
	rows := f.handLedgerRows(hand)
	if len(rows) != 3 {
		t.Fatalf("%d rows, want 3 (pack, loss, win)", len(rows))
	}
	byReason := map[string]int{}
	for _, r := range rows {
		byReason[r.Reason]++
	}
	if byReason[game.LedgerReasonHandPacked] != 1 || byReason[game.LedgerReasonHandLoss] != 1 || byReason[game.LedgerReasonHandWin] != 1 {
		t.Fatalf("reasons %+v", byReason)
	}
	ua, ub := f.find(a.ID), f.find(b.ID)
	if ua.HandsLost != 1 || ua.HandsPlayed != 1 || ua.HandsWon != 0 {
		t.Fatalf("packer counters %+v", ua)
	}
	if ub.HandsWon != 1 || ub.HandsPlayed != 1 || ub.HandsLost != 0 || ub.TotalWinnings != pot || ub.BiggestPot != pot {
		t.Fatalf("winner counters %+v", ub)
	}
	f.reconcile()
}

// A DELTA, NEVER AN ABSOLUTE: a reward credited between two checkpoints
// survives the next one. This is the hole an absolute overwrite would open.
func TestARewardBetweenCheckpointsSurvives(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	room, hand := "room-reward", "hand-reward"

	if _, err := f.pack(room, hand, a, -400); err != nil {
		t.Fatal(err)
	}
	// The four-hour bonus lands (the REST handler refuses this while seated;
	// the money path must not depend on that gate).
	if _, err := f.users.ClaimTimedBonus(f.ctx, a.ID); err != nil {
		t.Fatal(err)
	}
	withReward := f.chips(a.ID)
	if withReward <= welcome-400 {
		t.Fatalf("the reward did not land: %d", withReward)
	}

	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, a.ID, 0, false, true, 0),
	}}); err != nil {
		t.Fatal(err)
	}
	if got := f.chips(a.ID); got != withReward {
		t.Fatalf("the checkpoint erased the reward: %d, want %d", got, withReward)
	}
	f.reconcile()
}

// ---------------------------------------------------------------- settle

func TestSettleWritesARowPerPlayerAndMovesTheCounters(t *testing.T) {
	f := newFixture(t)
	a, b, c := f.user("A"), f.user("B"), f.user("C")
	room, hand := "room-settle", "hand-settle"
	const staked int64 = 600
	pot := staked * 3

	entries := []game.SettleEntry{
		settleEntry(hand, a.ID, pot-staked, true, true, pot),
		settleEntry(hand, b.ID, -staked, false, true, 0),
		settleEntry(hand, c.ID, -staked, false, false, 0), // boot only: not "played"
	}
	balances, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand, Entries: entries})
	if err != nil {
		t.Fatal(err)
	}
	if len(balances) != 3 {
		t.Fatalf("balances %+v", balances)
	}
	if f.chips(a.ID) != welcome+pot-staked || f.chips(b.ID) != welcome-staked || f.chips(c.ID) != welcome-staked {
		t.Fatalf("wallets %d %d %d", f.chips(a.ID), f.chips(b.ID), f.chips(c.ID))
	}

	// Rows are written in ascending userId order (the wallet-lock order).
	rows := f.handLedgerRows(hand)
	if len(rows) != 3 {
		t.Fatalf("%d rows", len(rows))
	}
	ids := make([]string, len(rows))
	for i, r := range rows {
		ids[i] = r.UserID
		if r.ActionID == nil || *r.ActionID != hand+":settle:"+r.UserID {
			t.Fatalf("action id %v", r.ActionID)
		}
	}
	if !sort.StringsAreSorted(ids) {
		t.Fatalf("rows out of wallet-lock order: %v", ids)
	}

	ua, ub, uc := f.find(a.ID), f.find(b.ID), f.find(c.ID)
	if ua.HandsWon != 1 || ua.HandsPlayed != 1 || ua.TotalWinnings != pot || ua.BiggestPot != pot {
		t.Fatalf("winner %+v", ua)
	}
	if ub.HandsLost != 1 || ub.HandsPlayed != 1 {
		t.Fatalf("loser %+v", ub)
	}
	if uc.HandsLost != 1 || uc.HandsPlayed != 0 {
		t.Fatalf("boot-only player counts as played: %+v", uc)
	}
	f.reconcile()
}

// The settle retry is safe because the action ids are UNIQUE: a second
// attempt rolls back whole and comes out as duplicate_action, which the Table
// reads as the success it is.
func TestSettleIsIdempotent(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	room, hand := "room-idem", "hand-idem"
	req := game.SettleRequest{RoomID: room, HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, a.ID, 400, true, true, 800),
		settleEntry(hand, b.ID, -400, false, true, 0),
	}}
	if _, err := f.ledger.Settle(f.ctx, req); err != nil {
		t.Fatal(err)
	}
	chipsA, chipsB := f.chips(a.ID), f.chips(b.ID)
	wonA := f.find(a.ID).HandsWon

	_, err := f.ledger.Settle(f.ctx, req)
	if code := codeOf(t, err); code != game.CodeDuplicateAction {
		t.Fatalf("code = %s", code)
	}
	if f.chips(a.ID) != chipsA || f.chips(b.ID) != chipsB {
		t.Fatal("a retry moved the wallets again")
	}
	if f.find(a.ID).HandsWon != wonA {
		t.Fatal("a retry counted the win twice")
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE hand_id = $1`, hand); n != 2 {
		t.Fatalf("%d rows after the retry", n)
	}
	f.reconcile()
}

func TestSettleSkipsUnknownUsersAndReportsZeroBalancesAsPresent(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	room, hand := "room-gone", "hand-gone"
	balances, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, a.ID, -welcome, false, true, 0),
		settleEntry(hand, "nobody-at-all", -100, false, false, 0),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := balances["nobody-at-all"]; ok {
		t.Fatal("a deleted account must not report a balance")
	}
	v, ok := balances[a.ID]
	if !ok || v != 0 {
		t.Fatalf("a balance of exactly 0 must be present: %v %v", v, ok)
	}
	f.reconcile()
}

func TestSettleClampsTheBalanceAtZero(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	hand := "hand-clamp"
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "r", HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, a.ID, -(welcome * 10), false, true, 0),
	}}); err != nil {
		t.Fatal(err)
	}
	if got := f.chips(a.ID); got != 0 {
		t.Fatalf("wallet = %d, want 0", got)
	}
	// NB: the clamp is a tripwire, not a normal path — it is unreachable while
	// the wallet and chipsWritten agree, because delta = chips_now -
	// chips_written and chips_now is never negative. It is deliberately the
	// ONE place the reconciliation invariant can be broken, and breaking it
	// loudly beats letting the users.chips CHECK abort a settlement.
	if f.chips(a.ID) == f.ledgerSum(a.ID) {
		t.Fatal("this test is meant to exercise the clamp, which loses the difference")
	}
}

// ------------------------------------------------------------- property

// Randomised checkpoints keep every wallet equal to its ledger — the one
// money cross-check the system still has.
func TestRandomisedPlayKeepsEveryWalletEqualToItsLedger(t *testing.T) {
	f := newFixture(t)
	players := []*db.User{f.user("P1"), f.user("P2"), f.user("P3"), f.user("P4")}
	rng := rand.New(rand.NewSource(7))
	const boot int64 = 200

	for handNo := 1; handNo <= 30; handNo++ {
		hand := fmt.Sprintf("hand-%d", handNo)
		room := "room-rand"
		staked := map[string]int64{}
		var pot int64
		for _, p := range players {
			amount := boot + int64(rng.Intn(5))*boot
			if f.chips(p.ID) < amount {
				amount = boot
			}
			staked[p.ID] = amount
			pot += amount
		}

		// Some players pack (written at once); one may leave.
		resolved := map[string]bool{}
		for _, p := range players[1:] {
			switch rng.Intn(3) {
			case 0:
				if _, err := f.pack(room, hand, p, -staked[p.ID]); err != nil {
					t.Fatalf("pack: %v", err)
				}
			case 1:
				if _, err := f.left(room, hand, p, -staked[p.ID], true); err != nil {
					t.Fatalf("left: %v", err)
				}
				resolved[p.ID] = true
			}
		}

		entries := []game.SettleEntry{}
		winner := players[0]
		for _, p := range players {
			if resolved[p.ID] {
				continue // resolved at their own checkpoint
			}
			delta := -staked[p.ID]
			if p.ID == winner.ID {
				delta = pot - staked[p.ID]
			}
			// A packer's money already moved.
			if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE action_id = $1`, hand+":packed:"+p.ID); n > 0 {
				delta = 0
				if p.ID == winner.ID {
					delta = pot
				}
			}
			entries = append(entries, settleEntry(hand, p.ID, delta, p.ID == winner.ID, true, pot))
		}
		if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand, Entries: entries}); err != nil {
			t.Fatalf("settle %s: %v", hand, err)
		}
		f.reconcile()
	}

	for _, p := range players {
		if f.chips(p.ID) != f.ledgerSum(p.ID) {
			t.Fatalf("%s: wallet %d != ledger %d", p.DisplayName, f.chips(p.ID), f.ledgerSum(p.ID))
		}
	}
}

// ---------------------------------------------------------------- misc

func TestChipLedgerIsAppendOnly(t *testing.T) {
	f := newFixture(t)
	u := f.user("Immutable")
	var id int64
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT id FROM chip_ledger WHERE user_id = $1`, u.ID).Scan(&id); err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`UPDATE chip_ledger SET delta = 1 WHERE id = $1`,
		`DELETE FROM chip_ledger WHERE id = $1`,
	} {
		_, err := f.d.Pool.Exec(f.ctx, stmt, id)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || !strings.Contains(pgErr.Message, "chip_ledger is append-only") {
			t.Fatalf("%s: expected the append-only trigger, got %v", stmt, err)
		}
	}
	// The cascade from users cannot fire either (the trigger refuses it).
	if _, err := f.d.Pool.Exec(f.ctx, `DELETE FROM users WHERE id = $1`, u.ID); err == nil {
		t.Fatal("deleting a user with ledger rows must fail through the trigger")
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("ledger rows = %d", n)
	}
}

// ---------------------------------------------------------------- classify

func TestClassifyMapsErrorsLikeNode(t *testing.T) {
	if db.Classify(nil) != nil {
		t.Fatal("nil → nil")
	}
	// GameErrors pass through untouched, UserID included.
	in := &game.GameError{Code: game.CodeInsufficientChips, Message: "insufficient chips for u1", UserID: "u1"}
	if out := db.Classify(in); out != in {
		t.Fatal("GameError must pass through as-is")
	}
	wrapped := fmt.Errorf("context: %w", in)
	if out := db.Classify(wrapped); out.Code != game.CodeInsufficientChips || out.UserID != "u1" {
		t.Fatalf("wrapped GameError → %+v", out)
	}

	dup := &pgconn.PgError{Code: db.UniqueViolation, Detail: "Key (action_id)=(abc) already exists.", ConstraintName: "chip_ledger_action_id_key", Message: "duplicate key value violates unique constraint"}
	if out := db.Classify(dup); out.Code != game.CodeDuplicateAction || out.Message != "That move has already been applied" {
		t.Fatalf("action_id violation → %+v", out)
	}
	// Either field alone is enough.
	if out := db.Classify(&pgconn.PgError{Code: db.UniqueViolation, ConstraintName: "chip_ledger_action_id_key"}); out.Code != game.CodeDuplicateAction {
		t.Fatalf("constraint-only → %s", out.Code)
	}
	if out := db.Classify(&pgconn.PgError{Code: db.UniqueViolation, Detail: "Key (action_id)=(x) already exists."}); out.Code != game.CodeDuplicateAction {
		t.Fatalf("detail-only → %s", out.Code)
	}

	// A unique violation on any other constraint is persist_failed with the cause kept.
	other := &pgconn.PgError{Code: db.UniqueViolation, Detail: "Key (hand_id)=(h) already exists.", ConstraintName: "pots_pkey", Message: "duplicate key value violates unique constraint \"pots_pkey\""}
	out := db.Classify(other)
	if out.Code != game.CodePersistFailed || out.Message != other.Error() || !errors.Is(out, other) {
		t.Fatalf("pots_pkey violation → %+v", out)
	}
	var pgErr *pgconn.PgError
	if !errors.As(out, &pgErr) || pgErr != other {
		t.Fatal("Cause must be the original driver error")
	}
	// Non-unique errors and plain errors are persist_failed carrying their message.
	plain := errors.New("connection reset")
	if out := db.Classify(plain); out.Code != game.CodePersistFailed || out.Message != "connection reset" || out.Cause != plain {
		t.Fatalf("plain error → %+v", out)
	}
	// errors.Is on Code works for the Table's refusal mapping.
	if !errors.Is(db.Classify(plain), &game.GameError{Code: game.CodePersistFailed}) {
		t.Fatal("errors.Is by code failed")
	}
}

// ----------------------------------------------------------------- metrics

// The ledger feeds game_db_transaction_duration_seconds{op=checkpoint|settle},
// the settlement histogram, and counts refusals by code.
// (game_hand_start_duration_seconds is fed by the table now — the deal has no
// transaction of its own.)
func TestLedgerObservesTransactionMetrics(t *testing.T) {
	f := newFixture(t)
	reg := prometheus.NewRegistry()
	m := &metrics.Metrics{
		DBTransactionDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "game_db_transaction_duration_seconds"}, []string{"op"}),
		DBTransactionErrors:   prometheus.NewCounterVec(prometheus.CounterOpts{Name: "game_db_transaction_errors_total"}, []string{"op", "code"}),
		SettlementDuration:    prometheus.NewHistogram(prometheus.HistogramOpts{Name: "game_settlement_duration_seconds"}),
	}
	reg.MustRegister(m.DBTransactionDuration, m.DBTransactionErrors, m.SettlementDuration)
	ledger := db.NewLedger(f.d, m, nil)

	a, b := f.user("A"), f.user("B")
	room, hand := "room-metrics", "hand-metrics"
	cp := func(u *db.User, delta int64, actionID string) error {
		_, err := ledger.Checkpoint(f.ctx, game.CheckpointRequest{RoomID: room, HandID: hand,
			Entry: game.SettleEntry{UserID: u.ID, Delta: delta, Reason: game.LedgerReasonHandPacked, ActionID: actionID}})
		return err
	}
	if err := cp(a, -400, "m1"); err != nil {
		t.Fatal(err)
	}
	// One refusal inside a transaction: the same action id twice.
	_ = cp(a, -400, "m1")
	// And one for an account that does not exist.
	if _, err := ledger.Checkpoint(f.ctx, game.CheckpointRequest{RoomID: room, HandID: hand,
		Entry: game.SettleEntry{UserID: "nobody", Delta: -1, Reason: game.LedgerReasonHandPacked, ActionID: "m2"}}); err == nil {
		t.Fatal("an unknown account must be refused by Checkpoint")
	}
	if _, err := ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, a.ID, 800, true, true, 800),
		settleEntry(hand, b.ID, 0, false, true, 0),
	}}); err != nil {
		t.Fatal(err)
	}

	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	sampleCount := func(name string, labels map[string]string) uint64 {
		for _, fam := range families {
			if fam.GetName() != name {
				continue
			}
		metric:
			for _, mt := range fam.GetMetric() {
				for _, lp := range mt.GetLabel() {
					if labels[lp.GetName()] != lp.GetValue() {
						continue metric
					}
				}
				return mt.GetHistogram().GetSampleCount()
			}
		}
		return 0
	}
	if n := sampleCount("game_db_transaction_duration_seconds", map[string]string{"op": "checkpoint"}); n != 3 {
		t.Fatalf("checkpoint transactions observed = %d (every attempt, refused ones included)", n)
	}
	if n := sampleCount("game_db_transaction_duration_seconds", map[string]string{"op": "settle"}); n != 1 {
		t.Fatalf("settle transactions observed = %d", n)
	}
	if n := sampleCount("game_settlement_duration_seconds", nil); n != 1 {
		t.Fatalf("settlement observed = %d", n)
	}
	counter := func(name string, labels map[string]string) float64 {
		for _, fam := range families {
			if fam.GetName() != name {
				continue
			}
		metric:
			for _, mt := range fam.GetMetric() {
				for _, lp := range mt.GetLabel() {
					if labels[lp.GetName()] != lp.GetValue() {
						continue metric
					}
				}
				return mt.GetCounter().GetValue()
			}
		}
		return 0
	}
	for code, want := range map[string]float64{"duplicate_action": 1, "unknown_user": 1} {
		if got := counter("game_db_transaction_errors_total", map[string]string{"op": "checkpoint", "code": code}); got != want {
			t.Fatalf("errors{op=checkpoint,code=%s} = %v, want %v", code, got, want)
		}
	}
	if got := counter("game_db_transaction_errors_total", map[string]string{"op": "settle", "code": "duplicate_action"}); got != 0 {
		t.Fatalf("unexpected settle errors: %v", got)
	}
}

// A player who leaves mid-hand is resolved at their OWN checkpoint and must
// not be written again at the hand end: one wallet movement, one outcome row,
// hands_left_mid counted once.
func TestAPlayerWhoLeavesMidHandIsResolvedOnce(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	room, hand := "room-leave", "hand-leave"
	const aStaked, bStaked int64 = 1400, 600
	pot := aStaked + bStaked

	if _, err := f.left(room, hand, a, -aStaked, true); err != nil {
		t.Fatal(err)
	}
	walletAfterLeave := f.chips(a.ID)
	if walletAfterLeave != welcome-aStaked {
		t.Fatalf("wallet after the leave = %d", walletAfterLeave)
	}

	// The hand settles with only the player still at the table.
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, b.ID, pot-bStaked, true, true, pot),
	}}); err != nil {
		t.Fatal(err)
	}

	if got := f.chips(a.ID); got != walletAfterLeave {
		t.Fatalf("the departed player was charged again: %d → %d", walletAfterLeave, got)
	}
	if got := f.chips(b.ID); got != welcome+pot-bStaked {
		t.Fatalf("winner wallet = %d, want %d", got, welcome+pot-bStaked)
	}
	rows := f.handLedgerRows(hand)
	if len(rows) != 2 {
		t.Fatalf("%d rows, want 2 (the leave and the win)", len(rows))
	}
	ua := f.find(a.ID)
	if ua.HandsLeftMid != 1 || ua.HandsLost != 0 || ua.HandsPlayed != 1 {
		t.Fatalf("leaver counters %+v", ua)
	}
	f.reconcile()
}
