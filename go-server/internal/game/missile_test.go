package game

// Missile (owner, 14 Sep 2026): the player on turn pays one missile and every
// hand still in is shown, the best taking the pot. The rules pinned here: it
// needs three players in the hand and the turn, and no sideshow may be
// pending; blind and seen players alike may fire; it is paid for before the
// table changes, and a refusal — no missiles, or a wallet that cannot be
// written — changes nothing; a retry is never charged twice; an exact tie goes
// against the player who fired; and the next deal waits for the reveal.

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

const missileExtra = 3 * time.Second

// withMissiles gives the table a missile wallet.
func withMissiles(w MissileWallet) harnessOption {
	return func(o *harnessOptions) { o.missiles = w }
}

func missileConfig() TableConfig {
	cfg := sideshowConfig()
	cfg.MissileRevealExtra = missileExtra
	return cfg
}

// missileTable seats count players with 5 missiles each and deals; seen says
// whether everyone looks at their cards first.
func missileTable(t *testing.T, count int, seen bool) (*harness, []string, *MemoryMissiles) {
	t.Helper()
	wallet := NewMemoryMissiles(nil)
	h := newHarness(t, missileConfig(), withLedger(emptyLedger), withMissiles(wallet), withID("missile-room", "MISSILE1"))
	var ids []string
	for i := 0; i < count; i++ {
		id := "p" + string(rune('0'+i))
		ids = append(ids, id)
		wallet.Set(id, 5)
		h.seatNamed(id, strings.ToUpper(id), sideshowStart)
	}
	// Dealt by the countdown the seating armed, as production deals, so the
	// table has no start timer left over when the hand ends.
	h.advance(missileConfig().NextHandDelay)
	eq(t, h.handNo(), 1, "the first hand is dealt")
	if seen {
		for _, id := range ids {
			h.mustAct(id, ActionSee, ActRequest{})
		}
	}
	return h, ids, wallet
}

func fire(id string) ActRequest { return ActRequest{ActionID: id} }

func except(ids []string, drop ...string) []string {
	var out []string
	for _, id := range ids {
		keep := true
		for _, d := range drop {
			if id == d {
				keep = false
			}
		}
		if keep {
			out = append(out, id)
		}
	}
	return out
}

// ------------------------------------------------------------- the outcome

