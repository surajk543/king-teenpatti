// Package stats is the players' statistics pipeline (Player stats v2, owner
// 27 Sep 2026: "maintain stats acc to only three category: teenpatti
// variation and poker … store this info in redis, then async you can update
// by group commit so that u don't call postgres db multiple times"):
//
//	a table's write commits ─► game.StatsRecorder ─► Recorder (a queue, one goroutine)
//	    ─► live.Store.RecordStats   one round trip per hand, into kt:stats:<userId>
//	Flusher, every STATS_FLUSH_MS:
//	    live.Store.TakeStatsBatch   up to STATS_FLUSH_BATCH players, moved out atomically under one batch id
//	    db.StatsStore.Flush         ONE PostgreSQL transaction for the whole batch, receipt in stats_flushes
//	    live.Store.FinishStatsBatch only after the COMMIT
//
// The money never passes through here: the ledger's transactions write money
// only, and a table hands its counters over once they have committed. Losing
// the live store loses the counters not yet flushed (at most one interval's),
// exactly as losing it loses the hands in play (CLAUDE.md §5.1).
package stats

import (
	"strings"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// The fields of a pending hash (kt:stats:<userId>). A bucket's counter is
// "<BUCKET>:<column>" — the player_stats column it is added to, so
// "TEEN_PATTI:hands_played", "VARIATION:trail", "POKER:biggest_pot" — and a
// variation's is "<BUCKET>:v:<VARIATION>:played" or "…:won", so
// "VARIATION:v:MUFLIS:played". Every field is summed but biggest_pot, which
// keeps the larger value.
const (
	colHandsPlayed   = "hands_played"
	colHandsWon      = "hands_won"
	colHandsLost     = "hands_lost"
	colHandsLeft     = "hands_left"
	colTotalWinnings = "total_winnings"
	colBiggestPot    = "biggest_pot"
	colTrail         = "trail"
	colPureSequence  = "pure_sequence"
	colSequence      = "sequence"
	colColor         = "color"
	colPair          = "pair"
	colHighCard      = "high_card"

	variationInfix = "v:"
	variationWon   = "won"
	variationPlays = "played"
)

// heldColumns names the column of each hand held.
var heldColumns = map[game.HandCategory]string{
	game.Trail:        colTrail,
	game.PureSequence: colPureSequence,
	game.Sequence:     colSequence,
	game.Color:        colColor,
	game.Pair:         colPair,
	game.HighCard:     colHighCard,
}

// Fields is one hand's counters for one player as the live store folds them
// in: Add for the sums, Max for the biggest pot. A counter that did not move
// is left out, so a hand writes only the fields it changes.
func Fields(h game.HandStats) live.StatsDelta {
	d := live.StatsDelta{UserID: h.UserID, Add: map[string]int64{}, Max: map[string]int64{}}
	prefix := string(h.Bucket) + ":"
	add := func(column string, v int64) {
		if v != 0 {
			d.Add[prefix+column] += v
		}
	}
	add(colHandsPlayed, h.Played)
	add(colHandsWon, h.Won)
	add(colHandsLost, h.Lost)
	add(colHandsLeft, h.Left)
	add(colTotalWinnings, h.Winnings)
	if h.Winnings > 0 {
		d.Max[prefix+colBiggestPot] = h.Winnings
	}
	if h.HasHeld {
		if column, ok := heldColumns[h.Held]; ok {
			add(column, 1)
		}
	}
	if h.Variation != "" {
		key := prefix + variationInfix + string(h.Variation) + ":"
		d.Add[key+variationPlays]++
		if h.VariationWon {
			d.Add[key+variationWon]++
		}
	}
	return d
}

// Deltas is Fields for every hand of a write, in order, the empty ones left
// out — what one call of RecordStats carries.
func Deltas(stats []game.HandStats) []live.StatsDelta {
	out := make([]live.StatsDelta, 0, len(stats))
	for _, h := range stats {
		if h.UserID == "" {
			continue
		}
		if d := Fields(h); len(d.Add)+len(d.Max) > 0 {
			out = append(out, d)
		}
	}
	return out
}

// Decode reads one player's counters as a batch took them back into what the
// flush adds to PostgreSQL. A field this build does not know — a bucket other
// than the three, a column that is not one — is left out and counted in
// unknown (the flush goes on: a statistic is never worth stopping the others
// for).
func Decode(userID string, fields map[string]int64) (delta *db.StatsDelta, unknown int) {
	delta = db.NewStatsDelta(userID)
	for field, v := range fields {
		bucket, rest, ok := strings.Cut(field, ":")
		if !ok || !knownBucket(game.StatsBucket(bucket)) {
			unknown++
			continue
		}
		if body, isVariation := strings.CutPrefix(rest, variationInfix); isVariation {
			cut := strings.LastIndexByte(body, ':')
			if cut <= 0 {
				unknown++
				continue
			}
			variation, kind := body[:cut], body[cut+1:]
			switch kind {
			case variationPlays:
				delta.Tally(variation).HandsPlayed += v
			case variationWon:
				delta.Tally(variation).HandsWon += v
			default:
				unknown++
			}
			continue
		}
		fold, ok := columnFolds[rest]
		if !ok {
			unknown++
			continue
		}
		fold(delta.Line(game.StatsBucket(bucket)), v)
	}
	return delta, unknown
}

// columnFolds adds a pending field's value to the column it names: a sum for
// every counter, the larger for the biggest pot.
var columnFolds = map[string]func(line *db.StatsLine, v int64){
	colHandsPlayed:   func(l *db.StatsLine, v int64) { l.HandsPlayed += v },
	colHandsWon:      func(l *db.StatsLine, v int64) { l.HandsWon += v },
	colHandsLost:     func(l *db.StatsLine, v int64) { l.HandsLost += v },
	colHandsLeft:     func(l *db.StatsLine, v int64) { l.HandsLeft += v },
	colTotalWinnings: func(l *db.StatsLine, v int64) { l.TotalWinnings += v },
	colBiggestPot:    func(l *db.StatsLine, v int64) { l.BiggestPot = max(l.BiggestPot, v) },
	colTrail:         func(l *db.StatsLine, v int64) { l.Hands.Trail += v },
	colPureSequence:  func(l *db.StatsLine, v int64) { l.Hands.PureSequence += v },
	colSequence:      func(l *db.StatsLine, v int64) { l.Hands.Sequence += v },
	colColor:         func(l *db.StatsLine, v int64) { l.Hands.Color += v },
	colPair:          func(l *db.StatsLine, v int64) { l.Hands.Pair += v },
	colHighCard:      func(l *db.StatsLine, v int64) { l.Hands.HighCard += v },
}

func knownBucket(b game.StatsBucket) bool {
	for _, known := range game.StatsBuckets {
		if b == known {
			return true
		}
	}
	return false
}
