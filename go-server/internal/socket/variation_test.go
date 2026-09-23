package socket

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// Variation Teen Patti on the WIRE (Go only; owner, 18 Sep 2026). What the
// window IS — who may choose, what each variation makes of a hand, the race
// between a pick and the clock, a restart mid-window — is proved on the Table
// in game/table_variation_test.go and game/variation_test.go. These prove what
// a client can observe through a real socket: the two room events and their
// order, the `variation` block of room:state (the only thing a reconnecting
// client has), the ack and the refusal reported twice, and that a seen or blind
// table's traffic has not gained so much as a key.

// variationFixture is a variation table whose first hand has been dealt and
// whose window is still open.
type variationFixture struct {
	boot    int64
	table   *game.Table
	roomID  string
	players []*player
	chooser *player
	// others are the players the window is NOT open for, in joining order.
	others []*player
	// dealt is each client's event mark from before anybody sat down, so a test
	// can read the deal's own traffic in order.
	dealt map[*player]int
	// states is the room:state that told each player the window was open.
	states map[*player]json.RawMessage
}

// selecting is the predicate for "a snapshot whose window is open".
func selecting(raw json.RawMessage) bool { return field(raw, "variation.selecting") == true }

// selected is the predicate for "a snapshot whose window closed on v".
func selected(v game.Variation) func(json.RawMessage) bool {
	return func(raw json.RawMessage) bool {
		return field(raw, "variation.selecting") == false && str(raw, "variation.selected") == string(v)
	}
}

// variationTable quick-joins n players to a variation table of their own and
// waits for the deal. It must NOT wait the way dealtTable and forcedTable do —
// for state "betting" and then a turn — because a variation hand is dealt with
// nobody on turn: it waits for the snapshot that says the window is open.
func (st *stack) variationTable(n int) *variationFixture {
	st.t.Helper()
	f := &variationFixture{boot: st.uniqueStake(), dealt: map[*player]int{}, states: map[*player]json.RawMessage{}}
	for i := 0; i < n; i++ {
		f.players = append(f.players, st.player("V"+string(rune('1'+i))))
	}
	for _, p := range f.players {
		f.dealt[p] = p.c.Mark()
		ack := st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": f.boot, "category": "variation"})
		// An OLD server seats this request at a seen table with ok:true (an
		// unknown category is silently seen); the ack is how a client tells.
		if str(ack.Raw, "category") != "variation" {
			st.t.Fatalf("quickJoin {category: variation} was seated at %s", ack.Raw)
		}
		f.roomID = str(ack.Raw, "roomId")
	}
	if _, err := f.players[0].c.Wait(EvGameHandStarted, func(raw json.RawMessage) bool {
		var e struct{ Participants []string }
		return json.Unmarshal(raw, &e) == nil && len(e.Participants) == n
	}, eventTimeout); err != nil {
		st.t.Fatalf("no %d-player hand: %v", n, err)
	}
	for _, p := range f.players {
		state, err := p.c.Wait(EvRoomState, selecting, eventTimeout)
		if err != nil {
			st.t.Fatalf("%s got no snapshot with the window open: %v", p.user.DisplayName, err)
		}
		f.states[p] = state
	}
	f.table = game.AsTable(st.rooms.GetTable(f.roomID))
	if f.table == nil {
		st.t.Fatalf("table %s not found", f.roomID)
	}
	chooserID := str(f.states[f.players[0]], "variation.userId")
	for _, p := range f.players {
		if p.user.ID == chooserID {
			f.chooser = p
		} else {
			f.others = append(f.others, p)
		}
	}
	if f.chooser == nil {
		st.t.Fatalf("the chooser %q is nobody at the table", chooserID)
	}
	return f
}

// marks takes every player's event mark.
func (f *variationFixture) marks() map[*player]int {
	out := map[*player]int{}
	for _, p := range f.players {
		out[p] = p.c.Mark()
	}
	return out
}

// windowOpen asserts the Table still has its window open for the chooser.
func (f *variationFixture) windowOpen(st *stack, after string) {
	st.t.Helper()
	v := st.view(f.table, f.chooser.user.ID).Variation
	if v == nil || !v.Selecting || v.Selected != nil || v.UserID != f.chooser.user.ID {
		st.t.Fatalf("the window did not survive %s: %+v", after, v)
	}
}

// refusedTwice asserts a refusal reached the client both ways — the ack and
// the game:error echo every guarded refusal has (clients dedupe).
func refusedTwice(st *stack, c *testclient.Client, payload any, code, message string) {
	st.t.Helper()
	mark := c.Mark()
	ack := st.mustFail(c, EvGameSelectVariation, payload, code)
	if ack.Message != message {
		st.t.Fatalf("%s message %q, want %q", code, ack.Message, message)
	}
	raw, err := c.WaitFrom(mark, EvGameError, func(raw json.RawMessage) bool { return str(raw, "code") == code }, eventTimeout)
	if err != nil {
		st.t.Fatalf("the %s refusal is also emitted as game:error: %v", code, err)
	}
	if str(raw, "message") != message {
		st.t.Fatalf("game:error %s", raw)
	}
}

