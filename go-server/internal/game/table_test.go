package game

// Port of server/test/table.test.js plus the direct-Table cases of
// categories.test.js, blindRules.test.js, raiseLadder.test.js, chat.test.js
// and privateTables.test.js, and the actor/property tests the Node suite had
// no need for. Every scenario keeps the Node test's setup and assertions
// (same config, same error codes); the fake clock stands in for fakeTimers
// and the recording Listener for `table.on(...)`.
//
// Helper discipline: the Table is an actor. Reads of actor state in these
// tests go through h.read (a posted closure) and are never made from inside a
// Listener callback — that would post to the actor delivering the callback.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// ------------------------------------------------------------ fake clock
//
// testclock.Fake cannot be imported here (it imports package game; these
// white-box tests are package game), so this is the same clock, verbatim in
// semantics: Advance fires due timers in deadline order, each callback run to
// completion with Now() at its deadline — server/test/helpers/fakeTimers.js.

type fakeClock struct {
	mu      sync.Mutex
	now     time.Time
	nextID  int
	pending map[int]*fakeEntry
}

type fakeEntry struct {
	id int
	at time.Time
	fn func()
}

type fakeTimer struct {
	c  *fakeClock
	id int
}

func (t *fakeTimer) Stop() bool {
	t.c.mu.Lock()
	defer t.c.mu.Unlock()
	if _, ok := t.c.pending[t.id]; !ok {
		return false
	}
	delete(t.c.pending, t.id)
	return true
}

func newFakeClock(start time.Time) *fakeClock {
	return &fakeClock{now: start, pending: map[int]*fakeEntry{}}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) AfterFunc(d time.Duration, fn func()) Timer {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.nextID++
	e := &fakeEntry{id: c.nextID, at: c.now.Add(d), fn: fn}
	c.pending[e.id] = e
	return &fakeTimer{c: c, id: e.id}
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	target := c.now.Add(d)
	c.mu.Unlock()
	for {
		c.mu.Lock()
		var due []*fakeEntry
		for _, e := range c.pending {
			if !e.at.After(target) {
				due = append(due, e)
			}
		}
		if len(due) == 0 {
			c.now = target
			c.mu.Unlock()
			return
		}
		sort.Slice(due, func(i, j int) bool {
			if due[i].at.Equal(due[j].at) {
				return due[i].id < due[j].id
			}
			return due[i].at.Before(due[j].at)
		})
		next := due[0]
		delete(c.pending, next.id)
		c.now = next.at
		c.mu.Unlock()
		next.fn()
	}
}

func (c *fakeClock) Pending() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.pending)
}

var _ Clock = (*fakeClock)(nil)

// ------------------------------------------------------------ recorder

// recorded is one delivered event: Node's `events.push({ name, payload })`.
type recorded struct {
	name    string
	payload any
}

// recorder is the Listener every harness table is built with. It records
// every event (name + payload) in delivery order. onKick, when set, is called
// synchronously from OnKick (it must not post to the table — spawn a
// goroutine, as RoomManager does). delay makes every callback slow, for the
// no-deadlock test.
type recorder struct {
	mu     sync.Mutex
	events []recorded
	onKick func(KickEvent)
	delay  time.Duration
}

func (r *recorder) add(name string, payload any) {
	if r.delay > 0 {
		time.Sleep(r.delay)
	}
	r.mu.Lock()
	r.events = append(r.events, recorded{name: name, payload: payload})
	r.mu.Unlock()
}

func (r *recorder) OnState(*View)                             { r.add("state", nil) }
func (r *recorder) OnSeatUpdated(_ *View, i int)              { r.add("seatUpdated", i) }
func (r *recorder) OnChat(_ *View, m *ChatMessage)            { r.add("chat", *m) }
func (r *recorder) OnHandStarted(_ *View, e HandStartedEvent) { r.add("handStarted", e) }
func (r *recorder) OnCards(_ *View, e CardsEvent)             { r.add("cards", e) }
func (r *recorder) OnTurn(_ *View, e TurnEvent)               { r.add("turn", e) }
func (r *recorder) OnAction(_ *View, e ActionEvent)           { r.add("action", e) }
func (r *recorder) OnSideshowRequested(_ *View, e SideshowRequestedEvent) {
	r.add("sideshowRequested", e)
}
func (r *recorder) OnSideshowReveal(_ *View, e SideshowRevealEvent)     { r.add("sideshowReveal", e) }
func (r *recorder) OnSideshowResolved(_ *View, e SideshowResolvedEvent) { r.add("sideshowResolved", e) }
func (r *recorder) OnShowdown(_ *View, e ShowdownEvent)                 { r.add("showdown", e) }
func (r *recorder) OnHandEnded(_ *View, e HandEndedEvent)               { r.add("handEnded", e) }
func (r *recorder) OnPersistError(_ *View, e PersistErrorEvent)         { r.add("persistError", e) }
func (r *recorder) OnError(_ *View, err error)                          { r.add("error", err) }
func (r *recorder) OnKick(_ *View, e KickEvent) {
	r.add("kick", e)
	if r.onKick != nil {
		r.onKick(e)
	}
}

var _ Listener = (*recorder)(nil)

// all returns the payloads of every event called name, in order.
func (r *recorder) all(name string) []any {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []any
	for _, e := range r.events {
		if e.name == name {
			out = append(out, e.payload)
		}
	}
	return out
}

// last returns the newest payload of the named event, or nil.
func (r *recorder) last(name string) any {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := len(r.events) - 1; i >= 0; i-- {
		if r.events[i].name == name {
			return r.events[i].payload
		}
	}
	return nil
}

// names is the delivery order of every event so far.
func (r *recorder) names() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.events))
	for _, e := range r.events {
		out = append(out, e.name)
	}
	return out
}

func (r *recorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.events)
}

// ------------------------------------------------------------ harness

// settleCall is one Ledger.Settle invocation.
type settleCall struct {
	req     SettleRequest
	entries []SettleEntry
}

// harness is Node's makeTable(): a Table on a fake clock with a recording
// listener and a memory ledger whose settle hook is chosen per suite.
type harness struct {
	t     *testing.T
	table *Table
	clock *fakeClock
	rec   *recorder

	mu          sync.Mutex
	settled     []settleCall
	checkpoints []SettleEntry
	// kicks tracks the RemovePlayer goroutines the seatKeeping-style kick
	// handler spawns, so a test can wait for a removal to land (Node:
	// `await table.settled()`).
	kicks sync.WaitGroup
}

// clockStart is where every fake clock begins (Node's fake started at 0;
// realistic epoch millis make wire timestamps meaningful).
var clockStart = time.UnixMilli(1_700_000_000_000)

type harnessOptions struct {
	id, code   string
	ledger     func(h *harness) Ledger
	onKick     func(h *harness, e KickEvent)
	clock      *fakeClock
	live       live.Store
	liveErrors func(op string, err error)
}

type harnessOption func(*harnessOptions)

// withLedger swaps the ledger the table is built with.
func withLedger(build func(h *harness) Ledger) harnessOption {
	return func(o *harnessOptions) { o.ledger = build }
}

// withKickHandler installs the seatKeeping.test.js stand-in for the room
// manager: every kick frees the seat through RemovePlayer, off the actor.
func withKickHandler() harnessOption {
	return func(o *harnessOptions) {
		o.onKick = func(h *harness, e KickEvent) {
			h.kicks.Add(1)
			go func() {
				defer h.kicks.Done()
				_, _ = h.table.RemovePlayer(e.UserID, e.Reason)
			}()
		}
	}
}

func withID(id, code string) harnessOption {
	return func(o *harnessOptions) { o.id, o.code = id, code }
}

// newHarness builds the table. Default ledger: MemoryLedger with the
// "mirror the real settlement" settle hook table.test.js used.
func newHarness(t *testing.T, cfg TableConfig, opts ...harnessOption) *harness {
	t.Helper()
	o := harnessOptions{id: "room-1", code: "TEST01"}
	for _, opt := range opts {
		opt(&o)
	}
	h := &harness{t: t, rec: &recorder{}}
	h.clock = o.clock
	if h.clock == nil {
		h.clock = newFakeClock(clockStart)
	}
	if o.onKick != nil {
		h.rec.onKick = func(e KickEvent) { o.onKick(h, e) }
	}
	var ledger Ledger
	if o.ledger != nil {
		ledger = o.ledger(h)
	} else {
		ledger = mirrorLedger(h)
	}
	h.table = NewTable(TableOptions{
		ID:         o.id,
		Code:       o.code,
		Config:     cfg,
		Ledger:     ledger,
		Clock:      h.clock,
		Listener:   h.rec,
		Live:       o.live,
		LiveErrors: o.liveErrors,
	})
	t.Cleanup(func() { _ = h.table.Destroy() })
	return h
}

// recordCheckpoint is what every Checkpoint hook calls first.
func (h *harness) recordCheckpoint(args CheckpointArgs) error {
	h.mu.Lock()
	h.checkpoints = append(h.checkpoints, args.Entry)
	h.mu.Unlock()
	return nil
}

// recordSettle is what every settle hook calls first.
func (h *harness) recordSettle(req SettleRequest, entries []SettleEntry) {
	h.mu.Lock()
	h.settled = append(h.settled, settleCall{req: req, entries: append([]SettleEntry(nil), entries...)})
	h.mu.Unlock()
}

// lastCheckpoint is the most recent pack/leave checkpoint the ledger was
// handed; lastCheckpointFor is the most recent one for a given player. Both
// need the harness's default ledger (mirrorLedger), which records them.
func (h *harness) lastCheckpoint() SettleEntry {
	h.t.Helper()
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.checkpoints) == 0 {
		h.t.Fatal("no checkpoint recorded")
	}
	return h.checkpoints[len(h.checkpoints)-1]
}

func (h *harness) lastCheckpointFor(userID string) SettleEntry {
	h.t.Helper()
	h.mu.Lock()
	defer h.mu.Unlock()
	for i := len(h.checkpoints) - 1; i >= 0; i-- {
		if h.checkpoints[i].UserID == userID {
			return h.checkpoints[i]
		}
	}
	h.t.Fatalf("no checkpoint recorded for %s", userID)
	return SettleEntry{}
}

// lastEnded is the most recent handEnded event — where the pot, the winner
// and the summary live now that the ledger no longer carries a hand record.
func (h *harness) lastEnded() HandEndedEvent {
	h.t.Helper()
	v := h.rec.last("handEnded")
	if v == nil {
		h.t.Fatal("no handEnded event")
	}
	return v.(HandEndedEvent)
}

// lastSettled is Node's `settled.at(-1)`.
func (h *harness) lastSettled() settleCall {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.settled) == 0 {
		h.t.Fatal("nothing has been settled")
	}
	return h.settled[len(h.settled)-1]
}

func (h *harness) settledCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.settled)
}

// mirrorLedger is table.test.js's settle: return each player's post-hand
// balance as the seat holds it plus the pot for the winner. The hook runs on
// the actor (inside endHand), so it reads the seats directly — exactly what
// Node's `table.findSeat` did from inside the callback.
func mirrorLedger(h *harness) Ledger {
	return NewMemoryLedger(MemoryLedgerHooks{
		Checkpoint: h.recordCheckpoint,
		Settle: func(req SettleRequest, entries []SettleEntry) (map[string]int64, error) {
			h.recordSettle(req, entries)
			// The winner is already paid in memory before Settle is called
			// now, so the seat IS the post-hand balance.
			balances := map[string]int64{}
			for _, e := range entries {
				if s := h.table.findSeat(e.UserID); s != nil {
					balances[e.UserID] = s.chips
				}
			}
			return balances, nil
		},
	})
}

// emptyLedger is `settle: () => ({})`: the table pays the winner in memory.
func emptyLedger(h *harness) Ledger {
	return NewMemoryLedger(MemoryLedgerHooks{
		Checkpoint: h.recordCheckpoint,
		Settle: func(req SettleRequest, entries []SettleEntry) (map[string]int64, error) {
			h.recordSettle(req, entries)
			return map[string]int64{}, nil
		},
	})
}

// ------------------------------------------------------------ helpers

func (h *harness) read(fn func()) {
	h.t.Helper()
	if err := h.table.run(fn); err != nil {
		h.t.Fatalf("read: %v", err)
	}
}

// seat is Node's `seat(id, chips)`: displayName == userId.
func (h *harness) seat(id string, chips int64) *SeatInfo {
	h.t.Helper()
	return h.seatNamed(id, id, chips)
}

func (h *harness) seatNamed(id, name string, chips int64) *SeatInfo {
	h.t.Helper()
	info, err := h.table.AddPlayer(NewPlayer{UserID: id, DisplayName: name, Chips: chips, SocketID: "s-" + id})
	if err != nil {
		h.t.Fatalf("seat %s: %v", id, err)
	}
	return info
}

func (h *harness) advance(d time.Duration) { h.clock.Advance(d) }

func (h *harness) act(id string, action Action, req ActRequest) (ActResult, error) {
	return h.table.Act(id, action, req)
}

func (h *harness) mustAct(id string, action Action, req ActRequest) ActResult {
	h.t.Helper()
	res, err := h.table.Act(id, action, req)
	if err != nil {
		h.t.Fatalf("%s %s: %v", id, action, err)
	}
	return res
}

func amt(v int64) ActRequest { return ActRequest{Amount: Int64Ptr(v)} }

func (h *harness) remove(id, reason string) *SeatInfo {
	h.t.Helper()
	info, err := h.table.RemovePlayer(id, reason)
	if err != nil {
		h.t.Fatalf("remove %s: %v", id, err)
	}
	return info
}

func (h *harness) startHand() {
	h.t.Helper()
	if err := h.table.StartHand(); err != nil {
		h.t.Fatalf("startHand: %v", err)
	}
}

func (h *harness) view(id string) *TableView {
	h.t.Helper()
	v, err := h.table.SerializeFor(id)
	if err != nil {
		h.t.Fatalf("serializeFor: %v", err)
	}
	return v
}

func (h *harness) hasHand() bool { return h.table.HasHand() }

func (h *harness) state() TableState { return h.table.State() }

// turnUser is Node's `table.seats[table.hand.turnSeat].userId`.
//
// The failure is raised OUTSIDE the posted closure: t.Fatal inside it would
// Goexit the actor goroutine and every later post would block forever.
func (h *harness) turnUser() string {
	h.t.Helper()
	var id, failure string
	h.read(func() {
		if h.table.hand == nil {
			failure = "turnUser: no hand"
			return
		}
		s := h.table.seats[h.table.hand.turnSeat]
		if s == nil {
			failure = "turnUser: turn seat is empty"
			return
		}
		id = s.userID
	})
	if failure != "" {
		h.t.Fatal(failure)
	}
	return id
}

