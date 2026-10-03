package game

import (
	"math"
	"net/url"
	"time"
)

// CardBackground is the card back a seated player has chosen (owner, 3 Oct
// 2026: "Add a table cards_background which users can buy just like user can
// buy profile_pictures … add one more tab Cards in Store which user can
// buy"), as it rides on the seat and on every viewer's room:state as
// `seats[].cardBackground`. URL is the catalogue's location of the picture
// (cards_background.asset_url — a JPEG in the private R2 bucket, which a
// client opens through POST /api/assets/sign), Format its asset_format
// ("IMAGE": a raster is all a card back is drawn from) and Crop where the
// card is inside that picture.
//
// It is SEAT state, public like a worn picture (avatarUrl): everyone at the
// table sees each player's card back on that player's face-down cards, and
// the viewer's own on their own hand (decided with the owner, 3 Oct 2026). A
// player choosing one, or taking theirs off, changes what everyone sees at
// once (Table.SetCardBackground). No money moves and nothing is written: the
// choice itself lives on the account (user_cards_background_choice); the
// seat only carries a copy, snapshotted to the live store with the rest of
// the seat so a restored table keeps it.
//
// The default back — the owner's Royal Fox, bundled with the app — is no
// catalogue row: a seat whose player has chosen nothing carries none, and
// its cards wear the default. Teen Patti tables only: a poker felt keeps the
// default back, so a poker room's view carries none, as it carries no table
// picture (RoomManager.SetPlayerCardBackground).
//
// A rented card back runs out (owner, 3 Oct 2026: "when validity of premium
// card expires, it restores default card"), and the seat knows when:
// ExpiresAt rides with the copy, and the table takes it off every seat the
// moment it lapses — by itself, on its own clock (armCardBackgroundTimer),
// whether or not the player's app is open to ask for anything.
type CardBackground struct {
	ID     int64  `json:"id"`
	URL    string `json:"url"`
	Format string `json:"assetFormat"`
	// Crop is the card's rectangle inside the picture, or nil when the whole
	// picture is the card. The owner's art is product shots — the card on a
	// dark ground, at a different size and place in each — so every seeded
	// row carries one, measured by hand at the card's 5:7.
	Crop *CardCrop `json:"crop,omitempty"`
	// ExpiresAt is when the player's rental of this card back runs out (epoch
	// ms; user_cards_background.expires_at, read with the account), or 0 for
	// one that never does — a free back, or one bought for ever. ABSENT on the
	// wire when 0, so a back that never runs out is sent byte for byte as it
	// was. Public with the rest of the seat's back: it says only when this
	// back leaves the table, which everybody there will see anyway. A back
	// whose moment has come is the default back: no seat takes one that
	// arrives already run out (Table.seatCardBackground), and the table's
	// card-back clock takes one off when its moment comes.
	ExpiresAt int64 `json:"expiresAt,omitempty"`
}

// CardCrop is where the card is in its picture, as fractions of the
// picture: X and W of its width, Y and H of its height — the card's top-left
// corner and its size. A client draws that rectangle stretched to the card.
type CardCrop struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	W float64 `json:"w"`
	H float64 `json:"h"`
}

// CardBackgroundFormat is the one asset format a card back is drawn from, a
// raster picture (cards_background.asset_format's CHECK allows nothing
// else).
const CardBackgroundFormat = "IMAGE"

// clone copies b, its crop included, so a seat never shares one with its
// caller, a view, a SeatInfo or a snapshot; nil stays nil.
func (b *CardBackground) clone() *CardBackground {
	if b == nil {
		return nil
	}
	c := *b
	if b.Crop != nil {
		crop := *b.Crop
		c.Crop = &crop
	}
	return &c
}

// valid reports whether b is a card back a client can draw: an https URL
// with a host, the IMAGE format, and a crop — when it has one — that is a
// rectangle of positive size inside the picture, every figure finite (the
// rules of the cards_background CHECKs, which the catalogue rows a seat's
// card back comes from already obey). An expiry before the epoch is no
// moment a rental was ever bought for: a back carrying one is not valid
// either.
func (b *CardBackground) valid() bool {
	if b == nil || b.Format != CardBackgroundFormat || b.ExpiresAt < 0 {
		return false
	}
	u, err := url.Parse(b.URL)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return false
	}
	return b.Crop == nil || b.Crop.valid()
}

// expiredAt reports whether b is a rental that has run out by now: an
// ExpiresAt at or before this instant, to the millisecond — the account's own
// rule (db.userFromAt joins a rental while expires_at > now), so a seat lets
// go of a back at exactly the moment the account stops carrying it. A back
// with no expiry (0) never runs out; nil has nothing to run out.
func (b *CardBackground) expiredAt(now time.Time) bool {
	return b != nil && b.ExpiresAt > 0 && b.ExpiresAt <= Millis(now)
}

// valid reports whether c is a rectangle of positive size inside its
// picture: 0 <= X, 0 <= Y, 0 < W, 0 < H, X+W <= 1 and Y+H <= 1, every figure
// finite. A float64 adds exactly as PostgreSQL's double precision does, so
// a crop the database's CHECK accepted is accepted here too.
func (c *CardCrop) valid() bool {
	for _, v := range [...]float64{c.X, c.Y, c.W, c.H} {
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return false
		}
	}
	return c.X >= 0 && c.Y >= 0 && c.W > 0 && c.H > 0 && c.X+c.W <= 1 && c.Y+c.H <= 1
}

