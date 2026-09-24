package db_test

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// The Lucky Draw (owner, 24 Sep 2026): a wheel of six prizes the server spins,
// grants and records in one transaction. These run against the owner's seeded
// draw, BEGINNER_LUCKY_DRAW (V1.0.1's THE LUCKY DRAW) — 1 hammer, 4 hammers,
// 10,00,000 chips, 1,00,000 chips, no reward and 5,00,000 chips, weighted 25,
// 15, 20, 20, 10 and 10, a spin every three days — and point slots at the
// other prizes where a test is about them.

// beginner is the seeded draw's code.
const beginner = "BEGINNER_LUCKY_DRAW"

// seededWeights are the seeded slots' weights in wheel order; landOn uses them
// to point the draw at one slot.
var seededWeights = []int64{25, 15, 20, 20, 10, 10}

// luckyClock is a clock a test moves by hand.
type luckyClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *luckyClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *luckyClock) advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// luckyStore is the Lucky Draw on the fixture's schema, on clock (nil: the
// real one).
func (f *fixture) luckyStore(clock func() time.Time) *db.LuckyDraws {
	return db.NewLuckyDraws(f.d, f.users, clock, nil)
}

// landOn points the draw at slotNumber of the seeded wheel, every slot active:
// the number drawn is where that slot starts along the weights laid end to end.
func landOn(t *testing.T, store *db.LuckyDraws, slotNumber int) {
	t.Helper()
	var start int64
	for i := 0; i < slotNumber-1; i++ {
		start += seededWeights[i]
	}
	store.SetLuckyPick(func(n int64) (int64, error) {
		if n != 100 {
			t.Errorf("the seeded wheel weighs 100 in all, the draw was handed %d", n)
		}
		return start, nil
	})
}

// exec runs one statement against the fixture's schema.
func (f *fixture) exec(sql string, args ...any) {
	f.t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, sql, args...); err != nil {
		f.t.Fatalf("%s: %v", sql, err)
	}
}

// noCooldown lets one account spin as often as a test likes.
func (f *fixture) noCooldown() {
	f.t.Helper()
	f.exec(`UPDATE lucky_draws SET cooldown_ms = 0 WHERE code = $1`, beginner)
}

// prize points one seeded slot at another prize, keeping its weight.
func (f *fixture) prize(slot int, rewardType string, value *int64, ref string) {
	f.t.Helper()
	var refID *string
	if ref != "" {
		refID = &ref
	}
	f.exec(`UPDATE lucky_draw_slots SET reward_type = $2, reward_value = $3, reward_ref_id = $4
	         WHERE slot_number = $1 AND lucky_draw_id = (SELECT id FROM lucky_draws WHERE code = $5)`,
		slot, rewardType, value, refID, beginner)
}

func amount(v int64) *int64 { return &v }

// pictureSlots puts Lovestruck Cat in slot 5 and Circle Background Pattern in
// slot 6, named by their catalogue ids on this database.
func (f *fixture) pictureSlots() (catID, circleID int64) {
	f.t.Helper()
	catID = f.scalar(`SELECT id FROM profile_pictures WHERE name = 'Lovestruck Cat'`)
	circleID = f.scalar(`SELECT id FROM table_pictures WHERE name = 'Circle Background Pattern'`)
	f.prize(5, db.LuckyRewardProfilePicture, nil, fmt.Sprint(catID))
	f.prize(6, db.LuckyRewardTablePicture, nil, fmt.Sprint(circleID))
	return catID, circleID
}

func (f *fixture) spins(userID string) int64 {
	f.t.Helper()
	return f.count(`SELECT count(*) FROM user_lucky_draws WHERE user_id = $1`, userID)
}

func (f *fixture) wallet(userID, column string) int64 {
	f.t.Helper()
	return f.scalar(`SELECT `+column+` FROM users WHERE id = $1`, userID)
}

