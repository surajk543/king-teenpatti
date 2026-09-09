package game

// Port of server/test/tableRules.test.js (requirements 15 and 19) and
// server/test/seatKeeping.test.js (requirements 31 and 32).
//
// tableRules.test.js built some tables through RoomManager to pick up the
// per-category rules; here those tables are built directly with the exact
// config RoomManager._createTable produces (roomManager.js:100-151 with the
// config defaults) so this file does not depend on roommanager.go. The
// RoomManager suite is expected to assert that CreateTable produces these
// values.

import (
	"encoding/json"
	"regexp"
	"testing"
	"time"
)

const (
	rulesBoot  int64 = 200
	rulesStart int64 = 200000
)

func rulesConfig() TableConfig {
	return TableConfig{
		Category:           CategorySeen,
		BootAmount:         rulesBoot,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        25 * time.Second,
		MaxBetRounds:       20,
		PotLimitMultiplier: 1024,
		MaxRaiseSteps:      8,
		NextHandDelay:      6 * time.Second,
		ChatMaxHistory:     100,
		ChatMaxLength:      140,
	}
}

// productionConfig is what RoomManager._createTable hands a PUBLIC table of
// the given category with the default env (config/index.js defaults).
func productionConfig(category Category, boot int64) TableConfig {
	cfg := TableConfig{
		Category:           category,
		BootAmount:         boot,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        25 * time.Second,
		MaxBetRounds:       20,
		PotLimitMultiplier: 1024,
		MaxRaiseSteps:      8,
		MaxBlindMoves:      4,
		MaxMissedTurns:     3,
		SideshowTimeout:    6 * time.Second,
		SideshowMinPlayers: 3,
		NextHandDelay:      4 * time.Second,
		ChatMaxHistory:     100,
		ChatMaxLength:      140,
	}
	if category == CategorySeen {
		cfg.MaxRaiseSteps = 2  // SEEN_MAX_RAISE_STEPS
		cfg.MaxBetRounds = 7   // SEEN_MAX_BET_ROUNDS
		cfg.MaxPot = 1_200_000 // SEEN_MAX_POT
	} else {
		cfg.MaxRaiseSteps = 0      // BLIND_MAX_RAISE_STEPS
		cfg.MaxBetRounds = 0       // BLIND_MAX_BET_ROUNDS
		cfg.PotLimitMultiplier = 0 // BLIND_POT_LIMIT_MULTIPLIER
		cfg.MaxPot = 0
	}
	return cfg
}

func rulesTable(t *testing.T) *harness {
	return newHarness(t, rulesConfig(), withID("rules-room", "RULE01"))
}

// ------------------------------- requirement 15: everybody leaves the table

func TestWhenAPlayerLeavesMidHandTheOneStillSittingTakesThePot(t *testing.T) {
	h := rulesTable(t)
	h.seatNamed("alice", "ALICE", rulesStart)
	h.seatNamed("bob", "BOB", rulesStart)
	h.advance(6 * time.Second)

	first := h.turnUser()
	h.mustAct(first, ActionChaal, ActRequest{})
	potBefore := h.pot()
	other := h.otherActive(first)

	h.remove(first, LeaveReasonLeft)

	result := h.lastHandEnded()
	eq(t, result.Reason, WinLastStanding, "reason")
	eq(t, *result.WinnerID, other, "the player still at the table takes it")
	eq(t, *result.WinnerName, h.mustSeat(other).DisplayName, "winnerName from the seat")
	eq(t, result.Pot, potBefore, "pot")
	// The leaver was resolved at their own checkpoint, so only the winner is
	// in the hand-end write, and their delta is the pot less their own stake.
	entries := h.lastSettled().entries
	eq(t, len(entries), 1, "only the player still at the table")
	eq(t, entries[0].UserID, other, "the winner")
	eq(t, entries[0].Delta, potBefore-h.mustSeat(other).Contributed, "the pot less their own stake")
}

