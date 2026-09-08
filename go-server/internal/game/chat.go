package game

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
	panic("not ported: (*RoomChat).Add")
}

// AddSystem appends a system line (a player joining or leaving): UserID nil,
// DisplayName ChatSystemDisplayName, System true, text truncated to MaxLength
// (NOT sanitised — Node only slices it).
func (c *RoomChat) AddSystem(text string) *ChatMessage {
	panic("not ported: (*RoomChat).AddSystem")
}

// History returns a copy of the messages, oldest first.
func (c *RoomChat) History() []ChatMessage {
	panic("not ported: (*RoomChat).History")
}

// Size is the number of buffered messages.
func (c *RoomChat) Size() int { return len(c.messages) }

// Clear empties the buffer (Table.Destroy).
func (c *RoomChat) Clear() { c.messages = c.messages[:0] }

// SanitizeChat is RoomChat.sanitize: replaces every Unicode "Other" (\p{C}:
// control, format, surrogate, private-use, unassigned) rune with a space,
// collapses runs of whitespace to one space, trims, then truncates to
// maxLength CHARACTERS (Node's String.slice counts UTF-16 code units; the Go
// port counts runes — a documented, harmless deviation for non-BMP text).
func SanitizeChat(text string, maxLength int) string {
	panic("not ported: game.SanitizeChat")
}
