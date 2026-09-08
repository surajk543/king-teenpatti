package game

// The Table's live-state behaviour (livestate.go): one snapshot per mutation
// under a rising seq, failures that never refuse a move, the ErrStale fence,
// chat mirroring, Suspend, and RestoreTable — every re-arm rule, the money
// after a restore, and the Snapshot ⇄ RestoreTable ⇄ Snapshot identity under
// random play.

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// withLive hands the harness table a live store.
func withLive(store live.Store) harnessOption {
	return func(o *harnessOptions) { o.live = store }
}

// withLiveErrors installs the LiveErrors hook.
func withLiveErrors(fn func(op string, err error)) harnessOption {
	return func(o *harnessOptions) { o.liveErrors = fn }
}

// liveConfig is tableConfig with every timed feature on (sideshows, the
// blind auto-reveal, idle kicks), so a snapshot can carry all of them.
func liveConfig() TableConfig {
	cfg := tableConfig()
	cfg.MaxBlindMoves = 4
	cfg.MaxMissedTurns = 3
	cfg.SideshowTimeout = 6 * time.Second
	cfg.SideshowMinPlayers = 3
	cfg.ChatMaxHistory = 100
	cfg.ChatMaxLength = 140
	return cfg
}

// restoreHarness rebuilds snap as a harness of its own on clock. The two
// phases are run by hand (restoreTable, then resume) so the harness already
// knows its table when a clock fires on resume — the mirror ledger reads the
// seats through h.table.
func restoreHarness(t *testing.T, snap *Snapshot, clock *fakeClock, opts ...harnessOption) *harness {
	t.Helper()
	o := harnessOptions{}
	for _, opt := range opts {
		opt(&o)
	}
	h := &harness{t: t, rec: &recorder{}, clock: clock}
	if o.onKick != nil {
		h.rec.onKick = func(e KickEvent) { o.onKick(h, e) }
	}
	var ledger Ledger
	if o.ledger != nil {
		ledger = o.ledger(h)
	} else {
		ledger = mirrorLedger(h)
	}
	table, err := restoreTable(snap, TableOptions{Ledger: ledger, Clock: clock, Listener: h.rec, Live: o.live, LiveErrors: o.liveErrors, Snapshots: o.sink})
	if err != nil {
		t.Fatalf("restoreTable: %v", err)
	}
	h.table = table
	if err := table.resume(); err != nil {
		t.Fatalf("resume: %v", err)
	}
	t.Cleanup(func() { _ = table.Destroy() })
	return h
}

// mustSnapshot is the live snapshot of the harness table.
func mustSnapshot(h *harness) *Snapshot {
	h.t.Helper()
	snap, err := h.table.Snapshot()
	if err != nil {
		h.t.Fatalf("snapshot: %v", err)
	}
	return snap
}

