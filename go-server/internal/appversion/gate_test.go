package appversion

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// rows is a Loader over a configuration a test changes as an operator would.
type rows struct {
	mu    sync.Mutex
	cfg   Config
	err   error
	reads atomic.Int64
}

func (r *rows) Load(context.Context) (Config, error) {
	r.reads.Add(1)
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.cfg, r.err
}

func (r *rows) set(cfg Config, err error) {
	r.mu.Lock()
	r.cfg, r.err = cfg, err
	r.mu.Unlock()
}

func withMinimum(min string) Config {
	return Config{Platforms: map[string]PlatformConfig{
		PlatformAndroid: {Status: StatusNormal, MinimumVersion: MustParse(min), StoreURL: "https://play.example/kt"},
	}}
}

// An operator's change is enforced within the TTL, with no restart — and the
// table is read once per TTL however busy the server is.
func TestAnOperatorsChangeIsEnforcedWithinTheCacheTTL(t *testing.T) {
	clock := &fakeClock{now: time.UnixMilli(1_790_000_000_000)}
	store := &rows{cfg: withMinimum("1.5.0")}
	gate := NewGate(GateOptions{Source: NewSource(store, 15*time.Second, clock.Now, nil), Now: clock.Now})
	ctx := context.Background()
	old := NewClient("android", "1.5.0")

	if _, ok := gate.Admit(ctx, old, ViaREST, "/api/auth/me"); !ok {
		t.Fatal("1.5.0 against a 1.5.0 minimum was refused")
	}
	for range 100 {
		gate.Admit(ctx, old, ViaREST, "/api/auth/me")
	}
	if n := store.reads.Load(); n != 1 {
		t.Fatalf("%d reads within the TTL, want 1", n)
	}

	// Production raises the minimum: current 1.5.0 → 1.6.0.
	store.set(withMinimum("1.6.0"), nil)
	clock.Advance(10 * time.Second)
	if _, ok := gate.Admit(ctx, old, ViaREST, "/api/auth/me"); !ok {
		t.Fatal("the cached minimum was not what was served inside the TTL")
	}
	clock.Advance(6 * time.Second)
	if v, ok := gate.Admit(ctx, old, ViaREST, "/api/auth/me"); ok || v.Status != StatusForceUpdate {
		t.Fatalf("1.5.0 after the minimum rose to 1.6.0: %s %v", v.Status, ok)
	}
	if _, ok := gate.Admit(ctx, NewClient("android", "1.6.0"), ViaREST, "/api/auth/me"); !ok {
		t.Fatal("1.6.0 against a 1.6.0 minimum was refused")
	}
	if n := store.reads.Load(); n != 2 {
		t.Fatalf("%d reads, want 2", n)
	}
}

// A failed read keeps the configuration last read; before any read has
// succeeded the gate is open.
func TestAFailedReadKeepsTheLastConfigurationAndAFirstOneFailsOpen(t *testing.T) {
	clock := &fakeClock{now: time.UnixMilli(1_790_000_000_000)}
	var logs bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&logs, nil))
	store := &rows{err: errors.New("database down")}
	source := NewSource(store, time.Second, clock.Now, log)
	ctx := context.Background()

	if cfg := source.Current(ctx); len(cfg.Platforms) != 0 {
		t.Fatalf("a first read that failed served %+v, want the open configuration", cfg)
	}
	store.set(withMinimum("1.6.0"), nil)
	if cfg := source.Current(ctx); cfg.For(PlatformAndroid).MinimumVersion != MustParse("1.6.0") {
		t.Fatalf("after the database came back: %+v", cfg)
	}
	store.set(Config{}, errors.New("database down again"))
	clock.Advance(2 * time.Second)
	for range 3 {
		if cfg := source.Current(ctx); cfg.For(PlatformAndroid).MinimumVersion != MustParse("1.6.0") {
			t.Fatalf("a failed read dropped the last configuration: %+v", cfg)
		}
	}
	if n := strings.Count(logs.String(), "app version config read failed"); n != 2 {
		t.Errorf("%d WARN lines for two failure streaks, want 2:\n%s", n, logs.String())
	}
}

