package auth

import (
	"context"
	"net/http"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// fakeTableCatalogue stands in for table_pictures: a free pair, one row in
// each wallet, and a retired one that is still a valid id.
var fakeTableCatalogue = map[int64]db.TablePicture{
	1: {ID: 1, Name: "Classic Baize", DayURL: "/tables/classic-baize-day.svg", NightURL: "/tables/classic-baize-night.svg",
		AssetFormat: "SVG", Currency: "COIN", Type: db.PictureFree, SortOrder: 10},
	2: {ID: 2, Name: "Royal Sapphire", DayURL: "/tables/royal-sapphire-day.svg", NightURL: "/tables/royal-sapphire-night.svg",
		AssetFormat: "SVG", Currency: "COIN", Type: db.PicturePremium, Cost: 50000, DurationDays: 7, SortOrder: 20},
	3: {ID: 3, Name: "Emerald Lattice", DayURL: "/tables/emerald-lattice-day.svg", NightURL: "/tables/emerald-lattice-night.svg",
		AssetFormat: "SVG", Currency: "HAMMER", Type: db.PicturePremium, Cost: 20, DurationDays: 20, SortOrder: 30},
	4: {ID: 4, Name: "Royal Purple", DayURL: "/tables/royal-purple-day.svg", NightURL: "/tables/royal-purple-night.svg",
		AssetFormat: "SVG", Currency: "DIAMOND", Type: db.PicturePremium, Cost: 5, DurationDays: 100, SortOrder: 40},
	9: {ID: 9, Name: "Old Felt", DayURL: "/tables/old-felt-day.svg", NightURL: "/tables/old-felt-night.svg",
		AssetFormat: "SVG", Currency: "COIN", Type: db.PicturePremium, Cost: 100, DurationDays: 30, SortOrder: 90},
}

// fakeTablePictures is the TablePictureStore the harness wires in: the
// catalogue above, an ownership set, the choice per player, and the wallet it
// debits.
type fakeTablePictures struct {
	store    *fakeStore
	owned    map[string]map[int64]bool
	retired  map[int64]bool
	failWith error
}

func newFakeTablePictures(store *fakeStore) *fakeTablePictures {
	return &fakeTablePictures{store: store, owned: map[string]map[int64]bool{}, retired: map[int64]bool{9: true}}
}

func (f *fakeTablePictures) has(userID string, id int64) bool {
	return fakeTableCatalogue[id].Type == db.PictureFree || f.owned[userID][id]
}

func (f *fakeTablePictures) List(_ context.Context, userID string) ([]db.TablePicture, error) {
	if f.failWith != nil {
		return nil, f.failWith
	}
	out := []db.TablePicture{}
	for _, id := range []int64{1, 2, 3, 4, 9} {
		if f.retired[id] {
			continue
		}
		pic := fakeTableCatalogue[id]
		pic.Owned = f.has(userID, id)
		out = append(out, pic)
	}
	return out, nil
}

func (f *fakeTablePictures) Find(_ context.Context, userID string, id int64) (db.TablePicture, bool, error) {
	if f.failWith != nil {
		return db.TablePicture{}, false, f.failWith
	}
	pic, ok := fakeTableCatalogue[id]
	if !ok {
		return db.TablePicture{}, false, db.ErrTablePictureUnknown
	}
	pic.Owned = f.has(userID, id)
	return pic, !f.retired[id], nil
}

func (f *fakeTablePictures) Buy(_ context.Context, userID string, id int64) (*db.TablePicturePurchase, error) {
	if f.failWith != nil {
		return nil, f.failWith
	}
	pic, ok := fakeTableCatalogue[id]
	if !ok {
		return nil, db.ErrTablePictureUnknown
	}
	switch {
	case f.retired[id]:
		return nil, db.ErrPictureInactive
	case pic.Free():
		return nil, db.ErrPictureFree
	}
	user := f.store.users[userID]
	if f.owned[userID][id] {
		pic.Owned = true
		return &db.TablePicturePurchase{Picture: pic, Charged: false, Balance: user.Chips, User: user}, nil
	}
	switch pic.Currency {
	case db.PictureCurrencyDiamond:
		if int64(user.Diamond) < pic.Cost {
			return nil, db.ErrPictureDiamonds
		}
		user.Diamond -= int(pic.Cost)
	case db.PictureCurrencyHammer:
		if int64(user.Hammer) < pic.Cost {
			return nil, &db.PictureHammerShortage{Cost: pic.Cost}
		}
		user.Hammer -= int(pic.Cost)
	default:
		if user.Chips < pic.Cost {
			return nil, db.ErrPictureChips
		}
		user.Chips -= pic.Cost
	}
	if f.owned[userID] == nil {
		f.owned[userID] = map[int64]bool{}
	}
	f.owned[userID][id] = true
	pic.Owned = true
	return &db.TablePicturePurchase{Picture: pic, Charged: true, Spent: pic.Cost, Balance: user.Chips, User: user}, nil
}

func (f *fakeTablePictures) BuyAtTable(ctx context.Context, userID string, id int64) (*db.TablePicturePurchase, error) {
	if f.failWith != nil {
		return nil, f.failWith
	}
	pic, ok := fakeTableCatalogue[id]
	if ok && !f.retired[id] && !pic.Free() && !f.owned[userID][id] && pic.PaidInChips() {
		return nil, db.ErrPictureAtTable
	}
	return f.Buy(ctx, userID, id)
}

func (f *fakeTablePictures) Use(_ context.Context, userID string, id *int64) (*db.User, error) {
	if f.failWith != nil {
		return nil, f.failWith
	}
	u := f.store.users[userID]
	if id == nil {
		u.TablePicture = nil
	} else {
		pic := fakeTableCatalogue[*id]
		u.TablePicture = &db.LaidTablePicture{ID: pic.ID, DayURL: pic.DayURL, NightURL: pic.NightURL, AssetFormat: pic.AssetFormat}
	}
	copied := *u
	return &copied, nil
}

func (f *fakeTablePictures) ExpireLapsed(_ context.Context, userID string) (bool, error) {
	if f.failWith != nil {
		return false, f.failWith
	}
	u := f.store.users[userID]
	if u == nil || u.TablePicture == nil {
		return false, nil
	}
	laid := fakeTableCatalogue[u.TablePicture.ID]
	if laid.Free() || f.has(userID, laid.ID) {
		return false, nil
	}
	u.TablePicture = nil
	return true, nil
}

// GET /api/table-pictures lists the catalogue in order with its two URLs per
// row, owned resolved per viewer, and the token optional: without one the free
// row alone is owned; with one, what that player has bought as well.
func TestTablePicturesListsTheCatalogueWithBothURLs(t *testing.T) {
	h := newHarness(t)
	res := h.do(http.MethodGet, "/api/table-pictures", nil)
	if res.status != 200 {
		t.Fatalf("%d %s", res.status, res.raw)
	}
	pictures, _ := res.body["tablePictures"].([]any)
	if len(pictures) != 4 {
		t.Fatalf("listed %d rows, want the 4 active ones: %s", len(pictures), res.raw)
	}
	first, _ := pictures[0].(map[string]any)
	if first["name"] != "Classic Baize" || first["dayUrl"] != "/tables/classic-baize-day.svg" ||
		first["nightUrl"] != "/tables/classic-baize-night.svg" || first["assetFormat"] != "SVG" || first["owned"] != true {
		t.Errorf("the free row: %v", first)
	}
	for _, key := range []string{"id", "name", "dayUrl", "nightUrl", "assetFormat", "currency", "type", "cost", "durationDays", "durationHours", "sortOrder", "owned", "expiresAt"} {
		if _, ok := first[key]; !ok {
			t.Errorf("a row lacks %q: %v", key, first)
		}
	}
	second, _ := pictures[1].(map[string]any)
	if second["owned"] != false || second["cost"] != float64(50000) || second["currency"] != "COIN" {
		t.Errorf("the chip-priced row, anonymous: %v", second)
	}

	token, user := h.login("device-table-list-01", "Lister")
	if user["tablePicture"] != nil {
		t.Errorf("a new account's tablePicture = %v, want null", user["tablePicture"])
	}
	if res := h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 2}, bearer(token)...); res.status != 200 {
		t.Fatalf("buy: %d %s", res.status, res.raw)
	}
	res = h.do(http.MethodGet, "/api/table-pictures", nil, bearer(token)...)
	pictures, _ = res.body["tablePictures"].([]any)
	second, _ = pictures[1].(map[string]any)
	if second["owned"] != true {
		t.Errorf("after buying, the row still reads unowned: %v", second)
	}
	// A bad token is ignored, not refused.
	if res := h.do(http.MethodGet, "/api/table-pictures", nil, "Authorization", "Bearer nonsense"); res.status != 200 {
		t.Errorf("a bad token on the listing: %d %s", res.status, res.raw)
	}
}

