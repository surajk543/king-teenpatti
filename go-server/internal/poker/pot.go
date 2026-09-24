package poker

import (
	"sort"
)

// Pot is one pot at showdown: an amount and the seats that can win it. The
// main pot is every seat that put chips in; a side pot forms whenever a
// player is all-in for less than the others kept betting, and only the seats
// that matched that level are in it.
type Pot struct {
	Amount   int64 `json:"amount"`
	Eligible []int `json:"eligible"` // seat indices, ascending
}

// SidePots builds the pots from every seat's total contribution this hand.
// inHand marks the seats still in (not folded, not gone); a folded seat's
// chips stay in the pots it reached but it can win none of them.
//
// Levels are the distinct contribution amounts, ascending; the pot at each
// level holds (level − previous level) from every seat that contributed at
// least that much, and is open to the in-hand seats among them. Consecutive
// pots open to exactly the same seats are merged, so a hand with no all-in
// has one pot. A pot nobody in hand reached (everyone at that level folded
// or left) is DEAD MONEY: it is folded into the pot before it — the highest
// pot a player still in can win — or, when there is none (the players still
// in put nothing in), opened to every seat still in. A folded or departed
// player's chips never come back to them, even the part nobody matched
// (CLAUDE.md §6.1: leaving mid-hand = pack, the stake stays); only a player
// STILL IN gets back an excess nobody could call, as the single-eligible top
// pot. Every chip of contrib is in exactly one pot.
func SidePots(contrib map[int]int64, inHand map[int]bool) []Pot {
	var levels []int64
	seen := map[int64]bool{}
	for _, c := range contrib {
		if c > 0 && !seen[c] {
			seen[c] = true
			levels = append(levels, c)
		}
	}
	sort.Slice(levels, func(i, j int) bool { return levels[i] < levels[j] })

	var pots []Pot
	var prev int64
	for _, level := range levels {
		pot := Pot{}
		for seat, c := range contrib {
			if c >= level {
				pot.Amount += level - prev
				if inHand[seat] {
					pot.Eligible = append(pot.Eligible, seat)
				}
			}
		}
		sort.Ints(pot.Eligible)
		prev = level
		if pot.Amount == 0 {
			continue
		}
		if n := len(pots); n > 0 && sameSeats(pots[n-1].Eligible, pot.Eligible) {
			pots[n-1].Amount += pot.Amount
			continue
		}
		pots = append(pots, pot)
	}
	// Orphaned pots (no eligible seat) go to their neighbour.
	for i := 0; i < len(pots); i++ {
		if len(pots[i].Eligible) > 0 {
			continue
		}
		switch {
		case i > 0:
			pots[i-1].Amount += pots[i].Amount
		case i+1 < len(pots):
			pots[i+1].Amount += pots[i].Amount
		default:
			// No pot anybody in hand reached: every chip was put in by
			// players who have folded or left, while the one(s) still in
			// put in nothing (the blinds walking out on the first player
			// to act). The chips are dead money and go to whoever is
			// still in — never to nobody, which destroyed them. With
			// nobody in hand at all it stays unclaimed for the caller to
			// refund.
			for seat, in := range inHand {
				if in {
					pots[i].Eligible = append(pots[i].Eligible, seat)
				}
			}
			sort.Ints(pots[i].Eligible)
			continue
		}
		pots = append(pots[:i], pots[i+1:]...)
		i--
	}
	return pots
}

func sameSeats(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// Payout is one seat's share of one pot.
type Payout struct {
	Seat   int
	Amount int64
	Pot    int // index into the pots
}

// Award pays every pot to the best hand(s) among its eligible seats. An exact
// tie splits the pot evenly; chips that do not divide go one each to the tied
// seats nearest the dealer's left (clockwise from the button), which is the
// rule at every card room. A pot whose eligible seats have no hand (never at a
// showdown; defensively) is paid to its eligible seats in the same way as a
// tie. Returns the payouts in pot order, and the total each seat took.
func Award(pots []Pot, hands map[int]Hand, button, seats int) ([]Payout, map[int]int64) {
	var payouts []Payout
	totals := map[int]int64{}
	for i, pot := range pots {
		var winners []int
		var best Hand
		for _, seat := range pot.Eligible {
			h, ok := hands[seat]
			if !ok {
				continue
			}
			switch {
			case len(winners) == 0:
				winners, best = []int{seat}, h
			default:
				if diff := Compare(h, best); diff > 0 {
					winners, best = []int{seat}, h
				} else if diff == 0 {
					winners = append(winners, seat)
				}
			}
		}
		if len(winners) == 0 {
			winners = append(winners, pot.Eligible...)
		}
		if len(winners) == 0 {
			continue
		}
		// Clockwise from the button: the seat just after it is first, the
		// button itself last.
		after := func(seat int) int {
			if d := distance(button, seat, seats); d > 0 {
				return d
			}
			return seats
		}
		sort.Slice(winners, func(a, b int) bool { return after(winners[a]) < after(winners[b]) })
		share := pot.Amount / int64(len(winners))
		odd := pot.Amount - share*int64(len(winners))
		for _, seat := range winners {
			amount := share
			if odd > 0 {
				amount++
				odd--
			}
			if amount == 0 {
				continue
			}
			payouts = append(payouts, Payout{Seat: seat, Amount: amount, Pot: i})
			totals[seat] += amount
		}
	}
	return payouts, totals
}

// distance is how many seats clockwise from `from` to `to` (1 for the next
// seat; 0 for the same seat; seats wraps).
func distance(from, to, seats int) int {
	if seats <= 0 {
		return 0
	}
	return ((to-from)%seats + seats) % seats
}
