package game_test

// The card backs through the RoomManager (owner, 3 Oct 2026; the table's
// side is cardbackground_test.go): a switch and a consolidation move take a
// player's card back to their new table, SetPlayerCardBackground puts a
// newly chosen one — or none — on a Teen Patti seat for everyone and does
// nothing at a poker room or in the lobby, and a restart through the live
// store brings every card back home, one no client could draw dropped and
// its table restored all the same.

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
)

// roomCardsAt is where the owner's card backs are (the seed's locations).
const roomCardsAt = "https://a91cb23b3b93a35dd9ea50db7b855e18.r2.cloudflarestorage.com/king-teenpatti/cards/"

func demonHell() *game.CardBackground {
	return &game.CardBackground{ID: 2, URL: roomCardsAt + "Demon%20Hell.jpg", Format: game.CardBackgroundFormat,
		Crop: &game.CardCrop{X: 0.2203, Y: 0.1167, W: 0.5594, H: 0.7831}}
}

func royalTiger() *game.CardBackground {
	return &game.CardBackground{ID: 7, URL: roomCardsAt + "Royal%20Tiger.jpg", Format: game.CardBackgroundFormat,
		Crop: &game.CardCrop{X: 0.2291, Y: 0.1262, W: 0.5417, H: 0.7584}}
}

// backAt is the card back viewer's snapshot of a Teen Patti room shows on
// userID's seat, or nil when that seat carries none.
func backAt(t *testing.T, room game.Room, viewer, userID string) *game.CardBackground {
	t.Helper()
	for _, s := range viewOf(t, room, viewer).Seats {
		if s.UserID == userID {
			return s.CardBackground
		}
	}
	t.Fatalf("%s is not seated at %s", userID, room.ID())
	return nil
}

// A switch re-seats the player from their account, which carries the card
// back they have chosen: it is on their seat at the new table, for everyone
// there, the moment they arrive.
func TestASwitchTakesThePlayersCardBackToTheirNewTable(t *testing.T) {
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		g.NextHandDelay = time.Hour // keep every table idle so seats stay put
	})
	home := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	mover := f.player("Mover", rmStart)
	mover.CardBackground = demonHell()
	f.mustJoin(home, mover)
	stay := f.player("Stay", rmStart)
	f.mustJoin(home, stay)
	other := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	there := f.player("There", rmStart)
	f.mustJoin(other, there)
	if got := backAt(t, home, stay.ID, mover.ID); !reflect.DeepEqual(got, demonHell()) {
		t.Fatalf("before the switch Stay sees %+v on Mover's seat", got)
	}

	result, err := f.rooms.SwitchTable(mover)
	if err != nil {
		t.Fatal(err)
	}
	if result.To.ID() != other.ID() {
		t.Fatalf("moved to %s, want %s", result.To.ID(), other.ID())
	}
	for _, viewer := range []string{there.ID, mover.ID} {
		if got := backAt(t, other, viewer, mover.ID); !reflect.DeepEqual(got, demonHell()) {
			t.Errorf("at the new table %s sees %+v on Mover's seat, want the Demon Hell", viewer, got)
		}
	}
	if got := backAt(t, other, mover.ID, there.ID); got != nil {
		t.Errorf("There chose no card back, yet the seat shows %+v", got)
	}
	if seat, err := home.FindSeat(mover.ID); err != nil || seat != nil {
		t.Fatalf("Mover is still at the old table: %+v %v", seat, err)
	}
}

// A consolidation move is not a sit-down that reads the account: the seat's
// own card back moves with its player, as its chips, level and picture do.
func TestAConsolidationMoveTakesThePlayersCardBackAlong(t *testing.T) {
	f := newRoomsFixture(t, nil)
	older := f.singleTable(rmBoot, game.CategoryBlind)
	solo := seatedIDs(t, older)[0]
	f.clock.Advance(time.Second)
	newer := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	mover := f.player("Mover", rmStart)
	mover.CardBackground = royalTiger()
	f.mustJoin(newer, mover)

	moves := f.mustConsolidate()
	if len(moves) != 1 || moves[0].UserID != mover.ID || moves[0].ToRoomID != older.ID() {
		t.Fatalf("moves %+v, want Mover onto the older table %s", moves, older.ID())
	}
	seat, err := older.FindSeat(mover.ID)
	if err != nil || seat == nil {
		t.Fatalf("Mover's seat at the older table: %+v %v", seat, err)
	}
	if !reflect.DeepEqual(seat.CardBackground, royalTiger()) {
		t.Fatalf("the moved seat carries %+v, want the Royal Tiger", seat.CardBackground)
	}
	for _, viewer := range []string{solo, mover.ID} {
		if got := backAt(t, older, viewer, mover.ID); !reflect.DeepEqual(got, royalTiger()) {
			t.Errorf("%s sees %+v on Mover's seat after the move", viewer, got)
		}
	}
	if got := backAt(t, older, mover.ID, solo); got != nil {
		t.Errorf("Solo chose no card back, yet the seat shows %+v", got)
	}
}

