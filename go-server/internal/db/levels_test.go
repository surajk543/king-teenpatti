package db_test

// Player levels and XP (owner, 26 Sep 2026; db/levels.go, V1.0.0's PLAYER
// LEVELS): the owner's ladder as seeded, the level rule — VIP never reached by
// XP — the one award function with its daily cap and rolling window, the XP a
// hand-end settle awards in its own transaction, and the two ledger rows of a
// taxed win.

import (
	"context"
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

func xpAt(n int64) *int64 { return &n }

// ownersLevels is the owner's table, exactly (26 Sep 2026): level, the XP that
// reaches it (nil: never — the VIP tier), title, icon, winning tax in basis
// points, and whether it is the VIP tier. The icons are written with escapes
// so an editor cannot drop a U+FE0F variation selector or merge two emoji.
var ownersLevels = []struct {
	level  int
	minXP  *int64
	title  string
	icon   string
	taxBps int
	vip    bool
}{
	{1, xpAt(0), "Newbie", "\U0001F331", 2000, false},
	{2, xpAt(100), "Rookie", "\U0001F530", 1980, false},
	{3, xpAt(250), "Beginner", "\u2B50", 1959, false},
	{4, xpAt(500), "Player", "\U0001F3AE", 1939, false},
	{5, xpAt(800), "Regular", "\U0001F7E2", 1918, false},
	{6, xpAt(1200), "Challenger", "\u2694\uFE0F", 1898, false},
	{7, xpAt(1700), "Skilled", "\U0001F3AF", 1878, false},
	{8, xpAt(2300), "Contender", "\U0001F6E1\uFE0F", 1857, false},
	{9, xpAt(3000), "Fighter", "\u2694\uFE0F", 1837, false},
	{10, xpAt(4000), "Rising Star", "\U0001F31F", 1816, false},
	{11, xpAt(5200), "Pro Player", "\U0001F3C5", 1796, false},
	{12, xpAt(6700), "Veteran", "\U0001F396\uFE0F", 1776, false},
	{13, xpAt(8500), "Expert", "\U0001F9E0", 1755, false},
	{14, xpAt(10500), "Specialist", "\U0001F4A0", 1735, false},
	{15, xpAt(13000), "Ace", "\U0001F0CF", 1714, false},
	{16, xpAt(16000), "Elite", "\U0001F48E", 1694, false},
	{17, xpAt(20000), "Master", "\U0001F451", 1673, false},
	{18, xpAt(25000), "Grand Master", "\U0001F451\u2694\uFE0F", 1653, false},
	{19, xpAt(31000), "Champion", "\U0001F3C6", 1633, false},
	{20, xpAt(38000), "High Roller", "\U0001F4B0", 1612, false},
	{21, xpAt(46000), "Royal", "\U0001F451", 1592, false},
	{22, xpAt(55000), "Royal Ace", "\U0001F0CF\U0001F451", 1571, false},
	{23, xpAt(65000), "Royal Master", "\U0001F451\U0001F48E", 1551, false},
	{24, xpAt(76000), "Supreme", "\U0001F531", 1531, false},
	{25, xpAt(88000), "Supreme Ace", "\U0001F531\U0001F0CF", 1510, false},
	{26, xpAt(102000), "Legend", "\U0001F320", 1490, false},
	{27, xpAt(118000), "Legendary", "\u2728", 1469, false},
	{28, xpAt(136000), "Grand Legend", "\U0001F31F\U0001F451", 1449, false},
	{29, xpAt(156000), "Immortal", "\u267E\uFE0F", 1429, false},
	{30, xpAt(178000), "Titan", "\u26A1", 1408, false},
	{31, xpAt(202000), "Elite Titan", "\u26A1\U0001F48E", 1388, false},
	{32, xpAt(228000), "Royal Titan", "\u26A1\U0001F451", 1367, false},
	{33, xpAt(256000), "Emperor", "\U0001F451", 1347, false},
	{34, xpAt(286000), "Royal Emperor", "\U0001F451\U0001F48E", 1327, false},
	{35, xpAt(318000), "Supreme Emperor", "\U0001F531\U0001F451", 1306, false},
	{36, xpAt(352000), "King", "\U0001F451", 1286, false},
	{37, xpAt(390000), "Grand King", "\U0001F451\U0001F3C6", 1265, false},
	{38, xpAt(432000), "Royal King", "\U0001F451\U0001F48E", 1245, false},
	{39, xpAt(478000), "Supreme King", "\U0001F531\U0001F451", 1224, false},
	{40, xpAt(528000), "Master King", "\U0001F451\u2694\uFE0F", 1204, false},
	{41, xpAt(585000), "Overlord", "\U0001F525", 1184, false},
	{42, xpAt(650000), "Grand Overlord", "\U0001F525\U0001F451", 1163, false},
	{43, xpAt(725000), "Royal Overlord", "\U0001F525\U0001F48E", 1143, false},
	{44, xpAt(810000), "Supreme Overlord", "\U0001F525\U0001F531", 1122, false},
	{45, xpAt(900000), "Mythic", "\U0001F30C", 1102, false},
	{46, xpAt(1000000), "Mythic King", "\U0001F30C\U0001F451", 1082, false},
	{47, xpAt(1150000), "Immortal King", "\u267E\uFE0F\U0001F451", 1061, false},
	{48, xpAt(1350000), "Legendary King", "\U0001F31F\U0001F451", 1041, false},
	{49, xpAt(1600000), "Supreme Legend", "\U0001F531\U0001F31F", 1020, false},
	{50, xpAt(2000000), "King of Kings", "\U0001F451\U0001F451", 1000, false},
	{51, nil, "VIP", "\U0001F48E\U0001F451", 400, true},
}

// TestTheSeededLevelsAreTheOwnersTable: a fresh database holds the owner's
// fifty-one levels exactly — thresholds, titles, rates, the VIP tier's missing
// threshold — and every icon code point for code point.
func TestTheSeededLevelsAreTheOwnersTable(t *testing.T) {
	f := newFixture(t)
	rows, err := f.d.Pool.Query(f.ctx, `SELECT level, min_xp, title, icon, tax_bps, is_vip FROM player_levels ORDER BY level`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	i := 0
	for rows.Next() {
		var level, bps int
		var minXP *int64
		var title, icon string
		var vip bool
		if err := rows.Scan(&level, &minXP, &title, &icon, &bps, &vip); err != nil {
			t.Fatal(err)
		}
		if i >= len(ownersLevels) {
			t.Fatalf("an extra level %d", level)
		}
		want := ownersLevels[i]
		i++
		if level != want.level || !reflect.DeepEqual(minXP, want.minXP) || title != want.title || bps != want.taxBps || vip != want.vip {
			t.Errorf("level %d: %v %q %d %v, want %d %v %q %d %v", level, minXP, title, bps, vip, want.level, want.minXP, want.title, want.taxBps, want.vip)
		}
		if icon != want.icon {
			t.Errorf("level %d's icon is %+q, want %+q", level, icon, want.icon)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if i != len(ownersLevels) {
		t.Fatalf("%d levels, want %d", i, len(ownersLevels))
	}
	// What earns XP and the daily cap, as the owner gave them.
	if n := f.count(`SELECT count(*) FROM xp_sources WHERE is_active AND (code, xp) IN
	    (('HAND_COMPLETED', 1), ('HAND_WON', 1), ('ACTIVE_30_MIN', 5), ('ACTIVE_60_MIN', 15), ('DAILY_PLAY_BONUS', 5))`); n != 5 ||
		f.count(`SELECT count(*) FROM xp_sources`) != 5 {
		t.Errorf("xp_sources: %d of the owner's five", n)
	}
	if f.count(`SELECT count(*) FROM xp_settings WHERE id = 1 AND daily_cap = 50 AND window_ms = 86400000`) != 1 {
		t.Error("xp_settings must be the 50 XP cap in a 24-hour window")
	}
	if f.count(`SELECT count(*) FROM player_xp`) != 0 {
		t.Error("the seed gives nobody XP")
	}
}

// setXP gives a player xp (and optionally a level set by hand) directly.
func (f *fixture) setXP(userID string, xp int64) {
	f.t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO player_xp (user_id, xp, created_at, updated_at) VALUES ($1, $2, 1, 1)
	     ON CONFLICT (user_id) DO UPDATE SET xp = EXCLUDED.xp`, userID, xp); err != nil {
		f.t.Fatal(err)
	}
}

// makeVIP runs the seed header's statement, as an owner would.
func (f *fixture) makeVIP(userID string) {
	f.t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO player_xp (user_id, level_override, created_at, updated_at)
     VALUES ($1, (SELECT level FROM player_levels WHERE is_vip),
             (EXTRACT(EPOCH FROM now()) * 1000)::bigint, (EXTRACT(EPOCH FROM now()) * 1000)::bigint)
     ON CONFLICT (user_id) DO UPDATE SET level_override = (SELECT level FROM player_levels WHERE is_vip),
                                         updated_at = EXCLUDED.updated_at`, userID); err != nil {
		f.t.Fatal(err)
	}
}

// TestTheLevelFollowsTheXP: the highest level whose threshold the XP has
// reached, with the next one beside it; a level set by hand wins and has no
// next; the ladder's lowest rung when an owner's edit leaves no level that
// low; and the account a seat is built from carries the rate.
func TestTheLevelFollowsTheXP(t *testing.T) {
	f := newFixture(t)
	u := f.user("Climber")
	fresh := f.find(u.ID).PlayerLevel
	want := db.PlayerLevel{Level: 1, Title: "Newbie", Icon: "\U0001F331", XP: 0, TaxBps: 2000,
		Next:  &db.NextLevel{Level: 2, Title: "Rookie", Icon: "\U0001F530", MinXP: 100, TaxBps: 1980},
		Today: db.XPToday{Cap: 50}}
	if !reflect.DeepEqual(fresh, want) {
		t.Fatalf("a new account: %+v, want %+v", fresh, want)
	}
	if p := f.find(u.ID).Player(); p.TaxBps != 2000 {
		t.Errorf("the seat is built at the account's rate: %d", p.TaxBps)
	}
	for _, tc := range []struct {
		xp    int64
		level int
		title string
		bps   int
		next  int
	}{
		{99, 1, "Newbie", 2000, 2},
		{100, 2, "Rookie", 1980, 3},
		{4000, 10, "Rising Star", 1816, 11},
		{5199, 10, "Rising Star", 1816, 11},
		{1_999_999, 49, "Supreme Legend", 1020, 50},
		{2_000_000, 50, "King of Kings", 1000, 0},
	} {
		f.setXP(u.ID, tc.xp)
		got := f.find(u.ID).PlayerLevel
		if got.Level != tc.level || got.Title != tc.title || got.TaxBps != tc.bps || got.XP != tc.xp || got.VIP {
			t.Errorf("%d XP: %+v, want level %d %q at %d", tc.xp, got, tc.level, tc.title, tc.bps)
		}
		if tc.next == 0 && got.Next != nil || tc.next != 0 && (got.Next == nil || got.Next.Level != tc.next) {
			t.Errorf("%d XP: next %+v, want level %d", tc.xp, got.Next, tc.next)
		}
	}
	// A level set by hand wins, whatever the XP, and XP leads nowhere from it.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE player_xp SET level_override = 10 WHERE user_id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}
	if got := f.find(u.ID).PlayerLevel; got.Level != 10 || got.TaxBps != 1816 || got.Next != nil || got.VIP {
		t.Errorf("a level set by hand: %+v", got)
	}
	// An owner's edit that leaves no level as low as the XP: the lowest rung.
	other := f.user("Bottom")
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE player_levels SET min_xp = 10 WHERE level = 1`); err != nil {
		t.Fatal(err)
	}
	if got := f.find(other.ID).PlayerLevel; got.Level != 1 || got.TaxBps != 2000 || got.Next == nil || got.Next.Level != 2 {
		t.Errorf("below every threshold: %+v, want the lowest rung with level 2 next", got)
	}
}

// TestXPNeverMakesAPlayerVIP (owner: "remember VIP Tag is not granted by XP"):
// any amount of XP stops at level 50 with nothing next; only a level set by
// hand is the VIP tier; the award never touches that setting; and the
// database refuses a VIP tier with an XP threshold, or a level without one.
func TestXPNeverMakesAPlayerVIP(t *testing.T) {
	f := newFixture(t)
	u := f.user("Grinder")
	f.setXP(u.ID, 9_000_000_000)
	got := f.find(u.ID).PlayerLevel
	if got.Level != 50 || got.VIP || got.TaxBps != 1000 || got.Next != nil {
		t.Fatalf("more XP than level 50 needs: %+v, want level 50, not VIP, nothing next", got)
	}

	f.makeVIP(u.ID)
	got = f.find(u.ID).PlayerLevel
	if got.Level != 51 || !got.VIP || got.Title != "VIP" || got.Icon != "\U0001F48E\U0001F451" || got.TaxBps != 400 || got.Next != nil || got.XP != 9_000_000_000 {
		t.Fatalf("a VIP: %+v", got)
	}
	// XP earned as a VIP moves the XP and leaves the tier alone.
	xp := db.NewXP(f.d, nil)
	if _, changed, err := xp.Award(f.ctx, u.ID, db.XPSourceActive60Min); err != nil || !changed {
		t.Fatalf("award to a VIP: %v %v", changed, err)
	}
	if n := f.count(`SELECT count(*) FROM player_xp WHERE user_id = $1 AND level_override = 51`, u.ID); n != 1 {
		t.Fatal("an award must never touch level_override")
	}
	if got := f.find(u.ID).PlayerLevel; !got.VIP || got.Level != 51 {
		t.Fatalf("still VIP after an award: %+v", got)
	}
	// Taken away by hand, the XP decides again — and it reaches level 50.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE player_xp SET level_override = NULL WHERE user_id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}
	if got := f.find(u.ID).PlayerLevel; got.Level != 50 || got.VIP {
		t.Fatalf("VIP taken away: %+v", got)
	}
	// The next level is never the VIP tier.
	f.setXP(u.ID, 1_700_000)
	if got := f.find(u.ID).PlayerLevel; got.Next == nil || got.Next.Level != 50 {
		t.Fatalf("level 49's next is level 50: %+v", got.Next)
	}

	var pgErr *pgconn.PgError
	for name, sql := range map[string]string{
		"an XP threshold on the VIP tier": `UPDATE player_levels SET min_xp = 3000000 WHERE is_vip`,
		"a level with no XP threshold":    `UPDATE player_levels SET min_xp = NULL WHERE level = 50`,
		"a new VIP tier with a threshold": `INSERT INTO player_levels (level, min_xp, title, icon, tax_bps, is_vip) VALUES (52, 5000000, 'VIP+', 'x', 100, TRUE)`,
		"a rate above the whole pot":      `UPDATE player_levels SET tax_bps = 10001 WHERE level = 1`,
		"a negative XP":                   `UPDATE player_xp SET xp = -1 WHERE user_id = '` + u.ID + `'`,
	} {
		if _, err := f.d.Pool.Exec(f.ctx, sql); !errors.As(err, &pgErr) || pgErr.Code != "23514" {
			t.Errorf("%s must be refused by a CHECK, got %v", name, err)
		}
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE player_xp SET level_override = 77 WHERE user_id = $1`, u.ID); !errors.As(err, &pgErr) || pgErr.Code != "23503" {
		t.Errorf("an override naming no level must be refused by the foreign key, got %v", err)
	}
}

// testClock is a clock a test moves by hand.
type testClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// TestTheAwardHoldsTheDailyCapInARollingWindow: the first award of a window
// opens it and brings the daily play bonus; every source is held to what the
// cap leaves; the window runs 24 hours from its opening and then everything
// starts over; an inactive or unknown source earns nothing; and with no
// settings row there is no XP at all.
func TestTheAwardHoldsTheDailyCapInARollingWindow(t *testing.T) {
	f := newFixture(t)
	clock := &testClock{now: time.UnixMilli(1_800_000_000_000)}
	xp := db.NewXP(f.d, clock.Now)
	users := db.NewUsers(f.d, welcome, clock.Now)
	u := f.user("Daily")
	award := func(source string) (db.PlayerLevel, bool) {
		t.Helper()
		level, changed, err := xp.Award(f.ctx, u.ID, source)
		if err != nil {
			t.Fatalf("award %s: %v", source, err)
		}
		return level, changed
	}

	opened := clock.Now().UnixMilli()
	level, changed := award(db.XPSourceActive30Min)
	if !changed || level.XP != 10 || level.Today != (db.XPToday{XP: 10, Cap: 50, ResetsAt: opened + 86_400_000}) {
		t.Fatalf("the window's first award: %+v %v, want 5 and the daily bonus's 5", level, changed)
	}
	level, _ = award(db.XPSourceActive60Min)
	if level.XP != 25 || level.Today.XP != 25 || level.Today.ResetsAt != opened+86_400_000 {
		t.Fatalf("the second award: %+v, want 25 and the same window", level)
	}
	// Up to the cap and no further: 25 + 15 + 15 would be 55.
	level, _ = award(db.XPSourceActive60Min)
	level, changed = award(db.XPSourceActive60Min)
	if level.XP != 50 || level.Today.XP != 50 || !changed {
		t.Fatalf("the cap: %+v, want exactly 50", level)
	}
	if level, changed = award(db.XPSourceHandCompleted); changed || level.XP != 50 {
		t.Fatalf("a capped window earns nothing: %+v %v", level, changed)
	}
	// The account read says the same.
	if got, err := users.FindByID(f.ctx, u.ID); err != nil || got.PlayerLevel.Today != level.Today {
		t.Fatalf("the account's today: %+v %v", got.PlayerLevel.Today, err)
	}

	// 24 hours after the window opened it has run out: the next award opens a
	// new one, with the daily bonus again.
	clock.Advance(24*time.Hour - time.Millisecond)
	if _, changed = award(db.XPSourceHandCompleted); changed {
		t.Fatal("a millisecond before the window runs out, the cap still holds")
	}
	clock.Advance(time.Millisecond)
	level, changed = award(db.XPSourceHandWon)
	if !changed || level.XP != 56 || level.Today.XP != 6 || level.Today.ResetsAt != clock.Now().UnixMilli()+86_400_000 {
		t.Fatalf("a new window: %+v, want 1 + the daily 5 on top of 50", level)
	}
	// No window is running once it has run out, and the account reads 0 today.
	clock.Advance(25 * time.Hour)
	if got, _ := users.FindByID(f.ctx, u.ID); got.PlayerLevel.Today != (db.XPToday{Cap: 50}) || got.PlayerLevel.XP != 56 {
		t.Fatalf("no window running: %+v", got.PlayerLevel)
	}

	// An inactive source earns nothing — but the award still opens the
	// window, and its daily bonus.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_sources SET is_active = FALSE WHERE code = 'HAND_WON'`); err != nil {
		t.Fatal(err)
	}
	level, _ = award(db.XPSourceHandWon)
	if level.XP != 61 || level.Today.XP != 5 {
		t.Fatalf("an inactive source: %+v, want the daily bonus alone", level)
	}
	if level, changed = award("BOGUS"); changed || level.XP != 61 {
		t.Fatalf("a source this build does not know earns nothing: %+v", level)
	}
	// An owner's cap of 0 stops every award; no settings row stops XP.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_settings SET daily_cap = 0`); err != nil {
		t.Fatal(err)
	}
	if _, changed = award(db.XPSourceActive60Min); changed {
		t.Fatal("a cap of 0 earns nothing")
	}
	if _, err := f.d.Pool.Exec(f.ctx, `DELETE FROM xp_settings`); err != nil {
		t.Fatal(err)
	}
	other := f.user("NoRules")
	if _, changed, err := xp.Award(f.ctx, other.ID, db.XPSourceActive60Min); err != nil || changed {
		t.Fatalf("no settings row, no XP: %v %v", changed, err)
	}
	if n := f.count(`SELECT count(*) FROM player_xp WHERE user_id = $1`, other.ID); n != 0 {
		t.Fatal("with XP off an award writes nothing")
	}
	if window, err := xp.Window(f.ctx); err != nil || window != 0 {
		t.Fatalf("no settings row: window %v %v", window, err)
	}
}

