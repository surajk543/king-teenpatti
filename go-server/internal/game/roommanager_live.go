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
	// Tables is how many tables were rebuilt and registered. The live store
	// is the only source there is: PostgreSQL holds no game state
	// (LIVE_STATE_PLAN.md).
	Tables int
	// Seats is how many seats those tables held (RestoredSeats has them).
	Seats int
	// HandsInProgress is how many restored tables had a live hand at the
	// moment of the restore (before their clocks were re-armed).
	HandsInProgress int
	// HandIDs are the ids of those hands: the pots the database refund step
	// (db.RefundOrphanedPots) must leave alone — they are still being played.
	HandIDs []string
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

// Restore rebuilds every stored table (LIVE_STATE_PLAN.md startup step 2)
// from the live store, the only place game state is kept:
// ListTables → LoadTable → parse → restore. Snapshots that fail to parse or
// cannot be rebuilt are deleted from the store and counted in Dropped; a
// load error leaves the entry in place and counts in Failed.
//
// There is no second pass. PostgreSQL holds money and audit only, so when
// the live store is empty nothing comes back: the players re-join fresh
// tables and every pot left open is refunded to its contributors
// (db.RefundOrphanedPots), which is the whole safety net.
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
// (there is no instance filter yet). Without a live store Restore does
// nothing. The returned error is fatal (the store could not even be listed);
// the report is still filled with what was done before it.
func (rm *RoomManager) Restore(ctx context.Context) (RestoreReport, error) {
	report := RestoreReport{HandIDs: []string{}}
	if err := rm.restoreFromLive(ctx, &report); err != nil {
		return report, err
	}
	return report, nil
}

// restoreFromLive rebuilds every table the live store holds.
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
			rm.log.Error("table restore: load failed", "roomId", ref.RoomID, "error", err.Error())
			report.Failed++
			continue
		}
		snap, err := parseStoredSnapshot(ref.RoomID, data)
		if err != nil {
			rm.dropStored(ctx, ref.RoomID, nil, err)
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
		switch rm.restoreOne(ctx, snap, report) {
		case restoreDropped:
			rm.dropStored(ctx, snap.RoomID, snap, errors.New("could not be rebuilt"))
		}
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
func (rm *RoomManager) restoreOne(ctx context.Context, snap *Snapshot, report *RestoreReport) restoreOutcome {
	rm.mu.Lock()
	_, exists := rm.tables[snap.RoomID]
	rm.mu.Unlock()
	if exists {
		report.Skipped++
		return restoreSkipped
	}

	table, err := restoreTable(snap, rm.tableOptions(TableOptions{}))
	if err != nil {
		rm.log.Error("table restore: could not rebuild", "roomId", snap.RoomID, "error", err.Error())
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
	if snap.Hand != nil {
		report.HandsInProgress++
		report.HandIDs = append(report.HandIDs, snap.Hand.ID)
	}

	// Second phase: clocks. Anything that fires now (a lapsed turn, a kick)
	// runs against a registered table. The first save that follows (seq + 1)
	// claims the table in the live store.
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
		"bootAmount", table.BootAmount(),
		"category", string(table.Category()),
		"isPrivate", table.IsPrivate(),
		"seats", len(seats)-len(duplicates),
		"handInProgress", snap.Hand != nil,
		"state", string(table.State()),
	)
	return restoreDone
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
	// StaleSeats and StaleSummaries are what the leak sweep removed: seat
	// entries for players this manager does not have, and summaries for
	// tables it does not have (see ReconcileLive).
	StaleSeats     int
	StaleSummaries int
	// Errors counts store calls that failed (also counted through the
	// LiveErrors hook / the wrapped store's own metrics).
	Errors int
}

// ReconcileLive makes the live store agree with memory, in both directions.
//
// Refill: when the store answers Ping, every live table is re-saved
// (Table.SaveLive: a fresh snapshot under the next seq), every public table
// re-published to the matchmaking index and every seat re-set. That is for a
// Redis that died while the process ran and came back EMPTY — without it
// each table would be missing until its next move — and it heals a FLUSHALL
// or an eviction the same way.
//
// Sweep: then everything the store holds that memory does not — stray seat
// entries and stray summaries — is deleted (sweepStrays), so a deletion
// missed anywhere heals itself on the next tick instead of accumulating.
//
// The app ticks it (LIVE_RECONCILE_MS) and calls it once more when the store
// turns healthy again. Cheap: three round trips per table, one per seat and
// two listings, no mutex held across any of them, and safe to call at any
// time (a table destroyed under it is skipped). Without a store it does
// nothing.
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

	rm.sweepStrays(ctx, &report)

	rm.log.Info("live store reconciled",
		"tables", report.Tables, "published", report.Published, "seats", report.Seats,
		"staleSeats", report.StaleSeats, "staleSummaries", report.StaleSummaries, "errors", report.Errors)
	return report
}

