package socket

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
	"github.com/surajk543/king-teenpatti/go-server/internal/sio"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// The in-process stack the Node process suites (integration.test.js,
// invalidMoves.test.js, metrics.test.js, socketProtocol.test.js) ran against:
// sio.Server + Handler + RoomManager on a MemoryLedger, a fake user store in
// place of Postgres, real timers with the short durations those suites set,
// all behind httptest and driven by testclient.

const (
	testSecret   = "socket-test-secret"
	welcomeChips = int64(200000)
	ackTimeout   = 4 * time.Second
	eventTimeout = 4 * time.Second
)

// fakeUsers is the UserStore: db.Users without the database. Chips are
// mutable so a test can drain a wallet the way the Node suites did through
// applyChipDelta.
type fakeUsers struct {
	mu    sync.Mutex
	users map[string]*db.User
	next  int
	// failWith, when set, makes FindByID fail (a database outage during the
	// handshake).
	failWith error
	// delay (nanoseconds) stalls every FindByID, standing in for a slow
	// user lookup so a test can land a replacement inside a join.
	delay atomic.Int64
}

func newFakeUsers() *fakeUsers { return &fakeUsers{users: map[string]*db.User{}} }

func (f *fakeUsers) add(displayName string) *db.User {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.next++
	id := fmt.Sprintf("00000000-0000-4000-8000-%012d", f.next)
	u := &db.User{
		ID:          id,
		Provider:    "guest",
		DisplayName: displayName,
		Chips:       welcomeChips,
		CreatedAt:   1700000000000,
		LastLoginAt: 1700000000000,
	}
	f.users[id] = u
	return u
}

func (f *fakeUsers) setChips(id string, chips int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if u, ok := f.users[id]; ok {
		u.Chips = chips
	}
}

func (f *fakeUsers) addChips(id string, delta int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if u, ok := f.users[id]; ok {
		u.Chips += delta
	}
}

func (f *fakeUsers) chips(id string) int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	if u, ok := f.users[id]; ok {
		return u.Chips
	}
	return -1
}

func (f *fakeUsers) setFailure(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.failWith = err
}