// POST /api/table-pictures/use lays a picture: a free one at once, a bought
// one after its purchase, and null takes it off. Its refusals: an id not in
// the catalogue (400 unknown_table_picture, a non-number included), a retired
// one (400 picture_retired), a premium one not bought (403 picture_locked).
// The user in the answer carries the pair as tablePicture.
func TestUseTablePictureLaysAndTakesOffWithTheProfileRules(t *testing.T) {
	h := newHarness(t)
	token, _ := h.login("device-table-use-01", "Layer")
	auth := bearer(token)

	res := h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": 1}, auth...)
	if res.status != 200 {
		t.Fatalf("laying the free picture: %d %s", res.status, res.raw)
	}
	user, _ := res.body["user"].(map[string]any)
	laid, _ := user["tablePicture"].(map[string]any)
	if laid["id"] != float64(1) || laid["dayUrl"] != "/tables/classic-baize-day.svg" || laid["nightUrl"] != "/tables/classic-baize-night.svg" || laid["assetFormat"] != "SVG" {
		t.Errorf("tablePicture after laying = %v", user["tablePicture"])
	}
	if len(res.body) != 1 {
		t.Errorf("the answer is %v, want exactly {user}", res.body)
	}

	// The id may arrive as text, like an avatar's.
	if res := h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": "1"}, auth...); res.status != 200 {
		t.Errorf("a text id: %d %s", res.status, res.raw)
	}

	expectError(t, h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": 2}, auth...), 403, CodePictureLocked)
	expectError(t, h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": 9}, auth...), 400, CodePictureRetired)
	expectError(t, h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": 77}, auth...), 400, CodeUnknownTablePicture)
	expectError(t, h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": "bear.svg"}, auth...), 400, CodeUnknownTablePicture)
	expectError(t, h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": 1}), 401, CodeMissingToken)

	// Bought, then laid; and the seat is never told — the felt is the
	// player's own.
	if res := h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 2}, auth...); res.status != 200 {
		t.Fatalf("buy: %d %s", res.status, res.raw)
	}
	res = h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": 2}, auth...)
	if res.status != 200 {
		t.Fatalf("laying the bought picture: %d %s", res.status, res.raw)
	}
	if len(h.worn) != 0 {
		t.Errorf("laying a table picture told the seat about a face: %v", h.worn)
	}

	// Off.
	res = h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": nil}, auth...)
	user, _ = res.body["user"].(map[string]any)
	if res.status != 200 || user["tablePicture"] != nil {
		t.Errorf("taking the picture off: %d %s", res.status, res.raw)
	}
	res = h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{}, auth...)
	if res.status != 200 {
		t.Errorf("an empty body takes it off too: %d %s", res.status, res.raw)
	}
}

// POST /api/table-pictures/buy answers {user, picture, charged, spent} and
// applies the profile pictures' money rules: chips in the lobby only (409
// seated at a table, where hammers and diamonds still sell), every shortage
// 409 picture_chips naming its wallet, free/retired/unknown refused before
// any wallet is read, and buying twice charging once.
func TestBuyTablePictureFollowsTheProfilePictureMoneyRules(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-table-buy-01", "Buyer")
	auth := bearer(token)
	id := user["id"].(string)

	res := h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 2}, auth...)
	if res.status != 200 || res.body["charged"] != true || res.body["spent"] != float64(50000) {
		t.Fatalf("a lobby chip buy: %d %s", res.status, res.raw)
	}
	if len(res.body) != 4 {
		t.Errorf("the answer is %v, want exactly user, picture, charged and spent", res.body)
	}
	picture, _ := res.body["picture"].(map[string]any)
	if picture["owned"] != true || picture["dayUrl"] != "/tables/royal-sapphire-day.svg" {
		t.Errorf("the answer's picture: %v", picture)
	}
	answered, _ := res.body["user"].(map[string]any)
	if answered["chips"] != float64(200000-50000) {
		t.Errorf("the answer's user: %v", answered)
	}
	res = h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 2}, auth...)
	if res.status != 200 || res.body["charged"] != false || res.body["spent"] != float64(0) {
		t.Errorf("buying it again: %d %s", res.status, res.raw)
	}

	expectError(t, h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 1}, auth...), 400, CodePictureFree)
	expectError(t, h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 9}, auth...), 400, CodePictureRetired)
	expectError(t, h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 77}, auth...), 400, CodeUnknownTablePicture)
	expectError(t, h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{}, auth...), 400, CodeUnknownTablePicture)

	// Short of hammers, then of diamonds: the same code, the wallet in the text.
	h.store.users[id].Hammer = 3
	short := h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 3}, auth...)
	expectError(t, short, 409, CodePictureChips)
	if short.body["message"] != "You need 20 hammers to unlock this table picture." {
		t.Errorf("the hammer shortage says %q", short.body["message"])
	}
	h.store.users[id].Diamond = 0
	short = h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 4}, auth...)
	expectError(t, short, 409, CodePictureChips)
	if short.body["message"] != MsgTablePictureDiamonds {
		t.Errorf("the diamond shortage says %q", short.body["message"])
	}

	// Seated: chips refused, hammers sold.
	h.store.users[id].Hammer = 20
	h.seated[id] = true
	seatedChips := h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 9}, auth...)
	// A retired row is refused as retired before the seat is consulted…
	expectError(t, seatedChips, 400, CodePictureRetired)
	delete(h.tables.retired, 9)
	seatedChips = h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 9}, auth...)
	expectError(t, seatedChips, 409, CodeSeated)
	if seatedChips.body["message"] != MsgSeatedTablePicture {
		t.Errorf("a seated chip buy says %q", seatedChips.body["message"])
	}
	res = h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 3}, auth...)
	if res.status != 200 || res.body["charged"] != true || res.body["spent"] != float64(20) {
		t.Errorf("a seated hammer buy: %d %s", res.status, res.raw)
	}
	if h.store.users[id].Hammer != 0 {
		t.Errorf("hammers after the seated buy = %d, want 0", h.store.users[id].Hammer)
	}
	// And a seated player may lay what they bought.
	if res := h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": 3}, auth...); res.status != 200 {
		t.Errorf("laying while seated: %d %s", res.status, res.raw)
	}
}

