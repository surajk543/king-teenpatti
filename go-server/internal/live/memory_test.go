package live

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// fakeClock is the injectable clock for the memory store.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func newMemoryHarness(t *testing.T) *harness {
	clock := newFakeClock()
	store := NewMemoryWithClock(clock.Now)
	t.Cleanup(func() { _ = store.Close() })
	return &harness{store: store, kind: "memory", ttl: time.Hour, advance: clock.Advance}
}

func TestMemoryConformance(t *testing.T) {
	runConformance(t, newMemoryHarness)
}

func TestMemoryOpenWithoutURL(t *testing.T) {
	store, err := Open(context.Background(), Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if store.Kind() != "memory" {
		t.Fatalf("Open with no URL gave %q, want memory", store.Kind())
	}
	if _, ok := store.(*Memory); !ok {
		t.Fatalf("Open returned %T, want *Memory", store)
	}
	if NewMemoryWithClock(nil).Kind() != "memory" {
		t.Fatal("nil clock must fall back to wall time")
	}
}

// The periodic sweep bounds memory: entries nobody reads again still leave
// the maps once they have expired and a mutation lands after the sweep
// interval.
func TestMemorySweepDropsExpiredEntries(t *testing.T) {
	ctx := context.Background()
	clock := newFakeClock()
	store := NewMemoryWithClock(clock.Now).(*Memory)
	ttl := 10 * time.Second
	for i := 0; i < 50; i++ {
		id := string(rune('a' + i%26))
		must(t, store.SaveTable(ctx, id, int64(i), []byte("x"), ttl))
		must(t, store.SetOnline(ctx, "u"+id, "inst", ttl))
		must(t, store.PutResumeOffer(ctx, "u"+id, ResumeOffer{RoomID: id}, ttl))
		must(t, store.AppendChat(ctx, id, []byte("hi"), 10))
		must(t, store.PublishTable(ctx, TableSummary{RoomID: id, Category: "blind", BootAmount: 200, Players: 1}))
	}
	store.mu.Lock()
	before := len(store.tables) + len(store.online) + len(store.offers)
	store.mu.Unlock()
	if before == 0 {
		t.Fatal("nothing stored")
	}
	// Expire the short-ttl entries but stay under the sweep interval: a
	// write leaves them in place (reads still see them as gone).
	clock.Advance(ttl + time.Second)
	must(t, store.SetSeated(ctx, "someone", "r"))
	store.mu.Lock()
	lingering := len(store.tables) + len(store.online) + len(store.offers)
	store.mu.Unlock()
	if lingering != before {
		t.Fatalf("swept before the interval: %d → %d", before, lingering)
	}
	if _, _, err := store.LoadTable(ctx, "a"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expired table still readable: %v", err)
	}
	// Past the interval the next mutation sweeps everything expired; chat and
	// summaries live for auxTTL and must survive.
	clock.Advance(memorySweepEvery)
	must(t, store.SetSeated(ctx, "someone", "r"))
	store.mu.Lock()
	after := len(store.tables) + len(store.online) + len(store.offers)
	chats, summaries := len(store.chats), len(store.summaries)
	store.mu.Unlock()
	if after != 0 {
		t.Fatalf("%d expired entries survived the sweep", after)
	}
	if chats != 26 || summaries != 26 {
		t.Fatalf("sweep took unexpired chat/summaries: chats=%d summaries=%d", chats, summaries)
	}
	// And after auxTTL those go too, including their lobby index entries.
	clock.Advance(auxTTL)
	out, err := store.Candidates(ctx, "blind", 200)
	must(t, err)
	if len(out) != 0 {
		t.Fatalf("expired summaries still listed: %d", len(out))
	}
	must(t, store.SetSeated(ctx, "someone", "r"))
	store.mu.Lock()
	chats, summaries, lobby := len(store.chats), len(store.summaries), len(store.lobby)
	store.mu.Unlock()
	if chats != 0 || summaries != 0 || lobby != 0 {
		t.Fatalf("aux entries survived: chats=%d summaries=%d lobby=%d", chats, summaries, lobby)
	}
}

func TestMemoryClosedReturnsErrClosed(t *testing.T) {
	ctx := context.Background()
	store := NewMemory()
	must(t, store.Close())
	if err := store.SaveTable(ctx, "r", 1, nil, time.Hour); !errors.Is(err, ErrClosed) {
		t.Fatalf("SaveTable after Close: %v, want ErrClosed", err)
	}
	if _, err := store.OnlineCount(ctx); !errors.Is(err, ErrClosed) {
		t.Fatalf("OnlineCount after Close: %v, want ErrClosed", err)
	}
	must(t, store.Close()) // idempotent
}

// A re-publish that changes bucket (or flips to private) must not leave the
// table listed in its old bucket.
func TestMemoryRepublishMovesBucket(t *testing.T) {
	ctx := context.Background()
	store := NewMemory()
	defer store.Close()
	s := TableSummary{RoomID: "a", Category: "blind", BootAmount: 200, Players: 2}
	must(t, store.PublishTable(ctx, s))
	s.BootAmount = 5000
	must(t, store.PublishTable(ctx, s))
	old, err := store.Candidates(ctx, "blind", 200)
	must(t, err)
	if len(old) != 0 {
		t.Fatalf("still in the old bucket: %s", idsOf(old))
	}
	now, err := store.Candidates(ctx, "blind", 5000)
	must(t, err)
	if idsOf(now) != "a" {
		t.Fatalf("not in the new bucket: %s", idsOf(now))
	}
	s.IsPrivate = true
	must(t, store.PublishTable(ctx, s))
	now, err = store.Candidates(ctx, "blind", 5000)
	must(t, err)
	if len(now) != 0 {
		t.Fatalf("private table still listed: %s", idsOf(now))
	}
}
