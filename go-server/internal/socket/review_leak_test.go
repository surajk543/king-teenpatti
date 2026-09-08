package socket

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Adversarial review — information leaks. A client must never receive another
// player's cards or a hidden stack. These tests read each seat's real cards
// off the Table (a test-side privilege) and then scan every raw frame each
// socket received — not just the events the client decodes — for the card
// codes of hands it has no right to see.

// framesContainCode reports whether any raw frame the client received carries
// the card code as a JSON string ("As", "Td" …).
func framesContainCode(frames []string, code string) bool {
	needle := `"` + code + `"`
	for _, f := range frames {
		if strings.Contains(f, needle) {
			return true
		}
	}
	return false
}

// assertNoForeignCards fails if any of the given codes reached the client.
func assertNoForeignCards(t *testing.T, who string, frames []string, codes []game.Card, owner string) {
	t.Helper()
	for _, c := range codes {
		if framesContainCode(frames, c.Code()) {
			t.Fatalf("REVIEW LEAK: %s received %s's card %s", who, owner, c.Code())
		}
	}
}

// A three-player hand carried all the way through a sideshow, the loser's
// pack, a paid show and game:handEnded. At every stage a socket may hold only:
// its own cards (after it has seen), the two hands of a sideshow it took part
// in, and the showdown reveals of the CONTENDERS. The sideshow loser's hand
// must never reach the third player — not via game:sideshowReveal (audience),
// not via game:showdown (contenders only), not via game:handEnded.summary
// (cards null unless revealed) and not via any room:state.
func TestReviewSideshowLoserCardsNeverReachTheThirdPlayer(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	ps := []*player{st.player("L1"), st.player("L2"), st.player("L3")}
	for _, p := range ps {
		st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot, "category": "seen"})
	}
	if _, err := ps[0].c.Wait(EvGameHandStarted, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}
	table := st.rooms.GetTableForPlayer(ps[0].user.ID)
	if table == nil {
		t.Fatal("no table")
	}
	byID := map[string]*player{}
	cards := map[string][]game.Card{}
	for _, p := range ps {
		byID[p.user.ID] = p
		seat, err := table.FindSeat(p.user.ID)
		if err != nil || seat == nil || len(seat.Cards) != 3 {
			t.Fatalf("%s has no cards: %v %+v", p.user.DisplayName, err, seat)
		}
		cards[p.user.ID] = seat.Cards
	}
	if len(cards) != 3 {
		t.Fatalf("the hand did not include all three players")
	}
	noForeign := func(stage string) {
		t.Helper()
		for _, p := range ps {
			for other, codes := range cards {
				if other == p.user.ID {
					continue
				}
				assertNoForeignCards(t, p.user.DisplayName+" ("+stage+")", p.c.Frames(), codes, byID[other].user.DisplayName)
			}
		}
	}

	// Blind: nobody has any card on the wire, not even their own.
	for _, p := range ps {
		for _, c := range cards[p.user.ID] {
			if framesContainCode(p.c.Frames(), c.Code()) {
				t.Fatalf("%s received their own card %s while blind", p.user.DisplayName, c.Code())
			}
		}
	}
	noForeign("dealt")

	// Everyone sees: each gets exactly their own hand and nothing else.
	for _, p := range ps {
		st.mustOK(p.c, EvGameAction, map[string]any{"action": "see"})
		if _, err := p.c.Wait(EvPlayerCards, nil, eventTimeout); err != nil {
			t.Fatalf("%s: no player:cards: %v", p.user.DisplayName, err)
		}
	}
	noForeign("seen")

	// First to act bets so the next player has a right-hand neighbour who bet.
	view := st.view(table, ps[0].user.ID)
	first := byID[*view.Turn.UserID]
	st.mustOK(first.c, EvGameAction, map[string]any{"action": "chaal"})
	view = st.view(table, ps[0].user.ID)
	asker := byID[*view.Turn.UserID]
	ack := st.mustOK(asker.c, EvGameAction, map[string]any{"action": "sideshow"})
	asked := byID[str(ack.Raw, "toUserId")]
	var third *player
	for _, p := range ps {
		if p != asker && p != asked {
			third = p
		}
	}
	if asked == nil || third == nil {
		t.Fatalf("sideshow ack: %s", ack.Raw)
	}
	resp := st.mustOK(asked.c, EvGameSideshowResp, map[string]any{"accept": true})
	loserID := str(resp.Raw, "packedUserId")
	loser := byID[loserID]
	if loser == nil {
		t.Fatalf("sideshow outcome: %s", resp.Raw)
	}
	var winner *player
	if loser == asker {
		winner = asked
	} else {
		winner = asker
	}
	if _, err := third.c.Wait(EvGameSideshowRes, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}
	// The two participants legitimately learned each other's hand; the third
	// player learned nothing.
	assertNoForeignCards(t, third.user.DisplayName+" (after sideshow)", third.c.Frames(), cards[asker.user.ID], asker.user.DisplayName)
	assertNoForeignCards(t, third.user.DisplayName+" (after sideshow)", third.c.Frames(), cards[asked.user.ID], asked.user.DisplayName)
	assertNoForeignCards(t, winner.user.DisplayName+" (after sideshow)", winner.c.Frames(), cards[third.user.ID], third.user.DisplayName)
	assertNoForeignCards(t, loser.user.DisplayName+" (after sideshow)", loser.c.Frames(), cards[third.user.ID], third.user.DisplayName)

	// The loser is packed but still seated and still a viewer: their room:state
	// shows the survivors with cardCount only.
	state, ok := loser.c.Last(EvRoomState)
	if !ok {
		t.Fatal("loser has no room:state")
	}
	for _, s := range arr(state, "seats") {
		m, _ := s.(map[string]any)
		if _, present := m["cards"]; present {
			t.Fatalf("room:state seat carries cards: %v", m)
		}
	}
	if str(state, "you.status") != "packed" {
		t.Fatalf("loser's you.status = %q", str(state, "you.status"))
	}

	// Two active players remain; whoever is on turn pays for a show.
	view = st.view(table, ps[0].user.ID)
	shower := byID[*view.Turn.UserID]
	if shower == loser {
		t.Fatalf("the packed player is on turn")
	}
	st.mustOK(shower.c, EvGameAction, map[string]any{"action": "show"})
	ended, err := third.c.Wait(EvGameHandEnded, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	// game:showdown / handEnded reveal the two contenders to the room — never
	// the packed hand.
	reveals := arr(ended, "reveals")
	if len(reveals) != 2 {
		t.Fatalf("handEnded reveals %d hands, want the 2 contenders: %s", len(reveals), ended)
	}
	for _, r := range reveals {
		m, _ := r.(map[string]any)
		if m["userId"] == loserID {
			t.Fatalf("REVIEW LEAK: the packed player's hand was revealed at showdown: %v", m)
		}
	}
	for _, s := range arr(ended, "summary") {
		m, _ := s.(map[string]any)
		if m["userId"] == loserID && m["cards"] != nil {
			t.Fatalf("REVIEW LEAK: handEnded.summary carries the packed player's cards: %v", m)
		}
	}
	// And at the frame level: the third player never saw the loser's cards.
	assertNoForeignCards(t, third.user.DisplayName+" (hand over)", third.c.Frames(), cards[loserID], loser.user.DisplayName)
	// The loser's own frames hold their own hand and the winner's (sideshow
	// reveal + showdown) and the third player's showdown reveal — all
	// legitimate; nothing here to forbid. Sanity: chips are conserved.
	var total int64
	for _, p := range ps {
		total += st.users.chips(p.user.ID)
	}
	eventually(t, eventTimeout, func() bool {
		var sum int64
		for _, p := range ps {
			sum += st.users.chips(p.user.ID)
		}
		return sum == 3*welcomeChips
	}, "chips conserved after settlement")
}

