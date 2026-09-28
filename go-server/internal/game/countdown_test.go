package game

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// The countdown before every deal (countdown.go; owner, 29 Sep 2026): a
// first deal is the 3-2-1 alone, a deal after a hand waits for the
// celebration and then the countdown, room:state says how long is left, and
// nothing can be played until the cards are out.

func TestStartDelayIsTheCountdownOrAShorterWindow(t *testing.T) {
	eq(t, StartDelay(6*time.Second), StartCountdown, "a 6 s window: the 3 s countdown")
	eq(t, StartDelay(StartCountdown), StartCountdown, "exactly the countdown")
	eq(t, StartDelay(1500*time.Millisecond), 1500*time.Millisecond, "a quicker table keeps its own delay")
	eq(t, StartDelay(0), time.Duration(0), "none")

	at := clockStart
	eq(t, StartsInMs(at.Add(2500*time.Millisecond), at), int64(2500), "time left")
	eq(t, StartsInMs(at, at), int64(0), "the deal is now")
	eq(t, StartsInMs(at, at.Add(time.Second)), int64(0), "never negative")
}

// wireKeys is the set of top-level keys a viewer's room:state carries.
func wireKeys(t *testing.T, v *TableView) map[string]json.RawMessage {
	t.Helper()
	var keys map[string]json.RawMessage
	if err := json.Unmarshal([]byte(mustJSON(t, v)), &keys); err != nil {
		t.Fatal(err)
	}
	return keys
}

func TestStartsInMsIsOnTheWireExactlyWhileTheTableCountsDown(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("a", tableStart)

	// Waiting: startsAt null, startsInMs absent — the snapshot every client
	// has always had.
	keys := wireKeys(t, h.view("a"))
	eq(t, string(keys["startsAt"]), "null", "waiting: startsAt null")
	if _, ok := keys["startsInMs"]; ok {
		t.Fatal("waiting: startsInMs must be absent, not null")
	}

	h.seat("b", tableStart)
	eq(t, h.state(), TableStarting, "the countdown")
	keys = wireKeys(t, h.view("a"))
	eq(t, string(keys["startsAt"]), jsonInt(Millis(h.clock.Now().Add(StartCountdown))), "startsAt")
	eq(t, string(keys["startsInMs"]), "3000", "3 s left")

	// Measured when each snapshot is serialised, not when the countdown began.
	h.advance(1200 * time.Millisecond)
	for _, viewer := range []string{"a", "b"} {
		v := h.view(viewer)
		eq(t, *v.StartsInMs, int64(1800), viewer+": 1.8 s left")
		eq(t, *v.StartsAt, Millis(h.clock.Now().Add(1800*time.Millisecond)), viewer+": the same deal")
	}

	// Dealt: both gone again.
	h.advance(1800 * time.Millisecond)
	eq(t, h.state(), TableBetting, "dealt")
	keys = wireKeys(t, h.view("a"))
	eq(t, string(keys["startsAt"]), "null", "betting: startsAt null")
	if _, ok := keys["startsInMs"]; ok {
		t.Fatal("betting: startsInMs must be absent")
	}
}

func TestASecondPlayerSittingDownGetsTheCountdownAndTheDealAtItsEnd(t *testing.T) {
	h := newHarness(t, tableConfig()) // NextHandDelay 6 s
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	eq(t, h.state(), TableStarting, "counting down")
	begun := h.clock.Now()

	// Nothing can be played before the cards are out.
	h.advance(StartCountdown - time.Millisecond)
	eq(t, h.hasHand(), false, "a millisecond before the end: no hand")
	for _, id := range []string{"a", "b"} {
		for _, action := range []Action{ActionChaal, ActionSee, ActionPack} {
			_, err := h.act(id, action, ActRequest{})
			codeIs(t, err, CodeNoHand)
		}
	}
	eq(t, len(h.rec.all("handStarted")), 0, "no deal yet")
	eq(t, *h.view("a").StartsInMs, int64(1), "1 ms left")

	h.advance(time.Millisecond)
	eq(t, h.hasHand(), true, "dealt the instant the countdown ends")
	eq(t, h.state(), TableBetting, "betting")
	started := h.rec.all("handStarted")
	eq(t, len(started), 1, "one deal")
	eq(t, h.clock.Now(), begun.Add(StartCountdown), "3 s after the second player sat down")
	// And now the table plays.
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
}

func TestAHandsEndWaitsForTheCelebrationThenCountsDown(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	h.advance(StartCountdown)
	eq(t, h.handNo(), 1, "hand 1")

	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	eq(t, h.hasHand(), false, "hand 1 over")
	ended := h.lastHandEnded()
	end := h.clock.Now()
	eq(t, ended.NextHandAt, Millis(end.Add(tableConfig().NextHandDelay)), "nextHandAt = end + NextHandDelay")

	// The countdown is armed at once, to the instant handEnded promised: the
	// app plays the celebration in its first 3 s and 3-2-1 in the last 3.
	eq(t, h.state(), TableStarting, "starting")
	v := h.view("a")
	eq(t, *v.StartsAt, ended.NextHandAt, "startsAt = nextHandAt")
	eq(t, *v.StartsInMs, tableConfig().NextHandDelay.Milliseconds(), "6 s left")

	h.advance(tableConfig().NextHandDelay - StartCountdown)
	eq(t, *h.view("a").StartsInMs, StartCountdown.Milliseconds(), "the countdown's own 3 s are left")
	h.advance(StartCountdown - time.Millisecond)
	eq(t, h.handNo(), 1, "not dealt a millisecond early")
	_, err := h.act("a", ActionChaal, ActRequest{})
	codeIs(t, err, CodeNoHand)
	h.advance(time.Millisecond)
	eq(t, h.handNo(), 2, "dealt at nextHandAt")
}

