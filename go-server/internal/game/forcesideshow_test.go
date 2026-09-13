package game

// Force Sideshow (owner, 13 Sep 2026): an ordinary sideshow with the request
// and the answer taken out, paid for with one hammer. The rules pinned here:
// the same eligibility as a sideshow and the same one ask per turn; it resolves
// at once, as an accepted sideshow does; it is paid for before the table
// changes, and a refusal — no hammers, or a wallet that cannot be written —
// changes nothing; a retry is never charged twice, and one hammer buys one
// forced sideshow however often its id is replayed.

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

// forcedTable is sideshowTable with a hammer wallet holding 20 for everyone.
func forcedTable(t *testing.T, count int) (*harness, []string, *MemoryHammers) {
	t.Helper()
	wallet := NewMemoryHammers(nil)
	h := newHarness(t, sideshowConfig(), withLedger(emptyLedger), withHammers(wallet), withID("force-room", "FORCE001"))
	var ids []string
	for i := 0; i < count; i++ {
		id := "p" + string(rune('0'+i))
		ids = append(ids, id)
		wallet.Set(id, 20)
		h.seatNamed(id, strings.ToUpper(id), sideshowStart)
	}
	h.startHand()
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	return h, ids, wallet
}

func force(id string) ActRequest { return ActRequest{ActionID: id} }

// snapshotJSON is the table's full server-side state, for "nothing changed".
func snapshotJSON(t *testing.T, h *harness) string {
	t.Helper()
	return mustJSON(t, mustSnapshot(h))
}

// ------------------------------------------------------------- the outcomes

func TestAForcedSideshowTheAskedPlayerLosesPacksThemAndTheTurnStaysWithTheAsker(t *testing.T) {
	h, _, wallet := forcedTable(t, 3)
	actor := h.turnUser()
	asked := h.rightOf(actor)
	h.setCards(actor, "As", "Ah", "Ad")
	h.setCards(asked, "2s", "7h", "9d")

	opts := h.turnOptions(actor)
	eq(t, opts.CanForceSideshow, true, "canForceSideshow")
	rawOpts, _ := json.Marshal(opts)
	if !strings.Contains(string(rawOpts), `"canForceSideshow":true`) {
		t.Fatalf("options carry canForceSideshow: %s", rawOpts)
	}

	h.advance(20 * time.Second) // 5s left of a 25s turn
	mark := h.rec.count()
	res := h.mustAct(actor, ActionForceSideshow, force("force-1"))

	raw, _ := json.Marshal(res)
	eq(t, string(raw), `{"action":"forceSideshow","toUserId":"`+asked+`","packedUserId":"`+asked+`","hammers":19}`, "ack")
	eq(t, wallet.Balance(actor), int64(19), "one hammer spent")
	eq(t, wallet.Charges(), 1, "charged once")
	eq(t, wallet.Balance(asked), int64(20), "the asked player pays nothing")

	eq(t, len(h.sideshowRequested()), 0, "nobody was asked")
	reveals := h.sideshowReveals()
	eq(t, len(reveals), 1, "one reveal")
	eq(t, strings.Join(reveals[0].UserIDs, ","), actor+","+asked, "to both of them, asker first")
	eq(t, reveals[0].Reveal.Reason, SideshowForced, "reveal says forced")
	eq(t, reveals[0].Reveal.PackedUserID, asked, "reveal packedUserId")
	eq(t, strings.Join(reveals[0].Reveal.Hands[0].Cards, ""), "AsAhAd", "asker's cards first")

	resolved := h.sideshowResolved()
	eq(t, len(resolved), 1, "one resolution")
	eq(t, resolved[0].Accepted, true, "compared")
	eq(t, resolved[0].Reason, SideshowForced, "reason forced")
	eq(t, *resolved[0].PackedUserID, asked, "packed")
	rawResolved, _ := json.Marshal(resolved[0])
	if strings.Contains(string(rawResolved), "As") {
		t.Fatal("what the rest of the table hears carries no cards")
	}

	eq(t, h.mustSeat(asked).Status, SeatPacked, "asked packed")
	eq(t, h.lastAction().Reason, PackReasonSideshow, "the ordinary sideshow pack")
	eq(t, h.mustSeat(actor).Status, SeatActive, "asker active")
	eq(t, h.turnUser(), actor, "the turn never left the asker")
	eq(t, h.sideshowPending(), false, "nothing left pending")
	if h.view(actor).Sideshow != nil {
		t.Fatal("a forced sideshow is never a request in the table state")
	}
	eq(t, h.mustSeat(actor).SideshowAskedThisTurn, true, "the ask for this turn is used")
	eq(t, h.turnOptions(actor).CanSideshow, false, "no ordinary sideshow now")
	eq(t, h.turnOptions(actor).CanForceSideshow, false, "nor a forced one")

	// The same event order as an accepted sideshow the asked player loses.
	eq(t, strings.Join(h.rec.names()[mark:], ","), "sideshowReveal,action,state,sideshowResolved,turn,state", "order")

	// The clock was re-armed in full, as after an accepted sideshow.
	h.advance(25*time.Second - time.Millisecond)
	eq(t, h.turnUser(), actor, "still their turn on the re-armed clock")
	h.advance(time.Millisecond)
	eq(t, h.mustSeat(actor).Status, SeatPacked, "timed out on the re-armed clock")
}