// roundTrip is what the store does to a snapshot: JSON out, JSON in.
func roundTrip(t *testing.T, snap *Snapshot) *Snapshot {
	t.Helper()
	data, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	var decoded Snapshot
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	return &decoded
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// ------------------------------------------------------------ saving

func TestEveryMutationSavesOneSnapshotWithARisingSeq(t *testing.T) {
	store := livetest.New()
	h := newHarness(t, liveConfig(), withLive(store))
	eq(t, len(store.Saves()), 0, "nothing saved before the first mutation")

	h.seat("a", tableStart) // addPlayer: state
	h.seat("b", tableStart) // addPlayer + maybeStart: two state events, one save
	eq(t, len(store.Saves()), 2, "one save per posted mutation")

	h.advance(6 * time.Second) // the start timer's closure: startHand
	eq(t, len(store.Saves()), 3, "the deal saved once")

	_ = h.view("a")
	if _, err := h.table.Seats(); err != nil {
		t.Fatal(err)
	}
	eq(t, len(store.Saves()), 3, "reads save nothing")

	player := h.turnUser()
	h.mustAct(player, ActionChaal, ActRequest{}) // bet: state twice (advanceTurn + bet), one save
	other := h.otherActive(player)
	h.mustAct(other, ActionSee, ActRequest{}) // off-turn see: state once
	if _, err := h.table.SetConnected(other, false, ""); err != nil {
		t.Fatal(err)
	}
	if err := h.table.SetChips("a", 123456); err != nil {
		t.Fatal(err)
	}
	saves := store.Saves()
	eq(t, len(saves), 7, "chaal, see, setConnected, setChips each saved once")
	for i, s := range saves {
		eq(t, s.Seq, int64(i+1), "seq strictly increasing from 1")
		eq(t, s.RoomID, "room-1", "roomId")
		eq(t, s.TTL, DefaultLiveTTL, "default TTL")
		var snap Snapshot
		if err := json.Unmarshal(s.Snapshot, &snap); err != nil {
			t.Fatalf("save %d does not parse: %v", i, err)
		}
		eq(t, snap.Seq, s.Seq, "the snapshot carries its own seq")
		eq(t, snap.RoomID, "room-1", "snapshot roomId")
		eq(t, snap.Config.MaxPlayers, 5, "config travels with the snapshot")
	}
	eq(t, h.table.LiveSeq(), int64(7), "LiveSeq is the last seq used")

	stored, ok := store.Stored("room-1")
	eq(t, ok, true, "the store holds the table")
	eq(t, stored.Seq, int64(7), "latest seq stored")
	var latest Snapshot
	if err := json.Unmarshal(stored.Snapshot, &latest); err != nil {
		t.Fatal(err)
	}
	eq(t, latest.State, TableBetting, "live hand")
	eq(t, latest.Hand != nil, true, "hand present")
	eq(t, latest.Version, int64(2), "boot + chaal committed")
	for _, s := range latest.Seats {
		if s == nil {
			continue
		}
		eq(t, len(s.Cards), 3, "cards are in the server-side snapshot")
		if s.UserID == "a" {
			eq(t, s.Chips, int64(123456), "setChips saved")
		}
	}
	for _, c := range latest.Hand.Contributions {
		eq(t, len(c.Cards), 3, "contribution cards saved")
	}
	if latest.Hand.TurnDeadline == nil {
		t.Fatal("the turn deadline is saved")
	}
	raw := string(stored.Snapshot)
	for _, forbidden := range []string{`"connected"`, `"socketId"`, `"turnToken"`} {
		if containsStr(raw, forbidden) {
			t.Fatalf("snapshot must not carry %s", forbidden)
		}
	}
}

func containsStr(s, sub string) bool { return len(sub) <= len(s) && indexOf(s, sub) >= 0 }

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func TestALiveSaveFailureNeverRefusesTheMoveAndRetriesOnTheNextPost(t *testing.T) {
	store := livetest.New()
	var mu sync.Mutex
	var ops []string
	h := newHarness(t, liveConfig(), withLive(store), withLiveErrors(func(op string, err error) {
		mu.Lock()
		ops = append(ops, op)
		mu.Unlock()
	}))
	store.Fail("save_table", errors.New("redis: connection refused"))

	h.seat("a", tableStart)
	h.seat("b", tableStart)
	eq(t, h.state(), TableStarting, "the mutations stood")
	eq(t, len(store.Saves()), 0, "nothing landed")
	persist := h.rec.all("persistError")
	eq(t, len(persist), 2, "each failed save is reported")
	for _, p := range persist {
		eq(t, p.(PersistErrorEvent).Reason, PersistReasonLiveSave, "reason live_save")
	}
	mu.Lock()
	eq(t, len(ops), 2, "each failure counted")
	eq(t, ops[0], LiveOpSaveTable, "op")
	mu.Unlock()
	eq(t, h.table.Fenced(), false, "an ordinary failure is not a fence")

	// The table stays dirty; the next post of any kind retries — under a
	// fresh seq (every attempt takes one, so the durable writer's
	// version guard stays monotonic).
	store.Fail("save_table", nil)
	_ = h.view("a")
	saves := store.Saves()
	eq(t, len(saves), 1, "retried on the next post")
	eq(t, saves[0].Seq, int64(3), "attempts 1 and 2 failed, 3 landed")
	eq(t, h.table.LiveSeq(), int64(3), "LiveSeq follows")
}

func TestAStaleSaveFencesTheTable(t *testing.T) {
	store := livetest.New()
	h := newHarness(t, liveConfig(), withLive(store))
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	h.advance(6 * time.Second)
	eq(t, len(store.Saves()), 3, "three saves so far")

	// Another process has written seq 3 (or more) for this table.
	player := h.turnUser()
	other := h.otherActive(player)
	store.StaleSaves = true
	res, err := h.act(player, ActionChaal, ActRequest{})
	if err != nil {
		t.Fatalf("the move that trips the fence still stands: %v", err)
	}
	eq(t, res.Action, "chaal", "acked")

	errs := h.rec.all("error")
	eq(t, len(errs), 1, "one error event")
	var fenced *FencedError
	if !errors.As(errs[0].(error), &fenced) {
		t.Fatalf("error is %T, want *FencedError", errs[0])
	}
	eq(t, errors.Is(errs[0].(error), live.ErrStale), true, "unwraps to live.ErrStale")
	eq(t, fenced.RoomID, "room-1", "names the room")
	eq(t, fenced.Seq, int64(4), "the refused seq")
	eq(t, h.table.Fenced(), true, "fenced")
	eq(t, h.clock.Pending(), 0, "every clock stopped")

	// Every post but Destroy is refused with table_destroyed.
	_, err = h.act(other, ActionSee, ActRequest{})
	eq(t, CodeOf(err, ""), CodeTableDestroyed, "moves refused")
	_, err = h.table.SerializeFor("a")
	eq(t, errors.Is(err, ErrTableDestroyed), true, "reads refused")
	_, err = h.table.AddPlayer(NewPlayer{UserID: "c", DisplayName: "c", Chips: tableStart})
	eq(t, CodeOf(err, ""), CodeTableDestroyed, "joins refused")
	eq(t, h.table.Settled() != nil, true, "even Settled")

	// Destroy goes through, settles nothing and leaves the owner's copy alone.
	if err := h.table.Destroy(); err != nil {
		t.Fatalf("destroy: %v", err)
	}
	eq(t, h.settledCount(), 0, "the hand is the owner's to settle")
	eq(t, len(h.rec.all("handEnded")), 0, "no handEnded")
	eq(t, len(store.CallsOf("delete_table")), 0, "the store's snapshot is not deleted")
	eq(t, len(store.CallsOf("delete_chat")), 0, "nor its chat")
	stored, ok := store.Stored("room-1")
	eq(t, ok, true, "still stored")
	eq(t, stored.Seq, int64(3), "at the seq before the fence")
	eq(t, h.table.Destroyed(), true, "destroyed")
}

func TestChatIsMirroredToTheLiveStore(t *testing.T) {
	store := livetest.New()
	h := newHarness(t, liveConfig(), withLive(store))
	h.seatNamed("a", "Alice", tableStart)
	eq(t, len(store.Chat("room-1")), 1, "the join line is mirrored")

	msg, err := h.table.PostChat("a", "hello  there")
	if err != nil {
		t.Fatal(err)
	}
	lines := store.Chat("room-1")
	eq(t, len(lines), 2, "player line mirrored")
	var stored ChatMessage
	if err := json.Unmarshal(lines[1], &stored); err != nil {
		t.Fatal(err)
	}
	eq(t, mustJSON(t, stored), mustJSON(t, *msg), "the stored line is the emitted message")
	eq(t, stored.Text, "hello there", "sanitised before mirroring")
	for _, call := range store.CallsOf("append_chat") {
		eq(t, call, "append_chat:room-1:100", "capped at ChatMaxHistory")
	}

	if m, err := h.table.PostChat("a", "   "); err != nil || m != nil {
		t.Fatalf("empty line: %v %v", m, err)
	}
	eq(t, len(store.Chat("room-1")), 2, "nothing mirrored for an empty line")

	h.remove("a", LeaveReasonLeft)
	eq(t, len(store.Chat("room-1")), 3, "the leave line is mirrored")

	// A mirror failure is reported and counted, never surfaced to the poster.
	h.seat("b", tableStart)
	store.Fail("append_chat", errors.New("redis down"))
	if _, err := h.table.PostChat("b", "still works"); err != nil {
		t.Fatalf("post: %v", err)
	}
	found := false
	for _, p := range h.rec.all("persistError") {
		if p.(PersistErrorEvent).Reason == PersistReasonLiveChat {
			found = true
		}
	}
	eq(t, found, true, "live_chat reported")
	history, _ := h.table.ChatHistory()
	eq(t, history[len(history)-1].Text, "still works", "the room log has it regardless")
}

func TestDestroyDeletesTheLiveCopy(t *testing.T) {
	store := livetest.New()
	h := newHarness(t, liveConfig(), withLive(store))
	h.seat("a", tableStart)
	if _, err := h.table.PostChat("a", "bye"); err != nil {
		t.Fatal(err)
	}
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	eq(t, len(store.CallsOf("delete_table")), 1, "DeleteTable once")
	eq(t, len(store.CallsOf("delete_chat")), 1, "DeleteChat once")
	_, ok := store.Stored("room-1")
	eq(t, ok, false, "gone from the store")
	eq(t, len(store.Chat("room-1")), 0, "chat gone")
}

func TestSuspendSavesAFinalSnapshotAndEndsNothing(t *testing.T) {
	store := livetest.New()
	bk := newBank()
	h := newHarness(t, settleConfig(), withLedger(bankLedger(bk, settleStart)), withLive(store))
	h.bankSeat(bk, "a", settleStart)
	h.bankSeat(bk, "b", settleStart)
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	before := len(store.Saves())

	if err := h.table.Suspend(); err != nil {
		t.Fatalf("suspend: %v", err)
	}
	saves := store.Saves()
	eq(t, len(saves), before+1, "one final save")
	eq(t, saves[len(saves)-1].Seq, h.table.LiveSeq(), "at the table's seq")
	var snap Snapshot
	if err := json.Unmarshal(saves[len(saves)-1].Snapshot, &snap); err != nil {
		t.Fatal(err)
	}
	eq(t, snap.Hand != nil, true, "the hand is still live in the store")
	eq(t, snap.State, TableBetting, "betting")
	eq(t, len(store.CallsOf("delete_table")), 0, "not deleted")
	eq(t, h.settledCount(), 0, "no settlement")
	eq(t, len(h.rec.all("handEnded")), 0, "no handEnded")
	eq(t, h.clock.Pending(), 0, "clocks stopped")
	eq(t, h.table.Destroyed(), true, "posts refused from here on")
	_, err := h.act("a", ActionPack, ActRequest{})
	eq(t, errors.Is(err, ErrTableDestroyed), true, "refused")
	eq(t, bk.total(), 2*settleStart, "the bank has not moved")

	// Without a store a suspend is a destroy: the pot is settled.
	h2 := newHarness(t, settleConfig(), withLedger(bankLedger(newBank(), settleStart)))
	h2.seat("a", settleStart)
	h2.seat("b", settleStart)
	h2.advance(6 * time.Second)
	if err := h2.table.Suspend(); err != nil {
		t.Fatal(err)
	}
	eq(t, h2.settledCount(), 1, "settled as all_left")
	eq(t, h2.lastHandEnded().Reason, WinAllLeft, "all_left")
}

// ------------------------------------------------------------ restore

func TestRestoreMidHandWithTheDeadlineAheadKeepsTheTurnAndItsClock(t *testing.T) {
	h := newHarness(t, liveConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.advance(10 * time.Second) // 15 s of the next player's clock left
	player := h.turnUser()
	deadline := *h.view(player).Turn.Deadline

	snap := mustSnapshot(h)
	r := restoreHarness(t, roundTrip(t, snap), h.clock)

	eq(t, r.turnUser(), player, "the same player is on turn")
	eq(t, *r.view(player).Turn.Deadline, deadline, "with the same deadline")
	eq(t, len(r.rec.all("action")), 0, "nothing fired on restore")
	eq(t, r.state(), TableBetting, "betting")
	eq(t, mustJSON(t, mustSnapshot(r)), mustJSON(t, snap), "snapshot round trip")
	for _, s := range mustSeats(t, r.table) {
		eq(t, s.Connected, false, "every restored seat is disconnected")
		eq(t, s.SocketID, "", "and has no socket")
	}

	// The clock is armed for exactly what was left.
	h.advance(14 * time.Second)
	eq(t, len(r.rec.all("action")), 0, "not yet")
	h.advance(1 * time.Second)
	acts := r.rec.all("action")
	eq(t, len(acts), 1, "the timeout fired at the original deadline")
	last := acts[0].(ActionEvent)
	eq(t, last.Action, ActionPack, "pack")
	eq(t, last.Reason, PackReasonTimeout, "timeout")
	eq(t, last.UserID, player, "of the player on turn")
	eq(t, r.mustSeat(player).MissedTurns, 1, "missedTurns counted")
	eq(t, r.turnUser() != player, true, "turn advanced")
	// The original table, on the same clock, did exactly the same.
	eq(t, h.mustSeat(player).MissedTurns, 1, "original agrees")
}

func mustSeats(t *testing.T, table *Table) []SeatInfo {
	t.Helper()
	seats, err := table.Seats()
	if err != nil {
		t.Fatal(err)
	}
	return seats
}

func TestRestoreWithTheDeadlinePastTimesTheTurnOutAtOnce(t *testing.T) {
	h := newHarness(t, liveConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)
	player := h.turnUser()
	snap := mustSnapshot(h)

	// The process was down for 30 s: the deadline is 5 s in the past.
	later := newFakeClock(h.clock.Now().Add(30 * time.Second))
	r := restoreHarness(t, roundTrip(t, snap), later)

	acts := r.rec.all("action")
	eq(t, len(acts), 1, "one action on restore")
	pack := acts[0].(ActionEvent)
	eq(t, pack.Action, ActionPack, "pack")
	eq(t, pack.Reason, PackReasonTimeout, "timeout")
	eq(t, pack.UserID, player, "the player whose clock ran out")
	eq(t, r.mustSeat(player).MissedTurns, 1, "missedTurns++")
	eq(t, r.mustSeat(player).Status, SeatPacked, "packed")
	eq(t, r.hasHand(), true, "two players still in")
	next := r.turnUser()
	eq(t, next != player, true, "the turn moved on")
	eq(t, *r.view(next).Turn.Deadline, Millis(later.Now().Add(25*time.Second)), "a full clock from the restore instant")
	eq(t, len(r.rec.all("turn")), 1, "turn event for the next player")
	eq(t, len(r.rec.all("kick")), 0, "one missed turn is no kick")

	// Third missed turn in a row → the ordinary idle kick.
	tired := roundTrip(t, snap)
	for _, s := range tired.Seats {
		if s != nil && s.UserID == player {
			s.MissedTurns = 2
		}
	}
	r2 := restoreHarness(t, tired, newFakeClock(h.clock.Now().Add(30*time.Second)), withKickHandler())
	kicks := r2.kickEvents()
	eq(t, len(kicks), 1, "kicked")
	eq(t, kicks[0].UserID, player, "the idle player")
	eq(t, kicks[0].Reason, KickReasonIdle, "idle")
	eq(t, kicks[0].Message, "Left the table after 3 missed turns", "message")
	r2.waitKicks()
	if r2.seatInfo(player) != nil {
		t.Fatal("the kick handler removed the seat")
	}
}

func TestRestoreWithAPendingSideshow(t *testing.T) {
	h := newHarness(t, liveConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)
	for _, id := range []string{"a", "b", "c"} {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	asker := h.turnUser()
	res := h.mustAct(asker, ActionSideshow, ActRequest{})
	asked := res.ToUserID
	h.advance(2 * time.Second) // 4 s left on the request
	snap := mustSnapshot(h)
	eq(t, snap.Hand.Sideshow != nil, true, "the request is in the snapshot")
	expiresAt := snap.Hand.Sideshow.ExpiresAt

	// (1) Restored with time left: the request stands and can be answered.
	r := restoreHarness(t, roundTrip(t, snap), h.clock)
	view := r.view(asker)
	if view.Sideshow == nil {
		t.Fatal("the pending sideshow survives the restore")
	}
	eq(t, view.Sideshow.ToUserID, asked, "same target")
	eq(t, view.Sideshow.ExpiresAt, expiresAt, "same expiry")
	eq(t, len(r.rec.all("sideshowResolved")), 0, "unresolved")
	eq(t, mustJSON(t, mustSnapshot(r)), mustJSON(t, snap), "snapshot round trip")
	out := r.mustRespond(asked, false)
	eq(t, out.Accepted, false, "declined")
	eq(t, r.turnUser(), asker, "the asker has the turn back")
	if r.view(asker).Sideshow != nil {
		t.Fatal("request cleared")
	}
	_, err := r.act(asker, ActionSideshow, ActRequest{})
	eq(t, CodeOf(err, ""), CodeAlreadyAsked, "one ask per turn survives the restore")

	// (2) Restored after it expired: it lapses, the asker's clock restarts.
	later := newFakeClock(h.clock.Now().Add(10 * time.Second))
	r2 := restoreHarness(t, roundTrip(t, snap), later)
	resolved := r2.rec.all("sideshowResolved")
	eq(t, len(resolved), 1, "lapsed on restore")
	ev := resolved[0].(SideshowResolvedEvent)
	eq(t, ev.Accepted, false, "not accepted")
	eq(t, ev.Reason, SideshowTimeout, "timeout")
	eq(t, ev.FromUserID, asker, "asker")
	eq(t, r2.turnUser(), asker, "asker still on turn")
	eq(t, *r2.view(asker).Turn.Deadline, Millis(later.Now().Add(25*time.Second)), "full clock from the restore instant")
	if r2.view(asker).Sideshow != nil {
		t.Fatal("request cleared")
	}
	eq(t, r2.hasHand(), true, "hand continues")
	eq(t, r2.mustSeat(asker).Status, SeatActive, "nobody packed")

	// (3) Restored with time left and then left to expire: the timer fires
	// at the original expiry.
	r3 := restoreHarness(t, roundTrip(t, snap), h.clock)
	h.advance(3 * time.Second)
	eq(t, len(r3.rec.all("sideshowResolved")), 0, "3 s left")
	h.advance(1 * time.Second)
	eq(t, len(r3.rec.all("sideshowResolved")), 1, "expired at the original instant")
}

func TestRestoreOfACountdown(t *testing.T) {
	var boots int
	countBoots := func(h *harness) Ledger {
		return &captureLedger{inner: mirrorLedger(h), onBoot: func(CollectBootRequest) { boots++ }}
	}
	h := newHarness(t, liveConfig())
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	h.advance(2 * time.Second) // 4 s of the 6 s countdown left
	snap := mustSnapshot(h)
	eq(t, snap.State, TableStarting, "starting")
	if snap.StartsAt == nil {
		t.Fatal("startsAt saved")
	}

	// (1) Time left: the countdown is armed for what remains.
	r := restoreHarness(t, roundTrip(t, snap), h.clock, withLedger(countBoots))
	eq(t, r.state(), TableStarting, "still starting")
	eq(t, *r.view("a").StartsAt, *snap.StartsAt, "same startsAt")
	eq(t, r.hasHand(), false, "not dealt yet")
	eq(t, mustJSON(t, mustSnapshot(r)), mustJSON(t, snap), "snapshot round trip")
	h.advance(3 * time.Second)
	eq(t, r.hasHand(), false, "1 s left")
	h.advance(1 * time.Second)
	eq(t, r.hasHand(), true, "dealt at the original startsAt")
	eq(t, boots, 1, "the boot went through the ledger")
	eq(t, r.handNo(), 1, "hand 1")

	// (2) The countdown ran out while the process was down: deal now.
	boots = 0
	r2 := restoreHarness(t, roundTrip(t, snap), newFakeClock(h.clock.Now().Add(time.Minute)), withLedger(countBoots))
	eq(t, r2.hasHand(), true, "dealt on restore")
	eq(t, boots, 1, "boot collected once")
	eq(t, len(r2.rec.all("handStarted")), 1, "handStarted emitted")
	eq(t, r2.mustSeat("a").Chips, tableStart-tableBoot, "boot debited")

	// (3) A refused boot on restore follows the ordinary refusal path.
	refuse := func(h *harness) Ledger {
		return &captureLedger{inner: mirrorLedger(h), boot: func(CollectBootRequest) (CollectBootResult, error) {
			return CollectBootResult{}, errors.New("db down")
		}}
	}
	r3 := restoreHarness(t, roundTrip(t, snap), newFakeClock(h.clock.Now().Add(time.Minute)), withLedger(refuse))
	eq(t, r3.hasHand(), false, "refused")
	eq(t, r3.state(), TableWaiting, "back to waiting")
	eq(t, len(r3.rec.all("persistError")), 1, "reported")
	eq(t, r3.clock.Pending(), 1, "retry armed")
}

func TestRestoredHandEndsWhenEveryoneLapsesAndMoneyIsConserved(t *testing.T) {
	bk := newBank()
	h := newHarness(t, settleConfig(), withLedger(bankLedger(bk, settleStart)))
	for _, id := range []string{"a", "b", "c"} {
		h.bankSeat(bk, id, settleStart)
	}
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionRaise, ActRequest{})
	pot := h.pot()
	snap := mustSnapshot(h)

	// The new process: a fresh bank (the database never saw the bookless
	// bets, so it holds the pre-hand balances) and every seat disconnected.
	bk2 := newBank()
	r := restoreHarness(t, roundTrip(t, snap), newFakeClock(h.clock.Now()), withLedger(bankLedger(bk2, settleStart)))
	for _, s := range mustSeats(t, r.table) {
		eq(t, s.Connected, false, "disconnected")
	}
	eq(t, r.pot(), pot, "pot restored")

	// Nobody comes back: the socket layer's grace timers remove them one by
	// one (reason disconnected), as after any drop.
	ids := r.occupiedIDs()
	r.remove(ids[0], LeaveReasonDisconnected)
	eq(t, r.hasHand(), true, "two left")
	r.remove(ids[1], LeaveReasonDisconnected)
	eq(t, r.hasHand(), false, "last standing ends the hand")
	ended := r.lastHandEnded()
	eq(t, ended.Reason, WinLastStanding, "last_standing")
	eq(t, *ended.WinnerID, ids[2], "the one who stayed")
	eq(t, ended.Pot, pot, "the whole pot")
	rec := r.lastSettled()
	assertConserved(t, rec)
	eq(t, bk2.total(), 3*settleStart, "the bank is conserved")
	r.remove(ids[2], LeaveReasonDisconnected)
	eq(t, r.table.IsEmpty(), true, "table empty")
	eq(t, r.clock.Pending(), 0, "no clock left")
}

func TestRestoreOfAWaitingTableArmsNothing(t *testing.T) {
	h := newHarness(t, liveConfig())
	h.seat("a", tableStart)
	snap := mustSnapshot(h)
	eq(t, snap.State, TableWaiting, "waiting")

	r := restoreHarness(t, roundTrip(t, snap), newFakeClock(h.clock.Now().Add(time.Hour)))
	eq(t, r.state(), TableWaiting, "waiting")
	eq(t, r.clock.Pending(), 0, "no clock")
	eq(t, len(r.rec.names()), 0, "no event")
	eq(t, mustJSON(t, mustSnapshot(r)), mustJSON(t, snap), "snapshot round trip")

	// A waiting table with enough funded seats can only be a boot refusal
	// whose retry timer died with the process: the countdown resumes.
	h.seat("b", tableStart)
	stuck := mustSnapshot(h)
	stuck.State = TableWaiting
	stuck.StartsAt = nil
	r2 := restoreHarness(t, stuck, newFakeClock(h.clock.Now()))
	eq(t, r2.state(), TableStarting, "countdown resumed")
	eq(t, r2.clock.Pending(), 1, "start timer armed")
}

func TestRestoreAnnouncesPendingKicksAgain(t *testing.T) {
	h := newHarness(t, liveConfig())
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	snap := mustSnapshot(h)
	for _, s := range snap.Seats {
		if s != nil && s.UserID == "b" {
			s.Chips = 0
			s.KickPending = true
		}
	}
	r := restoreHarness(t, snap, newFakeClock(h.clock.Now()), withKickHandler())
	kicks := r.kickEvents()
	eq(t, len(kicks), 1, "the lost kick is announced again")
	eq(t, kicks[0].UserID, "b", "for the unfunded seat")
	eq(t, kicks[0].Reason, KickReasonInsufficientChips, "insufficient_chips")
	r.waitKicks()
	if r.seatInfo("b") != nil {
		t.Fatal("removed")
	}
}

func TestRestoreClaimsTheTableInTheStoreWithTheNextSeq(t *testing.T) {
	h := newHarness(t, liveConfig())
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	h.advance(6 * time.Second)
	snap := mustSnapshot(h)
	snap.Seq = 7
	store := livetest.New()
	store.Put(snap.RoomID, 7, []byte(mustJSON(t, snap)))

	r := restoreHarness(t, roundTrip(t, snap), h.clock, withLive(store))
	saves := store.Saves()
	eq(t, len(saves), 1, "one save on restore")
	eq(t, saves[0].Seq, int64(8), "seq + 1 claims the table")
	eq(t, r.table.LiveSeq(), int64(8), "LiveSeq")
	var again Snapshot
	if err := json.Unmarshal(saves[0].Snapshot, &again); err != nil {
		t.Fatal(err)
	}
	eq(t, again.Hand.ID, snap.Hand.ID, "same hand")
	// The old owner's next save (seq 8 too) is now stale.
	eq(t, errors.Is(store.SaveTable(t.Context(), snap.RoomID, 8, []byte("{}"), time.Hour), live.ErrStale), true, "old owner fenced")
}

func TestRestoreRefusesSnapshotsItCannotRebuild(t *testing.T) {
	h := newHarness(t, liveConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)
	base := mustSnapshot(h)
	opts := TableOptions{Clock: h.clock}

	cases := map[string]func(s *Snapshot){
		"no config":             func(s *Snapshot) { s.Config.MaxPlayers = 0 },
		"no boot":               func(s *Snapshot) { s.Config.BootAmount = 0 },
		"seat index mismatch":   func(s *Snapshot) { s.Seats[0].SeatIndex = 3 },
		"seat without user":     func(s *Snapshot) { s.Seats[0].UserID = "" },
		"duplicate user":        func(s *Snapshot) { s.Seats[1].UserID = s.Seats[0].UserID },
		"bad card":              func(s *Snapshot) { s.Seats[0].Cards[0] = "Zz" },
		"bad seat status":       func(s *Snapshot) { s.Seats[0].Status = "dancing" },
		"bad state":             func(s *Snapshot) { s.State = "limbo" },
		"turn at an empty seat": func(s *Snapshot) { s.Hand.TurnSeat = 4 },
		"hand without id":       func(s *Snapshot) { s.Hand.ID = "" },
		"contribution card":     func(s *Snapshot) { s.Hand.Contributions[0].Cards = []string{"As", "K"} },
		"sideshow asker mismatch": func(s *Snapshot) {
			s.Hand.Sideshow = &SnapshotSideshow{FromUserID: "ghost", FromSeat: 0, ToUserID: s.Seats[1].UserID, ToSeat: 1}
		},
		"too many seats": func(s *Snapshot) { s.Seats = append(s.Seats, nil) },
		"no room id":     func(s *Snapshot) { s.RoomID = "" },
	}
	for name, mutate := range cases {
		snap := roundTrip(t, base)
		mutate(snap)
		table, err := RestoreTable(snap, opts)
		if err == nil || table != nil {
			t.Fatalf("%s: restored a bad snapshot", name)
		}
	}
	if _, err := RestoreTable(nil, opts); err == nil {
		t.Fatal("nil snapshot restored")
	}
	// The unmodified snapshot restores fine (the cases above were the fault).
	table, err := RestoreTable(roundTrip(t, base), opts)
	if err != nil {
		t.Fatal(err)
	}
	_ = table.Destroy()
}

// ------------------------------------------------------------ property

// normaliseView blanks the one field a restore cannot preserve: a restored
// seat has no socket, so it is disconnected until the player is back.
func normaliseView(v *TableView) *TableView {
	for i := range v.Seats {
		v.Seats[i].Connected = false
	}
	return v
}

// assertRoundTrip checks Snapshot → JSON → RestoreTable → Snapshot is the
// identity and that every viewer (seated or not) sees the same TableView on
// both tables. The restored copy shares the original's clock and is
// destroyed at once.
func assertRoundTrip(t *testing.T, h *harness, step int) {
	t.Helper()
	h.waitKicks()
	snap := mustSnapshot(h)
	encoded := mustJSON(t, snap)
	decoded := roundTrip(t, snap)
	r, err := RestoreTable(decoded, TableOptions{Clock: h.clock, Ledger: NewMemoryLedger(MemoryLedgerHooks{})})
	if err != nil {
		t.Fatalf("step %d: restore: %v\n%s", step, err, encoded)
	}
	defer func() { _ = r.Destroy() }()
	again, err := r.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if got := mustJSON(t, again); got != encoded {
		t.Fatalf("step %d: snapshot changed across the round trip\n was: %s\n now: %s", step, encoded, got)
	}
	viewers := append(h.occupiedIDs(), "stranger")
	for _, id := range viewers {
		want := mustJSON(t, normaliseView(h.view(id)))
		view, err := r.SerializeFor(id)
		if err != nil {
			t.Fatal(err)
		}
		if got := mustJSON(t, normaliseView(view)); got != want {
			t.Fatalf("step %d: view for %s differs\n want: %s\n  got: %s", step, id, want, got)
		}
	}
}

func TestSnapshotRoundTripIsLossless(t *testing.T) {
	for seed := int64(1); seed <= 8; seed++ {
		t.Run(fmt.Sprintf("seed=%d", seed), func(t *testing.T) {
			rng := rand.New(rand.NewSource(seed))
			cfg := TableConfig{
				Category:           Category([]string{"seen", "blind"}[rng.Intn(2)]),
				BootAmount:         100,
				MaxPlayers:         5,
				MinPlayers:         2,
				TurnTimeout:        25 * time.Second,
				MaxBetRounds:       []int{0, 3, 7}[rng.Intn(3)],
				PotLimitMultiplier: []int64{0, 4, 1024}[rng.Intn(3)],
				MaxRaiseSteps:      []int{0, 2, 8}[rng.Intn(3)],
				MaxPot:             []int64{0, 20000}[rng.Intn(2)],
				MaxBlindMoves:      4,
				MaxMissedTurns:     3,
				SideshowTimeout:    6 * time.Second,
				SideshowMinPlayers: 3,
				NextHandDelay:      4 * time.Second,
				ChatMaxHistory:     100,
				ChatMaxLength:      140,
			}
			h := newHarness(t, cfg, withKickHandler())
			const start int64 = 20000
			ids := []string{"p1", "p2", "p3", "p4", "p5"}
			for _, id := range ids[:4] {
				h.seat(id, start)
			}
			checked := 0
			for step := 0; step < 300; step++ {
				// A kick's removal runs in its own goroutine; let it land before
				// the step reads the table (it may have ended the hand).
				h.waitKicks()
				if step%5 == 0 {
					assertRoundTrip(t, h, step)
					checked++
				}
				roll := rng.Intn(100)
				switch {
				case roll < 6:
					for _, id := range ids {
						if h.seatInfo(id) == nil && !h.table.IsFull() {
							h.seat(id, start)
							break
						}
					}
				case roll < 10:
					occ := h.occupiedIDs()
					if len(occ) > 0 {
						h.remove(occ[rng.Intn(len(occ))], LeaveReasonLeft)
					}
				case roll < 14:
					occ := h.occupiedIDs()
					if len(occ) > 0 {
						_, _ = h.table.SetConnected(occ[rng.Intn(len(occ))], rng.Intn(2) == 0, "")
					}
				case roll < 22:
					h.advance(time.Duration(rng.Intn(30)) * time.Second)
				default:
					if !h.hasHand() {
						h.advance(cfg.NextHandDelay)
						continue
					}
					player := h.turnUser()
					opts := h.turnOptions(player)
					move := rng.Intn(100)
					var err error
					switch {
					case move < 25 && opts.CanSee:
						_, err = h.act(player, ActionSee, ActRequest{})
					case move < 30:
						if right := h.rightOf(player); right != "" {
							_, _ = h.act(right, ActionSee, ActRequest{})
						}
					case move < 45 && opts.CanSideshow:
						if _, err = h.act(player, ActionSideshow, ActRequest{}); err == nil {
							to := h.view(player).Sideshow.ToUserID
							switch rng.Intn(4) {
							case 0:
								_, err = h.respond(to, true)
							case 1:
								_, err = h.respond(to, false)
							case 2:
								h.advance(7 * time.Second)
							default:
								h.advance(2 * time.Second) // leave it pending for the checkpoint
							}
						}
					case move < 50 && opts.Show != nil:
						_, err = h.act(player, ActionShow, ActRequest{})
					case move < 57:
						_, err = h.act(player, ActionPack, ActRequest{})
					case move < 64:
						h.advance(cfg.TurnTimeout)
					case len(opts.RaiseSteps) > 0:
						rung := opts.RaiseSteps[rng.Intn(len(opts.RaiseSteps))]
						action := ActionChaal
						if rung >= opts.RaiseSteps[0]*2 && rng.Intn(2) == 0 {
							action = ActionRaise
						}
						_, err = h.act(player, action, amt(rung))
					default:
						_, err = h.act(player, ActionPack, ActRequest{})
					}
					if err != nil {
						t.Fatalf("step %d: %v", step, err)
					}
				}
			}
			assertRoundTrip(t, h, 300)
			if h.handNo() < 3 {
				t.Fatalf("only %d hands played", h.handNo())
			}
			t.Logf("%s table: %d hands, %d checkpoints, %d sideshows, %d kicks", cfg.Category, h.handNo(), checked, len(h.sideshowRequested()), len(h.kickEvents()))
		})
	}
}

// ------------------------------------------------------------ durable sink

// sinkRecorder is a SnapshotSink that remembers what it was handed.
type sinkRecorder struct {
	mu      sync.Mutex
	dirty   []sinkMark
	deleted []string
}

type sinkMark struct {
	roomID, handID string
	seq            int64
	snapshot       []byte
}

func (s *sinkRecorder) MarkDirty(roomID string, seq int64, handID string, snapshot []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dirty = append(s.dirty, sinkMark{roomID: roomID, handID: handID, seq: seq, snapshot: append([]byte(nil), snapshot...)})
}

func (s *sinkRecorder) MarkDeleted(roomID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.deleted = append(s.deleted, roomID)
}

func (s *sinkRecorder) marks() []sinkMark {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]sinkMark(nil), s.dirty...)
}

