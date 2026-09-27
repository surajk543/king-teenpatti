package db_test

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Report Player (owner, 27 Sep 2026): player_reports and its one writer,
// db.Reports.Submit — a report filed PENDING with the server's own account of
// the table and the hand, and every abuse guard enforced in PostgreSQL, inside
// the transaction that files it: one report per player per hand, one per
// player per pair window, and (owner: "a player may submit at most 2 reports
// in any 24 hours") a per-reporter limit counted from the reporter's own
// rows, so no restart resets it and no two reports sent in the same instant
// can both take the last slot.

// reportClock is a settable clock for the report store.
type reportClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *reportClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *reportClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func newReportClock() *reportClock {
	return &reportClock{now: time.UnixMilli(1_790_000_000_000)}
}

// dayLimits are the owner's: two a day, one per pair a day.
var dayLimits = db.ReportLimits{MaxPerReporter: 2, Window: 24 * time.Hour, PairWindow: 24 * time.Hour}

// aReport is a report of reported by reporter at a seen table, in hand.
func aReport(reporter, reported *db.User, hand string) db.PlayerReport {
	return db.PlayerReport{
		ReporterID: reporter.ID, ReportedID: reported.ID, Reason: "CHEATING",
		Game: string(game.GameTeenPatti), Category: string(game.CategorySeen),
		TableID: "room-" + reporter.ID[:8], HandID: hand,
	}
}

func TestAReportIsFiledPendingWithWhatTheServerSaysAboutWhereItWasMade(t *testing.T) {
	f := newFixture(t)
	clock := newReportClock()
	reports := db.NewReports(f.d, clock.Now)
	alice, bob := f.user("Alice"), f.user("Bob")

	id, err := reports.Submit(f.ctx, db.PlayerReport{
		ReporterID: alice.ID, ReportedID: bob.ID, Reason: "COLLUSION", Description: "Chaal after chaal with Ravi",
		Game: "teen_patti", Category: "variation", Variant: "AK47", TableID: "room-1", HandID: "hand-1",
	}, dayLimits)
	if err != nil || id <= 0 {
		t.Fatalf("Submit: %d %v", id, err)
	}
	var reporter, reported, reason, gameCode, category, tableID, status string
	var description, variant, handID *string
	var created, updated int64
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT reporter_user_id, reported_user_id, reason, description, game, category,
	        variant, table_id, hand_id, status, created_at, updated_at FROM player_reports WHERE id = $1`, id).
		Scan(&reporter, &reported, &reason, &description, &gameCode, &category, &variant, &tableID, &handID, &status,
			&created, &updated); err != nil {
		t.Fatal(err)
	}
	if reporter != alice.ID || reported != bob.ID || reason != "COLLUSION" || description == nil ||
		*description != "Chaal after chaal with Ravi" || gameCode != "teen_patti" || category != "variation" ||
		variant == nil || *variant != "AK47" || tableID != "room-1" || handID == nil || *handID != "hand-1" {
		t.Fatalf("the row: %s %s %s %v %s %s %v %s %v", reporter, reported, reason, description, gameCode, category, variant, tableID, handID)
	}
	if status != db.ReportPending || created != clock.Now().UnixMilli() || updated != created {
		t.Fatalf("status %s created %d updated %d, want PENDING at %d", status, created, updated, clock.Now().UnixMilli())
	}

	// No description, no variant, no hand: NULLs, never empty strings.
	carla := f.user("Carla")
	id2, err := reports.Submit(f.ctx, db.PlayerReport{
		ReporterID: alice.ID, ReportedID: carla.ID, Reason: "SPAM",
		Game: "poker", Category: "texas_holdem", TableID: "room-2",
	}, dayLimits)
	if err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM player_reports WHERE id = $1 AND description IS NULL AND variant IS NULL AND hand_id IS NULL`, id2); n != 1 {
		t.Fatal("an empty description, variant or hand must be stored as NULL")
	}

	// A report changes nothing but its own table: no wallet moved, no ledger row.
	for _, u := range []*db.User{alice, bob, carla} {
		if f.chips(u.ID) != welcome || f.ledgerSum(u.ID) != welcome {
			t.Fatalf("%s's wallet moved: %d (ledger %d)", u.DisplayName, f.chips(u.ID), f.ledgerSum(u.ID))
		}
	}
}

