package game

// SeatLevel is a seated player's level as every viewer's snapshot shows it on
// their pod (owner, 29 Sep 2026: "In gametable In every player pod show their
// game level icon on top right of player pod"): the level's number and its
// art (player_levels.asset_url, the owner's Lottie) — never the XP, the rate
// or a badge, which stay the player's own. Public: a player's level is already
// shown to everybody at the table (the player drawer's profile).
//
// Captured when the player sits down (NewPlayer.Level, read with their
// account), refreshed from every hand-end settle (SettleResult.Levels — a
// level up shows on the pod at the hand that earned it), carried by a
// consolidation move (SeatInfo.Level) and kept in the snapshot across a
// restart. Absent on the wire for a seat whose level is not known.
type SeatLevel struct {
	Level       int    `json:"level"`
	AssetURL    string `json:"assetUrl,omitempty"`
	AssetFormat string `json:"assetFormat,omitempty"`
}

// clone copies l (nil stays nil), so no two seats, views or snapshots ever
// share one.
func (l *SeatLevel) clone() *SeatLevel {
	if l == nil {
		return nil
	}
	c := *l
	return &c
}

// valid reports whether l names a level (1 or above); a snapshot's level that
// does not is dropped rather than refusing the table.
func (l *SeatLevel) valid() bool { return l != nil && l.Level >= 1 }

// adoptLevels puts the levels a landed settle read (SettleResult.Levels) onto
// the seats it names. A seat whose level did not change is left as it is.
func (t *Table) adoptLevels(levels map[string]SeatLevel) {
	for userID, level := range levels {
		if !level.valid() {
			continue
		}
		if s := t.findSeat(userID); s != nil {
			s.level = level.clone()
		}
	}
}
