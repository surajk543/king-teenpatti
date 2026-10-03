package auth

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// fakeCardCatalogue stands in for cards_background: a free card back, one in
// each wallet — the hammer one priced as the seed prices its first eight, 5
// for 10 days — and a retired one that is still a valid id.
var fakeCardCatalogue = map[int64]db.CardBackground{
	1: {ID: 1, Name: "Plain", URL: "https://r2.example/king-teenpatti/cards/Plain.jpg", AssetFormat: "IMAGE",
		Currency: "COIN", Type: db.PictureFree, SortOrder: 5},
	2: {ID: 2, Name: "Brutal Demon", URL: "https://r2.example/king-teenpatti/cards/Brutal%20Demon.jpg", AssetFormat: "IMAGE",
		Crop: &game.CardCrop{X: 0.2035, Y: 0.0805, W: 0.6007, H: 0.841}, Currency: "HAMMER", Type: db.PicturePremium, Cost: 5,
		DurationDays: 10, SortOrder: 10},
	3: {ID: 3, Name: "Gold Leaf", URL: "https://r2.example/king-teenpatti/cards/Gold%20Leaf.jpg", AssetFormat: "IMAGE",
		Currency: "COIN", Type: db.PicturePremium, Cost: 50000, DurationDays: 7, SortOrder: 20},
	4: {ID: 4, Name: "Gem Inlay", URL: "https://r2.example/king-teenpatti/cards/Gem%20Inlay.jpg", AssetFormat: "IMAGE",
		Currency: "DIAMOND", Type: db.PicturePremium, Cost: 3, SortOrder: 30},
	9: {ID: 9, Name: "Old Back", URL: "https://r2.example/king-teenpatti/cards/Old%20Back.jpg", AssetFormat: "IMAGE",
		Currency: "HAMMER", Type: db.PicturePremium, Cost: 5, DurationDays: 10, SortOrder: 90},
}

// fakeCardBackgrounds is the CardBackgroundStore the harness wires in: the
// catalogue above, an ownership set, the choice on the fake account, and the
// wallet it debits.
type fakeCardBackgrounds struct {
	store    *fakeStore
	owned    map[string]map[int64]bool
	retired  map[int64]bool
	failWith error
}

func newFakeCardBackgrounds(store *fakeStore) *fakeCardBackgrounds {
	return &fakeCardBackgrounds{store: store, owned: map[string]map[int64]bool{}, retired: map[int64]bool{9: true}}
}

func (f *fakeCardBackgrounds) has(userID string, id int64) bool {
	return fakeCardCatalogue[id].Type == db.PictureFree || f.owned[userID][id]
}

func (f *fakeCardBackgrounds) List(_ context.Context, userID string) ([]db.CardBackground, error) {
	if f.failWith != nil {
		return nil, f.failWith
	}
	out := []db.CardBackground{}
	for _, id := range []int64{1, 2, 3, 4, 9} {
		if f.retired[id] {
			continue
		}
		cb := fakeCardCatalogue[id]
		cb.Owned = f.has(userID, id)
		out = append(out, cb)
	}
	return out, nil
}

func (f *fakeCardBackgrounds) Find(_ context.Context, userID string, id int64) (db.CardBackground, bool, error) {
	if f.failWith != nil {
		return db.CardBackground{}, false, f.failWith
	}
	cb, ok := fakeCardCatalogue[id]
	if !ok {
		return db.CardBackground{}, false, db.ErrCardBackgroundUnknown
	}
	cb.Owned = f.has(userID, id)
	return cb, !f.retired[id], nil
}

func (f *fakeCardBackgrounds) Buy(_ context.Context, userID string, id int64) (*db.CardBackgroundPurchase, error) {
	if f.failWith != nil {
		return nil, f.failWith
	}
	cb, ok := fakeCardCatalogue[id]
	if !ok {
		return nil, db.ErrCardBackgroundUnknown
	}
	switch {
	case f.retired[id]:
		return nil, db.ErrPictureInactive
	case cb.Free():
		return nil, db.ErrPictureFree
	}
	user := f.store.users[userID]
	if f.owned[userID][id] {
		cb.Owned = true
		return &db.CardBackgroundPurchase{CardBackground: cb, Charged: false, Balance: user.Chips, User: user}, nil
	}
	switch cb.Currency {
	case db.PictureCurrencyDiamond:
		if int64(user.Diamond) < cb.Cost {
			return nil, db.ErrPictureDiamonds
		}
		user.Diamond -= int(cb.Cost)
	case db.PictureCurrencyHammer:
		if int64(user.Hammer) < cb.Cost {
			return nil, &db.PictureHammerShortage{Cost: cb.Cost}
		}
		user.Hammer -= int(cb.Cost)
	default:
		if user.Chips < cb.Cost {
			return nil, db.ErrPictureChips
		}
		user.Chips -= cb.Cost
	}
	if f.owned[userID] == nil {
		f.owned[userID] = map[int64]bool{}
	}
	f.owned[userID][id] = true
	cb.Owned = true
	return &db.CardBackgroundPurchase{CardBackground: cb, Charged: true, Spent: cb.Cost, Balance: user.Chips, User: user}, nil
}

