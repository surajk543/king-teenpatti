package game

import (
	"sync"
	"testing"
	"time"
)

// Player stats v2 (owner, 27 Sep 2026): what a finished hand, or a departure,
// counts for each player — worked out by the table and handed to its
// StatsRecorder only once the write it belongs to has committed.

// statsLog is a StatsRecorder that keeps every call.
type statsLog struct {
	mu    sync.Mutex
	calls [][]HandStats
}

func (l *statsLog) record(stats []HandStats) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls = append(l.calls, append([]HandStats(nil), stats...))
}

// all is every HandStats recorded so far, in order.
func (l *statsLog) all() []HandStats {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []HandStats
	for _, c := range l.calls {
		out = append(out, c...)
	}
	return out
}

func (l *statsLog) callCount() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.calls)
}

// byUser indexes stats by player, failing on a player counted twice.
func statsByUser(t *testing.T, stats []HandStats) map[string]HandStats {
	t.Helper()
	out := map[string]HandStats{}
	for _, s := range stats {
		if _, twice := out[s.UserID]; twice {
			t.Fatalf("%s counted twice in %+v", s.UserID, stats)
		}
		out[s.UserID] = s
	}
	return out
}

func TestEveryCategoryCountsInExactlyOneOfTheThreeBuckets(t *testing.T) {
	for category, want := range map[Category]StatsBucket{
		CategorySeen: StatsTeenPatti, CategoryBlind: StatsTeenPatti, CategoryVariation: StatsVariation,
		CategoryThreeCardPoker: StatsPoker, CategoryFiveCardDraw: StatsPoker, CategoryTexasHoldem: StatsPoker, CategoryOmaha: StatsPoker,
		// An unknown category plays as seen, and counts as Teen Patti.
		Category("mystery"): StatsTeenPatti, Category(""): StatsTeenPatti,
	} {
		eq(t, StatsBucketOf(category), want, string(category))
	}
	eq(t, StatsTeenPatti.CountsHeld(), true, "Teen Patti counts the hand held")
	eq(t, StatsVariation.CountsHeld(), true, "Variation counts the hand held")
	eq(t, StatsPoker.CountsHeld(), false, "Poker does not")
	eq(t, len(StatsBuckets), 3, "three buckets")
}

// The outcome counters follow exactly the rules the checkpoints applied when
// they wrote player_stats themselves (requirement 16; Friends V1).
func TestAnEntryCountsWhatTheCheckpointsAlwaysCounted(t *testing.T) {
	cases := []struct {
		name  string
		entry SettleEntry
		ok    bool
		want  HandStats
	}{
		{"a pack is money only", SettleEntry{UserID: "u", DidChaal: true}, false, HandStats{}},
		{"the winner", SettleEntry{UserID: "u", Outcome: true, IsWinner: true, DidChaal: true, Pot: 900}, true,
			HandStats{UserID: "u", Bucket: StatsTeenPatti, Played: 1, Won: 1, Winnings: 900}},
		{"a loser who bet", SettleEntry{UserID: "u", Outcome: true, DidChaal: true}, true,
			HandStats{UserID: "u", Bucket: StatsTeenPatti, Played: 1, Lost: 1}},
		{"the boot and a fold is not a hand played", SettleEntry{UserID: "u", Outcome: true}, true,
			HandStats{UserID: "u", Bucket: StatsTeenPatti, Lost: 1}},
		{"a departure is left, never lost", SettleEntry{UserID: "u", Outcome: true, DidChaal: true, LeftMidHand: true}, true,
			HandStats{UserID: "u", Bucket: StatsTeenPatti, Played: 1, Left: 1}},
		{"a push is neither won nor lost", SettleEntry{UserID: "u", Outcome: true, Push: true, DidChaal: true}, true,
			HandStats{UserID: "u", Bucket: StatsTeenPatti, Played: 1}},
		{"a loser's pot takes nothing", SettleEntry{UserID: "u", Outcome: true, Pot: 500}, true,
			HandStats{UserID: "u", Bucket: StatsTeenPatti, Lost: 1}},
	}
	for _, c := range cases {
		got, ok := StatsForEntry(c.entry, StatsTeenPatti)
		if ok != c.ok || got != c.want {
			t.Errorf("%s: StatsForEntry = %+v %v, want %+v %v", c.name, got, ok, c.want, c.ok)
		}
	}
	if (HandStats{UserID: "u", Bucket: StatsPoker}).Empty() != true {
		t.Error("a push with no bet counts nothing")
	}
	if (HandStats{UserID: "u", HasHeld: true, Held: HighCard}).Empty() {
		t.Error("a hand held is a count")
	}
}