// The card-back endpoints' door onto a seat: at a Teen Patti table the new
// back (or none) reaches everyone at once, mid-hand too; for a player in the
// lobby there is nothing to change.
func TestSetPlayerCardBackgroundChangesTheSeatForEveryoneAtTheTable(t *testing.T) {
	f := newRoomsFixture(t, nil)
	a, b := f.player("A", rmStart), f.player("B", rmStart)
	table := f.mustQuickJoin(a, rmBoot, "blind")
	if f.mustQuickJoin(b, rmBoot, "blind").ID() != table.ID() {
		t.Fatal("A and B must share a table")
	}
	f.clock.Advance(f.cfg.NextHandDelay)
	if !table.HasHand() {
		t.Fatal("no hand was dealt")
	}

	f.rooms.SetPlayerCardBackground(a.ID, royalTiger())
	for _, viewer := range []string{a.ID, b.ID} {
		if got := backAt(t, table, viewer, a.ID); !reflect.DeepEqual(got, royalTiger()) {
			t.Errorf("%s sees %+v on A's seat, want the Royal Tiger", viewer, got)
		}
		if got := backAt(t, table, viewer, b.ID); got != nil {
			t.Errorf("%s sees %+v on B's seat, want none", viewer, got)
		}
	}
	if !table.HasHand() {
		t.Fatal("choosing a card back ended the hand")
	}

	f.rooms.SetPlayerCardBackground(a.ID, nil)
	for _, viewer := range []string{a.ID, b.ID} {
		if got := backAt(t, table, viewer, a.ID); got != nil {
			t.Errorf("A took the card back off, yet %s sees %+v", viewer, got)
		}
	}

	// In the lobby: no seat, nothing to do, nothing goes wrong.
	lobby := f.player("Lobby", rmStart)
	f.rooms.SetPlayerCardBackground(lobby.ID, royalTiger())
	if f.rooms.GetTableForPlayer(lobby.ID) != nil {
		t.Fatal("choosing a card back seated a player")
	}
}

// A poker felt keeps the default back: a poker room's snapshot carries no
// card back — not the one a player sat down with, not one chosen at the
// table — and SetPlayerCardBackground does nothing there.
func TestSetPlayerCardBackgroundDoesNothingAtAPokerRoom(t *testing.T) {
	f := newRoomsFixture(t, nil)
	room := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 50_000, Category: "texas_holdem"})
	if game.AsTable(room) != nil {
		t.Fatal("a Texas Hold'em room must be a poker room")
	}
	p := f.player("P", 1_000_000)
	p.CardBackground = demonHell()
	f.mustJoin(room, p)
	q := f.player("Q", 1_000_000)
	f.mustJoin(room, q)

	f.rooms.SetPlayerCardBackground(p.ID, royalTiger())
	f.rooms.SetPlayerCardBackground(q.ID, royalTiger())

	for _, viewer := range []string{p.ID, q.ID} {
		view, err := room.ViewFor(viewer)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := json.Marshal(view)
		if err != nil {
			t.Fatal(err)
		}
		for _, word := range []string{"cardBackground", "/cards/"} {
			if strings.Contains(string(raw), word) {
				t.Fatalf("%s's poker snapshot carries %s: %s", viewer, word, raw)
			}
		}
	}
	for _, id := range []string{p.ID, q.ID} {
		if seat, err := room.FindSeat(id); err != nil || seat == nil || seat.CardBackground != nil {
			t.Fatalf("%s's poker seat: %+v %v", id, seat, err)
		}
	}
}

// A restart through the live store brings each seat's card back home with
// its table. One the snapshot holds that no client could draw is dropped —
// that seat wears the default back — and the table, hand and all, is
// restored like the others.
func TestTheCardBacksComeBackWithTheirTablesAfterARestart(t *testing.T) {
	store := livetest.New()
	f1 := newRoomsFixture(t, withStore(store, "old"))
	a, b, c := f1.player("A", rmStart), f1.player("B", rmStart), f1.player("C", rmStart)
	a.CardBackground = demonHell()
	b.CardBackground = royalTiger()
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

	// B's card back is spoilt in the store: an http location, which no
	// phone may open.
	stored, ok := store.Stored(table.ID())
	if !ok {
		t.Fatal("the table is not in the store")
	}
	if got := strings.Count(string(stored.Snapshot), `"cardBackground":`); got != 2 {
		t.Fatalf("the stored snapshot names %d card backs, want A's and B's", got)
	}
	var snap game.Snapshot
	if err := json.Unmarshal(stored.Snapshot, &snap); err != nil {
		t.Fatal(err)
	}
	for _, s := range snap.Seats {
		if s != nil && s.UserID == b.ID {
			s.CardBackground.URL = "http://insecure.test/cards/Royal%20Tiger.jpg"
		}
	}
	spoilt, err := json.Marshal(&snap)
	if err != nil {
		t.Fatal(err)
	}
	store.Put(table.ID(), stored.Seq, spoilt)

	f2 := newRoomsFixture(t, withStore(store, "new"))
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch) + 3*time.Second)
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
		if got := backAt(t, restored, viewer, a.ID); !reflect.DeepEqual(got, demonHell()) {
			t.Errorf("after the restart %s sees %+v on A's seat, want the Demon Hell", viewer, got)
		}
		if got := backAt(t, restored, viewer, b.ID); got != nil {
			t.Errorf("after the restart %s sees B's spoilt card back: %+v", viewer, got)
		}
		if got := backAt(t, restored, viewer, c.ID); got != nil {
			t.Errorf("after the restart %s sees %+v on C's seat, want none", viewer, got)
		}
	}
}
