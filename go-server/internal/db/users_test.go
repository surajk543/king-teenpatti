package db_test

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// settle is the statsAndRewards helper: one synthetic hand, no version/state,
// no pot row — the counters still move.
func (f *fixture) settle(entries []game.SettleEntry, pot int64) {
	f.t.Helper()
	var winner *string
	for _, e := range entries {
		if e.IsWinner {
			winner = ptr(e.UserID)
			break
		}
	}
	handID := "hand-" + randomSuffix(f.t)
	filled := make([]game.SettleEntry, len(entries))
	for i, e := range entries {
		e.ActionID = game.SettleActionID(handID, e.UserID)
		e.Outcome = true
		if e.Reason == "" {
			e.Reason = game.LedgerReasonHandLoss
			if e.IsWinner {
				e.Reason = game.LedgerReasonHandWin
				e.Pot = pot
			}
		}
		filled[i] = e
	}
	_ = winner
	_, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "room-stats", HandID: handID, Entries: filled})
	if err != nil {
		f.t.Fatalf("settle: %v", err)
	}
}

// setHandsPlayed reaches past the API to put a career's worth of hands on the
// counter, so the milestone tests do not have to settle 25 hands apiece.
func (f *fixture) setHandsPlayed(userID string, n int) {
	f.t.Helper()
	if err := f.d.Exec(f.ctx, `UPDATE users SET hands_played = $1 WHERE id = $2`, n, userID); err != nil {
		f.t.Fatal(err)
	}
}

// -------------------------------------------------------------- statistics

func TestAHandOnlyCountsAsPlayedOnceThePlayerBetsBeyondTheBoot(t *testing.T) {
	f := newFixture(t)
	better, folder := f.user("Better"), f.user("Folder")
	f.settle([]game.SettleEntry{
		{UserID: better.ID, Delta: 400, IsWinner: true, DidChaal: true},
		// Posted the boot, then packed without ever betting.
		{UserID: folder.ID, Delta: -200, DidChaal: false},
	}, 600)
	if f.find(better.ID).HandsPlayed != 1 {
		t.Fatal("the player who bet has played a hand")
	}
	if f.find(folder.ID).HandsPlayed != 0 {
		t.Fatal("posting the boot alone is not playing")
	}
}

func TestWinsLossesAndAbandonedHandsAreCountedSeparately(t *testing.T) {
	f := newFixture(t)
	winner, loser, quitter := f.user("W"), f.user("L"), f.user("Q")
	f.settle([]game.SettleEntry{
		{UserID: winner.ID, Delta: 800, IsWinner: true, DidChaal: true},
		{UserID: loser.ID, Delta: -400, DidChaal: true},
		{UserID: quitter.ID, Delta: -400, DidChaal: true, LeftMidHand: true},
	}, 1600)
	w, l, q := f.find(winner.ID), f.find(loser.ID), f.find(quitter.ID)
	if w.HandsWon != 1 || w.HandsLost != 0 || w.HandsLeftMid != 0 {
		t.Fatalf("winner = %+v", w)
	}
	if l.HandsWon != 0 || l.HandsLost != 1 || l.HandsLeftMid != 0 {
		t.Fatalf("loser = %+v", l)
	}
	if q.HandsLeftMid != 1 {
		t.Fatal("leaving mid-hand is tracked on its own")
	}
	if q.HandsLost != 0 {
		t.Fatal("and is not also counted as a loss")
	}
	if q.HandsPlayed != 1 {
		t.Fatal("they had bet, so the hand still counts as played")
	}
}

func TestTotalWinningsAccumulateThePotsTaken(t *testing.T) {
	f := newFixture(t)
	player := f.user("Rich")
	f.settle([]game.SettleEntry{{UserID: player.ID, Delta: 500, IsWinner: true, DidChaal: true}}, 1000)
	f.settle([]game.SettleEntry{{UserID: player.ID, Delta: 900, IsWinner: true, DidChaal: true}}, 2500)
	row := f.find(player.ID)
	if row.TotalWinnings != 3500 {
		t.Fatalf("totalWinnings = %d, want the two pots summed (gross, not net)", row.TotalWinnings)
	}
	if row.BiggestPot != 2500 || row.HandsWon != 2 {
		t.Fatalf("row = %+v", row)
	}
}

// ------------------------------------------------- milestone reward (req 17)

func TestTheMilestoneRewardUnlocksEvery25PlayedHands(t *testing.T) {
	f := newFixture(t)
	player := f.user("Grinder")

	fresh := f.find(player.ID)
	if fresh.Rewards.MilestoneAvailable || fresh.Rewards.HandsToNextMilestone != 25 {
		t.Fatalf("fresh rewards = %+v", fresh.Rewards)
	}
	f.setHandsPlayed(player.ID, 24)
	nearly := f.find(player.ID)
	if nearly.Rewards.MilestoneAvailable || nearly.Rewards.HandsToNextMilestone != 1 {
		t.Fatalf("at 24: %+v", nearly.Rewards)
	}
	f.setHandsPlayed(player.ID, 25)
	ready := f.find(player.ID)
	if !ready.Rewards.MilestoneAvailable || ready.Rewards.MilestoneAt != 25 || ready.Rewards.MilestoneReward != 25000 {
		t.Fatalf("at 25: %+v", ready.Rewards)
	}
	// The documented quirk: 25 (not 0) to the next milestone at an exact multiple.
	if ready.Rewards.HandsToNextMilestone != 25 || ready.Rewards.MilestoneEvery != 25 {
		t.Fatalf("at 25: %+v", ready.Rewards)
	}
}