// A seen hand: every player the hand-end write resolves — the packer too — is
// counted in TEEN_PATTI with the hand they HELD; the pack itself counts
// nothing, and the whole hand is recorded once, after its settle.
func TestASeenHandCountsEveryPlayersHeldHandInTheTeenPattiBucket(t *testing.T) {
	log := &statsLog{}
	cfg := winnerSeenConfig()
	h := newHarness(t, cfg, withLedger(emptyLedger), withStats(log.record))
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, sideshowStart)
	}
	h.advance(cfg.NextHandDelay)
	eq(t, h.handNo(), 1, "dealt")
	held := map[string]HandCategory{"a": Trail, "b": PureSequence, "c": Pair}
	h.setCards("a", "5s", "5h", "5d")
	h.setCards("b", "4c", "5c", "6c")
	h.setCards("c", "9s", "9h", "2d")
	for _, id := range []string{"a", "b", "c"} {
		h.mustAct(id, ActionSee, ActRequest{})
	}

	first := h.turnUser()
	h.mustAct(first, ActionChaal, ActRequest{})
	packer := h.turnUser()
	h.mustAct(packer, ActionPack, ActRequest{})
	eq(t, log.callCount(), 0, "a pack counts nothing: the hand-end write resolves the packer")
	shower := h.turnUser()
	h.mustAct(shower, ActionShow, ActRequest{})

	ended := h.lastEnded()
	winner := *ended.WinnerID
	eq(t, log.callCount(), 1, "the hand is recorded once, after its settle committed")
	got := statsByUser(t, log.all())
	eq(t, len(got), 3, "every player the hand-end write resolves is counted")
	for id, s := range got {
		eq(t, s.Bucket, StatsTeenPatti, id+" counts in Teen Patti")
		eq(t, s.HasHeld, true, id+"'s hand held is counted")
		eq(t, s.Held, held[id], id+"'s hand held")
		eq(t, s.Variation, Variation(""), id+": no variation at a seen table")
		if id == winner {
			eq(t, s.Won, int64(1), "the winner won")
			eq(t, s.Lost, int64(0), "and did not lose")
			eq(t, s.Winnings, ended.Pot, "the winner took the pot")
		} else {
			eq(t, s.Won, int64(0), id+" did not win")
			eq(t, s.Lost, int64(1), id+" lost")
			eq(t, s.Winnings, int64(0), id+" took nothing")
		}
	}
	eq(t, got[first].Played, int64(1), "a chaal is a hand played")
	eq(t, got[shower].Played, int64(1), "so is paying for a show")
	eq(t, got[packer].Played, int64(0), "the boot and a pack is not")
	eq(t, len(h.lastSettled().req.Stats), 3, "the counters rode with the settlement")
}

// A blind table and a private one count in the same bucket as a seen one.
func TestABlindHandCountsInTheTeenPattiBucketToo(t *testing.T) {
	log := &statsLog{}
	cfg := winnerBlindConfig()
	h := newHarness(t, cfg, withLedger(emptyLedger), withStats(log.record))
	h.seat("a", sideshowStart)
	h.seat("b", sideshowStart)
	h.advance(cfg.NextHandDelay)
	h.setCards("a", "Ah", "Kh", "2c")
	h.setCards("b", "7s", "8d", "9c")
	// Neither looks: the server knows the cards all the same.
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	got := statsByUser(t, log.all())
	eq(t, got["a"].Bucket, StatsTeenPatti, "blind is Teen Patti")
	eq(t, got["a"].Held, HighCard, "a blind hand is counted as held")
	eq(t, got["b"].Held, Sequence, "a blind hand is counted as held")
}

