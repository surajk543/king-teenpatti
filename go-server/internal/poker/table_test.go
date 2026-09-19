package poker

import (
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/testclock"
)

// The white-box harness: a room on a deterministic clock, a recording
// listener, and a memory ledger that keeps wallets so every test can assert
// the three-checkpoint money model — chips are never created or lost.

var start = time.UnixMilli(1_700_000_000_000)

type event struct {
	name    string
	payload any
}

type recorder struct {
	NopListener
	mu     sync.Mutex
	events []event
	cards  map[string][]string // last hole cards each player was sent
}

func newRecorder() *recorder { return &recorder{cards: map[string][]string{}} }

func (r *recorder) add(name string, payload any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event{name, payload})
}
func (r *recorder) OnState(v *View)                           { r.add("state", nil) }
func (r *recorder) OnHandStarted(v *View, e HandStartedEvent) { r.add("handStarted", e) }
func (r *recorder) OnCards(v *View, e CardsEvent) {
	r.mu.Lock()
	r.cards[e.UserID] = e.Cards
	r.mu.Unlock()
	r.add("cards", e)
}
func (r *recorder) OnTurn(v *View, e TurnEvent)         { r.add("turn", e) }
func (r *recorder) OnAction(v *View, e ActionEvent)     { r.add("action", e) }
func (r *recorder) OnStreet(v *View, e StreetEvent)     { r.add("street", e) }
func (r *recorder) OnDraw(v *View, e DrawEvent)         { r.add("draw", e) }
func (r *recorder) OnShowdown(v *View, e ShowdownEvent) { r.add("showdown", e) }
func (r *recorder) OnHandEnded(v *View, e HandEndedEvent) {
	r.add("handEnded", e)
}

func (r *recorder) last(name string) any {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := len(r.events) - 1; i >= 0; i-- {
		if r.events[i].name == name {
			return r.events[i].payload
		}
	}
	return nil
}

func (r *recorder) count(name string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, e := range r.events {
		if e.name == name {
			n++
		}
	}
	return n
}

// books is the memory ledger's wallets: every checkpoint applies its delta.
type books struct {
	mu      sync.Mutex
	wallets map[string]int64
	rows    []game.SettleEntry
	refuse  bool
}

func (b *books) ledger() *game.MemoryLedger {
	return game.NewMemoryLedger(game.MemoryLedgerHooks{
		Checkpoint: func(args game.CheckpointArgs) error {
			b.mu.Lock()
			defer b.mu.Unlock()
			if b.refuse {
				return game.NewGameError(game.CodePersistFailed, "down")
			}
			b.wallets[args.Entry.UserID] += args.Entry.Delta
			b.rows = append(b.rows, args.Entry)
			return nil
		},
		Settle: func(req game.SettleRequest, entries []game.SettleEntry) (map[string]int64, error) {
			b.mu.Lock()
			defer b.mu.Unlock()
			out := map[string]int64{}
			for _, e := range entries {
				out[e.UserID] = b.wallets[e.UserID]
			}
			return out, nil
		},
	})
}

func (b *books) total() int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	var sum int64
	for _, v := range b.wallets {
		sum += v
	}
	return sum
}

type harness struct {
	t     *testing.T
	table *Table
	clock *testclock.Fake
	rec   *recorder
	books *books
	cfg   Config
}

type harnessOptions struct {
	variant Variant
	boot    int64
	live    interface{}
}

func newHarness(t *testing.T, variant Variant) *harness {
	t.Helper()
	clock := testclock.New(start)
	rec := newRecorder()
	b := &books{wallets: map[string]int64{}}
	cfg := Config{
		Category:       variant.Category(),
		Variant:        Variants[variant],
		BootAmount:     200,
		MaxPlayers:     5,
		MinPlayers:     2,
		TurnTimeout:    25 * time.Second,
		NextHandDelay:  4 * time.Second,
		UnfundedGrace:  0,
		MaxMissedTurns: 3,
		MinBuyIn:       400,
		MaxDiscards:    3,
	}
	table := NewTable(TableOptions{
		ID: "room-1", Code: "ROOM0001", Config: cfg, Listener: rec,
		Deps: game.RoomDeps{Clock: clock, Ledger: b.ledger()},
	})
	t.Cleanup(func() { _ = table.Destroy() })
	return &harness{t: t, table: table, clock: clock, rec: rec, books: b, cfg: cfg}
}

