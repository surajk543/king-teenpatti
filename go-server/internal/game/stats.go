package game

// Player stats v2 (owner, 27 Sep 2026): "maintain stats acc to only three
// category: teenpatti variation and poker … in teenpatti and variation
// category also store … how many times he got trail, pair, highcard, pure
// sequence, sequence … how many muflis, ak47, other gameplay type he played.
// store this info in redis, then async … group commit".
//
// This file is what ONE finished hand (or one departure) counts for one player
// — the rules, and nothing about where the counts go. A table computes a
// HandStats per player at the moment the hand's money is written, carries them
// with the write (SettleRequest.Stats), and hands them to its StatsRecorder
// only once that write has COMMITTED: the recorder (internal/stats) adds them
// to the player's pending counters in the live store, and a flusher moves
// those into PostgreSQL in batches (player_stats, player_variation_stats). The
// ledger's transactions write money and nothing else.

// StatsBucket is one of the three buckets a hand counts in: every hand counts
// in exactly one, the bucket of the table it was played at. The values are
// player_stats.category and the prefix of every pending counter in the live
// store; the wire names them teenPatti, variation and poker.
type StatsBucket string

const (
	// StatsTeenPatti is every seen and blind table, public or private.
	StatsTeenPatti StatsBucket = "TEEN_PATTI"
	// StatsVariation is every variation table.
	StatsVariation StatsBucket = "VARIATION"
	// StatsPoker is the four poker categories.
	StatsPoker StatsBucket = "POKER"
)

// StatsBuckets are the three buckets in the order the wire shows them.
var StatsBuckets = []StatsBucket{StatsTeenPatti, StatsVariation, StatsPoker}

// StatsBucketOf is the bucket a hand at a table of this category counts in:
// POKER for the four poker categories, VARIATION for a variation table, and
// TEEN_PATTI for seen, blind and anything else (an unknown category plays as
// seen — NormalizeCategory).
func StatsBucketOf(c Category) StatsBucket {
	switch {
	case c.IsPoker():
		return StatsPoker
	case c == CategoryVariation:
		return StatsVariation
	default:
		return StatsTeenPatti
	}
}

// CountsHeld reports whether a hand in this bucket counts the hand each
// player HELD (trail … high card): Teen Patti and Variation do, poker — whose
// hands are not ranked on the Teen Patti ladder — does not.
func (b StatsBucket) CountsHeld() bool {
	return b == StatsTeenPatti || b == StatsVariation
}

// HandStats is what one resolved hand counts for one player. Played, Won, Lost
// and Left are each 0 or 1; the rest say what the hand was.
type HandStats struct {
	UserID string
	Bucket StatsBucket
	// Played is requirement 16's "played": the player made a voluntary bet
	// (a chaal, raise or show; at poker any chips beyond the forced ones).
	Played int64
	// Won, Lost and Left: the hand's outcome for this player. A departure is
	// Left and never Lost; a push (3-Card Poker's tie against the house) is
	// neither won nor lost.
	Won  int64
	Lost int64
	Left int64
	// Winnings is the pot (or, with several winners, the share) the player
	// took: total_winnings adds it and biggest_pot keeps the largest. 0 unless
	// Won.
	Winnings int64
	// Held is the hand the player held, as the table counted it — a
	// variation's wild cards make the category (a pair and a joker IS a
	// trail), and under 5-Card it is the three that played. Meaningful only
	// when HasHeld: Teen Patti and Variation, for everyone the hand-end write
	// resolves, packed or not, seen or blind; never for a departure (they did
	// not finish the hand) and never at poker.
	Held    HandCategory
	HasHeld bool
	// Variation is the variation the hand was played under — "" at every
	// table but a variation one, and there when the hand ended before one was
	// chosen. VariationWon is whether this player won it.
	Variation    Variation
	VariationWon bool
}

// Empty reports whether the hand counts nothing at all for this player — a
// resolution that moves no counter (a push by a player who never bet, at a
// table with no held hand to count).
func (h HandStats) Empty() bool {
	return h.Played == 0 && h.Won == 0 && h.Lost == 0 && h.Left == 0 && h.Winnings == 0 &&
		!h.HasHeld && h.Variation == ""
}

// StatsForEntry is the counters one ledger entry resolves — exactly the rules
// the checkpoints applied when they wrote player_stats themselves (Friends V1):
// only an Outcome row counts (a pack is money only; the hand-end row resolves
// the packer); Played is DidChaal; Won is IsWinner; Lost is neither a win, a
// departure nor a push; Left is LeftMidHand; Winnings is the entry's Pot when
// it won. ok is false for a row that is not an outcome. The held hand and the
// variation are the table's to add: an entry knows neither.
func StatsForEntry(entry SettleEntry, bucket StatsBucket) (HandStats, bool) {
	if !entry.Outcome {
		return HandStats{}, false
	}
	h := HandStats{UserID: entry.UserID, Bucket: bucket}
	h.Played = statsBit(entry.DidChaal)
	h.Won = statsBit(entry.IsWinner)
	h.Lost = statsBit(!entry.IsWinner && !entry.LeftMidHand && !entry.Push)
	h.Left = statsBit(entry.LeftMidHand)
	if entry.IsWinner {
		h.Winnings = entry.Pot
	}
	return h, true
}

func statsBit(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

// StatsRecorder receives the counters of writes that have COMMITTED: a hand
// end's (SettleRequest.Stats, once its Settle returned without error — on the
// first attempt or a retry, never on duplicate_action, which is a replay) and
// a departure's (after its leave checkpoint). It is called on a room's actor,
// or on the clock's goroutine for a settlement retried after the room was
// destroyed, so it must be safe from any goroutine, must not block and must
// never call back into a room. Production: stats.Recorder.Record, which queues
// the counters for the live store. nil records nothing.
type StatsRecorder func(stats []HandStats)