// The deal on a variation table: every client hears game:variationSelecting
// after game:handStarted and its own player:hand, and then the room:state that
// says the same thing — the same chooser and the same deadline to everybody,
// nobody on turn, no options for anyone. Nobody hears game:turn: the first turn
// does not exist yet.
func TestTheDealOpensTheVariationWindowToTheWholeRoom(t *testing.T) {
	st := newStack(t, nil)
	f := st.variationTable(3)

	want := f.states[f.chooser]
	deadline, startedAt := num(want, "variation.deadline"), num(want, "variation.startedAt")
	timeout := float64(st.cfg.Game.VariationSelectTimeout.Milliseconds())
	if timeout != 10000 {
		t.Fatalf("VARIATION_SELECT_TIMEOUT_MS defaults to %v, want 10000", timeout)
	}
	if deadline != startedAt+timeout {
		t.Fatalf("deadline %v is not startedAt %v + %v", deadline, startedAt, timeout)
	}
	if now := float64(time.Now().UnixMilli()); startedAt > now || startedAt < now-float64(eventTimeout.Milliseconds()) {
		t.Fatalf("startedAt %v is not an epoch-ms instant just past (now %v)", startedAt, now)
	}
	// Seven: 5-Card Teen Patti joined the end of the menu (owner, 18 Sep 2026).
	options := `["MUFLIS","AK47","JOKER","HUKAM","LOWEST_JOKER","HIGHEST_JOKER","FIVE_CARD"]`

	for _, p := range f.players {
		who := p.user.DisplayName
		state := f.states[p]
		var block map[string]json.RawMessage
		if err := json.Unmarshal(obj2(state)["variation"], &block); err != nil {
			t.Fatalf("%s: variation block: %s", who, state)
		}
		if len(block) != 11 {
			t.Fatalf("%s: an open window has exactly eleven keys (turnUp is not one of them): %s", who, obj2(state)["variation"])
		}
		if num(state, "variation.cardsPerPlayer") != 3 {
			t.Fatalf("%s: every hand is dealt three: %s", who, obj2(state)["variation"])
		}
		if str(state, "variation.userId") != f.chooser.user.ID || str(state, "variation.displayName") != f.chooser.user.DisplayName {
			t.Fatalf("%s was told of another chooser: %s", who, state)
		}
		if num(state, "variation.deadline") != deadline || num(state, "variation.startedAt") != startedAt || num(state, "variation.timeoutMs") != timeout {
			t.Fatalf("%s was told of another clock: %s", who, state)
		}
		if string(block["options"]) != options || string(block["selected"]) != "null" || string(block["selectedBy"]) != "null" {
			t.Fatalf("%s: options/selected/selectedBy: %s", who, obj2(state)["variation"])
		}
		if seat := seatOf(state, f.chooser.user.ID); seat == nil || seat["seatIndex"] != num(state, "variation.seatIndex") {
			t.Fatalf("%s: variation.seatIndex is not the chooser's seat: %s", who, state)
		}
		// Nobody is on turn — the chooser included.
		if str(state, "state") != "betting" || num(state, "turn.seatIndex") != -1 || !has(state, "turn.userId") || field(state, "turn.userId") != nil {
			t.Fatalf("%s: somebody is on turn while the variation is chosen: %s", who, state)
		}
		if !has(state, "you.options") || field(state, "you.options") != nil {
			t.Fatalf("%s was offered moves while the variation is chosen: %s", who, state)
		}

		// The event repeats the block, plus the room.
		ev, err := p.c.WaitFrom(f.dealt[p], EvGameVariationSelecting, nil, eventTimeout)
		if err != nil {
			t.Fatalf("%s heard no game:variationSelecting: %v", who, err)
		}
		var evBody map[string]json.RawMessage
		if err := json.Unmarshal(ev, &evBody); err != nil || len(evBody) != 8 {
			t.Fatalf("%s: game:variationSelecting has eight keys: %s", who, ev)
		}
		if str(ev, "userId") != f.chooser.user.ID || str(ev, "displayName") != f.chooser.user.DisplayName ||
			num(ev, "seatIndex") != num(state, "variation.seatIndex") || num(ev, "startedAt") != startedAt ||
			num(ev, "deadline") != deadline || num(ev, "timeoutMs") != timeout ||
			string(evBody["options"]) != options || str(ev, "roomId") != f.roomID {
			t.Fatalf("%s: game:variationSelecting %s disagrees with room:state %s", who, ev, obj2(state)["variation"])
		}

		// handStarted → player:hand → variationSelecting → room:state (selecting),
		// and no turn anywhere in the deal.
		evs := p.c.Since(f.dealt[p])
		started := indexOf(evs, EvGameHandStarted, nil)
		hand := indexOf(evs, EvPlayerHand, nil)
		announced := indexOf(evs, EvGameVariationSelecting, nil)
		snapshot := indexOf(evs, EvRoomState, selecting)
		if started < 0 || !(started < hand && hand < announced && announced < snapshot) {
			t.Fatalf("%s heard the deal out of order (handStarted %d, player:hand %d, variationSelecting %d, room:state %d): %v", who, started, hand, announced, snapshot, names(evs))
		}
		if indexOf(evs, EvGameTurn, nil) >= 0 || indexOf(evs, EvGameYourTurn, nil) >= 0 {
			t.Fatalf("%s heard a turn before the variation was chosen: %v", who, names(evs))
		}
		if n := len(p.c.All(EvGameVariationSelecting)); n != 1 {
			t.Fatalf("%s heard game:variationSelecting %d times", who, n)
		}
	}
	if v := metricValue(st.metrics.GamesStartedTotal.WithLabelValues("variation")); v != 1 {
		t.Fatalf("games_started_total{variation} = %v — the category is a label of its own, not `other`", v)
	}
}