// After room:left a socket receives nothing more from the table, and a
// player who left mid-hand never receives the hand's later reveals.
func TestReviewLeaverReceivesNothingAfterRoomLeft(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	ps := []*player{st.player("Q1"), st.player("Q2"), st.player("Q3")}
	for _, p := range ps {
		st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot, "category": "seen"})
	}
	if _, err := ps[0].c.Wait(EvGameHandStarted, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}
	table := st.rooms.GetTableForPlayer(ps[0].user.ID)
	byID := map[string]*player{}
	// Capture every hand NOW: once this hand ends the next one is dealt
	// 150 ms later and a seat's live cards would no longer be this hand's.
	dealtCards := map[string][]game.Card{}
	for _, p := range ps {
		byID[p.user.ID] = p
		seat, err := table.FindSeat(p.user.ID)
		if err != nil || seat == nil || len(seat.Cards) != 3 {
			t.Fatalf("%s has no cards: %v", p.user.DisplayName, err)
		}
		dealtCards[p.user.ID] = seat.Cards
	}
	for _, p := range ps {
		st.mustOK(p.c, EvGameAction, map[string]any{"action": "see"})
	}
	// The player NOT on turn leaves mid-hand (a pack); the hand goes on
	// between the other two.
	view := st.view(table, ps[0].user.ID)
	onTurn := byID[*view.Turn.UserID]
	var leaver *player
	for _, p := range ps {
		if p != onTurn {
			leaver = p
			break
		}
	}
	st.mustOK(leaver.c, EvRoomLeave, map[string]any{})
	if _, err := leaver.c.Wait(EvRoomLeft, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}
	mark := leaver.c.Mark()
	framesBefore := len(leaver.c.Frames())

	// The survivors play the hand out: chaal, then a show.
	view = st.view(table, ps[0].user.ID)
	st.mustOK(byID[*view.Turn.UserID].c, EvGameAction, map[string]any{"action": "chaal"})
	view = st.view(table, ps[0].user.ID)
	st.mustOK(byID[*view.Turn.UserID].c, EvGameAction, map[string]any{"action": "show"})
	if _, err := onTurn.c.Wait(EvGameHandEnded, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	if got := leaver.c.Since(mark); len(got) != 0 {
		t.Fatalf("REVIEW LEAK: the leaver received %v after room:left", names(got))
	}
	// Not even a ping-level frame carrying table data.
	for _, f := range leaver.c.Frames()[framesBefore:] {
		if strings.HasPrefix(f, "42") {
			t.Fatalf("REVIEW LEAK: table frame after room:left: %s", f)
		}
	}
	// The remaining players' showdown reveals do not include the leaver's
	// hand, and the leaver's frames never carried the survivors' cards.
	for _, p := range ps {
		if p == leaver {
			continue
		}
		assertNoForeignCards(t, leaver.user.DisplayName, leaver.c.Frames(), dealtCards[p.user.ID], p.user.DisplayName)
		ended, _ := p.c.Last(EvGameHandEnded)
		for _, r := range arr(ended, "reveals") {
			m, _ := r.(map[string]any)
			if m["userId"] == leaver.user.ID {
				t.Fatalf("REVIEW LEAK: the leaver's hand was revealed: %v", m)
			}
		}
		assertNoForeignCards(t, p.user.DisplayName, p.c.Frames(), dealtCards[leaver.user.ID], leaver.user.DisplayName)
	}
}