func TestAMissileShowsEveryPlayerStillInTheHandAndPaysTheBestHand(t *testing.T) {
	h, ids, wallet := missileTable(t, 4, true)
	folder := h.turnUser()
	h.mustAct(folder, ActionPack, ActRequest{})
	firer := h.turnUser()
	rest := except(ids, folder, firer)
	best, weak := rest[0], rest[1]
	h.setCards(firer, "Ks", "Kh", "4d")  // a pair
	h.setCards(best, "As", "Ah", "Ad")   // a trail
	h.setCards(weak, "2s", "7h", "9d")   // high card
	h.setCards(folder, "Qs", "Qh", "Qc") // would beat the pair, but packed
	pot, stake := h.pot(), h.stake()

	eq(t, h.view(firer).You.CanMissile, true, "you.canMissile")
	eq(t, h.turnOptions(firer).CanMissile, true, "options.canMissile")

	started := h.clock.Now()
	mark := h.rec.count()
	res := h.mustAct(firer, ActionMissile, fire("missile-1"))

	raw, _ := json.Marshal(res)
	eq(t, string(raw), `{"action":"missile","missiles":4}`, "ack")
	eq(t, wallet.Balance(firer), int64(4), "one missile spent")
	eq(t, wallet.Charges(), 1, "charged once")
	for _, id := range except(ids, firer) {
		eq(t, wallet.Balance(id), int64(5), id+" pays nothing")
	}

	names := h.rec.names()[mark:]
	if len(names) < 3 || strings.Join(names[:3], ",") != "action,showdown,handEnded" {
		t.Fatalf("event order %v, want action, showdown, handEnded first", names)
	}

	action := h.lastAction()
	rawAction, _ := json.Marshal(action)
	eq(t, string(rawAction), `{"userId":"`+firer+`","action":"missile","amount":0,"pot":`+jsonInt(pot)+`,"stake":`+jsonInt(stake)+`}`, "game:action")

	showdown := h.lastShowdown()
	eq(t, showdown.Reason, WinMissile, "showdown reason")
	eq(t, len(showdown.Reveals), 3, "every player still in is shown, the packed one is not")
	for _, r := range showdown.Reveals {
		if r.UserID == folder {
			t.Fatal("a packed hand was revealed")
		}
		eq(t, len(r.Cards), 3, r.UserID+" cards")
		eq(t, r.Won, r.UserID == best, r.UserID+" won")
	}

	ended := h.lastHandEnded()
	eq(t, ended.Reason, WinMissile, "handEnded reason")
	eq(t, *ended.WinnerID, best, "the best hand wins")
	eq(t, *ended.WinnerName, strings.ToUpper(best), "winnerName")
	eq(t, ended.Pot, pot, "pot")
	eq(t, len(ended.Reveals), 3, "handEnded reveals")
	eq(t, ended.NextHandAt, Millis(started.Add(missileConfig().NextHandDelay+missileExtra)), "nextHandAt waits for the reveal")

	eq(t, h.mustSeat(best).Chips, sideshowStart-sideshowBoot+pot, "the winner is paid the pot")
	eq(t, h.mustSeat(best).Status, SeatWon, "winner status")
	eq(t, h.mustSeat(firer).Chips, sideshowStart-sideshowBoot, "firing costs no chips")
	eq(t, h.mustSeat(firer).Status, SeatLost, "the firer lost")
	eq(t, h.mustSeat(weak).Status, SeatLost, "the weak hand lost")
	eq(t, h.mustSeat(folder).Status, SeatPacked, "the folder stays packed")
	settled := h.lastSettled()
	eq(t, len(settled.entries), 4, "the hand end settles everyone who put in a boot")
	for _, e := range settled.entries {
		eq(t, e.Reason == LedgerReasonHandWin, e.UserID == best, e.UserID+" row reason")
	}

	// The deal waits for the reveal: not at the ordinary delay, but when
	// handEnded said.
	view := h.view(best)
	if view.StartsAt == nil || *view.StartsAt != ended.NextHandAt {
		t.Fatalf("startsAt %v, want the handEnded nextHandAt %d", view.StartsAt, ended.NextHandAt)
	}
	h.advance(missileConfig().NextHandDelay)
	eq(t, h.handNo(), 1, "not dealt at the ordinary delay")
	h.advance(missileExtra)
	eq(t, h.handNo(), 2, "dealt at nextHandAt")

	// …and the hold is spent: the next hand end counts down as ever.
	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	next := h.lastHandEnded()
	eq(t, next.NextHandAt, Millis(h.clock.Now().Add(missileConfig().NextHandDelay)), "an ordinary hand end")
	if v := h.view(best); v.StartsAt == nil || *v.StartsAt != next.NextHandAt {
		t.Fatalf("an ordinary countdown after a missile: startsAt %v, want %d", v.StartsAt, next.NextHandAt)
	}
}

func jsonInt(n int64) string {
	raw, _ := json.Marshal(n)
	return string(raw)
}

// An exact tie goes against the player who fired, wherever the dealer sits: the
// firer stands where a show payer stands in the tie order. Played over three
// hands, so the dealer moves round the table.
func TestAMissileTieGoesAgainstThePlayerWhoFiredIt(t *testing.T) {
	h, ids, _ := missileTable(t, 3, true)
	for hand := 1; hand <= 3; hand++ {
		eq(t, h.handNo(), hand, "hand")
		firer := h.turnUser()
		others := except(ids, firer)
		// Suits never break a tie: all three hold the same ranks.
		h.setCards(firer, "Ah", "9d", "5c")
		h.setCards(others[0], "Ad", "9c", "5h")
		h.setCards(others[1], "Ac", "9h", "5d")
		h.mustAct(firer, ActionMissile, fire("tie"))
		ended := h.lastHandEnded()
		if *ended.WinnerID == firer {
			t.Fatalf("hand %d: the firer won a three-way tie", hand)
		}
		eq(t, h.mustSeat(firer).Status, SeatLost, "the firer loses the tie")
		h.advance(missileConfig().NextHandDelay + missileExtra)
	}

	// A tie with one player, the third weaker: the other tied hand wins.
	firer := h.turnUser()
	others := except(ids, firer)
	h.setCards(firer, "Ks", "Kh", "4d")
	h.setCards(others[0], "Kd", "Kc", "4s")
	h.setCards(others[1], "2s", "7h", "9d")
	h.mustAct(firer, ActionMissile, fire("tie-two"))
	eq(t, *h.lastHandEnded().WinnerID, others[0], "the tied player who did not fire wins")
}