func (h *harness) seat(id string, chips int64) {
	h.t.Helper()
	h.books.mu.Lock()
	h.books.wallets[id] = chips
	h.books.mu.Unlock()
	if _, err := h.table.AddPlayer(game.NewPlayer{UserID: id, DisplayName: id, Chips: chips, SocketID: "s-" + id}); err != nil {
		h.t.Fatalf("seat %s: %v", id, err)
	}
}

// read runs fn on the actor.
func (h *harness) read(fn func()) {
	h.t.Helper()
	if err := h.table.run(fn); err != nil {
		h.t.Fatalf("read: %v", err)
	}
}

func (h *harness) deal() {
	h.t.Helper()
	// The countdown armed by the second seat; deal now.
	if err := h.table.StartHand(); err != nil {
		h.t.Fatalf("start: %v", err)
	}
	h.read(func() {
		if h.table.hand == nil {
			h.t.Fatal("no hand dealt")
		}
	})
}

// setCards forces a player's hole cards (the deterministic-showdown seam).
func (h *harness) setCards(id string, codes ...string) {
	h.read(func() {
		s := h.table.findSeat(id)
		s.cards = game.ParseCards(codes)
		if c := h.table.hand.contributions[id]; c != nil {
			c.cards = s.cards
		}
	})
}

// setDeck forces the rest of the deck (board cards, draws) in order.
func (h *harness) setDeck(codes ...string) {
	h.read(func() { h.table.hand.deck = game.ParseCards(codes) })
}

func (h *harness) setDealer(codes ...string) {
	h.read(func() { h.table.hand.dealerCards = game.ParseCards(codes) })
}

func (h *harness) turn() string {
	var id string
	h.read(func() {
		if h.table.hand != nil && h.table.hand.turnSeat >= 0 {
			if s := h.table.seats[h.table.hand.turnSeat]; s != nil {
				id = s.userID
			}
		}
	})
	return id
}

func (h *harness) street() Street {
	var s Street
	h.read(func() {
		if h.table.hand != nil {
			s = h.table.hand.street()
		}
	})
	return s
}

func (h *harness) chips(id string) int64 {
	var n int64
	h.read(func() {
		if s := h.table.findSeat(id); s != nil {
			n = s.chips
		}
	})
	return n
}

func (h *harness) pot() int64 {
	var n int64
	h.read(func() {
		if h.table.hand != nil {
			n = h.table.hand.pot
		}
	})
	return n
}

func (h *harness) act(id string, action Action, amount ...int64) error {
	req := ActRequest{}
	if len(amount) > 0 {
		req.Amount, req.HasAmount = amount[0], true
	}
	_, err := h.table.Act(id, action, req)
	return err
}

func (h *harness) mustAct(id string, action Action, amount ...int64) {
	h.t.Helper()
	if err := h.act(id, action, amount...); err != nil {
		h.t.Fatalf("%s %s %v: %v", id, action, amount, err)
	}
}

func (h *harness) options(id string) Options {
	view, err := h.table.SerializeFor(id)
	if err != nil || view.You == nil || view.You.Options == nil {
		h.t.Fatalf("no options for %s: %v", id, err)
	}
	return *view.You.Options
}

func expectCode(t *testing.T, err error, code string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected %s, got no error", code)
	}
	if got := game.CodeOf(err, "<nil>"); got != code {
		t.Fatalf("expected %s, got %s (%v)", code, got, err)
	}
}

// conservation: the seats plus the pot always equal what the wallets held
// at the deal; after the hand, the wallets equal the seats.
func (h *harness) assertConserved(expectTotal int64) {
	h.t.Helper()
	var seats, pot int64
	h.read(func() {
		for _, s := range h.table.occupiedSeats() {
			seats += s.chips
		}
		if h.table.hand != nil {
			pot = h.table.hand.pot
		}
	})
	if seats+pot != expectTotal {
		h.t.Fatalf("chips created or lost: seats %d + pot %d != %d", seats, pot, expectTotal)
	}
}

func (h *harness) assertWalletsMatchSeats() {
	h.t.Helper()
	h.read(func() {
		if h.table.hand != nil {
			h.t.Fatal("hand still live")
		}
		h.books.mu.Lock()
		defer h.books.mu.Unlock()
		for _, s := range h.table.occupiedSeats() {
			if h.books.wallets[s.userID] != s.chips {
				h.t.Fatalf("%s: wallet %d, seat %d", s.userID, h.books.wallets[s.userID], s.chips)
			}
		}
	})
}

// ------------------------------------------------------------ Hold'em

