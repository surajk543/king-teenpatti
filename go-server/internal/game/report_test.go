package game_test

import (
	"context"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/poker"
)

// Report Player (owner, 27 Sep 2026; report.go): whether a reporter may report
// a player — the two seated at the same room now, or at one they shared within
// ReportRecent — and what the server says about where they met: the room, its
// game, category and variant, and the hand. All of it read from the room and
// the seat index; a report never changes anything at a table.

const reportRecent = 10 * time.Minute

// withReports opens the menu and turns the recent-departure memory on.
func withReports(g *config.GameConfig, o *game.RoomManagerOptions) {
	openMenu(g, o)
	o.ReportRecent = reportRecent
}

func mustReportContext(t *testing.T, f *roomsFixture, reporter, reported string) game.ReportContext {
	t.Helper()
	ctx, ok := f.rooms.ReportContext(reporter, reported)
	if !ok {
		t.Fatalf("%s may not report %s", reporter, reported)
	}
	return ctx
}

func mustNotReport(t *testing.T, f *roomsFixture, reporter, reported, why string) {
	t.Helper()
	if ctx, ok := f.rooms.ReportContext(reporter, reported); ok {
		t.Fatalf("%s: %s may report %s (%+v)", why, reporter, reported, ctx)
	}
}

// packOnTurn has the player on turn pack.
func packOnTurn(t *testing.T, table *game.Table) string {
	t.Helper()
	who := turnUser(t, table)
	if _, err := table.Act(who, game.ActionPack, game.ActRequest{}); err != nil {
		t.Fatalf("%s packs: %v", who, err)
	}
	return who
}

func TestPlayersSeatedTogetherMayReportEachOtherWithTheHandInPlay(t *testing.T) {
	f := newRoomsFixture(t, withReports)
	table := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	a, b := seatTwoAndDeal(t, f, table, rmStart)
	hand := mustSnapshotOf(t, table).Hand.ID
	version := table.Version()

	want := game.ReportContext{RoomID: table.ID(), Game: game.GameTeenPatti, Category: game.CategorySeen, HandID: hand}
	eq(t, mustReportContext(t, f, a.ID, b.ID), want, "a reports b in the hand")
	eq(t, mustReportContext(t, f, b.ID, a.ID), want, "b reports a in the hand")

	// Nobody reports themselves, nor a player they have never sat with — seated
	// elsewhere, or in no room at all.
	mustNotReport(t, f, a.ID, a.ID, "oneself")
	elsewhere := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	c := f.player("C", rmStart)
	f.mustJoin(elsewhere, c)
	mustNotReport(t, f, a.ID, c.ID, "a player at another table")
	mustNotReport(t, f, c.ID, a.ID, "a player at another table, the other way")
	mustNotReport(t, f, a.ID, "nobody-at-all", "an id seated nowhere")
	mustNotReport(t, f, "nobody-at-all", a.ID, "a reporter seated nowhere")

	// The answers were reads: the hand plays on exactly as it was.
	eq(t, table.Version(), version, "no ledger write")
	eq(t, mustSnapshotOf(t, table).Hand.ID, hand, "the same hand")
	eq(t, len(seatedIDs(t, table)), 2, "both still seated")
}

// Between hands the report names the hand just played — for a player who was
// dealt into it; one who sat down after it has no hand yet.
func TestBetweenHandsAReportNamesTheLastHandThePlayerWasIn(t *testing.T) {
	f := newRoomsFixture(t, withReports)
	table := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	a, b := seatTwoAndDeal(t, f, table, rmStart)
	hand := mustSnapshotOf(t, table).Hand.ID
	packOnTurn(t, table)
	if table.HasHand() {
		t.Fatal("the hand did not end")
	}
	eq(t, mustReportContext(t, f, a.ID, b.ID).HandID, hand, "the hand just played")
	late := f.player("Late", rmStart)
	f.mustJoin(table, late)
	eq(t, mustReportContext(t, f, a.ID, late.ID).HandID, "", "no hand for a player who sat down after it")
	eq(t, mustReportContext(t, f, late.ID, a.ID).HandID, hand, "the late player reports a for the hand a played")

	// The next hand, once dealt, is the one named.
	f.clock.Advance(f.cfg.NextHandDelay + time.Millisecond)
	if !table.HasHand() {
		t.Fatal("the next hand was not dealt")
	}
	next := mustSnapshotOf(t, table).Hand.ID
	if next == hand {
		t.Fatal("the same hand id twice")
	}
	eq(t, mustReportContext(t, f, a.ID, late.ID).HandID, next, "the hand in play")
}