// Only the chooser's game:selectVariation closes the window. Everybody else is
// refused not_selecting, twice over; while it is open no move but a look at
// one's own cards is taken; and when the chooser picks, the room hears
// game:variationSelected, then the chooser's turn, then the room:state that
// says both. A second pick — theirs or anyone's — is refused and changes
// nothing.
func TestOnlyTheChooserClosesTheWindowAndTheRoomHearsIt(t *testing.T) {
	st := newStack(t, nil)
	f := st.variationTable(3)

	for _, p := range f.others {
		refusedTwice(st, p.c, map[string]any{"variation": "AK47"}, game.CodeNotSelecting, game.MsgNotSelecting)
	}
	if v := metricValue(st.metrics.InvalidMovesTotal.WithLabelValues(game.CodeNotSelecting)); v != 2 {
		t.Fatalf("invalid_moves_total{not_selecting} = %v", v)
	}
	// A payload that NAMES the chooser is still the sender's own request: there
	// is no player id on this event to trust.
	st.mustFail(f.others[0].c, EvGameSelectVariation, map[string]any{"variation": "AK47", "userId": f.chooser.user.ID, "playerId": f.chooser.user.ID}, game.CodeNotSelecting)
	f.windowOpen(st, "other players' picks")

	// No move while the variation is being chosen — for the chooser, who will
	// be first to act, or for anybody else — except See, which is free and
	// off-turn everywhere and lets the chooser look before choosing.
	for _, p := range f.players {
		for _, action := range []string{"chaal", "raise", "pack", "show", "sideshow", "missile"} {
			ack := st.mustFail(p.c, EvGameAction, map[string]any{"action": action, "amount": 2 * f.boot}, game.CodeVariationPending)
			if ack.Message != game.MsgVariationPending {
				t.Fatalf("variation_pending message %q", ack.Message)
			}
		}
	}
	seen := st.mustOK(f.chooser.c, EvGameAction, map[string]any{"action": "see"})
	if str(seen.Raw, "action") != "see" {
		t.Fatalf("see ack %s", seen.Raw)
	}
	st.mustOK(f.others[0].c, EvGameAction, map[string]any{"action": "see"})
	f.windowOpen(st, "a look at one's own cards")
	if st.view(f.table, f.chooser.user.ID).You.IsBlind || len(st.view(f.table, f.chooser.user.ID).You.Cards) != 3 {
		t.Fatal("the chooser's See during the window did not show them their cards")
	}
	if v := metricValue(st.metrics.InvalidMovesTotal.WithLabelValues(game.CodeVariationPending)); v != 18 {
		t.Fatalf("invalid_moves_total{variation_pending} = %v", v)
	}

	marks := f.marks()
	ack := st.mustOK(f.chooser.c, EvGameSelectVariation, map[string]any{"variation": "AK47"})
	var body map[string]any
	if err := json.Unmarshal(ack.Raw, &body); err != nil {
		t.Fatal(err)
	}
	// AK47 is not decided by the turned-up card, so the ack has no turnUp.
	if len(body) != 4 || body["ok"] != true || body["variation"] != "AK47" || body["selectedBy"] != "PLAYER" ||
		body["cardsPerPlayer"] != float64(3) {
		t.Fatalf("ack %s", ack.Raw)
	}

	for _, p := range f.players {
		who := p.user.DisplayName
		ev, err := p.c.WaitFrom(marks[p], EvGameVariationSelected, nil, eventTimeout)
		if err != nil {
			t.Fatalf("%s heard no game:variationSelected: %v", who, err)
		}
		var evBody map[string]any
		if err := json.Unmarshal(ev, &evBody); err != nil || len(evBody) != 7 || evBody["cardsPerPlayer"] != float64(3) {
			t.Fatalf("%s: game:variationSelected has seven keys under AK47 (no turnUp): %s", who, ev)
		}
		if str(ev, "userId") != f.chooser.user.ID || str(ev, "displayName") != f.chooser.user.DisplayName ||
			num(ev, "seatIndex") != num(f.states[p], "variation.seatIndex") ||
			str(ev, "variation") != "AK47" || str(ev, "selectedBy") != "PLAYER" || str(ev, "roomId") != f.roomID {
			t.Fatalf("%s: game:variationSelected %s", who, ev)
		}
		state, err := p.c.WaitFrom(marks[p], EvRoomState, selected(game.VariationAK47), eventTimeout)
		if err != nil {
			t.Fatalf("%s got no snapshot with the choice in it: %v", who, err)
		}
		// The chooser stays the chooser; the clock the window ran on is still
		// there to be read; and the first turn is theirs.
		if str(state, "variation.selectedBy") != "PLAYER" || has(state, "variation.turnUp") ||
			str(state, "variation.userId") != f.chooser.user.ID || num(state, "variation.deadline") != num(f.states[p], "variation.deadline") {
			t.Fatalf("%s: closed window %s", who, obj2(state)["variation"])
		}
		if str(state, "turn.userId") != f.chooser.user.ID || num(state, "turn.seatIndex") != num(state, "variation.seatIndex") {
			t.Fatalf("%s: the chooser is not on turn after choosing: %s", who, state)
		}

		// variationSelected → game:turn → room:state (selected, turn set).
		evs := p.c.Since(marks[p])
		announced := indexOf(evs, EvGameVariationSelected, nil)
		turn := indexOf(evs, EvGameTurn, nil)
		snapshot := indexOf(evs, EvRoomState, selected(game.VariationAK47))
		if !(announced >= 0 && announced < turn && turn < snapshot) {
			t.Fatalf("%s heard the choice out of order (variationSelected %d, game:turn %d, room:state %d): %v", who, announced, turn, snapshot, names(evs))
		}
		turnEv := evs[turn].Payload
		// A fresh turn with a whole clock: choosing did not eat into it.
		if str(turnEv, "userId") != f.chooser.user.ID || num(turnEv, "timeoutMs") != float64(st.cfg.Game.TurnTimeout.Milliseconds()) {
			t.Fatalf("%s: game:turn %s", who, turnEv)
		}
		yours := indexOf(evs, EvGameYourTurn, nil)
		if (p == f.chooser) != (yours >= 0) {
			t.Fatalf("%s: game:yourTurn goes to the chooser alone: %v", who, names(evs))
		}
		if p == f.chooser && (yours < announced || field(state, "you.options") == nil) {
			t.Fatalf("the chooser's turn came without its options: %s", state)
		}
	}

	// (f) the window is closed for good.
	refusedTwice(st, f.chooser.c, map[string]any{"variation": "MUFLIS"}, game.CodeVariationAlreadySelected, game.MsgVariationAlreadySelected)
	refusedTwice(st, f.chooser.c, map[string]any{"variation": "AK47"}, game.CodeVariationAlreadySelected, game.MsgVariationAlreadySelected)
	st.mustFail(f.others[0].c, EvGameSelectVariation, map[string]any{"variation": "JOKER"}, game.CodeVariationAlreadySelected)
	st.mustFail(f.chooser.c, EvGameSelectVariation, map[string]any{"variation": 7}, game.CodeVariationAlreadySelected)
	if v := st.view(f.table, f.chooser.user.ID).Variation; v == nil || v.Selecting || v.Selected == nil || *v.Selected != game.VariationAK47 {
		t.Fatalf("a refused second pick changed the choice: %+v", v)
	}
	for _, p := range f.players {
		if n := len(p.c.All(EvGameVariationSelected)); n != 1 {
			t.Fatalf("%s heard game:variationSelected %d times", p.user.DisplayName, n)
		}
	}

	// And play is an ordinary seen table's from here.
	st.mustFail(f.others[0].c, EvGameAction, map[string]any{"action": "chaal", "amount": 2 * f.boot}, game.CodeNotYourTurn)
	st.mustOK(f.chooser.c, EvGameAction, map[string]any{"action": "chaal", "amount": 2 * f.boot, "actionId": "after-the-choice"})
}

