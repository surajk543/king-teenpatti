package config

import "testing"

// WS_COMPRESSION (26 Sep 2026): websocket permessage-deflate is negotiated by
// default and turned off with a restart. It reads as every boolean key does
// (parse.go `boolean`, Node's): 1/true/yes/on is on, anything else set is off.
func TestWebsocketCompressionIsOnByDefaultAndCanBeTurnedOff(t *testing.T) {
	if !Defaults().WSCompression {
		t.Fatal("Defaults(): WSCompression is off")
	}
	if !mustLoad(t, map[string]string{}).WSCompression {
		t.Fatal("unset WS_COMPRESSION: compression is off")
	}
	if mustLoad(t, map[string]string{"WS_COMPRESSION": "false"}).WSCompression {
		t.Fatal("WS_COMPRESSION=false: compression is still on")
	}
	if !mustLoad(t, map[string]string{"WS_COMPRESSION": "true"}).WSCompression {
		t.Fatal("WS_COMPRESSION=true: compression is off")
	}
	for _, off := range []string{"0", "no", "off", "maybe"} {
		if mustLoad(t, map[string]string{"WS_COMPRESSION": off}).WSCompression {
			t.Errorf("WS_COMPRESSION=%s: compression is on", off)
		}
	}
}