func TestTheOwnersBeginnerDrawIsTheOneTheLobbyOpens(t *testing.T) {
	f := newFixture(t)
	u := f.user("looker")
	store := f.luckyStore(nil)
	state, err := store.State(f.ctx, u.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if state.Draw.Code != beginner || state.Draw.Name != "Beginner Lucky Draw" || state.Draw.SpinnerType != "BEGINNER" ||
		state.Draw.CooldownMs != 3*24*60*60*1000 {
		t.Fatalf("the draw the lobby opens: %+v", state.Draw)
	}
	if state.NextSpinAt != 0 {
		t.Fatalf("a player who never spun may spin now, got nextSpinAt %d", state.NextSpinAt)
	}
	want := []struct {
		kind  string
		value int64
	}{
		{db.LuckyRewardHammer, 1}, {db.LuckyRewardHammer, 4}, {db.LuckyRewardChips, 1_000_000},
		{db.LuckyRewardChips, 100_000}, {db.LuckyRewardNone, 0}, {db.LuckyRewardChips, 500_000},
	}
	if len(state.Slots) != db.LuckyDrawSlots {
		t.Fatalf("%d slots, want %d: %+v", len(state.Slots), db.LuckyDrawSlots, state.Slots)
	}
	for i, slot := range state.Slots {
		if slot.SlotNumber != i+1 || slot.RewardType != want[i].kind || slot.RewardValue == nil || *slot.RewardValue != want[i].value {
			t.Fatalf("slot %d: %+v (value %v), want number %d paying %d %s", i, slot, slot.RewardValue, i+1, want[i].value, want[i].kind)
		}
	}
	// Asked for by code, it is the same draw.
	if byCode, err := store.State(f.ctx, u.ID, beginner); err != nil || byCode.Draw.Code != beginner || len(byCode.Slots) != 6 {
		t.Fatalf("by code: %+v %v", byCode, err)
	}
	// How likely a slot is never leaves the server.
	body, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.ToLower(string(body)), "weight") {
		t.Fatalf("the weights reached the wire: %s", body)
	}
	// A draw nobody seeded is unavailable, and so is a retired one.
	if _, err := store.State(f.ctx, u.ID, "NO_SUCH_DRAW"); !errors.Is(err, db.ErrLuckyDrawUnavailable) {
		t.Fatalf("an unknown draw: %v", err)
	}
	f.exec(`UPDATE lucky_draws SET is_active = FALSE`)
	if _, err := store.State(f.ctx, u.ID, ""); !errors.Is(err, db.ErrLuckyDrawUnavailable) {
		t.Fatalf("with every draw retired: %v", err)
	}
}

// The lobby's draw is the first active one in sort_order, so a draw switched on
// ahead of the beginner one becomes the lobby's without a release.
func TestTheLobbysDrawIsTheFirstActiveOneInOrder(t *testing.T) {
	f := newFixture(t)
	u := f.user("orderly")
	f.exec(`INSERT INTO lucky_draws (code, name, spinner_type, cooldown_ms, sort_order) VALUES ('VIP_LUCKY_DRAW', 'VIP', 'VIP', 0, 5)`)
	f.exec(`INSERT INTO lucky_draw_slots (lucky_draw_id, slot_number, reward_type, reward_value, weight)
	         SELECT id, 1, 'DIAMOND', 50, 1 FROM lucky_draws WHERE code = 'VIP_LUCKY_DRAW'`)
	state, err := f.luckyStore(nil).State(f.ctx, u.ID, "")
	if err != nil || state.Draw.Code != "VIP_LUCKY_DRAW" || state.Draw.SpinnerType != "VIP" || len(state.Slots) != 1 {
		t.Fatalf("the first draw in order: %+v %v", state, err)
	}
	f.exec(`UPDATE lucky_draws SET is_active = FALSE WHERE code = 'VIP_LUCKY_DRAW'`)
	if state, err := f.luckyStore(nil).State(f.ctx, u.ID, ""); err != nil || state.Draw.Code != beginner {
		t.Fatalf("with the VIP draw retired: %+v %v", state, err)
	}
}

