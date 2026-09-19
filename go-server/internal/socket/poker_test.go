package socket

import (
	"encoding/json"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/poker"
)

// The poker family over real sockets: the lobby door, the per-viewer
// snapshot, a hand from the blinds to the showdown, the refusals, and the
// wall between the two families' events.

type pokerFixture struct {
	boot    int64
	roomID  string
	players []*player
}

// pokerTable quick-joins n players to a poker room of their own and waits
// for the first deal (the snapshot with a turn on it).
func (st *stack) pokerTable(category string, n int) *pokerFixture {
	st.t.Helper()
	f := &pokerFixture{boot: st.uniqueStake()}
	for i := 0; i < n; i++ {
		f.players = append(f.players, st.player("P"+string(rune('1'+i))))
	}
	for _, p := range f.players {
		ack := st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": f.boot, "category": category})
		if str(ack.Raw, "category") != category {
			st.t.Fatalf("quickJoin {category: %s} was seated at %s", category, ack.Raw)
		}
		f.roomID = str(ack.Raw, "roomId")
	}
	if _, err := f.players[0].c.Wait(EvPokerHandStarted, func(raw json.RawMessage) bool {
		return len(arr(raw, "participants")) == n
	}, eventTimeout); err != nil {
		st.t.Fatalf("no %d-player poker hand: %v", n, err)
	}
	for _, p := range f.players {
		if _, err := p.c.Wait(EvRoomState, func(raw json.RawMessage) bool {
			return str(raw, "state") == "betting" && has(raw, "turn.userId") && str(raw, "game") == "poker"
		}, eventTimeout); err != nil {
			st.t.Fatalf("%s got no betting snapshot: %v", p.user.DisplayName, err)
		}
	}
	return f
}

func (f *pokerFixture) byID(id string) *player {
	for _, p := range f.players {
		if p.user.ID == id {
			return p
		}
	}
	return nil
}

// onTurn is the player the latest snapshot puts on turn.
func (st *stack) onTurn(f *pokerFixture) *player {
	st.t.Helper()
	room := st.rooms.GetTable(f.roomID)
	if room == nil {
		st.t.Fatal("room gone")
	}
	view, err := room.ViewFor(f.players[0].user.ID)
	if err != nil {
		st.t.Fatal(err)
	}
	tv := view.(*poker.TableView)
	if tv.Turn == nil || tv.Turn.UserID == nil {
		st.t.Fatalf("nobody on turn: street %s", tv.Poker.Street)
	}
	return f.byID(*tv.Turn.UserID)
}

func TestPokerQuickJoinOpensAPokerRoomWithItsOwnSnapshot(t *testing.T) {
	st := newStack(t, nil)
	f := st.pokerTable("texas_holdem", 3)
	view, err := st.rooms.GetTable(f.roomID).ViewFor(f.players[0].user.ID)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(view)
	if str(raw, "game") != "poker" || str(raw, "category") != "texas_holdem" || str(raw, "poker.variant") != "texas_holdem" {
		t.Fatalf("%s", raw)
	}
	if num(raw, "poker.bigBlind") != float64(f.boot) || num(raw, "poker.smallBlind") != float64(f.boot/2) || num(raw, "poker.holeCards") != 2 {
		t.Fatalf("%s", raw)
	}
	if field(raw, "chipsHidden") != false || len(arr(raw, "you.cards")) != 2 {
		t.Fatalf("%s", raw)
	}
	// Other seats carry a card count, never cards; stacks are public.
	for _, s := range arr(raw, "seats") {
		seat := s.(map[string]any)
		if seat["userId"] == f.players[0].user.ID || seat["status"] == "empty" {
			continue
		}
		if seat["cardCount"] != float64(2) || seat["chips"] == nil {
			t.Fatalf("seat %v", seat)
		}
		if _, leaked := seat["cards"]; leaked {
			t.Fatalf("seat carries cards: %v", seat)
		}
	}
	// Every player received their own two cards privately.
	for _, p := range f.players {
		cards, err := p.c.Wait(EvPokerCards, nil, eventTimeout)
		if err != nil || len(arr(cards, "cards")) != 2 {
			t.Fatalf("%s cards: %v %s", p.user.DisplayName, err, cards)
		}
	}
}

