package decision

// Where a counted hand stands under a variation's rules.
//
// Every variation hand is scored by the SERVER (you.hand): its category, its
// name, and the three cards it counted — the wild ones replaced by the cards
// they stood for (playsAs), or the three chosen under 5-Card (best). Those
// three are an ordinary classic hand, so this package can place them among
// all 22,100 with Percentile. What it cannot do without re-implementing the
// wild-card rules — which it must not: the server's evaluation is the only
// one — is say how common that hand is at a table where cards are wild. A
// Pair is the bottom quarter under AK47, where one hand in four is a Trail,
// and no hand at all is weaker than a Pair under Lowest Joker.
//
// So each variation carries a fixed table: the share of hands, under that
// variation's rules, whose counted three fall below each of the classic
// percentiles in variationKnots. A hand's Strength is its classic percentile
// read through that table (linear between knots).
//
// The tables were estimated OFFLINE, once (27 Sep 2026), by enumerating every
// deal against a scratch copy of the server's variation.go that never entered
// this module: all 22,100 hands for AK47, Lowest Joker and Highest Joker;
// every hand against every possible turned-up card for Joker and Hukam (the
// wild rank or suit averaged over the 49 cards that could be turned up); and
// every one of the 2,598,960 five-card hands for FIVE_CARD, best three of
// each. They are an approximation on purpose: a linear read between 25 knots,
// and Joker and Hukam averaged over the turned-up card the bot is not told
// about here. Evaluate lowers its Confidence on these tables accordingly.
//
// The category shares they encode (High Card … Trail):
//
//	classic        0.744 0.169 0.050 0.033 0.002 0.002
//	AK47           0.220 0.295 0.087 0.104 0.032 0.262
//	JOKER          0.607 0.230 0.066 0.063 0.014 0.020
//	HUKAM          0.316 0.251 0.131 0.100 0.045 0.157
//	LOWEST_JOKER   0.000 0.356 0.119 0.265 0.088 0.172
//	HIGHEST_JOKER  0.000 0.358 0.120 0.263 0.088 0.172
//	FIVE_CARD      0.196 0.269 0.273 0.219 0.021 0.023
//
// The tables are functions returning fixed values: nothing can write them.

// knotCount is how many classic percentiles each table is read at.
const knotCount = 25

// variationTable is, knot for knot, the share of a variation's hands whose
// counted three rank below that classic percentile.
type variationTable [knotCount]float64

// variationKnots are the classic percentiles the tables are read at: 0.1
// steps through the high cards, then each category's first hand (Pair
// 0.743891, Color 0.913303, Sequence 0.962896, Pure Sequence 0.995475, Trail
// 0.997647) with points inside the pairs, colours, sequences and trails.
func variationKnots() variationTable {
	return variationTable{
		0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7,
		0.743891, 0.78, 0.82, 0.86, 0.89,
		0.913303, 0.93, 0.945,
		0.962896, 0.975, 0.985,
		0.995475,
		0.997647, 0.9988, 0.9994, 0.9998, 1.0,
	}
}

// variationTableFor is the offline estimate for a wire variation value; ok is
// false for MUFLIS (no card is wild: it is the classic percentile turned the
// other way up, exactly) and for any value this build does not know.
func variationTableFor(variation string) (t variationTable, ok bool) {
	switch variation {
	case "AK47":
		return variationTable{0.0000, 0.0380, 0.0869, 0.1439, 0.2009, 0.2199, 0.2199, 0.2199, 0.2199, 0.2373, 0.2807, 0.4024, 0.5153, 0.5153, 0.5225, 0.5300, 0.6024, 0.6197, 0.6686, 0.7061, 0.7385, 0.8434, 0.9484, 0.9747, 1.0000}, true
	case "JOKER":
		return variationTable{0.0000, 0.0820, 0.1640, 0.2449, 0.3258, 0.4078, 0.4898, 0.5718, 0.6073, 0.6394, 0.6843, 0.7423, 0.7960, 0.8369, 0.8505, 0.8628, 0.9032, 0.9223, 0.9429, 0.9664, 0.9804, 0.9894, 0.9954, 0.9984, 1.0000}, true
	case "HUKAM":
		return variationTable{0.0000, 0.0426, 0.0853, 0.1273, 0.1694, 0.2121, 0.2547, 0.2973, 0.3158, 0.3300, 0.3668, 0.4346, 0.5090, 0.5664, 0.5797, 0.5916, 0.6975, 0.7263, 0.7586, 0.7978, 0.8427, 0.9104, 0.9556, 0.9782, 1.0000}, true
	case "LOWEST_JOKER":
		return variationTable{0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0087, 0.0760, 0.1890, 0.3562, 0.3562, 0.3562, 0.4749, 0.5010, 0.5966, 0.7399, 0.8282, 0.8608, 0.9260, 0.9716, 1.0000}, true
	case "HIGHEST_JOKER":
		return variationTable{0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0999, 0.2585, 0.3453, 0.3584, 0.3584, 0.3584, 0.4778, 0.6103, 0.6972, 0.7406, 0.8282, 0.9520, 0.9911, 0.9976, 1.0000}, true
	case "FIVE_CARD":
		return variationTable{0.0000, 0.0007, 0.0081, 0.0248, 0.0464, 0.0718, 0.1164, 0.1489, 0.1955, 0.2388, 0.3008, 0.3679, 0.4175, 0.4647, 0.5479, 0.6313, 0.7374, 0.8056, 0.8774, 0.9565, 0.9772, 0.9877, 0.9947, 0.9982, 1.0000}, true
	}
	return variationTable{}, false
}

// variationConfidence is how far a Strength under a variation can be
// trusted: the wild-card tables are averages (Joker and Hukam over the
// turned-up card, every table over the hands inside a category), FIVE_CARD's
// is exact bar the linear read, Muflis's is exact. A variation this build
// does not know gets a low 0.4.
func variationConfidence(variation string) float64 {
	switch variation {
	case "MUFLIS":
		return 0.95
	case "FIVE_CARD":
		return 0.9
	case "JOKER":
		return 0.8
	case "AK47", "HUKAM", "LOWEST_JOKER", "HIGHEST_JOKER":
		return 0.7
	}
	return 0.4
}

// classicCategoryStarts are the classic percentiles at which each category
// begins (High Card … Trail), and 1 at the top: 16,440 high cards, 3,744
// pairs, 1,096 colours, 720 sequences, 48 pure sequences, 52 trails.
func classicCategoryStarts() [7]float64 {
	return [7]float64{0, 0.743891, 0.913303, 0.962896, 0.995475, 0.997647, 1}
}

// readThrough reads a classic percentile through a variation table.
func readThrough(t variationTable, pct float64) float64 {
	k := variationKnots()
	if pct <= k[0] {
		return t[0]
	}
	for i := 1; i < knotCount; i++ {
		if pct <= k[i] {
			f := (pct - k[i-1]) / (k[i] - k[i-1])
			return t[i-1] + f*(t[i]-t[i-1])
		}
	}
	return t[knotCount-1]
}

// categoryMidpoint is the classic percentile in the middle of a category —
// the best guess at a hand known only by its category.
func categoryMidpoint(category int) float64 {
	category = max(0, min(5, category))
	starts := classicCategoryStarts()
	return (starts[category] + starts[category+1]) / 2
}