func TestHoldemDealsBlindsAndOpensToTheSeatAfterTheBigBlind(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, 10_000)
	}
	h.deal()
	started := h.rec.last("handStarted").(HandStartedEvent)
	if started.SmallBlind != 100 || started.BigBlind != 200 || started.Ante != 0 || started.Pot != 300 {
		t.Fatalf("%+v", started)
	}
	// Button at seat 0 (a), small blind b, big blind c, first to act: a.
	if h.turn() != "a" || h.street() != StreetPreflop {
		t.Fatalf("turn %s street %s", h.turn(), h.street())
	}
	if h.chips("b") != 9_900 || h.chips("c") != 9_800 || h.pot() != 300 {
		t.Fatalf("blinds: b %d c %d pot %d", h.chips("b"), h.chips("c"), h.pot())
	}
	for _, id := range []string{"a", "b", "c"} {
		if n := len(h.rec.cards[id]); n != 2 {
			t.Fatalf("%s got %d cards", id, n)
		}
	}
	o := h.options("a")
	if !o.Fold || !o.Call || o.CallAmount != 200 || !o.Raise || o.MinRaise != 400 || o.MaxRaise != 10_000 || o.Check || o.Bet {
		t.Fatalf("%+v", o)
	}
	h.assertConserved(30_000)
}

func TestHoldemPlaysEveryStreetToAShowdownAndPaysTheBestHand(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.setCards("a", "As", "Ad")
	h.setCards("b", "Kh", "Kd")
	h.setCards("c", "7c", "2d")
	h.setDeck("Ac", "Kc", "9h", "3s", "5d")

	// Preflop: a raises to 600, b calls, c folds.
	h.mustAct("a", ActionRaise, 600)
	h.mustAct("b", ActionCall)
	h.mustAct("c", ActionFold)
	if h.street() != StreetFlop {
		t.Fatalf("street %s", h.street())
	}
	flop := h.rec.last("street").(StreetEvent)
	if !equalStrings(flop.Community, []string{"Ac", "Kc", "9h"}) {
		t.Fatalf("flop %v", flop.Community)
	}
	// Postflop the small blind acts first: b.
	if h.turn() != "b" {
		t.Fatalf("turn %s", h.turn())
	}
	h.mustAct("b", ActionCheck)
	h.mustAct("a", ActionBet, 1_000)
	h.mustAct("b", ActionCall)
	if h.street() != StreetTurn {
		t.Fatalf("street %s", h.street())
	}
	h.mustAct("b", ActionCheck)
	h.mustAct("a", ActionCheck)
	if h.street() != StreetRiver {
		t.Fatalf("street %s", h.street())
	}
	h.mustAct("b", ActionCheck)
	h.mustAct("a", ActionCheck)

	ended := h.rec.last("handEnded").(HandEndedEvent)
	if ended.Reason != WinShowdown {
		t.Fatalf("reason %s", ended.Reason)
	}
	// Pot: 200 (c's big blind) + 600 + 600 + 1000 + 1000 = 3400, to a (three aces) over b's three kings.
	if len(ended.Pots) != 1 || ended.Pots[0].Amount != 3_400 || len(ended.Pots[0].Winners) != 1 || ended.Pots[0].Winners[0].UserID != "a" {
		t.Fatalf("pots %+v", ended.Pots)
	}
	if h.chips("a") != 10_000-1_600+3_400 || h.chips("b") != 10_000-1_600 || h.chips("c") != 9_800 {
		t.Fatalf("a %d b %d c %d", h.chips("a"), h.chips("b"), h.chips("c"))
	}
	showdown := h.rec.last("showdown").(ShowdownEvent)
	if len(showdown.Reveals) != 2 {
		t.Fatalf("reveals %+v", showdown.Reveals)
	}
	for _, r := range showdown.Reveals {
		if r.UserID == "a" && (r.HandName != "Three of a Kind" || r.Won != 3_400) {
			t.Fatalf("a's reveal %+v", r)
		}
	}
	h.assertConserved(30_000)
	h.assertWalletsMatchSeats()
	// The ledger: one outcome row each; c's fold checkpointed early.
	h.books.mu.Lock()
	defer h.books.mu.Unlock()
	reasons := map[string]int{}
	for _, row := range h.books.rows {
		reasons[row.Reason]++
		if row.Game != game.GamePoker || row.Variant != game.CategoryTexasHoldem {
			t.Fatalf("row %+v lacks the family", row)
		}
	}
	if reasons[game.LedgerReasonHandWin] != 1 || reasons[game.LedgerReasonHandLoss] != 2 || reasons[game.LedgerReasonHandPacked] != 1 {
		t.Fatalf("reasons %v", reasons)
	}
}

