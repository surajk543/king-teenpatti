package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// fakeStore is the UserStore the handlers are tested against: an in-memory
// map keyed by (provider, providerUserId) with the reward rules of users.js
// reduced to what the HTTP layer observes.
type fakeStore struct {
	users    map[string]*db.User // by id
	byIdent  map[string]string   // provider|providerUserId → id
	hands    map[string][]db.HandHistory
	milestOK map[string]bool // ClaimMilestoneReward succeeds
	bonusAt  map[string]int64
	failWith error // every call returns this when set
	now      int64
	lastLim  int
}

func newFakeStore() *fakeStore {
	return &fakeStore{users: map[string]*db.User{}, byIdent: map[string]string{}, hands: map[string][]db.HandHistory{},
		milestOK: map[string]bool{}, bonusAt: map[string]int64{}, now: 1_800_000_000_000}
}

func (s *fakeStore) FindByID(_ context.Context, id string) (*db.User, error) {
	if s.failWith != nil {
		return nil, s.failWith
	}
	u := s.users[id]
	if u == nil {
		return nil, nil
	}
	copied := *u
	return &copied, nil
}

func (s *fakeStore) UpsertFromProfile(_ context.Context, p db.Profile) (*db.User, bool, error) {
	if s.failWith != nil {
		return nil, false, s.failWith
	}
	key := p.Provider + "|" + p.ProviderUserID
	if id, ok := s.byIdent[key]; ok {
		u := s.users[id]
		u.DisplayName = p.DisplayName // every login overwrites display_name (known issue)
		u.LastLoginAt = s.now
		copied := *u
		return &copied, false, nil
	}
	id := fmt.Sprintf("user-%d", len(s.users)+1)
	u := &db.User{ID: id, Provider: p.Provider, DisplayName: p.DisplayName, Email: p.Email, AvatarURL: p.AvatarURL,
		ProviderAvatarURL: p.AvatarURL, Chips: 200000, CreatedAt: s.now, LastLoginAt: s.now,
		Rewards: db.Rewards{MilestoneReward: 25000, MilestoneEvery: 25, HandsToNextMilestone: 25, BonusAvailable: true, BonusReward: 10000, BonusIntervalMs: 14400000}}
	s.users[id] = u
	s.byIdent[key] = id
	copied := *u
	return &copied, true, nil
}

func (s *fakeStore) RecentHands(_ context.Context, userID string, limit int) ([]db.HandHistory, error) {
	if s.failWith != nil {
		return nil, s.failWith
	}
	s.lastLim = limit
	hands := s.hands[userID]
	if len(hands) > limit {
		hands = hands[:limit]
	}
	return hands, nil
}

func (s *fakeStore) ClaimMilestoneReward(_ context.Context, userID string) (*db.RewardResult, error) {
	if s.failWith != nil {
		return nil, s.failWith
	}
	u := s.users[userID]
	if !s.milestOK[userID] {
		return &db.RewardResult{Claimed: false, Reason: "not_available", User: u}, nil
	}
	s.milestOK[userID] = false
	u.Chips += 25000
	return &db.RewardResult{Claimed: true, Amount: 25000, Milestone: 50, User: u}, nil
}

func (s *fakeStore) ClaimTimedBonus(_ context.Context, userID string) (*db.RewardResult, error) {
	if s.failWith != nil {
		return nil, s.failWith
	}
	u := s.users[userID]
	if s.now < s.bonusAt[userID] {
		return &db.RewardResult{Claimed: false, Reason: "not_ready", ReadyAt: s.bonusAt[userID], User: u}, nil
	}
	s.bonusAt[userID] = s.now + 14400000
	u.Chips += 10000
	return &db.RewardResult{Claimed: true, Amount: 10000, ReadyAt: s.bonusAt[userID], User: u}, nil
}

func (s *fakeStore) SetDisplayName(_ context.Context, userID, displayName string) (*db.User, error) {
	if s.failWith != nil {
		return nil, s.failWith
	}
	s.users[userID].DisplayName = displayName
	copied := *s.users[userID]
	return &copied, nil
}

func (s *fakeStore) SetAvatarChoice(_ context.Context, userID string, choice *string) (*db.User, error) {
	if s.failWith != nil {
		return nil, s.failWith
	}
	u := s.users[userID]
	u.AvatarChoice = choice
	if choice != nil {
		u.AvatarURL = choice
	} else {
		u.AvatarURL = u.ProviderAvatarURL
	}
	copied := *u
	return &copied, nil
}

