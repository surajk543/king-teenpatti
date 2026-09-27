// Package strategy is how a bot plays: its personality, and the decisions a
// turn, a sideshow ask, a variation window or a 5-Card pick call for. It
// knows nothing of sockets or timers — every function is a pure function of
// what the server showed the bot, its personality, its memory of the hand
// and its random stream, so every rule is tested deterministically.
//
// Every move it returns is one the server offered (you.options) and every
// amount a rung of the ladder the server sent. The server validates it all
// again; this package only chooses.
package strategy

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// Kind is a personality's family.
type Kind string

// The six families (brief §9).
const (
	Cautious   Kind = "CAUTIOUS"
	Balanced   Kind = "BALANCED"
	Aggressive Kind = "AGGRESSIVE"
	Loose      Kind = "LOOSE"
	Random     Kind = "RANDOM"
	Beginner   Kind = "BEGINNER"
)

// Kinds is every family, in a fixed order.
var Kinds = []Kind{Cautious, Balanced, Aggressive, Loose, Random, Beginner}

// ParseKind reads a family's name as configuration writes it — any case,
// surrounding spaces ignored ("aggressive", " Beginner"). An unknown name is
// an error naming it.
func ParseKind(name string) (Kind, error) {
	k := Kind(strings.ToUpper(strings.TrimSpace(name)))
	for _, known := range Kinds {
		if k == known {
			return k, nil
		}
	}
	return "", fmt.Errorf("strategy: unknown personality kind %q (want one of CAUTIOUS, BALANCED, AGGRESSIVE, LOOSE, RANDOM, BEGINNER)", name)
}

// Range is a closed interval a trait is drawn from.
type Range struct{ Lo, Hi float64 }

// draw is a uniform draw inside the range.
func (g Range) draw(r *rng.Rand) float64 { return r.Between(g.Lo, g.Hi) }

// Personality is one bot's stable way of playing, drawn ONCE from its
// family's Profile with per-bot variation, so two AGGRESSIVE bots are alike
// in kind but not identical (one plays blind 57% of hands, the other 46%).
// Every float is 0..1 unless noted.
type Personality struct {
	Kind Kind

	Tightness  float64 // 0 plays almost anything … 1 folds whatever is not clearly good
	Aggression float64 // 0 calls … 1 raises often and high up the ladder
	BlindRate  float64 // chance a hand starts with the intent to stay blind (brief §10 ranges)
	BlindLove  float64 // how long a blind intent lasts, and how little pressure it takes to look
	Bluff      float64 // chance of playing a weak hand as a strong one
	Mistake    float64 // chance per decision of a controlled imperfection (bad call, needless fold, …)
	Noise      float64 // how far randomness bends thresholds (RANDOM is high; still legal)
	Adapt      float64 // how much it reacts to its reads of opponents

	SideshowRate float64 // appetite for asking a sideshow with a middling hand
	ShowRate     float64 // appetite for paying to show heads-up
	ChatRate     float64 // base chance of speaking at a moment worth a word

	Pace       float64 // 0 snap decisions … 1 deliberate (timing)
	Distracted float64 // chance of a much longer pause (phone put down)

	StakeAppetite float64 // 0 the lowest stakes it can sit at … 1 the highest it can afford
	TableMoves    float64 // 0 stays at a table … 1 moves on readily

	HandsAtTable   [2]int     // min, max hands before it thinks of moving (clamped to config)
	SessionMinutes [2]float64 // min, max session length, minutes (clamped to config)

	StopLossBoots   float64 // leaves a table after losing this many boots there
	TakeProfitBoots float64 // … or after winning this many
}

// Profile is a family's trait ranges; NewPersonality draws inside them.
type Profile struct {
	Tightness, Aggression, BlindRate, BlindLove, Bluff, Mistake, Noise, Adapt Range
	SideshowRate, ShowRate, ChatRate                                          Range
	Pace, Distracted, StakeAppetite, TableMoves                               Range
	StopLossBoots, TakeProfitBoots                                            Range
	HandsAtTable                                                              [2]int
	SessionMinutes                                                            Range
}