func TestAPlayerCannotReportThemselvesNorAnAccountThatIsGone(t *testing.T) {
	f := newFixture(t)
	reports := db.NewReports(f.d, nil)
	alice, bob := f.user("Alice"), f.user("Bob")
	if _, err := reports.Submit(f.ctx, aReport(alice, alice, "h"), dayLimits); !errors.Is(err, db.ErrSelfReport) {
		t.Fatalf("a self-report: %v", err)
	}
	// The table's CHECK is the last word even around Submit.
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO player_reports (reporter_user_id, reported_user_id, reason, game, category,
	    table_id, created_at, updated_at) VALUES ($1, $1, 'SPAM', 'teen_patti', 'seen', 'r', 1, 1)`, alice.ID); err == nil {
		t.Fatal("the table took a self-report")
	}
	if err := f.users.DeleteAccount(f.ctx, bob.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := reports.Submit(f.ctx, aReport(alice, bob, "h"), dayLimits); !errors.Is(err, db.ErrReportedNotFound) {
		t.Fatalf("a report about a deleted account: %v", err)
	}
	ghost := *bob
	ghost.ID = "00000000-0000-4000-8000-000000000000"
	if _, err := reports.Submit(f.ctx, aReport(alice, &ghost, "h"), dayLimits); !errors.Is(err, db.ErrReportedNotFound) {
		t.Fatalf("a report about nobody: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM player_reports`); n != 0 {
		t.Fatalf("%d reports filed", n)
	}
}

