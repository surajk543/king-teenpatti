package game_test

import (
	"sync"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Player stats v2 (owner, 27 Sep 2026): the RoomManager hands its
// StatsRecorder to every room it opens — the Teen Patti tables it builds
// itself and the poker rooms its factory builds — so a departure and a hand
// end are counted in the table's bucket wherever they happen.
func TestTheManagerHandsItsStatsRecorderToEveryRoomItOpens(t *testing.T) {
	var mu sync.Mutex
	var got []game.HandStats
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		o.Stats = func(stats []game.HandStats) {
			mu.Lock()
			defer mu.Unlock()
			got = append(got, stats...)
		}
	})
	counted := func() map[string]game.HandStats {
		mu.Lock()
		defer mu.Unlock()
		out := map[string]game.HandStats{}
		for _, s := range got {
			out[s.UserID+"/"+string(s.Bucket)] = s
		}
		return out
	}

	for _, c := range []struct {
		category string
		bucket   game.StatsBucket
	}{{"blind", game.StatsTeenPatti}, {"texas_holdem", game.StatsPoker}} {
		room := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: c.category})
		leaver, stayer := f.player("Leaver", rmStart), f.player("Stayer", rmStart)
		f.mustJoin(room, leaver)
		f.mustJoin(room, stayer)
		f.clock.Advance(f.cfg.NextHandDelay)
		if !room.HasHand() {
			t.Fatalf("%s: no hand dealt", c.category)
		}
		f.mustLeave(leaver.ID, game.LeaveReasonLeft)
		if err := room.Settled(); err != nil {
			t.Fatal(err)
		}
		all := counted()
		if s, ok := all[leaver.ID+"/"+string(c.bucket)]; !ok || s.Left != 1 || s.Lost != 0 || s.HasHeld {
			t.Errorf("%s: the leaver counted %+v (%v)", c.category, s, ok)
		}
		s, ok := all[stayer.ID+"/"+string(c.bucket)]
		if !ok || s.Won != 1 {
			t.Errorf("%s: the last player standing counted %+v (%v)", c.category, s, ok)
		}
		if want := c.bucket.CountsHeld(); s.HasHeld != want {
			t.Errorf("%s: the winner's hand held counted %v, want %v", c.category, s.HasHeld, want)
		}
	}
}
