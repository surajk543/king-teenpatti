package socket

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// chat:emoji over real sockets (owner, 26 Sep 2026): a player sends an
// animated emoji they own, and everybody at the table receives it as an
// ordinary chat:message carrying the emoji. The catalogue is a fake of
// db.Emojis.Owns — the database's side is proven in internal/db and on the
// real wiring in internal/app.

// fakeEmojis is db.Emojis.Owns without the database: rows by id, and who owns
// which premium one until when (epoch ms, 0 for ever).
type fakeEmojis struct {
	mu    sync.Mutex
	rows  map[int64]fakeEmojiRow
	owned map[string]int64
	// reads counts every Owns call: chat:emoji must read the catalogue on
	// every send, and never for a sender who is not at a table.
	reads atomic.Int64
}

type fakeEmojiRow struct {
	emoji  db.Emoji
	active bool
}

func newFakeEmojis() *fakeEmojis {
	return &fakeEmojis{rows: map[int64]fakeEmojiRow{}, owned: map[string]int64{}}
}

// add puts a row in the catalogue; kind is db.PictureFree or db.PicturePremium.
func (f *fakeEmojis) add(id int64, name, kind string) db.Emoji {
	f.mu.Lock()
	defer f.mu.Unlock()
	e := db.Emoji{
		ID: id, Name: name, URL: fmt.Sprintf("https://drive.example/emoji-%d.json", id), AssetFormat: db.EmojiFormatLottie,
		Currency: db.PictureCurrencyDiamond, Type: kind, SortOrder: int(id),
	}
	if kind == db.PicturePremium {
		e.Cost = 5
	}
	f.rows[id] = fakeEmojiRow{emoji: e, active: true}
	return e
}

func (f *fakeEmojis) retire(id int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	row := f.rows[id]
	row.active = false
	f.rows[id] = row
}

// grant records userID owning id until expiresAt (0 = for ever).
func (f *fakeEmojis) grant(userID string, id, expiresAt int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.owned[userID+":"+fmt.Sprint(id)] = expiresAt
}

func (f *fakeEmojis) Owns(_ context.Context, userID string, id int64) (db.Emoji, error) {
	f.reads.Add(1)
	f.mu.Lock()
	defer f.mu.Unlock()
	row, ok := f.rows[id]
	switch {
	case !ok:
		return db.Emoji{}, db.ErrEmojiUnknown
	case !row.active:
		return db.Emoji{}, db.ErrEmojiInactive
	}
	if row.emoji.Type == db.PicturePremium {
		until, bought := f.owned[userID+":"+fmt.Sprint(id)]
		if !bought || (until != 0 && until <= time.Now().UnixMilli()) {
			return db.Emoji{}, db.ErrEmojiLocked
		}
	}
	e := row.emoji
	e.Owned = true
	return e, nil
}

// emojiLine reports whether a chat:message is the emoji line with that id.
func emojiLine(id int64) func(json.RawMessage) bool {
	return func(p json.RawMessage) bool { return has(p, "emoji") && num(p, "emoji.id") == float64(id) }
}