// harness is a mux with the 8 routes plus the app-side /api/ 404, a fake
// store and a profiles directory holding the bundled picture names.
type harness struct {
	t      *testing.T
	mux    *http.ServeMux
	store  *fakeStore
	tokens *Tokens
	cfg    *config.Config
	seated map[string]bool
	logs   *bytes.Buffer
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	cfg := config.Defaults()
	cfg.AllowFakeProviders = true
	profiles := t.TempDir()
	for _, name := range []string{"bear.svg", "cat.svg", "Zebra.png", "wolf.webp", "NOTICE.txt", "dog.SVG", ".hidden.svg"} {
		if err := os.WriteFile(filepath.Join(profiles, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	h := &harness{t: t, mux: http.NewServeMux(), store: newFakeStore(), cfg: cfg, seated: map[string]bool{}, logs: &bytes.Buffer{}}
	h.tokens = NewTokens(cfg.JWT.Secret, cfg.JWT.ExpiresIn, time.Now)
	handler := NewHandler(Deps{
		Config:      cfg,
		Users:       h.store,
		Tokens:      h.tokens,
		Verifier:    NewVerifier(cfg),
		IsSeated:    func(id string) bool { return h.seated[id] },
		ProfilesDir: profiles,
		Logger:      slog.New(slog.NewJSONHandler(h.logs, nil)),
	})
	handler.Register(h.mux)
	h.mux.Handle("/api/", NotFoundHandler())
	return h
}

type response struct {
	status int
	header http.Header
	body   map[string]any
	raw    []byte
}

func (h *harness) do(method, target string, body any, headers ...string) response {
	h.t.Helper()
	var reader io.Reader
	contentType := "application/json"
	switch b := body.(type) {
	case nil:
	case string:
		reader = strings.NewReader(b)
	case []byte:
		reader = bytes.NewReader(b)
	default:
		raw, _ := json.Marshal(b)
		reader = bytes.NewReader(raw)
	}
	req := httptest.NewRequest(method, target, reader)
	if reader != nil {
		req.Header.Set("Content-Type", contentType)
	}
	for i := 0; i+1 < len(headers); i += 2 {
		if headers[i+1] == "" {
			req.Header.Del(headers[i])
		} else {
			req.Header.Set(headers[i], headers[i+1])
		}
	}
	rec := httptest.NewRecorder()
	h.mux.ServeHTTP(rec, req)
	res := response{status: rec.Code, header: rec.Header(), raw: rec.Body.Bytes()}
	if len(res.raw) > 0 {
		if err := json.Unmarshal(res.raw, &res.body); err != nil {
			h.t.Fatalf("%s %s: body is not a JSON object: %v\n%s", method, target, err, res.raw)
		}
	}
	return res
}

func (h *harness) login(deviceID, name string) (string, map[string]any) {
	h.t.Helper()
	body := map[string]any{"provider": "guest", "deviceId": deviceID}
	if name != "" {
		body["displayName"] = name
	}
	res := h.do(http.MethodPost, "/api/auth/login", body)
	if res.status != 200 {
		h.t.Fatalf("login: %d %s", res.status, res.raw)
	}
	return res.body["token"].(string), res.body["user"].(map[string]any)
}

func bearer(token string) []string { return []string{"Authorization", "Bearer " + token} }

func expectError(t *testing.T, res response, status int, code string) {
	t.Helper()
	if res.status != status || res.body["error"] != code {
		t.Errorf("want %d %s, got %d %s", status, code, res.status, res.raw)
	}
	if msg, ok := res.body["message"].(string); !ok || msg == "" {
		t.Errorf("error responses carry a human message: %s", res.raw)
	}
	if ct := res.header.Get("Content-Type"); ct != "application/json; charset=utf-8" {
		t.Errorf("content-type %q", ct)
	}
}

// ---- integration.test.js REST cases ----

func TestGuestLoginCreatesAnAccountWithTheWelcomeGrant(t *testing.T) {
	h := newHarness(t)
	res := h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "guest", "deviceId": "device-guest-0001", "displayName": "Suraj"})
	if res.status != 200 {
		t.Fatalf("%d %s", res.status, res.raw)
	}
	if res.body["token"] == "" || res.body["isNew"] != true || res.body["welcomeChips"] != float64(200000) {
		t.Errorf("%s", res.raw)
	}
	user := res.body["user"].(map[string]any)
	if user["chips"] != float64(200000) || user["provider"] != "guest" || user["displayName"] != "Suraj" {
		t.Errorf("user %v", user)
	}
	if ct := res.header.Get("Content-Type"); ct != "application/json; charset=utf-8" {
		t.Errorf("content-type %q", ct)
	}
	// Key set of the login response.
	for _, key := range []string{"token", "user", "isNew", "welcomeChips"} {
		if _, ok := res.body[key]; !ok {
			t.Errorf("missing %s", key)
		}
	}
	if len(res.body) != 4 {
		t.Errorf("extra keys: %v", res.body)
	}
	if !strings.Contains(h.logs.String(), `"msg":"account created"`) || !strings.Contains(h.logs.String(), `"provider":"guest"`) {
		t.Errorf("log: %s", h.logs.String())
	}
	// The token verifies and names the account.
	claims, err := h.tokens.Verify(res.body["token"].(string))
	if err != nil || claims.Subject != user["id"] {
		t.Errorf("token %v %v", err, claims)
	}
}

func TestLoggingInAgainReturnsTheSameAccount(t *testing.T) {
	h := newHarness(t)
	_, first := h.login("device-again-0002", "Suraj")
	res := h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "guest", "deviceId": "device-again-0002", "displayName": "Suraj"})
	if res.body["isNew"] != false || res.body["welcomeChips"] != float64(0) {
		t.Errorf("%s", res.raw)
	}
	second := res.body["user"].(map[string]any)
	if second["id"] != first["id"] || second["chips"] != first["chips"] {
		t.Errorf("first %v second %v", first, second)
	}
	if !strings.Contains(h.logs.String(), `"msg":"login"`) {
		t.Errorf("log: %s", h.logs.String())
	}
	// A different device is a different account.
	_, alpha := h.login("device-alpha-0003", "")
	_, beta := h.login("device-beta-0004", "")
	if alpha["id"] == beta["id"] {
		t.Error("different devices must be different accounts")
	}
	// Second login without a name renames to Guest<5 HEX> (known behaviour).
	res = h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "guest", "deviceId": "device-again-0002"})
	if name := res.body["user"].(map[string]any)["displayName"].(string); !strings.HasPrefix(name, "Guest") || len(name) != 10 {
		t.Errorf("renamed to %q", name)
	}
}

