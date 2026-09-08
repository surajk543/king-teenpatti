package sio

import (
	"errors"
	"testing"
)

// The exact strings below come from the spec (§14.4/§14.5), csharpJsonPort.js
// and socket.io-parser 4.2.x's encodeAsString/decodeString.

func TestEncodePacketMatchesSocketIOParser(t *testing.T) {
	cases := []struct {
		name string
		p    Packet
		want string
	}{
		{"event no ack", Packet{Type: PacketEvent, ID: -1, Data: []byte(`["x",{}]`)}, `2["x",{}]`},
		{"event with ack id", Packet{Type: PacketEvent, ID: 17, Data: []byte(`["x",{}]`)}, `217["x",{}]`},
		{"ack", Packet{Type: PacketAck, ID: 17, Data: []byte(`[{"ok":true}]`)}, `317[{"ok":true}]`},
		{"ack id 0", Packet{Type: PacketAck, ID: 0, Data: []byte(`[{"ok":true,"roomId":"r"}]`)}, `30[{"ok":true,"roomId":"r"}]`},
		{"connect ack", Packet{Type: PacketConnect, ID: -1, Data: []byte(`{"sid":"s"}`)}, `0{"sid":"s"}`},
		{"disconnect", Packet{Type: PacketDisconnect, ID: -1}, `1`},
		{"connect error", Packet{Type: PacketConnectError, ID: -1, Data: []byte(`{"message":"invalid_session"}`)}, `4{"message":"invalid_session"}`},
		{"connect error other nsp", Packet{Type: PacketConnectError, ID: -1, Nsp: "/admin", Data: []byte(`{"message":"Invalid namespace"}`)}, `4/admin,{"message":"Invalid namespace"}`},
		{"default nsp spelled out", Packet{Type: PacketEvent, ID: -1, Nsp: "/", Data: []byte(`["a"]`)}, `2["a"]`},
	}
	for _, tc := range cases {
		if got := string(EncodePacket(tc.p)); got != tc.want {
			t.Errorf("%s: got %q want %q", tc.name, got, tc.want)
		}
	}
}

func TestDecodePacketGrammar(t *testing.T) {
	cases := []struct {
		frame string
		want  Packet
	}{
		{`0{"token":"abc"}`, Packet{Type: PacketConnect, ID: -1, Data: []byte(`{"token":"abc"}`)}},
		{`0`, Packet{Type: PacketConnect, ID: -1}},
		{``, Packet{Type: PacketConnect, ID: -1}}, // Number("") === 0 in JS
		{`0/admin,{"token":"abc"}`, Packet{Type: PacketConnect, ID: -1, Nsp: "/admin", Data: []byte(`{"token":"abc"}`)}},
		{`0/admin`, Packet{Type: PacketConnect, ID: -1, Nsp: "/admin"}},
		{`1`, Packet{Type: PacketDisconnect, ID: -1}},
		{`2["room:leave",{}]`, Packet{Type: PacketEvent, ID: -1, Data: []byte(`["room:leave",{}]`)}},
		{`21["room:quickJoin",{"bootAmount":100}]`, Packet{Type: PacketEvent, ID: 1, Data: []byte(`["room:quickJoin",{"bootAmount":100}]`)}},
		{`20["ping:rtt",1730000000000]`, Packet{Type: PacketEvent, ID: 0, Data: []byte(`["ping:rtt",1730000000000]`)}},
		{`2123456["ev"]`, Packet{Type: PacketEvent, ID: 123456, Data: []byte(`["ev"]`)}},
		{`2/admin,5["ev"]`, Packet{Type: PacketEvent, ID: 5, Nsp: "/admin", Data: []byte(`["ev"]`)}},
		{`2`, Packet{Type: PacketEvent, ID: -1}},
		{`2[7,"numeric event names are tolerated"]`, Packet{Type: PacketEvent, ID: -1, Data: []byte(`[7,"numeric event names are tolerated"]`)}},
		{`33[{"ok":true}]`, Packet{Type: PacketAck, ID: 3, Data: []byte(`[{"ok":true}]`)}},
		{`4{"message":"x"}`, Packet{Type: PacketConnectError, ID: -1, Data: []byte(`{"message":"x"}`)}},
		{`4"plain"`, Packet{Type: PacketConnectError, ID: -1, Data: []byte(`"plain"`)}},
	}
	for _, tc := range cases {
		got, err := DecodePacket([]byte(tc.frame))
		if err != nil {
			t.Errorf("%q: unexpected error %v", tc.frame, err)
			continue
		}
		if got.Type != tc.want.Type || got.ID != tc.want.ID || got.Nsp != tc.want.Nsp || string(got.Data) != string(tc.want.Data) {
			t.Errorf("%q: got %+v (data %q) want %+v (data %q)", tc.frame, got, got.Data, tc.want, tc.want.Data)
		}
	}
}