func TestAnEmojiReachesEveryoneAtTheTableAsAChatMessageCarryingIt(t *testing.T) {
	st := newStack(t, nil)
	laughing := st.emojis.add(3, "Laughing", db.PicturePremium)
	wave := st.emojis.add(4, "Wave", db.PictureFree)
	d := st.dealtTable("")
	st.emojis.grant(d.a.user.ID, laughing.ID, 0)
	outsider := st.player("Outsider")
	st.mustOK(outsider.c, EvRoomQuickJoin, map[string]any{"bootAmount": st.uniqueStake()})

	ack := st.mustOK(d.a.c, EvChatEmoji, map[string]any{"emojiId": 3})
	messageID := str(ack.Raw, "messageId")
	if messageID == "" || string(ack.Raw) != `{"ok":true,"messageId":"`+messageID+`"}` {
		t.Fatalf("chat:emoji ack: %s", ack.Raw)
	}
	t.Logf("chat:emoji ack: %s", ack.Raw)

	// Everybody at the table — the sender included — gets the ordinary
	// chat:message, its text the emoji's name and the emoji beside it, key
	// for key what the contract says.
	for _, p := range []*player{d.a, d.b} {
		msg, err := p.c.Wait(EvChatMessageOut, emojiLine(laughing.ID), eventTimeout)
		if err != nil {
			t.Fatalf("%s got no emoji line: %v", p.user.DisplayName, err)
		}
		want := fmt.Sprintf(`{"id":"%s","userId":"%s","displayName":"Alice","text":"Laughing","at":%d,`+
			`"emoji":{"id":3,"name":"Laughing","url":"https://drive.example/emoji-3.json","assetFormat":"LOTTIE"},"roomId":"%s"}`,
			messageID, d.a.user.ID, int64(num(msg, "at")), d.roomID)
		if string(msg) != want || num(msg, "at") <= 0 {
			t.Fatalf("%s's chat:message:\n %s\nwant\n %s", p.user.DisplayName, msg, want)
		}
		if p == d.b {
			t.Logf("chat:message (emoji): %s", msg)
		}
	}
	time.Sleep(150 * time.Millisecond)
	for _, p := range outsider.c.All(EvChatMessageOut) {
		if has(p, "emoji") {
			t.Fatalf("an emoji leaked to another table: %s", p)
		}
	}

	// The id may come as its text; a free emoji needs no purchase; and the
	// other player sends too.
	st.mustOK(d.a.c, EvChatEmoji, map[string]any{"emojiId": "4"})
	st.mustOK(d.b.c, EvChatEmoji, map[string]any{"emojiId": wave.ID})
	if _, err := d.a.c.Wait(EvChatMessageOut, func(p json.RawMessage) bool {
		return str(p, "userId") == d.b.user.ID && num(p, "emoji.id") == float64(wave.ID) && str(p, "text") == "Wave"
	}, eventTimeout); err != nil {
		t.Fatalf("Bob's free emoji: %v", err)
	}

	// A typed line is exactly what it was: no emoji key, not even null.
	st.mustOK(d.b.c, EvChatMessage, map[string]any{"text": "nice one"})
	plain, err := d.a.c.Wait(EvChatMessageOut, func(p json.RawMessage) bool { return str(p, "text") == "nice one" }, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if has(plain, "emoji") {
		t.Fatalf("a typed line carries an emoji key: %s", plain)
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(plain, &keys); err != nil || len(keys) != 6 {
		t.Fatalf("a typed line has keys %v, want id, userId, displayName, text, at, roomId", keys)
	}

	// A later joiner's history carries the emoji lines, emoji and all, beside
	// the typed one without.
	late := st.player("Late")
	st.mustOK(late.c, EvRoomJoinCode, map[string]any{"code": d.code})
	hist, err := late.c.Wait(EvChatHistoryOut, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	emojis, typed := 0, 0
	for _, m := range arr(hist, "messages") {
		line := m.(map[string]any)
		emoji, present := line["emoji"]
		switch line["text"] {
		case "Laughing":
			e := emoji.(map[string]any)
			if e["id"] != float64(3) || e["name"] != "Laughing" || e["url"] != laughing.URL || e["assetFormat"] != "LOTTIE" || line["id"] != messageID {
				t.Fatalf("the emoji line in the history: %v", line)
			}
			emojis++
		case "Wave":
			emojis++
		case "nice one":
			if present {
				t.Fatalf("the typed line in the history carries an emoji: %v", line)
			}
			typed++
		default:
			if present {
				t.Fatalf("a system line carries an emoji: %v", line)
			}
		}
	}
	if emojis != 3 || typed != 1 {
		t.Fatalf("the history holds %d emoji line(s) and %d typed, want 3 and 1: %s", emojis, typed, hist)
	}
	t.Logf("chat:history: %s", hist)

	// An emoji is a chat message to the metrics too, and chat:emoji is a known
	// event, never "other".
	if v := metricValue(st.metrics.SocketMessagesTotal.WithLabelValues(EvChatEmoji)); v != 3 {
		t.Fatalf("game_socket_messages_total{event=chat:emoji} = %v, want 3", v)
	}
	if v := metricValue(st.metrics.ChatMessagesTotal); v < 4 {
		t.Fatalf("game_chat_messages_total = %v, want the three emojis and the typed line counted", v)
	}
}

// Every refusal, in the contract's order: not at a table (before the
// catalogue is read at all), an id that is not one, no such row, a retired
// one, a premium one not bought or whose rental has run out. Each is acked
// {ok:false, code, message} AND reported on game:error, and counted under its
// own code.
func TestChatEmojiRefusalsComeInTheContractsOrder(t *testing.T) {
	st := newStack(t, nil)
	laughing := st.emojis.add(3, "Laughing", db.PicturePremium)
	retired := st.emojis.add(5, "Retired", db.PictureFree)
	st.emojis.retire(retired.ID)
	lapsed := st.emojis.add(6, "Lapsed", db.PicturePremium)

	loner := st.player("Loner")
	for _, payload := range []any{map[string]any{"emojiId": 3}, map[string]any{"emojiId": 987654}, map[string]any{}} {
		ack := st.mustFail(loner.c, EvChatEmoji, payload, game.CodeNotInRoom)
		if ack.Message != game.MsgNotInRoom && ack.Message != MsgNotAtTable {
			t.Fatalf("not_in_room message %q", ack.Message)
		}
	}
	if n := st.emojis.reads.Load(); n != 0 {
		t.Fatalf("an unseated send read the catalogue %d time(s)", n)
	}

	d := st.dealtTable("")
	st.emojis.grant(d.a.user.ID, lapsed.ID, time.Now().Add(-time.Minute).UnixMilli())
	for _, id := range []any{0, -3, 3.5, 1e300, "abc", "3x", "", true, nil, map[string]any{}, []any{3}, 987654} {
		ack := st.mustFail(d.a.c, EvChatEmoji, map[string]any{"emojiId": id}, auth.CodeUnknownEmoji)
		if ack.Message != "That emoji does not exist." {
			t.Fatalf("unknown_emoji message %q", ack.Message)
		}
	}
	st.mustFail(d.a.c, EvChatEmoji, map[string]any{}, auth.CodeUnknownEmoji)
	st.mustFail(d.a.c, EvChatEmoji, nil, auth.CodeUnknownEmoji)
	if ack := st.mustFail(d.a.c, EvChatEmoji, map[string]any{"emojiId": retired.ID}, auth.CodeEmojiRetired); ack.Message != "That emoji is no longer available." {
		t.Fatalf("emoji_retired message %q", ack.Message)
	}
	if ack := st.mustFail(d.a.c, EvChatEmoji, map[string]any{"emojiId": laughing.ID}, auth.CodeEmojiLocked); ack.Message != "Unlock this emoji in the store first." {
		t.Fatalf("emoji_locked message %q", ack.Message)
	}
	// A rental that has run out is locked as surely as one never bought.
	st.mustFail(d.a.c, EvChatEmoji, map[string]any{"emojiId": lapsed.ID}, auth.CodeEmojiLocked)
	if _, err := d.a.c.Wait(EvGameError, func(p json.RawMessage) bool { return str(p, "code") == auth.CodeEmojiLocked }, eventTimeout); err != nil {
		t.Fatalf("emoji_locked was not reported on game:error: %v", err)
	}
	for _, code := range []string{auth.CodeUnknownEmoji, auth.CodeEmojiRetired, auth.CodeEmojiLocked} {
		if v := metricValue(st.metrics.SocketErrorsTotal.WithLabelValues(code)); v < 1 {
			t.Fatalf("game_socket_errors_total{code=%s} = %v", code, v)
		}
	}
	// Nothing reached the table.
	time.Sleep(100 * time.Millisecond)
	for _, p := range d.b.c.All(EvChatMessageOut) {
		if has(p, "emoji") {
			t.Fatalf("a refused emoji reached the table: %s", p)
		}
	}
}

// Ownership is read on every send, never remembered: an emoji bought mid-
// sitting can be sent at once, and one whose rental runs out mid-sitting stops
// at the very next send.
func TestChatEmojiReadsOwnershipOnEverySend(t *testing.T) {
	st := newStack(t, nil)
	laughing := st.emojis.add(3, "Laughing", db.PicturePremium)
	d := st.dealtTable("")

	st.mustFail(d.a.c, EvChatEmoji, map[string]any{"emojiId": laughing.ID}, auth.CodeEmojiLocked)
	st.emojis.grant(d.a.user.ID, laughing.ID, time.Now().Add(time.Hour).UnixMilli())
	before := st.emojis.reads.Load()
	st.mustOK(d.a.c, EvChatEmoji, map[string]any{"emojiId": laughing.ID})
	st.mustOK(d.a.c, EvChatEmoji, map[string]any{"emojiId": laughing.ID})
	if n := st.emojis.reads.Load() - before; n != 2 {
		t.Fatalf("two sends read the catalogue %d time(s), want once each", n)
	}
	st.emojis.grant(d.a.user.ID, laughing.ID, time.Now().Add(-time.Second).UnixMilli())
	st.mustFail(d.a.c, EvChatEmoji, map[string]any{"emojiId": laughing.ID}, auth.CodeEmojiLocked)
}

// An emoji is a chat message: it spends the same per-socket chat allowance as
// a typed line (CHAT_RATE_LIMIT / CHAT_RATE_WINDOW_MS), so the two together
// are held to one budget — and a send refused on the catalogue spends none.
func TestChatEmojiSharesTheChatAllowance(t *testing.T) {
	st := newStack(t, nil)
	wave := st.emojis.add(4, "Wave", db.PictureFree)
	locked := st.emojis.add(7, "Locked", db.PicturePremium)
	d := st.dealtTable("")
	budget := st.cfg.Chat.RateLimit
	if budget < 2 {
		t.Fatalf("the chat allowance is %d; this test needs at least 2", budget)
	}

	// A refused emoji spends nothing: the catalogue is checked first.
	for i := 0; i < budget+2; i++ {
		st.mustFail(d.a.c, EvChatEmoji, map[string]any{"emojiId": locked.ID}, auth.CodeEmojiLocked)
	}
	// Then the allowance, half typed and half emojis.
	for i := 0; i < budget; i++ {
		if i%2 == 0 {
			st.mustOK(d.a.c, EvChatMessage, map[string]any{"text": fmt.Sprintf("line %d", i)})
		} else {
			st.mustOK(d.a.c, EvChatEmoji, map[string]any{"emojiId": wave.ID})
		}
	}
	ack := st.mustFail(d.a.c, EvChatEmoji, map[string]any{"emojiId": wave.ID}, game.CodeChatRateLimited)
	if ack.Message != MsgChatRateLimited {
		t.Fatalf("chat_rate_limited message %q", ack.Message)
	}
	st.mustFail(d.a.c, EvChatMessage, map[string]any{"text": "one more"}, game.CodeChatRateLimited)
	// Past the allowance the catalogue still speaks first.
	st.mustFail(d.a.c, EvChatEmoji, map[string]any{"emojiId": locked.ID}, auth.CodeEmojiLocked)
	// The other player's allowance is their own.
	st.mustOK(d.b.c, EvChatEmoji, map[string]any{"emojiId": wave.ID})
}

// A poker room takes an emoji exactly as a Teen Patti table does: the same
// chat:message to every player there, and the same history.
func TestAnEmojiIsSentAtAPokerRoomToo(t *testing.T) {
	st := newStack(t, nil)
	wave := st.emojis.add(4, "Wave", db.PictureFree)
	f := st.pokerTable("texas_holdem", 2)
	sender, other := f.players[0], f.players[1]

	ack := st.mustOK(sender.c, EvChatEmoji, map[string]any{"emojiId": wave.ID})
	for _, p := range f.players {
		msg, err := p.c.Wait(EvChatMessageOut, emojiLine(wave.ID), eventTimeout)
		if err != nil {
			t.Fatalf("%s got no emoji line at the poker room: %v", p.user.DisplayName, err)
		}
		if str(msg, "id") != str(ack.Raw, "messageId") || str(msg, "userId") != sender.user.ID || str(msg, "text") != "Wave" ||
			str(msg, "roomId") != f.roomID || str(msg, "emoji.url") != wave.URL || str(msg, "emoji.assetFormat") != "LOTTIE" {
			t.Fatalf("the poker room's emoji line: %s", msg)
		}
	}
	count := st.mustOK(other.c, EvChatHistory, map[string]any{})
	hist, err := other.c.Wait(EvChatHistoryOut, func(p json.RawMessage) bool {
		for _, m := range arr(p, "messages") {
			if _, ok := m.(map[string]any)["emoji"]; ok {
				return true
			}
		}
		return false
	}, eventTimeout)
	if err != nil || num(count.Raw, "count") < 1 {
		t.Fatalf("the poker room's history lacks the emoji line: %v %s", err, hist)
	}
}
