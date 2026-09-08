package game

import "time"

// Clock is the Table's (and RoomManager's, and the socket layer's) only
// source of time, so tests can drive turn clocks, the between-hand countdown
// and sideshow expiry deterministically (decision 6). Node used
// `timers = {setTimeout, clearTimeout}` injected into the Table plus
// Date.now(); the Go port folds both into this one interface.
//
// Production: RealClock. Tests: internal/game/testclock.Fake.
type Clock interface {
	// Now is the current instant. Every wire timestamp (deadline, expiresAt,
	// startsAt, nextHandAt, chat `at`) is Millis(clock.Now()).
	Now() time.Time
	// AfterFunc runs fn once, in its own goroutine (real) or synchronously
	// from Advance (fake), after d. Callers inside the Table MUST post back
	// onto the actor from fn (`t.run(...)`) — fn itself is NOT on the actor
	// goroutine.
	AfterFunc(d time.Duration, fn func()) Timer
}

// Timer is the handle AfterFunc returns. Stop reports whether the call was
// prevented (false when it already fired or was stopped) — time.Timer.Stop
// semantics. Stop is the only method the game needs.
type Timer interface {
	Stop() bool
}

// RealClock is the production Clock over package time.
type RealClock struct{}

// Now returns time.Now().
func (RealClock) Now() time.Time { return time.Now() }

// AfterFunc wraps time.AfterFunc.
func (RealClock) AfterFunc(d time.Duration, fn func()) Timer { return time.AfterFunc(d, fn) }

// Millis converts a time to the epoch-milliseconds integer Node's Date.now()
// produced — the only time representation on the wire and in the database.
func Millis(t time.Time) int64 { return t.UnixMilli() }

// FromMillis is the inverse of Millis (for values read back from the DB).
func FromMillis(ms int64) time.Time { return time.UnixMilli(ms) }