// DefaultProfiles are the six families' ranges — the one piece of package
// state, a table of defaults that configuration overrides through
// ApplyTuning (which copies it; nothing in this package writes it).
//
// The families are meant to be told apart at a table, and are not equally
// good at the game:
//
//   - CAUTIOUS folds what is not clearly good, rarely bluffs, raises small,
//     settles cheaply with sideshows, plays blind 20–35% of hands, sits at low
//     stakes and stays put. Hard to beat, easy to push out of pots.
//   - BALANCED is the regular: mixed, and the most responsive to what the
//     opponents do (Adapt high). Blind 35–50%. The strongest family.
//   - AGGRESSIVE raises often and high up the ladder, bluffs, calls wide,
//     plays blind 45–65%, likes high stakes and moves tables readily.
//   - LOOSE plays almost everything and pays to see it through: few folds,
//     moderate raises, frequent shows. Blind 40–60%. Leaks chips.
//   - RANDOM is deliberately noisy: wide trait ranges, thresholds bent hard
//     by Noise and now and then a whim move (always a legal one). Blind
//     25–60%.
//   - BEGINNER makes the most mistakes — bad calls, needless folds, the
//     occasional small raise on nothing — thinks slowly, plays small, and
//     plays blind 30–55%. The weakest family.
//
// Within a family each bot draws every trait uniformly inside its range, so
// no two bots of a family are the same player.
var DefaultProfiles = map[Kind]Profile{
	Cautious: {
		Tightness: Range{0.62, 0.85}, Aggression: Range{0.10, 0.30}, BlindRate: Range{0.20, 0.35}, BlindLove: Range{0.15, 0.40},
		Bluff: Range{0.01, 0.04}, Mistake: Range{0.01, 0.03}, Noise: Range{0.03, 0.08}, Adapt: Range{0.40, 0.65},
		SideshowRate: Range{0.35, 0.60}, ShowRate: Range{0.20, 0.40}, ChatRate: Range{0.03, 0.10},
		Pace: Range{0.45, 0.85}, Distracted: Range{0.02, 0.05}, StakeAppetite: Range{0.05, 0.35}, TableMoves: Range{0.05, 0.25},
		StopLossBoots: Range{15, 35}, TakeProfitBoots: Range{25, 60},
		HandsAtTable: [2]int{10, 40}, SessionMinutes: Range{30, 120},
	},
	Balanced: {
		Tightness: Range{0.42, 0.62}, Aggression: Range{0.35, 0.55}, BlindRate: Range{0.35, 0.50}, BlindLove: Range{0.35, 0.60},
		Bluff: Range{0.04, 0.09}, Mistake: Range{0.02, 0.04}, Noise: Range{0.05, 0.10}, Adapt: Range{0.70, 0.95},
		SideshowRate: Range{0.25, 0.45}, ShowRate: Range{0.30, 0.50}, ChatRate: Range{0.05, 0.15},
		Pace: Range{0.35, 0.70}, Distracted: Range{0.02, 0.06}, StakeAppetite: Range{0.30, 0.60}, TableMoves: Range{0.20, 0.45},
		StopLossBoots: Range{25, 60}, TakeProfitBoots: Range{40, 100},
		HandsAtTable: [2]int{8, 30}, SessionMinutes: Range{25, 100},
	},
	Aggressive: {
		Tightness: Range{0.20, 0.42}, Aggression: Range{0.65, 0.92}, BlindRate: Range{0.45, 0.65}, BlindLove: Range{0.55, 0.85},
		Bluff: Range{0.10, 0.22}, Mistake: Range{0.03, 0.06}, Noise: Range{0.06, 0.14}, Adapt: Range{0.30, 0.60},
		SideshowRate: Range{0.30, 0.55}, ShowRate: Range{0.45, 0.70}, ChatRate: Range{0.08, 0.22},
		Pace: Range{0.10, 0.45}, Distracted: Range{0.01, 0.04}, StakeAppetite: Range{0.55, 0.95}, TableMoves: Range{0.40, 0.75},
		StopLossBoots: Range{40, 100}, TakeProfitBoots: Range{60, 150},
		HandsAtTable: [2]int{5, 22}, SessionMinutes: Range{20, 80},
	},
	Loose: {
		Tightness: Range{0.05, 0.28}, Aggression: Range{0.30, 0.55}, BlindRate: Range{0.40, 0.60}, BlindLove: Range{0.45, 0.75},
		Bluff: Range{0.06, 0.14}, Mistake: Range{0.04, 0.08}, Noise: Range{0.08, 0.16}, Adapt: Range{0.15, 0.40},
		SideshowRate: Range{0.20, 0.40}, ShowRate: Range{0.40, 0.65}, ChatRate: Range{0.10, 0.25},
		Pace: Range{0.15, 0.55}, Distracted: Range{0.03, 0.07}, StakeAppetite: Range{0.35, 0.75}, TableMoves: Range{0.30, 0.60},
		StopLossBoots: Range{30, 80}, TakeProfitBoots: Range{40, 120},
		HandsAtTable: [2]int{6, 25}, SessionMinutes: Range{20, 90},
	},
	Random: {
		Tightness: Range{0.15, 0.85}, Aggression: Range{0.15, 0.85}, BlindRate: Range{0.25, 0.60}, BlindLove: Range{0.20, 0.80},
		Bluff: Range{0.05, 0.20}, Mistake: Range{0.08, 0.16}, Noise: Range{0.35, 0.60}, Adapt: Range{0.05, 0.25},
		SideshowRate: Range{0.20, 0.60}, ShowRate: Range{0.25, 0.65}, ChatRate: Range{0.04, 0.20},
		Pace: Range{0.10, 0.90}, Distracted: Range{0.02, 0.08}, StakeAppetite: Range{0.10, 0.90}, TableMoves: Range{0.20, 0.80},
		StopLossBoots: Range{20, 80}, TakeProfitBoots: Range{30, 120},
		HandsAtTable: [2]int{4, 30}, SessionMinutes: Range{15, 90},
	},
	Beginner: {
		Tightness: Range{0.30, 0.60}, Aggression: Range{0.20, 0.50}, BlindRate: Range{0.30, 0.55}, BlindLove: Range{0.35, 0.70},
		Bluff: Range{0.02, 0.08}, Mistake: Range{0.10, 0.20}, Noise: Range{0.18, 0.32}, Adapt: Range{0.05, 0.20},
		SideshowRate: Range{0.15, 0.35}, ShowRate: Range{0.30, 0.60}, ChatRate: Range{0.06, 0.18},
		Pace: Range{0.50, 0.95}, Distracted: Range{0.04, 0.09}, StakeAppetite: Range{0.05, 0.30}, TableMoves: Range{0.10, 0.35},
		StopLossBoots: Range{10, 30}, TakeProfitBoots: Range{15, 40},
		HandsAtTable: [2]int{5, 20}, SessionMinutes: Range{10, 45},
	},
}

