package bot

import (
	"context"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/interaction"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/state"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/strategy"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/table"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/timing"
	"github.com/surajk543/king-teenpatti/bot-play/internal/clock"
	"github.com/surajk543/king-teenpatti/bot-play/internal/config"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

type harness struct {
	t      *testing.T
	fs     *fakeServer
	clk    *clock.Fake
	bot    *Bot
	cancel context.CancelFunc
	done   chan struct{}
}

// start runs one bot against a fakeServer on a fake clock. advance moves the
// fake clock on in small steps while a test waits for the bot.
func start(t *testing.T, fs *fakeServer, tweak func(*config.Config)) *harness {
	t.Helper()
	clk := clock.NewFake(time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC))
	cfg := config.Default()
	cfg.Bots.Count = 1
	cfg.Interaction.EnableChat = false
	cfg.Session.MinDuration = 2 * time.Hour
	cfg.Session.MaxDuration = 3 * time.Hour
	cfg.Table.MinHands, cfg.Table.MaxHands = 3, 20
	if tweak != nil {
		tweak(&cfg)
	}
	finder := table.NewFinder(fs, cfg.Table.Categories, clk.Now)
	if err := finder.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	deps := Deps{
		API: fs, Dialer: fs, Finder: finder, Clock: clk,
		Delay:  timing.New(timing.Config{}),
		Budget: interaction.NewTableBudget(0, 0), Emoter: interaction.NoEmotes{},
		Fleet: NewFleet(), Config: cfg, Seed: 7,
		Log: testLogger(),
	}
	h := &harness{t: t, fs: fs, clk: clk, done: make(chan struct{})}
	h.bot = New(NewIdentity("botplay-", 0, 1, 0), deps)
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	go func() {
		defer close(h.done)
		h.bot.Run(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-h.done:
		case <-time.After(5 * time.Second):
			t.Error("the bot did not stop")
		}
	})
	return h
}

// testLogger discards the bot's log unless BOTTEST_LOG is set.
func testLogger() *slog.Logger {
	if os.Getenv("BOTTEST_LOG") != "" {
		return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	}
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func (h *harness) advance() { h.clk.Advance(100 * time.Millisecond) }

// nextSession waits for the bot's next connection, moving the fake clock on
// so its reconnect backoff can run out.
func (h *harness) nextSession() *fakeSession {
	h.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case s := <-h.fs.sessCh:
			return s
		case <-time.After(2 * time.Millisecond):
			h.advance()
		}
	}
	h.t.Fatal("the bot never connected")
	return nil
}

// waitState advances the clock until the bot is in want.
func (h *harness) waitState(want state.State) {
	h.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if h.bot.machine.Current() == want {
			return
		}
		h.advance()
		time.Sleep(2 * time.Millisecond)
	}
	h.t.Fatalf("state %s, want %s", h.bot.machine.Current(), want)
}

// seat takes the bot from connection to a seat at room r1.
func (h *harness) seat() *fakeSession {
	h.t.Helper()
	s := h.fs.nextSession()
	uid := "u-botplay-000001"
	s.push(protocol.EvSessionReady, protocol.SessionReady{User: protocol.User{ID: uid, Chips: 1_000_000}})
	join := s.expect(h.t, protocol.EvRoomQuickJoin, 5*time.Second, h.advance)
	join.reply <- roomAck("r1")
	st := seatedState(uid, "r1", 0, protocol.TableWaiting)
	s.push(protocol.EvRoomJoined, st)
	h.waitState(state.WaitingForHand)
	return s
}

func TestIdentitiesAreStableAndInTheBotNamespace(t *testing.T) {
	a := NewIdentity("botplay-", 0, 1, 0)
	must(t, a.DeviceID == "botplay-000001", "device id %q", a.DeviceID)
	must(t, NewIdentity("botplay-", 16, 17, 0).DeviceID == "botplay-000017", "the 17th bot")
	must(t, NewIdentity("botplay-", 0, 1, 2).DeviceID == "botplay-000001-g2", "a replenished generation")
	must(t, a.Seed() == NewIdentity("botplay-", 0, 1, 0).Seed(), "the seed is stable")
	must(t, a.Seed() != NewIdentity("botplay-", 1, 2, 0).Seed(), "bots differ")
	must(t, a.Name != "" && len(a.Name) <= 24, "name %q", a.Name)
}