func TestDestroyingATableMidHandPaysThePotOutRatherThanVoidingIt(t *testing.T) {
	h := rulesTable(t)
	for _, id := range []string{"a", "b", "c"} {
		h.seatNamed(id, id, rulesStart)
	}
	h.advance(6 * time.Second)

	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	pot := h.pot()
	stillIn := h.activeIDs()

	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}

	result := h.lastHandEnded()
	eq(t, result.Reason, WinAllLeft, "reason")
	if !contains(stillIn, *result.WinnerID) {
		t.Fatal("a player who was still in the hand receives it")
	}
	eq(t, *result.WinnerID, stillIn[0], "the lowest active seat wins on destroy")
	eq(t, result.Pot, pot, "the whole pot is paid out")
	eq(t, sumDeltas(h.lastSettled().entries), int64(0), "no chips are created or destroyed")
	eq(t, h.table.Destroyed(), true, "destroyed")
	eq(t, h.clock.Pending(), 0, "every timer stopped")
}

func TestSuccessiveDeparturesHandThePotToWhoeverIsStillInTheHand(t *testing.T) {
	h := rulesTable(t)
	for _, id := range []string{"a", "b", "c"} {
		h.seatNamed(id, id, rulesStart)
	}
	h.advance(6 * time.Second)

	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	active := h.activeIDs()

	h.remove(active[0], LeaveReasonLeft)
	eq(t, h.hasHand(), true, "the hand continues with two players")

	potBefore := h.pot()
	h.remove(active[1], LeaveReasonLeft)

	eq(t, h.hasHand(), false, "the hand is over")
	eq(t, *h.lastHandEnded().WinnerID, active[2], "the remaining player takes it")
	eq(t, h.lastHandEnded().Pot, potBefore, "pot")
}

func TestTheLeaveReasonIsEchoedAsThePackReason(t *testing.T) {
	h := rulesTable(t)
	h.seatNamed("a", "A", rulesStart)
	h.seatNamed("b", "B", rulesStart)
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})

	first := h.turnUser()
	second := h.otherActive(first)
	info := h.remove(first, LeaveReasonDisconnected)
	eq(t, info.Status, SeatPacked, "the detached seat reads packed")

	ended := h.lastHandEnded()
	eq(t, ended.Reason, WinLastStanding, "reason")
	eq(t, *ended.WinnerID, second, "winner")
	pack := h.lastAction()
	eq(t, pack.Action, ActionPack, "leaving mid-hand is a pack")
	eq(t, pack.Reason, LeaveReasonDisconnected, "the leave reason is the pack reason")
	eq(t, pack.UserID, first, "of the leaver")
	for _, e := range h.lastSettled().entries {
		if e.UserID == first {
			eq(t, e.LeftMidHand, true, "leaver flagged")
			eq(t, e.IsWinner, false, "leaver did not win")
		}
	}
	// Removing someone who is not seated is a quiet nil.
	gone, err := h.table.RemovePlayer("nobody", LeaveReasonLeft)
	if err != nil || gone != nil {
		t.Fatalf("remove of a stranger: %v %v", gone, err)
	}
}

func TestAllLeftWinnerNameFromContribution(t *testing.T) {
	// Build the all_left path explicitly: two active players; the first leaves
	// → the hand ends last_standing. To reach all_left the hand must still be
	// live with zero active seats, which destroy() reaches when the one
	// remaining active player is removed by RemovePlayer... which ends the
	// hand. So the only real producer is destroy() after the sole active seat
	// has been vacated *within the same mutation* — impossible from outside.
	// Instead exercise resolveIfOnlyOneLeft directly on the actor.
	h := rulesTable(t)
	h.seatNamed("a", "A", rulesStart)
	h.seatNamed("b", "B", rulesStart)
	h.advance(6 * time.Second)
	h.read(func() {
		// Vacate both seats without ending the hand, marking b as the last leaver.
		for _, id := range []string{"a", "b"} {
			s := h.table.findSeat(id)
			s.status = SeatPacked
			h.table.syncContribution(s, SeatPacked)
			h.table.hand.contributions[id].leftMidHand = true
			h.table.seats[s.seatIndex] = nil
		}
		h.table.refreshPlayerCount()
		departed := "b"
		h.table.hand.lastDeparture = &departed
		h.table.resolveIfOnlyOneLeft()
	})
	ended := h.lastHandEnded()
	eq(t, ended.Reason, WinAllLeft, "all_left")
	eq(t, *ended.WinnerID, "b", "the last leaver is paid")
	eq(t, *ended.WinnerName, "B", "winnerName from the contribution record")
	// The departed winner is written at the hand end even though they have no
	// seat: their leave checkpoint took their stake, and the pot still has to
	// reach them.
	record := h.lastSettled()
	for _, e := range record.entries {
		switch e.UserID {
		case "b":
			eq(t, e.IsWinner, true, "b wins")
			eq(t, e.Reason, LedgerReasonHandWin, "reason")
			eq(t, e.Delta, ended.Pot-rulesBoot, "the pot reaches the departed winner, less the boot already written at their leave")
		case "a":
			t.Fatal("a left mid-hand and was resolved at their own checkpoint")
		}
	}
	for _, row := range ended.Summary {
		if row.UserID == "b" {
			eq(t, row.Status, SeatWon, "departed winner's record marked won")
		}
	}
}

