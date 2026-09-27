package db_test

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/testclock"
)

// A mid-hand leave the ledger REFUSED is caught up by the hand-end settle
// (game.Table.endHand; review of 27 Sep 2026): the leaver's stake rides the
// settle as a hand_loss row under the settle's action id — their OUTCOME when
// the refused leave counted nothing (Outcome true), money only after a replay
// (Outcome false). Here is that request against PostgreSQL, both ways: the
// stake leaves the leaver's wallet once, the hand's hand_* rows sum to zero
// beside the winner's gross win and table tax, the ledger writes no
// statistics (Player stats v2: the table records the catch-up's counters once
// the settle has committed) and no XP window opens for the leaver, every
// wallet equals its ledger — and the settle's retry is as safe as ever: a
// replay is duplicate_action and writes nothing.
func TestARefusedLeaveIsCaughtUpByTheSettle(t *testing.T) {
	for _, outcome := range []bool{true, false} {
		name := "money only after a replay"
		if outcome {
			name = "the outcome of a leave that counted nothing"
		}
		t.Run(name, func(t *testing.T) { refusedLeaveCaughtUp(t, outcome) })
	}
}

func refusedLeaveCaughtUp(t *testing.T, outcome bool) {
	f := newFixture(t)
	seen := &settledHands{}
	f.ledger.OnSettled(seen.hook)
	winner, leaver := f.user("Stayed"), f.user("Walked")
	room, hand := "room-refused-leave", "hand-refused-leave-"+randomSuffix(t)
	const winnerStaked, leaverStaked, tax int64 = 600, 1400, 280
	pot := winnerStaked + leaverStaked

	// The leaver's hand_left checkpoint was refused: nothing reached their
	// wallet, so the table's chipsWritten for them is still where the deal
	// left it and the hand end carries the whole stake.
	win := settleEntry(hand, winner.ID, pot-winnerStaked-tax, true, true, pot)
	win.Tax = tax
	catchUp := game.SettleEntry{
		UserID: leaver.ID, Delta: -leaverStaked,
		ActionID: game.SettleActionID(hand, leaver.ID), Reason: game.LedgerReasonHandLoss,
		Outcome: outcome, DidChaal: true, LeftMidHand: true,
	}
	req := game.SettleRequest{RoomID: room, HandID: hand, PlayedMs: 30_000, Entries: []game.SettleEntry{win, catchUp}}
	if _, err := f.ledger.Settle(f.ctx, req); err != nil {
		t.Fatal(err)
	}

	if got := f.chips(leaver.ID); got != welcome-leaverStaked {
		t.Fatalf("leaver wallet = %d, want %d: the stake must leave it once", got, welcome-leaverStaked)
	}
	if got := f.chips(winner.ID); got != welcome+pot-winnerStaked-tax {
		t.Fatalf("winner wallet = %d, want %d", got, welcome+pot-winnerStaked-tax)
	}
	var leaverRows []ledgerRow
	var handSum int64
	for _, r := range f.handLedgerRows(hand) {
		if r.Reason != "table_tax" {
			handSum += r.Delta
		}
		if r.UserID == leaver.ID {
			leaverRows = append(leaverRows, r)
		}
	}
	if handSum != 0 {
		t.Fatalf("the hand's hand_* rows sum to %d, want 0", handSum)
	}
	if len(leaverRows) != 1 || leaverRows[0].Reason != game.LedgerReasonHandLoss ||
		leaverRows[0].ActionID == nil || *leaverRows[0].ActionID != game.SettleActionID(hand, leaver.ID) {
		t.Fatalf("leaver rows %+v: want one hand_loss under the settle's action id", leaverRows)
	}
	if n := f.statsRows(leaver.ID); n != 0 {
		t.Fatalf("the settle wrote %d statistics rows for the leaver: the ledger writes money only", n)
	}
	// What the table records once this settle has committed: a departure,
	// counted once, when the row is their outcome; nothing after a replay.
	counted, ok := game.StatsForEntry(catchUp, game.StatsTeenPatti)
	if ok != outcome {
		t.Fatalf("StatsForEntry ok=%v for an Outcome=%v catch-up", ok, outcome)
	}
	if outcome && counted != (game.HandStats{UserID: leaver.ID, Bucket: game.StatsTeenPatti, Played: 1, Left: 1}) {
		t.Fatalf("the catch-up counts %+v, want left and played", counted)
	}
	u := f.find(leaver.ID)
	if u.PlayerLevel.XP != 0 {
		t.Fatalf("the catch-up row earned %d XP", u.PlayerLevel.XP)
	}
	if n := f.count(`SELECT count(*) FROM player_xp WHERE user_id = $1 AND window_start > 0`, winner.ID); n != 1 {
		t.Fatal("the winner's XP window is not open: the settle's XP did not run, so the next check proves nothing")
	}
	if n := f.count(`SELECT count(*) FROM player_xp WHERE user_id = $1 AND window_start > 0`, leaver.ID); n != 0 {
		t.Fatal("the leaver's XP window was opened: they did not complete the hand")
	}
	for _, h := range seen.all() {
		for _, id := range h.Players {
			if id == leaver.ID {
				t.Fatal("the settle counted the leaver as having completed the hand")
			}
		}
	}
	f.reconcile()

	// The Settler's retry re-sends the request unchanged: one spent id rolls it
	// all back, and nothing moves a second time.
	if _, err := f.ledger.Settle(f.ctx, req); codeOf(t, err) != game.CodeDuplicateAction {
		t.Fatalf("a replayed settle must be duplicate_action, got %v", err)
	}
	if got := f.chips(leaver.ID); got != welcome-leaverStaked {
		t.Fatalf("the replay moved the leaver's wallet to %d", got)
	}
	f.reconcile()
}