// Each currency prize lands in its wallet: chips through chip_ledger (reason
// lucky_draw, the spin's key), so every wallet still equals its ledger; the
// other three as deltas with no ledger row; NO_REWARD in none. Every spin is
// recorded with a snapshot of what it won.
func TestASpinGrantsEachPrizeIntoItsWallet(t *testing.T) {
	f := newFixture(t)
	f.noCooldown()
	f.prize(2, db.LuckyRewardDiamond, amount(5), "")
	f.prize(4, db.LuckyRewardMissile, amount(2), "")
	u := f.user("spinner")
	store := f.luckyStore(nil)

	chips, diamonds, hammers, missiles := f.wallet(u.ID, "chips"), f.wallet(u.ID, "diamond"), f.wallet(u.ID, "hammer"), f.wallet(u.ID, "missile")
	ledgerRows := len(f.ledgerRows(u.ID))

	for slot, key := range map[int]string{1: "spin-hammer", 2: "spin-diamonds", 3: "spin-chips", 4: "spin-missiles", 5: "spin-nothing"} {
		landOn(t, store, slot)
		spin, err := store.Spin(f.ctx, u.ID, "", key)
		if err != nil {
			t.Fatalf("slot %d: %v", slot, err)
		}
		if spin.SlotNumber != slot || spin.Replayed || spin.AlreadyOwned || spin.ActionID != key || spin.User == nil {
			t.Fatalf("slot %d: %+v", slot, spin)
		}
	}
	if got := f.wallet(u.ID, "chips"); got != chips+1_000_000 {
		t.Fatalf("chips %d, want %d", got, chips+1_000_000)
	}
	if got := f.wallet(u.ID, "diamond"); got != diamonds+5 {
		t.Fatalf("diamonds %d, want %d", got, diamonds+5)
	}
	if got := f.wallet(u.ID, "hammer"); got != hammers+1 {
		t.Fatalf("hammers %d, want %d", got, hammers+1)
	}
	if got := f.wallet(u.ID, "missile"); got != missiles+2 {
		t.Fatalf("missiles %d, want %d", got, missiles+2)
	}
	// One ledger row, for the chips alone.
	rows := f.ledgerRows(u.ID)
	if len(rows) != ledgerRows+1 {
		t.Fatalf("%d ledger rows, want %d", len(rows), ledgerRows+1)
	}
	last := rows[len(rows)-1]
	if last.Reason != game.LedgerReasonLuckyDraw || last.Delta != 1_000_000 || last.Balance != chips+1_000_000 ||
		last.ActionID == nil || *last.ActionID != db.LuckyDrawActionID(u.ID, "spin-chips") {
		t.Fatalf("the chips' ledger row: %+v", last)
	}
	f.reconcile()
	// Five spins recorded, each a snapshot of its prize — the empty one too.
	if n := f.spins(u.ID); n != 5 {
		t.Fatalf("%d spins recorded, want 5", n)
	}
	if n := f.count(`SELECT count(*) FROM user_lucky_draws WHERE user_id = $1 AND reward_type = 'MISSILE'
	                    AND reward_value = 2 AND reward_ref_id IS NULL AND action_id = $2`,
		u.ID, db.LuckyDrawActionID(u.ID, "spin-missiles")); n != 1 {
		t.Fatalf("the missiles' spin was not recorded as won: %d", n)
	}
	if n := f.count(`SELECT count(*) FROM user_lucky_draws WHERE user_id = $1 AND reward_type = 'NO_REWARD'`, u.ID); n != 1 {
		t.Fatalf("the empty spin was not recorded: %d", n)
	}
}

// The empty slot is a spin like any other: nothing is granted, and the cooldown
// starts all the same.
func TestTheEmptySlotPaysNothingAndStillStartsTheCooldown(t *testing.T) {
	f := newFixture(t)
	u := f.user("unlucky-one")
	store := f.luckyStore(nil)
	before := map[string]int64{}
	for _, column := range []string{"chips", "diamond", "hammer", "missile"} {
		before[column] = f.wallet(u.ID, column)
	}
	rows := len(f.ledgerRows(u.ID))
	landOn(t, store, 5)
	spin, err := store.Spin(f.ctx, u.ID, "", "empty")
	if err != nil || spin.Reward.Type != db.LuckyRewardNone || spin.SlotNumber != 5 || spin.NextSpinAt == 0 {
		t.Fatalf("the empty slot: %+v %v", spin, err)
	}
	for column, v := range before {
		if got := f.wallet(u.ID, column); got != v {
			t.Fatalf("the empty slot moved %s: %d → %d", column, v, got)
		}
	}
	if len(f.ledgerRows(u.ID)) != rows {
		t.Fatalf("the empty slot wrote a ledger row")
	}
	var cooldown *db.LuckyDrawCooldown
	if _, err := store.Spin(f.ctx, u.ID, "", "again"); !errors.As(err, &cooldown) {
		t.Fatalf("a second spin after an empty one: %v, want the cooldown", err)
	}
}

