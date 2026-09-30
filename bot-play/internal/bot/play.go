package bot

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/interaction"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/state"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/strategy"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/table"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/timing"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// handle is one inbound event, on the bot's loop.
func (b *Bot) handle(ctx context.Context, ev protocol.Event) {
	b.ctx = ctx
	switch ev.Name {
	case protocol.EvSessionReady:
		var p protocol.SessionReady
		if b.decode(ev, &p) {
			b.onSessionReady(p)
		}
	case protocol.EvRoomJoined:
		var s protocol.RoomState
		if b.decode(ev, &s) {
			b.onJoined(&s)
		}
	case protocol.EvRoomState:
		var s protocol.RoomState
		if b.decode(ev, &s) {
			b.onState(&s)
		}
	case protocol.EvGameActionOut:
		var a protocol.ActionEvent
		if b.decode(ev, &a) {
			b.onAction(a)
		}
	case protocol.EvGameSideshowRequested:
		var r protocol.SideshowRequested
		if b.decode(ev, &r) && r.ToUserID == b.userID {
			b.answerSideshow(r.ExpiresAt)
		}
	case protocol.EvGameSideshowResolved:
		var r protocol.SideshowResolved
		if b.decode(ev, &r) {
			b.onSideshowResolved(r)
		}
	case protocol.EvGameShowdown:
		// The hand is over; anything still being thought about is stale.
		b.invalidateTurn()
	case protocol.EvGameHandEnded:
		var h protocol.HandEnded
		if b.decode(ev, &h) {
			b.onHandEnded(h)
		}
	case protocol.EvRoomKicked:
		var k protocol.RoomKicked
		_ = ev.Decode(&k)
		b.onKicked(k)
	case protocol.EvRoomClosed:
		b.onUnseated("room_closed")
	case protocol.EvRoomLeft:
		if b.seated && !b.machineIn(state.LeavingTable, state.SwitchingTable) {
			b.onUnseated("room_left")
		}
	case protocol.EvRoomMoved:
		// A consolidation or a switch moved this bot; the room:joined that
		// follows carries the new table.
		b.log.Info("moved by the server")
	case protocol.EvChatMessage:
		var m protocol.ChatMessage
		if b.decode(ev, &m) {
			b.onChat(m)
		}
	case protocol.EvSessionReplaced:
		b.log.Error("session replaced: another connection signed in as this bot")
		b.outcome = outFatal
	case protocol.EvDisconnect:
		if b.outcome == outNone {
			b.outcome = outLost
		}
	case protocol.EvGameError:
		// Every refusal also arrives on its request's ack, which is where it
		// is handled; this copy is only counted.
	}
	b.publish()
}

func (b *Bot) decode(ev protocol.Event, v any) bool {
	if err := ev.Decode(v); err != nil {
		b.log.Warn("undecodable event", "event", ev.Name, "err", err)
		return false
	}
	return true
}

func (b *Bot) machineIn(states ...state.State) bool {
	cur := b.machine.Current()
	for _, s := range states {
		if cur == s {
			return true
		}
	}
	return false
}

// ---- session and seat -------------------------------------------------------

// onSessionReady is the server's hello. A seat the server still holds for
// this account arrives by itself as room:joined (a reconnect inside the
// server's grace), so the bot waits a moment before looking for a table.
func (b *Bot) onSessionReady(p protocol.SessionReady) {
	b.ready = true
	b.sched.cancel("hello")
	b.attempts = 0
	b.chips = p.User.Chips
	b.session.Chips = b.chips
	b.resume = p.Resume
	if b.d.Finder.NoticeSession(p.Config) {
		ctx, cancel := context.WithTimeout(b.ctx, 5*time.Second)
		if err := b.d.Finder.Refresh(ctx); err != nil {
			b.log.Warn("menu refresh failed", "err", err)
		}
		cancel()
	}
	b.sched.after(time.Duration(b.rand.Between(2.2, 3.4)*float64(time.Second)), "settle", func() {
		if b.seated || b.outcome != outNone {
			return
		}
		if b.resume != nil && b.resume.Code != "" {
			b.takeResumeOffer()
			return
		}
		// After a reconnect that lost the seat (a server restart), the
		// natural idle gap: a whole fleet sitting down in the same second is
		// both a tell and a burst on a server that has just come back.
		b.search(b.rejoin)
	})
}

// takeResumeOffer sits back down at the table the server offers back after
// a disconnect that outlasted the grace (session:ready.resume).
func (b *Bot) takeResumeOffer() {
	offer := b.resume
	b.resume = nil
	b.machine.To(state.JoiningTable, "table", offer.Category+":"+fmt.Sprint(offer.BootAmount), "resume", true)
	var ack protocol.RoomAck
	if err := b.request(protocol.EvRoomJoinCode, map[string]any{"code": offer.Code}, &ack); err != nil {
		return
	}
	if !ack.OK {
		b.d.Metrics.Refused(ack.Code)
		b.log.Info("resume offer refused", "code", ack.Code)
		b.search(false)
		return
	}
	if c, ok := b.d.Finder.Menu().Lookup(fmt.Sprintf("%s:%d", offer.Category, offer.BootAmount)); ok {
		b.table = c
	}
}