// Blind tables withhold every other stack from every viewer, including the
// viewer's own snapshot after they leave (you: null, all chips null), and a
// seen table never withholds. Cross-check the redaction on the wire against
// the table's real figures so a regression that sent 0 instead of null, or
// the real number, is caught.
func TestReviewBlindTableNeverPutsAnotherStackOnTheWire(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("blind")
	for _, p := range []*player{d.a, d.b} {
		other := d.b
		if p == d.b {
			other = d.a
		}
		otherSeat, _ := d.table.FindSeat(other.user.ID)
		joined, ok := p.c.Last(EvRoomJoined)
		if !ok {
			t.Fatalf("%s has no room:joined", p.user.DisplayName)
		}
		for _, raw := range append(p.c.All(EvRoomState), joined) {
			seat := seatOf(raw, other.user.ID)
			if seat == nil {
				continue
			}
			if v, present := seat["chips"]; !present || v != nil {
				t.Fatalf("REVIEW LEAK: blind table sent %s's chips=%v to %s", other.user.DisplayName, v, p.user.DisplayName)
			}
			if field(raw, "chipsHidden") != true {
				t.Fatalf("chipsHidden not true on a blind table: %s", raw)
			}
			// The real figure must not appear anywhere in the seat entry.
			b, _ := json.Marshal(seat)
			if otherSeat != nil && strings.Contains(string(b), `:`+jsonOf(otherSeat.Chips)+`,`) {
				t.Fatalf("REVIEW LEAK: %s's real stack %d appears in their seat entry for %s: %s", other.user.DisplayName, otherSeat.Chips, p.user.DisplayName, b)
			}
			// Own chips are always present.
			own := seatOf(raw, p.user.ID)
			if own == nil || own["chips"] == nil {
				t.Fatalf("own chips withheld: %v", own)
			}
		}
	}
	// A viewer who leaves still gets the redacted snapshot on the way out.
	mark := d.waiting.c.Mark()
	st.mustOK(d.waiting.c, EvRoomLeave, map[string]any{})
	for _, ev := range d.waiting.c.Since(mark) {
		if ev.Name != EvRoomState {
			continue
		}
		if field(ev.Payload, "you") == nil {
			seat := seatOf(ev.Payload, d.onTurn.user.ID)
			if seat != nil && seat["chips"] != nil {
				t.Fatalf("REVIEW LEAK: after leaving, the other stack was sent: %v", seat)
			}
		}
	}
}
