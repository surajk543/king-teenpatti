package game

import "testing"

// The table picture is table state (owner, 15 Sep 2026): every viewer is sent
// the same one — the highest-ranking picture laid by any seated player,
// diamonds over hammers over coins and the dearer within a wallet, the lower
// seat winning a tie — a player laying or taking one off at the table changes
// what everyone sees, a player leaving takes theirs with them, and the seats'
// pictures survive a snapshot round trip.
func TestTheTableShowsTheDearestLaidPictureToEveryoneUntilItsOwnerLeaves(t *testing.T) {
	h := newHarness(t, tableConfig())
	seatWith := func(id string, pic *TablePicture) {
		t.Helper()
		if _, err := h.table.AddPlayer(NewPlayer{UserID: id, DisplayName: id, Chips: 100000, SocketID: "s-" + id, TablePicture: pic}); err != nil {
			t.Fatalf("seat %s: %v", id, err)
		}
	}
	shown := func(viewer string) *TablePicture {
		t.Helper()
		view, err := h.table.SerializeFor(viewer)
		if err != nil {
			t.Fatal(err)
		}
		return view.TablePicture
	}
	expect := func(when string, wantID int64, wantUser string) {
		t.Helper()
		for _, viewer := range []string{"a", "b", "c", "d"} {
			if seat, err := h.table.FindSeat(viewer); err != nil || seat == nil {
				continue
			}
			got := shown(viewer)
			switch {
			case wantID == 0 && got != nil:
				t.Fatalf("%s: %s sees %+v, want no table picture", when, viewer, got)
			case wantID != 0 && (got == nil || got.ID != wantID || got.UserID != wantUser):
				t.Fatalf("%s: %s sees %+v, want picture %d laid by %s", when, viewer, got, wantID, wantUser)
			}
		}
	}

	coin := &TablePicture{ID: 1, DayURL: "d1", NightURL: "n1", AssetFormat: "SVG", Currency: "COIN", Cost: 50000}
	hammer := &TablePicture{ID: 2, DayURL: "d2", NightURL: "n2", AssetFormat: "LOTTIE", Currency: "HAMMER", Cost: 10}
	diamond := &TablePicture{ID: 3, DayURL: "d3", NightURL: "n3", AssetFormat: "SVG", Currency: "DIAMOND", Cost: 5}

	seatWith("a", coin)
	seatWith("b", nil)
	expect("one picture laid", 1, "a")
	// A dearer chip price would not beat it: the wallet ranks first.
	seatWith("c", hammer)
	expect("hammers over 50,000 chips", 2, "c")
	seatWith("d", diamond)
	expect("diamonds over hammers", 3, "d")

	// b lays a dearer diamond picture while seated: the table follows at once.
	if err := h.table.SetTablePicture("b", &TablePicture{ID: 4, DayURL: "d4", NightURL: "n4", AssetFormat: "SVG", Currency: "DIAMOND", Cost: 9}); err != nil {
		t.Fatal(err)
	}
	expect("9 diamonds over 5", 4, "b")
	// The seat carries a copy tagged with its own player.
	if seat := h.seatInfo("b"); seat.TablePicture == nil || seat.TablePicture.UserID != "b" || seat.TablePicture.ID != 4 {
		t.Fatalf("b's seat carries %+v", seat.TablePicture)
	}
	// Taken off again: back to the next.
	if err := h.table.SetTablePicture("b", nil); err != nil {
		t.Fatal(err)
	}
	expect("b's taken off", 3, "d")

	// The owner leaving takes the picture with them.
	h.remove("d", "left")
	expect("d left", 2, "c")
	h.remove("c", "left")
	expect("c left", 1, "a")
	h.remove("a", "left")
	expect("everyone with a picture gone", 0, "")

	// A tie goes to the lower seat, so every viewer sees the same one.
	same := &TablePicture{ID: 7, DayURL: "d7", NightURL: "n7", AssetFormat: "SVG", Currency: "COIN", Cost: 50000}
	seatWith("c", same) // takes the lowest free seat, 0
	seatWith("d", same)
	if got := shown("b"); got == nil || got.UserID != "c" {
		t.Fatalf("a tie shows %+v, want c's (the lower seat)", got)
	}

	// The seats' pictures survive a snapshot: a table rebuilt from the live
	// store shows the same one.
	snap, err := h.table.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	restored, err := restoreTable(snap, TableOptions{Ledger: mirrorLedger(h), Clock: h.clock, Listener: h.rec})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = restored.Destroy() })
	view, err := restored.SerializeFor("b")
	if err != nil {
		t.Fatal(err)
	}
	if view.TablePicture == nil || view.TablePicture.ID != 7 || view.TablePicture.UserID != "c" {
		t.Fatalf("after a restore the table shows %+v, want c's picture 7", view.TablePicture)
	}
}

// The ranking on its own: wallet first, price second, and nothing outranks
// itself, so a tie keeps whoever was found first.
func TestTablePicturesRankByWalletThenPrice(t *testing.T) {
	pic := func(currency string, cost int64) *TablePicture { return &TablePicture{Currency: currency, Cost: cost} }
	cases := []struct {
		name string
		p, q *TablePicture
		want bool
	}{
		{"diamonds over hammers", pic("DIAMOND", 1), pic("HAMMER", 100), true},
		{"hammers over coins", pic("HAMMER", 1), pic("COIN", 100000000), true},
		{"coins under hammers", pic("COIN", 100000000), pic("HAMMER", 1), false},
		{"dearer within a wallet", pic("HAMMER", 30), pic("HAMMER", 10), true},
		{"cheaper within a wallet", pic("HAMMER", 10), pic("HAMMER", 30), false},
		{"a free picture is the cheapest coin one", pic("COIN", 0), pic("COIN", 1), false},
		{"equal is not better", pic("COIN", 5), pic("COIN", 5), false},
		{"anything over nothing", pic("COIN", 0), nil, true},
		{"nothing over nothing", nil, nil, false},
		{"an unknown wallet ranks with coins", pic("GEMS", 100), pic("HAMMER", 1), false},
	}
	for _, c := range cases {
		if got := c.p.outranks(c.q); got != c.want {
			t.Errorf("%s: outranks = %v, want %v", c.name, got, c.want)
		}
	}
}