// A variation hand counts in VARIATION: the hand held as the table counted it
// — a natural pair and a wild card IS a trail — and the variation it was
// played under, with the winner marked.
func TestAWildCardMakesATrailAndTheVariationIsTallied(t *testing.T) {
	log := &statsLog{}
	h, ids, chooser := variationTable(t, 2, withStats(log.record))
	other := ids[0]
	if other == chooser {
		other = ids[1]
	}
	if _, err := h.table.SelectVariation(chooser, string(VariationAK47)); err != nil {
		t.Fatal(err)
	}
	h.setCards(chooser, "9s", "9h", "Ad") // the ace is wild: a trail of nines
	h.setCards(other, "2c", "5d", "8h")   // nothing wild: high card
	h.mustAct(chooser, ActionSee, ActRequest{})
	h.mustAct(other, ActionSee, ActRequest{})
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})

	ended := h.lastEnded()
	eq(t, *ended.WinnerID, chooser, "the trail wins")
	got := statsByUser(t, log.all())
	eq(t, got[chooser].Bucket, StatsVariation, "a variation table counts in Variation")
	eq(t, got[chooser].Held, Trail, "a pair and a wild card is a trail")
	eq(t, got[chooser].Variation, VariationAK47, "played under AK47")
	eq(t, got[chooser].VariationWon, true, "and won it")
	eq(t, got[other].Held, HighCard, "no wild card: high card")
	eq(t, got[other].Variation, VariationAK47, "every player of the hand is tallied under its variation")
	eq(t, got[other].VariationWon, false, "the loser did not win it")
}

// Under 5-Card the hand held is the THREE that played — the player's choice,
// not the best their five could make.
func TestAFiveCardHandCountsTheThreeThatPlayed(t *testing.T) {
	log := &statsLog{}
	h, ids, chooser := variationTable(t, 2, withStats(log.record))
	other := ids[0]
	if other == chooser {
		other = ids[1]
	}
	h.setCards(chooser, "As", "7d", "Ks")
	h.setExtra(chooser, "7c", "Qs") // A-K-Q of spades was there to be played
	h.setCards(other, "2c", "3d", "9h")
	h.setExtra(other, "Tc", "Jd")
	h.mustAct(chooser, ActionSee, ActRequest{})
	if _, err := h.table.SelectVariation(chooser, string(VariationFiveCard)); err != nil {
		t.Fatal(err)
	}
	if _, err := h.table.SelectCards(chooser, []string{"7d", "7c", "As"}); err != nil {
		t.Fatal(err)
	}
	h.mustAct(other, ActionSee, ActRequest{})
	if _, err := h.table.SelectCards(other, []string{"2c", "3d", "9h"}); err != nil {
		t.Fatal(err)
	}
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})

	got := statsByUser(t, log.all())
	eq(t, got[chooser].Held, Pair, "the pair of sevens they chose, not the pure sequence they held")
	eq(t, got[other].Held, HighCard, "the three they played")
	eq(t, got[chooser].Variation, VariationFiveCard, "tallied under FIVE_CARD")
	eq(t, got[chooser].Won+got[other].Won, int64(1), "one winner")
}