// Blind and seen players alike may fire: a missile reveals every hand, the
// firer's own included, and a blind firer is paid like anyone else.
func TestABlindPlayerCanFireAMissile(t *testing.T) {
	h, ids, wallet := missileTable(t, 3, false)
	firer := h.turnUser()
	for _, id := range ids {
		eq(t, h.mustSeat(id).IsBlind, true, id+" is blind")
	}
	eq(t, h.view(firer).You.CanMissile, true, "a blind player is offered a missile")
	h.setCards(firer, "As", "Ah", "Ad")
	for _, id := range except(ids, firer) {
		h.setCards(id, "2s", "7h", "9d")
	}
	pot := h.pot()

	res := h.mustAct(firer, ActionMissile, fire("blind"))
	eq(t, *res.Missiles, int64(4), "ack missiles")
	eq(t, wallet.Charges(), 1, "charged")
	ended := h.lastHandEnded()
	eq(t, *ended.WinnerID, firer, "the blind firer's trail wins")
	eq(t, len(h.lastShowdown().Reveals), 3, "every blind hand is shown")
	eq(t, h.mustSeat(firer).Chips, sideshowStart-sideshowBoot+pot, "and is paid")
}

// ------------------------------------------------------------- the refusals

func TestAMissileNeedsThreePlayersInTheHand(t *testing.T) {
	refused := func(t *testing.T, h *harness, wallet *MemoryMissiles, id string) {
		t.Helper()
		eq(t, h.view(id).You.CanMissile, false, "canMissile")
		_, err := h.act(id, ActionMissile, fire("few"))
		codeIs(t, err, CodeTooFewPlayers)
		var ge *GameError
		if errors.As(err, &ge) {
			eq(t, ge.Message, "A missile needs at least 3 players in the hand", "message")
		}
		eq(t, wallet.Charges(), 0, "nothing spent")
		eq(t, h.hasHand(), true, "the hand goes on")
	}
	t.Run("two dealt in", func(t *testing.T) {
		h, _, wallet := missileTable(t, 2, true)
		refused(t, h, wallet, h.turnUser())
	})
	t.Run("three dealt in, one packed", func(t *testing.T) {
		h, _, wallet := missileTable(t, 3, true)
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
		refused(t, h, wallet, h.turnUser())
	})
	t.Run("three in the hand is enough", func(t *testing.T) {
		h, _, wallet := missileTable(t, 3, true)
		h.mustAct(h.turnUser(), ActionMissile, fire("three"))
		eq(t, wallet.Charges(), 1, "fired")
	})
}

// The refusals come in the documented order — no_hand, not_in_hand,
// not_your_turn, sideshow_pending, too_few_players — and none spends a missile.
func TestAMissileNeedsYourTurnAndNoSideshowPending(t *testing.T) {
	t.Run("no_hand", func(t *testing.T) {
		wallet := NewMemoryMissiles(map[string]int64{"a": 5})
		h := newHarness(t, missileConfig(), withLedger(emptyLedger), withMissiles(wallet))
		h.seat("a", sideshowStart)
		_, err := h.act("a", ActionMissile, fire("no-hand"))
		codeIs(t, err, CodeNoHand)
		eq(t, wallet.Charges(), 0, "nothing spent")
	})
	t.Run("not_in_hand", func(t *testing.T) {
		h, _, wallet := missileTable(t, 4, true)
		packer := h.turnUser()
		h.mustAct(packer, ActionPack, ActRequest{})
		_, err := h.act(packer, ActionMissile, fire("packed"))
		codeIs(t, err, CodeNotInHand)
		eq(t, wallet.Charges(), 0, "nothing spent")
	})
	t.Run("not_your_turn", func(t *testing.T) {
		h, ids, wallet := missileTable(t, 3, true)
		actor := h.turnUser()
		for _, id := range except(ids, actor) {
			_, err := h.act(id, ActionMissile, fire("off-"+id))
			codeIs(t, err, CodeNotYourTurn)
		}
		eq(t, wallet.Charges(), 0, "nothing spent")
		eq(t, h.turnUser(), actor, "the turn did not move")
	})
	t.Run("sideshow_pending", func(t *testing.T) {
		h, _, wallet := missileTable(t, 3, true)
		actor := h.turnUser()
		h.mustAct(actor, ActionSideshow, ActRequest{})
		_, err := h.act(actor, ActionMissile, fire("pending"))
		codeIs(t, err, CodeSideshowPending)
		var ge *GameError
		if errors.As(err, &ge) {
			eq(t, ge.Message, MsgSideshowPending, "message")
		}
		eq(t, h.sideshowPending(), true, "the request stands")
		eq(t, wallet.Charges(), 0, "nothing spent")
	})
}

