package game_test

// A rented card back running out through the RoomManager (owner, 3 Oct 2026:
// "when validity of premium card expires, it restores default card"; the
// table's side is cardbackground_expiry_test.go): a back moved with its player
// — by a consolidation move or a switch — still comes off at its moment on the
// table it is at now, and across a restart through the live store each back
// keeps its term: one that ended while the process was down comes back as the
// default back, and one still running comes off on the new process's clock.

import (
	"context"
	"encoding/json"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
)

// rentedUntil is b rented until ends (epoch ms).
func rentedUntil(b *game.CardBackground, ends int64) *game.CardBackground {
	b.ExpiresAt = ends
	return b
}

func TestAMovedCardBackStillComesOffWhenItsRentalEnds(t *testing.T) {
	// A consolidation move carries the seat's own copy, term and all: it is
	// not a sit-down that reads the account.
	t.Run("a consolidation move", func(t *testing.T) {
		f := newRoomsFixture(t, nil)
		older := f.singleTable(rmBoot, game.CategoryBlind)
		solo := seatedIDs(t, older)[0]
		f.clock.Advance(time.Second)
		newer := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
		ends := f.clock.Now().Add(2 * time.Second).UnixMilli()
		mover := f.player("Mover", rmStart)
		mover.CardBackground = rentedUntil(royalTiger(), ends)
		f.mustJoin(newer, mover)

		moves := f.mustConsolidate()
		if len(moves) != 1 || moves[0].ToRoomID != older.ID() {
			t.Fatalf("moves %+v, want Mover onto the older table %s", moves, older.ID())
		}
		for _, viewer := range []string{solo, mover.ID} {
			if got := backAt(t, older, viewer, mover.ID); !reflect.DeepEqual(got, rentedUntil(royalTiger(), ends)) {
				t.Fatalf("after the move %s sees %+v on Mover's seat, want the Royal Tiger and its term", viewer, got)
			}
		}

		f.clock.Advance(2*time.Second - time.Millisecond)
		if backAt(t, older, solo, mover.ID) == nil {
			t.Fatal("the moved back came off before its moment")
		}
		f.clock.Advance(time.Millisecond)
		for _, viewer := range []string{solo, mover.ID} {
			if got := backAt(t, older, viewer, mover.ID); got != nil {
				t.Errorf("at its moment %s still sees %+v on Mover's seat at the table it moved to", viewer, got)
			}
		}
	})

	// A switch re-seats the player from their account, which carries the
	// term (db: the ownership row's expires_at).
	t.Run("a switch", func(t *testing.T) {
		f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
			openMenu(g, o)
			g.NextHandDelay = time.Hour // keep every table idle so seats stay put
		})
		home := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
		ends := f.clock.Now().Add(5 * time.Second).UnixMilli()
		mover := f.player("Mover", rmStart)
		mover.CardBackground = rentedUntil(demonHell(), ends)
		f.mustJoin(home, mover)
		f.mustJoin(home, f.player("Stay", rmStart))
		other := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
		there := f.player("There", rmStart)
		f.mustJoin(other, there)

		result, err := f.rooms.SwitchTable(mover)
		if err != nil {
			t.Fatal(err)
		}
		if result.To.ID() != other.ID() {
			t.Fatalf("moved to %s, want %s", result.To.ID(), other.ID())
		}
		if got := backAt(t, other, there.ID, mover.ID); !reflect.DeepEqual(got, rentedUntil(demonHell(), ends)) {
			t.Fatalf("at the new table There sees %+v on Mover's seat", got)
		}
		f.clock.Advance(5 * time.Second)
		for _, viewer := range []string{there.ID, mover.ID} {
			if got := backAt(t, other, viewer, mover.ID); got != nil {
				t.Errorf("at its moment %s still sees %+v on Mover's seat", viewer, got)
			}
		}
	})
}

// Across a restart each rented back keeps its term: the stored snapshot
// carries it, a back whose term ended while the process was down comes back
// as the default back, and one still running comes off at its moment on the
// new process's clock — mid-hand, the hand untouched.
func TestAfterARestartARentedCardBackStillComesOffOnTime(t *testing.T) {
	store := livetest.New()
	f1 := newRoomsFixture(t, withStore(store, "old"))
	a, b, c := f1.player("A", rmStart), f1.player("B", rmStart), f1.player("C", rmStart)
	soon := rmEpoch.Add(f1.cfg.NextHandDelay + 2*time.Second).UnixMilli()   // ends while the process is down
	later := rmEpoch.Add(f1.cfg.NextHandDelay + 10*time.Second).UnixMilli() // still running after the restart
	a.CardBackground = rentedUntil(demonHell(), later)
	b.CardBackground = rentedUntil(royalTiger(), soon)
	table := f1.mustQuickJoin(a, rmBoot, "blind")
	f1.mustQuickJoin(b, rmBoot, "blind")
	f1.mustQuickJoin(c, rmBoot, "blind")
	f1.clock.Advance(f1.cfg.NextHandDelay)
	if !table.HasHand() {
		t.Fatal("no hand was dealt")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := f1.rooms.Suspend(ctx); err != nil {
		t.Fatalf("suspend: %v", err)
	}
	stored, ok := store.Stored(table.ID())
	if !ok {
		t.Fatal("the table is not in the store")
	}
	for _, term := range []int64{soon, later} {
		if !strings.Contains(string(stored.Snapshot), `"expiresAt":`+strconv.FormatInt(term, 10)) {
			t.Fatalf("the stored snapshot lost the term %d: %s", term, stored.Snapshot)
		}
	}

	f2 := newRoomsFixture(t, withStore(store, "new"))
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch) + 3*time.Second) // B's term ends meanwhile
	report, err := f2.rooms.Restore(ctx)
	if err != nil {
		t.Fatalf("restore: %v", err)
	}
	if report.Tables != 1 || report.Failed+report.Dropped != 0 {
		t.Fatalf("restore report %+v, want the one table back", report)
	}
	restored := f2.rooms.GetTable(table.ID())
	if restored == nil || !restored.HasHand() {
		t.Fatalf("the table and its hand were not restored: %v", restored)
	}
	for _, viewer := range []string{a.ID, b.ID, c.ID} {
		if got := backAt(t, restored, viewer, a.ID); !reflect.DeepEqual(got, rentedUntil(demonHell(), later)) {
			t.Errorf("after the restart %s sees %+v on A's seat, want the Demon Hell and its term", viewer, got)
		}
		if got := backAt(t, restored, viewer, b.ID); got != nil {
			t.Errorf("after the restart %s sees B's back, whose term ended while the process was down: %+v", viewer, got)
		}
	}
	raw, err := json.Marshal(mustSnapshotOf(t, restored))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "Royal%20Tiger") {
		t.Fatalf("the restored table's snapshot keeps B's back: %s", raw)
	}

	left := time.Duration(later-f2.clock.Now().UnixMilli()) * time.Millisecond
	f2.clock.Advance(left - time.Millisecond)
	if backAt(t, restored, b.ID, a.ID) == nil {
		t.Fatal("A's back came off before its moment")
	}
	f2.clock.Advance(time.Millisecond)
	for _, viewer := range []string{a.ID, b.ID, c.ID} {
		if got := backAt(t, restored, viewer, a.ID); got != nil {
			t.Errorf("at its moment %s still sees %+v on A's seat", viewer, got)
		}
	}
	if !restored.HasHand() {
		t.Fatal("the back running out ended the hand")
	}
}
