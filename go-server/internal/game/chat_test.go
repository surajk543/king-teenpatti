package game

// Mirrors the buffer half of server/test/chat.test.js (the Table half lives
// with the table engineer) plus the sanitising rules DECISIONS.md §4 pins
// down: \p{C} + unassigned → space, JS \s collapsing, UTF-16 truncation.

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// stepClock is the minimal Clock these tests need (testclock.Fake imports
// this package, so it cannot be used from inside it). AfterFunc is never
// called by RoomChat.
type stepClock struct{ now time.Time }

func (c *stepClock) Now() time.Time { return c.now }
func (c *stepClock) AfterFunc(time.Duration, func()) Timer {
	panic("RoomChat must not arm timers")
}
func (c *stepClock) Advance(d time.Duration) { c.now = c.now.Add(d) }

func newChat(maxHistory, maxLength int) (*RoomChat, *stepClock) {
	clock := &stepClock{now: time.UnixMilli(1_700_000_000_000)}
	return NewRoomChat(maxHistory, maxLength, clock), clock
}

func TestChatMessagesAreStoredInOrderWithAuthorAndTimestamp(t *testing.T) {
	chat, clock := newChat(100, 140)
	first := chat.Add("u1", "Alice", "hello")
	clock.Advance(1500 * time.Millisecond)
	second := chat.Add("u2", "Bob", "gg")

	history := chat.History()
	if len(history) != 2 {
		t.Fatalf("%d messages, want 2", len(history))
	}
	if history[0].Text != "hello" || history[0].DisplayName != "Alice" || history[0].UserID == nil || *history[0].UserID != "u1" {
		t.Errorf("first message wrong: %+v", history[0])
	}
	if history[0].At != 1_700_000_000_000 || history[1].At != 1_700_000_001_500 {
		t.Errorf("timestamps must come from the injected clock: %d / %d", history[0].At, history[1].At)
	}
	if history[0].ID == "" || history[1].ID == "" || history[0].ID == history[1].ID {
		t.Errorf("ids must be fresh uuids: %q / %q", history[0].ID, history[1].ID)
	}
	if history[1].Text != "gg" {
		t.Errorf("second text %q", history[1].Text)
	}
	if first == nil || second == nil || first.ID != history[0].ID || second.ID != history[1].ID {
		t.Error("Add must return the stored message")
	}
	if history[0].System || history[1].System {
		t.Error("player messages are not system lines")
	}
	// History is a copy: mutating it must not touch the buffer.
	history[0].Text = "tampered"
	if chat.History()[0].Text != "hello" {
		t.Error("History must return a copy")
	}
}

func TestChatHistoryIsCappedAt100KeepingTheNewest(t *testing.T) {
	chat, _ := newChat(100, 140)
	for i := 1; i <= 150; i++ {
		chat.Add("u1", "Alice", "msg "+itoa(i))
	}
	history := chat.History()
	if len(history) != 100 {
		t.Fatalf("the buffer never exceeds the cap: %d", len(history))
	}
	if history[0].Text != "msg 51" {
		t.Errorf("the oldest messages were dropped: first is %q", history[0].Text)
	}
	if history[99].Text != "msg 150" {
		t.Errorf("the newest message is kept: last is %q", history[99].Text)
	}
	if chat.Size() != 100 {
		t.Errorf("Size %d", chat.Size())
	}
}

func TestChatCapIsConfigurable(t *testing.T) {
	chat, _ := newChat(3, 140)
	for _, text := range []string{"a", "b", "c", "d", "e"} {
		chat.Add("u", "U", text)
	}
	if got := texts(chat.History()); got != "c,d,e" {
		t.Errorf("history %q, want c,d,e", got)
	}
	// System lines share the same cap.
	chat.AddSystem("Zed joined the table")
	if got := texts(chat.History()); got != "d,e,Zed joined the table" {
		t.Errorf("history %q", got)
	}
}

