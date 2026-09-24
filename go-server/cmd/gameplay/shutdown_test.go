package main

import (
	"os"
	"regexp"
	"strconv"
	"testing"
	"time"
)

// The SIGTERM budget reaches past the statement timeout (chaos-F1, 24 Sep
// 2026): with the old flat 8 s and the default 15 s PG_STATEMENT_TIMEOUT_MS, an
// actor stalled in a checkpoint outlived the budget and the hand in play was
// never settled.
func TestTheShutdownBudgetOutlastsTheStatementTimeout(t *testing.T) {
	for _, tc := range []struct {
		statement, want time.Duration
	}{
		{0, 8 * time.Second}, // no statement timeout: Node's 8 s
		{time.Second, 8 * time.Second},
		{3 * time.Second, 8 * time.Second},
		{15 * time.Second, 20 * time.Second}, // the default
		{60 * time.Second, 65 * time.Second},
	} {
		got := shutdownBudgetFor(tc.statement)
		if got != tc.want {
			t.Errorf("statement timeout %v: budget %v, want %v", tc.statement, got, tc.want)
		}
		if tc.statement > 0 && got <= tc.statement {
			t.Errorf("statement timeout %v: budget %v does not outlast it", tc.statement, got)
		}
	}
}

// systemd must not SIGKILL the binary inside its own budget on the default
// statement timeout.
func TestTheUnitStopTimeoutIsAboveTheDefaultShutdownBudget(t *testing.T) {
	unit, err := os.ReadFile("../../ops/gameplay-go.service")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^TimeoutStopSec=(\d+)$`).FindSubmatch(unit)
	if m == nil {
		t.Fatal("no TimeoutStopSec in the unit")
	}
	secs, _ := strconv.Atoi(string(m[1]))
	if budget := shutdownBudgetFor(15 * time.Second); time.Duration(secs)*time.Second <= budget {
		t.Fatalf("TimeoutStopSec=%d is not above the default shutdown budget %v", secs, budget)
	}
}
