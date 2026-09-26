package game

// The winning tax (owner, 26 Sep 2026; tabletax.go): at a table that taxes its
// winners the ONE winner of every hand pays their level's rate of the WHOLE
// pot, rounded down; nobody else pays anything; the seat is credited the pot
// less the tax, the ledger records the win gross and the tax as a row of its
// own, and every other table is exactly what it was.

import (
	"encoding/json"
	"math"
	"math/big"
	"math/rand"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
)

// taxBook is a MemoryLedger's books for these tests: a wallet per player that
// every ledger row moves (the pack and leave checkpoints and each row of the
// settlement — a taxed win's two), every row with its hand, every settlement,
// and the rates the ledger reports after one (SettleResult.TaxBps).
type taxBook struct {
	mu      sync.Mutex
	wallets map[string]int64
	rows    []taxBookRow
	settles []SettleRequest
	rates   map[string]int
}

type taxBookRow struct {
	hand  string
	entry SettleEntry
}

func newTaxBook() *taxBook {
	return &taxBook{wallets: map[string]int64{}, rates: map[string]int{}}
}

func (b *taxBook) ledger(*harness) Ledger {
	return NewMemoryLedger(MemoryLedgerHooks{
		Checkpoint: func(args CheckpointArgs) error {
			b.mu.Lock()
			defer b.mu.Unlock()
			b.rows = append(b.rows, taxBookRow{hand: args.HandID, entry: args.Entry})
			b.wallets[args.Entry.UserID] += args.Entry.Delta
			return nil
		},
		Settle: func(req SettleRequest, entries []SettleEntry) (map[string]int64, error) {
			b.mu.Lock()
			defer b.mu.Unlock()
			b.settles = append(b.settles, req)
			out := map[string]int64{}
			for _, e := range entries {
				out[e.UserID] = b.wallets[e.UserID]
			}
			return out, nil
		},
		TaxBps: func(req SettleRequest) map[string]int {
			b.mu.Lock()
			defer b.mu.Unlock()
			out := map[string]int{}
			for _, e := range req.Entries {
				if bps, ok := b.rates[e.UserID]; ok {
					out[e.UserID] = bps
				}
			}
			return out
		},
	})
}

func (b *taxBook) total() int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	var sum int64
	for _, v := range b.wallets {
		sum += v
	}
	return sum
}

func (b *taxBook) wallet(id string) int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.wallets[id]
}

func (b *taxBook) rowsOf(hand string) []SettleEntry {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []SettleEntry
	for _, r := range b.rows {
		if r.hand == hand {
			out = append(out, r.entry)
		}
	}
	return out
}

func (b *taxBook) lastSettle(t *testing.T) SettleRequest {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.settles) == 0 {
		t.Fatal("nothing settled")
	}
	return b.settles[len(b.settles)-1]
}

// taxConfig is settleConfig at a table that taxes its winners.
func taxConfig() TableConfig {
	cfg := settleConfig()
	cfg.WinnerTax = true
	return cfg
}

// seatAt seats id with chips whose level carries bps, and funds its wallet.
func (h *harness) seatAt(book *taxBook, id string, chips int64, bps int) {
	h.t.Helper()
	book.mu.Lock()
	book.wallets[id] = chips
	book.mu.Unlock()
	if _, err := h.table.AddPlayer(NewPlayer{UserID: id, DisplayName: strings.ToUpper(id), Chips: chips, SocketID: "s-" + id, TaxBps: bps}); err != nil {
		h.t.Fatalf("seat %s: %v", id, err)
	}
}

// taxObserver records the table's ObserveTableTax calls.
type taxObserver struct {
	mu    sync.Mutex
	calls []struct {
		category Category
		chips    int64
	}
}

func (o *taxObserver) install(h *harness) {
	h.read(func() {
		h.table.onTableTax = func(category Category, chips int64) {
			o.mu.Lock()
			o.calls = append(o.calls, struct {
				category Category
				chips    int64
			}{category, chips})
			o.mu.Unlock()
		}
	})
}

