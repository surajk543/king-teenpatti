package socket

// Adversarial money review at the trust boundary: what a client is allowed to
// put on a chip_ledger row.

import (
	"fmt"
	"testing"
)

// TestReviewClientActionIDCannotClaimAReservedLedgerNamespace: chip_ledger's
// action_id column is shared by client-chosen ids (bets/shows) and the
// server's own deterministic ids — "<handId>:boot:<userId>",
// "<handId>:settle:<userId>" and "<userId>:milestone:<n>". The two hand-scoped
// forms are 78+ chars and fall outside the 64-char client cap, but
// "<userId>:milestone:25" is 49 chars: any player can send another player's
// id (it is on every room:state) as their own bet's actionId. The row is
// written, and when the victim reaches 25 played hands their milestone claim
// hits the UNIQUE index and fails — 25,000 chips they can never collect, for
// the price of one chaal. (Node had the identical hole.)
//
// A client id is meant to be an opaque idempotency token (Flutter sends a
// uuid v4); anything shaped like a server namespace is not adopted.
func TestReviewClientActionIDCannotClaimAReservedLedgerNamespace(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")

	forged := fmt.Sprintf("%s:milestone:25", d.waiting.user.ID)
	if len(forged) > ActionIDMaxLength {
		t.Fatalf("test premise: %q is %d chars, over the cap", forged, len(forged))
	}
	ack := st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal", "actionId": forged})
	if str(ack.Raw, "action") != "chaal" {
		t.Fatalf("chaal ack: %s", ack.Raw)
	}
	// A bet reaches the books only when the hand ends (owner's decision of
	// 9 Sep 2026), so end it: the other player packs and the winner is paid.
	st.mustOK(d.waiting.c, EvGameAction, map[string]any{"action": "pack"})
	if _, err := d.onTurn.c.Wait(EvGameHandEnded, nil, eventTimeout); err != nil {
		t.Fatalf("hand never ended: %v", err)
	}
	if n := st.books.rows(forged); n != 0 {
		t.Fatalf("REVIEW: the ledger row for %s's chaal carries the forged action_id %q (%d row); %s's 25-hand milestone claim will now fail on the UNIQUE index",
			d.onTurn.user.DisplayName, forged, n, d.waiting.user.DisplayName)
	}
	// The chaal itself still went through and was banked under a server id:
	// the winner staked 2×boot and took a pot of 3×boot.
	if got := st.users.chips(d.onTurn.user.ID); got != welcomeChips+d.boot {
		t.Fatalf("the chaal was not banked: chips %d, want %d", got, welcomeChips+d.boot)
	}
}
