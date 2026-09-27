package poker

import "github.com/surajk543/king-teenpatti/go-server/internal/game"

// Report Player (owner, 27 Sep 2026; game/report.go): what a poker room says
// about where a player stands, for a report about them. A read on the actor;
// nothing here changes the room.

// ReportContexts implements game.Room: every seated player, and every player
// of also, with the room's id, game and category, its variant (the poker
// variant, as chip_ledger.variant names a poker row) and — where the room
// knows one — the relevant hand.
func (t *Table) ReportContexts(also ...string) (map[string]game.ReportContext, error) {
	var out map[string]game.ReportContext
	err := t.run(func() {
		out = make(map[string]game.ReportContext, len(t.seats)+len(also))
		for _, s := range t.occupiedSeats() {
			out[s.userID] = t.reportContext(s.userID)
		}
		for _, id := range also {
			if id != "" {
				out[id] = t.reportContext(id)
			}
		}
	})
	return out, err
}

// reportContext is userID's standing for a report (actor only): the hand in
// play when they were dealt into it — a player who folded or walked out of it
// included — else the last hand this room finished when they were in it, else
// no hand.
func (t *Table) reportContext(userID string) game.ReportContext {
	ctx := game.ReportContext{
		RoomID:   t.id,
		Game:     game.GamePoker,
		Category: t.cfg.Category,
		Variant:  string(t.cfg.Category),
	}
	if h := t.hand; h != nil && h.contributions[userID] != nil {
		ctx.HandID = h.id
		return ctx
	}
	if t.lastHand.Has(userID) {
		ctx.HandID = t.lastHand.ID
	}
	return ctx
}

// recent is the hand as game.RecentHand keeps it once it has finished: its id
// and everybody dealt into it.
func (h *hand) recent(category game.Category) *game.RecentHand {
	players := make([]string, 0, len(h.contributions))
	for id := range h.contributions {
		players = append(players, id)
	}
	return game.NewRecentHand(h.id, string(category), players)
}