// forSeat is what a seat keeps of the card back it is given: a copy of a
// valid one, or nil — the default back — for anything a client could not
// draw. With the expiry test the table adds (Table.seatCardBackground) it is
// the ONE rule for every way a card back reaches a seat (a sit-down, a move,
// a change at the table, a restore), so what every viewer is sent is exactly
// what a restored table brings back, and a figure JSON cannot carry (a NaN,
// an infinity) can never stop a snapshot being written. A snapshot's card
// back that fails it is dropped, never a refused table.
func (b *CardBackground) forSeat() *CardBackground {
	if !b.valid() {
		return nil
	}
	return b.clone()
}

// seatCardBackground is what a seat keeps of a card back handed to it now:
// forSeat's copy of one a client can draw, or nil — the default back — for
// anything else, a rental that has already run out included (owner, 3 Oct
// 2026: "when validity of premium card expires, it restores default card").
// A back can arrive run out: a consolidation move whose seat was read a
// moment before the old table's clock fired, a snapshot restored after the
// moment passed while the process was down, a choice that lapsed between the
// account's read and the seat. Every one of them is the default back from
// the start, so no viewer is ever sent a back whose term is over. Actor only
// (and RestoreTable's first phase, before the loop runs): it reads the
// table's clock.
func (t *Table) seatCardBackground(cb *CardBackground) *CardBackground {
	kept := cb.forSeat()
	if kept.expiredAt(t.clock.Now()) {
		return nil
	}
	return kept
}

// SetCardBackground puts the card back a player has just chosen on their seat
// (nil takes it off, and their cards wear the default back again), and emits
// seatUpdated and state, so every viewer sees the new back on that player's
// cards at once — mid-hand too: nothing about the hand changes. The state
// emit marks the snapshot dirty, so a table restored from the live store
// keeps it. A card back no client could draw, or a rental already run out
// (seatCardBackground), is taken as none. The table's card-back clock is
// re-armed for whatever the seats now wear: a rented back comes off by itself
// when its term ends, and one renewed meanwhile — the same back with a later
// ExpiresAt — stays on until its new moment. No-op when the player is not
// seated.
func (t *Table) SetCardBackground(userID string, cb *CardBackground) error {
	// A copy, taken before posting: the caller's value is not the actor's to
	// read.
	cb = cb.forSeat()
	return t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			return
		}
		s.cardBackground = t.seatCardBackground(cb)
		t.listener.OnSeatUpdated(t.view, s.seatIndex)
		t.emitState()
		t.armCardBackgroundTimer()
	})
}

// armCardBackgroundTimer (re)arms the table's ONE card-back clock for the
// earliest moment a seat's rented card back runs out, and leaves it stopped
// when no seat wears one that does — the unfunded grace's pattern
// (armUnfundedTimer): one timer for every seat, re-armed whenever the backs
// the seats wear change (a sit-down or a move's arrival, a departure, a change
// at the table, a restore, and each time it fires). When it fires,
// expireCardBackgrounds takes off every back whose moment has come. A moment
// already past (a restore, a late re-arm) fires at once. Actor only.
func (t *Table) armCardBackgroundTimer() {
	t.clearCardBackgroundTimer()
	if t.destroyed.Load() {
		return
	}
	var next int64
	for _, s := range t.occupiedSeats() {
		if b := s.cardBackground; b != nil && b.ExpiresAt > 0 && (next == 0 || b.ExpiresAt < next) {
			next = b.ExpiresAt
		}
	}
	if next == 0 {
		return
	}
	d := max(FromMillis(next).Sub(t.clock.Now()), 0)
	t.cardBackgroundTimerGen++
	gen := t.cardBackgroundTimerGen
	t.cardBackgroundTimer = t.clock.AfterFunc(d, func() {
		_ = t.run(func() {
			// A timer stopped a moment too late (time.AfterFunc's Stop can
			// lose that race) is stale: a newer one is armed for the backs as
			// they are now.
			if t.cardBackgroundTimerGen != gen || t.cardBackgroundTimer == nil {
				return
			}
			t.cardBackgroundTimer = nil
			t.expireCardBackgrounds()
		})
	})
}

// expireCardBackgrounds runs when the card-back clock fires: every seat whose
// card back has run out by now goes back to the default back — seatUpdated for
// each, then one state for the table, so every viewer sees it go at once and
// the snapshot is saved without it — and the clock is re-armed for the next
// one. Each seat is judged by the back it wears NOW, its own ExpiresAt against
// the clock: a back renewed meanwhile (a later ExpiresAt) or replaced by
// another is kept, and two backs with the same moment go together. Nothing
// else about the table or its hand changes: a card back is only what the
// face-down cards look like. Actor only.
func (t *Table) expireCardBackgrounds() {
	now := t.clock.Now()
	expired := false
	for _, s := range t.occupiedSeats() {
		if !s.cardBackground.expiredAt(now) {
			continue
		}
		s.cardBackground = nil
		t.listener.OnSeatUpdated(t.view, s.seatIndex)
		expired = true
	}
	if expired {
		t.emitState()
	}
	t.armCardBackgroundTimer()
}

// clearCardBackgroundTimer stops the card-back clock if it is armed — and
// destroy, suspend and a fence stop it with every other clock.
func (t *Table) clearCardBackgroundTimer() {
	if t.cardBackgroundTimer != nil {
		t.cardBackgroundTimer.Stop()
		t.cardBackgroundTimer = nil
	}
}