func TestCollectingTheMilestoneRewardGrants25000ChipsExactlyOnce(t *testing.T) {
	f := newFixture(t)
	player := f.user("Collector")
	f.setHandsPlayed(player.ID, 50)
	before := f.find(player.ID).Chips

	first, err := f.users.ClaimMilestoneReward(f.ctx, player.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !first.Claimed || first.Amount != 25000 || first.Milestone != 50 || first.User.Chips != before+25000 {
		t.Fatalf("first = %+v", first)
	}
	if first.User.Rewards.MilestoneAvailable {
		t.Fatal("the same milestone is now spent")
	}

	second, err := f.users.ClaimMilestoneReward(f.ctx, player.ID)
	if err != nil {
		t.Fatal(err)
	}
	if second.Claimed || second.Reason != db.RewardNotAvailable || second.User == nil {
		t.Fatalf("second = %+v", second)
	}
	if f.find(player.ID).Chips != before+25000 {
		t.Fatal("a second claim moved chips")
	}
	// The milestone action id makes the same grant unrepeatable at the DB too.
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE action_id = $1`, fmt.Sprintf("%s:milestone:50", player.ID)); n != 1 {
		t.Fatalf("milestone rows = %d", n)
	}
	f.reconcile()
}

func TestReachingTheNextMilestoneUnlocksTheRewardAgain(t *testing.T) {
	f := newFixture(t)
	player := f.user("Repeater")
	f.setHandsPlayed(player.ID, 25)
	if r, _ := f.users.ClaimMilestoneReward(f.ctx, player.ID); !r.Claimed {
		t.Fatal("claim at 25")
	}
	f.setHandsPlayed(player.ID, 49)
	if f.find(player.ID).Rewards.MilestoneAvailable {
		t.Fatal("still on the 25 milestone")
	}
	f.setHandsPlayed(player.ID, 50)
	if !f.find(player.ID).Rewards.MilestoneAvailable {
		t.Fatal("50 is a new milestone")
	}
	if r, _ := f.users.ClaimMilestoneReward(f.ctx, player.ID); !r.Claimed {
		t.Fatal("claim at 50")
	}
}

func TestSkippedMilestonesAreForfeited(t *testing.T) {
	f := newFixture(t)
	player := f.user("Skipper")
	f.setHandsPlayed(player.ID, 25)
	if r, _ := f.users.ClaimMilestoneReward(f.ctx, player.ID); !r.Claimed || r.Milestone != 25 {
		t.Fatalf("first = %+v", r)
	}
	f.setHandsPlayed(player.ID, 77)
	r, err := f.users.ClaimMilestoneReward(f.ctx, player.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !r.Claimed || r.Milestone != 75 || r.Amount != 25000 {
		t.Fatalf("second = %+v", r)
	}
	if again, _ := f.users.ClaimMilestoneReward(f.ctx, player.ID); again.Claimed {
		t.Fatal("milestone_claimed must jump to 75; the skipped 50 pays nothing")
	}
	if f.find(player.ID).Chips != welcome+50000 {
		t.Fatalf("chips = %d", f.find(player.ID).Chips)
	}
}

func TestTheMilestoneRewardIsWrittenToTheChipLedger(t *testing.T) {
	f := newFixture(t)
	player := f.user("Audited")
	f.setHandsPlayed(player.ID, 25)
	if _, err := f.users.ClaimMilestoneReward(f.ctx, player.ID); err != nil {
		t.Fatal(err)
	}
	var found []ledgerRow
	for _, r := range f.ledgerRows(player.ID) {
		if r.Reason == "milestone_reward" {
			found = append(found, r)
		}
	}
	if len(found) != 1 || found[0].Delta != 25000 || found[0].Balance != welcome+25000 || found[0].HandID != nil ||
		found[0].ActionID == nil || *found[0].ActionID != player.ID+":milestone:25" {
		t.Fatalf("milestone rows = %+v", found)
	}
	f.reconcile()
}

func TestClaimingForAnUnknownUserIsAnError(t *testing.T) {
	f := newFixture(t)
	if _, err := f.users.ClaimMilestoneReward(f.ctx, "nobody"); err == nil || err.Error() != "unknown user nobody" {
		t.Fatalf("milestone: %v", err)
	}
	if _, err := f.users.ClaimTimedBonus(f.ctx, "nobody"); err == nil || err.Error() != "unknown user nobody" {
		t.Fatalf("bonus: %v", err)
	}
}

// ----------------------------------------------------- timed bonus (req 18)

func TestANewAccountCanCollectTheTimedBonusStraightAway(t *testing.T) {
	f := newFixture(t)
	player := f.user("Fresh")
	rewards := f.find(player.ID).Rewards
	if !rewards.BonusAvailable {
		t.Fatal("no waiting on a brand new account")
	}
	if rewards.BonusReward != 10000 || rewards.BonusIntervalMs != 4*60*60*1000 || rewards.BonusReadyAt != 0 {
		t.Fatalf("rewards = %+v", rewards)
	}
}

func TestCollectingTheBonusGrants10000ChipsAndStartsA4HourCountdown(t *testing.T) {
	f := newFixture(t)
	player := f.user("Bonus")
	before := f.find(player.ID).Chips

	claimedAt := nowMs()
	result, err := f.users.ClaimTimedBonus(f.ctx, player.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Claimed || result.Amount != 10000 || result.User.Chips != before+10000 {
		t.Fatalf("result = %+v", result)
	}
	fourHours := int64(4 * 60 * 60 * 1000)
	if result.ReadyAt < claimedAt+fourHours-1000 || result.ReadyAt > nowMs()+fourHours+1000 {
		t.Fatalf("readyAt %d is not ~4h out from %d", result.ReadyAt, claimedAt)
	}
	if result.User.Rewards.BonusAvailable {
		t.Fatal("and is not collectable now")
	}
	if result.User.Rewards.BonusReadyAt != result.ReadyAt {
		t.Fatal("user.rewards.bonusReadyAt must be the persisted unlock time")
	}
	f.reconcile()
}

func TestTheBonusCannotBeCollectedTwiceInsideTheCountdown(t *testing.T) {
	f := newFixture(t)
	player := f.user("Greedy")
	if _, err := f.users.ClaimTimedBonus(f.ctx, player.ID); err != nil {
		t.Fatal(err)
	}
	before := f.find(player.ID).Chips
	second, err := f.users.ClaimTimedBonus(f.ctx, player.ID)
	if err != nil {
		t.Fatal(err)
	}
	if second.Claimed || second.Reason != db.RewardNotReady || second.ReadyAt <= nowMs() || second.User == nil {
		t.Fatalf("second = %+v", second)
	}
	if f.find(player.ID).Chips != before {
		t.Fatal("no chips moved")
	}
	// The bonus row has no action id (the row lock is its only guard).
	rows := f.ledgerRows(player.ID)
	last := rows[len(rows)-1]
	if last.Reason != "timed_bonus" || last.Delta != 10000 || last.ActionID != nil || last.HandID != nil {
		t.Fatalf("bonus row = %+v", last)
	}
}

func TestTheCountdownLivesInTheDatabase(t *testing.T) {
	f := newFixture(t)
	player := f.user("Persistent")
	result, err := f.users.ClaimTimedBonus(f.ctx, player.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored := f.scalar(`SELECT next_bonus_at FROM users WHERE id = $1`, player.ID); stored != result.ReadyAt {
		t.Fatalf("next_bonus_at %d != readyAt %d — the unlock time is persisted, not held in memory", stored, result.ReadyAt)
	}
	// Once the stored time passes, it is collectable again.
	if err := f.d.Exec(f.ctx, `UPDATE users SET next_bonus_at = $1 WHERE id = $2`, nowMs()-1, player.ID); err != nil {
		t.Fatal(err)
	}
	if !f.find(player.ID).Rewards.BonusAvailable {
		t.Fatal("bonusAvailable is evaluated against now")
	}
	if r, _ := f.users.ClaimTimedBonus(f.ctx, player.ID); !r.Claimed {
		t.Fatal("claim after the countdown")
	}
}

// A fixed clock proves every row of a claim shares one timestamp and that
// readyAt = now + 4h exactly.
func TestRewardsUseOneTimestampPerTransaction(t *testing.T) {
	f := newFixture(t)
	fixed := time.UnixMilli(1_800_000_000_000)
	users := db.NewUsers(f.d, welcome, func() time.Time { return fixed })
	player := f.user("Clocked")

	r, err := users.ClaimTimedBonus(f.ctx, player.ID)
	if err != nil {
		t.Fatal(err)
	}
	if r.ReadyAt != fixed.UnixMilli()+db.TimedBonusInterval.Milliseconds() {
		t.Fatalf("readyAt = %d", r.ReadyAt)
	}
	rows := f.ledgerRows(player.ID)
	if rows[len(rows)-1].Created != fixed.UnixMilli() {
		t.Fatalf("ledger created_at = %d", rows[len(rows)-1].Created)
	}
	if f.scalar(`SELECT updated_at FROM users WHERE id = $1`, player.ID) != fixed.UnixMilli() {
		t.Fatal("users.updated_at differs from the ledger row")
	}
	// With the clock frozen before readyAt the bonus reads as unavailable.
	if r.User.Rewards.BonusAvailable {
		t.Fatal("bonusAvailable must be false right after claiming")
	}
}

// ------------------------------------------------------ avatars (req 20/21)

func TestAProviderPictureIsKeptAndUsedByDefault(t *testing.T) {
	f := newFixture(t)
	user, _, err := f.users.UpsertFromProfile(f.ctx, db.Profile{
		Provider: db.ProviderGoogle, ProviderUserID: "g-" + randomSuffix(t), DisplayName: "G Player",
		AvatarURL: ptr("https://lh3.googleusercontent.com/example"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if user.AvatarURL == nil || *user.AvatarURL != "https://lh3.googleusercontent.com/example" {
		t.Fatalf("avatarUrl = %v", user.AvatarURL)
	}
	if user.ProviderAvatarURL == nil || *user.ProviderAvatarURL != "https://lh3.googleusercontent.com/example" {
		t.Fatalf("providerAvatarUrl = %v", user.ProviderAvatarURL)
	}
	if user.ActivePictureID != nil {
		t.Fatalf("activePictureId = %v, want null", *user.ActivePictureID)
	}
}

// newGuest is a funded account to spend on pictures.
func newGuest(t *testing.T, f *fixture) *db.User {
	t.Helper()
	user, _, err := f.users.UpsertFromProfile(f.ctx, db.Profile{
		Provider: db.ProviderGuest, ProviderUserID: "p-" + randomSuffix(t), DisplayName: "Buyer",
	})
	if err != nil {
		t.Fatal(err)
	}
	return user
}

// freePicture returns a free catalogue row, and premiumPicture a paid one, as
// seeded by schema.sql. They are looked up rather than hardcoded because the
// catalogue is data the owner is expected to edit.
func freePicture(t *testing.T, f *fixture) db.Picture {
	t.Helper()
	return pictureOfType(t, f, db.PictureFree)
}

func premiumPicture(t *testing.T, f *fixture) db.Picture {
	t.Helper()
	return pictureOfType(t, f, db.PicturePremium)
}

func pictureOfType(t *testing.T, f *fixture, kind string) db.Picture {
	t.Helper()
	all, err := f.pictures.List(f.ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range all {
		if p.Type == kind {
			return p
		}
	}
	t.Fatalf("no %s picture in the seeded catalogue", kind)
	return db.Picture{}
}

func TestTheSeededCatalogueOffersFreeAndPremiumPictures(t *testing.T) {
	f := newFixture(t)
	all, err := f.pictures.List(f.ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) == 0 {
		t.Fatal("schema.sql seeds no pictures")
	}
	var free, premium int
	for i, p := range all {
		switch p.Type {
		case db.PictureFree:
			free++
			if p.Cost != 0 || !p.Owned {
				t.Errorf("free picture %q: cost=%d owned=%v", p.Name, p.Cost, p.Owned)
			}
		case db.PicturePremium:
			premium++
			if p.Cost <= 0 {
				t.Errorf("premium picture %q costs %d", p.Name, p.Cost)
			}
			// Nobody owns a premium picture until they buy it, and an
			// anonymous caller owns nothing at all.
			if p.Owned {
				t.Errorf("premium picture %q is owned by nobody", p.Name)
			}
		default:
			t.Errorf("unknown type %q", p.Type)
		}
		if p.Name == "" || p.URL == "" {
			t.Errorf("picture %d is missing a name or image", p.ID)
		}
		if i > 0 && all[i-1].SortOrder > p.SortOrder {
			t.Errorf("catalogue is not in display order at %d", i)
		}
	}
	if free == 0 || premium == 0 {
		t.Fatalf("free=%d premium=%d — the catalogue needs both", free, premium)
	}
}

func TestAChosenPictureOverridesTheProviderOneAndClearingRestoresIt(t *testing.T) {
	f := newFixture(t)
	user, _, err := f.users.UpsertFromProfile(f.ctx, db.Profile{
		Provider: db.ProviderFacebook, ProviderUserID: "f-" + randomSuffix(t), DisplayName: "F Player",
		AvatarURL: ptr("https://graph.facebook.com/example"),
	})
	if err != nil {
		t.Fatal(err)
	}
	pic := freePicture(t, f)

	chosen, err := f.users.SetActivePicture(f.ctx, user.ID, &pic.ID)
	if err != nil {
		t.Fatal(err)
	}
	if chosen.AvatarURL == nil || *chosen.AvatarURL != pic.URL {
		t.Fatalf("the choice wins: %v", chosen.AvatarURL)
	}
	if chosen.ProviderAvatarURL == nil || *chosen.ProviderAvatarURL != "https://graph.facebook.com/example" {
		t.Fatal("the original is kept")
	}
	if chosen.ActivePictureID == nil || *chosen.ActivePictureID != pic.ID {
		t.Fatalf("activePictureId = %v", chosen.ActivePictureID)
	}

	cleared, err := f.users.SetActivePicture(f.ctx, user.ID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if cleared.AvatarURL == nil || *cleared.AvatarURL != "https://graph.facebook.com/example" || cleared.ActivePictureID != nil {
		t.Fatalf("clearing falls back: %+v", cleared)
	}
}

func TestAPictureIdMustBeInTheCatalogue(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	// The foreign key is the backstop under the handler's own check: an id
	// that is not a catalogue row is refused by the database rather than
	// stored and drawn as a broken image later.
	missing := int64(9_000_000)
	if _, err := f.users.SetActivePicture(f.ctx, user.ID, &missing); err == nil {
		t.Fatal("an unknown picture id was accepted")
	}
}

func TestBuyingAPremiumPictureMovesChipsThroughTheLedgerExactlyOnce(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	pic := premiumPicture(t, f)

	before := f.chips(user.ID)
	bought, err := f.pictures.Buy(f.ctx, user.ID, pic.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !bought.Charged || bought.Spent != pic.Cost {
		t.Fatalf("charged=%v spent=%d, want a %d charge", bought.Charged, bought.Spent, pic.Cost)
	}
	if got := f.chips(user.ID); got != before-pic.Cost {
		t.Fatalf("wallet %d, want %d", got, before-pic.Cost)
	}
	if !bought.Picture.Owned {
		t.Error("the bought picture is not owned")
	}

	// One ledger row, negative, with the reason that says what it was.
	var rows, delta int64
	if err := f.d.Pool.QueryRow(f.ctx,
		`SELECT count(*), COALESCE(sum(delta),0) FROM chip_ledger WHERE user_id = $1 AND reason = $2`,
		user.ID, "picture_purchase").Scan(&rows, &delta); err != nil {
		t.Fatal(err)
	}
	if rows != 1 || delta != -pic.Cost {
		t.Fatalf("ledger rows=%d delta=%d", rows, delta)
	}
	// The invariant the whole money model is checked against.
	f.reconcile()

	// Buying it again is success with nothing charged, and no second row.
	again, err := f.pictures.Buy(f.ctx, user.ID, pic.ID)
	if err != nil {
		t.Fatal(err)
	}
	if again.Charged || again.Spent != 0 {
		t.Fatalf("a second buy charged: %+v", again)
	}
	if got := f.chips(user.ID); got != before-pic.Cost {
		t.Fatalf("a second buy moved the wallet to %d", got)
	}
	f.reconcile()

	// Now it can be worn, and the wire carries the catalogue image.
	worn, err := f.users.SetActivePicture(f.ctx, user.ID, &pic.ID)
	if err != nil {
		t.Fatal(err)
	}
	if worn.AvatarURL == nil || *worn.AvatarURL != pic.URL {
		t.Fatalf("avatarUrl = %v, want %s", worn.AvatarURL, pic.URL)
	}

	// And it now reads as owned in the listing this player is shown.
	listed, err := f.pictures.List(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range listed {
		if p.ID == pic.ID && !p.Owned {
			t.Error("a bought picture is not listed as owned")
		}
	}
}

func TestAPremiumPictureIsARentalThatRunsOut(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	pic := premiumPicture(t, f)

	// Give it a term, then buy it.
	if _, err := f.d.Pool.Exec(f.ctx,
		`UPDATE profile_pictures SET duration_days = 30 WHERE id = $1`, pic.ID); err != nil {
		t.Fatal(err)
	}
	bought, err := f.pictures.Buy(f.ctx, user.ID, pic.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !bought.Charged || bought.Picture.ExpiresAt == 0 {
		t.Fatalf("a rental should be charged and dated: %+v", bought)
	}
	if _, err := f.users.SetActivePicture(f.ctx, user.ID, &pic.ID); err != nil {
		t.Fatal(err)
	}

	// While it runs: owned, worn, and the sweep has nothing to do.
	listed, err := f.pictures.List(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !ownedIn(listed, pic.ID) {
		t.Fatal("a live rental is not owned")
	}
	if swept, err := f.pictures.ExpireLapsed(f.ctx, user.ID); err != nil || swept {
		t.Fatalf("swept a live rental: %v %v", swept, err)
	}

	// Wind the clock past the term by moving the expiry into the past — the
	// same thing the passage of time does, without waiting a month for it.
	if _, err := f.d.Pool.Exec(f.ctx,
		`UPDATE user_profile_pictures SET expires_at = 1 WHERE user_id = $1`, user.ID); err != nil {
		t.Fatal(err)
	}

	// Ownership lapses on its own, with no sweep having run: every read tests
	// the expiry, which is what stops a lapsed rental being wearable.
	listed, err = f.pictures.List(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if ownedIn(listed, pic.ID) {
		t.Error("a lapsed rental is still owned")
	}
	if _, _, err := f.pictures.Find(f.ctx, user.ID, pic.ID); err != nil {
		t.Fatal(err)
	}

	// But the player is still WEARING it until the sweep at login says so —
	// active_picture_id is a plain column no expiry test passes through.
	still, err := f.users.FindByID(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if still.ActivePictureID == nil {
		t.Fatal("the picture came off without the sweep; the test proves nothing")
	}

	swept, err := f.pictures.ExpireLapsed(f.ctx, user.ID)
	if err != nil || !swept {
		t.Fatalf("the sweep did not take the lapsed picture off: %v %v", swept, err)
	}
	after, err := f.users.FindByID(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if after.ActivePictureID != nil {
		t.Errorf("still wearing a lapsed rental: %v", *after.ActivePictureID)
	}
	// Idempotent: a second login does not keep finding work to do.
	if swept, err := f.pictures.ExpireLapsed(f.ctx, user.ID); err != nil || swept {
		t.Errorf("the sweep repeated itself: %v %v", swept, err)
	}

	// And it can be rented again — the first purchase's action id is spent, so
	// this only works because the id carries the purchase number.
	again, err := f.pictures.Buy(f.ctx, user.ID, pic.ID)
	if err != nil {
		t.Fatalf("a lapsed rental could not be bought again: %v", err)
	}
	if !again.Charged {
		t.Error("renewing a lapsed rental charged nothing")
	}
	f.reconcile()
}

// ownedIn reports whether the listing marks that picture as owned.
func ownedIn(listed []db.Picture, id int64) bool {
	for _, p := range listed {
		if p.ID == id {
			return p.Owned
		}
	}
	return false
}

func TestAFreePictureNeverExpires(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	pic := freePicture(t, f)
	if _, err := f.users.SetActivePicture(f.ctx, user.ID, &pic.ID); err != nil {
		t.Fatal(err)
	}
	// Nothing to expire, so nothing is taken off — a free picture has no
	// ownership row for the sweep to find missing.
	if swept, err := f.pictures.ExpireLapsed(f.ctx, user.ID); err != nil || swept {
		t.Fatalf("swept a free picture: %v %v", swept, err)
	}
	after, err := f.users.FindByID(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if after.ActivePictureID == nil {
		t.Error("a free picture was taken off")
	}
}

func TestBuyingIsRefusedWhenItCannotBePaidFor(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	pic := premiumPicture(t, f)

	// Spend the wallet down through the ledger so the books stay true.
	if _, err := f.d.Pool.Exec(f.ctx,
		`UPDATE users SET chips = 1 WHERE id = $1`, user.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Pool.Exec(f.ctx,
		`INSERT INTO chip_ledger (user_id, delta, balance, reason, created_at)
		 VALUES ($1, $2, 1, 'test_fixture', 0)`, user.ID, 1-welcome); err != nil {
		t.Fatal(err)
	}

	if _, err := f.pictures.Buy(f.ctx, user.ID, pic.ID); !errors.Is(err, db.ErrPictureChips) {
		t.Fatalf("err = %v, want ErrPictureChips", err)
	}
	if got := f.chips(user.ID); got != 1 {
		t.Fatalf("a refused buy moved the wallet to %d", got)
	}
	f.reconcile()

	// A free picture is not for sale, and an unknown id is unknown.
	if _, err := f.pictures.Buy(f.ctx, user.ID, freePicture(t, f).ID); !errors.Is(err, db.ErrPictureFree) {
		t.Fatalf("err = %v, want ErrPictureFree", err)
	}
	if _, err := f.pictures.Buy(f.ctx, user.ID, 9_000_000); !errors.Is(err, db.ErrPictureUnknown) {
		t.Fatalf("err = %v, want ErrPictureUnknown", err)
	}
}

func TestARetiredPictureLeavesTheCatalogueButNotTheWearer(t *testing.T) {
	f := newFixture(t)
	user := newGuest(t, f)
	pic := freePicture(t, f)
	if _, err := f.users.SetActivePicture(f.ctx, user.ID, &pic.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Pool.Exec(f.ctx,
		`UPDATE profile_pictures SET is_active = FALSE WHERE id = $1`, pic.ID); err != nil {
		t.Fatal(err)
	}

	listed, err := f.pictures.List(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range listed {
		if p.ID == pic.ID {
			t.Error("a retired picture is still on offer")
		}
	}
	// Find still resolves it, reporting that it is no longer active, and the
	// player wearing it keeps it.
	found, active, err := f.pictures.Find(f.ctx, user.ID, pic.ID)
	if err != nil || active || found.ID != pic.ID {
		t.Fatalf("find retired: %+v active=%v err=%v", found, active, err)
	}
	still, err := f.users.FindByID(f.ctx, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if still.AvatarURL == nil || *still.AvatarURL != pic.URL {
		t.Fatalf("retiring a picture undressed its wearer: %v", still.AvatarURL)
	}
}

// ------------------------------------------------------------ login upsert

func TestGuestLoginCreatesAnAccountWithTheWelcomeGrant(t *testing.T) {
	f := newFixture(t)
	deviceHash := strings.Repeat("ab", 32)
	user, isNew, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: deviceHash, DisplayName: "Suraj"})
	if err != nil {
		t.Fatal(err)
	}
	if !isNew || user.Chips != welcome || user.Provider != "guest" || user.DisplayName != "Suraj" {
		t.Fatalf("new user = %+v isNew=%v", user, isNew)
	}
	if !regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`).MatchString(user.ID) {
		t.Fatalf("id %q is not a lowercase uuid v4", user.ID)
	}
	if user.Email != nil || user.AvatarURL != nil || user.ProviderAvatarURL != nil || user.ActivePictureID != nil {
		t.Fatalf("guest nullables must be null: %+v", user)
	}
	if user.CreatedAt == 0 || user.CreatedAt != user.LastLoginAt {
		t.Fatalf("timestamps: created %d lastLogin %d", user.CreatedAt, user.LastLoginAt)
	}
	if !withinMs(user.CreatedAt, nowMs(), 5000) {
		t.Fatalf("createdAt %d is not now", user.CreatedAt)
	}
	// created_at == updated_at == last_login_at on insert.
	var created, updated, lastLogin int64
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT created_at, updated_at, last_login_at FROM users WHERE id = $1`, user.ID).Scan(&created, &updated, &lastLogin); err != nil {
		t.Fatal(err)
	}
	if created != updated || updated != lastLogin {
		t.Fatalf("insert timestamps differ: %d %d %d", created, updated, lastLogin)
	}
	rows := f.ledgerRows(user.ID)
	if len(rows) != 1 || rows[0].Reason != "welcome_bonus" || rows[0].Delta != welcome || rows[0].Balance != welcome || rows[0].ActionID != nil || rows[0].HandID != nil || rows[0].Created != created {
		t.Fatalf("welcome row = %+v", rows)
	}
	f.reconcile()
}

func TestLoggingInAgainReturnsTheSameAccountAndOverwritesTheName(t *testing.T) {
	f := newFixture(t)
	id := "same-device-" + randomSuffix(t)
	first, _, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: id, DisplayName: "Suraj"})
	if err != nil {
		t.Fatal(err)
	}
	// An in-game rename…
	if _, err := f.users.SetDisplayName(f.ctx, first.ID, "Renamed"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * time.Millisecond)
	// …is clobbered by the next login (known, unresolved vs requirement 29).
	second, isNew, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: id, DisplayName: "GuestABCDE"})
	if err != nil {
		t.Fatal(err)
	}
	if isNew || second.ID != first.ID || second.Chips != welcome {
		t.Fatalf("second login = %+v isNew=%v", second, isNew)
	}
	if second.DisplayName != "GuestABCDE" {
		t.Fatalf("displayName = %q, want the provider's name", second.DisplayName)
	}
	if second.LastLoginAt <= first.LastLoginAt || second.CreatedAt != first.CreatedAt {
		t.Fatalf("timestamps: first %d/%d second %d/%d", first.CreatedAt, first.LastLoginAt, second.CreatedAt, second.LastLoginAt)
	}
	// Only an empty provider name keeps the stored one.
	third, _, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: id, DisplayName: ""})
	if err != nil {
		t.Fatal(err)
	}
	if third.DisplayName != "GuestABCDE" {
		t.Fatalf("empty provider name must keep the stored one, got %q", third.DisplayName)
	}
	// No second welcome grant.
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1`, first.ID); n != 1 {
		t.Fatalf("ledger rows after re-login = %d", n)
	}
	if n := f.count(`SELECT COUNT(*) FROM users WHERE provider = 'guest' AND provider_user_id = $1`, id); n != 1 {
		t.Fatalf("accounts = %d", n)
	}
}

