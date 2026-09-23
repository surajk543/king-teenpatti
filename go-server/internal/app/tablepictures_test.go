package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
)

// tableCatalogue is GET /api/table-pictures as a signed-out client reads it.
func tableCatalogue(t *testing.T, baseURL string) []db.TablePicture {
	t.Helper()
	res, err := http.Get(baseURL + "/api/table-pictures")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/table-pictures: %d", res.StatusCode)
	}
	var body struct {
		TablePictures []db.TablePicture `json:"tablePictures"`
	}
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return body.TablePictures
}

// insertTablePicture adds one catalogue row pointing at a file the real public
// directory serves, and returns its id.
func insertTablePicture(t *testing.T, database *db.DB, name, currency, kind string, cost int64, days int) int64 {
	t.Helper()
	var id int64
	if err := database.Pool.QueryRow(context.Background(),
		`INSERT INTO table_pictures (name, day_asset_url, night_asset_url, asset_format, currency, type, cost, duration_days, sort_order, created_at, updated_at)
		 VALUES ($1, $2, $3, 'SVG', $4, $5, $6, $7, 900, 0, 0) RETURNING id`,
		name, "/profiles/bear.svg?"+strings.ToLower(name)+"-day", "/profiles/bear.svg?"+strings.ToLower(name)+"-night",
		currency, kind, cost, days).Scan(&id); err != nil {
		t.Fatalf("insert table picture %s: %v", name, err)
	}
	return id
}