// A laid table picture whose rental has run out is taken off by the sweep on
// /api/auth/me — how a saved session comes back — and by the listing, and the
// account comes back with tablePicture null.
func TestALapsedTablePictureIsTakenOffOnMeAndOnTheListing(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-table-lapse-01", "Lapser")
	auth := bearer(token)
	id := user["id"].(string)

	if res := h.do(http.MethodPost, "/api/table-pictures/buy", map[string]any{"pictureId": 2}, auth...); res.status != 200 {
		t.Fatal(res.raw)
	}
	if res := h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": 2}, auth...); res.status != 200 {
		t.Fatal(res.raw)
	}
	res := h.do(http.MethodGet, "/api/auth/me", nil, auth...)
	if me, _ := res.body["user"].(map[string]any); me["tablePicture"] == nil {
		t.Fatalf("/me lost a running rental: %s", res.raw)
	}

	// Laying told the seat.
	if n := len(h.laid); n == 0 || h.laid[n-1].userID != id || h.laid[n-1].pic == nil || h.laid[n-1].pic.ID != 2 {
		t.Fatalf("laying did not reach the seat: %+v", h.laid)
	}
	told := len(h.laid)

	// The rental lapses. The sweep takes it off the account AND tells the
	// seat (23 Sep 2026): the whole table shows a laid picture, so a seated
	// player's lapsed cloth must leave every viewer's felt at once, not when
	// they next leave or lay another.
	delete(h.tables.owned[id], 2)
	res = h.do(http.MethodGet, "/api/auth/me", nil, auth...)
	if me, _ := res.body["user"].(map[string]any); res.status != 200 || me["tablePicture"] != nil {
		t.Fatalf("/me kept a lapsed table picture: %d %s", res.status, res.raw)
	}
	if len(h.laid) != told+1 || h.laid[told].userID != id || h.laid[told].pic != nil {
		t.Fatalf("the sweep on /me did not tell the seat the cloth came off: %+v", h.laid[told:])
	}
	told = len(h.laid)

	// The listing sweeps too.
	if res := h.do(http.MethodPost, "/api/table-pictures/use", map[string]any{"pictureId": 1}, auth...); res.status != 200 {
		t.Fatal(res.raw)
	}
	h.store.users[id].TablePicture = &db.LaidTablePicture{ID: 2, DayURL: "x", NightURL: "y"}
	if res := h.do(http.MethodGet, "/api/table-pictures", nil, auth...); res.status != 200 {
		t.Fatal(res.raw)
	}
	if h.store.users[id].TablePicture != nil {
		t.Error("listing the catalogue left a lapsed table picture laid")
	}
	if len(h.laid) != told+2 || h.laid[told+1].userID != id || h.laid[told+1].pic != nil {
		t.Errorf("the sweep on the listing did not tell the seat the cloth came off: %+v", h.laid[told:])
	}
}
