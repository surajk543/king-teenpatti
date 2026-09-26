package live

import (
	"context"
	"reflect"
	"sync"
	"testing"
	"time"
)

// The XP play time (owner, 26 Sep 2026: "game duration will be stored in
// redis not in postgres"): a player's active play in their XP window and the
// play marks claimed in it, kept by the live store's PlayClock.

func memoryClock(t *testing.T) (PlayClock, *fakeClock) {
	t.Helper()
	clock := newFakeClock()
	store := NewMemoryWithClock(clock.Now)
	t.Cleanup(func() { _ = store.Close() })
	pc, ok := PlayClockOf(store)
	if !ok {
		t.Fatal("the memory store keeps play time")
	}
	return pc, clock
}

// TestThePlayClockClaimsEachMarkOncePerWindow: the window opens at the first
// play, its play adds up, the 30- and 60-minute marks are each claimed by the
// one call that carries the play past them, a released mark is claimed again
// by the next call, and once the window has gone everything starts over.
func TestThePlayClockClaimsEachMarkOncePerWindow(t *testing.T) {
	ctx := context.Background()
	pc, clock := memoryClock(t)
	const window = 24 * time.Hour
	add := func(play time.Duration) PlayTime {
		t.Helper()
		pt, err := pc.AddPlayTime(ctx, "u1", play, clock.Now(), window)
		if err != nil {
			t.Fatal(err)
		}
		return pt
	}

	opened := clock.Now()
	if pt := add(0); !pt.Start.Equal(opened) || pt.Play != 0 || len(pt.Claimed) != 0 || pt.Claimed == nil {
		t.Fatalf("a play of 0 opens the window and claims nothing: %+v", pt)
	}
	clock.Advance(time.Minute)
	if pt := add(20 * time.Minute); !pt.Start.Equal(opened) || pt.Play != 20*time.Minute || len(pt.Claimed) != 0 {
		t.Fatalf("20 minutes: %+v", pt)
	}
	if pt := add(15 * time.Minute); pt.Play != 35*time.Minute || !reflect.DeepEqual(pt.Claimed, []string{PlayMark30}) {
		t.Fatalf("past 30 minutes: %+v", pt)
	}
	if pt := add(time.Minute); len(pt.Claimed) != 0 {
		t.Fatalf("the 30-minute mark is claimed once: %+v", pt)
	}
	// Released (its award failed): the next call claims it again.
	if err := pc.ClearPlayMark(ctx, "u1", PlayMark30); err != nil {
		t.Fatal(err)
	}
	if pt := add(time.Minute); !reflect.DeepEqual(pt.Claimed, []string{PlayMark30}) {
		t.Fatalf("a released mark is claimed by the next call: %+v", pt)
	}
	if pt := add(30 * time.Minute); pt.Play != 67*time.Minute || !reflect.DeepEqual(pt.Claimed, []string{PlayMark60}) {
		t.Fatalf("past 60 minutes: %+v", pt)
	}
	// Another player's window is their own; one call can claim both marks.
	if pt, err := pc.AddPlayTime(ctx, "u2", 2*time.Hour, clock.Now(), window); err != nil || !reflect.DeepEqual(pt.Claimed, []string{PlayMark30, PlayMark60}) {
		t.Fatalf("u2's two hours at once: %+v %v", pt, err)
	}
	// A negative play adds nothing.
	if pt := add(-time.Hour); pt.Play != 67*time.Minute {
		t.Fatalf("a negative play: %+v", pt)
	}

	// The window runs out window after it opened; the next play opens another.
	clock.Advance(window - time.Minute)
	pt := add(31 * time.Minute)
	if !pt.Start.Equal(clock.Now()) || pt.Play != 31*time.Minute || !reflect.DeepEqual(pt.Claimed, []string{PlayMark30}) {
		t.Fatalf("a new window: %+v", pt)
	}
	// Releasing a mark in a window that has gone is a no-op, not an error.
	clock.Advance(window)
	if err := pc.ClearPlayMark(ctx, "u1", PlayMark60); err != nil {
		t.Fatal(err)
	}
	if err := pc.ClearPlayMark(ctx, "nobody", PlayMark30); err != nil {
		t.Fatal(err)
	}
}

// TestOnlyOneOfManyPlaysClaimsAMark: hand ends at several tables adding a
// player's play together claim each mark exactly once.
func TestOnlyOneOfManyPlaysClaimsAMark(t *testing.T) {
	ctx := context.Background()
	pc, clock := memoryClock(t)
	var mu sync.Mutex
	claims := map[string]int{}
	var wg sync.WaitGroup
	for i := 0; i < 64; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			pt, err := pc.AddPlayTime(ctx, "u1", 2*time.Minute, clock.Now(), 24*time.Hour)
			if err != nil {
				t.Error(err)
				return
			}
			mu.Lock()
			for _, m := range pt.Claimed {
				claims[m]++
			}
			mu.Unlock()
		}()
	}
	wg.Wait()
	if !reflect.DeepEqual(claims, map[string]int{PlayMark30: 1, PlayMark60: 1}) {
		t.Fatalf("claims %v, want each mark once", claims)
	}
}

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
	if _, err := inner.(PlayClock).AddPlayTime(context.Background(), "u1", time.Minute, time.Now(), time.Hour); err != ErrClosed {
		t.Errorf("a closed store: %v", err)
	}
	if got := PlayMarks(); len(got) != 2 || got[0] != (PlayMark{PlayMark30, 30 * time.Minute}) || got[1] != (PlayMark{PlayMark60, time.Hour}) {
		t.Errorf("the marks: %+v", got)
	}
}