// The table pictures over REST on the real wiring (owner, 15 Sep 2026): the
// catalogue is served — the seeded Drive row beside three rows of the test's
// own, whose server-relative files are really there under PUBLIC_DIR; a
// chip-priced table is bought in the lobby with a ledger row that reconciles
// and refused 409 seated at a table, where a hammer one sells and is laid; the
// laid pair rides on the account from /api/auth/me and session:ready.
func TestTablePicturesAreServedBoughtAndLaidOverREST(t *testing.T) {
	// The repository's own public directory rather than the harness's stub:
	// what this checks is that the files the rows point at are really there.
	a, database := newApp(t, func(cfg *config.Config) { cfg.PublicDir = filepath.Join("..", "..", "public") })
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	welcome := a.cfg.Game.WelcomeChips

	// The seed's own rows come first (the owner's Drive Lotties, however many
	// the seed holds today); this test's three are found by name.
	seeded := len(tableCatalogue(t, ts.URL))
	insertTablePicture(t, database, "Classic", db.PictureCurrencyCoin, db.PictureFree, 0, 0)
	insertTablePicture(t, database, "Sapphire", db.PictureCurrencyCoin, db.PicturePremium, 50000, 7)
	insertTablePicture(t, database, "Lattice", db.PictureCurrencyHammer, db.PicturePremium, 20, 20)
	catalogue := tableCatalogue(t, ts.URL)
	if len(catalogue) != seeded+3 {
		t.Fatalf("the catalogue lists %d table pictures, want the %d seeded rows and 3 of this test's", len(catalogue), seeded)
	}
	var free, coin, hammer db.TablePicture
	for _, p := range catalogue {
		switch {
		case p.Name == "Classic" && p.Type == db.PictureFree:
			free = p
		case p.Name == "Sapphire" && p.Type == db.PicturePremium && p.Currency == db.PictureCurrencyCoin:
			coin = p
		case p.Name == "Lattice" && p.Currency == db.PictureCurrencyHammer:
			hammer = p
		}
	}
	if free.ID == 0 || coin.ID == 0 || hammer.ID == 0 {
		t.Fatal("the catalogue lacks a free, a chip-priced or a hammer-priced table picture")
	}
	// Every file this server serves is really there — a row pointing at a
	// missing file is a blank table on every phone. A hosted row (the seeded
	// Drive Lottie) is not fetched here.
	for _, p := range catalogue {
		for _, path := range []string{p.DayURL, p.NightURL} {
			if strings.HasPrefix(path, "http") {
				continue
			}
			res, err := http.Get(ts.URL + path)
			if err != nil {
				t.Fatal(err)
			}
			res.Body.Close()
			if res.StatusCode != http.StatusOK || res.Header.Get("Content-Type") != "image/svg+xml" {
				t.Errorf("GET %s: %d %s", path, res.StatusCode, res.Header.Get("Content-Type"))
			}
		}
	}

	// In the lobby: buy with chips, lay it, read it back.
	token, id := login(t, ts.URL, "table-picture-buyer", "Table Buyer")
	res := postJSON(ts.URL, token, "/api/table-pictures/buy", map[string]any{"pictureId": coin.ID})
	if res.err != nil || res.status != http.StatusOK || res.body["charged"] != true || res.body["spent"] != float64(coin.Cost) {
		t.Fatalf("lobby chip buy: %d %v %v", res.status, res.body, res.err)
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != welcome-coin.Cost || ledger != wallet {
		t.Errorf("after the buy: wallet %d, ledger %d, want both %d", wallet, ledger, welcome-coin.Cost)
	}
	var reason string
	if err := database.Pool.QueryRow(ctx,
		`SELECT reason FROM chip_ledger WHERE user_id = $1 ORDER BY id DESC LIMIT 1`, id).Scan(&reason); err != nil || reason != "table_picture_purchase" {
		t.Errorf("the ledger row's reason = %q %v", reason, err)
	}
	res = postJSON(ts.URL, token, "/api/table-pictures/use", map[string]any{"pictureId": coin.ID})
	if res.err != nil || res.status != http.StatusOK {
		t.Fatalf("laying: %d %v %v", res.status, res.body, res.err)
	}
	user, _ := res.body["user"].(map[string]any)
	laid, _ := user["tablePicture"].(map[string]any)
	if laid["id"] != float64(coin.ID) || laid["dayUrl"] != coin.DayURL || laid["nightUrl"] != coin.NightURL || laid["assetFormat"] != "SVG" {
		t.Errorf("tablePicture after laying = %v", user["tablePicture"])
	}

	// A saved session sees it on /api/auth/me and on session:ready.
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/auth/me", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	meRes, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var me struct {
		User struct {
			TablePicture *db.LaidTablePicture `json:"tablePicture"`
		} `json:"user"`
	}
	if err := json.NewDecoder(meRes.Body).Decode(&me); err != nil || me.User.TablePicture == nil || me.User.TablePicture.ID != coin.ID {
		t.Errorf("/api/auth/me carries %+v (%v)", me.User.TablePicture, err)
	}
	meRes.Body.Close()

	// At a table: chips refused, hammers sold and laid; the seat's chips and
	// the wallet do not move.
	seatedToken, seatedID := login(t, ts.URL, "table-picture-seated", "Table Seated")
	c := dial(t, ts.URL, seatedToken)
	joinAck := mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	// A Teen Patti table (the picture shows on that felt alone, §6.5).
	table := game.AsTable(a.Rooms().GetTableForPlayer(seatedID))
	if table == nil {
		t.Fatal("the player is not seated after a quick join")
	}
	var joined struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(joinAck.Raw, &joined); err != nil || joined.Code == "" {
		t.Fatalf("the quick-join ack carries no code: %s %v", joinAck.Raw, err)
	}
	// A second player at the same table, who has laid nothing.
	otherToken, otherID := login(t, ts.URL, "table-picture-other", "Table Other")
	c2 := dial(t, ts.URL, otherToken)
	mustOK(t, c2, socket.EvRoomJoinCode, map[string]any{"code": joined.Code})
	shownTo := func(viewer string) *game.TablePicture {
		t.Helper()
		view, err := table.SerializeFor(viewer)
		if err != nil {
			t.Fatal(err)
		}
		return view.TablePicture
	}
	if shownTo(otherID) != nil {
		t.Fatalf("a table where nobody has laid a picture shows %+v", shownTo(otherID))
	}
	res = postJSON(ts.URL, seatedToken, "/api/table-pictures/buy", map[string]any{"pictureId": coin.ID})
	if res.err != nil || res.status != http.StatusConflict || res.body["error"] != auth.CodeSeated {
		t.Errorf("a seated chip buy: %d %v %v, want 409 seated", res.status, res.body, res.err)
	}
	res = postJSON(ts.URL, seatedToken, "/api/table-pictures/buy", map[string]any{"pictureId": hammer.ID})
	if res.err != nil || res.status != http.StatusOK || res.body["charged"] != true || res.body["spent"] != float64(hammer.Cost) {
		t.Fatalf("a seated hammer buy: %d %v %v", res.status, res.body, res.err)
	}
	res = postJSON(ts.URL, seatedToken, "/api/table-pictures/use", map[string]any{"pictureId": hammer.ID})
	if res.err != nil || res.status != http.StatusOK {
		t.Fatalf("laying at the table: %d %v %v", res.status, res.body, res.err)
	}
	// The whole table sees it (owner, 15 Sep 2026): the other player's own
	// view carries the buyer's picture, tagged with who laid it, and the
	// seat holds a copy.
	for _, viewer := range []string{seatedID, otherID} {
		if got := shownTo(viewer); got == nil || got.ID != hammer.ID || got.UserID != seatedID || got.NightURL != hammer.NightURL {
			t.Fatalf("after laying, %s sees %+v, want picture %d laid by %s", viewer, got, hammer.ID, seatedID)
		}
	}
	if seat, err := table.FindSeat(seatedID); err != nil || seat == nil || seat.TablePicture == nil || seat.TablePicture.ID != hammer.ID {
		t.Fatalf("the seat carries %+v (%v)", seat, err)
	}
	// It reaches the other player over the wire, in room:state.
	if _, err := c2.Wait(socket.EvRoomState, func(raw json.RawMessage) bool {
		var view struct {
			TablePicture *game.TablePicture `json:"tablePicture"`
		}
		return json.Unmarshal(raw, &view) == nil && view.TablePicture != nil && view.TablePicture.ID == hammer.ID
	}, 3*time.Second); err != nil {
		t.Fatalf("the other player never got room:state with the picture: %v", err)
	}
	if hammers, spends, _ := hammerBooks(t, database, seatedID); hammers != 20-hammer.Cost || spends != 0 {
		t.Errorf("a seated hammer table buy: hammers %d, hammer_spends %d", hammers, spends)
	}
	if wallet, ledger := walletAndLedger(t, database, seatedID); seatOf(t, a, seatedID) != welcome || wallet != welcome || ledger != welcome {
		t.Errorf("chips moved while seated: seat %d, wallet %d, ledger %d, want all %d", seatOf(t, a, seatedID), wallet, ledger, welcome)
	}
	// The free one is laid without a purchase, and the choice replaces the
	// last.
	res = postJSON(ts.URL, seatedToken, "/api/table-pictures/use", map[string]any{"pictureId": free.ID})
	user, _ = res.body["user"].(map[string]any)
	laid, _ = user["tablePicture"].(map[string]any)
	if res.status != http.StatusOK || laid["id"] != float64(free.ID) {
		t.Errorf("laying the free picture: %d %v", res.status, res.body)
	}
	if got := shownTo(otherID); got == nil || got.ID != free.ID {
		t.Errorf("after the swap the other player sees %+v, want picture %d", got, free.ID)
	}
	// The owner leaving takes the picture with them: the table falls back to
	// nothing — the flowing chips — for whoever is still there.
	mustOK(t, c, socket.EvRoomLeave, map[string]any{})
	if got := shownTo(otherID); got != nil {
		t.Errorf("after the owner left the other player still sees %+v", got)
	}
	mustOK(t, c2, socket.EvRoomLeave, map[string]any{})
}
