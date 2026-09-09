package socket

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// Mirror of server/test/invalidMoves.test.js: a tampered or confused client
// has every bad request refused with a clear code, nothing changes, and the
// table stays up for the honest players.

func TestOutOfTurnMovesAreRefusedAndTheTurnStays(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	before := st.turnSeat(d.table, d.a.user.ID)
	stake := st.view(d.table, d.a.user.ID).Stake
	for _, action := range []string{"chaal", "pack", "show", "sideshow"} {
		st.mustFail(d.waiting.c, EvGameAction, map[string]any{"action": action, "amount": stake, "actionId": "oot-" + action}, game.CodeNotYourTurn)
	}
	if st.turnSeat(d.table, d.a.user.ID) != before {
		t.Fatalf("the turn moved")
	}
}

func TestOffLadderBetsAreRefused(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	view := st.view(d.table, d.onTurn.user.ID)
	stake := view.Stake
	potBefore := view.Pot
	walletBefore := st.users.chips(d.onTurn.user.ID)
	for _, amount := range []int64{stake + 1, stake * 3, -stake, 0, 1, 1e15, walletBefore + 1} {
		ack := st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal", "amount": amount, "actionId": fmt.Sprintf("ladder-%d", amount)}, "")
		if ack.Code != game.CodeInvalidBet && ack.Code != game.CodeInsufficientChips {
			t.Fatalf("chaal %d → %s", amount, ack.Raw)
		}
	}
	if st.view(d.table, d.onTurn.user.ID).Pot != potBefore {
		t.Fatalf("the pot moved")
	}
	if st.users.chips(d.onTurn.user.ID) != walletBefore {
		t.Fatalf("the wallet moved")
	}
}

func TestNonNumericAmountsAreRefusedBeforeTheTable(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	view := st.view(d.table, d.onTurn.user.ID)
	potBefore := view.Pot
	// NaN and Infinity cannot cross the wire (JSON has no spelling for them).
	// Every other shape would coerce to a legal figure under Number() and
	// must be refused instead. 1.0 and 1e3 ARE the numbers 1 and 1000 and
	// pass this check (the ladder refuses them).
	for _, amount := range []any{fmt.Sprint(view.Stake), "abc", 1.5, map[string]any{"amount": 100}, []any{view.Stake}, true, json.RawMessage(`"1e3"`), json.RawMessage(`9007199254740992`), json.RawMessage(`-9007199254740992`)} {
		ack := st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal", "amount": amount, "actionId": "nan-" + jsonOf(amount)}, game.CodeInvalidBet)
		if ack.Message != game.MsgBetNotWhole {
			t.Fatalf("message %q", ack.Message)
		}
	}
	// The type check runs for EVERY action, off turn or not, before the table.
	st.mustFail(d.waiting.c, EvGameAction, map[string]any{"action": "pack", "amount": "x"}, game.CodeInvalidBet)
	st.mustFail(d.waiting.c, EvGameAction, map[string]any{"action": "see", "amount": []any{}}, game.CodeInvalidBet)
	// 1e3 as a JSON number is a whole number: it reaches the ladder.
	st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal", "amount": json.RawMessage(`1e3`)}, game.CodeInvalidBet)
	ack := st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal", "amount": json.RawMessage(`1e3`)}, "")
	if ack.Message == game.MsgBetNotWhole {
		t.Fatalf("1e3 was refused by the type check, want the ladder")
	}
	// null amount is the ordinary "chaal at the stake" — but the typed check
	// must not fire for it (proved by a not_your_turn from the other seat).
	st.mustFail(d.waiting.c, EvGameAction, map[string]any{"action": "chaal", "amount": null()}, game.CodeNotYourTurn)
	if st.view(d.table, d.onTurn.user.ID).Pot != potBefore {
		t.Fatalf("the pot moved")
	}
	// No pre-check refusal ever reached the move histogram; every one was
	// counted as an invalid move.
	if v := metricValue(st.metrics.InvalidMovesTotal.WithLabelValues(game.CodeInvalidBet)); v < 11 {
		t.Fatalf("invalid_moves_total{invalid_bet} = %v", v)
	}
}

