package testclock

import (
	"testing"
	"time"
)

func TestAdvanceFiresInOrderAndChainsNewTimers(t *testing.T) {
	c := New(time.UnixMilli(1_700_000_000_000))
	var order []string

	c.AfterFunc(3*time.Second, func() { order = append(order, "b") })
	c.AfterFunc(1*time.Second, func() {
		order = append(order, "a")
		// A timer armed from inside a callback, still inside the window.
		c.AfterFunc(1*time.Second, func() { order = append(order, "a2") })
	})
	late := c.AfterFunc(10*time.Second, func() { order = append(order, "late") })

	c.Advance(5 * time.Second)

	if got := len(order); got != 3 || order[0] != "a" || order[1] != "a2" || order[2] != "b" {
		t.Fatalf("fired %v, want [a a2 b]", order)
	}
	if c.Pending() != 1 {
		t.Fatalf("pending %d, want 1", c.Pending())
	}
	if !c.Now().Equal(time.UnixMilli(1_700_000_005_000)) {
		t.Fatalf("now %v", c.Now())
	}
	if !late.Stop() {
		t.Fatal("Stop on a pending timer should return true")
	}
	if late.Stop() {
		t.Fatal("second Stop should return false")
	}
	c.Advance(10 * time.Second)
	if len(order) != 3 {
		t.Fatalf("stopped timer fired: %v", order)
	}
}
