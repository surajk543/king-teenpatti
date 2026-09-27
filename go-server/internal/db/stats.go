package db

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Player stats v2 (owner, 27 Sep 2026): a player's statistics per BUCKET —
// Teen Patti, Variation, Poker (game.StatsBucket) — with the hands held in the
// first two and the variations played in the second. PostgreSQL holds them in
// player_stats (a row per player per bucket) and player_variation_stats (a row
// per player per variation), and nothing writes those in a money transaction:
// the tables record each committed hand's counters in the live store, and the
// stats flusher (internal/stats) adds them here in batches, through Flush —
// one transaction per batch, exactly once by its stats_flushes receipt.

// HandTally is the hands a player HELD in one bucket at the hand end, as the
// table counted them: the wire's `hands`. Its six sum to the hands the bucket
// finished for them (a departure is not counted: they did not finish).
type HandTally struct {
	Trail        int64 `json:"trail"`
	PureSequence int64 `json:"pureSequence"`
	Sequence     int64 `json:"sequence"`
	Color        int64 `json:"color"`
	Pair         int64 `json:"pair"`
	HighCard     int64 `json:"highCard"`
}

// VariationTally is one variation of the Variation bucket: the hands the
// player was resolved in at the hand end under it, and the ones they won.
type VariationTally struct {
	Variation   string `json:"variation"`
	HandsPlayed int64  `json:"handsPlayed"`
	HandsWon    int64  `json:"handsWon"`
}

// StatsLine is one bucket's counters, one player_stats row. In a StatsDelta
// every field is an amount to ADD but BiggestPot, which is a figure to keep
// the larger of.
type StatsLine struct {
	HandsPlayed   int64
	HandsWon      int64
	HandsLost     int64
	HandsLeft     int64
	TotalWinnings int64
	BiggestPot    int64
	Hands         HandTally
}

// StatsSheet is a player's statistics as PostgreSQL holds them: a line per
// bucket (zeros where they have none) and the variations they have played, in
// the wire's order (orderVariations), never nil.
type StatsSheet struct {
	TeenPatti  StatsLine
	Variation  StatsLine
	Poker      StatsLine
	Variations []VariationTally
}

// line is the sheet's line of one bucket, nil for a bucket it does not know.
func (s *StatsSheet) line(bucket game.StatsBucket) *StatsLine {
	switch bucket {
	case game.StatsTeenPatti:
		return &s.TeenPatti
	case game.StatsVariation:
		return &s.Variation
	case game.StatsPoker:
		return &s.Poker
	}
	return nil
}

// Totals is the whole career: every bucket's counters summed, the biggest pot
// the largest. It is what the user object's six top-level counters carry
// (handsPlayed … biggestPot, unchanged in name and meaning), what a friend's
// profile totals, and what the HANDS_PLAYED milestone is judged on.
func (s StatsSheet) Totals() StatsLine {
	var t StatsLine
	for _, l := range []StatsLine{s.TeenPatti, s.Variation, s.Poker} {
		t.HandsPlayed += l.HandsPlayed
		t.HandsWon += l.HandsWon
		t.HandsLost += l.HandsLost
		t.HandsLeft += l.HandsLeft
		t.TotalWinnings += l.TotalWinnings
		t.BiggestPot = max(t.BiggestPot, l.BiggestPot)
		t.Hands.Trail += l.Hands.Trail
		t.Hands.PureSequence += l.Hands.PureSequence
		t.Hands.Sequence += l.Hands.Sequence
		t.Hands.Color += l.Hands.Color
		t.Hands.Pair += l.Hands.Pair
		t.Hands.HighCard += l.Hands.HighCard
	}
	return t
}

// CategoryStats is one bucket on the wire (user.stats.teenPatti and its
// siblings): the six counters and the win rate.
type CategoryStats struct {
	HandsPlayed   int64   `json:"handsPlayed"`
	HandsWon      int64   `json:"handsWon"`
	HandsLost     int64   `json:"handsLost"`
	HandsLeft     int64   `json:"handsLeft"`
	TotalWinnings int64   `json:"totalWinnings"`
	BiggestPot    int64   `json:"biggestPot"`
	WinRate       float64 `json:"winRate"`
}