// Anything but one of the six exact strings is invalid_variation — a missing
// field, null, a number, an array, an object, the right word in the wrong case,
// the menu's label instead of its value — and none of it closes the window or
// costs the chooser their choice.
func TestAnythingButTheSixExactNamesIsRefusedAndLeavesTheWindowOpen(t *testing.T) {
	st := newStack(t, nil)
	f := st.variationTable(2)

	garbage := []any{
		testclient.NoPayload{}, null(), 42, "AK47", []any{}, []any{"AK47"},
		map[string]any{},
		map[string]any{"variation": null()},
		map[string]any{"variation": 2},
		map[string]any{"variation": true},
		map[string]any{"variation": []any{"AK47"}},
		map[string]any{"variation": map[string]any{"variation": "AK47"}},
		map[string]any{"variation": ""},
		map[string]any{"variation": "muflis"},
		map[string]any{"variation": "Muflis"},
		map[string]any{"variation": "Lowest Joker"},
		map[string]any{"variation": "LOWEST-JOKER"},
		map[string]any{"variation": " AK47"},
		map[string]any{"variation": "AK47 "},
		map[string]any{"variation": "TIMEOUT"},
		map[string]any{"Variation": "AK47"},
		json.RawMessage(`{"__proto__":{"variation":"AK47"}}`),
	}
	for _, payload := range garbage {
		ack := st.mustFail(f.chooser.c, EvGameSelectVariation, payload, game.CodeInvalidVariation)
		if ack.Message != game.MsgInvalidVariation {
			t.Fatalf("%s: message %q", jsonOf(payload), ack.Message)
		}
		f.windowOpen(st, jsonOf(payload))
	}
	// guard acks first and echoes game:error after, so the last echo may still
	// be on the wire when the last ack has landed.
	eventually(t, 2*time.Second, func() bool {
		return len(f.chooser.c.All(EvGameError)) == len(garbage)
	}, "one game:error echo per refusal")
	if v := metricValue(st.metrics.InvalidMovesTotal.WithLabelValues(game.CodeInvalidVariation)); v != float64(len(garbage)) {
		t.Fatalf("invalid_moves_total{invalid_variation} = %v, want %d", v, len(garbage))
	}
	for _, p := range f.players {
		if n := len(p.c.All(EvGameVariationSelected)); n != 0 {
			t.Fatalf("%s heard a choice announced out of garbage", p.user.DisplayName)
		}
	}
	// Somebody else's garbage is judged on WHO first: the window is not theirs.
	st.mustFail(f.others[0].c, EvGameSelectVariation, map[string]any{"variation": 42}, game.CodeNotSelecting)

	// The chooser has lost nothing by it.
	ack := st.mustOK(f.chooser.c, EvGameSelectVariation, map[string]any{"variation": "LOWEST_JOKER"})
	if str(ack.Raw, "variation") != "LOWEST_JOKER" || str(ack.Raw, "selectedBy") != "PLAYER" || has(ack.Raw, "turnUp") {
		t.Fatalf("ack %s", ack.Raw)
	}
}

// A client that is at no table is told so — before any table is asked anything.
func TestAPlayerInTheLobbyCannotSelectAVariation(t *testing.T) {
	st := newStack(t, nil)
	f := st.variationTable(2)
	lobby := st.player("Lobby")
	for _, payload := range []any{map[string]any{"variation": "AK47"}, map[string]any{}, null()} {
		mark := lobby.c.Mark()
		ack := st.mustFail(lobby.c, EvGameSelectVariation, payload, game.CodeNotInRoom)
		if ack.Message != MsgNotAtTable {
			t.Fatalf("not_in_room message %q", ack.Message)
		}
		if _, err := lobby.c.WaitFrom(mark, EvGameError, func(raw json.RawMessage) bool { return str(raw, "code") == game.CodeNotInRoom }, eventTimeout); err != nil {
			t.Fatalf("the refusal is also emitted as game:error: %v", err)
		}
	}
	f.windowOpen(st, "a stranger's pick")

	// Having LEFT a variation table is the same thing.
	gone := f.others[0]
	st.mustOK(gone.c, EvRoomLeave, map[string]any{})
	st.mustFail(gone.c, EvGameSelectVariation, map[string]any{"variation": "AK47"}, game.CodeNotInRoom)
}

// Seen and blind tables are byte for byte what they were: no `variation` key in
// room:joined or room:state — absent, not null — no game:variationSelecting at
// the deal, a turn straight away, and nothing about a variation in the
// showdown. Asking such a table for a variation is refused no_variation.
func TestSeenAndBlindTablesCarryNoVariationAnywhere(t *testing.T) {
	for _, category := range []string{"seen", "blind"} {
		t.Run(category, func(t *testing.T) {
			st := newStack(t, nil)
			d := st.dealtTable(category)
			for _, p := range []*player{d.a, d.b} {
				for _, name := range []string{EvRoomJoined, EvRoomState} {
					all := p.c.All(name)
					if len(all) == 0 {
						t.Fatalf("%s got no %s", p.user.DisplayName, name)
					}
					for _, raw := range all {
						if has(raw, "variation") || strings.Contains(string(raw), "ariation") {
							t.Fatalf("a %s table's %s mentions a variation: %s", category, name, raw)
						}
					}
				}
				if len(p.c.All(EvGameVariationSelecting)) != 0 || len(p.c.All(EvGameVariationSelected)) != 0 {
					t.Fatalf("a %s table announced a variation window", category)
				}
				if _, ok := p.c.Last(EvGameTurn); !ok {
					t.Fatalf("a %s table's deal did not open with a turn", category)
				}
			}

			refusedTwice(st, d.onTurn.c, map[string]any{"variation": "AK47"}, game.CodeNoVariation, game.MsgNoVariation)
			refusedTwice(st, d.waiting.c, map[string]any{"variation": "AK47"}, game.CodeNoVariation, game.MsgNoVariation)
			// Not even garbage gets a different answer: there is no window to
			// judge it against.
			st.mustFail(d.onTurn.c, EvGameSelectVariation, map[string]any{"variation": 42}, game.CodeNoVariation)
			if !d.table.HasHand() || st.turnSeat(d.table, d.a.user.ID) < 0 {
				t.Fatal("the refused selection disturbed the hand")
			}

			marks := map[*player]int{d.a: d.a.c.Mark(), d.b: d.b.c.Mark()}
			st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "show"})
			for _, p := range []*player{d.a, d.b} {
				for _, name := range []string{EvGameShowdown, EvGameHandEnded} {
					raw, err := p.c.WaitFrom(marks[p], name, nil, eventTimeout)
					if err != nil {
						t.Fatalf("%s heard no %s: %v", p.user.DisplayName, name, err)
					}
					if has(raw, "variation") || has(raw, "turnUp") || strings.Contains(string(raw), `"wild"`) {
						t.Fatalf("a %s table's %s carries variation fields: %s", category, name, raw)
					}
				}
			}
		})
	}
}