// One report per reporter, per reported player, per hand — whatever the pair
// window — while other players may report the same player for the same hand,
// and the reporter may report another player of it.
func TestOnePlayerIsReportedOncePerHandByEachReporter(t *testing.T) {
	f := newFixture(t)
	reports := db.NewReports(f.d, newReportClock().Now)
	alice, bob, carla, dev := f.user("Alice"), f.user("Bob"), f.user("Carla"), f.user("Dev")
	noPair := db.ReportLimits{MaxPerReporter: 10, Window: 24 * time.Hour}

	if _, err := reports.Submit(f.ctx, aReport(alice, bob, "hand-7"), noPair); err != nil {
		t.Fatal(err)
	}
	again := aReport(alice, bob, "hand-7")
	again.Reason = "HARASSMENT"
	if _, err := reports.Submit(f.ctx, again, noPair); !errors.Is(err, db.ErrAlreadyReported) {
		t.Fatalf("the same hand again, another reason: %v", err)
	}
	// The unique index says the same should anything ever file around Submit.
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO player_reports (reporter_user_id, reported_user_id, reason, game, category,
	    table_id, hand_id, created_at, updated_at) VALUES ($1, $2, 'SPAM', 'teen_patti', 'seen', 'r', 'hand-7', 1, 1)`,
		alice.ID, bob.ID); err == nil {
		t.Fatal("the table took a second report of the same hand")
	}
	for _, ok := range []db.PlayerReport{
		aReport(alice, bob, "hand-8"),   // another hand (no pair window)
		aReport(alice, carla, "hand-7"), // another player of the same hand
		aReport(carla, bob, "hand-7"),   // multiple players reporting one player
		aReport(dev, bob, "hand-7"),
	} {
		if _, err := reports.Submit(f.ctx, ok, noPair); err != nil {
			t.Fatalf("%+v: %v", ok, err)
		}
	}
	if n := f.count(`SELECT count(*) FROM player_reports WHERE reported_user_id = $1`, bob.ID); n != 4 {
		t.Fatalf("Bob has %d reports, want 4", n)
	}
}

// One report per reporter → reported player within the pair window, whatever
// the hand or the reason; the window passed, another.
func TestAPairIsReportedOncePerPairWindow(t *testing.T) {
	f := newFixture(t)
	clock := newReportClock()
	reports := db.NewReports(f.d, clock.Now)
	alice, bob := f.user("Alice"), f.user("Bob")
	limits := db.ReportLimits{MaxPerReporter: 10, Window: 24 * time.Hour, PairWindow: 24 * time.Hour}

	if _, err := reports.Submit(f.ctx, aReport(alice, bob, "hand-1"), limits); err != nil {
		t.Fatal(err)
	}
	clock.advance(23 * time.Hour)
	later := aReport(alice, bob, "hand-2")
	later.Reason = "ABUSIVE_LANGUAGE"
	if _, err := reports.Submit(f.ctx, later, limits); !errors.Is(err, db.ErrAlreadyReported) {
		t.Fatalf("inside the pair window: %v", err)
	}
	// Between hands: no hand at all, and still the pair window.
	if _, err := reports.Submit(f.ctx, aReport(alice, bob, ""), limits); !errors.Is(err, db.ErrAlreadyReported) {
		t.Fatalf("no hand, inside the pair window: %v", err)
	}
	clock.advance(time.Hour)
	if _, err := reports.Submit(f.ctx, later, limits); err != nil {
		t.Fatalf("the window passed: %v", err)
	}
}

// The owner's limit: two reports in any 24 hours. The third inside them is
// refused, saying when the oldest leaves the window; once it has, one more is
// accepted — and a report refused for the limit files nothing.
func TestTheThirdReportInTwentyFourHoursIsRefusedAndOneAfterTheWindowIsAccepted(t *testing.T) {
	f := newFixture(t)
	clock := newReportClock()
	reports := db.NewReports(f.d, clock.Now)
	alice := f.user("Alice")
	targets := []*db.User{f.user("Bob"), f.user("Carla"), f.user("Dev"), f.user("Esha")}

	first := clock.Now()
	if _, err := reports.Submit(f.ctx, aReport(alice, targets[0], "h1"), dayLimits); err != nil {
		t.Fatal(err)
	}
	clock.advance(5 * time.Hour)
	if _, err := reports.Submit(f.ctx, aReport(alice, targets[1], "h2"), dayLimits); err != nil {
		t.Fatal(err)
	}
	clock.advance(18*time.Hour + 59*time.Minute)
	_, err := reports.Submit(f.ctx, aReport(alice, targets[2], "h3"), dayLimits)
	var limited *db.ReportLimitReached
	if !errors.As(err, &limited) || !errors.Is(err, db.ErrReportLimitReached) {
		t.Fatalf("the third report within 24 h: %v", err)
	}
	if want := first.Add(24 * time.Hour).UnixMilli(); limited.RetryAt != want {
		t.Fatalf("retry at %d, want %d (the first report's 24 h)", limited.RetryAt, want)
	}
	if n := f.count(`SELECT count(*) FROM player_reports WHERE reporter_user_id = $1`, alice.ID); n != 2 {
		t.Fatalf("%d reports on file, want 2", n)
	}
	// Exactly 24 h after the first, it no longer counts.
	clock.now = first.Add(24 * time.Hour)
	if _, err := reports.Submit(f.ctx, aReport(alice, targets[2], "h3"), dayLimits); err != nil {
		t.Fatalf("after the window: %v", err)
	}
	// …and the second still does, with the third: two in the window again.
	if _, err := reports.Submit(f.ctx, aReport(alice, targets[3], "h4"), dayLimits); !errors.Is(err, db.ErrReportLimitReached) {
		t.Fatalf("the window full again: %v", err)
	}
	// Another reporter's limit is their own.
	if _, err := reports.Submit(f.ctx, aReport(targets[3], alice, "h4"), dayLimits); err != nil {
		t.Fatalf("another reporter: %v", err)
	}
	// 0 is no per-reporter limit.
	if _, err := reports.Submit(f.ctx, aReport(alice, targets[3], "h5"), db.ReportLimits{PairWindow: 24 * time.Hour}); err != nil {
		t.Fatalf("no limit: %v", err)
	}
}

// The limit is counted from the rows, so a new process — a fresh store on a
// pool of its own, as a restart has — finds it exactly where the old one left
// it.
func TestTheReportLimitSurvivesARestart(t *testing.T) {
	f := newFixture(t)
	clock := newReportClock()
	alice := f.user("Alice")
	targets := []*db.User{f.user("Bob"), f.user("Carla"), f.user("Dev")}
	before := db.NewReports(f.d, clock.Now)
	for i, target := range targets[:2] {
		if _, err := before.Submit(f.ctx, aReport(alice, target, "h"+string(rune('1'+i))), dayLimits); err != nil {
			t.Fatal(err)
		}
	}

	second, err := db.Open(f.ctx, db.Options{URL: testURL(), Schema: f.d.Schema, PoolMax: 2})
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	clock.advance(time.Hour)
	after := db.NewReports(second, clock.Now)
	if _, err := after.Submit(f.ctx, aReport(alice, targets[2], "h3"), dayLimits); !errors.Is(err, db.ErrReportLimitReached) {
		t.Fatalf("after a restart the third report was: %v", err)
	}
}

// Two reports sent in the same instant with one slot left file exactly one:
// the count and the insert are one step, one reporter at a time. Each racer
// that has counted waits (a little) for the others to count too before it
// inserts — which, were Submit not serialised per reporter, would let every
// one of them count one short and file; serialised, the others cannot count
// until the first has committed, and find the window full.
func TestConcurrentReportsWithOneSlotLeftFileExactlyOne(t *testing.T) {
	f := newFixture(t)
	reports := db.NewReports(f.d, nil)
	alice := f.user("Alice")
	if _, err := reports.Submit(f.ctx, aReport(alice, f.user("First"), "h0"), dayLimits); err != nil {
		t.Fatal(err)
	}
	const racers = 4 // dbtest's pool: every racer holds a connection at once
	var countedMu sync.Mutex
	countedCh := make(chan struct{})
	counted := 0
	reports.SetReportCounted(func() {
		countedMu.Lock()
		counted++
		if counted == 2 {
			close(countedCh)
		}
		countedMu.Unlock()
		select {
		case <-countedCh: // a second racer counted beside this one
		case <-time.After(300 * time.Millisecond):
		}
	})
	targets := make([]*db.User, racers)
	for i := range targets {
		targets[i] = f.user("Target" + string(rune('A'+i)))
	}
	var wg sync.WaitGroup
	start := make(chan struct{})
	results := make([]error, racers)
	for i := range racers {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			_, results[i] = reports.Submit(f.ctx, aReport(alice, targets[i], "h"+string(rune('a'+i))), dayLimits)
		}(i)
	}
	close(start)
	wg.Wait()
	filed, limited := 0, 0
	for _, err := range results {
		switch {
		case err == nil:
			filed++
		case errors.Is(err, db.ErrReportLimitReached):
			limited++
		default:
			t.Fatalf("a racing report failed otherwise: %v", err)
		}
	}
	if filed != 1 || limited != racers-1 {
		t.Fatalf("%d filed and %d limited, want exactly one filed", filed, limited)
	}
	if n := f.count(`SELECT count(*) FROM player_reports WHERE reporter_user_id = $1`, alice.ID); n != 2 {
		t.Fatalf("%d reports on file, want 2", n)
	}
}

// The status is moderation's, from a closed set; nothing but moderation (none
// is built yet) moves it, and a player's account deletion keeps the reports
// — theirs and those about them — as it keeps their ledger.
func TestTheStatusIsAClosedSetAndReportsOutliveAnAccountDeletion(t *testing.T) {
	f := newFixture(t)
	reports := db.NewReports(f.d, nil)
	alice, bob := f.user("Alice"), f.user("Bob")
	id, err := reports.Submit(f.ctx, aReport(alice, bob, "h"), dayLimits)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE player_reports SET status = 'BANNED' WHERE id = $1`, id); err == nil {
		t.Fatal("a status outside the lifecycle was taken")
	}
	for _, status := range []string{db.ReportUnderReview, db.ReportActionTaken, db.ReportDismissed} {
		if _, err := f.d.Pool.Exec(f.ctx, `UPDATE player_reports SET status = $2, updated_at = updated_at + 1 WHERE id = $1`, id, status); err != nil {
			t.Fatalf("moderation's %s: %v", status, err)
		}
	}
	if err := f.users.DeleteAccount(f.ctx, alice.ID); err != nil {
		t.Fatalf("an account with a report deletes: %v", err)
	}
	if err := f.users.DeleteAccount(f.ctx, bob.ID); err != nil {
		t.Fatalf("a reported account deletes: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM player_reports WHERE id = $1`, id); n != 1 {
		t.Fatal("the report went with an account deletion")
	}
}

