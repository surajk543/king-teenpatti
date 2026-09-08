package game

// The RoomManager's side of the live-state store (LIVE_STATE_PLAN.md):
// mirroring the seat index, publishing public tables to the matchmaking
// index, rebuilding every stored table at startup (Restore) and suspending
// them for a graceful restart (Suspend). Every helper is a no-op without a
// store, and none of them is ever called under mu.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"

	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// RestoredSeat is one seat Restore rebuilt: the socket layer marks it
// disconnected and arms the reconnect grace timer for it exactly as it would
// after a drop (Handler.RestoreSeats).
type RestoredSeat struct {
	UserID string
	RoomID string
}

// RestoreReport is what Restore did.
type RestoreReport struct {
	// Tables is how many tables were rebuilt and registered, from either
	// source (FromLive + FromDurable).
	Tables int
	// FromLive / FromDurable split Tables by where the snapshot came from:
	// the live store (pass 1) or game_states (pass 2, Redis came up empty).
	FromLive    int
	FromDurable int
	// Seats is how many seats those tables held (RestoredSeats has them).
	Seats int
	// HandsInProgress is how many restored tables had a live hand at the
	// moment of the restore (before their clocks were re-armed).
	HandsInProgress int
	// HandIDs are the ids of those hands: the pots the database refund step
	// (db.RefundOrphanedPots) must leave alone — they are still being played.
	HandIDs []string
	// Reconciled is how many durable snapshots the ledger corrected (a bet
	// the asynchronous writer had not flushed yet).
	Reconciled int
	// Rejected is how many durable snapshots were too stale to trust
	// (ReconcileWithLedger refused them); they were NOT restored and are
	// left for the refund step.
	Rejected int
	// Dropped is how many stored snapshots could not be parsed or rebuilt;
	// live ones were deleted from the store (snapshot and chat).
	Dropped int
	// Skipped is how many stored tables were already registered (Restore
	// called twice) and left alone.
	Skipped int
	// Failed is how many stored tables could not be loaded (a store error,
	// not a bad snapshot) and were left in place for a later attempt.
	Failed int
}

// TableRestoreListener is the optional extension of RoomListener a listener
// may implement to be told about restored tables specifically. Restore calls
// OnTableCreated for every restored table in any case (the socket layer
// treats both alike), and OnTableRestored as well when implemented.
type TableRestoreListener interface {
	OnTableRestored(t *Table)
}

// Restore source names (RestoreReport, logs, game_restored_tables_total{source}).
const (
	RestoreSourceLive    = "live"
	RestoreSourceDurable = "postgres"
)

// Restore rebuilds every stored table (LIVE_STATE_PLAN.md startup step 2) in
// two passes, the fresher source first:
//
//  1. the live store: ListTables → LoadTable → parse → restore (source
//     "live"). Snapshots that fail to parse or cannot be rebuilt are deleted
//     from the store and counted in Dropped; a load error leaves the entry
//     in place and counts in Failed.
//  2. the durable source (game_states), for every room the live store did
//     not have: the snapshot is up to SNAPSHOT_FLUSH_MS behind the money, so
//     it is RECONCILED against the ledger first (ReconcileWithLedger — the
//     ledger wins; a snapshot too old to trust is Rejected and left for the
//     refund step), then restored (source "postgres") and written straight
//     back into the live store by its first save, which refills Redis.
//
// For each table: RestoreTable's first phase (construct without clocks) →
// register (tables in CreatedAt order, playerRooms from the seats, code
// lookup by scan as for every table) → LoadChat from the live store →
// re-arm the clocks (second phase, so a timeout or kick that fires at once
// finds the player indexed) → RoomListener.OnTableCreated (+
// OnTableRestored) → PublishTable and SetSeated per seat.
//
// Restored tables are ordinary tables afterwards: the sweeper, consolidation
// and kicks treat them like any other. Call Restore before StartSweeper and
// before the listener opens; then hand RestoredSeats to the socket layer and
// HandIDs to the database refund. A single instance owns every stored table
// (there is no instance filter yet). Without a live store or durable source
// Restore does nothing. The returned error is fatal (a source could not even
// be listed); the report is still filled with what was done before it.
func (rm *RoomManager) Restore(ctx context.Context) (RestoreReport, error) {
	report := RestoreReport{HandIDs: []string{}}
	if err := rm.restoreFromLive(ctx, &report); err != nil {
		return report, err
	}
	if err := rm.restoreFromDurable(ctx, &report); err != nil {
		return report, err
	}
	return report, nil
}