func TestUnknownActionAndNoTable(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	ack := st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "allin", "actionId": "unknown-1"}, game.CodeUnknownAction)
	if ack.Message != `Unknown action "allin"` {
		t.Fatalf("message %q", ack.Message)
	}
	st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "__proto__", "actionId": "unknown-2"}, game.CodeUnknownAction)
	// The message interpolates String(action), as Node's template literal did.
	if ack := st.mustFail(d.onTurn.c, EvGameAction, map[string]any{}, game.CodeUnknownAction); ack.Message != `Unknown action "undefined"` {
		t.Fatalf("absent action message %q", ack.Message)
	}
	if ack := st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": map[string]any{}}, game.CodeUnknownAction); ack.Message != `Unknown action "[object Object]"` {
		t.Fatalf("object action message %q", ack.Message)
	}
	if ack := st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": null()}, game.CodeUnknownAction); ack.Message != `Unknown action "null"` {
		t.Fatalf("null action message %q", ack.Message)
	}
	// unknown_action is checked BEFORE not_in_room.
	loner := st.player("Cara")
	st.mustFail(loner.c, EvGameAction, map[string]any{"action": "allin"}, game.CodeUnknownAction)
	ack = st.mustFail(loner.c, EvGameAction, map[string]any{"action": "pack", "actionId": "unknown-3"}, game.CodeNotInRoom)
	if ack.Message != MsgNotAtTable {
		t.Fatalf("not_in_room message %q", ack.Message)
	}
	// A refused game:action is not a move.
	if v := metricValue(st.metrics.MovesTotal.WithLabelValues("pack")); v != 0 {
		t.Fatalf("moves_total{pack} = %v", v)
	}
}

func TestShowWithThreePlayersIsRefused(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	ps := []*player{st.player("P1"), st.player("P2"), st.player("P3")}
	for _, p := range ps {
		st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	}
	if _, err := ps[0].c.Wait(EvGameHandStarted, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}
	table := st.rooms.GetTableForPlayer(ps[0].user.ID)
	view := st.view(table, ps[0].user.ID)
	var onTurn *player
	for _, p := range ps {
		if p.user.ID == *view.Turn.UserID {
			onTurn = p
		}
	}
	st.mustFail(onTurn.c, EvGameAction, map[string]any{"action": "show", "actionId": "show3-1"}, game.CodeShowUnavailable)
	if !table.HasHand() {
		t.Fatalf("the hand ended")
	}
}

func TestSideshowWithTwoPlayersAndUnaskedAnswer(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	ack := st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "sideshow", "actionId": "ss-1"}, game.CodeTooFewPlayers)
	if ack.Message != "A sideshow needs at least 3 players in the hand" {
		t.Fatalf("message %q", ack.Message)
	}
	st.mustFail(d.waiting.c, EvGameSideshowResp, map[string]any{"accept": true}, game.CodeNoSideshow)
	// Unseated → not_in_room first.
	loner := st.player("Loner")
	st.mustFail(loner.c, EvGameSideshowResp, map[string]any{"accept": true}, game.CodeNotInRoom)
	if !d.table.HasHand() {
		t.Fatalf("the hand ended")
	}
}

func TestSeeingTwiceAndSeeNeverMovesTheTurn(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	before := st.turnSeat(d.table, d.a.user.ID)
	st.mustOK(d.waiting.c, EvGameAction, map[string]any{"action": "see", "actionId": "see-1"})
	st.mustFail(d.waiting.c, EvGameAction, map[string]any{"action": "see", "actionId": "see-2"}, game.CodeAlreadySeen)
	if st.turnSeat(d.table, d.a.user.ID) != before {
		t.Fatalf("see moved the turn")
	}
	seat, err := d.table.FindSeat(d.waiting.user.ID)
	if err != nil || seat == nil || seat.IsBlind {
		t.Fatalf("seat after see: %+v %v", seat, err)
	}
}

