package poker

import (
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// 3-Card Poker against the house (POKER_PLAN.md §5). Every participant antes
// (the boot) at the deal and is dealt three cards, as is the dealer, face
// down. In turn each player PLAYS — a second bet equal to the ante — or
// FOLDS, the ante lost. Then the dealer's hand is turned up:
//
//   - the dealer QUALIFIES with queen-high or better. Not qualified: every
//     player still in has their play bet returned and their ante paid 1:1,
//     whatever they hold;
//   - qualified: each player's hand against the dealer's. Win → ante and play
//     both paid 1:1; lose → both taken; tie → both returned (a push).
//
// The house has no wallet: chips a player wins come into the economy and
// chips they lose leave it, exactly as a reward or a picture purchase moves
// them, and the per-hand zero-sum audit exempts these hands by their
// chip_ledger.variant (POKER_PLAN.md §6). No ante bonus and no pair-plus bet
// — documented, not built.

// resolveDealer ends a 3-Card Poker hand once every player has decided.
func (t *Table) resolveDealer() {
	h := t.hand
	if h == nil {
		return
	}
	dealerHand := Evaluate3(h.dealerCards)
	h.dealerHand = &dealerHand
	qualified := DealerQualifies(dealerHand)
	dealer := &DealerReveal{Cards: game.CardCodes(h.dealerCards), HandName: dealerHand.Name, Category: dealerHand.Category, Qualified: qualified}
	ante := t.ante()

	reveals := []Reveal{}
	winners := map[string]bool{}
	pots := []PotResult{}
	for _, s := range t.seatsInHand() {
		entry := h.contributions[s.userID]
		if entry == nil {
			continue
		}
		player := Evaluate3(s.cards)
		var back int64
		outcome := "lose"
		playBet := entry.contributed - ante // the play bet, or 0 on an all-in ante
		if playBet < 0 {
			playBet = 0
		}
		switch {
		case !qualified:
			// Ante pays even money; the play bet is returned.
			back = ante*2 + playBet
			outcome = "win"
		default:
			diff := Compare(player, dealerHand)
			switch {
			case diff > 0:
				back = entry.contributed * 2
				outcome = "win"
			case diff == 0:
				back = entry.contributed
				outcome = "push"
			default:
				back = 0
			}
		}
		if back > 0 {
			s.chips += back
			entry.chips = s.chips
			entry.won = back
			h.pot -= min(back, h.pot)
		}
		if outcome == "win" || outcome == "push" {
			winners[s.userID] = true
			s.status = game.SeatWon
		} else {
			s.status = game.SeatLost
		}
		entry.status = s.status
		reveals = append(reveals, Reveal{UserID: s.userID, SeatIndex: s.seatIndex, Cards: game.CardCodes(s.cards), Best: player.Best, HandName: player.Name, Category: player.Category, Won: back, Outcome: outcome})
		pots = append(pots, PotResult{Amount: entry.contributed, Eligible: []int{s.seatIndex}, Winners: potWinnersFor(s, back, player.Name)})
	}
	// Folded players: their ante is the house's.
	t.listener.OnShowdown(t.view, ShowdownEvent{Reveals: reveals, Community: []string{}, Dealer: dealer, Reason: WinDealer})
	t.settle(WinDealer, winners, pots, reveals, dealer)
}

func potWinnersFor(s *seat, back int64, handName string) []PotWinner {
	if back <= 0 {
		return []PotWinner{}
	}
	return []PotWinner{{UserID: s.userID, SeatIndex: s.seatIndex, Amount: back, HandName: handName}}
}
