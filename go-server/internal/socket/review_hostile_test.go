package socket

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// Adversarial review — hostile input on the realtime protocol. Every test
// here puts something on the wire that a well-behaved client never sends and
// requires the server to refuse it cheaply, without a crash, a hang or a
// bypass of validation. The stack is the in-process one from stack_test.go.

// nestedArrayJSON is `[[[…["pad"]…]]]` — depth levels deep, padded to about
// size bytes, valid JSON and within sio's MaxPayload (100000).
func nestedArrayJSON(depth, size int) json.RawMessage {
	pad := size - 2*depth - 2
	if pad < 0 {
		pad = 0
	}
	return json.RawMessage(strings.Repeat("[", depth) + `"` + strings.Repeat("x", pad) + `"` + strings.Repeat("]", depth))
}

// jsString on a deeply nested array used to re-parse the whole remaining
// subtree at every level (json.Unmarshal per element, recursively): O(size ×
// depth), which for one 100 KB frame nested 9 000 deep was ~3 s of CPU per
// message — a client-controlled CPU amplifier reachable through
// `game:action {action: [[[…]]]}` and `room:joinCode {code: [[[…]]]}`. The
// coercion must be linear in the payload size.
func TestReviewNestedArrayCoercionIsLinear(t *testing.T) {
	raw := nestedArrayJSON(9000, 99_000)
	if !json.Valid(raw) {
		t.Fatal("fixture is not valid JSON")
	}
	start := time.Now()
	got := jsString(raw, kindOf(raw))
	elapsed := time.Since(start)
	// Array#join flattens nested arrays, so the result is the padding itself.
	if want := strings.Repeat("x", 99_000-2*9000-2); got != want {
		t.Fatalf("jsString(nested) = %d bytes, want %d", len(got), len(want))
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("jsString on a 99 KB array nested 9000 deep took %s (quadratic coercion)", elapsed)
	}

	// Mixed content keeps JavaScript's Array#join semantics.
	cases := map[string]string{
		`[1,[2,3],"a",null,true,{},[],1e3,-0]`: "1,2,3,a,,true,[object Object],,1000,0",
		`[[[]]]`:                               "",
		`[null,[null]]`:                        ",",
		`[1e400]`:                              "Infinity",
	}
	for in, want := range cases {
		if got := jsString(json.RawMessage(in), kindArray); got != want {
			t.Errorf("jsString(%s) = %q, want %q", in, got, want)
		}
	}
}

// The same payload on the wire: the refusal must come back promptly and the
// socket must still work afterwards.
func TestReviewNestedActionPayloadIsRefusedPromptly(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	nested := nestedArrayJSON(9000, 99_000)

	for _, tc := range []struct {
		event   string
		payload json.RawMessage
		code    string
	}{
		{EvGameAction, json.RawMessage(`{"action":` + string(nested) + `}`), game.CodeUnknownAction},
		{EvRoomJoinCode, json.RawMessage(`{"code":` + string(nested) + `}`), ""},
		{EvGameAction, json.RawMessage(`{"action":"chaal","amount":` + string(nested) + `}`), game.CodeInvalidBet},
		{EvGameAction, json.RawMessage(`{"action":"chaal","actionId":` + string(nested) + `}`), ""},
	} {
		start := time.Now()
		ack, err := d.waiting.c.Call(tc.event, tc.payload, 6*time.Second)
		if err != nil {
			t.Fatalf("%s nested: %v", tc.event, err)
		}
		if elapsed := time.Since(start); elapsed > 1500*time.Millisecond {
			t.Fatalf("%s nested payload took %s to be answered", tc.event, elapsed)
		}
		if ack.OK {
			// The actionId case is a legitimate off-turn move; it is refused
			// for being out of turn, never accepted.
			t.Fatalf("%s nested payload accepted: %s", tc.event, ack.Raw[:min(len(ack.Raw), 200)])
		}
		if tc.code != "" && ack.Code != tc.code {
			t.Fatalf("%s nested payload code %q, want %q", tc.event, ack.Code, tc.code)
		}
	}
	// Still alive and still seated.
	st.mustFail(d.waiting.c, EvGameAction, map[string]any{"action": "chaal"}, game.CodeNotYourTurn)
}