// settledHands records the ledger's OnSettled hook.
type settledHands struct {
	mu    sync.Mutex
	hands []db.SettledHand
}

func (s *settledHands) hook(h db.SettledHand) {
	s.mu.Lock()
	s.hands = append(s.hands, h)
	s.mu.Unlock()
}

func (s *settledHands) all() []db.SettledHand {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]db.SettledHand(nil), s.hands...)
}

// TestATaxedWinIsTheWinGrossAndTheTaxAsItsOwnRow: the winner's hand-end
// entry with a Tax is two chip_ledger rows in the one settlement — hand_win at
// the GROSS figure, then table_tax of minus the tax under <handId>:tax:<userId>,
// its balance the wallet's — so the hand's hand_* rows still sum to zero, the
// tax is exactly what left the game, every wallet reconciles, and a replay of
// the settlement changes nothing: no row, no chip and no XP twice.
func TestATaxedWinIsTheWinGrossAndTheTaxAsItsOwnRow(t *testing.T) {
	f := newFixture(t)
	seen := &settledHands{}
	f.ledger.OnSettled(seen.hook)
	a, b := f.user("Winner"), f.user("Loser")
	room, hand := "room-tax", "hand-tax-"+randomSuffix(t)
	const pot, stake = int64(2000), int64(1000)
	tax := game.TableTax(pot, 2000)
	winner := settleEntry(hand, a.ID, pot-stake-tax, true, true, pot)
	winner.Tax = tax
	req := game.SettleRequest{RoomID: room, HandID: hand, PlayedMs: 95_000, Entries: []game.SettleEntry{
		winner, settleEntry(hand, b.ID, -stake, false, true, 0),
	}}
	settled, err := f.ledger.Settle(f.ctx, req)
	if err != nil {
		t.Fatal(err)
	}
	if settled.Balances[a.ID] != welcome+pot-stake-tax || settled.Balances[b.ID] != welcome-stake {
		t.Fatalf("balances %+v", settled.Balances)
	}
	if f.chips(a.ID) != welcome+pot-stake-tax {
		t.Fatalf("the winner's wallet %d, want the pot less their stake less the tax", f.chips(a.ID))
	}

	rows := f.handLedgerRows(hand)
	if len(rows) != 3 {
		t.Fatalf("%d rows for the hand, want the loss, the gross win and the tax: %+v", len(rows), rows)
	}
	var handSum int64
	var taxRow *ledgerRow
	for i, r := range rows {
		switch r.Reason {
		case game.LedgerReasonTableTax:
			taxRow = &rows[i]
		case game.LedgerReasonHandWin:
			handSum += r.Delta
			if r.UserID != a.ID || r.Delta != pot-stake || r.Balance != welcome+pot-stake || *r.ActionID != game.SettleActionID(hand, a.ID) {
				t.Errorf("the win row %+v: want the gross %d at balance %d", r, pot-stake, welcome+pot-stake)
			}
		default:
			handSum += r.Delta
		}
	}
	if handSum != 0 {
		t.Errorf("the hand's hand_* rows sum to %d, want 0", handSum)
	}
	if taxRow == nil || taxRow.UserID != a.ID || taxRow.Delta != -tax || taxRow.Balance != f.chips(a.ID) ||
		taxRow.ActionID == nil || *taxRow.ActionID != game.TaxActionID(hand, a.ID) || taxRow.HandID == nil || *taxRow.HandID != hand {
		t.Fatalf("the tax row %+v: want -%d under %s at the wallet's balance, same hand", taxRow, tax, game.TaxActionID(hand, a.ID))
	}
	f.reconcile()
	// The counters are the pot's, once: the tax row moves none.
	if u := f.find(a.ID); u.HandsWon != 1 || u.HandsPlayed != 1 || u.TotalWinnings != pot || u.BiggestPot != pot {
		t.Errorf("the winner's counters: %+v", u)
	}

	// The hand's XP, in the same transaction: both completed it, a won it,
	// and it opened both windows (the daily bonus).
	if got := f.find(a.ID).PlayerLevel.XP; got != 7 {
		t.Errorf("the winner's XP %d, want 1 + 1 + 5", got)
	}
	if got := f.find(b.ID).PlayerLevel.XP; got != 6 {
		t.Errorf("the loser's XP %d, want 1 + 5", got)
	}
	if settled.TaxBps[a.ID] != 2000 || settled.TaxBps[b.ID] != 2000 {
		t.Errorf("the rates the seats take: %+v", settled.TaxBps)
	}
	hands := seen.all()
	if len(hands) != 1 {
		t.Fatalf("OnSettled heard %d settlements, want 1", len(hands))
	}
	h := hands[0]
	if h.HandID != hand || h.PlayedMs != 95_000 || h.Window != 24*time.Hour || len(h.Players) != 2 ||
		h.Levels[a.ID].XP != 7 || h.Levels[b.ID].XP != 6 {
		t.Errorf("the settled hand: %+v", h)
	}

	// A replay — a retry whose first commit's answer was lost.
	if _, err := f.ledger.Settle(f.ctx, req); codeOf(t, err) != game.CodeDuplicateAction {
		t.Fatalf("a replay must be duplicate_action, got %v", err)
	}
	if n := len(f.handLedgerRows(hand)); n != 3 || f.chips(a.ID) != welcome+pot-stake-tax {
		t.Fatalf("the replay wrote something: %d rows, wallet %d", n, f.chips(a.ID))
	}
	if f.find(a.ID).PlayerLevel.XP != 7 || f.find(b.ID).PlayerLevel.XP != 6 {
		t.Fatal("the replay awarded XP again")
	}
	if len(seen.all()) != 1 {
		t.Fatal("a settlement that did not commit must not be heard of")
	}
	f.reconcile()
}