// With nobody choosing, the SERVER chooses: when the window's clock runs out
// the room hears game:variationSelected {MUFLIS, TIMEOUT} — not before the
// deadline it advertised — and the player who did not choose still gets the
// first turn, with a whole clock. Their pick after that is too late.
func TestWhenTheWindowLapsesTheRoomHearsTheServerChooseMuflis(t *testing.T) {
	const window = 400 * time.Millisecond
	st := newStack(t, func(cfg *config.Config) { cfg.Game.VariationSelectTimeout = window })
	f := st.variationTable(3)
	deadline := int64(num(f.states[f.chooser], "variation.deadline"))
	if num(f.states[f.chooser], "variation.timeoutMs") != float64(window.Milliseconds()) {
		t.Fatalf("timeoutMs is the configured window: %s", f.states[f.chooser])
	}

	for _, p := range f.players {
		who := p.user.DisplayName
		ev, err := p.c.WaitFrom(f.dealt[p], EvGameVariationSelected, nil, eventTimeout)
		if err != nil {
			t.Fatalf("%s never heard the server choose: %v", who, err)
		}
		if str(ev, "variation") != "MUFLIS" || str(ev, "selectedBy") != "TIMEOUT" || has(ev, "turnUp") ||
			str(ev, "userId") != f.chooser.user.ID || str(ev, "displayName") != f.chooser.user.DisplayName || str(ev, "roomId") != f.roomID {
			t.Fatalf("%s: game:variationSelected %s", who, ev)
		}
		state, err := p.c.WaitFrom(f.dealt[p], EvRoomState, selected(game.VariationMuflis), eventTimeout)
		if err != nil {
			t.Fatalf("%s got no snapshot with the server's choice: %v", who, err)
		}
		if str(state, "variation.selectedBy") != "TIMEOUT" || has(state, "variation.turnUp") || str(state, "turn.userId") != f.chooser.user.ID {
			t.Fatalf("%s: %s", who, state)
		}
		turn, err := p.c.WaitFrom(f.dealt[p], EvGameTurn, nil, eventTimeout)
		if err != nil || str(turn, "userId") != f.chooser.user.ID || num(turn, "timeoutMs") != float64(st.cfg.Game.TurnTimeout.Milliseconds()) {
			t.Fatalf("%s: game:turn %s (%v)", who, turn, err)
		}
		// The turn's clock starts when the window closes, not when it opened.
		if int64(num(turn, "deadline")) < deadline+st.cfg.Game.TurnTimeout.Milliseconds() {
			t.Fatalf("%s: the turn's deadline %v was counted from before the window closed at %d", who, num(turn, "deadline"), deadline)
		}
	}
	// Every client has heard it; none can have heard it early.
	if now := time.Now().UnixMilli(); now < deadline {
		t.Fatalf("the server chose at %d, before the deadline %d it advertised", now, deadline)
	}

	refusedTwice(st, f.chooser.c, map[string]any{"variation": "AK47"}, game.CodeVariationAlreadySelected, game.MsgVariationAlreadySelected)
	if v := st.view(f.table, f.chooser.user.ID).Variation; v == nil || v.Selected == nil || *v.Selected != game.VariationMuflis {
		t.Fatalf("a late pick overturned the server's choice: %+v", v)
	}
	st.mustOK(f.chooser.c, EvGameAction, map[string]any{"action": "chaal", "amount": f.boot, "actionId": "after-the-timeout"})
}