// A picture won is unlocked for the term the shop would sell it for — and not
// put on: the face and the table the player chose stay theirs to change.
func TestAPictureWonIsUnlockedForItsTermButNotPutOn(t *testing.T) {
	f := newFixture(t)
	f.noCooldown()
	catID, circleID := f.pictureSlots()
	u := f.user("picture-winner")
	clock := &luckyClock{now: time.Now()}
	store := f.luckyStore(clock.Now)

	state, err := store.State(f.ctx, u.ID, "")
	if err != nil || state.Slots[4].Picture == nil || state.Slots[4].Picture.Name != "Lovestruck Cat" || state.Slots[4].Picture.Owned ||
		state.Slots[5].TablePicture == nil || state.Slots[5].TablePicture.ID != circleID {
		t.Fatalf("a picture prize is offered with its catalogue row: %+v %v", state, err)
	}

	landOn(t, store, 5)
	spin, err := store.Spin(f.ctx, u.ID, "", "cat")
	if err != nil {
		t.Fatal(err)
	}
	at := clock.Now().UnixMilli()
	pic := spin.Reward.Picture
	if spin.Reward.Type != db.LuckyRewardProfilePicture || pic == nil || pic.ID != catID || !pic.Owned || spin.AlreadyOwned {
		t.Fatalf("the cat: %+v", spin)
	}
	// Lovestruck Cat rents for 50 days in the shop, and so it does here.
	if want := at + 50*db.DayMs; pic.ExpiresAt != want {
		t.Fatalf("expires at %d, want %d (50 days from the spin)", pic.ExpiresAt, want)
	}
	if found, _, err := f.pictures.Find(f.ctx, u.ID, catID); err != nil || !found.Owned {
		t.Fatalf("the catalogue does not count it as theirs: %+v %v", found, err)
	}
	if fresh := f.find(u.ID); fresh.ActivePictureID != nil {
		t.Fatalf("a picture won was put on: %v", *fresh.ActivePictureID)
	}

	landOn(t, store, 6)
	spin, err = store.Spin(f.ctx, u.ID, "", "circle")
	if err != nil {
		t.Fatal(err)
	}
	table := spin.Reward.TablePicture
	if spin.Reward.Type != db.LuckyRewardTablePicture || table == nil || !table.Owned || table.ExpiresAt != at+7*db.DayMs {
		t.Fatalf("the table picture: %+v", spin.Reward)
	}
	if n := f.count(`SELECT count(*) FROM user_table_pictures WHERE user_id = $1 AND table_picture_id = $2`, u.ID, circleID); n != 1 {
		t.Fatalf("%d ownership rows for the table picture", n)
	}
	if n := f.count(`SELECT count(*) FROM user_table_choice WHERE user_id = $1`, u.ID); n != 0 {
		t.Fatalf("a table picture won was laid")
	}
	// No chips moved for either.
	f.reconcile()
}

