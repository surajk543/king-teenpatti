package sim

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sync/atomic"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/clock"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// ---- a scripted client on a fake clock ----

var epoch = time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)

// world is a simulation on a clock.Fake with no latency, driven by the test
// one step at a time: every message is handled and delivered before the
// test looks again, so a run is exactly reproducible.
type world struct {
	t       *testing.T
	s       *Server
	clk     *clock.Fake
	players []*player
}

func newWorld(t *testing.T, cfg Config) *world {
	t.Helper()
	clk := clock.NewFake(epoch)
	cfg.Clock = clk
	if cfg.Latency == ([2]time.Duration{}) {
		cfg.Latency = [2]time.Duration{-1, -1}
	}
	s := NewServer(cfg)
	t.Cleanup(s.Close)
	return &world{t: t, s: s, clk: clk}
}

type player struct {
	w      *world
	idx    int
	token  string
	id     string
	sess   protocol.Session
	events []protocol.Event
	state  *protocol.RoomState
	seq    int
}

// join signs a device in and connects it.
func (w *world) join(device string) *player {
	w.t.Helper()
	res, err := w.s.API().Login(context.Background(), device, "")
	if err != nil {
		w.t.Fatalf("login %s: %v", device, err)
	}
	p := &player{w: w, idx: len(w.players), token: res.Token, id: res.User.ID}
	w.players = append(w.players, p)
	p.dial()
	return p
}

func (p *player) dial() {
	p.w.t.Helper()
	sess, err := p.w.s.Dialer().Dial(context.Background(), p.token)
	if err != nil {
		p.w.t.Fatalf("dial: %v", err)
	}
	p.sess = sess
	p.w.settle()
}

// settle lets the actor run everything due now, then every player reads
// everything waiting for it.
func (w *world) settle() {
	if err := w.s.do(func() { w.s.runDue() }); err != nil {
		w.t.Fatalf("settle: %v", err)
	}
	for _, p := range w.players {
		p.drain()
	}
}

// next moves the clock to the simulation's next timer and settles.
func (w *world) next() {
	var at time.Time
	_ = w.s.do(func() {
		w.s.rearm()
		if len(w.s.tasks) > 0 {
			at = w.s.tasks[0].at
		}
	})
	if at.IsZero() {
		w.t.Fatal("the simulation has nothing left to do")
	}
	w.clk.Advance(at.Sub(w.clk.Now()))
	w.settle()
}

func (p *player) drain() {
	for {
		select {
		case ev, ok := <-p.sess.Events():
			if !ok {
				return
			}
			p.record(ev)
		default:
			return
		}
	}
}

var cardCode = regexp.MustCompile(`"([2-9TJQKA][shdc])"`)

func (p *player) record(ev protocol.Event) {
	p.events = append(p.events, ev)
	if ev.Name != protocol.EvRoomState && ev.Name != protocol.EvRoomJoined {
		return
	}
	var st protocol.RoomState
	if err := ev.Decode(&st); err != nil {
		p.w.t.Fatalf("room:state does not decode: %v", err)
	}
	p.state = &st
	// Redaction: the only cards in a snapshot are the viewer's own, once seen.
	own := map[string]bool{}
	if st.You != nil {
		for _, c := range st.You.Cards {
			own[c] = true
		}
		if st.You.Options != nil && (st.Turn == nil || st.Turn.SeatIndex != st.You.SeatIndex) {
			p.w.t.Errorf("options sent to a player who is not on turn")
		}
	}
	for _, m := range cardCode.FindAllStringSubmatch(string(ev.Data), -1) {
		if !own[m[1]] {
			p.w.t.Errorf("%s leaks card %s to %s: %s", ev.Name, m[1], p.id, ev.Data)
		}
	}
	for _, seat := range st.Seats {
		if st.ChipsHidden && seat.UserID != "" && seat.UserID != p.id && seat.Chips != nil {
			p.w.t.Errorf("a hidden stack was sent: %+v", seat)
		}
	}
}

// request sends an event and decodes its acknowledgement.
func (p *player) request(event string, payload, ack any) {
	p.w.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := p.sess.Request(ctx, event, payload, ack); err != nil {
		p.w.t.Fatalf("%s: %v", event, err)
	}
	p.w.settle()
}

func (p *player) quickJoin(category string, boot int64) protocol.RoomAck {
	var ack protocol.RoomAck
	p.request(protocol.EvRoomQuickJoin, map[string]any{"bootAmount": boot, "category": category}, &ack)
	return ack
}

func (p *player) act(action string, amount *int64) protocol.ActionAck {
	p.seq++
	var ack protocol.ActionAck
	p.request(protocol.EvGameAction, protocol.ActionRequest{Action: action, Amount: amount, ActionID: fmt.Sprintf("a%d", p.seq)}, &ack)
	return ack
}

func (p *player) options() *protocol.TurnOptions {
	if p.state == nil || p.state.You == nil {
		return nil
	}
	return p.state.You.Options
}

func (p *player) last(name string) (protocol.Event, bool) {
	for i := len(p.events) - 1; i >= 0; i-- {
		if p.events[i].Name == name {
			return p.events[i], true
		}
	}
	return protocol.Event{}, false
}

func (p *player) count(name string) int {
	n := 0
	for _, ev := range p.events {
		if ev.Name == name {
			n++
		}
	}
	return n
}

