package game_test

// Port of the RoomManager halves of server/test/{consolidation, lobbyRules,
// privateTables, tableRules, stakes}.test.js, plus the concurrency cases the
// Go port needs (PORT_PLAN.md §3.2). Real Tables, a bookless MemoryLedger and
// testclock.Fake throughout; no database.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// ------------------------------------------------------------ the merge
// (consolidation.test.js, requirement 24)

func TestRoomsConsolidationMergesTwoLoneTables(t *testing.T) {
	f := newRoomsFixture(t, nil)
	a := f.singleTable(rmBoot, game.CategoryBlind)
	b := f.singleTable(rmBoot, game.CategoryBlind)
	aPlayer, bPlayer := seatedIDs(t, a)[0], seatedIDs(t, b)[0]

	moves := f.mustConsolidate()

	if len(moves) != 1 {
		t.Fatalf("one player was moved, got %v", moves)
	}
	live := f.rooms.LiveTables()
	if len(live) != 1 {
		t.Fatalf("the emptied table was disposed of, got %d tables", len(live))
	}
	survivor := live[0]
	if survivor.PlayerCount() != 2 {
		t.Fatalf("both players are now at one table, got %d", survivor.PlayerCount())
	}
	want := []string{aPlayer, bPlayer}
	if aPlayer > bPlayer {
		want = []string{bPlayer, aPlayer}
	}
	if got := seatedIDs(t, survivor); !equalStrings(got, want) {
		t.Fatalf("seated %v, want %v", got, want)
	}
}

func TestRoomsConsolidatedPlayersCanStartAHand(t *testing.T) {
	f := newRoomsFixture(t, nil)
	f.singleTable(rmBoot, game.CategoryBlind)
	f.singleTable(rmBoot, game.CategoryBlind)
	f.mustConsolidate()

	survivor := f.rooms.LiveTables()[0]
	if survivor.State() != game.TableStarting {
		t.Fatalf("two players triggers the countdown, state %s", survivor.State())
	}
	f.clock.Advance(10 * time.Second)
	if !survivor.HasHand() {
		t.Fatal("a hand was dealt")
	}
}

func TestRoomsConsolidationTargetsTheLongestStandingTable(t *testing.T) {
	f := newRoomsFixture(t, nil)
	first := f.singleTable(rmBoot, game.CategoryBlind)
	second := f.singleTable(rmBoot, game.CategoryBlind)

	moves := f.mustConsolidate()

	if len(moves) != 1 || moves[0].FromRoomID != second.ID() {
		t.Fatalf("the newer room gives up its player: %v", moves)
	}
	if moves[0].ToRoomID != first.ID() {
		t.Fatalf("to the one that has been open longest: %v", moves)
	}
	if f.rooms.GetTable(second.ID()) != nil {
		t.Fatal("the newer room is gone")
	}
	if !second.Destroyed() {
		t.Fatal("the newer table's actor was destroyed")
	}
}

func TestRoomsConsolidationBreaksCreatedAtTiesByCreationOrder(t *testing.T) {
	// The fake clock stamps every table with the same CreatedAt; the order
	// the tables were opened in must still decide the destination.
	f := newRoomsFixture(t, nil)
	var tables []*game.Table
	for i := 0; i < 4; i++ {
		tables = append(tables, f.singleTable(rmBoot, game.CategoryBlind))
	}
	moves := f.mustConsolidate()
	if len(moves) != 3 {
		t.Fatalf("three moves, got %v", moves)
	}
	for i, m := range moves {
		if m.ToRoomID != tables[0].ID() || m.FromRoomID != tables[i+1].ID() {
			t.Fatalf("move %d: %v (target %s)", i, m, tables[0].ID())
		}
	}
}

func TestRoomsThreeLonePlayersEndUpTogether(t *testing.T) {
	f := newRoomsFixture(t, nil)
	f.singleTable(rmBoot, game.CategoryBlind)
	f.singleTable(rmBoot, game.CategoryBlind)
	f.singleTable(rmBoot, game.CategoryBlind)

	f.mustConsolidate()

	live := f.rooms.LiveTables()
	if len(live) != 1 || live[0].PlayerCount() != 3 {
		t.Fatalf("one table of three, got %d tables", len(live))
	}
}

func TestRoomsConsolidationIsAnnounced(t *testing.T) {
	f := newRoomsFixture(t, nil)
	f.singleTable(rmBoot, game.CategoryBlind)
	second := f.singleTable(rmBoot, game.CategoryBlind)
	movedUser := seatedIDs(t, second)[0]

	f.mustConsolidate()

	announced := f.events.movedCopy()
	if len(announced) != 1 || announced[0].UserID != movedUser || announced[0].FromRoomID != second.ID() {
		t.Fatalf("announced %v", announced)
	}
}

func TestRoomsIndexFollowsTheMovedPlayer(t *testing.T) {
	f := newRoomsFixture(t, nil)
	first := f.singleTable(rmBoot, game.CategoryBlind)
	second := f.singleTable(rmBoot, game.CategoryBlind)
	movedUser := seatedIDs(t, second)[0]

	f.mustConsolidate()

	if got := f.rooms.GetTableForPlayer(movedUser); got == nil || got.ID() != first.ID() {
		t.Fatal("lookups point at the new room")
	}
}

func TestRoomsMovedPlayerKeepsSeatChipsAndSocket(t *testing.T) {
	f := newRoomsFixture(t, nil)
	f.singleTable(rmBoot, game.CategoryBlind)
	second := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	mover := f.player("Mover", 4321)
	if err := f.rooms.Join(second, mover, "sock-mover"); err != nil {
		t.Fatal(err)
	}

	f.mustConsolidate()

	target := f.rooms.GetTableForPlayer(mover.ID)
	seat, err := target.FindSeat(mover.ID)
	if err != nil || seat == nil {
		t.Fatalf("seat: %v %v", seat, err)
	}
	if seat.Chips != 4321 || seat.SocketID != "sock-mover" || !seat.Connected {
		t.Fatalf("chips %d socket %q connected %v", seat.Chips, seat.SocketID, seat.Connected)
	}
}

func TestRoomsConsolidationEventOrder(t *testing.T) {
	// source events → target events → tableDestroyed(source) → playerMoved,
	// so the mover's room:closed always precedes room:moved / room:joined.
	f := newRoomsFixture(t, nil)
	first := f.singleTable(rmBoot, game.CategoryBlind)
	second := f.singleTable(rmBoot, game.CategoryBlind)
	movedUser := seatedIDs(t, second)[0]

	before := len(f.trace())
	f.mustConsolidate()
	trace := f.trace()[before:]

	idx := func(prefix string) int {
		for i, e := range trace {
			if strings.HasPrefix(e, prefix) {
				return i
			}
		}
		t.Fatalf("%q not in trace %v", prefix, trace)
		return -1
	}
	sourceSeat := idx("seat:" + second.ID())
	targetSeat := idx("seat:" + first.ID())
	destroyed := idx("destroyed:" + second.ID())
	moved := idx("moved:" + movedUser)
	if !(sourceSeat < targetSeat && targetSeat < destroyed && destroyed < moved) {
		t.Fatalf("order broken: %v", trace)
	}
}

// ------------------------------------------- never during a live game

func TestRoomsConsolidationNeverDisturbsALiveHand(t *testing.T) {
	f := newRoomsFixture(t, nil)
	busy := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(busy, f.player("Busy1", rmStart))
	f.mustJoin(busy, f.player("Busy2", rmStart))
	f.clock.Advance(10 * time.Second)
	if !busy.HasHand() {
		t.Fatal("the busy table is mid-hand")
	}
	lonely := f.singleTable(rmBoot, game.CategoryBlind)

	moves := f.mustConsolidate()

	if len(moves) != 0 {
		t.Fatalf("nobody was moved off a table that is playing: %v", moves)
	}
	if f.rooms.GetTable(busy.ID()) == nil || f.rooms.GetTable(lonely.ID()) == nil {
		t.Fatal("both tables are untouched")
	}
}

func TestRoomsLeaveMidHandResolvesBeforeAnyMerge(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(table, f.player("P1", rmStart))
	f.mustJoin(table, f.player("P2", rmStart))
	f.clock.Advance(10 * time.Second)
	if !table.HasHand() {
		t.Fatal("hand expected")
	}

	f.mustLeave(seatedIDs(t, table)[0], game.LeaveReasonLeft)

	if table.PlayerCount() != 1 {
		t.Fatalf("player count %d", table.PlayerCount())
	}
	if table.HasHand() {
		t.Fatal("the hand resolved before any merge could apply")
	}
	ended := f.tables.endedCopy()
	if len(ended) != 1 || ended[0].Reason != game.WinLastStanding {
		t.Fatalf("hand ended %v", ended)
	}
}

// -------------------------------------------- only like-for-like tables

func TestRoomsDifferentStakesNeverMerge(t *testing.T) {
	f := newRoomsFixture(t, nil)
	f.singleTable(200, game.CategoryBlind)
	f.singleTable(5000, game.CategoryBlind)
	if moves := f.mustConsolidate(); len(moves) != 0 {
		t.Fatalf("a player keeps the stake they chose: %v", moves)
	}
	if n := len(f.rooms.LiveTables()); n != 2 {
		t.Fatalf("tables %d", n)
	}
}

func TestRoomsBlindAndSeenNeverMerge(t *testing.T) {
	f := newRoomsFixture(t, nil)
	f.singleTable(rmBoot, game.CategoryBlind)
	f.singleTable(rmBoot, game.CategorySeen)
	if moves := f.mustConsolidate(); len(moves) != 0 {
		t.Fatalf("a player keeps the category they chose: %v", moves)
	}
	if n := len(f.rooms.LiveTables()); n != 2 {
		t.Fatalf("tables %d", n)
	}
}