func (h *harness) turnSeat() int {
	var idx int
	h.read(func() {
		idx = -1
		if h.table.hand != nil {
			idx = h.table.hand.turnSeat
		}
	})
	return idx
}

func (h *harness) seatInfo(id string) *SeatInfo {
	h.t.Helper()
	info, err := h.table.FindSeat(id)
	if err != nil {
		h.t.Fatalf("findSeat: %v", err)
	}
	return info
}

func (h *harness) mustSeat(id string) SeatInfo {
	h.t.Helper()
	info := h.seatInfo(id)
	if info == nil {
		h.t.Fatalf("%s is not seated", id)
	}
	return *info
}

// unwritten is how much of a player's stack has not yet reached PostgreSQL:
// the delta the next checkpoint will carry.
func (h *harness) unwritten(userID string) int64 {
	var delta int64
	h.read(func() {
		if h.table.hand == nil {
			return
		}
		if entry := h.table.hand.contributions[userID]; entry != nil {
			delta = entry.chips - entry.chipsWritten
		}
	})
	return delta
}

// unwrittenPot is everything staked in the live hand that PostgreSQL has not
// been told about — what a conservation check must subtract from the pot when
// the accounts still hold it.
func (h *harness) unwrittenPot() int64 {
	var total int64
	h.read(func() {
		if h.table.hand == nil {
			return
		}
		for _, entry := range h.table.hand.contributions {
			if d := entry.chipsWritten - entry.chips; d > 0 {
				total += d
			}
		}
	})
	return total
}

func (h *harness) pot() int64 {
	var pot int64
	h.read(func() {
		if h.table.hand != nil {
			pot = h.table.hand.pot
		}
	})
	return pot
}

func (h *harness) stake() int64 {
	var stake int64
	h.read(func() {
		if h.table.hand != nil {
			stake = h.table.hand.stake
		}
	})
	return stake
}

func (h *harness) round() int {
	var round int
	h.read(func() {
		if h.table.hand != nil {
			round = h.table.hand.round
		}
	})
	return round
}

func (h *harness) handNo() int {
	var n int
	h.read(func() { n = h.table.handNo })
	return n
}

func (h *harness) dealerSeat() int {
	var d int
	h.read(func() { d = h.table.dealerSeat })
	return d
}

func (h *harness) sideshowPending() bool {
	var pending bool
	h.read(func() { pending = h.table.hand != nil && h.table.hand.sideshow != nil })
	return pending
}

func (h *harness) activeIDs() []string {
	var ids []string
	h.read(func() {
		for _, s := range h.table.activeSeats() {
			ids = append(ids, s.userID)
		}
	})
	return ids
}

func (h *harness) occupiedIDs() []string {
	var ids []string
	h.read(func() {
		for _, s := range h.table.occupiedSeats() {
			ids = append(ids, s.userID)
		}
	})
	return ids
}

func (h *harness) betOptions(id string) BetOptions {
	h.t.Helper()
	var opts BetOptions
	h.read(func() {
		s := h.table.findSeat(id)
		if s == nil {
			h.t.Fatalf("betOptions: %s not seated", id)
		}
		opts = h.table.betOptions(s)
	})
	return opts
}

func (h *harness) turnOptions(id string) TurnOptions {
	h.t.Helper()
	var opts TurnOptions
	h.read(func() {
		s := h.table.findSeat(id)
		if s == nil {
			h.t.Fatalf("turnOptions: %s not seated", id)
		}
		opts = h.table.turnOptions(s)
	})
	return opts
}

func (h *harness) showCost(id string) *int64 {
	var cost *int64
	h.read(func() { cost = h.table.showCost(h.table.findSeat(id)) })
	return cost
}

func (h *harness) blockedReason(id string) string {
	var reason string
	h.read(func() { reason = h.table.sideshowBlockedReason(h.table.findSeat(id)) })
	return reason
}

// setCards is the deterministic-showdown seam: Node's
// `table.findSeat(userId).cards = codes.map(parseCard)`.
func (h *harness) setCards(id string, codes ...string) {
	h.t.Helper()
	h.read(func() {
		s := h.table.findSeat(id)
		if s == nil {
			h.t.Fatalf("setCards: %s not seated", id)
		}
		s.cards = ParseCards(codes)
	})
}

func (h *harness) setBlind(id string, blind bool) {
	h.read(func() { h.table.findSeat(id).isBlind = blind })
}

func (h *harness) setPot(pot int64) {
	h.read(func() { h.table.hand.pot = pot })
}

// waitKicks waits for every RemovePlayer a kick handler has spawned — the
// Go stand-in for `await table.settled()` after a kick.
func (h *harness) waitKicks() { h.kicks.Wait() }

// ---- typed event accessors

func (h *harness) lastTurn() TurnEvent {
	h.t.Helper()
	p := h.rec.last("turn")
	if p == nil {
		h.t.Fatal("no turn event")
	}
	return p.(TurnEvent)
}

func (h *harness) lastAction() ActionEvent {
	h.t.Helper()
	p := h.rec.last("action")
	if p == nil {
		h.t.Fatal("no action event")
	}
	return p.(ActionEvent)
}

func (h *harness) actions() []ActionEvent {
	var out []ActionEvent
	for _, p := range h.rec.all("action") {
		out = append(out, p.(ActionEvent))
	}
	return out
}

func (h *harness) lastHandEnded() HandEndedEvent {
	h.t.Helper()
	p := h.rec.last("handEnded")
	if p == nil {
		h.t.Fatal("no handEnded event")
	}
	return p.(HandEndedEvent)
}

func (h *harness) lastShowdown() ShowdownEvent {
	h.t.Helper()
	p := h.rec.last("showdown")
	if p == nil {
		h.t.Fatal("no showdown event")
	}
	return p.(ShowdownEvent)
}

func (h *harness) lastCards() CardsEvent {
	h.t.Helper()
	p := h.rec.last("cards")
	if p == nil {
		h.t.Fatal("no cards event")
	}
	return p.(CardsEvent)
}

func (h *harness) lastHandStarted() HandStartedEvent {
	h.t.Helper()
	p := h.rec.last("handStarted")
	if p == nil {
		h.t.Fatal("no handStarted event")
	}
	return p.(HandStartedEvent)
}

func (h *harness) kickEvents() []KickEvent {
	var out []KickEvent
	for _, p := range h.rec.all("kick") {
		out = append(out, p.(KickEvent))
	}
	return out
}

// ---- assertions

func codeIs(t *testing.T, err error, code string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error %q, got nil", code)
	}
	var ge *GameError
	if !errors.As(err, &ge) {
		t.Fatalf("expected GameError %q, got %T %v", code, err, err)
	}
	if ge.Code != code {
		t.Fatalf("expected code %q, got %q (%s)", code, ge.Code, ge.Message)
	}
}

func eq[T comparable](t *testing.T, got, want T, msg string) {
	t.Helper()
	if got != want {
		t.Fatalf("%s: got %v, want %v", msg, got, want)
	}
}

func deref(p *int64) int64 {
	if p == nil {
		return -1
	}
	return *p
}

func sumDeltas(entries []SettleEntry) int64 {
	var sum int64
	for _, e := range entries {
		sum += e.Delta
	}
	return sum
}

func sumContributed(summary []HandSummaryEntry) int64 {
	var sum int64
	for _, row := range summary {
		sum += row.Contributed
	}
	return sum
}

func contains(ids []string, id string) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}

// ------------------------------------------------------------ table.test.js

const (
	tableBoot  int64 = 100
	tableStart int64 = 200000
)

// tableConfig is table.test.js baseConfig. It set no maxRaiseSteps (Node
// default 8), and no maxBlindMoves / maxMissedTurns / sideshow* — in Node
// those comparisons against undefined never fire; in Go 0 means disabled
// (DECISIONS.md §2).
func tableConfig() TableConfig {
	return TableConfig{
		Category:           CategorySeen,
		BootAmount:         tableBoot,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        25 * time.Second,
		MaxBetRounds:       20,
		PotLimitMultiplier: 1024,
		MaxRaiseSteps:      8,
		NextHandDelay:      6 * time.Second,
	}
}

func TestTableWaitsUntilTheMinimumNumberOfPlayersIsSeated(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	eq(t, h.state(), TableWaiting, "one player")
	eq(t, h.hasHand(), false, "no hand yet")

	h.seat("bob", tableStart)
	eq(t, h.state(), TableStarting, "two players triggers the start countdown")

	h.advance(6 * time.Second)
	eq(t, h.state(), TableBetting, "dealt")
	eq(t, h.hasHand(), true, "a hand is live")
}

func TestTableSeatsAtMostFivePlayers(t *testing.T) {
	h := newHarness(t, tableConfig())
	for _, id := range []string{"a", "b", "c", "d", "e"} {
		h.seat(id, tableStart)
	}
	eq(t, h.table.PlayerCount(), 5, "playerCount")
	eq(t, h.table.IsFull(), true, "isFull")
	_, err := h.table.AddPlayer(NewPlayer{UserID: "f", DisplayName: "f", Chips: tableStart})
	codeIs(t, err, CodeTableFull)
}

func TestTheSamePlayerCannotTakeTwoSeats(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	_, err := h.table.AddPlayer(NewPlayer{UserID: "alice", DisplayName: "alice", Chips: tableStart})
	codeIs(t, err, CodeAlreadySeated)
}

func TestAPlayerWhoJoinsMidHandSitsOutUntilTheNextDeal(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	late := h.seat("carol", tableStart)
	eq(t, late.Status, SeatWaiting, "late joiner waits")
	eq(t, len(late.Cards), 0, "no cards")
	eq(t, len(h.activeIDs()), 2, "two active")
}

func TestAPlayerWhoCannotCoverTheBootIsDealtOut(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.seat("broke", tableBoot-1)
	h.advance(6 * time.Second)

	// No kick handler here, so the seat stays (the kick was only announced).
	eq(t, h.mustSeat("broke").Status, SeatWaiting, "broke sits out")
	eq(t, len(h.activeIDs()), 2, "two active")
	kicks := h.kickEvents()
	if len(kicks) == 0 || kicks[0].UserID != "broke" || kicks[0].Reason != KickReasonInsufficientChips {
		t.Fatalf("expected an insufficient_chips kick for broke, got %+v", kicks)
	}
}

func TestEveryPlayerIsDealtThreeHiddenCardsAndTheBootIsCollected(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.seat("carol", tableStart)
	h.advance(6 * time.Second)

	for _, id := range h.activeIDs() {
		s := h.mustSeat(id)
		eq(t, len(s.Cards), 3, id+" cards")
		eq(t, s.IsBlind, true, "cards start face down")
		eq(t, s.Chips, tableStart-tableBoot, id+" chips")
		eq(t, s.Contributed, tableBoot, id+" contributed")
	}
	eq(t, h.pot(), tableBoot*3, "pot")
	eq(t, h.lastHandStarted().Pot, tableBoot*3, "handStarted.pot")

	you := h.view("alice").You
	if you == nil || you.Cards == nil || len(you.Cards) != 0 {
		t.Fatalf("you.cards must be [] for a blind viewer, got %+v", you)
	}
}

func TestASnapshotNeverContainsAnotherPlayersCards(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	onTurn := h.turnUser()
	h.mustAct(onTurn, ActionSee, ActRequest{})
	view := h.view(onTurn)
	eq(t, len(view.You.Cards), 3, "you can see your own hand once you look")

	raw, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	var generic struct {
		Seats []map[string]any `json:"seats"`
	}
	if err := json.Unmarshal(raw, &generic); err != nil {
		t.Fatal(err)
	}
	for _, s := range generic.Seats {
		if _, ok := s["cards"]; ok {
			t.Fatalf("no seat entry ever carries card faces: %v", s)
		}
	}
}

func TestTurnsOpenLeftOfTheDealerAndRotateClockwise(t *testing.T) {
	h := newHarness(t, tableConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)

	var expected []string
	h.read(func() {
		cursor := h.table.dealerSeat
		for len(expected) < 3 {
			cursor = (cursor + 1) % len(h.table.seats)
			if s := h.table.seats[cursor]; s != nil {
				expected = append(expected, s.userID)
			}
		}
	})

	var order []string
	for i := 0; i < 3; i++ {
		order = append(order, h.turnUser())
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	eq(t, strings.Join(order, ","), strings.Join(expected, ","), "clockwise order")
	if len(h.rec.all("turn")) < 3 {
		t.Fatal("expected at least three turn events")
	}
}

func TestActingOutOfTurnIsRefused(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	onTurn := h.turnUser()
	other := "alice"
	if onTurn == "alice" {
		other = "bob"
	}
	_, err := h.act(other, ActionChaal, ActRequest{})
	codeIs(t, err, CodeNotYourTurn)
}

func TestAPlayerNotInTheHandCannotAct(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)
	h.seat("carol", tableStart)

	_, err := h.act("carol", ActionChaal, ActRequest{})
	codeIs(t, err, CodeNotInHand)
	_, err = h.act("nobody", ActionChaal, ActRequest{})
	codeIs(t, err, CodeNotSeated)
}

func TestABlindPlayerBetsTheStakeOrDoubleItASeenPlayerPaysDoubleThat(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	blind := h.turnUser()
	opts := h.betOptions(blind)
	eq(t, deref(opts.Chaal), tableBoot, "blind: same amount")
	eq(t, deref(opts.Raise), tableBoot*2, "blind: double")

	h.mustAct(blind, ActionSee, ActRequest{})
	opts = h.betOptions(blind)
	eq(t, deref(opts.Chaal), tableBoot*2, "seen: same amount is double a blind")
	eq(t, deref(opts.Raise), tableBoot*4, "seen: double")
}

func TestABlindBetRaisesTheStakeASeenBetRaisesItByHalfAsMuch(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	first := h.turnUser()
	h.mustAct(first, ActionRaise, ActRequest{})
	eq(t, h.stake(), tableBoot*2, "blind raise sets the stake")
	eq(t, h.pot(), tableBoot*4, "pot after blind raise")

	second := h.turnUser()
	h.mustAct(second, ActionSee, ActRequest{})
	h.mustAct(second, ActionChaal, ActRequest{})
	eq(t, h.pot(), tableBoot*8, "seen chaal pays 2 x stake")
	eq(t, h.stake(), tableBoot*2, "stake stays in blind units")
}

