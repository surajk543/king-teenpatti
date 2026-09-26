package db_test

import (
	"encoding/json"
	"errors"
	"sync"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// The emoji store (owner, 26 Sep 2026): the profile-picture catalogue again,
// for an animated emoji a player SENDS to their table rather than wears. The
// seed holds no emoji — the owner supplies them — so every rule is proven on
// rows of the test's own.

func (f *fixture) emojiStore() *db.Emojis {
	return db.NewEmojis(f.d, f.users, nil)
}

// emojiRow inserts one catalogue row and returns its id. hours is the rental's
// hours on top of days; both 0 is for ever.
func emojiRow(t *testing.T, f *fixture, name, currency, kind string, cost int64, days, hours, sortOrder int) int64 {
	t.Helper()
	var id int64
	if err := f.d.Pool.QueryRow(f.ctx,
		`INSERT INTO emojis (name, asset_url, currency, type, cost, duration_days, duration_hours, sort_order, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 0, 0) RETURNING id`,
		name, "https://drive.example/"+toSlug(name)+".json", currency, kind, cost, days, hours, sortOrder).Scan(&id); err != nil {
		t.Fatalf("insert emoji %s: %v", name, err)
	}
	return id
}

// hammersOf is in hammers_test.go; diamondsOf in missiles_test.go.

// withoutSeededEmojis takes the owner's seeded emojis (V1.0.1__seed.sql, THE
// EMOJIS) out of a fresh schema, for a test that builds its own catalogue
// and counts it. Nobody owns one yet, so nothing else goes with them.
func withoutSeededEmojis(t *testing.T, f *fixture) {
	t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, `DELETE FROM emojis`); err != nil {
		t.Fatal(err)
	}
}

