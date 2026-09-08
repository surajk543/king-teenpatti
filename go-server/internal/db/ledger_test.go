package db_test

import (
	"encoding/json"
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

// ------------------------------------------------------------------ bet

func TestBetDebitsTheWalletGrowsThePotAndWritesTheLedger(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	room, hand := "room-bet", "hand-bet-1"
	f.boot(room, hand, 200, a, b)

	res, err := f.ledger.Bet(f.ctx, game.BetRequest{
		UserID: a.ID, Amount: 400, RoomID: room, HandID: hand, ActionID: "client-uuid-1",
		Reason: game.LedgerReasonBet, BalanceBefore: welcome - 200,
	})
	if err != nil {
		t.Fatalf("bet: %v", err)
	}
	if res.Balance != welcome-200-400 || res.Persisted != 400 {
		t.Fatalf("result = %+v", res)
	}
	if got := f.chips(a.ID); got != welcome-600 {
		t.Fatalf("wallet = %d", got)
	}
	if pot := f.scalar(`SELECT amount FROM pots WHERE hand_id = $1`, hand); pot != 800 {
		t.Fatalf("pot = %d, want 800", pot)
	}
	rows := f.ledgerRows(a.ID)
	last := rows[len(rows)-1]
	if last.Delta != -400 || last.Balance != welcome-600 || last.Reason != "bet" || last.ActionID == nil || *last.ActionID != "client-uuid-1" || last.HandID == nil || *last.HandID != hand {
		t.Fatalf("ledger row = %+v", last)
	}
	// The money transaction touches nothing but users, pots and chip_ledger
	// (the snapshot lives in the live store now; LIVE_STATE_PLAN.md).
	// Every row of one transaction shares one timestamp.
	updatedAt := f.scalar(`SELECT updated_at FROM users WHERE id = $1`, a.ID)
	if last.Created != updatedAt {
		t.Fatalf("ledger created_at %d != users.updated_at %d", last.Created, updatedAt)
	}
	f.reconcile()
}

func TestBetShowReasonIsWrittenVerbatim(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	f.boot("room-show", "hand-show", 200, a, b)
	if _, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: b.ID, Amount: 400, RoomID: "room-show", HandID: "hand-show",
		ActionID: "show-1", Reason: game.LedgerReasonShow}); err != nil {
		t.Fatal(err)
	}
	rows := f.ledgerRows(b.ID)
	if rows[len(rows)-1].Reason != "show" {
		t.Fatalf("reason = %q", rows[len(rows)-1].Reason)
	}
	// An empty reason falls back to Node's default parameter 'bet'.
	if _, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: b.ID, Amount: 400, RoomID: "room-show", HandID: "hand-show",
		ActionID: "bet-default"}); err != nil {
		t.Fatal(err)
	}
	rows = f.ledgerRows(b.ID)
	if rows[len(rows)-1].Reason != "bet" {
		t.Fatalf("default reason = %q", rows[len(rows)-1].Reason)
	}
}

// A retried request carries the same actionId; the UNIQUE index refuses the
// second insert and — because the wallet UPDATE is in the same transaction —
// nobody is charged twice (invalidMoves.test.js "replaying a move…").
func TestBetWithADuplicateActionIDIsRefusedAndChargesNobody(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	room, hand := "room-dup", "hand-dup"
	f.boot(room, hand, 200, a, b)

	req := game.BetRequest{UserID: a.ID, Amount: 400, RoomID: room, HandID: hand, ActionID: "dup-same-id"}
	if _, err := f.ledger.Bet(f.ctx, req); err != nil {
		t.Fatal(err)
	}
	before := f.chips(a.ID)

	_, err := f.ledger.Bet(f.ctx, req)
	if code := codeOf(t, err); code != game.CodeDuplicateAction {
		t.Fatalf("code = %s, want duplicate_action", code)
	}
	if err.Error() != "That move has already been applied" {
		t.Fatalf("message = %q", err.Error())
	}
	if got := f.chips(a.ID); got != before {
		t.Fatalf("wallet moved on a duplicate: %d → %d", before, got)
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE action_id = $1`, "dup-same-id"); n != 1 {
		t.Fatalf("expected one row for the action id, got %d", n)
	}
	if pot := f.scalar(`SELECT amount FROM pots WHERE hand_id = $1`, hand); pot != 800 {
		t.Fatalf("pot moved on a duplicate: %d", pot)
	}
	f.reconcile()
}

func TestBetWithInsufficientChipsLeavesNoRows(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	room, hand := "room-poor", "hand-poor"
	f.boot(room, hand, 200, a, b)
	before := f.chips(a.ID)

	_, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: a.ID, Amount: before + 1, RoomID: room, HandID: hand, ActionID: "too-much"})
	if code := codeOf(t, err); code != game.CodeInsufficientChips {
		t.Fatalf("code = %s", code)
	}
	if got := f.chips(a.ID); got != before {
		t.Fatalf("wallet moved: %d", got)
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE action_id = 'too-much'`); n != 0 {
		t.Fatal("refused bet left a ledger row")
	}
	if pot := f.scalar(`SELECT amount FROM pots WHERE hand_id = $1`, hand); pot != 400 {
		t.Fatalf("pot = %d", pot)
	}
	// Exactly the balance is allowed (chips < amount is the refusal).
	if _, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: a.ID, Amount: before, RoomID: room, HandID: hand, ActionID: "all-in"}); err != nil {
		t.Fatalf("all-in refused: %v", err)
	}
	if got := f.chips(a.ID); got != 0 {
		t.Fatalf("all-in left %d", got)
	}
	f.reconcile()
}