// policy is a deterministic scripted player: look on alternate hands, show
// when it can after the first round, pack now and then from the third round
// (a blind table has no round cap: only packs end its hands), raise now and
// then while the stake is low, else chaal.
func policy(p *player) bool {
	o := p.options()
	if o == nil {
		return false
	}
	st := p.state
	switch {
	case o.CanSee && (st.HandNo+p.idx)%2 == 0:
		p.act(protocol.ActionSee, nil)
	case o.Show != nil && st.Round >= 1:
		p.act(protocol.ActionShow, nil)
	case st.Round >= 2 && (st.HandNo+st.Round+p.idx)%3 == 0:
		p.act(protocol.ActionPack, nil)
	case len(o.RaiseSteps) > 1 && o.CurrentStake <= 800 && (st.HandNo+st.Round+p.idx)%3 == 0:
		p.act(protocol.ActionRaise, ptr(o.RaiseSteps[1]))
	case o.Chaal != nil:
		p.act(protocol.ActionChaal, o.Chaal)
	default:
		p.act(protocol.ActionPack, nil)
	}
	return true
}

// play runs the table until watcher has seen hands game:handEnded events,
// letting the clock run whenever nobody acts.
func (w *world) play(watcher *player, hands int, policy func(*player) bool) []protocol.HandEnded {
	w.t.Helper()
	for i := 0; i < 20_000 && watcher.count(protocol.EvGameHandEnded) < hands; i++ {
		acted := false
		for _, p := range w.players {
			if policy(p) {
				acted = true
				break
			}
		}
		if !acted {
			w.next()
		}
	}
	var out []protocol.HandEnded
	for _, ev := range watcher.events {
		if ev.Name == protocol.EvGameHandEnded {
			var h protocol.HandEnded
			_ = ev.Decode(&h)
			out = append(out, h)
		}
	}
	if len(out) < hands {
		w.t.Fatalf("only %d of %d hands finished", len(out), hands)
	}
	return out
}

func (w *world) conserved() {
	w.t.Helper()
	st := w.s.Stats()
	if st.Chips != st.Minted {
		w.t.Fatalf("chips not conserved: %d in play, %d minted", st.Chips, st.Minted)
	}
}

// ---- REST ----

func TestTheRESTSideIsAStableGuestAccount(t *testing.T) {
	w := newWorld(t, Config{Seed: 7})
	api, ctx := w.s.API(), context.Background()
	if _, err := api.Login(ctx, "short", ""); !isAPIError(err, "invalid_device_id") {
		t.Fatalf("a short device id: %v", err)
	}
	first, err := api.Login(ctx, "botplay-000001", "Ravi")
	if err != nil || !first.IsNew || first.User.DisplayName != "Ravi" || first.User.Chips != 1_000_000 || first.WelcomeChips != 1_000_000 {
		t.Fatalf("first login: %+v %v", first, err)
	}
	again, _ := api.Login(ctx, "botplay-000001", "Someone Else")
	if again.IsNew || again.User.ID != first.User.ID || again.Token != first.Token || again.User.DisplayName != "Ravi" {
		t.Fatalf("second login is not the same account: %+v", again)
	}
	other := NewServer(Config{Seed: 7, Clock: w.clk})
	defer other.Close()
	if same, _ := other.API().Login(ctx, "botplay-000001", ""); same.User.ID != first.User.ID {
		t.Fatal("an account id is not derived from the seed")
	}

	cat, _ := api.Tables(ctx)
	if len(cat.Tables) != 4 || cat.Version == "" || cat.MaxPlayers != 5 || cat.TurnTimeoutMs != 25_000 {
		t.Fatalf("catalogue: %+v", cat)
	}
	want := map[string]int64{"seen:200": 0, "blind:200": 2_000_000, "blind:5000": 200_000_000, "variation:50000": 2_000_000_000}
	for _, e := range cat.Tables {
		if cap, ok := want[e.Key]; !ok || e.MaxChips != cap || e.Engine != protocol.EngineTeenPatti || e.TurnTimeoutMs != 25_000 {
			t.Fatalf("entry %+v", e)
		}
	}

	if _, err := api.Me(ctx, "nope"); !isAPIError(err, protocol.CodeUnknownUser) {
		t.Fatalf("an unknown token: %v", err)
	}
	if ids, _ := api.FreePictureIDs(ctx); len(ids) != 2 {
		t.Fatalf("pictures: %v", ids)
	}
	if err := api.WearPicture(ctx, first.Token, 2); err != nil {
		t.Fatal(err)
	}
	if me, _ := api.Me(ctx, first.Token); me.ActivePictureID == nil || *me.ActivePictureID != 2 || me.Chips != 1_000_000 {
		t.Fatalf("me: %+v", me)
	}

	p := w.join("botplay-000001")
	p.quickJoin(protocol.CategorySeen, 200)
	if _, err := w.s.Dialer().Dial(ctx, "nope"); !isConnectError(err, protocol.CodeUnknownUser) {
		t.Fatalf("an unknown token's handshake: %v", err)
	}
	if st := w.s.Stats(); st.Chips != st.Minted || st.Minted != 1_000_000 {
		t.Fatalf("stats: %+v", st)
	}
}

func isAPIError(err error, code string) bool {
	var e *protocol.APIError
	return errors.As(err, &e) && e.Code == code
}

func isConnectError(err error, message string) bool {
	var e *protocol.ConnectError
	return errors.As(err, &e) && e.Message == message
}