func TestSeeingCardsIsFreeRevealsOnlyYourHandAndDoesNotPassTheTurn(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	before := h.mustSeat(player).Chips
	res := h.mustAct(player, ActionSee, ActRequest{})
	eq(t, res.Action, "see", "ack action")
	if res.Auto == nil || *res.Auto {
		t.Fatalf("see ack must carry auto:false, got %+v", res)
	}

	eq(t, h.mustSeat(player).Chips, before, "seeing costs nothing")
	eq(t, h.turnUser(), player, "the turn does not move")
	cards := h.lastCards()
	eq(t, cards.UserID, player, "cards go to the player")
	eq(t, len(cards.Cards), 3, "three codes")
	_, err := h.act(player, ActionSee, ActRequest{})
	codeIs(t, err, CodeAlreadySeen)
}

func TestBetsAreCappedByThePotLimit(t *testing.T) {
	cfg := tableConfig()
	cfg.PotLimitMultiplier = 4
	h := newHarness(t, cfg)
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	h.mustAct(player, ActionSee, ActRequest{})
	opts := h.betOptions(player)
	eq(t, deref(opts.Chaal), tableBoot*2, "chaal")
	eq(t, deref(opts.Raise), tableBoot*4, "raise")
	eq(t, deref(opts.Max), tableBoot*4, "the ladder stops at the pot limit")
}

func TestAPlayerWhoCannotAffordABetIsOfferedNoBet(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableBoot+10)
	h.advance(6 * time.Second)

	opts := h.turnOptions("bob")
	if opts.Chaal != nil || opts.Raise != nil {
		t.Fatalf("expected no bet, got chaal %v raise %v", opts.Chaal, opts.Raise)
	}
	eq(t, opts.CanPack, true, "can always pack")
}

func TestPackingForfeitsTheHandAndPassesTheTurn(t *testing.T) {
	h := newHarness(t, tableConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)

	packer := h.turnUser()
	potBefore := h.pot()
	res := h.mustAct(packer, ActionPack, ActRequest{})
	eq(t, res.Action, "pack", "ack action")
	eq(t, res.Reason, PackReasonPack, "ack reason")

	eq(t, h.mustSeat(packer).Status, SeatPacked, "packed")
	eq(t, h.pot(), potBefore, "a pack adds nothing to the pot")
	if h.turnUser() == packer {
		t.Fatal("the turn should have moved")
	}
	eq(t, h.lastAction().Action, ActionPack, "last action is a pack")
}

func TestTheLastPlayerStandingTakesThePotWithoutAShow(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.seat("carol", tableStart)
	h.advance(6 * time.Second)

	pot := h.pot()
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})

	ended := h.lastHandEnded()
	eq(t, ended.Reason, WinLastStanding, "reason")
	eq(t, ended.Pot, pot, "pot")
	if ended.Reveals == nil || len(ended.Reveals) != 0 {
		t.Fatalf("nobody has to show their cards: %v", ended.Reveals)
	}
	if ended.WinnerID == nil {
		t.Fatal("winner expected")
	}
	eq(t, h.mustSeat(*ended.WinnerID).Status, SeatWon, "winner status")
}

func TestAPlayerWhoDoesNotActWithin25SecondsIsPackedAutomatically(t *testing.T) {
	h := newHarness(t, tableConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)

	stalling := h.turnUser()
	h.advance(25 * time.Second)

	eq(t, h.mustSeat(stalling).Status, SeatPacked, "packed by the clock")
	found := false
	for _, a := range h.actions() {
		if a.UserID == stalling && a.Action == ActionPack && a.Reason == PackReasonTimeout {
			found = true
		}
	}
	if !found {
		t.Fatal("the pack is reported as a timeout")
	}
	if h.turnUser() == stalling {
		t.Fatal("play continues with the others")
	}
}

func TestTheTurnClockIsAnnouncedWithADeadlineTheClientCanCountDown(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	turn := h.lastTurn()
	eq(t, turn.TimeoutMs, int64(25000), "timeoutMs")
	if turn.Deadline <= Millis(h.clock.Now())+20000 {
		t.Fatalf("deadline %d should be well ahead of now %d", turn.Deadline, Millis(h.clock.Now()))
	}
	if turn.Options.Chaal == nil || *turn.Options.Chaal <= 0 {
		t.Fatal("options.chaal > 0")
	}
}

func TestActingResetsTheClockForTheNextPlayer(t *testing.T) {
	h := newHarness(t, tableConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)

	h.advance(24 * time.Second)
	player := h.turnUser()
	h.mustAct(player, ActionChaal, ActRequest{})

	next := h.turnUser()
	h.advance(24 * time.Second)
	eq(t, h.mustSeat(next).Status, SeatActive, "the next player got a full window")
}

func TestAShowNeedsExactlyTwoPlayersLeft(t *testing.T) {
	h := newHarness(t, tableConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)
	_, err := h.act(h.turnUser(), ActionShow, ActRequest{})
	codeIs(t, err, CodeShowUnavailable)
}

func TestAShowRevealsBothHandsAndTheBetterHandTakesThePot(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	h.setCards("alice", "As", "Ah", "Ad")
	h.setCards("bob", "2s", "7h", "9d")

	caller := h.turnUser()
	res := h.mustAct(caller, ActionShow, ActRequest{})
	eq(t, res.Action, "show", "ack action")
	eq(t, deref(res.Amount), tableBoot, "ack amount")

	showdown := h.lastShowdown()
	eq(t, len(showdown.Reveals), 2, "both revealed")
	eq(t, showdown.Reason, WinShow, "reason")

	ended := h.lastHandEnded()
	eq(t, *ended.WinnerID, "alice", "winner")
	eq(t, ended.Reason, WinShow, "reason")
	for _, r := range ended.Reveals {
		if r.UserID == "alice" {
			eq(t, r.HandName, "Trail", "hand name")
			eq(t, r.Won, true, "won")
			eq(t, r.Category, Trail, "category")
		}
	}
}

func TestPayingForAShowCostsTheCallerAChaal(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	caller := h.turnUser()
	potBefore := h.pot()
	cost := h.showCost(caller)
	eq(t, deref(cost), tableBoot, "a blind caller pays the blind stake")

	h.mustAct(caller, ActionShow, ActRequest{})
	eq(t, h.view("alice").Pot, int64(0), "the pot is cleared once the hand ends")
	eq(t, potBefore+*cost, tableBoot*3, "final pot")
	eq(t, h.lastHandEnded().Pot, tableBoot*3, "handEnded.pot")
}

func TestAnExactTieGoesToThePlayerWhoDidNotCallTheShow(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	h.setCards("alice", "As", "9s", "4s")
	h.setCards("bob", "Ah", "9h", "4h")

	caller := h.turnUser()
	h.mustAct(caller, ActionShow, ActRequest{})
	if *h.lastHandEnded().WinnerID == caller {
		t.Fatal("the caller loses a tie")
	}
}

func TestTheRoundCapForcesAShowdownSoAPotCannotRunForever(t *testing.T) {
	cfg := tableConfig()
	cfg.MaxBetRounds = 3
	h := newHarness(t, cfg)
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	h.setCards("alice", "As", "Ks", "Qs")
	h.setCards("bob", "2s", "7h", "9d")

	for i := 0; i < 40 && h.hasHand(); i++ {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	eq(t, h.hasHand(), false, "the hand ended on its own")
	ended := h.lastHandEnded()
	eq(t, ended.Reason, WinForcedShowdown, "reason")
	eq(t, *ended.WinnerID, "alice", "winner")
}

func TestTheWinnerTakesTheWholePotAndEveryoneElsePaysWhatTheyStaked(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)
	h.setCards("alice", "As", "Ah", "Ad")
	h.setCards("bob", "2s", "7h", "9d")

	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})

	record := h.lastSettled()
	ended := h.lastHandEnded()
	eq(t, sumDeltas(record.entries), int64(0), "chips are conserved")
	winners := 0
	for _, e := range record.entries {
		if e.IsWinner {
			winners++
			eq(t, e.UserID, "alice", "winner")
		}
	}
	eq(t, winners, 1, "exactly one winner")
	eq(t, sumContributed(ended.Summary), ended.Pot, "pot equals contributions")
}

// The hand's audit trail is the handEnded event and the chip_ledger outcome
// rows — there is no `hands` table any more (owner's decision of 9 Sep 2026:
// it was write-only, its single reader GET /api/auth/me/hands is gone, and
// every stat the app shows is a counter column on `users`).
func TestTheHandEndedEventCarriesTheFullAuditTrail(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)
	h.setCards("alice", "As", "Ah", "Ad")
	h.setCards("bob", "2s", "7h", "9d")
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})

	ended := h.lastEnded()
	eq(t, ended.HandNo, 1, "handNo")
	eq(t, ended.Reason, WinShow, "reason")
	if ended.WinnerID == nil || *ended.WinnerID != "alice" {
		t.Fatalf("winner %v", ended.WinnerID)
	}
	eq(t, len(ended.Summary), 2, "a row per contributor")
	eq(t, sumContributed(ended.Summary), ended.Pot, "the summary explains the pot")
	for _, row := range ended.Summary {
		eq(t, len(row.Cards), 3, "cards revealed at a show")
		eq(t, row.Status, map[string]SeatState{"alice": SeatWon, "bob": SeatLost}[row.UserID], "status")
	}

	// And the ledger row that resolves each player carries the same story.
	settle := h.lastSettled()
	eq(t, settle.req.HandID, ended.HandID, "the settlement is for this hand")
	for _, e := range settle.entries {
		eq(t, e.ActionID, SettleActionID(ended.HandID, e.UserID), "action id")
		eq(t, e.Outcome, true, "an outcome row")
		if e.IsWinner {
			eq(t, e.Reason, LedgerReasonHandWin, "winner reason")
			eq(t, e.Pot, ended.Pot, "the pot, for total_winnings")
		} else {
			eq(t, e.Reason, LedgerReasonHandLoss, "loser reason")
		}
	}
}

func TestAPlayerWhoLeavesMidHandStillForfeitsTheirStake(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.seat("carol", tableStart)
	h.advance(6 * time.Second)

	quitter := h.turnUser()
	h.mustAct(quitter, ActionChaal, ActRequest{})
	h.remove(quitter, LeaveReasonLeft)

	remaining := h.activeIDs()
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})

	record := h.lastSettled()
	var winner string
	for i := range record.entries {
		if record.entries[i].UserID == quitter {
			t.Fatal("a player who left must not be written again at the hand end")
		}
		if record.entries[i].IsWinner {
			winner = record.entries[i].UserID
		}
	}
	// Their stake left their wallet at their own checkpoint and stays in the pot.
	cp := h.lastCheckpointFor(quitter)
	eq(t, cp.Reason, LedgerReasonHandLeft, "resolved when they left")
	eq(t, cp.Delta, -(tableBoot + tableBoot), "their boot and chaal stay in the pot")
	if !contains(remaining, winner) {
		t.Fatalf("winner %s should be one of %v", winner, remaining)
	}
}

func TestTheNextHandStartsAutomaticallyAndTheDealerButtonMoves(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	firstDealer := h.dealerSeat()
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	eq(t, h.handNo(), 1, "hand 1 ended")

	h.advance(6 * time.Second)
	eq(t, h.handNo(), 2, "a new hand was dealt")
	if h.dealerSeat() == firstDealer {
		t.Fatal("the dealer button rotated")
	}
}

func TestPlayStopsWhenOnlyOneFundedPlayerRemains(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	h.remove("bob", LeaveReasonLeft)
	h.advance(18 * time.Second)

	eq(t, h.state(), TableWaiting, "waiting")
	eq(t, h.hasHand(), false, "no hand")
}

func TestADestroyedTableStopsAllOfItsTimers(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	h.advance(30 * time.Second)
	eq(t, h.table.HasHand(), false, "no hand is dealt after destroy")
	eq(t, h.clock.Pending(), 0, "no timer left armed")
}

func TestUnknownActionsAreRejected(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)
	_, err := h.act(h.turnUser(), Action("steal_the_pot"), ActRequest{})
	codeIs(t, err, CodeUnknownAction)
	var ge *GameError
	errors.As(err, &ge)
	eq(t, ge.Message, `Unknown action "steal_the_pot"`, "message")

	// Off turn, the turn check wins over the dispatch (spec §12.1).
	other := "alice"
	if h.turnUser() == "alice" {
		other = "bob"
	}
	_, err = h.act(other, Action("steal_the_pot"), ActRequest{})
	codeIs(t, err, CodeNotYourTurn)
}

// ------------------------------------------------------ categories.test.js

func categoriesConfig(category Category) TableConfig {
	return TableConfig{
		Category:           category,
		BootAmount:         200,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        25 * time.Second,
		MaxBetRounds:       20,
		PotLimitMultiplier: 1024,
		MaxRaiseSteps:      8,
		NextHandDelay:      6 * time.Second,
		ChatMaxHistory:     100,
		ChatMaxLength:      140,
	}
}

func seatViewOf(view *TableView, id string) SeatView {
	for _, s := range view.Seats {
		if !s.Empty && s.UserID == id {
			return s
		}
	}
	return SeatView{Empty: true}
}

func TestATableDefaultsToTheSeenCategory(t *testing.T) {
	h := newHarness(t, categoriesConfig(""), withLedger(emptyLedger))
	eq(t, h.table.Category(), CategorySeen, "empty category")
	eq(t, h.table.Config().Category, CategorySeen, "normalised in Config too")

	h2 := newHarness(t, categoriesConfig(Category("nonsense")), withLedger(emptyLedger))
	eq(t, h2.table.Category(), CategorySeen, "never hide by accident")
}

func TestTheCategoryIsReportedInTheSnapshotAndTheLobbyRow(t *testing.T) {
	h := newHarness(t, categoriesConfig(CategoryBlind), withLedger(emptyLedger))
	h.seat("alice", 200000)
	eq(t, h.view("alice").Category, CategoryBlind, "snapshot")
	summary, err := h.table.Summary()
	if err != nil {
		t.Fatal(err)
	}
	eq(t, summary.Category, CategoryBlind, "lobby row")
	eq(t, summary.Players, 1, "players")
	eq(t, summary.BootAmount, int64(200), "boot")
}

func TestOnASeenTableEveryoneCanSeeEveryStack(t *testing.T) {
	h := newHarness(t, categoriesConfig(CategorySeen), withLedger(emptyLedger))
	h.seat("alice", 150000)
	h.seat("bob", 75000)
	h.seat("carol", 42000)

	view := h.view("alice")
	eq(t, view.ChipsHidden, false, "chipsHidden")
	eq(t, deref(seatViewOf(view, "alice").Chips), int64(150000), "own")
	eq(t, deref(seatViewOf(view, "bob").Chips), int64(75000), "bob")
	eq(t, deref(seatViewOf(view, "carol").Chips), int64(42000), "carol")
}

