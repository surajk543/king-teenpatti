package socket

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/testclock"
	"github.com/surajk543/king-teenpatti/go-server/internal/livetest"
)

// The handler's side of the live-state store (LIVE_STATE_PLAN.md): presence,
// resume offers that outlive the process, and the seats a restart hands back.

// ----------------------------------------------------------------- presence

// A live socket is an online entry tagged with this instance; the entry goes
// when the socket does. A replaced socket's disconnect must not clear the
// new session's entry.
func TestPresenceFollowsTheLiveSocket(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Present")
	if inst, ok := st.live.Online(p.user.ID); !ok || inst != testInstance {
		t.Fatalf("online after connect: %q %v", inst, ok)
	}
	if n := st.live.Calls(livetest.OpSetOnline); n != 1 {
		t.Fatalf("set_online calls = %d, want 1", n)
	}
	expiry := st.live.OnlineExpiry(p.user.ID)
	if ttl := time.Until(expiry); ttl < PresenceTTL-5*time.Second || ttl > PresenceTTL {
		t.Fatalf("presence ttl %s, want ≈ %s", ttl, PresenceTTL)
	}

	// A second sign-in replaces the first; the account stays online.
	second := st.connect(p.token)
	if !p.c.WaitClosed(eventTimeout) {
		t.Fatal("the replaced socket was not closed")
	}
	time.Sleep(50 * time.Millisecond)
	if _, ok := st.live.Online(p.user.ID); !ok {
		t.Fatal("the replaced socket's disconnect cleared the new session's presence")
	}
	if n := st.live.Calls(livetest.OpSetOffline); n != 0 {
		t.Fatalf("set_offline called %d times during a replacement, want 0", n)
	}

	second.Close()
	eventually(t, eventTimeout, func() bool {
		_, ok := st.live.Online(p.user.ID)
		return !ok
	}, "presence cleared on disconnect")
	if n := st.live.Calls(livetest.OpSetOffline); n != 1 {
		t.Fatalf("set_offline calls = %d, want 1", n)
	}
}

// One heartbeat per handler refreshes every live account's entry every
// PresenceHeartbeat (its expiry moves forward by that much) and stops with
// Close.
func TestHeartbeatRefreshesEveryLiveAccount(t *testing.T) {
	clock := testclock.New(time.UnixMilli(1_700_000_000_000))
	st := newStackWithClock(t, nil, clock)
	a := st.player("A")
	b := st.player("B")
	gone := st.player("Gone")
	gone.c.Close()
	eventually(t, eventTimeout, func() bool {
		_, ok := st.live.Online(gone.user.ID)
		return !ok
	}, "gone offline")
	before := st.live.Calls(livetest.OpSetOnline)
	expiryA := st.live.OnlineExpiry(a.user.ID)

	clock.Advance(PresenceHeartbeat + time.Millisecond)
	if n := st.live.Calls(livetest.OpSetOnline) - before; n != 2 {
		t.Fatalf("heartbeat refreshed %d entries, want 2 (the two live accounts, not the closed one)", n)
	}
	// The beat fires at exactly +30 s on the fake clock, so the entry's expiry
	// moves forward by one heartbeat.
	if got := st.live.OnlineExpiry(a.user.ID).Sub(expiryA); got != PresenceHeartbeat {
		t.Fatalf("expiry advanced by %s, want %s", got, PresenceHeartbeat)
	}
	if _, ok := st.live.Online(b.user.ID); !ok {
		t.Fatal("b not online after the beat")
	}
	if _, ok := st.live.Online(gone.user.ID); ok {
		t.Fatal("a closed socket was revived by the heartbeat")
	}
	// Ninety seconds without a beat would expire the entry; the beat keeps it.
	before = st.live.Calls(livetest.OpSetOnline)
	clock.Advance(3*PresenceHeartbeat + time.Millisecond)
	if n := st.live.Calls(livetest.OpSetOnline) - before; n != 6 {
		t.Fatalf("three beats refreshed %d entries, want 6", n)
	}
	if _, ok := st.live.Online(a.user.ID); !ok {
		t.Fatal("presence lapsed despite the heartbeat")
	}

	// Close stops the beat; the next window refreshes nothing.
	st.h.Close()
	before = st.live.Calls(livetest.OpSetOnline)
	clock.Advance(2 * PresenceHeartbeat)
	if n := st.live.Calls(livetest.OpSetOnline) - before; n != 0 {
		t.Fatalf("heartbeat still running after Close: %d refreshes", n)
	}
	if clock.Pending() != 0 {
		t.Fatalf("%d timers still armed after Close", clock.Pending())
	}
}