func (f *fakeCardBackgrounds) BuyAtTable(ctx context.Context, userID string, id int64) (*db.CardBackgroundPurchase, error) {
	if f.failWith != nil {
		return nil, f.failWith
	}
	cb, ok := fakeCardCatalogue[id]
	if ok && !f.retired[id] && !cb.Free() && !f.owned[userID][id] && cb.PaidInChips() {
		return nil, db.ErrPictureAtTable
	}
	return f.Buy(ctx, userID, id)
}

func (f *fakeCardBackgrounds) Use(_ context.Context, userID string, id *int64) (*db.User, error) {
	if f.failWith != nil {
		return nil, f.failWith
	}
	u := f.store.users[userID]
	if id == nil {
		u.CardBackground = nil
	} else {
		cb := fakeCardCatalogue[*id]
		u.CardBackground = &game.CardBackground{ID: cb.ID, URL: cb.URL, Format: cb.AssetFormat, Crop: cb.Crop}
	}
	copied := *u
	return &copied, nil
}

func (f *fakeCardBackgrounds) ExpireLapsed(_ context.Context, userID string) (bool, error) {
	if f.failWith != nil {
		return false, f.failWith
	}
	u := f.store.users[userID]
	if u == nil || u.CardBackground == nil || f.has(userID, u.CardBackground.ID) {
		return false, nil
	}
	u.CardBackground = nil
	return true, nil
}

// GET /api/card-backgrounds lists the catalogue in order, each row with its
// one url and its crop (absent where it has none), owned resolved per viewer
// and the token optional: without one the free row alone is owned; with one,
// what that player has bought as well; a bad one is ignored.
func TestCardBackgroundsListsTheCatalogueWithItsCropAndAnOptionalToken(t *testing.T) {
	h := newHarness(t)
	res := h.do(http.MethodGet, "/api/card-backgrounds", nil)
	if res.status != 200 || len(res.body) != 1 {
		t.Fatalf("%d %s", res.status, res.raw)
	}
	backs, _ := res.body["cardBackgrounds"].([]any)
	if len(backs) != 4 {
		t.Fatalf("listed %d rows, want the 4 active ones: %s", len(backs), res.raw)
	}
	plain, _ := backs[0].(map[string]any)
	if plain["name"] != "Plain" || plain["owned"] != true || plain["assetFormat"] != "IMAGE" {
		t.Errorf("the free row: %v", plain)
	}
	if _, ok := plain["crop"]; ok {
		t.Errorf("a row with no crop carries one: %v", plain)
	}
	brutal, _ := backs[1].(map[string]any)
	for _, key := range []string{"id", "name", "url", "assetFormat", "crop", "currency", "type", "cost", "durationDays", "durationHours", "sortOrder", "owned", "expiresAt"} {
		if _, ok := brutal[key]; !ok {
			t.Errorf("a row lacks %q: %v", key, brutal)
		}
	}
	crop, _ := brutal["crop"].(map[string]any)
	if brutal["owned"] != false || brutal["cost"] != float64(5) || brutal["currency"] != "HAMMER" || crop["x"] != 0.2035 || crop["h"] != 0.841 {
		t.Errorf("the hammer row, anonymous: %v", brutal)
	}

	token, user := h.login("device-card-list-01", "Lister")
	if v, ok := user["cardBackground"]; !ok || v != nil {
		t.Errorf("a new account's cardBackground = %v (present %v), want null", v, ok)
	}
	h.store.users[user["id"].(string)].Hammer = 5
	if res := h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 2}, bearer(token)...); res.status != 200 {
		t.Fatalf("buy: %d %s", res.status, res.raw)
	}
	res = h.do(http.MethodGet, "/api/card-backgrounds", nil, bearer(token)...)
	backs, _ = res.body["cardBackgrounds"].([]any)
	if brutal, _ = backs[1].(map[string]any); brutal["owned"] != true {
		t.Errorf("after buying, the row still reads unowned: %v", brutal)
	}
	if res := h.do(http.MethodGet, "/api/card-backgrounds", nil, "Authorization", "Bearer nonsense"); res.status != 200 {
		t.Errorf("a bad token on the listing: %d %s", res.status, res.raw)
	}
}

