package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// A lobby-only wallet change — a chip-priced picture, the milestone reward,
// the timed bonus — must run under the player's seat lock (Deps.WhileUnseated),
// not merely after a look at whether they are seated, and on the context that
// lock hands out rather than the request's. The look and the commit are two
// moments; a room:quickJoin that read the wallet between them used to seat
// chips the wallet no longer held. And a request context ends the moment the
// client hangs up, even with COMMIT on the wire, which would let the lock go
// before the outcome was known. The RoomManager side of the lock is covered in
// internal/game (lobbywallet_test.go) and end to end in internal/app.

// lockContextKey marks the context the seat lock hands out, so a store call
// can tell it from the request's.
type lockContextKey struct{}

// seatGate stands in for rooms.WhileUnseated: a real mutex as the seat lock, a
// seated set, and a log of every store call saying whether the lock was held.
type seatGate struct {
	lock sync.Mutex // the seat lock itself

	mu     sync.Mutex // guards everything below
	seated map[string]bool
	held   bool
	calls  []string
}

func newSeatGate() *seatGate { return &seatGate{seated: map[string]bool{}} }

func (g *seatGate) whileUnseated(userID string, fn func(ctx context.Context)) bool {
	g.lock.Lock()
	defer g.lock.Unlock()
	g.mu.Lock()
	seated := g.seated[userID]
	g.held = !seated
	g.mu.Unlock()
	if seated {
		return false
	}
	defer func() {
		g.mu.Lock()
		g.held = false
		g.mu.Unlock()
	}()
	fn(context.WithValue(context.Background(), lockContextKey{}, g))
	return true
}

func (g *seatGate) seat(userID string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.seated[userID] = true
}

// record notes a store call: whether it happened inside the lock, and whether
// it ran there on the context the lock handed out.
func (g *seatGate) record(ctx context.Context, call string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	switch {
	case g.held && ctx.Value(lockContextKey{}) == g:
		g.calls = append(g.calls, call+":locked")
	case g.held:
		g.calls = append(g.calls, call+":locked-on-the-request-context")
	default:
		g.calls = append(g.calls, call+":unlocked")
	}
}

func (g *seatGate) log() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]string(nil), g.calls...)
}

// gatedPictures is fakePictures reporting its purchases to the gate, with an
// optional pause inside Buy — after the seated check, before the wallet moves.
type gatedPictures struct {
	*fakePictures
	gate      *seatGate
	beforeBuy func(ctx context.Context)
}

func (p *gatedPictures) Buy(ctx context.Context, userID string, id int64) (*db.PicturePurchase, error) {
	p.gate.record(ctx, "buy")
	if p.beforeBuy != nil {
		p.beforeBuy(ctx)
	}
	return p.fakePictures.Buy(ctx, userID, id)
}

func (p *gatedPictures) BuyAtTable(ctx context.Context, userID string, id int64) (*db.PicturePurchase, error) {
	p.gate.record(ctx, "atTable")
	return p.fakePictures.BuyAtTable(ctx, userID, id)
}

// gatedUsers is fakeStore reporting its reward claims to the gate.
type gatedUsers struct {
	*fakeStore
	gate *seatGate
}

func (u *gatedUsers) ClaimMilestoneReward(ctx context.Context, userID string) (*db.RewardResult, error) {
	u.gate.record(ctx, "milestone")
	return u.fakeStore.ClaimMilestoneReward(ctx, userID)
}

func (u *gatedUsers) ClaimTimedBonus(ctx context.Context, userID string) (*db.RewardResult, error) {
	u.gate.record(ctx, "bonus")
	return u.fakeStore.ClaimTimedBonus(ctx, userID)
}

func (u *gatedUsers) ClaimDailyBonus(ctx context.Context, userID string) (*db.RewardResult, error) {
	u.gate.record(ctx, "daily")
	return u.fakeStore.ClaimDailyBonus(ctx, userID)
}

// newGatedHarness is newHarness with the seat lock wired in. IsSeated always
// answers "no": a handler that still decided a money route by that look alone
// would sell to a seated player here, and the tests would see it.
func newGatedHarness(t *testing.T) (*harness, *seatGate, *gatedPictures) {
	t.Helper()
	cfg := config.Defaults()
	cfg.AllowFakeProviders = true
	h := &harness{t: t, mux: http.NewServeMux(), store: newFakeStore(), cfg: cfg, seated: map[string]bool{}, logs: &bytes.Buffer{}}
	h.pictures = newFakePictures(h.store)
	h.tokens = NewTokens(cfg.JWT.Secret, cfg.JWT.ExpiresIn, time.Now)
	gate := newSeatGate()
	pictures := &gatedPictures{fakePictures: h.pictures, gate: gate}
	handler := NewHandler(Deps{
		Config:        cfg,
		Users:         &gatedUsers{fakeStore: h.store, gate: gate},
		Pictures:      pictures,
		Tokens:        h.tokens,
		Verifier:      NewVerifier(cfg),
		IsSeated:      func(string) bool { return false },
		WhileUnseated: gate.whileUnseated,
		Logger:        slog.New(slog.NewJSONHandler(h.logs, nil)),
	})
	handler.Register(h.mux)
	h.mux.Handle("/api/", NotFoundHandler())
	return h, gate, pictures
}