func TestHoldemFoldingToOnePlayerEndsTheHandWithoutAShowdown(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.deal()
	// Heads-up: the button (a) posts the small blind and acts first.
	if h.turn() != "a" || h.chips("a") != 9_900 || h.chips("b") != 9_800 {
		t.Fatalf("turn %s a %d b %d", h.turn(), h.chips("a"), h.chips("b"))
	}
	h.mustAct("a", ActionRaise, 600)
	h.mustAct("b", ActionFold)
	ended := h.rec.last("handEnded").(HandEndedEvent)
	if ended.Reason != WinLastStanding || h.rec.count("showdown") != 0 {
		t.Fatalf("reason %s showdowns %d", ended.Reason, h.rec.count("showdown"))
	}
	if h.chips("a") != 10_200 || h.chips("b") != 9_800 {
		t.Fatalf("a %d b %d", h.chips("a"), h.chips("b"))
	}
	h.assertWalletsMatchSeats()
}

func TestHoldemAllInRunsTheBoardOutAndBuildsSidePots(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 1_000) // short stack
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.setCards("a", "As", "Ad") // best hand, wins the main pot only
	h.setCards("b", "Kh", "Kd")
	h.setCards("c", "7c", "2d")
	h.setDeck("Qc", "Jc", "9h", "3s", "5d")
	// Button a; b small, c big; a acts first and shoves 1,000.
	h.mustAct("a", ActionAllIn)
	// b raises to 3,000, c calls.
	h.mustAct("b", ActionRaise, 3_000)
	h.mustAct("c", ActionCall)
	// b and c still have chips: the flop is dealt and they play on.
	if h.street() != StreetFlop || h.turn() != "b" {
		t.Fatalf("street %s turn %s", h.street(), h.turn())
	}
	h.mustAct("b", ActionCheck)
	h.mustAct("c", ActionCheck)
	h.mustAct("b", ActionCheck)
	h.mustAct("c", ActionCheck)
	h.mustAct("b", ActionCheck)
	h.mustAct("c", ActionCheck)
	ended := h.rec.last("handEnded").(HandEndedEvent)
	if ended.Reason != WinShowdown || len(ended.Pots) != 2 {
		t.Fatalf("%+v", ended)
	}
	// Main pot 3 × 1,000 to a; side pot 2 × 2,000 to b (kings over c's seven-high).
	if ended.Pots[0].Amount != 3_000 || ended.Pots[0].Winners[0].UserID != "a" {
		t.Fatalf("main %+v", ended.Pots[0])
	}
	if ended.Pots[1].Amount != 4_000 || ended.Pots[1].Winners[0].UserID != "b" {
		t.Fatalf("side %+v", ended.Pots[1])
	}
	if h.chips("a") != 3_000 || h.chips("b") != 11_000 || h.chips("c") != 7_000 {
		t.Fatalf("a %d b %d c %d", h.chips("a"), h.chips("b"), h.chips("c"))
	}
	h.assertConserved(21_000)
	h.assertWalletsMatchSeats()
}

func TestHoldemWhenEveryoneIsAllInTheBoardRunsOutWithNoTurns(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 1_000)
	h.seat("b", 1_000)
	h.deal()
	h.setCards("a", "As", "Ad")
	h.setCards("b", "Kh", "Kd")
	h.setDeck("2c", "3c", "9h", "3s", "5d")
	h.mustAct("a", ActionAllIn)
	h.mustAct("b", ActionCall)
	ended, ok := h.rec.last("handEnded").(HandEndedEvent)
	if !ok || ended.Reason != WinShowdown || len(ended.Community) != 5 {
		t.Fatalf("%+v", ended)
	}
	if h.chips("a") != 2_000 || h.chips("b") != 0 {
		t.Fatalf("a %d b %d", h.chips("a"), h.chips("b"))
	}
}

