package live

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

// shiftedClock lets a test move the Redis store's process clock forward in
// step with miniredis.FastForward, so presence expiry stamps and key ttls
// age together.
type shiftedClock struct{ offset atomic.Int64 }

func (c *shiftedClock) Now() time.Time          { return time.Now().Add(time.Duration(c.offset.Load())) }
func (c *shiftedClock) Advance(d time.Duration) { c.offset.Add(int64(d)) }

func randomPrefix(t *testing.T) string {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatal(err)
	}
	return "t" + hex.EncodeToString(b[:]) + ":"
}

func openRedisStore(t *testing.T, url, prefix string) *Redis {
	t.Helper()
	store, err := OpenRedis(context.Background(), Options{URL: url, KeyPrefix: prefix, Timeout: 2 * time.Second})
	if err != nil {
		t.Fatalf("OpenRedis(%s): %v", url, err)
	}
	r, ok := store.(*Redis)
	if !ok {
		t.Fatalf("OpenRedis returned %T", store)
	}
	t.Cleanup(func() { _ = r.Close() })
	return r
}

// ---- miniredis (in-process) -------------------------------------------------

func newMiniredisHarness(t *testing.T) *harness {
	m := miniredis.RunT(t)
	r := openRedisStore(t, "redis://"+m.Addr(), "t:")
	clock := &shiftedClock{}
	r.now = clock.Now
	return &harness{
		store: r,
		kind:  "redis",
		ttl:   time.Hour,
		advance: func(d time.Duration) {
			m.FastForward(d)
			clock.Advance(d)
		},
	}
}

func TestMiniredisConformance(t *testing.T) {
	runConformance(t, newMiniredisHarness)
}

