package game

import (
	"sync"
	"time"
)

// Report Player (owner, 27 Sep 2026): "A player sitting at a gameplay table
// must be able to report another player currently at the same table" — or
// one the reporter was validly associated with at their recent table/hand.
// This file is the game's half of it: whether two players share a table, or
// shared one moments ago, and what the server knows about where they met — the
// room, its game and category, the variant, the hand. The report itself is
// the REST layer's (auth/reports.go) and the database's (db/reports.go).
//
// NOTHING HERE CHANGES THE GAME. A report is a read of the room's state —
// one posted read, like Seats — and a note kept beside the seat index; it
// never pauses, kicks, folds or bans anybody.
//
// "RECENTLY" IS A MEMORY OF THIS PROCESS. A room keeps no record of who has
// left it, and PostgreSQL keeps no hands (CLAUDE.md §5.1). So when a player
// leaves a room — a leave, a kick, a lapsed reconnect grace, a switch, a
// consolidation move, the room closing — the manager asks the room, once,
// where everybody still seated stands and where the departing player stood,
// and remembers each pair for ReportRecent (REPORT_RECENT_MS). Two players
// still seated together need no memory: the seat index says so, and the room
// answers for them on the spot. A restart forgets the departures (a restored
// room still answers for everybody seated at it), which is the accepted
// cost: a player who left before the restart can no longer be reported.

// ReportContext is where a report was filed, as the server knows it: the room
// two players shared, the kind of table it is, and the hand. Every field is
// the server's own; none comes from a client, and none is ever sent to one.
type ReportContext struct {
	// RoomID is the room's id (player_reports.table_id).
	RoomID string
	// Game is the room's engine: GameTeenPatti or GamePoker.
	Game Game
	// Category is the room's category (seen … omaha).
	Category Category
	// Variant is the rules the relevant hand was played under: a Variation
	// hand's chosen variation (MUFLIS … FIVE_CARD; "" while it is being
	// chosen), the poker variant at a poker room (its category, as
	// chip_ledger.variant has it), "" otherwise.
	Variant string
	// HandID is the relevant hand: the one the player is in now, else the
	// last one they were dealt into at this room; "" when neither is known
	// (they sat down between hands, or the room was restored since).
	HandID string
}

// RecentHand is the hand a room last finished, kept in memory until the next
// one finishes (never in the snapshot): which players were dealt into it and
// what it was played as, so a report filed in the pause between hands names
// the hand just played rather than none.
type RecentHand struct {
	ID      string
	Variant string
	players map[string]struct{}
}

// NewRecentHand remembers hand id, played as variant, with players dealt in.
func NewRecentHand(id, variant string, players []string) *RecentHand {
	h := &RecentHand{ID: id, Variant: variant, players: make(map[string]struct{}, len(players))}
	for _, p := range players {
		h.players[p] = struct{}{}
	}
	return h
}

// Has reports whether userID was dealt into the hand (nil-safe).
func (h *RecentHand) Has(userID string) bool {
	if h == nil {
		return false
	}
	_, ok := h.players[userID]
	return ok
}

// coPlayersPerPlayer bounds how many recent table-mates are remembered for one
// player: the oldest is dropped past it. A seat has at most four others at a
// time, so this is dozens of tables' worth of churn inside the window.
const coPlayersPerPlayer = 64

// coPlay is one remembered pair: where the OTHER player stood, and when.
type coPlay struct {
	ctx ReportContext
	at  time.Time
}

// coPlayers is the manager's memory of who shared a room with whom, for
// ReportRecent: seen[a][b] is b as a last saw them at a room they both sat at
// — the report a may file about b. Its own mutex, taken only by the manager's
// goroutines and never while a table is called or mu is held; the tables never
// touch it.
type coPlayers struct {
	mu     sync.Mutex
	ttl    time.Duration
	seen   map[string]map[string]coPlay
	swept  time.Time
	enable bool
}

func newCoPlayers(ttl time.Duration) *coPlayers {
	return &coPlayers{ttl: ttl, seen: map[string]map[string]coPlay{}, enable: ttl > 0}
}