// sweepStrays is ReconcileLive's other half: the belt to every ClearSeated
// and RetireTable's braces. Whatever the reason a deletion was missed — a
// departure path that forgot one, a store that was down for the one call
// that mattered, a table this process never restored after a previous one
// died — this removes it on the next tick instead of letting it accumulate.
// Production, 9 Sep 2026, with zero players and zero tables: 4,715
// `kt:seat:<userId>` keys (they have no ttl at all) and 141
// `kt:summary:<roomId>` hashes.
//
// The rule is deliberately simple and it is the same one for both: THIS
// PROCESS OWNS EVERY TABLE IN THE STORE (LIVE_STATE_PLAN.md: there is no
// instance filter yet), so an entry naming something it does not have is by
// definition finished with.
//
//   - a seat entry whose user is not in playerRooms → ClearSeated. Seats are
//     read back only through this index, so nothing is lost by dropping one;
//     a player who is really seated is re-set by the loop above, on this same
//     tick, before the sweep looks.
//   - a summary whose room is not registered → RetireTable, which also takes
//     the room out of its lobby bucket. Private tables never publish one, so
//     a private room being missing from the index is not a stray.
//
// It runs after the refill pass on purpose, and every candidate is checked
// against the index AS IT IS AT THAT MOMENT, not against the copy the refill
// used: a player who sits down while the reconcile is running has their key
// written by seatHeld, and judging them against a stale copy would delete
// the seat of somebody who is at a table.
func (rm *RoomManager) sweepStrays(ctx context.Context, report *ReconcileReport) {
	stored, err := rm.live.ListSeats(ctx)
	if err != nil {
		rm.liveError(LiveOpListSeats, err)
		report.Errors++
	}
	for userID := range stored {
		rm.mu.Lock()
		_, ours := rm.playerRooms[userID]
		rm.mu.Unlock()
		if ours {
			continue
		}
		if err := rm.live.ClearSeated(ctx, userID); err != nil {
			rm.liveError(LiveOpClearSeated, err)
			report.Errors++
			continue
		}
		report.StaleSeats++
	}

	summaries, err := rm.live.ListSummaries(ctx)
	if err != nil {
		rm.liveError(LiveOpListSummaries, err)
		report.Errors++
	}
	for _, summary := range summaries {
		rm.mu.Lock()
		_, ours := rm.tables[summary.RoomID]
		rm.mu.Unlock()
		if ours {
			continue
		}
		rm.pubMu.Lock()
		delete(rm.published, summary.RoomID)
		rm.pubMu.Unlock()
		if err := rm.live.RetireTable(ctx, summary.RoomID, summary.Category, summary.BootAmount); err != nil {
			rm.liveError(LiveOpRetireTable, err)
			report.Errors++
			continue
		}
		report.StaleSummaries++
	}
	if report.StaleSeats > 0 || report.StaleSummaries > 0 {
		rm.log.Warn("live store strays removed",
			"seats", report.StaleSeats, "summaries", report.StaleSummaries)
	}
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

// dropStored forgets a stored table that cannot be restored and says why.
// EVERYTHING the table left in the store goes, not just its snapshot: the
// chat, its matchmaking summary, and the seat entry of every player the
// snapshot named. Dropping only the snapshot is how a room that fails to
// rebuild leaves a `kt:summary:<roomId>` and a fistful of `kt:seat:<userId>`
// behind it for good (seat keys have no ttl), which is one of the two leaks
// found on production, 9 Sep 2026.
//
// snap is nil when the snapshot could not even be parsed: there are no seats
// to name then, and RetireTable still deletes the summary hash (the bucket
// it also tries to ZREM simply does not have it; Candidates drops members
// whose summary is gone, and ReconcileLive sweeps the rest).
func (rm *RoomManager) dropStored(ctx context.Context, roomID string, snap *Snapshot, cause error) {
	rm.log.Error("table restore: dropping stored table", "roomId", roomID, "error", cause.Error())
	if err := rm.live.DeleteTable(ctx, roomID); err != nil {
		rm.liveError(LiveOpDeleteTable, err)
	}
	if err := rm.live.DeleteChat(ctx, roomID); err != nil {
		rm.liveError(LiveOpDeleteChat, err)
	}
	category, bootAmount := "", int64(0)
	if snap != nil {
		category = string(snap.Category)
		if category == "" {
			category = string(snap.Config.Category)
		}
		bootAmount = snap.Config.BootAmount
		for _, seat := range snap.Seats {
			if seat == nil {
				continue
			}
			rm.mu.Lock()
			stillSeated := rm.playerRooms[seat.UserID] != ""
			rm.mu.Unlock()
			if stillSeated {
				continue // they sit at a table that DID restore; leave their key
			}
			rm.liveClearSeated(seat.UserID)
		}
	}
	if err := rm.live.RetireTable(ctx, roomID, category, bootAmount); err != nil {
		rm.liveError(LiveOpRetireTable, err)
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