// TeenPattiStats is user.stats.teenPatti: the counters and the hands held.
type TeenPattiStats struct {
	CategoryStats
	Hands HandTally `json:"hands"`
}

// VariationStats is user.stats.variation: the counters, the hands held and
// the variations played ([] before the first).
type VariationStats struct {
	CategoryStats
	Hands      HandTally        `json:"hands"`
	Variations []VariationTally `json:"variations"`
}

// UserStats is user.stats: the player's statistics per bucket. Poker has no
// hands held — its hands are not ranked on the Teen Patti ladder.
type UserStats struct {
	TeenPatti TeenPattiStats `json:"teenPatti"`
	Variation VariationStats `json:"variation"`
	Poker     CategoryStats  `json:"poker"`
}

// categoryStats is a line on the wire with its win rate.
func categoryStats(l StatsLine) CategoryStats {
	return CategoryStats{
		HandsPlayed: l.HandsPlayed, HandsWon: l.HandsWon, HandsLost: l.HandsLost, HandsLeft: l.HandsLeft,
		TotalWinnings: l.TotalWinnings, BiggestPot: l.BiggestPot, WinRate: WinRate(l.HandsWon, l.HandsPlayed),
	}
}

// Wire is the sheet as user.stats: every list non-nil.
func (s StatsSheet) Wire() UserStats {
	variations := s.Variations
	if variations == nil {
		variations = []VariationTally{}
	}
	return UserStats{
		TeenPatti: TeenPattiStats{CategoryStats: categoryStats(s.TeenPatti), Hands: s.TeenPatti.Hands},
		Variation: VariationStats{CategoryStats: categoryStats(s.Variation), Hands: s.Variation.Hands, Variations: variations},
		Poker:     categoryStats(s.Poker),
	}
}

// WinRate is round(100 · won / played, 2): 0 before a hand has been played,
// and never over 100 — a hand won without a voluntary bet (everybody else
// packed first) counts as won but not as played (requirement 16), so won
// can outrun played.
func WinRate(won, played int64) float64 {
	if played <= 0 || won <= 0 {
		return 0
	}
	rate := math.Round(10000*float64(won)/float64(played)) / 100
	return math.Min(rate, 100)
}

// orderVariations sorts tallies into the wire's order: the variations the
// chooser is shown, in that order (game.Variations: MUFLIS, AK47, JOKER,
// HUKAM, LOWEST_JOKER, HIGHEST_JOKER, FIVE_CARD), then any other value by
// name — the set is open, and a variation added later is shown after them.
func orderVariations(tallies []VariationTally) {
	rank := func(v string) int {
		for i, known := range game.Variations {
			if string(known) == v {
				return i
			}
		}
		return len(game.Variations)
	}
	sort.SliceStable(tallies, func(i, j int) bool {
		ri, rj := rank(tallies[i].Variation), rank(tallies[j].Variation)
		if ri != rj {
			return ri < rj
		}
		return tallies[i].Variation < tallies[j].Variation
	})
}

// statsColumns are the two correlated subqueries every read of a player's
// statistics selects, against the users row aliased u: the player's
// player_stats rows as one JSON array of arrays (category first, then the
// twelve counters in column order) and their player_variation_stats rows as
// another ([variation, played, won]); '[]' for a player with none. Two index
// lookups on the primary keys' leading user_id, inside the account read's one
// round trip — the socket layer reads an account on every connect and join.
const statsColumns = `(SELECT COALESCE(json_agg(json_build_array(s.category, s.hands_played, s.hands_won, s.hands_lost, s.hands_left,
               s.total_winnings, s.biggest_pot, s.trail, s.pure_sequence, s.sequence, s.color, s.pair, s.high_card)), '[]'::json)::text
          FROM player_stats s WHERE s.user_id = u.id),
       (SELECT COALESCE(json_agg(json_build_array(v.variation, v.hands_played, v.hands_won)), '[]'::json)::text
          FROM player_variation_stats v WHERE v.user_id = u.id)`

