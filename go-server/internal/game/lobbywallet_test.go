package game_test

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
)

// A wallet change and a seat being taken for the same player must not
// interleave (CLAUDE.md §5.1: a seated wallet moves only at a checkpoint).
//
// The race these tests pin: a player holding 2,50,000 buys a 2,00,000 COIN
// picture while their room:quickJoin is under way. The purchase looked, saw no
// seat, and committed; the join had already read the wallet, and reserved its
// seat afterwards with 2,50,000 against a wallet of 50,000. Losing the hand then
// clamped the wallet at zero and paid the winner chips that never existed. A
// Google Play chip pack had the mirror image: its credit committed, a join read
// the wallet with the pack in it and sat down, and the seat top-up that followed
// found the seat and added the pack a second time.
//
// The fix has two halves and every race here holds one of them still while the
// other runs: WhileUnseated and CreditBoughtChips keep the player's seat lock
// across the whole change, and every lobby seat reads the wallet under that
// same lock (RoomManagerOptions.LoadPlayer). The races run through every door
// into a seat from the lobby (lobbyDoors), because each door reads the wallet
// in its own method: a door that read it one line too early would bring the bug
// back on its own, and a race run only through quick join would not notice.
//
// A wallet can also be unfinished for a reason no lock can see: a hand-end
// settlement the database refused is still being retried after its players
// have left the table. Until it lands, neither a lobby change nor a lobby seat
// may use that wallet (RoomManager.settlementOwed); the tests at the end of the
// file hold the retry back to prove it.

// walletBook is the players' wallets as PostgreSQL would hold them, read by
// the manager through LoadPlayer.
type walletBook struct {
	mu     sync.Mutex
	chips  map[string]int64
	loads  map[string]int
	onLoad func(ctx context.Context, userID string) // runs inside the read, before it answers
	fail   error
}

func newWalletBook() *walletBook {
	return &walletBook{chips: map[string]int64{}, loads: map[string]int{}}
}

func (b *walletBook) load(ctx context.Context, userID string) (game.Player, error) {
	b.mu.Lock()
	b.loads[userID]++
	hook, fail := b.onLoad, b.fail
	b.mu.Unlock()
	if hook != nil {
		hook(ctx, userID)
	}
	if fail != nil {
		return game.Player{}, fail
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return game.Player{ID: userID, DisplayName: userID, Chips: b.chips[userID]}, nil
}

func (b *walletBook) set(userID string, chips int64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.chips[userID] = chips
}

func (b *walletBook) add(userID string, delta int64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.chips[userID] += delta
}

func (b *walletBook) get(userID string) int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.chips[userID]
}

func (b *walletBook) loadsOf(userID string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.loads[userID]
}

func (b *walletBook) failWith(err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.fail = err
}

// hook sets the function every read runs before it answers.
func (b *walletBook) hook(fn func(ctx context.Context, userID string)) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.onLoad = fn
}

// bookedRooms is a rooms fixture on the open menu whose lobby seats read their
// wallet from book.
func bookedRooms(t *testing.T, book *walletBook, mutate func(*config.GameConfig, *game.RoomManagerOptions)) *roomsFixture {
	t.Helper()
	return newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		o.LoadPlayer = book.load
		if mutate != nil {
			mutate(g, o)
		}
	})
}

// lobbyDoor is one way into a seat from the lobby, driven the way the socket
// layer drives it. open runs on the test goroutine before a race starts and
// returns the join itself — a table the door needs is made there, as it exists
// before the client that holds its code asks for it. frame is the RoomManager
// method in which that join waits for the player's seat lock.
type lobbyDoor struct {
	name  string
	frame string
	open  func(f *roomsFixture) func(p game.Player) (game.Room, error)
}

// lobbyDoors are every door into a seat from the lobby. room:joinCode is also
// the resume offer's auto-join (session:ready.resume → the client sends it).
// A switch or a consolidation move is not one: it carries the seat's own chips
// and reads no wallet (TestALobbyPurchaseCannotSlipIntoTheGapOfATableSwitch,
// TestAChipPackLandingWhileAConsolidationWaitsMovesWithThePlayer).
func lobbyDoors() []lobbyDoor {
	return []lobbyDoor{
		{
			name:  "room:quickJoin",
			frame: "(*RoomManager).QuickJoin(",
			open: func(f *roomsFixture) func(game.Player) (game.Room, error) {
				return func(p game.Player) (game.Room, error) { return f.rooms.QuickJoin(p, seenAt200) }
			},
		},
		{
			name:  "room:joinCode",
			frame: "(*RoomManager).JoinByCode(",
			open: func(f *roomsFixture) func(game.Player) (game.Room, error) {
				code := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"}).Code()
				return func(p game.Player) (game.Room, error) { return f.rooms.JoinByCode(p, code) }
			},
		},
		{
			// The socket layer's room:create; isPrivate defaults to true.
			name:  "room:create",
			frame: "(*RoomManager).CreateAndJoin(",
			open: func(f *roomsFixture) func(game.Player) (game.Room, error) {
				return func(p game.Player) (game.Room, error) {
					return f.rooms.CreateAndJoin(p, game.CreateTableOptions{BootAmount: 200, IsPrivate: true, Category: "seen"}, "sock-"+p.ID)
				}
			},
		},
		{
			// A public create, whose chip checks read the same wallet.
			name:  "room:create public",
			frame: "(*RoomManager).CreateAndJoin(",
			open: func(f *roomsFixture) func(game.Player) (game.Room, error) {
				return func(p game.Player) (game.Room, error) {
					return f.rooms.CreateAndJoin(p, game.CreateTableOptions{BootAmount: 200, Category: "seen"}, "sock-"+p.ID)
				}
			},
		},
		{
			// RoomManager.Join onto a table that already exists: no socket
			// event uses it any more, but it is still a door that reads a wallet.
			name:  "Join",
			frame: "(*RoomManager).Join(",
			open: func(f *roomsFixture) func(game.Player) (game.Room, error) {
				table := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})
				return func(p game.Player) (game.Room, error) { return table, f.rooms.Join(table, p, "sock-"+p.ID) }
			},
		},
	}
}

// waitParkedOnLock waits until some goroutine is blocked taking a sync.Mutex
// inside a function whose name contains frame — for these tests, a player's
// seat lock. It is how a test knows, with no seam in the production code, that
// the other side of a race has got as far as the lock and is waiting on it.
func waitParkedOnLock(t *testing.T, frame string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if parkedOnLock(frame) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("no goroutine is waiting for a lock in %s", frame)
		}
		time.Sleep(time.Millisecond)
	}
}

// waitParkedOrDone is waitParkedOnLock for a join that a broken lock would let
// straight through: true once it is waiting on a lock in frame, false once it
// has already finished (done holds its outcome, unread). The race then goes on
// to report what that did to the money rather than only that nothing waited.
func waitParkedOrDone(t *testing.T, frame string, done chan joinOutcome) bool {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if len(done) > 0 {
			return false
		}
		if parkedOnLock(frame) {
			return true
		}
		if time.Now().After(deadline) {
			t.Fatalf("the join neither waited for a lock in %s nor finished", frame)
		}
		time.Sleep(time.Millisecond)
	}
}