func TestADifferentDeviceOrProviderIsADifferentAccount(t *testing.T) {
	f := newFixture(t)
	id := "shared-id-" + randomSuffix(t)
	g, _, _ := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: id, DisplayName: "A"})
	other, _, _ := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: id + "-2", DisplayName: "B"})
	google, isNew, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGoogle, ProviderUserID: id, DisplayName: "C", Email: ptr("c@example.com")})
	if err != nil || !isNew {
		t.Fatalf("google login: %v isNew=%v", err, isNew)
	}
	if g.ID == other.ID || g.ID == google.ID {
		t.Fatal("identities collided")
	}
	if google.Email == nil || *google.Email != "c@example.com" || google.Chips != welcome {
		t.Fatalf("google = %+v", google)
	}
	found, err := f.users.FindByProvider(f.ctx, db.ProviderGoogle, id)
	if err != nil || found == nil || found.ID != google.ID {
		t.Fatalf("FindByProvider → %+v %v", found, err)
	}
	if missing, err := f.users.FindByProvider(f.ctx, db.ProviderFacebook, id); err != nil || missing != nil {
		t.Fatalf("FindByProvider(miss) → %+v %v", missing, err)
	}
	if missing, err := f.users.FindByID(f.ctx, "no-such-id"); err != nil || missing != nil {
		t.Fatalf("FindByID(miss) → %+v %v", missing, err)
	}
}

