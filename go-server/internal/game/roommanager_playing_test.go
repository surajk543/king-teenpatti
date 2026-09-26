package game_test

// The playing record (Friends V1, owner 26 Sep 2026): what a seated player's
// friends are shown they are playing. It rides the RoomManager's seat mirror
// into the live store — written at every seat, rewritten by every move, the
// restore and the reconciler's refresh, deleted wherever the seat is — and it
// names the family and the variant, never the table.

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// fixtureNow is a store clock that reads the fixture's fake clock once the
// fixture exists (the store is built first, to be handed to it) and the
// fixtures' epoch before.
func fixtureNow(f **roomsFixture) func() time.Time {
	return func() time.Time {
		if *f == nil {
			return rmEpoch
		}
		return (*f).clock.Now()
	}
}

// withPlayingStore attaches a recording store and a playing ttl.
func withPlayingStore(store *livetest.Store, ttl time.Duration) func(*config.GameConfig, *game.RoomManagerOptions) {
	return func(g *config.GameConfig, o *game.RoomManagerOptions) {
		withStore(store, "node-1")(g, o)
		o.PlayingTTL = ttl
	}
}

func TestPlayingAtNamesTheFamilyAndTheVariantOfEveryCategory(t *testing.T) {
	at := time.UnixMilli(1_790_000_000_123)
	for category, want := range map[game.Category][2]string{
		game.CategorySeen:      {"TEEN_PATTI", "SEEN"},
		game.CategoryBlind:     {"TEEN_PATTI", "BLIND"},
		game.CategoryVariation: {"TEEN_PATTI", "VARIATION"},
		"three_card_poker":     {"POKER", "THREE_CARD_POKER"},
		"five_card_draw":       {"POKER", "FIVE_CARD_DRAW"},
		"texas_holdem":         {"POKER", "TEXAS_HOLDEM"},
		"omaha":                {"POKER", "OMAHA"},
	} {
		got := game.PlayingAt(category, at)
		if got != (live.Playing{Game: want[0], Variant: want[1], UpdatedAt: 1_790_000_000_123}) {
			t.Errorf("PlayingAt(%s) = %+v, want %v", category, got, want)
		}
	}
}

func TestThePlayingTTLCoversThreeReconcilesAndNoReconcilerMeansNoExpiry(t *testing.T) {
	for reconcile, want := range map[time.Duration]time.Duration{
		0:                0,
		-time.Second:     0,
		time.Second:      game.MinPlayingTTL,
		30 * time.Second: 90 * time.Second, // LIVE_RECONCILE_MS's default
		time.Minute:      3 * time.Minute,
	} {
		if got := game.PlayingTTLFor(reconcile); got != want {
			t.Errorf("PlayingTTLFor(%v) = %v, want %v", reconcile, got, want)
		}
	}
}

func TestASeatWritesItsPlayingRecordAndALeaveTakesItAway(t *testing.T) {
	store := livetest.New()
	f := newRoomsFixture(t, withPlayingStore(store, 90*time.Second))

	a, b, c := f.player("A", rmStart), f.player("B", rmStart), f.player("C", rmStart)
	seen := f.mustQuickJoin(a, rmBoot, "seen")
	f.mustQuickJoin(b, rmBoot, "blind")
	private := f.createTable(game.CreateTableOptions{IsPrivate: true, Category: "variation"})
	f.mustJoin(private, c)

	playing := store.Playing()
	now := game.Millis(f.clock.Now())
	for who, want := range map[string]live.Playing{
		a.ID: {Game: "TEEN_PATTI", Variant: "SEEN", UpdatedAt: now},
		b.ID: {Game: "TEEN_PATTI", Variant: "BLIND", UpdatedAt: now},
		// A private table reports its category like any other.
		c.ID: {Game: "TEEN_PATTI", Variant: "VARIATION", UpdatedAt: now},
	} {
		entry, ok := playing[who]
		if !ok {
			t.Fatalf("%s has no playing record", who)
		}
		eq(t, entry.Record, want, "the playing record of "+who)
		eq(t, entry.TTL, 90*time.Second, "written for the configured ttl")
	}
	// Never the table: the record has no field that could carry it, and the
	// seat key beside it is the only thing that names the room.
	eq(t, store.Seats()[a.ID], seen.ID(), "the seat mirror names the room")

	f.mustLeave(a.ID, game.LeaveReasonLeft)
	if _, ok := store.Playing()[a.ID]; ok {
		t.Fatal("a player who left is still shown playing")
	}
	if _, ok := store.Playing()[b.ID]; !ok {
		t.Fatal("somebody else's leave took B's record")
	}

	// A kick is a departure like any other.
	d := f.player("D", rmBoot-1)
	short := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(short, d)
	f.awaitKick(2 * time.Second)
	eventually(t, 2*time.Second, func() bool { _, ok := store.Playing()[d.ID]; return !ok }, "the kicked player's record cleared")
}