func parkedOnLock(frame string) bool {
	for _, g := range goroutineStacks() {
		if strings.Contains(g, "[sync.Mutex.Lock") && strings.Contains(g, frame) {
			return true
		}
	}
	return false
}

func goroutineStacks() []string {
	buf := make([]byte, 1<<16)
	for {
		n := runtime.Stack(buf, true)
		if n < len(buf) {
			return strings.Split(string(buf[:n]), "\n\n")
		}
		buf = make([]byte, 2*len(buf))
	}
}

// receiveWithin takes one value from ch, failing the test after 5 s: a broken
// lock should fail these races, never hang them.
func receiveWithin[T any](t *testing.T, ch <-chan T, what string) T {
	t.Helper()
	select {
	case v := <-ch:
		return v
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
	var zero T
	return zero
}

// releaseOnce closes ch at most once, and at the latest when the test ends, so
// a failure half-way through a race never leaves a goroutine holding a lock
// the fixture's shutdown then waits on. Register it after the fixture: cleanups
// run last-registered first.
func releaseOnce(t *testing.T, ch chan struct{}) func() {
	var once sync.Once
	release := func() { once.Do(func() { close(ch) }) }
	t.Cleanup(release)
	return release
}

var seenAt200 = game.QuickJoinOptions{BootAmount: 200, Category: "seen"}

// chipPack is what the chip-pack races buy: 1,00,000 chips.
const chipPack = 100_000

type joinOutcome struct {
	table game.Room
	err   error
}

func seatChips(t *testing.T, table game.Room, userID string) int64 {
	t.Helper()
	if table == nil {
		t.Fatalf("no table for %s", userID)
	}
	seat, err := table.FindSeat(userID)
	if err != nil || seat == nil {
		t.Fatalf("no seat for %s: %v", userID, err)
	}
	return seat.Chips
}

// The finding itself, through every door: the purchase is stopped after its
// seated check and before its commit, the join is sent in with the wallet as
// the socket layer read it before the purchase (2,50,000), and the seat must
// still start at 50,000.
func TestASeatNeverStartsFromAWalletReadBeforeALobbyPurchaseCommitted(t *testing.T) {
	for _, door := range lobbyDoors() {
		t.Run(door.name, func(t *testing.T) {
			book := newWalletBook()
			f := bookedRooms(t, book, nil)
			stale := f.player("Buyer", 250_000)
			book.set(stale.ID, 250_000)
			join := door.open(f)

			paused, gate := make(chan struct{}), make(chan struct{})
			release := releaseOnce(t, gate)
			bought := make(chan bool, 1)
			go func() {
				bought <- f.rooms.WhileUnseated(stale.ID, func(context.Context) {
					close(paused)
					<-gate
					book.add(stale.ID, -200_000) // the picture commits
				})
			}()
			receiveWithin(t, paused, "the purchase to pause before its commit")

			joined := make(chan joinOutcome, 1)
			go func() {
				table, err := join(stale)
				joined <- joinOutcome{table, err}
			}()
			waitParkedOnLock(t, door.frame)
			if n := book.loadsOf(stale.ID); n != 0 {
				t.Fatalf("the join read the wallet %d time(s) while a lobby purchase held the seat lock", n)
			}

			release()
			if !receiveWithin(t, bought, "the purchase") {
				t.Fatal("the purchase was refused, but nobody was seated when it began")
			}
			res := receiveWithin(t, joined, "the join")
			if res.err != nil {
				t.Fatalf("join: %v", res.err)
			}
			if got, wallet := seatChips(t, res.table, stale.ID), book.get(stale.ID); got != 50_000 || wallet != 50_000 {
				t.Fatalf("seat starts with %d chips against a wallet of %d; both must be 50,000", got, wallet)
			}
		})
	}
}

// The other order, through every door: the join holds the lock and is reading
// the wallet when the purchase arrives. The purchase waits, then finds the
// seat and is refused — the seat and the wallet both keep 2,50,000.
func TestALobbyPurchaseWaitsForAJoinInFlightAndIsThenRefused(t *testing.T) {
	for _, door := range lobbyDoors() {
		t.Run(door.name, func(t *testing.T) {
			book := newWalletBook()
			f := bookedRooms(t, book, nil)
			buyer := f.player("Buyer", 250_000)
			book.set(buyer.ID, 250_000)
			join := door.open(f)

			loading, gate := make(chan struct{}), make(chan struct{})
			release := releaseOnce(t, gate)
			var first sync.Once
			book.hook(func(_ context.Context, userID string) {
				if userID != buyer.ID {
					return
				}
				first.Do(func() {
					close(loading)
					<-gate
				})
			})

			joined := make(chan joinOutcome, 1)
			go func() {
				table, err := join(buyer)
				joined <- joinOutcome{table, err}
			}()
			receiveWithin(t, loading, "the join to read the wallet")

			ran := false
			bought := make(chan bool, 1)
			go func() {
				bought <- f.rooms.WhileUnseated(buyer.ID, func(context.Context) {
					ran = true
					book.add(buyer.ID, -200_000)
				})
			}()
			waitParkedOnLock(t, "(*RoomManager).WhileUnseated")

			release()
			res := receiveWithin(t, joined, "the join")
			if res.err != nil {
				t.Fatalf("join: %v", res.err)
			}
			if receiveWithin(t, bought, "the purchase") || ran {
				t.Fatal("a lobby purchase ran for a player whose seat was being taken")
			}
			if got, wallet := seatChips(t, res.table, buyer.ID), book.get(buyer.ID); got != 250_000 || wallet != 250_000 {
				t.Fatalf("seat %d, wallet %d; both must be 2,50,000", got, wallet)
			}
		})
	}
}

// A Google Play chip pack is two moments — the wallet credit, then the seat
// top-up — and a lobby seat is taken from the wallet as read under the seat
// lock. Paused between the two, through every door, a join must wait for the
// pack: had it read the wallet then, with the pack already in it, and sat down
// before the top-up looked for a seat, the top-up would have found that seat
// and added the pack a second time. It then reads 3,50,000, and the top-up,
// which finished first, finds no seat to add to.
func TestAChipPackCreditedBeforeAJoinIsNotPutOnTheSeatTwice(t *testing.T) {
	for _, door := range lobbyDoors() {
		t.Run(door.name, func(t *testing.T) {
			book := newWalletBook()
			f := bookedRooms(t, book, nil)
			buyer := f.player("Buyer", 250_000)
			book.set(buyer.ID, 250_000)
			join := door.open(f)

			paused, gate := make(chan struct{}), make(chan struct{})
			release := releaseOnce(t, gate)
			credited := make(chan bool, 1)
			go func() {
				credited <- f.rooms.CreditBoughtChips(buyer.ID, chipPack, func(context.Context) bool {
					book.add(buyer.ID, chipPack) // db.CreditPurchase commits
					close(paused)
					<-gate
					return true
				})
			}()
			receiveWithin(t, paused, "the chip pack to commit its credit")

			joined := make(chan joinOutcome, 1)
			go func() {
				table, err := join(buyer)
				joined <- joinOutcome{table, err}
			}()
			waited := waitParkedOrDone(t, door.frame, joined)
			readsWhilePaused := book.loadsOf(buyer.ID)

			release()
			toppedUp := receiveWithin(t, credited, "the chip pack")
			res := receiveWithin(t, joined, "the join")
			if res.err != nil {
				t.Fatalf("join: %v", res.err)
			}
			seat, wallet := seatChips(t, res.table, buyer.ID), book.get(buyer.ID)
			if seat != wallet {
				t.Fatalf("seat %d against a wallet of %d: the pack went on the seat twice (the join waited for the pack's seat lock: %v)", seat, wallet, waited)
			}
			if !waited || readsWhilePaused != 0 {
				t.Fatalf("the join read the wallet %d time(s) without waiting for a chip pack that held the seat lock", readsWhilePaused)
			}
			if toppedUp || seat != 350_000 {
				t.Fatalf("the top-up found a seat (%v) and the seat holds %d; want no seat, and 3,50,000 read from the wallet", toppedUp, seat)
			}
		})
	}
}

// The other order, through every door: the join holds the lock and is reading
// the wallet when the chip pack arrives. The pack must not credit the wallet
// under the join's read; it waits, then credits and tops up the seat the join
// has just taken, once.
func TestAChipPackWaitsForAJoinInFlightAndThenTopsUpItsSeat(t *testing.T) {
	for _, door := range lobbyDoors() {
		t.Run(door.name, func(t *testing.T) {
			book := newWalletBook()
			f := bookedRooms(t, book, nil)
			buyer := f.player("Buyer", 250_000)
			book.set(buyer.ID, 250_000)
			join := door.open(f)

			loading, gate := make(chan struct{}), make(chan struct{})
			release := releaseOnce(t, gate)
			var first sync.Once
			book.hook(func(_ context.Context, userID string) {
				if userID != buyer.ID {
					return
				}
				first.Do(func() {
					close(loading)
					<-gate
				})
			})

			joined := make(chan joinOutcome, 1)
			go func() {
				table, err := join(buyer)
				joined <- joinOutcome{table, err}
			}()
			receiveWithin(t, loading, "the join to read the wallet")

			banked := make(chan struct{})
			credited := make(chan bool, 1)
			go func() {
				credited <- f.rooms.CreditBoughtChips(buyer.ID, chipPack, func(context.Context) bool {
					close(banked)
					book.add(buyer.ID, chipPack)
					return true
				})
			}()
			waitParkedOnLock(t, "(*RoomManager).CreditBoughtChips")
			select {
			case <-banked:
				t.Fatal("the chip pack credited the wallet while a join held the seat lock to read it")
			default:
			}

			release()
			res := receiveWithin(t, joined, "the join")
			if res.err != nil {
				t.Fatalf("join: %v", res.err)
			}
			if !receiveWithin(t, credited, "the chip pack") {
				t.Fatal("the chip pack found no seat for a player who had just sat down")
			}
			if seat, wallet := seatChips(t, res.table, buyer.ID), book.get(buyer.ID); seat != 350_000 || wallet != 350_000 {
				t.Fatalf("seat %d, wallet %d; both must be 3,50,000", seat, wallet)
			}
		})
	}
}

// A seated player's chip pack reaches the seat once — it is how a short stack
// buys its way back over the boot, and Table.CreditChips, which it ends in,
// also lifts the unfunded grace (unfunded_grace_test.go) — while a receipt
// already banked reaches neither the wallet nor the seat, and a pack bought in
// the lobby has no seat to top up.
func TestASeatedChipPackTopsUpTheSeatOnceAndAReplayedOneNotAtAll(t *testing.T) {
	book := newWalletBook()
	f := bookedRooms(t, book, nil)
	p := f.player("Topper", 250_000)
	book.set(p.ID, 250_000)
	table := f.mustQuickJoin(p, 200, "seen")

	if !f.rooms.CreditBoughtChips(p.ID, chipPack, func(context.Context) bool {
		book.add(p.ID, chipPack)
		return true
	}) {
		t.Fatal("a seated player's chip pack found no seat")
	}
	if seat, wallet := seatChips(t, table, p.ID), book.get(p.ID); seat != 350_000 || wallet != 350_000 {
		t.Fatalf("after a seated pack: seat %d, wallet %d; both must be 3,50,000", seat, wallet)
	}
	if f.rooms.CreditBoughtChips(p.ID, chipPack, func(context.Context) bool { return false }) {
		t.Fatal("a replayed receipt topped up the seat")
	}
	if seat := seatChips(t, table, p.ID); seat != 350_000 {
		t.Fatalf("after a replayed receipt: seat %d, want 3,50,000", seat)
	}

	f.mustLeave(p.ID, game.LeaveReasonLeft)
	banked := false
	if f.rooms.CreditBoughtChips(p.ID, chipPack, func(context.Context) bool {
		banked = true
		book.add(p.ID, chipPack)
		return true
	}) || !banked {
		t.Fatalf("a lobby pack: banked %v, and it must report no seat", banked)
	}
}

// Run with -race: for each fresh player a join and a chip pack start at the
// same moment, through every door in turn. Whichever wins, the seat holds the
// pack exactly once.
func TestConcurrentJoinsAndChipPacksNeverPutAPackOnTheSeatTwice(t *testing.T) {
	const roundsPerDoor = 24
	book := newWalletBook()
	f := bookedRooms(t, book, nil)
	for _, door := range lobbyDoors() {
		for round := 0; round < roundsPerDoor; round++ {
			where := fmt.Sprintf("%s round %d", door.name, round)
			p := f.player("Packer", 250_000)
			book.set(p.ID, 250_000)
			join := door.open(f)

			var wg sync.WaitGroup
			var res joinOutcome
			wg.Add(2)
			go func() {
				defer wg.Done()
				res.table, res.err = join(p)
			}()
			go func() {
				defer wg.Done()
				f.rooms.CreditBoughtChips(p.ID, chipPack, func(context.Context) bool {
					book.add(p.ID, chipPack)
					return true
				})
			}()
			wg.Wait()

			if res.err != nil {
				t.Fatalf("%s: join: %v", where, res.err)
			}
			if seat, wallet := seatChips(t, res.table, p.ID), book.get(p.ID); seat != wallet || wallet != 350_000 {
				t.Fatalf("%s: seat %d, wallet %d, want both 3,50,000", where, seat, wallet)
			}
			f.mustLeave(p.ID, game.LeaveReasonLeft)
		}
	}
}

// A consolidation move reads the lone player's seat before it takes their
// stripe. A chip pack's top-up holds that stripe, so it can land in between;
// the move must carry what the seat held when it was given up, not the figure
// read a moment before.
func TestAChipPackLandingWhileAConsolidationWaitsMovesWithThePlayer(t *testing.T) {
	book := newWalletBook()
	f := bookedRooms(t, book, nil)
	host, mover := f.player("Host", 250_000), f.player("Mover", 250_000)
	book.set(host.ID, 250_000)
	book.set(mover.ID, 250_000)
	older := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})
	f.mustJoin(older, host)
	newer := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})
	f.mustJoin(newer, mover)

	paused, gate := make(chan struct{}), make(chan struct{})
	release := releaseOnce(t, gate)
	credited := make(chan bool, 1)
	go func() {
		credited <- f.rooms.CreditBoughtChips(mover.ID, chipPack, func(context.Context) bool {
			book.add(mover.ID, chipPack)
			close(paused)
			<-gate
			return true
		})
	}()
	receiveWithin(t, paused, "the chip pack to commit its credit")

	type consolidation struct {
		moves []game.PlayerMove
		err   error
	}
	consolidated := make(chan consolidation, 1)
	go func() {
		moves, err := f.rooms.ConsolidateTables()
		consolidated <- consolidation{moves, err}
	}()
	waitParkedOnLock(t, "(*RoomManager).movePlayer(")

	release()
	if !receiveWithin(t, credited, "the chip pack") {
		t.Fatal("the chip pack found no seat for a player still seated when it began")
	}
	res := receiveWithin(t, consolidated, "the consolidation")
	if res.err != nil || len(res.moves) != 1 || res.moves[0].UserID != mover.ID || res.moves[0].ToRoomID != older.ID() {
		t.Fatalf("consolidation: %v %v, want the mover taken to the older table", res.moves, res.err)
	}
	if seat, wallet := seatChips(t, older, mover.ID), book.get(mover.ID); seat != 350_000 || wallet != 350_000 {
		t.Fatalf("the mover sat down with %d against a wallet of %d; both must be 3,50,000", seat, wallet)
	}
}