// restoreFromLive is Restore's first pass.
func (rm *RoomManager) restoreFromLive(ctx context.Context, report *RestoreReport) error {
	if rm.live == nil {
		return nil
	}
	refs, err := rm.live.ListTables(ctx)
	if err != nil {
		rm.liveError(LiveOpListTables, err)
		return fmt.Errorf("live store: list tables: %w", err)
	}
	loaded := make([]*Snapshot, 0, len(refs))
	for _, ref := range refs {
		seq, data, err := rm.live.LoadTable(ctx, ref.RoomID)
		if errors.Is(err, live.ErrNotFound) {
			continue // expired between the list and the load
		}
		if err != nil {
			rm.liveError(LiveOpLoadTable, err)
			rm.log.Error("table restore: load failed", "roomId", ref.RoomID, "source", RestoreSourceLive, "error", err.Error())
			report.Failed++
			continue
		}
		snap, err := parseStoredSnapshot(ref.RoomID, data)
		if err != nil {
			rm.dropStored(ctx, ref.RoomID, err)
			report.Dropped++
			continue
		}
		if snap.Seq < seq {
			snap.Seq = seq
		}
		loaded = append(loaded, snap)
	}
	sortSnapshotsByAge(loaded)
	for _, snap := range loaded {
		switch rm.restoreOne(ctx, snap, RestoreSourceLive, report) {
		case restoreDropped:
			rm.dropStored(ctx, snap.RoomID, errors.New("could not be rebuilt"))
		}
	}
	return nil
}

// restoreFromDurable is Restore's second pass (LIVE_STATE_PLAN.md "the
// durable backstop"): every game_states row the live store did not have.
func (rm *RoomManager) restoreFromDurable(ctx context.Context, report *RestoreReport) error {
	if rm.durable == nil {
		return nil
	}
	rows, err := rm.durable.LoadSnapshots(ctx)
	if err != nil {
		return fmt.Errorf("durable snapshots: load: %w", err)
	}
	loaded := make([]*Snapshot, 0, len(rows))
	for _, row := range rows {
		rm.mu.Lock()
		_, registered := rm.tables[row.RoomID]
		rm.mu.Unlock()
		if registered {
			continue // the live store had it (pass 1) — fresher, wins
		}
		snap, err := parseStoredSnapshot(row.RoomID, row.State)
		if err != nil {
			rm.log.Error("table restore: dropping durable snapshot", "roomId", row.RoomID, "source", RestoreSourceDurable, "error", err.Error())
			report.Dropped++
			continue
		}
		if snap.Seq < row.Seq {
			snap.Seq = row.Seq
		}
		if snap.Hand != nil {
			contributions, err := rm.durable.HandContributions(ctx, snap.Hand.ID)
			if err != nil {
				rm.log.Error("table restore: ledger totals unavailable", "roomId", row.RoomID, "handId", snap.Hand.ID, "error", err.Error())
				report.Failed++
				continue
			}
			potBefore := snap.Hand.Pot
			if err := ReconcileWithLedger(snap, contributions); err != nil {
				rm.log.Warn("table restore: durable snapshot too stale, leaving the pot to the refund",
					"roomId", row.RoomID, "handId", snap.Hand.ID, "error", err.Error())
				report.Rejected++
				continue
			}
			if snap.Hand.Pot != potBefore {
				report.Reconciled++
				rm.log.Info("table restore: snapshot reconciled with the ledger",
					"roomId", row.RoomID, "handId", snap.Hand.ID, "potBefore", potBefore, "pot", snap.Hand.Pot)
			}
		}
		loaded = append(loaded, snap)
	}
	sortSnapshotsByAge(loaded)
	for _, snap := range loaded {
		rm.restoreOne(ctx, snap, RestoreSourceDurable, report)
	}
	return nil
}