// POST /api/card-backgrounds/use chooses a card back — a free one at once, a
// bought one after its purchase — and null (or nothing) takes it off; each
// choice goes onto the player's seat (Deps.CardBackgroundChosen), the card
// back itself or nil. Its refusals: an id not in the catalogue (400
// unknown_card_background, a non-number included), a retired one (400
// picture_retired), a premium one not bought (403 picture_locked), no token
// (401). The answer is exactly {user}, carrying cardBackground.
func TestUseCardBackgroundChoosesTellsTheSeatAndTakesItOff(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-card-use-01", "Chooser")
	auth := bearer(token)
	id := user["id"].(string)
	h.store.users[id].Hammer = 5

	res := h.do(http.MethodPost, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": 1}, auth...)
	if res.status != 200 || len(res.body) != 1 {
		t.Fatalf("choosing the free card back: %d %s", res.status, res.raw)
	}
	answered, _ := res.body["user"].(map[string]any)
	if back, _ := answered["cardBackground"].(map[string]any); back["id"] != float64(1) || back["url"] != fakeCardCatalogue[1].URL || back["assetFormat"] != "IMAGE" {
		t.Errorf("cardBackground after choosing = %v", answered["cardBackground"])
	}
	if n := len(h.chosen); n != 1 || h.chosen[0].userID != id || h.chosen[0].cb == nil || h.chosen[0].cb.ID != 1 {
		t.Fatalf("the choice did not reach the seat: %+v", h.chosen)
	}
	// The id may arrive as text.
	if res := h.do(http.MethodPost, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": "1"}, auth...); res.status != 200 {
		t.Errorf("a text id: %d %s", res.status, res.raw)
	}

	for name, c := range map[string]struct {
		body   any
		status int
		code   string
		msg    string
	}{
		"not bought":    {map[string]any{"cardBackgroundId": 2}, 403, CodePictureLocked, MsgCardBackgroundLocked},
		"retired":       {map[string]any{"cardBackgroundId": 9}, 400, CodePictureRetired, MsgCardBackgroundRetired},
		"unknown":       {map[string]any{"cardBackgroundId": 77}, 400, CodeUnknownCardBackground, MsgUnknownCardBackground},
		"not a number":  {map[string]any{"cardBackgroundId": "brutal"}, 400, CodeUnknownCardBackground, MsgUnknownCardBackground},
		"not positive":  {map[string]any{"cardBackgroundId": -2}, 400, CodeUnknownCardBackground, MsgUnknownCardBackground},
		"a JSON object": {map[string]any{"cardBackgroundId": map[string]any{"id": 2}}, 400, CodeUnknownCardBackground, MsgUnknownCardBackground},
	} {
		got := h.do(http.MethodPost, "/api/card-backgrounds/use", c.body, auth...)
		expectError(t, got, c.status, c.code)
		if got.body["message"] != c.msg {
			t.Errorf("%s says %q, want %q", name, got.body["message"], c.msg)
		}
	}
	expectError(t, h.do(http.MethodPost, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": 1}), 401, CodeMissingToken)
	told := len(h.chosen)

	// Bought, then chosen: the seat gets the card back with its crop.
	if res := h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 2}, auth...); res.status != 200 {
		t.Fatalf("buy: %d %s", res.status, res.raw)
	}
	if res := h.do(http.MethodPost, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": 2}, auth...); res.status != 200 {
		t.Fatalf("choosing the bought card back: %d %s", res.status, res.raw)
	}
	if len(h.chosen) != told+1 || h.chosen[told].cb == nil || h.chosen[told].cb.ID != 2 || h.chosen[told].cb.Crop == nil {
		t.Fatalf("the bought card back did not reach the seat: %+v", h.chosen[told:])
	}
	// Off: null, and an empty body, each tell the seat nil.
	for _, body := range []any{map[string]any{"cardBackgroundId": nil}, map[string]any{}} {
		res := h.do(http.MethodPost, "/api/card-backgrounds/use", body, auth...)
		answered, _ := res.body["user"].(map[string]any)
		if v, ok := answered["cardBackground"]; res.status != 200 || !ok || v != nil {
			t.Errorf("taking it off with %v: %d %s", body, res.status, res.raw)
		}
		if last := h.chosen[len(h.chosen)-1]; last.userID != id || last.cb != nil {
			t.Errorf("taking it off told the seat %+v", last)
		}
	}
	if len(h.worn) != 0 || len(h.laid) != 0 {
		t.Errorf("a card back told the seat of a face or a cloth: %v %v", h.worn, h.laid)
	}
}

// POST /api/card-backgrounds/buy answers exactly {user, cardBackground,
// charged, spent} and applies the pictures' money rules: hammers and diamonds
// at a table too, chips in the lobby only (409 seated at a table), every
// shortage 409 picture_chips naming its wallet — the hammer one its price —
// free, retired and unknown refused, and buying twice charging once. Buying
// does not choose it.
func TestBuyCardBackgroundFollowsThePictureMoneyRules(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-card-buy-01", "Buyer")
	auth := bearer(token)
	id := user["id"].(string)
	h.store.users[id].Hammer = 12

	res := h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 2}, auth...)
	if res.status != 200 || res.body["charged"] != true || res.body["spent"] != float64(5) || len(res.body) != 4 {
		t.Fatalf("a hammer buy: %d %s", res.status, res.raw)
	}
	back, _ := res.body["cardBackground"].(map[string]any)
	answered, _ := res.body["user"].(map[string]any)
	if back["owned"] != true || back["url"] != fakeCardCatalogue[2].URL || answered["hammer"] != float64(7) || answered["cardBackground"] != nil {
		t.Errorf("the answer: %s", res.raw)
	}
	if len(h.chosen) != 0 {
		t.Errorf("buying told the seat: %+v", h.chosen)
	}
	res = h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": "2"}, auth...)
	if res.status != 200 || res.body["charged"] != false || res.body["spent"] != float64(0) || h.store.users[id].Hammer != 7 {
		t.Errorf("buying it again: %d %s", res.status, res.raw)
	}

	expectError(t, h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 1}, auth...), 400, CodePictureFree)
	expectError(t, h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 9}, auth...), 400, CodePictureRetired)
	expectError(t, h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 77}, auth...), 400, CodeUnknownCardBackground)
	expectError(t, h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{}, auth...), 400, CodeUnknownCardBackground)
	expectError(t, h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 2}), 401, CodeMissingToken)

	// Short of each wallet: the same code, the wallet in the text.
	delete(h.cards.owned[id], 2)
	h.store.users[id].Hammer = 4
	short := h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 2}, auth...)
	expectError(t, short, 409, CodePictureChips)
	if short.body["message"] != "You need 5 hammers to unlock this card back." {
		t.Errorf("the hammer shortage says %q", short.body["message"])
	}
	h.store.users[id].Diamond = 0
	short = h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 4}, auth...)
	expectError(t, short, 409, CodePictureChips)
	if short.body["message"] != MsgCardBackgroundDiamonds {
		t.Errorf("the diamond shortage says %q", short.body["message"])
	}
	h.store.users[id].Chips = 10
	short = h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 3}, auth...)
	expectError(t, short, 409, CodePictureChips)
	if short.body["message"] != MsgCardBackgroundChips {
		t.Errorf("the chip shortage says %q", short.body["message"])
	}

	// Seated: chips refused, hammers sold.
	h.store.users[id].Hammer, h.store.users[id].Chips = 5, 200000
	h.seated[id] = true
	seated := h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 3}, auth...)
	expectError(t, seated, 409, CodeSeated)
	if seated.body["message"] != "You can only buy a chip-priced card back in the lobby." {
		t.Errorf("a seated chip buy says %q", seated.body["message"])
	}
	res = h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 2}, auth...)
	if res.status != 200 || res.body["charged"] != true || h.store.users[id].Hammer != 0 || h.store.users[id].Chips != 200000 {
		t.Errorf("a seated hammer buy: %d %s", res.status, res.raw)
	}
	if CardBackgroundHammersMessage(1) != "You need 1 hammer to unlock this card back." {
		t.Errorf("the singular says %q", CardBackgroundHammersMessage(1))
	}
}