// Hostile session tokens on the handshake: none may reach session:ready.
func TestReviewHostileTokensAreRefusedOnTheHandshake(t *testing.T) {
	st := newStack(t, nil)
	victim, good := st.login("Victim")
	_ = good

	now := time.Now()
	base := jwt.MapClaims{"sub": victim.ID, "provider": "guest", "name": "Victim", "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()}
	sign := func(method jwt.SigningMethod, claims jwt.MapClaims, key any) string {
		tok, err := jwt.NewWithClaims(method, claims).SignedString(key)
		if err != nil {
			t.Fatalf("sign: %v", err)
		}
		return tok
	}
	with := func(overrides map[string]any) jwt.MapClaims {
		out := jwt.MapClaims{}
		for k, v := range base {
			out[k] = v
		}
		for k, v := range overrides {
			out[k] = v
		}
		return out
	}
	// alg=none, signed with the unsafe allow-none key, for the victim's id.
	noneTok := sign(jwt.SigningMethodNone, base, jwt.UnsafeAllowNoneSignatureType)
	cases := []struct {
		name  string
		token string
		want  string // connect_error message; "" = any refusal
	}{
		{"alg none", noneTok, "invalid_session"},
		{"alg none, empty signature", strings.TrimRight(noneTok, ".") + ".", "invalid_session"},
		{"HS512 with the real secret (Node accepted; DECISIONS §5 pins HS256)", sign(jwt.SigningMethodHS512, base, []byte(testSecret)), "invalid_session"},
		{"HS384 with the real secret", sign(jwt.SigningMethodHS384, base, []byte(testSecret)), "invalid_session"},
		{"wrong secret", sign(jwt.SigningMethodHS256, base, []byte("guess")), "invalid_session"},
		{"expired", sign(jwt.SigningMethodHS256, with(map[string]any{"exp": now.Add(-time.Minute).Unix()}), []byte(testSecret)), "invalid_session"},
		{"not yet valid", sign(jwt.SigningMethodHS256, with(map[string]any{"nbf": now.Add(time.Hour).Unix()}), []byte(testSecret)), "invalid_session"},
		{"numeric sub", sign(jwt.SigningMethodHS256, with(map[string]any{"sub": 12345}), []byte(testSecret)), ""},
		{"array sub", sign(jwt.SigningMethodHS256, with(map[string]any{"sub": []string{victim.ID}}), []byte(testSecret)), ""},
		{"missing sub", sign(jwt.SigningMethodHS256, with(map[string]any{"sub": nil}), []byte(testSecret)), "unknown_user"},
		{"unknown sub", sign(jwt.SigningMethodHS256, with(map[string]any{"sub": "00000000-0000-4000-8000-999999999999"}), []byte(testSecret)), "unknown_user"},
		{"exp far beyond int64", sign(jwt.SigningMethodHS256, with(map[string]any{"exp": 1e30}), []byte(testSecret)), ""},
		{"exp NaN-ish string", sign(jwt.SigningMethodHS256, with(map[string]any{"exp": "never"}), []byte(testSecret)), "invalid_session"},
		{"garbage", "not.a.jwt", "invalid_session"},
		{"header only", "eyJhbGciOiJIUzI1NiJ9", "invalid_session"},
		{"90 KB token", strings.Repeat("A", 90_000), "invalid_session"},
		{"unicode", "🃏.🃏.🃏", "invalid_session"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := ctxTimeout(5 * time.Second)
			defer cancel()
			c, err := testclient.Dial(ctx, st.ts.URL, tc.token)
			if c != nil {
				st.track(c)
			}
			if err == nil {
				t.Fatalf("%s: CONNECT accepted", tc.name)
			}
			cerr, ok := err.(*testclient.ConnectError)
			if !ok {
				t.Fatalf("%s: %v (want a CONNECT_ERROR)", tc.name, err)
			}
			if tc.want != "" && cerr.Message != tc.want {
				t.Fatalf("%s: connect_error %q, want %q", tc.name, cerr.Message, tc.want)
			}
			switch cerr.Message {
			case "invalid_session", "unknown_user", "unauthorized", "missing_token":
			default:
				t.Fatalf("%s: connect_error message %q is not an auth code", tc.name, cerr.Message)
			}
			if _, got := c.Last(EvSessionReady); got {
				t.Fatalf("%s: session:ready was emitted", tc.name)
			}
		})
	}

	// The same claims signed properly for the victim still work, so the
	// refusals above were not a broken fixture.
	c := st.connect(sign(jwt.SigningMethodHS256, base, []byte(testSecret)))
	ready, _ := c.Last(EvSessionReady)
	if str(ready, "user.id") != victim.ID {
		t.Fatalf("control token: %s", ready)
	}
}