func TestOnABlindTableYouSeeYourOwnStackButNobodyElses(t *testing.T) {
	h := newHarness(t, categoriesConfig(CategoryBlind), withLedger(emptyLedger))
	h.seat("alice", 150000)
	h.seat("bob", 75000)
	h.seat("carol", 42000)

	view := h.view("alice")
	eq(t, view.ChipsHidden, true, "chipsHidden")
	eq(t, deref(seatViewOf(view, "alice").Chips), int64(150000), "your own stack is always visible")
	if seatViewOf(view, "bob").Chips != nil || seatViewOf(view, "carol").Chips != nil {
		t.Fatal("other stacks are withheld (null, not 0)")
	}

	// Each viewer sees only their own.
	bob := h.view("bob")
	eq(t, deref(seatViewOf(bob, "bob").Chips), int64(75000), "bob sees bob")
	if seatViewOf(bob, "alice").Chips != nil {
		t.Fatal("bob must not see alice's stack")
	}

	// The strong claim: the digits are absent from the wire.
	h2 := newHarness(t, categoriesConfig(CategoryBlind), withLedger(emptyLedger))
	h2.seat("alice", 1000)
	h2.seat("bob", 987654)
	raw, _ := json.Marshal(h2.view("alice"))
	if strings.Contains(string(raw), "987654") {
		t.Fatal("bob's stack is absent from the wire")
	}
	if !strings.Contains(string(raw), "1000") {
		t.Fatal("alice's own stack is present")
	}
	if !strings.Contains(string(raw), `"chips":null`) {
		t.Fatal("hidden chips must serialise as null")
	}
}

func TestYourOwnTurnOptionsStillCarryYourStackOnABlindTable(t *testing.T) {
	h := newHarness(t, categoriesConfig(CategoryBlind), withLedger(emptyLedger))
	h.seat("alice", 200000)
	h.seat("bob", 200000)
	h.advance(6 * time.Second)

	view := h.view(h.turnUser())
	eq(t, view.You.Chips, int64(200000-200), "you always know what you hold")
	if view.You.Options == nil {
		t.Fatal("options expected for the player on turn")
	}
	eq(t, view.You.Options.Chips, int64(200000-200), "options.chips")

	// Bets stay public on a blind table.
	alice := h.view("alice")
	eq(t, seatViewOf(alice, "bob").Contributed, int64(200), "the boot they staked is visible")
	if seatViewOf(alice, "bob").Chips != nil {
		t.Fatal("their bankroll is not")
	}
	eq(t, alice.Pot, int64(400), "the pot is public")
}

func TestHidingChipsDoesNotAffectGameplay(t *testing.T) {
	blind := newHarness(t, categoriesConfig(CategoryBlind), withLedger(emptyLedger))
	seen := newHarness(t, categoriesConfig(CategorySeen), withLedger(emptyLedger))
	for _, h := range []*harness{blind, seen} {
		h.seat("alice", 200000)
		h.seat("bob", 200000)
		h.advance(6 * time.Second)
	}
	a := blind.betOptions(blind.turnUser()).Steps
	b := seen.betOptions(seen.turnUser()).Steps
	eq(t, fmt.Sprint(a), fmt.Sprint(b), "the same bets are available in both categories")
	eq(t, blind.pot(), seen.pot(), "same pot")
}

// ------------------------------------------------------ blindRules.test.js

func blindConfig() TableConfig {
	return TableConfig{
		Category:           CategorySeen,
		BootAmount:         200,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        25 * time.Second,
		MaxBetRounds:       40,
		PotLimitMultiplier: 1_048_576,
		MaxRaiseSteps:      8,
		MaxBlindMoves:      4,
		NextHandDelay:      6 * time.Second,
		ChatMaxHistory:     100,
		ChatMaxLength:      140,
	}
}

const blindStart int64 = 5_000_000

func (h *harness) otherActive(notThis string) string {
	for _, id := range h.activeIDs() {
		if id != notThis {
			return id
		}
	}
	h.t.Fatal("no other active player")
	return ""
}

