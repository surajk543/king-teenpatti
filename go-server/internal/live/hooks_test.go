package live

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

type observed struct {
	op  string
	err error
}

func TestWithHooksObservesEveryCall(t *testing.T) {
	ctx := context.Background()
	var (
		mu   sync.Mutex
		seen []observed
		durs []time.Duration
	)
	inner := NewMemory()
	store := WithHooks(inner, Hooks{Observe: func(op string, err error, d time.Duration) {
		mu.Lock()
		defer mu.Unlock()
		seen = append(seen, observed{op, err})
		durs = append(durs, d)
	}})
	if store.Kind() != "memory" {
		t.Fatalf("Kind passthrough = %q", store.Kind())
	}
	if u, ok := store.(interface{ Unwrap() Store }); !ok || u.Unwrap() != inner {
		t.Fatal("Unwrap must return the decorated store")
	}

	must(t, store.SaveTable(ctx, "r", 1, []byte("x"), time.Hour))
	stale := store.SaveTable(ctx, "r", 1, []byte("x"), time.Hour)
	_, _, _ = store.LoadTable(ctx, "r")
	_, _, _ = store.LoadTable(ctx, "missing")
	must(t, store.DeleteTable(ctx, "r"))
	_, _ = store.ListTables(ctx)
	must(t, store.AppendChat(ctx, "r", []byte("m"), 5))
	_, _ = store.LoadChat(ctx, "r")
	must(t, store.DeleteChat(ctx, "r"))
	must(t, store.SetSeated(ctx, "u", "r"))
	_, _ = store.SeatOf(ctx, "u")
	must(t, store.ClearSeated(ctx, "u"))
	must(t, store.SetOnline(ctx, "u", "i", time.Minute))
	_, _ = store.OnlineCount(ctx)
	must(t, store.SetOffline(ctx, "u"))
	must(t, store.PutResumeOffer(ctx, "u", ResumeOffer{RoomID: "r"}, time.Minute))
	_, _ = store.TakeResumeOffer(ctx, "u")
	must(t, store.DeleteResumeOffer(ctx, "u"))
	must(t, store.PublishTable(ctx, TableSummary{RoomID: "r", Category: "blind", BootAmount: 200}))
	_, _ = store.Candidates(ctx, "blind", 200)
	must(t, store.RetireTable(ctx, "r", "blind", 200))
	must(t, store.Ping(ctx))
	must(t, store.Close())

	if !errors.Is(stale, ErrStale) {
		t.Fatalf("decorator changed the result: %v", stale)
	}
	wantOps := []string{
		"save_table", "save_table", "load_table", "load_table", "delete_table", "list_tables",
		"append_chat", "load_chat", "delete_chat",
		"set_seated", "seat_of", "clear_seated", "set_online", "online_count", "set_offline",
		"put_resume_offer", "take_resume_offer", "delete_resume_offer",
		"publish_table", "candidates", "retire_table", "ping", "close",
	}
	mu.Lock()
	defer mu.Unlock()
	ops := make([]string, len(seen))
	for i, o := range seen {
		ops[i] = o.op
	}
	if !reflect.DeepEqual(ops, wantOps) {
		t.Fatalf("observed ops\n got %s\nwant %s", strings.Join(ops, " "), strings.Join(wantOps, " "))
	}
	// Errors are reported as returned: the stale save and the missing load.
	if !errors.Is(seen[1].err, ErrStale) || !errors.Is(seen[3].err, ErrNotFound) {
		t.Fatalf("errors not passed through: %v / %v", seen[1].err, seen[3].err)
	}
	for i, o := range seen {
		if i == 1 || i == 3 {
			continue
		}
		if o.err != nil {
			t.Fatalf("%s reported %v", o.op, o.err)
		}
	}
	for i, d := range durs {
		if d < 0 {
			t.Fatalf("negative duration for %s", seen[i].op)
		}
	}
	// Every Store method except Kind was called above and observed under its
	// own name, so none is left to the embedded (unobserved) forwarder.
	storeType := reflect.TypeOf((*Store)(nil)).Elem()
	if got, want := len(uniq(wantOps)), storeType.NumMethod()-1; got != want {
		t.Fatalf("test exercises %d distinct ops, Store has %d observable methods", got, want)
	}
}

func uniq(ss []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range ss {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func TestWithHooksNilObserveReturnsStore(t *testing.T) {
	inner := NewMemory()
	defer inner.Close()
	if got := WithHooks(inner, Hooks{}); got != inner {
		t.Fatalf("WithHooks with no Observe returned %T, want the store itself", got)
	}
}