// note remembers that a (as ctxA) and b (as ctxB) shared a room at `at`, both
// ways.
func (c *coPlayers) note(a, b string, ctxA, ctxB ReportContext, at time.Time) {
	if !c.enable || a == "" || b == "" || a == b {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sweepLocked(at)
	c.putLocked(a, b, coPlay{ctx: ctxB, at: at})
	c.putLocked(b, a, coPlay{ctx: ctxA, at: at})
}

func (c *coPlayers) putLocked(viewer, other string, p coPlay) {
	row := c.seen[viewer]
	if row == nil {
		row = map[string]coPlay{}
		c.seen[viewer] = row
	}
	row[other] = p
	if len(row) <= coPlayersPerPlayer {
		return
	}
	oldest, first := "", true
	var at time.Time
	for id, e := range row {
		if first || e.at.Before(at) {
			oldest, at, first = id, e.at, false
		}
	}
	delete(row, oldest)
}

// lookup is b as viewer last saw them, while that is inside the window.
func (c *coPlayers) lookup(viewer, other string, now time.Time) (ReportContext, bool) {
	if !c.enable {
		return ReportContext{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.seen[viewer][other]
	if !ok || now.Sub(e.at) > c.ttl {
		return ReportContext{}, false
	}
	return e.ctx, true
}

// sweepLocked drops every pair older than the window, at most once a window.
func (c *coPlayers) sweepLocked(now time.Time) {
	if now.Sub(c.swept) < c.ttl {
		return
	}
	c.swept = now
	for viewer, row := range c.seen {
		for other, e := range row {
			if now.Sub(e.at) > c.ttl {
				delete(row, other)
			}
		}
		if len(row) == 0 {
			delete(c.seen, viewer)
		}
	}
}

// ReportContext answers whether reporterID may report reportedID — whether
// the two are seated at the same room now, or shared one within
// RoomManagerOptions.ReportRecent — and where they met, as the server knows
// it. Now wins over memory: two players seated together are answered from the
// room itself (a posted read), with the hand as it is at this moment. Never
// changes anything at a table.
//
// Safe from any goroutine; takes mu briefly and calls the room with it
// released, as every manager method does.
func (rm *RoomManager) ReportContext(reporterID, reportedID string) (ReportContext, bool) {
	if reporterID == "" || reportedID == "" || reporterID == reportedID {
		return ReportContext{}, false
	}
	rm.mu.Lock()
	roomID := rm.playerRooms[reporterID]
	var room Room
	if roomID != "" && rm.playerRooms[reportedID] == roomID {
		room = rm.tables[roomID]
	}
	rm.mu.Unlock()
	if room != nil {
		if ctxs, err := room.ReportContexts(); err == nil {
			if ctx, ok := ctxs[reportedID]; ok {
				return ctx, true
			}
		}
	}
	return rm.coPlayers.lookup(reporterID, reportedID, rm.clock.Now())
}

// noteDeparture remembers, as departingID leaves room, every pair of them and
// a player still seated there — one posted read of the room, after the seat
// is gone (a player who left mid-hand is still in that hand's contributions,
// so the room still answers for them). Called holding the departing player's
// stripe, never mu. A room destroyed meanwhile has nothing to answer: nothing
// is remembered.
func (rm *RoomManager) noteDeparture(room Room, departingID string) {
	if room == nil || !rm.coPlayers.enable {
		return
	}
	ctxs, err := room.ReportContexts(departingID)
	if err != nil {
		return
	}
	mine, ok := ctxs[departingID]
	if !ok {
		return
	}
	at := rm.clock.Now()
	for other, theirs := range ctxs {
		if other != departingID {
			rm.coPlayers.note(departingID, other, mine, theirs, at)
		}
	}
}

// noteTogether remembers every pair among the players seated at room — the
// room is about to be destroyed with them at it (destroyTable), so it will
// never answer for them again. One posted read.
func (rm *RoomManager) noteTogether(room Room) {
	if room == nil || !rm.coPlayers.enable {
		return
	}
	ctxs, err := room.ReportContexts()
	if err != nil || len(ctxs) < 2 {
		return
	}
	at := rm.clock.Now()
	ids := make([]string, 0, len(ctxs))
	for id := range ctxs {
		ids = append(ids, id)
	}
	for i := range ids {
		for j := i + 1; j < len(ids); j++ {
			rm.coPlayers.note(ids[i], ids[j], ctxs[ids[i]], ctxs[ids[j]], at)
		}
	}
}