func TestATTLOfZeroReadsEveryTimeAndInvalidateForcesARead(t *testing.T) {
	store := &rows{cfg: withMinimum("1.0.0")}
	source := NewSource(store, 0, nil, nil)
	for range 3 {
		source.Current(context.Background())
	}
	if n := store.reads.Load(); n != 3 {
		t.Errorf("ttl 0: %d reads, want 3", n)
	}
	cached := NewSource(store, time.Hour, nil, nil)
	cached.Current(context.Background())
	cached.Invalidate()
	store.set(withMinimum("2.0.0"), nil)
	if cfg := cached.Current(context.Background()); cfg.For(PlatformAndroid).MinimumVersion != MustParse("2.0.0") {
		t.Errorf("after Invalidate: %+v", cfg)
	}
}

// Every refusal is counted by platform, state and door, and logged once a
// minute per kind — with the event names the brief asked for, the platform,
// the version and the minimum, and nothing about the player.
func TestRefusalsAreCountedAndLoggedWithoutFlooding(t *testing.T) {
	clock := &fakeClock{now: time.UnixMilli(1_790_000_000_000)}
	var logs bytes.Buffer
	var mu sync.Mutex
	rejected := map[string]int{}
	checked := map[string]int{}
	cfg := withMinimum("1.6.0")
	android := cfg.Platforms[PlatformAndroid]
	android.LatestVersion = MustParse("1.7.0")
	cfg.Platforms[PlatformAndroid] = android
	gate := NewGate(GateOptions{
		Source: NewSource(&rows{cfg: cfg}, time.Minute, clock.Now, nil),
		Logger: slog.New(slog.NewJSONHandler(&logs, nil)),
		Now:    clock.Now,
		Hooks: Hooks{
			Rejected: func(platform, status, via string) {
				mu.Lock()
				rejected[platform+"/"+status+"/"+via]++
				mu.Unlock()
			},
			Checked: func(platform, status string) {
				mu.Lock()
				checked[platform+"/"+status]++
				mu.Unlock()
			},
		},
	})
	ctx := context.Background()
	old := NewClient("android", "1.5.0")
	for range 5 {
		gate.Admit(ctx, old, ViaREST, "/api/auth/me")
	}
	gate.Admit(ctx, old, ViaSocket, "handshake")
	gate.Check(ctx, old)
	gate.Check(ctx, NewClient("android", "1.6.5"))
	gate.Check(ctx, NewClient("android", "1.7.0"))
	if _, ok := gate.Admit(ctx, NewClient("bot", ""), ViaSocket, "handshake"); !ok {
		t.Fatal("a bot was refused")
	}

	if rejected["android/FORCE_UPDATE/rest"] != 5 || rejected["android/FORCE_UPDATE/socket"] != 1 || len(rejected) != 2 {
		t.Errorf("rejections counted: %v", rejected)
	}
	if checked["android/FORCE_UPDATE"] != 1 || checked["android/SOFT_UPDATE"] != 1 || checked["android/NORMAL"] != 1 {
		t.Errorf("checks counted: %v", checked)
	}
	out := logs.String()
	for event, want := range map[string]int{
		EventForceRejected: 1, EventWebSocketRejected: 1, EventCheck: 2, EventSoftUpdate: 1,
	} {
		if n := strings.Count(out, `"event":"`+event+`"`); n != want {
			t.Errorf("%s logged %d times, want %d:\n%s", event, n, want, out)
		}
	}
	for _, field := range []string{`"platform":"android"`, `"appVersion":"1.5.0"`, `"minimumVersion":"1.6.0"`, `"endpoint":"/api/auth/me"`, `"endpoint":"handshake"`} {
		if !strings.Contains(out, field) {
			t.Errorf("the logs lack %s:\n%s", field, out)
		}
	}
	clock.Advance(61 * time.Second)
	gate.Admit(ctx, old, ViaREST, "/api/auth/me")
	if n := strings.Count(logs.String(), `"event":"`+EventForceRejected+`"`); n != 2 {
		t.Errorf("a minute later the refusal is logged again: %d lines", n)
	}
}

func TestANilGateAdmitsEveryoneAndHasNoFloor(t *testing.T) {
	var g *Gate
	if v, ok := g.Admit(context.Background(), NewClient("android", "0.0.1"), ViaREST, ""); !ok || v.Status != StatusNormal {
		t.Errorf("a nil gate: %s %v", v.Status, ok)
	}
	if n := g.MinClientBuild(context.Background(), Client{}, 3); n != 3 {
		t.Errorf("a nil gate's build floor: %d", n)
	}
	if g.Required() {
		t.Error("a nil gate requires nothing")
	}
}
