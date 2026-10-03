package game

import (
	"math"
	"net/url"
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
type CardBackground struct {
	ID     int64  `json:"id"`
	URL    string `json:"url"`
	Format string `json:"assetFormat"`
	// Crop is the card's rectangle inside the picture, or nil when the whole
	// picture is the card. The owner's art is product shots — the card on a
	// dark ground, at a different size and place in each — so every seeded
	// row carries one, measured by hand at the card's 5:7.
	Crop *CardCrop `json:"crop,omitempty"`
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
// card back comes from already obey).
func (b *CardBackground) valid() bool {
	if b == nil || b.Format != CardBackgroundFormat {
		return false
	}
	u, err := url.Parse(b.URL)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return false
	}
	return b.Crop == nil || b.Crop.valid()
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
// draw. It is the ONE rule for every way a card back reaches a seat (a
// sit-down, a change at the table, a restore), so what every viewer is sent
// is exactly what a restored table brings back, and a figure JSON cannot
// carry (a NaN, an infinity) can never stop a snapshot being written. A
// snapshot's card back that fails it is dropped, never a refused table.
func (b *CardBackground) forSeat() *CardBackground {
	if !b.valid() {
		return nil
	}
	return b.clone()
}

// SetCardBackground puts the card back a player has just chosen on their seat
// (nil takes it off, and their cards wear the default back again), and emits
// seatUpdated and state, so every viewer sees the new back on that player's
// cards at once — mid-hand too: nothing about the hand changes. The state
// emit marks the snapshot dirty, so a table restored from the live store
// keeps it. A card back no client could draw (CardBackground.forSeat) is
// taken as none. No-op when the player is not seated.
func (t *Table) SetCardBackground(userID string, cb *CardBackground) error {
	cb = cb.forSeat()
	return t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			return
		}
		s.cardBackground = cb
		t.listener.OnSeatUpdated(t.view, s.seatIndex)
		t.emitState()
	})
}