func TestLosingYourOwnForcedSideshowPacksYouAndPassesTheTurnOn(t *testing.T) {
	h, _, wallet := forcedTable(t, 4)
	actor := h.turnUser()
	asked := h.rightOf(actor)
	h.setCards(actor, "2s", "7h", "9d")
	h.setCards(asked, "As", "Ah", "Ad")

	mark := h.rec.count()
	res := h.mustAct(actor, ActionForceSideshow, force("force-lose"))
	eq(t, *res.PackedUserID, actor, "ack says the asker packed")
	eq(t, *res.Hammers, int64(19), "and paid for it")
	eq(t, wallet.Balance(actor), int64(19), "the hammer is spent whoever wins")

	eq(t, h.mustSeat(actor).Status, SeatPacked, "asker packed")
	eq(t, h.mustSeat(asked).Status, SeatActive, "asked active")
	if h.turnUser() == actor {
		t.Fatal("the turn moved off the packed player")
	}
	eq(t, h.sideshowReveals()[0].Reveal.Reason, SideshowForced, "reveal reason")
	eq(t, strings.Join(h.rec.names()[mark:], ","), "sideshowReveal,action,turn,state,state,sideshowResolved,state", "asker-loses order")
}

func TestAForcedSideshowTieGoesAgainstThePlayerWhoForcedIt(t *testing.T) {
	h, _, _ := forcedTable(t, 3)
	actor := h.turnUser()
	asked := h.rightOf(actor)
	h.setCards(actor, "Ks", "Kh", "4d")
	h.setCards(asked, "Kd", "Kc", "4s")

	res := h.mustAct(actor, ActionForceSideshow, force("force-tie"))
	eq(t, *res.PackedUserID, actor, "a tie goes against the asker")
	eq(t, h.mustSeat(actor).Status, SeatPacked, "asker packed on a tie")
	eq(t, h.mustSeat(asked).Status, SeatActive, "asked active")
}

// ------------------------------------------------------------- the refusals