// NewPersonality draws one bot's personality of kind from profiles
// (DefaultProfiles when nil). Deterministic for a given r.
//
// Every trait is a uniform draw inside the family's range, in a fixed order.
// The two spans — HandsAtTable and SessionMinutes — are drawn as a narrower
// span inside the family's: a minimum from the lower third, a maximum from
// the upper third, so one bot is a regular who stays long and another a
// dropper-in. A kind the profiles do not hold falls back to DefaultProfiles,
// and a kind unknown there too plays as BALANCED (and says so in Kind).
func NewPersonality(kind Kind, profiles map[Kind]Profile, r *rng.Rand) Personality {
	if profiles == nil {
		profiles = DefaultProfiles
	}
	prof, ok := profiles[kind]
	if !ok {
		prof, ok = DefaultProfiles[kind]
	}
	if !ok {
		kind, prof = Balanced, DefaultProfiles[Balanced]
	}
	p := Personality{Kind: kind}
	p.Tightness = prof.Tightness.draw(r)
	p.Aggression = prof.Aggression.draw(r)
	p.BlindRate = prof.BlindRate.draw(r)
	p.BlindLove = prof.BlindLove.draw(r)
	p.Bluff = prof.Bluff.draw(r)
	p.Mistake = prof.Mistake.draw(r)
	p.Noise = prof.Noise.draw(r)
	p.Adapt = prof.Adapt.draw(r)
	p.SideshowRate = prof.SideshowRate.draw(r)
	p.ShowRate = prof.ShowRate.draw(r)
	p.ChatRate = prof.ChatRate.draw(r)
	p.Pace = prof.Pace.draw(r)
	p.Distracted = prof.Distracted.draw(r)
	p.StakeAppetite = prof.StakeAppetite.draw(r)
	p.TableMoves = prof.TableMoves.draw(r)
	p.StopLossBoots = prof.StopLossBoots.draw(r)
	p.TakeProfitBoots = prof.TakeProfitBoots.draw(r)

	lo, hi := prof.HandsAtTable[0], prof.HandsAtTable[1]
	if hi < lo {
		lo, hi = hi, lo
	}
	third := (hi - lo) / 3
	minHands := lo + r.IntN(third+1)
	maxHands := hi - r.IntN(third+1)
	p.HandsAtTable = [2]int{minHands, max(minHands, maxHands)}

	slo, shi := prof.SessionMinutes.Lo, prof.SessionMinutes.Hi
	if shi < slo {
		slo, shi = shi, slo
	}
	sthird := (shi - slo) / 3
	minMinutes := r.Between(slo, slo+sthird)
	maxMinutes := r.Between(shi-sthird, shi)
	p.SessionMinutes = [2]float64{minMinutes, math.Max(minMinutes, maxMinutes)}
	return p
}

