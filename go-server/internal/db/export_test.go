package db

// Test seams for the external db_test package, compiled into tests only.

// SetLuckyPick makes the Lucky Draw draw its numbers from pick instead of
// crypto/rand, so a test can land a spin on the slot it is about: pick is
// handed the draw's total weight n and answers a number in [0, n).
func (l *LuckyDraws) SetLuckyPick(pick func(n int64) (int64, error)) { l.pick = pick }