func TestAPlayerWhoLeavesMidHandIsFlaggedForTheAbandonedCounter(t *testing.T) {
	h := rulesTable(t)
	for _, id := range []string{"a", "b", "c"} {
		h.seatNamed(id, id, rulesStart)
	}
	h.advance(6 * time.Second)

	quitter := h.turnUser()
	h.mustAct(quitter, ActionChaal, ActRequest{})
	h.remove(quitter, LeaveReasonLeft)
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})

	// A player who leaves is resolved at their OWN checkpoint (that is where
	// hands_left_mid is counted) and is not in the hand-end write.
	for _, e := range h.lastSettled().entries {
		if e.UserID == quitter {
			t.Fatal("a player who left must not be written again at the hand end")
		}
	}
	entry := h.lastCheckpointFor(quitter)
	eq(t, entry.Reason, LedgerReasonHandLeft, "reason")
	eq(t, entry.Outcome, true, "it resolves them")
	eq(t, entry.LeftMidHand, true, "flagged as abandoned")
	eq(t, entry.DidChaal, true, "they had bet, so it counts as played")
	eq(t, entry.IsWinner, false, "not the winner")
}

func TestAPlayerWhoOnlyPostsTheBootIsNotMarkedAsHavingPlayed(t *testing.T) {
	h := rulesTable(t)
	h.seatNamed("alice", "ALICE", rulesStart)
	h.seatNamed("bob", "BOB", rulesStart)
	h.advance(6 * time.Second)

	packer := h.turnUser()
	h.mustAct(packer, ActionPack, ActRequest{})

	for _, e := range h.lastSettled().entries {
		if e.UserID == packer {
			eq(t, e.DidChaal, false, "the boot alone is not a hand played")
			eq(t, e.LeftMidHand, false, "not abandoned")
		}
	}
}

func TestBettingMarksTheHandAsPlayed(t *testing.T) {
	h := rulesTable(t)
	h.seatNamed("alice", "ALICE", rulesStart)
	h.seatNamed("bob", "BOB", rulesStart)
	h.advance(6 * time.Second)

	better := h.turnUser()
	h.mustAct(better, ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})

	for _, e := range h.lastSettled().entries {
		if e.UserID == better {
			eq(t, e.DidChaal, true, "played")
		}
	}
}

func TestAPaidShowCountsAsPlayed(t *testing.T) {
	h := rulesTable(t)
	h.seatNamed("alice", "ALICE", rulesStart)
	h.seatNamed("bob", "BOB", rulesStart)
	h.advance(6 * time.Second)
	caller := h.turnUser()
	h.mustAct(caller, ActionShow, ActRequest{})
	for _, e := range h.lastSettled().entries {
		if e.UserID == caller {
			eq(t, e.DidChaal, true, "a show is a bet beyond the boot")
		} else {
			eq(t, e.DidChaal, false, "the other only posted the boot")
		}
	}
}

// --------------------------- requirement 19: seen tables play tighter

func TestASeenTableAllowsASingleDoublePerTurn(t *testing.T) {
	h := newHarness(t, productionConfig(CategorySeen, rulesBoot), withLedger(emptyLedger))
	h.seatNamed("a", "A", rulesStart)
	h.seatNamed("b", "B", rulesStart)
	h.startHand()

	player := h.turnUser()
	steps := h.betOptions(player).Steps
	eq(t, len(steps), 2, "the chaal and one double, nothing further")
	stepsEqual(t, steps, rulesBoot, rulesBoot*2)
	_, err := h.act(player, ActionRaise, amt(rulesBoot*4))
	codeIs(t, err, CodeInvalidBet)
}