// Every reason an ordinary sideshow is refused refuses a forced one, with the
// same code and message, and not one hammer is spent on any of them.
func TestAForcedSideshowIsRefusedForEveryReasonASideshowIsAndSpendsNothing(t *testing.T) {
	refused := func(t *testing.T, h *harness, wallet *MemoryHammers, id, code, message string) {
		t.Helper()
		before := wallet.Charges()
		_, err := h.act(id, ActionForceSideshow, force("refused-"+code))
		codeIs(t, err, code)
		var ge *GameError
		if errors.As(err, &ge) && message != "" {
			eq(t, ge.Message, message, code+" message")
		}
		eq(t, wallet.Charges(), before, code+": nothing spent")
		if s := h.seatInfo(id); s != nil && h.hasHand() {
			eq(t, h.turnOptions(id).CanForceSideshow, h.turnOptions(id).CanSideshow, code+": same eligibility")
		}
	}

	t.Run("no_hand", func(t *testing.T) {
		wallet := NewMemoryHammers(map[string]int64{"a": 20})
		h := newHarness(t, sideshowConfig(), withLedger(emptyLedger), withHammers(wallet))
		h.seat("a", sideshowStart)
		refused(t, h, wallet, "a", CodeNoHand, MsgNoHand)
	})
	t.Run("not_in_hand", func(t *testing.T) {
		h, _, wallet := forcedTable(t, 3)
		actor := h.turnUser()
		other := h.rightOf(actor)
		h.read(func() { h.table.findSeat(other).status = SeatPacked })
		refused(t, h, wallet, other, CodeNotInHand, MsgNotInHand)
	})
	t.Run("not_your_turn", func(t *testing.T) {
		h, _, wallet := forcedTable(t, 3)
		refused(t, h, wallet, h.rightOf(h.turnUser()), CodeNotYourTurn, MsgNotYourTurn)
	})
	t.Run("sideshow_pending", func(t *testing.T) {
		h, _, wallet := forcedTable(t, 3)
		actor := h.turnUser()
		h.mustAct(actor, ActionSideshow, ActRequest{})
		refused(t, h, wallet, actor, CodeSideshowPending, MsgSideshowPending)
		eq(t, h.sideshowPending(), true, "the standing request is untouched")
	})
	t.Run("already_asked", func(t *testing.T) {
		h, _, wallet := forcedTable(t, 3)
		actor := h.turnUser()
		h.mustAct(actor, ActionSideshow, ActRequest{})
		h.mustRespond(h.rightOf(actor), false)
		refused(t, h, wallet, actor, CodeAlreadyAsked, MsgSideshowAlreadyAsked)
	})
	t.Run("too_few_players", func(t *testing.T) {
		h, _, wallet := forcedTable(t, 2)
		refused(t, h, wallet, h.turnUser(), CodeTooFewPlayers, "A sideshow needs at least 3 players in the hand")
	})
	t.Run("you_are_blind", func(t *testing.T) {
		h, _, wallet := forcedTable(t, 3)
		actor := h.turnUser()
		h.setBlind(actor, true)
		refused(t, h, wallet, actor, CodeYouAreBlind, MsgSideshowYouAreBlind)
	})
	t.Run("no_neighbour", func(t *testing.T) {
		cfg := sideshowConfig()
		cfg.SideshowMinPlayers = 0
		wallet := NewMemoryHammers(map[string]int64{"a": 20, "b": 20, "c": 20})
		h := newHarness(t, cfg, withLedger(emptyLedger), withHammers(wallet))
		for _, id := range []string{"a", "b", "c"} {
			h.seat(id, sideshowStart)
		}
		h.startHand()
		for _, id := range []string{"a", "b", "c"} {
			h.mustAct(id, ActionSee, ActRequest{})
		}
		actor := h.turnUser()
		// Nobody else still betting, without ending the hand.
		h.read(func() {
			for _, s := range h.table.seats {
				if s != nil && s.userID != actor {
					s.status = SeatPacked
				}
			}
		})
		refused(t, h, wallet, actor, CodeNoNeighbour, MsgSideshowNoNeighbour)
	})
	t.Run("neighbour_is_blind", func(t *testing.T) {
		h, _, wallet := forcedTable(t, 3)
		actor := h.turnUser()
		h.setBlind(h.rightOf(actor), true)
		refused(t, h, wallet, actor, CodeNeighbourIsBlind, MsgSideshowNeighbour)
	})
}

