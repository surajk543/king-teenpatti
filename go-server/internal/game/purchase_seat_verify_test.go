package game

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
)

// Buying chips while seated at a BLIND table, end to end on the table side:
// the seat, the live-store (Redis) snapshot, the next checkpoint, and the
// between-hands sweep that shows an unfunded player out to the lobby.

func purchaseBlindConfig() TableConfig {
	cfg := blindConfig()
	cfg.Category = CategoryBlind
	return cfg
}

// seatInSave decodes one live-store save and returns that player's seat and,
// while a hand is live, their contribution record.
func seatInSave(t *testing.T, data []byte, userID string) (*SnapshotSeat, *SnapshotContribution) {
	t.Helper()
	var snap Snapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		t.Fatalf("decode saved snapshot: %v", err)
	}
	var seat *SnapshotSeat
	for _, s := range snap.Seats {
		if s != nil && s.UserID == userID {
			seat = s
		}
	}
	var contrib *SnapshotContribution
	if snap.Hand != nil {
		for i := range snap.Hand.Contributions {
			if snap.Hand.Contributions[i].UserID == userID {
				contrib = &snap.Hand.Contributions[i]
			}
		}
	}
	return seat, contrib
}

// packOnTurn gets `id` packed, letting the other player chaal first when the
// turn is theirs.
func packOnTurn(h *harness, id string) {
	h.t.Helper()
	if h.turnUser() != id {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	h.mustAct(id, ActionPack, ActRequest{})
}

func TestVerifyBuyingMidHandOnABlindTableKeepsTheSeatAndSavesIt(t *testing.T) {
	store := livetest.New()
	h := newHarness(t, purchaseBlindConfig(), withLive(store), withKickHandler())
	h.seat("buyer", 300) // the 200 boot leaves 100 — short for the next hand
	h.seat("rival", blindStart)
	h.advance(6 * time.Second)
	if !h.hasHand() {
		t.Fatal("expected a hand in play")
	}

	before := h.mustSeat("buyer").Chips
	eq(t, before, int64(100), "boot taken")
	saves := len(store.Saves())
	states := len(h.rec.all("state"))

	const bought = 19_200_000
	if !h.table.CreditChips("buyer", bought) {
		t.Fatal("CreditChips found no seat for a seated player")
	}

	// The live seat, and the room:state that carries it to the app.
	eq(t, h.mustSeat("buyer").Chips, before+bought, "seat shows the purchase")
	if len(h.rec.all("state")) <= states {
		t.Error("no state event after the credit: the app would not see the new stack")
	}

	// Redis: exactly one more save, carrying the new stack and a chipsWritten
	// that already includes what PostgreSQL banked.
	all := store.Saves()
	eq(t, len(all), saves+1, "one live-store save for the credit")
	seat, contrib := seatInSave(t, all[len(all)-1].Snapshot, "buyer")
	if seat == nil || contrib == nil {
		t.Fatalf("buyer missing from the saved snapshot: seat=%v contrib=%v", seat, contrib)
	}
	eq(t, seat.Chips, before+bought, "saved seat stack")
	eq(t, contrib.Chips, before+bought, "saved contribution stack")
	eq(t, contrib.ChipsWritten, int64(300)+bought, "saved chipsWritten includes the purchase")

	// The pack checkpoint writes the boot only — never the purchase again. The
	// memory ledger records every row (the pack, then the hand-end outcome), so
	// the buyer's rows for this hand must add up to the boot and no more.
	packOnTurn(h, "buyer")
	var packed, total int64
	var sawPack bool
	h.mu.Lock()
	for _, c := range h.checkpoints {
		if c.UserID != "buyer" {
			continue
		}
		total += c.Delta
		if c.Reason == LedgerReasonHandPacked {
			packed, sawPack = c.Delta, true
		}
	}
	h.mu.Unlock()
	eq(t, sawPack, true, "a pack checkpoint was written")
	eq(t, packed, int64(-200), "pack delta is the boot, not boot+purchase")
	eq(t, total, int64(-200), "the hand moved the buyer's wallet by the boot only")

	// Two players, one packed: the hand is over and the sweep has run.
	h.waitKicks()
	eq(t, h.hasHand(), false, "hand over")
	for _, k := range h.kickEvents() {
		if k.UserID == "buyer" {
			t.Fatalf("buyer was kicked after buying: %+v", k)
		}
	}
	eq(t, h.mustSeat("buyer").Chips, before+bought, "still seated with the chips")
	eq(t, h.state(), TableStarting, "next hand counting down with the buyer in it")
}

func TestVerifyBuyingAfterTheLosingHandEndsIsTooLateToStayAtTheTable(t *testing.T) {
	h := newHarness(t, purchaseBlindConfig(), withKickHandler())
	h.seat("buyer", 300)
	h.seat("rival", blindStart)
	h.advance(6 * time.Second)

	// The hand ends with the buyer at 100, under the 200 boot.
	packOnTurn(h, "buyer")
	var kicked bool
	for _, k := range h.kickEvents() {
		if k.UserID == "buyer" && k.Reason == KickReasonInsufficientChips {
			kicked = true
		}
	}
	if !kicked {
		t.Fatalf("expected the sweep at the hand's end to kick the short buyer, got %+v", h.kickEvents())
	}

	// The purchase lands a moment later: the seat is already gone, so only
	// PostgreSQL gets the chips and the player is back in the lobby.
	h.waitKicks()
	if h.table.CreditChips("buyer", 19_200_000) {
		t.Error("CreditChips found a seat after the unfunded kick")
	}
}