// onJoined is a seat: taken by a join, restored after a reconnect, or the
// new table after a switch or consolidation.
func (b *Bot) onJoined(s *protocol.RoomState) {
	b.sched.cancel("settle")
	newRoom := s.RoomID != b.roomID
	b.seated = true
	b.roomID = s.RoomID
	key := fmt.Sprintf("%s:%d", s.Category, s.BootAmount)
	if c, ok := b.d.Finder.Menu().Lookup(key); ok {
		b.table = c
	} else if b.table.Key != key {
		b.table = table.Choice{Key: key, Category: s.Category, Boot: s.BootAmount, TurnTimeoutMs: s.TurnTimeoutMs}
	}
	b.d.Fleet.Seat(b.userID, s.RoomID, key)
	if newRoom {
		b.joinedAt = b.now()
		b.session.TableHands = 0
		b.session.TableJoinedAt = b.joinedAt
		b.session.TableStartChip = b.chips
		b.plannedHands = table.PlanHands(b.persona, b.d.Config.Table.MinHands, b.d.Config.Table.MaxHands, b.rand)
		b.knownSeats = map[string]bool{}
		for _, seat := range s.Seats {
			if seat.UserID != "" {
				b.knownSeats[seat.UserID] = true
			}
		}
		b.recent = append([]string{key}, b.recent...)
		if len(b.recent) > 6 {
			b.recent = b.recent[:6]
		}
		b.d.Metrics.TableJoin(s.Category)
		b.log.Info("seated", "table", key, "room", s.RoomID, "planned_hands", b.plannedHands)
		b.say(interaction.Join, nil)
	}
	b.onState(s)
}

// onUnseated is the seat gone by the server's hand (the table closed).
func (b *Bot) onUnseated(reason string) {
	if !b.seated {
		return
	}
	b.seated = false
	b.d.Fleet.Unseat(b.userID)
	b.invalidateTurn()
	b.d.Metrics.TableLeave(reason)
	b.log.Info("unseated", "reason", reason)
	b.afterLeaving(outNone)
}

// onKicked: idle (this bot missed its turns — its timing failed) or out of
// chips, among others.
func (b *Bot) onKicked(k protocol.RoomKicked) {
	if b.seated {
		b.d.Fleet.Unseat(b.userID)
	}
	b.seated = false
	b.invalidateTurn()
	b.d.Metrics.TableLeave("kicked_" + k.Reason)
	b.log.Warn("kicked", "reason", k.Reason)
	b.afterLeaving(outNone)
}

// ---- the table's state ------------------------------------------------------

// onState is a new snapshot of the table as this bot may see it.
func (b *Bot) onState(s *protocol.RoomState) {
	if !b.seated || (b.roomID != "" && s.RoomID != b.roomID) {
		return
	}
	prev := b.view
	b.view = s
	you := s.You
	if you != nil {
		b.chips = you.Chips
		b.session.Chips = b.chips
		b.contributed = you.Contributed
	}
	b.noticeHumans(s)
	betting := s.State == protocol.TableBetting
	if betting && s.HandNo != b.handNo {
		b.startHand(s)
	}
	if !betting {
		// Seated between hands. A leave or a switch in flight, or a result
		// still being settled, keeps its own state until it is done.
		if !b.machineIn(state.ProcessingResult, state.LeavingTable, state.SwitchingTable) {
			b.machine.To(state.WaitingForHand, "table", b.table.Key)
		}
		b.invalidateTurn()
		return
	}
	if you == nil || you.Status != protocol.SeatActive {
		if b.inHand && you != nil && you.Status == protocol.SeatPacked {
			b.packed = true
		}
		b.machine.To(state.WaitingForHand, "table", b.table.Key)
		b.invalidateTurn()
		return
	}
	b.maybeChooseVariation(s)
	b.maybePickCards(s)
	b.noticeVariation(s)
	if s.Sideshow != nil && s.Sideshow.ToUserID == b.userID {
		b.answerSideshow(s.Sideshow.ExpiresAt)
	}
	if you.Options != nil {
		b.machine.To(state.WaitingForAction, "table", b.table.Key, "hand", s.HandNo)
		b.maybeAct(s)
		return
	}
	if prev != nil && prev.You != nil && prev.You.Options != nil {
		b.invalidateTurn()
	}
	b.machine.To(state.Playing, "table", b.table.Key, "hand", s.HandNo)
}

// startHand is a new deal seen for the first time.
func (b *Bot) startHand(s *protocol.RoomState) {
	b.handNo = s.HandNo
	b.inHand = s.You != nil && s.You.Status == protocol.SeatActive
	b.packed = false
	b.answered = map[string]bool{}
	b.turnKey = ""
	b.memory = strategy.NewHandMemory(b.persona, s.Category, b.rand)
	if !b.inHand {
		return
	}
	b.session.Hands++
	b.session.TableHands++
	b.d.Metrics.HandStarted(s.Category)
	others := make([]string, 0, len(s.Seats))
	for _, seat := range s.Seats {
		if seat.UserID != "" && seat.UserID != b.userID && seat.Status == protocol.SeatActive {
			others = append(others, seat.UserID)
		}
	}
	b.book.HandDealt(others)
	b.machine.To(state.Playing, "table", b.table.Key, "hand", s.HandNo)
	if s.You.IsBlind && b.d.Config.Strategy.EnableSeen && strategy.LookEarly(b.persona, b.memory, s.Category, b.rand) {
		hand := s.HandNo
		b.sched.after(b.delay(timing.LookEarly, 0, 0.5, true, false, time.Time{}), "look", func() {
			v := b.view
			if v == nil || v.HandNo != hand || v.You == nil || !v.You.IsBlind || v.You.Status != protocol.SeatActive {
				return
			}
			b.send(protocol.ActionRequest{Action: protocol.ActionSee, ActionID: newActionID()}, "", "LOOK_EARLY")
		})
	}
}

// noticeHumans marks when a player who is not one of the fleet's bots was
// last at the table, and greets a newcomer now and then.
func (b *Bot) noticeHumans(s *protocol.RoomState) {
	for _, seat := range s.Seats {
		if seat.UserID == "" || seat.UserID == b.userID {
			continue
		}
		isBot := b.d.Fleet.IsBot(seat.UserID)
		if !isBot {
			b.lastHumanAt = b.now()
		}
		if !b.knownSeats[seat.UserID] {
			b.knownSeats[seat.UserID] = true
			if !isBot || b.rand.Chance(0.15) {
				b.say(interaction.Welcome, map[string]string{"name": firstName(seat.DisplayName)})
			}
		}
	}
}