// The ledger purge keeps every row of a hand a report names — the hand's one
// authoritative record in PostgreSQL — and purges every other hand as before.
func TestTheLedgerPurgeKeepsTheRowsOfAReportedHand(t *testing.T) {
	f := newFixture(t)
	reports := db.NewReports(f.d, nil)
	a, b := f.user("Reporter"), f.user("Reported")
	reported, other := "hand-reported-"+randomSuffix(t), "hand-other-"+randomSuffix(t)
	for _, hand := range []string{reported, other} {
		if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "r", HandID: hand, Entries: []game.SettleEntry{
			settleEntry(hand, a.ID, 400, true, true, 800), settleEntry(hand, b.ID, -400, false, true, 0),
		}}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := reports.Submit(f.ctx, aReport(a, b, reported), dayLimits); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.PurgeLedger(f.ctx, time.Now().Add(time.Hour).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if rows := f.handLedgerRows(reported); len(rows) != 2 {
		t.Fatalf("the reported hand keeps %d rows, want both", len(rows))
	}
	if rows := f.handLedgerRows(other); len(rows) != 0 {
		t.Fatalf("an unreported hand keeps %d rows after the purge", len(rows))
	}
}

// The standing the app switches its Report line off by (owner, 27 Sep 2026:
// "if user has reported 2 player, then reporting by him should be disabled in
// UI, and show a cool down time in UI when can he report again"): Quota
// counts what Submit counts, says when the next report opens, and the limit's
// refusal carries the same.
func TestTheQuotaSaysWhatSubmitWillDecideAndWhenTheNextReportOpens(t *testing.T) {
	f := newFixture(t)
	clock := newReportClock()
	reports := db.NewReports(f.d, clock.Now)
	alice := f.user("Alice")
	targets := []*db.User{f.user("Bob"), f.user("Carla"), f.user("Dev")}
	quota := func(limits db.ReportLimits) db.ReportQuota {
		t.Helper()
		q, err := reports.Quota(f.ctx, alice.ID, limits)
		if err != nil {
			t.Fatal(err)
		}
		return q
	}

	if q := quota(dayLimits); q != (db.ReportQuota{Max: 2, Remaining: 2, Window: 24 * time.Hour, Now: clock.Now().UnixMilli()}) {
		t.Fatalf("nothing filed: %+v", q)
	}
	first := clock.Now()
	if _, err := reports.Submit(f.ctx, aReport(alice, targets[0], "h1"), dayLimits); err != nil {
		t.Fatal(err)
	}
	clock.advance(5 * time.Hour)
	if q := quota(dayLimits); q.Used != 1 || q.Remaining != 1 || q.AvailableAt != 0 || q.Limited() {
		t.Fatalf("one filed: %+v", q)
	}
	second := clock.Now()
	if _, err := reports.Submit(f.ctx, aReport(alice, targets[1], "h2"), dayLimits); err != nil {
		t.Fatal(err)
	}
	clock.advance(time.Hour)
	q := quota(dayLimits)
	if !q.Limited() || q.Used != 2 || q.Remaining != 0 || q.AvailableAt != first.Add(24*time.Hour).UnixMilli() ||
		q.Now != clock.Now().UnixMilli() {
		t.Fatalf("both used: %+v, want open at the first report's 24 h", q)
	}
	_, err := reports.Submit(f.ctx, aReport(alice, targets[2], "h3"), dayLimits)
	var limited *db.ReportLimitReached
	if !errors.As(err, &limited) || limited.Quota != q || limited.RetryAt != q.AvailableAt {
		t.Fatalf("the refusal's standing: %v %+v, want %+v", err, limited, q)
	}

	// A limit lowered under what was filed opens when the count falls under
	// it: here, the second report's 24 h.
	if q := quota(db.ReportLimits{MaxPerReporter: 1, Window: 24 * time.Hour}); q.Used != 2 || q.AvailableAt != second.Add(24*time.Hour).UnixMilli() {
		t.Fatalf("a lowered limit: %+v", q)
	}
	// No limit: nothing counted, nothing to wait for.
	if q := quota(db.ReportLimits{PairWindow: time.Hour}); q.Max != 0 || q.Used != 0 || q.Limited() || q.AvailableAt != 0 {
		t.Fatalf("no limit: %+v", q)
	}
	// Once the first leaves the window, one opens — and another reporter's
	// standing is their own.
	clock.now = first.Add(24 * time.Hour)
	if q := quota(dayLimits); q.Used != 1 || q.Remaining != 1 || q.Limited() {
		t.Fatalf("after the first's 24 h: %+v", q)
	}
	if q, err := reports.Quota(f.ctx, targets[0].ID, dayLimits); err != nil || q.Used != 0 || q.Remaining != 2 {
		t.Fatalf("another reporter: %+v %v", q, err)
	}
}