func TestRoomsPrivateTablesAreLeftAlone(t *testing.T) {
	f := newRoomsFixture(t, nil)
	one := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true, Category: "blind"})
	f.mustJoin(one, f.player("Host1", rmStart))
	two := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true, Category: "blind"})
	f.mustJoin(two, f.player("Host2", rmStart))

	if moves := f.mustConsolidate(); len(moves) != 0 {
		t.Fatalf("a private room is joined on purpose: %v", moves)
	}
	if n := len(f.rooms.LiveTables()); n != 2 {
		t.Fatalf("tables %d", n)
	}
}

func TestRoomsFullDestinationStopsTakingPlayers(t *testing.T) {
	f := newRoomsFixture(t, nil)
	target := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	for i := 0; i < 5; i++ {
		f.mustJoin(target, f.player(fmt.Sprintf("Seat%d", i), rmStart))
	}
	if !target.IsFull() {
		t.Fatal("target should be full")
	}
	lonely := f.singleTable(rmBoot, game.CategoryBlind)

	moves := f.mustConsolidate()
	if len(moves) != 0 {
		t.Fatalf("there was nowhere to put them: %v", moves)
	}
	if lonely.PlayerCount() != 1 {
		t.Fatal("so they stayed where they were")
	}
}

func TestRoomsSingleLoneTableHasNothingToMergeWith(t *testing.T) {
	f := newRoomsFixture(t, nil)
	f.singleTable(rmBoot, game.CategoryBlind)
	if moves := f.mustConsolidate(); len(moves) != 0 {
		t.Fatalf("moves %v", moves)
	}
	if n := len(f.rooms.LiveTables()); n != 1 {
		t.Fatalf("tables %d", n)
	}
}

// ------------------------------------------------ the start countdown

func TestRoomsMergedTableAnnouncesTheCountdown(t *testing.T) {
	f := newRoomsFixture(t, nil)
	f.singleTable(rmBoot, game.CategoryBlind)
	f.singleTable(rmBoot, game.CategoryBlind)
	f.mustConsolidate()

	survivor := f.rooms.LiveTables()[0]
	view := viewOf(t, survivor, seatedIDs(t, survivor)[0])
	if view.State != game.TableStarting {
		t.Fatalf("state %s", view.State)
	}
	now := game.Millis(f.clock.Now())
	if view.StartsAt == nil || *view.StartsAt <= now {
		t.Fatal("clients get a deadline to count down to")
	}
	if *view.StartsAt > now+5000 {
		t.Fatal("and it is a few seconds away")
	}
}

func TestRoomsLeavingTriggersAMergeImmediately(t *testing.T) {
	f := newRoomsFixture(t, nil)
	a := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(a, f.player("A1", rmStart))
	f.mustJoin(a, f.player("A2", rmStart))
	b := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(b, f.player("B1", rmStart))

	f.mustLeave(seatedIDs(t, a)[0], game.LeaveReasonLeft)

	live := f.rooms.LiveTables()
	if len(live) != 1 {
		t.Fatalf("the rooms merged on the spot, got %d tables", len(live))
	}
	if live[0].PlayerCount() != 2 {
		t.Fatalf("player count %d", live[0].PlayerCount())
	}
}

// ------------------------------------------- requirement 30: the entry cap
// (lobbyRules.test.js)

func TestRoomsBigStackCannotJoinCappedTable(t *testing.T) {
	f := newRoomsFixture(t, nil)
	cap := f.cfg.EntryCapMaxChips
	_, err := f.rooms.QuickJoin(f.player("Rich", cap+1), game.QuickJoinOptions{BootAmount: f.cfg.EntryCapBoot, Category: f.cfg.EntryCapCategory})
	expectCode(t, err, game.CodeOverEntryCap)
	if want := "Players with more than 500,000 chips cannot join this table"; err.Error() != want {
		t.Fatalf("message %q, want %q", err.Error(), want)
	}
	if n := len(f.rooms.LiveTables()); n != 0 {
		t.Fatalf("no table was opened for them: %d", n)
	}
}

func TestRoomsStackExactlyAtCapMayJoin(t *testing.T) {
	f := newRoomsFixture(t, nil)
	f.mustQuickJoin(f.player("Edge", f.cfg.EntryCapMaxChips), f.cfg.EntryCapBoot, f.cfg.EntryCapCategory)
}

func TestRoomsCapAppliesOnlyToThatStakeAndCategory(t *testing.T) {
	f := newRoomsFixture(t, nil)
	rich := f.player("Rich", f.cfg.EntryCapMaxChips+1)

	// The same stake in the other category is open.
	f.mustQuickJoin(rich, f.cfg.EntryCapBoot, "seen")
	f.mustLeave(rich.ID, game.LeaveReasonLeft)

	// And so is the higher stake in the capped category.
	f.mustQuickJoin(rich, 5000, f.cfg.EntryCapCategory)
}

func TestRoomsCapIsDisabledByZero(t *testing.T) {
	f := newRoomsFixture(t, func(g *config.GameConfig, _ *game.RoomManagerOptions) { g.EntryCapMaxChips = 0 })
	f.mustQuickJoin(f.player("Rich", 90_000_000), f.cfg.EntryCapBoot, f.cfg.EntryCapCategory)
}

func TestRoomsJoinByCodeRefusesOverCap(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.mustQuickJoin(f.player("Eligible", 1000), f.cfg.EntryCapBoot, f.cfg.EntryCapCategory)
	_, err := f.rooms.JoinByCode(f.player("Rich", f.cfg.EntryCapMaxChips+1), table.Code())
	expectCode(t, err, game.CodeOverEntryCap)
}

func TestRoomsLobbyOptionsReportTheCap(t *testing.T) {
	f := newRoomsFixture(t, nil)
	o := f.rooms.LobbyOptions()
	if o.EntryCapBoot != f.cfg.EntryCapBoot || o.EntryCapCategory != f.cfg.EntryCapCategory || o.EntryCapMaxChips != f.cfg.EntryCapMaxChips {
		t.Fatalf("%+v", o)
	}
}

// ------------------------------------- the cap guards the lobby, not a switch

func TestRoomsSwitchIgnoresTheEntryCap(t *testing.T) {
	f := newRoomsFixture(t, nil)
	rich := f.player("Rich", f.cfg.EntryCapMaxChips+1)

	first := f.mustQuickJoin(f.player("P", 1000), f.cfg.EntryCapBoot, f.cfg.EntryCapCategory)
	second := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: f.cfg.EntryCapBoot, Category: f.cfg.EntryCapCategory})
	f.mustJoin(second, f.player("Q", 2000))

	// The rich player got in before their stack grew.
	f.mustJoin(first, rich)

	result, err := f.rooms.SwitchTable(rich)
	if err != nil {
		t.Fatal(err)
	}
	if result.To.ID() != second.ID() || result.From.ID() != first.ID() {
		t.Fatalf("moved to %s from %s", result.To.ID(), result.From.ID())
	}
	if f.rooms.GetTableForPlayer(rich.ID).ID() != second.ID() {
		t.Fatal("index follows the switch")
	}
}

func TestRoomsSwitchNeverChangesStakeOrCategory(t *testing.T) {
	f := newRoomsFixture(t, nil)
	home := f.mustQuickJoin(f.player("P", 1000), f.cfg.EntryCapBoot, f.cfg.EntryCapCategory)
	// Tables of a different kind are not candidates, however empty they are.
	f.rooms.CreateTable(game.CreateTableOptions{BootAmount: f.cfg.EntryCapBoot, Category: "seen"})
	f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 5000, Category: f.cfg.EntryCapCategory})
	mover := f.player("Mover", 1000)
	f.mustJoin(home, mover)

	_, err := f.rooms.SwitchTable(mover)
	expectCode(t, err, game.CodeNoOtherTable)
	if want := "No other blind table at this stake has a free seat right now"; err.Error() != want {
		t.Fatalf("message %q", err.Error())
	}
}

func TestRoomsSwitchKeepsSeatWhenNowhereToGo(t *testing.T) {
	f := newRoomsFixture(t, nil)
	home := f.mustQuickJoin(f.player("P", 1000), f.cfg.EntryCapBoot, f.cfg.EntryCapCategory)
	mover := f.player("Mover", 1000)
	f.mustJoin(home, mover)

	_, err := f.rooms.SwitchTable(mover)
	expectCode(t, err, game.CodeNoOtherTable)
	if got := f.rooms.GetTableForPlayer(mover.ID); got == nil || got.ID() != home.ID() {
		t.Fatal("still seated where they were")
	}
	if home.PlayerCount() != 2 {
		t.Fatal("the seat was never given up")
	}
}

func TestRoomsUnseatedPlayerCannotSwitch(t *testing.T) {
	f := newRoomsFixture(t, nil)
	_, err := f.rooms.SwitchTable(f.player("Nobody", 1000))
	expectCode(t, err, game.CodeNotInRoom)
	if err.Error() != "You are not at a table" {
		t.Fatalf("message %q", err.Error())
	}
}

func TestRoomsSwitchFromPrivateTableRefused(t *testing.T) {
	f := newRoomsFixture(t, nil)
	private := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true})
	host := f.player("Host", rmStart)
	f.mustJoin(private, host)
	f.singleTable(f.cfg.PrivateBoot, game.CategorySeen)

	_, err := f.rooms.SwitchTable(host)
	expectCode(t, err, game.CodePrivateTable)
	if f.rooms.GetTableForPlayer(host.ID) != private {
		t.Fatal("still at the private table")
	}
}

