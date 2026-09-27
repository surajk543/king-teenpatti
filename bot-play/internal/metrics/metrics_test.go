package metrics

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/state"
)

// sample is one gathered series: its labels (service included) and value
// (a histogram's sample count).
type sample struct {
	labels map[string]string
	value  float64
}

func gather(t *testing.T, reg *prometheus.Registry) map[string][]sample {
	t.Helper()
	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("Gather: %v", err)
	}
	out := map[string][]sample{}
	for _, f := range families {
		for _, m := range f.GetMetric() {
			s := sample{labels: map[string]string{}}
			for _, l := range m.GetLabel() {
				s.labels[l.GetName()] = l.GetValue()
			}
			switch {
			case m.GetCounter() != nil:
				s.value = m.GetCounter().GetValue()
			case m.GetGauge() != nil:
				s.value = m.GetGauge().GetValue()
			case m.GetHistogram() != nil:
				s.value = float64(m.GetHistogram().GetSampleCount())
			}
			out[f.GetName()] = append(out[f.GetName()], s)
		}
	}
	return out
}

// value is the named series whose labels include want (0 when absent).
func value(t *testing.T, m *Metrics, name string, want map[string]string) float64 {
	t.Helper()
	for _, s := range gather(t, m.Registry())[name] {
		match := true
		for k, v := range want {
			if s.labels[k] != v {
				match = false
			}
		}
		if match && len(s.labels) == len(want)+1 { // + service
			return s.value
		}
	}
	return 0
}

func TestANilMetricsIsSilent(t *testing.T) {
	var m *Metrics
	m.Connected()
	m.Disconnected("x")
	m.TableJoin("seen")
	m.TableLeave("MAX_HANDS")
	m.HandStarted("seen")
	m.HandCompleted("seen", "win")
	m.Action("chaal", true)
	m.Refused("invalid_bet")
	m.Reconnect("ok")
	m.DecisionLatency(time.Millisecond)
	m.ReactionDelay("chaal", time.Second)
	m.State(state.Offline, state.Connecting)
	m.Track(state.Offline)
	m.Untrack(state.Offline)
	m.Chat("win")
	if m.Registry() != nil {
		t.Error("a nil Metrics has a registry")
	}
}

func TestEveryMetricIsRegisteredUnderItsName(t *testing.T) {
	m := New()
	m.Connected()
	m.Disconnected("transport close")
	m.TableJoin("seen")
	m.TableLeave("MAX_HANDS")
	m.HandStarted("blind")
	m.HandCompleted("blind", "loss")
	m.Action("see", false)
	m.Refused("not_your_turn")
	m.Reconnect("ok")
	m.DecisionLatency(300 * time.Microsecond)
	m.ReactionDelay("chaal", 2*time.Second)
	m.Track(state.Offline)
	m.State(state.Offline, state.Connecting)
	m.Chat("win")

	got := gather(t, m.Registry())
	for _, name := range []string{
		"bot_connected", "bot_disconnected_total", "bot_table_join_total", "bot_table_leave_total",
		"bot_hand_started_total", "bot_hand_completed_total", "bot_action_total", "bot_refused_total",
		"bot_reconnect_total", "bot_decision_latency_seconds", "bot_reaction_delay_seconds", "bot_state",
		"bot_state_transitions_total", "bot_chat_total", "go_goroutines",
	} {
		if len(got[name]) == 0 {
			t.Errorf("%s is not exposed", name)
		}
	}
	for name, series := range got {
		for _, s := range series {
			if s.labels["service"] != "bot-play" {
				t.Errorf("%s%v lacks service=\"bot-play\"", name, s.labels)
			}
		}
	}
}