// A switch takes the player off the index before it leaves the old table and
// puts them back only when it sits at the new one. In that gap a bare "is
// seated?" look says lobby — and a purchase that believed it would be written
// behind a seat about to be recreated with the chips it had. The stripe is
// held across the gap, so the purchase waits, then finds the new seat.
func TestALobbyPurchaseCannotSlipIntoTheGapOfATableSwitch(t *testing.T) {
	book := newWalletBook()
	pause := &pausingListener{paused: make(chan struct{}), gate: make(chan struct{})}
	f := bookedRooms(t, book, func(_ *config.GameConfig, o *game.RoomManagerOptions) {
		pause.Listener = o.TableListener
		o.TableListener = pause
	})
	release := releaseOnce(t, pause.gate)
	mover, stayer, host := f.player("Mover", 250_000), f.player("Stayer", 250_000), f.player("Host", 250_000)
	for _, p := range []game.Player{mover, stayer, host} {
		book.set(p.ID, 250_000)
	}
	source := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})
	f.mustJoin(source, mover)
	f.mustJoin(source, stayer)
	target := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})
	f.mustJoin(target, host)

	pause.arm(source.ID())
	switched := make(chan error, 1)
	go func() {
		_, err := f.rooms.SwitchTable(mover)
		switched <- err
	}()
	receiveWithin(t, pause.paused, "the switch to leave the old table")
	if f.rooms.GetTableForPlayer(mover.ID) != nil {
		t.Fatal("the switch was paused outside its gap: the index still seats the mover")
	}

	ran := false
	bought := make(chan bool, 1)
	go func() {
		bought <- f.rooms.WhileUnseated(mover.ID, func(context.Context) {
			ran = true
			book.add(mover.ID, -200_000)
		})
	}()
	waitParkedOnLock(t, "(*RoomManager).WhileUnseated")

	release()
	if err := receiveWithin(t, switched, "the switch"); err != nil {
		t.Fatalf("switch: %v", err)
	}
	if receiveWithin(t, bought, "the purchase") || ran {
		t.Fatal("a lobby purchase ran in the middle of a table switch")
	}
	if f.rooms.GetTableForPlayer(mover.ID) != target {
		t.Fatal("the mover did not land on the other table")
	}
	if got, wallet := seatChips(t, target, mover.ID), book.get(mover.ID); got != 250_000 || wallet != 250_000 {
		t.Fatalf("seat %d, wallet %d; both must be 2,50,000", got, wallet)
	}
}