// A client that drops and comes back mid-window is sent room:joined and nothing
// else about the window — no replay of game:variationSelecting — so the block
// in that snapshot has to be enough to draw the picker and its countdown: still
// selecting, the same chooser, and the ORIGINAL deadline, not a fresh ten
// seconds. It is the chooser who drops here, because they must also still be
// able to choose from the new socket.
func TestAReconnectMidWindowIsToldTheOriginalDeadline(t *testing.T) {
	st := newStack(t, func(cfg *config.Config) {
		cfg.Game.ReconnectGrace = 8 * time.Second
		cfg.Game.VariationSelectTimeout = 8 * time.Second
	})
	f := st.variationTable(3)
	before := f.states[f.chooser]
	watcher := f.others[0]

	mark := watcher.c.Mark()
	f.chooser.c.Disconnect()
	eventually(t, eventTimeout, func() bool {
		for _, e := range watcher.c.Since(mark) {
			if e.Name == EvRoomState {
				if seat := seatOf(e.Payload, f.chooser.user.ID); seat != nil && seat["connected"] == false {
					return true
				}
			}
		}
		return false
	}, "the chooser's seat is marked disconnected")
	// A chooser who has dropped is not a chooser who has left: the window and
	// its clock carry on (the server times them out like anyone).
	f.windowOpen(st, "the chooser's disconnect")
	// Long enough that a deadline re-counted from the reconnect would differ
	// by far more than a millisecond's rounding.
	time.Sleep(300 * time.Millisecond)

	back := st.connect(f.chooser.token)
	joined, err := back.Wait(EvRoomJoined, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(joined, "roomId") != f.roomID || !selecting(joined) {
		t.Fatalf("the resumed snapshot does not say the window is open: %s", joined)
	}
	for _, key := range []string{"userId", "displayName", "seatIndex", "startedAt", "deadline", "timeoutMs", "options", "selected", "selectedBy"} {
		if jsonOf(field(joined, "variation."+key)) != jsonOf(field(before, "variation."+key)) {
			t.Fatalf("variation.%s changed across the reconnect: %s, was %s", key, jsonOf(field(joined, "variation."+key)), jsonOf(field(before, "variation."+key)))
		}
	}
	if left := int64(num(joined, "variation.deadline")) - time.Now().UnixMilli(); left <= 0 || left > 8000-300 {
		t.Fatalf("%d ms left on the resumed window — the deadline was not the original", left)
	}
	if num(joined, "turn.seatIndex") != -1 || field(joined, "you.options") != nil {
		t.Fatalf("the resumed snapshot puts somebody on turn: %s", joined)
	}
	if len(back.All(EvGameVariationSelecting)) != 0 {
		t.Fatal("the announcement was replayed; the test no longer proves room:joined is enough")
	}

	// The new socket is the chooser's as much as the old one was.
	marks := map[*player]int{}
	for _, p := range f.others {
		marks[p] = p.c.Mark()
	}
	ack := st.mustOK(back, EvGameSelectVariation, map[string]any{"variation": "HIGHEST_JOKER"})
	if str(ack.Raw, "variation") != "HIGHEST_JOKER" || str(ack.Raw, "selectedBy") != "PLAYER" {
		t.Fatalf("ack %s", ack.Raw)
	}
	if _, err := back.Wait(EvRoomState, selected(game.VariationHighestJoker), eventTimeout); err != nil {
		t.Fatalf("the chooser's new socket got no snapshot of its own choice: %v", err)
	}
	for _, p := range f.others {
		if _, err := p.c.WaitFrom(marks[p], EvGameVariationSelected, func(raw json.RawMessage) bool {
			return str(raw, "variation") == "HIGHEST_JOKER" && str(raw, "selectedBy") == "PLAYER"
		}, eventTimeout); err != nil {
			t.Fatalf("%s did not hear the reconnected chooser's pick: %v", p.user.DisplayName, err)
		}
	}
}

// When the chooser walks away the server chooses at once — MUFLIS, LEFT — and
// play opens with the next player rather than waiting out a clock for somebody
// who is not there.
func TestWhenTheChooserLeavesTheRoomHearsTheServerChoose(t *testing.T) {
	st := newStack(t, nil)
	f := st.variationTable(3)
	marks := f.marks()
	st.mustOK(f.chooser.c, EvRoomLeave, map[string]any{})
	for _, p := range f.others {
		who := p.user.DisplayName
		ev, err := p.c.WaitFrom(marks[p], EvGameVariationSelected, nil, eventTimeout)
		if err != nil {
			t.Fatalf("%s never heard the server choose: %v", who, err)
		}
		if str(ev, "variation") != "MUFLIS" || str(ev, "selectedBy") != "LEFT" || str(ev, "userId") != f.chooser.user.ID {
			t.Fatalf("%s: game:variationSelected %s", who, ev)
		}
		state, err := p.c.WaitFrom(marks[p], EvRoomState, func(raw json.RawMessage) bool {
			return selected(game.VariationMuflis)(raw) && str(raw, "turn.userId") != ""
		}, eventTimeout)
		if err != nil {
			t.Fatalf("%s got no snapshot with a turn in it: %v", who, err)
		}
		if on := str(state, "turn.userId"); on == f.chooser.user.ID || (on != f.others[0].user.ID && on != f.others[1].user.ID) {
			t.Fatalf("%s: the turn went to %q: %s", who, on, state)
		}
		if str(state, "variation.selectedBy") != "LEFT" {
			t.Fatalf("%s: %s", who, obj2(state)["variation"])
		}
	}
	// The leaver's own socket is still in the room while its departure is
	// played out (room:leave untracks it afterwards, as it does for the pack a
	// mid-hand leave causes), so it may hear the announcement too. What it must
	// get is room:left, and no seat.
	if _, err := f.chooser.c.WaitFrom(marks[f.chooser], EvRoomLeft, nil, eventTimeout); err != nil {
		t.Fatalf("the chooser who left got no room:left: %v", err)
	}
	if st.rooms.GetTableForPlayer(f.chooser.user.ID) != nil {
		t.Fatal("the chooser who left still has a seat")
	}
}

// A showdown on a variation table says which rules it was decided by: both
// game:showdown and game:handEnded carry `variation`, and — under the two
// variations a turned-up card decides — `turnUp`, the same card the ack, the
// announcement and room:state named. Each reveal lists which of its cards
// played wild, and under HUKAM that is exactly its cards of the turned-up suit.
func TestAVariationShowdownNamesItsRulesAndItsWildCards(t *testing.T) {
	st := newStack(t, nil)
	f := st.variationTable(2)
	marks := f.marks()

	ack := st.mustOK(f.chooser.c, EvGameSelectVariation, map[string]any{"variation": "HUKAM"})
	turnUp := str(ack.Raw, "turnUp")
	var body map[string]any
	if err := json.Unmarshal(ack.Raw, &body); err != nil || len(body) != 5 || body["variation"] != "HUKAM" || body["selectedBy"] != "PLAYER" {
		t.Fatalf("ack %s", ack.Raw)
	}
	if len(turnUp) != 2 || !strings.ContainsRune("23456789TJQKA", rune(turnUp[0])) || !strings.ContainsRune("shdc", rune(turnUp[1])) {
		t.Fatalf("turnUp %q is not a card code", turnUp)
	}
	for _, p := range f.players {
		ev, err := p.c.WaitFrom(marks[p], EvGameVariationSelected, nil, eventTimeout)
		if err != nil || str(ev, "variation") != "HUKAM" || str(ev, "turnUp") != turnUp {
			t.Fatalf("%s: game:variationSelected %s (%v)", p.user.DisplayName, ev, err)
		}
		state, err := p.c.WaitFrom(marks[p], EvRoomState, selected(game.VariationHukam), eventTimeout)
		if err != nil || str(state, "variation.turnUp") != turnUp {
			t.Fatalf("%s: room:state %s (%v)", p.user.DisplayName, state, err)
		}
	}

	marks = f.marks()
	st.mustOK(f.chooser.c, EvGameAction, map[string]any{"action": "show", "actionId": "variation-show"})
	for _, p := range f.players {
		who := p.user.DisplayName
		showdown, err := p.c.WaitFrom(marks[p], EvGameShowdown, nil, eventTimeout)
		if err != nil {
			t.Fatalf("%s heard no showdown: %v", who, err)
		}
		ended, err := p.c.WaitFrom(marks[p], EvGameHandEnded, nil, eventTimeout)
		if err != nil {
			t.Fatalf("%s heard no handEnded: %v", who, err)
		}
		for name, raw := range map[string]json.RawMessage{EvGameShowdown: showdown, EvGameHandEnded: ended} {
			if str(raw, "variation") != "HUKAM" || str(raw, "turnUp") != turnUp || str(raw, "reason") != "show" {
				t.Fatalf("%s: %s %s", who, name, raw)
			}
			var e struct {
				Reveals []game.Reveal `json:"reveals"`
			}
			if err := json.Unmarshal(raw, &e); err != nil || len(e.Reveals) != 2 {
				t.Fatalf("%s: %s reveals: %s", who, name, raw)
			}
			for _, r := range e.Reveals {
				var want []string
				for _, card := range r.Cards {
					if card[1] == turnUp[1] {
						want = append(want, card)
					}
				}
				if len(r.Cards) != 3 || r.HandName == "" || strings.Join(r.Wild, ",") != strings.Join(want, ",") {
					t.Fatalf("%s: %s: %v played %v as wild under a turned-up %s, want %v", who, name, r.Cards, r.Wild, turnUp, want)
				}
				// playsAs — the hand as it was counted — comes exactly with wild
				// (owner, 24 Sep 2026: "on show or sideshow, show updated cards
				// not the base cards"): three cards, the naturals themselves,
				// each wild a stand-in, and together the hand the reveal names.
				if len(r.Wild) == 0 {
					if r.PlaysAs != nil {
						t.Fatalf("%s: %s: playsAs %v on a hand with no wild card", who, name, r.PlaysAs)
					}
					continue
				}
				if len(r.PlaysAs) != 3 {
					t.Fatalf("%s: %s: playsAs %v, want three cards", who, name, r.PlaysAs)
				}
				isWild := map[string]bool{}
				for _, w := range r.Wild {
					isWild[w] = true
				}
				for i, card := range r.Cards {
					if !isWild[card] && r.PlaysAs[i] != card {
						t.Fatalf("%s: %s: natural %s plays as %s", who, name, card, r.PlaysAs[i])
					}
				}
				if made := game.Evaluate(game.ParseCards(r.PlaysAs), game.EvaluateOptions{}); made.Name != r.HandName {
					t.Fatalf("%s: %s: playsAs %v makes %s, the reveal says %s", who, name, r.PlaysAs, made.Name, r.HandName)
				}
			}
		}
		if str(ended, "winnerId") != f.players[0].user.ID && str(ended, "winnerId") != f.players[1].user.ID {
			t.Fatalf("%s: handEnded names no winner: %s", who, ended)
		}
	}
	if v := metricValue(st.metrics.GamesCompletedTotal.WithLabelValues("variation", "show")); v != 1 {
		t.Fatalf("games_completed_total{variation,show} = %v", v)
	}

	// The next hand opens a window of its own, for the next chooser, with
	// nothing left over from this one — and between the two hands the block is
	// absent altogether.
	for _, p := range f.players {
		between, err := p.c.WaitFrom(marks[p], EvRoomState, func(raw json.RawMessage) bool {
			return str(raw, "state") != "betting" && str(raw, "state") != "showdown"
		}, eventTimeout)
		if err == nil && has(between, "variation") {
			t.Fatalf("%s: a variation block between hands: %s", p.user.DisplayName, between)
		}
		next, err := p.c.WaitFrom(marks[p], EvRoomState, selecting, eventTimeout)
		if err != nil {
			t.Fatalf("%s: the next hand opened no window: %v", p.user.DisplayName, err)
		}
		if field(next, "variation.selected") != nil || has(next, "variation.turnUp") || num(next, "handNo") != 2 {
			t.Fatalf("%s: the next hand's window: %s", p.user.DisplayName, next)
		}
	}
}

// obj2 is obj with the values left as raw JSON, for counting keys and telling
// null from absent.
func obj2(raw json.RawMessage) map[string]json.RawMessage {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil
	}
	return m
}

