package live

import (
	"bytes"
	"encoding/json"
	"errors"
	"strconv"
	"time"
)

// ErrClosed is returned by every method of a Store after Close.
var ErrClosed = errors.New("live: store closed")

const (
	// DefaultKeyPrefix namespaces every Redis key (Options.KeyPrefix empty).
	DefaultKeyPrefix = "kt:"
	// DefaultTimeout bounds one Redis round trip (Options.Timeout zero).
	DefaultTimeout = 500 * time.Millisecond

	// auxTTL is the safety net on the keys the Store interface gives no ttl
	// for (chat lists, lobby summaries): they are refreshed on every write and
	// only ever expire when the table that owned them stopped writing for as
	// long as a table snapshot itself survives (LIVE_STATE_TTL_MS default,
	// 24 h). Without it a process that dies and never restarts would leak
	// its tables' chat and summaries forever. Seat keys (kt:seat:<userId>)
	// carry no ttl — RoomManager clears them explicitly.
	auxTTL = 24 * time.Hour
)

// HandIDOf extracts hand.id from a game.Snapshot JSON document ("" when the
// table is between hands or the document is not a snapshot). The Redis store
// records it in the table hash (kt:table:<roomId>.handId) so an operator can
// see which open pot a stored table holds without parsing the snapshot.
//
// It streams tokens and stops at the "hand" member, which game.Snapshot
// emits before the bulky "seats", so the cost per save stays around a
// microsecond instead of a full 20 KB unmarshal.
func HandIDOf(snapshot []byte) string {
	dec := json.NewDecoder(bytes.NewReader(snapshot))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return ""
	}
	for dec.More() {
		keyTok, err := dec.Token()
		if err != nil {
			return ""
		}
		if key, _ := keyTok.(string); key == "hand" {
			var hand struct {
				ID string `json:"id"`
			}
			if err := dec.Decode(&hand); err != nil { // null leaves ID empty
				return ""
			}
			return hand.ID
		}
		if err := skipJSONValue(dec); err != nil {
			return ""
		}
	}
	return ""
}

// skipJSONValue consumes one complete JSON value (scalar, object or array).
func skipJSONValue(dec *json.Decoder) error {
	depth := 0
	for {
		tok, err := dec.Token()
		if err != nil {
			return err
		}
		switch tok {
		case json.Delim('{'), json.Delim('['):
			depth++
		case json.Delim('}'), json.Delim(']'):
			depth--
		}
		if depth == 0 {
			return nil
		}
	}
}

// lobbyBucket is the matchmaking bucket name shared by both stores:
// "<category>:<boot>" (the Redis key is prefix + "lobby:" + bucket).
func lobbyBucket(category string, bootAmount int64) string {
	return category + ":" + strconv.FormatInt(bootAmount, 10)
}

// lessCandidate orders matchmaking candidates: fullest first, then oldest
// first, then by room id so the order is total (tests and quick-join both
// rely on a deterministic list).
func lessCandidate(a, b TableSummary) bool {
	if a.Players != b.Players {
		return a.Players > b.Players
	}
	if a.CreatedAt != b.CreatedAt {
		return a.CreatedAt < b.CreatedAt
	}
	return a.RoomID < b.RoomID
}
