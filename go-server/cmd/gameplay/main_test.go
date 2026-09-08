package main

import (
	"runtime"
	"strings"
	"testing"
)

// TestVersionString pins the `-version` output that ops/install-go-server.sh
// and DEPLOY.md quote: the stamped version and the Go toolchain, on one line.
func TestVersionString(t *testing.T) {
	old := version
	t.Cleanup(func() { version = old })

	version = "abc1234-dirty"
	got := versionString()
	for _, want := range []string{"gameplay abc1234-dirty ", runtime.Version(), runtime.GOOS + "/" + runtime.GOARCH} {
		if !strings.Contains(got, want) {
			t.Fatalf("versionString() = %q, want it to contain %q", got, want)
		}
	}
	if strings.Contains(got, "\n") {
		t.Fatalf("versionString() = %q, want a single line", got)
	}
}
