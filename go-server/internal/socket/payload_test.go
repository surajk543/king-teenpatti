package socket

import (
	"encoding/json"
	"net/url"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/sio"
)

// White-box tests of the JavaScript coercions payload.go reproduces
// (socket/index.js destructured `payload ?? {}` with loose typing).

func raw(s string) json.RawMessage { return json.RawMessage(s) }

func args(s string) []json.RawMessage {
	if s == "" {
		return nil
	}
	return []json.RawMessage{raw(s)}
}

func TestParseAmount(t *testing.T) {
	cases := []struct {
		in   string // "" = absent
		want *int64
		ok   bool
	}{
		{"", nil, true},
		{"null", nil, true},
		{"100", ptr(100), true},
		{"1e3", ptr(1000), true},
		{"1.0", ptr(1), true},
		{"-200", ptr(-200), true},
		{"0", ptr(0), true},
		{"9007199254740991", ptr(9007199254740991), true},
		{"9007199254740992", nil, false},
		{"-9007199254740992", nil, false},
		{"1.5", nil, false},
		{`"100"`, nil, false},
		{`"1e3"`, nil, false},
		{"true", nil, false},
		{"[100]", nil, false},
		{`{"amount":100}`, nil, false},
		{"1e300", nil, false},
	}
	for _, c := range cases {
		var in json.RawMessage
		kind := kindAbsent
		if c.in != "" {
			in = raw(c.in)
			kind = kindOf(in)
		}
		got, ok := parseAmount(in, kind)
		if ok != c.ok || (got == nil) != (c.want == nil) || (got != nil && *got != *c.want) {
			t.Errorf("parseAmount(%s) = %v,%v want %v,%v", c.in, deref(got), ok, deref(c.want), c.ok)
		}
	}
}

func ptr(v int64) *int64 { return &v }