// pausingListener stops one table's actor inside OnSeatUpdated, once, so a
// test can freeze a seat transition half-way through.
type pausingListener struct {
	game.Listener

	mu      sync.Mutex
	room    string
	paused  chan struct{}
	gate    chan struct{}
	tripped bool
}

func (l *pausingListener) arm(roomID string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.room = roomID
}

func (l *pausingListener) OnSeatUpdated(v *game.View, seatIndex int) {
	l.mu.Lock()
	hit := !l.tripped && l.room != "" && v.ID() == l.room
	if hit {
		l.tripped = true
	}
	l.mu.Unlock()
	if hit {
		close(l.paused)
		<-l.gate
	}
	l.Listener.OnSeatUpdated(v, seatIndex)
}

func TestWhileUnseatedRunsALobbyChangeOnlyForAPlayerWithNoSeat(t *testing.T) {
	f := newRoomsFixture(t, openMenu)
	p := f.player("Lobby", rmStart)
	ran := 0
	if !f.rooms.WhileUnseated(p.ID, func(context.Context) { ran++ }) || ran != 1 {
		t.Fatalf("in the lobby: ran %d time(s)", ran)
	}
	f.mustQuickJoin(p, 200, "seen")
	if f.rooms.WhileUnseated(p.ID, func(context.Context) { ran++ }) || ran != 1 {
		t.Fatalf("seated: ran %d time(s), want the change refused", ran)
	}
	f.mustLeave(p.ID, game.LeaveReasonLeft)
	if !f.rooms.WhileUnseated(p.ID, func(context.Context) { ran++ }) || ran != 2 {
		t.Fatalf("back in the lobby: ran %d time(s)", ran)
	}
}

// A suspend (every production restart) takes the seats off the index without
// the players' stripes and hands them, stake and all, to the next process,
// while REST is still served. A chip-priced picture bought now would debit a
// wallet the restored seat never hears of — the same clamp at zero as the
// original race — so to WhileUnseated the player is still seated.
func TestALobbyChangeIsRefusedForASeatASuspendHandsOn(t *testing.T) {
	f := newRoomsFixture(t, withStore(livetest.New(), "one"))
	a, b := f.player("A", 100_000), f.player("B", 100_000)
	table := f.mustQuickJoin(a, 200, "seen")
	f.mustQuickJoin(b, 200, "seen")
	f.clock.Advance(6 * time.Second)
	if !table.HasHand() {
		t.Fatal("no hand dealt")
	}
	if err := f.rooms.Suspend(context.Background()); err != nil {
		t.Fatal(err)
	}
	if f.rooms.GetTableForPlayer(a.ID) != nil {
		t.Fatal("the index still seats a player after the suspend")
	}
	ran := false
	if f.rooms.WhileUnseated(a.ID, func(context.Context) { ran = true }) || ran {
		t.Fatal("a lobby change ran for a player whose seat and stake a suspend had just handed on")
	}
	lobby := f.player("Lobby", 100_000)
	if !f.rooms.WhileUnseated(lobby.ID, func(context.Context) {}) {
		t.Fatal("a player who was never seated was refused after the suspend")
	}
}