func TestAForcedSideshowWithNoHammersIsRefusedAndChangesNothing(t *testing.T) {
	h, _, wallet := forcedTable(t, 3)
	actor := h.turnUser()
	wallet.Set(actor, 0)
	before := snapshotJSON(t, h)
	mark := h.rec.count()

	_, err := h.act(actor, ActionForceSideshow, force("broke-1"))
	codeIs(t, err, CodeNoHammers)
	var ge *GameError
	if errors.As(err, &ge) {
		eq(t, ge.Message, MsgNoHammers, "message")
	}
	eq(t, snapshotJSON(t, h), before, "the table state is exactly as it was")
	eq(t, h.rec.count(), mark, "nobody was told anything")
	eq(t, wallet.Charges(), 0, "nothing spent")
	eq(t, wallet.Balance(actor), int64(0), "still none")

	// The refusal did not use up the turn's ask: an ordinary sideshow is still
	// on offer, and with a hammer the forced one goes through.
	eq(t, h.turnOptions(actor).CanSideshow, true, "canSideshow")
	wallet.Set(actor, 1)
	res := h.mustAct(actor, ActionForceSideshow, force("broke-2"))
	eq(t, *res.Hammers, int64(0), "the ack reports none left, not an absent count")
}

func TestAHammerWalletThatCannotBeWrittenRefusesTheMoveAndChangesNothing(t *testing.T) {
	h, _, wallet := forcedTable(t, 3)
	actor := h.turnUser()
	wallet.Fail = func(HammerSpend) error { return errors.New("connection reset by peer") }
	before := snapshotJSON(t, h)
	mark := h.rec.count()

	_, err := h.act(actor, ActionForceSideshow, force("down-1"))
	codeIs(t, err, CodePersistFailed)
	var ge *GameError
	if errors.As(err, &ge) {
		eq(t, ge.Message, MsgPersistFailed, "message")
	}
	eq(t, snapshotJSON(t, h), before, "the table state is exactly as it was")
	eq(t, strings.Join(h.rec.names()[mark:], ","), "persistError", "only the refused write is reported")
	if e, ok := h.rec.last("persistError").(PersistErrorEvent); !ok || e.Reason != PersistReasonHammerSpend || e.UserID != actor {
		t.Fatalf("persistError %+v", h.rec.last("persistError"))
	}
	eq(t, wallet.Balance(actor), int64(20), "nothing spent")
	eq(t, len(h.sideshowReveals()), 0, "nothing resolved")

	wallet.Fail = nil
	h.mustAct(actor, ActionForceSideshow, force("down-2"))
	eq(t, wallet.Balance(actor), int64(19), "the next try, with the wallet back, is charged once")
}

// ------------------------------------------------------------- idempotency

// A spend that committed but whose answer was lost refuses the move — the
// table cannot know it was paid — and the retry with the same actionId gets
// the forced sideshow it paid for without paying again.
func TestARetriedForceSideshowIsNotChargedTwice(t *testing.T) {
	h, _, wallet := forcedTable(t, 3)
	actor := h.turnUser()
	lose := true
	wallet.LoseAck = func(HammerSpend) bool { return lose }
	before := snapshotJSON(t, h)

	_, err := h.act(actor, ActionForceSideshow, force("retry-1"))
	codeIs(t, err, CodePersistFailed)
	eq(t, wallet.Charges(), 1, "the commit landed")
	eq(t, wallet.Balance(actor), int64(19), "one hammer gone")
	eq(t, snapshotJSON(t, h), before, "but the table did not resolve anything")

	lose = false
	res := h.mustAct(actor, ActionForceSideshow, force("retry-1"))
	eq(t, wallet.Charges(), 1, "the retry is not charged")
	eq(t, wallet.Balance(actor), int64(19), "still one hammer gone")
	eq(t, *res.Hammers, int64(19), "the ack reports the wallet as it stands")
	eq(t, len(h.sideshowResolved()), 1, "and the forced sideshow happened, once")
}

