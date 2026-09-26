package game

// The winning tax (owner, 26 Sep 2026: "on Blind table boot amount 10Lakh,
// and variation table boot amount 10 Lakh, whenever any player wins, the …
// table tax will be applied on his winning amount", then "only winner be taxed
// at on whole pot winning amount, others will not be taxed", then "create
// table which stores every player xp and ac to their level, tax will be
// applied").
//
// A table that taxes its winners (TableConfig.WinnerTax — table_configs
// .winner_tax in db mode, a LOBBY_TABLES entry's tax=1 from env; every public
// seen, blind and variation table since 27 Sep 2026, owner: "Apply this tax
// rule on all the tables, blind, seen, variation") takes a share of what the
// ONE winner of each hand WON — the pot less the winner's own contribution to
// it (WinnerWinnings; owner, 27 Sep 2026: "tax will be on total pot amount -
// amount player contributed, so the tax will be on winning amount") — and only
// when those winnings come to TableConfig.WinnerTaxMinWinnings or more (50
// Lakh by default: "no tax for winning amount less than 50 Lakh").
// The pot is never split. The share is the winner's RATE in basis points: the
// lowest of their level's (player_levels.tax_bps — 2000 = 20.00% at Level 1,
// less at every level up to 600 = 6.00% at Level 50) and those of the badges
// they hold (badges.tax_bps — Regular 20%, everyone's by default; the Royal
// badges 0%;
// db.Standing.TaxBps), as of the START of that hand: the seat captures its
// player's rate when they sit down (NewPlayer.TaxBps, read with the account)
// and refreshes it from every hand-end settle (SettleResult.TaxBps — the XP
// that settle just awarded may have raised the level, and a badge may have run
// out), and the hand captures the seat's rate when it is dealt
// (contribution.taxBps), so a rate that changes mid-hand is the next hand's.
// Every way a hand ends with a winner is taxed alike: a show, the last player
// standing, the forced and the pot-limit showdowns, a missile, and the pot that
// goes to the last to leave. Nobody else pays anything.
//
// The winner's seat is credited the pot less the tax, and the tax leaves the
// game: at the hand end the ledger records the win gross and the tax as a
// table_tax row of its own (LedgerRows), so a hand's hand_* rows still sum to
// zero. The table never reads the database for a rate outside those two
// moments.

// MaxTaxBps is 100.00% in basis points, the most any rate can be
// (player_levels.tax_bps CHECK).
const MaxTaxBps = 10000

// WinnerWinnings is what a hand's winner WON: the pot they take less what
// they put into it themselves (owner, 27 Sep 2026: "tax will be on total pot
// amount - amount player contributed, so the tax will be on winning amount").
// Never below 0 — a pot that holds only the winner's own chips (everybody
// else left before putting any in) is no winnings at all.
func WinnerWinnings(pot, contributed int64) int64 {
	if won := pot - contributed; won > 0 {
		return won
	}
	return 0
}

// TableTax is THE winning tax a hand's winner pays: taxBps basis points of
// their winnings (WinnerWinnings — the base the hand end hands it), rounded
// DOWN to a whole chip, so the house never takes a chip more than the rate. 0
// when the rate is 0 or less or there are no winnings; a rate above MaxTaxBps
// is read as MaxTaxBps. Computed without the product winnings × taxBps, which
// could overflow an int64 on winnings the product would not fit.
func TableTax(winnings int64, taxBps int) int64 {
	base := winnings
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