// Destroying a table takes its seats off the index first and settles the live
// hand after, on the actor. Until that settlement has landed the wallet does
// not hold the hand's result, so a lobby change and a lobby seat both wait it
// out: paused inside the settlement they are refused, and once the destroy is
// done they go through.
func TestALobbyChangeOrSeatIsRefusedUntilADestroyedTablesSettlementHasLanded(t *testing.T) {
	settling, gate := make(chan struct{}), make(chan struct{})
	var once sync.Once
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		o.Ledger = game.NewMemoryLedger(game.MemoryLedgerHooks{
			Settle: func(game.SettleRequest, []game.SettleEntry) (map[string]int64, error) {
				once.Do(func() {
					close(settling)
					<-gate
				})
				return map[string]int64{}, nil
			},
		})
	})
	release := releaseOnce(t, gate)
	table := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	a, _ := seatTwoAndDeal(t, f, table, rmStart)

	destroyed := make(chan error, 1)
	go func() { destroyed <- f.rooms.DestroyTable(table.ID()) }()
	receiveWithin(t, settling, "the destroy to settle the live hand")
	if f.rooms.GetTableForPlayer(a.ID) != nil {
		t.Fatal("the destroy paused before it took the seats off the index")
	}
	ran := false
	if f.rooms.WhileUnseated(a.ID, func(context.Context) { ran = true }) || ran {
		t.Fatal("a lobby change ran while the destroyed table's settlement was still being written")
	}
	blind := game.QuickJoinOptions{BootAmount: rmBoot, Category: "blind"}
	if _, err := f.rooms.QuickJoin(a, blind); game.CodeOf(err, "") != game.CodeSettlementPending {
		t.Fatalf("a lobby seat while the destroyed table's settlement was still being written: %v, want settlement_pending", err)
	}

	release()
	if err := receiveWithin(t, destroyed, "the destroy"); err != nil {
		t.Fatalf("destroy: %v", err)
	}
	if !f.rooms.WhileUnseated(a.ID, func(context.Context) { ran = true }) || !ran {
		t.Fatal("the player was still refused once the settlement had landed")
	}
	if _, err := f.rooms.QuickJoin(a, blind); err != nil {
		t.Fatalf("a lobby seat once the settlement had landed: %v", err)
	}
}

// A settlement the database refused at destroy time goes on being retried off
// the actor. The players whose wallets it moves stay owed until it lands, and
// no longer: the mark ends inside the retry's own callback, so it is gone by
// the time the clock that fired it returns.
func TestALobbyChangeWaitsOutASettlementADestroyLeftRetrying(t *testing.T) {
	var mu sync.Mutex
	failures := 1
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		o.Ledger = game.NewMemoryLedger(game.MemoryLedgerHooks{
			Settle: func(game.SettleRequest, []game.SettleEntry) (map[string]int64, error) {
				mu.Lock()
				defer mu.Unlock()
				if failures > 0 {
					failures--
					return nil, errors.New("database unavailable")
				}
				return map[string]int64{}, nil
			},
		})
	})
	table := f.createTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	a, _ := seatTwoAndDeal(t, f, table, rmStart)

	if err := f.rooms.DestroyTable(table.ID()); err != nil {
		t.Fatalf("destroy: %v", err)
	}
	if table.PendingSettlements() == 0 {
		t.Fatal("the refused settlement was not left retrying")
	}
	if f.rooms.WhileUnseated(a.ID, func(context.Context) {}) {
		t.Fatal("a lobby change ran while a destroyed table's settlement was still being retried")
	}

	f.clock.Advance(f.cfg.NextHandDelay) // the first retry is due, and lands
	if !f.rooms.WhileUnseated(a.ID, func(context.Context) {}) {
		t.Fatalf("the player was still refused after the retried settlement landed (pending %d)", table.PendingSettlements())
	}
}