func TestCountersCarryTheirLabels(t *testing.T) {
	m := New()
	m.TableJoin("variation")
	m.TableJoin("variation")
	m.TableLeave("STOP_LOSS")
	m.HandStarted("seen")
	m.HandCompleted("seen", "fold")
	m.Action("raise", false)
	m.Action("chaal", true)
	m.Action("chaal", true)
	m.Refused("invalid_bet")
	m.Reconnect("failed")
	m.Chat("big_win")

	checks := []struct {
		name   string
		labels map[string]string
		want   float64
	}{
		{"bot_table_join_total", map[string]string{"category": "variation"}, 2},
		{"bot_table_join_total", map[string]string{"category": "blind"}, 0},
		{"bot_table_leave_total", map[string]string{"reason": "STOP_LOSS"}, 1},
		{"bot_hand_started_total", map[string]string{"category": "seen"}, 1},
		{"bot_hand_completed_total", map[string]string{"category": "seen", "result": "fold"}, 1},
		{"bot_action_total", map[string]string{"action": "raise", "blind": "false"}, 1},
		{"bot_action_total", map[string]string{"action": "chaal", "blind": "true"}, 2},
		{"bot_refused_total", map[string]string{"code": "invalid_bet"}, 1},
		{"bot_reconnect_total", map[string]string{"result": "failed"}, 1},
		{"bot_chat_total", map[string]string{"moment": "big_win"}, 1},
	}
	for _, c := range checks {
		if got := value(t, m, c.name, c.labels); got != c.want {
			t.Errorf("%s%v = %v, want %v", c.name, c.labels, got, c.want)
		}
	}
}

func TestSeriesADashboardRatesExistFromTheStart(t *testing.T) {
	m := New()
	got := gather(t, m.Registry())
	if n := len(got["bot_state"]); n != len(states) {
		t.Errorf("bot_state has %d series at start, want one per state (%d)", n, len(states))
	}
	if n := len(got["bot_hand_completed_total"]); n != len(categories)*len(results) {
		t.Errorf("bot_hand_completed_total has %d series at start, want %d", n, len(categories)*len(results))
	}
}

func TestTheConnectionGauge(t *testing.T) {
	m := New()
	m.Connected()
	m.Connected()
	m.Disconnected("transport close")
	if got := value(t, m, "bot_connected", nil); got != 1 {
		t.Errorf("bot_connected = %v, want 1", got)
	}
	if got := value(t, m, "bot_disconnected_total", map[string]string{"reason": "transport_close"}); got != 1 {
		t.Errorf("bot_disconnected_total{transport_close} = %v, want 1", got)
	}
}

func TestTheStateGaugeCountsBotsPerState(t *testing.T) {
	m := New()
	for range 3 {
		m.Track(state.Offline)
	}
	m.State(state.Offline, state.Connecting)
	m.State(state.Connecting, state.Online)
	m.State(state.Offline, state.Connecting)
	m.State(state.Online, state.Online) // no change, no transition
	want := map[state.State]float64{state.Offline: 1, state.Connecting: 1, state.Online: 1, state.Playing: 0}
	for s, n := range want {
		if got := value(t, m, "bot_state", map[string]string{"state": string(s)}); got != n {
			t.Errorf("bot_state{%s} = %v, want %v", s, got, n)
		}
	}
	if got := value(t, m, "bot_state_transitions_total", map[string]string{"from": "OFFLINE", "to": "CONNECTING"}); got != 2 {
		t.Errorf("transitions OFFLINE→CONNECTING = %v, want 2", got)
	}
	if got := value(t, m, "bot_state_transitions_total", map[string]string{"from": "ONLINE", "to": "ONLINE"}); got != 0 {
		t.Errorf("a no-op transition was counted: %v", got)
	}
	m.Untrack(state.Online)
	if got := value(t, m, "bot_state", map[string]string{"state": "ONLINE"}); got != 0 {
		t.Errorf("after Untrack bot_state{ONLINE} = %v", got)
	}
	// A Machine's hook drives it.
	mc := state.NewMachine(nil, nil, m.State)
	m.Track(mc.Current())
	mc.To(state.Connecting)
	if got := value(t, m, "bot_state", map[string]string{"state": "CONNECTING"}); got != 2 {
		t.Errorf("through a Machine bot_state{CONNECTING} = %v, want 2", got)
	}
}

func TestHistograms(t *testing.T) {
	m := New()
	m.DecisionLatency(300 * time.Microsecond)
	m.DecisionLatency(-time.Second) // counted as 0
	m.ReactionDelay("chaal", 2*time.Second)
	m.ReactionDelay("chaal", 24*time.Second)
	if got := value(t, m, "bot_decision_latency_seconds", nil); got != 2 {
		t.Errorf("decision samples = %v, want 2", got)
	}
	if got := value(t, m, "bot_reaction_delay_seconds", map[string]string{"kind": "chaal"}); got != 2 {
		t.Errorf("reaction samples = %v, want 2", got)
	}
	families, _ := m.Registry().Gather()
	for _, f := range families {
		if f.GetName() != "bot_reaction_delay_seconds" {
			continue
		}
		buckets := f.GetMetric()[0].GetHistogram().GetBucket()
		if top := buckets[len(buckets)-1].GetUpperBound(); top != 25 {
			t.Errorf("the reaction histogram's top bucket is %v s, want 25 (the turn clock)", top)
		}
		for _, b := range buckets {
			if b.GetUpperBound() == 25 && b.GetCumulativeCount() != 2 {
				t.Errorf("24 s did not land under 25 s")
			}
		}
	}
}