func TestDecodePacketRejectsWhatSocketIOParserThrowsOn(t *testing.T) {
	malformed := []string{
		`7`,                         // unknown packet type
		`x["ev"]`,                   // not a digit
		`2{"not":"an array"}`,       // EVENT payload must be an array
		`2[]`,                       // first element missing
		`2[{"obj":1}]`,              // first element neither string nor number
		`2["connect",{}]`,           // reserved event name
		`2["disconnect"]`,           // reserved event name
		`2["ev",{unterminated`,      // invalid JSON
		`3{"ack":"must be array"}`,  // ACK payload must be an array
		`0"string auth"`,            // CONNECT payload must be an object
		`0[1,2]`,                    // CONNECT payload must be an object
		`0null`,                     // isObject(null) is false
		`1{"payload":"forbidden"}`,  // DISCONNECT carries nothing
		`4[1]`,                      // CONNECT_ERROR is a string or object
		`21234567890123456789["e"]`, // ack id far beyond any client's counter
	}
	for _, frame := range malformed {
		if _, err := DecodePacket([]byte(frame)); !errors.Is(err, ErrMalformedPacket) {
			t.Errorf("%q: want ErrMalformedPacket, got %v", frame, err)
		}
	}
	for _, frame := range []string{`51-["ev",{"_placeholder":true,"num":0}]`, `62-3[]`} {
		if _, err := DecodePacket([]byte(frame)); !errors.Is(err, ErrBinaryUnsupported) {
			t.Errorf("%q: want ErrBinaryUnsupported, got %v", frame, err)
		}
	}
}

func TestEncodeDecodeRoundTrip(t *testing.T) {
	frames := []string{
		`0{"token":"eyJ"}`, `1`, `2["chat:message",{"text":"gg [nice] {hand} \"wp\""}]`,
		`217["room:switch",{}]`, `317[{"ok":false,"code":"not_in_room","message":"x"}]`,
		`4{"message":"unauthorized"}`, `2/nsp,3["a",1]`,
	}
	for _, f := range frames {
		p, err := DecodePacket([]byte(f))
		if err != nil {
			t.Fatalf("%q: %v", f, err)
		}
		if got := string(EncodePacket(p)); got != f {
			t.Errorf("round trip %q → %q", f, got)
		}
	}
}

func TestMarshalJSONIsJSONStringify(t *testing.T) {
	got, err := marshalJSON(map[string]any{"text": `<b>&"quotes"</b>`, "n": 1})
	if err != nil {
		t.Fatal(err)
	}
	// Node emits <, > and & raw; Go's default encoder would write <.
	if want := `{"n":1,"text":"<b>&\"quotes\"</b>"}`; string(got) != want {
		t.Errorf("got %s want %s", got, want)
	}
	frame, err := eventFrame("room:left", []any{map[string]any{"roomId": "r1"}})
	if err != nil {
		t.Fatal(err)
	}
	if want := `42["room:left",{"roomId":"r1"}]`; string(frame) != want {
		t.Errorf("event frame %s want %s", frame, want)
	}
	frame, err = eventFrame("room:left", nil)
	if err != nil {
		t.Fatal(err)
	}
	if want := `42["room:left"]`; string(frame) != want {
		t.Errorf("payload-less event frame %s want %s", frame, want)
	}
	frame, err = ackFrame(1, []any{map[string]any{"ok": true}})
	if err != nil {
		t.Fatal(err)
	}
	if want := `431[{"ok":true}]`; string(frame) != want {
		t.Errorf("ack frame %s want %s", frame, want)
	}
	frame, _ = ackFrame(0, nil)
	if want := `430[]`; string(frame) != want {
		t.Errorf("empty ack frame %s want %s", frame, want)
	}
}

func TestNewSIDShape(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		id := newSID()
		if len(id) != 20 {
			t.Fatalf("sid %q has length %d, want 20", id, len(id))
		}
		for _, r := range id {
			if r == '"' || r == '+' || r == '/' || r == '=' {
				t.Fatalf("sid %q contains %q", id, r)
			}
		}
		if seen[id] {
			t.Fatalf("duplicate sid %q", id)
		}
		seen[id] = true
	}
}