func TestHoldemATieSplitsThePot(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.deal()
	h.setCards("a", "2s", "3d")
	h.setCards("b", "2h", "3c")
	h.setDeck("Ac", "Kc", "Qh", "Js", "Td") // the board plays: both have a broadway straight
	h.mustAct("a", ActionCall)
	h.mustAct("b", ActionCheck)
	for i := 0; i < 3; i++ {
		h.mustAct("b", ActionCheck)
		h.mustAct("a", ActionCheck)
	}
	ended := h.rec.last("handEnded").(HandEndedEvent)
	if len(ended.Pots[0].Winners) != 2 || h.chips("a") != 10_000 || h.chips("b") != 10_000 {
		t.Fatalf("%+v a %d b %d", ended.Pots, h.chips("a"), h.chips("b"))
	}
	// A tie is a share of a contested pot: both are winners with a zero delta.
	h.books.mu.Lock()
	wins := 0
	for _, row := range h.books.rows {
		if row.Reason == game.LedgerReasonHandWin {
			wins++
			if row.Delta != 0 || row.Pot != 200 {
				t.Fatalf("row %+v", row)
			}
		}
	}
	h.books.mu.Unlock()
	if wins != 2 {
		t.Fatalf("%d win rows", wins)
	}
}

func TestHoldemRefusesMovesOffTurnOffStreetAndOutOfRange(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 500) // will be all-in on a call
	h.deal()
	expectCode(t, h.act("b", ActionCall), game.CodeNotYourTurn)
	expectCode(t, h.act("a", ActionCheck), CodeInvalidAction) // facing the big blind
	expectCode(t, h.act("a", ActionBet, 500), CodeInvalidAction)
	expectCode(t, h.act("a", ActionRaise, 300), CodeInvalidAmount)    // below min raise (400)
	expectCode(t, h.act("a", ActionRaise, 20_000), CodeInvalidAmount) // above the stack
	expectCode(t, h.act("a", ActionDraw), CodeInvalidAction)
	expectCode(t, h.act("a", ActionPlay), CodeInvalidAction)
	expectCode(t, h.act("a", "dance"), game.CodeUnknownAction)
	expectCode(t, h.act("zz", ActionCall), game.CodeNotSeated)
	// A replayed action id is refused.
	if _, err := h.table.Act("a", ActionCall, ActRequest{ActionID: "once"}); err != nil {
		t.Fatal(err)
	}
	_, err := h.table.Act("b", ActionCall, ActRequest{ActionID: "once"})
	expectCode(t, err, game.CodeDuplicateAction)
}

func TestHoldemTheClockChecksWhenItCanAndFoldsOtherwiseAndKicksAtThree(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	// a faces the big blind: the clock folds them.
	h.clock.Advance(25 * time.Second)
	act := h.rec.last("action").(ActionEvent)
	if act.UserID != "a" || act.Action != ActionFold || act.Reason != "timeout" {
		t.Fatalf("%+v", act)
	}
	// b (small blind) calls, c (big blind) can check: the clock checks.
	h.mustAct("b", ActionCall)
	if h.turn() != "c" {
		t.Fatalf("turn %s", h.turn())
	}
	h.clock.Advance(25 * time.Second)
	act = h.rec.last("action").(ActionEvent)
	if act.UserID != "c" || act.Action != ActionCheck {
		t.Fatalf("%+v", act)
	}
	if h.street() != StreetFlop {
		t.Fatalf("street %s", h.street())
	}
	var missed int
	h.read(func() { missed = h.table.findSeat("c").missedTurns })
	if missed != 1 {
		t.Fatalf("missed %d", missed)
	}
}

func TestHoldemLeavingMidHandFoldsAndCheckpointsTheStake(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.mustAct("a", ActionRaise, 1_000)
	// b leaves facing the raise: their small blind is gone with them.
	if _, err := h.table.RemovePlayer("b", game.LeaveReasonLeft); err != nil {
		t.Fatal(err)
	}
	if h.turn() != "c" {
		t.Fatalf("turn %s", h.turn())
	}
	h.books.mu.Lock()
	var left *game.SettleEntry
	for i := range h.books.rows {
		if h.books.rows[i].Reason == game.LedgerReasonHandLeft {
			left = &h.books.rows[i]
		}
	}
	h.books.mu.Unlock()
	if left == nil || left.UserID != "b" || left.Delta != -100 || !left.LeftMidHand || !left.Outcome {
		t.Fatalf("leave row %+v", left)
	}
	h.mustAct("c", ActionFold)
	if h.chips("a") != 10_300 {
		t.Fatalf("a %d", h.chips("a"))
	}
	h.assertWalletsMatchSeats()
}

// ------------------------------------------------------------- Omaha