// A store that is down never costs a player their sign-in: presence and the
// offer lookup fail quietly.
func TestStoreFailuresNeverBreakSignIn(t *testing.T) {
	st := newStack(t, nil)
	down := errors.New("dial tcp 127.0.0.1:6379: connection refused")
	st.live.Fail(livetest.OpSetOnline, down)
	st.live.Fail(livetest.OpTakeResumeOffer, down)
	st.live.Fail(livetest.OpSetOffline, down)
	p := st.player("Unlucky")
	ready, _ := p.c.Last(EvSessionReady)
	if has(ready, "resume") {
		t.Fatalf("resume offered while the store is down: %s", ready)
	}
	// Play works as before.
	st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": st.uniqueStake()})
	p.c.Close()
	time.Sleep(50 * time.Millisecond)
	if n := st.live.Calls(livetest.OpSetOffline); n != 1 {
		t.Fatalf("set_offline attempted %d times, want 1", n)
	}
}

// ------------------------------------------------------------ resume offers

// The offer a lapsed seat leaves behind lives in the store with
// RESUME_OFFER_MS as its ttl, and is taken from it once.
func TestLapsedSeatOfferIsKeptInTheStoreAndTakenOnce(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("blind")
	d.a.c.Close()
	time.Sleep(800 * time.Millisecond) // past the 400 ms grace

	offer, ok := st.live.Offer(d.a.user.ID)
	if !ok {
		t.Fatal("no offer in the store after the lapse")
	}
	if offer.RoomID != d.roomID || offer.Code != d.code || offer.Category != "blind" || offer.BootAmount != d.boot || offer.At == 0 {
		t.Fatalf("offer = %+v", offer)
	}
	if ttl := time.Until(st.live.OfferExpiry(d.a.user.ID)); ttl > st.cfg.Game.ResumeOffer || ttl < st.cfg.Game.ResumeOffer-5*time.Second {
		t.Fatalf("offer ttl %s, want ≈ RESUME_OFFER_MS (%s)", ttl, st.cfg.Game.ResumeOffer)
	}
	if n := st.live.Calls(livetest.OpPutResumeOffer); n != 1 {
		t.Fatalf("put_resume_offer calls = %d", n)
	}

	// Every unseated sign-in asks the store once (the two players' first
	// connections found nothing); this one takes the offer.
	takes := st.live.Calls(livetest.OpTakeResumeOffer)
	back := st.connect(d.a.token)
	ready, _ := back.Last(EvSessionReady)
	if str(ready, "resume.roomId") != d.roomID || str(ready, "resume.code") != d.code {
		t.Fatalf("session:ready.resume = %s", ready)
	}
	if _, still := st.live.Offer(d.a.user.ID); still {
		t.Fatal("the offer was not consumed")
	}
	if n := st.live.Calls(livetest.OpTakeResumeOffer) - takes; n != 1 {
		t.Fatalf("take_resume_offer calls = %d, want 1", n)
	}
	// Seated again (still inside the grace? no — a fresh join), the offer is
	// cleared for good on the next sign-in with a held seat.
	st.mustOK(back, EvRoomJoinCode, map[string]any{"code": d.code})
	back.Close()
	time.Sleep(50 * time.Millisecond)
	again := st.connect(d.a.token)
	if ready2, _ := again.Last(EvSessionReady); has(ready2, "resume") {
		t.Fatalf("held seat AND an offer: %s", ready2)
	}
	if n := st.live.Calls(livetest.OpDeleteResumeOffer); n != 1 {
		t.Fatalf("delete_resume_offer calls = %d (a seated sign-in drops any stale offer)", n)
	}
}