func withSink(sink SnapshotSink) harnessOption {
	return func(o *harnessOptions) { o.sink = sink }
}

func TestEverySaveIsAlsoHandedToTheDurableSinkWithTheSameBytes(t *testing.T) {
	store := livetest.New()
	sink := &sinkRecorder{}
	h := newHarness(t, liveConfig(), withLive(store), withSink(sink))
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})

	saves := store.Saves()
	marks := sink.marks()
	eq(t, len(marks), len(saves), "one MarkDirty per save")
	for i := range saves {
		eq(t, marks[i].roomID, saves[i].RoomID, "room")
		eq(t, marks[i].seq, saves[i].Seq, "seq")
		eq(t, string(marks[i].snapshot), string(saves[i].Snapshot), "the same bytes, serialised once")
	}
	eq(t, marks[0].handID, "", "no hand before the deal")
	eq(t, marks[len(marks)-1].handID, h.lastHandStarted().HandID, "hand id while a hand is live")

	// The sink is fed even while the live store is down — that is what it
	// is for — under a fresh seq each time.
	store.Fail("save_table", errors.New("redis down"))
	before := len(sink.marks())
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	marks = sink.marks()
	eq(t, len(marks), before+1, "marked dirty despite the live failure")
	eq(t, marks[len(marks)-1].seq > saves[len(saves)-1].Seq, true, "with a higher seq")
	store.Fail("save_table", nil)

	// A fenced table hands the sink nothing more; Destroy of an owned table
	// marks the row deleted.
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	sink.mu.Lock()
	eq(t, len(sink.deleted), 1, "MarkDeleted on destroy")
	eq(t, sink.deleted[0], "room-1", "for the room")
	sink.mu.Unlock()

	// Without a live store the sink alone still receives every snapshot.
	sink2 := &sinkRecorder{}
	h2 := newHarness(t, liveConfig(), withSink(sink2))
	h2.seat("a", tableStart)
	eq(t, len(sink2.marks()), 1, "sink without a live store")
	eq(t, h2.table.LiveSeq(), int64(1), "seq advances")
}