func TestBetValidationErrorsAndCodes(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")

	for _, amount := range []int64{0, -1} {
		_, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: a.ID, Amount: amount, RoomID: "r", HandID: "h", ActionID: "x"})
		if code := codeOf(t, err); code != game.CodeInvalidAmount {
			t.Fatalf("amount %d: code = %s", amount, code)
		}
	}
	_, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: "nobody", Amount: 100, RoomID: "r", HandID: "h", ActionID: "x"})
	if code := codeOf(t, err); code != game.CodeUnknownUser {
		t.Fatalf("unknown user: code = %s", code)
	}
	// No pot row for the hand → no_pot, wallet untouched.
	_, err = f.ledger.Bet(f.ctx, game.BetRequest{UserID: a.ID, Amount: 100, RoomID: "r", HandID: "no-such-hand", ActionID: "x"})
	if code := codeOf(t, err); code != game.CodeNoPot {
		t.Fatalf("no pot: code = %s", code)
	}
	if got := f.chips(a.ID); got != welcome {
		t.Fatalf("wallet moved on no_pot: %d", got)
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1`, a.ID); n != 1 {
		t.Fatalf("expected only the welcome row, got %d", n)
	}
	f.reconcile()
}

// ------------------------------------------------------------ collectBoot

func TestCollectBootTakesEveryBootOpensThePotAndOrdersRowsByUserID(t *testing.T) {
	f := newFixture(t)
	users := []*db.User{f.user("P1"), f.user("P2"), f.user("P3")}
	room, hand := "room-boot", "hand-boot"

	// Hand the entries over in reverse id order to prove the ledger sorts.
	sorted := append([]*db.User(nil), users...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].ID < sorted[j].ID })
	reversed := append([]*db.User(nil), sorted...)
	for i, j := 0, len(reversed)-1; i < j; i, j = i+1, j-1 {
		reversed[i], reversed[j] = reversed[j], reversed[i]
	}
	res := f.boot(room, hand, 200, reversed...)

	if res.Persisted != 200 {
		t.Fatalf("persisted = %d", res.Persisted)
	}
	if len(res.Balances) != 3 {
		t.Fatalf("balances = %v", res.Balances)
	}
	for _, u := range users {
		if res.Balances[u.ID] != welcome-200 || f.chips(u.ID) != welcome-200 {
			t.Fatalf("user %s: balance %d wallet %d", u.ID, res.Balances[u.ID], f.chips(u.ID))
		}
	}

	var potRoom string
	var bootAmount, amount int64
	var winner *string
	var closedAt *int64
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT room_id, boot_amount, amount, winner_id, closed_at FROM pots WHERE hand_id = $1`, hand).
		Scan(&potRoom, &bootAmount, &amount, &winner, &closedAt); err != nil {
		t.Fatal(err)
	}
	if potRoom != room || bootAmount != 200 || amount != 600 || winner != nil || closedAt != nil {
		t.Fatalf("pot row = %s %d %d %v %v", potRoom, bootAmount, amount, winner, closedAt)
	}

	rows := f.handLedgerRows(hand)
	if len(rows) != 3 {
		t.Fatalf("expected 3 boot rows, got %d", len(rows))
	}
	for i, r := range rows {
		want := sorted[i]
		if r.UserID != want.ID {
			t.Fatalf("row %d is for %s, want ascending user id order (%s)", i, r.UserID, want.ID)
		}
		if r.Reason != "boot" || r.Delta != -200 || r.Balance != welcome-200 || r.ActionID == nil || *r.ActionID != game.BootActionID(hand, want.ID) {
			t.Fatalf("row %d = %+v", i, r)
		}
		if r.Created != rows[0].Created {
			t.Fatal("boot rows of one transaction carry different timestamps")
		}
	}
	f.reconcile()
}