func TestABotSignsInFindsATeenPattiTableAndSits(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.fs.nextSession()
	s.push(protocol.EvSessionReady, protocol.SessionReady{User: protocol.User{ID: "u-botplay-000001", Chips: 1_000_000}})
	join := s.expect(t, protocol.EvRoomQuickJoin, 5*time.Second, h.advance)
	cat, _ := join.payload["category"].(string)
	must(t, cat == "seen" || cat == "blind", "joined %v — never a poker table", join.payload)
	must(t, join.payload["bootAmount"] == float64(200), "boot %v", join.payload["bootAmount"])
	join.reply <- roomAck("r1")
	s.push(protocol.EvRoomJoined, seatedState("u-botplay-000001", "r1", 0, protocol.TableWaiting))
	h.waitState(state.WaitingForHand)
	must(t, h.bot.Snapshot().Table != "", "the snapshot names the table")
}

func TestARestoredSeatIsResumedWithoutAJoin(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.fs.nextSession()
	uid := "u-botplay-000001"
	s.push(protocol.EvSessionReady, protocol.SessionReady{User: protocol.User{ID: uid, Chips: 1_000_000}})
	// The server still holds the seat: room:joined arrives by itself.
	s.push(protocol.EvRoomJoined, seatedState(uid, "r9", 3, protocol.TableWaiting))
	h.waitState(state.WaitingForHand)
	s.none(t, protocol.EvRoomQuickJoin, 400*time.Millisecond, h.advance)
}

func TestABotActsOnItsTurnWithALegalMoveAndAFreshActionID(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.seat()
	s.push(protocol.EvRoomState, turnState("u-botplay-000001", "r1", 1, h.clk.Now().Add(25*time.Second)))
	act := s.expect(t, protocol.EvGameAction, 5*time.Second, h.advance)
	a, _ := act.payload["action"].(string)
	id, _ := act.payload["actionId"].(string)
	must(t, id != "" && len(id) <= 64, "action id %q", id)
	switch a {
	case protocol.ActionSee, protocol.ActionPack:
	case protocol.ActionChaal:
		must(t, act.payload["amount"] == float64(200), "a chaal names the first rung: %v", act.payload)
	case protocol.ActionRaise:
		amt := act.payload["amount"]
		must(t, amt == float64(400) || amt == float64(800), "a raise names a rung: %v", act.payload)
	default:
		t.Fatalf("an action the options did not offer: %v", act.payload)
	}
	act.reply <- map[string]any{"ok": true, "action": a}
}

func TestAMoveWhoseAckWasLostIsResentWithTheSameActionID(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.seat()
	deadline := h.clk.Now().Add(25 * time.Second)
	turn := turnState("u-botplay-000001", "r1", 1, deadline)
	s.push(protocol.EvRoomState, turn)
	first := s.expect(t, protocol.EvGameAction, 5*time.Second, h.advance)
	// The connection goes before the acknowledgement arrives.
	s.drop()
	s2 := h.nextSession()
	s2.push(protocol.EvSessionReady, protocol.SessionReady{User: protocol.User{ID: "u-botplay-000001", Chips: 1_000_000}})
	s2.push(protocol.EvRoomJoined, turn) // the seat was held; still the same turn
	again := s2.expect(t, protocol.EvGameAction, 5*time.Second, h.advance)
	must(t, again.payload["actionId"] == first.payload["actionId"],
		"the resend must reuse the action id (%v vs %v) so the server applies it once", again.payload["actionId"], first.payload["actionId"])
	must(t, again.payload["action"] == first.payload["action"], "the same move")
	again.reply <- map[string]any{"ok": false, "code": protocol.CodeDuplicateAction}
}

func TestADecisionTheHandOutranIsDropped(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.seat()
	uid := "u-botplay-000001"
	s.push(protocol.EvRoomState, turnState(uid, "r1", 1, h.clk.Now().Add(25*time.Second)))
	// Before the bot has finished thinking, the turn is gone (someone
	// showed, the hand ended): the snapshot carries no options.
	gone := turnState(uid, "r1", 1, h.clk.Now().Add(25*time.Second))
	gone.You.Options = nil
	gone.Turn = &protocol.TurnView{SeatIndex: 1, UserID: ptr("u-human"), Deadline: ptr(h.clk.Now().Add(20 * time.Second).UnixMilli())}
	s.push(protocol.EvRoomState, gone)
	// A look at its own cards is allowed off-turn (and a careful player looks
	// straight after the deal); a BET for the turn that is gone is not.
	deadline := time.Now().Add(600 * time.Millisecond)
	for time.Now().Before(deadline) {
		select {
		case r := <-s.requests:
			if r.event == protocol.EvGameAction && r.payload["action"] != protocol.ActionSee {
				t.Fatalf("the bot bet on a turn that had gone: %v", r.payload)
			}
			r.reply <- map[string]any{"ok": true}
		case <-time.After(5 * time.Millisecond):
			h.advance()
		}
	}
}