// ---- the turn -----------------------------------------------------------------

// maybeAct decides this turn once and schedules the move after a human-like
// delay. A snapshot that repeats the same turn (same deadline) does nothing.
func (b *Bot) maybeAct(s *protocol.RoomState) {
	key := turnKeyOf(s)
	if key == b.turnKey {
		return
	}
	if key != b.lastTurnKey {
		b.lastTurnKey = key
		b.refusals = 0
	}
	b.turnKey = key
	b.turnSeq++
	seq := b.turnSeq

	// A move sent on this very turn whose acknowledgement the connection
	// took with it: resend it with the same action id. The server applies
	// it once (a copy it already has is refused as duplicate_action).
	if u := b.unacked; u != nil && u.turnKey == key {
		b.unacked = nil
		b.send(u.req, key, "RESEND_AFTER_RECONNECT")
		return
	}
	b.unacked = nil

	ctx := b.decisionContext(s)
	started := time.Now()
	d := strategy.Decide(ctx, b.rand)
	b.d.Metrics.DecisionLatency(time.Since(started))
	if d.Action == "" {
		// NO_LEGAL_MOVE (a sideshow the bot asked still waits for its
		// answer): decide again on the next snapshot, whatever its deadline.
		b.turnKey = ""
		return
	}
	deadline := time.Time{}
	if s.Turn != nil && s.Turn.Deadline != nil {
		deadline = time.UnixMilli(*s.Turn.Deadline)
	}
	if d.Action == protocol.ActionSee {
		b.sched.cancel("look")
	}
	wait := b.delay(kindFor(d, s.You.IsBlind, s.You.Options), d.Complexity, ctx.Hand.Strength, s.You.IsBlind, b.memory.RaisesFaced > 0, deadline)
	b.sched.after(wait, "turn", func() {
		if seq != b.turnSeq {
			return
		}
		v := b.view
		if v == nil || v.You == nil || v.You.Options == nil || turnKeyOf(v) != key {
			return
		}
		if !strategy.Legal(d, *v.You.Options) {
			d = strategy.Decide(b.decisionContext(v), b.rand)
			if d.Action == "" {
				return
			}
		}
		req := protocol.ActionRequest{Action: d.Action, ActionID: newActionID()}
		if d.Action == protocol.ActionChaal || d.Action == protocol.ActionRaise {
			amount := d.Amount
			req.Amount = &amount
		}
		b.noteDecision(d.Action, d.Reason, wait)
		b.log.Info("action", "table", b.table.Key, "hand", v.HandNo, "action", d.Action, "amount", d.Amount,
			"reason", d.Reason, "blind", v.You.IsBlind, "delay", wait.Round(time.Millisecond).String())
		b.send(req, key, d.Reason)
	})
}

// decisionContext is everything the turn's decision reads.
func (b *Bot) decisionContext(s *protocol.RoomState) strategy.DecisionContext {
	you := s.You
	variation := ""
	if s.Variation != nil && s.Variation.Selected != nil {
		variation = *s.Variation.Selected
	}
	active := 0
	blindOpp := 0
	opponents := make([]string, 0, len(s.Seats))
	for _, seat := range s.Seats {
		if seat.Status != protocol.SeatActive {
			continue
		}
		active++
		if seat.UserID != b.userID {
			opponents = append(opponents, seat.UserID)
			if seat.IsBlind {
				blindOpp++
			}
		}
	}
	reads := b.book.Summary(opponents)
	var opts protocol.TurnOptions
	if you.Options != nil {
		opts = *you.Options
	}
	return strategy.DecisionContext{
		Category:      s.Category,
		Variation:     variation,
		Options:       opts,
		IsBlind:       you.IsBlind,
		Hand:          decision.Evaluate(s.Category, variation, you),
		Pot:           s.Pot,
		Boot:          s.BootAmount,
		Chips:         you.Chips,
		Contribution:  you.Contributed,
		ActivePlayers: active,
		Pressure:      decision.NewPressure(b.memory.RaisesFaced, b.memory.BiggestRaiseFaced, s.BootAmount, reads.Aggression, reads.Looseness, blindOpp),
		Tilt:          b.tilt,
		Personality:   b.persona,
		Memory:        b.memory,
		EnableBlind:   b.d.Config.Strategy.EnableBlind,
		EnableSeen:    b.d.Config.Strategy.EnableSeen,
	}
}

// send makes a move and handles its acknowledgement.
func (b *Bot) send(req protocol.ActionRequest, key, reason string) {
	b.lastSent = &sentAction{turnKey: key, req: req}
	var ack protocol.ActionAck
	err := b.request(protocol.EvGameAction, req, &ack)
	if err != nil {
		if errors.Is(err, protocol.ErrClosed) {
			b.unacked = b.lastSent
		}
		return
	}
	blind := b.view != nil && b.view.You != nil && b.view.You.IsBlind
	if ack.OK || ack.Code == protocol.CodeDuplicateAction {
		b.d.Metrics.Action(req.Action, blind)
		b.afterMove(req)
		return
	}
	b.d.Metrics.Refused(ack.Code)
	switch ack.Code {
	case protocol.CodeNotYourTurn, protocol.CodeNoHand, protocol.CodeNotInHand, protocol.CodeShowUnavailable,
		protocol.CodeSideshowPending, protocol.CodePickPending, protocol.CodeVariationPending, protocol.CodeRateLimited,
		protocol.CodeAlreadySeen:
		// A race the hand won (it moved on, or the cards were already turned
		// up), or a wait the server asks for: decide again from the next
		// snapshot.
		b.turnKey = ""
		b.redecide(key)
		return
	}
	b.log.Warn("move refused", "action", req.Action, "code", ack.Code, "reason", reason)
	b.refusals++
	b.turnKey = ""
	b.redecide(key)
}