// One unfunded player refuses the whole start: no wallet moves, no pot, no
// ledger rows, no state — and the error names the offender so the table can
// show them out instead of retrying forever.
func TestCollectBootIsAllOrNothingAndNamesTheUnfundedPlayer(t *testing.T) {
	f := newFixture(t)
	rich, poor, other := f.user("Rich"), f.user("Poor"), f.user("Other")
	if _, err := f.users.ApplyChipDelta(f.ctx, poor.ID, -(welcome - 150), "test_fixture", "", "poor-fixture"); err != nil {
		t.Fatal(err)
	}

	_, err := f.ledger.CollectBoot(f.ctx, game.CollectBootRequest{
		RoomID: "room-short", HandID: "hand-short", BootAmount: 200,
		Entries: []game.BootEntry{{UserID: rich.ID, Amount: 200}, {UserID: poor.ID, Amount: 200}, {UserID: other.ID, Amount: 200}},
	})
	var ge *game.GameError
	if !errors.As(err, &ge) {
		t.Fatalf("expected a GameError, got %v", err)
	}
	if ge.Code != game.CodeInsufficientChips || ge.UserID != poor.ID {
		t.Fatalf("code=%s userId=%s, want insufficient_chips for %s", ge.Code, ge.UserID, poor.ID)
	}
	for _, u := range []*db.User{rich, other} {
		if got := f.chips(u.ID); got != welcome {
			t.Fatalf("%s charged despite the refusal: %d", u.DisplayName, got)
		}
	}
	if got := f.chips(poor.ID); got != 150 {
		t.Fatalf("poor = %d", got)
	}
	if n := f.count(`SELECT COUNT(*) FROM pots WHERE hand_id = 'hand-short'`); n != 0 {
		t.Fatal("pot row written despite the refusal")
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE hand_id = 'hand-short'`); n != 0 {
		t.Fatal("ledger rows written despite the refusal")
	}
	f.reconcile()
}

// A second boot for the same hand id hits pots_pkey — a unique violation that
// is NOT about action_id, so it is persist_failed, not duplicate_action.
func TestCollectBootTwiceForOneHandIsPersistFailed(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	f.boot("room-twice", "hand-twice", 200, a, b)
	before := f.chips(a.ID)

	_, err := f.ledger.CollectBoot(f.ctx, game.CollectBootRequest{
		RoomID: "room-twice", HandID: "hand-twice", BootAmount: 200,
		Entries: []game.BootEntry{{UserID: a.ID, Amount: 200}, {UserID: b.ID, Amount: 200}},
	})
	var ge *game.GameError
	if !errors.As(err, &ge) || ge.Code != game.CodePersistFailed {
		t.Fatalf("expected persist_failed, got %v", err)
	}
	var pgErr *pgconn.PgError
	if !errors.As(ge.Cause, &pgErr) || pgErr.Code != db.UniqueViolation {
		t.Fatalf("cause should be the unique violation, got %v", ge.Cause)
	}
	if got := f.chips(a.ID); got != before {
		t.Fatalf("wallet moved: %d → %d", before, got)
	}
	f.reconcile()
}

func TestCollectBootUnknownUserRefusesTheStart(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	_, err := f.ledger.CollectBoot(f.ctx, game.CollectBootRequest{
		RoomID: "r", HandID: "h-unknown", BootAmount: 200,
		Entries: []game.BootEntry{{UserID: a.ID, Amount: 200}, {UserID: "zzz-ghost", Amount: 200}},
	})
	if code := codeOf(t, err); code != game.CodeUnknownUser {
		t.Fatalf("code = %s", code)
	}
	if got := f.chips(a.ID); got != welcome {
		t.Fatalf("wallet moved: %d", got)
	}
}

// ------------------------------------------------------------------ settle

// The full money path of one hand: boots, bets, settlement. Production
// deltas are payout-only (winner +pot, losers 0) because every stake was
// already banked as it was bet.
func TestSettlePaysTheWinnerWritesEveryRowAndClosesThePot(t *testing.T) {
	f := newFixture(t)
	w, l1, l2 := f.user("Winner"), f.user("Loser"), f.user("Quitter")
	room, hand := "room-settle", "hand-settle"
	f.boot(room, hand, 200, w, l1, l2)
	bet := func(u *db.User, amount int64, id string) {
		if _, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: u.ID, Amount: amount, RoomID: room, HandID: hand, ActionID: id}); err != nil {
			t.Fatalf("bet %s: %v", id, err)
		}
	}
	bet(w, 400, "b1")
	bet(l1, 400, "b2")
	bet(w, 400, "b3")
	pot := int64(600 + 1200)

	record := game.HandRecord{
		ID: hand, RoomID: room, HandNo: 1, Pot: pot, WinnerID: ptr(w.ID), WinReason: game.WinReason("show"),
		BootAmount: 200, StartedAt: nowMs() - 1000, EndedAt: nowMs(),
		Summary: []game.HandSummaryEntry{
			{UserID: w.ID, DisplayName: "Winner", SeatIndex: 0, Contributed: 1000, Status: game.SeatWon, SawCards: true, Cards: []string{"As", "Ah", "Ad"}},
			{UserID: l1.ID, DisplayName: "Loser", SeatIndex: 1, Contributed: 600, Status: game.SeatLost, SawCards: true, Cards: []string{"2s", "3h", "9d"}},
			{UserID: l2.ID, DisplayName: "Quitter", SeatIndex: 2, Contributed: 200, Status: game.SeatPacked, SawCards: false, Cards: nil},
		},
	}
	balances, err := f.ledger.Settle(f.ctx, game.SettleRequest{
		Hand: record,
		Entries: []game.SettleEntry{
			{UserID: w.ID, Delta: pot, IsWinner: true, DidChaal: true},
			{UserID: l1.ID, Delta: 0, DidChaal: true},
			{UserID: l2.ID, Delta: 0, DidChaal: false, LeftMidHand: true},
		},
	})
	if err != nil {
		t.Fatalf("settle: %v", err)
	}
	if len(balances) != 3 || balances[w.ID] != welcome-1000+pot || balances[l1.ID] != welcome-600 || balances[l2.ID] != welcome-200 {
		t.Fatalf("balances = %v", balances)
	}

	wu, l1u, l2u := f.find(w.ID), f.find(l1.ID), f.find(l2.ID)
	if wu.Chips != welcome-1000+pot || wu.HandsPlayed != 1 || wu.HandsWon != 1 || wu.HandsLost != 0 || wu.HandsLeftMid != 0 || wu.TotalWinnings != pot || wu.BiggestPot != pot {
		t.Fatalf("winner = %+v", wu)
	}
	if l1u.HandsPlayed != 1 || l1u.HandsWon != 0 || l1u.HandsLost != 1 || l1u.HandsLeftMid != 0 || l1u.TotalWinnings != 0 || l1u.BiggestPot != 0 {
		t.Fatalf("loser = %+v", l1u)
	}
	// A mid-hand leaver: left_mid, not lost, and not played (no chaal).
	if l2u.HandsPlayed != 0 || l2u.HandsLost != 0 || l2u.HandsLeftMid != 1 {
		t.Fatalf("quitter = %+v", l2u)
	}

	// Settlement rows: one per contributor, ascending user id, zero deltas
	// included, reasons hand_win / hand_loss (the leaver too).
	rows := f.handLedgerRows(hand)
	var settleRows []ledgerRow
	for _, r := range rows {
		if r.Reason == "hand_win" || r.Reason == "hand_loss" {
			settleRows = append(settleRows, r)
		}
	}
	if len(settleRows) != 3 {
		t.Fatalf("expected 3 settlement rows, got %d", len(settleRows))
	}
	ids := []string{w.ID, l1.ID, l2.ID}
	sort.Strings(ids)
	for i, r := range settleRows {
		if r.UserID != ids[i] {
			t.Fatalf("settlement row %d for %s, want %s (ascending)", i, r.UserID, ids[i])
		}
		if r.ActionID == nil || *r.ActionID != game.SettleActionID(hand, r.UserID) {
			t.Fatalf("settlement row action id = %v", r.ActionID)
		}
		wantReason := "hand_loss"
		if r.UserID == w.ID {
			wantReason = "hand_win"
			if r.Delta != pot {
				t.Fatalf("winner delta = %d", r.Delta)
			}
		} else if r.Delta != 0 {
			t.Fatalf("loser delta = %d, want 0 (already banked)", r.Delta)
		}
		if r.Reason != wantReason {
			t.Fatalf("row %d reason = %s, want %s", i, r.Reason, wantReason)
		}
	}

	// hands row.
	var hRoom string
	var hNo int
	var hPot, hBoot, hStarted, hEnded int64
	var hWinner, hReason *string
	var summaryJSON []byte
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT room_id, hand_no, pot, winner_id, win_reason, boot_amount, started_at, ended_at, summary_json FROM hands WHERE id = $1`, hand).
		Scan(&hRoom, &hNo, &hPot, &hWinner, &hReason, &hBoot, &hStarted, &hEnded, &summaryJSON); err != nil {
		t.Fatal(err)
	}
	if hRoom != room || hNo != 1 || hPot != pot || hWinner == nil || *hWinner != w.ID || hReason == nil || *hReason != "show" || hBoot != 200 || hStarted != record.StartedAt || hEnded != record.EndedAt {
		t.Fatalf("hands row = %s %d %d %v %v %d %d %d", hRoom, hNo, hPot, hWinner, hReason, hBoot, hStarted, hEnded)
	}
	var summary []game.HandSummaryEntry
	if err := json.Unmarshal(summaryJSON, &summary); err != nil {
		t.Fatal(err)
	}
	if len(summary) != 3 || summary[0].Cards[0] != "As" || summary[2].Cards != nil {
		t.Fatalf("summary = %s", summaryJSON)
	}
	// cards: null (not []) for the unrevealed player.
	if !strings.Contains(string(summaryJSON), `"cards": null`) && !strings.Contains(string(summaryJSON), `"cards":null`) {
		t.Fatalf("unrevealed cards must be JSON null: %s", summaryJSON)
	}

	// Pot closed with the winner; amount unchanged.
	var closedAt *int64
	var potWinner *string
	var potAmount int64
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT closed_at, winner_id, amount FROM pots WHERE hand_id = $1`, hand).Scan(&closedAt, &potWinner, &potAmount); err != nil {
		t.Fatal(err)
	}
	if closedAt == nil || potWinner == nil || *potWinner != w.ID || potAmount != pot {
		t.Fatalf("pot after settle = %v %v %d", closedAt, potWinner, potAmount)
	}
	// Pot invariants: stakes in == pot == winnings out.
	staked := -f.scalar(`SELECT SUM(delta)::bigint FROM chip_ledger WHERE hand_id = $1 AND reason IN ('boot','bet','show')`, hand)
	won := f.scalar(`SELECT SUM(delta)::bigint FROM chip_ledger WHERE hand_id = $1 AND reason = 'hand_win'`, hand)
	if staked != pot || won != pot {
		t.Fatalf("staked %d won %d pot %d", staked, won, pot)
	}

	f.reconcile()
}

// Settling the same hand twice hits the <handId>:settle:<userId> key: the
// second attempt is duplicate_action and moves nothing (the Table's retry
// loop may hit this after a committed-but-unacknowledged first attempt).
func TestSettleIsIdempotent(t *testing.T) {
	f := newFixture(t)
	w, l := f.user("W"), f.user("L")
	room, hand := "room-idem", "hand-idem"
	f.boot(room, hand, 200, w, l)
	req := game.SettleRequest{
		Hand:    game.HandRecord{ID: hand, RoomID: room, HandNo: 1, Pot: 400, WinnerID: ptr(w.ID), WinReason: "last_standing", BootAmount: 200, StartedAt: 1, EndedAt: 2},
		Entries: []game.SettleEntry{{UserID: w.ID, Delta: 400, IsWinner: true, DidChaal: true}, {UserID: l.ID, Delta: 0}},
	}
	if _, err := f.ledger.Settle(f.ctx, req); err != nil {
		t.Fatal(err)
	}
	wChips, lChips := f.chips(w.ID), f.chips(l.ID)
	wUser := f.find(w.ID)

	_, err := f.ledger.Settle(f.ctx, req) // the Table's retry resends the same request
	if code := codeOf(t, err); code != game.CodeDuplicateAction {
		t.Fatalf("second settle code = %s", code)
	}
	if f.chips(w.ID) != wChips || f.chips(l.ID) != lChips {
		t.Fatal("a repeated settlement moved chips")
	}
	if again := f.find(w.ID); again.HandsWon != wUser.HandsWon || again.TotalWinnings != wUser.TotalWinnings {
		t.Fatal("a repeated settlement bumped the counters")
	}
	if n := f.count(`SELECT COUNT(*) FROM hands WHERE id = $1`, hand); n != 1 {
		t.Fatalf("hands rows = %d", n)
	}
	f.reconcile()
}

// A contributor whose account has vanished is skipped silently — no ledger
// row, no key in the result — while everyone else is settled.
func TestSettleSkipsUnknownUsersAndReportsZeroBalancesAsPresent(t *testing.T) {
	f := newFixture(t)
	w, broke := f.user("W"), f.user("Broke")
	// Empty the second wallet so its settled balance is exactly 0.
	if _, err := f.users.ApplyChipDelta(f.ctx, broke.ID, -welcome, "test_fixture", "", ""); err != nil {
		t.Fatal(err)
	}
	balances, err := f.ledger.Settle(f.ctx, game.SettleRequest{
		Hand: game.HandRecord{ID: "hand-skip", RoomID: "room-skip", HandNo: 1, Pot: 0, WinnerID: ptr(w.ID), WinReason: "show", BootAmount: 200, StartedAt: 1, EndedAt: 2},
		Entries: []game.SettleEntry{
			{UserID: w.ID, Delta: 0, IsWinner: true, DidChaal: true},
			{UserID: broke.ID, Delta: 0, DidChaal: true},
			{UserID: "ghost-user", Delta: 100, DidChaal: true},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, present := balances["ghost-user"]; present {
		t.Fatal("a missing account must not appear in balances")
	}
	v, present := balances[broke.ID]
	if !present || v != 0 {
		t.Fatalf("a settled balance of exactly 0 must be present as 0: %v", balances)
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE hand_id = 'hand-skip'`); n != 2 {
		t.Fatalf("expected 2 settlement rows, got %d", n)
	}
	if f.find(broke.ID).HandsLost != 1 {
		t.Fatal("the broke loser should still count a loss")
	}
	f.reconcile()
}

