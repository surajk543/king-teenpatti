package db_test

import (
	"errors"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// is_listed (owner, 1 Oct 2026: "profile_pictures, table_pictures, emojis,
// badges in these tables also add one more column flag is_listed, by default
// it is true, if it is false, then user will not see these assets in UI or UI
// store"). An unlisted row leaves the catalogues the app draws its shelves and
// pickers from, for everybody but a player who already has it, and is sold to
// nobody. It takes nothing away from anyone, and a reward can still give it.

// pictureRow inserts one profile picture of the test's own and returns its id.
func pictureRow(t *testing.T, f *fixture, name, currency, kind string, cost int64, days int) int64 {
	t.Helper()
	var id int64
	if err := f.d.Pool.QueryRow(f.ctx,
		`INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, sort_order, created_at, updated_at)
		 VALUES ($1, $2, 'LOTTIE', $3, $4, $5, $6, 999, 0, 0) RETURNING id`,
		name, "https://drive.example/"+toSlug(name)+".json", currency, kind, cost, days).Scan(&id); err != nil {
		t.Fatalf("insert picture %s: %v", name, err)
	}
	return id
}

// setListed takes a row off the shelves, or puts it back, as an owner would
// by hand: by id, or by code for a badge.
func (f *fixture) setListed(table string, key any, listed bool) {
	f.t.Helper()
	column := "id"
	if table == "badges" {
		column = "code"
	}
	execSQL(f.t, f.d, `UPDATE `+table+` SET is_listed = $2 WHERE `+column+` = $1`, key, listed)
}

func TestEverySeededShelfRowIsListed(t *testing.T) {
	f := newFixture(t)
	for _, table := range []string{"profile_pictures", "table_pictures", "emojis", "badges"} {
		if n := f.count(`SELECT count(*) FROM ` + table); n == 0 {
			t.Errorf("the seed put no rows in %s to prove the DEFAULT on", table)
		}
		if n := f.count(`SELECT count(*) FROM ` + table + ` WHERE NOT is_listed`); n != 0 {
			t.Errorf("%d seeded rows of %s are unlisted; is_listed defaults to TRUE", n, table)
		}
	}
}

func TestAnUnlistedPictureIsShownOnlyToWhoeverHasItAndSoldToNobody(t *testing.T) {
	f := newFixture(t)
	owner, stranger, wearer := newGuest(t, f), newGuest(t, f), newGuest(t, f)
	premium := pictureRow(t, f, "Shelf Premium", db.PictureCurrencyCoin, db.PicturePremium, 1000, 0)
	rental := pictureRow(t, f, "Shelf Rental", db.PictureCurrencyCoin, db.PicturePremium, 1000, 3)
	free := pictureRow(t, f, "Shelf Free", db.PictureCurrencyCoin, db.PictureFree, 0, 0)

	for _, id := range []int64{premium, rental} {
		if bought, err := f.pictures.Buy(f.ctx, owner.ID, id); err != nil || !bought.Charged {
			t.Fatalf("buy %d before it was unlisted: %+v %v", id, bought, err)
		}
	}
	if _, err := f.users.SetActivePicture(f.ctx, wearer.ID, &free); err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{premium, rental, free} {
		f.setListed("profile_pictures", id, false)
	}

	shelf := func(viewer string) map[int64]db.Picture {
		t.Helper()
		all, err := f.pictures.List(f.ctx, viewer)
		if err != nil {
			t.Fatal(err)
		}
		out := map[int64]db.Picture{}
		for _, p := range all {
			out[p.ID] = p
		}
		return out
	}

	// Nobody else is shown any of the three, signed in or not; the listed
	// pictures are all still there.
	for who, viewer := range map[string]string{"an anonymous caller": "", "a stranger": stranger.ID} {
		got := shelf(viewer)
		for _, id := range []int64{premium, rental, free} {
			if _, ok := got[id]; ok {
				t.Errorf("%s is shown unlisted picture %d", who, id)
			}
		}
		if len(got) == 0 {
			t.Errorf("%s is shown no pictures at all", who)
		}
	}
	// The owner still has what they bought, as theirs, to wear again; a free
	// unlisted picture they neither own nor wear is hidden from them too.
	mine := shelf(owner.ID)
	if p, ok := mine[premium]; !ok || !p.Owned || p.ExpiresAt != 0 {
		t.Errorf("the owner's unlisted picture on their shelf: %+v %v", p, ok)
	}
	if p, ok := mine[rental]; !ok || !p.Owned || p.ExpiresAt <= nowMs() {
		t.Errorf("the owner's unlisted rental on their shelf: %+v %v", p, ok)
	}
	if _, ok := mine[free]; ok {
		t.Error("the owner is shown an unlisted free picture they do not wear")
	}
	// …and the player wearing the free one still finds it.
	if p, ok := shelf(wearer.ID)[free]; !ok || !p.Owned {
		t.Errorf("the wearer's unlisted free picture: %+v %v", p, ok)
	}

	// Sold to nobody, at a table or in the lobby, and nothing is charged.
	before := f.chips(stranger.ID)
	if _, err := f.pictures.Buy(f.ctx, stranger.ID, premium); !errors.Is(err, db.ErrPictureUnlisted) {
		t.Errorf("a stranger buying an unlisted picture: %v, want ErrPictureUnlisted", err)
	}
	if _, err := f.pictures.BuyAtTable(f.ctx, stranger.ID, premium); !errors.Is(err, db.ErrPictureUnlisted) {
		t.Errorf("a stranger buying an unlisted picture at a table: %v, want ErrPictureUnlisted", err)
	}
	if after := f.chips(stranger.ID); after != before {
		t.Errorf("a refused purchase moved the wallet: %d → %d", before, after)
	}
	// The owner's second tap is still the success the first was.
	if again, err := f.pictures.Buy(f.ctx, owner.ID, premium); err != nil || again.Charged {
		t.Errorf("the owner's second buy: %+v %v, want an uncharged success", again, err)
	}
	// Wearing it is unchanged: active and theirs.
	if found, active, err := f.pictures.Find(f.ctx, owner.ID, premium); err != nil || !active || !found.Owned {
		t.Errorf("the owner's unlisted picture as wear sees it: %+v active=%v %v", found, active, err)
	}
	if _, err := f.users.SetActivePicture(f.ctx, owner.ID, &premium); err != nil {
		t.Fatal(err)
	}

	// A rental that runs out leaves its owner's shelf as well, and is not
	// renewed: an unlisted picture sells nothing new.
	execSQL(t, f.d, `UPDATE user_profile_pictures SET expires_at = 1 WHERE user_id = $1 AND profile_picture_id = $2`, owner.ID, rental)
	if _, ok := shelf(owner.ID)[rental]; ok {
		t.Error("a lapsed rental of an unlisted picture is still on its owner's shelf")
	}
	if _, err := f.pictures.Buy(f.ctx, owner.ID, rental); !errors.Is(err, db.ErrPictureUnlisted) {
		t.Errorf("renewing a lapsed rental of an unlisted picture: %v, want ErrPictureUnlisted", err)
	}

	// Listed again, it is on everybody's shelf, and for sale.
	f.setListed("profile_pictures", premium, true)
	if p, ok := shelf("")[premium]; !ok || p.Owned {
		t.Errorf("the picture listed again, anonymously: %+v %v", p, ok)
	}
	if bought, err := f.pictures.Buy(f.ctx, stranger.ID, premium); err != nil || !bought.Charged {
		t.Errorf("buying it once it is listed again: %+v %v", bought, err)
	}
	f.reconcile()
}

func TestAnUnlistedTablePictureIsShownOnlyToWhoeverHasItAndSoldToNobody(t *testing.T) {
	f := newFixture(t)
	owner, stranger, layer := newGuest(t, f), newGuest(t, f), newGuest(t, f)
	premium := tablePictureRow(t, f, "Shelf Cloth", db.PictureCurrencyCoin, db.PicturePremium, 1000, 0)
	free := tablePictureRow(t, f, "Shelf Free Cloth", db.PictureCurrencyCoin, db.PictureFree, 0, 0)
	if bought, err := f.tables.Buy(f.ctx, owner.ID, premium.ID); err != nil || !bought.Charged {
		t.Fatalf("buy before it was unlisted: %+v %v", bought, err)
	}
	if _, err := f.tables.Use(f.ctx, layer.ID, &free.ID); err != nil {
		t.Fatal(err)
	}
	f.setListed("table_pictures", premium.ID, false)
	f.setListed("table_pictures", free.ID, false)

	shelf := func(viewer string) map[int64]db.TablePicture {
		t.Helper()
		all, err := f.tables.List(f.ctx, viewer)
		if err != nil {
			t.Fatal(err)
		}
		out := map[int64]db.TablePicture{}
		for _, p := range all {
			out[p.ID] = p
		}
		return out
	}
	for who, viewer := range map[string]string{"an anonymous caller": "", "a stranger": stranger.ID} {
		got := shelf(viewer)
		if _, ok := got[premium.ID]; ok {
			t.Errorf("%s is shown the unlisted table picture", who)
		}
		if _, ok := got[free.ID]; ok {
			t.Errorf("%s is shown the unlisted free table picture", who)
		}
	}
	if p, ok := shelf(owner.ID)[premium.ID]; !ok || !p.Owned {
		t.Errorf("the owner's unlisted table picture on their shelf: %+v %v", p, ok)
	}
	if p, ok := shelf(layer.ID)[free.ID]; !ok || !p.Owned {
		t.Errorf("the unlisted free table picture laid on a player's table, on their shelf: %+v %v", p, ok)
	}

	if _, err := f.tables.Buy(f.ctx, stranger.ID, premium.ID); !errors.Is(err, db.ErrPictureUnlisted) {
		t.Errorf("a stranger buying an unlisted table picture: %v, want ErrPictureUnlisted", err)
	}
	if _, err := f.tables.BuyAtTable(f.ctx, stranger.ID, premium.ID); !errors.Is(err, db.ErrPictureUnlisted) {
		t.Errorf("a stranger buying an unlisted table picture at a table: %v, want ErrPictureUnlisted", err)
	}
	if again, err := f.tables.Buy(f.ctx, owner.ID, premium.ID); err != nil || again.Charged {
		t.Errorf("the owner's second buy: %+v %v, want an uncharged success", again, err)
	}
	// The owner still lays it: what the lay route checks is active and theirs.
	if found, active, err := f.tables.Find(f.ctx, owner.ID, premium.ID); err != nil || !active || !found.Owned {
		t.Errorf("the owner's unlisted table picture as the lay route sees it: %+v active=%v %v", found, active, err)
	}
	// Taken off the table, the unlisted free picture leaves that player's shelf.
	if _, err := f.tables.Use(f.ctx, layer.ID, nil); err != nil {
		t.Fatal(err)
	}
	if _, ok := shelf(layer.ID)[free.ID]; ok {
		t.Error("an unlisted free table picture no longer laid is still on the player's shelf")
	}
	f.reconcile()
}

func TestAnUnlistedEmojiStaysWithItsOwnersWhoStillSendIt(t *testing.T) {
	f := newFixture(t)
	emojis := f.emojiStore()
	owner, stranger := newGuest(t, f), newGuest(t, f)
	premium := emojiRow(t, f, "Shelf Wink", db.PictureCurrencyCoin, db.PicturePremium, 1000, 0, 0, 1)
	free := emojiRow(t, f, "Shelf Wave", db.PictureCurrencyCoin, db.PictureFree, 0, 0, 0, 2)
	if bought, err := emojis.Buy(f.ctx, owner.ID, premium); err != nil || !bought.Charged {
		t.Fatalf("buy before it was unlisted: %+v %v", bought, err)
	}
	f.setListed("emojis", premium, false)
	f.setListed("emojis", free, false)

	shelf := func(viewer string) map[int64]db.Emoji {
		t.Helper()
		all, err := emojis.List(f.ctx, viewer)
		if err != nil {
			t.Fatal(err)
		}
		out := map[int64]db.Emoji{}
		for _, e := range all {
			out[e.ID] = e
		}
		return out
	}
	for who, viewer := range map[string]string{"an anonymous caller": "", "a stranger": stranger.ID, "the owner": owner.ID} {
		if _, ok := shelf(viewer)[free]; ok {
			t.Errorf("%s is shown the unlisted free emoji", who)
		}
	}
	for who, viewer := range map[string]string{"an anonymous caller": "", "a stranger": stranger.ID} {
		if _, ok := shelf(viewer)[premium]; ok {
			t.Errorf("%s is shown the unlisted emoji", who)
		}
	}
	if e, ok := shelf(owner.ID)[premium]; !ok || !e.Owned {
		t.Errorf("the owner's unlisted emoji on their shelf: %+v %v", e, ok)
	}

	// Its owner still sends it; a stranger still may not.
	if _, err := emojis.Owns(f.ctx, owner.ID, premium); err != nil {
		t.Errorf("the owner sending an unlisted emoji: %v", err)
	}
	if _, err := emojis.Owns(f.ctx, stranger.ID, premium); !errors.Is(err, db.ErrEmojiLocked) {
		t.Errorf("a stranger sending an unlisted emoji: %v, want ErrEmojiLocked", err)
	}
	// Sold to nobody, at a table or in the lobby.
	if _, err := emojis.Buy(f.ctx, stranger.ID, premium); !errors.Is(err, db.ErrEmojiUnlisted) {
		t.Errorf("a stranger buying an unlisted emoji: %v, want ErrEmojiUnlisted", err)
	}
	if _, err := emojis.BuyAtTable(f.ctx, stranger.ID, premium); !errors.Is(err, db.ErrEmojiUnlisted) {
		t.Errorf("a stranger buying an unlisted emoji at a table: %v, want ErrEmojiUnlisted", err)
	}
	if again, err := emojis.Buy(f.ctx, owner.ID, premium); err != nil || again.Charged {
		t.Errorf("the owner's second buy: %+v %v, want an uncharged success", again, err)
	}
	f.reconcile()
}

func TestAnUnlistedBadgeLeavesTheCatalogueButNotItsHolders(t *testing.T) {
	f := newFixture(t)
	holder := newGuest(t, f)
	f.grant(holder.ID, "ROYAL_KING")
	f.setListed("badges", "ROYAL_KING", false)

	codes := func() map[string]bool {
		t.Helper()
		ladder, err := db.NewXP(f.d, nil).Ladder(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]bool{}
		for _, b := range ladder.Badges {
			out[b.Code] = true
		}
		return out
	}
	// Out of the catalogue the store and the level screen draw, the others in it.
	if got := codes(); got["ROYAL_KING"] || !got["REGULAR"] || !got["ROYAL_ACE"] {
		t.Errorf("the catalogue with ROYAL_KING unlisted: %v", got)
	}
	// Its holder still holds it — its rate and its art come with the account.
	user := f.find(holder.ID)
	held := false
	for _, b := range user.Badges {
		if b.Code == "ROYAL_KING" {
			held = b.AssetURL != ""
		}
	}
	if !held || user.TaxBps != 0 {
		t.Errorf("the holder of an unlisted badge: badges %+v, tax %d bps; want it held, with its art, at 0%%", user.Badges, user.TaxBps)
	}
	// A Play purchase made while it was listed still finds it to grant.
	if product, ok, err := db.BadgeForProduct(f.ctx, f.d, "badge_royal_king_999"); err != nil || !ok || product.Code != "ROYAL_KING" {
		t.Errorf("the unlisted badge's Play product: %+v %v %v", product, ok, err)
	}
	f.setListed("badges", "ROYAL_KING", true)
	if !codes()["ROYAL_KING"] {
		t.Error("the badge listed again is not back in the catalogue")
	}
}

// An unlisted item is a prize no store sells: the welcome (and the Lucky Draw
// and the reward programs, through the same grant) still gives it, and the
// player it was given to finds it on their shelf.
func TestAnUnlistedItemCanStillBeGivenAsAPrize(t *testing.T) {
	f := newFixture(t)
	// An account from before the prize was set up, so the welcome gave it none.
	other := newGuest(t, f)
	execSQL(t, f.d, `UPDATE profile_pictures SET is_listed = FALSE WHERE name = 'Lovestruck Cat'`)
	execSQL(t, f.d, `UPDATE emojis SET is_listed = FALSE WHERE name = 'Clapping Hands'`)
	execSQL(t, f.d, `INSERT INTO welcome_rewards (code, reward_type, reward_ref_id, sort_order) VALUES
		('exclusive_picture', 'PROFILE_PICTURE', (SELECT id::text FROM profile_pictures WHERE name = 'Lovestruck Cat'), 50),
		('exclusive_emoji', 'EMOJI', (SELECT id::text FROM emojis WHERE name = 'Clapping Hands'), 70)`)

	res := signIn(t, f.users, "Exclusive")
	if g := res.Welcome; len(g.Pictures) != 1 || len(g.Emojis) != 1 || !g.Pictures[0].Owned || !g.Emojis[0].Owned {
		t.Fatalf("the welcome's unlisted items: %+v", g)
	}
	picture, emoji := res.Welcome.Pictures[0].ID, res.Welcome.Emojis[0].ID

	onShelf := func(viewer string) (bool, bool) {
		t.Helper()
		pictures, err := f.pictures.List(f.ctx, viewer)
		if err != nil {
			t.Fatal(err)
		}
		emojis, err := f.emojiStore().List(f.ctx, viewer)
		if err != nil {
			t.Fatal(err)
		}
		var p, e bool
		for _, x := range pictures {
			p = p || (x.ID == picture && x.Owned)
		}
		for _, x := range emojis {
			e = e || (x.ID == emoji && x.Owned)
		}
		return p, e
	}
	if p, e := onShelf(res.User.ID); !p || !e {
		t.Errorf("the winner's shelves: picture %v, emoji %v; want both, owned", p, e)
	}
	if p, e := onShelf(other.ID); p || e {
		t.Errorf("another player's shelves: picture %v, emoji %v; want neither", p, e)
	}
	if _, err := f.emojiStore().Owns(f.ctx, res.User.ID, emoji); err != nil {
		t.Errorf("the winner sending the unlisted emoji: %v", err)
	}
	f.reconcile()
}