func (o *taxObserver) total() (int64, int) {
	o.mu.Lock()
	defer o.mu.Unlock()
	var sum int64
	for _, c := range o.calls {
		sum += c.chips
	}
	return sum, len(o.calls)
}

// ------------------------------------------------------------- the function

// TestTheWinningTaxIsTheRateOfTheWholePotRoundedDown: basis points of the
// whole pot, never a chip more than the rate (floor), nothing for a rate or a
// pot of nothing, a rate above 100% read as 100%, and no overflow on a pot the
// product would not fit — checked against exact big-integer arithmetic.
func TestTheWinningTaxIsTheRateOfTheWholePotRoundedDown(t *testing.T) {
	for _, tc := range []struct {
		pot  int64
		bps  int
		want int64
	}{
		{200, 2000, 40},            // Level 1: 20.00%
		{200, 400, 8},              // VIP: 4.00%
		{2_000_000, 1816, 363_200}, // Level 10: 18.16%
		{199, 2000, 39},            // 39.8 rounds down
		{3, 1959, 0},               // 0.5877 rounds down to nothing
		{1, 10000, 1},              // the whole pot at 100%
		{1000, 20000, 1000},        // a rate above 100% is 100%
		{0, 2000, 0},
		{-500, 2000, 0},
		{1000, 0, 0},
		{1000, -1, 0},
	} {
		if got := TableTax(tc.pot, tc.bps); got != tc.want {
			t.Errorf("TableTax(%d, %d) = %d, want %d", tc.pot, tc.bps, got, tc.want)
		}
	}
	exact := func(pot int64, bps int) int64 {
		p := new(big.Int).Mul(big.NewInt(pot), big.NewInt(int64(min(bps, MaxTaxBps))))
		return p.Quo(p, big.NewInt(MaxTaxBps)).Int64()
	}
	if got, want := TableTax(math.MaxInt64, 2000), exact(math.MaxInt64, 2000); got != want {
		t.Fatalf("TableTax(MaxInt64, 2000) = %d, want %d: the product must not overflow", got, want)
	}
	rng := rand.New(rand.NewSource(26))
	for i := 0; i < 20000; i++ {
		pot := rng.Int63()
		if i%2 == 0 {
			pot = rng.Int63n(10_000_000_000)
		}
		bps := rng.Intn(MaxTaxBps + 1)
		if got, want := TableTax(pot, bps), exact(pot, bps); got != want {
			t.Fatalf("TableTax(%d, %d) = %d, want %d", pot, bps, got, want)
		}
	}
}

// TestATaxedWinIsTwoLedgerRowsAndAnUntaxedOneIsItself: LedgerRows — what
// db.Ledger inserts and MemoryLedger reports — writes a taxed winner's entry
// as the win GROSS and the tax as a table_tax row of its own under its own
// action id; the two sum to the entry's Delta, which is what the wallet moves.
func TestATaxedWinIsTwoLedgerRowsAndAnUntaxedOneIsItself(t *testing.T) {
	entry := SettleEntry{UserID: "w", Delta: 560, ActionID: SettleActionID("h1", "w"), Reason: LedgerReasonHandWin,
		Outcome: true, IsWinner: true, DidChaal: true, Pot: 2000, Tax: 400}
	rows := LedgerRows("h1", entry)
	if len(rows) != 2 {
		t.Fatalf("%d rows, want 2", len(rows))
	}
	win, tax := rows[0], rows[1]
	if win.Delta != 960 || win.Tax != 0 || win.Reason != LedgerReasonHandWin || win.ActionID != "h1:settle:w" || !win.Outcome || !win.IsWinner || win.Pot != 2000 {
		t.Errorf("the win row %+v: want the entry at its gross 960, with its counters", win)
	}
	if tax.Delta != -400 || tax.Reason != LedgerReasonTableTax || tax.ActionID != "h1:tax:w" || tax.ActionID != TaxActionID("h1", "w") ||
		tax.Outcome || tax.IsWinner || tax.Pot != 0 || tax.UserID != "w" {
		t.Errorf("the tax row %+v: want −400, table_tax, h1:tax:w, no counters", tax)
	}
	if win.Delta+tax.Delta != entry.Delta {
		t.Error("the two rows must move the wallet by the entry's Delta")
	}
	plain := SettleEntry{UserID: "l", Delta: -1000, ActionID: "h1:settle:l", Reason: LedgerReasonHandLoss, Outcome: true}
	if got := LedgerRows("h1", plain); len(got) != 1 || got[0] != plain {
		t.Errorf("an untaxed entry is one row, itself: %+v", got)
	}
}