func TestAMissileWithNoMissilesIsRefusedAndChangesNothing(t *testing.T) {
	h, _, wallet := missileTable(t, 3, true)
	actor := h.turnUser()
	wallet.Set(actor, 0)
	before := snapshotJSON(t, h)
	mark := h.rec.count()

	_, err := h.act(actor, ActionMissile, fire("broke-1"))
	codeIs(t, err, CodeNoMissiles)
	var ge *GameError
	if errors.As(err, &ge) {
		eq(t, ge.Message, "You need a missile to fire", "message")
	}
	eq(t, snapshotJSON(t, h), before, "the table state is exactly as it was")
	eq(t, h.rec.count(), mark, "nobody was told anything")
	eq(t, wallet.Charges(), 0, "nothing spent")
	eq(t, h.view(actor).You.CanMissile, true, "canMissile says nothing about the wallet")

	wallet.Set(actor, 1)
	res := h.mustAct(actor, ActionMissile, fire("broke-2"))
	raw, _ := json.Marshal(res)
	eq(t, string(raw), `{"action":"missile","missiles":0}`, "the ack reports none left, not an absent count")
}

func TestAMissileWalletThatCannotBeWrittenRefusesTheMoveAndChangesNothing(t *testing.T) {
	h, _, wallet := missileTable(t, 3, true)
	actor := h.turnUser()
	wallet.Fail = func(MissileSpend) error { return errors.New("connection reset by peer") }
	before := snapshotJSON(t, h)
	mark := h.rec.count()

	_, err := h.act(actor, ActionMissile, fire("down-1"))
	codeIs(t, err, CodePersistFailed)
	eq(t, snapshotJSON(t, h), before, "the table state is exactly as it was")
	eq(t, strings.Join(h.rec.names()[mark:], ","), "persistError", "only the refused write is reported")
	if e, ok := h.rec.last("persistError").(PersistErrorEvent); !ok || e.Reason != PersistReasonMissileSpend || e.UserID != actor {
		t.Fatalf("persistError %+v", h.rec.last("persistError"))
	}
	eq(t, wallet.Balance(actor), int64(5), "nothing spent")

	wallet.Fail = nil
	h.mustAct(actor, ActionMissile, fire("down-2"))
	eq(t, wallet.Balance(actor), int64(4), "the next try, with the wallet back, is charged once")
}

// A table built without a wallet refuses every missile rather than firing one
// free.
func TestATableWithoutAMissileWalletNeverFiresOneFree(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	_, err := h.act(h.turnUser(), ActionMissile, fire("free"))
	codeIs(t, err, CodeNoMissiles)
	eq(t, h.hasHand(), true, "nothing resolved")
}

// ------------------------------------------------------------- idempotency