func TestEmptyAndWhitespaceOnlyMessagesAreDropped(t *testing.T) {
	chat, _ := newChat(100, 140)
	for _, text := range []string{"", "    ", "\n\t\r", " \u3000\uFEFF", "\x00 \u200D\x1b", "\U000E0001", "\x7f"} {
		if m := chat.Add("u", "U", text); m != nil {
			t.Errorf("%q should be dropped, stored %q", text, m.Text)
		}
	}
	if chat.Size() != 0 {
		t.Errorf("size %d, want 0", chat.Size())
	}
}

func TestControlCharactersAreStrippedAndLongMessagesTrimmed(t *testing.T) {
	chat, _ := newChat(100, 20)

	// The escape byte is removed; the "[31m" after it is ordinary printable
	// text and is left alone, so the sequence can no longer colour a terminal.
	sneaky := chat.Add("u", "U", "hi \x1b[31m there")
	if sneaky == nil || sneaky.Text != "hi [31m there" {
		t.Fatalf("sneaky → %+v, want %q", sneaky, "hi [31m there")
	}
	if strings.ContainsRune(sneaky.Text, '\x1b') {
		t.Error("no control character reaches a client")
	}

	newlines := chat.Add("u", "U", "one\ntwo\r\nthree")
	if newlines.Text != "one two three" {
		t.Errorf("newlines collapse into spaces: %q", newlines.Text)
	}

	long := chat.Add("u", "U", strings.Repeat("x", 200))
	if len(long.Text) != 20 {
		t.Errorf("trimmed to %d, want 20", len(long.Text))
	}
}

func TestSanitizeChatRules(t *testing.T) {
	cases := []struct {
		in, want string
		max      int
	}{
		// \p{C} becomes a space (not nothing): "a\x00b" → "a b", as Node.
		{"a\x00b", "a b", 140},
		{"a\x1bb", "a b", 140},
		{"a\u200Db", "a b", 140},      // ZWJ (Cf) is destroyed, as in Node
		{"a\u200Cb", "a b", 140},      // ZWNJ
		{"\uFEFFhello", "hello", 140}, // BOM (Cf) then trim
		{"a\U000F0000b", "a b", 140},  // private use (Co)
		{"a\U000E0001b", "a b", 140},  // tag (Cf)
		{"a\U00050000b", "a b", 140},  // unassigned (Cn) — JS \p{C} matches it too
		{"a\x80b", "a b", 140},        // invalid UTF-8 byte treated as C
		// JS \s: NBSP, ideographic space, en/em spaces, line/para separators,
		// vertical tab and form feed all collapse.
		{"a\u00A0\u3000\u2000\u2003\u2028\u2029\v\f\u202F\u205F\u1680b", "a b", 140},
		{"  spaced   out  ", "spaced out", 140},
		{"\t\n hello \r\n", "hello", 140},
		// Cc runs between words merge with neighbouring spaces.
		{"one \x01\x02 two", "one two", 140},
		// Letters, marks (Indic vowel signs), numbers, punctuation and symbols survive.
		{"नमस्ते 123 !?", "नमस्ते 123 !?", 140},
		{"emoji 🃏 ok", "emoji 🃏 ok", 140},
		// U+FFFD written by the client is So and stays.
		{"a\uFFFDb", "a\uFFFDb", 140},
		// Length is in UTF-16 units: an emoji costs 2.
		{"🃏🃏🃏", "🃏🃏", 5},
		{"🃏🃏🃏", "🃏🃏🃏", 6},
		{"ab🃏", "ab", 3}, // the pair would be split → dropped whole
		{"abc", "abc", 3},
		{"abcd", "abc", 3},
		{"abc", "", 0},
		{"abc", "", -1},
	}
	for _, c := range cases {
		if got := SanitizeChat(c.in, c.max); got != c.want {
			t.Errorf("SanitizeChat(%q, %d) = %q, want %q", c.in, c.max, got, c.want)
		}
	}
	// The spec's asserted case: 'x'.repeat(5000) → length 140.
	if got := SanitizeChat(strings.Repeat("x", 5000), 140); len(got) != 140 {
		t.Errorf("5000 x → %d, want 140", len(got))
	}
}