// playRoundTo bets chaal for everyone until `player` is on turn.
func (h *harness) playRoundTo(player string) {
	h.t.Helper()
	for guard := 0; h.hasHand() && h.turnUser() != player; guard++ {
		if guard > 100 {
			h.t.Fatal("turn never reached the player")
		}
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
}

func TestAPlayerMaySeeTheirCardsWhenItIsNotTheirTurn(t *testing.T) {
	h := newHarness(t, blindConfig())
	h.seatNamed("alice", "ALICE", blindStart)
	h.seatNamed("bob", "BOB", blindStart)
	h.advance(6 * time.Second)

	onTurn := h.turnUser()
	waiting := h.otherActive(onTurn)
	eq(t, h.mustSeat(waiting).IsBlind, true, "blind to begin with")
	h.mustAct(waiting, ActionSee, ActRequest{})
	eq(t, h.mustSeat(waiting).IsBlind, false, "seen off turn")
	eq(t, h.turnUser(), onTurn, "the turn stays where it was")

	_, err := h.act(waiting, ActionChaal, ActRequest{})
	codeIs(t, err, CodeNotYourTurn)
}

func TestTheCardsTurnFaceUpAfterTheCappedNumberOfBlindBets(t *testing.T) {
	h := newHarness(t, blindConfig())
	h.seatNamed("alice", "ALICE", blindStart)
	h.seatNamed("bob", "BOB", blindStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	for move := 1; move <= 4; move++ {
		h.playRoundTo(player)
		eq(t, h.mustSeat(player).IsBlind, true, fmt.Sprintf("still blind before move %d", move))
		res := h.mustAct(player, ActionChaal, ActRequest{})
		eq(t, h.mustSeat(player).BlindMoves, move, "blindMoves counts")
		eq(t, *res.AutoSeen, move == 4, "autoSeen flag on the capped bet only")
	}
	eq(t, h.mustSeat(player).IsBlind, false, "the cap turned the cards face up")
	eq(t, h.view(player).You.BlindMovesLeft, 0, "no blind moves left once seen")
}

func TestTheCappedBetIsItselfStillChargedAtTheBlindRate(t *testing.T) {
	h := newHarness(t, blindConfig())
	h.seatNamed("alice", "ALICE", blindStart)
	h.seatNamed("bob", "BOB", blindStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	for move := 1; move < 4; move++ {
		h.playRoundTo(player)
		h.mustAct(player, ActionChaal, ActRequest{})
	}
	h.playRoundTo(player)

	stake := h.stake()
	before := h.mustSeat(player).Chips
	h.rec.mu.Lock()
	mark := len(h.rec.events)
	h.rec.mu.Unlock()
	h.mustAct(player, ActionChaal, ActRequest{})

	eq(t, before-h.mustSeat(player).Chips, stake, "charged at the blind rate")
	eq(t, h.mustSeat(player).IsBlind, false, "and only then turned face up")

	// Observed order (spec §19.1): action:chaal > cards > action:see(auto) > state > turn > state > state.
	names := h.rec.names()[mark:]
	want := "action,cards,action,state,turn,state,state"
	eq(t, strings.Join(names, ","), want, "auto-reveal event order")
	see := h.rec.all("action")
	last := see[len(see)-1].(ActionEvent)
	eq(t, last.Action, ActionSee, "auto see action")
	if last.Auto == nil || !*last.Auto {
		t.Fatal("auto:true on the forced reveal")
	}
}

func TestAPlayerWhoLookedEarlyIsNeverAutoSeen(t *testing.T) {
	h := newHarness(t, blindConfig())
	h.seatNamed("alice", "ALICE", blindStart)
	h.seatNamed("bob", "BOB", blindStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	h.mustAct(player, ActionSee, ActRequest{})
	eq(t, h.mustSeat(player).IsBlind, false, "seen")
	for move := 0; move < 6; move++ {
		h.playRoundTo(player)
		res := h.mustAct(player, ActionChaal, ActRequest{})
		eq(t, h.mustSeat(player).BlindMoves, 0, "nothing accrues after looking")
		eq(t, *res.AutoSeen, false, "never auto seen")
	}
}

func TestTheCounterStartsAgainOnTheNextHand(t *testing.T) {
	h := newHarness(t, blindConfig())
	h.seatNamed("alice", "ALICE", blindStart)
	h.seatNamed("bob", "BOB", blindStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	h.mustAct(player, ActionChaal, ActRequest{})
	eq(t, h.mustSeat(player).BlindMoves, 1, "one blind move")

	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	h.advance(6 * time.Second)

	eq(t, h.mustSeat(player).BlindMoves, 0, "reset")
	eq(t, h.mustSeat(player).IsBlind, true, "blind again")
}

func TestASeatReportsItsLastBetAsWellAsItsRunningTotal(t *testing.T) {
	h := newHarness(t, blindConfig())
	h.seatNamed("alice", "ALICE", blindStart)
	h.seatNamed("bob", "BOB", blindStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	view := func() SeatView { return seatViewOf(h.view("watcher"), player) }
	eq(t, view().LastBet, int64(0), "the boot is not a bet")
	if view().LastAction != nil {
		t.Fatal("no last action before betting")
	}
	contributedBefore := view().Contributed

	h.mustAct(player, ActionChaal, ActRequest{})
	after := view()
	if after.LastBet <= 0 {
		t.Fatal("the last bet is reported")
	}
	eq(t, after.Contributed, contributedBefore+after.LastBet, "contributed")
	eq(t, *after.LastAction, ActionChaal, "lastAction")

	// A non-seated viewer gets you: null.
	if h.view("watcher").You != nil {
		t.Fatal("you must be null for a spectator")
	}

	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	h.advance(6 * time.Second)
	eq(t, h.mustSeat(player).LastBet, int64(0), "cleared on the next deal")
	if h.mustSeat(player).LastAction != nil {
		t.Fatal("lastAction cleared on the next deal")
	}
}

// ------------------------------------------------------ raiseLadder.test.js

func ladderConfig() TableConfig {
	return TableConfig{
		Category:           CategorySeen,
		BootAmount:         100,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        25 * time.Second,
		MaxBetRounds:       20,
		PotLimitMultiplier: 1024,
		MaxRaiseSteps:      8,
		NextHandDelay:      6 * time.Second,
		ChatMaxHistory:     100,
		ChatMaxLength:      140,
	}
}

func stepsEqual(t *testing.T, got []int64, want ...int64) {
	t.Helper()
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("steps %v, want %v", got, want)
	}
}

func TestEachStepDoublesThePreviousAmount(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("a", 200000)
	h.seat("b", 200000)
	h.advance(6 * time.Second)

	steps := h.betOptions(h.turnUser()).Steps
	eq(t, steps[0], int64(100), "the first rung is the plain chaal")
	for i := 1; i < len(steps); i++ {
		eq(t, steps[i], steps[i-1]*2, fmt.Sprintf("step %d doubles", i))
	}
	stepsEqual(t, steps, 100, 200, 400, 800, 1600, 3200, 6400, 12800)

	h.mustAct(h.turnUser(), ActionSee, ActRequest{})
	seen := h.betOptions(h.turnUser()).Steps
	eq(t, seen[0], int64(200), "seen pays double")
	eq(t, seen[1], int64(400), "seen second rung")
}

func TestTheLadderIsCappedByTheNumberOfStepsConfigured(t *testing.T) {
	cfg := ladderConfig()
	cfg.MaxRaiseSteps = 3
	h := newHarness(t, cfg)
	h.seat("a", 200000)
	h.seat("b", 200000)
	h.advance(6 * time.Second)
	stepsEqual(t, h.betOptions(h.turnUser()).Steps, 100, 200, 400)
}

func TestTheLadderIsCappedByThePotLimit(t *testing.T) {
	cfg := ladderConfig()
	cfg.PotLimitMultiplier = 4
	h := newHarness(t, cfg)
	h.seat("a", 200000)
	h.seat("b", 200000)
	h.advance(6 * time.Second)
	opts := h.betOptions(h.turnUser())
	stepsEqual(t, opts.Steps, 100, 200, 400)
	eq(t, deref(opts.Max), int64(400), "max")
}

func TestZeroRungsAndAZeroMultiplierMeanTheLadderRunsToTheWholeStack(t *testing.T) {
	cfg := ladderConfig()
	cfg.MaxRaiseSteps = 0
	cfg.PotLimitMultiplier = 0
	h := newHarness(t, cfg)
	h.seat("a", 100+1_000_000)
	h.seat("b", 100+1_000_000)
	h.advance(6 * time.Second)

	opts := h.betOptions(h.turnUser())
	eq(t, len(opts.Steps), 14, "far past the eight rungs a capped ladder stops at")
	eq(t, opts.Steps[0], int64(100), "first")
	eq(t, deref(opts.Max), int64(819_200), "max")
	if *opts.Max > h.mustSeat(h.turnUser()).Chips {
		t.Fatal("never more than the player holds")
	}
}

func TestTheLadderNeverOffersMoreChipsThanThePlayerHolds(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("rich", 200000)
	h.seat("short", 100+650)
	h.advance(6 * time.Second)

	eq(t, h.mustSeat("short").Chips, int64(650), "chips left after the boot")
	opts := h.betOptions("short")
	stepsEqual(t, opts.Steps, 100, 200, 400)
	eq(t, deref(opts.Max), int64(400), "max")
}

func TestAPlayerWhoCannotAffordTheBaseBetIsOfferedNoBetAtAll(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("rich", 200000)
	h.seat("broke", 100+50)
	h.advance(6 * time.Second)

	opts := h.turnOptions("broke")
	if opts.RaiseSteps == nil || len(opts.RaiseSteps) != 0 {
		t.Fatalf("raiseSteps must be [] (never null), got %v", opts.RaiseSteps)
	}
	if opts.Chaal != nil || opts.Raise != nil || opts.MaxBet != nil {
		t.Fatal("all nil")
	}
	eq(t, opts.CanPack, true, "packing is always available")
	raw, _ := json.Marshal(opts)
	if !strings.Contains(string(raw), `"raiseSteps":[]`) || !strings.Contains(string(raw), `"chaal":null`) {
		t.Fatalf("wire shape: %s", raw)
	}
}

func TestTheTurnPayloadCarriesTheLadderAndThePlayersStack(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("a", 200000)
	h.seat("b", 200000)
	h.advance(6 * time.Second)

	opts := h.turnOptions(h.turnUser())
	eq(t, opts.RaiseSteps[0], *opts.Chaal, "raiseSteps[0] == chaal")
	eq(t, opts.RaiseSteps[1], *opts.Raise, "raiseSteps[1] == raise")
	eq(t, opts.Chips, int64(200000-100), "the client can show what is left")
	eq(t, *opts.MaxBet, opts.RaiseSteps[len(opts.RaiseSteps)-1], "maxBet is the last rung")
	eq(t, opts.CurrentStake, int64(100), "currentStake")
	eq(t, opts.Pot, int64(200), "pot")
	eq(t, opts.CanSee, true, "canSee while blind")
	eq(t, opts.IsBlind, true, "isBlind")
}

func TestARaiseCanBePlacedAtAnyRungOfTheLadder(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("a", 200000)
	h.seat("b", 200000)
	h.advance(6 * time.Second)

	player := h.turnUser()
	potBefore := h.pot()
	res := h.mustAct(player, ActionRaise, amt(800))
	eq(t, res.Action, "raise", "ack")
	eq(t, deref(res.Amount), int64(800), "ack amount")
	eq(t, h.lastAction().Amount, int64(800), "event amount")
	eq(t, h.lastAction().Action, ActionRaise, "event action")
	eq(t, h.pot(), potBefore+800, "pot")
	eq(t, h.mustSeat(player).Chips, int64(200000-100-800), "chips")
	eq(t, h.stake(), int64(800), "a blind bet sets the stake")
}

func TestOmittingTheAmountKeepsTheOldDefaultBehaviour(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("a", 200000)
	h.seat("b", 200000)
	h.advance(6 * time.Second)

	h.mustAct(h.turnUser(), ActionRaise, ActRequest{})
	eq(t, h.lastAction().Amount, int64(200), "a bare raise is still double")
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	eq(t, h.lastAction().Action, ActionChaal, "bare chaal")
}

func TestAnAmountThatIsNotOnTheLadderIsRefused(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("a", 200000)
	h.seat("b", 200000)
	h.advance(6 * time.Second)

	player := h.turnUser()
	for _, bad := range []int64{150, 999, 101, 1, -100} {
		_, err := h.act(player, ActionRaise, amt(bad))
		codeIs(t, err, CodeInvalidBet)
	}
	// A raise must be at least double the chaal (the base rung is a chaal).
	_, err := h.act(player, ActionRaise, amt(100))
	codeIs(t, err, CodeInvalidBet)
	var ge *GameError
	errors.As(err, &ge)
	eq(t, ge.Message, MsgRaiseTooSmall, "message")
}

func TestABetLargerThanThePlayersStackIsRefused(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("rich", 200000)
	h.seat("short", 100+650)
	h.advance(6 * time.Second)

	for h.turnUser() != "short" {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	eq(t, h.mustSeat("short").Chips, int64(650), "short stack")
	_, err := h.act("short", ActionRaise, amt(800))
	codeIs(t, err, CodeInvalidBet)
	_, err = h.act("short", ActionRaise, amt(200000))
	codeIs(t, err, CodeInvalidBet)
	eq(t, h.mustSeat("short").Chips, int64(650), "no chips moved on a refused bet")
}

func TestSteppingUpRepeatedlyStaysInsideTheStackAcrossAWholeHand(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("a", 200000)
	h.seat("b", 200000)
	h.advance(6 * time.Second)

	for i := 0; i < 30 && h.hasHand(); i++ {
		player := h.turnUser()
		opts := h.betOptions(player)
		if opts.Max == nil {
			h.mustAct(player, ActionPack, ActRequest{})
			continue
		}
		action := ActionChaal
		if len(opts.Steps) > 1 {
			action = ActionRaise
		}
		h.mustAct(player, action, amt(*opts.Max))
		if h.mustSeat(player).Chips < 0 {
			t.Fatal("a player can never be driven negative")
		}
	}
	for _, id := range h.occupiedIDs() {
		if h.mustSeat(id).Chips < 0 {
			t.Fatalf("%s has a negative stack", id)
		}
	}
}

func TestAStackThatAffordsOnlyOneRungCanChaalButNotRaise(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("rich", 200000)
	h.seat("tight", 100+150)
	h.advance(6 * time.Second)

	for h.turnUser() != "tight" {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	opts := h.turnOptions("tight")
	stepsEqual(t, opts.RaiseSteps, 100)
	eq(t, deref(opts.Chaal), int64(100), "chaal")
	if opts.Raise != nil {
		t.Fatal("no raise is offered")
	}
	_, err := h.act("tight", ActionRaise, amt(100))
	codeIs(t, err, CodeInvalidBet)
	// A bare raise with a single rung: `amount = null` → "That bet is not available".
	_, err = h.act("tight", ActionRaise, ActRequest{})
	codeIs(t, err, CodeInvalidBet)
	var ge *GameError
	errors.As(err, &ge)
	eq(t, ge.Message, MsgBetUnavailable, "bare raise message")

	h.mustAct("tight", ActionChaal, amt(100))
	eq(t, h.mustSeat("tight").Chips, int64(50), "50 left")
}

func TestAnEmptyLadderRefusesABetWithInsufficientChips(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("rich", 200000)
	h.seat("broke", 100+50)
	h.advance(6 * time.Second)
	for h.turnUser() != "broke" {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	_, err := h.act("broke", ActionChaal, ActRequest{})
	codeIs(t, err, CodeInsufficientChips)
	var ge *GameError
	errors.As(err, &ge)
	eq(t, ge.Message, MsgInsufficientToBet, "message")
	// Show with a nil cost is never free either (2 active).
	_, err = h.act("broke", ActionShow, ActRequest{})
	codeIs(t, err, CodeInsufficientChips)
	errors.As(err, &ge)
	eq(t, ge.Message, MsgInsufficientForShow, "show message")
}

func TestTheTimeoutStillFiresWhileARaiseStepperIsOpen(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("a", 200000)
	h.seat("b", 200000)
	h.advance(6 * time.Second)

	stalling := h.turnUser()
	h.mustAct(stalling, ActionSee, ActRequest{}) // looking does not stop the clock
	// The SEE re-issues the turn with the remaining time and the seen ladder.
	turn := h.lastTurn()
	eq(t, turn.UserID, stalling, "re-issued to the player")
	eq(t, turn.TimeoutMs, int64(25000), "remaining time (nothing elapsed yet)")
	eq(t, deref(turn.Options.Chaal), int64(200), "seen ladder")
	h.advance(25 * time.Second)

	eq(t, h.mustSeat(stalling).Status, SeatPacked, "packed")
	eq(t, h.hasHand(), false, "the last player standing took the pot")
}

func TestAManualSeeReissuesTheTurnWithTheRemainingTime(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("a", 200000)
	h.seat("b", 200000)
	h.advance(6 * time.Second)

	player := h.turnUser()
	deadline := h.lastTurn().Deadline
	h.advance(10 * time.Second)
	h.rec.mu.Lock()
	mark := len(h.rec.events)
	h.rec.mu.Unlock()
	h.mustAct(player, ActionSee, ActRequest{})
	eq(t, strings.Join(h.rec.names()[mark:], ","), "cards,action,turn,state", "manual see on turn order")
	turn := h.lastTurn()
	eq(t, turn.Deadline, deadline, "same deadline")
	eq(t, turn.TimeoutMs, int64(15000), "time left")

	// Off turn: no turn re-issue.
	other := h.otherActive(player)
	mark = h.rec.count()
	h.mustAct(other, ActionSee, ActRequest{})
	eq(t, strings.Join(h.rec.names()[mark:], ","), "cards,action,state", "manual see off turn order")
}

// ------------------------------------------------------ chat.test.js (Table)

func TestASeatedPlayerCanPostToTheirRoom(t *testing.T) {
	h := newHarness(t, categoriesConfig(CategorySeen), withLedger(emptyLedger))
	h.seatNamed("alice", "Alice", 200000)

	msg, err := h.table.PostChat("alice", "good luck everyone")
	if err != nil || msg == nil {
		t.Fatalf("post: %v %v", msg, err)
	}
	eq(t, msg.Text, "good luck everyone", "text")
	eq(t, msg.DisplayName, "Alice", "author")
	found := false
	for _, p := range h.rec.all("chat") {
		if p.(ChatMessage).Text == "good luck everyone" {
			found = true
		}
	}
	eq(t, found, true, "chat event emitted")

	_, err = h.table.PostChat("stranger", "let me in")
	codeIs(t, err, CodeNotInRoom)

	// Whitespace only → nil, no event.
	before := len(h.rec.all("chat"))
	msg, err = h.table.PostChat("alice", "   ")
	if err != nil || msg != nil {
		t.Fatalf("blank post should be nil, nil: %v %v", msg, err)
	}
	eq(t, len(h.rec.all("chat")), before, "no event for a blank line")
}

func TestJoiningAndLeavingAreAnnouncedInTheRoomLog(t *testing.T) {
	h := newHarness(t, categoriesConfig(CategorySeen), withLedger(emptyLedger))
	h.seatNamed("alice", "Alice", 200000)
	h.seatNamed("bob", "Bob", 200000)
	h.remove("bob", LeaveReasonLeft)

	history, err := h.table.ChatHistory()
	if err != nil {
		t.Fatal(err)
	}
	var lines []string
	for _, m := range history {
		lines = append(lines, m.Text)
		if m.System {
			if m.UserID != nil {
				t.Fatal("system lines have no author")
			}
			eq(t, m.DisplayName, ChatSystemDisplayName, "system display name")
		}
	}
	for _, want := range []string{"Alice joined the table", "Bob joined the table", "Bob left the table"} {
		if !contains(lines, want) {
			t.Fatalf("missing %q in %v", want, lines)
		}
	}

	// A later joiner sees the backlog.
	_, _ = h.table.PostChat("alice", "anyone here?")
	h.seatNamed("carol", "Carol", 200000)
	history, _ = h.table.ChatHistory()
	lines = lines[:0]
	for _, m := range history {
		lines = append(lines, m.Text)
	}
	if !contains(lines, "anyone here?") || !contains(lines, "Carol joined the table") {
		t.Fatalf("backlog: %v", lines)
	}
}

func TestDestroyingTheRoomDeletesItsChatHistory(t *testing.T) {
	h := newHarness(t, categoriesConfig(CategorySeen), withLedger(emptyLedger))
	h.seatNamed("alice", "Alice", 200000)
	_, _ = h.table.PostChat("alice", "secret table talk")
	if h.table.chat.Size() == 0 {
		t.Fatal("history expected before destroy")
	}
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	// Reads post to the actor and are refused after Destroy; the buffer
	// itself is empty (white-box: the actor has stopped, nothing races).
	eq(t, h.table.chat.Size(), 0, "nothing survives the room")
	_, err := h.table.ChatHistory()
	if !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("ChatHistory after Destroy: %v", err)
	}
}

func TestChatKeepsWorkingMidHandAndIsNeverInTheSnapshot(t *testing.T) {
	h := newHarness(t, categoriesConfig(CategorySeen), withLedger(emptyLedger))
	h.seatNamed("alice", "Alice", 200000)
	h.seatNamed("bob", "Bob", 200000)
	h.advance(6 * time.Second)
	eq(t, h.hasHand(), true, "a hand is live")

	msg, err := h.table.PostChat("alice", "do not leak me")
	if err != nil || msg == nil || msg.Text != "do not leak me" {
		t.Fatalf("post mid-hand: %v %v", msg, err)
	}
	raw, _ := json.Marshal(h.view("alice"))
	if strings.Contains(string(raw), "do not leak me") {
		t.Fatal("chat travels on its own events, not in state")
	}

	// Two tables never see each other's messages.
	other := newHarness(t, categoriesConfig(CategorySeen), withLedger(emptyLedger), withID("room-2", "TEST02"))
	other.seatNamed("bob", "Bob", 200000)
	history, _ := other.table.ChatHistory()
	for _, m := range history {
		if m.Text == "do not leak me" {
			t.Fatal("chat is scoped to one room")
		}
	}
}

// ------------------------------------------- privateTables.test.js (Table)

func potCapConfig(maxBetRounds int) TableConfig {
	return TableConfig{
		Category:           CategorySeen,
		BootAmount:         200,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        25 * time.Second,
		MaxBetRounds:       maxBetRounds,
		PotLimitMultiplier: 1024,
		MaxRaiseSteps:      8,
		NextHandDelay:      6 * time.Second,
		MaxPot:             5000,
	}
}

func TestABetThatWouldPushThePotPastTheCeilingIsNotOffered(t *testing.T) {
	h := newHarness(t, potCapConfig(100), withLedger(emptyLedger))
	h.seatNamed("a", "A", 2_000_000)
	h.seatNamed("b", "B", 2_000_000)
	h.startHand()

	h.setPot(4000)
	steps := h.betOptions(h.turnUser()).Steps
	for _, step := range steps {
		if 4000+step > 5000 {
			t.Fatalf("%d would push the pot over the ceiling", step)
		}
	}
	stepsEqual(t, steps, 200, 400, 800)
	eq(t, h.view("a").MaxPot, int64(5000), "maxPot reported to clients")
}

func TestReachingTheCeilingEndsTheHandInAShowdown(t *testing.T) {
	h := newHarness(t, potCapConfig(500), withLedger(emptyLedger))
	h.seatNamed("a", "A", 2_000_000)
	h.seatNamed("b", "B", 2_000_000)
	h.startHand()

	for i := 0; i < 200 && h.hasHand(); i++ {
		player := h.turnUser()
		opts := h.betOptions(player)
		if opts.Max == nil {
			break
		}
		action := ActionChaal
		if len(opts.Steps) > 1 {
			action = ActionRaise
		}
		h.mustAct(player, action, amt(*opts.Max))
	}
	eq(t, h.hasHand(), false, "the hand ended on its own")
	ended := h.lastHandEnded()
	eq(t, ended.Reason, WinPotLimit, "reason")
	eq(t, len(h.lastShowdown().Reveals), 2, "everyone still in shows their cards")
	if ended.WinnerID == nil {
		t.Fatal("the best hand takes the pot")
	}
	if ended.Pot > 5000 {
		t.Fatalf("pot %d exceeded the ceiling", ended.Pot)
	}
	eq(t, sumDeltas(h.lastSettled().entries), int64(0), "chips are still conserved")
}

// ------------------------------------------------ redaction & wire shape

func TestSerializeForRedactionRules(t *testing.T) {
	cfg := categoriesConfig(CategoryBlind)
	cfg.MaxMissedTurns = 3
	cfg.MaxBlindMoves = 4
	h := newHarness(t, cfg, withLedger(emptyLedger))
	h.seatNamed("alice", "Alice", 200000)
	h.seatNamed("bob", "Bob", 200000)
	h.advance(6 * time.Second)

	onTurn := h.turnUser()
	other := h.otherActive(onTurn)
	view := h.view(onTurn)

	// Header.
	eq(t, view.RoomID, "room-1", "roomId")
	eq(t, view.Code, "TEST01", "code")
	eq(t, view.State, TableBetting, "state")
	eq(t, view.HandNo, 1, "handNo")
	eq(t, view.MaxPlayers, 5, "maxPlayers")
	eq(t, view.MinPlayers, 2, "minPlayers")
	eq(t, view.BootAmount, int64(200), "bootAmount")
	eq(t, view.TurnTimeoutMs, int64(25000), "turnTimeoutMs")
	if view.StartsAt != nil {
		t.Fatal("startsAt null while betting")
	}
	eq(t, view.Pot, int64(400), "pot")
	eq(t, view.Stake, int64(200), "stake")
	eq(t, view.Round, 0, "round")
	if view.Sideshow != nil {
		t.Fatal("no sideshow")
	}
	if view.Turn == nil || view.Turn.UserID == nil || *view.Turn.UserID != onTurn || view.Turn.Deadline == nil {
		t.Fatalf("turn: %+v", view.Turn)
	}

	// You.
	you := view.You
	eq(t, you.MissedTurns, 0, "missedTurns")
	eq(t, you.MaxMissedTurns, 3, "maxMissedTurns")
	eq(t, you.BlindMovesLeft, 4, "blindMovesLeft")
	eq(t, you.Status, SeatActive, "status")
	if you.Options == nil {
		t.Fatal("options for the player on turn")
	}
	if h.view(other).You.Options != nil {
		t.Fatal("no options off turn")
	}

	// Seats: missedTurns/options never appear; chips null for others.
	raw, _ := json.Marshal(view)
	var generic map[string]any
	_ = json.Unmarshal(raw, &generic)
	seats := generic["seats"].([]any)
	eq(t, len(seats), 5, "five seat entries")
	for _, s := range seats {
		m := s.(map[string]any)
		for _, forbidden := range []string{"missedTurns", "maxMissedTurns", "options", "cards", "socketId", "blindMoves"} {
			if _, ok := m[forbidden]; ok {
				t.Fatalf("seat entry must not carry %s: %v", forbidden, m)
			}
		}
		if m["status"] == "empty" {
			eq(t, len(m), 2, "empty seat is exactly two fields")
			continue
		}
		eq(t, m["cardCount"].(float64), float64(3), "cardCount")
		if m["userId"] != onTurn && m["chips"] != nil {
			t.Fatalf("other player's chips must be null on a blind table: %v", m)
		}
	}
	you2 := generic["you"].(map[string]any)
	if _, ok := you2["missedTurns"]; !ok {
		t.Fatal("missedTurns lives in you")
	}
	if cards, ok := you2["cards"].([]any); !ok || len(cards) != 0 {
		t.Fatalf("you.cards must be [] while blind: %v", you2["cards"])
	}

	// A spectator: you null, everyone's chips null.
	spectator := h.view("watcher")
	if spectator.You != nil {
		t.Fatal("you is null for a non-seated viewer")
	}
	for _, s := range spectator.Seats {
		if !s.Empty && s.Chips != nil {
			t.Fatal("a spectator sees no stacks on a blind table")
		}
	}
	raw, _ = json.Marshal(spectator)
	if !strings.Contains(string(raw), `"you":null`) {
		t.Fatalf("you must marshal as null: %s", raw)
	}
}

func TestSeatsKeepLastHandsStatusAndCardsUntilTheNextDeal(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	h.mustAct(player, ActionSee, ActRequest{})
	h.mustAct(player, ActionPack, ActRequest{})
	eq(t, h.hasHand(), false, "hand over")
	eq(t, h.state(), TableStarting, "next countdown running")

	view := h.view(player)
	eq(t, view.You.Status, SeatPacked, "status persists between hands")
	eq(t, len(view.You.Cards), 3, "a seen viewer still sees last hand's cards")
	if view.You.Options != nil {
		t.Fatal("no options between hands")
	}
	if view.Turn != nil {
		t.Fatal("turn is null between hands")
	}
	if view.StartsAt == nil {
		t.Fatal("startsAt set while starting")
	}
	eq(t, view.Stake, tableBoot, "stake falls back to the boot")
	var winner string
	for _, id := range h.occupiedIDs() {
		if id != player {
			winner = id
		}
	}
	eq(t, seatViewOf(view, winner).Status, SeatWon, "winner keeps won")
	eq(t, seatViewOf(view, winner).CardCount, 3, "cardCount stays 3")

	h.advance(6 * time.Second)
	view = h.view(player)
	eq(t, view.You.Status, SeatActive, "active again")
	eq(t, len(view.You.Cards), 0, "blind again")
}

func TestLedgerRequestsCarryTheMoneyFactsAndTheSnapshotIsTheLiveOne(t *testing.T) {
	// PostgreSQL is written at three moments and no others (LIVE_STATE_PLAN.md):
	// a pack, a leave or switch, and the hand end. The deal and every bet move
	// chips at the seat and in the snapshot only.
	var checkpoints []CheckpointRequest
	var settles []SettleRequest
	h := newHarness(t, tableConfig(), withLedger(func(h *harness) Ledger {
		return &captureLedger{
			inner:        mirrorLedger(h),
			onCheckpoint: func(r CheckpointRequest) { checkpoints = append(checkpoints, r) },
			onSettle:     func(r SettleRequest) { settles = append(settles, r) },
		}
	}))
	h.seat("alice", tableStart)
	h.seat("bob", tableStart)
	h.seat("carol", tableStart)
	h.advance(6 * time.Second)

	eq(t, len(checkpoints), 0, "the deal writes nothing")
	eq(t, len(settles), 0, "and settles nothing")
	eq(t, h.table.Version(), int64(0), "no committed write yet")

	snap, err := h.table.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	eq(t, snap.State, TableBetting, "snapshot state is betting")
	eq(t, snap.HandNo, 1, "handNo")
	eq(t, snap.Hand.Pot, tableBoot*3, "pot")
	eq(t, snap.Hand.Stake, tableBoot, "stake")
	if snap.Hand.TurnSeat < 0 || snap.Hand.StartSeat < 0 || snap.Hand.TurnDeadline == nil {
		t.Fatalf("the live snapshot is the table as it is, turn included: %+v", snap.Hand)
	}
	eq(t, len(snap.Hand.Contributions), 3, "contributions")
	for _, c := range snap.Hand.Contributions {
		eq(t, c.Contributed, tableBoot, "contributed")
		eq(t, c.Chips, tableStart-tableBoot, "the live stack")
		eq(t, c.ChipsWritten, tableStart, "PostgreSQL still holds the pre-boot figure")
		eq(t, c.Status, SeatActive, "active")
		eq(t, len(c.Cards), 3, "contribution cards kept server-side")
	}
	eq(t, len(snap.Seats), 5, "five seat slots")
	occupied := 0
	for _, s := range snap.Seats {
		if s == nil {
			continue
		}
		occupied++
		eq(t, s.Chips, tableStart-tableBoot, "debited")
		eq(t, s.Status, SeatActive, "active")
		eq(t, s.IsBlind, true, "blind")
		eq(t, s.Contributed, tableBoot, "contributed")
		eq(t, len(s.Cards), 3, "cards included server-side")
	}
	eq(t, occupied, 3, "three occupied")
	raw, _ := json.Marshal(snap)
	for _, key := range []string{`"roomId"`, `"code"`, `"category"`, `"state"`, `"handNo"`, `"dealerSeat"`, `"hand"`, `"seats"`, `"contributions"`, `"showRequestedBy":null`, `"startedAt"`,
		`"seq"`, `"version"`, `"config"`, `"turnDeadline"`, `"packedUserIds"`, `"seatOrder"`, `"sideshow":null`, `"lastDeparture":null`, `"createdAt"`, `"isPrivate"`, `"chipsWritten"`, `"actionIds"`} {
		if !strings.Contains(string(raw), key) {
			t.Fatalf("snapshot JSON lacks %s: %s", key, raw)
		}
	}
	for _, forbidden := range []string{"turnToken", "connected", "socketId"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("snapshot JSON must not carry %s", forbidden)
		}
	}
	if strings.Contains(string(raw), "null,null") == false {
		t.Fatalf("empty seats must marshal as null: %s", raw)
	}

	player := h.turnUser()
	h.mustAct(player, ActionChaal, amt(tableBoot))
	eq(t, len(checkpoints), 0, "a bet writes nothing either")
	eq(t, h.table.Version(), int64(0), "still nothing committed")
	snap, _ = h.table.Snapshot()
	eq(t, snap.Hand.Pot, tableBoot*4, "pot advanced in the live snapshot")
	for _, c := range snap.Hand.Contributions {
		if c.UserID == player {
			eq(t, c.Contributed, tableBoot*2, "contribution advanced")
			eq(t, c.DidChaal, true, "played")
			eq(t, c.Chips, tableStart-tableBoot*2, "live stack")
			eq(t, c.ChipsWritten, tableStart, "and PostgreSQL still knows nothing of it")
		}
	}
	eq(t, len(snap.Hand.ActionIDs), 1, "the bet's action id is remembered for the duplicate guard")

	// CHECKPOINT 1: a pack. That one player is written, nobody else.
	packer := h.turnUser()
	packerStaked := h.mustSeat(packer).Contributed
	h.mustAct(packer, ActionPack, ActRequest{})
	eq(t, len(checkpoints), 1, "one checkpoint")
	cp := checkpoints[0]
	eq(t, cp.RoomID, "room-1", "roomId")
	eq(t, cp.Entry.UserID, packer, "the packer")
	eq(t, cp.Entry.Delta, -packerStaked, "their whole stake, as a delta")
	eq(t, cp.Entry.Reason, LedgerReasonHandPacked, "reason")
	eq(t, cp.Entry.Outcome, false, "a pack carries no counters")
	eq(t, cp.Entry.ActionID, PackedActionID(cp.HandID, packer), "action id")
	eq(t, h.table.Version(), int64(1), "one committed write")

	// CHECKPOINT 3: the hand end resolves everyone still at the table —
	// packers included, with a delta of zero.
	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	eq(t, len(settles), 1, "one settle")
	settle := settles[0]
	byUser := map[string]SettleEntry{}
	for _, e := range settle.Entries {
		byUser[e.UserID] = e
	}
	eq(t, len(settle.Entries), 3, "everyone still at the table")
	eq(t, byUser[packer].Delta, int64(0), "the packer's money moved at the pack")
	eq(t, byUser[packer].Reason, LedgerReasonHandLoss, "and their outcome row is a loss")
	eq(t, byUser[packer].Outcome, true, "which carries the counters")
	winners := 0
	for _, e := range settle.Entries {
		if e.IsWinner {
			winners++
			eq(t, e.Reason, LedgerReasonHandWin, "winner reason")
			eq(t, e.Pot, h.lastEnded().Pot, "the pot for total_winnings")
		}
		eq(t, e.ActionID, SettleActionID(settle.HandID, e.UserID), "settle action id")
	}
	eq(t, winners, 1, "one winner")
	eq(t, h.table.Version(), int64(3), "the pack, this pack, and the settlement")
	snap, _ = h.table.Snapshot()
	eq(t, snap.State, TableStarting, "back between hands")
	if snap.Hand != nil {
		t.Fatal("snapshot hand null between hands")
	}
	eq(t, snap.HandNo, 1, "handNo of the hand just ended")
	ended := h.lastEnded()
	eq(t, ended.HandNo, 1, "the handEnded event carries the record now")
	eq(t, len(ended.Summary), 3, "three contributors")
	for _, row := range ended.Summary {
		if row.Cards != nil {
			t.Fatal("no cards in the summary without a showdown")
		}
	}
	rawSummary, _ := json.Marshal(ended.Summary)
	if !strings.Contains(string(rawSummary), `"cards":null`) {
		t.Fatalf("summary cards must be null when unrevealed: %s", rawSummary)
	}
}

// captureLedger wraps a Ledger to record (or override) each call.
type captureLedger struct {
	inner        Ledger
	onCheckpoint func(CheckpointRequest)
	onSettle     func(SettleRequest)
	// overrides, when set, replace the inner call.
	checkpoint func(CheckpointRequest) (CheckpointResult, error)
	settle     func(SettleRequest) (SettleResult, error)
}

func (c *captureLedger) Checkpoint(ctx context.Context, req CheckpointRequest) (CheckpointResult, error) {
	if c.onCheckpoint != nil {
		c.onCheckpoint(req)
	}
	if c.checkpoint != nil {
		return c.checkpoint(req)
	}
	return c.inner.Checkpoint(ctx, req)
}

func (c *captureLedger) Settle(ctx context.Context, req SettleRequest) (SettleResult, error) {
	if c.onSettle != nil {
		c.onSettle(req)
	}
	if c.settle != nil {
		return c.settle(req)
	}
	return c.inner.Settle(ctx, req)
}

var _ Ledger = (*captureLedger)(nil)

// ------------------------------------------------ View and lock-free getters

// viewProbe is a Listener that exercises the View from inside callbacks — the
// only place a View is valid — and records what it saw.
type viewProbe struct {
	NopListener
	mu       sync.Mutex
	handEnds int
	seen     []string
}

func (p *viewProbe) OnHandStarted(v *View, e HandStartedEvent) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.seen = append(p.seen, fmt.Sprintf("started:%s:%s:%v:%d:%d", v.ID(), v.Code(), v.HasHand(), v.Pot(), len(v.Seats())))
	for _, id := range e.Participants {
		if s := v.FindSeat(id); s == nil || s.Status != SeatActive || len(s.Cards) != 3 {
			p.seen = append(p.seen, "bad-seat:"+id)
		}
		if tv := v.SerializeFor(id); tv.You == nil || len(tv.You.Cards) != 0 {
			p.seen = append(p.seen, "bad-view:"+id)
		}
	}
	if v.FindSeat("nobody") != nil {
		p.seen = append(p.seen, "ghost")
	}
	p.seen = append(p.seen, fmt.Sprintf("summary:%d:%s:%v:%s", v.Summary().Players, v.Summary().State, v.IsPrivate(), v.Category()))
	p.seen = append(p.seen, fmt.Sprintf("chat:%d", len(v.ChatHistory())))
}

func (p *viewProbe) OnHandEnded(v *View, e HandEndedEvent) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.handEnds++
	p.seen = append(p.seen, fmt.Sprintf("ended:%v:%d:%s:%d", v.HasHand(), v.Pot(), v.State(), v.Config().MaxPlayers))
}

func TestViewAccessorsInsideCallbacksAndLockFreeGetters(t *testing.T) {
	probe := &viewProbe{}
	clock := newFakeClock(clockStart)
	cfg := tableConfig()
	table := NewTable(TableOptions{ID: "view-room", Code: "VIEW01", Config: cfg, IsPrivate: true, Clock: clock, Listener: probe})
	t.Cleanup(func() { _ = table.Destroy() })

	eq(t, table.ID(), "view-room", "ID")
	eq(t, table.Code(), "VIEW01", "Code")
	eq(t, table.IsPrivate(), true, "IsPrivate")
	eq(t, table.BootAmount(), tableBoot, "BootAmount")
	eq(t, table.MaxPot(), int64(0), "MaxPot")
	eq(t, table.CreatedAt(), clockStart, "CreatedAt from the clock")
	eq(t, table.IsEmpty(), true, "IsEmpty")
	eq(t, table.Destroyed(), false, "not destroyed")
	eq(t, RealClock{}.Now().IsZero(), false, "RealClock ticks")
	eq(t, FromMillis(Millis(clockStart)), clockStart, "Millis round trip")

	for _, id := range []string{"a", "b"} {
		if _, err := table.AddPlayer(NewPlayer{UserID: id, DisplayName: id, Chips: tableStart}); err != nil {
			t.Fatal(err)
		}
	}
	eq(t, table.IsEmpty(), false, "seated")
	clock.Advance(6 * time.Second)
	eq(t, table.HasHand(), true, "HasHand")
	eq(t, table.State(), TableBetting, "State")

	var onTurn string
	_ = table.run(func() { onTurn = table.seats[table.hand.turnSeat].userID })
	if _, err := table.Act(onTurn, ActionPack, ActRequest{}); err != nil {
		t.Fatal(err)
	}

	probe.mu.Lock()
	defer probe.mu.Unlock()
	eq(t, probe.handEnds, 1, "one hand ended")
	want := []string{
		"started:view-room:VIEW01:true:200:2",
		"summary:2:betting:true:seen",
		"chat:2",
		"ended:false:0:waiting:5",
	}
	eq(t, strings.Join(probe.seen, "|"), strings.Join(want, "|"), "what the View reported")
}

func TestDestroyHandsArmedSettleRetriesToADetachedChain(t *testing.T) {
	// Node dropped the retry (`if (this._destroyed) return`) and the pot was
	// never banked; the port keeps the write alive off the actor
	// (Table.settleDetached, review_money_test.go). Destroy still stops
	// every actor timer and no Listener event follows it.
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		return NewMemoryLedger(MemoryLedgerHooks{
			Settle: func(SettleRequest, []SettleEntry) (map[string]int64, error) { return nil, errors.New("settle down") },
		})
	}))
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)
	handID := h.lastHandStarted().HandID
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	if h.clock.Pending() < 2 {
		t.Fatalf("expected a retry timer and the next countdown, have %d", h.clock.Pending())
	}
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	eq(t, h.clock.Pending(), 1, "the countdown is gone; the owed settlement's retry is the only timer left")
	eq(t, h.table.PendingSettlements(), 1, "one settlement still owed")
	count := h.rec.count()
	h.advance(time.Hour)
	eq(t, h.rec.count(), count, "no event after Destroy")
	eq(t, h.clock.Pending(), 0, "the chain gave up and left no timer")
	eq(t, h.table.PendingSettlements(), 0, "nothing pending")
	err := h.table.WaitSettlements(context.Background())
	if err == nil || !strings.Contains(err.Error(), handID) {
		t.Fatalf("WaitSettlements should report the abandoned hand, got %v", err)
	}
}