// balance = max(0, chips + delta): a negative delta larger than the wallet
// clamps to zero instead of failing (Node's Math.max). Never hit in
// production, where settlement deltas are payouts.
func TestSettleClampsTheBalanceAtZero(t *testing.T) {
	f := newFixture(t)
	u := f.user("Clamp")
	balances, err := f.ledger.Settle(f.ctx, game.SettleRequest{
		Hand:    game.HandRecord{ID: "hand-clamp", RoomID: "room-clamp", HandNo: 1, Pot: 0, WinReason: "show", BootAmount: 200, StartedAt: 1, EndedAt: 2},
		Entries: []game.SettleEntry{{UserID: u.ID, Delta: -(welcome + 500), DidChaal: true}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if balances[u.ID] != 0 || f.chips(u.ID) != 0 {
		t.Fatalf("balance = %d wallet = %d", balances[u.ID], f.chips(u.ID))
	}
}

// statsAndRewards.test.js settles with no pot row: the pot UPDATE matching
// nothing is tolerated.
func TestSettleWithoutAPotStillCountsAndPays(t *testing.T) {
	f := newFixture(t)
	w, l := f.user("W"), f.user("L")
	balances, err := f.ledger.Settle(f.ctx, game.SettleRequest{
		Hand:    game.HandRecord{ID: "hand-nostate", RoomID: "room-nostate", HandNo: 1, Pot: 600, WinnerID: ptr(w.ID), WinReason: "show", BootAmount: 200, StartedAt: 1, EndedAt: 2},
		Entries: []game.SettleEntry{{UserID: w.ID, Delta: 400, IsWinner: true, DidChaal: true}, {UserID: l.ID, Delta: -200, DidChaal: false}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if balances[w.ID] != welcome+400 || balances[l.ID] != welcome-200 {
		t.Fatalf("balances = %v", balances)
	}
	if n := f.count(`SELECT COUNT(*) FROM hands WHERE id = 'hand-nostate'`); n != 1 {
		t.Fatal("hands row missing")
	}
	// An empty summary is stored as [] (never null) and win_reason verbatim.
	var summaryJSON string
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT summary_json::text FROM hands WHERE id = 'hand-nostate'`).Scan(&summaryJSON); err != nil {
		t.Fatal(err)
	}
	if summaryJSON != "[]" {
		t.Fatalf("summary_json = %s", summaryJSON)
	}
	f.reconcile()
}

// With no winner (every player vanished) each contributor is refunded: the
// Table sends delta = contributed, and everyone is a "loss" for the counters.
func TestSettleWithoutAWinnerRefundsAndWritesNullWinner(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	room, hand := "room-void", "hand-void"
	f.boot(room, hand, 200, a, b)
	balances, err := f.ledger.Settle(f.ctx, game.SettleRequest{
		Hand:    game.HandRecord{ID: hand, RoomID: room, HandNo: 1, Pot: 400, WinnerID: nil, WinReason: "all_left", BootAmount: 200, StartedAt: 1, EndedAt: 2},
		Entries: []game.SettleEntry{{UserID: a.ID, Delta: 200, LeftMidHand: true}, {UserID: b.ID, Delta: 200, LeftMidHand: true}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if balances[a.ID] != welcome || balances[b.ID] != welcome {
		t.Fatalf("balances = %v", balances)
	}
	var winner *string
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT winner_id FROM hands WHERE id = $1`, hand).Scan(&winner); err != nil {
		t.Fatal(err)
	}
	if winner != nil {
		t.Fatalf("hands.winner_id = %v, want NULL", *winner)
	}
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT winner_id FROM pots WHERE hand_id = $1`, hand).Scan(&winner); err != nil {
		t.Fatal(err)
	}
	if winner != nil {
		t.Fatalf("pots.winner_id = %v, want NULL", *winner)
	}
	au := f.find(a.ID)
	if au.HandsLeftMid != 1 || au.HandsLost != 0 || au.HandsWon != 0 {
		t.Fatalf("a = %+v", au)
	}
	rows := f.handLedgerRows(hand)
	for _, r := range rows[2:] {
		if r.Reason != "hand_loss" || r.Delta != 200 {
			t.Fatalf("refund row = %+v", r)
		}
	}
	f.reconcile()
}

// A random walk of boots, bets and settlements across several players; the
// ledger must reconcile to every wallet and every pot afterwards.
func TestRandomisedPlayKeepsEveryWalletEqualToItsLedger(t *testing.T) {
	f := newFixture(t)
	rng := rand.New(rand.NewSource(20260908))
	players := make([]*db.User, 5)
	for i := range players {
		players[i] = f.user(fmt.Sprintf("R%d", i))
	}
	const boot = int64(200)
	room := "room-random"

	for handNo := 1; handNo <= 12; handNo++ {
		// 2–5 participants.
		perm := rng.Perm(len(players))[:2+rng.Intn(len(players)-1)]
		var participants []*db.User
		for _, i := range perm {
			participants = append(participants, players[i])
		}
		hand := fmt.Sprintf("hand-random-%d", handNo)
		if _, err := f.ledger.CollectBoot(f.ctx, game.CollectBootRequest{
			RoomID: room, HandID: hand, BootAmount: boot,
			Entries: func() []game.BootEntry {
				var es []game.BootEntry
				for _, p := range participants {
					es = append(es, game.BootEntry{UserID: p.ID, Amount: boot})
				}
				return es
			}(),
		}); err != nil {
			t.Fatalf("hand %d boot: %v", handNo, err)
		}
		contributed := map[string]int64{}
		for _, p := range participants {
			contributed[p.ID] = boot
		}
		pot := boot * int64(len(participants))

		// A handful of bets, some deliberately refused.
		for move := 0; move < 3+rng.Intn(6); move++ {
			p := participants[rng.Intn(len(participants))]
			amount := boot * int64(1<<rng.Intn(4))
			actionID := fmt.Sprintf("%s:%d", hand, move)
			if rng.Intn(6) == 0 {
				// Replay a previous move: must be refused and change nothing.
				actionID = fmt.Sprintf("%s:%d", hand, rng.Intn(move+1))
			}
			_, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: p.ID, Amount: amount, RoomID: room, HandID: hand, ActionID: actionID})
			switch game.CodeOf(err, "") {
			case "":
				contributed[p.ID] += amount
				pot += amount
			case game.CodeDuplicateAction, game.CodeInsufficientChips:
				// nothing was written
			default:
				t.Fatalf("hand %d move %d: %v", handNo, move, err)
			}
		}

		if got := f.scalar(`SELECT amount FROM pots WHERE hand_id = $1`, hand); got != pot {
			t.Fatalf("hand %d pot %d != tracked %d", handNo, got, pot)
		}

		var winner *string
		var entries []game.SettleEntry
		if rng.Intn(5) != 0 {
			winner = ptr(participants[rng.Intn(len(participants))].ID)
		}
		for _, p := range participants {
			e := game.SettleEntry{UserID: p.ID, DidChaal: contributed[p.ID] > boot}
			if winner != nil {
				if p.ID == *winner {
					e.IsWinner, e.Delta = true, pot
				}
			} else {
				e.Delta, e.LeftMidHand = contributed[p.ID], true
			}
			entries = append(entries, e)
		}
		if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{
			Hand:    game.HandRecord{ID: hand, RoomID: room, HandNo: handNo, Pot: pot, WinnerID: winner, WinReason: "show", BootAmount: boot, StartedAt: 1, EndedAt: 2},
			Entries: entries,
		}); err != nil {
			t.Fatalf("hand %d settle: %v", handNo, err)
		}
	}

	f.reconcile()
	// Chips are conserved across the whole session.
	total := f.scalar(`SELECT SUM(chips)::bigint FROM users`)
	if total != welcome*int64(len(players)) {
		t.Fatalf("chips created or destroyed: total %d", total)
	}
	// Every pot equals its stakes and, when won, its payout.
	mismatched := f.scalar(`SELECT COUNT(*) FROM pots p
	   WHERE p.amount <> (SELECT -COALESCE(SUM(delta),0) FROM chip_ledger l WHERE l.hand_id = p.hand_id AND l.reason IN ('boot','bet','show'))
	      OR (p.winner_id IS NOT NULL AND p.amount <> (SELECT COALESCE(SUM(delta),0) FROM chip_ledger l WHERE l.hand_id = p.hand_id AND l.reason = 'hand_win'))`)
	if mismatched != 0 {
		t.Fatalf("%d pot(s) do not reconcile with their ledger rows", mismatched)
	}
}

// ---------------------------------------------------------- append-only

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

// The ledger feeds game_db_transaction_duration_seconds{op}, the two
// unlabelled hand-start / settlement histograms, and counts refusals by code.
func TestLedgerObservesTransactionMetrics(t *testing.T) {
	f := newFixture(t)
	reg := prometheus.NewRegistry()
	m := &metrics.Metrics{
		DBTransactionDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "game_db_transaction_duration_seconds"}, []string{"op"}),
		DBTransactionErrors:   prometheus.NewCounterVec(prometheus.CounterOpts{Name: "game_db_transaction_errors_total"}, []string{"op", "code"}),
		HandStartDuration:     prometheus.NewHistogram(prometheus.HistogramOpts{Name: "game_hand_start_duration_seconds"}),
		SettlementDuration:    prometheus.NewHistogram(prometheus.HistogramOpts{Name: "game_settlement_duration_seconds"}),
	}
	reg.MustRegister(m.DBTransactionDuration, m.DBTransactionErrors, m.HandStartDuration, m.SettlementDuration)
	ledger := db.NewLedger(f.d, m, nil)

	a, b := f.user("A"), f.user("B")
	room, hand := "room-metrics", "hand-metrics"
	if _, err := ledger.CollectBoot(f.ctx, game.CollectBootRequest{RoomID: room, HandID: hand, BootAmount: 200,
		Entries: []game.BootEntry{{UserID: a.ID, Amount: 200}, {UserID: b.ID, Amount: 200}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := ledger.Bet(f.ctx, game.BetRequest{UserID: a.ID, Amount: 400, RoomID: room, HandID: hand, ActionID: "m1"}); err != nil {
		t.Fatal(err)
	}
	// One refusal inside a transaction: a duplicate (duplicate_action).
	_, _ = ledger.Bet(f.ctx, game.BetRequest{UserID: a.ID, Amount: 400, RoomID: room, HandID: hand, ActionID: "m1"})
	// invalid_amount is counted even though no transaction was opened.
	_, _ = ledger.Bet(f.ctx, game.BetRequest{UserID: a.ID, Amount: 0, RoomID: room, HandID: hand, ActionID: "m3"})
	if _, err := ledger.Settle(f.ctx, game.SettleRequest{
		Hand:    game.HandRecord{ID: hand, RoomID: room, HandNo: 1, Pot: 800, WinnerID: ptr(a.ID), WinReason: "show", BootAmount: 200, StartedAt: 1, EndedAt: 2},
		Entries: []game.SettleEntry{{UserID: a.ID, Delta: 800, IsWinner: true, DidChaal: true}, {UserID: b.ID}},
	}); err != nil {
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
	if n := sampleCount("game_db_transaction_duration_seconds", map[string]string{"op": "boot"}); n != 1 {
		t.Fatalf("boot transactions observed = %d", n)
	}
	if n := sampleCount("game_db_transaction_duration_seconds", map[string]string{"op": "bet"}); n != 3 {
		t.Fatalf("bet transactions observed = %d (every attempt, refused ones included)", n)
	}
	if n := sampleCount("game_db_transaction_duration_seconds", map[string]string{"op": "settle"}); n != 1 {
		t.Fatalf("settle transactions observed = %d", n)
	}
	if n := sampleCount("game_hand_start_duration_seconds", nil); n != 1 {
		t.Fatalf("hand start observed = %d", n)
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
	for code, want := range map[string]float64{"duplicate_action": 1, "invalid_amount": 1} {
		if got := counter("game_db_transaction_errors_total", map[string]string{"op": "bet", "code": code}); got != want {
			t.Fatalf("errors{op=bet,code=%s} = %v, want %v", code, got, want)
		}
	}
	if got := counter("game_db_transaction_errors_total", map[string]string{"op": "boot", "code": "insufficient_chips"}); got != 0 {
		t.Fatalf("unexpected boot errors: %v", got)
	}
}