// The seed is the owner's own art (26 Sep 2026: "use this Lottie emoji,
// validity 30 days, cost 5 Hammer", then six more at "same price same
// validity"): sixteen Drive-hosted Lotties at 5 hammers for 30 days each, in
// the order they were given and owned by nobody.
func TestTheSeededEmojisAreTheOwnersSixteenAtFiveHammersForThirtyDays(t *testing.T) {
	f := newFixture(t)
	listed, err := f.emojiStore().List(f.ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	want := []struct{ name, driveID string }{
		{"Angry", "19CkeJfl8J9knw0tLoxgruKFaGwnsP3jh"},
		{"Dollar", "1HZej1y15g4FhGKjNPbR2WOqFdDXn-r5l"},
		{"Crying", "1iTOgg_JZRXvY9f9IRPaAR9UyEt4q7f4S"},
		{"Hi Face", "1qpBgQTwXWMvrHqQLAA6wT1EIsNb9zakr"},
		{"Clapping Hands", "1_wnZ9Tmiy7qnK7EzmK5hpSPZCOTxvjlc"},
		{"Cowboy Hat Face", "141HlEZZxoRuIzAaN16emiNO7UZ7RWYNn"},
		{"Muscle", "199f59nq4Vx0FImGvbAv4X2LJnkyUQ67f"},
		{"Plane Face", "1Y3WEnboXZskv6vItBQ_E1WZoC9aIUh8D"},
		{"Knife", "1lLryjoIf2KNGqZFGxGX8vGThozJM0vw-"},
		{"Sleeping", "1bC-1hqYUblHCjiTvAd6OT8xHYYbj9sKC"},
		{"Squinting Face with Tongue", "1MwoBkG2OIUbHVwu_Jrp4d1VjsJyPb9Y7"},
		{"Crying Face", "1NbIZ7Uix45KCEencp5cvX6aDisiEfhqi"},
		{"Enraged Face", "1C_zU11KCYX8vaGC04TQgC68cE2TYXHWt"},
		{"Chill Face", "1kvwY307kfud4L9SjaZCLzO0mLOZ9pRYR"},
		{"Face Blowing a Kiss", "1K7mIif6FpaHl06j1VFkPB8awW21zz-wf"},
		{"Kiss Face", "1oLtnFWg0dd75cuPebF5i0IHuynRnJlp2"},
	}
	if len(listed) != len(want) {
		t.Fatalf("the seeded catalogue holds %d emojis, want %d: %+v", len(listed), len(want), listed)
	}
	for i, w := range want {
		e := listed[i]
		if e.Name != w.name || e.URL != "https://drive.google.com/uc?export=download&id="+w.driveID ||
			e.AssetFormat != db.EmojiFormatLottie || e.Currency != db.PictureCurrencyHammer || e.Type != db.PicturePremium ||
			e.Cost != 5 || e.DurationDays != 30 || e.DurationHours != 0 || e.SortOrder != (i+1)*10 || e.Owned || e.ExpiresAt != 0 {
			t.Errorf("seeded emoji %d = %+v, want %s at 5 hammers for 30 days", i, e, w.name)
		}
	}
}

func TestTheEmojiCatalogueListsEachRowWithWhetherThisViewerOwnsIt(t *testing.T) {
	f := newFixture(t)
	store := f.emojiStore()
	withoutSeededEmojis(t, f)

	// An empty catalogue lists as [] — never null — so the wire reads
	// {"emojis": []}.
	empty, err := store.List(f.ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if raw, _ := json.Marshal(empty); string(raw) != "[]" {
		t.Fatalf("an empty catalogue marshals to %s, want []", raw)
	}

	// Listed by sort_order, then id; a retired row is left out.
	laughing := emojiRow(t, f, "Laughing", db.PictureCurrencyDiamond, db.PicturePremium, 5, 0, 0, 10)
	wave := emojiRow(t, f, "Wave", db.PictureCurrencyCoin, db.PictureFree, 0, 0, 0, 20)
	heart := emojiRow(t, f, "Heart", db.PictureCurrencyCoin, db.PicturePremium, 50000, 7, 0, 10)
	retired := emojiRow(t, f, "Retired", db.PictureCurrencyHammer, db.PicturePremium, 3, 0, 0, 5)
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE emojis SET is_active = FALSE WHERE id = $1`, retired); err != nil {
		t.Fatal(err)
	}

	anonymous, err := store.List(f.ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(anonymous) != 3 || anonymous[0].ID != laughing || anonymous[1].ID != heart || anonymous[2].ID != wave {
		t.Fatalf("the anonymous listing = %+v, want Laughing, Heart (sort 10, by id), Wave (20), and no retired row", anonymous)
	}
	first := anonymous[0]
	if first.Name != "Laughing" || first.URL != "https://drive.example/laughing.json" || first.AssetFormat != db.EmojiFormatLottie ||
		first.Currency != db.PictureCurrencyDiamond || first.Type != db.PicturePremium || first.Cost != 5 ||
		first.DurationDays != 0 || first.DurationHours != 0 || first.SortOrder != 10 || first.Owned || first.ExpiresAt != 0 {
		t.Fatalf("the Laughing row = %+v", first)
	}
	// Free is owned by everyone, anonymous callers included; premium by nobody.
	if !anonymous[2].Owned || anonymous[1].Owned {
		t.Fatalf("anonymously: free owned=%v, premium owned=%v", anonymous[2].Owned, anonymous[1].Owned)
	}
	// The JSON is the contract's, key for key.
	raw, _ := json.Marshal(first)
	want := `{"id":` + itoa(laughing) + `,"name":"Laughing","url":"https://drive.example/laughing.json","assetFormat":"LOTTIE",` +
		`"currency":"DIAMOND","type":"PREMIUM","cost":5,"durationDays":0,"durationHours":0,"sortOrder":10,"owned":false,"expiresAt":0}`
	if string(raw) != want {
		t.Fatalf("an emoji row on the wire:\n %s\nwant\n %s", raw, want)
	}

	// A buyer sees their own: the rental with its expiry, a for-ever one with 0.
	user := newGuest(t, f)
	if _, err := store.Buy(f.ctx, user.ID, heart); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Buy(f.ctx, user.ID, laughing); err != nil {
		t.Fatal(err)
	}
	mine, err := store.List(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !mine[0].Owned || mine[0].ExpiresAt != 0 || !mine[1].Owned || mine[1].ExpiresAt <= nowMs() || !mine[2].Owned {
		t.Fatalf("the buyer's listing = %+v", mine)
	}
	// Somebody else still owns neither.
	other, err := store.List(f.ctx, newGuest(t, f).ID)
	if err != nil {
		t.Fatal(err)
	}
	if other[0].Owned || other[1].Owned || !other[2].Owned {
		t.Fatalf("another player's listing = %+v", other)
	}
}

// A chip-priced emoji is bought as a picture is: one chip_ledger row (reason
// emoji_purchase, action_id emoji:<user>:<id>:1, delta -cost) and a wallet
// delta that reconcile, an ownership row on the row's term; buying it again
// while it runs charges nothing; once it lapses it is locked, and buying again
// renews it from now on a second action id.
func TestAChipPricedEmojiIsBoughtOnceThroughTheLedgerAndRenewedWhenItLapses(t *testing.T) {
	f := newFixture(t)
	store := f.emojiStore()
	user := newGuest(t, f)
	heart := emojiRow(t, f, "Heart", db.PictureCurrencyCoin, db.PicturePremium, 50000, 7, 12, 10)

	if _, err := store.Owns(f.ctx, user.ID, heart); !errors.Is(err, db.ErrEmojiLocked) {
		t.Fatalf("an unbought premium emoji: %v, want ErrEmojiLocked", err)
	}
	bought, err := store.Buy(f.ctx, user.ID, heart)
	if err != nil {
		t.Fatal(err)
	}
	if !bought.Charged || bought.Spent != 50000 || bought.Balance != welcome-50000 || !bought.Emoji.Owned || bought.Emoji.ExpiresAt == 0 {
		t.Fatalf("purchase = %+v", bought)
	}
	if bought.User == nil || bought.User.Chips != welcome-50000 || bought.User.Diamond != 9 || bought.User.Hammer != 20 {
		t.Fatalf("the response user after a chip buy: %+v", bought.User)
	}
	rows := f.ledgerRows(user.ID)
	last := rows[len(rows)-1]
	if game.LedgerReasonEmojiPurchase != "emoji_purchase" || last.Reason != game.LedgerReasonEmojiPurchase || last.Delta != -50000 ||
		last.Balance != welcome-50000 || last.HandID != nil || last.ActionID == nil || *last.ActionID != "emoji:"+user.ID+":"+itoa(heart)+":1" {
		t.Fatalf("the ledger row = %+v", last)
	}
	f.reconcile()
	if span := f.scalar(`SELECT expires_at - acquired_at FROM user_emojis WHERE user_id = $1 AND emoji_id = $2`, user.ID, heart); span != 7*db.DayMs+12*db.HourMs {
		t.Fatalf("the rental spans %d ms, want 7 days 12 hours", span)
	}
	sent, err := store.Owns(f.ctx, user.ID, heart)
	if err != nil || sent.ID != heart || sent.Name != "Heart" || sent.ForChat() != (game.ChatEmoji{ID: heart, Name: "Heart", URL: "https://drive.example/heart.json", AssetFormat: "LOTTIE"}) {
		t.Fatalf("Owns after the buy: %+v %v", sent, err)
	}

	// Again while it runs: success, nothing moved, no second row.
	again, err := store.Buy(f.ctx, user.ID, heart)
	if err != nil || again.Charged || again.Spent != 0 || again.User == nil || f.chips(user.ID) != welcome-50000 {
		t.Fatalf("a second buy: %+v %v, chips %d", again, err, f.chips(user.ID))
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE reason = 'emoji_purchase' AND user_id = $1`, user.ID); n != 1 {
		t.Fatalf("%d emoji_purchase rows after a second buy, want 1", n)
	}

	// Lapsed: locked for sending and shown unowned, before any sweep (there
	// is none) — the expiry is tested in every read.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE user_emojis SET expires_at = 1 WHERE user_id = $1 AND emoji_id = $2`, user.ID, heart); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Owns(f.ctx, user.ID, heart); !errors.Is(err, db.ErrEmojiLocked) {
		t.Fatalf("a lapsed rental: %v, want ErrEmojiLocked", err)
	}
	if found, active, err := store.Find(f.ctx, user.ID, heart); err != nil || !active || found.Owned || found.ExpiresAt != 0 {
		t.Fatalf("a lapsed rental reads %+v active=%v %v", found, active, err)
	}
	renewed, err := store.Buy(f.ctx, user.ID, heart)
	if err != nil || !renewed.Charged || renewed.Spent != 50000 || f.chips(user.ID) != welcome-100000 || renewed.Emoji.ExpiresAt <= nowMs() {
		t.Fatalf("the renewal = %+v %v, chips %d", renewed, err, f.chips(user.ID))
	}
	rows = f.ledgerRows(user.ID)
	if got := *rows[len(rows)-1].ActionID; got != "emoji:"+user.ID+":"+itoa(heart)+":2" {
		t.Fatalf("the renewal's action id = %s", got)
	}
	if n := f.scalar(`SELECT purchases FROM user_emojis WHERE user_id = $1 AND emoji_id = $2`, user.ID, heart); n != 2 {
		t.Fatalf("purchases = %d, want 2", n)
	}
	if _, err := store.Owns(f.ctx, user.ID, heart); err != nil {
		t.Fatalf("the renewed emoji cannot be sent: %v", err)
	}
	f.reconcile()
}