func TestTheFirstRungIsThePerBetCeilingWhenTheStakeOutgrowsIt(t *testing.T) {
	// DECISIONS.md §2 / spec §11.1 quirk: boot 100, potLimitMultiplier 4,
	// blind stake 800 → {steps:[400], chaal:400, raise:null, max:400}.
	cfg := tableConfig()
	cfg.PotLimitMultiplier = 4
	h := newHarness(t, cfg)
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	h.advance(6 * time.Second)
	h.read(func() { h.table.hand.stake = 800 })

	player := h.turnUser()
	opts := h.betOptions(player)
	stepsEqual(t, opts.Steps, 400)
	eq(t, deref(opts.Chaal), int64(400), "chaal is the ceiling itself")
	if opts.Raise != nil {
		t.Fatal("no raise")
	}
	eq(t, deref(opts.Max), int64(400), "max")
	eq(t, deref(h.showCost(player)), int64(400), "a show costs the chaal")

	// A seen player's show costs 2 × stake when it fits.
	h.read(func() { h.table.hand.stake = 100 })
	h.mustAct(player, ActionSee, ActRequest{})
	eq(t, deref(h.showCost(player)), int64(200), "seen caller pays double")
	// And the seen bet at the ceiling still records the stake in blind units.
	h.read(func() { h.table.hand.stake = 800 })
	h.mustAct(player, ActionChaal, amt(400))
	eq(t, h.stake(), int64(200), "floor(400/2)")
	eq(t, h.lastAction().Amount, int64(400), "charged the ceiling")
}

