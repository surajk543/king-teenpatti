package socket

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// Mirrors of server/test/integration.test.js (socket parts), the connect /
// replace / resume paths of socket/index.js, and the exact event order on
// join, leave and consolidation (DECISIONS.md §1 "Reproduce exactly").

// ---------------------------------------------------------------- handshake

func TestHandshakeRefusals(t *testing.T) {
	st := newStack(t, nil)
	ctx := context.Background()

	// integration.test.js:225 — garbage token.
	c, err := testclient.Dial(ctx, st.ts.URL, "garbage")
	if c != nil {
		st.track(c)
	}
	var ce *testclient.ConnectError
	if !asConnectError(err, &ce) || ce.Message != auth.CodeInvalidSession {
		t.Fatalf("garbage token: got %v, want connect_error invalid_session", err)
	}

	// No auth object at all → missing_token.
	c, err = testclient.DialAuth(ctx, st.ts.URL, nil)
	if c != nil {
		st.track(c)
	}
	if !asConnectError(err, &ce) || ce.Message != auth.CodeMissingToken {
		t.Fatalf("no token: got %v, want missing_token", err)
	}

	// {"token": ""} is not nullish: verifyToken("") → missing_token.
	c, err = testclient.DialAuth(ctx, st.ts.URL, json.RawMessage(`{"token":""}`))
	if c != nil {
		st.track(c)
	}
	if !asConnectError(err, &ce) || ce.Message != auth.CodeMissingToken {
		t.Fatalf("empty token: got %v, want missing_token", err)
	}

	// A well-formed token for an account that no longer exists.
	ghost, ghostTok := st.login("Ghost")
	st.users.mu.Lock()
	delete(st.users.users, ghost.ID)
	st.users.mu.Unlock()
	c, err = testclient.Dial(ctx, st.ts.URL, ghostTok)
	if c != nil {
		st.track(c)
	}
	if !asConnectError(err, &ce) || ce.Message != auth.CodeUnknownUser {
		t.Fatalf("unknown user: got %v, want unknown_user", err)
	}

	// DECISIONS.md §1: a database failure during findById is `unauthorized`,
	// never a SQLSTATE.
	_, tok := st.login("Unlucky")
	st.users.setFailure(errDB)
	c, err = testclient.Dial(ctx, st.ts.URL, tok)
	if c != nil {
		st.track(c)
	}
	st.users.setFailure(nil)
	if !asConnectError(err, &ce) || ce.Message != auth.CodeUnauthorized {
		t.Fatalf("db outage: got %v, want unauthorized", err)
	}

	// The human-readable AuthError.message never reaches the socket client.
	if strings.Contains(ce.Message, " ") {
		t.Fatalf("connect_error carries a sentence, want the bare code: %q", ce.Message)
	}
}

