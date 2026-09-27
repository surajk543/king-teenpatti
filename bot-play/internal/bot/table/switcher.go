package table

import (
	"math"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/strategy"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// Move is what a bot does after a hand (brief §7).
type Move string

const (
	Stay       Move = "STAY"
	SwitchSame Move = "SWITCH"      // room:switch: another table of the same category and boot
	Hop        Move = "HOP"         // leave, then sit at a different table (stake or category)
	EndSession Move = "END_SESSION" // leave, disconnect, rest
)

// The reasons a Decision carries. Forced ones (SESSION_OVER, NOT_OFFERED,
// NOT_ADMITTED, SHORT_STACK) and IDLE_TABLE are honoured before MinHands;
// MAX_HANDS is honoured whatever MinHands says; the rest wait for MinHands.
const (
	ReasonStay          = "STAY"
	ReasonSessionOver   = "SESSION_OVER"   // the session's planned length ran out → EndSession
	ReasonNotOffered    = "NOT_OFFERED"    // the menu no longer lists this table (forced)
	ReasonNotAdmitted   = "NOT_ADMITTED"   // the stack is outside this table's band (forced)
	ReasonShortStack    = "SHORT_STACK"    // the stack no longer covers this table's boot (forced)
	ReasonIdleTable     = "IDLE_TABLE"     // no hand dealt here for IdlePatience
	ReasonMaxHands      = "MAX_HANDS"      // config table.max_hands reached
	ReasonStopLoss      = "STOP_LOSS"      // lost StopLossBoots boots at this table
	ReasonTakeProfit    = "TAKE_PROFIT"    // won TakeProfitBoots boots at this table
	ReasonUnsuitable    = "UNSUITABLE"     // the stake no longer suits the stack or the personality
	ReasonTooManyBots   = "TOO_MANY_BOTS"  // more fleet bots here than config table.max_bots_per_table
	ReasonNoHumans      = "NO_HUMANS"      // no human here for config NoHumanPatience
	ReasonTableEmptying = "TABLE_EMPTYING" // two players or fewer, none of them human
	ReasonPlannedHands  = "PLANNED_HANDS"  // this sitting's planned hands are played
	ReasonRandom        = "RANDOM"         // a natural, unprompted move
)

// SwitchInput is the situation after a hand.
type SwitchInput struct {
	Personality     strategy.Personality
	Current         Choice
	Menu            Menu
	Chips           int64
	HandsAtTable    int           // hands dealt in at this table
	PlannedHands    int           // this sitting's plan (PlanHands)
	MinHands        int           // config table.min_hands: never move before this, bar a forced reason
	MaxHands        int           // config table.max_hands
	TableNet        int64         // chips won (+) or lost (−) at this table
	Players         int           // seated players, this bot included
	FleetBots       int           // of them, bots of this fleet (this bot included)
	SinceHuman      time.Duration // how long since a player who is not a fleet bot sat here (0 = one is here now)
	Idle            time.Duration // how long the table has gone without a hand
	SessionOver     bool          // the session's planned length has run out
	MaxBotsHere     int           // config table.max_bots_per_table (0 = no limit)
	NoHumanPatience time.Duration // config: move on after this long with no human (0 = never for that reason)
	BootsToSit      float64       // config table.boots_to_sit (0 = 8): the depth a stake "suits"
}

// Decision is the move and its reason ("MAX_HANDS", "STOP_LOSS", "TAKE_PROFIT",
// "TABLE_EMPTYING", "TOO_MANY_BOTS", "NO_HUMANS", "IDLE_TABLE", "UNSUITABLE",
// "SESSION_OVER", "RANDOM", "STAY", "NOT_ADMITTED", …).
type Decision struct {
	Move   Move
	Reason string
}

// The switcher's rates.
const (
	// randomMoveBase is the per-hand chance of an unprompted wander for a bot
	// of middling TableMoves (scaled from a quarter of it to 1.75×).
	randomMoveBase = 0.03
	// hopShareBase / hopShareMoves: when a sitting ends at a table that still
	// suits, the chance it ends in a hop to another stake or category rather
	// than a switch within the same one (rare: a fleet that redistributes
	// itself often leaves whole stakes empty in waves).
	hopShareBase  = 0.08
	hopShareMoves = 0.25
	// mismatch is how far (as a share of the stake ladder) the current stake
	// may sit from the bot's appetite before the table stops suiting it.
	mismatch = 0.5
	// unsuitBase / unsuitMoves: the per-hand chance a bot acts on a stake that
	// no longer suits it (it notices, it does not bolt).
	unsuitBase  = 0.05
	unsuitMoves = 0.15
	// emptyingBase / emptyingMoves: the per-hand chance a bot leaves a table
	// down to two bots (alone, it always goes).
	emptyingBase  = 0.35
	emptyingMoves = 0.4
	// oddSitting is the chance a sitting's plan is drawn across the whole
	// configured range instead of the personality's: the regular who leaves
	// after five hands, the dropper-in who stays for twenty.
	oddSitting = 0.12
)

// IdlePatience is how long p waits at a table that deals no hand before
// looking elsewhere: 60 s for a restless bot up to 120 s for a settled one —
// longer than the server's consolidation pass (CONSOLIDATE_INTERVAL_MS,
// 15 s), which merges lone players of one stake by itself.
func IdlePatience(p strategy.Personality) time.Duration {
	return 60*time.Second + time.Duration(float64(60*time.Second)*(1-clamp01(p.TableMoves)))
}

// AfterHand decides whether to stay, switch, hop or end the session. It never
// moves before MinHands unless forced (session over, the table no longer
// admits the stack, no longer offered), and always moves at MaxHands.
//
// In order:
//  1. SESSION_OVER → EndSession.
//  2. Forced, whatever MinHands says: NOT_OFFERED (a known menu no longer
//     lists the table), SHORT_STACK (the stack no longer covers the boot),
//     NOT_ADMITTED (the stack is outside the band, read from the menu's
//     current entry). Each is a Hop when another offered table admits the
//     stack, else EndSession.
//  3. IDLE_TABLE: no hand dealt for IdlePatience → Hop (else EndSession).
//     Also before MinHands, which an idle table can never reach.
//  4. MAX_HANDS → a move, as PLANNED_HANDS below.
//  5. Before MinHands: Stay.
//  6. STOP_LOSS / TAKE_PROFIT (TableNet past ∓StopLossBoots/TakeProfitBoots
//     boots) → Hop (SwitchSame when nowhere else admits the stack).
//  7. UNSUITABLE → Hop: the stack is under half the boots-to-sit depth here
//     and a cheaper table admits it; or, now and then, the stake has drifted
//     more than half the ladder away from the bot's appetite.
//  8. TOO_MANY_BOTS, NO_HUMANS, TABLE_EMPTYING (two players or fewer and no
//     human among them — a bot never abandons a human heads-up) → SwitchSame.
//  9. PLANNED_HANDS → SwitchSame, or Hop when the stake no longer suits (and
//     rarely otherwise, more often for a restless bot).
//  10. RANDOM (a small per-hand chance scaled by TableMoves) → SwitchSame.
//  11. Stay.
//
// Deterministic for a given r; it draws only where a rule is probabilistic.
func AfterHand(in SwitchInput, r *rng.Rand) Decision {
	if in.SessionOver {
		return Decision{EndSession, ReasonSessionOver}
	}
	p := in.Personality
	cur := in.Current
	if fresh, ok := in.Menu.Lookup(cur.Key); ok {
		cur = fresh // the band as the server publishes it now
	}
	if len(in.Menu.Tables) > 0 && cur.Key != "" && !in.Menu.Offered(cur.Key) {
		return forced(in, cur, ReasonNotOffered)
	}
	if cur.Boot > 0 {
		if in.Chips < cur.Boot {
			return forced(in, cur, ReasonShortStack)
		}
		if !in.Menu.Admits(cur, in.Chips) {
			return forced(in, cur, ReasonNotAdmitted)
		}
	}
	if in.Idle > 0 && in.Idle >= IdlePatience(p) {
		return forced(in, cur, ReasonIdleTable)
	}
	if in.MaxHands > 0 && in.HandsAtTable >= in.MaxHands {
		return sittingOver(in, cur, ReasonMaxHands, r)
	}
	if in.HandsAtTable < in.MinHands {
		return Decision{Stay, ReasonStay}
	}

	boot := float64(cur.Boot)
	if boot > 0 && p.StopLossBoots > 0 && float64(in.TableNet) <= -p.StopLossBoots*boot {
		return leave(in, cur, ReasonStopLoss)
	}
	if boot > 0 && p.TakeProfitBoots > 0 && float64(in.TableNet) >= p.TakeProfitBoots*boot {
		return leave(in, cur, ReasonTakeProfit)
	}

	bootsToSit := in.BootsToSit
	if bootsToSit <= 0 {
		bootsToSit = defaultBootsToSit
	}
	if boot > 0 && float64(in.Chips) < boot*bootsToSit/2 && cheaperElsewhere(in, cur) {
		return Decision{Hop, ReasonUnsuitable}
	}
	if stakeAstray(in, cur, bootsToSit) && hopTarget(in, cur) &&
		r.Chance(unsuitBase+unsuitMoves*clamp01(p.TableMoves)) {
		return Decision{Hop, ReasonUnsuitable}
	}

	if in.MaxBotsHere > 0 && in.FleetBots > in.MaxBotsHere {
		return Decision{SwitchSame, ReasonTooManyBots}
	}
	if in.NoHumanPatience > 0 && in.SinceHuman >= in.NoHumanPatience {
		return Decision{SwitchSame, ReasonNoHumans}
	}
	noHumanHere := in.SinceHuman > 0 || (in.FleetBots > 0 && in.FleetBots >= in.Players)
	if in.Players > 0 && in.Players <= 2 && noHumanHere {
		if in.Players == 1 || r.Chance(emptyingBase+emptyingMoves*clamp01(p.TableMoves)) {
			return Decision{SwitchSame, ReasonTableEmptying}
		}
	}

	if in.PlannedHands > 0 && in.HandsAtTable >= in.PlannedHands {
		return sittingOver(in, cur, ReasonPlannedHands, r)
	}
	if r.Chance(randomMoveBase * (0.25 + 1.5*clamp01(p.TableMoves))) {
		return Decision{SwitchSame, ReasonRandom}
	}
	return Decision{Stay, ReasonStay}
}

// forced is a move the bot cannot refuse: to another table that admits its
// stack, or out of the session when none does.
func forced(in SwitchInput, cur Choice, reason string) Decision {
	if hopTarget(in, cur) {
		return Decision{Hop, reason}
	}
	return Decision{EndSession, reason}
}

// leave is a move away from this table's result (a stop-loss, a take-profit):
// another table when one admits the stack, else another of the same stake.
func leave(in SwitchInput, cur Choice, reason string) Decision {
	if hopTarget(in, cur) {
		return Decision{Hop, reason}
	}
	return Decision{SwitchSame, reason}
}

// sittingOver is the end of a sitting's hands: a switch within the same
// stake, or a hop when the stake no longer suits the bot (and rarely
// otherwise).
func sittingOver(in SwitchInput, cur Choice, reason string, r *rng.Rand) Decision {
	if !hopTarget(in, cur) {
		return Decision{SwitchSame, reason}
	}
	bootsToSit := in.BootsToSit
	if bootsToSit <= 0 {
		bootsToSit = defaultBootsToSit
	}
	if stakeAstray(in, cur, bootsToSit) || r.Chance(hopShareBase+hopShareMoves*clamp01(in.Personality.TableMoves)) {
		return Decision{Hop, reason}
	}
	return Decision{SwitchSame, reason}
}

// hopTarget reports whether another offered Teen Patti table admits the stack.
func hopTarget(in SwitchInput, cur Choice) bool {
	for _, t := range in.Menu.Tables {
		if t.Key != cur.Key && IsTeenPatti(t.Category) && in.Menu.Admits(t, in.Chips) {
			return true
		}
	}
	return false
}

// cheaperElsewhere reports whether an offered table with a lower boot than
// cur admits the stack.
func cheaperElsewhere(in SwitchInput, cur Choice) bool {
	for _, t := range in.Menu.Tables {
		if t.Boot < cur.Boot && IsTeenPatti(t.Category) && in.Menu.Admits(t, in.Chips) {
			return true
		}
	}
	return false
}

// stakeAstray reports whether cur's stake sits more than `mismatch` of the
// ladder away from the bot's appetite, the ladder being the stakes the stack
// can sit at bootsToSit boots deep (the selector's). A ladder of one rung
// never strays.
func stakeAstray(in SwitchInput, cur Choice, bootsToSit float64) bool {
	var reach []Choice
	for _, t := range in.Menu.Tables {
		if IsTeenPatti(t.Category) && in.Menu.Admits(t, in.Chips) && affords(in.Chips, t.Boot, bootsToSit) {
			reach = append(reach, t)
		}
	}
	levels := distinctBoots(reach)
	if len(levels) < 2 {
		return false
	}
	return math.Abs(ladderPosition(cur.Boot, levels)-appetite(in.Personality)) > mismatch
}

// PlanHands draws this sitting's planned hands inside [minHands, maxHands],
// shaped by the personality (a regular stays long, a dropper-in leaves
// early) and varied per sitting.
//
// The draw lies in the personality's HandsAtTable range clamped to the
// configured one (the whole configured range when the personality names
// none), skewed towards its short end by TableMoves (u^(0.6+1.6·TableMoves)
// of the way up: a settled bot's sittings run long, a restless bot's short);
// about one sitting in eight is drawn across the whole configured range
// instead. minHands below 1 is 1; maxHands below minHands is minHands.
func PlanHands(p strategy.Personality, minHands, maxHands int, r *rng.Rand) int {
	lo := max(1, minHands)
	hi := max(lo, maxHands)
	plo, phi := lo, hi
	if p.HandsAtTable[0] > 0 || p.HandsAtTable[1] > 0 {
		a, b := p.HandsAtTable[0], p.HandsAtTable[1]
		if b < a {
			a, b = b, a
		}
		plo = min(max(a, lo), hi)
		phi = min(max(b, lo), hi)
	}
	if r.Chance(oddSitting) {
		plo, phi = lo, hi
	}
	e := 0.6 + 1.6*clamp01(p.TableMoves)
	n := plo + int(math.Pow(r.Float64(), e)*float64(phi-plo+1))
	return min(n, phi)
}