// ---- the table ----

func TestSessionReadyThenAJoinAndTheSnapshotsOfAHand(t *testing.T) {
	w := newWorld(t, Config{Seed: 1})
	a := w.join("device-a-000001")
	if len(a.events) != 1 || a.events[0].Name != protocol.EvSessionReady {
		t.Fatalf("first events: %v", a.events)
	}
	var ready protocol.SessionReady
	_ = a.events[0].Decode(&ready)
	if ready.User.ID != a.id || ready.Config.TurnTimeoutMs != 25_000 || len(ready.Config.Tables) != 4 || ready.Config.TableConfigVersion == "" {
		t.Fatalf("session:ready: %+v", ready)
	}
	ack := a.quickJoin(protocol.CategoryBlind, 200)
	if !ack.OK || ack.RoomID == "" || len(ack.Code) != 8 || ack.Category != protocol.CategoryBlind {
		t.Fatalf("join: %+v", ack)
	}
	if _, ok := a.last(protocol.EvRoomJoined); !ok || a.state.State != protocol.TableWaiting || a.state.You == nil {
		t.Fatalf("no room:joined: %+v", a.state)
	}
	b := w.join("device-b-000001")
	if b.quickJoin(protocol.CategoryBlind, 200).RoomID != ack.RoomID {
		t.Fatal("quick-join did not fill the open table")
	}
	if a.state.State != protocol.TableStarting || a.state.StartsAt == nil {
		t.Fatalf("no countdown: %+v", a.state)
	}
	w.next() // the deal
	if a.state.State != protocol.TableBetting || a.state.Pot != 400 || a.state.HandNo != 1 || len(a.state.You.Cards) != 0 {
		t.Fatalf("after the deal: %+v", a.state)
	}
	onTurn := a
	if b.options() != nil {
		onTurn = b
	}
	o := onTurn.options()
	if o == nil || *o.Chaal != 200 || !o.CanSee || len(o.RaiseSteps) < 3 || o.Show == nil {
		t.Fatalf("options on a blind table: %+v", o)
	}
	if _, ok := onTurn.last(protocol.EvGameYourTurn); !ok {
		t.Fatal("no game:yourTurn")
	}
	onTurn.act(protocol.ActionSee, nil)
	if o := onTurn.options(); o == nil || *o.Chaal != 400 || o.CanSee || len(onTurn.state.You.Cards) != 3 {
		t.Fatalf("after a look the ladder doubles: %+v", onTurn.state.You)
	}
	if ack := onTurn.act(protocol.ActionChaal, ptr(int64(400))); !ack.OK || ack.Action != protocol.ActionChaal || ack.Amount != 400 {
		t.Fatalf("chaal: %+v", ack)
	}
	other := a
	if onTurn == a {
		other = b
	}
	if other.options() == nil || *other.options().Chaal != 200 {
		t.Fatalf("a blind player calls a seen chaal at half: %+v", other.options())
	}
	var ae protocol.ActionEvent
	ev, _ := other.last(protocol.EvGameActionOut)
	_ = ev.Decode(&ae)
	if ae.Action != protocol.ActionChaal || ae.Amount != 400 || ae.Pot != 800 || ae.Stake != 200 {
		t.Fatalf("the room's game:action: %+v", ae)
	}
	if ack := other.act(protocol.ActionShow, nil); !ack.OK || ack.Amount != 200 {
		t.Fatalf("show: %+v", ack)
	}
	var ended protocol.HandEnded
	ev, _ = a.last(protocol.EvGameHandEnded)
	_ = ev.Decode(&ended)
	if ended.WinnerID == nil || ended.Pot != 1000 || ended.Reason != protocol.WinShow || len(ended.Reveals) != 2 || ended.NextHandAt == 0 {
		t.Fatalf("hand end: %+v", ended)
	}
	if _, ok := b.last(protocol.EvGameShowdown); !ok {
		t.Fatal("no showdown")
	}
	w.conserved()
}

func TestHandsCompleteAndChipsAreConservedAtEveryKindOfTable(t *testing.T) {
	for _, tc := range []struct {
		category string
		boot     int64
	}{{protocol.CategorySeen, 200}, {protocol.CategoryBlind, 200}, {protocol.CategoryBlind, 5000}} {
		t.Run(fmt.Sprintf("%s:%d", tc.category, tc.boot), func(t *testing.T) {
			w := newWorld(t, Config{Seed: 3})
			for i := range 4 {
				w.join(fmt.Sprintf("device-%d-00000", i)).quickJoin(tc.category, tc.boot)
			}
			hands := w.play(w.players[0], 12, policy)
			reasons := map[string]int{}
			for _, h := range hands {
				reasons[h.Reason]++
				if h.WinnerID == nil {
					t.Fatalf("a hand with no winner: %+v", h)
				}
			}
			if reasons[protocol.WinShow] == 0 {
				t.Errorf("no show in %d hands: %v", len(hands), reasons)
			}
			w.conserved()
			if st := w.s.Stats(); st.HandsCompleted < 12 || st.Moves == 0 || st.Tables != 1 {
				t.Fatalf("stats: %+v", st)
			}
		})
	}
}

