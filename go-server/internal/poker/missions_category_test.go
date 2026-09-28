package poker

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// The one-time XP missions (owner, 28 Sep 2026) count a poker hand by its
// game — "First Poker Hand" any of the four, "Texas Hold'em Debut" Texas
// Hold'em alone — which the ledger reads off the hand-end settle: the room's
// category on the request (SettleRequest.Category), agreeing with what its
// rows are written under.
func TestAPokerSettleNamesItsGame(t *testing.T) {
	for _, variant := range []Variant{TexasHoldem, Omaha} {
		t.Run(string(variant), func(t *testing.T) {
			h := newHarness(t, variant)
			h.seat("a", 10_000)
			h.seat("b", 10_000)
			h.deal()
			h.mustAct(h.turn(), ActionFold)
			h.books.mu.Lock()
			defer h.books.mu.Unlock()
			if len(h.books.settles) != 1 {
				t.Fatalf("%d settles, want the hand's one", len(h.books.settles))
			}
			req := h.books.settles[0]
			if req.Category != variant.Category() {
				t.Fatalf("the settle names %q, want %q", req.Category, variant.Category())
			}
			for _, e := range req.Entries {
				if e.Game != game.GamePoker || e.Variant != req.Category {
					t.Errorf("a row written under %q/%q beside a settle naming %q", e.Game, e.Variant, req.Category)
				}
			}
		})
	}
}