// Raw frames a real client never produces, on an authenticated, seated socket.
// The connection must either answer or close cleanly; the process must stay
// up and the other player must be unaffected.
func TestReviewHostileFramesAreHandled(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	c := d.waiting.c

	// 1. An 18-digit ack id is honoured and echoed back verbatim.
	if err := c.SendRaw(`42999999999999999999["ping:rtt",7]`); err != nil {
		t.Fatal(err)
	}
	eventually(t, eventTimeout, func() bool {
		for _, f := range c.Frames() {
			if strings.HasPrefix(f, "43999999999999999999[") {
				return true
			}
		}
		return false
	}, "ack for the 18-digit id")

	// 2. Leading zeros: Number("007") is 7.
	if err := c.SendRaw(`42007["ping:rtt",1]`); err != nil {
		t.Fatal(err)
	}
	eventually(t, eventTimeout, func() bool {
		for _, f := range c.Frames() {
			if strings.HasPrefix(f, "437[") {
				return true
			}
		}
		return false
	}, "ack id 7 for '007'")

	// 3. Extra arguments after the payload are ignored; the payload is still
	//    the first argument.
	ack := st.call(c, EvGameAction, json.RawMessage(`{"action":"chaal"}`))
	if ack.OK || ack.Code != game.CodeNotYourTurn {
		t.Fatalf("baseline chaal off turn: %s", ack.Raw)
	}
	if err := c.SendRaw(`4242["game:action",{"action":"chaal"},{"action":"pack"},[1,2],null,"x"]`); err != nil {
		t.Fatal(err)
	}
	eventually(t, eventTimeout, func() bool {
		for _, f := range c.Frames() {
			if strings.HasPrefix(f, "4342[") && strings.Contains(f, `"not_your_turn"`) {
				return true
			}
		}
		return false
	}, "ack 42 with not_your_turn")

	// 4. Numbers JavaScript would parse as Infinity / -0 / beyond 2^53 and
	//    duplicate keys (last wins in both runtimes) never reach the ladder.
	for _, payload := range []string{
		`{"action":"chaal","amount":1e400}`,
		`{"action":"chaal","amount":-0}`,
		`{"action":"chaal","amount":9007199254740993}`,
		`{"action":"chaal","amount":100,"amount":"100"}`,
		`{"action":"chaal","amount":1E2}`,
		`{"action":"chaal","amount":0.1e3}`,
	} {
		a := st.call(c, EvGameAction, json.RawMessage(payload))
		if a.OK {
			t.Fatalf("%s accepted", payload)
		}
		if a.Code != game.CodeInvalidBet && a.Code != game.CodeNotYourTurn {
			t.Fatalf("%s → %s", payload, a.Raw)
		}
	}

	// 5. Deep OBJECT nesting on a string field coerces to "[object Object]"
	//    and is answered quickly.
	deep := strings.Repeat(`{"a":`, 9000) + `1` + strings.Repeat(`}`, 9000)
	start := time.Now()
	a := st.call(c, EvRoomJoinCode, json.RawMessage(`{"code":`+deep+`}`))
	if a.OK {
		t.Fatalf("deep-object code accepted: %s", a.Raw)
	}
	if time.Since(start) > 1500*time.Millisecond {
		t.Fatalf("deep object took %s", time.Since(start))
	}

	// 6. A 19-digit ack id is malformed in the Go decoder: the connection is
	//    closed (forced close), not crashed; the OTHER player is unaffected.
	if err := c.SendRaw(`421234567890123456789["ping:rtt",1]`); err != nil {
		t.Fatal(err)
	}
	if !c.WaitClosed(eventTimeout) {
		t.Fatalf("19-digit ack id did not close the connection")
	}
	// Bob is still there and the table is still live for Alice.
	st.mustFail(d.onTurn.c, EvGameAction, map[string]any{"action": "sideshow"}, "")
	if !d.onTurn.c.Connected() {
		t.Fatal("the other player's socket was closed too")
	}
}