func TestACountdownCancelledByALeaveStopsAndOneStartedInsideTheWindowKeepsTheHold(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	h.advance(StartCountdown)
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	end := h.clock.Now()
	eq(t, h.state(), TableStarting, "the next countdown is running")

	// b walks away during the celebration: the countdown stops at once.
	h.advance(time.Second)
	h.remove("b", LeaveReasonLeft)
	eq(t, h.state(), TableWaiting, "cancelled")
	keys := wireKeys(t, h.view("a"))
	eq(t, string(keys["startsAt"]), "null", "startsAt cleared")
	if _, ok := keys["startsInMs"]; ok {
		t.Fatal("startsInMs cleared")
	}
	eq(t, h.clock.Pending(), 0, "no start timer left")

	// c sits down a second later, still inside the last hand's window: the
	// new countdown ends where the old one would have — the celebration the
	// players were promised is not cut short by a 3 s countdown over it.
	h.advance(time.Second)
	h.seat("c", tableStart)
	eq(t, h.state(), TableStarting, "counting down again")
	eq(t, *h.view("a").StartsAt, Millis(end.Add(tableConfig().NextHandDelay)), "held to the last hand's nextHandAt")
	h.advance(end.Add(tableConfig().NextHandDelay).Sub(h.clock.Now()) - time.Millisecond)
	eq(t, h.handNo(), 1, "not before the hold")
	h.advance(time.Millisecond)
	eq(t, h.handNo(), 2, "dealt at the hold")

	// Long after a hand, a countdown is the countdown alone.
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	h.advance(tableConfig().NextHandDelay)
	eq(t, h.handNo(), 3, "hand 3")
	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	h.remove("c", LeaveReasonLeft)
	eq(t, h.state(), TableWaiting, "one player left")
	h.advance(time.Minute)
	h.seat("d", tableStart)
	eq(t, *h.view("a").StartsInMs, StartCountdown.Milliseconds(), "a fresh table: 3 s")
}

func TestAMissileShowdownHoldsTheCountdownForTheReveal(t *testing.T) {
	h, ids, _ := missileTable(t, 3, true)
	firer := h.turnUser()
	h.mustAct(firer, ActionMissile, fire("countdown"))
	ended := h.lastHandEnded()
	extra := missileConfig().NextHandDelay + missileExtra
	eq(t, ended.NextHandAt, Millis(h.clock.Now().Add(extra)), "the missile's longer window")
	v := h.view(ids[0])
	eq(t, *v.StartsAt, ended.NextHandAt, "the countdown ends at nextHandAt")
	eq(t, *v.StartsInMs, extra.Milliseconds(), "time left includes the reveal")
	h.advance(extra - StartCountdown)
	eq(t, *h.view(ids[0]).StartsInMs, StartCountdown.Milliseconds(), "the 3-2-1 starts late, after the reveal")
	h.advance(StartCountdown)
	eq(t, h.handNo(), 2, "dealt at the end of it")
}

func TestARestartDuringTheCelebrationKeepsTheSameDeal(t *testing.T) {
	h := newHarness(t, liveConfig())
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	h.advance(StartCountdown)
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	deal := *h.view("a").StartsAt
	h.advance(2 * time.Second) // 4 s of the window left
	snap := mustSnapshot(h)

	r := restoreHarness(t, roundTrip(t, snap), h.clock)
	v := r.view("a")
	eq(t, *v.StartsAt, deal, "the same deal")
	eq(t, *v.StartsInMs, int64(4000), "and the time left to it, not a fresh countdown")
	h.advance(4*time.Second - time.Millisecond)
	eq(t, r.handNo(), 1, "not early")
	h.advance(time.Millisecond)
	eq(t, r.handNo(), 2, "dealt at the original instant")
}

func TestAQuickTableKeepsItsOwnShorterDelay(t *testing.T) {
	cfg := tableConfig()
	cfg.NextHandDelay = 1500 * time.Millisecond
	h := newHarness(t, cfg)
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	eq(t, *h.view("a").StartsInMs, int64(1500), "shorter than the countdown: its own")
	h.advance(1500 * time.Millisecond)
	eq(t, h.handNo(), 1, "dealt")
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	eq(t, *h.view("a").StartsInMs, int64(1500), "between hands too")
	if !strings.Contains(mustJSON(t, h.view("a")), `"startsInMs":1500`) {
		t.Fatal("startsInMs on the wire")
	}
}