func TestOmahaDealsFourAndCountsExactlyTwo(t *testing.T) {
	h := newHarness(t, Omaha)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.deal()
	if len(h.rec.cards["a"]) != 4 {
		t.Fatalf("%v", h.rec.cards["a"])
	}
	h.setCards("a", "Ah", "Kh", "Qh", "Jh") // four hearts: no flush with one on the board
	h.setCards("b", "2c", "2d", "9s", "8s")
	h.setDeck("Th", "2s", "3d", "4c", "9d")
	h.mustAct("a", ActionCall)
	h.mustAct("b", ActionCheck)
	for i := 0; i < 3; i++ {
		h.mustAct("b", ActionCheck)
		h.mustAct("a", ActionCheck)
	}
	ended := h.rec.last("handEnded").(HandEndedEvent)
	// b holds three deuces (2c 2d + 2s on the board); a has at best a pair/high.
	if ended.Pots[0].Winners[0].UserID != "b" || ended.Pots[0].Winners[0].HandName != "Three of a Kind" {
		t.Fatalf("%+v", ended.Pots[0])
	}
}

// ---------------------------------------------------------- 5-Card Draw

func TestDrawAntesDealsFiveAndExchangesCards(t *testing.T) {
	h := newHarness(t, FiveCardDraw)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.deal()
	started := h.rec.last("handStarted").(HandStartedEvent)
	if started.Ante != 200 || started.Pot != 400 || len(h.rec.cards["a"]) != 5 {
		t.Fatalf("%+v cards %v", started, h.rec.cards["a"])
	}
	if h.street() != StreetPredraw || h.turn() != "b" { // b is left of the button (a)
		t.Fatalf("street %s turn %s", h.street(), h.turn())
	}
	h.setCards("a", "2s", "3d", "9c", "Jh", "Kd")
	h.setCards("b", "Ah", "Ad", "7c", "8h", "4d")
	h.setDeck("As", "Ac", "5d", "6d")
	h.mustAct("b", ActionCheck)
	h.mustAct("a", ActionCheck)
	if h.street() != StreetDraw || h.turn() != "b" {
		t.Fatalf("street %s turn %s", h.street(), h.turn())
	}
	o := h.options("b")
	if !o.Draw || o.MaxDiscards != 3 || o.Fold {
		t.Fatalf("%+v", o)
	}
	// b exchanges three and draws the two aces: four aces.
	if _, err := h.table.Act("b", ActionDraw, ActRequest{Cards: []string{"7c", "8h", "4d"}}); err != nil {
		t.Fatal(err)
	}
	if !equalStrings(h.rec.cards["b"], []string{"Ah", "Ad", "As", "Ac", "5d"}) {
		t.Fatalf("b's new hand %v", h.rec.cards["b"])
	}
	draw := h.rec.last("draw").(DrawEvent)
	if draw.UserID != "b" || draw.Discarded != 3 {
		t.Fatalf("%+v", draw)
	}
	// a may not exchange four, nor a card they do not hold, nor one twice.
	_, err := h.table.Act("a", ActionDraw, ActRequest{Cards: []string{"2s", "3d", "9c", "Jh"}})
	expectCode(t, err, CodeInvalidDiscard)
	_, err = h.table.Act("a", ActionDraw, ActRequest{Cards: []string{"Qs"}})
	expectCode(t, err, CodeInvalidDiscard)
	_, err = h.table.Act("a", ActionDraw, ActRequest{Cards: []string{"2s", "2s"}})
	expectCode(t, err, CodeInvalidDiscard)
	// a stands pat.
	if _, err := h.table.Act("a", ActionDraw, ActRequest{}); err != nil {
		t.Fatal(err)
	}
	if h.street() != StreetPostdraw {
		t.Fatalf("street %s", h.street())
	}
	h.mustAct("b", ActionBet, 500)
	h.mustAct("a", ActionCall)
	ended := h.rec.last("handEnded").(HandEndedEvent)
	if ended.Pots[0].Winners[0].UserID != "b" || ended.Pots[0].Winners[0].HandName != "Four of a Kind" || ended.Pots[0].Amount != 1_400 {
		t.Fatalf("%+v", ended.Pots[0])
	}
	h.assertConserved(20_000)
	h.assertWalletsMatchSeats()
}

func TestDrawTheClockStandsPat(t *testing.T) {
	h := newHarness(t, FiveCardDraw)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.deal()
	h.mustAct("b", ActionCheck)
	h.mustAct("a", ActionCheck)
	before := append([]string(nil), h.rec.cards["b"]...)
	h.clock.Advance(25 * time.Second)
	if !equalStrings(h.rec.cards["b"], before) {
		t.Fatalf("cards changed on a timeout: %v → %v", before, h.rec.cards["b"])
	}
	if h.turn() != "a" || h.street() != StreetDraw {
		t.Fatalf("turn %s street %s", h.turn(), h.street())
	}
}

// -------------------------------------------------------- 3-Card Poker

