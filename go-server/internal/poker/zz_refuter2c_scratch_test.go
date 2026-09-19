package poker

import "testing"

// Scratch (refuter 2): a seat that folds with chips already in on this street
// keeps its streetBet after the street turns over, because beginStreet resets
// only seatsInHand().
func TestZZRefuter2CFoldedStreetBet(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("A", 10000)
	h.seat("B", 10000)
	h.seat("C", 10000)
	h.deal()

	var folded string
	for h.street() == StreetPreflop {
		id := h.turn()
		if id == "" {
			break
		}
		var sb int64
		h.read(func() { sb = h.table.findSeat(id).streetBet })
		if sb > 0 && sb < 200 && folded == "" {
			h.mustAct(id, ActionFold)
			folded = id
			continue
		}
		o := h.options(id)
		switch {
		case o.Call:
			h.mustAct(id, ActionCall)
		case o.Check:
			h.mustAct(id, ActionCheck)
		default:
			t.Fatalf("%s has nothing to do: %+v", id, o)
		}
	}
	if folded == "" {
		t.Fatal("nobody folded with a live blind in")
	}
	t.Logf("street now %s, folded=%s", h.street(), folded)

	view, err := h.table.SerializeFor("A")
	if err != nil {
		t.Fatal(err)
	}
	var shown int64
	for _, p := range view.Poker.Pots {
		shown += p.Amount
	}
	for _, s := range view.Seats {
		if s.Empty {
			continue
		}
		t.Logf("  seat %d %s status=%s contributed=%d streetBet=%d", s.SeatIndex, s.UserID, s.Status, s.Contributed, s.StreetBet)
	}
	t.Logf("pot=%d  pots-shown=%d", view.Pot, shown)
	if shown != view.Pot {
		t.Errorf("DEFECT CONFIRMED: pots sum %d != pot %d", shown, view.Pot)
	}
	for _, s := range view.Seats {
		if !s.Empty && s.UserID == folded && s.StreetBet != 0 {
			t.Errorf("DEFECT CONFIRMED: folded seat %s shows streetBet %d on the new street", folded, s.StreetBet)
		}
	}
}
