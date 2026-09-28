package game

import "time"

// The countdown before every deal (owner, 29 Sep 2026: "whenever Game starts
// in any game table, instead of showing text "Starting game .." show this
// count Down animation 3,2,1 … and when countdown finishes then distribute
// card").
//
// The table's `starting` state was always the countdown: startsAt is when the
// server deals, and until then there is no hand, so every move is refused
// (no_hand) — nobody can chaal, see or pack before the cards are out. What
// changed is how long it lasts and what the app is told:
//
//   - A FIRST deal (a second player sits down, a table that was waiting) is
//     the countdown alone: StartDelay — StartCountdown, or NextHandDelay where
//     a table is configured shorter than that.
//   - A deal AFTER A HAND is NextHandDelay from the hand's end, as it always
//     was (handEnded.nextHandAt), and NextHandDelay now defaults to 6 s: the
//     winner's celebration first (the fireworks, the ribbon and the pot's
//     flight take about 2.5 s in the app), then the 3 s countdown in the last
//     StartCountdown of the window. The hand's end also HOLDS the next deal
//     to that instant (Table.holdStartUntil), so a countdown cancelled by a
//     departure and started again inside the window never runs over the
//     celebration; a missile showdown's hold is that instant plus
//     MissileRevealExtra, as before.
//   - room:state carries startsInMs beside startsAt (StartsInMs): the time
//     left until the deal, measured when the snapshot is serialised. The app
//     anchors its countdown to the moment the snapshot arrives, which is
//     immune to the phone's clock being set wrong, and ends it one network
//     trip after the server deals — exactly when the deal's own snapshot
//     arrives, one trip after it too.

// StartCountdown is the countdown the app plays before a deal: "3, 2, 1".
// The app's animation is this long; the server only needs it to time a first
// deal, which has no celebration in front of it.
const StartCountdown = 3 * time.Second

// StartDelay is how long a countdown runs when nothing holds the deal later:
// StartCountdown, or nextHandDelay where a table is configured with a shorter
// window between hands (every test and parity profile with a quick clock
// keeps exactly the delay it always had).
func StartDelay(nextHandDelay time.Duration) time.Duration {
	if nextHandDelay < StartCountdown {
		return nextHandDelay
	}
	return StartCountdown
}

// StartsInMs is the wire's startsInMs: the milliseconds from now until the
// deal at startsAt, never negative (a snapshot serialised as the start timer
// is firing says 0, not a time in the past).
func StartsInMs(startsAt, now time.Time) int64 {
	left := startsAt.Sub(now).Milliseconds()
	if left < 0 {
		return 0
	}
	return left
}
