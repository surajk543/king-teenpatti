package table

import (
	"math"
	"sort"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/strategy"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// SelectInput is what a bot weighs when choosing a table (brief §6).
type SelectInput struct {
	Chips           int64
	Personality     strategy.Personality
	BootsToSit      float64            // it wants at least this many boots before sitting (config table.boots_to_sit)
	CategoryWeights map[string]float64 // config table.category_weights; nil = even
	Recent          []string           // table keys it played most recently, newest first
	Exclude         []string           // keys not to pick now (just refused, just left)
	Occupancy       map[string]float64 // key → share of the fleet's bots seated there, 0..1 (spreads the fleet)
	// Only are the lobby tables the fleet plays (config table.lobby_tables);
	// empty = every Teen Patti table on the menu.
	Only []string
	// Held is, per table key, how many of the fleet's bots sit at that lobby
	// table or are on their way to it (Fleet.Held).
	Held map[string]int
	// Floor and Ceiling are config table.fleet_per_table: a lobby table
	// holding Ceiling of the fleet's bots takes no more, and one holding
	// fewer than Floor is chosen before any other. 0 = none.
	Floor, Ceiling int
}

// The selector's weights. Every factor multiplies a table's weight; the bot
// then draws a table in proportion to it (never the argmax), so bots with
// the same stack and personality still spread across the lobby.
const (
	// stakeSpread is how far (as a share of the stake ladder the stack can
	// reach) a table's stake may sit from the bot's appetite and keep most of
	// its weight: the standard deviation of a Gaussian over the ladder.
	stakeSpread = 0.3
	// depthCautious / depthBold are the bankrolls, in boots of the table,
	// below which a bot of appetite 0 / 1 starts to feel short there.
	depthCautious = 60.0
	depthBold     = 12.0
	// comfortFloor keeps a thin bankroll from zeroing a table outright.
	comfortFloor = 0.05
	// recentLast / recentEarlier discount the table just played and the two
	// before it: mild, so a favourite table is still revisited.
	recentLast    = 0.5
	recentEarlier = 0.8
	// noiseFlatten is how much a bot's Noise flattens its preferences
	// (weights are raised to 1 − noiseFlatten·Noise): a RANDOM bot wanders.
	noiseFlatten = 0.6
	// defaultBootsToSit is config table.boots_to_sit's default, used where an
	// input leaves it unset.
	defaultBootsToSit = 8.0
)

// Select picks a table from the menu for in, or ok=false when no offered
// table admits this stack. Deterministic for a given r.
//
// The candidates are the menu's Teen Patti tables whose band admits the stack
// (Menu.Admits) and whose boot it covers BootsToSit times over — a game, not
// one hand and a walk back to the lobby — less Exclude. When none is that
// deep, the fallback is the cheapest boot among the tables that admit the
// stack at all (one boot covered), as a player turned away for being too rich
// or too poor for their usual table still has somewhere to sit. Excluded
// tables are never picked: when Exclude removes every candidate the answer is
// ok=false, and the caller may ask again without it.
//
// The fleet's own layout (owner, 27 Sep 2026: "seen table 200, 50000, blind
// 200, blind 50000, variation 50000 — each of these tables should have 30-50
// bots playing"): with Only set, only those lobby tables are candidates; a
// lobby table already holding Ceiling of the fleet's bots is not one
// (FullOfFleet tells that apart from a stack nothing admits); and while any
// candidate holds fewer than Floor, the choice is among those alone.
//
// Each candidate's weight is the product of
//   - stake fit: a Gaussian over the table's place on the ladder of stakes
//     the stack can reach (0 lowest … 1 highest), centred on the bot's stake
//     appetite as its family shapes it — a CAUTIOUS bot low to middling, a
//     BEGINNER low, an AGGRESSIVE bot high where it can afford it — shared
//     among the candidates at that stake in proportion to their category's
//     weight (config; 0 means "only if nothing else fits"), so a stake with
//     three tables is no likelier than one with a single table;
//   - comfort: the bankroll in boots of that table against the depth the bot
//     wants (a cautious bot wants ~60 boots, a bold one ~12);
//   - fleet occupancy: 2μ/(occ+μ) over the candidates' mean occupancy μ, so a
//     table the fleet is thin on weighs up to twice the average and one it
//     crowds weighs less;
//   - recency: ½ for the table just played, 0.8 for the two before it;
//
// flattened by the bot's Noise, then drawn by weight.
func Select(m Menu, in SelectInput, r *rng.Rand) (c Choice, ok bool) {
	cands := candidates(m, in, true)
	if len(cands) == 0 {
		return Choice{}, false
	}
	// A lobby table the fleet is thin on — under its floor — goes before
	// any other, so every table the fleet plays reaches its floor first.
	if in.Floor > 0 {
		var short []Choice
		for _, t := range cands {
			if in.Held[t.Key] < in.Floor {
				short = append(short, t)
			}
		}
		if len(short) > 0 {
			cands = short
		}
	}

	levels := distinctBoots(cands)
	// A stake's weight is shared among its tables by their category weights,
	// so the stake keeps the same chance however its tables are weighted.
	atBoot := make(map[int64]float64, len(levels))
	for _, t := range cands {
		atBoot[t.Boot] += categoryWeight(in.CategoryWeights, t.Category)
	}
	target := appetite(in.Personality)
	depth := depthCautious + (depthBold-depthCautious)*target

	meanOcc := 0.0
	if in.Occupancy != nil {
		for _, t := range cands {
			meanOcc += clamp01(in.Occupancy[t.Key])
		}
		meanOcc /= float64(len(cands))
	}

	sharp := 1 - noiseFlatten*clamp01(in.Personality.Noise)
	weights := make([]float64, len(cands))
	total := 0.0
	for i, t := range cands {
		pos := ladderPosition(t.Boot, levels)
		d := (pos - target) / stakeSpread
		w := math.Exp(-d * d / 2)
		if share := atBoot[t.Boot]; share > 0 {
			w *= categoryWeight(in.CategoryWeights, t.Category) / share
		} else {
			w = 0 // every table at this stake weighted 0
		}

		held := float64(in.Chips) / float64(t.Boot)
		w *= math.Max(comfortFloor, math.Min(1, math.Sqrt(held/depth)))

		if meanOcc > 0 {
			occ := clamp01(in.Occupancy[t.Key])
			w *= 2 * meanOcc / (occ + meanOcc)
		}

		for j, k := range in.Recent {
			if j > 2 {
				break
			}
			if k == t.Key {
				if j == 0 {
					w *= recentLast
				} else {
					w *= recentEarlier
				}
				break
			}
		}

		if w > 0 && sharp != 1 {
			w = math.Pow(w, sharp)
		}
		weights[i] = w
		total += w
	}
	if total <= 0 {
		// Every candidate weighed nothing (every category weighted 0): the
		// preference cannot choose, so every candidate is as good as another.
		for i := range weights {
			weights[i] = 1
		}
	}
	return cands[r.Weighted(weights)], true
}

// candidates are the tables Select chooses among for in: the menu's Teen
// Patti tables (config table.lobby_tables, when it names any) whose band
// admits the stack, less Exclude and — capped — less those holding their
// ceiling of the fleet; of those, the ones the stack covers BootsToSit times
// over, or failing any, the cheapest.
func candidates(m Menu, in SelectInput, capped bool) []Choice {
	bootsToSit := in.BootsToSit
	if bootsToSit <= 0 {
		bootsToSit = 1
	}
	excluded := make(map[string]bool, len(in.Exclude))
	for _, k := range in.Exclude {
		excluded[k] = true
	}
	only := make(map[string]bool, len(in.Only))
	for _, k := range in.Only {
		only[k] = true
	}

	var deep, fallback []Choice
	for _, t := range m.Tables {
		if !IsTeenPatti(t.Category) || excluded[t.Key] || !m.Admits(t, in.Chips) {
			continue
		}
		if len(only) > 0 && !only[t.Key] {
			continue
		}
		if capped && in.Ceiling > 0 && in.Held[t.Key] >= in.Ceiling {
			continue
		}
		fallback = append(fallback, t)
		if affords(in.Chips, t.Boot, bootsToSit) {
			deep = append(deep, t)
		}
	}
	if len(deep) > 0 {
		return deep
	}
	if len(fallback) == 0 {
		return nil
	}
	cheapest := fallback[0].Boot
	for _, t := range fallback {
		cheapest = min(cheapest, t.Boot)
	}
	var cands []Choice
	for _, t := range fallback {
		if t.Boot == cheapest {
			cands = append(cands, t)
		}
	}
	return cands
}

// FullOfFleet reports whether Select found nothing only because every table
// that would take this stack already holds its ceiling of the fleet — the
// bot is not broke, the fleet is simply big enough there, and it rests.
func FullOfFleet(m Menu, in SelectInput) bool {
	return in.Ceiling > 0 && len(candidates(m, in, true)) == 0 && len(candidates(m, in, false)) > 0
}

// affords reports whether chips covers boot bootsToSit times over.
func affords(chips, boot int64, bootsToSit float64) bool {
	return float64(chips) >= float64(boot)*bootsToSit
}

// categoryWeight is config table.category_weights for category: 1 when the
// map is nil or does not name it, never negative.
func categoryWeight(weights map[string]float64, category string) float64 {
	if weights == nil {
		return 1
	}
	w, ok := weights[category]
	if !ok {
		return 1
	}
	return math.Max(0, w)
}

// appetite is the bot's stake appetite as its family shapes it, 0 (the lowest
// stake it can reach) … 1 (the highest): a CAUTIOUS bot's is kept low to
// middling, a BEGINNER's low, an AGGRESSIVE bot's high and a LOOSE bot's
// raised a little; BALANCED and RANDOM take their trait as drawn.
func appetite(p strategy.Personality) float64 {
	a := clamp01(p.StakeAppetite)
	switch p.Kind {
	case strategy.Cautious:
		return 0.1 + 0.5*a
	case strategy.Beginner:
		return 0.5 * a
	case strategy.Aggressive:
		return 0.4 + 0.6*a
	case strategy.Loose:
		return 0.1 + 0.9*a
	default:
		return a
	}
}

// distinctBoots is the stakes of tables, ascending, each once: the ladder a
// stack can climb.
func distinctBoots(tables []Choice) []int64 {
	seen := make(map[int64]bool, len(tables))
	var boots []int64
	for _, t := range tables {
		if !seen[t.Boot] {
			seen[t.Boot] = true
			boots = append(boots, t.Boot)
		}
	}
	sort.Slice(boots, func(a, b int) bool { return boots[a] < boots[b] })
	return boots
}

// ladderPosition is where boot stands on the ladder levels, 0 (its lowest
// rung) … 1 (its highest); a boot between rungs, or off either end, takes
// the share of rungs below it. A one-rung ladder is position 0.
func ladderPosition(boot int64, levels []int64) float64 {
	if len(levels) <= 1 {
		return 0
	}
	below := 0
	for _, b := range levels {
		if b < boot {
			below++
		}
	}
	return math.Min(1, float64(below)/float64(len(levels)-1))
}

// clamp01 holds v to [0,1].
func clamp01(v float64) float64 {
	if v < 0 || math.IsNaN(v) {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}
