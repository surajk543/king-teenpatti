package game

// Port of server/src/game/handRank.js.

// HandCategory ranks Teen Patti hand types, low to high. The number is the
// primary comparison key, so a bigger category always beats a smaller one.
type HandCategory int

const (
	HighCard     HandCategory = 0
	Pair         HandCategory = 1
	Color        HandCategory = 2 // flush: three of a suit that is not a run
	Sequence     HandCategory = 3 // run: three consecutive ranks, mixed suits
	PureSequence HandCategory = 4 // straight flush
	Trail        HandCategory = 5 // trio / set: three of a kind
)

// CategoryNames are the ENGLISH wire names (handName in reveals). Flutter
// shows them untranslated — do not localise here.
var CategoryNames = map[HandCategory]string{
	HighCard:     "High Card",
	Pair:         "Pair",
	Color:        "Color",
	Sequence:     "Sequence",
	PureSequence: "Pure Sequence",
	Trail:        "Trail",
}

// String returns the wire name.
func (c HandCategory) String() string { return CategoryNames[c] }

// EvaluatedHand is the comparable descriptor Evaluate produces.
//
// Score is compared element by element: [category, ...tiebreakers]. Lengths
// differ by category (trail: 1 tiebreak; sequence: 1; pair: 2; color / high
// card: 3) but never mix because the category always decides first.
type EvaluatedHand struct {
	Category HandCategory
	Name     string   // CategoryNames[Category]
	Score    []int    // [category, tiebreak...]
	Cards    []string // wire codes of the input, same order
}

// EvaluateOptions carries the one variant switch. AceLowIsLowest=false (the
// default, and what the Table uses) is standard Teen Patti: A-2-3 ranks just
// below A-K-Q and above K-Q-J. With it true, A-2-3 is the weakest run.
type EvaluateOptions struct {
	AceLowIsLowest bool
}

// Evaluate scores a 3-card hand (handRank.js evaluate). Panics (Node throws)
// on len(cards) != 3 — a hand with any other size is a programming error.
//
// Algorithm, in this order:
//  1. ranks sorted descending [high, mid, low]; sameSuit = all three suits equal;
//  2. high==mid==low → Trail, tiebreak [high];
//  3. isRun (A-2-3 wheel, or high-mid==1 && mid-low==1) → PureSequence if
//     sameSuit else Sequence, tiebreak [runStrength] where runStrength is on a
//     DOUBLED scale: A-K-Q = 28 > A-2-3 = 27 > K-Q-J = 26 > … > 4-3-2 = 8
//     (A-2-3 = 5 when AceLowIsLowest); normal runs score 2*high;
//  4. sameSuit → Color, tiebreak [high, mid, low];
//  5. high==mid || mid==low → Pair, tiebreak [pairRank=mid, kicker];
//  6. else HighCard, tiebreak [high, mid, low].
//
// Suits never break ties (CLAUDE.md §6.3).
func Evaluate(cards []Card, opts EvaluateOptions) EvaluatedHand {
	panic("not ported: game.Evaluate")
}

// Compare returns > 0 when a wins, < 0 when b wins, 0 on an exact tie.
// Missing score elements compare as 0 (Node: `a.score[i] ?? 0`).
func Compare(a, b EvaluatedHand) int {
	panic("not ported: game.Compare")
}

// Contender is one entrant to PickWinner: Key identifies the player (userId),
// Cards their hand.
type Contender struct {
	Key   string
	Cards []Card
}

// WinnerPick is PickWinner's answer.
type WinnerPick struct {
	Key    string
	Hand   EvaluatedHand
	WasTie bool // more than one contender had the best score
}

// PickWinner chooses the single winner of a showdown (handRank.js pickWinner).
// Exact ties are broken by tieBreakOrder — a list of keys, EARLIEST wins;
// keys absent from it sort last. Returns nil for no contenders.
//
// NOTE: table.js re-implements this tie loop inline in _resolveShowdown
// (preference = seats sorted by distance from the dealer's left, with the
// show-payer moved to the very end). Keep both consistent; the Table port may
// call PickWinner with that preference list instead of duplicating it, as long
// as the result is identical.
func PickWinner(contenders []Contender, tieBreakOrder []string, opts EvaluateOptions) *WinnerPick {
	panic("not ported: game.PickWinner")
}