// A chosen card back whose rental has run out is taken off by the sweep on
// /api/auth/me — how a saved session comes back — at login, and on the
// listing, and every time the seat is told nil, so the player's table stops
// showing it at once.
func TestALapsedCardBackIsTakenOffOnMeAtLoginAndOnTheListingAndTheSeatIsTold(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-card-lapse-01", "Lapser")
	auth := bearer(token)
	id := user["id"].(string)
	h.store.users[id].Hammer = 100

	lapse := func() int {
		t.Helper()
		if res := h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 2}, auth...); res.status != 200 {
			t.Fatal(string(res.raw))
		}
		if res := h.do(http.MethodPost, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": 2}, auth...); res.status != 200 {
			t.Fatal(string(res.raw))
		}
		delete(h.cards.owned[id], 2)
		return len(h.chosen)
	}
	toldNil := func(where string, before int) {
		t.Helper()
		if len(h.chosen) != before+1 || h.chosen[before].userID != id || h.chosen[before].cb != nil {
			t.Errorf("the sweep %s did not tell the seat the card back came off: %+v", where, h.chosen[before:])
		}
		if h.store.users[id].CardBackground != nil {
			t.Errorf("the sweep %s left the lapsed card back chosen", where)
		}
	}

	res := h.do(http.MethodGet, "/api/auth/me", nil, auth...)
	if me, _ := res.body["user"].(map[string]any); me["cardBackground"] != nil {
		t.Fatalf("/me with nothing chosen: %s", res.raw)
	}
	before := lapse()
	res = h.do(http.MethodGet, "/api/auth/me", nil, auth...)
	if me, _ := res.body["user"].(map[string]any); res.status != 200 || me["cardBackground"] != nil {
		t.Fatalf("/me kept a lapsed card back: %d %s", res.status, res.raw)
	}
	toldNil("on /me", before)

	before = lapse()
	if res := h.do(http.MethodGet, "/api/card-backgrounds", nil, auth...); res.status != 200 {
		t.Fatal(string(res.raw))
	}
	toldNil("on the listing", before)

	before = lapse()
	h.login("device-card-lapse-01", "Lapser")
	toldNil("at login", before)

	// A running rental is never swept.
	if res := h.do(http.MethodPost, "/api/card-backgrounds/buy", map[string]any{"cardBackgroundId": 2}, auth...); res.status != 200 {
		t.Fatal(string(res.raw))
	}
	if res := h.do(http.MethodPost, "/api/card-backgrounds/use", map[string]any{"cardBackgroundId": 2}, auth...); res.status != 200 {
		t.Fatal(string(res.raw))
	}
	told := len(h.chosen)
	h.do(http.MethodGet, "/api/auth/me", nil, auth...)
	if len(h.chosen) != told || h.store.users[id].CardBackground == nil {
		t.Errorf("a running rental was swept: %+v", h.chosen[told:])
	}
}