// A player who leaves — mid-hand, with the hand they walked out of — stays
// reportable by those they sat with, and can report them, for ReportRecent;
// after it, neither.
func TestAPlayerWhoLeftStaysReportableForTheRecentWindowOnly(t *testing.T) {
	// A turn clock longer than the window: crossing it must not idle-kick the
	// two who stay (a kick is a departure of its own, in a goroutine).
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		withReports(g, o)
		g.TurnTimeout = 24 * time.Hour
	})
	table := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	a, b := seatTwoAndDeal(t, f, table, rmStart)
	c := f.player("C", rmStart)
	f.mustJoin(table, c) // sits out the hand in play
	hand := mustSnapshotOf(t, table).Hand.ID

	f.mustLeave(b.ID, game.LeaveReasonLeft)
	if f.rooms.GetTableForPlayer(b.ID) != nil {
		t.Fatal("b is still seated")
	}
	want := game.ReportContext{RoomID: table.ID(), Game: game.GameTeenPatti, Category: game.CategorySeen, HandID: hand}
	eq(t, mustReportContext(t, f, a.ID, b.ID), want, "a reports b for the hand b walked out of")
	eq(t, mustReportContext(t, f, c.ID, b.ID), want, "c, seated beside b, reports b too")
	eq(t, mustReportContext(t, f, b.ID, a.ID), want, "b, gone, reports a")
	eq(t, mustReportContext(t, f, b.ID, c.ID).HandID, "", "c was dealt no hand")

	f.clock.Advance(reportRecent)
	eq(t, mustReportContext(t, f, a.ID, b.ID).HandID, hand, "at the edge of the window")
	f.clock.Advance(time.Millisecond)
	mustNotReport(t, f, a.ID, b.ID, "past the window")
	mustNotReport(t, f, b.ID, a.ID, "past the window, the other way")
	// Still seated together, a and c need no memory.
	mustReportContext(t, f, a.ID, c.ID)
}

// With no window, only players seated at the reporter's room now.
func TestWithNoRecentWindowOnlyPlayersSeatedNowAreReportable(t *testing.T) {
	f := newRoomsFixture(t, openMenu)
	table := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	a, b := seatTwoAndDeal(t, f, table, rmStart)
	mustReportContext(t, f, a.ID, b.ID)
	f.mustLeave(b.ID, game.LeaveReasonLeft)
	mustNotReport(t, f, a.ID, b.ID, "REPORT_RECENT_MS=0")
}

// A kick, a table switch and a table closing on its players are departures
// like any other.
func TestKickedMovedAndClosedOutPlayersStayReportable(t *testing.T) {
	f := newRoomsFixture(t, withReports)

	// A switch to another table of the pair.
	first := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	a, b := f.player("A", rmStart), f.player("B", rmStart)
	f.mustJoin(first, a)
	f.mustJoin(first, b)
	if _, err := f.rooms.SwitchTable(b); err != nil {
		t.Fatalf("switch: %v", err)
	}
	if at := f.rooms.GetTableForPlayer(b.ID); at == nil || at.ID() == first.ID() {
		t.Fatal("b did not move")
	}
	eq(t, mustReportContext(t, f, a.ID, b.ID).RoomID, first.ID(), "b is reported for the table they left")
	eq(t, mustReportContext(t, f, b.ID, a.ID).RoomID, first.ID(), "and reports a for it")

	// The table closing with three players at it.
	closing := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	x, y, z := f.player("X", rmStart), f.player("Y", rmStart), f.player("Z", rmStart)
	for _, p := range []game.Player{x, y, z} {
		f.mustJoin(closing, p)
	}
	if err := closing.StartHand(); err != nil {
		t.Fatal(err)
	}
	hand := mustSnapshotOf(t, closing).Hand.ID
	if err := f.rooms.DestroyTable(closing.ID()); err != nil {
		t.Fatal(err)
	}
	for _, pair := range [][2]string{{x.ID, y.ID}, {y.ID, z.ID}, {z.ID, x.ID}} {
		ctx := mustReportContext(t, f, pair[0], pair[1])
		eq(t, ctx.RoomID, closing.ID(), "the closed table")
		eq(t, ctx.Category, game.CategoryBlind, "its category")
		eq(t, ctx.HandID, hand, "the hand it closed on")
	}
}

