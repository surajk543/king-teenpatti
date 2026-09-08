//go:build unix

package app

import (
	"syscall"
	"time"
)

// processCPUTime is user + system CPU time consumed by this process so far —
// the same getrusage(RUSAGE_SELF) figures Node's process.cpuUsage() reads, so
// /health.process.cpuPercent means the same thing on both servers.
func processCPUTime() (time.Duration, bool) {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return 0, false
	}
	user := time.Duration(ru.Utime.Sec)*time.Second + time.Duration(ru.Utime.Usec)*time.Microsecond
	sys := time.Duration(ru.Stime.Sec)*time.Second + time.Duration(ru.Stime.Usec)*time.Microsecond
	return user + sys, true
}