func TestAFencedTableLeavesTheDurableRowToTheOwner(t *testing.T) {
	store := livetest.New()
	sink := &sinkRecorder{}
	h := newHarness(t, liveConfig(), withLive(store), withSink(sink))
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	before := len(sink.marks())
	store.StaleSaves = true
	h.advance(6 * time.Second) // the deal's save is stale → fenced
	eq(t, h.table.Fenced(), true, "fenced")
	eq(t, len(sink.marks()), before, "nothing marked for a snapshot we do not own")
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	sink.mu.Lock()
	eq(t, len(sink.deleted), 0, "the owner's row is not deleted")
	sink.mu.Unlock()
}

// ------------------------------------------------------------ chat invariant

func TestSnapshotNeverCarriesChat(t *testing.T) {
	// LIVE_STATE_PLAN.md invariant 5: chat never reaches PostgreSQL. The
	// snapshot is also the durable game_states row, so it must carry no
	// message — only the chat caps from the config.
	store := livetest.New()
	sink := &sinkRecorder{}
	h := newHarness(t, liveConfig(), withLive(store), withSink(sink))
	h.seatNamed("a", "Alice", tableStart)
	h.seatNamed("b", "Bob", tableStart)
	lines := []string{"secret-line-one", "secret-line-two", "secret-line-three"}
	for i, text := range lines {
		if _, err := h.table.PostChat([]string{"a", "b"}[i%2], text); err != nil {
			t.Fatal(err)
		}
	}
	history, _ := h.table.ChatHistory()
	eq(t, len(history), 5, "two join lines and three messages in the room log")

	snap := mustSnapshot(h)
	raw := mustJSON(t, snap)
	for _, text := range append(lines, "joined the table", `"messages"`, `"chat":`) {
		if containsStr(raw, text) {
			t.Fatalf("snapshot carries chat (%q): %s", text, raw)
		}
	}
	eq(t, snap.Config.ChatMaxHistory, 100, "only the caps travel")
	eq(t, snap.Config.ChatMaxLength, 140, "only the caps travel")
	// Nor does anything handed to the durable sink or the live store.
	for _, m := range sink.marks() {
		for _, text := range lines {
			if containsStr(string(m.snapshot), text) {
				t.Fatalf("durable sink received chat: %s", m.snapshot)
			}
		}
	}
	for _, s := range store.Saves() {
		for _, text := range lines {
			if containsStr(string(s.Snapshot), text) {
				t.Fatalf("live snapshot carries chat: %s", s.Snapshot)
			}
		}
	}
	eq(t, len(store.Chat("room-1")), 5, "chat is mirrored to the live store, and only there")

	// A table rebuilt from the snapshot alone starts with an empty room log
	// — never null on the wire.
	r := restoreHarness(t, roundTrip(t, snap), h.clock)
	restored, err := r.table.ChatHistory()
	if err != nil {
		t.Fatal(err)
	}
	if restored == nil {
		t.Fatal("chat history must be an empty slice, not nil")
	}
	eq(t, len(restored), 0, "empty room log after a restore from the snapshot")
	eq(t, mustJSON(t, restored), "[]", "serialises as []")
}