// One hammer buys one forced sideshow: replaying a delivered actionId on a
// later turn of the same hand is refused before the wallet is asked, which
// would otherwise charge nothing (the key is paid) and resolve it all over again.
func TestReplayingADeliveredForceSideshowIsRefusedOnALaterTurn(t *testing.T) {
	h, _, wallet := forcedTable(t, 4)
	actor := h.turnUser()
	h.setCards(actor, "As", "Ah", "Ad")
	h.setCards(h.rightOf(actor), "2s", "7h", "9d")
	h.mustAct(actor, ActionForceSideshow, force("once-1"))

	// The same turn: the ask is used, which is refused first.
	_, err := h.act(actor, ActionForceSideshow, force("once-1"))
	codeIs(t, err, CodeAlreadyAsked)

	h.mustAct(actor, ActionChaal, ActRequest{})
	for h.turnUser() != actor {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	eq(t, h.blockedReason(actor), "", "a fresh turn, a fresh ask")
	mark := h.rec.count()
	_, err = h.act(actor, ActionForceSideshow, force("once-1"))
	codeIs(t, err, CodeDuplicateAction)
	eq(t, h.rec.count(), mark, "nothing happened")
	eq(t, wallet.Charges(), 1, "the wallet was not even asked")
	eq(t, len(h.sideshowResolved()), 1, "one forced sideshow")

	h.mustAct(actor, ActionForceSideshow, force("once-2"))
	eq(t, wallet.Charges(), 2, "a new id is a new hammer")
}

// The spend key names the hand, not only the client's id: the same actionId
// sent in the next hand is a new forced sideshow and a new hammer. A key
// without the hand would find the first hand's spend already paid for and hand
// out a free forced sideshow in every hand after it.
func TestTheSameActionIdInTheNextHandCostsAnotherHammer(t *testing.T) {
	h, ids, wallet := forcedTable(t, 4)
	actor := h.turnUser()
	h.mustAct(actor, ActionForceSideshow, force("every-hand"))
	eq(t, wallet.Balance(actor), int64(19), "the first hand's hammer")

	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	h.advance(sideshowConfig().NextHandDelay)
	eq(t, h.handNo(), 2, "the next hand is dealt")
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	for h.turnUser() != actor {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	eq(t, h.blockedReason(actor), "", "a forced sideshow is allowed again")

	res := h.mustAct(actor, ActionForceSideshow, force("every-hand"))
	eq(t, wallet.Charges(), 2, "a second hammer is taken")
	eq(t, wallet.Balance(actor), int64(18), "from the same player")
	eq(t, *res.Hammers, int64(18), "the ack reports it")
	eq(t, len(h.sideshowResolved()), 2, "one forced sideshow in each hand")
}

// …and names the player. An id this hand delivered is refused duplicate_action
// to everyone before the wallet is asked, but one whose answer was lost was
// never delivered: another player may send the very same actionId later in the
// hand, and it is their forced sideshow and their hammer — not a free ride on
// the spend the first player already paid for.
func TestAnotherPlayersForceSideshowWithTheSameActionIdCostsTheirOwnHammer(t *testing.T) {
	h, _, wallet := forcedTable(t, 4)
	first := h.turnUser()
	wallet.LoseAck = func(req HammerSpend) bool { return req.UserID == first }
	_, err := h.act(first, ActionForceSideshow, force("shared-id"))
	codeIs(t, err, CodePersistFailed)
	eq(t, wallet.Balance(first), int64(19), "the first player's hammer is spent")

	h.mustAct(first, ActionChaal, ActRequest{})
	second := h.turnUser()
	eq(t, h.blockedReason(second), "", "the next player may force a sideshow")
	res := h.mustAct(second, ActionForceSideshow, force("shared-id"))
	eq(t, wallet.Charges(), 2, "a second hammer is taken")
	eq(t, wallet.Balance(second), int64(19), "from the player who forced this one")
	eq(t, *res.Hammers, int64(19), "the ack reports their own count")
	eq(t, wallet.Balance(first), int64(19), "the first player paid once")
}

// ------------------------------------------------------------- once per turn

func TestOneAskPerTurnCoversOrdinaryAndForcedSideshowsAlike(t *testing.T) {
	t.Run("a forced one after an ordinary one", func(t *testing.T) {
		h, _, wallet := forcedTable(t, 3)
		actor := h.turnUser()
		h.mustAct(actor, ActionSideshow, ActRequest{})
		h.mustRespond(h.rightOf(actor), false)
		eq(t, h.turnOptions(actor).CanForceSideshow, false, "no forced sideshow offered")
		_, err := h.act(actor, ActionForceSideshow, force("after-ordinary"))
		codeIs(t, err, CodeAlreadyAsked)
		eq(t, wallet.Charges(), 0, "nothing spent")
	})
	t.Run("an ordinary one after a forced one", func(t *testing.T) {
		h, _, _ := forcedTable(t, 3)
		actor := h.turnUser()
		h.setCards(actor, "As", "Ah", "Ad")
		h.setCards(h.rightOf(actor), "2s", "7h", "9d")
		h.mustAct(actor, ActionForceSideshow, force("before-ordinary"))
		eq(t, h.turnUser(), actor, "still the asker's turn")
		_, err := h.act(actor, ActionSideshow, ActRequest{})
		codeIs(t, err, CodeAlreadyAsked)
		_, err = h.act(actor, ActionForceSideshow, force("twice"))
		codeIs(t, err, CodeAlreadyAsked)
	})
}

// ------------------------------------------------------------- restore

// A table saved just after a forced sideshow comes back from the live store
// knowing the turn's ask is used and which id was paid for.
func TestAForcedSideshowSurvivesASnapshotRoundTrip(t *testing.T) {
	h, _, wallet := forcedTable(t, 4)
	actor := h.turnUser()
	h.setCards(actor, "As", "Ah", "Ad")
	h.setCards(h.rightOf(actor), "2s", "7h", "9d")
	h.mustAct(actor, ActionForceSideshow, force("saved-1"))

	assertRoundTrip(t, h, 0)

	r, err := RestoreTable(roundTrip(t, mustSnapshot(h)), TableOptions{Clock: h.clock, Ledger: NewMemoryLedger(MemoryLedgerHooks{}), Hammers: wallet})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = r.Destroy() }()
	turnUser := func() string {
		t.Helper()
		view, err := r.SerializeFor(actor)
		if err != nil || view.Turn == nil || view.Turn.UserID == nil {
			t.Fatalf("restored turn: %v %+v", err, view)
		}
		return *view.Turn.UserID
	}
	eq(t, turnUser(), actor, "the asker still holds the turn")
	_, err = r.Act(actor, ActionForceSideshow, force("saved-2"))
	codeIs(t, err, CodeAlreadyAsked)

	if _, err := r.Act(actor, ActionChaal, ActRequest{}); err != nil {
		t.Fatal(err)
	}
	for turnUser() != actor {
		if _, err := r.Act(turnUser(), ActionChaal, ActRequest{}); err != nil {
			t.Fatal(err)
		}
	}
	_, err = r.Act(actor, ActionForceSideshow, force("saved-1"))
	codeIs(t, err, CodeDuplicateAction)
	eq(t, wallet.Charges(), 1, "the restored table did not charge the replay")
	if _, err := r.Act(actor, ActionForceSideshow, force("saved-3")); err != nil {
		t.Fatalf("a new id on the restored table: %v", err)
	}
	eq(t, wallet.Charges(), 2, "and a new id is charged through the restored table's wallet")
}

// A table built without a wallet refuses every Force Sideshow rather than
// handing one out free.
func TestATableWithoutAHammerWalletNeverGivesAForcedSideshowAway(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	actor := h.turnUser()
	_, err := h.act(actor, ActionForceSideshow, force("free"))
	codeIs(t, err, CodeNoHammers)
	eq(t, len(h.sideshowResolved()), 0, "nothing resolved")
}