// A replayed checkpoint (a restored hand repeating a pack or leave whose
// first write had landed) is refused by the UNIQUE action id and moves
// nothing — and the refusal says what the first write moved, which is what
// the table advances chipsWritten by (game.Table.checkpoint): exactly that,
// whatever the replay itself would have written, so a player who bet again
// before the replay still owes the difference at the hand end.
func TestAReplayedLeaveCheckpointIsRefusedAndSaysWhatLanded(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	room, hand := "room-left-dup", "hand-left-dup-"+randomSuffix(t)
	if _, err := f.left(room, hand, a, -800, true); err != nil {
		t.Fatal(err)
	}
	before := f.chips(a.ID)
	for _, replay := range []int64{-800, -1_000} {
		_, err := f.left(room, hand, a, replay, true)
		if codeOf(t, err) != game.CodeDuplicateAction {
			t.Fatalf("a replayed leave must be duplicate_action, got %v", err)
		}
		landed, ok := game.LandedDelta(err)
		if !ok || landed != -800 {
			t.Fatalf("the replay of %d says landed=%d ok=%v; want -800, what the first write moved", replay, landed, ok)
		}
	}
	if got := f.chips(a.ID); got != before {
		t.Fatalf("the replay moved the wallet: %d → %d", before, got)
	}
	if n := f.statsRows(a.ID); n != 0 {
		t.Fatalf("a leave checkpoint (or its replay) wrote %d statistics rows: the ledger writes money only", n)
	}
	f.reconcile()
}

// The money audits' rule for a leaver, held here on real books. These are the
// queries of tools/parity/money.test.js ("every hand conserves chips, and
// resolves each player exactly once" and the counters test's "Nobody is
// credited a loss and a departure") and tools/crashtest.mjs doubleClosed —
// keep them together. A hand_loss under the settle's id beside the same
// player's hand_left row of the same hand is that leave's CATCH-UP (money
// the leave did not bank), one resolution with it, and always moves chips.
const (
	auditResolvedTwice = `SELECT count(*) FROM (SELECT hand_id, user_id FROM chip_ledger c
	  WHERE reason IN ('hand_win', 'hand_loss', 'hand_left')
	    AND NOT (reason = 'hand_loss' AND EXISTS (
	          SELECT 1 FROM chip_ledger l
	           WHERE l.hand_id = c.hand_id AND l.user_id = c.user_id AND l.reason = 'hand_left'))
	  GROUP BY hand_id, user_id HAVING COUNT(*) > 1) x`
	auditLostAndLeft = `SELECT count(*) FROM chip_ledger c
	  WHERE c.reason = 'hand_loss' AND c.delta = 0 AND EXISTS (
	        SELECT 1 FROM chip_ledger l
	         WHERE l.hand_id = c.hand_id AND l.user_id = c.user_id AND l.reason = 'hand_left')`
	auditDoubleClosed = `SELECT count(*) FROM (SELECT hand_id, user_id FROM chip_ledger c
	  WHERE reason IN ('hand_win','hand_loss','hand_left')
	    AND NOT (reason = 'hand_loss' AND delta <> 0 AND EXISTS (
	          SELECT 1 FROM chip_ledger l
	           WHERE l.hand_id = c.hand_id AND l.user_id = c.user_id AND l.reason = 'hand_left'))
	  GROUP BY hand_id, user_id HAVING count(*) > 1) x`
)