func TestRoomsSwitchPicksTheFullestOtherTable(t *testing.T) {
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		g.NextHandDelay = time.Hour // keep every table idle so seats stay put
	})
	home := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	mover := f.player("Mover", rmStart)
	f.mustJoin(home, mover)
	f.mustJoin(home, f.player("Stay", rmStart))
	sparse := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(sparse, f.player("S1", rmStart))
	busier := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	for i := 0; i < 3; i++ {
		f.mustJoin(busier, f.player("B", rmStart))
	}
	full := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	for i := 0; i < 5; i++ {
		f.mustJoin(full, f.player("F", rmStart))
	}

	result, err := f.rooms.SwitchTable(mover)
	if err != nil {
		t.Fatal(err)
	}
	if result.To != busier {
		t.Fatalf("switched to %s, want the busier table %s", result.To.ID(), busier.ID())
	}
	if home.PlayerCount() != 1 || busier.PlayerCount() != 4 {
		t.Fatalf("home %d busier %d", home.PlayerCount(), busier.PlayerCount())
	}
	_ = sparse
}

func TestRoomsSwitchLeavesWithReasonMovedAndSkipsConsolidation(t *testing.T) {
	f := newRoomsFixture(t, nil)
	home := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	mover := f.player("Mover", rmStart)
	f.mustJoin(home, mover)
	target := f.singleTable(rmBoot, game.CategoryBlind)
	lonely := f.singleTable(rmBoot, game.CategoryBlind)

	result, err := f.rooms.SwitchTable(mover)
	if err != nil {
		t.Fatal(err)
	}
	if result.From != home || result.To != target {
		t.Fatalf("from %s to %s", result.From.ID(), result.To.ID())
	}
	// The emptied home table is destroyed …
	if f.rooms.GetTable(home.ID()) != nil || !home.Destroyed() {
		t.Fatal("the emptied source was destroyed")
	}
	found := false
	for _, id := range f.events.destroyedCopy() {
		found = found || id == home.ID()
	}
	if !found {
		t.Fatal("OnTableDestroyed(home) was reported")
	}
	// … and "moved" skipped the merge sweep: the other lone table is still
	// on its own even though it could have been merged into the target.
	if f.rooms.GetTable(lonely.ID()) == nil || lonely.PlayerCount() != 1 || target.PlayerCount() != 2 {
		t.Fatalf("lonely %d target %d", lonely.PlayerCount(), target.PlayerCount())
	}
}

func TestRoomsSwitchMidHandPacksWithReasonMoved(t *testing.T) {
	f := newRoomsFixture(t, nil)
	home := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	mover := f.player("Mover", rmStart)
	f.mustJoin(home, mover)
	f.mustJoin(home, f.player("Stay", rmStart))
	f.mustJoin(home, f.player("Stay2", rmStart))
	f.clock.Advance(10 * time.Second)
	if !home.HasHand() {
		t.Fatal("hand expected")
	}
	f.singleTable(rmBoot, game.CategoryBlind)

	if _, err := f.rooms.SwitchTable(mover); err != nil {
		t.Fatal(err)
	}
	var packs []game.ActionEvent
	for _, a := range f.tables.actionsCopy() {
		if a.UserID == mover.ID && a.Action == game.ActionPack {
			packs = append(packs, a)
		}
	}
	if len(packs) != 1 || packs[0].Reason != game.LeaveReasonMoved {
		t.Fatalf("the departure is a pack with reason moved: %+v", packs)
	}
}

// -------------------------------------------------------- requirement 22
// (privateTables.test.js)

func TestRoomsPrivateTableAlwaysUsesTheFixedBoot(t *testing.T) {
	f := newRoomsFixture(t, nil)
	for _, asked := range []int64{50, 199, 200, 1000, 99999, 0} {
		table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: asked, IsPrivate: true})
		if table.BootAmount() != 200 || table.Config().BootAmount != 200 {
			t.Fatalf("asking for %d still gives 200, got %d", asked, table.BootAmount())
		}
		if !table.IsPrivate() {
			t.Fatal("private flag")
		}
	}
}

func TestRoomsPublicTableKeepsItsStake(t *testing.T) {
	f := newRoomsFixture(t, nil)
	if got := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 100}).BootAmount(); got != 100 {
		t.Fatalf("boot %d", got)
	}
	if got := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 5000}).BootAmount(); got != 5000 {
		t.Fatalf("boot %d", got)
	}
	if got := f.rooms.CreateTable(game.CreateTableOptions{}).BootAmount(); got != f.cfg.BootAmount {
		t.Fatalf("an unspecified boot is the default: %d", got)
	}
}

func TestRoomsLobbyAdvertisesPrivateBootAndMaxPot(t *testing.T) {
	f := newRoomsFixture(t, nil)
	o := f.rooms.LobbyOptions()
	if o.PrivateBoot != 200 || o.PrivateMaxPot != 500000 {
		t.Fatalf("%+v", o)
	}
}

func TestRoomsPrivateTableAllowsASingleDouble(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 200, IsPrivate: true, Category: "blind"})
	seatTwoAndDeal(t, f, table, 2_000_000)

	who := turnUser(t, table)
	opts := optionsFor(t, table, who)
	if !equalInt64s(opts.RaiseSteps, []int64{200, 400}) {
		t.Fatalf("the chaal and one double, nothing further: %v", opts.RaiseSteps)
	}
	_, err := table.Act(who, game.ActionRaise, game.ActRequest{Amount: game.Int64Ptr(800)})
	expectCode(t, err, game.CodeInvalidBet)
}

func TestRoomsPublicBlindKeepsTheFullLadder(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 200, Category: "blind"})
	seatTwoAndDeal(t, f, table, 2_000_000)
	opts := optionsFor(t, table, turnUser(t, table))
	if len(opts.RaiseSteps) <= 2 {
		t.Fatalf("public blind tables can keep doubling: %v", opts.RaiseSteps)
	}
}

func TestRoomsPotCeilingsPerKind(t *testing.T) {
	f := newRoomsFixture(t, nil)
	cases := []struct {
		name string
		opts game.CreateTableOptions
		want int64
	}{
		{"private seen", game.CreateTableOptions{BootAmount: 200, IsPrivate: true}, 500000},
		{"private blind", game.CreateTableOptions{BootAmount: 200, IsPrivate: true, Category: "blind"}, 500000},
		{"public seen", game.CreateTableOptions{BootAmount: 200, Category: "seen"}, 1200000},
		{"public blind", game.CreateTableOptions{BootAmount: 200, Category: "blind"}, 0},
	}
	for _, c := range cases {
		if got := f.rooms.CreateTable(c.opts).MaxPot(); got != c.want {
			t.Fatalf("%s: maxPot %d, want %d", c.name, got, c.want)
		}
	}
}

func TestRoomsCeilingReportedInSnapshot(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 200, IsPrivate: true})
	a, _ := seatTwoAndDeal(t, f, table, 2_000_000)
	if got := viewOf(t, table, a.ID).MaxPot; got != 500000 {
		t.Fatalf("maxPot %d", got)
	}
}

func TestRoomsUncappedBlindLadderRunsToTheStack(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 200, Category: "blind"})
	seatTwoAndDeal(t, f, table, 2_000_000)
	who := turnUser(t, table)
	opts := optionsFor(t, table, who)
	if len(opts.RaiseSteps) <= 8 {
		t.Fatalf("runs past the eight rungs of a capped ladder (%d)", len(opts.RaiseSteps))
	}
	if opts.MaxBet == nil || *opts.MaxBet > opts.Chips {
		t.Fatalf("never past what the player holds: %v / %d", opts.MaxBet, opts.Chips)
	}
	if *opts.MaxBet*2 <= opts.Chips {
		t.Fatal("stops only where the next double would not fit")
	}
}

// --------------------------- requirement 19: seen tables play tighter
// (tableRules.test.js, RoomManager parts)

func TestRoomsSeenTableAllowsASingleDouble(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	if table.Config().MaxBetRounds != 7 {
		t.Fatalf("seven rounds each, then everyone shows: %d", table.Config().MaxBetRounds)
	}
	seatTwoAndDeal(t, f, table, rmStart)
	who := turnUser(t, table)
	opts := optionsFor(t, table, who)
	if !equalInt64s(opts.RaiseSteps, []int64{rmBoot, rmBoot * 2}) {
		t.Fatalf("steps %v", opts.RaiseSteps)
	}
	_, err := table.Act(who, game.ActionRaise, game.ActRequest{Amount: game.Int64Ptr(rmBoot * 4)})
	expectCode(t, err, game.CodeInvalidBet)
}

func TestRoomsBlindTableKeepsTheDoublingLadder(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	seatTwoAndDeal(t, f, table, rmStart)
	opts := optionsFor(t, table, turnUser(t, table))
	if len(opts.RaiseSteps) <= 2 || opts.RaiseSteps[2] != rmBoot*4 {
		t.Fatalf("steps %v", opts.RaiseSteps)
	}
}

func TestRoomsBlindTableConfigIsOpenEnded(t *testing.T) {
	f := newRoomsFixture(t, nil)
	cfg := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"}).Config()
	if cfg.MaxBetRounds != 0 || cfg.MaxRaiseSteps != 0 || cfg.PotLimitMultiplier != 0 || cfg.MaxPot != 0 {
		t.Fatalf("%+v", cfg)
	}
}