// parseStoredSnapshot decodes and validates one stored snapshot for roomID.
func parseStoredSnapshot(roomID string, data []byte) (*Snapshot, error) {
	snap := &Snapshot{}
	if err := json.Unmarshal(data, snap); err != nil {
		return nil, fmt.Errorf("unparseable snapshot: %w", err)
	}
	if err := validateSnapshot(snap); err != nil {
		return nil, err
	}
	if snap.RoomID != roomID {
		return nil, fmt.Errorf("snapshot names room %s", snap.RoomID)
	}
	return snap, nil
}

// sortSnapshotsByAge orders oldest first, so creation order (and every
// "oldest table" rule that hangs off it) survives the restart.
func sortSnapshotsByAge(snaps []*Snapshot) {
	sort.SliceStable(snaps, func(i, j int) bool {
		if snaps[i].CreatedAt != snaps[j].CreatedAt {
			return snaps[i].CreatedAt < snaps[j].CreatedAt
		}
		return snaps[i].RoomID < snaps[j].RoomID
	})
}

type restoreOutcome int

const (
	restoreDone restoreOutcome = iota
	restoreSkipped
	restoreDropped
)

// restoreOne rebuilds, registers and resumes one snapshot (see Restore).
func (rm *RoomManager) restoreOne(ctx context.Context, snap *Snapshot, source string, report *RestoreReport) restoreOutcome {
	rm.mu.Lock()
	_, exists := rm.tables[snap.RoomID]
	rm.mu.Unlock()
	if exists {
		report.Skipped++
		return restoreSkipped
	}

	table, err := restoreTable(snap, rm.tableOptions(TableOptions{}))
	if err != nil {
		rm.log.Error("table restore: could not rebuild", "roomId", snap.RoomID, "source", source, "error", err.Error())
		report.Dropped++
		return restoreDropped
	}
	rm.restoreChat(ctx, table)

	// Register: the table, its creation order, and every seat in the index
	// — before a single clock is re-armed.
	var seats []string
	for _, s := range snap.Seats {
		if s != nil {
			seats = append(seats, s.UserID)
		}
	}
	var duplicates []string
	rm.mu.Lock()
	if rm.codeTakenLocked(table.Code()) {
		rm.log.Warn("table restore: code already in use", "roomId", table.ID(), "code", table.Code())
	}
	rm.nextSeq++
	rm.tables[table.ID()] = table
	rm.order[table.ID()] = rm.nextSeq
	for _, userID := range seats {
		if other, seated := rm.playerRooms[userID]; seated && other != table.ID() {
			duplicates = append(duplicates, userID)
			continue
		}
		rm.playerRooms[userID] = table.ID()
		rm.restored = append(rm.restored, RestoredSeat{UserID: userID, RoomID: table.ID()})
		report.Seats++
	}
	rm.mu.Unlock()
	for _, userID := range duplicates {
		// Two stored tables claim the same player; the older table keeps
		// them (one seat per player, whichever door), this one lets go.
		rm.log.Warn("table restore: player already seated elsewhere, removing seat", "userId", userID, "roomId", table.ID())
		if _, err := table.RemovePlayer(userID, LeaveReasonLeft); err != nil && !errors.Is(err, ErrTableDestroyed) {
			rm.log.Error("table restore: duplicate seat could not be removed", "userId", userID, "roomId", table.ID(), "error", err.Error())
		}
	}
	for _, userID := range seats {
		if !slices.Contains(duplicates, userID) {
			rm.liveSetSeated(userID, table.ID())
		}
	}

	report.Tables++
	switch source {
	case RestoreSourceLive:
		report.FromLive++
	case RestoreSourceDurable:
		report.FromDurable++
	}
	if snap.Hand != nil {
		report.HandsInProgress++
		report.HandIDs = append(report.HandIDs, snap.Hand.ID)
	}

	// Second phase: clocks. Anything that fires now (a lapsed turn, a kick)
	// runs against a registered table. The first save that follows (seq + 1)
	// claims the table in the live store — and refills it when the snapshot
	// came from the durable source.
	if err := table.resume(); err != nil && !errors.Is(err, ErrTableDestroyed) {
		rm.log.Error("table restore: resume failed", "roomId", table.ID(), "error", err.Error())
	}

	rm.rl.OnTableCreated(table)
	if l, ok := rm.rl.(TableRestoreListener); ok {
		l.OnTableRestored(table)
	}
	rm.publishTable(table)
	rm.log.Info("table restored",
		"roomId", table.ID(),
		"code", table.Code(),
		"source", source,
		"bootAmount", table.BootAmount(),
		"category", string(table.Category()),
		"isPrivate", table.IsPrivate(),
		"seats", len(seats)-len(duplicates),
		"handInProgress", snap.Hand != nil,
		"state", string(table.State()),
	)
	return restoreDone
}