func TestTheSeenTableCapsItsRoundsAndItsPot(t *testing.T) {
	w := newWorld(t, Config{Seed: 5, Tables: []protocol.TableEntry{{Category: protocol.CategorySeen, BootAmount: 200, MaxPot: 6000, MaxBlindMoves: 4}}})
	for i := range 3 {
		w.join(fmt.Sprintf("device-%d-00000", i)).quickJoin(protocol.CategorySeen, 200)
	}
	chaal := func(p *player) bool {
		if o := p.options(); o != nil {
			if o.Chaal == nil {
				p.act(protocol.ActionPack, nil)
			} else {
				p.act(protocol.ActionChaal, o.Chaal)
			}
			return true
		}
		return false
	}
	hands := w.play(w.players[0], 3, chaal)
	for _, h := range hands {
		if h.Reason != protocol.WinPotLimit && h.Reason != protocol.WinForcedShowdown {
			t.Fatalf("a chaal-only seen hand ended %s", h.Reason)
		}
		if h.Reason == protocol.WinPotLimit && h.Pot > 6000 {
			t.Fatalf("the pot passed its cap: %d", h.Pot)
		}
	}
	w.conserved()
}

func TestRefusalsCarryTheServersCodes(t *testing.T) {
	w := newWorld(t, Config{Seed: 9, Tables: []protocol.TableEntry{
		{Category: protocol.CategorySeen, BootAmount: 200, MaxBlindMoves: 4},
		{Category: protocol.CategoryBlind, BootAmount: 200, MaxChips: 500_000, MaxBlindMoves: 4},
		{Category: protocol.CategoryBlind, BootAmount: 5000, MinChips: 5_000_000},
		{Category: protocol.CategoryBlind, BootAmount: 2_000_000},
	}})
	a := w.join("device-a-000001")
	refused := func(p *player, event string, payload any, code string) {
		t.Helper()
		var ack protocol.Ack
		before := p.count(protocol.EvGameError)
		p.request(event, payload, &ack)
		if ack.OK || ack.Code != code {
			t.Fatalf("%s %v: %+v, want %s", event, payload, ack, code)
		}
		if p.count(protocol.EvGameError) != before+1 {
			t.Fatalf("%s: no game:error beside the ack", event)
		}
	}
	join := func(category string, boot any) map[string]any {
		return map[string]any{"category": category, "bootAmount": boot}
	}
	refused(a, protocol.EvRoomQuickJoin, join("seen", 1234), protocol.CodeInvalidStake)
	refused(a, protocol.EvRoomQuickJoin, join("seen", "lots"), protocol.CodeInvalidStake)
	refused(a, protocol.EvRoomQuickJoin, join("seen", 5000), protocol.CodeTableNotOffered)
	refused(a, protocol.EvRoomQuickJoin, join("blind", 200), protocol.CodeOverEntryCap)
	refused(a, protocol.EvRoomQuickJoin, join("blind", 5000), protocol.CodeBelowTableMinimum)
	refused(a, protocol.EvRoomQuickJoin, join("blind", 2_000_000), protocol.CodeInsufficientChips)
	refused(a, protocol.EvGameAction, map[string]any{"action": "see"}, protocol.CodeNotInRoom)
	refused(a, protocol.EvRoomSwitch, map[string]any{}, protocol.CodeNotInRoom)
	refused(a, protocol.EvRoomJoinCode, map[string]any{"code": "abc"}, protocol.CodeInvalidRoomCode)
	refused(a, protocol.EvRoomJoinCode, map[string]any{"code": "ABCDEFGH"}, protocol.CodeRoomNotFound)
	if ack := a.quickJoin("anything", 200); !ack.OK || ack.Category != protocol.CategorySeen {
		t.Fatalf("an unknown category is seen: %+v", ack)
	}
	refused(a, protocol.EvRoomQuickJoin, join("seen", 200), protocol.CodeAlreadyInRoom)
	refused(a, protocol.EvGameAction, map[string]any{"action": "chaal"}, protocol.CodeNoHand)
	refused(a, protocol.EvGameAction, map[string]any{"action": "dance"}, "unknown_action")

	b := w.join("device-b-000001")
	b.quickJoin(protocol.CategorySeen, 200)
	w.next()
	on, off := a, b
	if b.options() != nil {
		on, off = b, a
	}
	refused(off, protocol.EvGameAction, map[string]any{"action": "chaal"}, protocol.CodeNotYourTurn)
	refused(on, protocol.EvGameAction, map[string]any{"action": "chaal", "amount": 12345}, protocol.CodeInvalidBet)
	refused(on, protocol.EvGameAction, map[string]any{"action": "chaal", "amount": "200"}, protocol.CodeInvalidBet)
	refused(on, protocol.EvGameAction, map[string]any{"action": "raise", "amount": 200}, protocol.CodeInvalidBet)
	refused(on, protocol.EvGameAction, map[string]any{"action": "sideshow"}, "too_few_players")
	refused(on, protocol.EvGameAction, map[string]any{"action": "forceSideshow"}, "no_hammers")
	refused(on, protocol.EvGameSideshowRespond, map[string]any{"accept": true}, protocol.CodeNoSideshow)
	refused(on, protocol.EvGameSelectVariation, map[string]any{"variation": "AK47"}, "no_variation")
	refused(on, protocol.EvGameSelectCards, map[string]any{"cards": []string{}}, protocol.CodeNotPicking)

	var ok protocol.ActionAck
	on.request(protocol.EvGameAction, map[string]any{"action": "chaal", "amount": 200, "actionId": "same-id"}, &ok)
	off.act(protocol.ActionChaal, off.options().Chaal)
	refused(on, protocol.EvGameAction, map[string]any{"action": "chaal", "amount": 200, "actionId": "same-id"}, protocol.CodeDuplicateAction)
	if o := on.options(); o == nil || o.Chaal == nil {
		t.Fatal("a refused duplicate took the turn away")
	}

	c := w.join("device-c-000001")
	c.quickJoin(protocol.CategorySeen, 200)
	refused(c, protocol.EvGameAction, map[string]any{"action": "chaal"}, protocol.CodeNotInHand)
	for i := range chatLimit {
		var ack struct {
			protocol.Ack
			MessageID string `json:"messageId"`
		}
		c.request(protocol.EvChatMessage, map[string]any{"text": fmt.Sprintf("hello %d", i)}, &ack)
		if !ack.OK || ack.MessageID == "" {
			t.Fatalf("chat %d: %+v", i, ack)
		}
	}
	refused(c, protocol.EvChatMessage, map[string]any{"text": "one more"}, protocol.CodeChatRateLimited)
	var line protocol.ChatMessage
	ev, _ := a.last(protocol.EvChatMessage)
	_ = ev.Decode(&line)
	if line.Text != "hello 4" || line.UserID == nil || *line.UserID != c.id {
		t.Fatalf("chat broadcast: %+v", line)
	}
	if st := w.s.Stats(); st.Refusals < 20 {
		t.Fatalf("refusals not counted: %+v", st)
	}
	w.conserved()
}