// Eight taps at once on the same chip-priced emoji charge once: the wallet
// lock serialises them and every one after the first finds it owned.
func TestEightSimultaneousBuysOfOneEmojiChargeOnce(t *testing.T) {
	f := newFixture(t)
	store := f.emojiStore()
	user := newGuest(t, f)
	heart := emojiRow(t, f, "Heart", db.PictureCurrencyCoin, db.PicturePremium, 30000, 0, 0, 10)

	var wg sync.WaitGroup
	var mu sync.Mutex
	charged := 0
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			out, err := store.Buy(f.ctx, user.ID, heart)
			if err != nil {
				t.Errorf("a concurrent buy: %v", err)
				return
			}
			if out.Charged {
				mu.Lock()
				charged++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if charged != 1 || f.chips(user.ID) != welcome-30000 {
		t.Fatalf("%d of 8 taps charged, chips %d", charged, f.chips(user.ID))
	}
	f.reconcile()
}

// A diamond-priced emoji debits users.diamond and a hammer-priced one
// users.hammer — no chips, no ledger row, no hammer_spends row — and both sell
// at a table, where a chip-priced one is refused ErrEmojiAtTable before
// anything moves. A wallet short of the price is an *EmojiShortage naming the
// wallet and the price.
func TestDiamondAndHammerEmojisLeaveTheChipsAloneAndSellAtATable(t *testing.T) {
	f := newFixture(t)
	store := f.emojiStore()
	user := newGuest(t, f)
	laughing := emojiRow(t, f, "Laughing", db.PictureCurrencyDiamond, db.PicturePremium, 5, 0, 0, 10)
	hammerTime := emojiRow(t, f, "Hammer Time", db.PictureCurrencyHammer, db.PicturePremium, 12, 30, 0, 20)
	heart := emojiRow(t, f, "Heart", db.PictureCurrencyCoin, db.PicturePremium, 50000, 7, 0, 30)
	ledgerRows := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1`, user.ID)

	if _, err := store.BuyAtTable(f.ctx, user.ID, heart); !errors.Is(err, db.ErrEmojiAtTable) {
		t.Fatalf("a chip-priced emoji at a table: %v, want ErrEmojiAtTable", err)
	}
	if f.chips(user.ID) != welcome || f.count(`SELECT COUNT(*) FROM user_emojis WHERE user_id = $1`, user.ID) != 0 {
		t.Fatal("a refused chip buy at a table moved something")
	}
	diamonds, err := store.BuyAtTable(f.ctx, user.ID, laughing)
	if err != nil || !diamonds.Charged || diamonds.Spent != 5 || diamonds.Balance != welcome || diamonds.Emoji.ExpiresAt != 0 {
		t.Fatalf("a diamond emoji at a table: %v %+v", err, diamonds)
	}
	hammers, err := store.BuyAtTable(f.ctx, user.ID, hammerTime)
	if err != nil || !hammers.Charged || hammers.Spent != 12 || hammers.Balance != welcome {
		t.Fatalf("a hammer emoji at a table: %v %+v", err, hammers)
	}
	if left := hammers.Emoji.ExpiresAt - nowMs(); left > 30*db.DayMs || left < 30*db.DayMs-60000 {
		t.Fatalf("Hammer Time rents for %d ms from now, want 30 days", left)
	}
	if f.diamondsOf(user.ID) != 4 || f.hammersOf(user.ID) != 8 || f.chips(user.ID) != welcome {
		t.Fatalf("wallets after the two buys: diamonds %d, hammers %d, chips %d", f.diamondsOf(user.ID), f.hammersOf(user.ID), f.chips(user.ID))
	}
	if hammers.User.Diamond != 4 || hammers.User.Hammer != 8 {
		t.Fatalf("the response user after both buys: %+v", hammers.User)
	}
	if got := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1`, user.ID); got != ledgerRows {
		t.Fatalf("a diamond or hammer emoji wrote %d ledger row(s)", got-ledgerRows)
	}
	if got := f.count(`SELECT COUNT(*) FROM hammer_spends WHERE user_id = $1`, user.ID); got != 0 {
		t.Fatalf("an emoji wrote %d hammer_spends row(s)", got)
	}
	f.reconcile()

	// Short of every wallet: each refusal names its own, with the price.
	poor := newGuest(t, f)
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE users SET diamond = 4, hammer = 11 WHERE id = $1`, poor.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE emojis SET cost = 250000 WHERE id = $1`, heart); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		id       int64
		currency string
		cost     int64
	}{{laughing, db.PictureCurrencyDiamond, 5}, {hammerTime, db.PictureCurrencyHammer, 12}, {heart, db.PictureCurrencyCoin, 250000}} {
		_, err := store.Buy(f.ctx, poor.ID, c.id)
		var short *db.EmojiShortage
		if !errors.Is(err, db.ErrEmojiUnaffordable) || !errors.As(err, &short) || short.Currency != c.currency || short.Cost != c.cost {
			t.Fatalf("a %s shortage: %v", c.currency, err)
		}
	}
	if f.count(`SELECT COUNT(*) FROM user_emojis WHERE user_id = $1`, poor.ID) != 0 || f.diamondsOf(poor.ID) != 4 ||
		f.hammersOf(poor.ID) != 11 || f.chips(poor.ID) != welcome {
		t.Fatal("a refused buy moved something")
	}
	f.reconcile()
}