// receiveWithin takes one value from ch, failing the test after 5 s: a lock
// that is never taken, or never let go, should fail this file, not hang it.
func receiveWithin[T any](t *testing.T, ch <-chan T, what string) T {
	t.Helper()
	select {
	case v := <-ch:
		return v
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
	var zero T
	return zero
}

func TestLobbyOnlyWalletChangesRunUnderTheSeatLock(t *testing.T) {
	h, gate, _ := newGatedHarness(t)
	token, user := h.login("device-seat-lock-0001", "Locked")
	id := user["id"].(string)
	h.store.users[id].Chips = 300000
	h.store.milestOK[id] = true
	h.store.bonusAt[id] = 0

	// In the lobby each change goes through, inside the lock and on the
	// context the lock handed out.
	res := h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": 3}, bearer(token)...)
	if res.status != 200 || res.body["charged"] != true {
		t.Fatalf("a lobby buy: %d %s", res.status, res.raw)
	}
	for _, path := range []string{"/api/rewards/milestone", "/api/rewards/bonus", "/api/rewards/daily"} {
		if res := h.do(http.MethodPost, path, map[string]any{}, bearer(token)...); res.status != 200 || res.body["claimed"] != true {
			t.Fatalf("%s from the lobby: %d %s", path, res.status, res.raw)
		}
	}
	if got, want := gate.log(), []string{"buy:locked", "milestone:locked", "bonus:locked", "daily:locked"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("store calls = %v, want %v", got, want)
	}

	// Seated: the chip-priced picture and both rewards are refused 409 seated
	// and no chips move; a diamond picture still sells, through BuyAtTable and
	// with no lock to hold.
	gate.seat(id)
	h.store.milestOK[id] = true
	h.store.bonusAt[id] = 0
	chips := h.store.users[id].Chips

	res = h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": 4}, bearer(token)...)
	expectError(t, res, http.StatusConflict, CodeSeated)
	if res.body["message"] != MsgSeatedPicture {
		t.Errorf("seated coin buy message: %s", res.raw)
	}
	for _, tc := range []struct{ path, msg string }{
		{"/api/rewards/milestone", MsgSeatedMilestone},
		{"/api/rewards/bonus", MsgSeatedBonus},
		{"/api/rewards/daily", MsgSeatedBonus},
	} {
		res := h.do(http.MethodPost, tc.path, map[string]any{}, bearer(token)...)
		expectError(t, res, http.StatusConflict, CodeSeated)
		if res.body["message"] != tc.msg {
			t.Errorf("%s message: %s", tc.path, res.raw)
		}
	}
	res = h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": 5}, bearer(token)...)
	if res.status != 200 || res.body["charged"] != true {
		t.Fatalf("a seated diamond buy: %d %s", res.status, res.raw)
	}
	if h.store.users[id].Chips != chips {
		t.Errorf("chips moved while seated: %d → %d", chips, h.store.users[id].Chips)
	}
	want := []string{"buy:locked", "milestone:locked", "bonus:locked", "daily:locked", "atTable:unlocked", "atTable:unlocked"}
	if got := gate.log(); !reflect.DeepEqual(got, want) {
		t.Fatalf("store calls = %v, want %v (no claim may reach the store while seated)", got, want)
	}
}

// The lock has to span the purchase, not just its seated check, and a client
// hanging up must not cut it short. Paused between the two, with the request
// already cancelled, the seat lock must still be held, the purchase's context
// still live, and no answer written; the lock goes only with the purchase.
func TestAPicturePurchaseHoldsTheSeatLockUntilItCommits(t *testing.T) {
	h, gate, pictures := newGatedHarness(t)
	token, user := h.login("device-seat-lock-0002", "Paused")
	id := user["id"].(string)
	h.store.users[id].Chips = 250000

	paused, release := make(chan context.Context, 1), make(chan struct{})
	var once sync.Once
	letGo := func() { once.Do(func() { close(release) }) }
	t.Cleanup(letGo) // a failure half-way must not leave the purchase parked
	pictures.beforeBuy = func(ctx context.Context) {
		paused <- ctx
		<-release
	}

	requestCtx, hangUp := context.WithCancel(context.Background())
	defer hangUp()
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		body, _ := json.Marshal(map[string]any{"pictureId": 3})
		req := httptest.NewRequestWithContext(requestCtx, http.MethodPost, "/api/profile/picture/buy", strings.NewReader(string(body)))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		h.mux.ServeHTTP(rec, req)
		done <- rec
	}()

	buyCtx := receiveWithin(t, paused, "the purchase to reach the store")
	hangUp() // the client gives up while the purchase is inside its transaction
	if err := buyCtx.Err(); err != nil {
		t.Fatalf("the purchase's context ended with the request (%v): a COMMIT on the wire would be abandoned with the lock let go", err)
	}
	if gate.lock.TryLock() {
		gate.lock.Unlock()
		t.Fatal("the seat lock was free while a purchase sat between its seated check and its commit")
	}
	select {
	case rec := <-done:
		t.Fatalf("the purchase answered %d before its store call returned", rec.Code)
	default:
	}

	letGo()
	rec := receiveWithin(t, done, "the purchase to answer")
	if rec.Code != http.StatusOK {
		t.Fatalf("buy: %d %s", rec.Code, rec.Body.String())
	}
	if !gate.lock.TryLock() {
		t.Fatal("the seat lock outlived the purchase")
	}
	gate.lock.Unlock()
	if got := h.store.users[id].Chips; got != 200000 {
		t.Errorf("wallet after the purchase = %d, want 200000", got)
	}
}
