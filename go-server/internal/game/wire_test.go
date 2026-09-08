package game

import (
	"encoding/json"
	"testing"
)

// These tests pin the null / absent / empty rules of PORT_PLAN.md §4.1 that the
// struct tags encode, so a porter cannot change them by accident.

func marshal(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestEmptySeatIsExactlyTwoFields(t *testing.T) {
	got := marshal(t, SeatView{Empty: true, SeatIndex: 3})
	if got != `{"seatIndex":3,"status":"empty"}` {
		t.Fatalf("empty seat = %s", got)
	}
}

func TestOccupiedSeatHidesChipsAsNullNotZero(t *testing.T) {
	got := marshal(t, SeatView{SeatIndex: 1, UserID: "u", DisplayName: "Ravi", Status: SeatActive, IsBlind: true})
	want := `{"seatIndex":1,"userId":"u","displayName":"Ravi","avatarUrl":null,"chips":null,"status":"active","isBlind":true,"lastBet":0,"lastAction":null,"contributed":0,"connected":false,"cardCount":0}`
	if got != want {
		t.Fatalf("seat = %s\nwant   %s", got, want)
	}
}

func TestActionEventReasonAndAutoAreOmittedUnlessSet(t *testing.T) {
	bet := marshal(t, ActionEvent{UserID: "u", Action: ActionChaal, Amount: 400, Pot: 1000, Stake: 400})
	if bet != `{"userId":"u","action":"chaal","amount":400,"pot":1000,"stake":400}` {
		t.Fatalf("bet = %s", bet)
	}
	auto := false
	see := marshal(t, ActionEvent{UserID: "u", Action: ActionSee, Auto: &auto, Pot: 1000, Stake: 400})
	if see != `{"userId":"u","action":"see","amount":0,"auto":false,"pot":1000,"stake":400}` {
		t.Fatalf("see = %s", see)
	}
	pack := marshal(t, ActionEvent{UserID: "u", Action: ActionPack, Reason: PackReasonTimeout, Pot: 1000, Stake: 400})
	if pack != `{"userId":"u","action":"pack","amount":0,"pot":1000,"stake":400,"reason":"timeout"}` {
		t.Fatalf("pack = %s", pack)
	}
}

func TestActResultShapesPerAction(t *testing.T) {
	auto, autoSeen := false, true
	cases := map[string]ActResult{
		`{"action":"see","auto":false}`:                   {Action: string(ActionSee), Auto: &auto},
		`{"action":"raise","amount":800,"autoSeen":true}`: {Action: string(BetRaise), Amount: Int64Ptr(800), AutoSeen: &autoSeen},
		`{"action":"pack","reason":"pack"}`:               {Action: string(ActionPack), Reason: PackReasonPack},
		`{"action":"show","amount":400}`:                  {Action: string(ActionShow), Amount: Int64Ptr(400)},
		`{"action":"sideshow","toUserId":"v"}`:            {Action: string(ActionSideshow), ToUserID: "v"},
	}
	for want, v := range cases {
		if got := marshal(t, v); got != want {
			t.Errorf("got %s want %s", got, want)
		}
	}
}

func TestChatMessageSystemFlagAndNullUser(t *testing.T) {
	sys := marshal(t, ChatMessage{ID: "m", DisplayName: ChatSystemDisplayName, Text: "x joined the table", At: 5, System: true})
	if sys != `{"id":"m","userId":null,"displayName":"Table","text":"x joined the table","at":5,"system":true}` {
		t.Fatalf("system = %s", sys)
	}
	player := marshal(t, ChatMessage{ID: "m", UserID: StrPtr("u"), DisplayName: "Ravi", Text: "gg", At: 5})
	if player != `{"id":"m","userId":"u","displayName":"Ravi","text":"gg","at":5}` {
		t.Fatalf("player = %s", player)
	}
}

func TestNilSlicesWouldLeakAsNull(t *testing.T) {
	// Documents the trap: a nil slice marshals as null, so producers MUST
	// allocate empty slices for the never-null arrays.
	if got := marshal(t, YouView{}); got[len(got)-len(`"cards":null,"options":null}`):] != `"cards":null,"options":null}` {
		t.Fatalf("unexpected zero YouView: %s", got)
	}
	if got := marshal(t, YouView{Cards: []string{}}); got[len(got)-len(`"cards":[],"options":null}`):] != `"cards":[],"options":null}` {
		t.Fatalf("empty cards should be []: %s", got)
	}
}

func TestGameErrorMatchesByCode(t *testing.T) {
	err := error(NewGameError(CodeInvalidBet, "x"))
	if CodeOf(err, CodeInternalError) != CodeInvalidBet {
		t.Fatal("CodeOf")
	}
	if CodeOf(ErrTableDestroyed, "") != CodeTableDestroyed {
		t.Fatal("ErrTableDestroyed code")
	}
	if BootActionID("h", "u") != "h:boot:u" || SettleActionID("h", "u") != "h:settle:u" {
		t.Fatal("deterministic action ids")
	}
}
