package game

import (
	"encoding/json"
	"math"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// A rented card back runs out (owner, 3 Oct 2026: "when validity of premium
// card expires, it restores default card"), and the seat lets go of it at
// that moment by itself: the back carries its ExpiresAt, and the table's one
// card-back clock takes it off every viewer's snapshot when its time comes —
// with nobody asking, since the owner's app may well be closed. A back renewed
// meanwhile stays on, seats with different terms go one at a time, one that
// arrives run out is the default back from the start, a restore keeps each
// term, and a table that is destroyed, suspended or fenced leaves no clock
// behind. The RoomManager's side (a move, a restart) is in
// cardbackground_rooms_test.go.

// rented is b rented until ends (epoch ms).
func rented(b *CardBackground, ends int64) *CardBackground {
	b.ExpiresAt = ends
	return b
}

// nextDeadline is when the earliest timer armed on the fake clock fires, or
// the zero time when none is armed.
func (c *fakeClock) nextDeadline() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	var next time.Time
	for _, e := range c.pending {
		if next.IsZero() || e.at.Before(next) {
			next = e.at
		}
	}
	return next
}

// backAt is the card back viewer's snapshot shows on userID's seat as the
// table holds it, or nil for none.
func (h *harness) backAt(viewer, userID string) *CardBackground {
	h.t.Helper()
	for _, s := range h.view(viewer).Seats {
		if s.UserID == userID {
			return s.CardBackground
		}
	}
	h.t.Fatalf("%s's snapshot has no seat for %s", viewer, userID)
	return nil
}

// eventsSince are the names of the events delivered since mark.
func (h *harness) eventsSince(mark int) []string {
	return h.rec.names()[mark:]
}

