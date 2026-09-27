package bot

import "sync"

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
}

// NewFleet is an empty registry.
func NewFleet() *Fleet {
	return &Fleet{bots: map[string]bool{}, seat: map[string]string{}, rooms: map[string]int{}, keys: map[string]string{}}
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