// redecide looks at the turn again a moment after a refusal — by then the
// snapshot the refusal raced has usually arrived — and decides afresh. A
// second refusal on the same turn packs where it can, so a bot whose idea of
// the rules has drifted never sits out the clock.
func (b *Bot) redecide(key string) {
	b.sched.after(time.Duration(b.rand.Between(250, 600)*float64(time.Millisecond)), "turn", func() {
		v := b.view
		if v == nil || v.You == nil || v.You.Options == nil || turnKeyOf(v) != key || b.turnKey != "" {
			return
		}
		if b.refusals >= 2 {
			if v.You.Options.CanPack {
				b.turnKey = key
				b.send(protocol.ActionRequest{Action: protocol.ActionPack, ActionID: newActionID()}, key, "REFUSED_TWICE_PACK")
			}
			return
		}
		b.maybeAct(v)
	})
}

// afterMove updates the hand's memory and, now and then, says something.
func (b *Bot) afterMove(req protocol.ActionRequest) {
	switch req.Action {
	case protocol.ActionSee, protocol.ActionSideshow:
		// Neither uses the turn: a look brings the cards, a sideshow ask
		// waits for its answer (declined, the turn is the bot's again). The
		// next snapshot decides afresh.
		b.turnKey = ""
		return
	case protocol.ActionRaise:
		b.memory.RaisedThisHand++
		if b.view != nil && b.view.You != nil && b.view.You.IsBlind {
			b.say(interaction.PlayingBlind, nil)
		} else if ev := b.lastEvaluation(); ev.Known && ev.Strength > 0.93 {
			b.say(interaction.StrongHand, nil)
		}
	case protocol.ActionPack:
		b.packed = true
		b.session.Folds++
		b.say(interaction.Packed, nil)
	}
	b.memory.RaisesFaced = 0
	b.memory.BiggestRaiseFaced = 0
}

func (b *Bot) lastEvaluation() decision.HandEvaluation {
	if b.view == nil || b.view.You == nil {
		return decision.HandEvaluation{}
	}
	variation := ""
	if b.view.Variation != nil && b.view.Variation.Selected != nil {
		variation = *b.view.Variation.Selected
	}
	return decision.Evaluate(b.view.Category, variation, b.view.You)
}

func (b *Bot) invalidateTurn() {
	b.turnSeq++
	b.turnKey = ""
	b.sched.cancel("turn")
}

// onAction is somebody's move: the opponent model, and the pressure this
// hand puts on the bot.
func (b *Bot) onAction(a protocol.ActionEvent) {
	if a.UserID == "" || a.UserID == b.userID {
		return
	}
	blind := false
	if b.view != nil {
		for _, seat := range b.view.Seats {
			if seat.UserID == a.UserID {
				blind = seat.IsBlind
			}
		}
	}
	b.book.Observe(a, blind)
	if a.Action == protocol.ActionRaise && b.memory != nil {
		b.memory.RaisesFaced++
		if a.Amount > b.memory.BiggestRaiseFaced {
			b.memory.BiggestRaiseFaced = a.Amount
		}
		if b.table.Boot > 0 && a.Amount >= b.table.Boot*16 {
			b.say(interaction.BigRaise, nil)
		}
	}
}

// ---- sideshows, variations, 5-Card picks ------------------------------------

func (b *Bot) answerSideshow(expiresAt int64) {
	key := fmt.Sprintf("sideshow:%d", expiresAt)
	if b.answered[key] || b.view == nil || b.view.You == nil {
		return
	}
	b.answered[key] = true
	answer, accept := strategy.SideshowAnswer(b.decisionContext(b.view), b.rand)
	if !answer {
		return // let it lapse, as a player who did not notice
	}
	deadline := time.UnixMilli(expiresAt)
	wait := b.delay(timing.AnswerSideshow, 0.4, 0.5, false, false, deadline)
	b.sched.after(wait, "sideshow", func() {
		var ack protocol.Ack
		_ = b.request(protocol.EvGameSideshowRespond, map[string]any{"accept": accept}, &ack)
		if !ack.OK && ack.Code != "" {
			b.d.Metrics.Refused(ack.Code)
		}
	})
}

func (b *Bot) onSideshowResolved(r protocol.SideshowResolved) {
	if r.FromUserID == b.userID {
		b.turnKey = "" // the asker's turn resumes: decide again
	}
	if !r.Accepted || r.PackedUserID == nil || (r.FromUserID != b.userID && r.ToUserID != b.userID) {
		return
	}
	if *r.PackedUserID == b.userID {
		b.say(interaction.SideshowLost, nil)
	} else {
		b.say(interaction.SideshowWon, nil)
	}
}

// maybeChooseVariation answers a variation window this bot holds, from the
// options the server offered this hand.
func (b *Bot) maybeChooseVariation(s *protocol.RoomState) {
	w := s.Variation
	if w == nil || !w.Selecting || w.UserID != b.userID || b.answered["variation"] {
		return
	}
	b.answered["variation"] = true
	choice, ok := strategy.ChooseVariation(w.Options, b.persona, b.rand)
	if !ok {
		return // lapse: the server chooses Muflis
	}
	deadline := time.Time{}
	if w.Deadline != nil {
		deadline = time.UnixMilli(*w.Deadline)
	}
	hand := s.HandNo
	b.sched.after(b.delay(timing.PickVariation, 0.5, 0.5, false, false, deadline), "variation", func() {
		v := b.view
		if v == nil || v.HandNo != hand || v.Variation == nil || !v.Variation.Selecting {
			return
		}
		var ack protocol.Ack
		_ = b.request(protocol.EvGameSelectVariation, map[string]any{"variation": choice}, &ack)
		if !ack.OK && ack.Code != "" {
			b.d.Metrics.Refused(ack.Code)
		} else {
			b.log.Info("variation chosen", "variation", choice, "hand", hand)
		}
	})
}