// TestTheSettleAwardsXPOnlyToThoseWhoCompletedTheHand: HAND_COMPLETED to every
// outcome row of a player still at the table — a push included — HAND_WON to
// the winner as well, and nothing to a leaver's row or a money-only row; in
// every game (a poker hand's rows too).
func TestTheSettleAwardsXPOnlyToThoseWhoCompletedTheHand(t *testing.T) {
	f := newFixture(t)
	seen := &settledHands{}
	f.ledger.OnSettled(seen.hook)
	win, lose, push, leaver, money := f.user("W"), f.user("L"), f.user("P"), f.user("Gone"), f.user("Money")
	hand := "poker-hand-" + randomSuffix(t)
	pushed := settleEntry(hand, push.ID, 0, false, true, 0)
	pushed.Push = true
	gone := settleEntry(hand, leaver.ID, 0, false, true, 0)
	gone.LeftMidHand = true
	moneyOnly := game.SettleEntry{UserID: money.ID, Delta: -50, ActionID: game.SettleActionID(hand, money.ID), Reason: game.LedgerReasonHandLoss}
	entries := []game.SettleEntry{
		settleEntry(hand, win.ID, 150, true, true, 200), settleEntry(hand, lose.ID, -100, false, true, 0),
		pushed, gone, moneyOnly,
	}
	for i := range entries {
		entries[i].Game, entries[i].Variant = game.GamePoker, game.Category("texas_holdem")
	}
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "poker", HandID: hand, PlayedMs: 60_000, Entries: entries}); err != nil {
		t.Fatal(err)
	}
	for id, want := range map[string]int64{win.ID: 7, lose.ID: 6, push.ID: 6, leaver.ID: 0, money.ID: 0} {
		if got := f.find(id).PlayerLevel.XP; got != want {
			t.Errorf("%s: %d XP, want %d", f.find(id).DisplayName, got, want)
		}
	}
	h := seen.all()[0]
	if len(h.Players) != 3 || len(h.Levels) != 3 {
		t.Errorf("the settled hand's players %v and levels %v: the three who completed it", h.Players, h.Levels)
	}
	for _, id := range h.Players {
		if id == leaver.ID || id == money.ID {
			t.Errorf("%s did not complete the hand", id)
		}
	}
}