func TestAnIdlePlayerIsPackedThenShownOutAfterThreeMissedTurns(t *testing.T) {
	w := newWorld(t, Config{Seed: 11})
	idle := w.join("device-idle-0001")
	busy := w.join("device-busy-0001")
	idle.quickJoin(protocol.CategorySeen, 200)
	busy.quickJoin(protocol.CategorySeen, 200)
	for i := 0; i < 500 && idle.count(protocol.EvRoomKicked) == 0; i++ {
		if !policy(busy) {
			w.next()
		}
	}
	ev, ok := idle.last(protocol.EvRoomKicked)
	var kicked protocol.RoomKicked
	_ = ev.Decode(&kicked)
	if !ok || kicked.Reason != "idle" || kicked.Message != "Left the table after 3 missed turns" {
		t.Fatalf("kick: %+v", kicked)
	}
	packs := 0
	for _, ev := range busy.events {
		var a protocol.ActionEvent
		if ev.Name == protocol.EvGameActionOut && ev.Decode(&a) == nil && a.UserID == idle.id && a.Reason == "timeout" {
			packs++
		}
	}
	if packs != 3 {
		t.Fatalf("%d timeouts before the kick", packs)
	}
	w.conserved()
}

func TestAReconnectWithinTheGraceGetsTheSeatBack(t *testing.T) {
	w := newWorld(t, Config{Seed: 13})
	a := w.join("device-a-000001")
	b := w.join("device-b-000001")
	room := a.quickJoin(protocol.CategorySeen, 200).RoomID
	b.quickJoin(protocol.CategorySeen, 200)
	w.next() // the deal

	_ = a.sess.Close()
	_ = a.sess.Close() // twice is fine
	w.settle()
	if last := a.events[len(a.events)-1]; last.Name != protocol.EvDisconnect || !errors.Is(a.sess.Err(), protocol.ErrClosed) {
		t.Fatalf("the stream did not end with a disconnect: %s %v", last.Name, a.sess.Err())
	}
	if _, open := <-a.sess.Events(); open {
		t.Fatal("the stream is still open")
	}
	var ack protocol.RoomAck
	if err := a.sess.Request(context.Background(), protocol.EvRoomLeave, nil, &ack); !errors.Is(err, protocol.ErrClosed) {
		t.Fatalf("a request on a closed session: %v", err)
	}
	if seat := b.state.Seats[0]; seat.UserID == a.id && seat.Connected {
		t.Fatal("the seat still reads connected")
	}

	w.clk.Advance(20 * time.Second)
	a.events = nil
	a.dial()
	// The server's resume order: session:ready, room:state (the seat reads
	// connected again), room:joined.
	if got := names(a.events); len(got) != 3 || got[0] != protocol.EvSessionReady || got[2] != protocol.EvRoomJoined || a.state.RoomID != room {
		t.Fatalf("no seat back: %v", names(a.events))
	}
	for _, seat := range b.state.Seats {
		if seat.UserID == a.id && !seat.Connected {
			t.Fatal("the seat does not read connected again")
		}
	}

	// A second connection replaces the first.
	first := a.sess
	a.dial()
	first.(*session).mu.Lock()
	why := first.(*session).err
	first.(*session).mu.Unlock()
	if !errors.Is(why, errReplaced) {
		t.Fatalf("the older connection: %v", why)
	}

	// Past the grace the seat is given up and offered back once.
	_ = a.sess.Close()
	seated := func() bool {
		for _, seat := range b.state.Seats {
			if seat.UserID == a.id {
				return true
			}
		}
		return false
	}
	for i := 0; i < 100 && seated(); i++ {
		if !policy(b) {
			w.next()
		}
	}
	if seated() || w.clk.Now().Sub(epoch) < 80*time.Second {
		t.Fatalf("the seat was not given up after the grace (at %v)", w.clk.Now().Sub(epoch))
	}
	a.events = nil
	a.dial()
	var ready protocol.SessionReady
	_ = a.events[0].Decode(&ready)
	if ready.Resume == nil || ready.Resume.RoomID != room || len(a.events) != 1 {
		t.Fatalf("no resume offer: %+v %v", ready, names(a.events))
	}
	var back protocol.RoomAck
	a.request(protocol.EvRoomJoinCode, map[string]any{"code": ready.Resume.Code}, &back)
	if !back.OK || back.RoomID != room {
		t.Fatalf("resume: %+v", back)
	}
	w.conserved()
}