func TestStopLeavesAfterTheHandNotDuringIt(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.seat()
	uid := "u-botplay-000001"
	inHand := turnState(uid, "r1", 1, h.clk.Now().Add(25*time.Second))
	inHand.You.Options = nil
	inHand.Turn = &protocol.TurnView{SeatIndex: 1, UserID: ptr("u-human"), Deadline: ptr(h.clk.Now().Add(25 * time.Second).UnixMilli())}
	s.push(protocol.EvRoomState, inHand)
	h.waitState(state.Playing)
	h.bot.Stop()
	s.none(t, protocol.EvRoomLeave, 300*time.Millisecond, h.advance)
	winner := "u-human"
	s.push(protocol.EvGameHandEnded, protocol.HandEnded{RoomID: "r1", HandNo: 1, WinnerID: &winner, Pot: 800,
		NextHandAt: h.clk.Now().Add(4 * time.Second).UnixMilli()})
	leave := s.expect(t, protocol.EvRoomLeave, 5*time.Second, h.advance)
	leave.reply <- map[string]any{"ok": true, "roomId": "r1"}
	select {
	case <-h.done:
	case <-time.After(3 * time.Second):
		t.Fatal("the bot did not stop after leaving")
	}
}

func TestStopWhenNotInAHandLeavesAtOnce(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.seat()
	h.bot.Stop()
	leave := s.expect(t, protocol.EvRoomLeave, 3*time.Second, h.advance)
	leave.reply <- map[string]any{"ok": true, "roomId": "r1"}
}

func TestATableNoLongerOfferedIsRetiredAndAnotherChosen(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.fs.nextSession()
	s.push(protocol.EvSessionReady, protocol.SessionReady{User: protocol.User{ID: "u-botplay-000001", Chips: 1_000_000}})
	first := s.expect(t, protocol.EvRoomQuickJoin, 5*time.Second, h.advance)
	first.reply <- map[string]any{"ok": false, "code": protocol.CodeTableNotOffered, "message": "not offered"}
	second := s.expect(t, protocol.EvRoomQuickJoin, 5*time.Second, h.advance)
	must(t, second.payload["category"] != first.payload["category"],
		"a retired table is not chosen again: %v then %v", first.payload, second.payload)
	second.reply <- roomAck("r2")
}

func TestAFullTableIsRetried(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.fs.nextSession()
	s.push(protocol.EvSessionReady, protocol.SessionReady{User: protocol.User{ID: "u-botplay-000001", Chips: 1_000_000}})
	first := s.expect(t, protocol.EvRoomQuickJoin, 5*time.Second, h.advance)
	first.reply <- map[string]any{"ok": false, "code": protocol.CodeTableFull}
	again := s.expect(t, protocol.EvRoomQuickJoin, 10*time.Second, h.advance)
	again.reply <- roomAck("r3")
}

// A kick for chips sends the bot back to the lobby to look again for a table
// its stack admits. There is no lobby reward to collect first: the game
// server removed the daily, 4-hour and milestone rewards (30 Sep 2026).
func TestAKickForChipsLooksAgain(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.seat()
	s.push(protocol.EvRoomKicked, protocol.RoomKicked{RoomID: "r1", Reason: protocol.CodeInsufficientChips})
	join := s.expect(t, protocol.EvRoomQuickJoin, 10*time.Second, h.advance)
	join.reply <- roomAck("r4")
}

func TestAServerRestartIsReconnectedAndPlayResumes(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.seat()
	s.drop() // the server restarted
	h.waitState(state.Reconnecting)
	s2 := h.nextSession()
	// The restart lost the seat: no room:joined, so the bot looks again.
	s2.push(protocol.EvSessionReady, protocol.SessionReady{User: protocol.User{ID: "u-botplay-000001", Chips: 1_000_000}})
	join := s2.expect(t, protocol.EvRoomQuickJoin, 10*time.Second, h.advance)
	join.reply <- roomAck("r5")
	must(t, h.bot.Snapshot().Reconnects >= 1, "the reconnect is counted")
}

func TestAWipedAccountSignsInAgainOnReconnect(t *testing.T) {
	fs := newFakeServer(t)
	h := start(t, fs, nil)
	s := h.seat()
	fs.mu.Lock()
	before := fs.logins
	fs.refuseDial = []error{&protocol.ConnectError{Message: protocol.CodeUnknownUser}}
	fs.mu.Unlock()
	s.drop()
	s2 := h.nextSession()
	fs.mu.Lock()
	after := fs.logins
	fs.mu.Unlock()
	must(t, after > before, "unknown_user → a fresh sign-in (%d → %d logins)", before, after)
	s2.push(protocol.EvSessionReady, protocol.SessionReady{User: protocol.User{ID: "u-botplay-000001", Chips: 1_000_000}})
	s2.expect(t, protocol.EvRoomQuickJoin, 10*time.Second, h.advance).reply <- roomAck("r6")
}