// TestTableTaxRowsAreNeverPurged: the purge takes a hand's hand_* rows once
// they are old enough and never its table_tax row — the house's revenue
// record, like a purchase.
func TestTableTaxRowsAreNeverPurged(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("Kept"), f.user("Purged")
	hand := "hand-purge-" + randomSuffix(t)
	winner := settleEntry(hand, a.ID, 1000-400, true, true, 2000)
	winner.Tax = 400
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "r", HandID: hand, Entries: []game.SettleEntry{
		winner, settleEntry(hand, b.ID, -1000, false, true, 0),
	}}); err != nil {
		t.Fatal(err)
	}
	deleted, err := f.d.PurgeLedger(f.ctx, time.Now().Add(time.Hour).UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	if deleted < 2 {
		t.Fatalf("the purge took %d rows, want the hand's hand_* rows", deleted)
	}
	rows := f.handLedgerRows(hand)
	if len(rows) != 1 || rows[0].Reason != game.LedgerReasonTableTax || rows[0].Delta != -400 {
		t.Fatalf("after the purge the hand keeps %+v, want its table_tax row alone", rows)
	}
}

// TestAnAccountReadIsOneQueryStill: the level rides the account's own read —
// a Users store with no player_xp row, a deleted level ladder or no settings
// row still reads the account (Level 0, no rate, no cap), never an error.
func TestAnAccountReadSurvivesAnEmptyLadder(t *testing.T) {
	f := newFixture(t)
	u := f.user("Ladderless")
	if _, err := f.d.Pool.Exec(context.Background(), `DELETE FROM player_levels; DELETE FROM xp_settings`); err != nil {
		t.Fatal(err)
	}
	got := f.find(u.ID).PlayerLevel
	if got != (db.PlayerLevel{}) {
		t.Fatalf("no ladder: %+v, want the zero level", got)
	}
}