// ReconcileWithLedger corrects a durable snapshot (game_states, written up to
// SNAPSHOT_FLUSH_MS after the money moved) against the ledger's per-player
// totals for its hand — DurableSource.HandContributions: userID → chips
// banked as boot, bet or show. The ledger is never behind, so the ledger wins:
//
//   - every seat's and contribution record's `contributed` and `persisted`
//     become the ledger figure, the seat's chips are lowered by whatever the
//     snapshot had not yet debited, `didChaal` is set once the figure exceeds
//     the boot, and the hand's pot becomes the ledger total;
//   - a ledger figure for a player the snapshot shows as PACKED, LOST or
//     ABSENT that exceeds what the snapshot recorded means they bet after the
//     snapshot was taken — the snapshot is too old to trust and an error is
//     returned (Restore then rejects the room and leaves its open pot to
//     RefundOrphanedPots); so is a ledger figure BELOW the snapshot's (a
//     snapshot is only ever saved after the commit).
//
// Cards, seat order, blind/seen status and who has packed come from the
// snapshot: none of them changes without a chip moving. The last bet's size
// (hand.stake) cannot be read back from the ledger and is left as saved.
//
// Invariant after a successful call: hand.pot == Σ contributions and every
// seat's contributed == its entry. A snapshot without a hand is returned
// unchanged (nil). Nil contributions with a live hand is an error: a hand in
// progress always has its boots in the ledger.
func ReconcileWithLedger(snap *Snapshot, contributions map[string]int64) error {
	if snap == nil {
		return errors.New("nil snapshot")
	}
	h := snap.Hand
	if h == nil {
		return nil
	}
	if len(contributions) == 0 {
		return fmt.Errorf("hand %s has no ledger rows", h.ID)
	}
	seatOf := make(map[string]*SnapshotSeat, len(snap.Seats))
	for _, s := range snap.Seats {
		if s != nil {
			seatOf[s.UserID] = s
		}
	}
	recordOf := make(map[string]*SnapshotContribution, len(h.Contributions))
	for i := range h.Contributions {
		recordOf[h.Contributions[i].UserID] = &h.Contributions[i]
	}

	var total int64
	for userID, banked := range contributions {
		if banked < 0 {
			return fmt.Errorf("ledger total for %s is negative (%d)", userID, banked)
		}
		total += banked
		seat := seatOf[userID]
		record := recordOf[userID]
		var recorded int64
		switch {
		case record != nil:
			recorded = record.Contributed
		case seat != nil:
			recorded = seat.Contributed
		}
		if banked < recorded {
			return fmt.Errorf("ledger shows %d for %s, snapshot already had %d", banked, userID, recorded)
		}
		if banked > recorded {
			// Only a player still in the hand can have put chips in after
			// the snapshot was taken.
			inHand := seat != nil && seat.Status == SeatActive && record != nil && record.Status == SeatActive
			if !inHand {
				return fmt.Errorf("ledger shows %d for %s, snapshot has %d and them out of the hand", banked, userID, recorded)
			}
			seat.Chips -= banked - recorded
		}
		if seat != nil {
			seat.Contributed = banked
		}
		if record != nil {
			record.Contributed = banked
			record.Persisted = banked
			if banked > snap.Config.BootAmount {
				record.DidChaal = true
			}
		}
	}
	// A record the ledger knows nothing about is a contribution that was
	// never banked — impossible for a saved snapshot.
	for _, c := range h.Contributions {
		if _, known := contributions[c.UserID]; !known && c.Contributed > 0 {
			return fmt.Errorf("snapshot has %d from %s, ledger has no row", c.Contributed, c.UserID)
		}
	}
	h.Pot = total
	return nil
}