// parseStatsSheet reads statsColumns' two arrays into a sheet. A row of a
// bucket this build does not know is left out, and a variation with no hand
// played or won is not listed.
func parseStatsSheet(buckets, variations string) (StatsSheet, error) {
	var sheet StatsSheet
	var rows [][]json.RawMessage
	if err := json.Unmarshal([]byte(buckets), &rows); err != nil {
		return StatsSheet{}, fmt.Errorf("player_stats rows: %w", err)
	}
	for _, row := range rows {
		if len(row) != 13 {
			return StatsSheet{}, fmt.Errorf("player_stats row of %d values", len(row))
		}
		var category string
		if err := json.Unmarshal(row[0], &category); err != nil {
			return StatsSheet{}, fmt.Errorf("player_stats category: %w", err)
		}
		var n [12]int64
		for i := range n {
			v, err := strconv.ParseInt(string(row[i+1]), 10, 64)
			if err != nil {
				return StatsSheet{}, fmt.Errorf("player_stats %s value %d: %w", category, i, err)
			}
			n[i] = v
		}
		line := sheet.line(game.StatsBucket(category))
		if line == nil {
			continue
		}
		*line = StatsLine{
			HandsPlayed: n[0], HandsWon: n[1], HandsLost: n[2], HandsLeft: n[3], TotalWinnings: n[4], BiggestPot: n[5],
			Hands: HandTally{Trail: n[6], PureSequence: n[7], Sequence: n[8], Color: n[9], Pair: n[10], HighCard: n[11]},
		}
	}
	var vrows [][]json.RawMessage
	if err := json.Unmarshal([]byte(variations), &vrows); err != nil {
		return StatsSheet{}, fmt.Errorf("player_variation_stats rows: %w", err)
	}
	sheet.Variations = make([]VariationTally, 0, len(vrows))
	for _, row := range vrows {
		if len(row) != 3 {
			return StatsSheet{}, fmt.Errorf("player_variation_stats row of %d values", len(row))
		}
		var t VariationTally
		if err := json.Unmarshal(row[0], &t.Variation); err != nil {
			return StatsSheet{}, fmt.Errorf("player_variation_stats variation: %w", err)
		}
		var err error
		if t.HandsPlayed, err = strconv.ParseInt(string(row[1]), 10, 64); err != nil {
			return StatsSheet{}, fmt.Errorf("player_variation_stats %s played: %w", t.Variation, err)
		}
		if t.HandsWon, err = strconv.ParseInt(string(row[2]), 10, 64); err != nil {
			return StatsSheet{}, fmt.Errorf("player_variation_stats %s won: %w", t.Variation, err)
		}
		if t.HandsPlayed > 0 || t.HandsWon > 0 {
			sheet.Variations = append(sheet.Variations, t)
		}
	}
	orderVariations(sheet.Variations)
	return sheet, nil
}

// ---------------------------------------------------------------- deltas

// StatsDelta is one player's share of a flush batch: per bucket, what to add
// to its player_stats row (and the biggest pot to keep the larger of), and
// per variation, what to add to its player_variation_stats row.
type StatsDelta struct {
	UserID     string
	Buckets    map[game.StatsBucket]*StatsLine
	Variations map[string]*VariationTally
}

// NewStatsDelta is an empty delta for userID.
func NewStatsDelta(userID string) *StatsDelta {
	return &StatsDelta{UserID: userID, Buckets: map[game.StatsBucket]*StatsLine{}, Variations: map[string]*VariationTally{}}
}

// Line is the delta's line of one bucket, created on first use.
func (d *StatsDelta) Line(bucket game.StatsBucket) *StatsLine {
	line := d.Buckets[bucket]
	if line == nil {
		line = &StatsLine{}
		d.Buckets[bucket] = line
	}
	return line
}

// Tally is the delta's tally of one variation, created on first use.
func (d *StatsDelta) Tally(variation string) *VariationTally {
	tally := d.Variations[variation]
	if tally == nil {
		tally = &VariationTally{Variation: variation}
		d.Variations[variation] = tally
	}
	return tally
}