func TestReplayedActionIDChargesNobodyTwice(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	amount := st.view(d.table, d.onTurn.user.ID).Stake
	walletBefore := st.users.chips(d.onTurn.user.ID)
	first := st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal", "amount": amount, "actionId": "dup-same-id"})
	if str(first.Raw, "action") != "chaal" || num(first.Raw, "amount") != float64(amount) || field(first.Raw, "autoSeen") != false {
		t.Fatalf("chaal ack %s", first.Raw)
	}
	// A bet writes nothing to the books until the hand ends (owner's decision
	// of 9 Sep 2026): the chips have moved at the seat and in the live store
	// only, so no ledger row and no wallet movement yet.
	if st.books.rows("dup-same-id") != 0 {
		t.Fatalf("a bet reached the books before the hand ended")
	}
	if st.users.chips(d.onTurn.user.ID) != walletBefore {
		t.Fatalf("wallet moved on a bet: %d, want %d", st.users.chips(d.onTurn.user.ID), walletBefore)
	}
	// The turn has moved on, so the replay fails the turn check first.
	st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal", "amount": amount, "actionId": "dup-same-id"}, "")
	// Now it IS the other player's turn: a replay of a used id is refused as
	// duplicate_action, and the pot stays put.
	other := d.waiting
	pot := st.view(d.table, other.user.ID).Pot
	st.mustOK(other.c, EvGameAction, map[string]any{"action": "chaal", "actionId": "other-1"})
	// Back to the first player, who replays a spent id: refused, uncharged.
	st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal", "actionId": "dup-same-id"}, game.CodeDuplicateAction)
	if st.view(d.table, other.user.ID).Pot != pot+amount {
		t.Fatalf("pot moved on a duplicate")
	}
	// An out-of-range actionId is silently replaced by a server uuid (no
	// idempotency, but a legal move): 65 UTF-16 units — 33 emoji — is too
	// long; a 64-unit one is honoured verbatim.
	longID := strings.Repeat("😀", 33)
	if utf16Len(longID) != 66 {
		t.Fatalf("utf16Len = %d", utf16Len(longID))
	}
	st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal", "actionId": longID})
	exact := strings.Repeat("😀", 32)
	st.mustOK(other.c, EvGameAction, map[string]any{"action": "chaal", "actionId": exact})

	// End the hand. The wallet catches up in ONE row per player, under a
	// server-minted action id — no client id ever reaches the ledger now
	// (owner's decision of 9 Sep 2026), so the ids above are audit-invisible
	// and can only ever have been idempotency tokens.
	walletBeforeEnd := st.users.chips(d.onTurn.user.ID)
	staked := st.view(d.table, d.onTurn.user.ID).You.Contributed
	st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "pack"})
	ended, err := other.c.Wait(EvGameHandEnded, nil, eventTimeout)
	if err != nil {
		t.Fatalf("hand never ended: %v", err)
	}
	_ = ended
	for _, id := range []string{"dup-same-id", longID, exact, "other-1"} {
		if n := st.books.rows(id); n != 0 {
			t.Fatalf("a client action id reached the ledger: %q has %d rows", id, n)
		}
	}
	handID := str(d.handStarted, "handId")
	if n := st.books.rows(handID + ":packed:" + d.onTurn.user.ID); n != 1 {
		t.Fatalf("the pack checkpoint wrote %d rows", n)
	}
	if n := st.books.rows(handID + ":settle:" + d.onTurn.user.ID); n != 1 {
		t.Fatalf("the outcome row was written %d times", n)
	}
	if got := st.users.chips(d.onTurn.user.ID); got != walletBeforeEnd-staked {
		t.Fatalf("wallet %d, want %d (their whole stake, charged once)", got, walletBeforeEnd-staked)
	}
}

func TestRequestCardsAndNoLeakOfOthersCards(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	loner := st.player("Cara")
	st.mustFail(loner.c, EvPlayerReqCards, map[string]any{}, game.CodeNotInRoom)

	// Blind: [] and no player:cards emitted.
	mark := d.onTurn.c.Mark()
	ack := st.mustOK(d.onTurn.c, EvPlayerReqCards, map[string]any{})
	if cards, ok := field(ack.Raw, "cards").([]any); !ok || len(cards) != 0 {
		t.Fatalf("blind requestCards: %s", ack.Raw)
	}
	if len(d.onTurn.c.Since(mark)) != 0 {
		t.Fatalf("player:cards emitted while blind: %v", names(d.onTurn.c.Since(mark)))
	}
	// Seen: the cards, plus a player:cards event to this socket.
	st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "see"})
	mark = d.onTurn.c.Mark()
	ack = st.mustOK(d.onTurn.c, EvPlayerReqCards, map[string]any{})
	if len(arr(ack.Raw, "cards")) != 3 {
		t.Fatalf("seen requestCards: %s", ack.Raw)
	}
	if n := names(d.onTurn.c.Since(mark)); len(n) != 1 || n[0] != EvPlayerCards {
		t.Fatalf("requestCards events %v", n)
	}
	// The other player's cards are never in anything this client receives.
	seat, _ := d.table.FindSeat(d.waiting.user.ID)
	if seat == nil || len(seat.Cards) != 3 {
		t.Fatalf("no cards on the other seat")
	}
	state, _ := d.onTurn.c.Last(EvRoomState)
	other := seatOf(state, d.waiting.user.ID)
	if _, present := other["cards"]; present {
		t.Fatalf("another seat carries cards: %v", other)
	}
	frames := strings.Join(d.waiting.c.Frames(), "\n")
	if strings.Contains(frames, `"cards":["`) {
		t.Fatalf("a card list reached the blind player: %s", frames)
	}
	// And the on-turn player's frames only ever contained their own hand.
	own := map[string]bool{}
	for _, c := range arr(ack.Raw, "cards") {
		own[c.(string)] = true
	}
	for _, c := range seat.Cards {
		if own[c.Code()] {
			t.Fatalf("the two hands overlap; test cannot tell them apart")
		}
		if strings.Contains(strings.Join(d.onTurn.c.Frames(), "\n"), `"`+c.Code()+`"`) {
			t.Fatalf("the other player's card %s reached this socket", c.Code())
		}
	}
}

