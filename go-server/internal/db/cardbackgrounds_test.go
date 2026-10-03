package db_test

import (
	"encoding/json"
	"errors"
	"math"
	"sort"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// The card backs (owner, 3 Oct 2026: "Add a table cards_background which users
// can buy just like user can buy profile_pictures … keep the price of all
// cards 5 Hammers validity 10 days"): the table pictures' catalogue, till and
// choice again, for the back of a player's cards — which everybody at their
// table sees.

// seededCard is one of the owner's thirteen as the seed writes it.
type seededCard struct {
	name, key  string
	x, y, w, h float64
	sort       int
	cost       int64 // in hammers
}

// seededCards are V1.0.1__seed.sql's THE CARD BACKS, in shelf order: the
// owner's file in the bucket's cards/ folder (its location writes each space
// %20) and the card's rectangle in its picture, measured by hand.
var seededCards = []seededCard{
	{"Brutal Demon", "cards/Brutal%20Demon.jpg", 0.2035, 0.0805, 0.6007, 0.8410, 10, 5},
	{"Demon Hell", "cards/Demon%20Hell.jpg", 0.2203, 0.1167, 0.5594, 0.7831, 20, 5},
	{"Dragon Hunter", "cards/Dragon%20Hunter.jpg", 0.2073, 0.0880, 0.5844, 0.8182, 30, 5},
	{"Royal Lion", "cards/Royal%20Lion.jpg", 0.2065, 0.0948, 0.5851, 0.8192, 40, 5},
	{"Royal Majestic Fox", "cards/Royal%20Majestic%20Fox.jpg", 0.2371, 0.1336, 0.5248, 0.7347, 50, 5},
	{"Royal Owl with Fox", "cards/Royal%20Owl%20with%20fox.jpg", 0.1985, 0.0776, 0.6021, 0.8429, 60, 5},
	{"Royal Tiger", "cards/Royal%20Tiger.jpg", 0.2291, 0.1262, 0.5417, 0.7584, 70, 5},
	{"Royal White Tiger", "cards/Royal%20White%20Tiger.jpg", 0.2224, 0.1108, 0.5533, 0.7746, 80, 5},
	{"Flower 1", "cards/Flower%201.jpg", 0.2209, 0.0994, 0.5729, 0.8021, 90, 2},
	{"Flower 2", "cards/Flower%202.jpg", 0.2308, 0.1124, 0.5383, 0.7537, 100, 2},
	{"Flower 3", "cards/Flower%203.jpg", 0.2295, 0.1261, 0.5411, 0.7575, 110, 2},
	{"Flower 4", "cards/Flower%204.jpg", 0.2393, 0.1365, 0.5214, 0.7299, 120, 2},
	{"Flower 5", "cards/Flower%205.jpg", 0.2346, 0.1279, 0.5289, 0.7404, 130, 2},
}

// cardBackRow inserts one card back of the test's own, in the seed's shape —
// an https location and a 5:7 crop — and returns it as an anonymous viewer
// lists it.
func cardBackRow(t *testing.T, f *fixture, name, currency, kind string, cost int64, days int) db.CardBackground {
	t.Helper()
	var id int64
	if err := f.d.Pool.QueryRow(f.ctx,
		`INSERT INTO cards_background (name, asset_url, asset_format, crop_x, crop_y, crop_w, crop_h, currency, type, cost,
		                               duration_days, sort_order, created_at, updated_at)
		 VALUES ($1, $2, 'IMAGE', 0.2, 0.1, 0.6, 0.84, $3, $4, $5, $6, 900, 0, 0) RETURNING id`,
		name, seededAssets+"cards/"+strings.ReplaceAll(name, " ", "%20")+".jpg", currency, kind, cost, days).Scan(&id); err != nil {
		t.Fatalf("insert card back %s: %v", name, err)
	}
	cb, _, err := f.cards.Find(f.ctx, "", id)
	if err != nil {
		t.Fatal(err)
	}
	return cb
}

// seededCardBack is the seeded row of that name, as viewer lists it.
func seededCardBack(t *testing.T, f *fixture, viewer, name string) db.CardBackground {
	t.Helper()
	shelf, err := f.cards.List(f.ctx, viewer)
	if err != nil {
		t.Fatal(err)
	}
	for _, cb := range shelf {
		if cb.Name == name {
			return cb
		}
	}
	t.Fatalf("the shelf has no %s", name)
	return db.CardBackground{}
}

// chosen is the id of the card back the account has chosen, or 0.
func (f *fixture) chosen(userID string) int64 {
	f.t.Helper()
	return f.scalar(`SELECT COALESCE((SELECT card_background_id FROM user_cards_background_choice WHERE user_id = $1), 0)`, userID)
}

// The seed (V1.0.1__seed.sql, THE CARD BACKS) holds the owner's thirteen, in
// shelf order: the files they uploaded to the bucket's cards/ folder, each
// with its card's rectangle — exactly 5:7, inside the picture — and every one
// PREMIUM for 10 days, listed: the first eight at 5 hammers, the five Flower
// backs at 2. The default back, Royal Fox, is the app's and no row. An
// anonymous viewer owns none of them.
func TestTheSeededCardBacksAreTheOwnersThirteenForTenDays(t *testing.T) {
	f := newFixture(t)
	shelf, err := f.cards.List(f.ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(shelf) != len(seededCards) {
		t.Fatalf("the seed lists %d card backs, want %d", len(shelf), len(seededCards))
	}
	for i, want := range seededCards {
		got := shelf[i]
		if got.Name != want.name || got.URL != seededAssets+want.key || got.AssetFormat != game.CardBackgroundFormat ||
			got.Currency != db.PictureCurrencyHammer || got.Type != db.PicturePremium || got.Cost != want.cost ||
			got.DurationDays != 10 || got.DurationHours != 0 || got.SortOrder != want.sort || got.Owned || got.ExpiresAt != 0 {
			t.Errorf("seeded card back %d = %+v, want %s at %s, %d hammers for 10 days", i, got, want.name, want.key, want.cost)
		}
		if got.Crop == nil || *got.Crop != (game.CardCrop{X: want.x, Y: want.y, W: want.w, H: want.h}) {
			t.Errorf("%s's crop = %+v, want %v %v %v %v", want.name, got.Crop, want.x, want.y, want.w, want.h)
			continue
		}
		// The card's own 5:7 (a 1024×1024 picture, so the fractions' ratio is
		// the pixels'), inside the picture.
		if ratio := got.Crop.W / got.Crop.H; math.Abs(ratio-5.0/7.0) > 0.001 {
			t.Errorf("%s's crop is %.4f wide for its height, want 5:7", want.name, ratio)
		}
		if got.Crop.X+got.Crop.W > 1 || got.Crop.Y+got.Crop.H > 1 {
			t.Errorf("%s's crop runs off its picture: %+v", want.name, got.Crop)
		}
		if strings.Contains(got.URL, " ") {
			t.Errorf("%s's location carries a raw space: %s", want.name, got.URL)
		}
	}
	if n := f.count(`SELECT count(*) FROM cards_background WHERE name = 'Royal Fox' OR asset_url = $1`,
		seededAssets+"cards/Royal%20Fox.jpg"); n != 0 {
		t.Error("the bundled default back is seeded as a row")
	}
}

// A catalogue row on the wire is the table picture's shape with one url and
// its crop: {id, name, url, assetFormat, crop?, currency, type, cost,
// durationDays, durationHours, sortOrder, owned, expiresAt} — crop ABSENT on a
// row that has none (the whole picture is the card), never null.
func TestACardBackMarshalsWithItsCropAndWithoutOneWhenItHasNone(t *testing.T) {
	f := newFixture(t)
	brutal := seededCardBack(t, f, "", "Brutal Demon")
	raw, err := json.Marshal(brutal)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if got := strings.Join(keys, ","); got != "assetFormat,cost,crop,currency,durationDays,durationHours,expiresAt,id,name,owned,sortOrder,type,url" {
		t.Fatalf("a card back's keys: %s", got)
	}
	if got := string(m["crop"]); got != `{"x":0.2035,"y":0.0805,"w":0.6007,"h":0.841}` {
		t.Fatalf("crop = %s", got)
	}

	var bare int64
	if err := f.d.Pool.QueryRow(f.ctx,
		`INSERT INTO cards_background (name, asset_url, type, currency, cost, created_at, updated_at)
		 VALUES ('Whole Picture', $1, 'PREMIUM', 'HAMMER', 5, 0, 0) RETURNING id`, seededAssets+"cards/Whole.jpg").Scan(&bare); err != nil {
		t.Fatal(err)
	}
	whole, _, err := f.cards.Find(f.ctx, "", bare)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ = json.Marshal(whole)
	if whole.Crop != nil || strings.Contains(string(raw), `"crop"`) || whole.AssetFormat != "IMAGE" {
		t.Fatalf("a card back with no crop: %+v marshals %s", whole, raw)
	}
}

// The crop is all four fractions or none, a rectangle of positive size inside
// its picture, and finite; the art is a raster. Anything else is refused by
// the table's CHECKs before a row is written.
func TestTheCardBackRowsChecksHoldItsCropAndItsFormat(t *testing.T) {
	f := newFixture(t)
	insert := func(format string, crop ...any) error {
		args := []any{seededAssets + "cards/Check-" + randomSuffix(t) + ".jpg", format}
		args = append(args, crop...)
		_, err := f.d.Pool.Exec(f.ctx,
			`INSERT INTO cards_background (name, asset_url, asset_format, crop_x, crop_y, crop_w, crop_h, type, currency, cost, created_at, updated_at)
			 VALUES ('Check', $1, $2, $3, $4, $5, $6, 'PREMIUM', 'HAMMER', 5, 0, 0)`, args...)
		return err
	}
	if err := insert("IMAGE", nil, nil, nil, nil); err != nil {
		t.Fatalf("no crop at all: %v", err)
	}
	if err := insert("IMAGE", 0.0, 0.0, 1.0, 1.0); err != nil {
		t.Fatalf("the whole picture as a crop: %v", err)
	}
	for name, crop := range map[string][]any{
		"three of four":      {0.1, 0.1, 0.5, nil},
		"x and w past 1":     {0.5, 0.1, 0.6, 0.7},
		"y and h past 1":     {0.1, 0.4, 0.5, 0.7},
		"a width of 0":       {0.1, 0.1, 0.0, 0.7},
		"a negative height":  {0.1, 0.1, 0.5, -0.7},
		"a negative x":       {-0.1, 0.1, 0.5, 0.7},
		"a NaN x":            {math.NaN(), 0.1, 0.5, 0.7},
		"an infinite height": {0.1, 0.1, 0.5, math.Inf(1)},
	} {
		var pgErr *pgconn.PgError
		if err := insert("IMAGE", crop...); !errors.As(err, &pgErr) || pgErr.Code != "23514" {
			t.Errorf("%s: %v, want a CHECK violation", name, err)
		}
	}
	var pgErr *pgconn.PgError
	if err := insert("LOTTIE", nil, nil, nil, nil); !errors.As(err, &pgErr) || pgErr.Code != "23514" {
		t.Errorf("a Lottie card back: %v, want a CHECK violation", err)
	}
}

// A seeded card back is bought with five hammers at a table as in the lobby: a
// delta on users.hammer alone — no chips, no ledger row, no hammer_spends row —
// and an ownership row running ten days from now; a second buy charges
// nothing. Too few hammers is refused naming the price, and moves nothing.
func TestAHammerCardBackIsBoughtWithFiveHammersAndASecondBuyChargesNothing(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	execSQL(t, f.d, `UPDATE users SET hammer = 12 WHERE id = $1`, user.ID)
	brutal := seededCardBack(t, f, user.ID, "Brutal Demon")
	ledgerRows := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1`, user.ID)

	bought, err := f.cards.Buy(f.ctx, user.ID, brutal.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !bought.Charged || bought.Spent != 5 || bought.Balance != welcome || !bought.CardBackground.Owned ||
		bought.CardBackground.ID != brutal.ID || bought.CardBackground.Crop == nil {
		t.Fatalf("purchase = %+v", bought)
	}
	if bought.User == nil || bought.User.Hammer != 7 || bought.User.Chips != welcome || bought.User.CardBackground != nil {
		t.Fatalf("the account after a buy (not yet chosen): %+v", bought.User)
	}
	if span := bought.CardBackground.ExpiresAt - nowMs(); span > 10*db.DayMs || span < 10*db.DayMs-60_000 {
		t.Fatalf("the rental runs %d ms from now, want 10 days", span)
	}
	if got := f.scalar(`SELECT expires_at - acquired_at FROM user_cards_background WHERE user_id = $1 AND card_background_id = $2`,
		user.ID, brutal.ID); got != 10*db.DayMs {
		t.Fatalf("the ownership row spans %d ms, want 10 days", got)
	}
	if got := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1`, user.ID); got != ledgerRows {
		t.Fatalf("a hammer card back wrote %d ledger row(s)", got-ledgerRows)
	}
	if got := f.count(`SELECT COUNT(*) FROM hammer_spends WHERE user_id = $1`, user.ID); got != 0 {
		t.Fatalf("a card back wrote %d hammer_spends row(s)", got)
	}
	if listed := seededCardBack(t, f, user.ID, "Brutal Demon"); !listed.Owned || listed.ExpiresAt != bought.CardBackground.ExpiresAt {
		t.Fatalf("the buyer's shelf shows %+v", listed)
	}

	again, err := f.cards.Buy(f.ctx, user.ID, brutal.ID)
	if err != nil || again.Charged || again.Spent != 0 || f.hammersOf(user.ID) != 7 {
		t.Fatalf("a second buy: %+v %v, hammers %d", again, err, f.hammersOf(user.ID))
	}

	// At a table a hammer card back sells as in the lobby.
	dragon := seededCardBack(t, f, user.ID, "Dragon Hunter")
	atTable, err := f.cards.BuyAtTable(f.ctx, user.ID, dragon.ID)
	if err != nil || !atTable.Charged || atTable.Spent != 5 || f.hammersOf(user.ID) != 2 || f.chips(user.ID) != welcome {
		t.Fatalf("a hammer card back at a table: %+v %v, hammers %d", atTable, err, f.hammersOf(user.ID))
	}

	// Two hammers left, a third card back costs five.
	tiger := seededCardBack(t, f, user.ID, "Royal Tiger")
	_, err = f.cards.Buy(f.ctx, user.ID, tiger.ID)
	var short *db.PictureHammerShortage
	if !errors.Is(err, db.ErrPictureHammers) || !errors.As(err, &short) || short.Cost != 5 {
		t.Fatalf("too few hammers: %v", err)
	}
	if f.hammersOf(user.ID) != 2 || f.count(`SELECT COUNT(*) FROM user_cards_background WHERE user_id = $1 AND card_background_id = $2`, user.ID, tiger.ID) != 0 {
		t.Fatal("a refused buy moved hammers or wrote an ownership row")
	}
	f.reconcile()
}

// A chip-priced card back is bought as a chip-priced table picture is: a
// ledger row (reason card_background_purchase, action_id
// cardbg:<user>:<id>:1) and a wallet delta that reconcile — and never at a
// table, where it is refused before anything moves. A diamond one takes
// diamonds alone. Each shortage is the pictures' own.
func TestAChipPricedCardBackGoesThroughTheLedgerAndOnlyInTheLobby(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	gold := cardBackRow(t, f, "Gold Leaf", db.PictureCurrencyCoin, db.PicturePremium, 50000, 7)
	gem := cardBackRow(t, f, "Gem Inlay", db.PictureCurrencyDiamond, db.PicturePremium, 3, 0)
	execSQL(t, f.d, `UPDATE users SET diamond = 4 WHERE id = $1`, user.ID)

	if _, err := f.cards.BuyAtTable(f.ctx, user.ID, gold.ID); !errors.Is(err, db.ErrPictureAtTable) {
		t.Fatalf("a chip-priced card back at a table: %v, want ErrPictureAtTable", err)
	}
	if f.chips(user.ID) != welcome {
		t.Fatal("a refused buy at a table moved chips")
	}
	bought, err := f.cards.Buy(f.ctx, user.ID, gold.ID)
	if err != nil || !bought.Charged || bought.Spent != 50000 || bought.Balance != welcome-50000 {
		t.Fatalf("a chip buy in the lobby: %+v %v", bought, err)
	}
	if db.LedgerReasonCardBackgroundPurchase != "card_background_purchase" {
		t.Fatalf("the ledger reason is %q", db.LedgerReasonCardBackgroundPurchase)
	}
	rows := f.ledgerRows(user.ID)
	last := rows[len(rows)-1]
	if last.Reason != db.LedgerReasonCardBackgroundPurchase || last.Delta != -50000 || last.ActionID == nil ||
		*last.ActionID != "cardbg:"+user.ID+":"+itoa(gold.ID)+":1" {
		t.Fatalf("the ledger row = %+v", last)
	}
	f.reconcile()

	diamonds, err := f.cards.BuyAtTable(f.ctx, user.ID, gem.ID)
	if err != nil || !diamonds.Charged || diamonds.Spent != 3 || f.diamondsOf(user.ID) != 1 || f.chips(user.ID) != welcome-50000 {
		t.Fatalf("a diamond card back: %+v %v", diamonds, err)
	}
	if diamonds.CardBackground.ExpiresAt != 0 {
		t.Fatalf("a card back for ever reads an expiry: %+v", diamonds.CardBackground)
	}

	f.reconcile()

	// Short of each wallet (the chips set by hand: this account's books are
	// not reconciled after it).
	poor := newGuest(t, f)
	execSQL(t, f.d, `UPDATE users SET chips = 49999, diamond = 2 WHERE id = $1`, poor.ID)
	if _, err := f.cards.Buy(f.ctx, poor.ID, gold.ID); !errors.Is(err, db.ErrPictureChips) {
		t.Fatalf("a chip shortage: %v", err)
	}
	if _, err := f.cards.Buy(f.ctx, poor.ID, gem.ID); !errors.Is(err, db.ErrPictureDiamonds) {
		t.Fatalf("a diamond shortage: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM user_cards_background WHERE user_id = $1`, poor.ID); n != 0 {
		t.Fatalf("a refused buy wrote %d ownership row(s)", n)
	}
}

// Choosing one puts it on the account — {id, url, assetFormat, crop}, what
// every seat built from the account carries (User.Player) — and nil takes it
// off: the default back. A free one is chosen with no purchase.
func TestAChosenCardBackRidesOnTheAccountAndEverySeatBuiltFromIt(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	if user.CardBackground != nil || user.Player().CardBackground != nil {
		t.Fatalf("a new account wears %+v, want the default back", user.CardBackground)
	}
	owl := seededCardBack(t, f, user.ID, "Royal Owl with Fox")
	if _, err := f.cards.Buy(f.ctx, user.ID, owl.ID); err != nil {
		t.Fatal(err)
	}
	chosen, err := f.cards.Use(f.ctx, user.ID, &owl.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := game.CardBackground{ID: owl.ID, URL: seededAssets + "cards/Royal%20Owl%20with%20fox.jpg", Format: "IMAGE",
		Crop: &game.CardCrop{X: 0.1985, Y: 0.0776, W: 0.6021, H: 0.8429}}
	same := func(got *game.CardBackground) bool {
		return got != nil && got.ID == want.ID && got.URL == want.URL && got.Format == want.Format && got.Crop != nil && *got.Crop == *want.Crop
	}
	if !same(chosen.CardBackground) {
		t.Fatalf("cardBackground after choosing = %+v", chosen.CardBackground)
	}
	if found := f.find(user.ID); !same(found.CardBackground) || !same(found.Player().CardBackground) {
		t.Fatalf("FindByID carries %+v, its Player %+v", found.CardBackground, found.Player().CardBackground)
	}
	raw, _ := json.Marshal(chosen)
	if !strings.Contains(string(raw), `"cardBackground":{"id":`+itoa(owl.ID)+`,"url":"`+want.URL+`","assetFormat":"IMAGE","crop":{"x":0.1985,"y":0.0776,"w":0.6021,"h":0.8429}}`) {
		t.Fatalf("the account on the wire: %s", raw)
	}

	// A free one needs no purchase, and replaces the choice.
	plain := cardBackRow(t, f, "Plain Felt", db.PictureCurrencyCoin, db.PictureFree, 0, 0)
	if got, err := f.cards.Use(f.ctx, user.ID, &plain.ID); err != nil || got.CardBackground == nil || got.CardBackground.ID != plain.ID {
		t.Fatalf("choosing the free card back: %+v %v", got.CardBackground, err)
	}
	// Off again: the default back, null on the wire.
	bare, err := f.cards.Use(f.ctx, user.ID, nil)
	if err != nil || bare.CardBackground != nil || f.chosen(user.ID) != 0 || bare.Player().CardBackground != nil {
		t.Fatalf("taking the card back off: %+v %v", bare.CardBackground, err)
	}
	raw, _ = json.Marshal(bare)
	if !strings.Contains(string(raw), `"cardBackground":null`) {
		t.Fatalf("the default back on the wire: %s", raw)
	}
	// Use checks no ownership — the route does — but the foreign key refuses
	// an id the catalogue does not hold.
	missing := int64(987654)
	if _, err := f.cards.Use(f.ctx, user.ID, &missing); err == nil {
		t.Fatal("choosing a card back that is not in the catalogue was stored")
	}
}

// A rental that runs out is gone from the account the instant it lapses — the
// account's join tests the expiry, so no new seat ever wears it — while the
// choice row waits for the sweep, which takes it off and says so once. The
// shelf shows it locked, and buying it again is a fresh charge from now.
func TestALapsedCardBackIsGoneFromTheAccountBeforeAnySweepAndIsBoughtAfresh(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	execSQL(t, f.d, `UPDATE users SET hammer = 10 WHERE id = $1`, user.ID)
	lion := seededCardBack(t, f, user.ID, "Royal Lion")
	if _, err := f.cards.Buy(f.ctx, user.ID, lion.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.cards.Use(f.ctx, user.ID, &lion.ID); err != nil {
		t.Fatal(err)
	}
	if swept, err := f.cards.ExpireLapsed(f.ctx, user.ID); err != nil || swept {
		t.Fatalf("a running rental was swept: %v %v", swept, err)
	}
	execSQL(t, f.d, `UPDATE user_cards_background SET expires_at = 1 WHERE user_id = $1 AND card_background_id = $2`, user.ID, lion.ID)
	if lapsed := f.find(user.ID); lapsed.CardBackground != nil || lapsed.Player().CardBackground != nil {
		t.Fatalf("a lapsed rental still reads as chosen before the sweep: %+v", lapsed.CardBackground)
	}
	if f.chosen(user.ID) != lion.ID {
		t.Fatal("the choice row is the sweep's to delete, not the read's")
	}
	if swept, err := f.cards.ExpireLapsed(f.ctx, user.ID); err != nil || !swept {
		t.Fatalf("the sweep left a lapsed rental chosen: %v %v", swept, err)
	}
	if swept, err := f.cards.ExpireLapsed(f.ctx, user.ID); err != nil || swept {
		t.Fatalf("a second sweep found something to take off: %v %v", swept, err)
	}
	if f.chosen(user.ID) != 0 {
		t.Fatal("the lapsed card back is still chosen")
	}
	if relisted := seededCardBack(t, f, user.ID, "Royal Lion"); relisted.Owned || relisted.ExpiresAt != 0 {
		t.Fatalf("a lapsed rental still reads as owned: %+v", relisted)
	}
	renewed, err := f.cards.Buy(f.ctx, user.ID, lion.ID)
	if err != nil || !renewed.Charged || renewed.Spent != 5 || f.hammersOf(user.ID) != 0 {
		t.Fatalf("the renewal = %+v %v, hammers %d", renewed, err, f.hammersOf(user.ID))
	}
	if n := f.scalar(`SELECT purchases FROM user_cards_background WHERE user_id = $1 AND card_background_id = $2`, user.ID, lion.ID); n != 2 {
		t.Fatalf("purchases = %d, want 2", n)
	}
	// A free card back never lapses: the sweep leaves it chosen.
	plain := cardBackRow(t, f, "Plain Felt", db.PictureCurrencyCoin, db.PictureFree, 0, 0)
	if _, err := f.cards.Use(f.ctx, user.ID, &plain.ID); err != nil {
		t.Fatal(err)
	}
	if swept, err := f.cards.ExpireLapsed(f.ctx, user.ID); err != nil || swept || f.chosen(user.ID) != plain.ID {
		t.Fatalf("the sweep touched a free card back: %v %v", swept, err)
	}
}

// is_listed on the card backs (owner, 1 Oct 2026's rule for every shelf): an
// unlisted one is shown to nobody but a player who has it — bought and
// running, or chosen — and sold to nobody, though a second tap from its owner
// is still the success the first was.
func TestAnUnlistedCardBackIsShownOnlyToWhoeverHasItAndSoldToNobody(t *testing.T) {
	f := newFixture(t)
	owner, stranger, chooser := newGuest(t, f), newGuest(t, f), newGuest(t, f)
	brutal := seededCardBack(t, f, owner.ID, "Brutal Demon")
	plain := cardBackRow(t, f, "Plain Felt", db.PictureCurrencyCoin, db.PictureFree, 0, 0)
	if _, err := f.cards.Buy(f.ctx, owner.ID, brutal.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.cards.Use(f.ctx, chooser.ID, &plain.ID); err != nil {
		t.Fatal(err)
	}
	execSQL(t, f.d, `UPDATE cards_background SET is_listed = FALSE WHERE id IN ($1, $2)`, brutal.ID, plain.ID)

	shelf := func(viewer string) map[int64]db.CardBackground {
		t.Helper()
		all, err := f.cards.List(f.ctx, viewer)
		if err != nil {
			t.Fatal(err)
		}
		out := map[int64]db.CardBackground{}
		for _, cb := range all {
			out[cb.ID] = cb
		}
		return out
	}
	for who, viewer := range map[string]string{"an anonymous caller": "", "a stranger": stranger.ID} {
		got := shelf(viewer)
		if _, ok := got[brutal.ID]; ok {
			t.Errorf("%s is shown the unlisted Brutal Demon", who)
		}
		if _, ok := got[plain.ID]; ok {
			t.Errorf("%s is shown the unlisted free card back", who)
		}
		if len(got) != len(seededCards)-1 {
			t.Errorf("%s is shown %d card backs, want the other %d", who, len(got), len(seededCards)-1)
		}
	}
	if cb, ok := shelf(owner.ID)[brutal.ID]; !ok || !cb.Owned {
		t.Errorf("the owner's unlisted card back on their shelf: %+v %v", cb, ok)
	}
	if cb, ok := shelf(chooser.ID)[plain.ID]; !ok || !cb.Owned {
		t.Errorf("the chooser's unlisted free card back on their shelf: %+v %v", cb, ok)
	}
	if _, err := f.cards.Buy(f.ctx, stranger.ID, brutal.ID); !errors.Is(err, db.ErrPictureUnlisted) {
		t.Errorf("a stranger buying an unlisted card back: %v, want ErrPictureUnlisted", err)
	}
	if again, err := f.cards.Buy(f.ctx, owner.ID, brutal.ID); err != nil || again.Charged {
		t.Errorf("the owner's second tap on an unlisted card back: %+v %v", again, err)
	}
}

// The refusals that need no wallet: an id the catalogue does not hold, a free
// row (nothing to sell), and a retired one — which whoever chose it keeps on
// their cards, but which is neither listed nor sold. Deleting the row, though,
// puts the default back on whoever had chosen it (ON DELETE CASCADE).
func TestACardBackThatIsUnknownFreeOrRetiredIsRefused(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	plain := cardBackRow(t, f, "Plain Felt", db.PictureCurrencyCoin, db.PictureFree, 0, 0)
	hell := seededCardBack(t, f, user.ID, "Demon Hell")

	if _, err := f.cards.Buy(f.ctx, user.ID, 987654); !errors.Is(err, db.ErrCardBackgroundUnknown) {
		t.Fatalf("an unknown id: %v", err)
	}
	if _, _, err := f.cards.Find(f.ctx, user.ID, 987654); !errors.Is(err, db.ErrCardBackgroundUnknown) {
		t.Fatalf("Find of an unknown id: %v", err)
	}
	if _, err := f.cards.Buy(f.ctx, user.ID, plain.ID); !errors.Is(err, db.ErrPictureFree) {
		t.Fatalf("buying a free card back: %v", err)
	}

	if _, err := f.cards.Buy(f.ctx, user.ID, hell.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.cards.Use(f.ctx, user.ID, &hell.ID); err != nil {
		t.Fatal(err)
	}
	execSQL(t, f.d, `UPDATE cards_background SET is_active = FALSE WHERE id = $1`, hell.ID)
	listed, err := f.cards.List(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, cb := range listed {
		if cb.ID == hell.ID {
			t.Fatal("a retired card back is still listed")
		}
	}
	found, active, err := f.cards.Find(f.ctx, user.ID, hell.ID)
	if err != nil || active || !found.Owned {
		t.Fatalf("Find of a retired, owned card back: %v active=%v %+v", err, active, found)
	}
	if _, err := f.cards.Buy(f.ctx, user.ID, hell.ID); !errors.Is(err, db.ErrPictureInactive) {
		t.Fatalf("buying a retired card back: %v", err)
	}
	if u := f.find(user.ID); u.CardBackground == nil || u.CardBackground.ID != hell.ID {
		t.Fatalf("retiring a card back took it off the cards it was on: %+v", u.CardBackground)
	}
	execSQL(t, f.d, `DELETE FROM cards_background WHERE id = $1`, hell.ID)
	if u := f.find(user.ID); u.CardBackground != nil || f.chosen(user.ID) != 0 {
		t.Fatalf("a deleted catalogue row is still chosen: %+v", u.CardBackground)
	}
}

// Deleting an account takes its card back off with the rest of what
// identifies it; the purchase stays, as every receipt does.
func TestDeletingAnAccountTakesItsCardBackOff(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	tiger := seededCardBack(t, f, user.ID, "Royal White Tiger")
	if _, err := f.cards.Buy(f.ctx, user.ID, tiger.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.cards.Use(f.ctx, user.ID, &tiger.ID); err != nil {
		t.Fatal(err)
	}
	if err := f.users.DeleteAccount(f.ctx, user.ID); err != nil {
		t.Fatal(err)
	}
	if f.chosen(user.ID) != 0 {
		t.Error("the chosen card back survived the deletion")
	}
	if n := f.count(`SELECT count(*) FROM user_cards_background WHERE user_id = $1`, user.ID); n != 1 {
		t.Errorf("the purchase record: %d rows, want it kept", n)
	}
	if _, err := f.cards.Buy(f.ctx, user.ID, tiger.ID); game.CodeOf(err, "") != game.CodeUnknownUser {
		t.Errorf("a deleted account buying a card back: %v", err)
	}
}
