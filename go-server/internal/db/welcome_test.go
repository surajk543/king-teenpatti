package db_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// What a new account is given comes from the welcome_rewards rows (owner,
// 30 Sep 2026: "new account will get how much coins, hammers, diamonds,
// profile_picture, emoji — this data should come from database, user might
// get some or all rewards").

// welcomeRowOf is one welcome_rewards row as the tests read it back.
type welcomeRowOf struct {
	Code   string
	Type   string
	Value  *int64
	Ref    *string
	Active bool
	Sort   int
}

func welcomeRows(t *testing.T, d *db.DB) []welcomeRowOf {
	t.Helper()
	rows, err := d.Pool.Query(context.Background(),
		`SELECT code, reward_type, reward_value, reward_ref_id, is_active, sort_order FROM welcome_rewards ORDER BY sort_order, id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []welcomeRowOf
	for rows.Next() {
		var r welcomeRowOf
		if err := rows.Scan(&r.Code, &r.Type, &r.Value, &r.Ref, &r.Active, &r.Sort); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	return out
}

func value(v *int64) int64 {
	if v == nil {
		return -1
	}
	return *v
}

// signIn creates a guest account through the store and fails the test unless
// it is new and welcomed.
func signIn(t *testing.T, users *db.Users, name string) *db.SignIn {
	t.Helper()
	res, err := users.SignIn(context.Background(), db.Profile{
		Provider: db.ProviderGuest, ProviderUserID: "welcome-" + name + "-" + randomSuffix(t), DisplayName: name,
	})
	if err != nil {
		t.Fatalf("sign in %s: %v", name, err)
	}
	if !res.IsNew || res.Welcome == nil {
		t.Fatalf("sign in %s: isNew=%v welcome=%v", name, res.IsNew, res.Welcome)
	}
	return res
}

// wallets reads the four wallets straight from the row.
func wallets(t *testing.T, d *db.DB, userID string) [4]int64 {
	t.Helper()
	var w [4]int64
	if err := d.Pool.QueryRow(context.Background(),
		`SELECT chips, diamond, hammer, missile FROM users WHERE id = $1`, userID).Scan(&w[0], &w[1], &w[2], &w[3]); err != nil {
		t.Fatal(err)
	}
	return w
}

// The seed holds 5 Lakh chips (owner, 30 Sep 2026: "Also add 5Lakh chips in
// welcome reward"), first, and today's diamonds, hammers and missile — what
// the users column DEFAULTs gave every account until the rows took over. The
// trigger stamps updated_at on every UPDATE.
func TestTheSeedHoldsFiveLakhChipsTheDiamondsHammersAndMissile(t *testing.T) {
	d := dbtest.Open(t, "welcome")
	got := welcomeRows(t, d)
	want := []welcomeRowOf{
		{Code: "chips", Type: "CHIPS", Active: true, Sort: 10},
		{Code: "diamonds", Type: "DIAMOND", Active: true, Sort: 20},
		{Code: "hammers", Type: "HAMMER", Active: true, Sort: 30},
		{Code: "missiles", Type: "MISSILE", Active: true, Sort: 40},
	}
	values := []int64{500000, 5, 10, 1}
	if len(got) != len(want) {
		t.Fatalf("the seed holds %d welcome rows, want 4: %+v", len(got), got)
	}
	for i := range want {
		if got[i].Code != want[i].Code || got[i].Type != want[i].Type || value(got[i].Value) != values[i] ||
			got[i].Ref != nil || got[i].Active != want[i].Active || got[i].Sort != want[i].Sort {
			t.Errorf("row %d = %+v (value %d), want %+v (value %d)", i, got[i], value(got[i].Value), want[i], values[i])
		}
	}

	before := countOf(t, d, `SELECT updated_at FROM welcome_rewards WHERE code = 'hammers'`)
	time.Sleep(5 * time.Millisecond)
	execSQL(t, d, `UPDATE welcome_rewards SET reward_value = 25 WHERE code = 'hammers'`)
	if after := countOf(t, d, `SELECT updated_at FROM welcome_rewards WHERE code = 'hammers'`); after <= before {
		t.Errorf("updated_at %d → %d: the touch trigger did not stamp the UPDATE", before, after)
	}
	// An owner's UPDATE survives every boot: the seed never rewrites a row.
	reboot(t, d)
	if v := countOf(t, d, `SELECT reward_value FROM welcome_rewards WHERE code = 'hammers'`); v != 25 {
		t.Errorf("after a reboot the hammers row gives %d, want the owner's 25", v)
	}
	if n := countOf(t, d, `SELECT count(*) FROM welcome_rewards`); n != 4 {
		t.Errorf("%d rows after a reboot, want 4", n)
	}
	// The CHECKs: a code is a lower-case word, an amount is never negative.
	for _, bad := range []string{
		`INSERT INTO welcome_rewards (code, reward_type, reward_value) VALUES ('Chips2', 'CHIPS', 1)`,
		`INSERT INTO welcome_rewards (code, reward_type, reward_value) VALUES ('bad code', 'CHIPS', 1)`,
		`INSERT INTO welcome_rewards (code, reward_type, reward_value) VALUES ('negative', 'CHIPS', -1)`,
		`INSERT INTO welcome_rewards (code, reward_type, reward_value) VALUES ('diamonds', 'DIAMOND', 1)`,
	} {
		if _, err := d.Pool.Exec(context.Background(), bad); err == nil {
			t.Errorf("accepted: %s", bad)
		}
	}
}

// The seed gives 5 Lakh chips (owner, 30 Sep 2026: "Also add 5Lakh chips in
// welcome reward"). In production (set false) WELCOME_CHIPS never writes over
// the row — it is compared with it, not written — and fills only a table with
// no chips row; outside production (set true) it sets the row, and says so
// only when it changed it. A reboot of the schema leaves the row as it is. A
// welcome of 0 writes the row switched off; a negative one is refused.
func TestTheSeedGivesFiveLakhAndWelcomeChipsSetsTheRowOnlyOutsideProduction(t *testing.T) {
	d := dbtest.Open(t, "welcome")
	ctx := context.Background()
	w := db.NewWelcome(d, nil)

	rows := welcomeRows(t, d)
	if len(rows) != 4 || rows[0].Code != db.WelcomeChipsCode || rows[0].Sort != 10 {
		t.Fatalf("the seed's chips row goes first: %+v", rows)
	}
	if chips, err := w.Chips(ctx); err != nil || chips != 500000 {
		t.Fatalf("the seed's welcome: %d, %v", chips, err)
	}

	prod, err := w.EnsureChipsRow(ctx, 1000000, false)
	if err != nil {
		t.Fatal(err)
	}
	if prod.Created || prod.Set || prod.Type != "CHIPS" || prod.Value != 500000 || !prod.Active || prod.Total != 500000 {
		t.Fatalf("production wrote over the seeded row: %+v", prod)
	}

	set, err := w.EnsureChipsRow(ctx, 700000, true)
	if err != nil || set.Created || !set.Set || set.Value != 700000 || !set.Active || set.Total != 700000 {
		t.Fatalf("outside production WELCOME_CHIPS sets the row: %+v %v", set, err)
	}
	again, err := w.EnsureChipsRow(ctx, 700000, true)
	if err != nil || again.Set || again.Value != 700000 {
		t.Fatalf("a row already at the figure is not written again: %+v %v", again, err)
	}
	reboot(t, d)
	if v := countOf(t, d, `SELECT reward_value FROM welcome_rewards WHERE code = 'chips'`); v != 700000 {
		t.Fatalf("after a reboot the chips row gives %d: the seed rewrote it", v)
	}

	// Switched off by an owner: production leaves it off.
	execSQL(t, d, `UPDATE welcome_rewards SET is_active = FALSE WHERE code = 'chips'`)
	off, err := w.EnsureChipsRow(ctx, 500000, false)
	if err != nil || off.Created || off.Set || off.Active || off.Total != 0 {
		t.Fatalf("a switched-off row: %+v %v", off, err)
	}

	// A table with no chips row is filled either way.
	execSQL(t, d, `DELETE FROM welcome_rewards WHERE code = 'chips'`)
	filled, err := w.EnsureChipsRow(ctx, 300000, false)
	if err != nil || !filled.Created || filled.Value != 300000 || !filled.Active || filled.Total != 300000 {
		t.Fatalf("an empty table is filled: %+v %v", filled, err)
	}

	zero := dbtest.Open(t, "welcome")
	z, err := db.NewWelcome(zero, nil).EnsureChipsRow(ctx, 0, true)
	if err != nil || z.Created || !z.Set || z.Active || z.Value != 0 || z.Total != 0 {
		t.Fatalf("WELCOME_CHIPS=0 sets the row switched off: %+v %v", z, err)
	}
	if _, err := db.NewWelcome(zero, nil).EnsureChipsRow(ctx, -1, true); err == nil {
		t.Fatal("a negative welcome was accepted")
	}
}

// A new account gets exactly the ACTIVE rows — all of them, some, or none —
// with the wallets written explicitly (0 where no row gives any: the column
// DEFAULTs no longer decide), a welcome_bonus ledger row for the chips (even
// at 0), and the wallet equal to its ledger. An owner's UPDATE applies to the
// very next account, with no restart.
func TestANewAccountGetsExactlyTheActiveRows(t *testing.T) {
	f := newFixture(t)
	// The seed's rows, as the table holds them (their figures are pinned by
	// TestTheSeedHoldsFiveLakhChipsTheDiamondsHammersAndMissile).
	diamonds, hammers, missiles := f.welcomeGrant(db.RewardDiamond), f.welcomeGrant(db.RewardHammer), f.welcomeGrant(db.RewardMissile)

	all := signIn(t, f.users, "All")
	if g := all.Welcome; g.Chips != welcome || g.Diamonds != diamonds || g.Hammers != hammers || g.Missiles != missiles ||
		len(g.Pictures) != 0 || len(g.TablePictures) != 0 || len(g.Emojis) != 0 {
		t.Fatalf("every row: %+v", g)
	}
	if got := wallets(t, f.d, all.User.ID); got != [4]int64{welcome, diamonds, hammers, missiles} {
		t.Fatalf("wallets %v", got)
	}
	if u := all.User; u.Chips != welcome || int64(u.Diamond) != diamonds || int64(u.Hammer) != hammers || int64(u.Missile) != missiles {
		t.Fatalf("the account as answered: %+v", u)
	}

	// Some: the chips and the hammers switched off. No restart, same store.
	execSQL(t, f.d, `UPDATE welcome_rewards SET is_active = FALSE WHERE code IN ('chips', 'hammers')`)
	some := signIn(t, f.users, "Some")
	if g := some.Welcome; g.Chips != 0 || g.Diamonds != diamonds || g.Hammers != 0 || g.Missiles != missiles {
		t.Fatalf("some rows: %+v", g)
	}
	if got := wallets(t, f.d, some.User.ID); got != [4]int64{0, diamonds, 0, missiles} {
		t.Fatalf("wallets %v", got)
	}
	rows := f.ledgerRows(some.User.ID)
	if len(rows) != 1 || rows[0].Reason != "welcome_bonus" || rows[0].Delta != 0 || rows[0].Balance != 0 || rows[0].ActionID != nil {
		t.Fatalf("a welcome of no chips still writes its ledger row: %+v", rows)
	}

	// An UPDATE of a figure, then two rows of one kind adding up.
	execSQL(t, f.d, `UPDATE welcome_rewards SET is_active = TRUE, reward_value = 300000 WHERE code = 'chips'`)
	execSQL(t, f.d, `INSERT INTO welcome_rewards (code, reward_type, reward_value, sort_order) VALUES ('festival_diamonds', 'DIAMOND', 6, 25)`)
	more := signIn(t, f.users, "More")
	if g := more.Welcome; g.Chips != 300000 || g.Diamonds != diamonds+6 || g.Hammers != 0 || g.Missiles != missiles {
		t.Fatalf("an UPDATE and a second diamond row: %+v", g)
	}

	// None.
	execSQL(t, f.d, `UPDATE welcome_rewards SET is_active = FALSE`)
	none := signIn(t, f.users, "None")
	if g := none.Welcome; g.Chips != 0 || g.Diamonds != 0 || g.Hammers != 0 || g.Missiles != 0 ||
		g.Pictures == nil || g.TablePictures == nil || g.Emojis == nil {
		t.Fatalf("no rows: %+v", g)
	}
	if got := wallets(t, f.d, none.User.ID); got != [4]int64{} {
		t.Fatalf("wallets %v", got)
	}
	// The answer's lists are [] on the wire, never null.
	raw, _ := json.Marshal(none.Welcome)
	if string(raw) != `{"chips":0,"diamonds":0,"hammers":0,"missiles":0,"pictures":[],"tablePictures":[],"emojis":[]}` {
		t.Fatalf("an empty welcome marshals to %s", raw)
	}
	f.reconcile()
}

// A picture, a table picture and an emoji given as a welcome are the new
// account's from its first moment, for the term the shop rents each for,
// exactly as their catalogues then list them — and none is worn or laid.
func TestAWelcomePictureTablePictureAndEmojiAreOwnedForTheirTermsAndNeverPutOn(t *testing.T) {
	f := newFixture(t)
	clock := &testClock{now: time.UnixMilli(1_900_000_000_000)}
	users := db.NewUsers(f.d, welcome, clock.Now)
	at := clock.Now().UnixMilli()
	execSQL(t, f.d, `INSERT INTO welcome_rewards (code, reward_type, reward_ref_id, sort_order) VALUES
		('welcome_picture', 'PROFILE_PICTURE', (SELECT id::text FROM profile_pictures WHERE name = 'Lovestruck Cat'), 50),
		('welcome_table_picture', 'TABLE_PICTURE', (SELECT id::text FROM table_pictures WHERE name = 'Lines Background'), 60),
		('welcome_emoji', 'EMOJI', (SELECT id::text FROM emojis WHERE name = 'Clapping Hands'), 70)`)

	res := signIn(t, users, "Items")
	g := res.Welcome
	if len(g.Pictures) != 1 || len(g.TablePictures) != 1 || len(g.Emojis) != 1 {
		t.Fatalf("the welcome's items: %+v", g)
	}
	pic, table, emoji := g.Pictures[0], g.TablePictures[0], g.Emojis[0]
	term := func(days, hours int) int64 { return at + int64(days)*db.DayMs + int64(hours)*db.HourMs }
	if pic.Name != "Lovestruck Cat" || !pic.Owned || pic.ExpiresAt != term(pic.DurationDays, pic.DurationHours) || pic.ExpiresAt <= at {
		t.Errorf("the picture: %+v", pic)
	}
	if table.Name != "Lines Background" || !table.Owned || table.ExpiresAt != term(table.DurationDays, table.DurationHours) || table.ExpiresAt <= at {
		t.Errorf("the table picture: %+v", table)
	}
	if emoji.Name != "Clapping Hands" || !emoji.Owned || emoji.ExpiresAt != term(emoji.DurationDays, emoji.DurationHours) || emoji.ExpiresAt <= at {
		t.Errorf("the emoji: %+v", emoji)
	}

	// Each item is its catalogue's own listing of it for this player.
	pictures, err := db.NewPictures(f.d, users, clock.Now).List(f.ctx, res.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, p := range pictures {
		if p.ID == pic.ID {
			found = true
			if p != pic {
				t.Errorf("GET /api/profiles lists %+v, the welcome said %+v", p, pic)
			}
		}
	}
	tables, err := db.NewTablePictures(f.d, users, clock.Now).List(f.ctx, res.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range tables {
		if p.ID == table.ID && p != table {
			t.Errorf("GET /api/table-pictures lists %+v, the welcome said %+v", p, table)
		}
	}
	emojis := db.NewEmojis(f.d, users, clock.Now)
	sendable, err := emojis.Owns(f.ctx, res.User.ID, emoji.ID)
	if err != nil || sendable.ExpiresAt != emoji.ExpiresAt {
		t.Errorf("the emoji is not sendable: %+v %v", sendable, err)
	}
	if !found {
		t.Error("the welcome picture is not in the catalogue")
	}

	// Owned, not put on.
	if res.User.ActivePictureID != nil || res.User.TablePicture != nil {
		t.Errorf("a welcome put something on: picture %v table %v", res.User.ActivePictureID, res.User.TablePicture)
	}
	for _, q := range []string{
		`SELECT count(*) FROM user_profile_pictures WHERE user_id = $1`,
		`SELECT count(*) FROM user_table_pictures WHERE user_id = $1`,
		`SELECT count(*) FROM user_emojis WHERE user_id = $1`,
	} {
		if n := f.count(q, res.User.ID); n != 1 {
			t.Errorf("%s = %d, want 1", q, n)
		}
	}
	if n := f.count(`SELECT count(*) FROM user_table_choice WHERE user_id = $1`, res.User.ID); n != 0 {
		t.Errorf("a welcome laid a table picture")
	}
	// The wallets are the seed's, the ledger the chips alone.
	if got := wallets(t, f.d, res.User.ID); got != [4]int64{welcome, 5, 10, 1} {
		t.Errorf("wallets %v", got)
	}
	f.reconcile()
}

// A row that cannot be granted is left out — one WARN naming its code and
// why — and the login succeeds with the rest.
func TestAWelcomeRowThatCannotBeGrantedIsLeftOutAndTheLoginSucceeds(t *testing.T) {
	f := newFixture(t)
	var logs bytes.Buffer
	f.users.SetLogger(slog.New(slog.NewJSONHandler(&logs, nil)))
	execSQL(t, f.d, `UPDATE emojis SET is_active = FALSE WHERE name = 'Angry'`)
	execSQL(t, f.d, `INSERT INTO welcome_rewards (code, reward_type, reward_value, reward_ref_id, sort_order) VALUES
		('frame', 'AVATAR_FRAME', NULL, 'golden', 50),
		('no_amount', 'CHIPS', NULL, NULL, 51),
		('zero_hammers', 'HAMMER', 0, NULL, 52),
		('too_many_missiles', 'MISSILE', 3000000000, NULL, 53),
		('not_an_id', 'PROFILE_PICTURE', NULL, 'bear', 54),
		('gone', 'TABLE_PICTURE', NULL, '999999', 55),
		('free', 'PROFILE_PICTURE', NULL, (SELECT id::text FROM profile_pictures WHERE name = 'Bear'), 56),
		('retired', 'EMOJI', NULL, (SELECT id::text FROM emojis WHERE name = 'Angry'), 57),
		('cat', 'PROFILE_PICTURE', NULL, (SELECT id::text FROM profile_pictures WHERE name = 'Lovestruck Cat'), 58),
		('cat_again', 'PROFILE_PICTURE', NULL, (SELECT id::text FROM profile_pictures WHERE name = 'Lovestruck Cat'), 59)`)

	res := signIn(t, f.users, "Partial")
	g := res.Welcome
	if g.Chips != welcome || g.Diamonds != 5 || g.Hammers != 10 || g.Missiles != 1 ||
		len(g.Pictures) != 1 || g.Pictures[0].Name != "Lovestruck Cat" || len(g.TablePictures) != 0 || len(g.Emojis) != 0 {
		t.Fatalf("the rows that can be granted: %+v", g)
	}
	reasons := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		var entry struct {
			Level, Msg, Code, Reason, UserID string
		}
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("%v: %s", err, line)
		}
		if entry.Msg != "welcome reward left out" || entry.Level != "WARN" {
			t.Errorf("unexpected log line %s", line)
			continue
		}
		reasons[entry.Code] = entry.Reason
	}
	want := map[string]string{
		"frame":             "a reward this server cannot grant",
		"no_amount":         "no amount",
		"zero_hammers":      "no amount",
		"too_many_missiles": "more than the wallet can hold",
		"not_an_id":         "no catalogue id",
		"gone":              "no such table picture",
		"free":              "the profile picture is free: every player has it already",
		"retired":           "the emoji is retired",
		"cat_again":         "the same profile picture as welcome reward cat",
	}
	if fmt.Sprint(reasons) != fmt.Sprint(want) {
		t.Fatalf("left out:\n %v\nwant\n %v", reasons, want)
	}
	if n := f.count(`SELECT count(*) FROM user_profile_pictures WHERE user_id = $1`, res.User.ID); n != 1 {
		t.Fatalf("%d ownership rows for one picture named twice", n)
	}
	f.reconcile()
}

// A returning player's login grants nothing, however the rows have changed
// since, and carries no welcome.
func TestAReturningLoginGrantsNothing(t *testing.T) {
	f := newFixture(t)
	profile := db.Profile{Provider: db.ProviderGuest, ProviderUserID: "welcome-back-" + randomSuffix(t), DisplayName: "Back"}
	first, err := f.users.SignIn(f.ctx, profile)
	if err != nil || !first.IsNew {
		t.Fatalf("%+v %v", first, err)
	}
	execSQL(t, f.d, `INSERT INTO welcome_rewards (code, reward_type, reward_ref_id, sort_order) VALUES
		('welcome_picture', 'PROFILE_PICTURE', (SELECT id::text FROM profile_pictures WHERE name = 'Lovestruck Cat'), 50)`)
	execSQL(t, f.d, `UPDATE welcome_rewards SET reward_value = reward_value * 2`)
	again, err := f.users.SignIn(f.ctx, profile)
	if err != nil || again.IsNew || again.Welcome != nil || again.User.ID != first.User.ID {
		t.Fatalf("a returning login: %+v %v", again, err)
	}
	if got := wallets(t, f.d, first.User.ID); got != [4]int64{welcome, 5, 10, 1} {
		t.Fatalf("wallets %v after a returning login", got)
	}
	if n := f.count(`SELECT count(*) FROM user_profile_pictures WHERE user_id = $1`, first.User.ID); n != 0 {
		t.Fatal("a returning login was given a picture")
	}
	if n := f.count(`SELECT count(*) FROM chip_ledger WHERE user_id = $1`, first.User.ID); n != 1 {
		t.Fatalf("%d ledger rows after a returning login", n)
	}
	f.reconcile()
}

// Eight simultaneous first logins for one identity make one account, one
// welcome_bonus row and one grant: the losers' transactions — their grants
// with them — roll back, and their retries take the returning path.
func TestConcurrentFirstLoginsGrantTheWelcomeOnce(t *testing.T) {
	f := newFixture(t)
	execSQL(t, f.d, `INSERT INTO welcome_rewards (code, reward_type, reward_ref_id, sort_order) VALUES
		('welcome_picture', 'PROFILE_PICTURE', (SELECT id::text FROM profile_pictures WHERE name = 'Lovestruck Cat'), 50),
		('welcome_emoji', 'EMOJI', (SELECT id::text FROM emojis WHERE name = 'Clapping Hands'), 70)`)
	for round := 0; round < 3; round++ {
		id := "welcome-race-" + randomSuffix(t)
		const logins = 8
		var wg sync.WaitGroup
		results := make([]*db.SignIn, logins)
		errs := make([]error, logins)
		for i := range logins {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				results[i], errs[i] = f.users.SignIn(f.ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: id, DisplayName: fmt.Sprintf("Racer%d", i)})
			}(i)
		}
		wg.Wait()
		welcomed := 0
		for i := range logins {
			if errs[i] != nil {
				t.Fatalf("round %d login %d: %v", round, i, errs[i])
			}
			if results[i].User.ID != results[0].User.ID {
				t.Fatalf("round %d: two accounts", round)
			}
			if results[i].IsNew != (results[i].Welcome != nil) {
				t.Fatalf("round %d: isNew %v with welcome %v", round, results[i].IsNew, results[i].Welcome)
			}
			if results[i].Welcome != nil {
				welcomed++
			}
		}
		user := results[0].User.ID
		if welcomed != 1 {
			t.Fatalf("round %d: %d logins were welcomed, want 1", round, welcomed)
		}
		for q, want := range map[string]int64{
			`SELECT count(*) FROM users WHERE provider = 'guest' AND provider_user_id = $1`:                       1,
			`SELECT count(*) FROM chip_ledger WHERE user_id = (SELECT id FROM users WHERE provider_user_id = $1)`: 1,
		} {
			if n := f.count(q, id); n != want {
				t.Fatalf("round %d: %s = %d", round, q, n)
			}
		}
		for _, q := range []string{
			`SELECT count(*) FROM user_profile_pictures WHERE user_id = $1`,
			`SELECT count(*) FROM user_emojis WHERE user_id = $1`,
		} {
			if n := f.count(q, user); n != 1 {
				t.Fatalf("round %d: %s = %d", round, q, n)
			}
		}
		if got := wallets(t, f.d, user); got != [4]int64{welcome, 5, 10, 1} {
			t.Fatalf("round %d: wallets %v", round, got)
		}
	}
	f.reconcile()
}

// session:ready's welcomeChips is read through a short cache: the boot's
// figure until the TTL, the rows' after it, and — when a read fails — the
// last good figure.
func TestTheWelcomeChipsCacheReadsTheRowsOncePerTTL(t *testing.T) {
	d := dbtest.Open(t, "welcome")
	ctx := context.Background()
	w := db.NewWelcome(d, nil)
	if _, err := w.EnsureChipsRow(ctx, 400000, true); err != nil {
		t.Fatal(err)
	}
	clock := &testClock{now: time.UnixMilli(1_900_000_000_000)}
	cache := db.NewWelcomeChipsCache(w, 400000, true, 15*time.Second, clock.Now, nil)
	if got := cache.Current(ctx); got != 400000 {
		t.Fatalf("the boot's figure: %d", got)
	}
	execSQL(t, d, `UPDATE welcome_rewards SET reward_value = 250000 WHERE code = 'chips'`)
	if got := cache.Current(ctx); got != 400000 {
		t.Fatalf("read inside the TTL: %d", got)
	}
	clock.Advance(15 * time.Second)
	if got := cache.Current(ctx); got != 250000 {
		t.Fatalf("read after the TTL: %d", got)
	}
	// A cache that did not start fresh reads at once.
	stale := db.NewWelcomeChipsCache(w, 1, false, time.Hour, clock.Now, nil)
	if got := stale.Current(ctx); got != 250000 {
		t.Fatalf("a stand-in figure is read over at once: %d", got)
	}
	// A failing read keeps the last figure (the schema is dropped after the
	// test, so the table need not come back).
	execSQL(t, d, `ALTER TABLE welcome_rewards RENAME TO welcome_rewards_gone`)
	clock.Advance(15 * time.Second)
	if got := cache.Current(ctx); got != 250000 {
		t.Fatalf("a failed read: %d", got)
	}
}