func TestAPokerSeatIsPlayingPokerWithItsVariant(t *testing.T) {
	store := livetest.New()
	f := newRoomsFixture(t, withPlayingStore(store, 0))
	for _, category := range []string{"three_card_poker", "five_card_draw", "texas_holdem", "omaha"} {
		p := f.player("P", rmStart)
		room, err := f.rooms.QuickJoin(p, game.QuickJoinOptions{BootAmount: rmBoot, Category: category})
		if err != nil {
			t.Fatalf("join %s: %v", category, err)
		}
		eq(t, string(room.Category()), category, "a poker room opened")
		entry := store.Playing()[p.ID]
		eq(t, entry.Record.Game, "POKER", category+" is poker")
		eq(t, entry.Record.Variant, strings.ToUpper(category), "with its variant")
		eq(t, entry.TTL, time.Duration(0), "no reconciler: no expiry")
	}
}

func TestAMoveRewritesThePlayingRecord(t *testing.T) {
	store := livetest.New()
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		withPlayingStore(store, time.Minute)(g, o)
		g.NextHandDelay = time.Hour // keep the tables idle so the seats stay put
	})

	// A switch: off one table, onto another of the same kind.
	home := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	stay, mover := f.player("Stay", rmStart), f.player("Mover", rmStart)
	f.mustJoin(home, stay)
	f.mustJoin(home, mover)
	before := store.Playing()[mover.ID].Record
	f.clock.Advance(5 * time.Second)
	result, err := f.rooms.SwitchTable(mover)
	if err != nil {
		t.Fatal(err)
	}
	after := store.Playing()[mover.ID].Record
	eq(t, store.Seats()[mover.ID], result.To.ID(), "the seat follows the move")
	eq(t, after.Variant, "SEEN", "still seen")
	eq(t, after.UpdatedAt, before.UpdatedAt+5000, "rewritten at the move")
	calls := strings.Join(store.CallsOf("set_seated"), " ")
	if !strings.Contains(calls, "set_seated:"+mover.ID+":"+result.To.ID()) {
		t.Fatalf("no seat mirror written for the new table: %s", calls)
	}

	// A consolidation move: two lone players, one is moved onto the other's
	// table.
	f2store := livetest.New()
	f2 := newRoomsFixture(t, withPlayingStore(f2store, time.Minute))
	x := f2.singleTable(rmBoot, game.CategoryBlind)
	y := f2.singleTable(rmBoot, game.CategoryBlind)
	xPlayer, yPlayer := seatedIDs(t, x)[0], seatedIDs(t, y)[0]
	f2.clock.Advance(7 * time.Second)
	moves := f2.mustConsolidate()
	eq(t, len(moves), 1, "one player moved")
	moved := moves[0].UserID
	eq(t, moved == xPlayer || moved == yPlayer, true, "one of the two")
	eq(t, f2store.Seats()[moved], moves[0].ToRoomID, "the seat follows the move")
	eq(t, f2store.Playing()[moved].Record.UpdatedAt, game.Millis(f2.clock.Now()), "the record rewritten at the move")
	eq(t, f2store.Playing()[moved].Record.Variant, "BLIND", "still blind")
}

