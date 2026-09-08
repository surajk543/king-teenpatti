//go:build !unix

package app

import "time"

// processCPUTime has no portable source outside Unix; /health reports 0.
func processCPUTime() (time.Duration, bool) { return 0, false }