// PickKind draws a family by weight (config bots.personality_mix: kind name →
// weight); nil or empty weights mean every family equally.
//
// Names are read as ParseKind reads them (any case). A name that is not a
// family, or a weight that is not positive, counts for nothing; when nothing
// counts every family is equally likely. The families are walked in Kinds
// order, never in map order, so a seed replays.
func PickKind(weights map[string]float64, r *rng.Rand) Kind {
	names := make([]string, 0, len(weights))
	for name := range weights {
		names = append(names, name)
	}
	sort.Strings(names)
	w := make([]float64, len(Kinds))
	total := 0.0
	for _, name := range names {
		weight := weights[name]
		k, err := ParseKind(name)
		if err != nil || !(weight > 0) || math.IsInf(weight, 0) {
			continue
		}
		for i, known := range Kinds {
			if known == k {
				w[i] += weight
				total += weight
			}
		}
	}
	if total <= 0 {
		return Kinds[r.IntN(len(Kinds))]
	}
	return Kinds[r.Weighted(w)]
}

// TraitNames are the snake_case trait names ApplyTuning accepts, in the
// order Personality declares them.
func TraitNames() []string {
	return []string{
		"tightness", "aggression", "blind_rate", "blind_love", "bluff", "mistake", "noise", "adapt",
		"sideshow_rate", "show_rate", "chat_rate", "pace", "distracted", "stake_appetite", "table_moves",
		"stop_loss_boots", "take_profit_boots", "session_minutes", "hands_at_table",
	}
}