// ------------------------------------------------------------ reconcile

// staleSnapshot is a live hand whose snapshot predates the last bet: the
// ledger has the bet, the snapshot does not.
func staleSnapshot(t *testing.T) (*Snapshot, map[string]int64, string) {
	t.Helper()
	h := newHarness(t, liveConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)
	first := h.turnUser()
	h.mustAct(first, ActionChaal, ActRequest{})
	snap := mustSnapshot(h) // the durable copy: one chaal in
	// …but a second chaal landed in the ledger before the process died.
	second := h.turnUser()
	h.mustAct(second, ActionChaal, ActRequest{})
	ledger := map[string]int64{}
	for _, c := range mustSnapshot(h).Hand.Contributions {
		ledger[c.UserID] = c.Contributed
	}
	return snap, ledger, second
}

func TestReconcileWithLedgerAppliesTheMissingBet(t *testing.T) {
	snap, ledger, second := staleSnapshot(t)
	var potBefore int64 = snap.Hand.Pot
	var chipsBefore int64
	for _, s := range snap.Seats {
		if s != nil && s.UserID == second {
			chipsBefore = s.Chips
		}
	}
	if err := ReconcileWithLedger(snap, ledger); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	var total int64
	for _, v := range ledger {
		total += v
	}
	eq(t, snap.Hand.Pot, total, "pot == Σ ledger")
	eq(t, snap.Hand.Pot, potBefore+tableBoot, "the missing chaal is in the pot")
	for _, s := range snap.Seats {
		if s == nil {
			continue
		}
		eq(t, s.Contributed, ledger[s.UserID], "seat contributed == ledger")
		if s.UserID == second {
			eq(t, s.Chips, chipsBefore-tableBoot, "the missing debit is applied to the stack")
		}
	}
	for _, c := range snap.Hand.Contributions {
		eq(t, c.Contributed, ledger[c.UserID], "record contributed == ledger")
		eq(t, c.Persisted, ledger[c.UserID], "persisted == banked")
		eq(t, c.DidChaal, ledger[c.UserID] > tableBoot, "didChaal from the ledger")
	}

	// The reconciled snapshot restores and the hand continues from the
	// ledger's truth: the turn is where the stale snapshot had it (the second
	// chaal's turn advance is lost, so the same player bets again — money
	// is right, the extra move is harmless).
	r := restoreHarness(t, roundTrip(t, snap), newFakeClock(clockStart.Add(6*time.Second)))
	eq(t, r.pot(), total, "restored pot")
	eq(t, r.hasHand(), true, "hand continues")

	// Idempotent: reconciling an up-to-date snapshot changes nothing.
	fresh := mustSnapshot(r)
	before := mustJSON(t, fresh)
	current := map[string]int64{}
	for _, c := range fresh.Hand.Contributions {
		current[c.UserID] = c.Contributed
	}
	if err := ReconcileWithLedger(fresh, current); err != nil {
		t.Fatal(err)
	}
	eq(t, mustJSON(t, fresh), before, "no change")

	player := r.turnUser()
	r.mustAct(player, ActionChaal, ActRequest{})
	eq(t, r.pot(), total+tableBoot, "play goes on")
}

