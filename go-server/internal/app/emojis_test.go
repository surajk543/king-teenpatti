package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
)

// The emoji store on the real wiring (owner, 26 Sep 2026): GET /api/emojis
// and POST /api/emojis/buy through the REST handler, the seat lock and
// PostgreSQL, and chat:emoji through the socket layer reading ownership from
// the same database on every send.

// insertEmoji adds one catalogue row and returns its id.
func insertEmoji(t *testing.T, database *db.DB, name, currency, kind string, cost int64, days, sortOrder int) int64 {
	t.Helper()
	var id int64
	if err := database.Pool.QueryRow(context.Background(),
		`INSERT INTO emojis (name, asset_url, currency, type, cost, duration_days, sort_order, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, 0, 0) RETURNING id`,
		name, "https://drive.example/"+name+".json", currency, kind, cost, days, sortOrder).Scan(&id); err != nil {
		t.Fatalf("insert emoji %s: %v", name, err)
	}
	return id
}

// getEmojis is GET /api/emojis with an optional Authorization header, the
// status and the raw body.
func getEmojis(t *testing.T, baseURL, authorization string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, baseURL+"/api/emojis", nil)
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res.StatusCode, body
}

func emojisIn(t *testing.T, body []byte) []db.Emoji {
	t.Helper()
	var out struct {
		Emojis []db.Emoji `json:"emojis"`
	}
	if err := json.Unmarshal(body, &out); err != nil || out.Emojis == nil {
		t.Fatalf("GET /api/emojis body %s: %v", body, err)
	}
	return out.Emojis
}

// postRaw is postJSON keeping the raw answer too.
func postRaw(t *testing.T, baseURL, token, path, body string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, baseURL+path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	return res.StatusCode, raw
}

