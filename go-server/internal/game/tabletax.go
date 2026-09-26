package game

// The winning tax (owner, 26 Sep 2026: "on Blind table boot amount 10Lakh,
// and variation table boot amount 10 Lakh, whenever any player wins, the …
// table tax will be applied on his winning amount", then "only winner be taxed
// at on whole pot winning amount, others will not be taxed", then "create
// table which stores every player xp and ac to their level, tax will be
// applied").
//
// A table that taxes its winners (TableConfig.WinnerTax — table_configs
// .winner_tax in db mode, a LOBBY_TABLES entry's tax=1 from env) takes a share
// of the WHOLE POT from the ONE winner of each hand — the pot is never split.
// The share is the winner's LEVEL's rate in basis points (player_levels.tax_bps:
// 2000 = 20.00% at Level 1, less at every level up, 400 = 4% for VIP), as of
// the START of that hand: the seat captures its player's rate when they sit
// down (NewPlayer.TaxBps, read with the account) and refreshes it from every
// hand-end settle (SettleResult.TaxBps — the XP that settle just awarded may
// have raised the level), and the hand captures the seat's rate when it is
// dealt (contribution.taxBps), so a rate that changes mid-hand is the next
// hand's. Every way a hand ends with a winner is taxed alike: a show, the last
// player standing, the forced and the pot-limit showdowns, a missile, and the
// pot that goes to the last to leave. Nobody else pays anything.
//
// The winner's seat is credited the pot less the tax, and the tax leaves the
// game: at the hand end the ledger records the win gross and the tax as a
// table_tax row of its own (LedgerRows), so a hand's hand_* rows still sum to
// zero. The table never reads the database for a rate outside those two
// moments.

// MaxTaxBps is 100.00% in basis points, the most any rate can be
// (player_levels.tax_bps CHECK).
const MaxTaxBps = 10000

// TableTax is THE winning tax a hand's winner pays: taxBps basis points of the
// WHOLE POT they take (owner, 26 Sep 2026 — their own contribution included),
// rounded DOWN to a whole chip, so the house never takes a chip more than the
// rate. 0 when the rate is 0 or less or the pot is nothing; a rate above
// MaxTaxBps is read as MaxTaxBps. Computed without the product pot × taxBps,
// which could overflow an int64 on a pot the product would not fit.
//
// The base is decided on the first line and nowhere else: to tax only what
// the winner won from the others, it would be pot minus their contribution.
func TableTax(pot int64, taxBps int) int64 {
	base := pot
	if base <= 0 || taxBps <= 0 {
		return 0
	}
	rate := int64(min(taxBps, MaxTaxBps))
	// base = 10000q + r, so ⌊base × rate / 10000⌋ = q × rate + ⌊r × rate / 10000⌋.
	return base/MaxTaxBps*rate + base%MaxTaxBps*rate/MaxTaxBps
}

// validTaxBps reports whether bps is a rate a level can carry: 0..MaxTaxBps.
func validTaxBps(bps int) bool { return bps >= 0 && bps <= MaxTaxBps }

// youTaxBps is you.taxBps: the rate THIS viewer's seat pays now — the rate
// their share of the hand in progress was dealt with, or between hands (or a
// hand they sit out) the rate their next hand will be dealt with. Present at a
// table that taxes its winners, even when it is 0 for the viewer; nil — the
// key absent — anywhere else, so an untaxed table's snapshot is byte for byte
// what it was.
func (t *Table) youTaxBps(viewer *seat) *int {
	if !t.cfg.WinnerTax || viewer == nil {
		return nil
	}
	bps := viewer.taxBps
	if t.hand != nil {
		if entry := t.hand.contributions[viewer.userID]; entry != nil {
			bps = entry.taxBps
		}
	}
	return &bps
}

// adoptTaxRates refreshes each seat's winning-tax rate from a landed hand-end
// settlement (SettleResult.TaxBps): the rate its player's level carries now,
// after the XP that settle awarded. A seat mid-hand takes it too — the hand in
// progress keeps the rate it was dealt with (contribution.taxBps); the new one
// is its next hand's. A player the result does not name keeps the rate they
// have. Actor only.
func (t *Table) adoptTaxRates(rates map[string]int) {
	for userID, bps := range rates {
		if !validTaxBps(bps) {
			continue
		}
		if s := t.findSeat(userID); s != nil {
			s.taxBps = bps
		}
	}
}