func TestReconcileWithLedgerRejectsASnapshotTooOldToTrust(t *testing.T) {
	snap, ledger, second := staleSnapshot(t)

	// (1) The ledger has more from a player the snapshot shows packed.
	packed := roundTrip(t, snap)
	for _, s := range packed.Seats {
		if s != nil && s.UserID == second {
			s.Status = SeatPacked
		}
	}
	for i := range packed.Hand.Contributions {
		if packed.Hand.Contributions[i].UserID == second {
			packed.Hand.Contributions[i].Status = SeatPacked
		}
	}
	if err := ReconcileWithLedger(packed, ledger); err == nil {
		t.Fatal("a bet from a packed player means the snapshot is too old")
	}

	// (2) The ledger has a player the snapshot does not know at all.
	absent := roundTrip(t, snap)
	extra := map[string]int64{}
	for k, v := range ledger {
		extra[k] = v
	}
	extra["ghost"] = tableBoot
	if err := ReconcileWithLedger(absent, extra); err == nil {
		t.Fatal("a contribution from an absent player means the snapshot is too old")
	}

	// (3) The ledger has LESS than the snapshot — impossible for a saved
	// snapshot; refuse rather than guess.
	short := roundTrip(t, snap)
	less := map[string]int64{}
	for k, v := range ledger {
		less[k] = v
	}
	less[second] -= tableBoot * 2
	if err := ReconcileWithLedger(short, less); err == nil {
		t.Fatal("a ledger behind the snapshot is refused")
	}

	// (4) A live hand with no ledger rows at all.
	if err := ReconcileWithLedger(roundTrip(t, snap), nil); err == nil {
		t.Fatal("no rows for a live hand is refused")
	}

	// (5) A player who left mid-hand keeps their recorded stake: fine when
	// equal, too old when the ledger has more.
	left := roundTrip(t, snap)
	var leaver string
	for _, s := range left.Seats {
		if s != nil && s.UserID != second {
			leaver = s.UserID
			break
		}
	}
	for i, s := range left.Seats {
		if s != nil && s.UserID == leaver {
			left.Seats[i] = nil
		}
	}
	for i := range left.Hand.Contributions {
		if left.Hand.Contributions[i].UserID == leaver {
			left.Hand.Contributions[i].Status = SeatPacked
			left.Hand.Contributions[i].LeftMidHand = true
		}
	}
	if left.Hand.TurnSeat >= 0 && left.Seats[left.Hand.TurnSeat] == nil {
		for i, s := range left.Seats {
			if s != nil && s.UserID == second {
				left.Hand.TurnSeat = i
			}
		}
	}
	if err := ReconcileWithLedger(roundTrip(t, left), ledger); err != nil {
		t.Fatalf("a leaver's recorded stake matching the ledger is fine: %v", err)
	}
	more := map[string]int64{}
	for k, v := range ledger {
		more[k] = v
	}
	more[leaver] += tableBoot
	if err := ReconcileWithLedger(roundTrip(t, left), more); err == nil {
		t.Fatal("a leaver who bet after the snapshot means it is too old")
	}

	// A snapshot between hands has nothing to reconcile.
	idle := roundTrip(t, snap)
	idle.Hand = nil
	if err := ReconcileWithLedger(idle, nil); err != nil {
		t.Fatal(err)
	}
}
