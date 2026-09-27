package game

// Report Player (owner, 27 Sep 2026; report.go): what a Teen Patti table says
// about where a player stands, for a report about them. A read on the actor;
// nothing here changes the table.

// ReportContexts implements Room: every seated player, and every player of
// also, with the table's id, game and category and — where the table knows
// one — the relevant hand and its variation.
func (t *Table) ReportContexts(also ...string) (map[string]ReportContext, error) {
	var out map[string]ReportContext
	err := t.run(func() {
		out = make(map[string]ReportContext, len(t.seats)+len(also))
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
// play when they were dealt into it — a player who packed or walked out of it
// included, their contribution staying with the hand — else the last hand
// this table finished when they were in that one, else no hand. The variant is
// that hand's variation once chosen ("" on a seen or blind table, and while a
// variation table's window is still open).
func (t *Table) reportContext(userID string) ReportContext {
	ctx := ReportContext{RoomID: t.id, Game: GameTeenPatti, Category: t.cfg.Category}
	if h := t.hand; h != nil && h.contributions[userID] != nil {
		ctx.HandID = h.id
		if h.variation != nil {
			ctx.Variant = string(h.variation.selected)
		}
		return ctx
	}
	if t.lastHand.Has(userID) {
		ctx.HandID, ctx.Variant = t.lastHand.ID, t.lastHand.Variant
	}
	return ctx
}

// recent is the hand as RecentHand keeps it once it has finished: its id, the
// variation it was decided by, and everybody dealt into it (its contributions
// — a player who packed or left mid-hand is one of them).
func (h *hand) recent() *RecentHand {
	variant := ""
	if h.variation != nil {
		variant = string(h.variation.selected)
	}
	players := make([]string, 0, len(h.contributions))
	for id := range h.contributions {
		players = append(players, id)
	}
	return NewRecentHand(h.id, variant, players)
}