func TestSeatingRefusals(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	st.mustFail(d.onTurn.c, EvRoomQuickJoin, map[string]any{"bootAmount": d.boot}, game.CodeAlreadyInRoom)
	ack := st.mustFail(d.onTurn.c, EvRoomJoinCode, map[string]any{"code": "NOPE00"}, "")
	if ack.Code != game.CodeAlreadyInRoom && ack.Code != game.CodeRoomNotFound {
		t.Fatalf("seated joinCode → %s", ack.Raw)
	}
	// Opening a private room is a way in as well, and it is shut to a seated
	// player — before any table is created (DECISIONS.md §3).
	tables := st.rooms.Stats().Tables
	st.mustFail(d.onTurn.c, EvRoomCreate, map[string]any{"isPrivate": true}, game.CodeAlreadyInRoom)
	if st.rooms.Stats().Tables != tables {
		t.Fatalf("a refused create left a table behind")
	}
	if st.rooms.GetTableForPlayer(d.onTurn.user.ID) != d.table {
		t.Fatalf("seat lost")
	}
	st.mustFail(d.onTurn.c, EvRoomSwitch, map[string]any{}, game.CodeNoOtherTable)

	loner := st.player("Cara")
	ack = st.mustFail(loner.c, EvRoomJoinCode, map[string]any{"code": "NOPE00"}, game.CodeRoomNotFound)
	if ack.Message != "No table with that code" {
		t.Fatalf("message %q", ack.Message)
	}
	st.mustFail(loner.c, EvRoomJoinCode, map[string]any{"code": map[string]any{"$gt": ""}}, game.CodeRoomNotFound)
	st.mustFail(loner.c, EvRoomJoinCode, map[string]any{}, game.CodeRoomNotFound)
	ack = st.mustFail(loner.c, EvRoomQuickJoin, map[string]any{"bootAmount": -5}, game.CodeInvalidStake)
	if ack.Message != "That stake is not valid" {
		t.Fatalf("message %q", ack.Message)
	}
	st.mustFail(loner.c, EvRoomQuickJoin, map[string]any{"bootAmount": "lots"}, game.CodeInvalidStake)
	st.mustFail(loner.c, EvRoomQuickJoin, map[string]any{"bootAmount": 0}, game.CodeInvalidStake)
	st.mustFail(loner.c, EvRoomQuickJoin, map[string]any{"bootAmount": 200.5}, game.CodeInvalidStake)
	// A null payload is read as "the defaults": a legitimate quick-join at
	// the default stake (DECISIONS.md §7).
	ok := st.mustOK(loner.c, EvRoomQuickJoin, null())
	if st.rooms.GetTable(str(ok.Raw, "roomId")).BootAmount() != st.cfg.Game.BootAmount {
		t.Fatalf("null payload did not join at the default boot")
	}
	st.mustOK(loner.c, EvRoomLeave, map[string]any{})
	// bootAmount: null is the default too.
	ok = st.mustOK(loner.c, EvRoomQuickJoin, map[string]any{"bootAmount": null()})
	if st.rooms.GetTable(str(ok.Raw, "roomId")).BootAmount() != st.cfg.Game.BootAmount {
		t.Fatalf("null bootAmount did not join at the default boot")
	}
}

