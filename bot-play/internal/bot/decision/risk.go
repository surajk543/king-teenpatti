package decision

import "math"

// Pressure is how hard the table is leaning on the bot this hand, from what
// it has seen: the raises since it last acted, how big, and what it has
// learned of the opponents still in (state.OpponentBook).
type Pressure struct {
	RaisesFaced        int
	BiggestRaise       int64
	OpponentAggression float64 // 0..1, mean over opponents still in
	OpponentLooseness  float64 // 0..1
	OpponentsBlind     int     // opponents still blind
	Level              float64 // 0..1 overall
}

// NeutralRead is the opponent read taken when there is none: an opponent
// nobody has watched yet is assumed middling on both counts.
const NeutralRead = 0.5

// NewPressure combines this hand's raises (relative to the boot) and the
// opponent reads into a Pressure with its Level.
//
// Level is a weighted sum, clamped to 0..1:
//
//   - 0.45 × the raises faced, saturating: 1 − 0.6^n (one raise 0.40, two
//     0.64, three 0.78) — each raise says someone likes their hand, and the
//     third says less than the first;
//   - 0.25 × the biggest raise against the boot, on a log scale that reaches
//     1 at 64 boots (a raise of 4 boots 0.33, of 16 boots 0.67);
//   - 0.20 × the opponents' aggression — a table of raisers is a table to be
//     careful at;
//   - 0.08 × their looseness — players who stay in make a showdown likely,
//     so it takes a real hand to win the pot;
//   - − 0.05 for each opponent still blind (up to four): a player who has not
//     looked is betting on nothing in particular.
//
// Reads of exactly zero on both counts are state.OpponentBook's "no data"
// (nobody at the table has been watched yet) and are taken as NeutralRead,
// never as "passive and tight". With neutral reads and no raises the Level
// is 0.14.
func NewPressure(raisesFaced int, biggestRaise, boot int64, oppAggression, oppLooseness float64, oppBlind int) Pressure {
	raisesFaced = max(0, raisesFaced)
	oppBlind = max(0, oppBlind)
	biggestRaise = max(0, biggestRaise)
	aggression, looseness := clamp01(oppAggression), clamp01(oppLooseness)
	if oppAggression == 0 && oppLooseness == 0 {
		aggression, looseness = NeutralRead, NeutralRead
	}

	raises := 1 - math.Pow(0.6, float64(raisesFaced))
	size := 0.0
	if boot > 0 && biggestRaise > boot {
		size = clamp01(math.Log2(float64(biggestRaise)/float64(boot)) / 6)
	}
	level := 0.45*raises + 0.25*size + 0.20*aggression + 0.08*looseness - 0.05*float64(min(oppBlind, 4))

	return Pressure{
		RaisesFaced:        raisesFaced,
		BiggestRaise:       biggestRaise,
		OpponentAggression: aggression,
		OpponentLooseness:  looseness,
		OpponentsBlind:     oppBlind,
		Level:              clamp01(level),
	}
}

// RiskShare is the share of a stack a move of amount puts in: 0 for a free
// move, 1 for one that takes everything (or more than there is).
func RiskShare(amount, chips int64) float64 {
	if amount <= 0 {
		return 0
	}
	if chips <= 0 || amount >= chips {
		return 1
	}
	return float64(amount) / float64(chips)
}