// RESUME_OFFER_MS=0 disables offers: nothing is written to the store.
func TestZeroResumeOfferWritesNothing(t *testing.T) {
	st := newStack(t, func(cfg *config.Config) { cfg.Game.ResumeOffer = 0 })
	d := st.dealtTable("")
	d.a.c.Close()
	time.Sleep(800 * time.Millisecond)
	if n := st.live.Calls(livetest.OpPutResumeOffer); n != 0 {
		t.Fatalf("put_resume_offer called %d times with RESUME_OFFER_MS=0", n)
	}
	back := st.connect(d.a.token)
	if ready, _ := back.Last(EvSessionReady); has(ready, "resume") {
		t.Fatalf("offer with RESUME_OFFER_MS=0: %s", ready)
	}
}

// -------------------------------------------------------------- RestoreSeats

// seatedWithoutSockets is a table as Restore leaves it: two players seated
// by the RoomManager with no socket and a hand in progress.
func seatedWithoutSockets(t *testing.T, st *stack) (*game.Table, *player, *player) {
	t.Helper()
	a, atok := st.login("Restored-A")
	b, btok := st.login("Restored-B")
	table := st.rooms.CreateTable(game.CreateTableOptions{BootAmount: st.uniqueStake(), Category: "seen"})
	for _, u := range []*player{{user: a, token: atok}, {user: b, token: btok}} {
		if err := st.rooms.Join(table, u.user.Player(), ""); err != nil {
			t.Fatalf("join %s: %v", u.user.DisplayName, err)
		}
	}
	eventually(t, eventTimeout, func() bool { return table.HasHand() }, "hand dealt")
	return table, &player{user: a, token: atok}, &player{user: b, token: btok}
}

