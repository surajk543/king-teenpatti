package stats

import (
	"reflect"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// The pending hash's fields are the contract between the tables' counters and
// the flush: the column each counter is added to, by bucket, and a variation's
// played and won.
func TestAHandsFieldsNameTheColumnsTheyAreAddedTo(t *testing.T) {
	d := Fields(game.HandStats{UserID: "u", Bucket: game.StatsVariation, Played: 1, Won: 1, Winnings: 900,
		HasHeld: true, Held: game.Trail, Variation: game.VariationMuflis, VariationWon: true})
	wantAdd := map[string]int64{
		"VARIATION:hands_played": 1, "VARIATION:hands_won": 1, "VARIATION:total_winnings": 900, "VARIATION:trail": 1,
		"VARIATION:v:MUFLIS:played": 1, "VARIATION:v:MUFLIS:won": 1,
	}
	if d.UserID != "u" || !reflect.DeepEqual(d.Add, wantAdd) || !reflect.DeepEqual(d.Max, map[string]int64{"VARIATION:biggest_pot": 900}) {
		t.Fatalf("Fields = %+v", d)
	}
	// Only what moved: a loss at poker is one field.
	d = Fields(game.HandStats{UserID: "u", Bucket: game.StatsPoker, Lost: 1})
	if !reflect.DeepEqual(d.Add, map[string]int64{"POKER:hands_lost": 1}) || len(d.Max) != 0 {
		t.Fatalf("a poker loss = %+v", d)
	}
	for held, column := range map[game.HandCategory]string{game.Trail: "trail", game.PureSequence: "pure_sequence",
		game.Sequence: "sequence", game.Color: "color", game.Pair: "pair", game.HighCard: "high_card"} {
		d := Fields(game.HandStats{UserID: "u", Bucket: game.StatsTeenPatti, HasHeld: true, Held: held})
		if !reflect.DeepEqual(d.Add, map[string]int64{"TEEN_PATTI:" + column: 1}) {
			t.Errorf("%s held = %v", held, d.Add)
		}
	}
	// Nothing to write, nothing written.
	if got := Deltas([]game.HandStats{{UserID: "u", Bucket: game.StatsPoker}, {Bucket: game.StatsPoker, Won: 1}}); len(got) != 0 {
		t.Fatalf("empty hands made %+v", got)
	}
}

// Encode, fold in the live store's way, take, decode: exactly what the
// database is asked to add for the same hands stated directly.
func TestWhatIsTakenFromTheLiveStoreDecodesToWhatTheHandsAddUp(t *testing.T) {
	hands := []game.HandStats{
		{UserID: "a", Bucket: game.StatsTeenPatti, Played: 1, Won: 1, Winnings: 3000, HasHeld: true, Held: game.Trail},
		{UserID: "a", Bucket: game.StatsTeenPatti, Played: 1, Lost: 1, HasHeld: true, Held: game.Pair},
		{UserID: "a", Bucket: game.StatsTeenPatti, Left: 1},
		{UserID: "a", Bucket: game.StatsVariation, Played: 1, Won: 1, Winnings: 7000, HasHeld: true, Held: game.Color,
			Variation: game.VariationAK47, VariationWon: true},
		{UserID: "a", Bucket: game.StatsVariation, Lost: 1, HasHeld: true, Held: game.HighCard, Variation: game.VariationAK47},
		{UserID: "a", Bucket: game.StatsVariation, Lost: 1, HasHeld: true, Held: game.Sequence, Variation: game.Variation("NEW_ONE")},
		{UserID: "a", Bucket: game.StatsPoker, Played: 1, Won: 1, Winnings: 400},
		{UserID: "a", Bucket: game.StatsPoker, Played: 1, Won: 1, Winnings: 900},
		{UserID: "b", Bucket: game.StatsPoker, Lost: 1},
	}
	book := live.NewStatsBook()
	for _, h := range hands {
		book.Record(Deltas([]game.HandStats{h}))
	}
	batch, err := book.Take("b1", 10, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"a", "b"} {
		got, unknown := Decode(id, batch.Players[id])
		if unknown != 0 {
			t.Fatalf("%s: %d unknown fields", id, unknown)
		}
		want := db.NewStatsDelta(id)
		for _, h := range hands {
			if h.UserID == id {
				want.Add(h)
			}
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s decoded %+v, want %+v", id, got, want)
		}
	}
}

func TestAFieldThisBuildDoesNotKnowIsLeftOutAndCounted(t *testing.T) {
	got, unknown := Decode("u", map[string]int64{
		"TEEN_PATTI:hands_won": 2,
		"RUMMY:hands_won":      1, // a bucket this build does not have
		"POKER:jackpots":       1, // a column it does not have
		"nonsense":             1,
		"VARIATION:v:MUFLIS:x": 1, // neither played nor won
		"VARIATION:v:bad":      1,
	})
	if unknown != 5 {
		t.Fatalf("%d unknown fields, want 5", unknown)
	}
	if got.Buckets[game.StatsTeenPatti].HandsWon != 2 {
		t.Fatalf("the known field was lost: %+v", got.Buckets)
	}
	if _, ok := got.Buckets[game.StatsBucket("RUMMY")]; ok {
		t.Fatal("an unknown bucket reached the delta")
	}
	if _, ok := got.Buckets[game.StatsPoker]; ok {
		t.Fatal("an unknown column opened a row for its bucket")
	}
	if len(got.Variations) != 0 {
		t.Fatalf("an unknown variation field reached the delta: %+v", got.Variations)
	}
}