// The reconciler rewrites every seat, so a record written for three of its
// intervals never lapses while the seat is held; once nothing rewrites it
// (a process that died) it runs out on its own. With no reconciler at all
// the record is written with no expiry and never lapses under a seat.
func TestTheReconcilerRefreshesEveryPlayingRecordSoItNeverLapsesUnderASeat(t *testing.T) {
	var f *roomsFixture
	store := live.NewMemoryWithClock(fixtureNow(&f))
	ttl := game.PlayingTTLFor(30 * time.Second)
	f = newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		o.Live = store
		o.PlayingTTL = ttl
		g.NextHandDelay = time.Hour
	})
	ctx := context.Background()
	a := f.player("A", rmStart)
	f.mustQuickJoin(a, rmBoot, "variation")
	playingOf := func() live.Presence {
		t.Helper()
		got, err := store.Presence(ctx, []string{a.ID})
		if err != nil {
			t.Fatal(err)
		}
		return got[a.ID]
	}
	eq(t, playingOf().Variant, "VARIATION", "playing variation")

	// Four reconciles, 30 s apart: two minutes in, far past one ttl from the
	// seat, and still playing.
	for i := 0; i < 4; i++ {
		f.clock.Advance(30 * time.Second)
		if report := f.rooms.ReconcileLive(ctx); !report.Healthy || report.Seats != 1 {
			t.Fatalf("reconcile: %+v", report)
		}
	}
	eq(t, playingOf().Playing, true, "refreshed by every pass")

	// The process dies: nothing rewrites it, and it runs out by itself.
	f.clock.Advance(ttl + time.Second)
	eq(t, playingOf().Playing, false, "lapsed once nothing refreshed it")
	// The seat key itself stays for the stray sweep (it has no ttl).
	if room, err := store.SeatOf(ctx, a.ID); err != nil || room == "" {
		t.Fatalf("the seat key lapsed with the record: %q %v", room, err)
	}
	// A reconcile after the outage writes it back.
	f.rooms.ReconcileLive(ctx)
	eq(t, playingOf().Variant, "VARIATION", "refilled")

	// LIVE_RECONCILE_MS=0: no reconciler, no expiry — a day later, still
	// playing.
	var g *roomsFixture
	store2 := live.NewMemoryWithClock(fixtureNow(&g))
	g = newRoomsFixture(t, func(c *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(c, o)
		o.Live = store2
		o.PlayingTTL = game.PlayingTTLFor(0)
		c.NextHandDelay = time.Hour
	})
	b := g.player("B", rmStart)
	g.mustQuickJoin(b, rmBoot, "blind")
	g.clock.Advance(24 * time.Hour)
	got, err := store2.Presence(ctx, []string{b.ID})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, got[b.ID].Playing, true, "a record with no reconciler never lapses under its seat")
	eq(t, got[b.ID].Variant, "BLIND", "blind")
}

// A graceful restart hands the seats to the next process, and the restore
// writes every playing record again — even one that ran out while the
// process was being replaced.
func TestARestartRestoresThePlayingRecords(t *testing.T) {
	store := livetest.New()
	f1, ids, players := playingFixture(t, store)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := f1.rooms.Suspend(ctx); err != nil {
		t.Fatalf("suspend: %v", err)
	}
	for _, p := range players {
		if _, ok := store.Playing()[p.ID]; !ok {
			t.Fatalf("%s's record went at the suspend: the seat is still held for the next process", p.DisplayName)
		}
		store.DropPlaying(p.ID) // a slow restart: every record ran out
	}

	f2 := newRoomsFixture(t, withPlayingStore(store, 90*time.Second))
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch) + 3*time.Second)
	if _, err := f2.rooms.Restore(ctx); err != nil {
		t.Fatalf("restore: %v", err)
	}
	playing := store.Playing()
	for name, want := range map[string]string{"A": "BLIND", "B": "BLIND", "C": "SEEN", "E": "SEEN", "D": "SEEN"} {
		entry, ok := playing[players[name].ID]
		if !ok {
			t.Fatalf("%s's record was not restored", name)
		}
		eq(t, entry.Record.Game, "TEEN_PATTI", name+"'s family")
		eq(t, entry.Record.Variant, want, name+"'s variant")
		eq(t, entry.Record.UpdatedAt, game.Millis(f2.clock.Now()), name+"'s record stamped by the new process")
		eq(t, entry.TTL, 90*time.Second, "for the new process's ttl")
	}
	eq(t, len(ids), 5, "five tables restored")
}
