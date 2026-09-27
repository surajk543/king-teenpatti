package game

// Requirement 31's missed-turn count measures a player who has stopped
// playing. Owner, 27 Sep 2026: three answers a player gives that are not
// moves in act() prove just as well that they are there — answering a
// sideshow (either way), choosing the hand's variation, choosing their 5-Card
// three — and each now clears the count, in memory and in the snapshot.

import "testing"

// setMissed writes a seat's missed-turn count — the same kind of seam
// setCards is.
func (h *harness) setMissed(userID string, n int) {
	h.t.Helper()
	h.read(func() { h.table.findSeat(userID).missedTurns = n })
}

// snapshotMissed is the count the live snapshot carries for userID.
func snapshotMissed(h *harness, userID string) int {
	h.t.Helper()
	for _, s := range mustSnapshot(h).Seats {
		if s != nil && s.UserID == userID {
			return s.MissedTurns
		}
	}
	h.t.Fatalf("%s is not in the snapshot", userID)
	return -1
}

func TestAnsweringASideshowClearsTheMissedTurns(t *testing.T) {
	for _, accept := range []bool{false, true} {
		h, _ := sideshowTable(t, 3)
		asker := h.turnUser()
		asked := h.rightOf(asker)
		h.setMissed(asked, 2)
		h.mustAct(asker, ActionSideshow, ActRequest{})
		eq(t, h.mustSeat(asked).MissedTurns, 2, "asking changes nothing for the asked")

		h.mustRespond(asked, accept)
		eq(t, h.mustSeat(asked).MissedTurns, 0, "the answer proves they are there")
		eq(t, snapshotMissed(h, asked), 0, "and the snapshot keeps it")
	}
}

func TestAnUnansweredSideshowClearsNothing(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	asker := h.turnUser()
	asked := h.rightOf(asker)
	h.setMissed(asked, 2)
	h.mustAct(asker, ActionSideshow, ActRequest{})
	h.advance(sideshowMS)
	eq(t, h.sideshowPending(), false, "the request lapsed")
	eq(t, h.mustSeat(asked).MissedTurns, 2, "a lapse is no answer")
}

func TestChoosingTheVariationClearsTheChoosersMissedTurns(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	h.setMissed(chooser, 2)
	if _, err := h.table.SelectVariation(chooser, string(VariationAK47)); err != nil {
		t.Fatal(err)
	}
	eq(t, h.mustSeat(chooser).MissedTurns, 0, "choosing proves they are there")
	eq(t, snapshotMissed(h, chooser), 0, "and the snapshot keeps it")
}

func TestTheVariationWindowLapsingClearsNothing(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	h.setMissed(chooser, 1)
	h.advance(h.table.cfg.VariationSelectTimeout)
	eq(t, h.window(chooser).Selecting, false, "the window closed on its own")
	eq(t, h.mustSeat(chooser).MissedTurns, 1, "the server's Muflis is no answer")
}

func TestChoosingTheFiveCardThreeClearsTheMissedTurns(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	var other string
	for _, id := range ids {
		if id != chooser {
			other = id
			break
		}
	}
	h.mustAct(other, ActionSee, ActRequest{})
	h.setMissed(other, 2)
	if _, err := h.table.SelectCards(other, h.view(other).You.Cards[:3]); err != nil {
		t.Fatal(err)
	}
	eq(t, h.mustSeat(other).MissedTurns, 0, "choosing their three proves they are there")
	eq(t, snapshotMissed(h, other), 0, "and the snapshot keeps it")
}