func TestTheSchedulerRunsInOrderAndCancelsByKind(t *testing.T) {
	clk := clock.NewFake(time.Unix(0, 0))
	s := newScheduler(clk)
	var got []string
	s.after(300*time.Millisecond, "b", func() { got = append(got, "b") })
	s.after(100*time.Millisecond, "a", func() { got = append(got, "a") })
	s.after(200*time.Millisecond, "x", func() { got = append(got, "x") })
	s.cancel("x")
	for i := 0; i < 5; i++ {
		clk.Advance(100 * time.Millisecond)
		select {
		case <-s.wake():
			s.fire()
		default:
		}
	}
	must(t, strings.Join(got, ",") == "a,b", "ran %v", got)
	must(t, !s.has("a") && !s.has("b"), "nothing left")
}

func TestTheFleetRegistryCountsBotsPerTable(t *testing.T) {
	f := NewFleet()
	f.AddBot("a")
	f.AddBot("b")
	f.Seat("a", "r1", "seen:200")
	f.Seat("b", "r1", "seen:200")
	must(t, f.BotsAt("r1") == 2 && f.IsBot("a") && !f.IsBot("human"), "two bots at r1")
	f.Seat("b", "r2", "blind:200")
	occ := f.Occupancy()
	must(t, occ["seen:200"] == 0.5 && occ["blind:200"] == 0.5, "occupancy %v", occ)
	f.Seat("c", "r3", "seen:200")
	f.Seat("d", "r3", "seen:200")
	f.AddBot("c")
	must(t, f.BusierTable("seen:200", "r1", 2, 5), "r3 has two bots and room")
	must(t, !f.BusierTable("seen:200", "r3", 2, 5), "r1 has one bot now")
	must(t, !f.BusierTable("blind:200", "r2", 1, 5), "no other blind table")
	f.Unseat("a")
	f.Unseat("b")
	f.Unseat("c")
	f.Unseat("d")
	must(t, f.Seated() == 0 && f.BotsAt("r1") == 0, "empty")
}

func TestAFleetOfTenHasEveryPersonalityFamily(t *testing.T) {
	seen := map[strategy.Kind]int{}
	for n := 1; n <= 10; n++ {
		seen[strategy.PickKind(nil, rng.From(&rng.Script{Values: []float64{familySlot(n)}}))]++
	}
	for _, k := range strategy.Kinds {
		must(t, seen[k] >= 1, "ten bots and no %s: %v", k, seen)
	}
	counts := map[strategy.Kind]int{}
	for n := 1; n <= 600; n++ {
		counts[strategy.PickKind(nil, rng.From(&rng.Script{Values: []float64{familySlot(n)}}))]++
	}
	for _, k := range strategy.Kinds {
		must(t, counts[k] >= 90 && counts[k] <= 110, "600 bots: %v", counts)
	}
}

// A stop that lands during the staggered start launches nobody else: every
// bot that ever ran is stopped gracefully, none is left to be cut off hard.
func TestAStopDuringTheStaggeredStartLaunchesNobodyElse(t *testing.T) {
	fs := newFakeServer(t)
	clk := clock.NewFake(time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC))
	cfg := config.Default()
	cfg.Bots.Count = 5
	cfg.Bots.StartStagger = [2]time.Duration{10 * time.Second, 20 * time.Second}
	cfg.Interaction.EnableChat = false
	finder := table.NewFinder(fs, cfg.Table.Categories, clk.Now)
	must(t, finder.Refresh(context.Background()) == nil, "menu")
	m := NewManager(Deps{
		API: fs, Dialer: fs, Finder: finder, Clock: clk, Delay: timing.New(timing.Config{}),
		Budget: interaction.NewTableBudget(0, 0), Emoter: interaction.NoEmotes{},
		Fleet: NewFleet(), Config: cfg, Seed: 1, Log: testLogger(),
	})
	m.Start(context.Background())
	deadline := time.Now().Add(3 * time.Second)
	for m.Health().Running == 0 && time.Now().Before(deadline) {
		time.Sleep(2 * time.Millisecond)
	}
	must(t, m.Health().Running == 1, "the first bot starts at once, the rest wait their gap")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	forced := m.Stop(ctx)
	clk.Advance(time.Minute) // the launcher's gap would have run out by now
	time.Sleep(20 * time.Millisecond)
	must(t, forced == 0, "nothing stopped hard (%d)", forced)
	m.mu.Lock()
	ran := len(m.running)
	m.mu.Unlock()
	must(t, ran == 1, "%d bots were launched; after the stop nobody else may start", ran)
}