func TestUnfundedPlayerIsNotSeated(t *testing.T) {
	st := newStack(t, nil)
	poor := st.player("Poor")
	st.users.setChips(poor.user.ID, 50)
	ack := st.mustFail(poor.c, EvRoomQuickJoin, map[string]any{"bootAmount": st.uniqueStake()}, game.CodeInsufficientChips)
	if ack.Message != "Not enough chips to join this table" {
		t.Fatalf("message %q", ack.Message)
	}
	if st.rooms.GetTableForPlayer(poor.user.ID) != nil {
		t.Fatalf("seated")
	}
	// The join re-reads the wallet: the handshake snapshot (200000) is stale.
	host := st.player("Host")
	created := st.mustOK(host.c, EvRoomCreate, map[string]any{"isPrivate": true})
	st.mustFail(poor.c, EvRoomJoinCode, map[string]any{"code": str(created.Raw, "code")}, game.CodeInsufficientChips)
}

func TestSixthPlayerIsRefused(t *testing.T) {
	st := newStack(t, nil)
	table := st.rooms.CreateTable(game.CreateTableOptions{BootAmount: st.uniqueStake(), IsPrivate: true})
	for i := 0; i < 5; i++ {
		p := st.player(fmt.Sprintf("F%d", i))
		st.mustOK(p.c, EvRoomJoinCode, map[string]any{"code": table.Code()})
	}
	extra := st.player("FX")
	ack := st.mustFail(extra.c, EvRoomJoinCode, map[string]any{"code": table.Code()}, game.CodeTableFull)
	if ack.Message != "That table is full" {
		t.Fatalf("message %q", ack.Message)
	}
}

func TestChatCoercionLengthAndBlank(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	mark := d.waiting.c.Mark()
	// Five sends: the chat allowance is five per five seconds, and every send
	// counts whether or not anything is posted.
	for _, payload := range []any{map[string]any{"text": "   "}, map[string]any{"text": strings.Repeat("x", 5000)}, map[string]any{"text": 12345}, null(), map[string]any{"text": "hello table"}} {
		ack := st.call(d.onTurn.c, EvChatMessage, payload)
		if !ack.OK {
			t.Fatalf("chat %s refused: %s", jsonOf(payload), ack.Raw)
		}
	}
	// The sixth is over the allowance.
	st.mustFail(d.onTurn.c, EvChatMessage, map[string]any{"text": "sixth"}, game.CodeChatRateLimited)
	if _, err := d.waiting.c.WaitFrom(mark, EvChatMessageOut, func(p json.RawMessage) bool { return str(p, "text") == "hello table" }, eventTimeout); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	heard := []string{}
	for _, e := range d.waiting.c.Since(mark) {
		if e.Name == EvChatMessageOut {
			heard = append(heard, str(e.Payload, "text"))
		}
	}
	if len(heard) != 3 || len(heard[0]) != 140 || heard[1] != "12345" || heard[2] != "hello table" {
		t.Fatalf("heard %q", heard)
	}
	// DECISIONS.md §4: objects, arrays, booleans and null are empty text.
	for _, payload := range []any{map[string]any{"text": map[string]any{}}, map[string]any{"text": []any{"a"}}, map[string]any{"text": true}, map[string]any{"text": null()}} {
		time.Sleep(0)
		ack := st.call(d.waiting.c, EvChatMessage, payload)
		if !ack.OK || has(ack.Raw, "messageId") {
			t.Fatalf("chat %s → %s", jsonOf(payload), ack.Raw)
		}
	}
	// A number is said as its digits in Number#toString form.
	ack := st.mustOK(d.waiting.c, EvChatMessage, map[string]any{"text": json.RawMessage(`1e3`)})
	if str(ack.Raw, "messageId") == "" {
		t.Fatalf("numeric chat not posted: %s", ack.Raw)
	}
	if _, err := d.onTurn.c.Wait(EvChatMessageOut, func(p json.RawMessage) bool { return str(p, "text") == "1000" }, eventTimeout); err != nil {
		t.Fatal(err)
	}
}

