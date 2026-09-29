package game

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// Every player's level on their pod (owner, 29 Sep 2026: "In gametable In
// every player pod show their game level icon on top right of player pod"):
// SeatLevel on each seat of every viewer's snapshot, refreshed by the settle,
// carried by a move and kept across a restart.

var (
	risingStar = &SeatLevel{Level: 10, AssetURL: "https://drive.test/levels/10.json", AssetFormat: "LOTTIE"}
	proPlayer  = SeatLevel{Level: 11, AssetURL: "https://drive.test/levels/11.json", AssetFormat: "LOTTIE"}
)

// seatWithLevel seats id with chips and the given level, and funds its wallet.
func (h *harness) seatWithLevel(book *taxBook, id string, level *SeatLevel) {
	h.t.Helper()
	book.mu.Lock()
	book.wallets[id] = settleStart
	book.mu.Unlock()
	if _, err := h.table.AddPlayer(NewPlayer{UserID: id, DisplayName: strings.ToUpper(id), Chips: settleStart, SocketID: "s-" + id, TaxBps: 2000, Level: level}); err != nil {
		h.t.Fatalf("seat %s: %v", id, err)
	}
}

// seatsJSON is the seats of id's snapshot as the wire carries them.
func (h *harness) seatsJSON(id string) []map[string]any {
	h.t.Helper()
	raw, err := json.Marshal(h.view(id).Seats)
	if err != nil {
		h.t.Fatal(err)
	}
	var seats []map[string]any
	if err := json.Unmarshal(raw, &seats); err != nil {
		h.t.Fatal(err)
	}
	return seats
}

func seatOf(seats []map[string]any, userID string) map[string]any {
	for _, s := range seats {
		if s["userId"] == userID {
			return s
		}
	}
	return nil
}

func TestEveryViewerSeesEachPlayersLevelOnTheirPod(t *testing.T) {
	book := newTaxBook()
	h := newHarness(t, taxConfig(), withLedger(book.ledger))
	h.seatWithLevel(book, "a", risingStar)
	h.seatWithLevel(book, "b", nil)

	for _, viewer := range []string{"a", "b"} {
		seats := h.seatsJSON(viewer)
		a := seatOf(seats, "a")
		level, ok := a["level"].(map[string]any)
		if !ok {
			t.Fatalf("%s's snapshot: a's seat carries no level: %v", viewer, a)
		}
		if level["level"] != 10.0 || level["assetUrl"] != risingStar.AssetURL || level["assetFormat"] != "LOTTIE" {
			t.Errorf("%s's snapshot: a's level %v", viewer, level)
		}
		if _, has := seatOf(seats, "b")["level"]; has {
			t.Errorf("%s's snapshot: a seat whose level is not known has no level key", viewer)
		}
		for _, s := range seats {
			if s["status"] == string(SeatEmpty) {
				if _, has := s["level"]; has {
					t.Errorf("an empty seat is exactly {seatIndex, status}: %v", s)
				}
			}
		}
	}
	// Only the level: no XP, rate or badge of another player on the wire.
	raw, _ := json.Marshal(h.view("b").Seats)
	for _, word := range []string{`"xp"`, `"badges"`, `"taxBps"`} {
		if strings.Contains(string(raw), word) {
			t.Errorf("the seats carry %s: %s", word, raw)
		}
	}
	// SeatInfo carries it, so a consolidation move takes it along.
	eq(t, *h.seatInfo("a").Level, *risingStar, "SeatInfo.Level")
}

func TestALevelUpShowsOnThePodAtTheHandThatEarnedIt(t *testing.T) {
	book := newTaxBook()
	var levels map[string]SeatLevel
	ledger := func(h *harness) Ledger {
		base := book.ledger(h).(*MemoryLedger)
		base.Hooks.Levels = func(SettleRequest) map[string]SeatLevel { return levels }
		return base
	}
	h := newHarness(t, taxConfig(), withLedger(ledger))
	h.seatWithLevel(book, "a", risingStar)
	h.seatWithLevel(book, "b", risingStar)
	levels = map[string]SeatLevel{"a": proPlayer, "zed": proPlayer, "b": {Level: 0}}

	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	h.lastHandEnded()

	seats := h.seatsJSON("b")
	if got := seatOf(seats, "a")["level"].(map[string]any); got["level"] != 11.0 || got["assetUrl"] != proPlayer.AssetURL {
		t.Errorf("a levelled up in the settle: the pod shows %v", got)
	}
	if got := seatOf(seats, "b")["level"].(map[string]any); got["level"] != 10.0 {
		t.Errorf("a level no ledger could hold (0) leaves the seat's as it was: %v", got)
	}
}

func TestTheLevelsSurviveARestore(t *testing.T) {
	book := newTaxBook()
	h := newHarness(t, taxConfig(), withLedger(book.ledger))
	h.seatWithLevel(book, "a", risingStar)
	h.seatWithLevel(book, "b", nil)
	h.advance(6 * time.Second)

	snap := roundTrip(t, mustSnapshot(h))
	if raw := mustJSON(t, snap); strings.Count(raw, `"level":{"level":10`) != 1 {
		t.Fatalf("a's level must be in the snapshot, b's absent: %s", raw)
	}
	restored := restoreHarness(t, snap, newFakeClock(h.clock.Now()), withLedger(newTaxBook().ledger))
	if got := mustJSON(t, roundTrip(t, mustSnapshot(restored))); got != mustJSON(t, snap) {
		t.Fatalf("the restore must keep every level:\n got %s\nwant %s", got, mustJSON(t, snap))
	}
	a := seatOf(restored.seatsJSON("b"), "a")["level"].(map[string]any)
	if a["level"] != 10.0 || a["assetUrl"] != risingStar.AssetURL {
		t.Errorf("the restored pod: %v", a)
	}

	// A level no ladder holds is dropped, not a refused table.
	bad := roundTrip(t, snap)
	for i := range bad.Seats {
		if bad.Seats[i] != nil && bad.Seats[i].Level != nil {
			bad.Seats[i].Level.Level = 0
		}
	}
	table, err := restoreTable(bad, TableOptions{Clock: newFakeClock(clockStart)})
	if err != nil {
		t.Fatalf("a bad level must not refuse the table: %v", err)
	}
	defer func() { _ = table.Destroy() }()
	view, err := table.SerializeFor("b")
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(view.Seats)
	if strings.Contains(string(raw), `"level"`) {
		t.Errorf("the bad level is dropped: %s", raw)
	}
}