// 5-Card Teen Patti over real sockets (owner, 18 Sep 2026): the chooser picks
// FIVE_CARD, the SERVER tops every hand up to five, each player is shown only
// their own five, and the showdown names the three of each hand that counted.
func TestFiveCardDealsFiveToEveryoneAndLetsEachPlayerChooseThree(t *testing.T) {
	st := newStack(t, nil)
	f := st.variationTable(2)

	// Dealt three, as every hand is; the snapshot says so.
	for _, p := range f.players {
		if num(f.states[p], "variation.cardsPerPlayer") != 3 {
			t.Fatalf("%s: dealt %v cards", p.user.DisplayName, num(f.states[p], "variation.cardsPerPlayer"))
		}
	}

	marks := f.marks()
	ack := st.mustOK(f.chooser.c, EvGameSelectVariation, map[string]any{"variation": "FIVE_CARD"})
	if str(ack.Raw, "variation") != "FIVE_CARD" || num(ack.Raw, "cardsPerPlayer") != 5 || has(ack.Raw, "turnUp") {
		t.Fatalf("ack %s", ack.Raw)
	}
	for _, p := range f.players {
		who := p.user.DisplayName
		ev, err := p.c.WaitFrom(marks[p], EvGameVariationSelected, nil, eventTimeout)
		if err != nil || str(ev, "variation") != "FIVE_CARD" || num(ev, "cardsPerPlayer") != 5 {
			t.Fatalf("%s: game:variationSelected %s (%v)", who, ev, err)
		}
		state, err := p.c.WaitFrom(marks[p], EvRoomState, selected(game.VariationFiveCard), eventTimeout)
		if err != nil || num(state, "variation.cardsPerPlayer") != 5 {
			t.Fatalf("%s: room:state %s (%v)", who, state, err)
		}
		// Everyone can see that every hand holds five; nobody is sent a card.
		for _, seat := range arr(state, "seats") {
			s, _ := json.Marshal(seat)
			if str(s, "status") == "empty" {
				continue
			}
			if num(s, "cardCount") != 5 {
				t.Fatalf("%s: a seat holds %v cards: %s", who, num(s, "cardCount"), s)
			}
		}
		if len(arr(state, "you.cards")) != 0 || has(state, "you.hand") {
			t.Fatalf("%s is blind and was sent cards: %s", who, state)
		}
	}

	// Each player looks, is shown five of their own — and is asked which three
	// of them play (owner, 19 Sep 2026). Until they answer the hand has no
	// name and nothing counts, so looking never hands them the answer.
	seen := map[string][]string{}
	for _, p := range f.players {
		who := p.user.DisplayName
		mark := p.c.Mark()
		st.mustOK(p.c, EvGameAction, map[string]any{"action": "see", "actionId": "five-see-" + p.user.ID})
		cards, err := p.c.WaitFrom(mark, EvPlayerCards, nil, eventTimeout)
		if err != nil || len(arr(cards, "cards")) != 5 {
			t.Fatalf("%s: player:cards %s (%v)", who, cards, err)
		}
		state, err := p.c.WaitFrom(mark, EvRoomState, func(raw json.RawMessage) bool { return has(raw, "you.hand") }, eventTimeout)
		if err != nil {
			t.Fatalf("%s: no you.hand after looking: %v", who, err)
		}
		mine := codes(arr(state, "you.cards"))
		if len(mine) != 5 {
			t.Fatalf("%s: you %s", who, obj2(state)["you"])
		}
		if field(state, "you.hand.picking") != true || str(state, "you.hand.handName") != "" ||
			len(arr(state, "you.hand.best")) != 0 || num(state, "you.hand.pickDeadline") == 0 {
			t.Fatalf("%s was not asked to choose: %s", who, obj2(state)["you"])
		}
		seen[p.user.ID] = mine
	}
	// Ten different cards between the two of them.
	all := map[string]bool{}
	for _, cards := range seen {
		for _, c := range cards {
			if all[c] {
				t.Fatalf("%v is in two hands", c)
			}
			all[c] = true
		}
	}

	// A pick must be exactly three cards of your own hand.
	first := f.players[0]
	mine := seen[first.user.ID]
	for _, bad := range []any{
		[]any{mine[0], mine[1]},
		[]any{mine[0], mine[0], mine[1]},
		[]any{mine[0], mine[1], "Zz"},
		[]any{mine[0], mine[1], 7},
		"As,Ks,Qs",
		nil,
	} {
		st.mustFail(first.c, EvGameSelectCards, map[string]any{"cards": bad}, game.CodeInvalidPick)
	}

	// Everyone chooses the first three they were dealt.
	picked := map[string][]string{}
	for _, p := range f.players {
		who := p.user.DisplayName
		three := seen[p.user.ID][:3]
		mark := p.c.Mark()
		ack := st.mustOK(p.c, EvGameSelectCards, map[string]any{"cards": three})
		if strings.Join(codes(arr(ack.Raw, "picked")), ",") != strings.Join(three, ",") {
			t.Fatalf("%s: ack %s, want %v", who, ack.Raw, three)
		}
		// The ack's `best` is the one ranking's answer over all five, so a
		// player can be told what they missed without a ranking of their own.
		want := game.EvaluateBest(game.ParseCards(seen[p.user.ID])).Best
		if strings.Join(codes(arr(ack.Raw, "best")), ",") != strings.Join(want, ",") {
			t.Fatalf("%s: ack best %s, want %v", who, ack.Raw, want)
		}
		picked[p.user.ID] = three

		state, err := p.c.WaitFrom(mark, EvRoomState, func(raw json.RawMessage) bool {
			return has(raw, "you.hand") && field(raw, "you.hand.picking") != true
		}, eventTimeout)
		if err != nil {
			t.Fatalf("%s: the choice did not land: %v", who, err)
		}
		if strings.Join(codes(arr(state, "you.hand.best")), ",") != strings.Join(three, ",") ||
			str(state, "you.hand.handName") == "" || str(state, "you.hand.pickedBy") != "PLAYER" ||
			len(arr(state, "you.hand.bestPossible")) != 3 {
			t.Fatalf("%s: you %s", who, obj2(state)["you"])
		}
		// A second pick is refused: the hand is decided.
		st.mustFail(p.c, EvGameSelectCards, map[string]any{"cards": three}, game.CodeDuplicateAction)
	}

	marks = f.marks()
	st.mustOK(f.chooser.c, EvGameAction, map[string]any{"action": "show", "actionId": "five-show"})
	for _, p := range f.players {
		who := p.user.DisplayName
		showdown, err := p.c.WaitFrom(marks[p], EvGameShowdown, nil, eventTimeout)
		if err != nil || str(showdown, "variation") != "FIVE_CARD" || has(showdown, "turnUp") {
			t.Fatalf("%s: showdown %s (%v)", who, showdown, err)
		}
		var e struct {
			Reveals []game.Reveal `json:"reveals"`
		}
		if err := json.Unmarshal(showdown, &e); err != nil || len(e.Reveals) != 2 {
			t.Fatalf("%s: reveals %s", who, showdown)
		}
		winners := 0
		for _, r := range e.Reveals {
			if len(r.Cards) != 5 || len(r.Best) != 3 || len(r.Wild) != 0 || r.HandName == "" {
				t.Fatalf("%s: reveal %+v", who, r)
			}
			// Named for the three its owner CHOSE, by the one classic ranking.
			if strings.Join(r.Best, ",") != strings.Join(picked[r.UserID], ",") {
				t.Fatalf("%s: %v played %v, want the chosen %v", who, r.Cards, r.Best, picked[r.UserID])
			}
			if got := game.Evaluate(game.ParseCards(r.Best), game.EvaluateOptions{}); got.Name != r.HandName {
				t.Fatalf("%s: %v was called %s; the ranking says %s", who, r.Best, r.HandName, got.Name)
			}
			if r.Won {
				winners++
			}
		}
		if winners != 1 {
			t.Fatalf("%s: %d winners", who, winners)
		}
	}
}

// codes turns a JSON array of card codes into the strings the engine uses.
func codes(items []any) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}