// A variation table names the variation the hand was decided by — none while
// it is still being chosen — and a poker room its variant, as chip_ledger
// names a poker row.
func TestTheVariantIsTheHandsVariationOrThePokerVariant(t *testing.T) {
	f := newRoomsFixture(t, withReports)
	table := f.createTable(game.CreateTableOptions{BootAmount: 50_000, Category: "variation"})
	a, b := seatTwoAndDeal(t, f, table, 5_000_000)
	ctx := mustReportContext(t, f, a.ID, b.ID)
	eq(t, ctx.Category, game.CategoryVariation, "variation")
	eq(t, ctx.Variant, "", "nothing chosen yet")
	chosen := false
	for _, who := range []string{a.ID, b.ID} {
		if _, err := table.SelectVariation(who, string(game.VariationAK47)); err == nil {
			chosen = true
		}
	}
	if !chosen {
		t.Fatal("nobody could choose the variation")
	}
	eq(t, mustReportContext(t, f, a.ID, b.ID).Variant, string(game.VariationAK47), "the chosen variation")

	room := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 50_000, Category: "texas_holdem"})
	p, q := f.player("P", 1_000_000), f.player("Q", 1_000_000)
	f.mustJoin(room, p)
	f.mustJoin(room, q)
	pt := room.(*poker.Table)
	before := mustReportContext(t, f, p.ID, q.ID)
	eq(t, before, game.ReportContext{RoomID: room.ID(), Game: game.GamePoker, Category: game.CategoryTexasHoldem,
		Variant: "texas_holdem"}, "a poker room between hands")
	if err := pt.StartHand(); err != nil {
		t.Fatal(err)
	}
	snap, err := pt.Snapshot()
	if err != nil || snap.Hand == nil {
		t.Fatalf("poker snapshot: %v", err)
	}
	eq(t, mustReportContext(t, f, p.ID, q.ID).HandID, snap.Hand.ID, "the poker hand in play")
}

// After a restart two players still seated together are reportable — the
// restored room answers for them, its hand included — and a player who left
// before the restart is not: the departures lived in the old process.
func TestAfterARestartSeatedPlayersStayReportableAndOnesWhoLeftBeforeDoNot(t *testing.T) {
	store := livetest.New()
	withStoreAndReports := func(g *config.GameConfig, o *game.RoomManagerOptions) {
		withStore(store, "old")(g, o)
		o.ReportRecent = reportRecent
	}
	f1 := newRoomsFixture(t, withStoreAndReports)
	table := f1.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	a, b := seatTwoAndDeal(t, f1, table, rmStart)
	c := f1.player("C", rmStart)
	f1.mustJoin(table, c)
	f1.mustLeave(c.ID, game.LeaveReasonLeft)
	hand := mustSnapshotOf(t, table).Hand.ID
	mustReportContext(t, f1, a.ID, c.ID)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := f1.rooms.Suspend(ctx); err != nil {
		t.Fatalf("suspend: %v", err)
	}
	f2 := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		withStore(store, "new")(g, o)
		o.ReportRecent = reportRecent
	})
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch) + time.Second)
	if _, err := f2.rooms.Restore(ctx); err != nil {
		t.Fatalf("restore: %v", err)
	}
	want := game.ReportContext{RoomID: table.ID(), Game: game.GameTeenPatti, Category: game.CategorySeen, HandID: hand}
	eq(t, mustReportContext(t, f2, a.ID, b.ID), want, "still seated together, the restored hand named")
	mustNotReport(t, f2, a.ID, c.ID, "c left before the restart")
}