// ---------------------------------------------------------------- the table

// taxedHand is one way a hand ends with a winner, played at the harness
// table: it returns the rates the players were seated at.
type taxedHand struct {
	name   string
	reason WinReason
	cfg    func() TableConfig
	play   func(t *testing.T, h *harness, book *taxBook) map[string]int
}

func taxedHands() []taxedHand {
	three := func(h *harness, book *taxBook) map[string]int {
		rates := map[string]int{"a": 2000, "b": 400, "c": 1816}
		for _, id := range []string{"a", "b", "c"} {
			h.seatAt(book, id, settleStart, rates[id])
		}
		return rates
	}
	return []taxedHand{
		{name: "last standing", reason: WinLastStanding, cfg: taxConfig, play: func(t *testing.T, h *harness, book *taxBook) map[string]int {
			rates := map[string]int{"a": 2000, "b": 400}
			h.seatAt(book, "a", settleStart, 2000)
			h.seatAt(book, "b", settleStart, 400)
			h.advance(6 * time.Second)
			h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
			h.mustAct(h.turnUser(), ActionPack, ActRequest{})
			return rates
		}},
		{name: "show", reason: WinShow, cfg: taxConfig, play: func(t *testing.T, h *harness, book *taxBook) map[string]int {
			rates := map[string]int{"a": 400, "b": 2000}
			h.seatAt(book, "a", settleStart, 400)
			h.seatAt(book, "b", settleStart, 2000)
			h.advance(6 * time.Second)
			h.setCards("a", "As", "Ah", "Ad")
			h.setCards("b", "2s", "7h", "9d")
			h.mustAct(h.turnUser(), ActionSee, ActRequest{})
			h.mustAct(h.turnUser(), ActionRaise, ActRequest{})
			h.mustAct(h.turnUser(), ActionShow, ActRequest{})
			return rates
		}},
		{name: "forced showdown", reason: WinForcedShowdown, cfg: func() TableConfig {
			cfg := taxConfig()
			cfg.MaxBetRounds = 4
			return cfg
		}, play: func(t *testing.T, h *harness, book *taxBook) map[string]int {
			rates := three(h, book)
			h.advance(6 * time.Second)
			for i := 0; i < 60 && h.hasHand(); i++ {
				h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
			}
			return rates
		}},
		{name: "pot limit", reason: WinPotLimit, cfg: func() TableConfig {
			cfg := taxConfig()
			cfg.MaxPot = 1500
			return cfg
		}, play: func(t *testing.T, h *harness, book *taxBook) map[string]int {
			rates := three(h, book)
			h.advance(6 * time.Second)
			for i := 0; i < 60 && h.hasHand(); i++ {
				player := h.turnUser()
				opts := h.betOptions(player)
				if opts.Max == nil {
					t.Fatalf("%s has no rung at pot %d", player, h.pot())
				}
				h.mustAct(player, ActionChaal, amt(*opts.Max))
			}
			return rates
		}},
		{name: "missile", reason: WinMissile, cfg: func() TableConfig {
			cfg := missileConfig()
			cfg.WinnerTax = true
			return cfg
		}, play: func(t *testing.T, h *harness, book *taxBook) map[string]int {
			rates := three(h, book)
			h.advance(missileConfig().NextHandDelay)
			h.mustAct(h.turnUser(), ActionMissile, fire("tax-missile"))
			return rates
		}},
		{name: "the table destroyed", reason: WinAllLeft, cfg: taxConfig, play: func(t *testing.T, h *harness, book *taxBook) map[string]int {
			rates := three(h, book)
			h.advance(6 * time.Second)
			h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
			if err := h.table.Destroy(); err != nil {
				t.Fatal(err)
			}
			return rates
		}},
		{name: "the last to leave", reason: WinAllLeft, cfg: taxConfig, play: func(t *testing.T, h *harness, book *taxBook) map[string]int {
			rates := map[string]int{"a": 2000, "b": 400}
			h.seatAt(book, "a", settleStart, 2000)
			h.seatAt(book, "b", settleStart, 400)
			h.advance(6 * time.Second)
			// Both seats vacated without ending the hand, b the last to go (the
			// all_left path of TestAllLeftWinnerNameFromContribution, with the
			// leave checkpoint each departure writes): b wins from outside the
			// table, at the rate b was dealt with.
			h.read(func() {
				for _, id := range []string{"a", "b"} {
					s := h.table.findSeat(id)
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
			return rates
		}},
	}
}

// TestATaxingTableTaxesTheWinnerOfEveryKindOfHandEnd: a show, the last
// player standing, the forced and the pot-limit showdowns, a missile, a table
// destroyed mid-hand and the pot of the last to leave — in every one the
// winner pays their own rate of the whole pot and nothing else moves: the
// winner's entry carries the Tax, its rows are the win gross and a table_tax
// row, the hand's hand_* rows still sum to zero, the books lose exactly the
// tax, the seat holds what the wallet does, handEnded says what was taken and
// at what rate, and the metric hears of it once.
func TestATaxingTableTaxesTheWinnerOfEveryKindOfHandEnd(t *testing.T) {
	for _, tc := range taxedHands() {
		t.Run(tc.name, func(t *testing.T) {
			book := newTaxBook()
			opts := []harnessOption{withLedger(book.ledger)}
			if tc.reason == WinMissile {
				wallet := NewMemoryMissiles(nil)
				for _, id := range []string{"a", "b", "c"} {
					wallet.Set(id, 5)
				}
				opts = append(opts, withMissiles(wallet))
			}
			h := newHarness(t, tc.cfg(), opts...)
			observer := &taxObserver{}
			observer.install(h)
			rates := tc.play(t, h, book)
			var before int64
			for range rates {
				before += settleStart
			}

			ended := h.lastHandEnded()
			eq(t, ended.Reason, tc.reason, "the hand ended as the case plays it")
			if ended.WinnerID == nil {
				t.Fatal("no winner")
			}
			winner := *ended.WinnerID
			bps := rates[winner]
			tax := TableTax(ended.Pot, bps)
			if tax <= 0 {
				t.Fatalf("pot %d at %d bps is no tax: the case proves nothing", ended.Pot, bps)
			}
			eq(t, ended.Tax, tax, "handEnded.tax is the winner's rate of the whole pot")
			eq(t, ended.TaxBps, bps, "handEnded.taxBps is the rate applied: the winner's own")

			req := book.lastSettle(t)
			eq(t, req.HandID, ended.HandID, "the hand's settlement")
			for _, e := range req.Entries {
				if e.UserID == winner {
					eq(t, e.Tax, tax, "the winner's entry carries the tax")
					eq(t, e.IsWinner, true, "the winner's entry")
				} else if e.Tax != 0 {
					t.Errorf("%s did not win and paid %d", e.UserID, e.Tax)
				}
			}
			var handRows, taxRows int64
			var taxRowCount int
			for _, row := range book.rowsOf(ended.HandID) {
				switch row.Reason {
				case LedgerReasonTableTax:
					taxRowCount++
					taxRows += row.Delta
					eq(t, row.UserID, winner, "the tax row is the winner's")
					eq(t, row.ActionID, TaxActionID(ended.HandID, winner), "the tax row's action id")
				default:
					handRows += row.Delta
				}
			}
			eq(t, taxRowCount, 1, "one table_tax row")
			eq(t, taxRows, -tax, "the table_tax row is minus the tax")
			eq(t, handRows, int64(0), "the hand's hand_* rows still sum to zero: the win is written gross")
			eq(t, book.total(), before-tax, "the tax, and only the tax, leaves the game")
			if sum, calls := observer.total(); sum != tax || calls != 1 {
				t.Errorf("game_table_tax_chips_total heard %d chips in %d calls, want %d once", sum, calls, tax)
			}
			if !h.table.Destroyed() {
				if s := h.seatInfo(winner); s != nil {
					eq(t, s.Chips, book.wallet(winner), "the seat holds what the wallet does: the pot less the tax")
				}
			}
			raw := mustJSON(t, ended)
			if !strings.Contains(raw, `"tax":`+jsonInt(tax)) || !strings.Contains(raw, `"taxBps":`+jsonInt(int64(bps))) {
				t.Errorf("game:handEnded must carry the tax and its rate: %s", raw)
			}
		})
	}
}

// TestAnUntaxedTableIsExactlyWhatItWas: the same hands at a table that does
// not tax its winners — every table but the catalogue's two — take nothing,
// write no table_tax row, and put not one new key on the wire.
func TestAnUntaxedTableIsExactlyWhatItWas(t *testing.T) {
	for _, tc := range taxedHands() {
		t.Run(tc.name, func(t *testing.T) {
			book := newTaxBook()
			opts := []harnessOption{withLedger(book.ledger)}
			if tc.reason == WinMissile {
				wallet := NewMemoryMissiles(nil)
				for _, id := range []string{"a", "b", "c"} {
					wallet.Set(id, 5)
				}
				opts = append(opts, withMissiles(wallet))
			}
			cfg := tc.cfg()
			cfg.WinnerTax = false
			h := newHarness(t, cfg, opts...)
			observer := &taxObserver{}
			observer.install(h)
			rates := tc.play(t, h, book)
			var before int64
			for range rates {
				before += settleStart
			}
			ended := h.lastHandEnded()
			eq(t, ended.Tax, int64(0), "no tax")
			eq(t, ended.TaxBps, 0, "no rate")
			eq(t, book.total(), before, "nothing leaves the game")
			for _, row := range book.rowsOf(ended.HandID) {
				if row.Reason == LedgerReasonTableTax || row.Tax != 0 {
					t.Fatalf("an untaxed hand wrote %+v", row)
				}
			}
			if _, calls := observer.total(); calls != 0 {
				t.Error("the metric must hear nothing")
			}
			raw := mustJSON(t, ended)
			if strings.Contains(raw, `"tax"`) || strings.Contains(raw, `"taxBps"`) {
				t.Errorf("an untaxed handEnded carries a tax key: %s", raw)
			}
		})
	}
}

// ----------------------------------------------------------------- the wire

// TestOnlyATaxingTableSaysSoAndEachViewerSeesTheirOwnRate: room:state at a
// table that taxes its winners carries winnerTax and, in `you`, the rate that
// viewer's seat pays — a VIP's 4%, a 0 when the level carries none — and no
// other seat's; at any other table neither key exists.
func TestOnlyATaxingTableSaysSoAndEachViewerSeesTheirOwnRate(t *testing.T) {
	book := newTaxBook()
	h := newHarness(t, taxConfig(), withLedger(book.ledger))
	h.seatAt(book, "a", settleStart, 2000)
	h.seatAt(book, "b", settleStart, 400)
	h.seatAt(book, "c", settleStart, 0)
	for _, phase := range []string{"between hands", "mid-hand"} {
		if phase == "mid-hand" {
			h.advance(6 * time.Second)
		}
		for id, want := range map[string]int{"a": 2000, "b": 400, "c": 0} {
			v := h.view(id)
			if !v.WinnerTax || v.You == nil || v.You.TaxBps == nil || *v.You.TaxBps != want {
				t.Fatalf("%s %s: winnerTax %v, you.taxBps %v, want true and %d", phase, id, v.WinnerTax, v.You.TaxBps, want)
			}
			raw := mustJSON(t, v)
			if !strings.Contains(raw, `"winnerTax":true`) || strings.Count(raw, `"taxBps"`) != 1 ||
				!strings.Contains(raw, `"taxBps":`+jsonInt(int64(want))) {
				t.Fatalf("%s %s: the snapshot must say the table taxes its winners and carry the viewer's rate once: %s", phase, id, raw)
			}
			var seats struct {
				Seats []map[string]any `json:"seats"`
			}
			if err := json.Unmarshal([]byte(raw), &seats); err != nil {
				t.Fatal(err)
			}
			for _, seat := range seats.Seats {
				if _, ok := seat["taxBps"]; ok {
					t.Fatalf("%s: a seat carries a rate — another player's level would leak: %v", phase, seat)
				}
			}
		}
	}

	plain := newHarness(t, settleConfig(), withID("plain", "PLAIN001"))
	plain.seat("a", settleStart)
	plain.seat("b", settleStart)
	for _, phase := range []string{"between hands", "mid-hand"} {
		if phase == "mid-hand" {
			plain.advance(6 * time.Second)
		}
		raw := mustJSON(t, plain.view("a"))
		if strings.Contains(raw, "winnerTax") || strings.Contains(raw, "taxBps") {
			t.Fatalf("%s: an untaxed table's snapshot carries a tax key: %s", phase, raw)
		}
	}
}

// ----------------------------------------------------------------- the rate

// TestTheSeatPaysTheRateItsHandWasDealtWith: the seat captures its player's
// rate when they sit down; a hand captures the seat's when it is dealt; a
// settlement's rates (the XP it awarded may have raised a level) reach the
// seat for its NEXT hand, and a rate that changes mid-hand is never the hand
// in progress's.
func TestTheSeatPaysTheRateItsHandWasDealtWith(t *testing.T) {
	book := newTaxBook()
	book.rates = map[string]int{"a": 1980, "b": 400}
	h := newHarness(t, taxConfig(), withLedger(book.ledger))
	h.seatAt(book, "a", settleStart, 2000)
	h.seatAt(book, "b", settleStart, 400)

	// Hand 1 at the rates the seats sat down with.
	h.advance(6 * time.Second)
	first := h.turnUser()
	h.mustAct(first, ActionPack, ActRequest{})
	ended := h.lastHandEnded()
	winner := *ended.WinnerID
	eq(t, ended.TaxBps, map[string]int{"a": 2000, "b": 400}[winner], "hand 1 at the sit-down rate")

	// The settlement said a is now at 19.80%: between hands the seat pays it.
	eq(t, *h.view("a").You.TaxBps, 1980, "the settle's rate reaches the seat")
	eq(t, h.seatInfo("a").TaxBps, 1980, "…and SeatInfo carries it (a consolidation move takes it along)")

	// Hand 2 is dealt at 19.80%; a rate that changes mid-hand is the next
	// hand's, never this one's.
	h.advance(6 * time.Second)
	h.read(func() { h.table.adoptTaxRates(map[string]int{"a": 1816, "b": 400, "zed": 5, "c": 99999}) })
	eq(t, *h.view("a").You.TaxBps, 1980, "mid-hand, you.taxBps is the rate the hand was dealt with")
	eq(t, h.seatInfo("a").TaxBps, 1816, "the seat already holds the next hand's rate")
	book.mu.Lock()
	book.rates = map[string]int{} // no further change after this hand
	book.mu.Unlock()
	for h.hasHand() {
		player := h.turnUser()
		if player == "a" {
			h.mustAct("a", ActionChaal, ActRequest{})
			continue
		}
		h.mustAct(player, ActionPack, ActRequest{})
	}
	ended = h.lastHandEnded()
	eq(t, *ended.WinnerID, "a", "a wins hand 2")
	eq(t, ended.TaxBps, 1980, "hand 2 pays the rate it was dealt with, not the one set mid-hand")
	eq(t, ended.Tax, TableTax(ended.Pot, 1980), "at 19.80% of the pot")
	eq(t, *h.view("a").You.TaxBps, 1816, "between hands again, the seat's rate")
}

// TestTheRatesSurviveARestoreAndABadOneIsRefused: the table's winner tax,
// every seat's rate and every contribution's dealt rate are in the snapshot,
// come back from it, and are what the restored hand is taxed at; a rate no
// level could carry is not restored.
func TestTheRatesSurviveARestoreAndABadOneIsRefused(t *testing.T) {
	book := newTaxBook()
	h := newHarness(t, taxConfig(), withLedger(book.ledger))
	h.seatAt(book, "a", settleStart, 2000)
	h.seatAt(book, "b", settleStart, 400)
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})

	snap := roundTrip(t, mustSnapshot(h))
	if !snap.Config.WinnerTax {
		t.Fatal("the snapshot must keep that the table taxes its winners")
	}
	raw := mustJSON(t, snap)
	if !strings.Contains(raw, `"winnerTax":true`) || strings.Count(raw, `"taxBps":2000`) != 2 || strings.Count(raw, `"taxBps":400`) != 2 {
		t.Fatalf("each seat's rate and each contribution's dealt rate must be in the snapshot: %s", raw)
	}

	clock := newFakeClock(h.clock.Now())
	book2 := newTaxBook()
	book2.wallets = map[string]int64{"a": settleStart, "b": settleStart}
	restored := restoreHarness(t, snap, clock, withLedger(book2.ledger))
	if got := mustJSON(t, roundTrip(t, mustSnapshot(restored))); got != mustJSON(t, snap) {
		t.Fatalf("the restore must keep every rate:\n got %s\nwant %s", got, mustJSON(t, snap))
	}
	eq(t, *restored.view("b").You.TaxBps, 400, "b's dealt rate came back")
	loser := restored.turnUser()
	restored.mustAct(loser, ActionPack, ActRequest{})
	ended := restored.lastHandEnded()
	winner := *ended.WinnerID
	eq(t, ended.TaxBps, map[string]int{"a": 2000, "b": 400}[winner], "the restored hand is taxed at the rate it was dealt with")

	for name, spoil := range map[string]func(s *Snapshot){
		"a seat's rate above 100%":         func(s *Snapshot) { s.Seats[0].TaxBps = 10001 },
		"a negative seat rate":             func(s *Snapshot) { s.Seats[1].TaxBps = -1 },
		"a contribution's rate above 100%": func(s *Snapshot) { s.Hand.Contributions[0].TaxBps = 20000 },
		"a negative contribution's rate":   func(s *Snapshot) { s.Hand.Contributions[1].TaxBps = -400 },
	} {
		bad := roundTrip(t, snap)
		spoil(bad)
		if _, err := restoreTable(bad, TableOptions{Clock: newFakeClock(clockStart)}); err == nil || !strings.Contains(err.Error(), "winning-tax rate") {
			t.Errorf("%s: restore must refuse it, got %v", name, err)
		}
	}
}

// TestATableRestoredFromBeforeTheTaxIsDrained: a table says what it plays by
// (RulesSpec), the winner tax included, so one opened before the catalogue
// taxed its pair — or after it stopped — never matches what the catalogue
// would open now, and the RoomManager drains it (SameRules).
func TestATableRestoredFromBeforeTheTaxIsDrained(t *testing.T) {
	g := config.Defaults().Game
	spec := g.Spec("blind", 1_000_000, false)
	if !spec.WinnerTax {
		t.Fatal("the default blind 10 Lakh table taxes its winners")
	}
	taxed := NewTable(TableOptions{ID: "taxed", Code: "TAXED001", Config: tableConfigFromSpec(CategoryBlind, spec, config.ChatConfig{})})
	defer func() { _ = taxed.Destroy() }()
	if got := taxed.RulesSpec(); !got.WinnerTax || !got.SameRules(spec) {
		t.Fatalf("a table opened from the spec plays by it: %+v", got)
	}
	cfg := tableConfigFromSpec(CategoryBlind, spec, config.ChatConfig{})
	cfg.WinnerTax = false
	old := NewTable(TableOptions{ID: "old", Code: "OLDTAB01", Config: cfg})
	defer func() { _ = old.Destroy() }()
	if old.RulesSpec().SameRules(spec) {
		t.Fatal("a table that does not tax where the catalogue now does must be drained")
	}
	for _, c := range []string{"seen", "variation", "omaha"} {
		if g.Spec(c, 200, false).WinnerTax {
			t.Errorf("%s 200 must not tax its winners", c)
		}
	}
}