func names(evs []protocol.Event) []string {
	var out []string
	for _, ev := range evs {
		out = append(out, ev.Name)
	}
	return out
}

func TestASideshowIsAskedAnsweredAndRevealedToTheTwoAlone(t *testing.T) {
	w := newWorld(t, Config{Seed: 17})
	ps := []*player{w.join("device-0-000001"), w.join("device-1-000001"), w.join("device-2-000001")}
	for _, p := range ps {
		p.quickJoin(protocol.CategorySeen, 200)
	}
	w.next()
	for _, p := range ps {
		p.act(protocol.ActionSee, nil)
	}
	var asker *player
	for _, p := range ps {
		if p.options() != nil {
			asker = p
		}
	}
	o := asker.options()
	if !o.CanSideshow || o.SideshowWith == nil {
		t.Fatalf("no sideshow offered: %+v", o)
	}
	var ack protocol.ActionAck
	asker.request(protocol.EvGameAction, map[string]any{"action": "sideshow", "actionId": "ss"}, &ack)
	var req protocol.SideshowRequested
	ev, _ := ps[0].last(protocol.EvGameSideshowRequested)
	_ = ev.Decode(&req)
	if !ack.OK || req.FromUserID != asker.id || req.TimeoutMs != 6000 {
		t.Fatalf("request: %+v %+v", ack, req)
	}
	if o := asker.options(); o == nil || len(o.RaiseSteps) != 0 || o.CanPack || o.Chaal != nil {
		t.Fatalf("the asker's turn is not frozen: %+v", o)
	}
	var target, third *player
	for _, p := range ps {
		switch p.id {
		case req.ToUserID:
			target = p
		case req.FromUserID:
		default:
			third = p
		}
	}
	var answer struct {
		protocol.Ack
		Accepted     bool    `json:"accepted"`
		PackedUserID *string `json:"packedUserId"`
	}
	third.request(protocol.EvGameSideshowRespond, map[string]any{"accept": true}, &answer)
	if answer.OK || answer.Code != "not_your_sideshow" {
		t.Fatalf("a third player answered: %+v", answer)
	}
	target.request(protocol.EvGameSideshowRespond, map[string]any{"accept": true}, &answer)
	if !answer.OK || !answer.Accepted || answer.PackedUserID == nil {
		t.Fatalf("answer: %+v", answer)
	}
	if _, ok := third.last(protocol.EvGameSideshowReveal); ok {
		t.Fatal("the third player saw the sideshow's cards")
	}
	for _, p := range []*player{asker, target} {
		if _, ok := p.last(protocol.EvGameSideshowReveal); !ok {
			t.Fatal("a participant got no reveal")
		}
	}
	var resolved protocol.SideshowResolved
	ev, _ = third.last(protocol.EvGameSideshowResolved)
	_ = ev.Decode(&resolved)
	if !resolved.Accepted || resolved.PackedUserID == nil || *resolved.PackedUserID != *answer.PackedUserID {
		t.Fatalf("resolved: %+v", resolved)
	}
	w.conserved()
}

