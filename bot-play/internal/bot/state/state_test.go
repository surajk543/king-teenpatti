package state

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestTheLifecycleTransitionsAreLoggedAndUnexpectedOnesWarned(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, nil))
	var seen []string
	m := NewMachine(log, func() time.Time { return time.Unix(0, 0) }, func(from, to State) { seen = append(seen, string(from)+">"+string(to)) })
	for _, s := range []State{Connecting, Online, SearchingTable, JoiningTable, WaitingForHand, Playing, WaitingForAction, Playing, ProcessingResult, WaitingForHand, SwitchingTable, Playing} {
		m.To(s, "table", "seen:200")
	}
	if m.Current() != Playing || len(seen) != 12 {
		t.Fatalf("current %s after %d transitions", m.Current(), len(seen))
	}
	if strings.Contains(buf.String(), "unexpected") {
		t.Fatalf("an expected lifecycle logged as unexpected:\n%s", buf.String())
	}
	m.To(Playing) // no-op
	if len(seen) != 12 {
		t.Fatal("a same-state To is not a transition")
	}
	m.To(Resting) // Playing → Resting skips leaving the table
	if !strings.Contains(buf.String(), "unexpected") || m.Current() != Resting {
		t.Fatal("an unexpected transition is warned and still made")
	}
}

func TestEveryStateCanStop(t *testing.T) {
	for from := range allowed {
		if from != Stopping && from != Offline && !Allowed(from, Stopping) {
			t.Errorf("%s cannot move to STOPPING", from)
		}
	}
}
