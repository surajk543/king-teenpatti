package game

import (
	"bytes"
	"encoding/json"
	"math"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
)

// The card backs (owner, 3 Oct 2026: "Add a table cards_background which
// users can buy just like user can buy profile_pictures"): the back each
// player has chosen rides on their seat, and every viewer's snapshot shows it
// on that seat — absent, never null, where none is chosen, so a table where
// nobody has chosen one sends exactly what it always did. A change at the
// table reaches everyone at once and leaves the hand alone, the snapshot
// keeps it, and a restore drops one no client could draw rather than refuse
// the table. The moves and the RoomManager's side are in
// cardbackground_rooms_test.go.

// cardsAt is where the owner's card backs are: the seed's locations in the
// private R2 bucket, spaces written %20.
const cardsAt = "https://a91cb23b3b93a35dd9ea50db7b855e18.r2.cloudflarestorage.com/king-teenpatti/cards/"

// brutalDemon is a seeded card back as the account hands it to a seat: its
// location, and the card's rectangle measured inside the product shot.
func brutalDemon() *CardBackground {
	return &CardBackground{ID: 1, URL: cardsAt + "Brutal%20Demon.jpg", Format: CardBackgroundFormat,
		Crop: &CardCrop{X: 0.2035, Y: 0.0805, W: 0.6007, H: 0.8410}}
}

func royalLion() *CardBackground {
	return &CardBackground{ID: 4, URL: cardsAt + "Royal%20Lion.jpg", Format: CardBackgroundFormat,
		Crop: &CardCrop{X: 0.2065, Y: 0.0948, W: 0.5851, H: 0.8192}}
}

// wholePicture is a card back whose picture is all card: it has no crop.
func wholePicture() *CardBackground {
	return &CardBackground{ID: 9, URL: cardsAt + "Whole.jpg", Format: CardBackgroundFormat}
}

// seatWithBack seats id with the given card back (nil: none chosen).
func (h *harness) seatWithBack(id string, back *CardBackground) {
	h.t.Helper()
	if _, err := h.table.AddPlayer(NewPlayer{UserID: id, DisplayName: id, Chips: tableStart, SocketID: "s-" + id, CardBackground: back}); err != nil {
		h.t.Fatalf("seat %s: %v", id, err)
	}
}

// backOn is the card back viewer's snapshot shows on userID's seat, as the
// wire carries it; ok is false when the seat has no cardBackground key.
func (h *harness) backOn(viewer, userID string) (back map[string]any, ok bool) {
	h.t.Helper()
	seat := seatOf(h.seatsJSON(viewer), userID)
	if seat == nil {
		h.t.Fatalf("%s's snapshot has no seat for %s", viewer, userID)
	}
	raw, has := seat["cardBackground"]
	if !has {
		return nil, false
	}
	back, isObject := raw.(map[string]any)
	if !isObject {
		h.t.Fatalf("%s's snapshot: %s's cardBackground is %v, want an object", viewer, userID, raw)
	}
	return back, true
}

// sameBack reports whether the wire's back is b, crop and all.
func sameBack(t *testing.T, got map[string]any, b *CardBackground) bool {
	t.Helper()
	var want map[string]any
	if err := json.Unmarshal([]byte(mustJSON(t, b)), &want); err != nil {
		t.Fatal(err)
	}
	return reflect.DeepEqual(got, want)
}

// keysInOrder lists a JSON object's keys exactly as the wire carries them.
func keysInOrder(t *testing.T, raw []byte) []string {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(raw))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		t.Fatalf("not an object: %s", raw)
	}
	var keys []string
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, tok.(string))
		var skip json.RawMessage
		if err := dec.Decode(&skip); err != nil {
			t.Fatal(err)
		}
	}
	return keys
}