// room:create's chip checks read the wallet under the seat lock — the wallet
// the seat then starts from — never the copy the socket layer read before it:
// with that copy a stale read could seat a creator below the boot, over the
// entry cap (requirement 30) or outside the table's band. Same codes and
// messages as a quick join; a refused create opens no table.
func TestAPublicCreateChecksTheWalletReadUnderTheSeatLock(t *testing.T) {
	book := newWalletBook()
	f := newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		g.TableStakes = []int64{200, 5000}
		g.LobbyTables = []config.LobbyTable{
			{Category: "seen", BootAmount: 200},
			{Category: "blind", BootAmount: 200},
			{Category: "blind", BootAmount: 5000, MinChips: 1_000_000},
		}
		g.EntryCapBoot, g.EntryCapCategory, g.EntryCapMaxChips = 200, "blind", 500_000
		o.LoadPlayer = book.load
	})
	blind200 := game.CreateTableOptions{BootAmount: 200, Category: "blind"}
	blind5000 := game.CreateTableOptions{BootAmount: 5000, Category: "blind"}

	for _, tc := range []struct {
		name          string
		stale, wallet int64
		opts          game.CreateTableOptions
		code, message string
	}{
		{"a wallet below the boot", 250_000, 100, blind200, game.CodeInsufficientChips, "Not enough chips to join this table"},
		{"a wallet over the entry cap", 490_000, 510_000, blind200, game.CodeOverEntryCap, "Players with more than 500,000 chips cannot join this table"},
		{"a wallet under the table's band", 2_000_000, 900_000, blind5000, game.CodeBelowTableMinimum, "This table is for players with 1,000,000 chips or more"},
	} {
		p := f.player("Creator", tc.stale)
		book.set(p.ID, tc.wallet)
		_, err := f.rooms.CreateAndJoin(p, tc.opts, "sock-"+p.ID)
		var gerr *game.GameError
		if !errors.As(err, &gerr) || gerr.Code != tc.code || gerr.Message != tc.message {
			t.Errorf("%s (read %d, wallet %d): %v, want %s %q", tc.name, tc.stale, tc.wallet, err, tc.code, tc.message)
		}
		if f.rooms.GetTableForPlayer(p.ID) != nil || f.rooms.Stats().Tables != 0 {
			t.Fatalf("%s: a refused create left a seat or a table (%+v)", tc.name, f.rooms.Stats())
		}
	}

	// The other way round: a stale read over the cap does not refuse a wallet
	// under it, and the seat starts from the wallet.
	under := f.player("Under", 600_000)
	book.set(under.ID, 400_000)
	table, err := f.rooms.CreateAndJoin(under, blind200, "sock-under")
	if err != nil {
		t.Fatalf("a wallet under the cap: %v", err)
	}
	if got := seatChips(t, table, under.ID); got != 400_000 || table.IsPrivate() || table.BootAmount() != 200 {
		t.Fatalf("public create seated %d at a %d table (private %v); want 4,00,000 at a public 200", got, table.BootAmount(), table.IsPrivate())
	}
	f.mustLeave(under.ID, game.LeaveReasonLeft)

	// A private table checks no chips; its seat still starts from the wallet.
	host := f.player("Host", 250_000)
	book.set(host.ID, 100)
	private, err := f.rooms.CreateAndJoin(host, game.CreateTableOptions{BootAmount: 5000, IsPrivate: true, Category: "blind"}, "sock-host")
	if err != nil {
		t.Fatalf("private create: %v", err)
	}
	if got := seatChips(t, private, host.ID); got != 100 || !private.IsPrivate() {
		t.Fatalf("private create seated %d (private %v); want the wallet's 100", got, private.IsPrivate())
	}
	f.mustLeave(host.ID, game.LeaveReasonLeft)

	// A wallet that cannot be read opens nothing.
	unavailable := errors.New("database unavailable")
	book.failWith(unavailable)
	ghost := f.player("Ghost", 250_000)
	if _, err := f.rooms.CreateAndJoin(ghost, blind200, "sock-ghost"); !errors.Is(err, unavailable) {
		t.Errorf("create with no wallet: %v", err)
	}
	if f.rooms.Stats().Tables != 0 {
		t.Fatalf("a create whose wallet could not be read left a table: %+v", f.rooms.Stats())
	}
	book.failWith(nil)

	// And the ordered race: a timed bonus paused inside its transaction under
	// the seat lock, a public create at the capped table sent in with the read
	// taken before it (4,90,000). The create waits, and its cap is checked on
	// the 5,15,000 the bonus left.
	racer := f.player("Racer", 490_000)
	book.set(racer.ID, 490_000)
	paused, gate := make(chan struct{}), make(chan struct{})
	release := releaseOnce(t, gate)
	claimed := make(chan bool, 1)
	go func() {
		claimed <- f.rooms.WhileUnseated(racer.ID, func(context.Context) {
			close(paused)
			<-gate
			book.add(racer.ID, 25_000)
		})
	}()
	receiveWithin(t, paused, "the bonus to pause before its commit")
	created := make(chan joinOutcome, 1)
	go func() {
		table, err := f.rooms.CreateAndJoin(racer, blind200, "sock-racer")
		created <- joinOutcome{table, err}
	}()
	waitParkedOnLock(t, "(*RoomManager).CreateAndJoin(")

	release()
	if !receiveWithin(t, claimed, "the bonus") {
		t.Fatal("the bonus was refused, but nobody was seated when it began")
	}
	res := receiveWithin(t, created, "the create")
	if game.CodeOf(res.err, "") != game.CodeOverEntryCap {
		t.Fatalf("a create checked after a bonus took the wallet to 5,15,000: %v, want over_entry_cap", res.err)
	}
	if f.rooms.Stats().Tables != 0 {
		t.Fatalf("a refused create left a table: %+v", f.rooms.Stats())
	}
}

// Every door into a seat from the lobby — quick join, a code, a create, a
// direct join — seats the wallet LoadPlayer reads, not the copy the caller
// brought, and the chip checks read that wallet too. That the read happens
// under the seat lock is what the ordered races above prove, door by door.
func TestEveryLobbySeatStartsFromTheWalletLoadPlayerReads(t *testing.T) {
	book := newWalletBook()
	f := bookedRooms(t, book, nil)

	quick := f.player("Quick", 250_000)
	book.set(quick.ID, 60_000)
	table := f.mustQuickJoin(quick, 200, "seen")
	if got := seatChips(t, table, quick.ID); got != 60_000 {
		t.Errorf("quick join seated %d, the wallet holds 60,000", got)
	}

	coded := f.player("Coded", 250_000)
	book.set(coded.ID, 70_000)
	if _, err := f.rooms.JoinByCode(coded, table.Code()); err != nil {
		t.Fatalf("join by code: %v", err)
	}
	if got := seatChips(t, table, coded.ID); got != 70_000 {
		t.Errorf("join by code seated %d, the wallet holds 70,000", got)
	}

	direct := f.player("Direct", 250_000)
	book.set(direct.ID, 80_000)
	f.mustJoin(table, direct)
	if got := seatChips(t, table, direct.ID); got != 80_000 {
		t.Errorf("join seated %d, the wallet holds 80,000", got)
	}

	creator := f.player("Creator", 250_000)
	book.set(creator.ID, 90_000)
	created, err := f.rooms.CreateAndJoin(creator, game.CreateTableOptions{BootAmount: 200, IsPrivate: true, Category: "seen"}, "sock-creator")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if got := seatChips(t, created, creator.ID); got != 90_000 {
		t.Errorf("create seated %d, the wallet holds 90,000", got)
	}
	f.mustLeave(creator.ID, game.LeaveReasonLeft)

	// A stale 2,50,000 does not pass a boot check the wallet cannot cover.
	poor := f.player("Poor", 250_000)
	book.set(poor.ID, 100)
	if _, err := f.rooms.QuickJoin(poor, seenAt200); game.CodeOf(err, "") != game.CodeInsufficientChips {
		t.Errorf("quick join on a wallet of 100: %v, want insufficient_chips", err)
	}
	if _, err := f.rooms.JoinByCode(poor, table.Code()); game.CodeOf(err, "") != game.CodeInsufficientChips {
		t.Errorf("join by code on a wallet of 100: %v, want insufficient_chips", err)
	}
	if _, err := f.rooms.CreateAndJoin(poor, game.CreateTableOptions{BootAmount: 200, Category: "seen"}, ""); game.CodeOf(err, "") != game.CodeInsufficientChips {
		t.Errorf("public create on a wallet of 100: %v, want insufficient_chips", err)
	}

	// A wallet that cannot be read seats nobody and reserves nothing.
	unavailable := errors.New("database unavailable")
	book.failWith(unavailable)
	ghost := f.player("Ghost", 250_000)
	if _, err := f.rooms.QuickJoin(ghost, seenAt200); !errors.Is(err, unavailable) {
		t.Errorf("quick join with no wallet: %v", err)
	}
	if _, err := f.rooms.JoinByCode(ghost, table.Code()); !errors.Is(err, unavailable) {
		t.Errorf("join by code with no wallet: %v", err)
	}
	if err := f.rooms.Join(table, ghost, ""); !errors.Is(err, unavailable) {
		t.Errorf("join with no wallet: %v", err)
	}
	if _, err := f.rooms.CreateAndJoin(ghost, game.CreateTableOptions{BootAmount: 200, IsPrivate: true, Category: "seen"}, ""); !errors.Is(err, unavailable) {
		t.Errorf("create with no wallet: %v", err)
	}
	if f.rooms.GetTableForPlayer(ghost.ID) != nil {
		t.Error("a join whose wallet could not be read left the player indexed at a table")
	}
	if stats := f.rooms.Stats(); stats.Tables != 1 || stats.Players != 3 {
		t.Errorf("rooms = %+v, want the one table with its three players", stats)
	}
}

