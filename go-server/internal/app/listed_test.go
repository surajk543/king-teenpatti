package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// Taking an item off the shelves on the real wiring (owner, 1 Oct 2026: "if
// it is false, then user will not see these assets in UI or UI store"):
// is_listed = FALSE on a profile picture, a table picture, an emoji or a badge
// leaves it out of GET /api/profiles, /api/table-pictures, /api/emojis and
// /api/levels for everybody who does not have it — signed out, or signed in as
// somebody else — keeps it on the shelf of the player who does, and refuses it
// to a buyer with the "no longer available" refusal an installed app already
// knows. internal/db/listed_test.go has the rules one by one.

// shelfGet is a GET with an optional bearer token: the status and the body.
func shelfGet(t *testing.T, baseURL, path, token string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, baseURL+path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res.StatusCode, body
}

// shelves is what one viewer is shown of the three item catalogues: each id
// listed, and whether it reads as theirs.
type shelves struct {
	profiles, tables, emojis map[int64]bool
}

func shelvesOf(t *testing.T, baseURL, token string) shelves {
	t.Helper()
	var profiles struct {
		Profiles []db.Picture `json:"profiles"`
	}
	var tables struct {
		TablePictures []db.TablePicture `json:"tablePictures"`
	}
	var emojis struct {
		Emojis []db.Emoji `json:"emojis"`
	}
	for _, route := range []struct {
		path string
		into any
	}{{"/api/profiles", &profiles}, {"/api/table-pictures", &tables}, {"/api/emojis", &emojis}} {
		status, body := shelfGet(t, baseURL, route.path, token)
		if err := json.Unmarshal(body, route.into); status != http.StatusOK || err != nil {
			t.Fatalf("GET %s: %d %s %v", route.path, status, body, err)
		}
	}
	out := shelves{profiles: map[int64]bool{}, tables: map[int64]bool{}, emojis: map[int64]bool{}}
	for _, p := range profiles.Profiles {
		out.profiles[p.ID] = p.Owned
	}
	for _, p := range tables.TablePictures {
		out.tables[p.ID] = p.Owned
	}
	for _, e := range emojis.Emojis {
		out.emojis[e.ID] = e.Owned
	}
	return out
}

// badgeCodes is GET /api/levels' badge catalogue, by code.
func badgeCodes(t *testing.T, baseURL string) map[string]bool {
	t.Helper()
	status, body := shelfGet(t, baseURL, "/api/levels", "")
	var ladder struct {
		Badges []struct {
			Code string `json:"code"`
		} `json:"badges"`
	}
	if err := json.Unmarshal(body, &ladder); status != http.StatusOK || err != nil {
		t.Fatalf("GET /api/levels: %d %s %v", status, body, err)
	}
	codes := map[string]bool{}
	for _, b := range ladder.Badges {
		codes[b.Code] = true
	}
	return codes
}