// ------------------------------------------------------- Node parity (diff)

// A parityStep is one scripted operation applied identically to the Node
// Table (server/src/game/table.js under fakeTimers) and the Go Table. Both
// runs emit the same normalised record stream — every event in order, every
// ack (result or error code + message), and per-viewer snapshots at each
// "view" step — and the streams must be identical. Wall-clock fields
// (deadlines, expiresAt, startsAt, nextHandAt, timestamps) and random ids
// (handId, chat ids) are stripped; everything else is compared verbatim.
type parityStep struct {
	Op     string   `json:"op"`
	ID     string   `json:"id,omitempty"`
	Chips  int64    `json:"chips,omitempty"`
	Ms     int64    `json:"ms,omitempty"`
	Action string   `json:"action,omitempty"`
	Amount *int64   `json:"amount,omitempty"`
	Accept bool     `json:"accept"`
	Reason string   `json:"reason,omitempty"`
	Cards  []string `json:"cards,omitempty"`
	Text   string   `json:"text,omitempty"`
	Flag   bool     `json:"flag"`
}

type parityScenario struct {
	Name    string
	Config  TableConfig
	Viewers []string
	Steps   []parityStep
}

func ps(op string) parityStep { return parityStep{Op: op} }
func pSeat(id string, chips int64) parityStep {
	return parityStep{Op: "seat", ID: id, Chips: chips}
}
func pAdvance(ms int64) parityStep { return parityStep{Op: "advance", Ms: ms} }
func pAct(id, action string) parityStep {
	return parityStep{Op: "act", ID: id, Action: action}
}
func pActAmt(id, action string, amount int64) parityStep {
	return parityStep{Op: "act", ID: id, Action: action, Amount: Int64Ptr(amount)}
}
func pRespond(id string, accept bool) parityStep {
	return parityStep{Op: "respond", ID: id, Accept: accept}
}
func pRemove(id, reason string) parityStep {
	return parityStep{Op: "remove", ID: id, Reason: reason}
}
func pCards(id string, codes ...string) parityStep {
	return parityStep{Op: "cards", ID: id, Cards: codes}
}
func pChat(id, text string) parityStep { return parityStep{Op: "chat", ID: id, Text: text} }
func pConnected(id string, connected bool) parityStep {
	return parityStep{Op: "connected", ID: id, Flag: connected}
}

// nodeConfig renders a TableConfig as the raw config object table.js reads.
func nodeConfig(cfg TableConfig) map[string]any {
	return map[string]any{
		"category":           string(cfg.Category),
		"bootAmount":         cfg.BootAmount,
		"maxPlayers":         cfg.MaxPlayers,
		"minPlayers":         cfg.MinPlayers,
		"turnTimeoutMs":      cfg.TurnTimeout.Milliseconds(),
		"maxBetRounds":       cfg.MaxBetRounds,
		"potLimitMultiplier": cfg.PotLimitMultiplier,
		"maxRaiseSteps":      cfg.MaxRaiseSteps,
		"maxPot":             cfg.MaxPot,
		"maxBlindMoves":      cfg.MaxBlindMoves,
		"maxMissedTurns":     cfg.MaxMissedTurns,
		"sideshowTimeoutMs":  cfg.SideshowTimeout.Milliseconds(),
		"sideshowMinPlayers": cfg.SideshowMinPlayers,
		"nextHandDelayMs":    cfg.NextHandDelay.Milliseconds(),
		"chatMaxHistory":     100,
		"chatMaxLength":      140,
	}
}

const parityNodeScript = `
import Table from './src/game/table.js';
import { parseCard } from './src/game/deck.js';
import createFakeTimers from './test/helpers/fakeTimers.js';
const S = __SCENARIO__;
const { timers, advance } = createFakeTimers();
const out = [];
const strip = (o, keys) => { const c = { ...o }; for (const k of keys) delete c[k]; return c; };
const table = new Table({
  id: 'parity', code: 'PAR001', config: S.config, timers,
  settle: ({ hand, entries }) => {
    out.push({ ev: 'settle', handNo: hand.handNo, pot: hand.pot, winnerId: hand.winnerId, winReason: hand.winReason,
      bootAmount: hand.bootAmount, roomId: hand.roomId, summary: hand.summary,
      entries: entries.map((e) => ({ userId: e.userId, delta: e.delta, isWinner: e.isWinner, didChaal: e.didChaal, leftMidHand: e.leftMidHand })) });
    return Object.fromEntries(entries.map((e) => {
      const s = table.findSeat(e.userId);
      return [e.userId, (s ? s.chips : 0) + (e.isWinner ? hand.pot : 0)];
    }));
  },
});
table.on('state', () => out.push({ ev: 'state' }));
table.on('seatUpdated', (p) => out.push({ ev: 'seatUpdated', seatIndex: p.seatIndex }));
table.on('chat', (m) => out.push({ ev: 'chat', userId: m.userId, displayName: m.displayName, text: m.text, system: m.system ?? false }));
table.on('handStarted', (p) => out.push({ ev: 'handStarted', ...strip(p, ['handId']) }));
table.on('cards', (p) => out.push({ ev: 'cards', ...p }));
table.on('turn', (p) => out.push({ ev: 'turn', userId: p.userId, seatIndex: p.seatIndex, options: p.options }));
table.on('action', (p) => out.push({ ev: 'action', ...p }));
table.on('sideshowRequested', (p) => out.push({ ev: 'sideshowRequested', ...strip(p, ['expiresAt']) }));
table.on('sideshowReveal', (p) => out.push({ ev: 'sideshowReveal', ...p }));
table.on('sideshowResolved', (p) => out.push({ ev: 'sideshowResolved', ...p }));
table.on('showdown', (p) => out.push({ ev: 'showdown', ...p }));
table.on('handEnded', (p) => out.push({ ev: 'handEnded', ...strip(p, ['handId', 'nextHandAt']) }));
table.on('kick', (p) => out.push({ ev: 'kick', ...p }));
table.on('persistError', (p) => out.push({ ev: 'persistError', reason: p.reason }));
const normView = (v) => ({ ...strip(v, ['startsAt']),
  turn: v.turn ? strip(v.turn, ['deadline']) : null,
  sideshow: v.sideshow ? strip(v.sideshow, ['expiresAt']) : null });
const ack = (fn) => { try { const r = fn(); return r && typeof r.then === 'function' ? r.then((v) => ({ ok: true, result: v ?? null }), (e) => ({ ok: false, code: e.code, message: e.message })) : Promise.resolve({ ok: true, result: r ?? null }); } catch (e) { return Promise.resolve({ ok: false, code: e.code, message: e.message }); } };
for (const step of S.steps) {
  switch (step.op) {
    case 'seat': out.push({ ev: 'ack', ...(await ack(() => { const s = table.addPlayer({ userId: step.id, displayName: step.id.toUpperCase(), avatarUrl: null, chips: step.chips, socketId: 's-' + step.id }); return { seatIndex: s.seatIndex, status: s.status }; })) }); break;
    case 'advance': await advance(step.ms); break;
    case 'startHand': await table.startHand(); break;
    case 'cards': table.findSeat(step.id).cards = step.cards.map(parseCard); break;
    case 'act': out.push({ ev: 'ack', ...(await ack(() => table.act(step.id, step.action, step.amount === undefined ? {} : { amount: step.amount }))) }); break;
    case 'respond': out.push({ ev: 'ack', ...(await ack(() => table.respondToSideshow(step.id, step.accept))) }); break;
    case 'remove': { const s = await table.removePlayer(step.id, step.reason); out.push({ ev: 'ack', ok: true, result: s ? { status: s.status } : null }); break; }
    case 'chat': out.push({ ev: 'ack', ...(await ack(() => { const m = table.postChat(step.id, step.text); return m ? { text: m.text, displayName: m.displayName } : null; })) }); break;
    case 'connected': { const s = table.setConnected(step.id, step.flag, step.flag ? 'sock-' + step.id : null); out.push({ ev: 'ack', ok: true, result: s ? { connected: s.connected } : null }); break; }
    case 'destroy': await table.destroy(); out.push({ ev: 'ack', ok: true, result: null }); break;
    case 'view': for (const v of S.viewers) out.push({ ev: 'view', viewer: v, view: normView(table.serializeFor(v)) }); break;
    default: throw new Error('unknown op ' + step.op);
  }
}
console.log(JSON.stringify(out));
`

// parityRecorder turns Go events into the same generic records.
type parityRecorder struct {
	NopListener
	out []any
}

func toGeneric(v any) map[string]any {
	raw, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		panic(err)
	}
	return m
}

func (p *parityRecorder) push(ev string, m map[string]any, drop ...string) {
	if m == nil {
		m = map[string]any{}
	}
	for _, k := range drop {
		delete(m, k)
	}
	m["ev"] = ev
	p.out = append(p.out, m)
}