func TestABlindTableKeepsTheFullDoublingLadder(t *testing.T) {
	h := newHarness(t, productionConfig(CategoryBlind, rulesBoot), withLedger(emptyLedger))
	h.seatNamed("a", "A", rulesStart)
	h.seatNamed("b", "B", rulesStart)
	h.startHand()

	opts := h.betOptions(h.turnUser())
	if len(opts.Steps) <= 2 {
		t.Fatal("blind tables can keep doubling")
	}
	eq(t, opts.Steps[2], rulesBoot*4, "third rung")
	if len(opts.Steps) <= 8 {
		t.Fatalf("runs past the eight rungs of a capped ladder (%d)", len(opts.Steps))
	}
	chips := h.mustSeat(h.turnUser()).Chips
	if *opts.Max > chips || *opts.Max*2 <= chips {
		t.Fatalf("max %d must be the largest rung inside %d", *opts.Max, chips)
	}
	eq(t, h.table.MaxPot(), int64(0), "0 is how the table says uncapped")
	eq(t, h.view("a").MaxPot, int64(0), "reported uncapped")
}

func TestABlindTableNeverForcesAShowdownHoweverLongTheBettingGoesOn(t *testing.T) {
	h := newHarness(t, productionConfig(CategoryBlind, rulesBoot), withLedger(emptyLedger))
	h.seatNamed("a", "A", rulesStart)
	h.seatNamed("b", "B", rulesStart)
	h.startHand()

	for i := 0; i < 120 && h.hasHand(); i++ {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	eq(t, h.hasHand(), true, "the hand is still live after 60 rounds each")
	if h.round() < 50 {
		t.Fatalf("rounds counted: %d", h.round())
	}
	eq(t, len(h.rec.all("handEnded")), 0, "nothing but a pack or a show ends a blind hand")
}

func TestASeenTableForcesAShowdownAfter7Rounds(t *testing.T) {
	cfg := productionConfig(CategorySeen, rulesBoot)
	eq(t, cfg.MaxBetRounds, 7, "seven turns each, then everyone shows")
	h := newHarness(t, cfg, withLedger(emptyLedger))
	h.seatNamed("a", "A", rulesStart)
	h.seatNamed("b", "B", rulesStart)
	h.startHand()

	chaals := 0
	for i := 0; i < 60 && h.hasHand(); i++ {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
		chaals++
	}
	eq(t, h.hasHand(), false, "the hand ended on its own")
	eq(t, chaals, 14, "seven bets each")
	eq(t, h.lastHandEnded().Reason, WinForcedShowdown, "reason")
	eq(t, len(h.lastShowdown().Reveals), 2, "everybody's cards are shown")
	if h.lastHandEnded().WinnerID == nil {
		t.Fatal("the pot goes to the best hand")
	}
}

func TestRoundsCountByDistanceWhenTheOpenerHasPacked(t *testing.T) {
	// startSeat never changes; a round is counted whenever the turn steps over
	// it, even after that player has folded (spec §13).
	cfg := rulesConfig()
	cfg.MaxBetRounds = 3
	h := newHarness(t, cfg)
	for _, id := range []string{"a", "b", "c"} {
		h.seatNamed(id, id, rulesStart)
	}
	h.advance(6 * time.Second)
	opener := h.turnUser()
	h.mustAct(opener, ActionPack, ActRequest{}) // round 0, turn to next
	eq(t, h.round(), 0, "no round yet")
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{}) // steps over the (packed) opener → round 1
	eq(t, h.round(), 1, "round counted stepping over the packed opener")
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	eq(t, h.round(), 2, "round 2")
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{}) // round 3 → forced showdown
	eq(t, h.hasHand(), false, "forced showdown at the cap")
	eq(t, h.lastHandEnded().Reason, WinForcedShowdown, "reason")
}