func TestPokerAHandFromTheBlindsToTheShowdownOverSockets(t *testing.T) {
	st := newStack(t, nil)
	f := st.pokerTable("texas_holdem", 2)
	first := st.onTurn(f)
	// Heads-up preflop: the button posted the small blind and acts first.
	yourTurn, err := first.c.Wait(EvPokerYourTurn, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if field(yourTurn, "options.call") != true || num(yourTurn, "options.callAmount") != float64(f.boot/2) {
		t.Fatalf("%s", yourTurn)
	}
	ack := st.mustOK(first.c, EvPokerAction, map[string]any{"action": "call", "actionId": "c1"})
	if str(ack.Raw, "action") != "call" || num(ack.Raw, "amount") != float64(f.boot) {
		t.Fatalf("%s", ack.Raw)
	}
	other := f.players[0]
	if other == first {
		other = f.players[1]
	}
	st.mustOK(other.c, EvPokerAction, map[string]any{"action": "check"})
	// The flop is dealt to the room.
	street, err := other.c.Wait(EvPokerStreet, func(raw json.RawMessage) bool { return str(raw, "street") == "flop" }, eventTimeout)
	if err != nil || len(arr(street, "community")) != 3 {
		t.Fatalf("%v %s", err, street)
	}
	// Check it down.
	for i := 0; i < 3; i++ {
		p := st.onTurn(f)
		st.mustOK(p.c, EvPokerAction, map[string]any{"action": "check"})
		q := st.onTurn(f)
		st.mustOK(q.c, EvPokerAction, map[string]any{"action": "check"})
	}
	showdown, err := other.c.Wait(EvPokerShowdown, nil, eventTimeout)
	if err != nil || len(arr(showdown, "reveals")) != 2 || len(arr(showdown, "community")) != 5 {
		t.Fatalf("%v %s", err, showdown)
	}
	ended, err := other.c.Wait(EvPokerHandEnded, nil, eventTimeout)
	if err != nil || str(ended, "reason") != "showdown" || len(arr(ended, "pots")) < 1 {
		t.Fatalf("%v %s", err, ended)
	}
	// The books: every wallet is what its seat holds.
	room := st.rooms.GetTable(f.roomID)
	seats, _ := room.Seats()
	var total int64
	for _, s := range seats {
		if got := st.users.chips(s.UserID); got != s.Chips {
			t.Fatalf("%s: wallet %d seat %d", s.UserID, got, s.Chips)
		}
		total += s.Chips
	}
	if total != 2*welcomeChips {
		t.Fatalf("chips created or lost: %d", total)
	}
	// No Teen Patti event ever reached a poker player.
	for _, p := range f.players {
		for _, e := range p.c.Events() {
			switch e.Name {
			case EvGameHandStarted, EvPlayerHand, EvGameTurn, EvGameYourTurn, EvGameShowdown, EvGameHandEnded:
				t.Fatalf("%s received %s at a poker room", p.user.DisplayName, e.Name)
			}
		}
	}
}

func TestPokerRefusesTheTeenPattiEventsAndTheReverse(t *testing.T) {
	st := newStack(t, nil)
	f := st.pokerTable("omaha", 2)
	p := st.onTurn(f)
	st.mustFail(p.c, EvGameAction, map[string]any{"action": "chaal"}, "wrong_game")
	st.mustFail(p.c, EvGameSideshowResp, map[string]any{"accept": true}, "wrong_game")
	st.mustFail(p.c, EvGameSelectVariation, map[string]any{"variation": "MUFLIS"}, "wrong_game")
	st.mustFail(p.c, EvPlayerReqCards, map[string]any{}, "wrong_game")
	// A Teen Patti player sending poker:action.
	d := st.dealtTable("seen")
	st.mustFail(d.onTurn.c, EvPokerAction, map[string]any{"action": "check"}, "wrong_game")
	// And a player in the lobby.
	lobby := st.player("Lobby")
	st.mustFail(lobby.c, EvPokerAction, map[string]any{"action": "check"}, "not_in_room")
}

func TestPokerActionIsValidatedOnTheServer(t *testing.T) {
	st := newStack(t, nil)
	f := st.pokerTable("texas_holdem", 3)
	p := st.onTurn(f)
	st.mustFail(p.c, EvPokerAction, map[string]any{"action": "dance"}, "unknown_action")
	st.mustFail(p.c, EvPokerAction, map[string]any{"action": "check"}, "invalid_action") // facing the big blind
	st.mustFail(p.c, EvPokerAction, map[string]any{"action": "raise", "amount": "lots"}, "invalid_amount")
	st.mustFail(p.c, EvPokerAction, map[string]any{"action": "raise", "amount": 1.5}, "invalid_amount")
	st.mustFail(p.c, EvPokerAction, map[string]any{"action": "raise", "amount": 1}, "invalid_amount")
	st.mustFail(p.c, EvPokerAction, map[string]any{"action": "raise"}, "invalid_amount")
	st.mustFail(p.c, EvPokerAction, map[string]any{"action": "draw", "cards": []string{"As"}}, "invalid_action")
	st.mustFail(p.c, EvPokerAction, map[string]any{"action": "play"}, "invalid_action")
	st.mustFail(p.c, EvPokerAction, map[string]any{"action": [][]int{{1}}}, "unknown_action")
	st.mustFail(p.c, EvPokerAction, "not an object", "unknown_action")
	// Somebody else on turn.
	for _, q := range f.players {
		if q != p {
			st.mustFail(q.c, EvPokerAction, map[string]any{"action": "fold"}, "not_your_turn")
			break
		}
	}
	// A move with a colon in its id gets a fresh id, and a repeated id is refused.
	st.mustOK(p.c, EvPokerAction, map[string]any{"action": "call", "actionId": "x1"})
	q := st.onTurn(f)
	st.mustFail(q.c, EvPokerAction, map[string]any{"action": "call", "actionId": "x1"}, "duplicate_action")
	st.mustOK(q.c, EvPokerAction, map[string]any{"action": "call", "actionId": "a:b"})
}

func TestPokerLobbyAdvertisesTheFamilyOnlyWhereTheMenuListsIt(t *testing.T) {
	st := newStack(t, nil) // a lifted menu: any pair, but no poker advertised
	p := st.player("L")
	ready, err := p.c.Wait(EvSessionReady, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range arr(ready, "config.categories") {
		if game.Category(c.(string)).IsPoker() {
			t.Fatalf("a lifted menu advertised %v", c)
		}
	}
	st2 := newStack(t, func(cfg *config.Config) {
		cfg.Game.LobbyTables = []config.LobbyTable{
			{Category: "seen", BootAmount: 200},
			{Category: "texas_holdem", BootAmount: 200},
			{Category: "three_card_poker", BootAmount: 200},
		}
	})
	q := st2.player("M")
	ready, err = q.c.Wait(EvSessionReady, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	var cats []string
	for _, c := range arr(ready, "config.categories") {
		cats = append(cats, c.(string))
	}
	if len(cats) != 4 || cats[0] != "seen" || cats[1] != "blind" || cats[2] != "three_card_poker" || cats[3] != "texas_holdem" {
		t.Fatalf("categories %v", cats)
	}
	tables := arr(ready, "config.tables")
	holdem := tables[1].(map[string]any)
	if holdem["game"] != "poker" || holdem["bigBlind"] != float64(200) || holdem["smallBlind"] != float64(100) || holdem["minBuyIn"] != float64(2000) || holdem["holeCards"] != float64(2) {
		t.Fatalf("hold'em entry %v", holdem)
	}
	if _, has := holdem["ante"]; has {
		t.Fatalf("a blinds game carries no ante: %v", holdem)
	}
	three := tables[2].(map[string]any)
	if three["ante"] != float64(200) || three["holeCards"] != float64(3) {
		t.Fatalf("3-card entry %v", three)
	}
	seen := tables[0].(map[string]any)
	if _, has := seen["game"]; has {
		t.Fatalf("a Teen Patti entry gained a key: %v", seen)
	}
}
