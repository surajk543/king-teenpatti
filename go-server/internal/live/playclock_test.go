package live

import (
	"context"
	"testing"
	"time"
)

// The XP play time (owner, 26–27 Sep 2026: "game duration will be stored in
// redis not in postgres"): a player's active play in their XP window, kept by
// the live store's PlayClock. What it counts is in the conformance suite
// (PlayClockCountsAWindow, PlayClockConcurrentAdds), which every store runs.

// TestThePlayClockIsFoundBehindTheHooksAndNowhereElse: a store's PlayClock is
// found through a WithHooks wrapper; a store without one has none; a closed
// store refuses.
func TestThePlayClockIsFoundBehindTheHooksAndNowhereElse(t *testing.T) {
	inner := NewMemory()
	if pc, ok := PlayClockOf(WithHooks(inner, Hooks{})); !ok || pc != inner.(PlayClock) {
		t.Error("the play clock behind WithHooks is the inner store's")
	}
	type plain struct{ Store } // a Store and nothing more
	if _, ok := PlayClockOf(plain{inner}); ok {
		t.Error("a store that does not keep play time has no play clock")
	}
	if _, ok := PlayClockOf(nil); ok {
		t.Error("no store, no play clock")
	}
	_ = inner.Close()
	if _, _, err := inner.(PlayClock).AddPlayTime(context.Background(), "u1", 1, time.Minute, time.Hour); err != ErrClosed {
		t.Errorf("a closed store: %v", err)
	}
}