// ReconcileReport is what ReconcileLive did.
type ReconcileReport struct {
	// Healthy is the store's Ping result; nothing is written when false.
	Healthy bool
	// Tables is how many tables were re-saved (SaveTable), Published how
	// many public ones were re-published, Seats how many seats were re-set.
	Tables    int
	Published int
	Seats     int
	// Errors counts store calls that failed (also counted through the
	// LiveErrors hook / the wrapped store's own metrics).
	Errors int
}

// ReconcileLive refills the live store from memory: when the store answers
// Ping, every live table is re-saved (Table.SaveLive: a fresh snapshot under
// the next seq), every public table re-published to the matchmaking index
// and every seat re-set. It exists for a Redis that died while the process
// ran and came back EMPTY — without it each table would be missing until its
// next move — and it heals a FLUSHALL or an eviction the same way. The app
// ticks it (LIVE_RECONCILE_MS) and calls it once more when the store turns
// healthy again. Cheap: three round trips per table plus one per seat, no
// mutex held across any of them, and safe to call at any time (a table
// destroyed under it is skipped). Without a store it does nothing.
func (rm *RoomManager) ReconcileLive(ctx context.Context) ReconcileReport {
	var report ReconcileReport
	if rm.live == nil {
		return report
	}
	if err := rm.live.Ping(ctx); err != nil {
		rm.log.Warn("live store unhealthy, reconcile skipped", "error", err.Error())
		return report
	}
	report.Healthy = true

	rm.mu.Lock()
	tables := rm.tablesLocked()
	seats := make(map[string]string, len(rm.playerRooms))
	for userID, roomID := range rm.playerRooms {
		seats[userID] = roomID
	}
	rm.mu.Unlock()

	for _, t := range tables {
		if t.Destroyed() || t.Fenced() {
			continue
		}
		if err := t.SaveLive(); err != nil {
			if !errors.Is(err, ErrTableDestroyed) {
				report.Errors++
			}
			continue
		}
		report.Tables++
		if t.IsPrivate() {
			continue
		}
		if err := rm.live.PublishTable(ctx, rm.summaryOf(t)); err != nil {
			rm.liveError(LiveOpPublishTable, err)
			report.Errors++
			continue
		}
		report.Published++
	}
	for userID, roomID := range seats {
		if err := rm.live.SetSeated(ctx, userID, roomID); err != nil {
			rm.liveError(LiveOpSetSeated, err)
			report.Errors++
			continue
		}
		report.Seats++
	}
	rm.log.Info("live store reconciled", "tables", report.Tables, "published", report.Published, "seats", report.Seats, "errors", report.Errors)
	return report
}

// RestoredSeats returns every seat Restore rebuilt, in restore order. The
// socket layer arms the reconnect grace timer for each (the seats are
// already connected=false); a seat that has since been vacated (a timeout
// kick on resume, say) is harmless — the timer finds nobody there.
func (rm *RoomManager) RestoredSeats() []RestoredSeat {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	out := make([]RestoredSeat, len(rm.restored))
	copy(out, rm.restored)
	return out
}