// FindByID returns a COPY (the handshake snapshot must not see later edits,
// as Node's row object did not).
func (f *fakeUsers) FindByID(_ context.Context, id string) (*db.User, error) {
	if d := time.Duration(f.delay.Load()); d > 0 {
		time.Sleep(d)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failWith != nil {
		return nil, f.failWith
	}
	u, ok := f.users[id]
	if !ok {
		return nil, nil
	}
	copied := *u
	return &copied, nil
}

// books is the MemoryLedger's PersistChips hook standing in for Postgres:
// every boot/bet/show debits the fake wallet and records its action_id, and
// a repeated action_id is refused as duplicate_action exactly as the UNIQUE
// constraint would be (invalidMoves.test.js "replaying a move…").
type books struct {
	mu        sync.Mutex
	actionIDs map[string]int
	users     *fakeUsers
	// delay (nanoseconds) stalls every persist call, standing in for a slow
	// Postgres so a test can hold a table's actor inside a ledger write.
	delay atomic.Int64
}

func (b *books) persist(args game.PersistChipsArgs) error {
	if d := time.Duration(b.delay.Load()); d > 0 {
		time.Sleep(d)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if args.ActionID != "" {
		if b.actionIDs[args.ActionID] > 0 {
			return game.NewGameError(game.CodeDuplicateAction, game.MsgDuplicateAction)
		}
		b.actionIDs[args.ActionID]++
	}
	b.users.addChips(args.UserID, args.Delta)
	return nil
}

func (b *books) rows(actionID string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.actionIDs[actionID]
}

// settle pays the winner: the hook receives net deltas (memory ledger:
// Persisted = amount, so winner +pot, losers 0) and returns the balances.
func (b *books) settle(_ game.HandRecord, entries []game.SettleEntry) (map[string]int64, error) {
	out := map[string]int64{}
	for _, e := range entries {
		b.users.addChips(e.UserID, e.Delta)
		out[e.UserID] = b.users.chips(e.UserID)
	}
	return out, nil
}

// stack is one running server.
type stack struct {
	t       *testing.T
	cfg     *config.Config
	users   *fakeUsers
	books   *books
	tokens  *auth.Tokens
	h       *Handler
	rooms   *game.RoomManager
	srv     *sio.Server
	ts      *httptest.Server
	metrics *metrics.Metrics

	stakes  atomic.Int64
	clients []*testclient.Client
	cmu     sync.Mutex
}

// testConfig is the process suites' environment: BOOT_AMOUNT=100,
// TURN_TIMEOUT_MS=60000, NEXT_HAND_DELAY_MS=150, RECONNECT_GRACE_MS=400,
// SIDESHOW_TIMEOUT_MS=60000, TABLE_STAKES=” and LOBBY_TABLES=” (any pair).
func testConfig() *config.Config {
	cfg := config.Defaults()
	cfg.Env = config.EnvTest
	cfg.JWT.Secret = testSecret
	cfg.Game.WelcomeChips = welcomeChips
	cfg.Game.BootAmount = 100
	cfg.Game.TurnTimeout = 60 * time.Second
	cfg.Game.NextHandDelay = 150 * time.Millisecond
	cfg.Game.ReconnectGrace = 400 * time.Millisecond
	cfg.Game.SideshowTimeout = 60 * time.Second
	cfg.Game.TableStakes = []int64{}
	cfg.Game.LobbyTables = []config.LobbyTable{}
	return cfg
}

func newStack(t *testing.T, mutate func(cfg *config.Config)) *stack {
	t.Helper()
	return newStackWithClock(t, mutate, nil)
}

// newStackWithClock is newStack with the Handler's clock injected (the
// grace timers and resume-offer ages run on it); nil → real clock. The
// RoomManager and its tables keep the real clock.
func newStackWithClock(t *testing.T, mutate func(cfg *config.Config), clock game.Clock) *stack {
	t.Helper()
	cfg := testConfig()
	if mutate != nil {
		mutate(cfg)
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	users := newFakeUsers()
	bk := &books{actionIDs: map[string]int{}, users: users}
	m := metrics.New(metrics.Options{})
	st := &stack{t: t, cfg: cfg, users: users, books: bk, metrics: m}
	st.stakes.Store(1000)
	st.tokens = auth.NewTokens(cfg.JWT.Secret, cfg.JWT.ExpiresIn, nil)

	st.srv = sio.NewServer(sio.Options{Logger: logger})
	st.h = New(Deps{
		Config:  cfg,
		Users:   users,
		Tokens:  st.tokens,
		Metrics: m,
		Clock:   clock,
		Logger:  logger,
	})
	st.rooms = game.NewRoomManager(game.RoomManagerOptions{
		Game:          cfg.Game,
		Chat:          cfg.Chat,
		Ledger:        game.NewMemoryLedger(game.MemoryLedgerHooks{PersistChips: bk.persist, Settle: bk.settle}),
		TableListener: st.h,
		Listener:      st.h,
		Logger:        logger,
		Metrics: game.MetricsHooks{
			ObserveCreation: func(d time.Duration) { metrics.Observe(m.CreationDuration, d) },
		},
	})
	st.h.SetRooms(st.rooms)
	st.h.Attach(st.srv)
	m.BindRooms(st.rooms)

	mux := http.NewServeMux()
	mux.Handle("/socket.io/", st.srv)
	st.ts = httptest.NewServer(mux)

	t.Cleanup(func() {
		st.cmu.Lock()
		clients := st.clients
		st.clients = nil
		st.cmu.Unlock()
		for _, c := range clients {
			c.Close()
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = st.rooms.Shutdown(ctx)
		st.srv.Close()
		st.ts.Close()
	})
	return st
}

// uniqueStake gives every test its own table (Node: uniqueStake()).
func (st *stack) uniqueStake() int64 { return st.stakes.Add(50) }

// login creates an account and mints its session token (POST /api/auth/login).
func (st *stack) login(displayName string) (*db.User, string) {
	st.t.Helper()
	u := st.users.add(displayName)
	tok, err := st.tokens.Issue(u)
	if err != nil {
		st.t.Fatalf("issue token: %v", err)
	}
	return u, tok
}

// connect dials with the token and waits for session:ready.
func (st *stack) connect(token string) *testclient.Client {
	st.t.Helper()
	c := st.dial(token)
	if _, err := c.Wait(EvSessionReady, nil, eventTimeout); err != nil {
		st.t.Fatalf("no session:ready: %v", err)
	}
	return c
}

// dial connects without waiting for anything after the CONNECT ack.
func (st *stack) dial(token string) *testclient.Client {
	st.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := testclient.Dial(ctx, st.ts.URL, token)
	if err != nil {
		st.t.Fatalf("dial: %v", err)
	}
	st.track(c)
	return c
}

func (st *stack) track(c *testclient.Client) {
	st.cmu.Lock()
	st.clients = append(st.clients, c)
	st.cmu.Unlock()
}

// player is a logged-in, connected account.
type player struct {
	user  *db.User
	token string
	c     *testclient.Client
}

func (st *stack) player(name string) *player {
	st.t.Helper()
	u, tok := st.login(name)
	return &player{user: u, token: tok, c: st.connect(tok)}
}

// leave is the Node clients' close(): room:leave then disconnect.
func (p *player) leave(st *stack) {
	st.t.Helper()
	if p.c.Connected() {
		_, _ = p.c.Request(EvRoomLeave, map[string]any{}, ackTimeout)
		p.c.Disconnect()
	}
}

// call sends with an ack and fails the test if none arrives.
func (st *stack) call(c *testclient.Client, event string, payload any) testclient.Ack {
	st.t.Helper()
	ack, err := c.Call(event, payload, ackTimeout)
	if err != nil {
		st.t.Fatalf("%s %s: %v", event, jsonOf(payload), err)
	}
	return ack
}

// mustOK sends and requires {ok:true}.
func (st *stack) mustOK(c *testclient.Client, event string, payload any) testclient.Ack {
	st.t.Helper()
	ack := st.call(c, event, payload)
	if !ack.OK {
		st.t.Fatalf("%s %s refused: %s", event, jsonOf(payload), ack.Raw)
	}
	return ack
}

// mustFail sends and requires {ok:false, code}.
func (st *stack) mustFail(c *testclient.Client, event string, payload any, code string) testclient.Ack {
	st.t.Helper()
	ack := st.call(c, event, payload)
	if ack.OK {
		st.t.Fatalf("%s %s was accepted: %s", event, jsonOf(payload), ack.Raw)
	}
	if code != "" && ack.Code != code {
		st.t.Fatalf("%s %s: code %q, want %q (%s)", event, jsonOf(payload), ack.Code, code, ack.Raw)
	}
	return ack
}

// dealt is a table with two players and a hand in progress
// (invalidMoves.test.js dealtTable).
type dealt struct {
	boot        int64
	a, b        *player
	onTurn      *player
	waiting     *player
	table       *game.Table
	roomID      string
	code        string
	handStarted json.RawMessage
}

func (st *stack) dealtTable(category string) *dealt {
	st.t.Helper()
	boot := st.uniqueStake()
	a := st.player("Alice")
	b := st.player("Bob")
	join := map[string]any{"bootAmount": boot}
	if category != "" {
		join["category"] = category
	}
	joined := st.mustOK(a.c, EvRoomQuickJoin, join)
	st.mustOK(b.c, EvRoomQuickJoin, join)
	started, err := a.c.Wait(EvGameHandStarted, nil, eventTimeout)
	if err != nil {
		st.t.Fatalf("hand never started: %v", err)
	}
	// The deal ends with a room:state (state betting) to every viewer; wait
	// for it so a test's event marks start after the deal's own traffic.
	for _, p := range []*player{a, b} {
		if _, err := p.c.Wait(EvRoomState, func(raw json.RawMessage) bool { return str(raw, "state") == "betting" }, eventTimeout); err != nil {
			st.t.Fatalf("no betting snapshot: %v", err)
		}
	}
	roomID := field(joined.Raw, "roomId").(string)
	table := st.rooms.GetTable(roomID)
	if table == nil {
		st.t.Fatalf("table %s not found", roomID)
	}
	view, err := table.SerializeFor(a.user.ID)
	if err != nil || view.Turn == nil || view.Turn.UserID == nil {
		st.t.Fatalf("no turn after the deal: %v %+v", err, view)
	}
	d := &dealt{boot: boot, a: a, b: b, table: table, roomID: roomID, code: field(joined.Raw, "code").(string), handStarted: started}
	if *view.Turn.UserID == a.user.ID {
		d.onTurn, d.waiting = a, b
	} else {
		d.onTurn, d.waiting = b, a
	}
	return d
}

// turnSeat reads the live turn seat from the table.
func (st *stack) turnSeat(table *game.Table, viewer string) int {
	st.t.Helper()
	view, err := table.SerializeFor(viewer)
	if err != nil {
		st.t.Fatalf("serialize: %v", err)
	}
	if view.Turn == nil {
		return -1
	}
	return view.Turn.SeatIndex
}

func (st *stack) view(table *game.Table, viewer string) *game.TableView {
	st.t.Helper()
	view, err := table.SerializeFor(viewer)
	if err != nil {
		st.t.Fatalf("serialize: %v", err)
	}
	return view
}

// ---- JSON helpers ----

func jsonOf(v any) string {
	if raw, ok := v.(json.RawMessage); ok {
		return string(raw)
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// obj decodes a JSON object payload.
func obj(raw json.RawMessage) map[string]any {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil
	}
	return m
}

// field walks a dotted path ("you.cards") into a payload; nil when absent.
func field(raw json.RawMessage, path string) any {
	var cur any
	if err := json.Unmarshal(raw, &cur); err != nil {
		return nil
	}
	for _, key := range strings.Split(path, ".") {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur, ok = m[key]
		if !ok {
			return nil
		}
	}
	return cur
}

// has reports whether the key is present (even with a null value).
func has(raw json.RawMessage, path string) bool {
	var cur any
	if err := json.Unmarshal(raw, &cur); err != nil {
		return false
	}
	keys := strings.Split(path, ".")
	for i, key := range keys {
		m, ok := cur.(map[string]any)
		if !ok {
			return false
		}
		cur, ok = m[key]
		if !ok {
			return false
		}
		if i == len(keys)-1 {
			return true
		}
	}
	return false
}

func str(raw json.RawMessage, path string) string {
	s, _ := field(raw, path).(string)
	return s
}

func num(raw json.RawMessage, path string) float64 {
	f, ok := field(raw, path).(float64)
	if !ok {
		return math.NaN()
	}
	return f
}

func arr(raw json.RawMessage, path string) []any {
	a, _ := field(raw, path).([]any)
	return a
}

// seatOf finds the seat entry for a user in a TableView payload.
func seatOf(raw json.RawMessage, userID string) map[string]any {
	for _, s := range arr(raw, "seats") {
		m, _ := s.(map[string]any)
		if m != nil && m["userId"] == userID {
			return m
		}
	}
	return nil
}

// names of the events in evs.
func names(evs []testclient.Event) []string { return testclient.Names(evs) }

// indexOf is the first position of name in evs, -1 when absent.
func indexOf(evs []testclient.Event, name string, pred func(json.RawMessage) bool) int {
	for i, e := range evs {
		if e.Name == name && (pred == nil || pred(e.Payload)) {
			return i
		}
	}
	return -1
}

// eventually polls cond until true or the timeout passes.
func eventually(t *testing.T, timeout time.Duration, cond func() bool, msg string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("condition not met within %s: %s", timeout, msg)
}

// errDB is the fake store's "database is down".
var errDB = errors.New("connection refused")

// ---- metric helpers (prometheus/testutil would add a module dependency) ----

// metricValue reads a counter or gauge.
func metricValue(m prometheus.Metric) float64 {
	var out dto.Metric
	if err := m.Write(&out); err != nil {
		return math.NaN()
	}
	if out.Counter != nil {
		return out.Counter.GetValue()
	}
	if out.Gauge != nil {
		return out.Gauge.GetValue()
	}
	return math.NaN()
}

// observations is the total sample count across every series of a histogram
// (vector or single).
func observations(c prometheus.Collector) uint64 {
	ch := make(chan prometheus.Metric, 64)
	go func() {
		c.Collect(ch)
		close(ch)
	}()
	var total uint64
	for m := range ch {
		var out dto.Metric
		if err := m.Write(&out); err == nil && out.Histogram != nil {
			total += out.Histogram.GetSampleCount()
		}
	}
	return total
}
