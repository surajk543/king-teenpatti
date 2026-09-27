package bot

import (
	"sync"
	"time"
)

// claimTTL is how long a bot's claim on a lobby table (ClaimTable) counts
// without the seat it was for: long enough for a quick-join's round trip,
// short enough that a claim a bot never settled (its connection dropped
// mid-join) stops holding a place.
const claimTTL = 20 * time.Second

// claim is a bot on its way to a table of key, since at.
type claim struct {
	key string
	at  time.Time
}

// Fleet is what the bots of one runner know about each other: which user ids
// are the fleet's own and which table each one sits at. It lets a bot tell
// "a table of my fellow bots" from "a table with a real player", spread the
// fleet across tables, and keep bots from greeting each other in chorus.
//
// It is the runner's own memory — nothing here reaches the server or any
// player, and the server's is_bot label is never read (it is not on the wire).
// Safe for concurrent use.
type Fleet struct {
	mu    sync.Mutex
	bots  map[string]bool   // user id → a bot of this fleet
	seat  map[string]string // bot user id → room id
	rooms map[string]int    // room id → bots of this fleet seated there
	keys  map[string]string // room id → table key ("blind:5000")
	// claims are the bots asking for a seat right now, by user id
	// (ClaimTable), so the fleet's count of a lobby table includes them.
	claims map[string]claim
}

// NewFleet is an empty registry.
func NewFleet() *Fleet {
	return &Fleet{
		bots:   map[string]bool{},
		seat:   map[string]string{},
		rooms:  map[string]int{},
		keys:   map[string]string{},
		claims: map[string]claim{},
	}
}

// AddBot records a user id as one of the fleet's.
func (f *Fleet) AddBot(userID string) {
	if userID == "" {
		return
	}
	f.mu.Lock()
	f.bots[userID] = true
	f.mu.Unlock()
}

// IsBot reports whether userID is one of the fleet's bots.
func (f *Fleet) IsBot(userID string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.bots[userID]
}

// Seat records that bot userID sits at roomID (a table of key).
func (f *Fleet) Seat(userID, roomID, key string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.claims, userID) // the seat it claimed, or another: either way settled
	if old, ok := f.seat[userID]; ok {
		if old == roomID {
			return
		}
		f.leaveLocked(userID, old)
	}
	f.seat[userID] = roomID
	f.rooms[roomID]++
	if key != "" {
		f.keys[roomID] = key
	}
}

// Unseat records that bot userID left its table.
func (f *Fleet) Unseat(userID string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if old, ok := f.seat[userID]; ok {
		f.leaveLocked(userID, old)
	}
}

func (f *Fleet) leaveLocked(userID, roomID string) {
	delete(f.seat, userID)
	f.rooms[roomID]--
	if f.rooms[roomID] <= 0 {
		delete(f.rooms, roomID)
		delete(f.keys, roomID)
	}
}

// BotsAt is how many of the fleet's bots sit at roomID.
func (f *Fleet) BotsAt(roomID string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.rooms[roomID]
}

// Occupancy is, per table key, the share of the fleet's seated bots sitting
// at tables of that key (0..1) — the selector uses it to spread the fleet.
func (f *Fleet) Occupancy() map[string]float64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	total := 0
	byKey := map[string]int{}
	for room, n := range f.rooms {
		byKey[f.keys[room]] += n
		total += n
	}
	out := make(map[string]float64, len(byKey))
	if total == 0 {
		return out
	}
	for k, n := range byKey {
		if k != "" {
			out[k] = float64(n) / float64(total)
		}
	}
	return out
}

// ClaimTable records that bot userID is about to ask for a seat at a table
// of key, and reports whether it may: false when the fleet already holds
// ceiling bots there, seated or on their way (ceiling 0 = no ceiling). The
// check and the claim are one step, so bots choosing at the same moment
// cannot all take the last place. Seat settles the claim; ReleaseClaim drops
// it when the seat is refused; a claim older than claimTTL no longer counts.
func (f *Fleet) ClaimTable(userID, key string, ceiling int, now time.Time) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.claims, userID) // a bot has one claim at a time
	if ceiling > 0 && f.heldLocked(now)[key] >= ceiling {
		return false
	}
	f.claims[userID] = claim{key: key, at: now}
	return true
}

// ReleaseClaim drops bot userID's claim (its join was refused or abandoned).
func (f *Fleet) ReleaseClaim(userID string) {
	f.mu.Lock()
	delete(f.claims, userID)
	f.mu.Unlock()
}

// Held is, per table key, how many of the fleet's bots sit at tables of that
// key or are on their way to one (a claim younger than claimTTL).
func (f *Fleet) Held(now time.Time) map[string]int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.heldLocked(now)
}

func (f *Fleet) heldLocked(now time.Time) map[string]int {
	out := map[string]int{}
	for room, n := range f.rooms {
		if k := f.keys[room]; k != "" {
			out[k] += n
		}
	}
	for id, c := range f.claims {
		if now.Sub(c.at) > claimTTL {
			delete(f.claims, id)
			continue
		}
		out[c.key]++
	}
	return out
}

// BusierTable reports whether the fleet has bots at another table of key
// (not excludeRoom) with at least than of them and fewer than maxPlayers —
// a table a quick-join at that stake could seat a bot at, busier than the
// one it is leaving. Humans are not counted, so this errs towards "no".
func (f *Fleet) BusierTable(key, excludeRoom string, than, maxPlayers int) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for room, n := range f.rooms {
		if room != excludeRoom && f.keys[room] == key && n >= than && (maxPlayers <= 0 || n < maxPlayers) {
			return true
		}
	}
	return false
}

// Seated is how many of the fleet's bots are seated anywhere.
func (f *Fleet) Seated() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.seat)
}
