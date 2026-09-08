package game

import (
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Port of server/src/game/chat.js.

// ChatMessage is one room chat line, exactly as sent in chat:message and
// chat:history (the socket layer adds roomId on top — see socket.ChatMessageEvent).
//
// UserID is null for system lines, and the "system" key is present only when
// true (Node sets it only in addSystem) — hence *string and omitempty.
type ChatMessage struct {
	ID          string  `json:"id"`     // util.UUID()
	UserID      *string `json:"userId"` // nil → null for system lines
	DisplayName string  `json:"displayName"`
	Text        string  `json:"text"`
	At          int64   `json:"at"`               // epoch ms
	System      bool    `json:"system,omitempty"` // only ever true on system lines
}

// RoomChat is the in-memory chat history of one room.
//
// Deliberately never persisted: the log lives with the Table, is visible to
// whoever is in the room (including a late joiner, who is sent History()),
// and disappears with the room. The buffer is capped at MaxHistory so a
// long-lived table cannot grow without bound.
//
// Not goroutine-safe: it is owned by the Table and only touched on the actor
// goroutine.
type RoomChat struct {
	MaxHistory int
	MaxLength  int
	clock      Clock
	messages   []ChatMessage
}

// NewRoomChat builds an empty history with the caps from TableConfig
// (ChatMaxHistory / ChatMaxLength, i.e. config.Chat.MaxHistory / MaxLength).
func NewRoomChat(maxHistory, maxLength int, clock Clock) *RoomChat {
	return &RoomChat{MaxHistory: maxHistory, MaxLength: maxLength, clock: clock}
}

// Add sanitises and appends a player message, dropping the oldest once the
// cap is hit. Returns nil when nothing was left to send after sanitising
// (Node returns null; the Table then emits nothing and the ack is `{}`).
func (c *RoomChat) Add(userID, displayName, text string) *ChatMessage {
	clean := SanitizeChat(text, c.MaxLength)
	if clean == "" {
		return nil
	}
	id := userID
	message := ChatMessage{
		ID:          util.UUID(),
		UserID:      &id,
		DisplayName: displayName,
		Text:        clean,
		At:          Millis(c.now()),
	}
	return c.push(message)
}

// AddSystem appends a system line (a player joining or leaving): UserID nil,
// DisplayName ChatSystemDisplayName, System true, text truncated to MaxLength
// (NOT sanitised — Node only slices it).
func (c *RoomChat) AddSystem(text string) *ChatMessage {
	message := ChatMessage{
		ID:          util.UUID(),
		UserID:      nil,
		DisplayName: ChatSystemDisplayName,
		Text:        truncateUTF16(text, c.MaxLength),
		At:          Millis(c.now()),
		System:      true,
	}
	return c.push(message)
}

// push appends and drops the oldest lines past MaxHistory (Node: splice from
// the front). Returns a pointer to the caller's copy, not into the buffer, so
// a later eviction can never invalidate what the Table emits.
func (c *RoomChat) push(message ChatMessage) *ChatMessage {
	c.messages = append(c.messages, message)
	if excess := len(c.messages) - c.MaxHistory; excess > 0 {
		if excess > len(c.messages) {
			excess = len(c.messages)
		}
		// Re-slice from a fresh backing array so the dropped prefix is
		// released rather than pinned behind the slice header forever.
		kept := make([]ChatMessage, len(c.messages)-excess)
		copy(kept, c.messages[excess:])
		c.messages = kept
	}
	return &message
}

// now tolerates a nil Clock (a bare RoomChat in a test) by falling back to
// the wall clock, as Node's Date.now() did.
func (c *RoomChat) now() time.Time {
	if c.clock == nil {
		return RealClock{}.Now()
	}
	return c.clock.Now()
}

// History returns a copy of the messages, oldest first.
func (c *RoomChat) History() []ChatMessage {
	out := make([]ChatMessage, len(c.messages))
	copy(out, c.messages)
	return out
}

// Size is the number of buffered messages.
func (c *RoomChat) Size() int { return len(c.messages) }

// Clear empties the buffer (Table.Destroy).
func (c *RoomChat) Clear() { c.messages = c.messages[:0] }

// SanitizeChat is RoomChat.sanitize (chat.js:82-88), rule by rule
// (DECISIONS.md §4):
//
//  1. every Unicode "Other" rune — \p{C}: Cc control (which could smuggle
//     escape sequences into a client), Cf format (ZWJ/ZWNJ/BOM included, as
//     in Node), Co private use, Cs surrogates — and every UNASSIGNED rune is
//     replaced by one space, as `/[\p{C}]/gu` → ' ' does. A byte that is not
//     valid UTF-8 is treated the same way (Node would only ever have seen a
//     lone surrogate there, which is Cs);
//  2. runs of JavaScript `\s` whitespace (Go unicode.IsSpace plus U+FEFF)
//     collapse to one ASCII space;
//  3. the same class is trimmed from both ends;
//  4. the result is cut to maxLength UTF-16 code units, exactly what
//     String.prototype.slice counts, so an emoji costs 2 — except that a
//     pair is never split: the lone high half Node would have emitted is
//     dropped instead.
//
// Number/object coercion (`String(text ?? ”)`) is the socket layer's job:
// this function only ever receives a string.
func SanitizeChat(text string, maxLength int) string {
	var b strings.Builder
	b.Grow(len(text))
	pendingSpace := false
	for i := 0; i < len(text); {
		r, size := utf8.DecodeRuneInString(text[i:])
		i += size
		if (r == utf8.RuneError && size == 1) || !isAssignedNonC(r) || isJSSpace(r) {
			pendingSpace = true
			continue
		}
		if pendingSpace && b.Len() > 0 {
			b.WriteByte(' ')
		}
		pendingSpace = false
		b.WriteRune(r)
	}
	return truncateUTF16(b.String(), maxLength)
}

// isAssignedNonC reports whether r has a General Category other than C —
// i.e. it is assigned and is not control/format/surrogate/private-use. The
// complement is precisely what JavaScript's \p{C} matches (Cn, unassigned,
// included).
func isAssignedNonC(r rune) bool {
	return unicode.In(r, unicode.L, unicode.M, unicode.N, unicode.P, unicode.S, unicode.Z)
}

// isJSSpace is JavaScript's \s: WhiteSpace + LineTerminator = Go's
// White_Space property (unicode.IsSpace) plus U+FEFF. U+0085 (NEL) is in
// Go's set but not JS's; it is a Cc control, so step 1 has already turned it
// into a space by the time this matters.
func isJSSpace(r rune) bool {
	return r == '\uFEFF' || unicode.IsSpace(r)
}

// truncateUTF16 is String.prototype.slice(0, max) counted in UTF-16 code
// units, minus the split pair: a supplementary-plane rune that would only
// half fit is dropped whole. max <= 0 yields "" as slice(0, 0) does.
func truncateUTF16(s string, max int) string {
	if max <= 0 {
		return ""
	}
	units := 0
	for i, r := range s {
		width := 1
		if r >= 0x10000 {
			width = 2
		}
		if units+width > max {
			return s[:i]
		}
		units += width
	}
	return s
}