// Suspend is Shutdown for a process that will be replaced: the sweeper stops
// and every table is suspended (Table.Suspend — a final snapshot, clocks
// stopped, no settlement, the store's copy kept) so the next process
// restores them with their hands still live and the seats held. Settlements
// still owed are waited for within ctx exactly as Shutdown does. Without a
// live store a suspend IS a destroy (nothing would come back), so Suspend
// then behaves as Shutdown. Rollback path: unset REDIS_URL → Shutdown
// semantics, as before Redis existed.
func (rm *RoomManager) Suspend(ctx context.Context) error {
	rm.stopSweeper()
	if rm.live == nil {
		return rm.Shutdown(ctx)
	}
	done := make(chan error, 1)
	go func() {
		var suspended []*Table
		var first error
		for {
			rm.mu.Lock()
			tables := rm.tablesLocked()
			rm.mu.Unlock()
			if len(tables) == 0 {
				break
			}
			for _, t := range tables {
				rm.mu.Lock()
				for userID, seatedAt := range rm.playerRooms {
					if seatedAt == t.ID() {
						delete(rm.playerRooms, userID)
					}
				}
				delete(rm.tables, t.ID())
				delete(rm.order, t.ID())
				delete(rm.pending, t.ID())
				rm.mu.Unlock()
				if err := t.Suspend(); err != nil && !errors.Is(err, ErrTableDestroyed) {
					if first == nil {
						first = err
					}
					continue
				}
				suspended = append(suspended, t)
				rm.log.Info("table suspended", "roomId", t.ID(), "seq", t.LiveSeq(), "handInProgress", t.HasHand())
			}
		}
		for _, t := range suspended {
			if err := t.WaitSettlements(ctx); err != nil {
				if ctx.Err() != nil {
					done <- err
					return
				}
				rm.log.Error("settlement abandoned at suspend", "roomId", t.ID(), "error", err.Error())
			}
		}
		done <- first
	}()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		select {
		case err := <-done:
			return err
		default:
			return ctx.Err()
		}
	}
}

// ---------------------------------------------------------------- helpers

// liveErrorHook is TableOptions.LiveErrors for every table: count only (the
// table reports the failure itself through OnPersistError / OnError, which
// tableHooks logs).
func (rm *RoomManager) liveErrorHook(op string, err error) {
	if rm.mx.ObserveLiveError != nil {
		rm.mx.ObserveLiveError(op, err)
	}
}

// liveError counts and logs a failed live-store call made by the manager.
func (rm *RoomManager) liveError(op string, err error) {
	rm.liveErrorHook(op, err)
	rm.log.Warn("live store call failed", "op", op, "error", err.Error())
}

// liveCtx bounds one store round trip.
func liveCtx() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), liveCallTimeout)
}

// liveSetSeated mirrors playerRooms[userID] = roomID.
func (rm *RoomManager) liveSetSeated(userID, roomID string) {
	if rm.live == nil {
		return
	}
	ctx, cancel := liveCtx()
	defer cancel()
	if err := rm.live.SetSeated(ctx, userID, roomID); err != nil {
		rm.liveError(LiveOpSetSeated, err)
	}
}

// liveClearSeated mirrors delete(playerRooms, userID).
func (rm *RoomManager) liveClearSeated(userID string) {
	if rm.live == nil {
		return
	}
	ctx, cancel := liveCtx()
	defer cancel()
	if err := rm.live.ClearSeated(ctx, userID); err != nil {
		rm.liveError(LiveOpClearSeated, err)
	}
}

// summaryOf renders the matchmaking row from lock-free getters.
func (rm *RoomManager) summaryOf(t *Table) live.TableSummary {
	return live.TableSummary{
		RoomID:     t.ID(),
		Code:       t.Code(),
		Category:   string(t.Category()),
		BootAmount: t.BootAmount(),
		Players:    t.PlayerCount(),
		MaxPlayers: t.Config().MaxPlayers,
		IsPrivate:  t.IsPrivate(),
		State:      string(t.State()),
		CreatedAt:  Millis(t.CreatedAt()),
		Instance:   rm.instance,
	}
}