// Add folds one hand's counters in — what a flushed batch of the live store's
// pending counters amounts to, stated directly (tests; the stats codec is
// checked against it).
func (d *StatsDelta) Add(h game.HandStats) {
	line := d.Line(h.Bucket)
	line.HandsPlayed += h.Played
	line.HandsWon += h.Won
	line.HandsLost += h.Lost
	line.HandsLeft += h.Left
	line.TotalWinnings += h.Winnings
	line.BiggestPot = max(line.BiggestPot, h.Winnings)
	if h.HasHeld {
		switch h.Held {
		case game.Trail:
			line.Hands.Trail++
		case game.PureSequence:
			line.Hands.PureSequence++
		case game.Sequence:
			line.Hands.Sequence++
		case game.Color:
			line.Hands.Color++
		case game.Pair:
			line.Hands.Pair++
		case game.HighCard:
			line.Hands.HighCard++
		}
	}
	if h.Variation != "" {
		tally := d.Tally(string(h.Variation))
		tally.HandsPlayed++
		if h.VariationWon {
			tally.HandsWon++
		}
	}
}

// ---------------------------------------------------------------- the store

// StatsStore writes and prunes the statistics the stats flusher moves out of
// the live store.
type StatsStore struct {
	db    *DB
	clock func() time.Time
}

// NewStatsStore builds the store; clock nil → time.Now.
func NewStatsStore(d *DB, clock func() time.Time) *StatsStore {
	return &StatsStore{db: d, clock: clock}
}

