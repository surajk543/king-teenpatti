//go:build !unix

package metrics

// rusageCPU has no portable source off unix; the counters read 0 there.
func rusageCPU() (user, system float64) { return 0, 0 }