func TestTheRawDeviceIDIsNeverStored(t *testing.T) {
	h := newHarness(t)
	h.login("device-guest-0001", "Suraj")
	for ident := range h.store.byIdent {
		_, providerUserID, _ := strings.Cut(ident, "|")
		if providerUserID == "device-guest-0001" || len(providerUserID) != 64 || strings.Trim(providerUserID, "0123456789abcdef") != "" {
			t.Errorf("stored identity %q", providerUserID)
		}
	}
}

func TestLoginRefusals(t *testing.T) {
	h := newHarness(t)
	expectError(t, h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "guest", "deviceId": "abc"}), 400, CodeInvalidDeviceID)
	expectError(t, h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "guest"}), 400, CodeInvalidDeviceID)
	expectError(t, h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "guest", "deviceId": 12345678}), 400, CodeInvalidDeviceID) // DECISIONS §5
	expectError(t, h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "myspace", "deviceId": "device-xxxx-9999"}), 400, CodeUnknownProvider)
	res := h.do(http.MethodPost, "/api/auth/login", map[string]any{"deviceId": "device-xxxx-9999"})
	expectError(t, res, 400, CodeUnknownProvider)
	if res.body["message"] != `Unsupported login provider "undefined"` {
		t.Errorf("message %q", res.body["message"])
	}
	// Body-parser behaviours (DECISIONS §5).
	expectError(t, h.do(http.MethodPost, "/api/auth/login", "{bad"), 400, CodeInvalidJSON)
	expectError(t, h.do(http.MethodPost, "/api/auth/login", `"x"`), 400, CodeInvalidJSON)
	expectError(t, h.do(http.MethodPost, "/api/auth/login", `null`), 400, CodeInvalidJSON)
	expectError(t, h.do(http.MethodPost, "/api/auth/login", `{} {}`), 400, CodeInvalidJSON)
	expectError(t, h.do(http.MethodPost, "/api/auth/login", `[]`), 400, CodeUnknownProvider) // array parses; provider undefined
	big := `{"provider":"guest","deviceId":"device-guest-0001","pad":"` + strings.Repeat("x", 40*1024) + `"}`
	expectError(t, h.do(http.MethodPost, "/api/auth/login", big), 413, CodeInvalidJSON)
	expectError(t, h.do(http.MethodPost, "/api/auth/login", `{"provider":"guest"}`, "Content-Type", "application/json; charset=utf-16"), 400, CodeInvalidJSON)
	// A non-JSON content type is ignored → body {} → unknown_provider "undefined".
	res = h.do(http.MethodPost, "/api/auth/login", `{"provider":"guest","deviceId":"device-guest-0001"}`, "Content-Type", "text/plain")
	expectError(t, res, 400, CodeUnknownProvider)
	res = h.do(http.MethodPost, "/api/auth/login", `{"provider":"guest","deviceId":"device-guest-0001"}`, "Content-Type", "application/vnd.api+json")
	expectError(t, res, 400, CodeUnknownProvider)
	// charset parameter on application/json is fine.
	res = h.do(http.MethodPost, "/api/auth/login", `{"provider":"guest","deviceId":"device-guest-0001"}`, "Content-Type", "application/json; charset=UTF-8")
	if res.status != 200 {
		t.Errorf("charset=UTF-8: %d %s", res.status, res.raw)
	}
	// Empty body with a JSON content type is {}.
	expectError(t, h.do(http.MethodPost, "/api/auth/login", ""), 400, CodeUnknownProvider)
	// A store failure is a 500 internal_error and a `request failed` log line.
	h.store.failWith = errors.New("connection refused")
	res = h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "guest", "deviceId": "device-guest-0001"})
	expectError(t, res, 500, CodeInternalError)
	if res.body["message"] != MsgInternalError || !strings.Contains(h.logs.String(), `"msg":"request failed"`) || !strings.Contains(h.logs.String(), `"path":"/api/auth/login"`) {
		t.Errorf("500 %s log %s", res.raw, h.logs.String())
	}
}

