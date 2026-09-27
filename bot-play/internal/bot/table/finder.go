// Package table is where a bot plays: which Teen Patti tables the server
// offers and which of them its stack may sit at (finder.go), which one it
// chooses (selector.go), and when it gets up and moves on (switcher.go).
//
// The menu is the server's (GET /api/tables, refreshed by session:ready's
// tableConfigVersion); no table id or stake is hard-coded. The server still
// decides every seat: a refusal (over_entry_cap, below_table_minimum,
// table_not_offered, insufficient_chips) is handled by the caller.
package table

import (
	"context"
	"errors"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// Choice is one lobby table a bot may pick: a Teen Patti category and boot,
// with its stack band and clock.
type Choice struct {
	Key           string // "blind:5000"
	Category      string
	Boot          int64
	MinChips      int64 // 0 = no floor
	MaxChips      int64 // 0 = no ceiling
	TurnTimeoutMs int64
	SortOrder     int
}

// Menu is the Teen Patti part of the catalogue: public, teen_patti engine,
// the categories the bots are allowed (config table.categories).
type Menu struct {
	Version string
	Tables  []Choice // in the server's sort order
}

// teenPattiCategories is every category the bots can play, in the lobby's
// order. Anything else — the four poker games, or a category a later server
// adds — is never on a bot's menu, whatever the configuration asks for: a
// bot can only play what it was written for.
var teenPattiCategories = []string{protocol.CategorySeen, protocol.CategoryBlind, protocol.CategoryVariation}

// IsTeenPatti reports whether category is one of the three Teen Patti
// categories the bots play (seen, blind, variation), matched exactly as the
// server matches it.
func IsTeenPatti(category string) bool {
	for _, c := range teenPattiCategories {
		if c == category {
			return true
		}
	}
	return false
}

// MenuKey is how the server keys a public table (table_configs.table_key):
// "blind:200".
func MenuKey(category string, boot int64) string {
	return category + ":" + strconv.FormatInt(boot, 10)
}

// Offered reports whether key is on the menu.
func (m Menu) Offered(key string) bool {
	_, ok := m.Lookup(key)
	return ok
}

// Lookup finds a table by key.
func (m Menu) Lookup(key string) (Choice, bool) {
	for _, c := range m.Tables {
		if c.Key == key {
			return c, true
		}
	}
	return Choice{}, false
}

// Admits reports whether a stack of chips may sit at c: inside its band and
// covering at least one boot.
//
// Both ends of the band are inclusive, as the server's assertWithinTableBand
// has them: a stack of exactly MinChips or exactly MaxChips sits down. The
// one-boot rule is the server's too (a smaller stack is refused
// insufficient_chips). Whether c is still offered is a separate question
// (Offered); Admits reads only c.
func (m Menu) Admits(c Choice, chips int64) bool {
	if c.Boot <= 0 || chips < c.Boot {
		return false
	}
	if c.MinChips > 0 && chips < c.MinChips {
		return false
	}
	if c.MaxChips > 0 && chips > c.MaxChips {
		return false
	}
	return true
}

// Keys is every table key on the menu, in its order.
func (m Menu) Keys() []string {
	keys := make([]string, len(m.Tables))
	for i, c := range m.Tables {
		keys[i] = c.Key
	}
	return keys
}

// FromCatalogue builds the menu from GET /api/tables, keeping only public
// teen_patti tables of the allowed categories (all three when empty).
//
// An entry is kept when it is public, its engine is teen_patti (or absent,
// with a Teen Patti category name — an older server), its category is one of
// seen, blind or variation AND one of allowed, and its boot is positive. The
// server's order is kept (stably sorted by sortOrder when every kept entry
// carries one, which is the order the server sends anyway); a key the server
// leaves out is "category:boot"; a table with no clock of its own takes the
// catalogue's; a repeated key keeps its first entry.
func FromCatalogue(cat protocol.Catalogue, allowed []string) Menu {
	return buildMenu(cat.Version, cat.Tables, allowed, cat.TurnTimeoutMs)
}

// FromSession builds a menu from session:ready.config (which carries no
// engine or key: a teen_patti category is recognised by name).
//
// The session's entries are the same lobby tables GET /api/tables serves, in
// the same order, with fewer keys; the rules are FromCatalogue's.
func FromSession(cfg protocol.SessionConfig, allowed []string) Menu {
	return buildMenu(cfg.TableConfigVersion, cfg.Tables, allowed, cfg.TurnTimeoutMs)
}

// buildMenu is FromCatalogue and FromSession: the filter, the keys, the order.
func buildMenu(version string, entries []protocol.TableEntry, allowed []string, turnTimeoutMs int64) Menu {
	allow := allowedSet(allowed)
	m := Menu{Version: version}
	seen := make(map[string]bool, len(entries))
	sortable := true
	for i, e := range entries {
		if e.IsPrivate || e.BootAmount <= 0 || !IsTeenPatti(e.Category) || !allow[e.Category] {
			continue
		}
		if e.Engine != "" && e.Engine != protocol.EngineTeenPatti {
			continue
		}
		key := e.Key
		if key == "" {
			key = MenuKey(e.Category, e.BootAmount)
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		c := Choice{
			Key:           key,
			Category:      e.Category,
			Boot:          e.BootAmount,
			MinChips:      max(e.MinChips, 0),
			MaxChips:      max(e.MaxChips, 0),
			TurnTimeoutMs: e.TurnTimeoutMs,
			SortOrder:     e.SortOrder,
		}
		if c.TurnTimeoutMs <= 0 {
			c.TurnTimeoutMs = max(turnTimeoutMs, 0)
		}
		if c.SortOrder <= 0 {
			sortable = false
			c.SortOrder = i + 1 // the position the server listed it at
		}
		m.Tables = append(m.Tables, c)
	}
	if sortable {
		sort.SliceStable(m.Tables, func(a, b int) bool { return m.Tables[a].SortOrder < m.Tables[b].SortOrder })
	}
	return m
}

// allowedSet is config table.categories as a set of Teen Patti categories;
// empty allows all three. A name that is not a Teen Patti category is
// ignored, so no configuration can put a poker table on a bot's menu.
func allowedSet(allowed []string) map[string]bool {
	set := make(map[string]bool, len(teenPattiCategories))
	for _, c := range allowed {
		if IsTeenPatti(c) {
			set[c] = true
		}
	}
	if len(allowed) == 0 {
		for _, c := range teenPattiCategories {
			set[c] = true
		}
	}
	return set
}

// ErrNoTables is Refresh's answer when the catalogue lists no table at all:
// not a usable menu (a server that offers nothing still lists its poker
// rooms), so the menu held is kept.
var ErrNoTables = errors.New("table: GET /api/tables listed no tables")

// Finder keeps the fleet's one shared copy of the menu: fetched at start,
// refreshed when a session names a catalogue version it does not hold, and
// on demand. Safe for concurrent use by every bot.
type Finder struct {
	mu sync.RWMutex

	api     protocol.API
	allowed []string
	now     func() time.Time

	menu    Menu            // as last read, before retirements
	known   bool            // a menu has been read (REST or a session)
	readAt  time.Time       // when it was read
	retired map[string]bool // keys refused table_not_offered since it was read
	noticed string          // the last version a session was answered stale for
}

// NewFinder reads through api; allowed is config table.categories.
func NewFinder(api protocol.API, allowed []string, now func() time.Time) *Finder {
	if now == nil {
		now = time.Now
	}
	return &Finder{
		api:     api,
		allowed: append([]string(nil), allowed...),
		now:     now,
		retired: map[string]bool{},
	}
}

// Refresh reads GET /api/tables now.
//
// On success the catalogue's Teen Patti tables replace the menu and every
// retirement is forgotten: the server has said afresh what it offers. On an
// error — the request failed, or the catalogue listed nothing (ErrNoTables)
// — the menu held is kept and the error returned; the next session:ready can
// still supply one (NoticeSession). The request is made outside the lock.
func (f *Finder) Refresh(ctx context.Context) error {
	if f.api == nil {
		return errors.New("table: finder has no API")
	}
	cat, err := f.api.Tables(ctx)
	if err != nil {
		return err
	}
	if len(cat.Tables) == 0 {
		return ErrNoTables
	}
	m := FromCatalogue(cat, f.allowed)
	f.mu.Lock()
	f.apply(m)
	f.mu.Unlock()
	return nil
}

// apply replaces the menu; the caller holds the write lock.
func (f *Finder) apply(m Menu) {
	f.menu = m
	f.known = true
	f.readAt = f.now()
	clear(f.retired)
}

// Menu is the current menu (empty until the first Refresh or NoticeSession).
//
// Tables the server has refused as not offered since the menu was read
// (Retire) are left out. The Tables slice is the caller's own copy.
func (f *Finder) Menu() Menu {
	f.mu.RLock()
	defer f.mu.RUnlock()
	out := Menu{Version: f.menu.Version}
	for _, c := range f.menu.Tables {
		if !f.retired[c.Key] {
			out.Tables = append(out.Tables, c)
		}
	}
	return out
}

// Known reports whether any menu has been read yet, from the REST call or a
// session. Until one has, Menu is empty and nothing is offered.
func (f *Finder) Known() bool {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.known
}

// Version is the catalogue version the menu came from ("" when none is held,
// or the server named none).
func (f *Finder) Version() string {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.menu.Version
}

// Age is how long ago the menu was read (0 while none is held).
func (f *Finder) Age() time.Duration {
	f.mu.RLock()
	defer f.mu.RUnlock()
	if !f.known {
		return 0
	}
	return f.now().Sub(f.readAt)
}

// NoticeSession takes session:ready.config: when it names a catalogue
// version the finder does not hold, the session's own table list replaces
// the menu at once and a Refresh is worth making (the returned bool).
//
// The session's list is applied straight away so the first bot to meet a
// changed catalogue hands it to the whole fleet, and — its version now held —
// every later session naming the same version changes nothing and asks for
// no refresh: one GET /api/tables for the fleet, not one per bot. A session
// whose list is empty keeps the menu held and reports stale once for its
// version (the first bot to see it asks for the refresh). A session
// naming NO version (a server older than the catalogue, where GET /api/tables
// does not exist) supplies the menu only while none is known, and never asks
// for a refresh.
func (f *Finder) NoticeSession(cfg protocol.SessionConfig) (stale bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if cfg.TableConfigVersion == "" {
		if !f.known && len(cfg.Tables) > 0 {
			f.apply(FromSession(cfg, f.allowed))
		}
		return false
	}
	if f.known && cfg.TableConfigVersion == f.menu.Version {
		return false
	}
	if len(cfg.Tables) == 0 && cfg.TableConfigVersion == f.noticed {
		return false // stale already reported for this version
	}
	f.noticed = cfg.TableConfigVersion
	if len(cfg.Tables) > 0 {
		f.apply(FromSession(cfg, f.allowed))
	}
	return true
}

// Retire takes a table off the menu until the next refresh (the server
// answered table_not_offered).
//
// The server is the authority on what it offers; a refusal means the menu
// held is stale for that table. It comes back when a menu is next read — a
// Refresh, or a session naming a new version — which says afresh what is
// offered.
func (f *Finder) Retire(key string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.retired[key] = true
}