func TestEveryViewerSeesEachPlayersCardBackOnTheirSeat(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seatWithBack("a", brutalDemon())
	h.seatWithBack("b", wholePicture())
	h.seatWithBack("c", nil)

	// The wire's shape, pinned once: the location, the format and the crop.
	raw, err := json.Marshal(h.view("c").Seats[0].CardBackground)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"id":1,"url":"` + cardsAt + `Brutal%20Demon.jpg","assetFormat":"IMAGE","crop":{"x":0.2035,"y":0.0805,"w":0.6007,"h":0.841}}`; string(raw) != want {
		t.Fatalf("a's card back on the wire:\n got %s\nwant %s", raw, want)
	}

	// Public: the same backs on the same seats in every viewer's snapshot,
	// the viewer's own seat included — and nowhere else in it.
	for _, viewer := range []string{"a", "b", "c", ""} {
		if back, ok := h.backOn(viewer, "a"); !ok || !sameBack(t, back, brutalDemon()) {
			t.Errorf("%q's snapshot: a's seat shows %v, want the Brutal Demon with its crop", viewer, back)
		}
		back, ok := h.backOn(viewer, "b")
		if !ok || !sameBack(t, back, wholePicture()) {
			t.Errorf("%q's snapshot: b's seat shows %v, want the whole-picture back", viewer, back)
		}
		if _, hasCrop := back["crop"]; hasCrop {
			t.Errorf("%q's snapshot: a back with no crop carries a crop key: %v", viewer, back)
		}
		if back, ok := h.backOn(viewer, "c"); ok {
			t.Errorf("%q's snapshot: c chose no card back, yet the seat carries %v", viewer, back)
		}
		for _, s := range h.seatsJSON(viewer) {
			if s["status"] == string(SeatEmpty) && len(s) != 2 {
				t.Errorf("an empty seat is exactly {seatIndex, status}: %v", s)
			}
		}
		if got := strings.Count(mustJSON(t, h.view(viewer)), `"cardBackground"`); got != 2 {
			t.Errorf("%q's snapshot names a card back %d times, want exactly on a's and b's seats", viewer, got)
		}
	}

	// SeatInfo carries a copy, so a consolidation move takes it along.
	if got := h.seatInfo("a").CardBackground; !reflect.DeepEqual(got, brutalDemon()) {
		t.Errorf("SeatInfo.CardBackground = %+v", got)
	}
	if got := h.seatInfo("c").CardBackground; got != nil {
		t.Errorf("c's SeatInfo carries %+v, want none", got)
	}
}

// A table where nobody has chosen a card back — every table before the
// feature — sends exactly what it always did: no seat grows a key, the keys
// it has stay in their order, and the live store's snapshot is unchanged too.
func TestATableWhereNobodyHasChosenACardBackSendsWhatItAlwaysDid(t *testing.T) {
	// The bytes wire_test.go pins for an occupied seat, now with the field.
	if got := marshal(t, SeatView{SeatIndex: 1, UserID: "u", DisplayName: "Ravi", Status: SeatActive, IsBlind: true}); got != `{"seatIndex":1,"userId":"u","displayName":"Ravi","avatarUrl":null,"chips":null,"status":"active","isBlind":true,"lastBet":0,"lastAction":null,"contributed":0,"connected":false,"cardCount":0}` {
		t.Fatalf("a seat with no card back = %s", got)
	}
	before := []string{"seatIndex", "userId", "displayName", "avatarUrl", "chips", "status", "isBlind", "lastBet", "lastAction", "contributed", "connected", "cardCount"}

	for _, category := range []Category{CategorySeen, CategoryBlind} {
		cfg := tableConfig()
		cfg.Category = category
		h := newHarness(t, cfg)
		h.seat("a", tableStart)
		h.seat("b", tableStart)
		h.advance(6 * time.Second)
		if !h.hasHand() {
			t.Fatalf("%s: no hand was dealt", category)
		}
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})

		for _, viewer := range []string{"a", "b"} {
			view := h.view(viewer)
			if raw := mustJSON(t, view); strings.Contains(raw, "cardBackground") {
				t.Fatalf("%s, %s's snapshot: %s", category, viewer, raw)
			}
			for _, s := range view.Seats {
				raw, err := json.Marshal(s)
				if err != nil {
					t.Fatal(err)
				}
				keys := keysInOrder(t, raw)
				if s.Empty {
					if !reflect.DeepEqual(keys, []string{"seatIndex", "status"}) {
						t.Errorf("%s: an empty seat is %s", category, raw)
					}
					continue
				}
				if !reflect.DeepEqual(keys, before) {
					t.Errorf("%s, %s's snapshot: seat %d's keys are %v, want %v", category, viewer, s.SeatIndex, keys, before)
				}
			}
		}
		if raw := mustJSON(t, mustSnapshot(h)); strings.Contains(raw, "cardBackground") {
			t.Fatalf("%s: the live store's snapshot names a card back nobody chose: %s", category, raw)
		}
	}
}

func TestChoosingACardBackMidHandShowsItToEveryoneAtOnceAndNilTakesItOff(t *testing.T) {
	store := livetest.New()
	h := newHarness(t, liveConfig(), withLive(store))
	for _, id := range []string{"a", "b", "c"} {
		h.seatWithBack(id, nil)
	}
	h.advance(6 * time.Second)
	if !h.hasHand() {
		t.Fatal("no hand was dealt")
	}
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	hand := mustSnapshot(h)
	saves := len(store.Saves())
	events := h.rec.count()

	// b chooses the Royal Lion at the table, mid-hand.
	lion := royalLion()
	if err := h.table.SetCardBackground("b", lion); err != nil {
		t.Fatal(err)
	}
	bSeat := h.seatInfo("b").SeatIndex
	if got := h.rec.names()[events:]; !reflect.DeepEqual(got, []string{"seatUpdated", "state"}) {
		t.Fatalf("the change emitted %v, want seatUpdated then state", got)
	}
	if got := h.rec.last("seatUpdated"); got != bSeat {
		t.Fatalf("seatUpdated for seat %v, want b's %d", got, bSeat)
	}
	for _, viewer := range []string{"a", "b", "c"} {
		if back, ok := h.backOn(viewer, "b"); !ok || !sameBack(t, back, royalLion()) {
			t.Errorf("%s's snapshot: b's seat shows %v, want the Royal Lion", viewer, back)
		}
		for _, other := range []string{"a", "c"} {
			if back, ok := h.backOn(viewer, other); ok {
				t.Errorf("%s's snapshot: %s's seat shows %v, want none", viewer, other, back)
			}
		}
	}
	// The seat keeps its own copy: the caller changing its value later
	// changes nothing anybody is sent.
	lion.URL, lion.Crop.X = cardsAt+"Tampered.jpg", 0.9
	if back, _ := h.backOn("a", "b"); !sameBack(t, back, royalLion()) {
		t.Errorf("the caller's later change reached the seat: %v", back)
	}

	// Nothing about the hand moved: the snapshot is the one from before but
	// for b's card back (and the seq of the save it took).
	now := mustSnapshot(h)
	if !reflect.DeepEqual(now.Seats[bSeat].CardBackground, royalLion()) {
		t.Fatalf("the snapshot carries %+v on b's seat", now.Seats[bSeat].CardBackground)
	}
	now.Seats[bSeat].CardBackground = nil
	now.Seq = hand.Seq
	if got, want := mustJSON(t, now), mustJSON(t, hand); got != want {
		t.Fatalf("the change moved the hand:\n got %s\nwant %s", got, want)
	}
	// And the live store has it, saved once.
	eq(t, len(store.Saves()), saves+1, "one save for the change")
	stored, _ := store.Stored("room-1")
	var latest Snapshot
	if err := json.Unmarshal(stored.Snapshot, &latest); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(latest.Seats[bSeat].CardBackground, royalLion()) {
		t.Fatalf("the stored snapshot carries %+v on b's seat", latest.Seats[bSeat].CardBackground)
	}

	// nil takes it off, for everyone.
	if err := h.table.SetCardBackground("b", nil); err != nil {
		t.Fatal(err)
	}
	for _, viewer := range []string{"a", "b", "c"} {
		if back, ok := h.backOn(viewer, "b"); ok {
			t.Errorf("%s's snapshot: b took the card back off, yet the seat shows %v", viewer, back)
		}
	}
	stored, _ = store.Stored("room-1")
	if strings.Contains(string(stored.Snapshot), "cardBackground") {
		t.Fatalf("the stored snapshot still names a card back: %s", stored.Snapshot)
	}
	eq(t, h.hasHand(), true, "the hand plays on")

	// A player who is not at the table: nothing happens, and nothing is sent.
	events, saves = h.rec.count(), len(store.Saves())
	if err := h.table.SetCardBackground("nobody", royalLion()); err != nil {
		t.Fatal(err)
	}
	eq(t, h.rec.count(), events, "no event for a player who is not seated")
	eq(t, len(store.Saves()), saves, "no save for a player who is not seated")
}

func TestTheCardBacksSurviveASnapshotRoundTripAndARestore(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seatWithBack("a", brutalDemon())
	h.seatWithBack("b", wholePicture())
	h.seatWithBack("c", nil)
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})

	snap := roundTrip(t, mustSnapshot(h))
	if got := strings.Count(mustJSON(t, snap), `"cardBackground":`); got != 2 {
		t.Fatalf("a's and b's card backs must be in the snapshot and c's absent; it names %d", got)
	}
	restored := restoreHarness(t, snap, newFakeClock(h.clock.Now()))
	if got, want := mustJSON(t, roundTrip(t, mustSnapshot(restored))), mustJSON(t, snap); got != want {
		t.Fatalf("the restore must keep every card back:\n got %s\nwant %s", got, want)
	}
	eq(t, restored.hasHand(), true, "the hand came back")
	for _, viewer := range []string{"a", "b", "c"} {
		if back, ok := restored.backOn(viewer, "a"); !ok || !sameBack(t, back, brutalDemon()) {
			t.Errorf("after the restore %s sees %v on a's seat", viewer, back)
		}
		if back, ok := restored.backOn(viewer, "b"); !ok || !sameBack(t, back, wholePicture()) {
			t.Errorf("after the restore %s sees %v on b's seat", viewer, back)
		}
		if back, ok := restored.backOn(viewer, "c"); ok {
			t.Errorf("after the restore %s sees %v on c's seat, want none", viewer, back)
		}
	}
}

// A snapshot's card back no client could draw — written by hand, or by a
// build with other rules — is dropped: that seat wears the default back, the
// others keep theirs, and the table (hand and all) is restored.
func TestACardBackNoClientCouldDrawIsDroppedOnRestoreAndTheTableStillRestores(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seatWithBack("a", brutalDemon())
	h.seatWithBack("b", royalLion())
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	good := mustSnapshot(h)

	spoil := map[string]func(b *CardBackground){
		"no url":             func(b *CardBackground) { b.URL = "" },
		"an http url":        func(b *CardBackground) { b.URL = "http://insecure.test/cards/x.jpg" },
		"a path, not a url":  func(b *CardBackground) { b.URL = "/cards/Brutal%20Demon.jpg" },
		"a url with no host": func(b *CardBackground) { b.URL = "https:///cards/x.jpg" },
		"a lottie":           func(b *CardBackground) { b.Format = "LOTTIE" },
		"no format":          func(b *CardBackground) { b.Format = "" },
		"a crop left of it":  func(b *CardBackground) { b.Crop.X = -0.01 },
		"a crop above it":    func(b *CardBackground) { b.Crop.Y = -0.5 },
		"no width":           func(b *CardBackground) { b.Crop.W = 0 },
		"a negative height":  func(b *CardBackground) { b.Crop.H = -0.8 },
		"past the right":     func(b *CardBackground) { b.Crop.X, b.Crop.W = 0.5, 0.6 },
		"past the foot":      func(b *CardBackground) { b.Crop.Y, b.Crop.H = 0.2, 0.81 },
		"a NaN":              func(b *CardBackground) { b.Crop.W = math.NaN() },
		"an infinity":        func(b *CardBackground) { b.Crop.H = math.Inf(1) },
	}
	for name, spoilIt := range spoil {
		t.Run(name, func(t *testing.T) {
			// The NaN and the infinity never survive JSON, so the snapshot
			// is copied by value and handed to the restore as a struct.
			bad := roundTrip(t, good)
			aSeat := -1
			for i, s := range bad.Seats {
				if s != nil && s.UserID == "a" {
					aSeat = i
				}
			}
			spoilIt(bad.Seats[aSeat].CardBackground)

			table, err := restoreTable(bad, TableOptions{Clock: newFakeClock(h.clock.Now())})
			if err != nil {
				t.Fatalf("a bad card back must not refuse the table: %v", err)
			}
			defer func() { _ = table.Destroy() }()
			if !table.HasHand() {
				t.Fatal("the hand was not restored")
			}
			view, err := table.SerializeFor("b")
			if err != nil {
				t.Fatal(err)
			}
			if got := view.Seats[aSeat].CardBackground; got != nil {
				t.Errorf("a's spoilt card back was kept: %+v", got)
			}
			found := false
			for _, s := range view.Seats {
				if s.UserID == "b" {
					found = reflect.DeepEqual(s.CardBackground, royalLion())
				}
			}
			if !found {
				t.Error("b's good card back must survive beside it")
			}
			if _, err := json.Marshal(view); err != nil {
				t.Fatalf("the restored table's snapshot does not marshal: %v", err)
			}
		})
	}
}

// The rules a card back must meet are the catalogue's own CHECKs: every crop
// the owner measured passes, and so does a crop that is the whole picture or
// touches its edges; nothing outside the picture, of no size, not finite,
// not an https location or not a raster does.
func TestTheCardBackRulesAreTheCataloguesChecks(t *testing.T) {
	seeded := map[string]CardCrop{
		"Brutal Demon":       {X: 0.2035, Y: 0.0805, W: 0.6007, H: 0.8410},
		"Demon Hell":         {X: 0.2203, Y: 0.1167, W: 0.5594, H: 0.7831},
		"Dragon Hunter":      {X: 0.2073, Y: 0.0880, W: 0.5844, H: 0.8182},
		"Royal Lion":         {X: 0.2065, Y: 0.0948, W: 0.5851, H: 0.8192},
		"Royal Majestic Fox": {X: 0.2371, Y: 0.1336, W: 0.5248, H: 0.7347},
		"Royal Owl with Fox": {X: 0.1985, Y: 0.0776, W: 0.6021, H: 0.8429},
		"Royal Tiger":        {X: 0.2291, Y: 0.1262, W: 0.5417, H: 0.7584},
		"Royal White Tiger":  {X: 0.2224, Y: 0.1108, W: 0.5533, H: 0.7746},
		"Royal Fox":          {X: 0.1927, Y: 0.0729, W: 0.6136, H: 0.8590},
		"Flower 1":           {X: 0.2209, Y: 0.0994, W: 0.5729, H: 0.8021},
		"Flower 2":           {X: 0.2308, Y: 0.1124, W: 0.5383, H: 0.7537},
		"Flower 3":           {X: 0.2295, Y: 0.1261, W: 0.5411, H: 0.7575},
		"Flower 4":           {X: 0.2393, Y: 0.1365, W: 0.5214, H: 0.7299},
		"Flower 5":           {X: 0.2346, Y: 0.1279, W: 0.5289, H: 0.7404},
	}
	for name, crop := range seeded {
		b := &CardBackground{ID: 1, URL: cardsAt + strings.ReplaceAll(name, " ", "%20") + ".jpg", Format: "IMAGE", Crop: &crop}
		if !b.valid() {
			t.Errorf("the owner's %s must pass: %+v", name, crop)
		}
	}

	back := func(url, format string, crop *CardCrop) *CardBackground {
		return &CardBackground{ID: 7, URL: url, Format: format, Crop: crop}
	}
	at := cardsAt + "x.jpg"
	cases := []struct {
		name string
		b    *CardBackground
		want bool
	}{
		{"no crop: the whole picture is the card", back(at, "IMAGE", nil), true},
		{"a crop that is the whole picture", back(at, "IMAGE", &CardCrop{0, 0, 1, 1}), true},
		{"a crop at the right and foot edges", back(at, "IMAGE", &CardCrop{0.25, 0.5, 0.75, 0.5}), true},
		{"an upper-case scheme", back("HTTPS://cards.test/x.jpg", "IMAGE", nil), true},
		{"nothing", nil, false},
		{"no url", back("", "IMAGE", nil), false},
		{"only spaces", back("   ", "IMAGE", nil), false},
		{"http", back("http://cards.test/x.jpg", "IMAGE", nil), false},
		{"ftp", back("ftp://cards.test/x.jpg", "IMAGE", nil), false},
		{"a relative path", back("cards/x.jpg", "IMAGE", nil), false},
		{"https with no host", back("https:///x.jpg", "IMAGE", nil), false},
		{"a malformed escape", back("https://cards.test/%zz.jpg", "IMAGE", nil), false},
		{"a lottie", back(at, "LOTTIE", nil), false},
		{"an svg", back(at, "SVG", nil), false},
		{"the format in lower case", back(at, "image", nil), false},
		{"x below 0", back(at, "IMAGE", &CardCrop{-0.0001, 0, 0.5, 0.5}), false},
		{"y below 0", back(at, "IMAGE", &CardCrop{0, -0.0001, 0.5, 0.5}), false},
		{"no width", back(at, "IMAGE", &CardCrop{0, 0, 0, 0.5}), false},
		{"no height", back(at, "IMAGE", &CardCrop{0, 0, 0.5, 0}), false},
		{"a negative width", back(at, "IMAGE", &CardCrop{0.6, 0, -0.5, 0.5}), false},
		{"past the right edge", back(at, "IMAGE", &CardCrop{0.5, 0, 0.5001, 0.5}), false},
		{"past the foot", back(at, "IMAGE", &CardCrop{0, 0.5, 0.5, 0.5001}), false},
		{"a NaN", back(at, "IMAGE", &CardCrop{math.NaN(), 0, 0.5, 0.5}), false},
		{"an infinite width", back(at, "IMAGE", &CardCrop{0, 0, math.Inf(1), 0.5}), false},
		{"a minus infinite x", back(at, "IMAGE", &CardCrop{math.Inf(-1), 0, 0.5, 0.5}), false},
	}
	for _, c := range cases {
		if got := c.b.valid(); got != c.want {
			t.Errorf("%s: valid = %v, want %v", c.name, got, c.want)
		}
		kept := c.b.forSeat()
		switch {
		case c.want && (kept == nil || !reflect.DeepEqual(kept, c.b)):
			t.Errorf("%s: a seat keeps %+v, want a copy of %+v", c.name, kept, c.b)
		case c.want && (kept == c.b || (c.b.Crop != nil && kept.Crop == c.b.Crop)):
			t.Errorf("%s: a seat shares its card back with the caller", c.name)
		case !c.want && kept != nil:
			t.Errorf("%s: a seat keeps %+v, want none (the default back)", c.name, kept)
		}
	}
}

// A seat never shares its card back with anybody: not with the player handed
// to AddPlayer, not with a SeatInfo, not with a viewer's snapshot. And it
// never takes one no client could draw — that player's cards wear the
// default back, exactly as a restore would leave them.
func TestASeatKeepsItsOwnCopyOfTheCardBack(t *testing.T) {
	h := newHarness(t, tableConfig())
	given := brutalDemon()
	h.seatWithBack("a", given)
	given.URL, given.Crop.W = cardsAt+"Tampered.jpg", 0.1

	info := h.seatInfo("a")
	info.CardBackground.ID, info.CardBackground.Crop.H = 99, 0.2
	view := h.view("a")
	view.Seats[0].CardBackground.URL, view.Seats[0].CardBackground.Crop.X = cardsAt+"Other.jpg", 0.3

	if got := h.seatInfo("a").CardBackground; !reflect.DeepEqual(got, brutalDemon()) {
		t.Fatalf("the seat's card back was changed from outside: %+v", got)
	}
	if back, ok := h.backOn("b", "a"); !ok || !sameBack(t, back, brutalDemon()) {
		t.Fatalf("another viewer sees %v on a's seat", back)
	}

	h.seatWithBack("b", &CardBackground{ID: 3, URL: "http://insecure.test/x.jpg", Format: "IMAGE"})
	if back, ok := h.backOn("a", "b"); ok {
		t.Fatalf("b was seated with a card back no client could draw: %v", back)
	}
	// Chosen at the table, such a card back is taken as none: a's own comes
	// off and their cards wear the default, as after a restore.
	if err := h.table.SetCardBackground("a", &CardBackground{ID: 5, URL: cardsAt + "x.jpg", Format: "IMAGE", Crop: &CardCrop{0.5, 0.5, 0.6, 0.6}}); err != nil {
		t.Fatal(err)
	}
	if back, ok := h.backOn("b", "a"); ok {
		t.Fatalf("a crop past the picture's edge must leave a's seat with no card back, it shows %v", back)
	}
}