func TestRoomsCreateTableConfigIsExplicit(t *testing.T) {
	// Every TableConfig field is set from config, per category; a zero that
	// means "unlimited" is a deliberate zero, never an unset field.
	f := newRoomsFixture(t, nil)
	g := f.cfg
	common := game.TableConfig{
		MaxPlayers:         g.MaxPlayers,
		MinPlayers:         g.MinPlayers,
		TurnTimeout:        g.TurnTimeout,
		MaxBlindMoves:      g.MaxBlindMoves,
		MaxMissedTurns:     g.MaxMissedTurns,
		SideshowTimeout:    g.SideshowTimeout,
		SideshowMinPlayers: g.SideshowMinPlayers,
		NextHandDelay:      g.NextHandDelay,
		ChatMaxHistory:     100,
		ChatMaxLength:      140,
	}
	seen := common
	seen.Category, seen.BootAmount = game.CategorySeen, 200
	seen.MaxRaiseSteps, seen.MaxBetRounds, seen.MaxPot, seen.PotLimitMultiplier = 2, 7, 1_200_000, 1024
	blind := common
	blind.Category, blind.BootAmount = game.CategoryBlind, 5000
	blind.MaxRaiseSteps, blind.MaxBetRounds, blind.MaxPot, blind.PotLimitMultiplier = 0, 0, 0, 0
	privateBlind := common
	privateBlind.Category, privateBlind.BootAmount = game.CategoryBlind, 200
	privateBlind.MaxRaiseSteps, privateBlind.MaxBetRounds, privateBlind.MaxPot, privateBlind.PotLimitMultiplier = 2, 0, 500_000, 0
	privateSeen := seen
	privateSeen.MaxPot = 500_000

	cases := []struct {
		name string
		opts game.CreateTableOptions
		want game.TableConfig
	}{
		{"seen", game.CreateTableOptions{BootAmount: 200, Category: "seen"}, seen},
		{"blind", game.CreateTableOptions{BootAmount: 5000, Category: "blind"}, blind},
		{"private blind", game.CreateTableOptions{BootAmount: 5000, IsPrivate: true, Category: "blind"}, privateBlind},
		{"private seen (default category)", game.CreateTableOptions{BootAmount: 777, IsPrivate: true}, privateSeen},
		{"unknown category is seen", game.CreateTableOptions{BootAmount: 200, Category: "BLIND"}, seen},
	}
	for _, c := range cases {
		if got := f.rooms.CreateTable(c.opts).Config(); got != c.want {
			t.Fatalf("%s:\n got  %+v\n want %+v", c.name, got, c.want)
		}
	}
}

func TestRoomsBlindTableNeverForcesAShowdown(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	seatTwoAndDeal(t, f, table, rmStart)

	for i := 0; i < 120 && table.HasHand(); i++ {
		if _, err := table.Act(turnUser(t, table), game.ActionChaal, game.ActRequest{}); err != nil {
			t.Fatalf("chaal %d: %v", i, err)
		}
	}
	if !table.HasHand() {
		t.Fatal("the hand is still live after 60 rounds each")
	}
	if round := viewOf(t, table, "").Round; round < 50 {
		t.Fatalf("rounds counted: %d", round)
	}
	if n := len(f.tables.endedCopy()); n != 0 {
		t.Fatalf("nothing but a pack or a show ends a blind hand: %d", n)
	}
}

func TestRoomsSeenTableForcesAShowdownAfterSevenRounds(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	seatTwoAndDeal(t, f, table, rmStart)

	for i := 0; i < 60 && table.HasHand(); i++ {
		if _, err := table.Act(turnUser(t, table), game.ActionChaal, game.ActRequest{}); err != nil {
			t.Fatalf("chaal %d: %v", i, err)
		}
	}
	if table.HasHand() {
		t.Fatal("the hand ended on its own")
	}
	ended := f.tables.endedCopy()
	if len(ended) == 0 || ended[len(ended)-1].Reason != game.WinForcedShowdown {
		t.Fatalf("ended %v", ended)
	}
	shows := f.tables.showdownsCopy()
	if len(shows) == 0 || len(shows[len(shows)-1].Reveals) != 2 {
		t.Fatalf("everybody's cards are shown: %v", shows)
	}
	if ended[len(ended)-1].WinnerID == nil {
		t.Fatal("and the pot goes to the best hand")
	}
}

// ------------------------------------------------------- the lobby menu
// (stakes.test.js, in-process parts; runs on the real defaults)

func TestRoomsLobbyOffersExactlyTheDefaultMenu(t *testing.T) {
	f := newRoomsFixture(t, nil)
	o := f.rooms.LobbyOptions()
	if !equalInt64s(o.Stakes, []int64{200, 5000}) {
		t.Fatalf("stakes %v", o.Stakes)
	}
	if len(o.Categories) != 2 || o.Categories[0] != game.CategorySeen || o.Categories[1] != game.CategoryBlind {
		t.Fatalf("categories %v", o.Categories)
	}
	wantTables := []game.LobbyTableOption{
		{Category: "seen", BootAmount: 200, MaxPot: 1200000, MaxBlindMoves: 4},
		{Category: "blind", BootAmount: 200, MaxPot: 0, MaxBlindMoves: 4},
		{Category: "blind", BootAmount: 5000, MaxPot: 0, MaxBlindMoves: 4},
	}
	if len(o.Tables) != len(wantTables) {
		t.Fatalf("tables %+v", o.Tables)
	}
	for i := range wantTables {
		if o.Tables[i] != wantTables[i] {
			t.Fatalf("table %d: %+v want %+v", i, o.Tables[i], wantTables[i])
		}
	}

	raw, err := json.Marshal(o)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"categories":["seen","blind"],"stakes":[200,5000],"tables":[` +
		`{"category":"seen","bootAmount":200,"maxPot":1200000,"maxBlindMoves":4},` +
		`{"category":"blind","bootAmount":200,"maxPot":0,"maxBlindMoves":4},` +
		`{"category":"blind","bootAmount":5000,"maxPot":0,"maxBlindMoves":4}],` +
		`"entryCapBoot":200,"entryCapCategory":"blind","entryCapMaxChips":500000,"privateBoot":200,"privateMaxPot":500000}`
	if string(raw) != want {
		t.Fatalf("json\n got  %s\n want %s", raw, want)
	}
}

func TestRoomsLobbyOptionsEmptyMenuMarshalsEmptyArrays(t *testing.T) {
	f := newRoomsFixture(t, openMenu)
	raw, err := json.Marshal(f.rooms.LobbyOptions())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"stakes":[]`) || !strings.Contains(string(raw), `"tables":[]`) {
		t.Fatalf("empty lists are [] never null: %s", raw)
	}
}

func TestRoomsAdvertisedCeilingMatchesTheTableBuilt(t *testing.T) {
	f := newRoomsFixture(t, nil)
	for _, entry := range f.rooms.LobbyOptions().Tables {
		table := f.mustQuickJoin(f.player("P", rmStart), entry.BootAmount, entry.Category)
		if table.MaxPot() != entry.MaxPot {
			t.Fatalf("%s %d: maxPot %d, card says %d", entry.Category, entry.BootAmount, table.MaxPot(), entry.MaxPot)
		}
		if table.Config().MaxBlindMoves != entry.MaxBlindMoves {
			t.Fatalf("maxBlindMoves %d vs %d", table.Config().MaxBlindMoves, entry.MaxBlindMoves)
		}
	}
}

func TestRoomsEveryMenuRoomCanBeJoined(t *testing.T) {
	f := newRoomsFixture(t, nil)
	for _, entry := range f.rooms.LobbyOptions().Tables {
		table := f.mustQuickJoin(f.player("P", rmStart), entry.BootAmount, entry.Category)
		if table.BootAmount() != entry.BootAmount || string(table.Category()) != entry.Category {
			t.Fatalf("%+v vs %s %d", entry, table.Category(), table.BootAmount())
		}
	}
	if n := len(f.rooms.ListTables(game.ListOptions{})); n != 3 {
		t.Fatalf("listTables %d", n)
	}
}

func TestRoomsPairNotOnMenuRefused(t *testing.T) {
	f := newRoomsFixture(t, nil)
	// Both halves are offered on their own; the pair is not.
	_, err := f.rooms.QuickJoin(f.player("P", rmStart), game.QuickJoinOptions{BootAmount: 5000, Category: "seen"})
	expectCode(t, err, game.CodeTableNotOffered)
	if want := "The lobby offers: seen 200, blind 200, blind 5000"; err.Error() != want {
		t.Fatalf("message %q", err.Error())
	}
	if n := len(f.rooms.ListTables(game.ListOptions{})); n != 0 {
		t.Fatalf("no room was opened for it: %d", n)
	}
}

func TestRoomsStakeNotOfferedRefused(t *testing.T) {
	f := newRoomsFixture(t, nil)
	for _, boot := range []int64{1, 100, 199, 4999, 10000} {
		_, err := f.rooms.QuickJoin(f.player("P", rmStart), game.QuickJoinOptions{BootAmount: boot})
		expectCode(t, err, game.CodeInvalidStake)
		if want := "Stake must be one of: 200, 5000"; err.Error() != want {
			t.Fatalf("%d: message %q", boot, err.Error())
		}
	}
}