func TestGoogleAndFacebookFakeLoginsCreateProviderScopedAccounts(t *testing.T) {
	h := newHarness(t)
	g := h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "google", "providerUserId": "google-sub-123", "displayName": "G Player"})
	f := h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "facebook", "providerUserId": "fb-123", "displayName": "F Player"})
	if g.status != 200 || f.status != 200 {
		t.Fatalf("%d %d", g.status, f.status)
	}
	gu, fu := g.body["user"].(map[string]any), f.body["user"].(map[string]any)
	if gu["provider"] != "google" || fu["provider"] != "facebook" || gu["chips"] != float64(200000) || gu["id"] == fu["id"] {
		t.Errorf("%v %v", gu, fu)
	}
	again := h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "google", "providerUserId": "google-sub-123", "displayName": "G Player"})
	if again.body["user"].(map[string]any)["id"] != gu["id"] || again.body["isNew"] != false {
		t.Errorf("%s", again.raw)
	}
	// Fake providers off → the real path: 401 missing_token (Node parity).
	h.cfg.AllowFakeProviders = false
	strict := newHarness(t)
	strict.cfg.AllowFakeProviders = false
	handler := NewHandler(Deps{Config: strict.cfg, Users: strict.store, Tokens: strict.tokens, Verifier: NewVerifier(strict.cfg)})
	mux := http.NewServeMux()
	handler.Register(mux)
	strict.mux = mux
	expectError(t, strict.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "google", "providerUserId": "x"}), 401, CodeMissingToken)
	expectError(t, strict.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "google", "idToken": "a.b.c"}), 503, CodeProviderUnconfigured)
}

func TestMeReturnsThePersistedProfile(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	res := h.do(http.MethodGet, "/api/auth/me", nil, bearer(token)...)
	if res.status != 200 {
		t.Fatalf("%d %s", res.status, res.raw)
	}
	me := res.body["user"].(map[string]any)
	if me["id"] != user["id"] || me["chips"] != float64(200000) || len(res.body) != 1 {
		t.Errorf("%s", res.raw)
	}
	// Fresh on every call: a change in the store shows up.
	h.store.users[user["id"].(string)].Chips = 123
	res = h.do(http.MethodGet, "/api/auth/me", nil, bearer(token)...)
	if res.body["user"].(map[string]any)["chips"] != float64(123) {
		t.Errorf("stale user: %s", res.raw)
	}
	// Tolerant bearer parsing and HEAD.
	res = h.do(http.MethodGet, "/api/auth/me", nil, "Authorization", "bearer  "+token+" ")
	if res.status != 200 {
		t.Errorf("lower-case bearer with spaces: %d", res.status)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodHead, "/api/auth/me", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	h.mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Errorf("HEAD: %d", rec.Code)
	}
}

func TestBadSessionTokensAreRefused(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	expectError(t, h.do(http.MethodGet, "/api/auth/me", nil, "Authorization", "Bearer nonsense"), 401, CodeInvalidSession)
	expectError(t, h.do(http.MethodGet, "/api/auth/me", nil), 401, CodeMissingToken)
	expectError(t, h.do(http.MethodGet, "/api/auth/me", nil, "Authorization", "Bearer"), 401, CodeMissingToken)
	expectError(t, h.do(http.MethodGet, "/api/auth/me", nil, "Authorization", "Basic abc"), 401, CodeMissingToken)
	res := h.do(http.MethodGet, "/api/auth/me", nil, "Authorization", "Bearer a.b")
	expectError(t, res, 401, CodeInvalidSession)
	if res.body["message"] != "Session token rejected: jwt malformed" {
		t.Errorf("message %q", res.body["message"])
	}
	other := NewTokens("other-secret", time.Hour, time.Now)
	forged, _ := other.Issue(&db.User{ID: user["id"].(string), Provider: "guest", DisplayName: "x"})
	res = h.do(http.MethodGet, "/api/auth/me", nil, bearer(forged)...)
	expectError(t, res, 401, CodeInvalidSession)
	if res.body["message"] != "Session token rejected: invalid signature" {
		t.Errorf("message %q", res.body["message"])
	}
	expired, _ := NewTokens(h.cfg.JWT.Secret, time.Second, func() time.Time { return time.Now().Add(-time.Hour) }).Issue(&db.User{ID: user["id"].(string)})
	res = h.do(http.MethodGet, "/api/auth/me", nil, bearer(expired)...)
	expectError(t, res, 401, CodeInvalidSession)
	if res.body["message"] != "Session token rejected: jwt expired" {
		t.Errorf("message %q", res.body["message"])
	}
	// Valid token, account gone.
	delete(h.store.users, user["id"].(string))
	res = h.do(http.MethodGet, "/api/auth/me", nil, bearer(token)...)
	expectError(t, res, 401, CodeUnknownUser)
	if res.body["message"] != MsgUnknownUser {
		t.Errorf("message %q", res.body["message"])
	}
	// Auth runs before everything else: the seated check never fires for a bad token.
	h.seated["nobody"] = true
	expectError(t, h.do(http.MethodPost, "/api/profile/name", map[string]any{"name": "x"}, "Authorization", "Bearer nonsense"), 401, CodeInvalidSession)
	// A store failure during auth is a 500.
	h.store.failWith = errors.New("db down")
	expectError(t, h.do(http.MethodGet, "/api/auth/me", nil, bearer(token)...), 500, CodeInternalError)
}