// noticeVariation: now and then a word once the hand's variation is
// announced (never naming it — the announcement is on the felt already).
func (b *Bot) noticeVariation(s *protocol.RoomState) {
	if s.Variation == nil || s.Variation.Selected == nil || b.answered["variation_said"] {
		return
	}
	b.answered["variation_said"] = true
	if *s.Variation.Selected == protocol.VariationFiveCard {
		b.say(interaction.FiveCard, nil)
		return
	}
	b.say(interaction.Variation, nil)
}

// maybePickCards chooses which three of five play under 5-Card Teen Patti.
func (b *Bot) maybePickCards(s *protocol.RoomState) {
	h := s.You.Hand
	if h == nil || !h.Picking || len(s.You.Cards) < 4 || b.answered["pick"] {
		return
	}
	b.answered["pick"] = true
	played := strategy.ChoosePlayedCards(s.You.Cards, b.persona, b.rand)
	if len(played) != 3 {
		return // lapse: the first three dealt play
	}
	deadline := time.Time{}
	if h.PickDeadline > 0 {
		deadline = time.UnixMilli(h.PickDeadline)
	}
	hand := s.HandNo
	b.sched.after(b.delay(timing.PickCards, 0.6, 0.5, false, false, deadline), "pick", func() {
		v := b.view
		if v == nil || v.HandNo != hand || v.You == nil || v.You.Hand == nil || !v.You.Hand.Picking {
			return
		}
		var ack protocol.Ack
		_ = b.request(protocol.EvGameSelectCards, map[string]any{"cards": played}, &ack)
		if !ack.OK && ack.Code != "" {
			b.d.Metrics.Refused(ack.Code)
		}
	})
}

// ---- the end of a hand ------------------------------------------------------

func (b *Bot) handInProgress() bool {
	return b.view != nil && b.view.State == protocol.TableBetting && b.inHand && !b.packed
}

// onHandEnded settles what the hand meant and decides what comes next
// (brief §18): stay, switch, hop, or end the session.
func (b *Bot) onHandEnded(h protocol.HandEnded) {
	b.invalidateTurn()
	b.sched.cancel("look")
	b.lastHandAt = b.now()
	played := b.inHand
	won := h.WinnerID != nil && *h.WinnerID == b.userID
	result := ""
	if played {
		b.machine.To(state.ProcessingResult, "table", b.table.Key, "hand", h.HandNo)
		switch {
		case won:
			result = "win"
			b.session.Wins++
			if gain := h.Pot - b.contributed; gain > b.session.BiggestWin {
				b.session.BiggestWin = gain
			}
		case b.packed:
			result = "fold"
			b.session.Losses++
		default:
			result = "loss"
			b.session.Losses++
		}
		b.d.Metrics.HandCompleted(b.table.Category, result)
	}
	b.book.Showdown(h.Reveals)
	// A big loss stings for a few hands.
	net := -b.contributed
	if won {
		net = h.Pot - b.contributed
	}
	if played && b.table.Boot > 0 && net <= -b.table.Boot*10 {
		b.tilt = min(1, b.tilt*0.7+0.35)
	} else {
		b.tilt *= 0.7
	}
	if played {
		b.reactToResult(h, won, net)
	}
	b.inHand = false
	b.packed = false
	b.contributed = 0

	nextHandAt := time.UnixMilli(h.NextHandAt)
	if h.NextHandAt == 0 {
		nextHandAt = b.now().Add(4 * time.Second)
	}
	if b.endAfterHand != "" {
		reason := b.endAfterHand
		b.endAfterHand = ""
		then := outEnded
		if reason == "stopping" {
			then = outStopped
		}
		b.leaveSoon(nextHandAt, reason, true, then)
		return
	}
	if !played {
		return
	}
	b.decideNext(nextHandAt)
}

// reactToResult: now and then, a word about the hand.
func (b *Bot) reactToResult(h protocol.HandEnded, won bool, net int64) {
	big := b.table.Boot > 0 && h.Pot >= b.table.Boot*12
	if won {
		if big {
			b.say(interaction.BigWin, nil)
		} else {
			b.say(interaction.Win, nil)
		}
		return
	}
	name := ""
	if h.WinnerName != nil {
		name = firstName(*h.WinnerName)
	}
	for _, r := range h.Reveals {
		if h.WinnerID != nil && r.UserID == *h.WinnerID && r.Category >= protocol.HandPureSequence {
			b.say(interaction.NiceHand, map[string]string{"name": name})
			return
		}
	}
	if big && net < 0 {
		b.say(interaction.BigLoss, nil)
		return
	}
	b.say(interaction.Loss, nil)
}