func TestAVariationWindowIsChosenOrLapsesToMuflis(t *testing.T) {
	w := newWorld(t, Config{Seed: 19})
	a, b := w.join("device-a-000001"), w.join("device-b-000001")
	a.quickJoin(protocol.CategoryVariation, 50_000)
	b.quickJoin(protocol.CategoryVariation, 50_000)
	w.next()
	v := a.state.Variation
	if v == nil || !v.Selecting || a.state.Turn.SeatIndex != -1 || len(v.Options) != 6 || v.Deadline == nil {
		t.Fatalf("no window: %+v", a.state.Variation)
	}
	chooser, other := a, b
	if v.UserID == b.id {
		chooser, other = b, a
	}
	var ack struct {
		protocol.Ack
		Variation      string `json:"variation"`
		SelectedBy     string `json:"selectedBy"`
		CardsPerPlayer int    `json:"cardsPerPlayer"`
	}
	other.request(protocol.EvGameSelectVariation, map[string]any{"variation": "AK47"}, &ack)
	if ack.Code != protocol.CodeNotSelecting {
		t.Fatalf("the other player chose: %+v", ack)
	}
	chooser.request(protocol.EvGameAction, map[string]any{"action": "chaal"}, &ack)
	if ack.Code != protocol.CodeVariationPending {
		t.Fatalf("a move in the window: %+v", ack)
	}
	chooser.request(protocol.EvGameSelectVariation, map[string]any{"variation": "muflis"}, &ack)
	if ack.Code != protocol.CodeInvalidVariation {
		t.Fatalf("a folded name: %+v", ack)
	}
	chooser.act(protocol.ActionSee, nil) // a look is allowed in the window
	chooser.request(protocol.EvGameSelectVariation, map[string]any{"variation": "AK47"}, &ack)
	if !ack.OK || ack.Variation != "AK47" || ack.SelectedBy != "PLAYER" || ack.CardsPerPlayer != 3 {
		t.Fatalf("choice: %+v", ack)
	}
	st := chooser.state
	if st.Variation.Selecting || *st.Variation.Selected != "AK47" || chooser.options() == nil || st.You.Hand == nil || len(st.You.Hand.Best) != 3 {
		t.Fatalf("after the choice: %+v %+v", st.Variation, st.You)
	}
	if other.state.You.Hand != nil {
		t.Fatal("a blind player was told their hand")
	}
	// It bets as a blind table does (the server's config.TableRules since
	// 28 Sep 2026): a seen chooser's ladder doubles from twice the stake until
	// the stack stops it — 1,00,000 to 8,00,000 inside 9,50,000 — where a seen
	// table stops at two rungs.
	if o := chooser.options(); len(o.RaiseSteps) != 4 || o.RaiseSteps[0] != 100_000 || o.RaiseSteps[3] != 800_000 {
		t.Fatalf("a variation table's ladder: %v (chips %d)", o.RaiseSteps, o.Chips)
	}
	chooser.request(protocol.EvGameSelectVariation, map[string]any{"variation": "JOKER"}, &ack)
	if ack.Code != protocol.CodeVariationSelected {
		t.Fatalf("a second choice: %+v", ack)
	}

	// The next hand's window lapses: the server chooses Muflis.
	chooser.act(protocol.ActionPack, nil)
	w.next() // the next deal
	if v := a.state.Variation; v == nil || !v.Selecting {
		t.Fatalf("no second window: %+v", v)
	}
	w.next() // the window's clock
	var sel struct {
		Variation  string `json:"variation"`
		SelectedBy string `json:"selectedBy"`
	}
	ev, _ := a.last(protocol.EvGameVariationSelected)
	_ = ev.Decode(&sel)
	if sel.Variation != protocol.VariationMuflis || sel.SelectedBy != "TIMEOUT" || a.state.Turn.SeatIndex < 0 {
		t.Fatalf("lapse: %+v turn %+v", sel, a.state.Turn)
	}
	w.conserved()
}

func TestASwitchMovesToTheEmptiestOtherTable(t *testing.T) {
	w := newWorld(t, Config{Seed: 23, MaxPlayers: 2})
	a, b, c := w.join("device-a-000001"), w.join("device-b-000001"), w.join("device-c-000001")
	first := a.quickJoin(protocol.CategorySeen, 200).RoomID
	b.quickJoin(protocol.CategorySeen, 200)
	second := c.quickJoin(protocol.CategorySeen, 200).RoomID
	if first == second {
		t.Fatal("a full table was joined")
	}
	var ack protocol.RoomAck
	a.request(protocol.EvRoomSwitch, map[string]any{}, &ack)
	if !ack.OK || ack.RoomID != second {
		t.Fatalf("switch: %+v", ack)
	}
	b.request(protocol.EvRoomSwitch, map[string]any{}, &ack)
	if !ack.OK || ack.RoomID == first || ack.RoomID == second {
		t.Fatalf("a switch with every other table full opens a new one: %+v", ack)
	}
	if st := w.s.Stats(); st.Tables != 2 {
		t.Fatalf("the empty table was not closed: %+v", st)
	}
	var left struct {
		protocol.Ack
		RoomID string `json:"roomId"`
	}
	b.request(protocol.EvRoomLeave, map[string]any{}, &left)
	if !left.OK || left.RoomID != ack.RoomID {
		t.Fatalf("leave: %+v", left)
	}
	if _, ok := b.last(protocol.EvRoomLeft); !ok {
		t.Fatal("no room:left")
	}
	left.RoomID = ""
	b.request(protocol.EvRoomLeave, map[string]any{}, &left)
	if !left.OK || left.RoomID != "" {
		t.Fatalf("a second leave: %+v", left)
	}
	w.conserved()
}

func TestAConnectionThatStopsReadingIsDropped(t *testing.T) {
	w := newWorld(t, Config{Seed: 29, SessionBuffer: 5})
	res, _ := w.s.API().Login(context.Background(), "device-slow-0001", "")
	slow, _ := w.s.Dialer().Dial(context.Background(), res.Token)
	ctx := context.Background()
	var ack protocol.RoomAck
	if err := slow.Request(ctx, protocol.EvRoomQuickJoin, map[string]any{"category": "seen"}, &ack); err != nil || !ack.OK {
		t.Fatalf("join: %+v %v", ack, err)
	}
	fast := w.join("device-fast-0001")
	fast.quickJoin(protocol.CategorySeen, 200)
	<-slow.Done()
	if !errors.Is(slow.Err(), errOverflow) {
		t.Fatalf("err: %v", slow.Err())
	}
	var got []protocol.Event
	for ev := range slow.Events() {
		got = append(got, ev)
	}
	// session:ready, room:state, room:joined, then the other player's
	// arrival: a chat line and a room:state fill the buffer, and the
	// countdown's room:state is one too many.
	if len(got) != 6 || got[5].Name != protocol.EvDisconnect || got[4].Name != protocol.EvRoomState {
		t.Fatalf("events: %v", names(got))
	}
}

// ---- determinism ----