func TestThreeCardPokerPlaysAgainstTheDealer(t *testing.T) {
	h := newHarness(t, ThreeCardPoker)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	if h.street() != StreetDecision || len(h.rec.cards["a"]) != 3 {
		t.Fatalf("street %s cards %v", h.street(), h.rec.cards["a"])
	}
	view, _ := h.table.SerializeFor("a")
	if view.Poker.Dealer == nil || view.Poker.Dealer.CardCount != 3 || len(view.Poker.Dealer.Cards) != 0 {
		t.Fatalf("dealer %+v", view.Poker.Dealer)
	}
	h.setCards("a", "Ks", "Kh", "2d") // pair: beats the dealer
	h.setCards("b", "7s", "5h", "2c") // seven high: loses
	h.setCards("c", "9s", "8h", "3c") // folds
	h.setDealer("Qs", "Jh", "4d")     // queen high: qualifies
	first := h.turn()
	if first != "b" { // left of the button (a)
		t.Fatalf("first %s", first)
	}
	o := h.options("b")
	if !o.Play || o.PlayAmount != 200 || !o.Fold || o.Call || o.Check {
		t.Fatalf("%+v", o)
	}
	h.mustAct("b", ActionPlay)
	h.mustAct("c", ActionFold)
	h.mustAct("a", ActionPlay)
	ended := h.rec.last("handEnded").(HandEndedEvent)
	if ended.Reason != WinDealer || ended.Dealer == nil || !ended.Dealer.Qualified {
		t.Fatalf("%+v", ended)
	}
	// a: ante 200 + play 200, both paid 1:1 → +400. b: −400. c: −200.
	if h.chips("a") != 10_400 || h.chips("b") != 9_600 || h.chips("c") != 9_800 {
		t.Fatalf("a %d b %d c %d", h.chips("a"), h.chips("b"), h.chips("c"))
	}
	for _, r := range ended.Reveals {
		switch r.UserID {
		case "a":
			if r.Outcome != "win" || r.Won != 800 {
				t.Fatalf("a %+v", r)
			}
		case "b":
			if r.Outcome != "lose" || r.Won != 0 {
				t.Fatalf("b %+v", r)
			}
		}
	}
	h.assertWalletsMatchSeats()
}

func TestThreeCardPokerDealerNotQualifiedPaysTheAnteAndReturnsThePlay(t *testing.T) {
	h := newHarness(t, ThreeCardPoker)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.deal()
	h.setCards("a", "3s", "5h", "2d") // nothing at all
	h.setCards("b", "8s", "6h", "2c")
	h.setDealer("Js", "9h", "4d") // jack high: does not qualify
	h.mustAct("b", ActionPlay)
	h.mustAct("a", ActionPlay)
	if h.chips("a") != 10_200 || h.chips("b") != 10_200 {
		t.Fatalf("a %d b %d", h.chips("a"), h.chips("b"))
	}
	h.assertWalletsMatchSeats()
}

func TestThreeCardPokerATieIsAPush(t *testing.T) {
	h := newHarness(t, ThreeCardPoker)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.deal()
	h.setCards("a", "Qs", "Th", "2d")
	h.setCards("b", "As", "Ah", "2c")
	h.setDealer("Qh", "Td", "2s") // ties a
	h.mustAct("b", ActionPlay)
	h.mustAct("a", ActionPlay)
	if h.chips("a") != 10_000 || h.chips("b") != 10_400 {
		t.Fatalf("a %d b %d", h.chips("a"), h.chips("b"))
	}
	h.assertWalletsMatchSeats()
}

func TestThreeCardPokerTheLastPlayerStillPlaysTheDealer(t *testing.T) {
	h := newHarness(t, ThreeCardPoker)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.deal()
	h.setCards("a", "As", "Ah", "2d")
	h.setDealer("Kh", "Kd", "2s")
	h.mustAct("b", ActionFold)
	if h.street() != StreetDecision || h.turn() != "a" {
		t.Fatalf("street %s turn %s", h.street(), h.turn())
	}
	h.mustAct("a", ActionPlay)
	if h.chips("a") != 10_400 || h.chips("b") != 9_800 {
		t.Fatalf("a %d b %d", h.chips("a"), h.chips("b"))
	}
}

// ------------------------------------------------------------ snapshot