func TestTheShowdownRevealsEveryRemainingPlayerToEveryone(t *testing.T) {
	h := rulesTable(t)
	h.seatNamed("alice", "ALICE", rulesStart)
	h.seatNamed("bob", "BOB", rulesStart)
	h.advance(6 * time.Second)

	h.mustAct(h.turnUser(), ActionShow, ActRequest{})
	showdown := h.lastShowdown()
	eq(t, len(showdown.Reveals), 2, "both")
	won := 0
	for _, r := range showdown.Reveals {
		eq(t, len(r.Cards), 3, "three cards per player")
		if r.HandName == "" {
			t.Fatal("hand name present")
		}
		if r.Won {
			won++
		}
	}
	eq(t, won, 1, "exactly one winner")
	// handEnded carries the same reveals and the summary has both hands.
	ended := h.lastHandEnded()
	eq(t, len(ended.Reveals), 2, "handEnded reveals")
	for _, row := range ended.Summary {
		eq(t, len(row.Cards), 3, "summary cards for revealed players")
	}
}

func TestForcedShowdownTiePrefersTheSeatNearestTheDealer(t *testing.T) {
	// No show payer: exact ties go to the dealer's own seat first (distance
	// 0), then the dealer's left (spec §14).
	cfg := rulesConfig()
	cfg.MaxBetRounds = 1
	h := newHarness(t, cfg)
	h.seatNamed("a", "A", rulesStart)
	h.seatNamed("b", "B", rulesStart)
	h.seatNamed("c", "C", rulesStart)
	h.advance(6 * time.Second)
	dealer := h.dealerSeat()
	eq(t, dealer, 0, "first dealer is the lowest seat")
	h.setCards("a", "As", "9s", "4s")
	h.setCards("b", "Ah", "9h", "4h")
	h.setCards("c", "Ad", "9d", "4d")
	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	eq(t, h.lastHandEnded().Reason, WinForcedShowdown, "reason")
	eq(t, *h.lastHandEnded().WinnerID, "a", "the dealer's own seat wins a three-way tie")
}

// ------------------------------------------------------ seatKeeping.test.js

const (
	seatBoot    int64 = 200
	seatStart   int64 = 50000
	seatTimeout       = 25 * time.Second
)

func seatConfig() TableConfig {
	return TableConfig{
		Category:           CategorySeen,
		BootAmount:         seatBoot,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        seatTimeout,
		MaxBetRounds:       40,
		PotLimitMultiplier: 1024,
		MaxRaiseSteps:      8,
		MaxBlindMoves:      4,
		MaxMissedTurns:     3,
		NextHandDelay:      6 * time.Second,
		ChatMaxHistory:     100,
		ChatMaxLength:      140,
	}
}

func seatTable(t *testing.T) *harness {
	return newHarness(t, seatConfig(), withKickHandler(), withID("seat-room", "SEAT01"))
}

func TestThreeMissedTurnsInARowLosesTheSeat(t *testing.T) {
	h := seatTable(t)
	h.seatNamed("alice", "ALICE", seatStart)
	h.seatNamed("bob", "BOB", seatStart)
	h.seatNamed("carol", "CAROL", seatStart)
	h.advance(6 * time.Second)

	idler := h.turnUser()
	for round := 0; round < 12 && h.seatInfo(idler) != nil; round++ {
		if !h.hasHand() {
			h.advance(6 * time.Second)
		}
		if !h.hasHand() {
			break
		}
		for guard := 0; h.hasHand() && h.turnUser() != idler && guard < 80; guard++ {
			h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
		}
		if !h.hasHand() {
			continue
		}
		before := h.mustSeat(idler).MissedTurns
		h.advance(seatTimeout + 10*time.Millisecond)
		h.waitKicks()
		if before < 2 {
			if h.seatInfo(idler) == nil {
				t.Fatalf("still seated after %d miss(es)", before+1)
			}
			eq(t, h.mustSeat(idler).MissedTurns, before+1, "misses accumulate across hands")
		}
	}

	kicks := h.kickEvents()
	eq(t, len(kicks), 1, "shown out exactly once")
	eq(t, kicks[0].UserID, idler, "the idler")
	eq(t, kicks[0].Reason, KickReasonIdle, "reason")
	if !regexp.MustCompile(`(?i)missed turns`).MatchString(kicks[0].Message) {
		t.Fatalf("message %q", kicks[0].Message)
	}
	eq(t, kicks[0].Message, "Left the table after 3 missed turns", "verbatim message")
	if h.seatInfo(idler) != nil {
		t.Fatal("the seat is free again")
	}
}