// publishTable pushes a public table to the matchmaking index
// unconditionally (creation, restore). Private tables are never indexed
// (requirement 22: reached by code only).
func (rm *RoomManager) publishTable(t *Table) {
	if rm.live == nil || t.IsPrivate() || t.Fenced() || t.Destroyed() {
		return
	}
	summary := rm.summaryOf(t)
	rm.pubMu.Lock()
	rm.published[t.ID()] = publishedSummary{players: summary.Players, state: TableState(summary.State)}
	rm.pubMu.Unlock()
	ctx, cancel := liveCtx()
	defer cancel()
	if err := rm.live.PublishTable(ctx, summary); err != nil {
		rm.liveError(LiveOpPublishTable, err)
	}
}

// publishFromActor is tableHooks.OnState's publish: only when the player
// count or state differs from what the index last heard. Runs on the
// table's actor — lock-free getters and pubMu only.
func (rm *RoomManager) publishFromActor(t *Table) {
	if rm.live == nil || t.IsPrivate() || t.fenced.Load() || t.destroyed.Load() {
		return
	}
	players, state := t.PlayerCount(), t.State()
	rm.pubMu.Lock()
	last, known := rm.published[t.ID()]
	if known && last.players == players && last.state == state {
		rm.pubMu.Unlock()
		return
	}
	rm.published[t.ID()] = publishedSummary{players: players, state: state}
	rm.pubMu.Unlock()
	ctx, cancel := liveCtx()
	defer cancel()
	if err := rm.live.PublishTable(ctx, rm.summaryOf(t)); err != nil {
		rm.liveError(LiveOpPublishTable, err)
	}
}

// retireTable removes a public table from the matchmaking index (destroy).
func (rm *RoomManager) retireTable(t *Table) {
	rm.pubMu.Lock()
	delete(rm.published, t.ID())
	rm.pubMu.Unlock()
	if rm.live == nil || t.IsPrivate() {
		return
	}
	ctx, cancel := liveCtx()
	defer cancel()
	if err := rm.live.RetireTable(ctx, t.ID(), string(t.Category()), t.BootAmount()); err != nil {
		rm.liveError(LiveOpRetireTable, err)
	}
}

// dropStored forgets a stored table that cannot be restored (snapshot and
// chat) and says why.
func (rm *RoomManager) dropStored(ctx context.Context, roomID string, cause error) {
	rm.log.Error("table restore: dropping stored table", "roomId", roomID, "error", cause.Error())
	if err := rm.live.DeleteTable(ctx, roomID); err != nil {
		rm.liveError(LiveOpDeleteTable, err)
	}
	if err := rm.live.DeleteChat(ctx, roomID); err != nil {
		rm.liveError(LiveOpDeleteChat, err)
	}
}

// restoreChat loads the mirrored chat log onto a restored table. A line that
// does not parse is skipped; a load failure leaves the log empty (logged).
func (rm *RoomManager) restoreChat(ctx context.Context, t *Table) {
	raw, err := rm.live.LoadChat(ctx, t.ID())
	if err != nil {
		if !errors.Is(err, live.ErrNotFound) {
			rm.liveError(LiveOpLoadChat, err)
		}
		return
	}
	history := make([]ChatMessage, 0, len(raw))
	for _, line := range raw {
		var msg ChatMessage
		if err := json.Unmarshal(line, &msg); err != nil {
			rm.log.Warn("table restore: skipping unparseable chat line", "roomId", t.ID(), "error", err.Error())
			continue
		}
		history = append(history, msg)
	}
	if err := t.restoreChat(history); err != nil {
		rm.log.Warn("table restore: chat not restored", "roomId", t.ID(), "error", err.Error())
	}
}