// A server with no card-back store (a test that wires none) lists an empty
// catalogue, never null, answers a buy or a use of an id unknown_card_background,
// and a use of null with the account as it is.
func TestWithNoCardBackStoreTheCatalogueIsEmptyAndAnIdIsUnknown(t *testing.T) {
	cfg := config.Defaults()
	cfg.AllowFakeProviders = true
	store := newFakeStore()
	tokens := NewTokens(cfg.JWT.Secret, cfg.JWT.ExpiresIn, time.Now)
	mux := http.NewServeMux()
	NewHandler(Deps{Config: cfg, Users: store, Pictures: newFakePictures(store), Tokens: tokens, Verifier: NewVerifier(cfg),
		Logger: slog.New(slog.NewJSONHandler(io.Discard, nil))}).Register(mux)
	call := func(method, path, token, body string) (int, string) {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec.Code, rec.Body.String()
	}
	if status, body := call(http.MethodGet, "/api/card-backgrounds", "", ""); status != 200 || body != `{"cardBackgrounds":[]}` {
		t.Fatalf("the listing with no store: %d %s", status, body)
	}
	user, _, _ := store.UpsertFromProfile(context.Background(), db.Profile{Provider: db.ProviderGuest, ProviderUserID: "no-store", DisplayName: "None"})
	token, err := tokens.Issue(user)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/api/card-backgrounds/buy", "/api/card-backgrounds/use"} {
		if status, body := call(http.MethodPost, path, token, `{"cardBackgroundId":2}`); status != 400 || !strings.Contains(body, `"error":"unknown_card_background"`) {
			t.Errorf("%s with no store: %d %s", path, status, body)
		}
	}
	if status, body := call(http.MethodPost, "/api/card-backgrounds/use", token, `{"cardBackgroundId":null}`); status != 200 ||
		!strings.Contains(body, `"cardBackground":null`) || !bytes.Contains([]byte(body), []byte(`"id":"`+user.ID+`"`)) {
		t.Errorf("a use of null with no store: %d %s", status, body)
	}
}