// A real game.Table on the real ledger: a player's leave LANDS, the process
// stops before the live store records it, the hand is restored from the save
// before the leave, and the restored player chaals once more before leaving
// again. The replay is refused duplicate_action with what landed, and the
// chaal the earlier life never saw rides the hand end as the leave's
// catch-up. The books then hold two rows for the leaver in one hand — the
// hand_left and its catch-up — which balance, and which the audits read as one
// resolution (before they learnt the catch-up, both flagged these books as a
// player resolved twice).
func TestAReplayedLeaveAndItsCatchUpPassTheMoneyAudits(t *testing.T) {
	f := newFixture(t)
	a, b, c := f.user("PA"), f.user("PB"), f.user("PC")
	cfg := game.TableConfig{
		Category: game.CategorySeen, BootAmount: 100, MaxPlayers: 5, MinPlayers: 2,
		TurnTimeout: 25 * time.Second, MaxBetRounds: 20, PotLimitMultiplier: 1024, MaxRaiseSteps: 8,
		NextHandDelay: 6 * time.Second, ChatMaxHistory: 100, ChatMaxLength: 140,
	}
	clock := testclock.New(time.UnixMilli(1_700_000_000_000))
	table := game.NewTable(game.TableOptions{ID: "room-replayed-leave-" + randomSuffix(t), Code: "REPLAY01", Config: cfg,
		Ledger: f.ledger, Clock: clock, Listener: game.NopListener{}, Live: livetest.New()})
	for _, u := range []string{a.ID, b.ID, c.ID} {
		if _, err := table.AddPlayer(game.NewPlayer{UserID: u, DisplayName: u[:6], Chips: welcome, SocketID: "s-" + u}); err != nil {
			t.Fatal(err)
		}
	}
	clock.Advance(cfg.NextHandDelay)
	if !table.HasHand() {
		t.Fatal("no hand dealt")
	}
	turn := func(tb *game.Table) string {
		t.Helper()
		for _, u := range []string{a.ID, b.ID, c.ID} {
			v, err := tb.SerializeFor(u)
			if err != nil {
				continue
			}
			if v.Turn != nil && v.Turn.UserID != nil {
				return *v.Turn.UserID
			}
		}
		return ""
	}
	quitter := turn(table)
	if _, err := table.Act(quitter, game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatal(err)
	}
	snap, err := table.Snapshot() // the last save the process made
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	var before game.Snapshot
	if err := json.Unmarshal(data, &before); err != nil {
		t.Fatal(err)
	}
	hand := before.Hand.ID
	if _, err := table.RemovePlayer(quitter, game.LeaveReasonLeft); err != nil { // the leave LANDS
		t.Fatal(err)
	}
	if err := table.Suspend(); err != nil { // the process stops; its last save is `before`
		t.Fatal(err)
	}

	restored, err := game.RestoreTable(&before, game.TableOptions{Ledger: f.ledger, Clock: clock, Listener: game.NopListener{}, Live: livetest.New()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = restored.Destroy() })
	for i := 0; i < 6 && turn(restored) != quitter; i++ {
		if _, err := restored.Act(turn(restored), game.ActionChaal, game.ActRequest{}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := restored.Act(quitter, game.ActionChaal, game.ActRequest{}); err != nil { // the earlier life never saw this
		t.Fatal(err)
	}
	if _, err := restored.RemovePlayer(quitter, game.LeaveReasonDisconnected); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 6 && restored.HasHand(); i++ {
		if _, err := restored.Act(turn(restored), game.ActionPack, game.ActRequest{}); err != nil {
			t.Fatal(err)
		}
	}
	if restored.HasHand() {
		t.Fatal("the restored hand did not end")
	}

	var net int64
	var mine []ledgerRow
	for _, r := range f.handLedgerRows(hand) {
		if r.Reason != game.LedgerReasonTableTax {
			net += r.Delta
		}
		if r.UserID == quitter {
			mine = append(mine, r)
		}
	}
	if len(mine) != 2 || mine[0].Reason != game.LedgerReasonHandLeft || mine[1].Reason != game.LedgerReasonHandLoss ||
		mine[1].ActionID == nil || *mine[1].ActionID != game.SettleActionID(hand, quitter) || mine[1].Delta == 0 {
		t.Fatalf("the leaver's rows are %+v, want their hand_left and a catch-up under the settle's id", mine)
	}
	if net != 0 {
		t.Fatalf("the hand's hand_* rows sum to %d, want 0", net)
	}
	f.reconcile()
	if n := f.count(auditResolvedTwice); n != 0 {
		t.Fatalf("money.test.js: %d player(s) resolved twice in one hand", n)
	}
	if n := f.count(auditLostAndLeft); n != 0 {
		t.Fatalf("money.test.js: %d player(s) both lost and left in one hand", n)
	}
	if n := f.count(auditDoubleClosed); n != 0 {
		t.Fatalf("crashtest.mjs: %d player(s) resolved twice in one hand", n)
	}
}