func TestRoomsMalformedStakeRefused(t *testing.T) {
	f := newRoomsFixture(t, nil)
	for _, boot := range []int64{0, -200} {
		_, err := f.rooms.QuickJoin(f.player("P", rmStart), game.QuickJoinOptions{BootAmount: boot})
		expectCode(t, err, game.CodeInvalidStake)
		if want := "That stake is not valid"; err.Error() != want {
			t.Fatalf("%d: message %q", boot, err.Error())
		}
	}
	// With an open menu the positivity check still holds.
	open := newRoomsFixture(t, openMenu)
	_, err := open.rooms.QuickJoin(open.player("P", rmStart), game.QuickJoinOptions{BootAmount: 0})
	expectCode(t, err, game.CodeInvalidStake)
	if err := open.rooms.AssertStakeAllowed(123); err != nil {
		t.Fatalf("an empty TableStakes means anything goes: %v", err)
	}
}

func TestRoomsShortOfStakeCannotSitDown(t *testing.T) {
	f := newRoomsFixture(t, nil)
	_, err := f.rooms.QuickJoin(f.player("Poor", 4999), game.QuickJoinOptions{BootAmount: 5000, Category: "blind"})
	expectCode(t, err, game.CodeInsufficientChips)
	if err.Error() != "Not enough chips to join this table" {
		t.Fatalf("message %q", err.Error())
	}
	table := f.mustQuickJoin(f.player("Poor", 4999), 200, "")
	if table.BootAmount() != 200 {
		t.Fatalf("boot %d", table.BootAmount())
	}
}

func TestRoomsPlayersClusterOntoTheFullestTable(t *testing.T) {
	f := newRoomsFixture(t, nil)
	first := f.mustQuickJoin(f.player("P", rmStart), 200, "seen")
	second := f.mustQuickJoin(f.player("P", rmStart), 200, "seen")
	if first != second {
		t.Fatal("the second player joins the first table")
	}
	other := f.mustQuickJoin(f.player("P", rmStart), 200, "blind")
	if other == first {
		t.Fatal("a different category at the same stake starts its own table")
	}
}

func TestRoomsQuickJoinPrefersTheFullestAndBreaksTiesByAge(t *testing.T) {
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		g.NextHandDelay = time.Hour
	})
	older := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(older, f.player("O", rmStart))
	newer := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(newer, f.player("N", rmStart))
	if got := f.mustQuickJoin(f.player("P", rmStart), rmBoot, "blind"); got != older {
		t.Fatal("ties go to the earliest created table")
	}
	// newer now has 1, older 2 → older still; fill older to 5 and the next
	// quick-join lands on newer; then when both are full a fresh table opens.
	for older.PlayerCount() < 5 {
		if got := f.mustQuickJoin(f.player("P", rmStart), rmBoot, "blind"); got != older {
			t.Fatal("the fullest table with room wins")
		}
	}
	if got := f.mustQuickJoin(f.player("P", rmStart), rmBoot, "blind"); got != newer {
		t.Fatal("a full table is skipped")
	}
	for newer.PlayerCount() < 5 {
		f.mustQuickJoin(f.player("P", rmStart), rmBoot, "blind")
	}
	fresh := f.mustQuickJoin(f.player("P", rmStart), rmBoot, "blind")
	if fresh == older || fresh == newer || fresh.PlayerCount() != 1 {
		t.Fatal("every table full → a new one is opened")
	}
	if n := len(f.rooms.LiveTables()); n != 3 {
		t.Fatalf("tables %d", n)
	}
}

func TestRoomsQuickJoinNeverPicksAPrivateTable(t *testing.T) {
	f := newRoomsFixture(t, nil)
	private := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true, Category: "seen"})
	f.mustJoin(private, f.player("Host", rmStart))
	if got := f.mustQuickJoin(f.player("P", rmStart), 200, "seen"); got == private {
		t.Fatal("a private table is reached by code only")
	}
	if n := len(f.rooms.ListTables(game.ListOptions{})); n != 1 {
		t.Fatalf("private tables are never listed: %d", n)
	}
	if n := len(f.rooms.ListTables(game.ListOptions{IncludePrivate: true})); n != 2 {
		t.Fatalf("unless asked for: %d", n)
	}
}

func TestRoomsUnknownCategoryIsSeen(t *testing.T) {
	f := newRoomsFixture(t, nil)
	for _, c := range []string{"", "seen", "BLIND", "Blind", "hidden", " blind"} {
		if got := game.NormalizeCategory(c); got != game.CategorySeen {
			t.Fatalf("%q → %s", c, got)
		}
		table := f.mustQuickJoin(f.player("P", rmStart), 200, c)
		if table.Category() != game.CategorySeen {
			t.Fatalf("%q → table category %s", c, table.Category())
		}
	}
	if game.NormalizeCategory("blind") != game.CategoryBlind {
		t.Fatal("blind is blind")
	}
}

func TestRoomsQuickJoinCheckOrder(t *testing.T) {
	f := newRoomsFixture(t, nil)
	seated := f.player("Seated", rmStart)
	f.mustQuickJoin(seated, 200, "seen")

	// already_in_room comes before every other check.
	_, err := f.rooms.QuickJoin(seated, game.QuickJoinOptions{BootAmount: 42})
	expectCode(t, err, game.CodeAlreadyInRoom)
	if err.Error() != "You are already seated at a table" {
		t.Fatalf("message %q", err.Error())
	}
	// invalid_stake before table_not_offered …
	_, err = f.rooms.QuickJoin(f.player("P", 1), game.QuickJoinOptions{BootAmount: 42, Category: "seen"})
	expectCode(t, err, game.CodeInvalidStake)
	// … before insufficient_chips …
	_, err = f.rooms.QuickJoin(f.player("P", 1), game.QuickJoinOptions{BootAmount: 5000, Category: "seen"})
	expectCode(t, err, game.CodeTableNotOffered)
	// … before the entry cap (a huge stack that cannot cover the boot is
	// impossible, so this is checked with a stack short of the boot but
	// otherwise fine).
	_, err = f.rooms.QuickJoin(f.player("P", 199), game.QuickJoinOptions{BootAmount: 200, Category: "blind"})
	expectCode(t, err, game.CodeInsufficientChips)
	_, err = f.rooms.QuickJoin(f.player("P", f.cfg.EntryCapMaxChips+1), game.QuickJoinOptions{BootAmount: 200, Category: "blind"})
	expectCode(t, err, game.CodeOverEntryCap)
}

// ------------------------------------------------------------ join by code

func TestRoomsJoinByCodeUnknownCode(t *testing.T) {
	f := newRoomsFixture(t, nil)
	_, err := f.rooms.JoinByCode(f.player("P", rmStart), "ZZZZZZ")
	expectCode(t, err, game.CodeRoomNotFound)
	if err.Error() != "No table with that code" {
		t.Fatalf("message %q", err.Error())
	}
}

func TestRoomsJoinByCodeFullTableSaysThatTableIsFull(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true})
	for i := 0; i < 5; i++ {
		f.mustJoin(table, f.player("P", rmStart))
	}
	_, err := f.rooms.JoinByCode(f.player("Late", rmStart), table.Code())
	expectCode(t, err, game.CodeTableFull)
	if err.Error() != "That table is full" {
		t.Fatalf("message %q (the Table's own refusal says \"This table is full\")", err.Error())
	}
}

func TestRoomsJoinByCodeIsCaseInsensitive(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true})
	got, err := f.rooms.JoinByCode(f.player("P", rmStart), strings.ToLower(table.Code()))
	if err != nil || got != table {
		t.Fatalf("%v %v", got, err)
	}
	if f.rooms.GetTableByCode(strings.ToLower(table.Code())) != table || f.rooms.GetTableByCode("nope") != nil {
		t.Fatal("GetTableByCode upper-cases")
	}
}

func TestRoomsJoinByCodeInsufficientChips(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 5000, Category: "blind"})
	_, err := f.rooms.JoinByCode(f.player("Poor", 4999), table.Code())
	expectCode(t, err, game.CodeInsufficientChips)
}

func TestRoomsJoinByCodePrivateSkipsEntryCap(t *testing.T) {
	f := newRoomsFixture(t, nil)
	private := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true, Category: f.cfg.EntryCapCategory})
	if private.BootAmount() != f.cfg.EntryCapBoot {
		t.Skip("the private boot is not the capped boot in this config")
	}
	rich := f.player("Rich", f.cfg.EntryCapMaxChips+1)
	if _, err := f.rooms.JoinByCode(rich, private.Code()); err != nil {
		t.Fatalf("you were invited: %v", err)
	}
}

func TestRoomsJoinByCodeSeatedRefused(t *testing.T) {
	f := newRoomsFixture(t, nil)
	p := f.player("P", rmStart)
	table := f.mustQuickJoin(p, 200, "seen")
	other := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true})
	_, err := f.rooms.JoinByCode(p, other.Code())
	expectCode(t, err, game.CodeAlreadyInRoom)
	if f.rooms.GetTableForPlayer(p.ID) != table {
		t.Fatal("still at the first table")
	}
}

// -------------------------------------------------------------- join / leave

func TestRoomsJoinRefusesASecondSeat(t *testing.T) {
	f := newRoomsFixture(t, nil)
	a := f.rooms.CreateTable(game.CreateTableOptions{})
	b := f.rooms.CreateTable(game.CreateTableOptions{})
	p := f.player("P", rmStart)
	f.mustJoin(a, p)
	expectCode(t, f.rooms.Join(b, p, ""), game.CodeAlreadyInRoom)
	expectCode(t, f.rooms.Join(a, p, ""), game.CodeAlreadyInRoom)
	if b.PlayerCount() != 0 || a.PlayerCount() != 1 {
		t.Fatal("no seat was taken")
	}
	if f.rooms.Stats().Players != 1 {
		t.Fatal("the index holds one entry")
	}
}