// decideNext is the switcher's call after a hand the bot played.
func (b *Bot) decideNext(nextHandAt time.Time) {
	menu := b.d.Finder.Menu()
	players, bots := 0, 0
	if b.view != nil {
		for _, seat := range b.view.Seats {
			if seat.UserID == "" {
				continue
			}
			players++
			if seat.UserID == b.userID || b.d.Fleet.IsBot(seat.UserID) {
				bots++
			}
		}
	}
	sinceHuman := time.Duration(0)
	if players > bots {
		sinceHuman = 0
	} else if b.lastHumanAt.IsZero() {
		sinceHuman = b.now().Sub(b.joinedAt)
	} else {
		sinceHuman = b.now().Sub(b.lastHumanAt)
	}
	in := table.SwitchInput{
		Personality:     b.persona,
		Current:         b.table,
		Menu:            menu,
		Chips:           b.chips,
		HandsAtTable:    b.session.TableHands,
		PlannedHands:    b.plannedHands,
		MinHands:        b.d.Config.Table.MinHands,
		MaxHands:        b.d.Config.Table.MaxHands,
		TableNet:        b.session.TableNet(),
		Players:         players,
		FleetBots:       bots,
		SinceHuman:      sinceHuman,
		SessionOver:     b.now().After(b.session.PlannedEnd),
		MaxBotsHere:     b.d.Config.Table.MaxBotsPerTable,
		NoHumanPatience: b.d.Config.Table.NoHumanPatience,
		BootsToSit:      b.d.Config.Table.BootsToSit,
		Idle:            b.now().Sub(maxTime(b.lastHandAt, b.joinedAt)),
	}
	d := table.AfterHand(in, b.rand)
	if d.Reason == "SHORT_STACK" {
		b.say(interaction.LowChips, nil)
	}
	switch d.Move {
	case table.Stay:
		b.machine.To(state.WaitingForHand, "table", b.table.Key)
	case table.SwitchSame:
		if d.Reason == "TABLE_EMPTYING" {
			maxPlayers := 5
			if b.view != nil && b.view.MaxPlayers > 0 {
				maxPlayers = b.view.MaxPlayers
			}
			if !b.d.Fleet.BusierTable(b.table.Key, b.roomID, players+1, maxPlayers) {
				// Nowhere busier to go: a quick-join would only seat the
				// bot back here. A heads-up game is a game; stay.
				b.machine.To(state.WaitingForHand, "table", b.table.Key)
				return
			}
			// room:switch would seat the bot at the EMPTIEST table of this
			// stake; a quick-join at the same stake seats it at the fullest
			// with room, which is what leaving an emptying table is for.
			b.log.Info("table emptying, re-queueing at this stake", "hands", b.session.TableHands)
			b.leaveSoon(nextHandAt, "table_emptying", false, outRequeue)
			return
		}
		b.log.Info("switching table", "reason", d.Reason, "hands", b.session.TableHands)
		wait := b.leaveDelay(nextHandAt)
		b.sched.after(wait, "move", func() { b.switchTable(d.Reason) })
	case table.Hop:
		b.log.Info("leaving for another table", "reason", d.Reason, "hands", b.session.TableHands)
		b.exclude = append(b.exclude[:0], b.table.Key)
		b.leaveSoon(nextHandAt, strings.ToLower(d.Reason), true, outNone)
	case table.EndSession:
		b.log.Info("ending session", "reason", d.Reason)
		b.leaveSoon(nextHandAt, strings.ToLower(d.Reason), true, outEnded)
	}
}

// leaveDelay is how long to wait before getting up: a human beat, but always
// before the next deal (a bot still seated then is dealt in, and leaving
// would pack that boot away).
func (b *Bot) leaveDelay(nextHandAt time.Time) time.Duration {
	wait := b.delay(timing.LeaveTable, 0.2, 0.5, false, false, nextHandAt)
	if room := nextHandAt.Sub(b.now()) - 900*time.Millisecond; wait > room {
		wait = max(room, 150*time.Millisecond)
	}
	return wait
}

// leaveSoon gets up before the next deal, with a goodbye now and then.
func (b *Bot) leaveSoon(nextHandAt time.Time, reason string, farewell bool, then outcome) {
	if farewell {
		b.say(interaction.Leave, nil)
	}
	b.sched.after(b.leaveDelay(nextHandAt), "move", func() { b.leaveThen(reason, false, then) })
}

// ---- leaving, searching, joining, switching ----------------------------------

// leaveThen leaves the table (room:leave) and then either looks for another
// (then == outNone) or ends the loop with then.
func (b *Bot) leaveThen(reason string, farewell bool, then outcome) {
	if farewell {
		b.say(interaction.Leave, nil)
	}
	if b.seated {
		b.machine.To(state.LeavingTable, "table", b.table.Key, "reason", reason)
		var ack protocol.Ack
		_ = b.request(protocol.EvRoomLeave, map[string]any{}, &ack)
		b.seated = false
		b.d.Fleet.Unseat(b.userID)
		b.invalidateTurn()
		b.d.Metrics.TableLeave(reason)
		b.log.Info("left table", "table", b.table.Key, "reason", reason, "hands", b.session.TableHands, "net", b.session.TableNet())
	}
	b.roomID = ""
	b.view = nil
	b.afterLeaving(then)
}

func (b *Bot) afterLeaving(then outcome) {
	if then == outRequeue {
		// Back into the queue at the same stake (the table's key stays
		// allowed), after the usual short beat.
		b.exclude = b.exclude[:0]
		b.sched.after(time.Duration(b.rand.Between(1.2, 3.5)*float64(time.Second)), "search", func() { b.joinSame() })
		b.machine.To(state.SearchingTable)
		return
	}
	if then != outNone {
		b.outcome = then
		return
	}
	if b.stopping {
		b.outcome = outStopped
		return
	}
	if b.now().After(b.session.PlannedEnd) {
		b.outcome = outEnded
		return
	}
	b.search(true)
}

// search looks for a table after a natural idle gap (brief §5: 2.5–8 s).
func (b *Bot) search(idle bool) {
	b.machine.To(state.SearchingTable)
	wait := time.Duration(b.rand.Between(0.8, 2.0) * float64(time.Second))
	if idle {
		lo, hi := b.d.Config.Table.SearchDelay[0], b.d.Config.Table.SearchDelay[1]
		if hi <= lo {
			hi = lo + time.Second
		}
		wait = time.Duration(b.rand.LogNormal(float64(lo+hi)/2, 0.35))
		wait = min(max(wait, lo), hi)
	}
	b.sched.after(wait, "search", func() { b.joinSomewhere(0) })
}