func TestAPlayerIsToldTheirOwnMissedTurnCountAndNobodyElseIs(t *testing.T) {
	h := seatTable(t)
	h.seatNamed("alice", "ALICE", seatStart)
	h.seatNamed("bob", "BOB", seatStart)
	h.seatNamed("carol", "CAROL", seatStart)
	h.advance(6 * time.Second)

	idler := h.turnUser()
	var other string
	for _, id := range []string{"alice", "bob", "carol"} {
		if id != idler {
			other = id
			break
		}
	}
	mine := h.view(idler).You
	eq(t, mine.MissedTurns, 0, "nothing missed yet")
	eq(t, mine.MaxMissedTurns, 3, "the allowance, so the warning can count down")

	h.advance(seatTimeout + 10*time.Millisecond)
	eq(t, h.view(idler).You.MissedTurns, 1, "one miss")

	theirs, _ := json.Marshal(h.view(other).Seats)
	if regexp.MustCompile(`missedTurns`).Match(theirs) {
		t.Fatal("the count is in `you` and nowhere in what anyone else receives")
	}
}

func TestPlayingATurnClearsTheMissedTurnCount(t *testing.T) {
	h := seatTable(t)
	h.seatNamed("alice", "ALICE", seatStart)
	h.seatNamed("bob", "BOB", seatStart)
	h.seatNamed("carol", "CAROL", seatStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	h.advance(seatTimeout + 10*time.Millisecond)
	eq(t, h.mustSeat(player).MissedTurns, 1, "one miss")

	for h.hasHand() && h.turnUser() != player {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	if !h.hasHand() {
		h.advance(6 * time.Second)
	}
	// missedTurns survives the new deal.
	eq(t, h.mustSeat(player).MissedTurns, 1, "not reset by a new hand")
	for h.hasHand() && h.turnUser() != player {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	if h.hasHand() && h.mustSeat(player).Status == SeatActive {
		h.mustAct(player, ActionChaal, ActRequest{})
		eq(t, h.mustSeat(player).MissedTurns, 0, "the slate is wiped")
	} else {
		t.Fatal("expected the player to get a turn")
	}
	eq(t, len(h.kickEvents()), 0, "nobody was shown out")
}

func TestAnOffTurnSeeAlsoClearsTheMissedTurnCount(t *testing.T) {
	// Spec §9.4: any successful act — including an off-turn SEE — resets it.
	h := seatTable(t)
	h.seatNamed("alice", "ALICE", seatStart)
	h.seatNamed("bob", "BOB", seatStart)
	h.seatNamed("carol", "CAROL", seatStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	h.advance(seatTimeout + 10*time.Millisecond)
	eq(t, h.mustSeat(player).MissedTurns, 1, "one miss")
	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	h.advance(6 * time.Second)
	eq(t, h.hasHand(), true, "next hand")
	if h.turnUser() == player {
		// make sure it is off turn
		h.mustAct(player, ActionChaal, ActRequest{})
		eq(t, h.mustSeat(player).MissedTurns, 0, "reset by the chaal")
		return
	}
	h.mustAct(player, ActionSee, ActRequest{})
	eq(t, h.mustSeat(player).MissedTurns, 0, "reset by an off-turn see")
}

func TestAPlayerWhoCannotCoverTheBootIsShownOutBetweenHands(t *testing.T) {
	h := seatTable(t)
	h.seatNamed("alice", "ALICE", seatStart)
	h.seatNamed("bob", "BOB", seatStart)
	broke := h.seatNamed("carol", "CAROL", seatBoot-1)
	if broke == nil {
		t.Fatal("was seated to begin with")
	}
	// The sweep in maybeStart (from addPlayer) asks for the kick straight away.
	h.advance(6 * time.Second)
	h.waitKicks()

	kicks := h.kickEvents()
	eq(t, len(kicks), 1, "kicked once (kickPending)")
	eq(t, kicks[0].UserID, "carol", "carol")
	eq(t, kicks[0].Reason, KickReasonInsufficientChips, "reason")
	if !regexp.MustCompile(`(?i)enough coins`).MatchString(kicks[0].Message) {
		t.Fatalf("message %q", kicks[0].Message)
	}
	eq(t, kicks[0].Message, KickMessageInsufficientChips, "verbatim")
	if h.seatInfo("carol") != nil {
		t.Fatal("seat freed")
	}
	eq(t, h.hasHand(), true, "the other two play on")
}

func TestAPlayerIsNeverShownOutMidHandForBeingAllIn(t *testing.T) {
	h := seatTable(t)
	h.seatNamed("alice", "ALICE", seatStart)
	h.seatNamed("bob", "BOB", seatBoot)
	h.advance(6 * time.Second)
	h.waitKicks()

	eq(t, h.mustSeat("bob").Chips, int64(0), "all in on the ante")
	eq(t, len(h.kickEvents()), 0, "still at the table while the hand runs")
	eq(t, h.hasHand(), true, "the hand is live")
}

func TestTheSweepRunsAgainOnceTheHandIsOver(t *testing.T) {
	h := seatTable(t)
	h.seatNamed("alice", "ALICE", seatStart)
	h.seatNamed("bob", "BOB", seatBoot)
	h.advance(6 * time.Second)

	for h.hasHand() {
		player := h.turnUser()
		action := ActionChaal
		if player == "bob" {
			action = ActionPack
		}
		h.mustAct(player, action, ActRequest{})
	}
	h.advance(6 * time.Second)
	h.waitKicks()

	found := false
	for _, k := range h.kickEvents() {
		if k.UserID == "bob" && k.Reason == KickReasonInsufficientChips {
			found = true
		}
	}
	eq(t, found, true, "the busted player was shown out")
	if h.seatInfo("bob") != nil {
		t.Fatal("bob's seat is free")
	}
}

func TestATableThatEmptiesOutDoesNotThrow(t *testing.T) {
	h := seatTable(t)
	h.seatNamed("alice", "ALICE", seatBoot-1)
	h.seatNamed("bob", "BOB", seatBoot-1)
	h.advance(12 * time.Second)
	h.waitKicks()
	eq(t, h.table.PlayerCount(), 0, "both were shown out")
	eq(t, len(h.kickEvents()), 2, "each kicked exactly once")
	eq(t, h.state(), TableWaiting, "waiting")
}

func TestKickPendingStopsASecondSweepAskingTwice(t *testing.T) {
	// No kick handler: the seat stays, and repeated sweeps must not repeat
	// the kick (table.js:688-689).
	h := newHarness(t, seatConfig())
	h.seatNamed("alice", "ALICE", seatStart)
	h.seatNamed("broke", "BROKE", seatBoot-1)
	eq(t, len(h.kickEvents()), 1, "asked once")
	h.seatNamed("bob", "BOB", seatStart) // another maybeStart → another sweep
	eq(t, len(h.kickEvents()), 1, "not asked again")
	h.advance(6 * time.Second) // startHand sweeps too
	eq(t, len(h.kickEvents()), 1, "still once")
	eq(t, h.mustSeat("broke").KickPending, true, "flag set")
}

func TestMaxMissedTurnsOfZeroNeverKicks(t *testing.T) {
	cfg := seatConfig()
	cfg.MaxMissedTurns = 0
	h := newHarness(t, cfg, withKickHandler())
	h.seatNamed("alice", "ALICE", seatStart)
	h.seatNamed("bob", "BOB", seatStart)
	h.seatNamed("carol", "CAROL", seatStart)
	h.advance(6 * time.Second)
	idler := h.turnUser()
	for i := 0; i < 6; i++ {
		if !h.hasHand() {
			h.advance(6 * time.Second)
		}
		for h.hasHand() && h.turnUser() != idler {
			h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
		}
		if h.hasHand() {
			h.advance(seatTimeout + 10*time.Millisecond)
		}
	}
	h.waitKicks()
	if h.mustSeat(idler).MissedTurns < 3 {
		t.Fatalf("expected several misses, got %d", h.mustSeat(idler).MissedTurns)
	}
	eq(t, len(h.kickEvents()), 0, "DECISIONS §2: 0 = never kicks")
	eq(t, h.view(idler).You.MaxMissedTurns, 0, "reported as 0")
}