func TestTheSameSeedPlaysTheSameHands(t *testing.T) {
	run := func(seed uint64) string {
		w := newWorld(t, Config{Seed: seed})
		for i := range 3 {
			w.join(fmt.Sprintf("device-%d-00000", i)).quickJoin(protocol.CategoryBlind, 200)
		}
		// Player 2 never moves after the first hand: its clock decides some turns.
		lazy := func(p *player) bool {
			if p.idx == 2 && p.state != nil && p.state.HandNo > 1 {
				return false
			}
			return policy(p)
		}
		var log string
		for _, h := range w.play(w.players[0], 10, lazy) {
			log += fmt.Sprintf("%d %s %d %s %v|", h.HandNo, *h.WinnerID, h.Pot, h.Reason, h.Reveals)
		}
		w.conserved()
		return log
	}
	first, second, other := run(42), run(42), run(43)
	if first != second {
		t.Fatalf("the same seed played differently:\n%s\n%s", first, second)
	}
	if first == other {
		t.Fatal("a different seed played the same hands")
	}
}

// ---- the real clock, latency, drops and concurrent bots ----

func TestAConcurrentFleetOnTheRealClockWithLatencyAndDrops(t *testing.T) {
	if testing.Short() {
		t.Skip("runs for a few seconds")
	}
	s := NewServer(Config{Seed: 31, TurnTimeout: 300 * time.Millisecond, NextHandDelay: 20 * time.Millisecond,
		Latency: [2]time.Duration{time.Millisecond, 4 * time.Millisecond}, DropEvery: 250 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 2500*time.Millisecond)
	defer cancel()
	done := make(chan error, 8)
	for i := range 8 {
		go func() { done <- fleetBot(ctx, s, i) }()
	}
	for range 8 {
		if err := <-done; err != nil {
			t.Error(err)
		}
	}
	s.Close()
	st := s.Stats()
	if st.HandsCompleted < 5 || st.Drops == 0 || st.Moves == 0 {
		t.Fatalf("stats: %+v", st)
	}
	if st.Chips != st.Minted {
		t.Fatalf("chips not conserved: %+v", st)
	}
}

// fleetBot is a minimal concurrent bot: it joins, acts from room:state's
// options, and reconnects whenever its connection is dropped.
func fleetBot(ctx context.Context, s *Server, i int) error {
	res, err := s.API().Login(ctx, fmt.Sprintf("fleet-bot-%04d", i), "")
	if err != nil {
		return err
	}
	category := []string{protocol.CategorySeen, protocol.CategoryBlind}[i%2]
	for n := 0; ctx.Err() == nil; n++ {
		sess, err := s.Dialer().Dial(ctx, res.Token)
		if err != nil {
			return nil // the context ended
		}
		var seated atomic.Bool
		for ev := range sess.Events() {
			switch ev.Name {
			case protocol.EvSessionReady:
				var ready protocol.SessionReady
				_ = ev.Decode(&ready)
				go func() {
					time.Sleep(10 * time.Millisecond)
					if ready.Resume != nil {
						_ = sess.Request(ctx, protocol.EvRoomJoinCode, map[string]any{"code": ready.Resume.Code}, nil)
					}
					if !seated.Load() {
						_ = sess.Request(ctx, protocol.EvRoomQuickJoin, map[string]any{"category": category, "bootAmount": 200}, nil)
					}
				}()
			case protocol.EvRoomJoined:
				seated.Store(true)
			case protocol.EvRoomKicked:
				_ = sess.Emit(ctx, protocol.EvRoomQuickJoin, map[string]any{"category": category, "bootAmount": 200})
			case protocol.EvRoomState:
				var st protocol.RoomState
				if ev.Decode(&st) != nil || st.You == nil || st.You.Options == nil {
					continue
				}
				o := st.You.Options
				req := protocol.ActionRequest{Action: protocol.ActionPack, ActionID: fmt.Sprintf("%d-%d-%d-%d", i, n, st.HandNo, st.Round)}
				switch {
				case o.CanSee && st.HandNo%2 == 0:
					req.Action = protocol.ActionSee
				case o.Show != nil && st.Round > 1:
					req.Action = protocol.ActionShow
				case o.Chaal != nil:
					req.Action, req.Amount = protocol.ActionChaal, o.Chaal
				}
				rctx, cancel := context.WithTimeout(ctx, time.Second)
				_ = sess.Request(rctx, protocol.EvGameAction, req, &protocol.ActionAck{})
				cancel()
			}
			if ctx.Err() != nil {
				_ = sess.Close()
			}
		}
		if sess.Err() == nil {
			return fmt.Errorf("bot %d: a closed stream with no reason", i)
		}
	}
	return nil
}

func TestSessionPayloadsHaveTheServersShape(t *testing.T) {
	w := newWorld(t, Config{Seed: 37})
	a := w.join("device-a-000001")
	a.quickJoin(protocol.CategoryBlind, 200)
	ev, _ := a.last(protocol.EvRoomJoined)
	var raw map[string]any
	if err := json.Unmarshal(ev.Data, &raw); err != nil {
		t.Fatal(err)
	}
	seats := raw["seats"].([]any)
	if len(seats) != 5 || len(seats[1].(map[string]any)) != 2 {
		t.Fatalf("an empty seat is not {seatIndex, status}: %v", seats[1])
	}
	you := raw["you"].(map[string]any)
	if you["cards"] == nil || you["options"] != nil || raw["turn"] != nil || raw["sideshow"] != nil {
		t.Fatalf("null and absent keys: %v", raw)
	}
	if _, ok := raw["variation"]; ok {
		t.Fatal("a blind table's snapshot carries a variation block")
	}
}