func (p *parityRecorder) OnState(*View) { p.push("state", nil) }
func (p *parityRecorder) OnSeatUpdated(_ *View, i int) {
	p.push("seatUpdated", map[string]any{"seatIndex": i})
}
func (p *parityRecorder) OnChat(_ *View, m *ChatMessage) {
	var uid any
	if m.UserID != nil {
		uid = *m.UserID
	}
	p.push("chat", map[string]any{"userId": uid, "displayName": m.DisplayName, "text": m.Text, "system": m.System})
}
func (p *parityRecorder) OnHandStarted(_ *View, e HandStartedEvent) {
	p.push("handStarted", toGeneric(e), "handId")
}
func (p *parityRecorder) OnCards(_ *View, e CardsEvent) {
	p.push("cards", map[string]any{"userId": e.UserID, "cards": e.Cards})
}
func (p *parityRecorder) OnTurn(_ *View, e TurnEvent) {
	p.push("turn", map[string]any{"userId": e.UserID, "seatIndex": e.SeatIndex, "options": toGeneric(e.Options)})
}
func (p *parityRecorder) OnAction(_ *View, e ActionEvent) { p.push("action", toGeneric(e)) }
func (p *parityRecorder) OnSideshowRequested(_ *View, e SideshowRequestedEvent) {
	p.push("sideshowRequested", toGeneric(e), "expiresAt")
}
func (p *parityRecorder) OnSideshowReveal(_ *View, e SideshowRevealEvent) {
	p.push("sideshowReveal", map[string]any{"userIds": e.UserIDs, "reveal": toGeneric(e.Reveal)})
}
func (p *parityRecorder) OnSideshowResolved(_ *View, e SideshowResolvedEvent) {
	p.push("sideshowResolved", toGeneric(e))
}
func (p *parityRecorder) OnShowdown(_ *View, e ShowdownEvent) { p.push("showdown", toGeneric(e)) }
func (p *parityRecorder) OnHandEnded(_ *View, e HandEndedEvent) {
	p.push("handEnded", toGeneric(e), "handId", "nextHandAt")
}
func (p *parityRecorder) OnKick(_ *View, e KickEvent) {
	p.push("kick", map[string]any{"userId": e.UserID, "displayName": e.DisplayName, "reason": e.Reason, "message": e.Message})
}
func (p *parityRecorder) OnPersistError(_ *View, e PersistErrorEvent) {
	p.push("persistError", map[string]any{"reason": e.Reason})
}

func (p *parityRecorder) ack(result any, err error) {
	if err != nil {
		var ge *GameError
		errors.As(err, &ge)
		p.out = append(p.out, map[string]any{"ev": "ack", "ok": false, "code": ge.Code, "message": ge.Message})
		return
	}
	var generic any
	if result != nil {
		raw, _ := json.Marshal(result)
		_ = json.Unmarshal(raw, &generic)
	}
	p.out = append(p.out, map[string]any{"ev": "ack", "ok": true, "result": generic})
}

func runGoParity(t *testing.T, sc parityScenario) []any {
	t.Helper()
	rec := &parityRecorder{}
	clock := newFakeClock(clockStart)
	var table *Table
	ledger := NewMemoryLedger(MemoryLedgerHooks{
		Settle: func(req SettleRequest, entries []SettleEntry) (map[string]int64, error) {
			es := make([]map[string]any, 0, len(entries))
			balances := map[string]int64{}
			for _, e := range entries {
				es = append(es, map[string]any{"userId": e.UserID, "delta": e.Delta, "isWinner": e.IsWinner, "didChaal": e.DidChaal, "leftMidHand": e.LeftMidHand, "reason": e.Reason})
				if s := table.findSeat(e.UserID); s != nil {
					balances[e.UserID] = s.chips
				}
			}
			rec.push("settle", map[string]any{"handId": req.HandID, "roomId": req.RoomID, "entries": es})
			return balances, nil
		},
	})
	table = NewTable(TableOptions{ID: "parity", Code: "PAR001", Config: sc.Config, Ledger: ledger, Clock: clock, Listener: rec})
	t.Cleanup(func() { _ = table.Destroy() })

	for i, step := range sc.Steps {
		switch step.Op {
		case "seat":
			info, err := table.AddPlayer(NewPlayer{UserID: step.ID, DisplayName: strings.ToUpper(step.ID), Chips: step.Chips, SocketID: "s-" + step.ID})
			if err != nil {
				rec.ack(nil, err)
			} else {
				rec.ack(map[string]any{"seatIndex": info.SeatIndex, "status": info.Status}, nil)
			}
		case "advance":
			clock.Advance(time.Duration(step.Ms) * time.Millisecond)
		case "startHand":
			if err := table.StartHand(); err != nil {
				t.Fatalf("step %d: %v", i, err)
			}
		case "cards":
			if err := table.run(func() { table.findSeat(step.ID).cards = ParseCards(step.Cards) }); err != nil {
				t.Fatalf("step %d: %v", i, err)
			}
		case "act":
			res, err := table.Act(step.ID, Action(step.Action), ActRequest{Amount: step.Amount})
			if err != nil {
				rec.ack(nil, err)
			} else {
				rec.ack(res, nil)
			}
		case "respond":
			res, err := table.RespondToSideshow(step.ID, step.Accept)
			if err != nil {
				rec.ack(nil, err)
			} else {
				rec.ack(res, nil)
			}
		case "remove":
			info, err := table.RemovePlayer(step.ID, step.Reason)
			if err != nil {
				t.Fatalf("step %d: %v", i, err)
			}
			if info == nil {
				rec.ack(nil, nil)
			} else {
				rec.ack(map[string]any{"status": info.Status}, nil)
			}
		case "chat":
			msg, err := table.PostChat(step.ID, step.Text)
			switch {
			case err != nil:
				rec.ack(nil, err)
			case msg == nil:
				rec.ack(nil, nil)
			default:
				rec.ack(map[string]any{"text": msg.Text, "displayName": msg.DisplayName}, nil)
			}
		case "connected":
			socket := ""
			if step.Flag {
				socket = "sock-" + step.ID
			}
			info, err := table.SetConnected(step.ID, step.Flag, socket)
			if err != nil {
				t.Fatalf("step %d: %v", i, err)
			}
			if info == nil {
				rec.ack(nil, nil)
			} else {
				rec.ack(map[string]any{"connected": info.Connected}, nil)
			}
		case "destroy":
			if err := table.Destroy(); err != nil {
				t.Fatalf("step %d: %v", i, err)
			}
			rec.ack(nil, nil)
		case "view":
			for _, viewer := range sc.Viewers {
				view, err := table.SerializeFor(viewer)
				if err != nil {
					t.Fatalf("step %d: %v", i, err)
				}
				generic := toGeneric(view)
				delete(generic, "startsAt")
				if turn, ok := generic["turn"].(map[string]any); ok {
					delete(turn, "deadline")
				}
				if ss, ok := generic["sideshow"].(map[string]any); ok {
					delete(ss, "expiresAt")
				}
				rec.out = append(rec.out, map[string]any{"ev": "view", "viewer": viewer, "view": generic})
			}
		default:
			t.Fatalf("unknown op %q", step.Op)
		}
	}
	return rec.out
}

func canonical(t *testing.T, v any) string {
	t.Helper()
	raw, err := json.Marshal(v) // map keys are sorted
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func runParity(t *testing.T, sc parityScenario) {
	t.Helper()
	dir := nodeServerDir(t)
	scenario, err := json.Marshal(map[string]any{"config": nodeConfig(sc.Config), "viewers": sc.Viewers, "steps": sc.Steps})
	if err != nil {
		t.Fatal(err)
	}
	var nodeOut []any
	runNode(t, dir, strings.Replace(parityNodeScript, "__SCENARIO__", string(scenario), 1), &nodeOut)
	goOut := runGoParity(t, sc)

	// Round-trip the Go records through JSON so numbers compare as float64.
	var goGeneric []any
	if err := json.Unmarshal([]byte(canonical(t, goOut)), &goGeneric); err != nil {
		t.Fatal(err)
	}
	n := len(nodeOut)
	if len(goGeneric) < n {
		n = len(goGeneric)
	}
	for i := 0; i < n; i++ {
		a, b := canonical(t, nodeOut[i]), canonical(t, goGeneric[i])
		if a != b {
			t.Fatalf("%s: record %d differs\nnode: %s\ngo:   %s", sc.Name, i, a, b)
		}
	}
	if len(nodeOut) != len(goGeneric) {
		t.Fatalf("%s: node emitted %d records, go %d", sc.Name, len(nodeOut), len(goGeneric))
	}
	// A histogram of what the script exercised, so a maintainer can see the
	// paths covered without reading the steps.
	hist := map[string]int{}
	for _, rec := range nodeOut {
		m := rec.(map[string]any)
		key := m["ev"].(string)
		for _, k := range []string{"action", "reason", "code"} {
			if v, ok := m[k].(string); ok {
				key += ":" + v
			}
		}
		hist[key]++
	}
	keys := make([]string, 0, len(hist))
	for k := range hist {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", k, hist[k]))
	}
	t.Logf("%s: %d records identical: %s", sc.Name, len(nodeOut), strings.Join(parts, " "))
}

func TestParityWithNodeTableOnScriptedScenarios(t *testing.T) {
	seen := TableConfig{
		Category: CategorySeen, BootAmount: 100, MaxPlayers: 5, MinPlayers: 2, TurnTimeout: 25 * time.Second,
		MaxBetRounds: 20, PotLimitMultiplier: 1024, MaxRaiseSteps: 8, MaxBlindMoves: 4, MaxMissedTurns: 3,
		SideshowTimeout: 6 * time.Second, SideshowMinPlayers: 3, NextHandDelay: 6 * time.Second,
		ChatMaxHistory: 100, ChatMaxLength: 140,
	}
	runParity(t, parityScenario{
		Name:    "seen table: sideshow, short stack, show, tie, leaves",
		Config:  seen,
		Viewers: []string{"a", "b", "c", "watcher"},
		Steps: []parityStep{
			pSeat("a", 200000), pSeat("b", 200000), pSeat("c", 800), pSeat("a", 5), ps("view"),
			pAdvance(6000), // hand 1: dealer 0, turn b
			pCards("a", "As", "Ah", "Ad"), pCards("b", "2s", "7h", "9d"), pCards("c", "Ks", "Kh", "4d"), ps("view"),
			pAct("a", "chaal"), pAct("nobody", "chaal"), pAct("b", "steal_the_pot"), pAct("a", "steal_the_pot"),
			pAct("b", "see"), pAct("b", "see"), pAct("b", "chaal"),
			pAct("c", "see"), pAct("c", "sideshow"), pAct("c", "sideshow"),
			pRespond("a", true), pRespond("c", true), ps("view"),
			pRespond("b", true), ps("view"), // c's pair beats b: b packs, turn stays with c
			pActAmt("c", "raise", 400), pAct("a", "see"), pAct("a", "chaal"),
			pAct("c", "chaal"), pAct("c", "show"), pActAmt("c", "raise", 100), pAct("c", "pack"), ps("view"),
			pAdvance(6000), // hand 2: dealer 1, turn c
			pCards("a", "As", "9s", "4s"), pCards("b", "Ah", "9h", "4h"), pCards("c", "2c", "3c", "5d"),
			pAct("c", "chaal"), pAct("a", "chaal"), pAct("b", "pack"), pAct("c", "show"), ps("view"), // c pays its last 100 to show and loses
			pAdvance(6000), // hand 3: c is unfunded → kick announced (no handler here), a & b play; dealer 0, turn b
			pCards("a", "Ah", "9h", "4h"), pCards("b", "As", "9s", "4s"),
			pAct("b", "show"), ps("view"), // exact tie: the show payer loses
			pRemove("c", "left"), pRemove("c", "left"),
			pAdvance(6000), // hand 4: dealer 1, turn a
			pCards("a", "2s", "3d", "7c"), pCards("b", "Ks", "Kd", "4c"),
			pAct("a", "chaal"), pAdvance(25000), ps("view"), // b times out
			pAdvance(6000), // hand 5: dealer 0, turn b
			pCards("a", "5s", "6d", "8c"), pCards("b", "Qs", "Jd", "4c"),
			pAct("b", "sideshow"), pAct("b", "see"), pAct("b", "chaal"),
			pAct("a", "see"), pAct("a", "sideshow"), pActAmt("a", "raise", 800),
			pChat("b", "  gg  "), pChat("watcher", "hi"), pChat("b", "​"),
			pConnected("a", false), pRemove("a", "moved"), ps("view"),
			pAdvance(30000), ps("destroy"), // (a post after destroy is no_hand in Node, table_destroyed in Go — PORT_PLAN §9)
		},
	})

	blind := TableConfig{
		Category: CategoryBlind, BootAmount: 200, MaxPlayers: 5, MinPlayers: 2, TurnTimeout: 25 * time.Second,
		MaxBetRounds: 0, PotLimitMultiplier: 0, MaxRaiseSteps: 0, MaxPot: 4000, MaxBlindMoves: 4, MaxMissedTurns: 3,
		SideshowTimeout: 6 * time.Second, SideshowMinPlayers: 3, NextHandDelay: 6 * time.Second,
		ChatMaxHistory: 100, ChatMaxLength: 140,
	}
	runParity(t, parityScenario{
		Name:    "blind table: hidden chips, auto-reveal, pot cap, idle kick",
		Config:  blind,
		Viewers: []string{"a", "b", "watcher"},
		Steps: []parityStep{
			pSeat("a", 100000), pSeat("b", 100000), ps("view"),
			pAdvance(6000), // hand 1: dealer 0, turn b
			pCards("a", "Td", "Tc", "3h"), pCards("b", "9s", "8s", "7s"),
			pAct("b", "chaal"), pAct("a", "chaal"), pAct("b", "chaal"), pAct("a", "chaal"),
			pAct("b", "chaal"), pAct("a", "chaal"), ps("view"),
			pAct("b", "chaal"), ps("view"), // b's 4th blind bet: auto-reveal
			pAct("a", "chaal"), ps("view"), // a's too
			pActAmt("b", "raise", 1600), ps("view"), // pot 3600 + stake 800 > 4000 → pot_limit showdown
			pAdvance(6000), // hand 2: dealer 1, turn a
			pCards("a", "2d", "5c", "9h"), pCards("b", "As", "Ks", "Qs"),
			pAdvance(25000), // a misses 1 → b wins
			pAdvance(6000), pCards("a", "2d", "5c", "9h"), pCards("b", "As", "Ks", "Qs"),
			pAct("b", "chaal"), pAdvance(25000), // a misses 2
			pAdvance(6000), pCards("a", "2d", "5c", "9h"), pCards("b", "As", "Ks", "Qs"),
			pAdvance(25000), ps("view"), // a misses 3 → kick idle (announced only)
			pAdvance(6000), pCards("a", "2d", "5c", "9h"), pCards("b", "As", "Ks", "Qs"),
			pAct("b", "see"), pAct("b", "show"), pActAmt("b", "chaal", 200), ps("view"),
			pRemove("b", "disconnected"), ps("view"), ps("destroy"),
		},
	})
}

// mustSeat2 is what a departed player staked in the live hand (their seat is
// gone, so it is read off the contribution record).
func (h *harness) mustSeat2(userID string) int64 {
	var staked int64
	h.read(func() {
		if h.table.hand == nil {
			return
		}
		if entry := h.table.hand.contributions[userID]; entry != nil {
			staked = entry.contributed
		}
	})
	return staked
}