// A hand that ends before its variation is chosen was played under none: it
// counts in VARIATION with the classic hand held and no variation tallied.
func TestAVariationHandThatEndsBeforeTheChoiceTalliesNoVariation(t *testing.T) {
	log := &statsLog{}
	h, ids, chooser := variationTable(t, 2, withStats(log.record))
	other := ids[0]
	if other == chooser {
		other = ids[1]
	}
	h.setCards(chooser, "Qs", "Qh", "3d")
	h.remove(other, LeaveReasonLeft)
	got := log.all()
	// The leaver first, at their leave; then the hand end resolves the chooser.
	byUser := statsByUser(t, got)
	eq(t, byUser[other].Left, int64(1), "the leaver is counted at their leave")
	eq(t, byUser[other].HasHeld, false, "a leaver did not finish the hand")
	eq(t, byUser[chooser].Won, int64(1), "the last player standing won")
	eq(t, byUser[chooser].Held, Pair, "classic rules: no variation was chosen")
	eq(t, byUser[chooser].Variation, Variation(""), "and none is tallied")
}

// A player who leaves mid-hand is counted at their leave checkpoint, once it
// has committed — left, played if they bet, no hand held, no variation — and
// not again at the hand end.
func TestALeaverIsCountedAtTheLeaveAndNotAtTheHandEnd(t *testing.T) {
	log := &statsLog{}
	cfg := winnerSeenConfig()
	h := newHarness(t, cfg, withLedger(emptyLedger), withStats(log.record))
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, sideshowStart)
	}
	h.advance(cfg.NextHandDelay)
	leaver := h.turnUser()
	h.mustAct(leaver, ActionChaal, ActRequest{})
	h.remove(leaver, LeaveReasonLeft)
	eq(t, log.callCount(), 1, "the departure is recorded at once")
	left := log.all()[0]
	eq(t, left, HandStats{UserID: leaver, Bucket: StatsTeenPatti, Played: 1, Left: 1}, "left and played, nothing else")

	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	end := statsByUser(t, log.all()[1:])
	eq(t, len(end), 2, "the hand end resolves the two still at the table")
	if _, again := end[leaver]; again {
		t.Fatal("the leaver was counted again at the hand end")
	}
	for id, s := range end {
		eq(t, s.HasHeld, true, id+"'s hand is counted")
	}
}

// A departure whose checkpoint the ledger refused is not counted: nothing
// committed.
func TestALeaveTheLedgerRefusedCountsNothing(t *testing.T) {
	log := &statsLog{}
	cfg := winnerSeenConfig()
	var refuse bool
	var mu sync.Mutex
	ledger := func(h *harness) Ledger {
		return NewMemoryLedger(MemoryLedgerHooks{
			Checkpoint: func(args CheckpointArgs) error {
				mu.Lock()
				defer mu.Unlock()
				if refuse && args.Entry.Reason == LedgerReasonHandLeft {
					return NewGameError(CodePersistFailed, "down")
				}
				return nil
			},
		})
	}
	h := newHarness(t, cfg, withLedger(ledger), withStats(log.record))
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, sideshowStart)
	}
	h.advance(cfg.NextHandDelay)
	mu.Lock()
	refuse = true
	mu.Unlock()
	h.remove(h.turnUser(), LeaveReasonLeft)
	eq(t, log.callCount(), 0, "a refused leave counts nothing")
}