// ApplyTuning overrides profile ranges from configuration: kind name →
// trait name (snake_case, e.g. "blind_rate") → [lo, hi]. Unknown kinds or
// traits are an error naming them.
//
// base is not changed: the result is a copy (base nil means
// DefaultProfiles; a family base lacks starts from its default). Names are
// read in any case. Each range must have lo ≤ hi; a 0..1 trait must lie in
// 0..1, the boots and minutes must not be negative (and session_minutes must
// be more than 0), and hands_at_table is rounded to whole hands, at least 1.
// Errors are reported in a fixed order (kinds, then traits, sorted), so the
// same configuration always names the same problem first.
func ApplyTuning(base map[Kind]Profile, tuning map[string]map[string][2]float64) (map[Kind]Profile, error) {
	if base == nil {
		base = DefaultProfiles
	}
	out := make(map[Kind]Profile, len(Kinds))
	for k, p := range base {
		out[k] = p
	}

	kindNames := make([]string, 0, len(tuning))
	for name := range tuning {
		kindNames = append(kindNames, name)
	}
	sort.Strings(kindNames)
	for _, kindName := range kindNames {
		kind, err := ParseKind(kindName)
		if err != nil {
			return nil, fmt.Errorf("strategy: tuning: %w", err)
		}
		prof, ok := out[kind]
		if !ok {
			prof = DefaultProfiles[kind]
		}
		traits := tuning[kindName]
		traitNames := make([]string, 0, len(traits))
		for name := range traits {
			traitNames = append(traitNames, name)
		}
		sort.Strings(traitNames)
		for _, traitName := range traitNames {
			if err := setTrait(&prof, traitName, traits[traitName]); err != nil {
				return nil, fmt.Errorf("strategy: tuning %s: %w", kind, err)
			}
		}
		out[kind] = prof
	}
	return out, nil
}

// setTrait writes one tuned range into a profile, validated.
func setTrait(p *Profile, name string, v [2]float64) error {
	key := strings.ToLower(strings.TrimSpace(name))
	lo, hi := v[0], v[1]
	if math.IsNaN(lo) || math.IsNaN(hi) || math.IsInf(lo, 0) || math.IsInf(hi, 0) {
		return fmt.Errorf("trait %q: [%v, %v] is not a range of numbers", name, lo, hi)
	}
	if lo > hi {
		return fmt.Errorf("trait %q: low %v is above high %v", name, lo, hi)
	}
	unit := map[string]*Range{
		"tightness": &p.Tightness, "aggression": &p.Aggression, "blind_rate": &p.BlindRate, "blind_love": &p.BlindLove,
		"bluff": &p.Bluff, "mistake": &p.Mistake, "noise": &p.Noise, "adapt": &p.Adapt,
		"sideshow_rate": &p.SideshowRate, "show_rate": &p.ShowRate, "chat_rate": &p.ChatRate,
		"pace": &p.Pace, "distracted": &p.Distracted, "stake_appetite": &p.StakeAppetite, "table_moves": &p.TableMoves,
	}
	if target, ok := unit[key]; ok {
		if lo < 0 || hi > 1 {
			return fmt.Errorf("trait %q: [%v, %v] must lie within 0..1", name, lo, hi)
		}
		*target = Range{lo, hi}
		return nil
	}
	switch key {
	case "stop_loss_boots", "take_profit_boots":
		if lo < 0 {
			return fmt.Errorf("trait %q: [%v, %v] must not be negative", name, lo, hi)
		}
		if key == "stop_loss_boots" {
			p.StopLossBoots = Range{lo, hi}
		} else {
			p.TakeProfitBoots = Range{lo, hi}
		}
		return nil
	case "session_minutes":
		if lo <= 0 {
			return fmt.Errorf("trait %q: [%v, %v] must be more than 0 minutes", name, lo, hi)
		}
		p.SessionMinutes = Range{lo, hi}
		return nil
	case "hands_at_table":
		minHands, maxHands := int(math.Round(lo)), int(math.Round(hi))
		if minHands < 1 {
			return fmt.Errorf("trait %q: [%v, %v] must be at least 1 hand", name, lo, hi)
		}
		p.HandsAtTable = [2]int{minHands, maxHands}
		return nil
	}
	return fmt.Errorf("unknown trait %q (want one of %s)", name, strings.Join(TraitNames(), ", "))
}