func TestARentedCardBackLeavesEveryViewersSnapshotTheMomentItRunsOut(t *testing.T) {
	store := livetest.New()
	h := newHarness(t, liveConfig(), withLive(store))
	ends := Millis(h.clock.Now()) + 20_000
	h.seatWithBack("a", nil)
	h.seatWithBack("b", rented(royalLion(), ends))
	h.seatWithBack("c", brutalDemon()) // bought for ever: no term
	h.advance(6 * time.Second)
	if !h.hasHand() {
		t.Fatal("no hand was dealt")
	}
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	bSeat := h.seatInfo("b").SeatIndex

	// The wire carries the term on b's back — and nothing of the kind on c's,
	// which never runs out and is sent byte for byte as it always was.
	raw, err := json.Marshal(h.view("a").Seats[bSeat].CardBackground)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"id":4,"url":"` + cardsAt + `Royal%20Lion.jpg","assetFormat":"IMAGE","crop":{"x":0.2065,"y":0.0948,"w":0.5851,"h":0.8192},"expiresAt":` +
		strconv.FormatInt(ends, 10) + `}`; string(raw) != want {
		t.Fatalf("b's rented back on the wire:\n got %s\nwant %s", raw, want)
	}
	if back, ok := h.backOn("a", "c"); !ok || !sameBack(t, back, brutalDemon()) {
		t.Fatalf("c's back for ever is sent as %v", back)
	}

	turn, deadline, pot := h.turnUser(), h.turnDeadline(), h.pot()
	hand := mustSnapshot(h)
	saves, events, pending := len(store.Saves()), h.rec.count(), h.clock.Pending()

	// A millisecond before its moment it is still on, for everyone, and
	// nothing has been sent.
	h.advance(14*time.Second - time.Millisecond)
	for _, viewer := range []string{"a", "b", "c", ""} {
		if back, ok := h.backOn(viewer, "b"); !ok || !sameBack(t, back, rented(royalLion(), ends)) {
			t.Errorf("a millisecond before its moment %q sees %v on b's seat, want the Royal Lion and its term", viewer, back)
		}
	}
	eq(t, h.rec.count(), events, "nothing is sent before the moment")

	// At its moment it comes off, for everyone at once: seatUpdated for b's
	// seat, then one state.
	h.advance(time.Millisecond)
	if got := h.eventsSince(events); !reflect.DeepEqual(got, []string{"seatUpdated", "state"}) {
		t.Fatalf("the moment emitted %v, want seatUpdated then state", got)
	}
	if got := h.rec.last("seatUpdated"); got != bSeat {
		t.Fatalf("seatUpdated for seat %v, want b's %d", got, bSeat)
	}
	for _, viewer := range []string{"a", "b", "c", ""} {
		if back, ok := h.backOn(viewer, "b"); ok {
			t.Errorf("%q still sees %v on b's seat after its term ended", viewer, back)
		}
		if back, ok := h.backOn(viewer, "c"); !ok || !sameBack(t, back, brutalDemon()) {
			t.Errorf("%q sees %v on c's seat, whose back never runs out", viewer, back)
		}
		if back, ok := h.backOn(viewer, "a"); ok {
			t.Errorf("%q sees %v on a's seat, which never had one", viewer, back)
		}
	}

	// Nothing else moved: the turn, its clock and the pot are as they were,
	// and the snapshot is the one from before but for b's back (and the seq
	// of the save it took).
	eq(t, h.hasHand(), true, "the hand plays on")
	eq(t, h.turnUser(), turn, "the same player is on turn")
	eq(t, h.turnDeadline().Equal(deadline), true, "on the same clock")
	eq(t, h.pot(), pot, "the pot is untouched")
	now := mustSnapshot(h)
	if now.Seats[bSeat].CardBackground != nil {
		t.Fatalf("the snapshot still carries %+v on b's seat", now.Seats[bSeat].CardBackground)
	}
	now.Seq = hand.Seq
	hand.Seats[bSeat].CardBackground = nil
	if got, want := mustJSON(t, now), mustJSON(t, hand); got != want {
		t.Fatalf("the back running out moved the hand:\n got %s\nwant %s", got, want)
	}

	// The live store was saved once for it, without it.
	eq(t, len(store.Saves()), saves+1, "one save at the moment")
	stored, _ := store.Stored("room-1")
	var latest Snapshot
	if err := json.Unmarshal(stored.Snapshot, &latest); err != nil {
		t.Fatal(err)
	}
	if latest.Seats[bSeat].CardBackground != nil || !strings.Contains(string(stored.Snapshot), "Brutal%20Demon") {
		t.Fatalf("the stored snapshot: %s", stored.Snapshot)
	}
	// And the clock is spent: no seat wears a back that runs out any more.
	eq(t, h.clock.Pending(), pending-1, "the card-back clock is not re-armed with nothing left to run out")
}

// Renewed before it runs out — the same back, a later term, handed to the seat
// by SetCardBackground — a back stays on through its old moment and comes off
// at its new one. Replaced by another, the old moment takes nothing: the new
// back goes when its own term ends, or never.
func TestARenewedCardBackStaysOnUntilItsNewMomentAndAReplacedOneIsKept(t *testing.T) {
	// Alone at a waiting table, the card-back clock is the only clock.
	t.Run("renewed", func(t *testing.T) {
		h := newHarness(t, tableConfig())
		start := Millis(h.clock.Now())
		h.seatWithBack("a", rented(royalLion(), start+10_000))
		eq(t, h.clock.Pending(), 1, "the card-back clock is armed")
		eq(t, Millis(h.clock.nextDeadline()), start+10_000, "for the term's end")

		h.advance(5 * time.Second)
		if err := h.table.SetCardBackground("a", rented(royalLion(), start+40_000)); err != nil {
			t.Fatal(err)
		}
		eq(t, h.clock.Pending(), 1, "one clock still")
		eq(t, Millis(h.clock.nextDeadline()), start+40_000, "re-armed for the new term")
		events := h.rec.count()

		h.advance(5 * time.Second) // the old moment
		eq(t, h.rec.count(), events, "the old moment takes nothing")
		for _, viewer := range []string{"a", ""} {
			if got := h.backAt(viewer, "a"); !reflect.DeepEqual(got, rented(royalLion(), start+40_000)) {
				t.Fatalf("after the old moment %q sees %+v, want the renewed Royal Lion", viewer, got)
			}
		}
		h.advance(30*time.Second - time.Millisecond)
		if h.backAt("a", "a") == nil {
			t.Fatal("the renewed back came off before its new moment")
		}
		h.advance(time.Millisecond)
		if got := h.backAt("", "a"); got != nil {
			t.Fatalf("the renewed back outlived its new term: %+v", got)
		}
		if got := h.eventsSince(events); !reflect.DeepEqual(got, []string{"seatUpdated", "state"}) {
			t.Fatalf("the new moment emitted %v", got)
		}
		eq(t, h.clock.Pending(), 0, "nothing left to run out")
	})

	t.Run("replaced by one bought for ever", func(t *testing.T) {
		h := newHarness(t, tableConfig())
		start := Millis(h.clock.Now())
		h.seatWithBack("a", rented(royalLion(), start+10_000))
		if err := h.table.SetCardBackground("a", brutalDemon()); err != nil {
			t.Fatal(err)
		}
		eq(t, h.clock.Pending(), 0, "a back for ever arms no clock")
		events := h.rec.count()
		h.advance(time.Hour)
		eq(t, h.rec.count(), events, "the old moment, and an hour after it, take nothing")
		if got := h.backAt("", "a"); !reflect.DeepEqual(got, brutalDemon()) {
			t.Fatalf("the back bought for ever is %+v", got)
		}
	})

	t.Run("replaced by one that runs out sooner", func(t *testing.T) {
		h := newHarness(t, tableConfig())
		start := Millis(h.clock.Now())
		h.seatWithBack("a", rented(royalLion(), start+30_000))
		if err := h.table.SetCardBackground("a", rented(brutalDemon(), start+10_000)); err != nil {
			t.Fatal(err)
		}
		eq(t, Millis(h.clock.nextDeadline()), start+10_000, "re-armed for the sooner term")
		h.advance(10 * time.Second)
		if got := h.backAt("", "a"); got != nil {
			t.Fatalf("the sooner term did not end: %+v", got)
		}
		eq(t, h.clock.Pending(), 0, "the Royal Lion's moment is not waited on: it is not worn")
	})

	t.Run("taken off", func(t *testing.T) {
		h := newHarness(t, tableConfig())
		h.seatWithBack("a", rented(royalLion(), Millis(h.clock.Now())+10_000))
		if err := h.table.SetCardBackground("a", nil); err != nil {
			t.Fatal(err)
		}
		eq(t, h.clock.Pending(), 0, "the default back runs out never")
	})
}

// Seats with different terms lose their backs one at a time, each at its own
// moment, the clock re-arming for the next; two that end in the same
// millisecond go together, in one state for the table. A back bought for ever
// never goes, and a seat with none is never touched.
func TestEachSeatsRentedBackComesOffAtItsOwnMoment(t *testing.T) {
	cfg := tableConfig()
	cfg.NextHandDelay = time.Hour // the table stays waiting: only the backs change
	h := newHarness(t, cfg)
	start := Millis(h.clock.Now())
	h.seatWithBack("a", rented(brutalDemon(), start+10_000))
	h.seatWithBack("b", rented(royalLion(), start+20_000))
	h.seatWithBack("c", wholePicture())
	h.seatWithBack("d", rented(royalLion(), start+20_000))
	h.seatWithBack("e", nil)
	seatIndexOf := func(id string) int { return h.seatInfo(id).SeatIndex }

	events := h.rec.count()
	h.advance(10*time.Second - time.Millisecond)
	eq(t, h.rec.count(), events, "nothing before the first moment")
	h.advance(time.Millisecond)
	if got := h.eventsSince(events); !reflect.DeepEqual(got, []string{"seatUpdated", "state"}) {
		t.Fatalf("a's moment emitted %v", got)
	}
	if got := h.rec.last("seatUpdated"); got != seatIndexOf("a") {
		t.Fatalf("a's moment updated seat %v, want a's %d", got, seatIndexOf("a"))
	}
	for _, viewer := range []string{"a", "b", "c", "d", "e", ""} {
		if got := h.backAt(viewer, "a"); got != nil {
			t.Errorf("%q still sees a's back: %+v", viewer, got)
		}
		for _, id := range []string{"b", "d"} {
			if got := h.backAt(viewer, id); !reflect.DeepEqual(got, rented(royalLion(), start+20_000)) {
				t.Errorf("%q sees %+v on %s's seat, whose term has ten seconds to run", viewer, got, id)
			}
		}
	}
	eq(t, Millis(h.clock.nextDeadline()), start+20_000, "the clock re-armed for the next term")

	events = h.rec.count()
	h.advance(10*time.Second - time.Millisecond)
	eq(t, h.rec.count(), events, "nothing between the two moments")
	h.advance(time.Millisecond)
	if got := h.eventsSince(events); !reflect.DeepEqual(got, []string{"seatUpdated", "seatUpdated", "state"}) {
		t.Fatalf("b's and d's shared moment emitted %v, want a seatUpdated each and one state", got)
	}
	updated := h.rec.all("seatUpdated")
	if got := updated[len(updated)-2:]; got[0] != seatIndexOf("b") || got[1] != seatIndexOf("d") {
		t.Fatalf("the shared moment updated seats %v, want b's %d and d's %d", got, seatIndexOf("b"), seatIndexOf("d"))
	}
	for _, viewer := range []string{"a", "c", "e", ""} {
		for _, id := range []string{"a", "b", "d", "e"} {
			if got := h.backAt(viewer, id); got != nil {
				t.Errorf("%q sees %+v on %s's seat", viewer, got, id)
			}
		}
		if got := h.backAt(viewer, "c"); !reflect.DeepEqual(got, wholePicture()) {
			t.Errorf("%q sees %+v on c's seat, whose back is for ever", viewer, got)
		}
	}

	events = h.rec.count()
	h.advance(10 * time.Minute)
	eq(t, h.rec.count(), events, "nothing is left to run out")
}

// A back that arrives run out is the default back from the start — at a
// sit-down (a move's arrival is one) and chosen at the table, where it takes
// off the back the seat wore — and arms nothing. Its moment is the account's
// own: run out AT its expiresAt.
func TestACardBackThatArrivesRunOutIsTheDefaultBack(t *testing.T) {
	arrivals := []struct {
		name    string
		ends    func(now int64) int64
		kept    bool
		pending int
	}{
		{"ending this very millisecond", func(now int64) int64 { return now }, false, 0},
		{"ended yesterday", func(now int64) int64 { return now - 86_400_000 }, false, 0},
		{"an expiry before the epoch", func(int64) int64 { return -1 }, false, 0},
		{"a millisecond still to run", func(now int64) int64 { return now + 1 }, true, 1},
	}
	for _, a := range arrivals {
		t.Run("a sit-down "+a.name, func(t *testing.T) {
			h := newHarness(t, tableConfig())
			ends := a.ends(Millis(h.clock.Now()))
			h.seatWithBack("a", rented(royalLion(), ends))
			got := h.backAt("", "a")
			if a.kept != (got != nil) {
				t.Fatalf("the seat keeps %+v", got)
			}
			if a.kept && got.ExpiresAt != ends {
				t.Fatalf("the seat keeps the term %d, want %d", got.ExpiresAt, ends)
			}
			eq(t, h.clock.Pending(), a.pending, "the card-back clock")
			if a.kept {
				h.advance(time.Millisecond)
				if got := h.backAt("", "a"); got != nil {
					t.Fatalf("the last millisecond ran out and the back is still on: %+v", got)
				}
			}
		})
	}

	t.Run("a sit-down with a term as far off as int64 goes", func(t *testing.T) {
		h := newHarness(t, tableConfig())
		h.seatWithBack("a", rented(royalLion(), math.MaxInt64))
		eq(t, h.clock.Pending(), 1, "armed, however far off")
		h.advance(24 * time.Hour)
		if got := h.backAt("", "a"); got == nil || got.ExpiresAt != math.MaxInt64 {
			t.Fatalf("a day on, the seat wears %+v", got)
		}
	})

	t.Run("chosen at the table", func(t *testing.T) {
		h := newHarness(t, tableConfig())
		h.seatWithBack("a", brutalDemon())
		events := h.rec.count()
		if err := h.table.SetCardBackground("a", rented(royalLion(), Millis(h.clock.Now()))); err != nil {
			t.Fatal(err)
		}
		if got := h.backAt("", "a"); got != nil {
			t.Fatalf("a back chosen as its term ends is on the seat: %+v", got)
		}
		if got := h.eventsSince(events); !reflect.DeepEqual(got, []string{"seatUpdated", "state"}) {
			t.Fatalf("the change emitted %v: it is the default back, and everyone is told", got)
		}
		eq(t, h.clock.Pending(), 0, "nothing to run out")
	})
}

// A player who leaves takes their term off the card-back clock: it is re-armed
// for the backs still at the table, so a moment nobody is left to wear wakes
// nothing, and the next back still comes off on time.
func TestALeavingPlayersTermLeavesTheCardBackClockWithThem(t *testing.T) {
	cfg := tableConfig()
	cfg.NextHandDelay = time.Hour
	h := newHarness(t, cfg)
	start := Millis(h.clock.Now())
	h.seatWithBack("a", rented(brutalDemon(), start+10_000))
	h.seatWithBack("b", rented(royalLion(), start+30_000))
	eq(t, Millis(h.clock.nextDeadline()), start+10_000, "armed for a's term, the earliest")

	h.advance(5 * time.Second)
	h.remove("a", LeaveReasonLeft)
	// The countdown went with a (one funded seat is not a game): the one clock
	// left is the card-back clock, and it waits on b's term now.
	eq(t, h.clock.Pending(), 1, "one clock")
	eq(t, Millis(h.clock.nextDeadline()), start+30_000, "re-armed for b's term")
	events := h.rec.count()
	h.advance(25*time.Second - time.Millisecond)
	eq(t, h.rec.count(), events, "a's moment, with a gone, wakes nothing")
	if h.backAt("b", "b") == nil {
		t.Fatal("b's back came off before its moment")
	}
	h.advance(time.Millisecond)
	if got := h.backAt("b", "b"); got != nil {
		t.Fatalf("b's back outlived its term: %+v", got)
	}
	h.remove("b", LeaveReasonLeft)
	eq(t, h.clock.Pending(), 0, "an empty table runs no clock")
}

// A restore brings each seat's back home on the terms it had: one whose term
// ended while the process was down comes back as the default back — in every
// viewer's snapshot and in the store's — and one still running comes off at
// its moment, on the restored table's clock, for what was left of it: mid-hand,
// with the hand none the wiser.
func TestARestoreDropsABackThatRanOutWhileDownAndTakesOffOneStillRunningOnTime(t *testing.T) {
	h := newHarness(t, liveConfig())
	start := Millis(h.clock.Now())
	h.seatWithBack("a", rented(brutalDemon(), start+30_000))
	h.seatWithBack("b", rented(royalLion(), start+60_000))
	h.seatWithBack("c", wholePicture())
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	snap := roundTrip(t, mustSnapshot(h))
	for _, term := range []int64{start + 30_000, start + 60_000} {
		if !strings.Contains(mustJSON(t, snap), `"expiresAt":`+strconv.FormatInt(term, 10)) {
			t.Fatalf("the snapshot lost the term %d: %s", term, mustJSON(t, snap))
		}
	}

	t.Run("down past one term", func(t *testing.T) {
		r := restoreHarness(t, roundTrip(t, snap), newFakeClock(FromMillis(start+40_000)))
		eq(t, r.hasHand(), true, "the hand came back")
		for _, viewer := range []string{"a", "b", "c", ""} {
			if got := r.backAt(viewer, "a"); got != nil {
				t.Errorf("after the restart %q sees a's back, whose term ended while the process was down: %+v", viewer, got)
			}
			if got := r.backAt(viewer, "b"); !reflect.DeepEqual(got, rented(royalLion(), start+60_000)) {
				t.Errorf("after the restart %q sees %+v on b's seat", viewer, got)
			}
			if got := r.backAt(viewer, "c"); !reflect.DeepEqual(got, wholePicture()) {
				t.Errorf("after the restart %q sees %+v on c's seat", viewer, got)
			}
		}
		if raw := mustJSON(t, mustSnapshot(r)); strings.Contains(raw, "Brutal%20Demon") {
			t.Fatalf("the restored table's snapshot keeps a's back: %s", raw)
		}

		// b's term had twenty seconds to run when the process came back.
		turn := r.turnUser()
		events := r.rec.count()
		r.advance(20*time.Second - time.Millisecond)
		eq(t, r.rec.count(), events, "nothing before b's moment")
		r.advance(time.Millisecond)
		if got := r.eventsSince(events); !reflect.DeepEqual(got, []string{"seatUpdated", "state"}) {
			t.Fatalf("b's moment emitted %v", got)
		}
		for _, viewer := range []string{"a", "b", "c", ""} {
			if got := r.backAt(viewer, "b"); got != nil {
				t.Errorf("%q still sees b's back after its moment: %+v", viewer, got)
			}
		}
		eq(t, r.turnUser(), turn, "the same player is on turn")
		eq(t, r.hasHand(), true, "the hand plays on")
	})

	t.Run("down before either term", func(t *testing.T) {
		r := restoreHarness(t, roundTrip(t, snap), newFakeClock(FromMillis(start+10_000)))
		if got := r.backAt("c", "a"); !reflect.DeepEqual(got, rented(brutalDemon(), start+30_000)) {
			t.Fatalf("after the restart a's back is %+v", got)
		}
		eq(t, Millis(r.clock.nextDeadline()), start+30_000, "the card-back clock armed for what is left of a's term")
		r.advance(20 * time.Second)
		if got := r.backAt("c", "a"); got != nil {
			t.Fatalf("a's back outlived its term on the restored table: %+v", got)
		}
		if got := r.backAt("c", "b"); !reflect.DeepEqual(got, rented(royalLion(), start+60_000)) {
			t.Fatalf("b's back, thirty seconds still to run, is %+v", got)
		}
	})

	t.Run("down until the very moment", func(t *testing.T) {
		r := restoreHarness(t, roundTrip(t, snap), newFakeClock(FromMillis(start+30_000)))
		if got := r.backAt("b", "a"); got != nil {
			t.Fatalf("a back whose moment is the restore's is restored: %+v", got)
		}
	})
}

// Destroy, a graceful suspend and a fence stop the card-back clock with every
// other, so nothing is left armed to fire into a table that has gone. The
// suspended table's last snapshot keeps each back's term, for the next process
// to arm again.
func TestDestroySuspendAndAFenceStopTheCardBackClock(t *testing.T) {
	t.Run("destroy", func(t *testing.T) {
		h := newHarness(t, tableConfig())
		h.seatWithBack("a", rented(royalLion(), Millis(h.clock.Now())+10_000))
		eq(t, h.clock.Pending(), 1, "armed")
		if err := h.table.Destroy(); err != nil {
			t.Fatal(err)
		}
		eq(t, h.clock.Pending(), 0, "stopped")
		events := h.rec.count()
		h.advance(time.Minute)
		eq(t, h.rec.count(), events, "nothing after the destroy")
	})

	t.Run("suspend", func(t *testing.T) {
		store := livetest.New()
		h := newHarness(t, liveConfig(), withLive(store))
		ends := Millis(h.clock.Now()) + 10_000
		h.seatWithBack("a", rented(royalLion(), ends))
		eq(t, h.clock.Pending(), 1, "armed")
		if err := h.table.Suspend(); err != nil {
			t.Fatal(err)
		}
		eq(t, h.clock.Pending(), 0, "stopped")
		stored, ok := store.Stored("room-1")
		if !ok || !strings.Contains(string(stored.Snapshot), `"expiresAt":`+strconv.FormatInt(ends, 10)) {
			t.Fatalf("the suspended table's snapshot lost the term: %s", stored.Snapshot)
		}
		events := h.rec.count()
		h.advance(time.Minute)
		eq(t, h.rec.count(), events, "nothing after the suspend")
	})

	t.Run("fence", func(t *testing.T) {
		store := livetest.New()
		h := newHarness(t, liveConfig(), withLive(store))
		now := Millis(h.clock.Now())
		h.seatWithBack("a", rented(royalLion(), now+10_000))
		// Another process owns the table now: the save after the next change
		// is refused, and the change that tripped the fence re-armed the clock
		// a moment before the fence stopped it.
		store.StaleSaves = true
		if err := h.table.SetCardBackground("a", rented(royalLion(), now+20_000)); err != nil {
			t.Fatal(err)
		}
		eq(t, h.table.Fenced(), true, "fenced")
		eq(t, h.clock.Pending(), 0, "stopped")
	})
}

// On the real clock — time.AfterFunc's own goroutine posting back onto the
// actor — a back comes off by itself at its moment, never before it; and a
// table destroyed or suspended with a back about to run out is never touched
// again. Under -race this is the proof that the clock shares nothing it should
// not with the table.
func TestOnTheRealClockABackComesOffByItselfAndAGoneTableIsNeverTouched(t *testing.T) {
	newReal := func(t *testing.T, store live.Store) (*Table, *recorder) {
		t.Helper()
		rec := &recorder{}
		table := NewTable(TableOptions{ID: "room-real", Code: "REAL01", Config: liveConfig(), Clock: RealClock{}, Listener: rec, Live: store})
		t.Cleanup(func() { _ = table.Destroy() })
		return table, rec
	}
	sit := func(t *testing.T, table *Table, ends int64) {
		t.Helper()
		if _, err := table.AddPlayer(NewPlayer{UserID: "a", DisplayName: "a", Chips: tableStart, SocketID: "s-a",
			CardBackground: rented(royalLion(), ends)}); err != nil {
			t.Fatal(err)
		}
	}

	t.Run("on time", func(t *testing.T) {
		table, rec := newReal(t, nil)
		ends := time.Now().UnixMilli() + 150
		sit(t, table, ends)
		mark := rec.count()
		giveUp := time.Now().Add(5 * time.Second)
		for {
			view, err := table.SerializeFor("a")
			if err != nil {
				t.Fatal(err)
			}
			if view.Seats[0].CardBackground == nil {
				if seen := time.Now().UnixMilli(); seen < ends {
					t.Fatalf("the back came off %d ms before its moment", ends-seen)
				}
				break
			}
			if time.Now().After(giveUp) {
				t.Fatal("the back never came off")
			}
			time.Sleep(10 * time.Millisecond)
		}
		// Alone at a waiting table, the back's moment is the only thing that
		// happened: everybody was told, once.
		if got := rec.names()[mark:]; !reflect.DeepEqual(got, []string{"seatUpdated", "state"}) {
			t.Fatalf("the moment emitted %v, want seatUpdated then state", got)
		}
	})

	for _, end := range []string{"destroyed", "suspended"} {
		t.Run(end+" first", func(t *testing.T) {
			store := livetest.New()
			table, rec := newReal(t, store)
			sit(t, table, time.Now().UnixMilli()+100)
			var err error
			if end == "destroyed" {
				err = table.Destroy()
			} else {
				err = table.Suspend()
			}
			if err != nil {
				t.Fatal(err)
			}
			events := rec.count()
			time.Sleep(300 * time.Millisecond)
			eq(t, rec.count(), events, "nothing reached the listener after the table was "+end)
			if _, err := table.SerializeFor("a"); err == nil {
				t.Fatalf("a %s table answered", end)
			}
		})
	}
}

// A term ends AT its expiresAt, to the millisecond — the account's own rule (a
// rental joins while expires_at > now) — and never for a back bought for ever.
// An expiry before the epoch is no term at all: a back carrying one is no back
// a seat keeps.
func TestARentalRunsOutAtItsExpiresAtToTheMillisecond(t *testing.T) {
	at := Millis(clockStart) + 5_000
	lion := rented(royalLion(), at)
	cases := []struct {
		name string
		b    *CardBackground
		now  time.Time
		want bool
	}{
		{"nothing", nil, FromMillis(at), false},
		{"a back for ever, years on", royalLion(), FromMillis(at + 10*365*86_400_000), false},
		{"a millisecond before", lion, FromMillis(at - 1), false},
		{"the last nanosecond before", lion, FromMillis(at).Add(-time.Nanosecond), false},
		{"its moment", lion, FromMillis(at), true},
		{"a nanosecond after", lion, FromMillis(at).Add(time.Nanosecond), true},
		{"a day after", lion, FromMillis(at + 86_400_000), true},
	}
	for _, c := range cases {
		if got := c.b.expiredAt(c.now); got != c.want {
			t.Errorf("%s: expiredAt = %v, want %v", c.name, got, c.want)
		}
	}

	before := rented(royalLion(), -1)
	if before.valid() || before.forSeat() != nil {
		t.Errorf("a back with an expiry before the epoch is kept: %+v", before.forSeat())
	}
	if far := rented(royalLion(), math.MaxInt64); !far.valid() || !reflect.DeepEqual(far.forSeat(), far) {
		t.Errorf("a term as far off as int64 goes is not kept: %+v", far.forSeat())
	}
}