// No id, name or free text ever becomes a label value, whatever a caller
// passes.
func TestIDsAndNamesNeverBecomeLabels(t *testing.T) {
	m := New()
	bad := []string{
		"botplay-000001", "3f2a9c1e-7b1d-4c8e-9f00-0123456789ab", "AB12CD34", "room:ab12cd34",
		"Guest0E00B", "Ravi Kumar", "seen:200", "variation:50000", "insufficient chips: you have 1,000",
		strings.Repeat("a", maxLabelLen+1), "<script>", "ümlaut",
	}
	for _, s := range bad {
		m.Disconnected(s)
		m.TableJoin(s)
		m.TableLeave(s)
		m.HandStarted(s)
		m.HandCompleted(s, s)
		m.Action(s, false)
		m.Refused(s)
		m.Reconnect(s)
		m.ReactionDelay(s, time.Second)
		m.Track(state.State(s))
		m.State(state.State(s), state.Offline)
		m.Chat(s)
	}
	for name, series := range gather(t, m.Registry()) {
		if !strings.HasPrefix(name, "bot_") {
			continue
		}
		for _, sm := range series {
			for k, v := range sm.labels {
				if k == "service" {
					continue
				}
				if slices.Contains(bad, v) || strings.ContainsAny(v, "0123456789-: <") {
					t.Errorf("%s{%s=%q}: an id or text became a label", name, k, v)
				}
			}
		}
	}
	if got := value(t, m, "bot_refused_total", map[string]string{"code": Other}); got != float64(len(bad)) {
		t.Errorf("bot_refused_total{other} = %v, want %d", got, len(bad))
	}
}

func TestALearningLabelIsCapped(t *testing.T) {
	m := New()
	for i := range 3 * maxLearned {
		m.Refused("code_" + strings.Repeat(string(rune('a'+i%26)), 1+i/26))
	}
	m.Refused("")
	values := map[string]bool{}
	for _, s := range gather(t, m.Registry())["bot_refused_total"] {
		values[s.labels["code"]] = true
	}
	if len(values) > maxLearned+2 { // + other + none
		t.Errorf("bot_refused_total has %d code values, want at most %d", len(values), maxLearned+2)
	}
	if !values[Other] || !values[None] {
		t.Errorf("past the cap values are %q and an empty code is %q; got %v", Other, None, values)
	}
	// Fixed vocabularies never learn.
	m.TableJoin("poker")
	if got := value(t, m, "bot_table_join_total", map[string]string{"category": Other}); got != 1 {
		t.Errorf("an unknown category is not %q", Other)
	}
}

func TestLabelsAreSafeUnderConcurrency(t *testing.T) {
	m := New()
	var wg sync.WaitGroup
	for g := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range 200 {
				m.Refused(fmt.Sprintf("code_%c", 'a'+(g*200+i)%26))
				m.Action("chaal", i%2 == 0)
				m.State(state.Offline, state.Connecting)
			}
		}()
	}
	wg.Wait()
	if got := value(t, m, "bot_state_transitions_total", map[string]string{"from": "OFFLINE", "to": "CONNECTING"}); got != 1600 {
		t.Errorf("transitions = %v, want 1600", got)
	}
}

func TestTheLabelVocabulary(t *testing.T) {
	v := newVocab(true, "forceSideshow")
	cases := map[string]string{
		"forceSideshow":        "forceSideshow", // fixed, whatever its case
		"io server disconnect": "io_server_disconnect",
		"  MAX_HANDS ":         "MAX_HANDS",
		"":                     None,
		"   ":                  None,
		"camelCase":            Other, // mixed case is refused unless fixed
		"with-hyphen":          Other,
		"digits1":              Other,
	}
	for in, want := range cases {
		if got := v.label(in); got != want {
			t.Errorf("label(%q) = %q, want %q", in, got, want)
		}
	}
	if !regexp.MustCompile(`^[a-z_]+$`).MatchString(None + Other) {
		t.Error("None and Other must themselves be plain words")
	}
}