func TestRoomsJoinRollsBackTheIndexWhenTheTableRefuses(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{})
	p := f.player("P", rmStart)
	// Seated behind the manager's back (no index entry): the Table refuses
	// with already_seated and the reservation is rolled back.
	if _, err := table.AddPlayer(game.NewPlayer{UserID: p.ID, DisplayName: p.DisplayName, Chips: p.Chips}); err != nil {
		t.Fatal(err)
	}
	expectCode(t, f.rooms.Join(table, p, ""), game.CodeAlreadySeated)
	if f.rooms.GetTableForPlayer(p.ID) != nil || f.rooms.Stats().Players != 0 {
		t.Fatal("the reservation was removed")
	}
	// A full table refuses too, and the index stays clean.
	full := f.rooms.CreateTable(game.CreateTableOptions{})
	for i := 0; i < 5; i++ {
		f.mustJoin(full, f.player("F", rmStart))
	}
	late := f.player("Late", rmStart)
	expectCode(t, f.rooms.Join(full, late, ""), game.CodeTableFull)
	if f.rooms.GetTableForPlayer(late.ID) != nil {
		t.Fatal("not indexed")
	}
}

func TestRoomsJoinOnADestroyedTableIsRefused(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{})
	if err := f.rooms.DestroyTable(table.ID()); err != nil {
		t.Fatal(err)
	}
	err := f.rooms.Join(table, f.player("P", rmStart), "")
	if !errors.Is(err, game.ErrTableDestroyed) {
		t.Fatalf("got %v", err)
	}
	if f.rooms.Stats().Players != 0 {
		t.Fatal("nothing indexed")
	}
	if err := f.rooms.DestroyTable(table.ID()); err != nil {
		t.Fatalf("destroying an unknown id is a no-op: %v", err)
	}
}

func TestRoomsLeaveUnseatedIsANoOp(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table, err := f.rooms.Leave("nobody", game.LeaveReasonLeft)
	if table != nil || err != nil {
		t.Fatalf("%v %v", table, err)
	}
}

func TestRoomsLeaveReasonReachesTheWire(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	for i := 0; i < 3; i++ {
		f.mustJoin(table, f.player("P", rmStart))
	}
	f.clock.Advance(10 * time.Second)
	if !table.HasHand() {
		t.Fatal("hand expected")
	}
	leaver := seatedIDs(t, table)[0]

	left := f.mustLeave(leaver, game.LeaveReasonDisconnected)
	if left != table {
		t.Fatal("returns the table left")
	}
	var pack *game.ActionEvent
	for _, a := range f.tables.actionsCopy() {
		if a.UserID == leaver && a.Action == game.ActionPack {
			a := a
			pack = &a
		}
	}
	if pack == nil || pack.Reason != game.LeaveReasonDisconnected {
		t.Fatalf("pack %+v", pack)
	}
	if f.rooms.GetTableForPlayer(leaver) != nil {
		t.Fatal("off the index")
	}
	if table.PlayerCount() != 2 || !table.HasHand() {
		t.Fatal("the other two play on")
	}
}

func TestRoomsLeaveDestroysAnEmptiedTable(t *testing.T) {
	f := newRoomsFixture(t, nil)
	p := f.player("P", rmStart)
	table := f.mustQuickJoin(p, 200, "seen")
	if s := f.rooms.Stats(); s.Tables != 1 || s.Players != 1 {
		t.Fatalf("%+v", s)
	}

	f.mustLeave(p.ID, game.LeaveReasonLeft)

	if f.rooms.GetTable(table.ID()) != nil || !table.Destroyed() {
		t.Fatal("the emptied table is gone")
	}
	if d := f.events.destroyedCopy(); len(d) != 1 || d[0] != table.ID() {
		t.Fatalf("destroyed %v", d)
	}
	if s := f.rooms.Stats(); s != (game.Stats{}) {
		t.Fatalf("%+v", s)
	}
	if !strings.Contains(f.logText(), `"msg":"table destroyed"`) {
		t.Fatal("logged")
	}
}

func TestRoomsLeaveWithReasonMovedSkipsConsolidation(t *testing.T) {
	f := newRoomsFixture(t, nil)
	a := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(a, f.player("A1", rmStart))
	f.mustJoin(a, f.player("A2", rmStart))
	f.singleTable(rmBoot, game.CategoryBlind)

	f.mustLeave(seatedIDs(t, a)[0], game.LeaveReasonMoved)

	if n := len(f.rooms.LiveTables()); n != 2 {
		t.Fatalf("no merge on a move: %d tables", n)
	}
	if len(f.events.movedCopy()) != 0 {
		t.Fatal("nobody moved")
	}
}

// ------------------------------------------------------------- lifecycle

func TestRoomsSweepEmptyTablesUsesTheThirtySecondAge(t *testing.T) {
	f := newRoomsFixture(t, nil)
	old := f.rooms.CreateTable(game.CreateTableOptions{})
	occupiedOld := f.rooms.CreateTable(game.CreateTableOptions{})
	f.mustJoin(occupiedOld, f.player("P", rmStart))
	f.clock.Advance(29 * time.Second)
	if err := f.rooms.SweepEmptyTables(); err != nil {
		t.Fatal(err)
	}
	if f.rooms.GetTable(old.ID()) == nil {
		t.Fatal("29 s is not old enough")
	}
	f.clock.Advance(time.Second) // exactly 30 s: Node's `createdAt < cutoff` is strict
	if err := f.rooms.SweepEmptyTables(); err != nil {
		t.Fatal(err)
	}
	if f.rooms.GetTable(old.ID()) == nil {
		t.Fatal("exactly 30 s is not older than 30 s")
	}
	young := f.rooms.CreateTable(game.CreateTableOptions{})
	f.clock.Advance(time.Millisecond)
	if err := f.rooms.SweepEmptyTables(); err != nil {
		t.Fatal(err)
	}
	if f.rooms.GetTable(old.ID()) != nil {
		t.Fatal("an empty table older than 30 s is swept")
	}
	if f.rooms.GetTable(young.ID()) == nil || f.rooms.GetTable(occupiedOld.ID()) == nil {
		t.Fatal("young and occupied tables stay")
	}
}

func TestRoomsSweeperRunsOnTheIntervalUntilShutdown(t *testing.T) {
	f := newRoomsFixture(t, nil)
	interval := f.cfg.ConsolidateInterval // 15 s
	f.rooms.StartSweeper()
	f.rooms.StartSweeper() // safe to call twice

	empty := f.rooms.CreateTable(game.CreateTableOptions{})
	f.singleTable(rmBoot, game.CategoryBlind)
	f.singleTable(rmBoot, game.CategoryBlind)

	// Nothing happens before the first tick.
	f.clock.Advance(interval - time.Millisecond)
	if len(f.events.movedCopy()) != 0 {
		t.Fatal("no tick yet")
	}
	// The first tick merges the singles; the empty table is too young.
	f.clock.Advance(time.Millisecond)
	if len(f.events.movedCopy()) != 1 {
		t.Fatalf("the tick consolidated: %v", f.events.movedCopy())
	}
	if f.rooms.GetTable(empty.ID()) == nil {
		t.Fatal("15 s old is kept")
	}
	// The next tick (30 s) still keeps it (not strictly older); the one after
	// sweeps it.
	f.clock.Advance(interval)
	if f.rooms.GetTable(empty.ID()) == nil {
		t.Fatal("exactly 30 s old is kept")
	}
	f.clock.Advance(interval)
	if f.rooms.GetTable(empty.ID()) != nil {
		t.Fatal("swept on the third tick")
	}

	// Shutdown stops the interval: a later empty table is never swept.
	if err := f.rooms.Shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := len(f.rooms.LiveTables()); n != 0 {
		t.Fatalf("shutdown destroys everything: %d", n)
	}
	later := f.rooms.CreateTable(game.CreateTableOptions{})
	f.clock.Advance(10 * interval)
	if f.rooms.GetTable(later.ID()) == nil {
		t.Fatal("the sweeper is stopped")
	}
	if f.clock.Pending() != 0 {
		t.Fatalf("no timer left armed: %d", f.clock.Pending())
	}
}

func TestRoomsShutdownSettlesLiveHands(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	a, b := seatTwoAndDeal(t, f, table, rmStart)
	if _, err := table.Act(turnUser(t, table), game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatal(err)
	}
	pot := viewOf(t, table, "").Pot
	idle := f.rooms.CreateTable(game.CreateTableOptions{})
	if s := f.rooms.Stats(); s.Tables != 2 || s.Players != 2 || s.ActiveHands != 1 {
		t.Fatalf("%+v", s)
	}

	if err := f.rooms.Shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}

	ended := f.tables.endedCopy()
	if len(ended) != 1 || ended[0].Reason != game.WinAllLeft || ended[0].Pot != pot {
		t.Fatalf("the pot is paid out, not voided: %+v", ended)
	}
	if ended[0].WinnerID == nil || (*ended[0].WinnerID != a.ID && *ended[0].WinnerID != b.ID) {
		t.Fatalf("winner %v", ended[0].WinnerID)
	}
	if !table.Destroyed() || !idle.Destroyed() {
		t.Fatal("every table destroyed")
	}
	if s := f.rooms.Stats(); s != (game.Stats{}) {
		t.Fatalf("%+v", s)
	}
	if d := f.events.destroyedCopy(); len(d) != 2 {
		t.Fatalf("destroyed %v", d)
	}
	if f.rooms.GetTableForPlayer(a.ID) != nil {
		t.Fatal("nobody is seated")
	}
	if err := f.rooms.Shutdown(context.Background()); err != nil {
		t.Fatalf("a second shutdown is harmless: %v", err)
	}
}