// joinSomewhere picks a table and asks for a seat, handling the refusals a
// stack or a changed menu earns.
func (b *Bot) joinSomewhere(attempt int) {
	if b.seated || b.outcome != outNone {
		return
	}
	menu := b.d.Finder.Menu()
	if len(menu.Tables) == 0 {
		ctx, cancel := context.WithTimeout(b.ctx, 5*time.Second)
		_ = b.d.Finder.Refresh(ctx)
		cancel()
		menu = b.d.Finder.Menu()
	}
	in := table.SelectInput{
		Chips:           b.chips,
		Personality:     b.persona,
		BootsToSit:      b.d.Config.Table.BootsToSit,
		CategoryWeights: b.d.Config.Table.CategoryWeights,
		Recent:          b.recent,
		Exclude:         b.exclude,
		Occupancy:       b.d.Fleet.Occupancy(),
		Only:            b.d.Config.Table.LobbyTables,
		Held:            b.d.Fleet.Held(b.now()),
		Floor:           b.d.Config.Table.FleetPerTable[0],
		Ceiling:         b.d.Config.Table.FleetPerTable[1],
	}
	choice, ok := table.Select(menu, in, b.rand)
	if !ok && table.FullOfFleet(menu, in) {
		// Every table this stack could sit at already holds its share of the
		// fleet (config table.fleet_per_table): nothing is wrong, the fleet is
		// big enough there. Rest, and look again next session.
		b.log.Info("every table holds its share of the fleet; resting", "chips", b.chips)
		b.outcome = outEnded
		return
	}
	if !ok {
		// Nothing this stack may sit at: rest and try again later (brief
		// §20). The lobby has no reward to collect first — the game server
		// removed the daily, 4-hour and milestone rewards (30 Sep 2026).
		if b.d.Config.Bankroll.DevReplenish && b.d.Config.Mode == "simulation" {
			// Simulation only (config refuses it against a server): a broke
			// bot comes back as a fresh account with its welcome.
			b.log.Info("broke: replenishing with a fresh simulated account", "chips", b.chips)
			b.replenish = true
			b.outcome = outEnded
			return
		}
		b.log.Warn("no table admits this stack; resting", "chips", b.chips)
		b.outcome = outEnded
		return
	}
	// Take the place before asking for it: bots choosing at the same moment
	// must not all fill a table's last places (config table.fleet_per_table).
	if !b.d.Fleet.ClaimTable(b.userID, choice.Key, b.d.Config.Table.FleetPerTable[1], b.now()) {
		if attempt >= 8 {
			b.outcome = outEnded
			return
		}
		b.sched.after(time.Duration(b.rand.Between(0.5, 1.5)*float64(time.Second)), "search", func() { b.joinSomewhere(attempt + 1) })
		return
	}
	b.table = choice
	b.machine.To(state.JoiningTable, "table", choice.Key)
	var ack protocol.RoomAck
	if err := b.request(protocol.EvRoomQuickJoin, map[string]any{"bootAmount": choice.Boot, "category": choice.Category}, &ack); err != nil {
		b.d.Fleet.ReleaseClaim(b.userID)
		return
	}
	b.exclude = b.exclude[:0]
	if ack.OK {
		return // room:joined carries the table, and Fleet.Seat settles the claim
	}
	b.d.Fleet.ReleaseClaim(b.userID)
	b.d.Metrics.Refused(ack.Code)
	retry := func(d time.Duration) {
		if attempt >= 8 {
			b.log.Warn("could not sit after several tries; resting", "code", ack.Code)
			b.outcome = outEnded
			return
		}
		b.sched.after(d, "search", func() { b.joinSomewhere(attempt + 1) })
	}
	switch ack.Code {
	case protocol.CodeTableNotOffered:
		b.d.Finder.Retire(choice.Key)
		retry(time.Second)
	case protocol.CodeOverEntryCap, protocol.CodeBelowTableMinimum, protocol.CodeInvalidStake:
		b.exclude = append(b.exclude, choice.Key)
		retry(time.Duration(b.rand.Between(1, 2.5) * float64(time.Second)))
	case protocol.CodeInsufficientChips:
		b.exclude = append(b.exclude, choice.Key)
		retry(time.Duration(b.rand.Between(1, 2.5) * float64(time.Second)))
	case protocol.CodeAlreadyInRoom:
		// The server still holds a seat (a reconnect's room:joined will
		// arrive, or the seat is from before a restart): give it a moment,
		// then leave it and look again.
		b.sched.after(3*time.Second, "search", func() {
			if b.seated {
				return
			}
			var leave protocol.Ack
			_ = b.request(protocol.EvRoomLeave, map[string]any{}, &leave)
			b.joinSomewhere(attempt + 1)
		})
	case protocol.CodeSettlementPending, protocol.CodeTableFull, protocol.CodeRateLimited:
		retry(time.Duration(b.rand.Between(3, 7) * float64(time.Second)))
	default:
		b.log.Warn("join refused", "table", choice.Key, "code", ack.Code, "message", ack.Message)
		retry(time.Duration(b.rand.Between(4, 9) * float64(time.Second)))
	}
}

// joinSame asks for a seat at the table kind the bot just left (a
// quick-join seats it at the fullest table of that kind with room), or looks
// afresh when that kind is no longer on the menu.
func (b *Bot) joinSame() {
	if b.seated || b.outcome != outNone {
		return
	}
	c, ok := b.d.Finder.Menu().Lookup(b.table.Key)
	if !ok || !b.d.Finder.Menu().Admits(c, b.chips) || !b.playsTable(c.Key) {
		b.joinSomewhere(0)
		return
	}
	// The same kind again only while it has room for the fleet.
	if !b.d.Fleet.ClaimTable(b.userID, c.Key, b.d.Config.Table.FleetPerTable[1], b.now()) {
		b.joinSomewhere(0)
		return
	}
	b.machine.To(state.JoiningTable, "table", c.Key)
	var ack protocol.RoomAck
	if err := b.request(protocol.EvRoomQuickJoin, map[string]any{"bootAmount": c.Boot, "category": c.Category}, &ack); err != nil {
		b.d.Fleet.ReleaseClaim(b.userID)
		return
	}
	if !ack.OK {
		b.d.Fleet.ReleaseClaim(b.userID)
		b.d.Metrics.Refused(ack.Code)
		b.joinSomewhere(0)
	}
}