func TestSanitizeChatNeverEmitsControlOrUnassignedRunes(t *testing.T) {
	// Every rune of the BMP and the first supplementary plane, one at a
	// time: whatever survives must be assigned and outside category C.
	for r := rune(1); r < 0x20000; r++ {
		if r >= 0xD800 && r <= 0xDFFF {
			continue // not encodable in UTF-8
		}
		out := SanitizeChat("a"+string(r)+"b", 140)
		for _, o := range out {
			if o == ' ' || o == 'a' || o == 'b' {
				continue
			}
			if !isAssignedNonC(o) {
				t.Fatalf("U+%04X survived sanitising", o)
			}
		}
	}
}

func TestSystemLinesHaveNoAuthorAndAreOnlySliced(t *testing.T) {
	chat, clock := newChat(100, 140)
	clock.Advance(42 * time.Millisecond)
	m := chat.AddSystem("Alice joined the table")
	if m.UserID != nil {
		t.Error("system lines have no author")
	}
	if m.DisplayName != "Table" || !m.System || m.Text != "Alice joined the table" || m.ID == "" {
		t.Errorf("system line wrong: %+v", m)
	}
	if m.At != 1_700_000_000_042 {
		t.Errorf("at %d", m.At)
	}
	// Not sanitised — an odd display name's control char passes; only the
	// UTF-16 slice applies.
	raw := chat.AddSystem("x\x01y")
	if raw.Text != "x\x01y" {
		t.Errorf("system text must not be sanitised: %q", raw.Text)
	}
	short, _ := newChat(100, 5)
	if got := short.AddSystem("abcdefgh").Text; got != "abcde" {
		t.Errorf("system slice %q, want abcde", got)
	}
	if got := short.AddSystem("ab🃏cd").Text; got != "ab🃏c" {
		t.Errorf("system slice counts UTF-16 units: %q", got)
	}
}

func TestChatMessageJSONShape(t *testing.T) {
	chat, _ := newChat(100, 140)
	player := chat.Add("u1", "Alice", "hi")
	system := chat.AddSystem("Alice joined the table")

	var p map[string]json.RawMessage
	b, _ := json.Marshal(player)
	if err := json.Unmarshal(b, &p); err != nil {
		t.Fatal(err)
	}
	if _, has := p["system"]; has {
		t.Errorf("player message must have no system key: %s", b)
	}
	for _, key := range []string{"id", "userId", "displayName", "text", "at"} {
		if _, has := p[key]; !has {
			t.Errorf("player message lacks %q: %s", key, b)
		}
	}
	if string(p["userId"]) != `"u1"` {
		t.Errorf("userId %s", p["userId"])
	}

	var s map[string]json.RawMessage
	b, _ = json.Marshal(system)
	if err := json.Unmarshal(b, &s); err != nil {
		t.Fatal(err)
	}
	if string(s["userId"]) != "null" || string(s["system"]) != "true" || string(s["displayName"]) != `"Table"` {
		t.Errorf("system line JSON wrong: %s", b)
	}
}

func TestClearingDropsTheWholeHistory(t *testing.T) {
	chat, _ := newChat(100, 140)
	chat.Add("u", "U", "hello")
	chat.AddSystem("U joined the table")
	chat.Clear()
	if chat.Size() != 0 || len(chat.History()) != 0 {
		t.Error("nothing survives Clear")
	}
	// Still usable afterwards.
	if chat.Add("u", "U", "again") == nil || chat.Size() != 1 {
		t.Error("buffer must keep working after Clear")
	}
}

func TestRoomChatWithoutAClockUsesWallTime(t *testing.T) {
	chat := NewRoomChat(10, 140, nil)
	before := time.Now().UnixMilli()
	m := chat.Add("u", "U", "now")
	if m.At < before || m.At > time.Now().UnixMilli() {
		t.Errorf("at %d not within wall time", m.At)
	}
}

func texts(messages []ChatMessage) string {
	out := make([]string, len(messages))
	for i, m := range messages {
		out[i] = m.Text
	}
	return strings.Join(out, ",")
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}