// The key layout is the contract with operators and with LIVE_STATE_PLAN.md.
func TestRedisKeySchema(t *testing.T) {
	ctx := context.Background()
	m := miniredis.RunT(t)
	r := openRedisStore(t, "redis://"+m.Addr(), "kt:")
	before := time.Now().UnixMilli()

	snap := bigSnapshot("hand-42", 2048)
	must(t, r.SaveTable(ctx, "room1", 9, snap, 24*time.Hour))
	if got := m.HGet("kt:table:room1", "seq"); got != "9" {
		t.Fatalf("kt:table:room1.seq = %q", got)
	}
	if got := m.HGet("kt:table:room1", "snapshot"); got != string(snap) {
		t.Fatalf("kt:table:room1.snapshot differs (%d vs %d bytes)", len(got), len(snap))
	}
	if got := m.HGet("kt:table:room1", "handId"); got != "hand-42" {
		t.Fatalf("kt:table:room1.handId = %q, want hand-42", got)
	}
	updated, err := strconv.ParseInt(m.HGet("kt:table:room1", "updatedAt"), 10, 64)
	if err != nil || updated < before || updated > time.Now().UnixMilli() {
		t.Fatalf("kt:table:room1.updatedAt = %q (err %v), want epoch ms around now", m.HGet("kt:table:room1", "updatedAt"), err)
	}
	if ttl := m.TTL("kt:table:room1"); ttl <= 23*time.Hour || ttl > 24*time.Hour {
		t.Fatalf("kt:table:room1 ttl = %v, want ≈24h", ttl)
	}
	members, err := m.SMembers("kt:tables")
	must(t, err)
	if strings.Join(members, ",") != "room1" {
		t.Fatalf("kt:tables = %v, want [room1]", members)
	}
	// A table between hands stores an empty handId.
	must(t, r.SaveTable(ctx, "room2", 1, []byte(`{"roomId":"room2","hand":null}`), time.Hour))
	if got := m.HGet("kt:table:room2", "handId"); got != "" {
		t.Fatalf("handId between hands = %q, want empty", got)
	}
	// ttl <= 0 means no expiry.
	must(t, r.SaveTable(ctx, "room3", 1, []byte("x"), 0))
	if ttl := m.TTL("kt:table:room3"); ttl != 0 {
		t.Fatalf("kt:table:room3 ttl = %v, want none", ttl)
	}

	must(t, r.AppendChat(ctx, "room1", []byte(`{"text":"hi"}`), 100))
	list, err := m.List("kt:chat:room1")
	must(t, err)
	if len(list) != 1 || list[0] != `{"text":"hi"}` {
		t.Fatalf("kt:chat:room1 = %v", list)
	}
	if ttl := m.TTL("kt:chat:room1"); ttl <= 0 {
		t.Fatal("chat list has no safety-net ttl")
	}

	must(t, r.SetSeated(ctx, "user1", "room1"))
	if got, _ := m.Get("kt:seat:user1"); got != "room1" {
		t.Fatalf("kt:seat:user1 = %q", got)
	}
	if ttl := m.TTL("kt:seat:user1"); ttl != 0 {
		t.Fatalf("seat key has a ttl (%v); it must be cleared explicitly", ttl)
	}

	must(t, r.SetOnline(ctx, "user1", "host:123", 90*time.Second))
	value := m.HGet("kt:online", "user1")
	inst, stamp, ok := strings.Cut(value, "|")
	if !ok || inst != "host:123" {
		t.Fatalf("kt:online.user1 = %q, want host:123|<expiresAtMs>", value)
	}
	expires, err := strconv.ParseInt(stamp, 10, 64)
	must(t, err)
	if lo, hi := before+90_000, time.Now().UnixMilli()+90_000; expires < lo || expires > hi {
		t.Fatalf("expiry stamp %d not within [%d, %d] (now + ttl)", expires, lo, hi)
	}

	must(t, r.PutResumeOffer(ctx, "user1", ResumeOffer{RoomID: "room1", Code: "ABCD", Category: "seen", BootAmount: 200, At: 5}, 10*time.Minute))
	raw, _ := m.Get("kt:resume:user1")
	if raw != `{"roomId":"room1","code":"ABCD","category":"seen","bootAmount":200,"at":5}` {
		t.Fatalf("kt:resume:user1 = %s", raw)
	}
	if ttl := m.TTL("kt:resume:user1"); ttl <= 9*time.Minute || ttl > 10*time.Minute {
		t.Fatalf("kt:resume:user1 ttl = %v, want ≈10m", ttl)
	}

	must(t, r.PublishTable(ctx, TableSummary{RoomID: "room1", Code: "ABCD", Category: "blind", BootAmount: 5000,
		Players: 3, MaxPlayers: 5, State: "betting", CreatedAt: 1234, Instance: "host:123"}))
	must(t, r.PublishTable(ctx, TableSummary{RoomID: "priv", Code: "PRIV", Category: "blind", BootAmount: 5000,
		Players: 4, MaxPlayers: 5, IsPrivate: true, State: "waiting", CreatedAt: 1, Instance: "host:123"}))
	score, err := m.ZScore("kt:lobby:blind:5000", "room1")
	must(t, err)
	if score != 3 {
		t.Fatalf("kt:lobby:blind:5000 room1 score = %v, want 3 (players)", score)
	}
	if zHas(t, m, "kt:lobby:blind:5000", "priv") {
		t.Fatal("private table was indexed in the lobby zset")
	}
	if !m.Exists("kt:summary:priv") {
		t.Fatal("private table has no summary hash (it should — only the index excludes it)")
	}
	want := map[string]string{"roomId": "room1", "code": "ABCD", "category": "blind", "bootAmount": "5000",
		"players": "3", "maxPlayers": "5", "isPrivate": "0", "state": "betting", "createdAt": "1234", "instance": "host:123"}
	for field, v := range want {
		if got := m.HGet("kt:summary:room1", field); got != v {
			t.Fatalf("kt:summary:room1.%s = %q, want %q", field, got, v)
		}
	}
	must(t, r.RetireTable(ctx, "room1", "blind", 5000))
	if m.Exists("kt:summary:room1") {
		t.Fatal("summary survived RetireTable")
	}
	if zHas(t, m, "kt:lobby:blind:5000", "room1") {
		t.Fatal("zset member survived RetireTable")
	}

	must(t, r.DeleteTable(ctx, "room1"))
	if m.Exists("kt:table:room1") {
		t.Fatal("hash survived DeleteTable")
	}
	members, _ = m.SMembers("kt:tables")
	for _, id := range members {
		if id == "room1" {
			t.Fatal("kt:tables still lists room1 after DeleteTable")
		}
	}
	// Chat has its own lifecycle.
	if !m.Exists("kt:chat:room1") {
		t.Fatal("DeleteTable must not delete the chat (DeleteChat does)")
	}

	// Every key carries the prefix.
	for _, k := range m.Keys() {
		if !strings.HasPrefix(k, "kt:") {
			t.Fatalf("unprefixed key %q", k)
		}
	}
}

// zHas reports zset membership (miniredis.ZScore answers 0 for a missing
// member, so it cannot).
func zHas(t *testing.T, m *miniredis.Miniredis, key, member string) bool {
	t.Helper()
	if !m.Exists(key) {
		return false
	}
	members, err := m.ZMembers(key)
	must(t, err)
	for _, got := range members {
		if got == member {
			return true
		}
	}
	return false
}