func TestHandshakeTokenSources(t *testing.T) {
	st := newStack(t, nil)
	ctx := context.Background()
	u, tok := st.login("Query")

	// The legacy ?token= query fallback (DECISIONS.md §1: kept).
	c, err := testclient.DialQuery(ctx, st.ts.URL, "token="+tok)
	if err != nil {
		t.Fatalf("query token: %v", err)
	}
	st.track(c)
	ready, err := c.Wait(EvSessionReady, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(ready, "user.id") != u.ID {
		t.Fatalf("session:ready.user.id = %q, want %q", str(ready, "user.id"), u.ID)
	}
	if has(ready, "resume") {
		t.Fatalf("resume must be ABSENT without an offer: %s", ready)
	}
	// config carries the lobby menu spread in (integration.test.js:512).
	cats := arr(ready, "config.categories")
	if len(cats) != 2 || cats[0] != "seen" || cats[1] != "blind" {
		t.Fatalf("config.categories = %v", cats)
	}
	if field(ready, "config.stakes") == nil || field(ready, "config.tables") == nil {
		t.Fatalf("config.stakes/tables must be arrays, never null: %s", ready)
	}
	if num(ready, "config.maxPlayers") != 5 || num(ready, "config.bootAmount") != 100 || num(ready, "config.turnTimeoutMs") != 60000 {
		t.Fatalf("config numbers: %s", field(ready, "config"))
	}
	// maxBetRounds is the GLOBAL default (20), not the seen table's 7.
	if num(ready, "config.maxBetRounds") != 20 {
		t.Fatalf("config.maxBetRounds = %v, want 20", num(ready, "config.maxBetRounds"))
	}

	// auth.token null falls through to the query token (`??`).
	c2, err := testclient.DialAuth(ctx, st.ts.URL, json.RawMessage(`{"token":null}`))
	if c2 != nil {
		st.track(c2)
	}
	var ce *testclient.ConnectError
	if !asConnectError(err, &ce) || ce.Message != auth.CodeMissingToken {
		t.Fatalf("null token, no query: got %v, want missing_token", err)
	}

	// A non-string auth token is handed to the verifier verbatim → invalid_session.
	c3, err := testclient.DialAuth(ctx, st.ts.URL, json.RawMessage(`{"token":12345}`))
	if c3 != nil {
		st.track(c3)
	}
	if !asConnectError(err, &ce) || ce.Message != auth.CodeInvalidSession {
		t.Fatalf("numeric token: got %v, want invalid_session", err)
	}
}

func asConnectError(err error, target **testclient.ConnectError) bool {
	ce, ok := err.(*testclient.ConnectError)
	if ok {
		*target = ce
	}
	return ok
}

// ------------------------------------------------------------------- lobby

func TestQuickJoinDealsAHandAndRedactsCards(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	alice := st.player("Alice")
	bob := st.player("Bob")

	// integration.test.js:232 — same unique boot → same room.
	j1 := st.mustOK(alice.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	j2 := st.mustOK(bob.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	if str(j1.Raw, "roomId") != str(j2.Raw, "roomId") {
		t.Fatalf("different rooms: %s vs %s", j1.Raw, j2.Raw)
	}
	if !regexp.MustCompile(`^[A-Z2-9]{6}$`).MatchString(str(j1.Raw, "code")) {
		t.Fatalf("room code %q", str(j1.Raw, "code"))
	}
	if str(j1.Raw, "category") != "seen" {
		t.Fatalf("default category %q, want seen", str(j1.Raw, "category"))
	}

	started, err := alice.c.Wait(EvGameHandStarted, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if len(arr(started, "participants")) != 2 || num(started, "pot") != float64(2*boot) || num(started, "handNo") != 1 {
		t.Fatalf("handStarted: %s", started)
	}
	if str(started, "roomId") != str(j1.Raw, "roomId") {
		t.Fatalf("handStarted.roomId missing: %s", started)
	}

	betting, err := alice.c.Wait(EvRoomState, func(p json.RawMessage) bool { return str(p, "state") == "betting" }, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if num(betting, "maxPlayers") != 5 || num(betting, "minPlayers") != 2 {
		t.Fatalf("room:state: %s", betting)
	}
	cards, ok := field(betting, "you.cards").([]any)
	if !ok || len(cards) != 0 {
		t.Fatalf("you.cards must be [] while blind: %v", field(betting, "you.cards"))
	}
	if len(arr(betting, "seats")) != 5 {
		t.Fatalf("seats must have exactly maxPlayers entries: %s", betting)
	}
	// Other seats carry cardCount only — never cards.
	other := seatOf(betting, bob.user.ID)
	if other == nil {
		t.Fatalf("bob's seat missing: %s", betting)
	}
	if _, present := other["cards"]; present {
		t.Fatalf("another seat carries cards: %v", other)
	}
	if other["cardCount"] != float64(3) {
		t.Fatalf("cardCount = %v, want 3", other["cardCount"])
	}
	// Empty seats are exactly {seatIndex, status:"empty"}.
	for _, s := range arr(betting, "seats") {
		m := s.(map[string]any)
		if m["status"] == "empty" && len(m) != 2 {
			t.Fatalf("empty seat has extra keys: %v", m)
		}
	}
	// player:hand went to every viewer, cards hidden.
	ph, err := bob.c.Wait(EvPlayerHand, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if field(ph, "dealt") != true || field(ph, "cardsHidden") != true {
		t.Fatalf("player:hand: %s", ph)
	}
	// No card code has crossed the wire to anyone yet.
	for _, c := range []*testclient.Client{alice.c, bob.c} {
		for _, f := range c.Frames() {
			if strings.Contains(f, `"cards":["`) {
				t.Fatalf("card list leaked before anyone looked: %s", f)
			}
		}
	}
	// game:turn to the room has no options; game:yourTurn only to the player on turn.
	turn, err := alice.c.Wait(EvGameTurn, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if has(turn, "options") || str(turn, "roomId") == "" || num(turn, "timeoutMs") != 60000 {
		t.Fatalf("game:turn: %s", turn)
	}
	onTurnID := str(turn, "userId")
	onTurn, waiting := alice, bob
	if onTurnID == bob.user.ID {
		onTurn, waiting = bob, alice
	}
	yt, err := onTurn.c.Wait(EvGameYourTurn, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if num(yt, "options.chaal") != float64(boot) || num(yt, "options.raise") != float64(2*boot) || field(yt, "options.canSee") != true {
		t.Fatalf("game:yourTurn.options: %s", yt)
	}
	time.Sleep(100 * time.Millisecond)
	if len(waiting.c.All(EvGameYourTurn)) != 0 {
		t.Fatalf("the waiting player received game:yourTurn")
	}
	// The viewer's own snapshot carries options only for the player on turn.
	ws := st.view(st.rooms.GetTable(str(j1.Raw, "roomId")), waiting.user.ID)
	if ws.You == nil || ws.You.Options != nil {
		t.Fatalf("waiting player's you.options must be null")
	}
}

func TestFullHandSeeAndShow(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")

	// integration.test.js:259
	seeAck := st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "see", "actionId": "see-1"})
	if str(seeAck.Raw, "action") != "see" || field(seeAck.Raw, "auto") != false {
		t.Fatalf("see ack: %s", seeAck.Raw)
	}
	cards, err := d.onTurn.c.Wait(EvPlayerCards, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	codes := arr(cards, "cards")
	if len(codes) != 3 || str(cards, "roomId") != d.roomID {
		t.Fatalf("player:cards: %s", cards)
	}
	codeRe := regexp.MustCompile(`^[2-9TJQKA][shdc]$`)
	for _, c := range codes {
		if !codeRe.MatchString(c.(string)) {
			t.Fatalf("bad card code %v", c)
		}
	}
	// The see is announced to the room with auto:false, and the turn is re-issued.
	act, err := d.waiting.c.Wait(EvGameActionOut, func(p json.RawMessage) bool { return str(p, "action") == "see" }, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if field(act, "auto") != false || has(act, "reason") || num(act, "amount") != 0 {
		t.Fatalf("game:action see: %s", act)
	}
	time.Sleep(100 * time.Millisecond)
	if len(d.waiting.c.All(EvPlayerCards)) != 0 {
		t.Fatalf("the opponent received player:cards")
	}
	// Their room:state now carries the cards for them alone.
	view := st.view(d.table, d.onTurn.user.ID)
	if len(view.You.Cards) != 3 {
		t.Fatalf("you.cards after see: %v", view.You.Cards)
	}
	oview := st.view(d.table, d.waiting.user.ID)
	if len(oview.You.Cards) != 0 {
		t.Fatalf("the blind opponent sees cards: %v", oview.You.Cards)
	}

	// A show with exactly two players ends the hand.
	showAck := st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "show", "actionId": "show-1"})
	if str(showAck.Raw, "action") != "show" || num(showAck.Raw, "amount") <= 0 {
		t.Fatalf("show ack: %s", showAck.Raw)
	}
	ended, err := d.waiting.c.Wait(EvGameHandEnded, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(ended, "winnerId") == "" || num(ended, "pot") != float64(4*d.boot) || len(arr(ended, "reveals")) != 2 || str(ended, "reason") != "show" {
		t.Fatalf("handEnded: %s", ended)
	}
	if num(ended, "nextHandAt") <= 0 || str(ended, "roomId") != d.roomID {
		t.Fatalf("handEnded roomId/nextHandAt: %s", ended)
	}
	showdown, err := d.onTurn.c.Wait(EvGameShowdown, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if len(arr(showdown, "reveals")) != 2 {
		t.Fatalf("showdown: %s", showdown)
	}
	for _, r := range arr(showdown, "reveals") {
		m := r.(map[string]any)
		if len(m["cards"].([]any)) != 3 || m["handName"] == "" {
			t.Fatalf("reveal: %v", m)
		}
	}
	// The books: the winner's wallet grew by the loser's stake.
	winner := str(ended, "winnerId")
	eventually(t, time.Second, func() bool { return st.users.chips(winner) > welcomeChips }, "winner paid")
}

func TestActingOutOfTurnIsRefused(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	ack := st.mustFail(d.waiting.c, EvGameAction, map[string]any{"action": "chaal", "actionId": "oot"}, game.CodeNotYourTurn)
	if ack.Message != game.MsgNotYourTurn {
		t.Fatalf("message %q", ack.Message)
	}
	// Refusals reach the client twice: ack then game:error (clients dedupe).
	ge, err := d.waiting.c.Wait(EvGameError, func(p json.RawMessage) bool { return str(p, "code") == game.CodeNotYourTurn }, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(ge, "message") != game.MsgNotYourTurn {
		t.Fatalf("game:error: %s", ge)
	}
}

func TestTurnTimeoutPacksAndEndsTheHand(t *testing.T) {
	st := newStack(t, func(cfg *config.Config) { cfg.Game.TurnTimeout = 300 * time.Millisecond })
	d := st.dealtTable("")
	// integration.test.js:337 — nobody acts.
	ended, err := d.waiting.c.Wait(EvGameHandEnded, nil, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if str(ended, "reason") != "last_standing" || str(ended, "winnerId") != d.waiting.user.ID {
		t.Fatalf("handEnded: %s", ended)
	}
	timeout, err := d.waiting.c.Wait(EvGameActionOut, func(p json.RawMessage) bool { return str(p, "reason") == "timeout" }, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(timeout, "action") != "pack" || num(timeout, "amount") != 0 || str(timeout, "userId") != d.onTurn.user.ID {
		t.Fatalf("timeout pack: %s", timeout)
	}
	if v := metricValue(st.metrics.TurnTimeoutsTotal); v < 1 {
		t.Fatalf("turn_timeouts_total = %v", v)
	}
	// The stalled player is warned in their own view only.
	view := st.view(d.table, d.onTurn.user.ID)
	if view.You.MissedTurns < 1 {
		t.Fatalf("missedTurns = %d", view.You.MissedTurns)
	}
}

func TestTableHoldsFivePlayers(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	rooms := map[string]int{}
	for i := 0; i < 6; i++ {
		p := st.player("P")
		ack := st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
		rooms[str(ack.Raw, "roomId")]++
	}
	if len(rooms) != 2 {
		t.Fatalf("rooms: %v", rooms)
	}
	counts := []int{}
	for _, n := range rooms {
		counts = append(counts, n)
	}
	if !(counts[0] == 5 && counts[1] == 1) && !(counts[0] == 1 && counts[1] == 5) {
		t.Fatalf("counts: %v", counts)
	}
}

func TestPrivateRoomCreateAndJoinByCode(t *testing.T) {
	st := newStack(t, nil)
	host := st.player("Host")
	guest := st.player("Guest")

	mark := host.c.Mark()
	created := st.mustOK(host.c, EvRoomCreate, map[string]any{"isPrivate": true, "bootAmount": 9999})
	code := str(created.Raw, "code")
	if !regexp.MustCompile(`^[A-Z2-9]{6}$`).MatchString(code) {
		t.Fatalf("code %q", code)
	}
	// room:create sends exactly room:joined + chat:history, no room:state.
	got := names(host.c.Since(mark))
	if strings.Join(got, ",") != EvRoomJoined+","+EvChatHistoryOut {
		t.Fatalf("creator received %v", got)
	}
	joined, _ := host.c.Last(EvRoomJoined)
	// Requirement 22: the boot is forced to privateBoot whatever was asked.
	if num(joined, "bootAmount") != 200 || num(joined, "maxPot") != 500000 {
		t.Fatalf("private table rules: boot %v maxPot %v", num(joined, "bootAmount"), num(joined, "maxPot"))
	}
	if str(created.Raw, "category") != "seen" {
		t.Fatalf("category %q", str(created.Raw, "category"))
	}
	table := st.rooms.GetTable(str(created.Raw, "roomId"))
	if table == nil || !table.IsPrivate() {
		t.Fatalf("private table not registered")
	}

	// Lower-case input is accepted; the ack names the same room.
	j := st.mustOK(guest.c, EvRoomJoinCode, map[string]any{"code": strings.ToLower(code)})
	if str(j.Raw, "roomId") != str(created.Raw, "roomId") {
		t.Fatalf("joinCode room %s != %s", j.Raw, created.Raw)
	}
	loner := st.player("Loner")
	st.mustFail(loner.c, EvRoomJoinCode, map[string]any{"code": "ZZZZZZ"}, game.CodeRoomNotFound)
	// A private table is never listed.
	list := st.mustOK(loner.c, EvLobbyList, map[string]any{})
	for _, row := range arr(list.Raw, "tables") {
		if row.(map[string]any)["roomId"] == str(created.Raw, "roomId") {
			t.Fatalf("private table listed: %s", list.Raw)
		}
	}
}

func TestPublicCreateIsValidatedLikeQuickJoin(t *testing.T) {
	// DECISIONS.md §3: a public room:create goes through the lobby checks.
	st := newStack(t, func(cfg *config.Config) {
		cfg.Game.TableStakes = []int64{200, 5000}
		cfg.Game.LobbyTables = []config.LobbyTable{{Category: "seen", BootAmount: 200}, {Category: "blind", BootAmount: 200}, {Category: "blind", BootAmount: 5000}}
	})
	p := st.player("Creator")
	st.mustFail(p.c, EvRoomCreate, map[string]any{"isPrivate": false, "bootAmount": 7}, game.CodeInvalidStake)
	st.mustFail(p.c, EvRoomCreate, map[string]any{"isPrivate": false, "bootAmount": 5000, "category": "seen"}, game.CodeTableNotOffered)
	st.users.setChips(p.user.ID, 100)
	st.mustFail(p.c, EvRoomCreate, map[string]any{"isPrivate": false, "bootAmount": 200}, game.CodeInsufficientChips)
	st.users.setChips(p.user.ID, 600000)
	ack := st.mustFail(p.c, EvRoomCreate, map[string]any{"isPrivate": null(), "bootAmount": 200, "category": "blind"}, game.CodeOverEntryCap)
	if ack.Message != "Players with more than 500,000 chips cannot join this table" {
		t.Fatalf("over_entry_cap message %q", ack.Message)
	}
	// Exactly the cap is allowed; the table is public and at the asked boot.
	st.users.setChips(p.user.ID, 500000)
	ok := st.mustOK(p.c, EvRoomCreate, map[string]any{"isPrivate": false, "bootAmount": 200, "category": "blind"})
	table := st.rooms.GetTable(str(ok.Raw, "roomId"))
	if table == nil || table.IsPrivate() || table.BootAmount() != 200 || table.Category() != game.CategoryBlind {
		t.Fatalf("public table: %+v", table)
	}
	// No orphan table is left by a refused create.
	if st.rooms.Stats().Tables != 1 {
		t.Fatalf("tables = %d, want 1", st.rooms.Stats().Tables)
	}
}

// null is a JSON null value for map payloads.
func null() json.RawMessage { return json.RawMessage("null") }

func TestLeavingFreesTheSeat(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Leaver")
	ack := st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": st.uniqueStake()})
	roomID := str(ack.Raw, "roomId")
	mark := p.c.Mark()
	left := st.mustOK(p.c, EvRoomLeave, map[string]any{})
	if str(left.Raw, "roomId") != roomID {
		t.Fatalf("room:leave ack: %s", left.Raw)
	}
	if st.rooms.GetTableForPlayer(p.user.ID) != nil {
		t.Fatalf("still seated")
	}
	// Last player: the leaver hears the table close BEFORE room:left (spec §11).
	got := names(p.c.Since(mark))
	closed := indexOf(p.c.Since(mark), EvRoomClosed, nil)
	leftAt := indexOf(p.c.Since(mark), EvRoomLeft, nil)
	if closed < 0 || leftAt != len(got)-1 || closed > leftAt {
		t.Fatalf("leave order %v", got)
	}
	if got[0] != EvChatMessageOut {
		t.Fatalf("first removal event %v, want the system chat line", got)
	}
	// The room:state sent while still tracked has you: null.
	for _, e := range p.c.Since(mark) {
		if e.Name == EvRoomState && field(e.Payload, "you") != nil {
			t.Fatalf("room:state after leaving still carries you: %s", e.Payload)
		}
	}
	// Leaving when unseated is {ok:true} with nothing else.
	again := st.mustOK(p.c, EvRoomLeave, map[string]any{})
	if string(again.Raw) != `{"ok":true}` {
		t.Fatalf("unseated leave ack %s", again.Raw)
	}
}

func TestLeaveMidHandOrder(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	mark := d.onTurn.c.Mark()
	st.mustOK(d.onTurn.c, EvRoomLeave, map[string]any{})
	evs := d.onTurn.c.Since(mark)
	got := names(evs)
	packAt := indexOf(evs, EvGameActionOut, func(p json.RawMessage) bool { return str(p, "reason") == "left" && str(p, "action") == "pack" })
	stateAt := indexOf(evs, EvRoomState, func(p json.RawMessage) bool { return field(p, "you") == nil && has(p, "you") })
	leftAt := indexOf(evs, EvRoomLeft, nil)
	if got[0] != EvChatMessageOut || packAt < 0 || stateAt < 0 || leftAt != len(got)-1 || packAt > leftAt || stateAt > leftAt {
		t.Fatalf("mid-hand leave order %v", got)
	}
	// The other player wins by last standing and stays seated.
	ended, err := d.waiting.c.Wait(EvGameHandEnded, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(ended, "reason") != "last_standing" || str(ended, "winnerId") != d.waiting.user.ID {
		t.Fatalf("handEnded: %s", ended)
	}
	if st.rooms.GetTableForPlayer(d.waiting.user.ID) == nil {
		t.Fatalf("the remaining player lost their seat")
	}
	// Their next snapshot shows the vacated seat as empty.
	view := st.view(d.table, d.waiting.user.ID)
	for _, s := range view.Seats {
		if s.UserID == d.onTurn.user.ID {
			t.Fatalf("leaver still seated: %+v", s)
		}
	}
}

func TestSecondSignInReplacesTheFirst(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	alice := st.player("Alice")
	bob := st.player("Bob")
	st.mustOK(alice.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	st.mustOK(bob.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	if _, err := alice.c.Wait(EvGameHandStarted, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}

	bobMark := bob.c.Mark()
	second := st.dial(alice.token)
	// integration.test.js:421 — the first socket is told, then dropped.
	replaced, err := alice.c.Wait(EvSessionReplaced, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(replaced, "message") != MsgSignedInElsewhere {
		t.Fatalf("session:replaced: %s", replaced)
	}
	if !alice.c.WaitClosed(2 * time.Second) {
		t.Fatalf("the replaced socket was not closed by the server")
	}
	// The new socket resumes the held seat: session:ready, room:state,
	// room:joined, chat:history — in that order (spec §11).
	if _, err := second.Wait(EvChatHistoryOut, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}
	got := names(second.Events())
	want := []string{EvSessionReady, EvRoomState, EvRoomJoined, EvChatHistoryOut}
	if strings.Join(got[:4], ",") != strings.Join(want, ",") {
		t.Fatalf("resume order %v, want %v", got, want)
	}
	ready, _ := second.Last(EvSessionReady)
	if has(ready, "resume") {
		t.Fatalf("a held seat is not offered: %s", ready)
	}
	joined, _ := second.Last(EvRoomJoined)
	if str(joined, "you.status") != "active" {
		t.Fatalf("resumed seat: %s", joined)
	}
	// Bob saw the seat flicker: connected:false then connected:true.
	sawOff := false
	eventually(t, eventTimeout, func() bool {
		for _, e := range bob.c.Since(bobMark) {
			if e.Name != EvRoomState {
				continue
			}
			seat := seatOf(e.Payload, alice.user.ID)
			if seat == nil {
				continue
			}
			if seat["connected"] == false {
				sawOff = true
			} else if sawOff && seat["connected"] == true {
				return true
			}
		}
		return false
	}, "bob sees alice disconnect then reconnect")
	// Counted as a seamless hand-over.
	if v := metricValue(st.metrics.SessionReplacedTotal); v != 1 {
		t.Fatalf("session_replaced_total = %v", v)
	}
	if v := metricValue(st.metrics.ReconnectsTotal.WithLabelValues("seat_held")); v != 1 {
		t.Fatalf("reconnects_total{seat_held} = %v", v)
	}
	// No grace timer is left armed for a seat that was handed over.
	st.h.mu.Lock()
	pending := len(st.h.pendingRemovals)
	st.h.mu.Unlock()
	if pending != 0 {
		t.Fatalf("pendingRemovals = %d", pending)
	}
	// The single-session map points at the new socket.
	if st.h.Stats().Sockets != 2 {
		t.Fatalf("Stats().Sockets = %d, want 2", st.h.Stats().Sockets)
	}
}

func TestBlindAndSeenTablesAreSeparateRooms(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	a := st.player("A")
	b := st.player("B")
	ja := st.mustOK(a.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot, "category": "blind"})
	jb := st.mustOK(b.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot, "category": "seen"})
	if str(ja.Raw, "category") != "blind" || str(jb.Raw, "category") != "seen" || str(ja.Raw, "roomId") == str(jb.Raw, "roomId") {
		t.Fatalf("%s / %s", ja.Raw, jb.Raw)
	}
	// integration.test.js:545 — an unknown category is treated as seen.
	c := st.player("C")
	jc := st.mustOK(c.c, EvRoomQuickJoin, map[string]any{"bootAmount": st.uniqueStake(), "category": "sneaky"})
	if str(jc.Raw, "category") != "seen" {
		t.Fatalf("sneaky → %s", jc.Raw)
	}
}

func TestSeenTableShowsEveryStackBlindHidesThem(t *testing.T) {
	st := newStack(t, nil)

	// integration.test.js:454
	seen := st.dealtTable("seen")
	view, err := seen.a.c.Wait(EvRoomState, func(p json.RawMessage) bool { return str(p, "state") == "betting" }, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(view, "category") != "seen" || field(view, "chipsHidden") != false {
		t.Fatalf("seen view: %s", view)
	}
	for _, s := range arr(view, "seats") {
		m := s.(map[string]any)
		if m["status"] == "empty" {
			continue
		}
		if chips, ok := m["chips"].(float64); !ok || chips <= 0 {
			t.Fatalf("seen seat chips: %v", m)
		}
	}

	// integration.test.js:479
	blind := st.dealtTable("blind")
	bview, err := blind.a.c.Wait(EvRoomState, func(p json.RawMessage) bool { return str(p, "state") == "betting" }, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if field(bview, "chipsHidden") != true {
		t.Fatalf("blind view: %s", bview)
	}
	if _, ok := field(bview, "you.chips").(float64); !ok {
		t.Fatalf("own chips must be a number: %s", bview)
	}
	for _, s := range arr(bview, "seats") {
		m := s.(map[string]any)
		if m["status"] == "empty" || m["userId"] == blind.a.user.ID {
			continue
		}
		v, present := m["chips"]
		if !present || v != nil {
			t.Fatalf("another player's chips must be null on a blind table: %v", m)
		}
	}
}

func TestLobbyListAndFilter(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Lister")
	list := st.mustOK(p.c, EvLobbyList, map[string]any{})
	if field(list.Raw, "tables") == nil || field(list.Raw, "options.categories") == nil {
		t.Fatalf("lobby:list: %s", list.Raw)
	}
	boot := st.uniqueStake()
	j := st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot, "category": "blind"})
	// integration.test.js:528
	blindOnly := st.mustOK(p.c, EvLobbyList, map[string]any{"category": "blind"})
	found := false
	for _, row := range arr(blindOnly.Raw, "tables") {
		m := row.(map[string]any)
		if m["category"] != "blind" {
			t.Fatalf("seen table in a blind list: %v", m)
		}
		if m["roomId"] == str(j.Raw, "roomId") {
			found = true
			if m["players"] != float64(1) || m["bootAmount"] != float64(boot) || m["state"] != "waiting" {
				t.Fatalf("summary row: %v", m)
			}
		}
	}
	if !found {
		t.Fatalf("own table not listed: %s", blindOnly.Raw)
	}
	seenOnly := st.mustOK(p.c, EvLobbyList, map[string]any{"category": "seen"})
	for _, row := range arr(seenOnly.Raw, "tables") {
		if row.(map[string]any)["category"] != "seen" {
			t.Fatalf("blind table in a seen list: %s", seenOnly.Raw)
		}
	}
	// A truthy non-string filter matches nothing; a falsy one means no filter.
	none := st.mustOK(p.c, EvLobbyList, map[string]any{"category": 42})
	if len(arr(none.Raw, "tables")) != 0 {
		t.Fatalf("numeric filter listed tables: %s", none.Raw)
	}
	all := st.mustOK(p.c, EvLobbyList, map[string]any{"category": null()})
	if len(arr(all.Raw, "tables")) == 0 {
		t.Fatalf("null filter listed nothing: %s", all.Raw)
	}
}

// -------------------------------------------------------------------- chat

func TestChatReachesTheRoomOnly(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	outsider := st.player("Outsider")
	st.mustOK(outsider.c, EvRoomQuickJoin, map[string]any{"bootAmount": st.uniqueStake()})

	ack := st.mustOK(d.a.c, EvChatMessage, map[string]any{"text": "hello table"})
	if str(ack.Raw, "messageId") == "" {
		t.Fatalf("chat ack: %s", ack.Raw)
	}
	msg, err := d.b.c.Wait(EvChatMessageOut, func(p json.RawMessage) bool { return str(p, "text") == "hello table" }, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(msg, "displayName") != "Alice" || str(msg, "userId") != d.a.user.ID || num(msg, "at") <= 0 || str(msg, "roomId") != d.roomID || str(msg, "id") != str(ack.Raw, "messageId") {
		t.Fatalf("chat:message: %s", msg)
	}
	// A player message has NO system key (socketProtocol.test.js:316).
	if has(msg, "system") {
		t.Fatalf("player message carries system: %s", msg)
	}
	time.Sleep(150 * time.Millisecond)
	for _, p := range outsider.c.All(EvChatMessageOut) {
		if str(p, "text") == "hello table" {
			t.Fatalf("chat leaked to another table")
		}
	}

	// integration.test.js:594 — a later joiner gets the backlog, oldest first,
	// including the system lines.
	st.mustOK(d.a.c, EvChatMessage, map[string]any{"text": "second line"})
	late := st.player("HistA")
	st.mustOK(late.c, EvRoomJoinCode, map[string]any{"code": d.code})
	hist, err := late.c.Wait(EvChatHistoryOut, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(hist, "roomId") != d.roomID {
		t.Fatalf("history roomId: %s", hist)
	}
	texts := []string{}
	for _, m := range arr(hist, "messages") {
		mm := m.(map[string]any)
		texts = append(texts, mm["text"].(string))
		if _, present := mm["roomId"]; present {
			t.Fatalf("history messages carry roomId: %v", mm)
		}
		if mm["displayName"] == "Table" && (mm["system"] != true || mm["userId"] != nil) {
			t.Fatalf("system line: %v", mm)
		}
	}
	joinedTexts := strings.Join(texts, "|")
	for _, want := range []string{"hello table", "second line", "HistA joined the table", "Alice joined the table"} {
		if !strings.Contains(joinedTexts, want) {
			t.Fatalf("history lacks %q: %v", want, texts)
		}
	}
	if idx := strings.Index(joinedTexts, "hello table"); idx > strings.Index(joinedTexts, "second line") {
		t.Fatalf("history not oldest first: %v", texts)
	}
	// Inbound chat:history re-sends the backlog and counts it.
	mark := late.c.Mark()
	count := st.mustOK(late.c, EvChatHistory, map[string]any{})
	if int(num(count.Raw, "count")) != len(texts) {
		t.Fatalf("chat:history count %s vs %d", count.Raw, len(texts))
	}
	if n := names(late.c.Since(mark)); len(n) != 1 || n[0] != EvChatHistoryOut {
		t.Fatalf("chat:history re-send: %v", n)
	}
}

func TestChatRules(t *testing.T) {
	st := newStack(t, nil)
	// integration.test.js:670 — not at a table.
	loner := st.player("Loner")
	st.mustFail(loner.c, EvChatMessage, map[string]any{"text": "hi"}, game.CodeNotInRoom)
	st.mustFail(loner.c, EvChatHistory, map[string]any{}, game.CodeNotInRoom)

	d := st.dealtTable("")
	// integration.test.js:701 — blank → ok, nothing posted, no messageId.
	blank := st.mustOK(d.a.c, EvChatMessage, map[string]any{"text": "   "})
	if has(blank.Raw, "messageId") || string(blank.Raw) != `{"ok":true}` {
		t.Fatalf("blank chat ack %s", blank.Raw)
	}
	// integration.test.js:681 — flooding trips the 5 / 5 s chat limiter.
	okCount, limited := 0, 0
	for i := 0; i < 12; i++ {
		ack := st.call(d.b.c, EvChatMessage, map[string]any{"text": "spam"})
		switch {
		case ack.OK:
			okCount++
		case ack.Code == game.CodeChatRateLimited:
			limited++
			if ack.Message != MsgChatRateLimited {
				t.Fatalf("chat_rate_limited message %q", ack.Message)
			}
		default:
			t.Fatalf("unexpected chat refusal %s", ack.Raw)
		}
	}
	if okCount < 3 || limited == 0 || okCount+limited != 12 {
		t.Fatalf("ok %d limited %d", okCount, limited)
	}
	// integration.test.js:643 — history dies with the room.
	d.a.leave(st)
	d.b.leave(st)
	eventually(t, eventTimeout, func() bool { return st.rooms.GetTable(d.roomID) == nil }, "table destroyed")
	fresh := st.player("Fresh")
	st.mustOK(fresh.c, EvRoomQuickJoin, map[string]any{"bootAmount": d.boot})
	hist, err := fresh.c.Wait(EvChatHistoryOut, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range arr(hist, "messages") {
		if m.(map[string]any)["text"] == "spam" {
			t.Fatalf("old chat survived the room: %s", hist)
		}
	}
}

// ---------------------------------------------------------- resume / grace

func TestReconnectInsideGraceRestoresTheSeat(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	// integration.test.js:720 — a force-closed app sends no room:leave.
	bobMark := d.b.c.Mark()
	d.a.c.Close()
	time.Sleep(100 * time.Millisecond)
	// Others see the seat held, disconnected.
	eventually(t, eventTimeout, func() bool {
		for _, e := range d.b.c.Since(bobMark) {
			if e.Name == EvRoomState {
				if seat := seatOf(e.Payload, d.a.user.ID); seat != nil && seat["connected"] == false {
					return true
				}
			}
		}
		return false
	}, "seat marked disconnected")
	if st.rooms.GetTableForPlayer(d.a.user.ID) == nil {
		t.Fatalf("the seat was given up inside the grace period")
	}

	back := st.connect(d.a.token)
	ready, _ := back.Last(EvSessionReady)
	if has(ready, "resume") {
		t.Fatalf("seat still held: resume must be absent: %s", ready)
	}
	joined, err := back.Wait(EvRoomJoined, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(joined, "roomId") != d.roomID || str(joined, "state") != "betting" || str(joined, "you.status") != "active" {
		t.Fatalf("resumed snapshot: %s", joined)
	}
	if seat := seatOf(joined, d.a.user.ID); seat == nil || seat["seatIndex"] != num(joined, "you.seatIndex") {
		t.Fatalf("seat mismatch: %s", joined)
	}
	if v := metricValue(st.metrics.ReconnectsTotal.WithLabelValues("seat_held")); v != 1 {
		t.Fatalf("reconnects_total{seat_held} = %v", v)
	}
	// The grace timer was cancelled: the seat survives well past 400 ms.
	time.Sleep(600 * time.Millisecond)
	if st.rooms.GetTableForPlayer(d.a.user.ID) == nil {
		t.Fatalf("the cancelled grace timer still removed the seat")
	}
}

func TestLapsedSeatIsOfferedBackOnce(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	// integration.test.js:750
	bobMark := d.b.c.Mark()
	d.a.c.Close()
	time.Sleep(800 * time.Millisecond) // past the 400 ms grace
	if st.rooms.GetTableForPlayer(d.a.user.ID) != nil {
		t.Fatalf("the seat was not given up")
	}
	// The removal reads as a pack with reason 'disconnected' to the others.
	if _, err := d.b.c.WaitFrom(bobMark, EvGameActionOut, func(p json.RawMessage) bool { return str(p, "reason") == "disconnected" }, eventTimeout); err != nil {
		t.Fatal(err)
	}

	back := st.connect(d.a.token)
	ready, _ := back.Last(EvSessionReady)
	resume := field(ready, "resume").(map[string]any)
	if resume["roomId"] != d.roomID || resume["code"] != d.code || resume["category"] != "seen" || resume["bootAmount"] != float64(d.boot) || len(resume) != 4 {
		t.Fatalf("resume = %v", resume)
	}
	time.Sleep(50 * time.Millisecond)
	if len(back.All(EvRoomJoined)) != 0 {
		t.Fatalf("no seat means no snapshot until they sit")
	}
	if v := metricValue(st.metrics.ReconnectsTotal.WithLabelValues("offer")); v != 1 {
		t.Fatalf("reconnects_total{offer} = %v", v)
	}
	// The client takes the offer up with the ordinary join-by-code.
	rejoined := st.mustOK(back, EvRoomJoinCode, map[string]any{"code": resume["code"]})
	if str(rejoined.Raw, "roomId") != d.roomID {
		t.Fatalf("rejoined %s", rejoined.Raw)
	}
	if j, _ := back.Last(EvRoomJoined); str(j, "roomId") != d.roomID {
		t.Fatalf("room:joined after rejoin: %s", j)
	}
	// Seated again, a further reconnect restores the seat and carries no offer.
	back.Close()
	time.Sleep(50 * time.Millisecond)
	again := st.connect(d.a.token)
	ready2, _ := again.Last(EvSessionReady)
	if has(ready2, "resume") {
		t.Fatalf("second sign-in carries an offer: %s", ready2)
	}
	if j, err := again.Wait(EvRoomJoined, nil, eventTimeout); err != nil || str(j, "roomId") != d.roomID {
		t.Fatalf("held seat not restored: %v %s", err, j)
	}
}

func TestOfferIsMadeOnlyOnce(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	d.a.c.Close()
	time.Sleep(800 * time.Millisecond)
	first := st.connect(d.a.token)
	ready, _ := first.Last(EvSessionReady)
	if !has(ready, "resume") {
		t.Fatalf("no offer: %s", ready)
	}
	// Declined (never joined); the next sign-in gets nothing.
	first.Close()
	time.Sleep(50 * time.Millisecond)
	second := st.connect(d.a.token)
	ready2, _ := second.Last(EvSessionReady)
	if has(ready2, "resume") {
		t.Fatalf("offered twice: %s", ready2)
	}
}

func TestVoluntaryLeaveLeavesNothingToResume(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	// integration.test.js:792
	st.mustOK(d.a.c, EvRoomLeave, map[string]any{})
	d.a.c.Close()
	time.Sleep(800 * time.Millisecond)
	back := st.connect(d.a.token)
	ready, _ := back.Last(EvSessionReady)
	if has(ready, "resume") {
		t.Fatalf("resume after a voluntary leave: %s", ready)
	}
	time.Sleep(50 * time.Millisecond)
	if len(back.All(EvRoomJoined)) != 0 {
		t.Fatalf("unsolicited room:joined")
	}
}

func TestClosedTableIsNotOfferedBack(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	// integration.test.js:816
	d.a.c.Close()
	time.Sleep(800 * time.Millisecond)
	d.b.leave(st)
	eventually(t, eventTimeout, func() bool { return st.rooms.GetTable(d.roomID) == nil }, "table destroyed")
	back := st.connect(d.a.token)
	ready, _ := back.Last(EvSessionReady)
	if has(ready, "resume") {
		t.Fatalf("a closed table was offered back: %s", ready)
	}
}

func TestStaleOfferExpires(t *testing.T) {
	st := newStack(t, func(cfg *config.Config) { cfg.Game.ResumeOffer = 200 * time.Millisecond })
	d := st.dealtTable("")
	d.a.c.Close()
	time.Sleep(800 * time.Millisecond) // grace lapsed at ~400 ms; the offer is ~400 ms old → stale
	back := st.connect(d.a.token)
	ready, _ := back.Last(EvSessionReady)
	if has(ready, "resume") {
		t.Fatalf("a stale offer was made: %s", ready)
	}
}

func TestFullTableIsNotOfferedBack(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	d.a.c.Close()
	time.Sleep(800 * time.Millisecond)
	for i := 0; i < 4; i++ {
		p := st.player("Filler")
		st.mustOK(p.c, EvRoomJoinCode, map[string]any{"code": d.code})
	}
	if !st.rooms.GetTable(d.roomID).IsFull() {
		t.Fatalf("table not full")
	}
	back := st.connect(d.a.token)
	ready, _ := back.Last(EvSessionReady)
	if has(ready, "resume") {
		t.Fatalf("a full table was offered back: %s", ready)
	}
}

// ------------------------------------------------------------ join order

func TestJoinEventOrder(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Joiner")
	mark := p.c.Mark()
	st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": st.uniqueStake()})
	got := names(p.c.Since(mark))
	want := []string{EvRoomState, EvRoomJoined, EvChatHistoryOut, EvRoomState}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("quickJoin order %v, want %v", got, want)
	}
	// Both snapshots are this viewer's own.
	for _, e := range p.c.Since(mark) {
		if e.Name == EvRoomState || e.Name == EvRoomJoined {
			if field(e.Payload, "you") == nil {
				t.Fatalf("snapshot without you: %s", e.Payload)
			}
			if seat := seatOf(e.Payload, p.user.ID); seat == nil {
				t.Fatalf("own seat missing: %s", e.Payload)
			}
		}
	}
	// joinCode has the same tail.
	code := str(func() json.RawMessage { j, _ := p.c.Last(EvRoomJoined); return j }(), "code")
	q := st.player("ByCode")
	mark = q.c.Mark()
	st.mustOK(q.c, EvRoomJoinCode, map[string]any{"code": code})
	got = names(q.c.Since(mark))
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("joinCode order %v, want %v", got, want)
	}
}

func TestSwitchTable(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	// Two tables at one stake: A alone, B+C+D on the other (so A cannot be
	// consolidated onto it: only lone players are merged).
	a := st.player("A")
	st.mustOK(a.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	full := st.rooms.CreateTable(game.CreateTableOptions{BootAmount: boot, Category: "seen"})
	others := []*player{}
	for _, n := range []string{"B", "C", "D"} {
		p := st.player(n)
		st.mustOK(p.c, EvRoomJoinCode, map[string]any{"code": full.Code()})
		others = append(others, p)
	}
	// nowhere to go when the only other table is this one: E on its own table.
	e := st.player("E")
	st.mustFail(e.c, EvRoomSwitch, map[string]any{}, game.CodeNotInRoom)

	mark := a.c.Mark()
	ack := st.mustOK(a.c, EvRoomSwitch, map[string]any{})
	if str(ack.Raw, "roomId") != full.ID() || str(ack.Raw, "code") != full.Code() {
		t.Fatalf("switch ack %s", ack.Raw)
	}
	// spec §11: room:state(new), room:joined, chat:history, room:state(new);
	// no room:left, no room:moved, no room:closed from the vacated table.
	got := names(a.c.Since(mark))
	want := []string{EvRoomState, EvRoomJoined, EvChatHistoryOut, EvRoomState}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("switch order %v, want %v", got, want)
	}
	for _, ev := range a.c.Since(mark) {
		if str(ev.Payload, "roomId") != full.ID() {
			t.Fatalf("switch traffic names the old room: %s %s", ev.Name, ev.Payload)
		}
	}
	// The other table's players saw the arrival.
	if _, err := others[0].c.Wait(EvChatMessageOut, func(p json.RawMessage) bool { return str(p, "text") == "A joined the table" }, eventTimeout); err != nil {
		t.Fatal(err)
	}
	// Nowhere else to go now: refused and the socket stays on its table.
	st.mustFail(a.c, EvRoomSwitch, map[string]any{}, game.CodeNoOtherTable)
	if st.rooms.GetTableForPlayer(a.user.ID) != full {
		t.Fatalf("seat lost after a refused switch")
	}
	mark = a.c.Mark()
	st.mustOK(others[0].c, EvChatMessage, map[string]any{"text": "still here?"})
	if _, err := a.c.WaitFrom(mark, EvChatMessageOut, func(p json.RawMessage) bool { return str(p, "text") == "still here?" }, eventTimeout); err != nil {
		t.Fatalf("socket no longer tracked on its table after a refused switch: %v", err)
	}
	// A private table cannot be swapped.
	priv := st.player("Priv")
	st.mustOK(priv.c, EvRoomCreate, map[string]any{"isPrivate": true})
	st.mustFail(priv.c, EvRoomSwitch, map[string]any{}, game.CodePrivateTable)
}

func TestConsolidationMovesTheLonePlayer(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	// Table X (older) holds X1 alone; table Y holds Y1 and Y2. When Y2 leaves,
	// Y drops to one player and Y1 is merged onto the older X (requirement 24).
	x1 := st.player("X1")
	jx := st.mustOK(x1.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	xRoom := str(jx.Raw, "roomId")
	tableY := st.rooms.CreateTable(game.CreateTableOptions{BootAmount: boot, Category: "seen"})
	y1 := st.player("Y1")
	y2 := st.player("Y2")
	st.mustOK(y1.c, EvRoomJoinCode, map[string]any{"code": tableY.Code()})
	st.mustOK(y2.c, EvRoomJoinCode, map[string]any{"code": tableY.Code()})
	// Y's hand must be over (consolidation touches idle tables only): let it
	// play out by timing out? No — leave before the countdown ends.
	mark := y1.c.Mark()
	st.mustOK(y2.c, EvRoomLeave, map[string]any{})

	moved, err := y1.c.WaitFrom(mark, EvRoomMoved, nil, eventTimeout)
	if err != nil {
		t.Fatalf("no room:moved: %v (events %v)", err, names(y1.c.Since(mark)))
	}
	if str(moved, "fromRoomId") != tableY.ID() || str(moved, "toRoomId") != xRoom || str(moved, "code") != st.rooms.GetTable(xRoom).Code() || str(moved, "message") != MsgMovedToBusier || has(moved, "state") {
		t.Fatalf("room:moved: %s", moved)
	}
	if _, err := y1.c.WaitFrom(mark, EvChatHistoryOut, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}
	evs := y1.c.Since(mark)
	closedAt := indexOf(evs, EvRoomClosed, func(p json.RawMessage) bool { return str(p, "roomId") == tableY.ID() })
	movedAt := indexOf(evs, EvRoomMoved, nil)
	joinedAt := indexOf(evs, EvRoomJoined, nil)
	histAt := indexOf(evs, EvChatHistoryOut, nil)
	newStateAt := indexOf(evs, EvRoomState, func(p json.RawMessage) bool { return str(p, "roomId") == xRoom })
	oldStateAt := indexOf(evs, EvRoomState, func(p json.RawMessage) bool { return str(p, "roomId") == tableY.ID() && field(p, "you") == nil })
	// spec §9.2: chat(old), room:state(old, you:null), room:closed(old),
	// room:state(new), room:moved, room:joined, chat:history, room:state(new).
	// A room:state for the old table may precede the system chat line (the
	// leaver's own departure broadcast lands first when the actor is quick);
	// DECISIONS.md §1 pins the relative order of the named events, not the
	// count or position of extra snapshots.
	chatAt := indexOf(evs, EvChatMessageOut, func(p json.RawMessage) bool { return str(p, "roomId") == tableY.ID() })
	if !(chatAt >= 0 && chatAt < closedAt && oldStateAt >= 0 && oldStateAt < closedAt && closedAt < newStateAt && newStateAt < movedAt && movedAt < joinedAt && joinedAt < histAt) {
		t.Fatalf("consolidation order %v (chat %d closed %d moved %d joined %d hist %d newState %d oldState %d)", names(evs), chatAt, closedAt, movedAt, joinedAt, histAt, newStateAt, oldStateAt)
	}
	if st.rooms.GetTableForPlayer(y1.user.ID) != st.rooms.GetTable(xRoom) || st.rooms.GetTable(tableY.ID()) != nil {
		t.Fatalf("player not moved / source not destroyed")
	}
	// The mover is now addressed by the new room: X1's chat reaches Y1 and the
	// merged table has enough players to deal.
	if _, err := y1.c.WaitFrom(mark, EvGameHandStarted, func(p json.RawMessage) bool { return str(p, "roomId") == xRoom }, eventTimeout); err != nil {
		t.Fatal(err)
	}
	if v := metricValue(st.metrics.SocketEmitsTotal.WithLabelValues(EvRoomMoved)); v != 1 {
		t.Fatalf("socket_emits_total{room:moved} = %v", v)
	}
}

// --------------------------------------------------------------------- kick

func TestIdleKick(t *testing.T) {
	// Three players; two of them answer every turn with chaal, the third
	// never acts. A seen table with one betting round ends each hand by
	// forced showdown, so the stalled player misses one turn per hand and is
	// kicked on the third (requirement 31).
	st := newStack(t, func(cfg *config.Config) {
		cfg.Game.TurnTimeout = 250 * time.Millisecond
		cfg.Game.SeenMaxBetRounds = 1
		cfg.Game.MaxMissedTurns = 3
	})
	boot := st.uniqueStake()
	idle := st.player("Idle")
	bots := []*player{st.player("Bot1"), st.player("Bot2")}
	st.mustOK(idle.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot, "category": "seen"})
	for _, b := range bots {
		st.mustOK(b.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot, "category": "seen"})
	}
	roomID := st.rooms.GetTableForPlayer(idle.user.ID).ID()
	stop := make(chan struct{})
	defer close(stop)
	for _, b := range bots {
		go func(p *player) {
			seen := 0
			for {
				select {
				case <-stop:
					return
				default:
				}
				turns := p.c.All(EvGameYourTurn)
				if len(turns) > seen {
					seen = len(turns)
					_, _ = p.c.Request(EvGameAction, map[string]any{"action": "chaal"}, ackTimeout)
					continue
				}
				time.Sleep(10 * time.Millisecond)
			}
		}(b)
	}
	kicked, err := idle.c.Wait(EvRoomKicked, nil, 15*time.Second)
	if err != nil {
		t.Fatalf("no room:kicked: %v", err)
	}
	if str(kicked, "roomId") != roomID || str(kicked, "reason") != "idle" || str(kicked, "message") != "Left the table after 3 missed turns" {
		t.Fatalf("room:kicked: %s", kicked)
	}
	eventually(t, eventTimeout, func() bool { return st.rooms.GetTableForPlayer(idle.user.ID) == nil }, "kicked player unseated")
	// The kicked player's own removal traffic arrived while still tracked,
	// and room:kicked came after it.
	evs := idle.c.Events()
	kickedAt := indexOf(evs, EvRoomKicked, nil)
	leftLine := indexOf(evs, EvChatMessageOut, func(p json.RawMessage) bool { return str(p, "text") == "Idle left the table" })
	if leftLine < 0 || leftLine > kickedAt {
		t.Fatalf("kick order: left line at %d, kicked at %d", leftLine, kickedAt)
	}
	if v := metricValue(st.metrics.KicksTotal.WithLabelValues("idle")); v != 1 {
		t.Fatalf("kicks_total{idle} = %v", v)
	}
	if v := metricValue(st.metrics.TurnTimeoutsTotal); v < 3 {
		t.Fatalf("turn_timeouts_total = %v", v)
	}
	// Nothing is left to resume for a kicked player.
	idle.c.Close()
	time.Sleep(600 * time.Millisecond)
	back := st.connect(idle.token)
	ready, _ := back.Last(EvSessionReady)
	if has(ready, "resume") {
		t.Fatalf("a kicked player was offered the table back: %s", ready)
	}
	// The remaining players still see a live table without the kicked seat.
	view := st.view(st.rooms.GetTable(roomID), bots[0].user.ID)
	if seatOf(mustJSON(view), idle.user.ID) != nil {
		t.Fatalf("kicked seat still shown")
	}
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// -------------------------------------------------------------------- misc

func TestPingRTTIsUnguarded(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Pinger")
	raw, err := p.c.Request(EvPingRTT, 12345, ackTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if has(raw, "ok") || num(raw, "sentAt") != 12345 || num(raw, "serverTime") <= 0 {
		t.Fatalf("ping:rtt ack %s", raw)
	}
	raw, err = p.c.Request(EvPingRTT, testclient.NoPayload{}, ackTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if has(raw, "sentAt") || num(raw, "serverTime") <= 0 {
		t.Fatalf("ping:rtt without sentAt: %s", raw)
	}
	raw, err = p.c.Request(EvPingRTT, null(), ackTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if !has(raw, "sentAt") || field(raw, "sentAt") != nil {
		t.Fatalf("ping:rtt null sentAt must echo null: %s", raw)
	}
	// Not rate limited: 40 pings in a row all answer.
	for i := 0; i < 40; i++ {
		if _, err := p.c.Request(EvPingRTT, i, ackTimeout); err != nil {
			t.Fatalf("ping %d: %v", i, err)
		}
	}
	if v := metricValue(st.metrics.SocketMessagesTotal.WithLabelValues(EvPingRTT)); v != 43 {
		t.Fatalf("socket_messages_total{ping:rtt} = %v", v)
	}
	// An unknown event is never acked.
	if _, err := p.c.Request("room:teleport", map[string]any{}, 300*time.Millisecond); err != testclient.ErrNoAck {
		t.Fatalf("unknown event: %v", err)
	}
	if !p.c.Connected() {
		t.Fatalf("socket dropped by an unknown event")
	}
}

func TestSocketMetricsAndStats(t *testing.T) {
	st := newStack(t, nil)
	before := metricValue(st.metrics.ConnectedSockets)
	a := st.player("A")
	b := st.player("B")
	if v := metricValue(st.metrics.ConnectedSockets); v != before+2 {
		t.Fatalf("connected_sockets = %v, want %v", v, before+2)
	}
	if v := metricValue(st.metrics.ConnectionsTotal); v != 2 {
		t.Fatalf("connections_total = %v", v)
	}
	if v := metricValue(st.metrics.ConnectedSocketsPeak); v < 2 {
		t.Fatalf("connected_sockets_peak = %v", v)
	}
	if s := st.h.Stats(); s.Sockets != 2 || s.Rooms != 0 {
		t.Fatalf("Stats = %+v", s)
	}
	if st.srv.ClientsCount() != 2 {
		t.Fatalf("ClientsCount = %d", st.srv.ClientsCount())
	}
	a.c.Disconnect() // "41" → client namespace disconnect
	b.c.Close()      // transport close
	eventually(t, eventTimeout, func() bool { return metricValue(st.metrics.ConnectedSockets) == before }, "gauge back")
	eventually(t, eventTimeout, func() bool { return st.h.Stats().Sockets == 0 }, "userSockets emptied")
	reasonRe := regexp.MustCompile(`^[a-z][a-z _]*$`)
	total := 0.0
	for _, reason := range []string{"client namespace disconnect", "transport close", "transport error", "other"} {
		if !reasonRe.MatchString(reason) {
			t.Fatalf("reason label %q", reason)
		}
		total += metricValue(st.metrics.DisconnectionsTotal.WithLabelValues(reason))
	}
	if total != 2 {
		t.Fatalf("disconnections_total sum = %v", total)
	}
	if v := metricValue(st.metrics.DisconnectionsTotal.WithLabelValues("client namespace disconnect")); v != 1 {
		t.Fatalf("disconnections_total{client namespace disconnect} = %v", v)
	}
}

func TestGameMetrics(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	// metrics.test.js:423
	st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "see"})
	st.mustOK(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal"})
	for _, action := range []string{"see", "chaal"} {
		if v := metricValue(st.metrics.MovesTotal.WithLabelValues(action)); v < 1 {
			t.Fatalf("moves_total{%s} = %v", action, v)
		}
	}
	if v := metricValue(st.metrics.SocketMessagesTotal.WithLabelValues(EvGameAction)); v < 2 {
		t.Fatalf("socket_messages_total{game:action} = %v", v)
	}
	if v := metricValue(st.metrics.SocketMessagesTotal.WithLabelValues(EvRoomQuickJoin)); v < 2 {
		t.Fatalf("socket_messages_total{room:quickJoin} = %v", v)
	}
	if n := observations(st.metrics.MoveDuration); n == 0 {
		t.Fatalf("move_processing_duration_seconds not observed")
	}
	if n := observations(st.metrics.StateUpdateDuration); n == 0 {
		t.Fatalf("state_update_duration_seconds not observed")
	}
	if n := observations(st.metrics.JoinDuration); n == 0 {
		t.Fatalf("join_duration_seconds not observed")
	}
	if v := metricValue(st.metrics.GamesStartedTotal.WithLabelValues("seen")); v != 1 {
		t.Fatalf("games_started_total{seen} = %v", v)
	}

	// metrics.test.js:462 — invalid moves by code; 'teleport' never a label.
	movesBefore := metricValue(st.metrics.MovesTotal.WithLabelValues("chaal")) + metricValue(st.metrics.MovesTotal.WithLabelValues("see"))
	// After the chaal the turn moved to the other player, so onTurn is now out of turn.
	st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "chaal"}, game.CodeNotYourTurn)
	st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "teleport"}, game.CodeUnknownAction)
	for _, code := range []string{game.CodeNotYourTurn, game.CodeUnknownAction} {
		if v := metricValue(st.metrics.InvalidMovesTotal.WithLabelValues(code)); v != 1 {
			t.Fatalf("invalid_moves_total{%s} = %v", code, v)
		}
		if v := metricValue(st.metrics.SocketErrorsTotal.WithLabelValues(code)); v != 1 {
			t.Fatalf("socket_errors_total{%s} = %v", code, v)
		}
	}
	if v := metricValue(st.metrics.SocketEmitsTotal.WithLabelValues(EvGameError)); v < 2 {
		t.Fatalf("socket_emits_total{game:error} = %v", v)
	}
	after := metricValue(st.metrics.MovesTotal.WithLabelValues("chaal")) + metricValue(st.metrics.MovesTotal.WithLabelValues("see"))
	if after != movesBefore {
		t.Fatalf("moves_total changed on refusals")
	}
	exposition := gather(t, st)
	if strings.Contains(exposition, `action="teleport"`) {
		t.Fatalf("'teleport' became a label")
	}

	// metrics.test.js:491 — a completed hand, by reason and pot.
	st.mustOK(d.waiting.c, EvGameAction, map[string]any{"action": "pack"})
	ended, err := d.onTurn.c.Wait(EvGameHandEnded, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	// Two boots plus one SEEN chaal (2 × stake) went into the pot.
	if str(ended, "reason") != "last_standing" || num(ended, "pot") != float64(4*d.boot) {
		t.Fatalf("handEnded: %s", ended)
	}
	if v := metricValue(st.metrics.GamesCompletedTotal.WithLabelValues("seen", "last_standing")); v != 1 {
		t.Fatalf("games_completed_total{seen,last_standing} = %v", v)
	}
	if v := metricValue(st.metrics.PotSettledTotal); v != float64(4*d.boot) {
		t.Fatalf("pot_settled_chips_total = %v", v)
	}
	if v := metricValue(st.metrics.SocketEmitsTotal.WithLabelValues(EvGameHandEnded)); v != 1 {
		t.Fatalf("socket_emits_total{game:handEnded} = %v", v)
	}
	if v := metricValue(st.metrics.MovesTotal.WithLabelValues("pack")); v != 1 {
		t.Fatalf("moves_total{pack} = %v", v)
	}

	// metrics.test.js:550 — chat.
	chat := st.mustOK(d.a.c, EvChatMessage, map[string]any{"text": "gg"})
	if str(chat.Raw, "messageId") == "" {
		t.Fatalf("chat ack %s", chat.Raw)
	}
	eventually(t, eventTimeout, func() bool { return metricValue(st.metrics.ChatMessagesTotal) >= 1 }, "chat counted")
	if v := metricValue(st.metrics.SocketEmitsTotal.WithLabelValues(EvChatMessageOut)); v < 1 {
		t.Fatalf("socket_emits_total{chat:message} = %v", v)
	}

	// metrics.test.js:580 — cardinality: nothing player-derived in labels.
	exposition = gather(t, st)
	uuidRe := regexp.MustCompile(`[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)
	labelRe := regexp.MustCompile(`(\w+)="([^"]*)"`)
	for _, line := range strings.Split(exposition, "\n") {
		if strings.HasPrefix(line, "#") || !strings.HasPrefix(line, "game_") {
			continue
		}
		for _, m := range labelRe.FindAllStringSubmatch(line, -1) {
			name, value := m[1], m[2]
			if strings.HasSuffix(name, "_id") || name == "ip" || name == "url" || name == "path" || strings.HasPrefix(name, "code_") {
				t.Fatalf("forbidden label name %q in %s", name, line)
			}
			if uuidRe.MatchString(value) {
				t.Fatalf("uuid in label value: %s", line)
			}
			switch name {
			case "code":
				if !regexp.MustCompile(`^[a-z][a-z0-9_]*$`).MatchString(value) {
					t.Fatalf("code label %q", value)
				}
			case "event":
				if !regexp.MustCompile(`^[a-z]+:[a-zA-Z]+$`).MatchString(value) {
					t.Fatalf("event label %q", value)
				}
			case "category":
				if value != "seen" && value != "blind" && value != "other" {
					t.Fatalf("category label %q", value)
				}
			case "reason":
				if !regexp.MustCompile(`^[a-z][a-z _]*$`).MatchString(value) {
					t.Fatalf("reason label %q", value)
				}
			}
		}
	}
}

func gather(t *testing.T, st *stack) string {
	t.Helper()
	families, err := st.metrics.Registry.Gather()
	if err != nil {
		t.Fatal(err)
	}
	var sb strings.Builder
	for _, mf := range families {
		for _, m := range mf.GetMetric() {
			sb.WriteString(mf.GetName())
			for _, lp := range m.GetLabel() {
				sb.WriteString(` ` + lp.GetName() + `="` + lp.GetValue() + `"`)
			}
			sb.WriteString("\n")
		}
	}
	return sb.String()
}

func TestSideshowEventsAudience(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	ps := []*player{st.player("S1"), st.player("S2"), st.player("S3")}
	for _, p := range ps {
		st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot, "category": "seen"})
	}
	if _, err := ps[0].c.Wait(EvGameHandStarted, nil, eventTimeout); err != nil {
		t.Fatal(err)
	}
	table := st.rooms.GetTableForPlayer(ps[0].user.ID)
	byID := map[string]*player{}
	for _, p := range ps {
		byID[p.user.ID] = p
	}
	// Everyone sees; the first player acts (chaal) so the second has a
	// right-hand neighbour who has bet; the second asks the sideshow.
	for _, p := range ps {
		st.mustOK(p.c, EvGameAction, map[string]any{"action": "see"})
	}
	view := st.view(table, ps[0].user.ID)
	first := byID[*view.Turn.UserID]
	st.mustOK(first.c, EvGameAction, map[string]any{"action": "chaal"})
	view = st.view(table, ps[0].user.ID)
	asker := byID[*view.Turn.UserID]
	ack := st.mustOK(asker.c, EvGameAction, map[string]any{"action": "sideshow"})
	askedID := str(ack.Raw, "toUserId")
	if askedID != first.user.ID {
		t.Fatalf("sideshow asked of %s, want the previous bettor %s", askedID, first.user.ID)
	}
	asked := byID[askedID]
	var third *player
	for _, p := range ps {
		if p != asker && p != asked {
			third = p
		}
	}
	req, err := third.c.Wait(EvGameSideshowReq, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(req, "fromUserId") != asker.user.ID || str(req, "toUserId") != askedID || str(req, "roomId") != table.ID() || num(req, "timeoutMs") != 60000 {
		t.Fatalf("sideshowRequested: %s", req)
	}
	// Only the asked player may answer; a "true" string declines.
	st.mustFail(third.c, EvGameSideshowResp, map[string]any{"accept": true}, game.CodeNotYourSideshow)
	resp := st.mustOK(asked.c, EvGameSideshowResp, map[string]any{"accept": true})
	if field(resp.Raw, "accepted") != true || str(resp.Raw, "packedUserId") == "" {
		t.Fatalf("sideshowRespond ack: %s", resp.Raw)
	}
	resolved, err := third.c.Wait(EvGameSideshowRes, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(resolved, "reason") != "accepted" || field(resolved, "accepted") != true {
		t.Fatalf("sideshowResolved: %s", resolved)
	}
	// The reveal went to the two participants only.
	for _, p := range []*player{asker, asked} {
		rev, err := p.c.Wait(EvGameSideshowRev, nil, eventTimeout)
		if err != nil {
			t.Fatalf("%s got no reveal: %v", p.user.DisplayName, err)
		}
		if len(arr(rev, "reveal.hands")) != 2 || str(rev, "roomId") != table.ID() {
			t.Fatalf("reveal: %s", rev)
		}
	}
	time.Sleep(100 * time.Millisecond)
	if len(third.c.All(EvGameSideshowRev)) != 0 {
		t.Fatalf("the third player received the sideshow reveal")
	}
	for _, f := range third.c.Frames() {
		if strings.Contains(f, `"hands":[`) {
			t.Fatalf("hands leaked to the third player: %s", f)
		}
	}
	if v := metricValue(st.metrics.SocketEmitsTotal.WithLabelValues(EvGameSideshowRev)); v != 1 {
		t.Fatalf("socket_emits_total{game:sideshowReveal} = %v (counted once per reveal)", v)
	}
}

func TestUnfundedKickBetweenHands(t *testing.T) {
	// Requirements 31/32: a player who can no longer cover the boot is kicked
	// between hands with reason insufficient_chips. Alice sits down with 250
	// chips at boot 100 and never acts; Bob chaals whenever it is his turn.
	// She loses two hands (150 → 50) and the sweep before the third removes her.
	st := newStack(t, func(cfg *config.Config) { cfg.Game.TurnTimeout = 250 * time.Millisecond })
	boot := int64(100)
	alice := st.player("Alice")
	st.users.setChips(alice.user.ID, 250)
	bob := st.player("Bob")
	st.mustOK(alice.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	st.mustOK(bob.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	roomID := st.rooms.GetTableForPlayer(alice.user.ID).ID()
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		seen := 0
		for {
			select {
			case <-stop:
				return
			default:
			}
			if turns := bob.c.All(EvGameYourTurn); len(turns) > seen {
				seen = len(turns)
				_, _ = bob.c.Request(EvGameAction, map[string]any{"action": "chaal"}, ackTimeout)
				continue
			}
			time.Sleep(10 * time.Millisecond)
		}
	}()
	kicked, err := alice.c.Wait(EvRoomKicked, nil, 10*time.Second)
	if err != nil {
		t.Fatalf("no room:kicked: %v", err)
	}
	if str(kicked, "roomId") != roomID || str(kicked, "reason") != game.KickReasonInsufficientChips || str(kicked, "message") != game.KickMessageInsufficientChips {
		t.Fatalf("room:kicked: %s", kicked)
	}
	eventually(t, eventTimeout, func() bool { return st.rooms.GetTableForPlayer(alice.user.ID) == nil }, "unseated")
	if v := metricValue(st.metrics.KicksTotal.WithLabelValues(game.KickReasonInsufficientChips)); v != 1 {
		t.Fatalf("kicks_total{insufficient_chips} = %v", v)
	}
	if chips := st.users.chips(alice.user.ID); chips != 50 {
		t.Fatalf("alice's wallet = %d, want 50", chips)
	}
	// Bob is alone again; his snapshot shows the vacated seat.
	view := st.view(st.rooms.GetTable(roomID), bob.user.ID)
	if seatOf(mustJSON(view), alice.user.ID) != nil || view.State != game.TableWaiting {
		t.Fatalf("after the kick: state %s", view.State)
	}
}

func TestInternalErrorsAreReportedTwiceDifferently(t *testing.T) {
	// A non-GameError failure (here: the account vanished between the
	// handshake and the join) is acked with its raw message under
	// internal_error, while game:error says only "Something went wrong".
	st := newStack(t, nil)
	p := st.player("Vanishing")
	st.users.mu.Lock()
	delete(st.users.users, p.user.ID)
	st.users.mu.Unlock()
	mark := p.c.Mark()
	ack := st.mustFail(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": st.uniqueStake()}, game.CodeInternalError)
	if ack.Message == "" || ack.Message == MsgInternalError {
		t.Fatalf("ack must carry the raw error: %s", ack.Raw)
	}
	ge, err := p.c.WaitFrom(mark, EvGameError, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if str(ge, "code") != game.CodeInternalError || str(ge, "message") != MsgInternalError {
		t.Fatalf("game:error: %s", ge)
	}
	if v := metricValue(st.metrics.SocketErrorsTotal.WithLabelValues(game.CodeInternalError)); v != 1 {
		t.Fatalf("socket_errors_total{internal_error} = %v", v)
	}
	// The join was still timed (Node's `timed` observed a throwing fn).
	if observations(st.metrics.JoinDuration) == 0 {
		t.Fatalf("join_duration_seconds not observed on failure")
	}
}

func TestTableDestroyedUnderneathViewers(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	if s := st.h.Stats(); s.Rooms != 1 || s.Sockets != 2 {
		t.Fatalf("Stats = %+v", s)
	}
	markA, markB := d.a.c.Mark(), d.b.c.Mark()
	if err := st.rooms.DestroyTable(d.roomID); err != nil {
		t.Fatal(err)
	}
	for _, c := range []*testclient.Client{d.a.c, d.b.c} {
		mark := markA
		if c == d.b.c {
			mark = markB
		}
		closed, err := c.WaitFrom(mark, EvRoomClosed, nil, eventTimeout)
		if err != nil {
			t.Fatal(err)
		}
		if str(closed, "roomId") != d.roomID {
			t.Fatalf("room:closed: %s", closed)
		}
		// The live hand was settled (all_left) before the close reached anyone.
		evs := c.Since(mark)
		if indexOf(evs, EvGameHandEnded, func(p json.RawMessage) bool { return str(p, "reason") == "all_left" }) > indexOf(evs, EvRoomClosed, nil) {
			t.Fatalf("handEnded after room:closed: %v", names(evs))
		}
	}
	if s := st.h.Stats(); s.Rooms != 0 {
		t.Fatalf("roomSockets not dropped: %+v", s)
	}
	if v := metricValue(st.metrics.SocketEmitsTotal.WithLabelValues(EvRoomClosed)); v != 1 {
		t.Fatalf("socket_emits_total{room:closed} = %v (counted once per table)", v)
	}
	if v := metricValue(st.metrics.GamesAbandonedTotal.WithLabelValues("seen")); v != 1 {
		t.Fatalf("games_abandoned_total{seen} = %v", v)
	}
	// Nobody is seated any more; a fresh join works and the sockets are alive.
	st.mustOK(d.a.c, EvRoomQuickJoin, map[string]any{"bootAmount": st.uniqueStake()})
}