// A spend that committed but whose answer was lost refuses the move — the table
// cannot know it was paid — and the retry with the same actionId gets the
// showdown it paid for without paying again. The key names the hand, so the
// same actionId from the same player in the next hand is a new missile.
func TestARetriedMissileWithTheSameActionIdIsChargedOnce(t *testing.T) {
	h, _, wallet := missileTable(t, 3, true)
	actor := h.turnUser()
	lose := true
	wallet.LoseAck = func(MissileSpend) bool { return lose }
	before := snapshotJSON(t, h)

	_, err := h.act(actor, ActionMissile, fire("retry-1"))
	codeIs(t, err, CodePersistFailed)
	eq(t, wallet.Charges(), 1, "the commit landed")
	eq(t, wallet.Balance(actor), int64(4), "one missile gone")
	eq(t, snapshotJSON(t, h), before, "but the table did not resolve anything")

	lose = false
	res := h.mustAct(actor, ActionMissile, fire("retry-1"))
	eq(t, wallet.Charges(), 1, "the retry is not charged")
	eq(t, *res.Missiles, int64(4), "the ack reports the wallet as it stands")
	eq(t, len(h.rec.all("showdown")), 1, "and the showdown happened, once")
	eq(t, h.hasHand(), false, "the hand is over")

	h.advance(missileConfig().NextHandDelay + missileExtra)
	eq(t, h.handNo(), 2, "the next hand is dealt")
	for h.turnUser() != actor {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	res = h.mustAct(actor, ActionMissile, fire("retry-1"))
	eq(t, wallet.Charges(), 2, "the same id in the next hand is a new missile")
	eq(t, *res.Missiles, int64(3), "from the same player")
}

// ------------------------------------------------------------- canMissile

// you.canMissile (and options.canMissile beside canForceSideshow) is true
// exactly when the rules would let a missile through: every false is a refusal
// that spends nothing, and the one true goes through.
func TestCanMissileIsTrueExactlyWhenAMissileIsAllowed(t *testing.T) {
	// Between hands nobody may fire, and the key is on the wire as false.
	lone := newHarness(t, missileConfig(), withLedger(emptyLedger))
	lone.seat("a", sideshowStart)
	rawYou, _ := json.Marshal(lone.view("a").You)
	if !strings.Contains(string(rawYou), `"canMissile":false`) {
		t.Fatalf("you carries canMissile:false between hands: %s", rawYou)
	}

	h, ids, wallet := missileTable(t, 3, true)
	check := func(what string) {
		t.Helper()
		for _, id := range ids {
			view := h.view(id)
			if view.You == nil {
				continue
			}
			allowed := view.You.CanMissile
			var blocked string
			h.read(func() { blocked = h.table.missileBlockedReason(h.table.findSeat(id)) })
			eq(t, allowed, blocked == "", what+": "+id+" canMissile matches the rules")
			if view.You.Options != nil {
				eq(t, view.You.Options.CanMissile, allowed, what+": "+id+" options.canMissile")
			}
			if !allowed {
				charges := wallet.Charges()
				if _, err := h.act(id, ActionMissile, fire("probe-"+id)); err == nil || CodeOf(err, "") == CodeNoMissiles {
					t.Fatalf("%s: %s is not offered a missile but was not refused by the rules: %v", what, id, err)
				}
				eq(t, wallet.Charges(), charges, what+": a refusal spends nothing")
			}
		}
	}

	actor := h.turnUser()
	check("a hand of three")
	eq(t, h.view(actor).You.CanMissile, true, "the player on turn")
	rawOpts, _ := json.Marshal(h.view(actor).You.Options)
	if !strings.Contains(string(rawOpts), `"canForceSideshow":true,"canMissile":true`) {
		t.Fatalf("options carry canMissile beside canForceSideshow: %s", rawOpts)
	}

	h.mustAct(actor, ActionSideshow, ActRequest{})
	check("a sideshow pending")
	eq(t, h.view(actor).You.CanMissile, false, "not while the sideshow stands")

	h.mustRespond(h.rightOf(actor), false)
	check("the sideshow declined")
	eq(t, h.view(actor).You.CanMissile, true, "offered again once it is answered")

	h.mustAct(actor, ActionPack, ActRequest{})
	check("two left")
	for _, id := range ids {
		eq(t, h.view(id).You.CanMissile, false, id+" with two left")
	}
	eq(t, wallet.Charges(), 0, "nothing was ever spent")
}

// ------------------------------------------------------------- restore

// A table saved while it waits out a missile's reveal comes back with the same
// countdown and the same extra delay configured.
func TestAMissileRevealSurvivesASnapshotRoundTrip(t *testing.T) {
	h, ids, wallet := missileTable(t, 3, true)
	h.mustAct(h.turnUser(), ActionMissile, fire("saved"))
	ended := h.lastHandEnded()

	snap := mustSnapshot(h)
	eq(t, snap.Config.MissileRevealExtraMs, missileExtra.Milliseconds(), "config carries the extra")
	if snap.StartsAt == nil || *snap.StartsAt != ended.NextHandAt {
		t.Fatalf("snapshot startsAt %v, want %d", snap.StartsAt, ended.NextHandAt)
	}
	assertRoundTrip(t, h, 0)

	r, err := RestoreTable(roundTrip(t, snap), TableOptions{Clock: h.clock, Ledger: NewMemoryLedger(MemoryLedgerHooks{}), Missiles: wallet})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = r.Destroy() }()
	eq(t, r.Config().MissileRevealExtra, missileExtra, "restored config")
	view, err := r.SerializeFor(ids[0])
	if err != nil || view.StartsAt == nil || *view.StartsAt != ended.NextHandAt {
		t.Fatalf("restored startsAt %v (%v), want %d", view.StartsAt, err, ended.NextHandAt)
	}
}