func TestRedisListTablesRepairsIndex(t *testing.T) {
	ctx := context.Background()
	m := miniredis.RunT(t)
	r := openRedisStore(t, "redis://"+m.Addr(), "kt:")
	must(t, r.SaveTable(ctx, "a", 1, []byte("a"), time.Minute))
	must(t, r.SaveTable(ctx, "b", 2, []byte("b"), time.Hour))
	m.FastForward(2 * time.Minute)
	refs, err := r.ListTables(ctx)
	must(t, err)
	if fmt.Sprint(refs) != fmt.Sprint([]TableRef{{RoomID: "b", Seq: 2}}) {
		t.Fatalf("ListTables = %v, want only b", refs)
	}
	members, _ := m.SMembers("kt:tables")
	if strings.Join(members, ",") != "b" {
		t.Fatalf("kt:tables = %v after repair, want [b]", members)
	}
}

func TestRedisCorruptValues(t *testing.T) {
	ctx := context.Background()
	m := miniredis.RunT(t)
	r := openRedisStore(t, "redis://"+m.Addr(), "kt:")
	m.HSet("kt:table:bad", "seq", "not-a-number", "snapshot", "{}")
	if _, _, err := r.LoadTable(ctx, "bad"); err == nil || errors.Is(err, ErrNotFound) {
		t.Fatalf("corrupt seq: err = %v, want a parse error", err)
	}
	must(t, m.Set("kt:resume:u", "{not json"))
	if _, err := r.TakeResumeOffer(ctx, "u"); err == nil || errors.Is(err, ErrNotFound) {
		t.Fatalf("corrupt offer: err = %v, want a parse error", err)
	}
	if m.Exists("kt:resume:u") {
		t.Fatal("a corrupt offer must still be consumed")
	}
	// A summary hash with junk numbers is listed with zeros, not dropped.
	m.HSet("kt:summary:s", "roomId", "s", "players", "x", "createdAt", "")
	_, err := m.ZAdd("kt:lobby:blind:200", 0, "s")
	must(t, err)
	out, err := r.Candidates(ctx, "blind", 200)
	must(t, err)
	if idsOf(out) != "s" || out[0].Players != 0 {
		t.Fatalf("Candidates with corrupt summary = %+v", out)
	}
	// A zset member without a summary is skipped.
	_, err = m.ZAdd("kt:lobby:blind:200", 5, "ghost")
	must(t, err)
	out, err = r.Candidates(ctx, "blind", 200)
	must(t, err)
	if idsOf(out) != "s" {
		t.Fatalf("ghost member listed: %s", idsOf(out))
	}
}

func TestOpenRedisFailsFast(t *testing.T) {
	ctx := context.Background()
	if _, err := OpenRedis(ctx, Options{URL: "not a url"}); err == nil || !strings.Contains(err.Error(), "invalid REDIS_URL") {
		t.Fatalf("bad URL: err = %v", err)
	}
	if _, err := OpenRedis(ctx, Options{}); err == nil {
		t.Fatal("empty URL must be refused by OpenRedis (Open picks Memory)")
	}
	// A port nobody listens on: must fail within the timeout, not hang.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	must(t, err)
	addr := ln.Addr().String()
	_ = ln.Close()
	start := time.Now()
	_, err = OpenRedis(ctx, Options{URL: "redis://" + addr + "/3", Timeout: 300 * time.Millisecond})
	if err == nil {
		t.Fatal("OpenRedis against a closed port succeeded")
	}
	if !strings.Contains(err.Error(), "unreachable") || !strings.Contains(err.Error(), addr) || !strings.Contains(err.Error(), "db 3") {
		t.Fatalf("error should name the address and db: %v", err)
	}
	if took := time.Since(start); took > 3*time.Second {
		t.Fatalf("OpenRedis took %v to fail", took)
	}
	// Open dispatches on URL.
	m := miniredis.RunT(t)
	store, err := Open(ctx, Options{URL: "redis://" + m.Addr()})
	must(t, err)
	defer store.Close()
	if store.Kind() != "redis" {
		t.Fatalf("Open with URL gave %q", store.Kind())
	}
	r := store.(*Redis)
	if r.prefix != DefaultKeyPrefix || r.timeout != DefaultTimeout {
		t.Fatalf("defaults not applied: prefix=%q timeout=%v", r.prefix, r.timeout)
	}
}

// Each call is bounded by Options.Timeout even when the caller's context has
// no deadline: a server that stops answering yields an error, not a hang.
func TestRedisPerCallTimeout(t *testing.T) {
	// A listener that accepts and never replies stands in for a wedged server.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	must(t, err)
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			t.Cleanup(func() { _ = c.Close() })
		}
	}()
	ro, err := redis.ParseURL("redis://" + ln.Addr().String())
	must(t, err)
	ro.ContextTimeoutEnabled = true
	ro.MaxRetries = 1
	r := &Redis{client: redis.NewClient(ro), prefix: "kt:", timeout: 150 * time.Millisecond, now: time.Now}
	defer r.Close()
	start := time.Now()
	err = r.SaveTable(context.Background(), "r", 1, []byte("x"), time.Hour)
	if err == nil {
		t.Fatal("SaveTable against a silent server succeeded")
	}
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("SaveTable took %v, want ≈150ms", took)
	}
}

