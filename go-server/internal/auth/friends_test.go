package auth

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// The friends routes' pure parts (friends.go): the win rate, the ids a path
// or a body carries, the list's order and the presence a friend is shown.

func TestTheWinRateIsRoundedToTwoPlacesZeroBeforeAHandAndNeverOverAHundred(t *testing.T) {
	for _, c := range []struct {
		won, played int64
		want        float64
	}{
		{0, 0, 0}, {5, 0, 0}, {0, 7, 0},
		{1, 3, 33.33}, {2, 3, 66.67}, {1, 2, 50}, {3, 3, 100}, {1, 8, 12.5}, {1, 7, 14.29},
		// A hand won without a voluntary bet counts as won, not as played.
		{4, 3, 100}, {1, 0, 0},
	} {
		if got := WinRate(c.won, c.played); got != c.want {
			t.Errorf("WinRate(%d, %d) = %v, want %v", c.won, c.played, got, c.want)
		}
	}
	raw, _ := json.Marshal(statsView(db.StatsSheet{TeenPatti: db.StatsLine{HandsPlayed: 3, HandsWon: 1}}))
	if !strings.Contains(string(raw), `"winRate":33.33`) {
		t.Fatalf("the stats on the wire: %s", raw)
	}
}

// A profile's stats (Player stats v2): the career's totals — every bucket
// summed — then each bucket in user.stats' shape WITHOUT a chip figure, the
// hands held on Teen Patti and Variation and the variations played on
// Variation, every list a list.
func TestAProfileShowsTheTotalsAndEachCategoryWithoutAChipFigure(t *testing.T) {
	sheet := db.StatsSheet{
		TeenPatti: db.StatsLine{HandsPlayed: 4, HandsWon: 2, HandsLost: 2, TotalWinnings: 9000, BiggestPot: 5000,
			Hands: db.HandTally{Trail: 1, Pair: 3}},
		Variation: db.StatsLine{HandsPlayed: 2, HandsWon: 1, HandsLost: 1, HandsLeft: 1, TotalWinnings: 700, BiggestPot: 700,
			Hands: db.HandTally{Sequence: 2}},
		Poker:      db.StatsLine{HandsPlayed: 1, HandsLost: 1},
		Variations: []db.VariationTally{{Variation: "MUFLIS", HandsPlayed: 2, HandsWon: 1}},
	}
	raw, err := json.Marshal(statsView(sheet))
	if err != nil {
		t.Fatal(err)
	}
	want := `{"handsPlayed":7,"handsWon":3,"handsLost":4,"handsLeft":1,"winRate":42.86,"categories":{` +
		`"teenPatti":{"handsPlayed":4,"handsWon":2,"handsLost":2,"handsLeft":0,"winRate":50,` +
		`"hands":{"trail":1,"pureSequence":0,"sequence":0,"color":0,"pair":3,"highCard":0}},` +
		`"variation":{"handsPlayed":2,"handsWon":1,"handsLost":1,"handsLeft":1,"winRate":50,` +
		`"hands":{"trail":0,"pureSequence":0,"sequence":2,"color":0,"pair":0,"highCard":0},` +
		`"variations":[{"variation":"MUFLIS","handsPlayed":2,"handsWon":1}]},` +
		`"poker":{"handsPlayed":1,"handsWon":0,"handsLost":1,"handsLeft":0,"winRate":0}}}`
	if string(raw) != want {
		t.Fatalf("the profile's stats\n got %s\nwant %s", raw, want)
	}
	for _, chips := range []string{"totalWinnings", "biggestPot"} {
		if strings.Contains(string(raw), chips) {
			t.Fatalf("a profile carries %s: %s", chips, raw)
		}
	}
	// No statistics at all: zeros, and the list is a list.
	empty, _ := json.Marshal(statsView(db.StatsSheet{}))
	if !strings.Contains(string(empty), `"variations":[]`) {
		t.Fatalf("an empty profile's stats: %s", empty)
	}
}

