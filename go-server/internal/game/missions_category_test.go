package game

import (
	"sync"
	"testing"
)

// The one-time XP missions (owner, 28 Sep 2026: "First Poker Hand", "Texas
// Hold'em Debut", "Game Explorer") count a hand by the category of the table
// it was played at, which the ledger reads off the hand-end settle
// (SettleRequest.Category): a Teen Patti table names its own, whatever the
// hand's entries carry — which, at Teen Patti, is no category at all.
func TestTheSettleNamesTheTablesCategory(t *testing.T) {
	for _, cat := range []Category{CategorySeen, CategoryBlind} {
		t.Run(string(cat), func(t *testing.T) {
			cfg := sideshowConfig()
			cfg.Category = cat
			var mu sync.Mutex
			var got []SettleRequest
			ledger := func(h *harness) Ledger {
				return NewMemoryLedger(MemoryLedgerHooks{
					Settle: func(req SettleRequest, entries []SettleEntry) (map[string]int64, error) {
						mu.Lock()
						defer mu.Unlock()
						got = append(got, req)
						return map[string]int64{}, nil
					},
				})
			}
			h := newHarness(t, cfg, withLedger(ledger))
			h.seat("a", sideshowStart)
			h.seat("b", sideshowStart)
			h.advance(cfg.NextHandDelay)
			h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
			h.mustAct(h.turnUser(), ActionPack, ActRequest{})
			mu.Lock()
			defer mu.Unlock()
			if len(got) != 1 || got[0].Category != cat {
				t.Fatalf("the settles %+v, want one naming %s", got, cat)
			}
			for _, e := range got[0].Entries {
				if e.Variant != "" || e.Game != "" {
					t.Errorf("a Teen Patti row names %q/%q: its bytes must not change", e.Game, e.Variant)
				}
			}
		})
	}
}