// The refusals that need no wallet, for a buy and for a send: an id that is not
// in the catalogue, a free row (nothing to sell, and anyone may send it), a
// retired row (neither sold nor sent, though its ownership row stays), and a
// deleted account (no wallet to charge).
func TestAnEmojiThatIsUnknownFreeOrRetiredIsRefusedToBuyAndToSend(t *testing.T) {
	f := newFixture(t)
	withoutSeededEmojis(t, f)
	store := f.emojiStore()
	user := newGuest(t, f)
	wave := emojiRow(t, f, "Wave", db.PictureCurrencyCoin, db.PictureFree, 0, 0, 0, 10)
	heart := emojiRow(t, f, "Heart", db.PictureCurrencyDiamond, db.PicturePremium, 2, 0, 0, 20)

	if _, err := store.Buy(f.ctx, user.ID, 987654); !errors.Is(err, db.ErrEmojiUnknown) {
		t.Fatalf("buying an unknown id: %v", err)
	}
	if _, err := store.Owns(f.ctx, user.ID, 987654); !errors.Is(err, db.ErrEmojiUnknown) {
		t.Fatalf("sending an unknown id: %v", err)
	}
	if _, _, err := store.Find(f.ctx, user.ID, 987654); !errors.Is(err, db.ErrEmojiUnknown) {
		t.Fatalf("Find of an unknown id: %v", err)
	}
	if _, err := store.Buy(f.ctx, user.ID, wave); !errors.Is(err, db.ErrEmojiFree) {
		t.Fatalf("buying a free emoji: %v", err)
	}
	if sent, err := store.Owns(f.ctx, user.ID, wave); err != nil || sent.ID != wave {
		t.Fatalf("a free emoji cannot be sent: %+v %v", sent, err)
	}
	if n := f.count(`SELECT COUNT(*) FROM user_emojis WHERE user_id = $1`, user.ID); n != 0 {
		t.Fatalf("a free emoji wrote %d ownership row(s)", n)
	}

	// Bought, then retired: not sold, not sent, not listed — and still owned.
	if _, err := store.Buy(f.ctx, user.ID, heart); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE emojis SET is_active = FALSE WHERE id = $1`, heart); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Buy(f.ctx, user.ID, heart); !errors.Is(err, db.ErrEmojiInactive) {
		t.Fatalf("buying a retired emoji: %v", err)
	}
	if _, err := store.Owns(f.ctx, user.ID, heart); !errors.Is(err, db.ErrEmojiInactive) {
		t.Fatalf("sending a retired emoji: %v", err)
	}
	if found, active, err := store.Find(f.ctx, user.ID, heart); err != nil || active || !found.Owned {
		t.Fatalf("Find of a retired, owned emoji: %v active=%v %+v", err, active, found)
	}
	listed, err := store.List(f.ctx, user.ID)
	if err != nil || len(listed) != 1 || listed[0].ID != wave {
		t.Fatalf("the listing after retiring: %+v %v", listed, err)
	}
	// A retired FREE emoji is not sent either.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE emojis SET is_active = FALSE WHERE id = $1`, wave); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Owns(f.ctx, user.ID, wave); !errors.Is(err, db.ErrEmojiInactive) {
		t.Fatalf("sending a retired free emoji: %v", err)
	}

	// A deleted account has no wallet to charge.
	gone := newGuest(t, f)
	if err := f.users.DeleteAccount(f.ctx, gone.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE emojis SET is_active = TRUE WHERE id = $1`, heart); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Buy(f.ctx, gone.ID, heart); codeOf(t, err) != game.CodeUnknownUser {
		t.Fatalf("a deleted account buying: %v", err)
	}
	f.reconcile()
}

// The schema holds the contract's rules itself: an emoji is a Lottie, a free
// one costs nothing and a premium one something, the currencies are the three
// the pictures use, and the asset URL is the row's natural key.
func TestTheEmojiTableRefusesARowThatBreaksItsRules(t *testing.T) {
	f := newFixture(t)
	for name, sql := range map[string]string{
		"a format other than LOTTIE": `INSERT INTO emojis (name, asset_url, asset_format, created_at, updated_at) VALUES ('x', '/a.svg', 'SVG', 0, 0)`,
		"a free emoji with a price":  `INSERT INTO emojis (name, asset_url, type, cost, created_at, updated_at) VALUES ('x', '/b.json', 'FREE', 5, 0, 0)`,
		"a premium emoji for free":   `INSERT INTO emojis (name, asset_url, type, cost, created_at, updated_at) VALUES ('x', '/c.json', 'PREMIUM', 0, 0, 0)`,
		"an unknown currency":        `INSERT INTO emojis (name, asset_url, type, currency, cost, created_at, updated_at) VALUES ('x', '/d.json', 'PREMIUM', 'GOLD', 5, 0, 0)`,
		"a negative term":            `INSERT INTO emojis (name, asset_url, duration_days, created_at, updated_at) VALUES ('x', '/e.json', -1, 0, 0)`,
	} {
		if _, err := f.d.Pool.Exec(f.ctx, sql); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
	// The defaults make a free, for-ever Lottie paid (nominally) in COIN.
	id := f.scalar(`INSERT INTO emojis (name, asset_url, created_at, updated_at) VALUES ('Plain', '/plain.json', 0, 0) RETURNING id`)
	found, active, err := f.emojiStore().Find(f.ctx, "", id)
	if err != nil || !active || found.AssetFormat != "LOTTIE" || found.Type != db.PictureFree || found.Currency != db.PictureCurrencyCoin ||
		found.Cost != 0 || found.DurationDays != 0 || found.DurationHours != 0 || !found.Owned {
		t.Fatalf("a row of defaults = %+v active=%v %v", found, active, err)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO emojis (name, asset_url, created_at, updated_at) VALUES ('Again', '/plain.json', 0, 0)`); err == nil {
		t.Error("a second row on the same asset_url was accepted")
	}
}
