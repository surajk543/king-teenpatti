package live

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

// harness is one Store under test plus the two things the suite needs that
// differ per backend: how to move time forward (fake clock, miniredis
// FastForward, or a real sleep) and a ttl short enough for the expiry tests
// to be quick on the backend that really has to wait.
type harness struct {
	store   Store
	kind    string
	ttl     time.Duration
	advance func(d time.Duration)
}

// runConformance runs the shared suite; newHarness must return an isolated
// store (fresh server, or a fresh key prefix on a shared one) per call.
func runConformance(t *testing.T, newHarness func(t *testing.T) *harness) {
	ctx := context.Background()
	past := func(h *harness) { h.advance(h.ttl + h.ttl/2) }

	t.Run("KindAndPing", func(t *testing.T) {
		h := newHarness(t)
		if got := h.store.Kind(); got != h.kind {
			t.Fatalf("Kind = %q, want %q", got, h.kind)
		}
		if err := h.store.Ping(ctx); err != nil {
			t.Fatalf("Ping: %v", err)
		}
	})

	t.Run("SaveTableCAS", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.SaveTable(ctx, "r1", 1, []byte("one"), h.ttl))
		must(t, h.store.SaveTable(ctx, "r1", 2, []byte("two"), h.ttl))
		if err := h.store.SaveTable(ctx, "r1", 2, []byte("two-again"), h.ttl); !errors.Is(err, ErrStale) {
			t.Fatalf("seq 2 again: err = %v, want ErrStale", err)
		}
		if err := h.store.SaveTable(ctx, "r1", 1, []byte("one-again"), h.ttl); !errors.Is(err, ErrStale) {
			t.Fatalf("seq 1 after 2: err = %v, want ErrStale", err)
		}
		seq, snap, err := h.store.LoadTable(ctx, "r1")
		must(t, err)
		if seq != 2 || string(snap) != "two" {
			t.Fatalf("Load = (%d, %q), want (2, two)", seq, snap)
		}
		// A different table has its own sequence.
		must(t, h.store.SaveTable(ctx, "r2", 1, []byte("r2"), h.ttl))
	})

	t.Run("LoadAfterSave", func(t *testing.T) {
		h := newHarness(t)
		if _, _, err := h.store.LoadTable(ctx, "missing"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Load missing: err = %v, want ErrNotFound", err)
		}
		snap := bigSnapshot("h-1", 20*1024)
		must(t, h.store.SaveTable(ctx, "r1", 7, snap, h.ttl))
		// The store must own its copy: mutating the caller's buffer later
		// must not change what was stored.
		mutated := append([]byte(nil), snap...)
		copy(snap, "XXXX")
		seq, got, err := h.store.LoadTable(ctx, "r1")
		must(t, err)
		if seq != 7 || !bytes.Equal(got, mutated) {
			t.Fatalf("Load = (%d, %d bytes, equal=%v), want (7, %d bytes, true)", seq, len(got), bytes.Equal(got, mutated), len(mutated))
		}
	})

	t.Run("TTLExpiry", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.SaveTable(ctx, "r1", 5, []byte("five"), h.ttl))
		past(h)
		if _, _, err := h.store.LoadTable(ctx, "r1"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Load after ttl: err = %v, want ErrNotFound", err)
		}
		refs, err := h.store.ListTables(ctx)
		must(t, err)
		if len(refs) != 0 {
			t.Fatalf("ListTables after ttl = %v, want empty", refs)
		}
		// The sequence restarts with the table: a low seq is accepted again.
		must(t, h.store.SaveTable(ctx, "r1", 1, []byte("reborn"), h.ttl))

		// A save refreshes the ttl.
		must(t, h.store.SaveTable(ctx, "r2", 1, []byte("a"), h.ttl))
		h.advance(h.ttl / 2)
		must(t, h.store.SaveTable(ctx, "r2", 2, []byte("b"), h.ttl))
		h.advance(h.ttl * 3 / 4) // 5/4 ttl since the first save, 3/4 since the refreshing one
		seq, _, err := h.store.LoadTable(ctx, "r2")
		must(t, err)
		if seq != 2 {
			t.Fatalf("seq after refresh = %d, want 2", seq)
		}
	})

	t.Run("DeleteThenLoad", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.SaveTable(ctx, "r1", 3, []byte("x"), h.ttl))
		must(t, h.store.DeleteTable(ctx, "r1"))
		if _, _, err := h.store.LoadTable(ctx, "r1"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Load after Delete: err = %v, want ErrNotFound", err)
		}
		must(t, h.store.DeleteTable(ctx, "r1")) // idempotent
		must(t, h.store.SaveTable(ctx, "r1", 1, []byte("again"), h.ttl))
	})

	t.Run("ListTables", func(t *testing.T) {
		h := newHarness(t)
		refs, err := h.store.ListTables(ctx)
		must(t, err)
		if refs == nil || len(refs) != 0 {
			t.Fatalf("empty ListTables = %#v, want empty non-nil", refs)
		}
		must(t, h.store.SaveTable(ctx, "c", 1, []byte("c1"), h.ttl))
		must(t, h.store.SaveTable(ctx, "a", 1, []byte("a1"), h.ttl))
		must(t, h.store.SaveTable(ctx, "b", 1, []byte("b1"), h.ttl))
		must(t, h.store.SaveTable(ctx, "a", 4, []byte("a4"), h.ttl))
		must(t, h.store.DeleteTable(ctx, "b"))
		refs, err = h.store.ListTables(ctx)
		must(t, err)
		want := []TableRef{{RoomID: "a", Seq: 4}, {RoomID: "c", Seq: 1}}
		if fmt.Sprint(refs) != fmt.Sprint(want) {
			t.Fatalf("ListTables = %v, want %v", refs, want)
		}
	})

	t.Run("ChatCapAndOrder", func(t *testing.T) {
		h := newHarness(t)
		msgs, err := h.store.LoadChat(ctx, "r1")
		must(t, err)
		if msgs == nil || len(msgs) != 0 {
			t.Fatalf("empty LoadChat = %#v, want empty non-nil", msgs)
		}
		for i := 1; i <= 7; i++ {
			must(t, h.store.AppendChat(ctx, "r1", []byte(fmt.Sprintf("m%d", i)), 5))
		}
		msgs, err = h.store.LoadChat(ctx, "r1")
		must(t, err)
		if got := joinBytes(msgs); got != "m3 m4 m5 m6 m7" {
			t.Fatalf("chat = %q, want the last five in order", got)
		}
		// Other rooms are independent; max <= 0 means uncapped.
		for i := 1; i <= 3; i++ {
			must(t, h.store.AppendChat(ctx, "r2", []byte(fmt.Sprintf("x%d", i)), 0))
		}
		msgs, err = h.store.LoadChat(ctx, "r2")
		must(t, err)
		if got := joinBytes(msgs); got != "x1 x2 x3" {
			t.Fatalf("uncapped chat = %q", got)
		}
		must(t, h.store.DeleteChat(ctx, "r1"))
		msgs, err = h.store.LoadChat(ctx, "r1")
		must(t, err)
		if len(msgs) != 0 {
			t.Fatalf("chat after delete = %q, want empty", joinBytes(msgs))
		}
		msgs, err = h.store.LoadChat(ctx, "r2")
		must(t, err)
		if len(msgs) != 3 {
			t.Fatalf("r2 chat lost on r1 delete: %q", joinBytes(msgs))
		}
	})

	t.Run("Seats", func(t *testing.T) {
		h := newHarness(t)
		if _, err := h.store.SeatOf(ctx, "u1"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("SeatOf unseated: err = %v, want ErrNotFound", err)
		}
		must(t, h.store.SetSeated(ctx, "u1", "r1"))
		must(t, h.store.SetSeated(ctx, "u2", "r1"))
		room, err := h.store.SeatOf(ctx, "u1")
		must(t, err)
		if room != "r1" {
			t.Fatalf("SeatOf = %q, want r1", room)
		}
		must(t, h.store.SetSeated(ctx, "u1", "r2")) // moved
		room, err = h.store.SeatOf(ctx, "u1")
		must(t, err)
		if room != "r2" {
			t.Fatalf("SeatOf after move = %q, want r2", room)
		}
		must(t, h.store.ClearSeated(ctx, "u1"))
		if _, err := h.store.SeatOf(ctx, "u1"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("SeatOf after clear: err = %v, want ErrNotFound", err)
		}
		room, err = h.store.SeatOf(ctx, "u2")
		must(t, err)
		if room != "r1" {
			t.Fatalf("u2 lost its seat: %q", room)
		}
		must(t, h.store.ClearSeated(ctx, "nobody")) // idempotent
	})

	t.Run("OnlineCountWithExpiry", func(t *testing.T) {
		h := newHarness(t)
		n, err := h.store.OnlineCount(ctx)
		must(t, err)
		if n != 0 {
			t.Fatalf("empty OnlineCount = %d", n)
		}
		must(t, h.store.SetOnline(ctx, "u1", "inst-a", h.ttl))
		must(t, h.store.SetOnline(ctx, "u2", "inst-a", h.ttl))
		must(t, h.store.SetOnline(ctx, "u3", "inst-b", h.ttl))
		must(t, h.store.SetOnline(ctx, "u1", "inst-a", h.ttl)) // refresh is not a second entry
		must(t, h.store.SetOffline(ctx, "u3"))
		n, err = h.store.OnlineCount(ctx)
		must(t, err)
		if n != 2 {
			t.Fatalf("OnlineCount = %d, want 2", n)
		}
		// Heartbeat keeps u1 alive across the ttl boundary; u2 lapses.
		h.advance(h.ttl / 2)
		must(t, h.store.SetOnline(ctx, "u1", "inst-a", h.ttl))
		h.advance(h.ttl * 3 / 4) // 3/4 ttl since u1's refresh, 5/4 since u2's
		n, err = h.store.OnlineCount(ctx)
		must(t, err)
		if n != 1 {
			t.Fatalf("OnlineCount after partial expiry = %d, want 1", n)
		}
		past(h)
		n, err = h.store.OnlineCount(ctx)
		must(t, err)
		if n != 0 {
			t.Fatalf("OnlineCount after full expiry = %d, want 0", n)
		}
		must(t, h.store.SetOffline(ctx, "never-online")) // idempotent
	})

	t.Run("ResumeOffers", func(t *testing.T) {
		h := newHarness(t)
		offer := ResumeOffer{RoomID: "r1", Code: "ABCD", Category: "blind", BootAmount: 5000, At: 1_700_000_000_000}
		if _, err := h.store.TakeResumeOffer(ctx, "u1"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Take with no offer: err = %v, want ErrNotFound", err)
		}
		must(t, h.store.PutResumeOffer(ctx, "u1", offer, h.ttl))
		got, err := h.store.TakeResumeOffer(ctx, "u1")
		must(t, err)
		if got != offer {
			t.Fatalf("Take = %+v, want %+v", got, offer)
		}
		if _, err := h.store.TakeResumeOffer(ctx, "u1"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("second Take: err = %v, want ErrNotFound (offered once)", err)
		}
		// Delete drops it without handing it out.
		must(t, h.store.PutResumeOffer(ctx, "u1", offer, h.ttl))
		must(t, h.store.DeleteResumeOffer(ctx, "u1"))
		if _, err := h.store.TakeResumeOffer(ctx, "u1"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Take after Delete: err = %v, want ErrNotFound", err)
		}
		// A newer offer replaces the old one.
		must(t, h.store.PutResumeOffer(ctx, "u1", offer, h.ttl))
		newer := offer
		newer.RoomID, newer.Code = "r2", "WXYZ"
		must(t, h.store.PutResumeOffer(ctx, "u1", newer, h.ttl))
		got, err = h.store.TakeResumeOffer(ctx, "u1")
		must(t, err)
		if got != newer {
			t.Fatalf("Take after replace = %+v, want %+v", got, newer)
		}
		// Expiry.
		must(t, h.store.PutResumeOffer(ctx, "u2", offer, h.ttl))
		past(h)
		if _, err := h.store.TakeResumeOffer(ctx, "u2"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Take after ttl: err = %v, want ErrNotFound", err)
		}
	})

	t.Run("MatchmakingOrder", func(t *testing.T) {
		h := newHarness(t)
		out, err := h.store.Candidates(ctx, "blind", 200)
		must(t, err)
		if out == nil || len(out) != 0 {
			t.Fatalf("empty Candidates = %#v, want empty non-nil", out)
		}
		summary := func(id string, players int, created int64, private bool) TableSummary {
			return TableSummary{RoomID: id, Code: strings.ToUpper(id), Category: "blind", BootAmount: 200,
				Players: players, MaxPlayers: 5, IsPrivate: private, State: "betting", CreatedAt: created, Instance: "host:1"}
		}
		must(t, h.store.PublishTable(ctx, summary("a", 2, 100, false)))
		must(t, h.store.PublishTable(ctx, summary("b", 3, 200, false)))
		must(t, h.store.PublishTable(ctx, summary("c", 3, 150, false)))
		must(t, h.store.PublishTable(ctx, summary("p", 5, 50, true))) // private: never listed
		other := summary("e", 4, 10, false)
		other.BootAmount = 5000 // different bucket
		must(t, h.store.PublishTable(ctx, other))

		got, err := h.store.Candidates(ctx, "blind", 200)
		must(t, err)
		if ids := idsOf(got); ids != "c b a" {
			t.Fatalf("Candidates = %s, want c b a (fullest first, ties oldest first, private excluded)", ids)
		}
		if got[0] != summary("c", 3, 150, false) {
			t.Fatalf("summary round trip lost fields: %+v", got[0])
		}
		got, err = h.store.Candidates(ctx, "blind", 5000)
		must(t, err)
		if ids := idsOf(got); ids != "e" {
			t.Fatalf("other bucket = %s, want e", ids)
		}
		got, err = h.store.Candidates(ctx, "seen", 200)
		must(t, err)
		if len(got) != 0 {
			t.Fatalf("seen bucket = %s, want empty", idsOf(got))
		}

		// Re-publishing moves a table in the order; retiring removes it.
		must(t, h.store.PublishTable(ctx, summary("a", 4, 100, false)))
		got, err = h.store.Candidates(ctx, "blind", 200)
		must(t, err)
		if ids := idsOf(got); ids != "a c b" {
			t.Fatalf("after re-publish = %s, want a c b", ids)
		}
		must(t, h.store.RetireTable(ctx, "c", "blind", 200))
		got, err = h.store.Candidates(ctx, "blind", 200)
		must(t, err)
		if ids := idsOf(got); ids != "a b" {
			t.Fatalf("after retire = %s, want a b", ids)
		}
		must(t, h.store.RetireTable(ctx, "c", "blind", 200)) // idempotent
		must(t, h.store.RetireTable(ctx, "p", "blind", 200)) // private retire is fine too
		got, err = h.store.Candidates(ctx, "blind", 200)
		must(t, err)
		if ids := idsOf(got); ids != "a b" {
			t.Fatalf("after idempotent retires = %s, want a b", ids)
		}
	})

	t.Run("ConcurrentSaves", func(t *testing.T) {
		h := newHarness(t)
		const maxSeq = 100
		var (
			wg      sync.WaitGroup
			mu      sync.Mutex
			winners = map[int64]int{}
			others  []error
		)
		// Every seq is offered by two racing goroutines: at most one of the
		// pair may win, and whoever offers the highest seq must win.
		for seq := int64(1); seq <= maxSeq; seq++ {
			for dup := 0; dup < 2; dup++ {
				wg.Add(1)
				go func(seq int64, dup int) {
					defer wg.Done()
					err := h.store.SaveTable(ctx, "race", seq, []byte(fmt.Sprintf("seq-%d-dup-%d", seq, dup)), h.ttl)
					mu.Lock()
					defer mu.Unlock()
					switch {
					case err == nil:
						winners[seq]++
					case errors.Is(err, ErrStale):
					default:
						others = append(others, err)
					}
				}(seq, dup)
			}
		}
		wg.Wait()
		if len(others) > 0 {
			t.Fatalf("unexpected errors: %v", others)
		}
		for seq, n := range winners {
			if n != 1 {
				t.Fatalf("seq %d had %d winners, want exactly one", seq, n)
			}
		}
		if winners[maxSeq] != 1 {
			t.Fatalf("the max seq did not win: %v", winners)
		}
		seq, snap, err := h.store.LoadTable(ctx, "race")
		must(t, err)
		if seq != maxSeq || !strings.HasPrefix(string(snap), fmt.Sprintf("seq-%d-", maxSeq)) {
			t.Fatalf("final = (%d, %q), want seq %d with its own snapshot", seq, snap, maxSeq)
		}
	})

	t.Run("ConcurrentTakeResumeOffer", func(t *testing.T) {
		h := newHarness(t)
		for round := 0; round < 5; round++ {
			must(t, h.store.PutResumeOffer(ctx, "u1", ResumeOffer{RoomID: "r1", Code: "AAAA"}, h.ttl))
			var (
				wg    sync.WaitGroup
				mu    sync.Mutex
				taken int
				bad   []error
			)
			for i := 0; i < 8; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					_, err := h.store.TakeResumeOffer(ctx, "u1")
					mu.Lock()
					defer mu.Unlock()
					switch {
					case err == nil:
						taken++
					case errors.Is(err, ErrNotFound):
					default:
						bad = append(bad, err)
					}
				}()
			}
			wg.Wait()
			if len(bad) > 0 {
				t.Fatalf("unexpected errors: %v", bad)
			}
			if taken != 1 {
				t.Fatalf("round %d: %d takers succeeded, want exactly one", round, taken)
			}
		}
	})

	t.Run("CancelledContext", func(t *testing.T) {
		h := newHarness(t)
		cctx, cancel := context.WithCancel(ctx)
		cancel()
		if err := h.store.SaveTable(cctx, "r1", 1, []byte("x"), h.ttl); err == nil {
			t.Fatal("SaveTable with a cancelled context succeeded")
		}
		if _, _, err := h.store.LoadTable(cctx, "r1"); err == nil {
			t.Fatal("LoadTable with a cancelled context succeeded")
		}
		if _, _, err := h.store.LoadTable(ctx, "r1"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("the cancelled save must not have landed: %v", err)
		}
	})

	t.Run("Closed", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.SaveTable(ctx, "r1", 1, []byte("x"), h.ttl))
		must(t, h.store.Close())
		if _, _, err := h.store.LoadTable(ctx, "r1"); err == nil {
			t.Fatal("LoadTable after Close succeeded")
		}
		if err := h.store.Ping(ctx); err == nil {
			t.Fatal("Ping after Close succeeded")
		}
	})
}

// ---- helpers ----------------------------------------------------------------

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func joinBytes(msgs [][]byte) string {
	parts := make([]string, len(msgs))
	for i, m := range msgs {
		parts[i] = string(m)
	}
	return strings.Join(parts, " ")
}

func idsOf(ts []TableSummary) string {
	parts := make([]string, len(ts))
	for i, s := range ts {
		parts[i] = s.RoomID
	}
	return strings.Join(parts, " ")
}

// bigSnapshot builds a game.Snapshot-shaped JSON document of about size
// bytes whose hand.id is handID (so HandIDOf finds it).
func bigSnapshot(handID string, size int) []byte {
	head := fmt.Sprintf(`{"roomId":"r1","code":"ABCD","category":"blind","state":"betting","handNo":3,"dealerSeat":1,"hand":{"id":%q,"pot":1200,"contributions":[]},"seats":[null,null,null,null,null],"pad":"`, handID)
	tail := `"}`
	pad := size - len(head) - len(tail)
	if pad < 0 {
		pad = 0
	}
	return []byte(head + strings.Repeat("x", pad) + tail)
}
