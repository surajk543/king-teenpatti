package clock

import (
	"context"
	"testing"
	"time"
)

func TestAFakeClockFiresTimersInOrderOnlyWhenAdvanced(t *testing.T) {
	c := NewFake(time.Unix(100, 0))
	late := c.NewTimer(3 * time.Second)
	early := c.NewTimer(1 * time.Second)
	stopped := c.NewTimer(2 * time.Second)
	if !stopped.Stop() || stopped.Stop() {
		t.Fatal("Stop reports the first stop only")
	}
	select {
	case <-early.C():
		t.Fatal("fired before the clock moved")
	default:
	}
	c.Advance(1500 * time.Millisecond)
	if at := <-early.C(); !at.Equal(time.Unix(101, 0)) {
		t.Fatalf("fired at %v", at)
	}
	select {
	case <-late.C():
		t.Fatal("the later timer fired early")
	default:
	}
	c.Advance(2 * time.Second)
	<-late.C()
	if c.Pending() != 0 {
		t.Fatalf("%d pending", c.Pending())
	}
	if c.Now() != time.Unix(103, int64(500*time.Millisecond)) {
		t.Fatalf("now %v", c.Now())
	}
}

func TestSleepEndsWithTheClockOrTheContext(t *testing.T) {
	c := NewFake(time.Unix(0, 0))
	done := make(chan error, 1)
	go func() { done <- c.Sleep(context.Background(), time.Second) }()
	for c.Pending() == 0 {
		time.Sleep(time.Millisecond)
	}
	c.Advance(time.Second)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := c.Sleep(ctx, time.Hour); err == nil {
		t.Fatal("a cancelled sleep returns the context's error")
	}
	if err := (Real{}).Sleep(context.Background(), time.Millisecond); err != nil {
		t.Fatal(err)
	}
}
