package game

// What a Teen Patti hand counts for each of its players (Player stats v2,
// stats.go): worked out by endHand while the cards and the rules are still at
// the table, carried with the settlement and recorded once it has committed.

// handStats is the counters the hand-end write resolves, one per player it
// counts for: StatsForEntry's outcome counters for every outcome entry, and —
// the hand being over and its cards still here — at a Teen Patti or variation
// table the hand each of them HELD, as the table counted it (handRules and
// playedHand: a variation's wild cards make the category, and under 5-Card
// the three that played), for everyone the write resolves but a departure;
// at a variation table, the variation the hand was played under, for every
// entry, with the winner's marked. Actor only; t.hand is still the ended hand.
func (t *Table) handStats(entries []SettleEntry) []HandStats {
	h := t.hand
	if h == nil || len(entries) == 0 {
		return nil
	}
	bucket := StatsBucketOf(t.cfg.Category)
	rules := h.variation.rules()
	out := make([]HandStats, 0, len(entries))
	for _, entry := range entries {
		stats, ok := StatsForEntry(entry, bucket)
		if !ok {
			continue
		}
		if bucket.CountsHeld() && !entry.LeftMidHand {
			if held, ok := t.heldHand(rules, h.contributions[entry.UserID]); ok {
				stats.Held, stats.HasHeld = held, true
			}
		}
		// A leaver's catch-up row counts only what their own leave would
		// have (Table.checkpoint): no held hand, no variation.
		if bucket == StatsVariation && rules.Variation != "" && (!entry.LeftMidHand || entry.IsWinner) {
			stats.Variation = rules.Variation
			stats.VariationWon = entry.IsWinner
		}
		if !stats.Empty() {
			out = append(out, stats)
		}
	}
	return out
}

// heldHand is the category of the hand a player held at the end of this hand,
// scored the one way every comparison scores it (playedHand under rules). The
// seat is used while the player still has it — it carries their 5-Card
// choice; a player who packed and has since left the table is scored from the
// cards the hand recorded for them, and so, under 5-Card, by the first three
// they were dealt, which is what an unchosen hand plays. ok is false when
// there is nothing to score. It never panics: a hand the evaluator cannot
// take is simply not counted, because a statistic must never cost a hand its
// ending.
func (t *Table) heldHand(rules VariationRules, entry *contribution) (held HandCategory, ok bool) {
	if entry == nil || len(entry.cards) < BaseCardsPerPlayer {
		return 0, false
	}
	defer func() {
		if recover() != nil {
			held, ok = 0, false
		}
	}()
	s := &seat{cards: entry.cards}
	if live := t.findSeat(entry.userID); live != nil && len(live.cards) == len(entry.cards) {
		s = live
	}
	if len(t.playedCards(s)) != BaseCardsPerPlayer {
		return 0, false
	}
	return t.playedHand(rules, s).Category, true
}
