//go:build unix

package metrics

import "syscall"

// rusageCPU returns the process's cumulative user and system CPU time in
// seconds, the two halves prom-client exposed as
// process_cpu_user_seconds_total and process_cpu_system_seconds_total.
func rusageCPU() (user, system float64) {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return 0, 0
	}
	toSeconds := func(tv syscall.Timeval) float64 {
		return float64(tv.Sec) + float64(tv.Usec)/1e6
	}
	return toSeconds(ru.Utime), toSeconds(ru.Stime)
}