func TestRoomsShutdownHonoursAnExpiredContext(t *testing.T) {
	f := newRoomsFixture(t, nil)
	f.rooms.CreateTable(game.CreateTableOptions{})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	// Returns at once (either the destroys already finished, or ctx.Err());
	// the destroys themselves carry on in the background.
	if err := f.rooms.Shutdown(ctx); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
	eventually(t, 2*time.Second, func() bool { return len(f.rooms.LiveTables()) == 0 }, "the background destroy to finish")
}

func TestRoomsStats(t *testing.T) {
	f := newRoomsFixture(t, nil)
	if s := f.rooms.Stats(); s != (game.Stats{}) {
		t.Fatalf("%+v", s)
	}
	busy := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	seatTwoAndDeal(t, f, busy, rmStart)
	f.singleTable(rmBoot, game.CategorySeen)
	f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true})
	if s := f.rooms.Stats(); s != (game.Stats{Tables: 3, Players: 3, ActiveHands: 1}) {
		t.Fatalf("%+v", s)
	}
	raw, _ := json.Marshal(f.rooms.Stats())
	if string(raw) != `{"tables":3,"players":3,"activeHands":1}` {
		t.Fatalf("json %s", raw)
	}
}

func TestRoomsListTablesFiltersPrivateAndCategory(t *testing.T) {
	f := newRoomsFixture(t, nil)
	seen := f.rooms.CreateTable(game.CreateTableOptions{Category: "seen"})
	blind := f.rooms.CreateTable(game.CreateTableOptions{Category: "blind"})
	private := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true, Category: "blind"})
	f.mustJoin(blind, f.player("P", rmStart))

	all := f.rooms.ListTables(game.ListOptions{})
	if len(all) != 2 || all[0].RoomID != seen.ID() || all[1].RoomID != blind.ID() {
		t.Fatalf("public tables in creation order: %+v", all)
	}
	if all[1].Players != 1 || all[1].MaxPlayers != 5 || all[1].Code != blind.Code() || all[1].State != game.TableWaiting || all[1].Pot != 0 {
		t.Fatalf("summary %+v", all[1])
	}
	onlyBlind := f.rooms.ListTables(game.ListOptions{Category: game.CategoryBlind})
	if len(onlyBlind) != 1 || onlyBlind[0].RoomID != blind.ID() {
		t.Fatalf("%+v", onlyBlind)
	}
	withPrivate := f.rooms.ListTables(game.ListOptions{IncludePrivate: true, Category: game.CategoryBlind})
	if len(withPrivate) != 2 || withPrivate[1].RoomID != private.ID() {
		t.Fatalf("%+v", withPrivate)
	}
	if live := f.rooms.LiveTables(); len(live) != 3 || live[2] != private {
		t.Fatal("LiveTables returns everything in creation order")
	}
}

func TestRoomsRoomCodesAreUniqueSixLettersAndUpperCase(t *testing.T) {
	f := newRoomsFixture(t, nil)
	seen := map[string]bool{}
	for i := 0; i < 300; i++ {
		code := f.rooms.CreateTable(game.CreateTableOptions{}).Code()
		if len(code) != 6 || strings.ToUpper(code) != code {
			t.Fatalf("code %q", code)
		}
		if seen[code] {
			t.Fatalf("duplicate code %q", code)
		}
		seen[code] = true
	}
	if !strings.Contains(f.logText(), `"msg":"table created"`) {
		t.Fatal("creation is logged")
	}
}

func TestRoomsCreateTableIsTimedAndAnnounced(t *testing.T) {
	var observed []time.Duration
	f := newRoomsFixture(t, func(_ *config.GameConfig, o *game.RoomManagerOptions) {
		o.Metrics = game.MetricsHooks{ObserveCreation: func(d time.Duration) { observed = append(observed, d) }}
	})
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 5000, Category: "blind"})
	if len(observed) != 1 {
		t.Fatalf("observed %v", observed)
	}
	if c := f.events.created; len(c) != 1 || c[0] != table.ID() {
		t.Fatalf("created %v", c)
	}
	log := f.logText()
	for _, want := range []string{`"msg":"table created"`, `"roomId":"` + table.ID() + `"`, `"code":"` + table.Code() + `"`, `"bootAmount":5000`, `"category":"blind"`, `"isPrivate":false`, `"maxPot":null`} {
		if !strings.Contains(log, want) {
			t.Fatalf("log lacks %s:\n%s", want, log)
		}
	}
	if len(f.rooms.LiveTables()) != 1 || f.rooms.GetTable(table.ID()) != table {
		t.Fatal("registered")
	}
}

// ------------------------------------------------------------- table hooks

func TestRoomsKickForInsufficientChipsLeavesAndReports(t *testing.T) {
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(table, f.player("Funded", rmStart))
	poor := f.player("Poor", rmBoot-1)
	// Join does not check chips (Node's join did not either); the Table's
	// sweep on maybeStart asks for the kick while it is still inside the
	// AddPlayer mutation — the Leave must complete regardless.
	f.mustJoin(table, poor)

	k := f.awaitKick(5 * time.Second)
	if k != (game.PlayerKicked{RoomID: table.ID(), UserID: poor.ID, Reason: game.KickReasonInsufficientChips, Message: game.KickMessageInsufficientChips}) {
		t.Fatalf("%+v", k)
	}
	if f.rooms.GetTableForPlayer(poor.ID) != nil {
		t.Fatal("the kicked player is off the index")
	}
	eventually(t, 2*time.Second, func() bool { return table.PlayerCount() == 1 }, "the seat to be vacated")
	if len(f.tables.kicks) != 1 {
		t.Fatal("the kick event was forwarded to the table listener too")
	}
}

func TestRoomsIdleKickAfterMissedTurns(t *testing.T) {
	f := newRoomsFixture(t, func(g *config.GameConfig, _ *game.RoomManagerOptions) { g.MaxMissedTurns = 1 })
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	seatTwoAndDeal(t, f, table, rmStart)
	idle := turnUser(t, table)

	f.clock.Advance(f.cfg.TurnTimeout)

	k := f.awaitKick(5 * time.Second)
	if k.UserID != idle || k.Reason != game.KickReasonIdle || k.RoomID != table.ID() || k.Message != "Left the table after 1 missed turns" {
		t.Fatalf("%+v", k)
	}
	if f.rooms.GetTableForPlayer(idle) != nil {
		t.Fatal("off the index")
	}
	eventually(t, 2*time.Second, func() bool { return table.PlayerCount() == 1 }, "the seat to be vacated")
	if f.rooms.GetTable(table.ID()) == nil {
		t.Fatal("the other player keeps the table")
	}
}