func TestTheEmojiCatalogueIsListedWithAnOptionalTokenAndBoughtOverREST(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	welcome := a.cfg.Game.WelcomeChips

	// A fresh database lists the owner's nineteen seeded emojis (5 hammers for
	// 30 days each, Angry first, Tongue Face last); cleared, the listing is [].
	status, body := getEmojis(t, ts.URL, "")
	if seeded := emojisIn(t, body); status != http.StatusOK || len(seeded) != 19 ||
		seeded[0].Name != "Angry" || seeded[18].Name != "Tongue Face" {
		t.Fatalf("the seeded catalogue: %d %s", status, body)
	}
	if _, err := database.Pool.Exec(ctx, `DELETE FROM emojis`); err != nil {
		t.Fatal(err)
	}
	status, body = getEmojis(t, ts.URL, "")
	if status != http.StatusOK || string(body) != `{"emojis":[]}` {
		t.Fatalf("an empty catalogue: %d %s", status, body)
	}

	laughing := insertEmoji(t, database, "Laughing", db.PictureCurrencyDiamond, db.PicturePremium, 5, 0, 10)
	wave := insertEmoji(t, database, "Wave", db.PictureCurrencyCoin, db.PictureFree, 0, 0, 20)
	heart := insertEmoji(t, database, "Heart", db.PictureCurrencyCoin, db.PicturePremium, 50000, 7, 30)
	hammerTime := insertEmoji(t, database, "HammerTime", db.PictureCurrencyHammer, db.PicturePremium, 12, 30, 40)
	nail := insertEmoji(t, database, "Nail", db.PictureCurrencyHammer, db.PicturePremium, 1, 0, 50)
	crown := insertEmoji(t, database, "Crown", db.PictureCurrencyCoin, db.PicturePremium, 1_000_000_000, 0, 60)
	retired := insertEmoji(t, database, "Retired", db.PictureCurrencyCoin, db.PicturePremium, 10, 0, 5)
	if _, err := database.Pool.Exec(ctx, `UPDATE emojis SET is_active = FALSE WHERE id = $1`, retired); err != nil {
		t.Fatal(err)
	}

	// Anonymous, and with a token that is not one: the same listing, free
	// owned and premium not, the retired row left out.
	_, anonymous := getEmojis(t, ts.URL, "")
	_, junk := getEmojis(t, ts.URL, "Bearer not-a-token")
	if string(anonymous) != string(junk) {
		t.Fatalf("a bad token changed the listing:\n %s\n %s", anonymous, junk)
	}
	listed := emojisIn(t, anonymous)
	if len(listed) != 6 || listed[0].ID != laughing || listed[1].ID != wave || listed[1].Owned != true || listed[0].Owned {
		t.Fatalf("the anonymous listing = %+v", listed)
	}
	t.Logf("GET /api/emojis (anonymous): %s", anonymous)

	token, id := login(t, ts.URL, "emoji-buyer-device", "Emoji Buyer")
	res := postJSON(ts.URL, token, "/api/emojis/buy", map[string]any{"emojiId": laughing})
	if res.err != nil || res.status != http.StatusOK || res.body["charged"] != true || res.body["spent"] != float64(5) {
		t.Fatalf("a diamond buy: %d %v %v", res.status, res.body, res.err)
	}
	user, _ := res.body["user"].(map[string]any)
	emoji, _ := res.body["emoji"].(map[string]any)
	if user["diamond"] != float64(4) || user["chips"] != float64(welcome) || emoji["id"] != float64(laughing) || emoji["owned"] != true ||
		emoji["url"] != "https://drive.example/Laughing.json" || emoji["assetFormat"] != "LOTTIE" || emoji["expiresAt"] != float64(0) {
		t.Fatalf("the buy's answer: %v", res.body)
	}
	// Again: success, nothing moved.
	status, raw := postRaw(t, ts.URL, token, "/api/emojis/buy", fmt.Sprintf(`{"emojiId":%d}`, laughing))
	var again map[string]any
	_ = json.Unmarshal(raw, &again)
	if status != http.StatusOK || again["charged"] != false || again["spent"] != float64(0) {
		t.Fatalf("a second buy: %d %s", status, raw)
	}
	t.Logf("POST /api/emojis/buy (already owned): %s", raw)

	// The id as its text; a chip price through the ledger, which reconciles.
	status, raw = postRaw(t, ts.URL, token, "/api/emojis/buy", fmt.Sprintf(`{"emojiId":"%d"}`, heart))
	if status != http.StatusOK {
		t.Fatalf("a chip buy by the id's text: %d %s", status, raw)
	}
	t.Logf("POST /api/emojis/buy (chips): %s", raw)
	if wallet, ledger := walletAndLedger(t, database, id); wallet != welcome-50000 || ledger != wallet {
		t.Fatalf("after the chip buy: wallet %d, ledger %d", wallet, ledger)
	}
	var reason, actionID string
	if err := database.Pool.QueryRow(ctx,
		`SELECT reason, action_id FROM chip_ledger WHERE user_id = $1 ORDER BY id DESC LIMIT 1`, id).Scan(&reason, &actionID); err != nil ||
		reason != "emoji_purchase" || actionID != fmt.Sprintf("emoji:%s:%d:1", id, heart) {
		t.Fatalf("the ledger row: %q %q %v", reason, actionID, err)
	}

	// The buyer's own listing says what is theirs, with the rental's expiry.
	_, mine := getEmojis(t, ts.URL, "Bearer "+token)
	for _, e := range emojisIn(t, mine) {
		switch e.ID {
		case laughing:
			if !e.Owned || e.ExpiresAt != 0 {
				t.Errorf("Laughing in the buyer's listing: %+v", e)
			}
		case heart:
			if !e.Owned || e.ExpiresAt <= time.Now().UnixMilli() {
				t.Errorf("Heart in the buyer's listing: %+v", e)
			}
		case hammerTime, nail, crown:
			if e.Owned {
				t.Errorf("%s reads as owned: %+v", e.Name, e)
			}
		}
	}

	// The refusals, each with its code, status and sentence.
	refused := func(body string, status int, code, message string) {
		t.Helper()
		got, raw := postRaw(t, ts.URL, token, "/api/emojis/buy", body)
		var answer auth.ErrorResponse
		if err := json.Unmarshal(raw, &answer); err != nil || got != status || answer.Error != code || answer.Message != message {
			t.Errorf("buy %s: %d %s, want %d %s %q", body, got, raw, status, code, message)
		}
	}
	refused(`{"emojiId":987654}`, 400, "unknown_emoji", "That emoji does not exist.")
	refused(`{}`, 400, "unknown_emoji", "That emoji does not exist.")
	refused(`{"emojiId":"abc"}`, 400, "unknown_emoji", "That emoji does not exist.")
	refused(`{"emojiId":null}`, 400, "unknown_emoji", "That emoji does not exist.")
	refused(fmt.Sprintf(`{"emojiId":%d}`, retired), 400, "emoji_retired", "That emoji is no longer available.")
	refused(fmt.Sprintf(`{"emojiId":%d}`, wave), 400, "emoji_free", "That emoji is free — it is already yours.")
	refused(fmt.Sprintf(`{"emojiId":%d}`, crown), 409, "emoji_unaffordable", "You need 1000000000 chips to unlock this emoji.")
	if _, err := database.Pool.Exec(ctx, `UPDATE users SET diamond = 0, hammer = 0 WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Pool.Exec(ctx, `DELETE FROM user_emojis WHERE user_id = $1 AND emoji_id = $2`, id, laughing); err != nil {
		t.Fatal(err)
	}
	refused(fmt.Sprintf(`{"emojiId":%d}`, laughing), 409, "emoji_unaffordable", "You need 5 diamonds to unlock this emoji.")
	refused(fmt.Sprintf(`{"emojiId":%d}`, hammerTime), 409, "emoji_unaffordable", "You need 12 hammers to unlock this emoji.")
	refused(fmt.Sprintf(`{"emojiId":%d}`, nail), 409, "emoji_unaffordable", "You need 1 hammer to unlock this emoji.")
	if got, raw := postRaw(t, ts.URL, "", "/api/emojis/buy", fmt.Sprintf(`{"emojiId":%d}`, heart)); got != http.StatusUnauthorized {
		t.Errorf("a buy without a token: %d %s", got, raw)
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != welcome-50000 || ledger != wallet {
		t.Fatalf("after the refusals: wallet %d, ledger %d", wallet, ledger)
	}
}

// At a table: a chip-priced emoji is refused 409 seated, a hammer one sells,
// and chat:emoji sends what the player owns to everybody there — reading the
// database on every send, so a rental that has run out is locked at once and a
// retired emoji is refused.
func TestASeatedPlayerBuysAHammerEmojiAndSendsItToTheTable(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	welcome := a.cfg.Game.WelcomeChips

	wave := insertEmoji(t, database, "Wave", db.PictureCurrencyCoin, db.PictureFree, 0, 0, 10)
	heart := insertEmoji(t, database, "Heart", db.PictureCurrencyCoin, db.PicturePremium, 50000, 7, 20)
	hammerTime := insertEmoji(t, database, "HammerTime", db.PictureCurrencyHammer, db.PicturePremium, 12, 30, 30)
	laughing := insertEmoji(t, database, "Laughing", db.PictureCurrencyDiamond, db.PicturePremium, 5, 0, 40)

	token, id := login(t, ts.URL, "emoji-seated-device", "Emoji Seated")
	otherToken, _ := login(t, ts.URL, "emoji-other-device", "Emoji Other")
	c := dial(t, ts.URL, token)
	joined := mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	var room struct {
		Code   string `json:"code"`
		RoomID string `json:"roomId"`
	}
	if err := json.Unmarshal(joined.Raw, &room); err != nil || room.Code == "" {
		t.Fatalf("quick join: %s %v", joined.Raw, err)
	}
	other := dial(t, ts.URL, otherToken)
	mustOK(t, other, socket.EvRoomJoinCode, map[string]any{"code": room.Code})

	res := postJSON(ts.URL, token, "/api/emojis/buy", map[string]any{"emojiId": heart})
	if res.err != nil || res.status != http.StatusConflict || res.body["error"] != auth.CodeSeated ||
		res.body["message"] != "You can only buy a chip-priced emoji in the lobby." {
		t.Fatalf("a seated chip buy: %d %v %v", res.status, res.body, res.err)
	}
	res = postJSON(ts.URL, token, "/api/emojis/buy", map[string]any{"emojiId": hammerTime})
	if res.err != nil || res.status != http.StatusOK || res.body["charged"] != true || res.body["spent"] != float64(12) {
		t.Fatalf("a seated hammer buy: %d %v %v", res.status, res.body, res.err)
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != welcome || ledger != wallet {
		t.Fatalf("a seated emoji buy moved the chips: wallet %d, ledger %d", wallet, ledger)
	}

	// Sent: the other player receives the ordinary chat:message with the emoji.
	ack := mustOK(t, c, socket.EvChatEmoji, map[string]any{"emojiId": hammerTime})
	var sent struct {
		MessageID string `json:"messageId"`
	}
	if err := json.Unmarshal(ack.Raw, &sent); err != nil || sent.MessageID == "" {
		t.Fatalf("chat:emoji ack %s", ack.Raw)
	}
	msg, err := other.Wait(socket.EvChatMessageOut, func(p json.RawMessage) bool { return jsonPath(p, "id") == sent.MessageID }, 4*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if jsonPath(msg, "text") != "HammerTime" || jsonPath(msg, "userId") != id || jsonPath(msg, "roomId") != room.RoomID ||
		jsonPath(msg, "emoji.id") != float64(hammerTime) || jsonPath(msg, "emoji.name") != "HammerTime" ||
		jsonPath(msg, "emoji.url") != "https://drive.example/HammerTime.json" || jsonPath(msg, "emoji.assetFormat") != "LOTTIE" {
		t.Fatalf("the emoji line: %s", msg)
	}
	t.Logf("chat:message (emoji, real wiring): %s", msg)
	mustOK(t, c, socket.EvChatEmoji, map[string]any{"emojiId": wave})

	refused := func(id int64, code string) {
		t.Helper()
		ack, err := c.Call(socket.EvChatEmoji, map[string]any{"emojiId": id}, 4*time.Second)
		if err != nil || ack.OK || ack.Code != code {
			t.Errorf("chat:emoji %d: %v %s, want %s", id, err, ack.Raw, code)
		}
	}
	refused(laughing, auth.CodeEmojiLocked)
	refused(987654, auth.CodeUnknownEmoji)
	// The rental runs out: the very next send is locked.
	if _, err := database.Pool.Exec(ctx, `UPDATE user_emojis SET expires_at = 1 WHERE user_id = $1 AND emoji_id = $2`, id, hammerTime); err != nil {
		t.Fatal(err)
	}
	refused(hammerTime, auth.CodeEmojiLocked)
	// A retired emoji is not sent, free or not.
	if _, err := database.Pool.Exec(ctx, `UPDATE emojis SET is_active = FALSE WHERE id = $1`, wave); err != nil {
		t.Fatal(err)
	}
	refused(wave, auth.CodeEmojiRetired)
}