// Flush is ONE group commit: every player of a batch, in one transaction.
//
//	INSERT INTO stats_flushes (batch_id, players, flushed_at) ON CONFLICT DO NOTHING
//	    — no row inserted: this batch was committed before (its acknowledgement
//	      lost), so nothing is added again and applied is false;
//	INSERT INTO player_stats … SELECT FROM unnest(…) JOIN users ON CONFLICT DO UPDATE
//	    — each bucket row adds the deltas, biggest_pot = GREATEST;
//	INSERT INTO player_variation_stats … the same, per variation.
//
// The receipt is written FIRST and in the same transaction as the counters, so
// it exists exactly when they were added: a retry of a batch whose commit was
// never acknowledged finds it and adds nothing, and a retry of one whose
// transaction failed finds none and adds everything. Two flushers on one batch
// serialise on the receipt's primary key. Rows go in (user_id, category)
// order, the one lock order every flush takes. A player whose account has been
// deleted (or never existed) is skipped: DELETE /api/account removed their
// rows, and counters still pending for them must not bring any back. A batch
// holds each player once; a player named twice is folded into one row per
// bucket first (an upsert may not touch one row twice).
func (s *StatsStore) Flush(ctx context.Context, batchID string, deltas []StatsDelta) (applied bool, err error) {
	if batchID == "" {
		return false, fmt.Errorf("stats flush: empty batch id")
	}
	at := now(s.clock)
	ordered := mergeDeltas(deltas)

	var lines statsLineColumns
	var tallies variationColumns
	for _, d := range ordered {
		for _, bucket := range sortedBuckets(d.Buckets) {
			lines.add(d.UserID, string(bucket), *d.Buckets[bucket])
		}
		for _, variation := range sortedVariations(d.Variations) {
			tallies.add(d.UserID, variation, *d.Variations[variation])
		}
	}

	err = s.db.WithTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO stats_flushes (batch_id, players, flushed_at) VALUES ($1, $2, $3)
		     ON CONFLICT (batch_id) DO NOTHING`, batchID, len(ordered), at)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			applied = false
			return nil
		}
		applied = true
		if len(lines.userIDs) > 0 {
			if _, err := tx.Exec(ctx, `INSERT INTO player_stats AS p (user_id, category, hands_played, hands_won, hands_lost, hands_left,
			         total_winnings, biggest_pot, trail, pure_sequence, sequence, color, pair, high_card, created_at, updated_at)
			     SELECT d.user_id, d.category, d.hands_played, d.hands_won, d.hands_lost, d.hands_left,
			            d.total_winnings, d.biggest_pot, d.trail, d.pure_sequence, d.sequence, d.color, d.pair, d.high_card, $15, $15
			       FROM unnest($1::text[], $2::text[], $3::bigint[], $4::bigint[], $5::bigint[], $6::bigint[], $7::bigint[],
			                   $8::bigint[], $9::bigint[], $10::bigint[], $11::bigint[], $12::bigint[], $13::bigint[], $14::bigint[])
			            AS d(user_id, category, hands_played, hands_won, hands_lost, hands_left, total_winnings, biggest_pot,
			                 trail, pure_sequence, sequence, color, pair, high_card)
			       JOIN users u ON u.id = d.user_id AND u.deleted_at = 0
			      ORDER BY d.user_id, d.category
			     ON CONFLICT (user_id, category) DO UPDATE
			        SET hands_played   = p.hands_played + EXCLUDED.hands_played,
			            hands_won      = p.hands_won + EXCLUDED.hands_won,
			            hands_lost     = p.hands_lost + EXCLUDED.hands_lost,
			            hands_left     = p.hands_left + EXCLUDED.hands_left,
			            total_winnings = p.total_winnings + EXCLUDED.total_winnings,
			            biggest_pot    = GREATEST(p.biggest_pot, EXCLUDED.biggest_pot),
			            trail          = p.trail + EXCLUDED.trail,
			            pure_sequence  = p.pure_sequence + EXCLUDED.pure_sequence,
			            sequence       = p.sequence + EXCLUDED.sequence,
			            color          = p.color + EXCLUDED.color,
			            pair           = p.pair + EXCLUDED.pair,
			            high_card      = p.high_card + EXCLUDED.high_card,
			            updated_at     = EXCLUDED.updated_at`,
				lines.userIDs, lines.categories, lines.played, lines.won, lines.lost, lines.left, lines.winnings, lines.biggest,
				lines.trail, lines.pureSequence, lines.sequence, lines.color, lines.pair, lines.highCard, at); err != nil {
				return err
			}
		}
		if len(tallies.userIDs) > 0 {
			if _, err := tx.Exec(ctx, `INSERT INTO player_variation_stats AS p (user_id, variation, hands_played, hands_won, created_at, updated_at)
			     SELECT d.user_id, d.variation, d.hands_played, d.hands_won, $5, $5
			       FROM unnest($1::text[], $2::text[], $3::bigint[], $4::bigint[]) AS d(user_id, variation, hands_played, hands_won)
			       JOIN users u ON u.id = d.user_id AND u.deleted_at = 0
			      ORDER BY d.user_id, d.variation
			     ON CONFLICT (user_id, variation) DO UPDATE
			        SET hands_played = p.hands_played + EXCLUDED.hands_played,
			            hands_won    = p.hands_won + EXCLUDED.hands_won,
			            updated_at   = EXCLUDED.updated_at`,
				tallies.userIDs, tallies.variations, tallies.played, tallies.won, at); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return false, err
	}
	return applied, nil
}

// PruneFlushes deletes the stats_flushes receipts older than olderThanMs
// (epoch ms) and reports how many went. The flusher keeps 7 days: a batch
// still unacknowledged after that would be counted again, and no batch waits
// that long for its in-flight counters to be forgotten.
func (s *StatsStore) PruneFlushes(ctx context.Context, olderThanMs int64) (int64, error) {
	tag, err := s.db.Pool.Exec(ctx, `DELETE FROM stats_flushes WHERE flushed_at < $1`, olderThanMs)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// Sheet reads one player's statistics as every account read sees them
// (StatsSheet; zeros and no variations for a player with no row).
func (s *StatsStore) Sheet(ctx context.Context, userID string) (StatsSheet, error) {
	var buckets, variations string
	if err := s.db.Pool.QueryRow(ctx, `SELECT `+statsColumns+` FROM (SELECT $1::text AS id) u`, userID).Scan(&buckets, &variations); err != nil {
		return StatsSheet{}, err
	}
	return parseStatsSheet(buckets, variations)
}

// deleteStats removes a player's statistics, inside the account deletion's
// transaction (Users.DeleteAccount): users rows are never deleted, so their
// ON DELETE CASCADE never would. A flush after it finds the account deleted
// and brings nothing back.
func deleteStats(ctx context.Context, tx pgx.Tx, userID string) error {
	if _, err := tx.Exec(ctx, `DELETE FROM player_stats WHERE user_id = $1`, userID); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `DELETE FROM player_variation_stats WHERE user_id = $1`, userID)
	return err
}

// mergeDeltas folds deltas into one per player, in user id order: counters
// summed, the biggest pot the larger.
func mergeDeltas(deltas []StatsDelta) []*StatsDelta {
	byUser := map[string]*StatsDelta{}
	for _, d := range deltas {
		merged := byUser[d.UserID]
		if merged == nil {
			merged = NewStatsDelta(d.UserID)
			byUser[d.UserID] = merged
		}
		for bucket, l := range d.Buckets {
			if l == nil {
				continue
			}
			into := merged.Line(bucket)
			into.HandsPlayed += l.HandsPlayed
			into.HandsWon += l.HandsWon
			into.HandsLost += l.HandsLost
			into.HandsLeft += l.HandsLeft
			into.TotalWinnings += l.TotalWinnings
			into.BiggestPot = max(into.BiggestPot, l.BiggestPot)
			into.Hands.Trail += l.Hands.Trail
			into.Hands.PureSequence += l.Hands.PureSequence
			into.Hands.Sequence += l.Hands.Sequence
			into.Hands.Color += l.Hands.Color
			into.Hands.Pair += l.Hands.Pair
			into.Hands.HighCard += l.Hands.HighCard
		}
		for variation, t := range d.Variations {
			if t == nil {
				continue
			}
			into := merged.Tally(variation)
			into.HandsPlayed += t.HandsPlayed
			into.HandsWon += t.HandsWon
		}
	}
	out := make([]*StatsDelta, 0, len(byUser))
	for _, d := range byUser {
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UserID < out[j].UserID })
	return out
}

// statsLineColumns are player_stats rows as the parallel arrays unnest reads.
type statsLineColumns struct {
	userIDs, categories                                  []string
	played, won, lost, left, winnings, biggest           []int64
	trail, pureSequence, sequence, color, pair, highCard []int64
}

func (c *statsLineColumns) add(userID, category string, l StatsLine) {
	c.userIDs = append(c.userIDs, userID)
	c.categories = append(c.categories, category)
	c.played = append(c.played, l.HandsPlayed)
	c.won = append(c.won, l.HandsWon)
	c.lost = append(c.lost, l.HandsLost)
	c.left = append(c.left, l.HandsLeft)
	c.winnings = append(c.winnings, l.TotalWinnings)
	c.biggest = append(c.biggest, l.BiggestPot)
	c.trail = append(c.trail, l.Hands.Trail)
	c.pureSequence = append(c.pureSequence, l.Hands.PureSequence)
	c.sequence = append(c.sequence, l.Hands.Sequence)
	c.color = append(c.color, l.Hands.Color)
	c.pair = append(c.pair, l.Hands.Pair)
	c.highCard = append(c.highCard, l.Hands.HighCard)
}

// variationColumns are player_variation_stats rows as parallel arrays.
type variationColumns struct {
	userIDs, variations []string
	played, won         []int64
}

func (c *variationColumns) add(userID, variation string, t VariationTally) {
	c.userIDs = append(c.userIDs, userID)
	c.variations = append(c.variations, variation)
	c.played = append(c.played, t.HandsPlayed)
	c.won = append(c.won, t.HandsWon)
}

func sortedBuckets(m map[game.StatsBucket]*StatsLine) []game.StatsBucket {
	out := make([]game.StatsBucket, 0, len(m))
	for b, l := range m {
		if l != nil {
			out = append(out, b)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func sortedVariations(m map[string]*VariationTally) []string {
	out := make([]string, 0, len(m))
	for v, t := range m {
		if t != nil {
			out = append(out, v)
		}
	}
	sort.Strings(out)
	return out
}