func TestHandsLimit(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	id := user["id"].(string)
	for i := 0; i < 5; i++ {
		h.store.hands[id] = append(h.store.hands[id], db.HandHistory{ID: fmt.Sprint("hand-", i), RoomID: "room", HandNo: i, Pot: 400, EndedAt: int64(1000 - i), Summary: []game.HandSummaryEntry{}})
	}
	for query, want := range map[string]int{"": 20, "?limit=3": 3, "?limit=abc": 20, "?limit=0": 20, "?limit=3.9": 3, "?limit=3abc": 3,
		"?limit=1e3": 1, "?limit=500": 100, "?limit=-5": 1, "?limit=3&limit=5": 3, "?limit=+7": 7, "?limit=%202": 2} {
		res := h.do(http.MethodGet, "/api/auth/me/hands"+query, nil, bearer(token)...)
		if res.status != 200 {
			t.Errorf("%s: %d %s", query, res.status, res.raw)
			continue
		}
		if h.store.lastLim != want {
			t.Errorf("%s: limit %d, want %d", query, h.store.lastLim, want)
		}
	}
	res := h.do(http.MethodGet, "/api/auth/me/hands?limit=2", nil, bearer(token)...)
	hands := res.body["hands"].([]any)
	if len(hands) != 2 {
		t.Fatalf("%s", res.raw)
	}
	first := hands[0].(map[string]any)
	for _, key := range []string{"id", "roomId", "handNo", "pot", "winnerId", "winReason", "endedAt", "summary"} {
		if _, ok := first[key]; !ok {
			t.Errorf("hand lacks %s: %v", key, first)
		}
	}
	if first["winnerId"] != nil || first["summary"] == nil {
		t.Errorf("null winner / non-null summary: %v", first)
	}
	// No hands → [] never null.
	_, other := h.login("device-other-0009", "")
	otherToken, _ := h.tokens.Issue(h.store.users[other["id"].(string)])
	res = h.do(http.MethodGet, "/api/auth/me/hands", nil, bearer(otherToken)...)
	if string(res.raw) != `{"hands":[]}` {
		t.Errorf("%s", res.raw)
	}
	expectError(t, h.do(http.MethodGet, "/api/auth/me/hands", nil), 401, CodeMissingToken)
}

func TestMilestoneReward(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	id := user["id"].(string)
	// Not available → 409 with the user attached, no writes.
	res := h.do(http.MethodPost, "/api/rewards/milestone", map[string]any{}, bearer(token)...)
	expectError(t, res, 409, CodeRewardNotAvailable)
	if res.body["message"] != MsgRewardNotAvailable || res.body["user"].(map[string]any)["id"] != id || len(res.body) != 3 {
		t.Errorf("%s", res.raw)
	}
	if _, ok := res.body["reason"]; ok {
		t.Error("the internal reason must not be sent")
	}
	// Available → 200 {claimed, amount, milestone, user}.
	h.store.milestOK[id] = true
	res = h.do(http.MethodPost, "/api/rewards/milestone", nil, bearer(token)...) // browser: no body, no content-type
	if res.status != 200 || res.body["claimed"] != true || res.body["amount"] != float64(25000) || res.body["milestone"] != float64(50) {
		t.Errorf("%d %s", res.status, res.raw)
	}
	if res.body["user"].(map[string]any)["chips"] != float64(225000) {
		t.Errorf("%s", res.raw)
	}
	for _, absent := range []string{"reason", "readyAt"} {
		if _, ok := res.body[absent]; ok {
			t.Errorf("%s must be absent on a milestone claim: %s", absent, res.raw)
		}
	}
	if !strings.Contains(h.logs.String(), `"msg":"milestone reward claimed"`) || !strings.Contains(h.logs.String(), `"milestone":50`) {
		t.Errorf("log %s", h.logs.String())
	}
	expectError(t, h.do(http.MethodPost, "/api/rewards/milestone", nil), 401, CodeMissingToken)
	h.store.failWith = errors.New("boom")
	expectError(t, h.do(http.MethodPost, "/api/rewards/milestone", nil, bearer(token)...), 500, CodeInternalError)
}

func TestTimedBonus(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	id := user["id"].(string)
	res := h.do(http.MethodPost, "/api/rewards/bonus", nil, bearer(token)...)
	if res.status != 200 || res.body["claimed"] != true || res.body["amount"] != float64(10000) {
		t.Fatalf("%d %s", res.status, res.raw)
	}
	readyAt := res.body["readyAt"].(float64)
	if int64(readyAt) != h.store.now+14400000 || res.body["user"].(map[string]any)["chips"] != float64(210000) {
		t.Errorf("%s", res.raw)
	}
	if _, ok := res.body["milestone"]; ok {
		t.Errorf("milestone must be absent on a bonus claim: %s", res.raw)
	}
	if !strings.Contains(h.logs.String(), `"msg":"timed bonus claimed"`) {
		t.Errorf("log %s", h.logs.String())
	}
	// Inside the countdown → 409 {error, message, readyAt, user}.
	res = h.do(http.MethodPost, "/api/rewards/bonus", map[string]any{}, bearer(token)...)
	expectError(t, res, 409, CodeRewardNotReady)
	if res.body["message"] != MsgRewardNotReady || res.body["readyAt"] != readyAt || res.body["user"].(map[string]any)["id"] != id || len(res.body) != 4 {
		t.Errorf("%s", res.raw)
	}
}

