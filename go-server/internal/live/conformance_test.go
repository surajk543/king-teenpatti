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

	// /health calls CountTables on every request, so it must be cheap AND it
	// must agree with the listing — otherwise the number on the dashboard is
	// a different number from the one a restore would rebuild.
	t.Run("CountTablesAgreesWithListTables", func(t *testing.T) {
		h := newHarness(t)
		n, err := h.store.CountTables(ctx)
		must(t, err)
		if n != 0 {
			t.Fatalf("empty CountTables = %d, want 0", n)
		}
		for _, id := range []string{"a", "b", "c", "d"} {
			must(t, h.store.SaveTable(ctx, id, 1, []byte(id), h.ttl))
		}
		must(t, h.store.DeleteTable(ctx, "b"))
		must(t, h.store.SaveTable(ctx, "a", 2, []byte("a2"), h.ttl))
		refs, err := h.store.ListTables(ctx)
		must(t, err)
		n, err = h.store.CountTables(ctx)
		must(t, err)
		if n != len(refs) {
			t.Fatalf("CountTables = %d, ListTables = %d", n, len(refs))
		}
		if n != 3 {
			t.Fatalf("CountTables = %d, want 3", n)
		}
		// After everything expires both agree on nothing.
		h.advance(h.ttl + time.Second)
		refs, err = h.store.ListTables(ctx)
		must(t, err)
		n, err = h.store.CountTables(ctx)
		must(t, err)
		if n != len(refs) || n != 0 {
			t.Fatalf("after expiry CountTables = %d, ListTables = %d, want 0", n, len(refs))
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
		must(t, h.store.SetSeated(ctx, "u1", "r1", Playing{}, 0))
		must(t, h.store.SetSeated(ctx, "u2", "r1", Playing{}, 0))
		room, err := h.store.SeatOf(ctx, "u1")
		must(t, err)
		if room != "r1" {
			t.Fatalf("SeatOf = %q, want r1", room)
		}
		must(t, h.store.SetSeated(ctx, "u1", "r2", Playing{}, 0)) // moved
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

	// ListSeats and ListSummaries are the sweep side of the mirror: what the
	// store holds that memory may no longer have (RoomManager.ReconcileLive).
	t.Run("ListSeatsAndSummaries", func(t *testing.T) {
		h := newHarness(t)
		seats, err := h.store.ListSeats(ctx)
		must(t, err)
		if len(seats) != 0 {
			t.Fatalf("empty ListSeats = %v", seats)
		}
		summaries, err := h.store.ListSummaries(ctx)
		must(t, err)
		if len(summaries) != 0 {
			t.Fatalf("empty ListSummaries = %v", summaries)
		}

		must(t, h.store.SetSeated(ctx, "u1", "r1", Playing{}, 0))
		must(t, h.store.SetSeated(ctx, "u2", "r1", Playing{}, 0))
		must(t, h.store.SetSeated(ctx, "u3", "r2", Playing{}, 0))
		seats, err = h.store.ListSeats(ctx)
		must(t, err)
		if len(seats) != 3 || seats["u1"] != "r1" || seats["u3"] != "r2" {
			t.Fatalf("ListSeats = %v", seats)
		}
		must(t, h.store.ClearSeated(ctx, "u2"))
		seats, err = h.store.ListSeats(ctx)
		must(t, err)
		if len(seats) != 2 {
			t.Fatalf("ListSeats after a clear = %v", seats)
		}

		// Private tables publish a summary too (they are just never indexed
		// in a bucket), so the sweep has to see them.
		must(t, h.store.PublishTable(ctx, TableSummary{RoomID: "r1", Category: "blind", BootAmount: 200, Players: 2}))
		must(t, h.store.PublishTable(ctx, TableSummary{RoomID: "r2", Category: "seen", BootAmount: 5000, Players: 1}))
		must(t, h.store.PublishTable(ctx, TableSummary{RoomID: "r3", Category: "seen", BootAmount: 5000, IsPrivate: true}))
		summaries, err = h.store.ListSummaries(ctx)
		must(t, err)
		if len(summaries) != 3 {
			t.Fatalf("ListSummaries = %v", summaries)
		}
		byRoom := map[string]TableSummary{}
		for _, s := range summaries {
			byRoom[s.RoomID] = s
		}
		if byRoom["r1"].Category != "blind" || byRoom["r1"].BootAmount != 200 {
			t.Fatalf("summary fields lost: %+v", byRoom["r1"])
		}
		// The category and boot are what a sweep needs to retire a stray.
		must(t, h.store.RetireTable(ctx, byRoom["r2"].RoomID, byRoom["r2"].Category, byRoom["r2"].BootAmount))
		summaries, err = h.store.ListSummaries(ctx)
		must(t, err)
		if len(summaries) != 2 {
			t.Fatalf("ListSummaries after a retire = %v", summaries)
		}
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

	// The playing record rides the seat mirror (Friends V1): written with the
	// seat, rewritten by the next SetSeated (a move, a restore, the
	// reconciler's refresh), deleted with the seat, and read back — never the
	// room — by Presence.
	t.Run("PlayingRidesTheSeat", func(t *testing.T) {
		h := newHarness(t)
		seen := Playing{Game: "TEEN_PATTI", Variant: "SEEN", UpdatedAt: 1_790_000_000_000}
		must(t, h.store.SetSeated(ctx, "u1", "r1", seen, h.ttl))
		got, err := h.store.Presence(ctx, []string{"u1"})
		must(t, err)
		want := Presence{Playing: true, Game: "TEEN_PATTI", Variant: "SEEN", UpdatedAt: 1_790_000_000_000}
		if got["u1"] != want {
			t.Fatalf("Presence after SetSeated = %+v, want %+v", got["u1"], want)
		}
		if got["u1"].Status() != StatusPlaying || !got["u1"].IsOnline() {
			t.Fatalf("a seated player with no socket is PLAYING and online: %s %v", got["u1"].Status(), got["u1"].IsOnline())
		}
		// A move rewrites it.
		must(t, h.store.SetSeated(ctx, "u1", "r2", Playing{Game: "POKER", Variant: "TEXAS_HOLDEM", UpdatedAt: 1_790_000_000_500}, h.ttl))
		got, err = h.store.Presence(ctx, []string{"u1"})
		must(t, err)
		if p := got["u1"]; !p.Playing || p.Game != "POKER" || p.Variant != "TEXAS_HOLDEM" || p.UpdatedAt != 1_790_000_000_500 {
			t.Fatalf("Presence after a move = %+v", p)
		}
		room, err := h.store.SeatOf(ctx, "u1")
		must(t, err)
		if room != "r2" {
			t.Fatalf("SeatOf after the move = %q", room)
		}
		// A write with no stamp is stamped by the store.
		must(t, h.store.SetSeated(ctx, "u2", "r1", Playing{Game: "TEEN_PATTI", Variant: "BLIND"}, h.ttl))
		got, err = h.store.Presence(ctx, []string{"u2"})
		must(t, err)
		if got["u2"].UpdatedAt <= 0 {
			t.Fatalf("an unstamped record = %+v, want updatedAt stamped", got["u2"])
		}
		// A zero Playing writes the seat alone, and takes an old record away.
		must(t, h.store.SetSeated(ctx, "u2", "r1", Playing{}, h.ttl))
		got, err = h.store.Presence(ctx, []string{"u2"})
		must(t, err)
		if got["u2"] != (Presence{}) {
			t.Fatalf("a seat with no playing record = %+v", got["u2"])
		}
		if room, err := h.store.SeatOf(ctx, "u2"); err != nil || room != "r1" {
			t.Fatalf("the seat itself = %q %v", room, err)
		}
		// Clearing the seat clears the record.
		must(t, h.store.ClearSeated(ctx, "u1"))
		got, err = h.store.Presence(ctx, []string{"u1"})
		must(t, err)
		if got["u1"] != (Presence{}) {
			t.Fatalf("Presence after ClearSeated = %+v", got["u1"])
		}
	})

	t.Run("PlayingRecordExpiry", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.SetSeated(ctx, "short", "r1", Playing{Game: "TEEN_PATTI", Variant: "SEEN"}, h.ttl))
		must(t, h.store.SetSeated(ctx, "refreshed", "r1", Playing{Game: "TEEN_PATTI", Variant: "SEEN"}, h.ttl))
		must(t, h.store.SetSeated(ctx, "forever", "r1", Playing{Game: "POKER", Variant: "OMAHA"}, 0))
		h.advance(h.ttl / 2)
		// The reconciler's refresh: the same seat written again.
		must(t, h.store.SetSeated(ctx, "refreshed", "r1", Playing{Game: "TEEN_PATTI", Variant: "SEEN"}, h.ttl))
		h.advance(h.ttl * 3 / 4) // 5/4 ttl since "short" was written, 3/4 since the refresh
		got, err := h.store.Presence(ctx, []string{"short", "refreshed", "forever"})
		must(t, err)
		if got["short"].Playing {
			t.Fatal("a playing record outlived its ttl")
		}
		if !got["refreshed"].Playing || !got["forever"].Playing {
			t.Fatalf("a refreshed record or one with no ttl lapsed: %+v", got)
		}
		// The seat key itself never expires: only the record does.
		if room, err := h.store.SeatOf(ctx, "short"); err != nil || room != "r1" {
			t.Fatalf("the seat key lapsed with its record: %q %v", room, err)
		}
		past(h)
		got, err = h.store.Presence(ctx, []string{"forever"})
		must(t, err)
		if !got["forever"].Playing {
			t.Fatal("a record written with no ttl lapsed")
		}
	})

	// Presence is one batched read: online (kt:online live), playing (the
	// record), both, or neither, for a whole list at once; one entry per
	// distinct id.
	t.Run("PresenceBatch", func(t *testing.T) {
		h := newHarness(t)
		empty, err := h.store.Presence(ctx, nil)
		must(t, err)
		if empty == nil || len(empty) != 0 {
			t.Fatalf("Presence(nil) = %#v, want an empty non-nil map", empty)
		}
		must(t, h.store.SetOnline(ctx, "lobby", "inst", h.ttl))
		must(t, h.store.SetOnline(ctx, "table", "inst", h.ttl))
		must(t, h.store.SetSeated(ctx, "table", "r1", Playing{Game: "TEEN_PATTI", Variant: "VARIATION"}, h.ttl))
		must(t, h.store.SetSeated(ctx, "grace", "r1", Playing{Game: "POKER", Variant: "FIVE_CARD_DRAW"}, h.ttl))
		must(t, h.store.SetOnline(ctx, "gone", "inst", h.ttl))
		must(t, h.store.SetOffline(ctx, "gone"))
		got, err := h.store.Presence(ctx, []string{"lobby", "table", "grace", "gone", "nobody", "lobby", ""})
		must(t, err)
		if len(got) != 5 {
			t.Fatalf("Presence answered %d ids, want the 5 distinct ones: %+v", len(got), got)
		}
		for id, want := range map[string]struct {
			status          string
			online, playing bool
			variant         string
		}{
			"lobby":  {StatusOnline, true, false, ""},
			"table":  {StatusPlaying, true, true, "VARIATION"},
			"grace":  {StatusPlaying, true, true, "FIVE_CARD_DRAW"},
			"gone":   {StatusOffline, false, false, ""},
			"nobody": {StatusOffline, false, false, ""},
		} {
			p, ok := got[id]
			if !ok {
				t.Fatalf("no entry for %s", id)
			}
			if p.Status() != want.status || p.IsOnline() != want.online || p.Playing != want.playing || p.Variant != want.variant {
				t.Fatalf("%s = %+v (%s), want %+v", id, p, p.Status(), want)
			}
		}
		// A presence entry that has run out is offline, whatever is left in
		// the hash until OnlineCount reaps it.
		past(h)
		got, err = h.store.Presence(ctx, []string{"lobby", "table"})
		must(t, err)
		if got["lobby"].Online || got["table"] != (Presence{}) {
			t.Fatalf("Presence after every ttl = %+v", got)
		}
	})

	t.Run("PresenceOfAThousandAccounts", func(t *testing.T) {
		h := newHarness(t)
		ids := make([]string, 1200)
		for i := range ids {
			ids[i] = fmt.Sprintf("u%04d", i)
			// A minute, not h.ttl: on a real server the writes themselves
			// take wall time, and nothing here is about expiry.
			if i%3 == 0 {
				must(t, h.store.SetSeated(ctx, ids[i], "r", Playing{Game: "TEEN_PATTI", Variant: "SEEN"}, time.Minute))
			}
			if i%2 == 0 {
				must(t, h.store.SetOnline(ctx, ids[i], "inst", time.Minute))
			}
		}
		got, err := h.store.Presence(ctx, ids)
		must(t, err)
		if len(got) != len(ids) {
			t.Fatalf("answered %d of %d", len(got), len(ids))
		}
		for i, id := range ids {
			if p := got[id]; p.Playing != (i%3 == 0) || p.Online != (i%2 == 0) {
				t.Fatalf("%s = %+v", id, p)
			}
		}
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
