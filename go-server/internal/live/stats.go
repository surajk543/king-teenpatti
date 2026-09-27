package live

import (
	"errors"
	"sort"
)

// Player stats v2 (owner, 27 Sep 2026: "store this info in redis, then async
// you can update by group commit so that u don't call postgres db multiple
// times"). The live store holds each player's gameplay counters from the
// moment a hand's write commits until the stats flusher (internal/stats) has
// added them to PostgreSQL:
//
//	kt:stats:<userId>                   hash  the PENDING counters: field → integer
//	kt:stats:dirty                      set   the players with pending counters
//	kt:stats:batches                    zset  batch id → when it was taken (epoch ms)
//	kt:stats:batch:<batchId>            set   the players a batch holds
//	kt:stats:inflight:<batchId>:<userId> hash a player's counters as the batch took them
//
// A field's name is opaque here (the stats codec writes "TEEN_PATTI:hands_played",
// "VARIATION:trail", "VARIATION:v:MUFLIS:played" and "…:biggest_pot"); what the
// store knows is how to fold a delta in: an Add field is summed (HINCRBY), a
// Max field keeps the larger value. User ids are UUIDs, so a player's key
// never collides with the dirty set, the batch index or a batch's keys.
//
// Losing the store loses the counters not yet flushed — at most one flush
// interval's — as losing it loses the hands in play (CLAUDE.md §5.1). No money
// is ever here.

// ErrStatsBatchExists is TakeStatsBatch's refusal of a batch id that already
// names an open batch: a take never adds to a batch, so an in-flight hash can
// never be overwritten by a second move.
var ErrStatsBatchExists = errors.New("live: stats batch already exists")

// StatsDelta is one player's counters to fold into their pending hash: Add's
// fields are summed, Max's keep the larger of the pending value and this one.
// A field is always of one kind — the codec never names it in both maps.
type StatsDelta struct {
	UserID string
	Add    map[string]int64
	Max    map[string]int64
}

// empty reports whether the delta folds nothing in.
func (d StatsDelta) empty() bool { return d.UserID == "" || len(d.Add)+len(d.Max) == 0 }

// StatsBatch is one flush's worth of counters: the players moved out of the
// pending hashes under one id, with their counters as moved (field → value).
// CreatedAt is when it was taken (epoch ms).
type StatsBatch struct {
	ID        string
	CreatedAt int64
	Players   map[string]map[string]int64
}

// StatsBook is the stats half of the Store contract kept in plain maps: the
// in-process store holds its counters in one, and the test stores
// (internal/livetest, internal/game/livetest) can use it to keep the same
// semantics. It is NOT safe for concurrent use — every caller holds its own
// lock around it, as Memory holds its mutex.
type StatsBook struct {
	pending map[string]map[string]int64
	dirty   map[string]struct{}
	batches map[string]*bookBatch
	taken   uint64 // a take's sequence number, the tie-break of batches taken in one millisecond
}

type bookBatch struct {
	createdAt int64
	seq       uint64
	players   map[string]map[string]int64
}

// NewStatsBook returns an empty book.
func NewStatsBook() *StatsBook {
	return &StatsBook{
		pending: map[string]map[string]int64{},
		dirty:   map[string]struct{}{},
		batches: map[string]*bookBatch{},
	}
}

// Record folds each delta into its player's pending counters and marks the
// player dirty (RecordStats).
func (b *StatsBook) Record(deltas []StatsDelta) {
	for _, d := range deltas {
		if d.empty() {
			continue
		}
		fields := b.pending[d.UserID]
		if fields == nil {
			fields = map[string]int64{}
			b.pending[d.UserID] = fields
		}
		for field, v := range d.Add {
			fields[field] += v
		}
		for field, v := range d.Max {
			if cur, ok := fields[field]; !ok || v > cur {
				fields[field] = v
			}
		}
		b.dirty[d.UserID] = struct{}{}
	}
}

// Take moves up to max dirty players' pending counters into a batch named
// batchID (TakeStatsBatch): the players with the smallest ids first, so a test
// knows which. Nothing dirty → an empty batch, and none is registered.
func (b *StatsBook) Take(batchID string, max int, nowMs int64) (StatsBatch, error) {
	out := StatsBatch{ID: batchID, CreatedAt: nowMs, Players: map[string]map[string]int64{}}
	if _, exists := b.batches[batchID]; exists {
		return StatsBatch{}, ErrStatsBatchExists
	}
	if max <= 0 || len(b.dirty) == 0 {
		return out, nil
	}
	ids := make([]string, 0, len(b.dirty))
	for id := range b.dirty {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	if len(ids) > max {
		ids = ids[:max]
	}
	moved := map[string]map[string]int64{}
	for _, id := range ids {
		delete(b.dirty, id)
		fields, ok := b.pending[id]
		if !ok {
			continue
		}
		delete(b.pending, id)
		moved[id] = fields
		out.Players[id] = copyFields(fields)
	}
	if len(moved) > 0 {
		b.taken++
		b.batches[batchID] = &bookBatch{createdAt: nowMs, seq: b.taken, players: moved}
	}
	return out, nil
}

// Batches lists every open batch with its counters, oldest first
// (StatsBatches).
func (b *StatsBook) Batches() []StatsBatch {
	type entry struct {
		id string
		*bookBatch
	}
	open := make([]entry, 0, len(b.batches))
	for id, batch := range b.batches {
		open = append(open, entry{id, batch})
	}
	sort.Slice(open, func(i, j int) bool {
		if open[i].createdAt != open[j].createdAt {
			return open[i].createdAt < open[j].createdAt
		}
		return open[i].seq < open[j].seq
	})
	out := make([]StatsBatch, 0, len(open))
	for _, e := range open {
		players := make(map[string]map[string]int64, len(e.players))
		for id, fields := range e.players {
			players[id] = copyFields(fields)
		}
		out = append(out, StatsBatch{ID: e.id, CreatedAt: e.createdAt, Players: players})
	}
	return out
}

// Finish forgets a batch (FinishStatsBatch). Idempotent.
func (b *StatsBook) Finish(batchID string) { delete(b.batches, batchID) }

// Drop forgets a player's pending counters and dirty mark (DropStats).
func (b *StatsBook) Drop(userID string) {
	delete(b.pending, userID)
	delete(b.dirty, userID)
}

// Pending is a copy of a player's pending counters (nil for none) — for tests.
func (b *StatsBook) Pending(userID string) map[string]int64 {
	fields, ok := b.pending[userID]
	if !ok {
		return nil
	}
	return copyFields(fields)
}

// Dirty lists the dirty players, sorted — for tests.
func (b *StatsBook) Dirty() []string {
	out := make([]string, 0, len(b.dirty))
	for id := range b.dirty {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// Reset empties the book (a store that lost its data).
func (b *StatsBook) Reset() {
	b.pending = map[string]map[string]int64{}
	b.dirty = map[string]struct{}{}
	b.batches = map[string]*bookBatch{}
}

func copyFields(in map[string]int64) map[string]int64 {
	out := make(map[string]int64, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