// playsTable reports whether the fleet plays lobby table key (config
// table.lobby_tables; an empty list plays every table).
func (b *Bot) playsTable(key string) bool {
	only := b.d.Config.Table.LobbyTables
	return len(only) == 0 || slices.Contains(only, key)
}

// switchTable moves to another table of the same category and boot
// (room:switch: the server picks the quietest, or opens a new one).
func (b *Bot) switchTable(reason string) {
	if !b.seated || b.handInProgress() {
		return
	}
	b.machine.To(state.SwitchingTable, "table", b.table.Key, "reason", reason)
	var ack protocol.RoomAck
	if err := b.request(protocol.EvRoomSwitch, map[string]any{}, &ack); err != nil {
		return
	}
	if ack.OK {
		b.d.Metrics.TableLeave("switch")
		return // room:joined for the new table follows
	}
	b.d.Metrics.Refused(ack.Code)
	switch ack.Code {
	case protocol.CodeInsufficientChips:
		b.exclude = append(b.exclude[:0], b.table.Key)
		b.leaveThen("low_chips", false, outNone)
	default:
		// no_other_table and the like: stay where it is.
		b.machine.To(state.WaitingForHand, "table", b.table.Key)
	}
}

// ---- chat ---------------------------------------------------------------------

// onChat: people talk back — to a hello, and when their name comes up.
func (b *Bot) onChat(m protocol.ChatMessage) {
	if m.System || m.UserID == nil || *m.UserID == b.userID || !b.seated {
		return
	}
	isBot := b.d.Fleet.IsBot(*m.UserID)
	if !isBot {
		b.lastHumanAt = b.now()
	}
	if isBot && !b.rand.Chance(0.1) {
		return // bots rarely answer bots
	}
	lower := strings.ToLower(m.Text)
	if name := strings.ToLower(firstName(b.id.Name)); len(name) >= 3 && strings.Contains(lower, name) {
		b.say(interaction.ReplyName, nil)
		return
	}
	for _, w := range strings.FieldsFunc(lower, func(r rune) bool { return !unicode.IsLetter(r) }) {
		switch w {
		case "hi", "hii", "hiii", "hello", "hey", "namaste", "hlo":
			b.say(interaction.ReplyHi, nil)
			return
		}
	}
}

// say sends a line now and then: the Chatter decides whether (most calls
// say nothing), and the timing model when.
func (b *Bot) say(m interaction.Moment, vars map[string]string) {
	if !b.seated || b.roomID == "" {
		return
	}
	line, ok := b.chat.Maybe(m, b.roomID, vars, b.now())
	if !ok {
		return
	}
	room := b.roomID
	b.sched.after(b.delay(timing.Chat, 0.1, 0.5, false, false, time.Time{}), "chat", func() {
		if !b.seated || b.roomID != room || b.sess == nil {
			return
		}
		ctx, cancel := context.WithTimeout(b.ctx, 3*time.Second)
		defer cancel()
		if err := b.sess.Emit(ctx, protocol.EvChatMessage, map[string]any{"text": line}); err == nil {
			b.d.Metrics.Chat(string(m))
		}
	})
}

// ---- helpers ------------------------------------------------------------------

// request is an acknowledged request on the current connection.
func (b *Bot) request(event string, payload, ack any) error {
	if b.sess == nil {
		return protocol.ErrClosed
	}
	ctx, cancel := context.WithTimeout(b.ctx, requestTimeout)
	defer cancel()
	err := b.sess.Request(ctx, event, payload, ack)
	if err != nil {
		b.noteError(err)
		if errors.Is(err, protocol.ErrClosed) && b.outcome == outNone {
			b.outcome = outLost
		}
		b.log.Warn("request failed", "event", event, "err", err)
	}
	return err
}

// delay is a human-like wait for kind, never past deadline's margin.
func (b *Bot) delay(kind timing.Kind, complexity, strength float64, blind, facedRaise bool, deadline time.Time) time.Duration {
	d := b.d.Delay.For(timing.Context{
		Kind:       kind,
		Pace:       b.persona.Pace,
		Distracted: b.persona.Distracted,
		Complexity: complexity,
		Strength:   strength,
		IsBlind:    blind,
		FacedRaise: facedRaise,
		Now:        b.now(),
		Deadline:   deadline,
	}, b.rand)
	b.d.Metrics.ReactionDelay(string(kind), d)
	return d
}

// kindFor maps a decision to its timing kind.
func kindFor(d strategy.Decision, blind bool, o *protocol.TurnOptions) timing.Kind {
	switch d.Action {
	case protocol.ActionSee:
		return timing.See
	case protocol.ActionPack:
		return timing.Fold
	case protocol.ActionShow:
		return timing.Show
	case protocol.ActionSideshow:
		return timing.Sideshow
	case protocol.ActionRaise:
		if o != nil && len(o.RaiseSteps) > 2 && d.Amount >= o.RaiseSteps[2] {
			return timing.LargeRaise
		}
		return timing.SmallRaise
	case protocol.ActionChaal:
		if d.Complexity > 0.65 {
			return timing.Difficult
		}
		if blind {
			return timing.BlindChaal
		}
		return timing.Chaal
	}
	return timing.Difficult
}

// turnKeyOf identifies one turn: the hand and the turn's deadline (a new
// turn always has a new deadline).
func turnKeyOf(s *protocol.RoomState) string {
	deadline := int64(0)
	if s.Turn != nil && s.Turn.Deadline != nil {
		deadline = *s.Turn.Deadline
	}
	return fmt.Sprintf("%s:%d:%d", s.RoomID, s.HandNo, deadline)
}

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

// firstName is the display name's first word, letters only.
func firstName(name string) string {
	fields := strings.FieldsFunc(name, func(r rune) bool { return !unicode.IsLetter(r) })
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}
