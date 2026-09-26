package game

// The playing record (Friends V1, owner 26 Sep 2026): what a seated player's
// friends are shown they are playing. It rides the seat mirror
// (roommanager_live.go: liveSetSeated, the restore, ReconcileLive's refill)
// into the live store as kt:playing:<userId> and is deleted with it
// (liveClearSeated, the stray sweep), so it says "Playing now" exactly while
// the RoomManager holds a seat for the player — the reconnect grace included —
// and never names the table.

import (
	"strings"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// The playing record's game families (live.Playing.Game). Upper-case wire
// values of their own, beside Game's ("teen_patti", "poker") which name the
// family on a chip_ledger row.
const (
	PlayingGameTeenPatti = "TEEN_PATTI"
	PlayingGamePoker     = "POKER"
)

// PlayingAt is the playing record of a seat at a room of category, stamped
// at: TEEN_PATTI for seen, blind and variation, POKER for the four poker
// categories, and the category itself upper-cased as the variant (SEEN,
// BLIND, VARIATION, THREE_CARD_POKER, FIVE_CARD_DRAW, TEXAS_HOLDEM, OMAHA). A
// private table reports its category like any other. Never a room id, a code,
// a stake or anything about the hand.
func PlayingAt(category Category, at time.Time) live.Playing {
	family := PlayingGameTeenPatti
	if category.Game() == GamePoker {
		family = PlayingGamePoker
	}
	return live.Playing{Game: family, Variant: strings.ToUpper(string(category)), UpdatedAt: Millis(at)}
}

// MinPlayingTTL is the shortest life a playing record is written with: the
// socket layer's presence window (kt:online entries live 90 s), so a record
// never outlasts a crashed process by much more than its online entry does,
// and a short reconcile interval does not make it flicker.
const MinPlayingTTL = 90 * time.Second

// PlayingTTLFor is RoomManagerOptions.PlayingTTL for a reconciler that runs
// every reconcile (LIVE_RECONCILE_MS): three intervals, never under
// MinPlayingTTL. ReconcileLive rewrites every seat, so the record never
// lapses while its seat is held — two missed passes are forgiven — yet the
// records of a process that died without clearing them expire on their own.
//
// A reconciler that is off (reconcile <= 0) refreshes nothing, so the record
// is then written with NO expiry: it lives exactly as long as the seat key
// beside it — cleared wherever the seat is, rewritten by the next process's
// restore — and never lapses under a seated player.
func PlayingTTLFor(reconcile time.Duration) time.Duration {
	if reconcile <= 0 {
		return 0
	}
	ttl := 3 * reconcile
	if ttl < MinPlayingTTL {
		ttl = MinPlayingTTL
	}
	return ttl
}