// ping:rtt is unguarded in Node and in Go (no rate limit, echoes its
// argument). It must not be a way to make the server allocate or return more
// than it was sent, and a missing argument must not panic.
func TestReviewPingRTTEchoIsBoundedAndNilSafe(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Pinger")
	// No argument at all.
	raw, err := p.c.Request(EvPingRTT, testclient.NoPayload{}, ackTimeout)
	if err != nil {
		t.Fatalf("ping:rtt with no args: %v", err)
	}
	if !has(raw, "serverTime") {
		t.Fatalf("ping ack: %s", raw)
	}
	// A 90 KB argument comes back once, never amplified.
	big := json.RawMessage(`"` + strings.Repeat("p", 90_000) + `"`)
	raw, err = p.c.Request(EvPingRTT, big, ackTimeout)
	if err != nil {
		t.Fatalf("ping:rtt big: %v", err)
	}
	if len(raw) > len(big)+200 {
		t.Fatalf("ping ack is %d bytes for a %d-byte argument", len(raw), len(big))
	}
	if p.c.Closed() {
		t.Fatal("ping:rtt closed the socket")
	}
}

// Every guarded event with the nastiest structural payloads: the ack must
// arrive and the socket must survive. (TestGarbageOnEveryEventIsAcked covers
// scalar garbage; this adds size and depth.)
func TestReviewStructuralGarbageOnEveryEvent(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Garbage")
	events := []string{EvLobbyList, EvRoomQuickJoin, EvRoomCreate, EvRoomJoinCode, EvRoomSwitch, EvRoomLeave, EvGameAction, EvGameSideshowResp, EvPlayerReqCards, EvChatMessage, EvChatHistory}
	payloads := []json.RawMessage{
		nestedArrayJSON(9000, 60_000),
		json.RawMessage(strings.Repeat(`{"text":`, 5000) + `"x"` + strings.Repeat(`}`, 5000)),
		json.RawMessage(`{"text":` + string(nestedArrayJSON(5000, 40_000)) + `,"code":` + string(nestedArrayJSON(3000, 20_000)) + `}`),
		json.RawMessage(`{"bootAmount":1e400,"category":` + string(nestedArrayJSON(2000, 10_000)) + `,"isPrivate":` + string(nestedArrayJSON(2000, 10_000)) + `}`),
		json.RawMessage(`{"accept":` + string(nestedArrayJSON(3000, 30_000)) + `}`),
		json.RawMessage(`{"action":"see","amount":` + string(nestedArrayJSON(3000, 30_000)) + `,"actionId":"` + strings.Repeat(`\u0000`, 10) + `"}`),
	}
	deadline := 3 * time.Second
	for _, ev := range events {
		for i, payload := range payloads {
			start := time.Now()
			if _, err := p.c.Call(ev, payload, deadline); err != nil {
				t.Fatalf("%s payload #%d: %v after %s", ev, i, err, time.Since(start))
			}
			if elapsed := time.Since(start); elapsed > 1500*time.Millisecond {
				t.Fatalf("%s payload #%d took %s", ev, i, elapsed)
			}
			if p.c.Closed() {
				t.Fatalf("%s payload #%d closed the socket", ev, i)
			}
		}
	}
	// Rate limit windows: the burst above is 66 requests; wait the window out
	// before proving the socket is still healthy.
	time.Sleep(ActionRateWindowMs*time.Millisecond + 100*time.Millisecond)
	st.mustOK(p.c, EvLobbyList, map[string]any{})
}

// ctxTimeout is context.WithTimeout from the background context.
func ctxTimeout(d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), d)
}