func TestUnlistedItemsLeaveTheShelvesButStayWithWhoeverHasThem(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := database.Pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}

	owner, ownerID := login(t, ts.URL, "listed-owner-device", "Shelf Owner")
	stranger, strangerID := login(t, ts.URL, "listed-stranger-device", "Shelf Stranger")
	// Both can afford everything, so that a refusal below is the shelf's and
	// never the wallet's.
	exec(`UPDATE users SET hammer = 100, diamond = 100 WHERE id IN ($1, $2)`, ownerID, strangerID)

	picture := insertPicture(t, database, "Shelf Cat", db.PictureCurrencyHammer, 3)
	table := insertTablePicture(t, database, "Shelf Felt", db.PictureCurrencyHammer, db.PicturePremium, 3, 0)
	emoji := insertEmoji(t, database, "Shelf Wave", db.PictureCurrencyHammer, db.PicturePremium, 3, 0, 999)
	const badge = "ROYAL_KING"

	// On sale, everybody sees all four; the owner buys the three items, wears
	// the picture and lays the table picture.
	for _, token := range []string{"", stranger, owner} {
		if s := shelvesOf(t, ts.URL, token); !hasKey(s.profiles, picture) || !hasKey(s.tables, table) || !hasKey(s.emojis, emoji) {
			t.Fatalf("on sale, a viewer (token %t) is not shown every item: %+v", token != "", s)
		}
	}
	if !badgeCodes(t, ts.URL)[badge] {
		t.Fatalf("on sale, /api/levels does not list %s", badge)
	}
	for path, body := range map[string]map[string]any{
		"/api/profile/picture/buy": {"pictureId": picture},
		"/api/table-pictures/buy":  {"pictureId": table},
		"/api/emojis/buy":          {"emojiId": emoji},
	} {
		if res := postJSON(ts.URL, owner, path, body); res.err != nil || res.status != http.StatusOK || res.body["charged"] != true {
			t.Fatalf("the owner's buy at %s: %d %v %v", path, res.status, res.body, res.err)
		}
	}
	if res := postJSON(ts.URL, owner, "/api/profile/avatar", map[string]any{"avatar": picture}); res.err != nil || res.status != http.StatusOK {
		t.Fatalf("wearing: %d %v %v", res.status, res.body, res.err)
	}
	if res := postJSON(ts.URL, owner, "/api/table-pictures/use", map[string]any{"pictureId": table}); res.err != nil || res.status != http.StatusOK {
		t.Fatalf("laying: %d %v %v", res.status, res.body, res.err)
	}

	// Off the shelves.
	exec(`UPDATE profile_pictures SET is_listed = FALSE WHERE id = $1`, picture)
	exec(`UPDATE table_pictures SET is_listed = FALSE WHERE id = $1`, table)
	exec(`UPDATE emojis SET is_listed = FALSE WHERE id = $1`, emoji)
	exec(`UPDATE badges SET is_listed = FALSE WHERE code = $1`, badge)

	// Signed out, and signed in as somebody who has none of them: gone.
	for _, token := range []string{"", stranger} {
		s := shelvesOf(t, ts.URL, token)
		if hasKey(s.profiles, picture) || hasKey(s.tables, table) || hasKey(s.emojis, emoji) {
			t.Errorf("unlisted, a viewer who has none of them (token %t) is still shown one: picture %t, table %t, emoji %t",
				token != "", hasKey(s.profiles, picture), hasKey(s.tables, table), hasKey(s.emojis, emoji))
		}
	}
	if badgeCodes(t, ts.URL)[badge] {
		t.Errorf("unlisted, /api/levels still lists %s", badge)
	}
	// The rest of the shelves are as they were.
	if codes := badgeCodes(t, ts.URL); !codes["REGULAR"] || !codes["ROYAL_ACE"] || len(codes) != 6 {
		t.Errorf("the badge catalogue after unlisting one = %v, want the other six", codes)
	}

	// The owner still has all three, on their own shelves, as theirs.
	if s := shelvesOf(t, ts.URL, owner); !s.profiles[picture] || !s.tables[table] || !s.emojis[emoji] {
		t.Errorf("unlisted, the owner's shelves lost what they bought: picture %t, table %t, emoji %t",
			s.profiles[picture], s.tables[table], s.emojis[emoji])
	}

	// Not for sale to anybody else — the refusal an installed app already
	// knows, and nothing moves.
	refused := func(path, body, code, message string) {
		t.Helper()
		status, raw := postRaw(t, ts.URL, stranger, path, body)
		var answer auth.ErrorResponse
		if err := json.Unmarshal(raw, &answer); err != nil || status != http.StatusBadRequest || answer.Error != code || answer.Message != message {
			t.Errorf("POST %s %s: %d %s, want 400 %s %q", path, body, status, raw, code, message)
		}
	}
	refused("/api/profile/picture/buy", fmt.Sprintf(`{"pictureId":%d}`, picture), "picture_retired", "That picture is no longer available.")
	refused("/api/table-pictures/buy", fmt.Sprintf(`{"pictureId":%d}`, table), "picture_retired", "That table picture is no longer available.")
	refused("/api/emojis/buy", fmt.Sprintf(`{"emojiId":%d}`, emoji), "emoji_retired", "That emoji is no longer available.")
	var hammers int64
	if err := database.Pool.QueryRow(ctx, `SELECT hammer FROM users WHERE id = $1`, strangerID).Scan(&hammers); err != nil || hammers != 100 {
		t.Errorf("the refused buyer's hammers = %d %v, want 100", hammers, err)
	}

	// The owner asking again is the idempotent success it always was; and they
	// keep wearing, laying and wearing again what they have.
	if res := postJSON(ts.URL, owner, "/api/profile/picture/buy", map[string]any{"pictureId": picture}); res.err != nil ||
		res.status != http.StatusOK || res.body["charged"] != false {
		t.Errorf("the owner's buy of their own unlisted picture: %d %v %v", res.status, res.body, res.err)
	}
	status, body := shelfGet(t, ts.URL, "/api/auth/me", owner)
	var me struct {
		User db.User `json:"user"`
	}
	if err := json.Unmarshal(body, &me); status != http.StatusOK || err != nil {
		t.Fatalf("GET /api/auth/me: %d %s %v", status, body, err)
	}
	if me.User.ActivePictureID == nil || *me.User.ActivePictureID != picture || me.User.TablePicture == nil || me.User.TablePicture.ID != table {
		t.Errorf("the owner's account after unlisting: picture %v, table %+v", me.User.ActivePictureID, me.User.TablePicture)
	}
	if res := postJSON(ts.URL, owner, "/api/profile/avatar", map[string]any{"avatar": nil}); res.err != nil || res.status != http.StatusOK {
		t.Fatalf("taking it off: %d %v %v", res.status, res.body, res.err)
	}
	if res := postJSON(ts.URL, owner, "/api/profile/avatar", map[string]any{"avatar": picture}); res.err != nil || res.status != http.StatusOK {
		t.Errorf("wearing an owned unlisted picture again: %d %v %v", res.status, res.body, res.err)
	}

	// Back on the shelves: shown and sold again.
	exec(`UPDATE profile_pictures SET is_listed = TRUE WHERE id = $1`, picture)
	exec(`UPDATE badges SET is_listed = TRUE WHERE code = $1`, badge)
	if s := shelvesOf(t, ts.URL, ""); !hasKey(s.profiles, picture) || hasKey(s.tables, table) {
		t.Errorf("relisting the picture alone: picture %t, table %t", hasKey(s.profiles, picture), hasKey(s.tables, table))
	}
	if !badgeCodes(t, ts.URL)[badge] {
		t.Errorf("relisted, /api/levels does not list %s", badge)
	}
	if res := postJSON(ts.URL, stranger, "/api/profile/picture/buy", map[string]any{"pictureId": picture}); res.err != nil ||
		res.status != http.StatusOK || res.body["charged"] != true {
		t.Errorf("a buy once relisted: %d %v %v", res.status, res.body, res.err)
	}
}

func hasKey(m map[int64]bool, id int64) bool {
	_, ok := m[id]
	return ok
}
