package bot

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestAClaimCountsUntilTheSeatSettlesItOrItIsReleased(t *testing.T) {
	f := NewFleet()
	now := time.Unix(1_800_000_000, 0)
	if !f.ClaimTable("a", "seen:200", 2, now) || !f.ClaimTable("b", "seen:200", 2, now) {
		t.Fatal("two claims under a ceiling of two")
	}
	if f.ClaimTable("c", "seen:200", 2, now) {
		t.Fatal("a third claim over the ceiling")
	}
	if got := f.Held(now)["seen:200"]; got != 2 {
		t.Fatalf("held %d, want 2", got)
	}
	// A seat settles its claim: still two, not three.
	f.Seat("a", "room-1", "seen:200")
	if got := f.Held(now)["seen:200"]; got != 2 {
		t.Fatalf("after a seat, held %d, want 2", got)
	}
	// A refused join releases its place.
	f.ReleaseClaim("b")
	if got := f.Held(now)["seen:200"]; got != 1 {
		t.Fatalf("after a release, held %d, want 1", got)
	}
	if !f.ClaimTable("c", "seen:200", 2, now) {
		t.Fatal("the released place is free again")
	}
	// A claim nobody settled stops counting after claimTTL.
	if got := f.Held(now.Add(claimTTL + time.Second))["seen:200"]; got != 1 {
		t.Fatalf("a stale claim still counts: held %d, want 1 (the seat)", got)
	}
	// No ceiling: always allowed.
	for i := range 100 {
		if !f.ClaimTable(fmt.Sprint("x", i), "blind:200", 0, now) {
			t.Fatal("a ceiling of 0 is none")
		}
	}
}

func TestBotsClaimingAtOnceNeverPassTheCeiling(t *testing.T) {
	f := NewFleet()
	now := time.Unix(1_800_000_000, 0)
	var wg sync.WaitGroup
	var mu sync.Mutex
	won := 0
	for i := range 200 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if f.ClaimTable(fmt.Sprint("bot", i), "variation:50000", 50, now) {
				mu.Lock()
				won++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if won != 50 {
		t.Fatalf("%d bots took places at a table capped at 50", won)
	}
}