// The database work done holding a stripe runs on a context of the manager's:
// bounded, so a stalled pool cannot keep a stripe other players share for
// ever, and nobody's request, so a client hanging up cannot end it early.
func TestWalletWorkUnderTheSeatLockGetsABoundedContextOfItsOwn(t *testing.T) {
	book := newWalletBook()
	f := bookedRooms(t, book, nil)
	p := f.player("Bounded", 250_000)
	book.set(p.ID, 250_000)

	checked := 0
	check := func(what string, ctx context.Context) {
		checked++
		deadline, bounded := ctx.Deadline()
		if !bounded {
			t.Errorf("%s: its context has no deadline", what)
			return
		}
		if left := time.Until(deadline); left <= 0 || left > time.Minute {
			t.Errorf("%s: its deadline is %v away", what, left)
		}
		if err := ctx.Err(); err != nil {
			t.Errorf("%s: its context had already ended: %v", what, err)
		}
	}
	book.hook(func(ctx context.Context, userID string) {
		if userID == p.ID {
			check("LoadPlayer", ctx)
		}
	})
	f.mustQuickJoin(p, 200, "seen")
	f.mustLeave(p.ID, game.LeaveReasonLeft)
	f.rooms.WhileUnseated(p.ID, func(ctx context.Context) { check("WhileUnseated", ctx) })
	f.rooms.CreditBoughtChips(p.ID, chipPack, func(ctx context.Context) bool {
		check("CreditBoughtChips", ctx)
		return false
	})
	if checked != 3 {
		t.Fatalf("checked %d contexts, want 3", checked)
	}
}

// Run with -race: for each fresh player a join and a lobby purchase start at
// the same moment, through every door in turn. Whichever wins, the seat and
// the wallet agree — 50,000 when the purchase went first, 2,50,000 (purchase
// refused) when the join did.
func TestConcurrentJoinsAndLobbyPurchasesNeverSeatChipsTheWalletLacks(t *testing.T) {
	const roundsPerDoor = 24
	book := newWalletBook()
	f := bookedRooms(t, book, nil)
	for _, door := range lobbyDoors() {
		for round := 0; round < roundsPerDoor; round++ {
			where := fmt.Sprintf("%s round %d", door.name, round)
			p := f.player("Racer", 250_000)
			book.set(p.ID, 250_000)
			join := door.open(f)

			var wg sync.WaitGroup
			var res joinOutcome
			var bought bool
			wg.Add(2)
			go func() {
				defer wg.Done()
				res.table, res.err = join(p)
			}()
			go func() {
				defer wg.Done()
				bought = f.rooms.WhileUnseated(p.ID, func(context.Context) { book.add(p.ID, -200_000) })
			}()
			wg.Wait()

			if res.err != nil {
				t.Fatalf("%s: join: %v", where, res.err)
			}
			want := int64(250_000)
			if bought {
				want = 50_000
			}
			if got, wallet := seatChips(t, res.table, p.ID), book.get(p.ID); got != wallet || wallet != want {
				t.Fatalf("%s (bought=%v): seat %d, wallet %d, want both %d", where, bought, got, wallet, want)
			}
			f.mustLeave(p.ID, game.LeaveReasonLeft)
		}
	}
}

// clampingLedger keeps a walletBook the way db.applyCheckpoint writes wallets
// — deltas, clamped at zero — and counts every chip a clamp has absorbed: a
// chip some winner was paid that no wallet gave up. While down it refuses the
// hand-end rows, so a settlement is left retrying.
type clampingLedger struct {
	book *walletBook

	mu      sync.Mutex
	down    bool
	clamped int64
}

func newClampingLedger(book *walletBook) *clampingLedger {
	return &clampingLedger{book: book}
}

// install is a bookedRooms mutate: every table of the manager writes through
// the ledger.
func (l *clampingLedger) install(_ *config.GameConfig, o *game.RoomManagerOptions) {
	o.Ledger = game.NewMemoryLedger(game.MemoryLedgerHooks{Checkpoint: l.checkpoint})
}

func (l *clampingLedger) checkpoint(args game.CheckpointArgs) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	e := args.Entry
	if l.down && (e.Reason == game.LedgerReasonHandWin || e.Reason == game.LedgerReasonHandLoss) {
		return errors.New("database unavailable")
	}
	balance := l.book.get(e.UserID) + e.Delta
	if balance < 0 {
		l.clamped -= balance
		balance = 0
	}
	l.book.set(e.UserID, balance)
	return nil
}

func (l *clampingLedger) setDown(down bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.down = down
}

func (l *clampingLedger) clampedChips() int64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.clamped
}

// refusedSettlement plays one seen hand at boot 200 between two players holding
// 10,000 each — a chaal, then a show — while the ledger refuses the hand-end
// rows. The seats end the hand holding its result; the wallets do not, and the
// settlement is left retrying.
func refusedSettlement(t *testing.T, f *roomsFixture, ledger *clampingLedger) (table *game.Table, winner, loser game.Player) {
	t.Helper()
	table = f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})
	a, b := f.player("A", 10_000), f.player("B", 10_000)
	for _, p := range []game.Player{a, b} {
		ledger.book.set(p.ID, 10_000)
		f.mustJoin(table, p)
	}
	if err := table.StartHand(); err != nil || !table.HasHand() {
		t.Fatalf("deal: %v", err)
	}
	ledger.setDown(true)
	if _, err := table.Act(turnUser(t, table), game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatalf("chaal: %v", err)
	}
	if _, err := table.Act(turnUser(t, table), game.ActionShow, game.ActRequest{}); err != nil {
		t.Fatalf("show: %v", err)
	}
	if table.HasHand() {
		t.Fatal("the show did not end the hand")
	}
	winner, loser = a, b
	if seatChips(t, table, b.ID) > seatChips(t, table, a.ID) {
		winner, loser = b, a
	}
	for _, p := range []game.Player{a, b} {
		if wallet := ledger.book.get(p.ID); wallet != 10_000 {
			t.Fatalf("the settlement was not refused: %s's wallet is already %d", p.ID, wallet)
		}
	}
	return table, winner, loser
}