// A picture the player already has is not granted again: the spin is recorded,
// the ownership row — its term, its purchase count — is left exactly as it
// was. One whose rental has lapsed is renewed in place, for a fresh term.
func TestAPictureAlreadyOwnedIsLeftAloneAndALapsedOneRenewed(t *testing.T) {
	f := newFixture(t)
	f.noCooldown()
	catID, _ := f.pictureSlots()
	u := f.user("owner")
	store := f.luckyStore(nil)
	const farOff = int64(9_000_000_000_000)
	f.exec(`INSERT INTO user_profile_pictures (user_id, profile_picture_id, acquired_at, expires_at, purchases)
	         VALUES ($1, $2, 1, $3, 2)`, u.ID, catID, farOff)
	landOn(t, store, 5)
	spin, err := store.Spin(f.ctx, u.ID, "", "owned")
	if err != nil {
		t.Fatal(err)
	}
	if !spin.AlreadyOwned || spin.Reward.Picture == nil || !spin.Reward.Picture.Owned {
		t.Fatalf("an owned picture: %+v", spin)
	}
	var acquired, expires, purchases int64
	if err := f.d.Pool.QueryRow(f.ctx,
		`SELECT acquired_at, expires_at, purchases FROM user_profile_pictures WHERE user_id = $1 AND profile_picture_id = $2`,
		u.ID, catID).Scan(&acquired, &expires, &purchases); err != nil {
		t.Fatal(err)
	}
	if acquired != 1 || expires != farOff || purchases != 2 {
		t.Fatalf("the ownership row moved: acquired %d expires %d purchases %d", acquired, expires, purchases)
	}
	if n := f.count(`SELECT count(*) FROM user_profile_pictures WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("%d ownership rows, want 1", n)
	}
	if f.spins(u.ID) != 1 {
		t.Fatalf("the spin was not recorded")
	}

	// Lapsed: renewed from now, the purchase count as it was.
	f.exec(`UPDATE user_profile_pictures SET expires_at = 5 WHERE user_id = $1 AND profile_picture_id = $2`, u.ID, catID)
	spin, err = store.Spin(f.ctx, u.ID, "", "lapsed")
	if err != nil {
		t.Fatal(err)
	}
	if spin.AlreadyOwned || spin.Reward.Picture == nil || spin.Reward.Picture.ExpiresAt <= nowMs() {
		t.Fatalf("a lapsed rental: %+v", spin.Reward.Picture)
	}
	if err := f.d.Pool.QueryRow(f.ctx,
		`SELECT purchases FROM user_profile_pictures WHERE user_id = $1 AND profile_picture_id = $2`,
		u.ID, catID).Scan(&purchases); err != nil {
		t.Fatal(err)
	}
	if purchases != 2 {
		t.Fatalf("a prize counted as a purchase: purchases %d", purchases)
	}
}

// The cooldown is the server's: a second spin inside it is refused with the
// moment it recharges, draws nothing and records nothing; the state says the
// same moment; at that moment the draw may be spun again.
func TestTheCooldownIsKeptByTheServer(t *testing.T) {
	f := newFixture(t)
	u := f.user("eager")
	clock := &luckyClock{now: time.Now()}
	store := f.luckyStore(clock.Now)
	landOn(t, store, 1)

	first, err := store.Spin(f.ctx, u.ID, "", "first")
	if err != nil {
		t.Fatal(err)
	}
	threeDays := int64(3 * 24 * 60 * 60 * 1000)
	recharged := clock.Now().UnixMilli() + threeDays
	if first.NextSpinAt != recharged {
		t.Fatalf("nextSpinAt %d, want %d", first.NextSpinAt, recharged)
	}
	hammers := f.wallet(u.ID, "hammer")

	clock.advance(time.Hour)
	_, err = store.Spin(f.ctx, u.ID, "", "second")
	var cooldown *db.LuckyDrawCooldown
	if !errors.As(err, &cooldown) || cooldown.NextSpinAt != recharged {
		t.Fatalf("a spin an hour later: %v, want the cooldown until %d", err, recharged)
	}
	if f.spins(u.ID) != 1 || f.wallet(u.ID, "hammer") != hammers {
		t.Fatalf("a refused spin drew something: %d spins, %d hammers", f.spins(u.ID), f.wallet(u.ID, "hammer"))
	}
	state, err := store.State(f.ctx, u.ID, "")
	if err != nil || state.NextSpinAt != recharged {
		t.Fatalf("state: %+v %v", state, err)
	}

	clock.advance(3*24*time.Hour - time.Hour)
	if _, err := store.Spin(f.ctx, u.ID, "", "third"); err != nil {
		t.Fatalf("a spin three days later: %v", err)
	}
	if f.spins(u.ID) != 2 {
		t.Fatalf("%d spins recorded, want 2", f.spins(u.ID))
	}
}

// One action id is one spin: a retry — even inside the cooldown the first one
// started — answers that spin again and grants nothing; a burst of the same
// request at once grants once.
func TestASpinIsGrantedOncePerActionID(t *testing.T) {
	f := newFixture(t)
	u := f.user("retrier")
	store := f.luckyStore(nil)
	landOn(t, store, 3)
	chips := f.wallet(u.ID, "chips")

	first, err := store.Spin(f.ctx, u.ID, "", "tap-1")
	if err != nil {
		t.Fatal(err)
	}
	again, err := store.Spin(f.ctx, u.ID, "", "tap-1")
	if err != nil {
		t.Fatalf("a retry of a spin that landed: %v", err)
	}
	if !again.Replayed || again.SlotNumber != first.SlotNumber || again.Reward.Type != first.Reward.Type ||
		*again.Reward.Value != *first.Reward.Value || again.NextSpinAt != first.NextSpinAt || again.ActionID != "tap-1" {
		t.Fatalf("the replay: %+v, first %+v", again, first)
	}
	if f.wallet(u.ID, "chips") != chips+1_000_000 || f.spins(u.ID) != 1 {
		t.Fatalf("a retry paid again: chips %d spins %d", f.wallet(u.ID, "chips"), f.spins(u.ID))
	}
	f.reconcile()

	// A burst of one request from another player, all at once.
	v := f.user("burst")
	burst := f.luckyStore(nil)
	landOn(t, burst, 3)
	vChips := f.wallet(v.ID, "chips")
	var wg sync.WaitGroup
	answers := make([]*db.LuckyDrawSpin, 8)
	errs := make([]error, len(answers))
	for i := range answers {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			answers[i], errs[i] = burst.Spin(f.ctx, v.ID, "", "same-tap")
		}(i)
	}
	wg.Wait()
	granted := 0
	for i, err := range errs {
		if err != nil {
			t.Fatalf("burst %d: %v", i, err)
		}
		if answers[i].SlotNumber != 3 {
			t.Fatalf("burst %d landed on %d", i, answers[i].SlotNumber)
		}
		if !answers[i].Replayed {
			granted++
		}
	}
	if granted != 1 || f.wallet(v.ID, "chips") != vChips+1_000_000 || f.spins(v.ID) != 1 {
		t.Fatalf("a burst of one spin granted %d times: chips %d spins %d", granted, f.wallet(v.ID, "chips"), f.spins(v.ID))
	}
	f.reconcile()

	// An empty key is refused before anything is read.
	if _, err := store.Spin(f.ctx, u.ID, "", ""); !errors.Is(err, db.ErrLuckyDrawActionID) {
		t.Fatalf("an empty action id: %v", err)
	}
}

// A slot that is retired, or holds a prize this build cannot grant, is neither
// offered nor drawn; the draw is laid out over the slots left; and a draw with
// none left is unavailable.
func TestSlotsThatCannotBeWonAreNeitherOfferedNorDrawn(t *testing.T) {
	f := newFixture(t)
	f.noCooldown()
	u := f.user("chooser")
	f.exec(`UPDATE lucky_draw_slots SET is_active = FALSE WHERE slot_number = 3`)
	f.prize(4, "AVATAR_FRAME", nil, "golden_crown_frame")
	f.prize(2, db.LuckyRewardHammer, amount(0), "")
	store := f.luckyStore(nil)
	state, err := store.State(f.ctx, u.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	var numbers []int
	for _, s := range state.Slots {
		numbers = append(numbers, s.SlotNumber)
	}
	if len(numbers) != 3 || numbers[0] != 1 || numbers[1] != 5 || numbers[2] != 6 {
		t.Fatalf("slots offered %v, want [1 5 6]", numbers)
	}
	// Laid end to end the three weigh 25 + 10 + 10: every number lands on one of
	// them, the empty slot included.
	for r, want := range map[int64]int{0: 1, 24: 1, 25: 5, 34: 5, 35: 6, 44: 6} {
		store.SetLuckyPick(func(n int64) (int64, error) {
			if n != 45 {
				t.Errorf("the draw was handed %d, want 45", n)
			}
			return r, nil
		})
		spin, err := store.Spin(f.ctx, u.ID, "", fmt.Sprintf("r-%d", r))
		if err != nil || spin.SlotNumber != want {
			t.Fatalf("drew %d: %+v %v, want slot %d", r, spin, err, want)
		}
	}
	// A picture that is gone from its catalogue, or retired there, is not a prize.
	f.prize(5, db.LuckyRewardProfilePicture, nil, "999999")
	f.prize(6, db.LuckyRewardTablePicture, nil, fmt.Sprint(f.scalar(`SELECT id FROM table_pictures WHERE name = 'Welcome'`)))
	f.exec(`UPDATE table_pictures SET is_active = FALSE WHERE name = 'Welcome'`)
	f.exec(`UPDATE lucky_draw_slots SET is_active = FALSE WHERE slot_number = 1`)
	if _, err := store.State(f.ctx, u.ID, ""); !errors.Is(err, db.ErrLuckyDrawUnavailable) {
		t.Fatalf("a draw with nothing left to win: %v", err)
	}
	if _, err := store.Spin(f.ctx, u.ID, "", "nothing"); !errors.Is(err, db.ErrLuckyDrawUnavailable) {
		t.Fatalf("spinning a draw with nothing left to win: %v", err)
	}
}

// A weight is a share, so it must be positive; the database refuses anything
// else, for an insert and an update alike, and a slot number off the wheel.
func TestASlotWeightMustBePositive(t *testing.T) {
	f := newFixture(t)
	for _, weight := range []int{0, -5} {
		_, err := f.d.Pool.Exec(f.ctx, `UPDATE lucky_draw_slots SET weight = $1 WHERE slot_number = 1`, weight)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
			t.Fatalf("weight %d was accepted: %v", weight, err)
		}
		code := fmt.Sprintf("WEIGHT_%d", weight+100)
		f.exec(`INSERT INTO lucky_draws (code, name) VALUES ($1, 'w')`, code)
		_, err = f.d.Pool.Exec(f.ctx,
			`INSERT INTO lucky_draw_slots (lucky_draw_id, slot_number, reward_type, reward_value, weight)
			 SELECT id, 1, 'CHIPS', 1, $1 FROM lucky_draws WHERE code = $2`, weight, code)
		if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
			t.Fatalf("a new slot of weight %d was accepted: %v", weight, err)
		}
	}
	_, err := f.d.Pool.Exec(f.ctx, `UPDATE lucky_draw_slots SET slot_number = 7 WHERE slot_number = 6`)
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
		t.Fatalf("slot 7 was accepted: %v", err)
	}
}

// All or nothing: a prize that cannot be granted leaves no record of a spin,
// and a spin that cannot be recorded takes its prize back out with it.
func TestASpinIsGrantedAndRecordedTogetherOrNotAtAll(t *testing.T) {
	f := newFixture(t)
	f.noCooldown()
	f.prize(2, db.LuckyRewardDiamond, amount(5), "")
	u := f.user("unlucky")
	store := f.luckyStore(nil)

	// The record cannot be written: the chips the spin paid go back out.
	f.exec(`
		CREATE FUNCTION refuse_spin() RETURNS trigger AS $fn$
		BEGIN RAISE EXCEPTION 'no spin today'; END;
		$fn$ LANGUAGE plpgsql;
		CREATE TRIGGER refuse_spin BEFORE INSERT ON user_lucky_draws FOR EACH ROW EXECUTE FUNCTION refuse_spin();`)
	chips, rows := f.wallet(u.ID, "chips"), len(f.ledgerRows(u.ID))
	landOn(t, store, 3)
	if _, err := store.Spin(f.ctx, u.ID, "", "unrecorded"); err == nil || !strings.Contains(err.Error(), "no spin today") {
		t.Fatalf("a spin that could not be recorded: %v", err)
	}
	if f.wallet(u.ID, "chips") != chips || len(f.ledgerRows(u.ID)) != rows || f.spins(u.ID) != 0 {
		t.Fatalf("an unrecorded spin paid: chips %d→%d, ledger %d→%d", chips, f.wallet(u.ID, "chips"), rows, len(f.ledgerRows(u.ID)))
	}
	f.exec(`DROP TRIGGER refuse_spin ON user_lucky_draws; DROP FUNCTION refuse_spin();`)

	// The prize cannot be granted — a diamond wallet already as full as its
	// column goes: nothing is recorded.
	f.exec(`UPDATE users SET diamond = 2147483647 WHERE id = $1`, u.ID)
	landOn(t, store, 2)
	if _, err := store.Spin(f.ctx, u.ID, "", "overfull"); err == nil {
		t.Fatalf("a prize the wallet cannot hold was granted")
	}
	if f.spins(u.ID) != 0 {
		t.Fatalf("a spin whose prize failed was recorded")
	}

	// And the next spin works, with a key the failures never used up.
	f.exec(`UPDATE users SET diamond = 0 WHERE id = $1`, u.ID)
	spin, err := store.Spin(f.ctx, u.ID, "", "overfull")
	if err != nil || spin.Replayed || f.wallet(u.ID, "diamond") != 5 || f.spins(u.ID) != 1 {
		t.Fatalf("after the failures: %+v %v", spin, err)
	}
	f.reconcile()
}

// A deleted account cannot spin: its wallet is gone.
func TestADeletedAccountCannotSpin(t *testing.T) {
	f := newFixture(t)
	u := f.user("gone")
	if err := f.users.DeleteAccount(f.ctx, u.ID); err != nil {
		t.Fatal(err)
	}
	_, err := f.luckyStore(nil).Spin(f.ctx, u.ID, "", "ghost")
	if game.CodeOf(err, "") != game.CodeUnknownUser {
		t.Fatalf("a deleted account spun: %v", err)
	}
}
