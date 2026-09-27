package config

import (
	"testing"
	"time"
)

// Report Player's limits are env keys (owner, 27 Sep 2026: "Make the limits
// configurable"; "a player may submit at most 2 reports in any 24 hours"),
// and a figure the server could not enforce stops the boot.
func TestTheReportLimitsAreConfigurable(t *testing.T) {
	def := mustLoad(t, map[string]string{})
	want := ReportConfig{MaxPerReporter: 2, Window: 24 * time.Hour, PairWindow: 24 * time.Hour, DescriptionMax: 500,
		Recent: 10 * time.Minute, AttemptLimit: 10, AttemptWindow: time.Minute}
	if def.Reports != want {
		t.Fatalf("defaults %+v, want %+v", def.Reports, want)
	}
	got := mustLoad(t, map[string]string{
		"REPORT_MAX_PER_REPORTER": "5", "REPORT_WINDOW_MS": "3600000", "REPORT_PAIR_WINDOW_MS": "0",
		"REPORT_DESCRIPTION_MAX": "2000", "REPORT_RECENT_MS": "0", "REPORT_ATTEMPT_LIMIT": "0", "REPORT_ATTEMPT_WINDOW_MS": "0",
	})
	if got.Reports != (ReportConfig{MaxPerReporter: 5, Window: time.Hour, DescriptionMax: 2000}) {
		t.Fatalf("configured %+v", got.Reports)
	}
	if off := mustLoad(t, map[string]string{"REPORT_MAX_PER_REPORTER": "0", "REPORT_WINDOW_MS": "0"}); off.Reports.MaxPerReporter != 0 {
		t.Fatalf("no per-reporter limit needs no window: %+v", off.Reports)
	}
	for _, bad := range []map[string]string{
		{"REPORT_MAX_PER_REPORTER": "-1"},
		{"REPORT_WINDOW_MS": "0"},
		{"REPORT_WINDOW_MS": "-5"},
		{"REPORT_PAIR_WINDOW_MS": "-1"},
		{"REPORT_DESCRIPTION_MAX": "0"},
		{"REPORT_DESCRIPTION_MAX": "2001"},
		{"REPORT_RECENT_MS": "-1"},
		{"REPORT_ATTEMPT_LIMIT": "-2"},
		{"REPORT_ATTEMPT_WINDOW_MS": "0"},
		{"REPORT_MAX_PER_REPORTER": "two"},
	} {
		if _, err := FromEnv(env(bad)); err == nil {
			t.Errorf("%v was accepted", bad)
		}
	}
}
