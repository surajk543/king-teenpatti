package game

// TablePicture is the table picture a seated player has laid (owner, 15 Sep
// 2026), as it rides on the seat and, for the one the table shows, on
// room:state as `tablePicture`. The two URLs are the catalogue's day and
// night files (db.LaidTablePicture); Currency and Cost are what decide whose
// picture the whole table sees when more than one player has laid one.
//
// It is TABLE state (owner: "that table background will be visible to the
// other players also"): every viewer of the table is sent the same one, and a
// player laying or taking off a picture changes what everyone at the table
// sees (Table.SetTablePicture), the way a worn avatar changes every viewer's
// seat pod. No money moves and nothing is written: the choice itself lives on
// the account (user_table_choice); the seat only carries a copy, snapshotted
// to the live store with the rest of the seat so a restored table keeps it.
type TablePicture struct {
	ID          int64  `json:"id"`
	DayURL      string `json:"dayUrl"`
	NightURL    string `json:"nightUrl"`
	AssetFormat string `json:"assetFormat"`
	// Currency is the wallet the picture was bought from — "DIAMOND",
	// "HAMMER" or "COIN" (a free picture is COIN at cost 0) — and Cost the
	// price paid. Together they rank the pictures laid at one table.
	Currency string `json:"currency"`
	Cost     int64  `json:"cost"`
	// UserID is the player who laid it: the seat's own, and on room:state
	// the one whose picture the table shows.
	UserID string `json:"userId"`
}

// clone copies a picture so a seat never shares one with its caller; nil
// stays nil.
func (p *TablePicture) clone() *TablePicture {
	if p == nil {
		return nil
	}
	c := *p
	return &c
}

// tablePictureRank orders the wallets a picture can be bought from, dearest
// kind first (owner, 15 Sep 2026: "priority to who has bought with diamonds,
// then hammers, then coins"). A currency this build does not know ranks with
// coins, as the shelves draw it.
func tablePictureRank(currency string) int {
	switch currency {
	case "DIAMOND":
		return 3
	case "HAMMER":
		return 2
	default:
		return 1
	}
}

// outranks reports whether p should be shown over q: a dearer wallet first,
// then the higher price within the wallet. Equal on both → false, so the
// caller keeps the earlier of two equals (the lower seat) and the answer is
// the same on every viewer's screen.
func (p *TablePicture) outranks(q *TablePicture) bool {
	if q == nil {
		return p != nil
	}
	if p == nil {
		return false
	}
	if a, b := tablePictureRank(p.Currency), tablePictureRank(q.Currency); a != b {
		return a > b
	}
	return p.Cost > q.Cost
}

// tablePicture is the picture the table shows: the highest-ranking one laid
// by any seated player, the lowest seat winning a tie, or nil when nobody has
// laid one. Read on the actor.
func (t *Table) tablePicture() *TablePicture {
	var best *TablePicture
	for _, s := range t.seats {
		if s == nil || s.tablePicture == nil {
			continue
		}
		if s.tablePicture.outranks(best) {
			best = s.tablePicture
		}
	}
	return best.clone()
}

// SetTablePicture puts the table picture a player has just laid on their seat
// (nil takes it off), and emits state so every viewer sees what the table now
// shows — which may be someone else's picture, if theirs is outranked. The
// state emit marks the snapshot dirty, so a restored table keeps it. No-op
// when the player is not seated.
func (t *Table) SetTablePicture(userID string, pic *TablePicture) error {
	pic = pic.clone()
	return t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			return
		}
		if pic != nil {
			pic.UserID = userID
		}
		s.tablePicture = pic
		t.listener.OnSeatUpdated(t.view, s.seatIndex)
		t.emitState()
	})
}