// A hand-end settle the ledger refused counts nothing until a retry COMMITS —
// once — and a retry answered duplicate_action (a replay of a write that
// landed unheard) counts nothing at all.
func TestAHandIsCountedOnceWhenItsSettleCommitsAndNeverForAReplay(t *testing.T) {
	for _, retryAnswer := range []string{"commit", CodeDuplicateAction} {
		t.Run(retryAnswer, func(t *testing.T) {
			log := &statsLog{}
			cfg := winnerSeenConfig()
			var mu sync.Mutex
			attempts := 0
			ledger := func(h *harness) Ledger {
				return NewMemoryLedger(MemoryLedgerHooks{
					Settle: func(req SettleRequest, entries []SettleEntry) (map[string]int64, error) {
						mu.Lock()
						defer mu.Unlock()
						attempts++
						if attempts == 1 {
							return nil, NewGameError(CodePersistFailed, "the database blinked")
						}
						if retryAnswer == CodeDuplicateAction {
							return nil, NewGameError(CodeDuplicateAction, "That move has already been applied")
						}
						return map[string]int64{}, nil
					},
				})
			}
			h := newHarness(t, cfg, withLedger(ledger), withStats(log.record))
			h.seat("a", sideshowStart)
			h.seat("b", sideshowStart)
			h.advance(cfg.NextHandDelay)
			h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
			h.mustAct(h.turnUser(), ActionPack, ActRequest{})
			eq(t, log.callCount(), 0, "a refused settle counts nothing")

			h.advance(cfg.NextHandDelay) // the first retry
			mu.Lock()
			tried := attempts
			mu.Unlock()
			eq(t, tried, 2, "the settle was retried")
			if retryAnswer == CodeDuplicateAction {
				eq(t, log.callCount(), 0, "a replay's counters were never this call's to count")
			} else {
				eq(t, log.callCount(), 1, "the committed retry counts the hand")
				eq(t, len(log.all()), 2, "both players")
			}
			h.advance(3 * cfg.NextHandDelay)
			if retryAnswer != CodeDuplicateAction {
				eq(t, log.callCount(), 1, "and never again")
			}
		})
	}
}

// A settlement still owed when its table is destroyed is retried off the
// actor, and when that retry commits the hand is counted — once.
func TestAHandSettledAfterItsTableIsGoneIsStillCountedOnce(t *testing.T) {
	log := &statsLog{}
	cfg := winnerSeenConfig()
	var mu sync.Mutex
	attempts := 0
	ledger := func(h *harness) Ledger {
		return NewMemoryLedger(MemoryLedgerHooks{
			Settle: func(req SettleRequest, entries []SettleEntry) (map[string]int64, error) {
				mu.Lock()
				defer mu.Unlock()
				attempts++
				if attempts == 1 {
					return nil, NewGameError(CodePersistFailed, "the database blinked")
				}
				return map[string]int64{}, nil
			},
		})
	}
	h := newHarness(t, cfg, withLedger(ledger), withStats(log.record))
	h.seat("a", sideshowStart)
	h.seat("b", sideshowStart)
	h.advance(cfg.NextHandDelay)
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	eq(t, log.callCount(), 0, "not yet committed")
	h.advance(cfg.NextHandDelay)
	deadline := time.Now().Add(2 * time.Second)
	for h.table.PendingSettlements() > 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	eq(t, log.callCount(), 1, "the detached retry committed and counted the hand")
	eq(t, len(log.all()), 2, "both players")
}

// A taxed win (the winning tax, 26–27 Sep 2026) counts the whole pot once: the
// winner's counters carry the pot they took — gross, as total_winnings always
// has — and the table_tax row the ledger writes beside the win is money only,
// never a second count. The hand is recorded once, after its settle.
func TestATaxedWinCountsThePotOnceAndTheTaxNothing(t *testing.T) {
	log := &statsLog{}
	book := newTaxBook()
	h := newHarness(t, taxConfig(), withLedger(book.ledger), withStats(log.record))
	h.seatAt(book, "a", settleStart, 2000)
	h.seatAt(book, "b", settleStart, 2000)
	h.advance(6 * time.Second)
	packer := h.turnUser()
	h.mustAct(packer, ActionPack, ActRequest{})

	ended := h.lastHandEnded()
	if ended.WinnerID == nil || ended.Tax <= 0 {
		t.Fatalf("the hand was not a taxed win: %+v", ended)
	}
	winner := *ended.WinnerID
	eq(t, log.callCount(), 1, "the hand is recorded once, after its settle committed")
	got := statsByUser(t, log.all())
	eq(t, got[winner].Won, int64(1), "the winner won")
	eq(t, got[winner].Winnings, ended.Pot, "the whole pot, gross of the tax")
	eq(t, got[packer].Lost, int64(1), "the packer lost")
	eq(t, got[packer].Winnings, int64(0), "and took nothing")
	eq(t, len(got), 2, "the tax adds no one and nothing")
}
