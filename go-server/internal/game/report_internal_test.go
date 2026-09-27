package game

import (
	"fmt"
	"testing"
	"time"
)

// The recent-departure memory (report.go) is bounded: each player remembers
// at most coPlayersPerPlayer table-mates, the oldest going first, and a pair
// past the window is forgotten — swept as other pairs are noted, and never
// answered in between.
func TestTheRecentTableMatesAreBoundedAndForgotten(t *testing.T) {
	start := time.UnixMilli(1_790_000_000_000)
	c := newCoPlayers(10 * time.Minute)
	for i := range coPlayersPerPlayer + 6 {
		other := fmt.Sprintf("u%03d", i)
		c.note("me", other, ReportContext{RoomID: "r"}, ReportContext{RoomID: "r", HandID: other}, start.Add(time.Duration(i)*time.Second))
	}
	if n := len(c.seen["me"]); n != coPlayersPerPlayer {
		t.Fatalf("%d table-mates remembered, want %d", n, coPlayersPerPlayer)
	}
	now := start.Add(2 * time.Minute)
	if _, ok := c.lookup("me", "u000", now); ok {
		t.Fatal("the oldest table-mate was kept past the bound")
	}
	if got, ok := c.lookup("me", "u069", now); !ok || got.HandID != "u069" {
		t.Fatalf("the newest table-mate: %+v %v", got, ok)
	}
	if got, ok := c.lookup("u069", "me", now); !ok || got.RoomID != "r" {
		t.Fatalf("the pair both ways: %+v %v", got, ok)
	}

	late := start.Add(time.Hour)
	if _, ok := c.lookup("me", "u069", late); ok {
		t.Fatal("a pair past the window was answered")
	}
	c.note("x", "y", ReportContext{}, ReportContext{}, late)
	if len(c.seen["me"]) != 0 || len(c.seen["u069"]) != 0 {
		t.Fatalf("the sweep left %d and %d stale pairs", len(c.seen["me"]), len(c.seen["u069"]))
	}

	off := newCoPlayers(0)
	off.note("a", "b", ReportContext{}, ReportContext{}, start)
	if _, ok := off.lookup("a", "b", start); ok || len(off.seen) != 0 {
		t.Fatal("a zero window remembered a pair")
	}
}
