package db_test

import (
	"errors"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// tablePictureRow inserts one catalogue row for a test, in the seed's shape,
// and returns it as an anonymous viewer lists it. The seed holds only the
// owner's own art, so every rule is proven on rows of the test's own.
func tablePictureRow(t *testing.T, f *fixture, name, currency, kind string, cost int64, days int) db.TablePicture {
	t.Helper()
	slug := "/tables/" + toSlug(name)
	var id int64
	if err := f.d.Pool.QueryRow(f.ctx,
		`INSERT INTO table_pictures (name, day_asset_url, night_asset_url, asset_format, currency, type, cost, duration_days, sort_order, created_at, updated_at)
		 VALUES ($1, $2, $3, 'SVG', $4, $5, $6, $7, 999, 0, 0) RETURNING id`,
		name, slug+"-day.svg", slug+"-night.svg", currency, kind, cost, days).Scan(&id); err != nil {
		t.Fatalf("insert table picture %s: %v", name, err)
	}
	pic, _, err := f.tables.Find(f.ctx, "", id)
	if err != nil {
		t.Fatal(err)
	}
	return pic
}

// toSlug is the file naming the generated designs use: lower case, spaces to
// hyphens.
func toSlug(name string) string {
	out := make([]byte, 0, len(name))
	for i := 0; i < len(name); i++ {
		c := name[i]
		switch {
		case c == ' ':
			out = append(out, '-')
		case c >= 'A' && c <= 'Z':
			out = append(out, c+'a'-'A')
		default:
			out = append(out, c)
		}
	}
	return string(out)
}

// laid is the id of the table picture the account has laid, or 0.
func (f *fixture) laid(userID string) int64 {
	f.t.Helper()
	return f.scalar(`SELECT COALESCE((SELECT table_picture_id FROM user_table_choice WHERE user_id = $1), 0)`, userID)
}

// The seed (V1.0.3__seed_table_pictures.sql) holds the owner's own art: four
// Lotties hosted on Drive, all rented for chips — Lines Background (re-priced
// from hammers on 16 Sep 2026) and Background Pattern, each in a day file and
// a night file, and Welcome and Thank You, whose rainbow and gold are their
// own night files. An anonymous viewer owns none of them.
func TestTheSeededTablePicturesAreTheOwnersOwn(t *testing.T) {
	f := newFixture(t)
	pictures, err := f.tables.List(f.ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	const (
		day   = "https://drive.google.com/uc?export=download&id=1r26ntLyDxKVbu7NAcsAQ3P3Sh8qF-oN-"
		night = "https://drive.google.com/uc?export=download&id=1mBnzYABRNRvP7aaEOk2JrBdQC7Lw--fB"
	)
	const (
		patternDay   = "https://drive.google.com/uc?export=download&id=1SZ9uuV6AuJB5vYqjMmbRq0Qi7ILr7O3_"
		patternNight = "https://drive.google.com/uc?export=download&id=1jysl9afLqlbeIO1SS8ypASb1TQkUFl2C"
	)
	const (
		welcome  = "https://drive.google.com/uc?export=download&id=1iEyjVt07WkoblcgnX-DdWlqYp-Hsc3Wy"
		thankYou = "https://drive.google.com/uc?export=download&id=1Iowysv9_-BE4qont-qLkZRi3XhfF6uc4"
	)
	if len(pictures) != 4 {
		t.Fatalf("the seed lists %d table pictures, want 4", len(pictures))
	}
	lines, pattern, word, thanks := pictures[0], pictures[1], pictures[2], pictures[3]
	if lines.Name != "Lines Background" || lines.Currency != db.PictureCurrencyCoin || lines.Type != db.PicturePremium || lines.Cost != 10000 ||
		lines.DurationDays != 7 || lines.DurationHours != 0 || lines.AssetFormat != "LOTTIE" || lines.SortOrder != 75 ||
		lines.DayURL != day || lines.NightURL != night || lines.Owned || lines.ExpiresAt != 0 {
		t.Fatalf("the seeded Lines Background = %+v", lines)
	}
	if pattern.Name != "Background Pattern" || pattern.Currency != db.PictureCurrencyCoin || pattern.Type != db.PicturePremium || pattern.Cost != 500000 ||
		pattern.DurationDays != 7 || pattern.DurationHours != 0 || pattern.AssetFormat != "LOTTIE" || pattern.SortOrder != 80 ||
		pattern.DayURL != patternDay || pattern.NightURL != patternNight || pattern.Owned || pattern.ExpiresAt != 0 {
		t.Fatalf("the seeded Background Pattern = %+v", pattern)
	}
	// A rainbow reads on both grounds: the night file is the day file.
	if word.Name != "Welcome" || word.Currency != db.PictureCurrencyCoin || word.Type != db.PicturePremium || word.Cost != 100000 ||
		word.DurationDays != 2 || word.DurationHours != 0 || word.AssetFormat != "LOTTIE" || word.SortOrder != 85 ||
		word.DayURL != welcome || word.NightURL != welcome || word.Owned || word.ExpiresAt != 0 {
		t.Fatalf("the seeded Welcome = %+v", word)
	}
	// Gold reads on both grounds too: the night file is the day file.
	if thanks.Name != "Thank You" || thanks.Currency != db.PictureCurrencyCoin || thanks.Type != db.PicturePremium || thanks.Cost != 1000000 ||
		thanks.DurationDays != 10 || thanks.DurationHours != 0 || thanks.AssetFormat != "LOTTIE" || thanks.SortOrder != 90 ||
		thanks.DayURL != thankYou || thanks.NightURL != thankYou || thanks.Owned || thanks.ExpiresAt != 0 {
		t.Fatalf("the seeded Thank You = %+v", thanks)
	}
}

// A chip-priced table picture is bought as a profile picture is: one ledger
// row (reason table_picture_purchase, action_id table:<user>:<id>:1), a wallet
// delta that reconciles, an ownership row on the row's term; buying it again
// charges nothing. Laying it puts it on the wire user with both URLs; taking
// it off leaves null; a free one is laid without any purchase; and a lapsed
// rental is taken off by the sweep and bought afresh, with a second action id.
func TestAChipPricedTablePictureIsBoughtLaidAndRenewed(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	sapphire := tablePictureRow(t, f, "Royal Sapphire", db.PictureCurrencyCoin, db.PicturePremium, 50000, 7)
	baize := tablePictureRow(t, f, "Classic Baize", db.PictureCurrencyCoin, db.PictureFree, 0, 0)
	if !baize.Owned || !baize.Free() || sapphire.Owned {
		t.Fatalf("as listed anonymously: free %+v, premium %+v", baize, sapphire)
	}

	if user.TablePicture != nil {
		t.Fatalf("a new account has a table picture laid: %+v", user.TablePicture)
	}

	bought, err := f.tables.Buy(f.ctx, user.ID, sapphire.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !bought.Charged || bought.Spent != 50000 || bought.Balance != welcome-50000 || !bought.Picture.Owned || bought.Picture.ExpiresAt == 0 {
		t.Fatalf("purchase = %+v", bought)
	}
	if bought.User == nil || bought.User.Chips != welcome-50000 || bought.User.TablePicture != nil {
		t.Fatalf("the response user after a buy (not yet laid): %+v", bought.User)
	}
	rows := f.ledgerRows(user.ID)
	last := rows[len(rows)-1]
	if last.Reason != game.LedgerReasonTablePicturePurchase || last.Delta != -50000 || last.ActionID == nil ||
		*last.ActionID != "table:"+user.ID+":"+itoa(sapphire.ID)+":1" {
		t.Fatalf("the ledger row = %+v", last)
	}
	f.reconcile()
	span := f.scalar(`SELECT expires_at - acquired_at FROM user_table_pictures WHERE user_id = $1 AND table_picture_id = $2`, user.ID, sapphire.ID)
	if span != 7*db.DayMs {
		t.Fatalf("the rental spans %d ms, want 7 days", span)
	}

	again, err := f.tables.Buy(f.ctx, user.ID, sapphire.ID)
	if err != nil {
		t.Fatal(err)
	}
	if again.Charged || again.Spent != 0 || f.chips(user.ID) != welcome-50000 {
		t.Fatalf("a second buy charged: %+v, chips %d", again, f.chips(user.ID))
	}

	// Laid: the wire user carries the pair.
	laid, err := f.tables.Use(f.ctx, user.ID, &sapphire.ID)
	if err != nil {
		t.Fatal(err)
	}
	if laid.TablePicture == nil || laid.TablePicture.ID != sapphire.ID || laid.TablePicture.DayURL != sapphire.DayURL ||
		laid.TablePicture.NightURL != sapphire.NightURL || laid.TablePicture.AssetFormat != "SVG" {
		t.Fatalf("tablePicture after laying = %+v", laid.TablePicture)
	}
	if f.find(user.ID).TablePicture == nil {
		t.Fatal("FindByID does not carry the laid table picture")
	}

	// A free one needs no purchase, and replaces the choice.
	laid, err = f.tables.Use(f.ctx, user.ID, &baize.ID)
	if err != nil || laid.TablePicture == nil || laid.TablePicture.ID != baize.ID {
		t.Fatalf("laying the free picture: %v %+v", err, laid.TablePicture)
	}
	// Off again.
	bare, err := f.tables.Use(f.ctx, user.ID, nil)
	if err != nil || bare.TablePicture != nil || f.laid(user.ID) != 0 {
		t.Fatalf("taking the picture off: %v %+v", err, bare.TablePicture)
	}

	// Back on the rental, which then runs out: the sweep takes it off, the
	// listing shows it locked, and buying again is a fresh charge on a second
	// action id.
	if _, err := f.tables.Use(f.ctx, user.ID, &sapphire.ID); err != nil {
		t.Fatal(err)
	}
	if swept, err := f.tables.ExpireLapsed(f.ctx, user.ID); err != nil || swept {
		t.Fatalf("a running rental was swept: %v %v", swept, err)
	}
	if _, err := f.d.Pool.Exec(f.ctx,
		`UPDATE user_table_pictures SET expires_at = 1 WHERE user_id = $1 AND table_picture_id = $2`, user.ID, sapphire.ID); err != nil {
		t.Fatal(err)
	}
	if swept, err := f.tables.ExpireLapsed(f.ctx, user.ID); err != nil || !swept {
		t.Fatalf("the sweep left a lapsed rental laid: %v %v", swept, err)
	}
	if f.find(user.ID).TablePicture != nil || f.laid(user.ID) != 0 {
		t.Fatal("the lapsed picture is still laid")
	}
	relisted, _, err := f.tables.Find(f.ctx, user.ID, sapphire.ID)
	if err != nil || relisted.Owned || relisted.ExpiresAt != 0 {
		t.Fatalf("a lapsed rental still reads as owned: %v %+v", err, relisted)
	}
	renewed, err := f.tables.Buy(f.ctx, user.ID, sapphire.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !renewed.Charged || renewed.Spent != 50000 || f.chips(user.ID) != welcome-100000 {
		t.Fatalf("the renewal = %+v, chips %d", renewed, f.chips(user.ID))
	}
	rows = f.ledgerRows(user.ID)
	if got := *rows[len(rows)-1].ActionID; got != "table:"+user.ID+":"+itoa(sapphire.ID)+":2" {
		t.Fatalf("the renewal's action id = %s", got)
	}
	if n := f.scalar(`SELECT purchases FROM user_table_pictures WHERE user_id = $1 AND table_picture_id = $2`, user.ID, sapphire.ID); n != 2 {
		t.Fatalf("purchases = %d, want 2", n)
	}
	f.reconcile()
}

// A hammer-priced table picture debits users.hammer alone — no chips, no
// ledger row, no hammer_spends row — and a diamond-priced one users.diamond;
// both sell at a table, where a chip-priced one is refused with
// ErrPictureAtTable before anything moves. A wallet short of the price is the
// profile pictures' shortage, the hammer one carrying its price. (The seed
// sells nothing for hammers since the owner re-priced Lines Background in
// chips on 16 Sep 2026, so the hammer picture is a fixture row.)
func TestHammerAndDiamondTablePicturesLeaveTheChipsAloneAndSellAtATable(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	lines := tablePictureRow(t, f, "Carbon Weave", db.PictureCurrencyHammer, db.PicturePremium, 10, 30)
	purple := tablePictureRow(t, f, "Royal Purple", db.PictureCurrencyDiamond, db.PicturePremium, 5, 100)
	sapphire := tablePictureRow(t, f, "Royal Sapphire", db.PictureCurrencyCoin, db.PicturePremium, 50000, 7)
	ledgerRows := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1`, user.ID)

	// At a table: the chip picture is refused, the others sold.
	if _, err := f.tables.BuyAtTable(f.ctx, user.ID, sapphire.ID); !errors.Is(err, db.ErrPictureAtTable) {
		t.Fatalf("a chip-priced table picture at a table: %v, want ErrPictureAtTable", err)
	}
	hammers, err := f.tables.BuyAtTable(f.ctx, user.ID, lines.ID)
	if err != nil || !hammers.Charged || hammers.Spent != 10 || hammers.Balance != welcome {
		t.Fatalf("a hammer table picture at a table: %v %+v", err, hammers)
	}
	if hammers.Picture.ExpiresAt-now(t, f) > 30*db.DayMs || hammers.Picture.ExpiresAt < now(t, f)+29*db.DayMs {
		t.Fatalf("Lines Background rents for %d ms from now, want 30 days", hammers.Picture.ExpiresAt-now(t, f))
	}
	diamonds, err := f.tables.BuyAtTable(f.ctx, user.ID, purple.ID)
	if err != nil || !diamonds.Charged || diamonds.Spent != 5 || diamonds.Balance != welcome {
		t.Fatalf("a diamond table picture at a table: %v %+v", err, diamonds)
	}
	if f.hammersOf(user.ID) != 10 || f.diamondsOf(user.ID) != 4 || f.chips(user.ID) != welcome {
		t.Fatalf("wallets after the two buys: hammers %d, diamonds %d, chips %d", f.hammersOf(user.ID), f.diamondsOf(user.ID), f.chips(user.ID))
	}
	if got := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1`, user.ID); got != ledgerRows {
		t.Fatalf("a hammer or diamond table picture wrote %d ledger row(s)", got-ledgerRows)
	}
	if got := f.count(`SELECT COUNT(*) FROM hammer_spends WHERE user_id = $1`, user.ID); got != 0 {
		t.Fatalf("a table picture wrote %d hammer_spends row(s)", got)
	}
	if diamonds.User.Hammer != 10 || diamonds.User.Diamond != 4 {
		t.Fatalf("the response user after both buys: %+v", diamonds.User)
	}
	f.reconcile()

	// Short of every wallet: each refusal names its own.
	poor := newGuest(t, f)
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE users SET diamond = 0, hammer = 9, chips = 49999 WHERE id = $1`, poor.ID); err != nil {
		t.Fatal(err)
	}
	_, err = f.tables.Buy(f.ctx, poor.ID, lines.ID)
	var short *db.PictureHammerShortage
	if !errors.Is(err, db.ErrPictureHammers) || !errors.As(err, &short) || short.Cost != 10 {
		t.Fatalf("a hammer shortage: %v", err)
	}
	if _, err := f.tables.Buy(f.ctx, poor.ID, purple.ID); !errors.Is(err, db.ErrPictureDiamonds) {
		t.Fatalf("a diamond shortage: %v", err)
	}
	if _, err := f.tables.Buy(f.ctx, poor.ID, sapphire.ID); !errors.Is(err, db.ErrPictureChips) {
		t.Fatalf("a chip shortage: %v", err)
	}
	if f.count(`SELECT COUNT(*) FROM user_table_pictures WHERE user_id = $1`, poor.ID) != 0 {
		t.Fatal("a refused buy wrote an ownership row")
	}
}

// now is the fixture's clock as the store reads it, in epoch ms.
func now(t *testing.T, f *fixture) int64 {
	t.Helper()
	return f.scalar(`SELECT (EXTRACT(EPOCH FROM now()) * 1000)::bigint`)
}

// The refusals that need no wallet: an id that is not in the catalogue, a
// free row (nothing to sell), and a retired row — which is still laid by
// whoever had it, and still owned, but neither listed nor sold.
func TestATablePictureThatIsUnknownFreeOrRetiredIsRefused(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	baize := tablePictureRow(t, f, "Classic Baize", db.PictureCurrencyCoin, db.PictureFree, 0, 0)
	sapphire := tablePictureRow(t, f, "Royal Sapphire", db.PictureCurrencyCoin, db.PicturePremium, 50000, 7)

	if _, err := f.tables.Buy(f.ctx, user.ID, 987654); !errors.Is(err, db.ErrTablePictureUnknown) {
		t.Fatalf("an unknown id: %v", err)
	}
	if _, _, err := f.tables.Find(f.ctx, user.ID, 987654); !errors.Is(err, db.ErrTablePictureUnknown) {
		t.Fatalf("Find of an unknown id: %v", err)
	}
	if _, err := f.tables.Buy(f.ctx, user.ID, baize.ID); !errors.Is(err, db.ErrPictureFree) {
		t.Fatalf("buying a free table picture: %v", err)
	}

	// Bought and laid, then retired.
	if _, err := f.tables.Buy(f.ctx, user.ID, sapphire.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.tables.Use(f.ctx, user.ID, &sapphire.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE table_pictures SET is_active = FALSE WHERE id = $1`, sapphire.ID); err != nil {
		t.Fatal(err)
	}
	listed, err := f.tables.List(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range listed {
		if p.ID == sapphire.ID {
			t.Fatal("a retired table picture is still listed")
		}
	}
	found, active, err := f.tables.Find(f.ctx, user.ID, sapphire.ID)
	if err != nil || active || !found.Owned {
		t.Fatalf("Find of a retired, owned picture: %v active=%v %+v", err, active, found)
	}
	if _, err := f.tables.Buy(f.ctx, user.ID, sapphire.ID); !errors.Is(err, db.ErrPictureInactive) {
		t.Fatalf("buying a retired picture: %v", err)
	}
	if u := f.find(user.ID); u.TablePicture == nil || u.TablePicture.ID != sapphire.ID {
		t.Fatalf("retiring a picture took it off the table it was laid on: %+v", u.TablePicture)
	}
	// Deleting the row, though, clears the choice (ON DELETE CASCADE).
	if _, err := f.d.Pool.Exec(f.ctx, `DELETE FROM table_pictures WHERE id = $1`, sapphire.ID); err != nil {
		t.Fatal(err)
	}
	if u := f.find(user.ID); u.TablePicture != nil {
		t.Fatalf("a deleted catalogue row is still laid: %+v", u.TablePicture)
	}
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