func deref(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

func TestJSString(t *testing.T) {
	cases := map[string]string{
		"":                     "undefined",
		"null":                 "null",
		`"see"`:                "see",
		"12345":                "12345",
		"1e3":                  "1000",
		"1.50":                 "1.5",
		"-0":                   "0",
		"1e21":                 "1e+21",
		"0.0000001":            "1e-7",
		"true":                 "true",
		"[1,2]":                "1,2",
		`["a",null,["b","c"]]`: "a,,b,c",
		"[]":                   "",
		"{}":                   "[object Object]",
		`{"a":1}`:              "[object Object]",
	}
	for in, want := range cases {
		var r json.RawMessage
		kind := kindAbsent
		if in != "" {
			r = raw(in)
			kind = kindOf(r)
		}
		if got := jsString(r, kind); got != want {
			t.Errorf("jsString(%s) = %q, want %q", in, got, want)
		}
	}
}

func TestJSTruthy(t *testing.T) {
	truthy := []string{"true", "1", "-1", `"x"`, "[]", "{}", "1e300"}
	falsy := []string{"", "null", "false", "0", "-0", `""`, "0.0"}
	for _, in := range truthy {
		if !jsTruthy(raw(in), kindOf(raw(in))) {
			t.Errorf("%s should be truthy", in)
		}
	}
	for _, in := range falsy {
		var r json.RawMessage
		kind := kindAbsent
		if in != "" {
			r = raw(in)
			kind = kindOf(r)
		}
		if jsTruthy(r, kind) {
			t.Errorf("%s should be falsy", in)
		}
	}
}

func TestDecodePayloadNonObjectsAreDefaults(t *testing.T) {
	// invalidMoves.test.js:399 — undefined, null, 42, 'string', [], [1,2]
	for _, in := range []string{"", "null", "42", `"string"`, "[]", "[1,2]", "tru", "{bad"} {
		p := decodePayload(args(in))
		if _, kind := p.field("action"); kind != kindAbsent {
			t.Errorf("payload %q: field present", in)
		}
	}
	// A JSON object keyed "__proto__" is an own property in JSON.parse —
	// nothing is inherited from it.
	p := decodePayload(args(`{"__proto__":{"action":"pack"}}`))
	if _, kind := p.field("action"); kind != kindAbsent {
		t.Errorf("__proto__ leaked an action")
	}
	// Only the FIRST argument is the payload.
	p = decodePayload([]json.RawMessage{raw(`{"a":1}`), raw(`{"b":2}`)})
	if _, kind := p.field("b"); kind != kindAbsent {
		t.Errorf("second argument read")
	}
}

func TestDecodeAction(t *testing.T) {
	req := decodeAction(args(`{"action":"chaal","amount":200,"actionId":"abc"}`))
	if req.Action != "chaal" || string(req.Amount) != "200" || req.ActionID != "abc" {
		t.Fatalf("%+v", req)
	}
	req = decodeAction(args(`{}`))
	if req.Action != "undefined" || req.Amount != nil || req.ActionID != "" {
		t.Fatalf("empty: %+v", req)
	}
	req = decodeAction(args(`{"action":null,"amount":null,"actionId":42}`))
	if req.Action != "null" || string(req.Amount) != "null" || req.ActionID != "" {
		t.Fatalf("nulls: %+v", req)
	}
	req = decodeAction(args(`{"action":{"x":1}}`))
	if req.Action != "[object Object]" {
		t.Fatalf("object action: %+v", req)
	}
}

func TestDecodeQuickJoinAndCreate(t *testing.T) {
	q := decodeQuickJoin(args(`{}`))
	if q.BootAmount != nil || q.Category != "" {
		t.Fatalf("defaults: %+v", q)
	}
	q = decodeQuickJoin(args(`{"bootAmount":null,"category":null}`))
	if q.BootAmount != nil || q.Category != "" {
		t.Fatalf("nulls: %+v", q)
	}
	q = decodeQuickJoin(args(`{"bootAmount":5000,"category":"blind"}`))
	if q.BootAmount == nil || *q.BootAmount != 5000 || q.Category != "blind" {
		t.Fatalf("values: %+v", q)
	}
	for _, bad := range []string{"0", "-5", `"lots"`, "200.5", "true", "{}", "[]"} {
		q = decodeQuickJoin(args(`{"bootAmount":` + bad + `}`))
		if q.BootAmount == nil || *q.BootAmount != invalidBoot {
			t.Errorf("bootAmount %s → %v, want invalidBoot", bad, deref(q.BootAmount))
		}
	}
	q = decodeQuickJoin(args(`{"bootAmount":1e300}`))
	if q.BootAmount == nil || *q.BootAmount <= 0 {
		t.Fatalf("huge boot must stay a positive integer: %v", deref(q.BootAmount))
	}
	q = decodeQuickJoin(args(`{"category":42}`))
	if q.Category != "" {
		t.Fatalf("non-string category: %+v", q)
	}

	c := decodeCreate(args(`{}`))
	if c.IsPrivate != nil {
		t.Fatalf("isPrivate absent must be nil (→ true): %+v", c)
	}
	for _, public := range []string{"null", "false", "0", `""`} {
		c = decodeCreate(args(`{"isPrivate":` + public + `}`))
		if c.IsPrivate == nil || *c.IsPrivate {
			t.Errorf("isPrivate %s must open a PUBLIC table", public)
		}
	}
	for _, private := range []string{"true", "1", `"yes"`, "{}", "[]"} {
		c = decodeCreate(args(`{"isPrivate":` + private + `}`))
		if c.IsPrivate == nil || !*c.IsPrivate {
			t.Errorf("isPrivate %s must open a PRIVATE table", private)
		}
	}
}

func TestDecodeJoinCodeAndChat(t *testing.T) {
	if j := decodeJoinCode(args(`{}`)); j.Code != "" {
		t.Fatalf("absent code: %+v", j)
	}
	if j := decodeJoinCode(args(`{"code":null}`)); j.Code != "" {
		t.Fatalf("null code: %+v", j)
	}
	if j := decodeJoinCode(args(`{"code":"abc123"}`)); j.Code != "abc123" {
		t.Fatalf("string code: %+v", j)
	}
	if j := decodeJoinCode(args(`{"code":{"$gt":""}}`)); j.Code != "[object Object]" {
		t.Fatalf("object code: %+v", j)
	}
	if j := decodeJoinCode(args(`{"code":123456}`)); j.Code != "123456" {
		t.Fatalf("numeric code: %+v", j)
	}

	// DECISIONS.md §4: strings as is, numbers as decimal text, the rest empty.
	if c := decodeChat(args(`{"text":"hi"}`)); c.Text != "hi" {
		t.Fatalf("%+v", c)
	}
	if c := decodeChat(args(`{"text":12345}`)); c.Text != "12345" {
		t.Fatalf("%+v", c)
	}
	if c := decodeChat(args(`{"text":1e3}`)); c.Text != "1000" {
		t.Fatalf("%+v", c)
	}
	for _, empty := range []string{`{"text":true}`, `{"text":{}}`, `{"text":["a"]}`, `{"text":null}`, `{}`, `null`, `42`} {
		if c := decodeChat(args(empty)); c.Text != "" {
			t.Errorf("chat %s → %q, want empty", empty, c.Text)
		}
	}
}

func TestDecodeLobbyListAndSideshow(t *testing.T) {
	if l := decodeLobbyList(args(`{}`)); l.Category != "" {
		t.Fatalf("%+v", l)
	}
	if l := decodeLobbyList(args(`{"category":"blind"}`)); l.Category != "blind" {
		t.Fatalf("%+v", l)
	}
	for _, none := range []string{"null", "false", "0", `""`} {
		if l := decodeLobbyList(args(`{"category":` + none + `}`)); l.Category != "" {
			t.Errorf("falsy category %s must mean no filter", none)
		}
	}
	for _, unmatched := range []string{"42", "{}", "true", `["blind"]`} {
		if l := decodeLobbyList(args(`{"category":` + unmatched + `}`)); l.Category != noSuchCategory {
			t.Errorf("truthy non-string %s must match no table", unmatched)
		}
	}

	if !acceptsSideshow(raw("true")) || !acceptsSideshow(raw(" true ")) {
		t.Fatalf("literal true must accept")
	}
	for _, decline := range []string{"1", `"true"`, "{}", "false", "null", ""} {
		if acceptsSideshow(raw(decline)) {
			t.Errorf("%q must decline", decline)
		}
	}
	if r := decodeSideshowRespond(args(`{}`)); r.Accept != nil {
		t.Fatalf("absent accept: %+v", r)
	}
}

func TestUTF16LenAndGrouping(t *testing.T) {
	if utf16Len("abc") != 3 || utf16Len("😀") != 2 || utf16Len("é") != 1 || utf16Len("") != 0 {
		t.Fatalf("utf16Len")
	}
	for n, want := range map[int64]string{0: "0", 999: "999", 1000: "1,000", 500000: "500,000", 1200000: "1,200,000", -5000: "-5,000"} {
		if got := groupThousands(n); got != want {
			t.Errorf("groupThousands(%d) = %q, want %q", n, got, want)
		}
	}
}

func TestHandshakeTokenSelection(t *testing.T) {
	q := url.Values{"token": {"from-query"}}
	cases := []struct {
		auth  string
		query url.Values
		want  string
	}{
		{`{"token":"abc"}`, q, "abc"},
		{`{"token":null}`, q, "from-query"},
		{`{}`, q, "from-query"},
		{``, q, "from-query"},
		{``, nil, ""},
		{`{"token":""}`, q, ""},         // "" is not nullish → missing_token, not the query
		{`{"token":0}`, q, ""},          // falsy → missing_token
		{`{"token":false}`, q, ""},      // falsy → missing_token
		{`{"token":12345}`, q, "12345"}, // truthy non-string → invalid_session downstream
		{`{"token":{"a":1}}`, q, `{"a":1}`},
	}
	for _, c := range cases {
		hs := sio.Handshake{Query: c.query}
		if c.auth != "" {
			var m map[string]json.RawMessage
			if err := json.Unmarshal([]byte(c.auth), &m); err != nil {
				t.Fatal(err)
			}
			hs.Auth = m
		}
		if got := handshakeToken(hs); got != c.want {
			t.Errorf("auth %s query %v → %q, want %q", c.auth, c.query, got, c.want)
		}
	}
}

func TestRateLimiterFixedWindow(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	clock := func() time.Time { return now }
	rl := newRateLimiter(3, 5*time.Second, clock)
	for i := 0; i < 3; i++ {
		if !rl.allow() {
			t.Fatalf("request %d refused", i+1)
		}
	}
	if rl.allow() {
		t.Fatalf("4th request inside the window allowed")
	}
	// The window is anchored to its start, not sliding: 4.999 s later still refused.
	now = now.Add(4999 * time.Millisecond)
	if rl.allow() {
		t.Fatalf("still inside the window")
	}
	// At exactly the window length a new window begins (`>=`).
	now = now.Add(1 * time.Millisecond)
	if !rl.allow() {
		t.Fatalf("new window refused")
	}
}
