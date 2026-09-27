package state

import (
	"container/list"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// OpponentRead is what one bot has noticed about another player this
// session (brief §15). Lightweight, in memory, never persisted.
type OpponentRead struct {
	Hands      int     // hands seen together
	Actions    int     // betting actions observed
	Aggression float64 // 0..1: raises (and blind raises) among their bets
	Looseness  float64 // 0..1: how rarely they fold
	FoldRate   float64 // 0..1
	BlindRate  float64 // 0..1: bets made blind
	Style      string  // "unknown" | "passive" | "aggressive" | "tight" | "loose"
}

// The styles an OpponentRead names.
const (
	StyleUnknown    = "unknown"    // too little seen, or nothing about them stands out
	StylePassive    = "passive"    // calls, seldom raises
	StyleAggressive = "aggressive" // raises a large share of their bets
	StyleTight      = "tight"      // folds most hands, shows down strong ones
	StyleLoose      = "loose"      // rarely folds, shows down weak hands
)

// The reads' small-sample prior and the style thresholds.
//
// Every rate is shrunk towards Neutral with PriorWeight pseudo-observations:
// rate = (count + Neutral·PriorWeight) / (n + PriorWeight). With nothing seen
// a rate is exactly Neutral; after a handful of observations it has moved
// part of the way to what was seen; after dozens it is what was seen.
const (
	Neutral     = 0.5
	PriorWeight = 4.0

	// styleMinActions: no style is named from fewer observed actions.
	styleMinActions = 6
	// A style is named when its (shrunk) figure is past its threshold; with
	// several past theirs, the one furthest past wins. Every threshold lies
	// strictly outside Neutral, so the prior alone never names a style: it
	// takes evidence — for instance eight bets with none raised (passive),
	// five of eight raised (aggressive), seven of ten hands folded (tight).
	aggressiveFrom = 0.55
	passiveBelow   = 0.30
	looseFrom      = 0.65
	tightBelow     = 0.35
	// weakShowdown is the best hand category that counts as a weak one to
	// have gone to a showdown with: a pair or a high card.
	weakShowdown = protocol.HandPair
)

// opponent is one player's counters.
type opponent struct {
	id string

	hands     int // hands dealt in with the bot
	actions   int // betting decisions: bets, folds, shows, sideshow asks
	calls     int // chaal
	raises    int // raise (the server reports a chaal that is a raise as "raise")
	shows     int // show (a paid call to the showdown)
	folds     int // voluntary packs (not a timeout, a lost sideshow or a leave)
	timeouts  int // packed by the turn clock
	blindBets int // chaal, raise or show while blind
	sees      int // looked at their cards (by choice, not the forced reveal)
	sideshows int // asked for a sideshow (forced ones included)

	showdowns     int // hands shown at a showdown
	weakShowdowns int // … of which a pair or worse
}

// bets is every paid betting action.
func (o *opponent) bets() int { return o.calls + o.raises + o.shows }

// OpponentBook is one bot's per-opponent session statistics. Bounded: the
// least recently seen opponents are forgotten past capacity. Owned by the
// bot's loop (not safe for concurrent use).
//
// "Seen" is being dealt in with the bot, making a move or showing a hand;
// reading a player's figures does not keep them in the book.
type OpponentBook struct {
	capacity int
	byID     map[string]*list.Element // → *opponent
	order    *list.List               // front = most recently seen
	ignore   map[string]bool
}

// NewOpponentBook remembers at most capacity opponents (≤ 0: 256).
func NewOpponentBook(capacity int) *OpponentBook {
	if capacity <= 0 {
		capacity = 256
	}
	return &OpponentBook{
		capacity: capacity,
		byID:     make(map[string]*list.Element, capacity),
		order:    list.New(),
		ignore:   map[string]bool{},
	}
}

// Ignore makes the book record nothing about userID — the bot's own id, so
// its own moves and its own hand at a showdown (which the server's events
// carry beside everyone else's) never enter its reads of the table. Any
// record already held for userID is dropped.
func (b *OpponentBook) Ignore(userID string) {
	if userID == "" {
		return
	}
	b.ignore[userID] = true
	if e, ok := b.byID[userID]; ok {
		b.order.Remove(e)
		delete(b.byID, userID)
	}
}

// Len is how many players the book holds.
func (b *OpponentBook) Len() int { return len(b.byID) }

// touch is userID's record, created if new, made most recent; nil for an
// empty or ignored id. Past capacity the least recently seen is forgotten.
func (b *OpponentBook) touch(userID string) *opponent {
	if userID == "" || b.ignore[userID] {
		return nil
	}
	if e, ok := b.byID[userID]; ok {
		b.order.MoveToFront(e)
		return e.Value.(*opponent)
	}
	o := &opponent{id: userID}
	b.byID[userID] = b.order.PushFront(o)
	for len(b.byID) > b.capacity {
		last := b.order.Back()
		b.order.Remove(last)
		delete(b.byID, last.Value.(*opponent).id)
	}
	return o
}

// HandDealt records that these players (not the bot itself) were dealt into
// a hand with the bot.
//
// A player named twice in one call is counted once.
func (b *OpponentBook) HandDealt(userIDs []string) {
	counted := make(map[string]bool, len(userIDs))
	for _, id := range userIDs {
		if counted[id] {
			continue
		}
		counted[id] = true
		if o := b.touch(id); o != nil {
			o.hands++
		}
	}
}

// Observe records another player's move; blind says whether their seat was
// still blind when they made it.
//
// A chaal is a call and a raise a raise (the server broadcasts a chaal that
// climbed the ladder as "raise"); a show is a paid call to the showdown. A
// pack counts as a fold only when the player chose it: a pack by the turn
// clock (reason "timeout"), the loser's pack of a sideshow ("sideshow") and a
// departure's pack (a leave reason) say nothing about how they play. A look
// counts unless it was the forced reveal after the last blind move (auto).
// Sideshow asks, forced ones included, are actions; a missile is an action
// and nothing more.
func (b *OpponentBook) Observe(ev protocol.ActionEvent, blind bool) {
	switch ev.Action {
	case protocol.ActionChaal, protocol.ActionRaise, protocol.ActionShow,
		protocol.ActionPack, protocol.ActionSee, protocol.ActionSideshow,
		protocol.ActionForceSideshow, protocol.ActionMissile:
	default:
		return // not a move this book reads
	}
	o := b.touch(ev.UserID)
	if o == nil {
		return
	}
	switch ev.Action {
	case protocol.ActionChaal, protocol.ActionRaise, protocol.ActionShow:
		o.actions++
		switch ev.Action {
		case protocol.ActionChaal:
			o.calls++
		case protocol.ActionRaise:
			o.raises++
		default:
			o.shows++
		}
		if blind {
			o.blindBets++
		}
	case protocol.ActionPack:
		switch ev.Reason {
		case "", "pack":
			o.actions++
			o.folds++
		case "timeout":
			o.timeouts++
		}
	case protocol.ActionSee:
		if ev.Auto == nil || !*ev.Auto {
			o.sees++
		}
	case protocol.ActionSideshow, protocol.ActionForceSideshow:
		o.actions++
		o.sideshows++
	case protocol.ActionMissile:
		o.actions++
	}
}

// Showdown records the hands shown at a showdown (who went to showdown with
// what).
//
// A reveal of a pair or worse is a weak hand to have gone the distance with
// — the loose player's mark; a player who only ever shows down strong hands
// reads tight.
func (b *OpponentBook) Showdown(reveals []protocol.Reveal) {
	for _, rv := range reveals {
		o := b.touch(rv.UserID)
		if o == nil {
			continue
		}
		o.showdowns++
		if rv.Category <= weakShowdown {
			o.weakShowdowns++
		}
	}
}

// Read is what the bot knows of one player ("unknown" style with no data).
//
//   - FoldRate is voluntary folds per hand dealt.
//   - Aggression is raises among paid bets (chaal, raise, show).
//   - BlindRate is bets made blind among paid bets.
//   - Looseness pools two kinds of evidence, one observation each: every hand
//     dealt (loose when they did not fold it) and every showdown (loose when
//     the hand shown was a pair or worse).
//
// Each is shrunk towards Neutral (PriorWeight pseudo-observations), so a
// player seen twice reads close to 0.5 on everything. Reading does not
// refresh the player's place in the book.
func (b *OpponentBook) Read(userID string) OpponentRead {
	e, ok := b.byID[userID]
	if !ok {
		return neutralRead()
	}
	o := e.Value.(*opponent)
	hands := max(o.hands, o.folds) // a fold is always in a hand, dealt or not recorded
	r := OpponentRead{
		Hands:      o.hands,
		Actions:    o.actions,
		Aggression: shrink(o.raises, o.bets()),
		FoldRate:   shrink(o.folds, hands),
		BlindRate:  shrink(o.blindBets, o.bets()),
		Looseness:  shrink(hands-o.folds+o.weakShowdowns, hands+o.showdowns),
	}
	r.Style = styleOf(r)
	return r
}

// Summary is the reads of these players averaged, weighted by how much each
// has been seen; "unknown" with no data.
//
// A player's weight is their hands plus their actions; a player the book
// does not hold weighs nothing, and a player named twice counts once. Hands
// and Actions are the sums; the style is named from the averaged figures,
// with the summed actions as the evidence.
func (b *OpponentBook) Summary(userIDs []string) OpponentRead {
	out := OpponentRead{}
	var agg, loose, fold, blind, total float64
	counted := make(map[string]bool, len(userIDs))
	for _, id := range userIDs {
		if counted[id] {
			continue
		}
		counted[id] = true
		if _, ok := b.byID[id]; !ok {
			continue
		}
		r := b.Read(id)
		w := float64(r.Hands + r.Actions)
		if w <= 0 {
			continue
		}
		out.Hands += r.Hands
		out.Actions += r.Actions
		agg += w * r.Aggression
		loose += w * r.Looseness
		fold += w * r.FoldRate
		blind += w * r.BlindRate
		total += w
	}
	if total <= 0 {
		return neutralRead()
	}
	out.Aggression = agg / total
	out.Looseness = loose / total
	out.FoldRate = fold / total
	out.BlindRate = blind / total
	out.Style = styleOf(out)
	return out
}

// neutralRead is the read of a player nothing is known about.
func neutralRead() OpponentRead {
	return OpponentRead{Aggression: Neutral, Looseness: Neutral, FoldRate: Neutral, BlindRate: Neutral, Style: StyleUnknown}
}

// shrink is count/n pulled towards Neutral by PriorWeight pseudo-observations.
func shrink(count, n int) float64 {
	if n < 0 {
		n = 0
	}
	count = min(max(count, 0), n)
	return (float64(count) + Neutral*PriorWeight) / (float64(n) + PriorWeight)
}

// styleOf names the style a read shows: unknown below styleMinActions, else
// the figure furthest past its threshold, else unknown (nothing stands out).
func styleOf(r OpponentRead) string {
	if r.Actions < styleMinActions {
		return StyleUnknown
	}
	best, margin := StyleUnknown, 0.0
	consider := func(style string, m float64) {
		if m > margin {
			best, margin = style, m
		}
	}
	consider(StyleAggressive, r.Aggression-aggressiveFrom)
	consider(StylePassive, passiveBelow-r.Aggression)
	consider(StyleLoose, r.Looseness-looseFrom)
	consider(StyleTight, tightBelow-r.Looseness)
	return best
}