func TestGarbageOnEveryEventIsAcked(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	garbage := []any{
		testclient.NoPayload{}, null(), 42, "string", []any{}, []any{1, 2},
		map[string]any{"action": null()}, map[string]any{"action": map[string]any{}}, map[string]any{"amount": map[string]any{}},
		map[string]any{"action": "chaal", "amount": "1e3"}, map[string]any{"action": "chaal", "amount": []any{100}},
		map[string]any{"action": "raise", "amount": true}, json.RawMessage(`{"__proto__":{"action":"pack"}}`),
	}
	events := []string{EvGameAction, EvGameSideshowResp, EvRoomQuickJoin, EvRoomJoinCode, EvRoomCreate, EvChatMessage}
	for _, payload := range garbage {
		for _, event := range events {
			raw, err := d.onTurn.c.Request(event, payload, 1500*time.Millisecond)
			if err != nil {
				t.Fatalf("%s %s was not acknowledged: %v", event, jsonOf(payload), err)
			}
			if event == EvChatMessage {
				if has(raw, "messageId") {
					t.Fatalf("%s %s posted something: %s", event, jsonOf(payload), raw)
				}
			} else if field(raw, "ok") != false {
				t.Fatalf("%s %s was not refused: %s", event, jsonOf(payload), raw)
			}
			if str(raw, "code") == game.CodeInternalError {
				t.Fatalf("%s %s crashed the handler: %s", event, jsonOf(payload), raw)
			}
		}
	}
	if !d.table.HasHand() {
		t.Fatalf("the hand did not survive")
	}
	if !d.onTurn.c.Connected() {
		t.Fatalf("the socket did not survive")
	}
	// That many requests trip the per-socket limiter (30 / 5 s), by design —
	// every one of them was still acked. Once the window has passed the table
	// works for honest play again.
	if v := metricValue(st.metrics.SocketErrorsTotal.WithLabelValues(game.CodeRateLimited)); v == 0 {
		t.Fatalf("the burst never tripped the limiter")
	}
	time.Sleep(5200 * time.Millisecond)
	st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "pack", "actionId": "garbage-pack"})
}

func TestBurstIsRateLimitedButAcked(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	// invalidMoves.test.js:437 — 60 parallel lobby:list.
	var wg sync.WaitGroup
	var mu sync.Mutex
	acks := []testclient.Ack{}
	for i := 0; i < 60; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ack, err := d.onTurn.c.Call(EvLobbyList, map[string]any{"i": i}, ackTimeout)
			if err != nil {
				t.Errorf("lobby:list %d: %v", i, err)
				return
			}
			mu.Lock()
			acks = append(acks, ack)
			mu.Unlock()
		}(i)
	}
	wg.Wait()
	limited := 0
	for _, a := range acks {
		if !a.OK {
			if a.Code != game.CodeRateLimited || a.Message != MsgRateLimited {
				t.Fatalf("unexpected refusal %s", a.Raw)
			}
			limited++
		}
	}
	// The player had already spent one request (quickJoin): 29 more pass.
	if limited != 31 {
		t.Fatalf("limited %d of 60, want 31", limited)
	}
	errs := d.onTurn.c.All(EvGameError)
	rl := 0
	for _, e := range errs {
		if str(e, "code") == game.CodeRateLimited && str(e, "message") == MsgRateLimited {
			rl++
		}
	}
	if rl != limited {
		t.Fatalf("game:error rate_limited %d, acks %d", rl, limited)
	}
	if !d.onTurn.c.Connected() {
		t.Fatalf("socket dropped")
	}
	// game_invalid_moves_total is not touched by rate limiting, even for game:action.
	before := metricValue(st.metrics.InvalidMovesTotal.WithLabelValues(game.CodeRateLimited))
	st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "pack"}, game.CodeRateLimited)
	if metricValue(st.metrics.InvalidMovesTotal.WithLabelValues(game.CodeRateLimited)) != before {
		t.Fatalf("invalid_moves_total counted a rate limit")
	}
	if v := metricValue(st.metrics.SocketErrorsTotal.WithLabelValues(game.CodeRateLimited)); v != 32 {
		t.Fatalf("socket_errors_total{rate_limited} = %v", v)
	}
	// Every refused message was still counted as received.
	if v := metricValue(st.metrics.SocketMessagesTotal.WithLabelValues(EvLobbyList)); v != 60 {
		t.Fatalf("socket_messages_total{lobby:list} = %v", v)
	}
}

func TestBooksBalanceAfterEverything(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "see"})
	st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "show"})
	if _, err := d.a.c.Wait(EvGameHandEnded, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}
	// Chips are conserved across the two wallets: boots and the show went
	// into the pot and the pot went to the winner.
	eventually(t, eventTimeout, func() bool {
		return st.users.chips(d.a.user.ID)+st.users.chips(d.b.user.ID) == 2*welcomeChips
	}, "chips conserved")
}