// After a restart every restored seat is held exactly like a dropped one: a
// sign-in inside the grace lands at the table with the live hand; nobody
// returning lets the seat lapse into a resume offer in the store, which the
// next session:ready carries.
func TestRestoreSeatsHoldsSeatsThenLapsesIntoOffers(t *testing.T) {
	st := newStack(t, nil)
	table, a, b := seatedWithoutSockets(t, st)
	roomID := table.ID()

	held := st.h.RestoreSeats([]RestoredSeat{{UserID: a.user.ID, RoomID: roomID}, {UserID: b.user.ID, RoomID: roomID}})
	if held != 2 {
		t.Fatalf("held %d seats, want 2", held)
	}
	if v := metricValue(st.metrics.RestoredSeatsTotal); v != 2 {
		t.Fatalf("restored_seats_total = %v", v)
	}
	for _, p := range []*player{a, b} {
		seat, err := table.FindSeat(p.user.ID)
		if err != nil || seat == nil || seat.Connected {
			t.Fatalf("%s seat after RestoreSeats: %+v %v (want held, disconnected)", p.user.DisplayName, seat, err)
		}
	}

	// A returns inside the grace: the ordinary held-seat path, no offer.
	a.c = st.connect(a.token)
	ready, _ := a.c.Last(EvSessionReady)
	if has(ready, "resume") {
		t.Fatalf("held seat must not come with an offer: %s", ready)
	}
	joined, err := a.c.Wait(EvRoomJoined, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(joined, "roomId") != roomID || str(joined, "state") != "betting" || str(joined, "you.status") != "active" || num(joined, "handNo") != 1 {
		t.Fatalf("restored snapshot: %s", joined)
	}
	if seat := seatOf(joined, a.user.ID); seat == nil || seat["connected"] != true {
		t.Fatalf("a's seat not reconnected: %s", joined)
	}
	if seat := seatOf(joined, b.user.ID); seat == nil || seat["connected"] != false {
		t.Fatalf("b's seat should still be held, disconnected: %s", joined)
	}
	if v := metricValue(st.metrics.ReconnectsTotal.WithLabelValues("seat_held")); v != 1 {
		t.Fatalf("reconnects_total{seat_held} = %v", v)
	}
	if _, ok := st.live.Online(a.user.ID); !ok {
		t.Fatal("a not online")
	}

	// B never comes back: the grace lapses, the seat is given up (read as a
	// pack with reason 'disconnected'), the offer lands in the store.
	if _, err := a.c.Wait(EvGameActionOut, func(p json.RawMessage) bool {
		return str(p, "userId") == b.user.ID && str(p, "reason") == "disconnected"
	}, 2*time.Second); err != nil {
		t.Fatalf("b's seat did not lapse: %v", err)
	}
	if st.rooms.GetTableForPlayer(b.user.ID) != nil {
		t.Fatal("b still seated after the lapse")
	}
	offer, ok := st.live.Offer(b.user.ID)
	if !ok || offer.RoomID != roomID {
		t.Fatalf("offer for b = %+v %v", offer, ok)
	}
	// The table survives with A alone (the hand ended last_standing).
	if st.rooms.GetTable(roomID) == nil {
		t.Fatal("table destroyed")
	}

	b.c = st.connect(b.token)
	ready, _ = b.c.Last(EvSessionReady)
	resume, _ := field(ready, "resume").(map[string]any)
	if resume == nil || resume["roomId"] != roomID || resume["code"] != table.Code() {
		t.Fatalf("b's session:ready.resume = %s", ready)
	}
	if v := metricValue(st.metrics.ReconnectsTotal.WithLabelValues("offer")); v != 1 {
		t.Fatalf("reconnects_total{offer} = %v", v)
	}
	rejoined := st.mustOK(b.c, EvRoomJoinCode, map[string]any{"code": table.Code()})
	if str(rejoined.Raw, "roomId") != roomID {
		t.Fatalf("rejoin: %s", rejoined.Raw)
	}
}

// Seats that cannot be held are skipped: an unknown table, a player the
// index does not place there, and an account whose own sign-in already
// restored its seat.
func TestRestoreSeatsSkipsWhatItCannotHold(t *testing.T) {
	st := newStack(t, nil)
	table, a, b := seatedWithoutSockets(t, st)
	roomID := table.ID()
	stranger, _ := st.login("Stranger")

	// A signs in before RestoreSeats runs (nothing held yet, but the seat is
	// indexed, so the connection restores it).
	a.c = st.connect(a.token)
	if _, err := a.c.Wait(EvRoomJoined, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}

	held := st.h.RestoreSeats([]RestoredSeat{
		{UserID: a.user.ID, RoomID: roomID},         // live socket → skipped
		{UserID: b.user.ID, RoomID: roomID},         // held
		{UserID: stranger.ID, RoomID: roomID},       // not seated there → skipped
		{UserID: b.user.ID, RoomID: "no-such-room"}, // unknown table → skipped
	})
	if held != 1 {
		t.Fatalf("held %d, want 1", held)
	}
	seat, err := table.FindSeat(a.user.ID)
	if err != nil || seat == nil || !seat.Connected {
		t.Fatalf("a's live seat was disturbed: %+v %v", seat, err)
	}
	st.h.mu.Lock()
	_, aHeld := st.h.pendingRemovals[a.user.ID]
	_, bHeld := st.h.pendingRemovals[b.user.ID]
	_, sHeld := st.h.pendingRemovals[stranger.ID]
	st.h.mu.Unlock()
	if aHeld || !bHeld || sHeld {
		t.Fatalf("grace timers a=%v b=%v stranger=%v, want only b", aHeld, bHeld, sHeld)
	}
	// A's seat survives well past the grace: no timer was armed for it.
	time.Sleep(600 * time.Millisecond)
	if st.rooms.GetTableForPlayer(a.user.ID) == nil {
		t.Fatal("a's seat was given up")
	}
	if st.rooms.GetTableForPlayer(b.user.ID) != nil {
		t.Fatal("b's held seat did not lapse")
	}
}