func TestLoginOnlyEverSetsEmailAndAvatarNeverClearsThem(t *testing.T) {
	f := newFixture(t)
	id := "coalesce-" + randomSuffix(t)
	first, _, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGoogle, ProviderUserID: id, DisplayName: "G",
		Email: ptr("g@example.com"), AvatarURL: ptr("https://pic/1")})
	if err != nil {
		t.Fatal(err)
	}
	pic := freePicture(t, f)
	if _, err := f.users.SetActivePicture(f.ctx, first.ID, &pic.ID); err != nil {
		t.Fatal(err)
	}
	// A login with no email/picture keeps both; the in-game choice survives.
	second, _, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGoogle, ProviderUserID: id, DisplayName: "G"})
	if err != nil {
		t.Fatal(err)
	}
	if second.Email == nil || *second.Email != "g@example.com" || second.ProviderAvatarURL == nil || *second.ProviderAvatarURL != "https://pic/1" {
		t.Fatalf("COALESCE broke: %+v", second)
	}
	if second.ActivePictureID == nil || *second.ActivePictureID != pic.ID || *second.AvatarURL != pic.URL {
		t.Fatalf("avatar choice lost on login: %+v", second)
	}
	// A new picture replaces the provider one, not the choice.
	third, _, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGoogle, ProviderUserID: id, DisplayName: "G", AvatarURL: ptr("https://pic/2")})
	if err != nil {
		t.Fatal(err)
	}
	if *third.ProviderAvatarURL != "https://pic/2" || *third.AvatarURL != pic.URL {
		t.Fatalf("third = %+v", third)
	}
}