func TestProfilesListsTheBundledPictures(t *testing.T) {
	h := newHarness(t)
	res := h.do(http.MethodGet, "/api/profiles", nil)
	if res.status != 200 {
		t.Fatalf("%d", res.status)
	}
	// JS default sort: UTF-16 code units, so upper case first; NOTICE.txt and
	// dotfiles... a dotfile matching the pattern IS listed by Node's readdir —
	// keep that (the static server hides it, the picker never shows one).
	want := `{"profiles":[{"id":".hidden.svg","url":"/profiles/.hidden.svg"},{"id":"Zebra.png","url":"/profiles/Zebra.png"},{"id":"bear.svg","url":"/profiles/bear.svg"},{"id":"cat.svg","url":"/profiles/cat.svg"},{"id":"dog.SVG","url":"/profiles/dog.SVG"},{"id":"wolf.webp","url":"/profiles/wolf.webp"}]}`
	if string(res.raw) != want {
		t.Errorf("got  %s\nwant %s", res.raw, want)
	}
	// Unreadable directory → [] never null.
	handler := NewHandler(Deps{Config: h.cfg, Users: h.store, Tokens: h.tokens, Verifier: NewVerifier(h.cfg), ProfilesDir: filepath.Join(t.TempDir(), "missing")})
	mux := http.NewServeMux()
	handler.Register(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/profiles", nil))
	if rec.Body.String() != `{"profiles":[]}` {
		t.Errorf("%s", rec.Body.String())
	}
	// Real bundled directory, when present: 15 animals, NOTICE.txt excluded.
	real := filepath.Join("..", "..", "..", "server", "public", "profiles")
	if _, err := os.Stat(real); err == nil {
		handler := NewHandler(Deps{ProfilesDir: real})
		pictures := handler.listProfilePictures()
		if len(pictures) != 15 || pictures[0].ID != "bear.svg" || pictures[14].ID != "wolf.svg" {
			t.Errorf("bundled profiles: %v", pictures)
		}
	}
}

func TestAvatarChoice(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	id := user["id"].(string)
	res := h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": "bear.svg"}, bearer(token)...)
	if res.status != 200 {
		t.Fatalf("%d %s", res.status, res.raw)
	}
	u := res.body["user"].(map[string]any)
	if u["avatarChoice"] != "/profiles/bear.svg" || u["avatarUrl"] != "/profiles/bear.svg" {
		t.Errorf("%s", res.raw)
	}
	for _, bad := range []any{"", 0, false, "nope.svg", "/profiles/bear.svg", "BEAR.SVG", "NOTICE.txt", []string{"bear.svg"}} {
		res := h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": bad}, bearer(token)...)
		expectError(t, res, 400, CodeUnknownAvatar)
		if res.body["message"] != MsgUnknownAvatar {
			t.Errorf("%v: %s", bad, res.raw)
		}
	}
	// null / absent clears the choice.
	res = h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": nil}, bearer(token)...)
	if res.status != 200 || res.body["user"].(map[string]any)["avatarChoice"] != nil {
		t.Errorf("%d %s", res.status, res.raw)
	}
	h.store.users[id].AvatarChoice = ptr("/profiles/cat.svg")
	res = h.do(http.MethodPost, "/api/profile/avatar", map[string]any{}, bearer(token)...)
	if res.status != 200 || res.body["user"].(map[string]any)["avatarChoice"] != nil {
		t.Errorf("absent avatar must clear: %d %s", res.status, res.raw)
	}
	// Seated → 409 before any validation.
	h.seated[id] = true
	res = h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": "nope.svg"}, bearer(token)...)
	expectError(t, res, 409, CodeSeated)
	if res.body["message"] != MsgSeatedAvatar {
		t.Errorf("%s", res.raw)
	}
	h.seated[id] = false
	expectError(t, h.do(http.MethodPost, "/api/profile/avatar", "{bad", bearer(token)...), 400, CodeInvalidJSON)
	expectError(t, h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": "bear.svg"}), 401, CodeMissingToken)
}

func ptr(s string) *string { return &s }

func TestDisplayNameChange(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	id := user["id"].(string)
	res := h.do(http.MethodPost, "/api/profile/name", map[string]any{"name": "  सुरज\t\tकुमार  "}, bearer(token)...)
	if res.status != 200 || res.body["user"].(map[string]any)["displayName"] != "सुरज कुमार" {
		t.Errorf("%d %s", res.status, res.raw)
	}
	res = h.do(http.MethodPost, "/api/profile/name", map[string]any{"name": 123}, bearer(token)...)
	if res.status != 200 || res.body["user"].(map[string]any)["displayName"] != "123" {
		t.Errorf("number names are accepted as text: %d %s", res.status, res.raw)
	}
	for _, tc := range []struct {
		name    any
		code    string
		message string
	}{
		{"   ", "empty_name", MsgEmptyName},
		{"", "empty_name", MsgEmptyName},
		{nil, "empty_name", MsgEmptyName},
		{true, "empty_name", MsgEmptyName}, // DECISIONS §4: booleans are empty
		{strings.Repeat("a", 25), "name_too_long", "Keep it to 24 characters or fewer."},
		{"a-b", "invalid_name", MsgInvalidName},
		{"a_b", "invalid_name", MsgInvalidName},
		{"name!", "invalid_name", MsgInvalidName},
		{map[string]any{"a": 1}, "empty_name", MsgEmptyName},
	} {
		body := map[string]any{"name": tc.name}
		if tc.name == nil {
			body = map[string]any{}
		}
		res := h.do(http.MethodPost, "/api/profile/name", body, bearer(token)...)
		expectError(t, res, 400, tc.code)
		if res.body["message"] != tc.message {
			t.Errorf("%v: message %q", tc.name, res.body["message"])
		}
	}
	h.seated[id] = true
	res = h.do(http.MethodPost, "/api/profile/name", map[string]any{"name": "!!!"}, bearer(token)...)
	expectError(t, res, 409, CodeSeated)
	if res.body["message"] != MsgSeatedName {
		t.Errorf("%s", res.raw)
	}
	h.seated[id] = false
	// A smaller DISPLAY_NAME_MAX shows in the message.
	h.cfg.Game.DisplayNameMaxLength = 5
	res = h.do(http.MethodPost, "/api/profile/name", map[string]any{"name": "abcdef"}, bearer(token)...)
	expectError(t, res, 400, "name_too_long")
	if res.body["message"] != "Keep it to 5 characters or fewer." {
		t.Errorf("%s", res.raw)
	}
	expectError(t, h.do(http.MethodPost, "/api/profile/name", map[string]any{"name": "x"}), 401, CodeMissingToken)
}

func TestUnknownAPIPathsAndMethodsAre404JSON(t *testing.T) {
	h := newHarness(t)
	for _, tc := range []struct{ method, path string }{
		{http.MethodGet, "/api/auth/login"},
		{http.MethodPost, "/api/auth/me"},
		{http.MethodDelete, "/api/profiles"},
		{http.MethodGet, "/api/nothing-here-123"},
		{http.MethodGet, "/api/authx/me"},
		{http.MethodPost, "/api/rewards/unknown"},
	} {
		res := h.do(tc.method, tc.path, nil)
		expectError(t, res, 404, CodeNotFound)
		if res.body["message"] != "Cannot "+tc.method+" "+tc.path {
			t.Errorf("%s %s: %s", tc.method, tc.path, res.raw)
		}
	}
	// The query string is not echoed.
	res := h.do(http.MethodGet, "/api/nothing?x=1", nil)
	if res.body["message"] != "Cannot GET /api/nothing" {
		t.Errorf("%s", res.raw)
	}
}

func TestWriteErrorAndWriteJSON(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logs, nil))
	req := httptest.NewRequest(http.MethodGet, "/api/x?secret=1", nil)

	rec := httptest.NewRecorder()
	WriteError(rec, req, logger, NewAuthError(CodeInvalidSession, "nope", 0))
	if rec.Code != 401 || rec.Body.String() != `{"error":"invalid_session","message":"nope"}` {
		t.Errorf("%d %s", rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	WriteError(rec, req, logger, fmt.Errorf("wrapped: %w", NewAuthError(CodeProviderUnconfigured, "x", 503)))
	if rec.Code != 503 {
		t.Errorf("wrapped AuthError: %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	WriteError(rec, req, logger, game.NewGameError("invalid_stake", "That stake is not valid"))
	if rec.Code != 400 || rec.Body.String() != `{"error":"invalid_stake","message":"That stake is not valid"}` {
		t.Errorf("%d %s", rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	WriteError(rec, req, logger, errors.New("pg: connection refused"))
	if rec.Code != 500 || rec.Body.String() != `{"error":"internal_error","message":"Something went wrong"}` {
		t.Errorf("%d %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(logs.String(), `"msg":"request failed"`) || !strings.Contains(logs.String(), `"path":"/api/x"`) || !strings.Contains(logs.String(), "connection refused") {
		t.Errorf("log %s", logs.String())
	}
	// nil logger is tolerated.
	WriteError(httptest.NewRecorder(), req, nil, errors.New("x"))

	// WriteJSON: compact, charset header, HTML not escaped, Content-Length set.
	rec = httptest.NewRecorder()
	WriteJSON(rec, 200, map[string]string{"a": "<b>&"})
	if rec.Body.String() != `{"a":"<b>&"}` || rec.Header().Get("Content-Type") != "application/json; charset=utf-8" || rec.Header().Get("Content-Length") != "12" {
		t.Errorf("%s %v", rec.Body.String(), rec.Header())
	}
	// UserFrom outside RequireAuth is nil.
	if UserFrom(context.Background()) != nil {
		t.Error("UserFrom on a bare context")
	}
}

func TestRequireAuthStoresTheUserInTheContext(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	handler := NewHandler(Deps{Config: h.cfg, Users: h.store, Tokens: h.tokens})
	var seen *db.User
	wrapped := handler.RequireAuth(func(w http.ResponseWriter, r *http.Request, u *db.User) {
		seen = UserFrom(r.Context())
		if seen != u {
			t.Error("UserFrom must return the same user the handler received")
		}
		w.WriteHeader(204)
	})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	wrapped.ServeHTTP(rec, req)
	if rec.Code != 204 || seen == nil || seen.ID != user["id"] {
		t.Errorf("%d %+v", rec.Code, seen)
	}
}

// TestReadJSONBodyMirrorsBodyParser pins the body-parser 1.20 behaviours
// ReadJSONBody reproduces (checked against `express.json({limit:'32kb'})`
// on Node 22 on 2026-09-08), with DECISIONS.md §5's statuses in place of
// Node's 500.
func TestReadJSONBodyMirrorsBodyParser(t *testing.T) {
	type target struct {
		A string `json:"a"`
	}
	read := func(body *string, contentType string, contentLength int64) (target, *AuthError) {
		t.Helper()
		var reader io.Reader
		if body != nil {
			reader = strings.NewReader(*body)
		}
		req := httptest.NewRequest(http.MethodPost, "/x", reader)
		if contentType != "" {
			req.Header.Set("Content-Type", contentType)
		}
		if contentLength != 0 {
			req.ContentLength = contentLength
		}
		var v target
		err := ReadJSONBody(req, &v)
		if err == nil {
			return v, nil
		}
		var ae *AuthError
		if !errors.As(err, &ae) {
			t.Fatalf("ReadJSONBody returned a non-AuthError: %v", err)
		}
		return v, ae
	}
	str := func(s string) *string { return &s }
	big := `{"a":"` + strings.Repeat("x", MaxBodyBytes) + `"}`

	// Parsed.
	if v, err := read(str(`{"a":"1"}`), "application/json", 0); err != nil || v.A != "1" {
		t.Errorf("plain object: %+v %v", v, err)
	}
	if v, err := read(str(` 	
{"a":"2"} 
`), "application/json", 0); err != nil || v.A != "2" {
		t.Errorf("JSON whitespace around the object: %+v %v", v, err)
	}
	if v, err := read(str(`{"a":"3"}`), "application/json; charset=UTF-8", 0); err != nil || v.A != "3" {
		t.Errorf("charset=UTF-8: %+v %v", v, err)
	}
	if v, err := read(str(`{"a":"4"}`), "APPLICATION/JSON", 0); err != nil || v.A != "4" {
		t.Errorf("media type is case-insensitive: %+v %v", v, err)
	}
	// Left as {}: no body, a zero-length body, a non-JSON type (whatever its size).
	for name, tc := range map[string]struct {
		body *string
		ct   string
	}{
		"no body":              {nil, ""},
		"no body with type":    {nil, "application/json"},
		"empty body":           {str(""), "application/json"},
		"text/plain":           {str(`{"a":"x"}`), "text/plain"},
		"vnd.api+json":         {str(`{"a":"x"}`), "application/vnd.api+json"},
		"no content type":      {str(`{"a":"x"}`), ""},
		"huge non-JSON body":   {str(big), "text/plain"},
		"unparsable type":      {str(`{"a":"x"}`), "application/;;"},
		"latin1 non-JSON type": {str(`{"a":"x"}`), "text/plain; charset=latin1"},
	} {
		if v, err := read(tc.body, tc.ct, 0); err != nil || v.A != "" {
			t.Errorf("%s: want {}, got %+v %v", name, v, err)
		}
	}
	// 400 invalid_json.
	for name, body := range map[string]string{
		"malformed":             `{bad`,
		"string":                `"x"`,
		"number":                `1`,
		"null":                  `null`,
		"true":                  `true`,
		"trailing data":         `{} {}`,
		"trailing garbage":      `{}x`,
		"whitespace only":       "  \n ",
		"vertical tab first":    "\v{}",
		"nbsp first":            " {}",
		"trailing vertical tab": "{}\v",
	} {
		if _, err := read(str(body), "application/json", 0); err == nil || err.Code != CodeInvalidJSON || err.Status != 400 {
			t.Errorf("%s: want 400 invalid_json, got %v", name, err)
		}
	}
	// Charsets: only utf-8 is decoded; body-parser 415'd non-utf and
	// transcoded utf-16 — both are invalid_json here.
	for _, charset := range []string{"utf-16", "UTF-16LE", "utf-32", "latin1", "iso-8859-1", "utf8"} {
		_, err := read(str(`{"a":"x"}`), "application/json; charset="+charset, 0)
		if err == nil || err.Code != CodeInvalidJSON || err.Status != 400 || !strings.Contains(err.Message, `unsupported charset "`+strings.ToUpper(charset)+`"`) {
			t.Errorf("charset=%s: %v", charset, err)
		}
	}
	// 413 by Content-Length and by streamed size; exactly the limit is fine.
	if _, err := read(str(big), "application/json", 0); err == nil || err.Status != 413 || err.Code != CodeInvalidJSON {
		t.Errorf("streamed over the limit: %v", err)
	}
	if _, err := read(str(`{}`), "application/json", MaxBodyBytes+1); err == nil || err.Status != 413 {
		t.Errorf("Content-Length over the limit: %v", err)
	}
	exact := `{"a":"` + strings.Repeat("x", MaxBodyBytes-len(`{"a":""}`)) + `"}`
	if len(exact) != MaxBodyBytes {
		t.Fatalf("fixture is %d bytes", len(exact))
	}
	if _, err := read(str(exact), "application/json", 0); err != nil {
		t.Errorf("exactly 32 KiB must parse: %v", err)
	}
}