// ---- real redis-server -------------------------------------------------------

// realRedisURL returns a URL for a real Redis: REDIS_TEST_URL when set,
// otherwise a redis-server binary started on a free port for this test (and
// killed in Cleanup). Skips the test when neither is available.
func realRedisURL(t *testing.T) string {
	t.Helper()
	if url := os.Getenv("REDIS_TEST_URL"); url != "" {
		return url
	}
	bin := filepath.Join(os.Getenv("HOME"), ".local", "bin", "redis-server")
	if _, err := os.Stat(bin); err != nil {
		if p, err := exec.LookPath("redis-server"); err == nil {
			bin = p
		} else {
			t.Skip("no real redis-server available (set REDIS_TEST_URL or install one)")
		}
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	must(t, err)
	port := strconv.Itoa(ln.Addr().(*net.TCPAddr).Port)
	_ = ln.Close()

	cmd := exec.Command(bin, "--port", port, "--bind", "127.0.0.1", "--save", "", "--appendonly", "no",
		"--daemonize", "no", "--loglevel", "warning")
	cmd.Dir = t.TempDir()
	if err := cmd.Start(); err != nil {
		t.Skipf("cannot start %s: %v", bin, err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	url := "redis://127.0.0.1:" + port + "/0"
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for {
		st, err := OpenRedis(ctx, Options{URL: url, Timeout: 200 * time.Millisecond})
		if err == nil {
			_ = st.Close()
			return url
		}
		select {
		case <-ctx.Done():
			t.Fatalf("redis-server on %s did not come up: %v", port, err)
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func newRealRedisHarness(url string) func(t *testing.T) *harness {
	return func(t *testing.T) *harness {
		prefix := randomPrefix(t)
		r := openRedisStore(t, url, prefix)
		t.Cleanup(func() { cleanupPrefix(t, url, prefix) })
		return &harness{store: r, kind: "redis", ttl: 300 * time.Millisecond, advance: time.Sleep}
	}
}

// cleanupPrefix deletes every key under prefix so a shared REDIS_TEST_URL
// server is left as it was found.
func cleanupPrefix(t *testing.T, url, prefix string) {
	ro, err := redis.ParseURL(url)
	if err != nil {
		return
	}
	c := redis.NewClient(ro)
	defer c.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	iter := c.Scan(ctx, 0, prefix+"*", 100).Iterator()
	for iter.Next(ctx) {
		_ = c.Del(ctx, iter.Val()).Err()
	}
	if err := iter.Err(); err != nil {
		t.Logf("cleanup of %s*: %v", prefix, err)
	}
}

func TestRealRedisConformance(t *testing.T) {
	url := realRedisURL(t)
	runConformance(t, newRealRedisHarness(url))
}

// The Lua scripts and GETDEL behave on a real server the way they do on
// miniredis: the CAS refuses an equal seq, presence reaps in place, an offer
// is handed out once.
func TestRealRedisScripts(t *testing.T) {
	url := realRedisURL(t)
	ctx := context.Background()
	prefix := randomPrefix(t)
	r := openRedisStore(t, url, prefix)
	t.Cleanup(func() { cleanupPrefix(t, url, prefix) })

	must(t, r.SaveTable(ctx, "r", 1, bigSnapshot("h", 20*1024), time.Minute))
	if err := r.SaveTable(ctx, "r", 1, []byte("dup"), time.Minute); !errors.Is(err, ErrStale) {
		t.Fatalf("equal seq on real redis: %v", err)
	}
	ttl, err := r.client.PTTL(ctx, r.keyTable("r")).Result()
	must(t, err)
	if ttl <= 50*time.Second || ttl > time.Minute {
		t.Fatalf("real ttl = %v", ttl)
	}
	must(t, r.SetOnline(ctx, "u1", "i", 100*time.Millisecond))
	must(t, r.SetOnline(ctx, "u2", "i", time.Hour))
	time.Sleep(150 * time.Millisecond)
	n, err := r.OnlineCount(ctx)
	must(t, err)
	if n != 1 {
		t.Fatalf("OnlineCount = %d, want 1", n)
	}
	if left, _ := r.client.HLen(ctx, r.keyOnline()).Result(); left != 1 {
		t.Fatalf("expired presence entry not reaped: %d fields", left)
	}
	must(t, r.PutResumeOffer(ctx, "u1", ResumeOffer{RoomID: "r"}, time.Minute))
	if _, err := r.TakeResumeOffer(ctx, "u1"); err != nil {
		t.Fatalf("GETDEL on real redis: %v", err)
	}
	if _, err := r.TakeResumeOffer(ctx, "u1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second take on real redis: %v", err)
	}
}