// DECISIONS.md §5: concurrent first logins for one identity produce exactly
// one account and one welcome_bonus row; the losers of the race take the
// update path (Node answered them with HTTP 500).
func TestConcurrentFirstLoginsProduceOneAccountAndOneWelcomeRow(t *testing.T) {
	f := newFixture(t)
	for round := 0; round < 3; round++ {
		id := "race-" + randomSuffix(t)
		const logins = 8
		var wg sync.WaitGroup
		ids := make([]string, logins)
		news := make([]bool, logins)
		errs := make([]error, logins)
		for i := range logins {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				u, isNew, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: id, DisplayName: fmt.Sprintf("Racer%d", i)})
				errs[i] = err
				if u != nil {
					ids[i], news[i] = u.ID, isNew
				}
			}(i)
		}
		wg.Wait()

		newCount := 0
		for i := range logins {
			if errs[i] != nil {
				t.Fatalf("round %d login %d: %v", round, i, errs[i])
			}
			if ids[i] != ids[0] {
				t.Fatalf("round %d: two accounts for one identity (%s vs %s)", round, ids[i], ids[0])
			}
			if news[i] {
				newCount++
			}
		}
		if newCount != 1 {
			t.Fatalf("round %d: %d logins reported isNew, want exactly 1", round, newCount)
		}
		if n := f.count(`SELECT COUNT(*) FROM users WHERE provider = 'guest' AND provider_user_id = $1`, id); n != 1 {
			t.Fatalf("round %d: %d accounts", round, n)
		}
		if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE user_id = $1 AND reason = 'welcome_bonus'`, ids[0]); n != 1 {
			t.Fatalf("round %d: %d welcome rows", round, n)
		}
		if f.chips(ids[0]) != welcome {
			t.Fatalf("round %d: chips = %d", round, f.chips(ids[0]))
		}
	}
	f.reconcile()
}

func TestWelcomeChipsComeFromConfigAndAZeroGrantStillWritesARow(t *testing.T) {
	f := newFixture(t)
	users := db.NewUsers(f.d, 0, nil)
	u, isNew, err := users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: "zero-" + randomSuffix(t), DisplayName: "Zero"})
	if err != nil || !isNew || u.Chips != 0 {
		t.Fatalf("%+v %v %v", u, isNew, err)
	}
	rows := f.ledgerRows(u.ID)
	if len(rows) != 1 || rows[0].Reason != "welcome_bonus" || rows[0].Delta != 0 || rows[0].Balance != 0 {
		t.Fatalf("rows = %+v", rows)
	}
}

// ---------------------------------------------------------- applyChipDelta

func TestApplyChipDeltaMovesChipsWithAMatchingLedgerRow(t *testing.T) {
	f := newFixture(t)
	poor := f.user("Poor")
	balance, err := f.users.ApplyChipDelta(f.ctx, poor.ID, -(welcome - 50), "test_fixture", "", "poor-fixture")
	if err != nil {
		t.Fatal(err)
	}
	if balance != 50 || f.chips(poor.ID) != 50 {
		t.Fatalf("balance %d wallet %d", balance, f.chips(poor.ID))
	}
	rows := f.ledgerRows(poor.ID)
	last := rows[len(rows)-1]
	if last.Reason != "test_fixture" || last.Delta != -(welcome-50) || last.Balance != 50 || last.ActionID == nil || *last.ActionID != "poor-fixture" || last.HandID != nil {
		t.Fatalf("row = %+v", last)
	}
	// Refuses to overdraw with a plain error and writes nothing.
	if _, err := f.users.ApplyChipDelta(f.ctx, poor.ID, -51, "test_fixture", "", ""); err == nil || err.Error() != "insufficient chips for "+poor.ID {
		t.Fatalf("overdraw: %v", err)
	}
	if game.CodeOf(err, "") != "" {
		t.Fatal("applyChipDelta errors are plain errors, not GameErrors")
	}
	if f.chips(poor.ID) != 50 || len(f.ledgerRows(poor.ID)) != 2 {
		t.Fatal("a refused delta wrote something")
	}
	if _, err := f.users.ApplyChipDelta(f.ctx, "ghost", 1, "test_fixture", "", ""); err == nil || err.Error() != "unknown user ghost" {
		t.Fatalf("unknown: %v", err)
	}
	// Exactly to zero is allowed; hand id can be attached.
	if _, err := f.users.ApplyChipDelta(f.ctx, poor.ID, -50, "test_fixture", "hand-x", ""); err != nil {
		t.Fatal(err)
	}
	rows = f.ledgerRows(poor.ID)
	if rows[len(rows)-1].HandID == nil || *rows[len(rows)-1].HandID != "hand-x" || rows[len(rows)-1].ActionID != nil {
		t.Fatalf("row = %+v", rows[len(rows)-1])
	}
	f.reconcile()
}

// -------------------------------------------------------- the wire object

func TestUserMarshalsToThePublicUserShape(t *testing.T) {
	f := newFixture(t)
	u, _, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGoogle, ProviderUserID: "shape-" + randomSuffix(t), DisplayName: "Shape",
		Email: ptr("s@example.com"), AvatarURL: ptr("https://pic")})
	if err != nil {
		t.Fatal(err)
	}
	out, err := json.Marshal(u)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatal(err)
	}
	wantKeys := []string{"id", "provider", "displayName", "email", "avatarUrl", "providerAvatarUrl", "activePictureId", "chips",
		"handsPlayed", "handsWon", "handsLost", "handsLeftMid", "totalWinnings", "biggestPot", "rewards", "createdAt", "lastLoginAt"}
	if len(m) != len(wantKeys) {
		t.Fatalf("user has %d keys, want %d: %s", len(m), len(wantKeys), out)
	}
	for _, k := range wantKeys {
		if _, ok := m[k]; !ok {
			t.Fatalf("missing key %q in %s", k, out)
		}
	}
	for _, forbidden := range []string{"providerUserId", "updatedAt", "milestoneClaimed", "nextBonusAt"} {
		if _, ok := m[forbidden]; ok {
			t.Fatalf("key %q must never be exposed", forbidden)
		}
	}
	// Key order is the emission order Node used.
	order := regexp.MustCompile(`"(\w+)":`).FindAllStringSubmatch(string(out), -1)
	var got []string
	for _, o := range order {
		got = append(got, o[1])
	}
	top := got[:17]
	for i, k := range wantKeys[:15] {
		if top[i] != k {
			t.Fatalf("key order differs at %d: %v", i, top)
		}
	}
	if string(m["chips"]) != "200000" || string(m["activePictureId"]) != "null" || string(m["avatarUrl"]) != `"https://pic"` {
		t.Fatalf("values: chips=%s activePictureId=%s avatarUrl=%s", m["chips"], m["activePictureId"], m["avatarUrl"])
	}
	var rewards map[string]json.RawMessage
	if err := json.Unmarshal(m["rewards"], &rewards); err != nil {
		t.Fatal(err)
	}
	for k, want := range map[string]string{
		"milestoneAvailable": "false", "milestoneAt": "0", "milestoneReward": "25000", "milestoneEvery": "25",
		"handsToNextMilestone": "25", "bonusReadyAt": "0", "bonusAvailable": "true", "bonusReward": "10000", "bonusIntervalMs": "14400000",
	} {
		if string(rewards[k]) != want {
			t.Fatalf("rewards.%s = %s, want %s", k, rewards[k], want)
		}
	}
	// A guest's nullables are JSON null, not "" or absent.
	g := f.user("Null")
	gout, _ := json.Marshal(g)
	for _, k := range []string{`"email":null`, `"avatarUrl":null`, `"providerAvatarUrl":null`, `"activePictureId":null`} {
		if !strings.Contains(string(gout), k) {
			t.Fatalf("expected %s in %s", k, gout)
		}
	}
	// Player() carries what the RoomManager seats.
	p := u.Player()
	if p.ID != u.ID || p.DisplayName != "Shape" || p.Chips != welcome || p.AvatarURL == nil || *p.AvatarURL != "https://pic" {
		t.Fatalf("Player() = %+v", p)
	}
}

// ------------------------------------------------- requirement 29: names

func TestADisplayNameKeepsLettersNumbersAndSingleSpaces(t *testing.T) {
	for in, want := range map[string]string{
		"  Suraj  Kumar ":   "Suraj Kumar",
		"Player7":           "Player7",
		"\tSuraj\u00a0 K":   "Suraj K", // NBSP is JS whitespace
		"a\u3000b":          "a b",     // ideographic space
		"\ufeffSuraj\ufeff": "Suraj",   // BOM is JS whitespace too
		"123":               "123",
		"Ⅳ Legion":          "Ⅳ Legion", // \p{N} covers letter-numbers
	} {
		got, err := db.NormalizeDisplayName(in, 24)
		if err != nil || got != want {
			t.Errorf("NormalizeDisplayName(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
}

func TestANameMayBeWrittenInAnyScriptAndSurvivesItsVowelMarks(t *testing.T) {
	for _, name := range []string{"सूरज", "সুরজ", "સૂરજ", "ਸੂਰਜ", "प्रिया", "सुरज कुमार"} {
		got, err := db.NormalizeDisplayName(name, 24)
		if err != nil || got != name {
			t.Errorf("NormalizeDisplayName(%q) = %q, %v", name, got, err)
		}
	}
}

func TestAnEmptyOrBlankNameIsRefused(t *testing.T) {
	for _, bad := range []string{"", "   ", "\t", "\u00a0\u2003", "\ufeff", "\n\r"} {
		if _, err := db.NormalizeDisplayName(bad, 24); !errors.Is(err, db.ErrEmptyName) {
			t.Errorf("NormalizeDisplayName(%q) → %v, want empty_name", bad, err)
		}
	}
}

func TestSpecialCharactersAreRefused(t *testing.T) {
	for _, bad := range []string{"Su<b>raj", "a@b", "hi!", "--", "x_y", "drop;table", "!Suraj", " SurajK", "a-b", "a.b", "😀", "Suraj😀", "a\u200db"} {
		if _, err := db.NormalizeDisplayName(bad, 24); !errors.Is(err, db.ErrInvalidName) {
			t.Errorf("NormalizeDisplayName(%q) → %v, want invalid_name", bad, err)
		}
	}
	// A name cannot start with a combining mark or a space-derived decoration.
	if _, err := db.NormalizeDisplayName("ासूरज", 24); !errors.Is(err, db.ErrInvalidName) {
		t.Errorf("leading vowel sign → %v", err)
	}
}

func TestAnOverLongNameIsRefusedInUTF16Units(t *testing.T) {
	if _, err := db.NormalizeDisplayName(strings.Repeat("a", 30), 24); !errors.Is(err, db.ErrNameTooLong) {
		t.Fatalf("30 ascii → %v", err)
	}
	if got, err := db.NormalizeDisplayName(strings.Repeat("a", 24), 24); err != nil || len(got) != 24 {
		t.Fatalf("24 ascii → %q %v", got, err)
	}
	// Length is counted like JS String.length: an astral letter is 2 units.
	astral := strings.Repeat("𐐷", 12) // Deseret letters, \p{L}, each 2 UTF-16 units
	if got, err := db.NormalizeDisplayName(astral, 24); err != nil || got != astral {
		t.Fatalf("12 astral letters (24 units) → %q %v", got, err)
	}
	if _, err := db.NormalizeDisplayName(astral+"a", 24); !errors.Is(err, db.ErrNameTooLong) {
		t.Fatalf("25 units → %v, want name_too_long", err)
	}
	// Combining marks count per code point, as in JS.
	if _, err := db.NormalizeDisplayName("प्रिया", 5); !errors.Is(err, db.ErrNameTooLong) {
		t.Fatalf("6 code points with max 5 → %v", err)
	}
	// Length is checked before the pattern (Node's order).
	if _, err := db.NormalizeDisplayName(strings.Repeat("!", 30), 24); !errors.Is(err, db.ErrNameTooLong) {
		t.Fatalf("long invalid → %v, want name_too_long first", err)
	}
	if !errors.Is(db.ErrNameTooLong, db.ErrNameTooLong) || db.ErrEmptyName.Error() != "empty_name" || db.ErrNameTooLong.Error() != "name_too_long" || db.ErrInvalidName.Error() != "invalid_name" {
		t.Fatal("error identities are the Node messages")
	}
}

func TestSetDisplayNameStoresTheNormalisedName(t *testing.T) {
	f := newFixture(t)
	u := f.user("Before")
	name, err := db.NormalizeDisplayName("  सुरज   कुमार ", 24)
	if err != nil {
		t.Fatal(err)
	}
	after, err := f.users.SetDisplayName(f.ctx, u.ID, name)
	if err != nil {
		t.Fatal(err)
	}
	if after.DisplayName != "सुरज कुमार" || f.find(u.ID).DisplayName != "सुरज कुमार" {
		t.Fatalf("displayName = %q", after.DisplayName)
	}
	if after.Chips != welcome {
		t.Fatal("a rename must not touch the wallet")
	}
}

func TestMilestoneFor(t *testing.T) {
	for in, want := range map[int]int{0: 0, 24: 0, 25: 25, 49: 25, 50: 50, 63: 50, 77: 75} {
		if got := db.MilestoneFor(in); got != want {
			t.Errorf("MilestoneFor(%d) = %d, want %d", in, got, want)
		}
	}
}