func TestRoomsKickIgnoresAPlayerWhoAlreadyLeft(t *testing.T) {
	// A kick for a player the index no longer has (they left, or were kicked
	// already) does nothing and reports nothing.
	f := newRoomsFixture(t, nil)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(table, f.player("Funded", rmStart))
	poor := f.player("Poor", rmBoot-1)
	f.mustJoin(table, poor)
	k := f.awaitKick(5 * time.Second)
	if k.UserID != poor.ID {
		t.Fatalf("%+v", k)
	}
	eventually(t, 2*time.Second, func() bool { return table.PlayerCount() == 1 }, "the seat to be vacated")
	// Re-seating triggers another sweep and another kick; a stale one for the
	// first cannot fire twice.
	f.mustJoin(table, poor)
	k2 := f.awaitKick(5 * time.Second)
	if k2.UserID != poor.ID {
		t.Fatalf("%+v", k2)
	}
	eventually(t, 2*time.Second, func() bool { return table.PlayerCount() == 1 }, "the seat to be vacated again")
	select {
	case extra := <-f.events.kickCh:
		t.Fatalf("unexpected extra kick %+v", extra)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestRoomsPersistErrorAndErrorAreLogged(t *testing.T) {
	refuse := errors.New("db down")
	f := newRoomsFixture(t, func(_ *config.GameConfig, o *game.RoomManagerOptions) {
		o.Ledger = nil // fall back to a MemoryLedger built from the hooks
		o.LedgerHooks = game.MemoryLedgerHooks{
			PersistChips: func(game.PersistChipsArgs) error { return refuse },
			Settle: func(game.HandRecord, []game.SettleEntry) (map[string]int64, error) {
				return nil, refuse
			},
		}
	})
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(table, f.player("A", rmStart))
	f.mustJoin(table, f.player("B", rmStart))
	f.clock.Advance(f.cfg.NextHandDelay)

	if table.HasHand() {
		t.Fatal("the boot was refused, so nothing was dealt")
	}
	pe := f.tables.persistErrorsCopy()
	if len(pe) == 0 || pe[0].Reason != game.LedgerReasonBoot {
		t.Fatalf("persist errors %+v", pe)
	}
	log := f.logText()
	if !strings.Contains(log, `"msg":"table write refused"`) || !strings.Contains(log, `"reason":"boot"`) || !strings.Contains(log, `"roomId":"`+table.ID()+`"`) {
		t.Fatalf("log:\n%s", log)
	}
}

func TestRoomsSettlementAbandonedIsLoggedAsTableError(t *testing.T) {
	refuse := errors.New("settle down")
	f := newRoomsFixture(t, func(_ *config.GameConfig, o *game.RoomManagerOptions) {
		o.Ledger = game.NewMemoryLedger(game.MemoryLedgerHooks{
			Settle: func(game.HandRecord, []game.SettleEntry) (map[string]int64, error) { return nil, refuse },
		})
	})
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	a, b := seatTwoAndDeal(t, f, table, rmStart)
	if _, err := table.Act(turnUser(t, table), game.ActionPack, game.ActRequest{}); err != nil {
		t.Fatal(err)
	}
	if table.HasHand() {
		t.Fatal("the hand ended")
	}
	// One player leaves so no further hand is dealt while the clock runs.
	f.mustLeave(b.ID, game.LeaveReasonLeft)
	if f.rooms.GetTableForPlayer(a.ID) != table {
		t.Fatal("the other stays")
	}
	// Retries back off min(30 s, 4 s × n) for attempts 1..10 (202 s in all);
	// a generous advance drains them and the eleventh gives up.
	f.clock.Advance(10 * time.Minute)
	errs := f.tables.errorsCopy()
	if len(errs) != 1 || !strings.Contains(errs[0].Error(), "failed after 10 attempts") {
		t.Fatalf("errors %v", errs)
	}
	log := f.logText()
	if !strings.Contains(log, `"msg":"table error"`) || !strings.Contains(log, "failed after 10 attempts") || !strings.Contains(log, `"roomId":"`+table.ID()+`"`) {
		t.Fatalf("log:\n%s", log)
	}
	pe := f.tables.persistErrorsCopy()
	if len(pe) != 11 || pe[0].Reason != "settle" || pe[10].Reason != "settle_retry" || pe[10].Attempt != 10 {
		t.Fatalf("one settle failure plus ten retries: %d %+v", len(pe), pe)
	}
	if !strings.Contains(log, `"reason":"settle_retry"`) {
		t.Fatal("retries are logged as write refusals")
	}
}

// ------------------------------------------------------------- concurrency

func TestRoomsConcurrentQuickJoinsNeverDoubleSeatOrOverfill(t *testing.T) {
	f := newRoomsFixture(t, nil)
	const players = 50
	var wg sync.WaitGroup
	errs := make(chan error, players)
	seatedAt := make([]*game.Table, players)
	for i := 0; i < players; i++ {
		p := game.Player{ID: fmt.Sprintf("rush-%02d", i), DisplayName: "Rush", Chips: rmStart}
		wg.Add(1)
		go func(i int, p game.Player) {
			defer wg.Done()
			table, err := f.rooms.QuickJoin(p, game.QuickJoinOptions{BootAmount: 200, Category: "blind"})
			if err != nil {
				errs <- fmt.Errorf("%s: %w", p.ID, err)
				return
			}
			seatedAt[i] = table
		}(i, p)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
	if t.Failed() {
		t.FailNow()
	}

	total := 0
	for _, table := range f.rooms.LiveTables() {
		n := table.PlayerCount()
		if n > f.cfg.MaxPlayers || n == 0 {
			t.Fatalf("table %s has %d players", table.ID(), n)
		}
		if len(seatedIDs(t, table)) != n {
			t.Fatal("seat count mismatch")
		}
		total += n
	}
	if total != players {
		t.Fatalf("%d seats for %d players", total, players)
	}
	if s := f.rooms.Stats(); s.Players != players {
		t.Fatalf("index holds %d", s.Players)
	}
	for i := 0; i < players; i++ {
		id := fmt.Sprintf("rush-%02d", i)
		table := f.rooms.GetTableForPlayer(id)
		if table == nil || table != seatedAt[i] {
			t.Fatalf("%s indexed at %v, seated at %v", id, table, seatedAt[i])
		}
		seat, err := table.FindSeat(id)
		if err != nil || seat == nil {
			t.Fatalf("%s has no seat at its table", id)
		}
	}

	// And everybody leaving at once empties the room cleanly.
	for i := 0; i < players; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if _, err := f.rooms.Leave(fmt.Sprintf("rush-%02d", i), game.LeaveReasonLeft); err != nil {
				t.Error(err)
			}
		}(i)
	}
	wg.Wait()
	if s := f.rooms.Stats(); s != (game.Stats{}) {
		t.Fatalf("after everyone left: %+v (tables %v)", s, tableIDs(f.rooms.LiveTables()))
	}
}

func TestRoomsConcurrentJoinsOfOneAccountSeatItOnce(t *testing.T) {
	f := newRoomsFixture(t, nil)
	p := game.Player{ID: "twin", DisplayName: "Twin", Chips: rmStart}
	const attempts = 50
	var wg sync.WaitGroup
	results := make(chan error, attempts)
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			var err error
			switch i % 3 {
			case 0:
				_, err = f.rooms.QuickJoin(p, game.QuickJoinOptions{BootAmount: 200, Category: "seen"})
			case 1:
				_, err = f.rooms.QuickJoin(p, game.QuickJoinOptions{BootAmount: 200, Category: "blind"})
			default:
				table := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true})
				if err = f.rooms.Join(table, p, ""); err != nil {
					_ = f.rooms.DestroyTable(table.ID())
				}
			}
			results <- err
		}(i)
	}
	wg.Wait()
	close(results)
	ok := 0
	for err := range results {
		if err == nil {
			ok++
			continue
		}
		expectCode(t, err, game.CodeAlreadyInRoom)
	}
	if ok != 1 {
		t.Fatalf("%d joins succeeded, want exactly 1", ok)
	}
	seats := 0
	for _, table := range f.rooms.LiveTables() {
		if seat, _ := table.FindSeat(p.ID); seat != nil {
			seats++
		}
	}
	if seats != 1 || f.rooms.Stats().Players != 1 {
		t.Fatalf("seated %d times, index %d", seats, f.rooms.Stats().Players)
	}
}

func TestRoomsKickedPlayersLeaveWhileTablesAreBusy(t *testing.T) {
	// Kicks are raised on the actor mid-mutation and handled off it; with
	// several tables churning at once every kick must still complete.
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		g.NextHandDelay = time.Hour
	})
	const tables = 8
	var wg sync.WaitGroup
	for i := 0; i < tables; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			// A distinct stake per table keeps consolidation out of the way.
			table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot + int64(i), Category: "blind"})
			// One funded player first, so the kick never empties the table
			// (an emptied table is destroyed, as in Node). The poor player
			// sits while the table is still waiting: the sweep on their own
			// AddPlayer asks for the kick, and the remaining funded joins race
			// the removal.
			if err := f.rooms.Join(table, game.Player{ID: fmt.Sprintf("ok-%d-0", i), DisplayName: "OK", Chips: rmStart}, ""); err != nil {
				t.Error(err)
			}
			if err := f.rooms.Join(table, game.Player{ID: fmt.Sprintf("poor-%d", i), DisplayName: "Poor", Chips: 1}, ""); err != nil {
				t.Error(err)
			}
			for j := 1; j < 3; j++ {
				if err := f.rooms.Join(table, game.Player{ID: fmt.Sprintf("ok-%d-%d", i, j), DisplayName: "OK", Chips: rmStart}, ""); err != nil {
					t.Error(err)
				}
			}
		}(i)
	}
	wg.Wait()
	kicked := map[string]bool{}
	for i := 0; i < tables; i++ {
		k := f.awaitKick(5 * time.Second)
		kicked[k.UserID] = true
	}
	if len(kicked) != tables {
		t.Fatalf("kicked %v", kicked)
	}
	for i := 0; i < tables; i++ {
		id := fmt.Sprintf("poor-%d", i)
		if !kicked[id] || f.rooms.GetTableForPlayer(id) != nil {
			t.Fatalf("%s still seated", id)
		}
	}
	eventually(t, 2*time.Second, func() bool {
		for _, table := range f.rooms.LiveTables() {
			if table.PlayerCount() != 3 {
				return false
			}
		}
		return len(f.rooms.LiveTables()) == tables
	}, "every poor seat to be vacated")
}

func TestRoomsConcurrentLeaveAndConsolidationNeverStrandASeat(t *testing.T) {
	// Lone players leaving while sweeps try to merge them: whoever wins, the
	// player either is gone or is indexed exactly where they sit.
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		g.NextHandDelay = time.Hour
	})
	for round := 0; round < 10; round++ {
		var ids []string
		for i := 0; i < 6; i++ {
			table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
			p := game.Player{ID: fmt.Sprintf("lone-%d-%d", round, i), DisplayName: "Lone", Chips: rmStart}
			f.mustJoin(table, p)
			ids = append(ids, p.ID)
		}
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := f.rooms.ConsolidateTables(); err != nil {
				t.Error(err)
			}
		}()
		for _, id := range ids[:3] {
			wg.Add(1)
			go func(id string) {
				defer wg.Done()
				if _, err := f.rooms.Leave(id, game.LeaveReasonLeft); err != nil {
					t.Error(err)
				}
			}(id)
		}
		wg.Wait()
		for _, id := range ids[:3] {
			if f.rooms.GetTableForPlayer(id) != nil {
				t.Fatalf("%s left but is still indexed", id)
			}
			for _, table := range f.rooms.LiveTables() {
				if seat, _ := table.FindSeat(id); seat != nil {
					t.Fatalf("%s left but still has a seat at %s", id, table.ID())
				}
			}
		}
		for _, id := range ids[3:] {
			table := f.rooms.GetTableForPlayer(id)
			if table == nil {
				t.Fatalf("%s never left but is unseated", id)
			}
			if seat, _ := table.FindSeat(id); seat == nil {
				t.Fatalf("%s indexed at %s without a seat", id, table.ID())
			}
		}
		for _, id := range ids[3:] {
			f.mustLeave(id, game.LeaveReasonLeft)
		}
		if s := f.rooms.Stats(); s != (game.Stats{}) {
			t.Fatalf("round %d: %+v", round, s)
		}
	}
}