func TestAPlayerIDIsTrimmedLowerCasedAndBounded(t *testing.T) {
	for raw, want := range map[string]string{
		"ABC-def":               "abc-def",
		"  \t7C2F1A2E-9B3D \n":  "7c2f1a2e-9b3d",
		" x　":                   "x",
		strings.Repeat("a", 64): strings.Repeat("a", 64),
	} {
		if got, ok := playerIDFrom(raw); !ok || got != want {
			t.Errorf("playerIDFrom(%q) = %q %v, want %q", raw, got, ok, want)
		}
	}
	for _, bad := range []string{"", "   ", "\t\n", strings.Repeat("a", 65)} {
		if got, ok := playerIDFrom(bad); ok {
			t.Errorf("playerIDFrom(%q) = %q, want refused", bad, got)
		}
	}
}

func TestARequestIDIsAPlainPositiveInteger(t *testing.T) {
	for raw, want := range map[string]int64{"1": 1, "42": 42, "9223372036854775807": 1<<63 - 1} {
		if got, ok := requestIDFrom(raw); !ok || got != want {
			t.Errorf("requestIDFrom(%q) = %d %v", raw, got, ok)
		}
	}
	for _, bad := range []string{"", "0", "01", "-1", "+1", "1.5", "1e3", "abc", " 1", "9223372036854775808"} {
		if got, ok := requestIDFrom(bad); ok {
			t.Errorf("requestIDFrom(%q) = %d, want refused", bad, got)
		}
	}
}

func TestFriendsArePlayingThenOnlineThenOfflineEachByNameWhateverItsCase(t *testing.T) {
	item := func(id, name string, p live.Presence) FriendItem {
		return friendItem(db.Friend{Player: db.FriendPlayer{UserID: id, DisplayName: name}}, p)
	}
	playing := live.Presence{Playing: true, Game: "POKER", Variant: "OMAHA"}
	online := live.Presence{Online: true}
	items := []FriendItem{
		item("1", "zed", live.Presence{}),
		item("2", "Amy", online),
		item("3", "bob", playing),
		item("4", "Yan", playing),
		item("5", "amy", online),
		item("6", "Cleo", live.Presence{}),
		item("7", "Ann", live.Presence{Playing: true, Online: true, Game: "TEEN_PATTI", Variant: "SEEN"}),
	}
	sortFriends(items)
	var got []string
	for _, it := range items {
		got = append(got, it.Status+":"+it.DisplayName)
	}
	want := "PLAYING:Ann PLAYING:bob PLAYING:Yan ONLINE:Amy ONLINE:amy OFFLINE:Cleo OFFLINE:zed"
	if strings.Join(got, " ") != want {
		t.Fatalf("order:\n got %s\nwant %s", strings.Join(got, " "), want)
	}
}

// A seated player with no socket — the reconnect grace — is PLAYING and
// online; the game and variant ride only with PLAYING.
func TestThePresenceAFriendIsShown(t *testing.T) {
	for _, c := range []struct {
		in   live.Presence
		want string
	}{
		{live.Presence{}, `{"status":"OFFLINE","online":false,"playing":false}`},
		{live.Presence{Online: true}, `{"status":"ONLINE","online":true,"playing":false}`},
		{live.Presence{Playing: true, Game: "TEEN_PATTI", Variant: "VARIATION"}, `{"status":"PLAYING","online":true,"playing":true,"game":"TEEN_PATTI","variant":"VARIATION"}`},
		{live.Presence{Online: true, Playing: true, Game: "POKER", Variant: "FIVE_CARD_DRAW", UpdatedAt: 5}, `{"status":"PLAYING","online":true,"playing":true,"game":"POKER","variant":"FIVE_CARD_DRAW"}`},
		// A stray game with no record says nothing.
		{live.Presence{Online: true, Game: "POKER"}, `{"status":"ONLINE","online":true,"playing":false}`},
	} {
		raw, _ := json.Marshal(presenceView(c.in))
		if string(raw) != c.want {
			t.Errorf("%+v → %s, want %s", c.in, raw, c.want)
		}
	}
}