// A player can leave a table between hands while the settlement of the hand
// they just lost is still being retried, and a leave between hands writes
// nothing: the wallet goes on holding the stake the seat has already lost. A
// lobby purchase paid from that wallet used to run, and the retry's negative
// delta, landing after it, clamped the wallet at zero and paid the winner chips
// that never existed. The purchase must wait for the retry, whether the table
// plays on or is destroyed behind its players with the write still retrying —
// and so must a winner whose pot is still on its way.
func TestALobbyChangeWaitsForTheSettlementOfATableThePlayerLeft(t *testing.T) {
	for _, destroyed := range []bool{false, true} {
		name := "the table plays on"
		if destroyed {
			name = "the table is destroyed behind them"
		}
		t.Run(name, func(t *testing.T) {
			book := newWalletBook()
			ledger := newClampingLedger(book)
			f := bookedRooms(t, book, ledger.install)
			table, winner, loser := refusedSettlement(t, f, ledger)
			final := map[string]int64{
				winner.ID: seatChips(t, table, winner.ID),
				loser.ID:  seatChips(t, table, loser.ID),
			}

			f.mustLeave(loser.ID, game.LeaveReasonLeft)
			if destroyed {
				f.mustLeave(winner.ID, game.LeaveReasonLeft)
				if f.rooms.GetTable(table.ID()) != nil || table.PendingSettlements() == 0 {
					t.Fatalf("the emptied table was not destroyed with its settlement still retrying (pending %d)", table.PendingSettlements())
				}
			}

			// A picture the wallet as it stands can pay for, and the stack the
			// loser really has cannot.
			price := final[loser.ID] + 200
			buy := func(context.Context) {
				if book.get(loser.ID) >= price {
					book.add(loser.ID, -price)
				}
			}
			if f.rooms.WhileUnseated(loser.ID, buy) {
				t.Fatalf("a lobby purchase ran against a wallet still waiting for the hand's loss (wallet now %d, the seat ended with %d)", book.get(loser.ID), final[loser.ID])
			}
			if destroyed && f.rooms.WhileUnseated(winner.ID, func(context.Context) {}) {
				t.Fatal("a lobby change ran for a winner whose pot was still being written")
			}

			ledger.setDown(false)
			f.clock.Advance(f.cfg.NextHandDelay) // the retry is due, and lands
			for id, chips := range final {
				if wallet := book.get(id); wallet != chips {
					t.Fatalf("after the retry %s's wallet is %d; the seat ended the hand with %d", id, wallet, chips)
				}
			}
			if !f.rooms.WhileUnseated(loser.ID, buy) {
				t.Fatal("the loser was still refused once the settlement had landed")
			}
			if destroyed && !f.rooms.WhileUnseated(winner.ID, func(context.Context) {}) {
				t.Fatal("the winner was still refused once the settlement had landed")
			}
			if wallet := book.get(loser.ID); wallet != final[loser.ID] {
				t.Fatalf("the purchase took %d from a wallet the loss had left below its price", final[loser.ID]-wallet)
			}
			if clamped := ledger.clampedChips(); clamped != 0 {
				t.Fatalf("a clamp at zero absorbed %d chips: chips were created", clamped)
			}
		})
	}
}

// The same wait at every door into a seat from the lobby: a seat started from
// a wallet the retry has yet to debit would hold chips the wallet is about to
// lose. The join is refused settlement_pending before the wallet is read or a
// table is opened, and once the retry has landed the same join seats what the
// hand left.
func TestALobbySeatWaitsForTheSettlementOfATableThePlayerLeft(t *testing.T) {
	for _, door := range lobbyDoors() {
		t.Run(door.name, func(t *testing.T) {
			book := newWalletBook()
			ledger := newClampingLedger(book)
			f := bookedRooms(t, book, ledger.install)
			table, _, loser := refusedSettlement(t, f, ledger)
			final := seatChips(t, table, loser.ID)
			join := door.open(f)
			f.mustLeave(loser.ID, game.LeaveReasonLeft)
			tables, reads := f.rooms.Stats().Tables, book.loadsOf(loser.ID)

			_, err := join(loser)
			var gerr *game.GameError
			if !errors.As(err, &gerr) || gerr.Code != game.CodeSettlementPending || gerr.Message != "Your last hand is still being saved; try again in a moment" {
				t.Fatalf("a join while the settlement was still retrying: %v, want settlement_pending", err)
			}
			if f.rooms.GetTableForPlayer(loser.ID) != nil || f.rooms.Stats().Tables != tables || book.loadsOf(loser.ID) != reads {
				t.Fatalf("a refused join left a trace: seated %v, tables %d → %d, wallet reads %d → %d",
					f.rooms.GetTableForPlayer(loser.ID) != nil, tables, f.rooms.Stats().Tables, reads, book.loadsOf(loser.ID))
			}

			ledger.setDown(false)
			f.clock.Advance(f.cfg.NextHandDelay) // the retry is due, and lands
			seated, err := join(loser)
			if err != nil {
				t.Fatalf("the join once the settlement had landed: %v", err)
			}
			if seat, wallet := seatChips(t, seated, loser.ID), book.get(loser.ID); seat != final || wallet != final {
				t.Fatalf("seat %d, wallet %d; both must be the %d the hand left", seat, wallet, final)
			}
			if clamped := ledger.clampedChips(); clamped != 0 {
				t.Fatalf("a clamp at zero absorbed %d chips: chips were created", clamped)
			}
		})
	}
}

// A settlement given up after its last attempt ends the wait too: nothing will
// write that hand now, so the wallet as it stands is the last word, and a
// player must not be kept out of the lobby for the life of the process —
// whether the retries were given up on the table's actor or outlived the
// table.
func TestASettlementGivenUpNoLongerKeepsItsPlayersWaiting(t *testing.T) {
	for _, destroyed := range []bool{false, true} {
		name := "the table plays on"
		if destroyed {
			name = "the table is destroyed behind them"
		}
		t.Run(name, func(t *testing.T) {
			book := newWalletBook()
			ledger := newClampingLedger(book)
			f := bookedRooms(t, book, ledger.install)
			table, winner, loser := refusedSettlement(t, f, ledger)
			f.mustLeave(loser.ID, game.LeaveReasonLeft)
			if destroyed {
				f.mustLeave(winner.ID, game.LeaveReasonLeft)
			}
			if f.rooms.WhileUnseated(loser.ID, func(context.Context) {}) {
				t.Fatal("a lobby change ran while the settlement was still being retried")
			}

			// Every retry is refused — min(30 s, 4 s × n) for ten attempts, 202 s
			// in all — and the eleventh gives up.
			f.clock.Advance(10 * time.Minute)
			if destroyed {
				if err := table.WaitSettlements(context.Background()); err == nil {
					t.Fatal("the settlement that outlived its table was not given up")
				}
			}
			if !f.rooms.WhileUnseated(loser.ID, func(context.Context) {}) {
				t.Fatal("the player was still refused after the settlement was given up")
			}
			seated, err := f.rooms.QuickJoin(loser, seenAt200)
			if err != nil {
				t.Fatalf("a lobby seat after the settlement was given up: %v", err)
			}
			if seat, wallet := seatChips(t, seated, loser.ID), book.get(loser.ID); seat != wallet {
				t.Fatalf("seat %d against a wallet of %d", seat, wallet)
			}
		})
	}
}