func TestSnapshotRoundTripRestoresAHandMidStreet(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.mustAct("a", ActionRaise, 600)
	h.mustAct("b", ActionCall)
	h.mustAct("c", ActionCall)
	h.mustAct("b", ActionBet, 400)
	snap, err := h.table.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if snap.Game != game.GamePoker || snap.Hand == nil || snap.Hand.StreetIndex != 1 || len(snap.Hand.Community) != 3 {
		t.Fatalf("%+v", snap)
	}
	data, err := h.table.marshalSnapshot(snap.Seq)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := ParseSnapshot(data)
	if err != nil {
		t.Fatal(err)
	}
	rec := newRecorder()
	restored, err := RestoreTable(parsed, TableOptions{Listener: rec, Deps: game.RoomDeps{Clock: h.clock, Ledger: h.books.ledger()}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = restored.Destroy() })
	again, err := restored.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	a, _ := restored.marshalSnapshot(snap.Seq)
	b, _ := h.table.marshalSnapshot(snap.Seq)
	if string(a) != string(b) {
		t.Fatalf("snapshot changed across a restore:\n%s\n%s", a, b)
	}
	if again.Hand.TurnSeat != snap.Hand.TurnSeat {
		t.Fatalf("turn %d vs %d", again.Hand.TurnSeat, snap.Hand.TurnSeat)
	}
	// Play on at the restored table: c is on turn facing b's bet.
	if _, err := restored.Act("c", ActionCall, ActRequest{}); err != nil {
		t.Fatalf("act after restore: %v", err)
	}
	if _, err := restored.Act("a", ActionFold, ActRequest{}); err != nil {
		t.Fatalf("act after restore: %v", err)
	}
	var street Street
	_ = restored.run(func() { street = restored.hand.street() })
	if street != StreetTurn {
		t.Fatalf("street %s", street)
	}
}

func TestSnapshotRefusesAForeignFamilyAndABadCard(t *testing.T) {
	if _, err := ParseSnapshot([]byte(`{"game":"teen_patti","roomId":"x"}`)); err == nil {
		t.Fatal("a Teen Patti document parsed as poker")
	}
	if _, err := ParseSnapshot([]byte(`{"game":"poker","roomId":"x","state":"waiting","config":{"variant":"texas_holdem","maxPlayers":5,"bootAmount":200},"seats":[{"seatIndex":0,"userId":"u","status":"waiting","cards":["Zz"]}]}`)); err == nil {
		t.Fatal("a bad card code parsed")
	}
	if _, err := ParseSnapshot([]byte(`{"game":"poker","roomId":"x","state":"waiting","config":{"variant":"texas_holdem","maxPlayers":5,"bootAmount":200},"seats":[{"seatIndex":0,"userId":"u","status":"waiting","cards":["As"]},{"seatIndex":1,"userId":"v","status":"waiting","cards":["As"]}]}`)); err == nil {
		t.Fatal("one card in two hands parsed")
	}
}

// ---------------------------------------------------------------- room

func TestASeatBelowTheBuyInIsRefusedAndTheViewIsRedacted(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	_, err := h.table.AddPlayer(game.NewPlayer{UserID: "poor", DisplayName: "poor", Chips: 399})
	expectCode(t, err, game.CodeInsufficientChips)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.deal()
	view, err := h.table.SerializeFor("a")
	if err != nil {
		t.Fatal(err)
	}
	if view.Game != game.GamePoker || view.Category != game.CategoryTexasHoldem || view.ChipsHidden || len(view.You.Cards) != 2 {
		t.Fatalf("%+v", view)
	}
	for _, s := range view.Seats {
		if s.UserID == "b" && (s.CardCount != 2 || s.Chips == nil) {
			t.Fatalf("seat b %+v", s)
		}
	}
	if view.Poker.Variant != TexasHoldem || view.Poker.BigBlind != 200 || view.Poker.SmallBlind != 100 || view.Poker.HoleCards != 2 {
		t.Fatalf("%+v", view.Poker)
	}
	stranger, _ := h.table.SerializeFor("nobody")
	if stranger.You != nil {
		t.Fatal("a stranger has a you")
	}
}

func TestDestroyingARoomMidHandRefundsEveryStake(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	h.mustAct("a", ActionRaise, 1_000)
	h.mustAct("b", ActionCall)
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	ended := h.rec.last("handEnded").(HandEndedEvent)
	if ended.Reason != WinAllLeft {
		t.Fatalf("%+v", ended)
	}
	h.books.mu.Lock()
	defer h.books.mu.Unlock()
	for _, id := range []string{"a", "b", "c"} {
		if h.books.wallets[id] != 10_000 {
			t.Fatalf("%s wallet %d", id, h.books.wallets[id])
		}
	}
}
