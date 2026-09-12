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
	milestOK map[string]bool     // ClaimMilestoneReward succeeds
	bonusAt  map[string]int64
	failWith error // every call returns this when set
	now      int64
	lastLim  int
}

func newFakeStore() *fakeStore {
	return &fakeStore{users: map[string]*db.User{}, byIdent: map[string]string{}, milestOK: map[string]bool{}, bonusAt: map[string]int64{}, now: 1_800_000_000_000}
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

// DeleteAccount mirrors db.Users.DeleteAccount as the HTTP layer sees it: the
// account stops resolving, so a later request with the same token is answered
// unknown_user.
func (s *fakeStore) DeleteAccount(_ context.Context, userID string) error {
	if s.failWith != nil {
		return s.failWith
	}
	if u := s.users[userID]; u != nil {
		delete(s.byIdent, u.Provider+"|"+userID)
		delete(s.users, userID)
	}
	return nil
}

func (s *fakeStore) SetActivePicture(_ context.Context, userID string, pictureID *int64) (*db.User, error) {
	if s.failWith != nil {
		return nil, s.failWith
	}
	u := s.users[userID]
	u.ActivePictureID = pictureID
	if pictureID != nil {
		u.AvatarURL = ptr(fakeCatalogue[*pictureID].URL)
	} else {
		u.AvatarURL = u.ProviderAvatarURL
	}
	copied := *u
	return &copied, nil
}

// fakeCatalogue stands in for the profile_pictures table: two free pictures,
// two premium ones, and a retired row that is still a valid id.
var fakeCatalogue = map[int64]db.Picture{
	1: {ID: 1, Name: "Bear", URL: "/profiles/bear.svg", Type: db.PictureFree, SortOrder: 10},
	2: {ID: 2, Name: "Cat", URL: "/profiles/cat.svg", Type: db.PictureFree, SortOrder: 20},
	3: {ID: 3, Name: "Wolf", URL: "/profiles/wolf.svg", Type: db.PicturePremium, Cost: 50000, DurationDays: 30, SortOrder: 30},
	4: {ID: 4, Name: "Lion", URL: "/profiles/lion.svg", Type: db.PicturePremium, Cost: 25000, DurationDays: 30, SortOrder: 40},
	9: {ID: 9, Name: "Dodo", URL: "/profiles/dodo.svg", Type: db.PicturePremium, Cost: 100, DurationDays: 30, SortOrder: 90},
}

// fakePictures is the PictureStore the harness wires in: the catalogue above,
// an ownership set, and a wallet it debits so the buy path can be exercised
// without a database.
type fakePictures struct {
	store    *fakeStore
	owned    map[string]map[int64]bool
	retired  map[int64]bool
	failWith error
}

func newFakePictures(store *fakeStore) *fakePictures {
	return &fakePictures{store: store, owned: map[string]map[int64]bool{}, retired: map[int64]bool{9: true}}
}

func (f *fakePictures) has(userID string, id int64) bool {
	return fakeCatalogue[id].Type == db.PictureFree || f.owned[userID][id]
}

func (f *fakePictures) List(_ context.Context, userID string) ([]db.Picture, error) {
	if f.failWith != nil {
		return nil, f.failWith
	}
	out := []db.Picture{}
	for _, id := range []int64{1, 2, 3, 4, 9} {
		if f.retired[id] {
			continue
		}
		pic := fakeCatalogue[id]
		pic.Owned = f.has(userID, id)
		out = append(out, pic)
	}
	return out, nil
}

func (f *fakePictures) Find(_ context.Context, userID string, id int64) (db.Picture, bool, error) {
	if f.failWith != nil {
		return db.Picture{}, false, f.failWith
	}
	pic, ok := fakeCatalogue[id]
	if !ok {
		return db.Picture{}, false, db.ErrPictureUnknown
	}
	pic.Owned = f.has(userID, id)
	return pic, !f.retired[id], nil
}

// expired is what ExpireLapsed should strip on the next login, keyed by user.
func (f *fakePictures) ExpireLapsed(_ context.Context, userID string) (bool, error) {
	if f.failWith != nil {
		return false, f.failWith
	}
	user := f.store.users[userID]
	if user == nil || user.ActivePictureID == nil {
		return false, nil
	}
	worn := fakeCatalogue[*user.ActivePictureID]
	if worn.Free() || f.has(userID, worn.ID) {
		return false, nil
	}
	user.ActivePictureID = nil
	user.AvatarURL = user.ProviderAvatarURL
	return true, nil
}

func (f *fakePictures) Buy(_ context.Context, userID string, id int64) (*db.PicturePurchase, error) {
	if f.failWith != nil {
		return nil, f.failWith
	}
	pic, ok := fakeCatalogue[id]
	if !ok {
		return nil, db.ErrPictureUnknown
	}
	switch {
	case f.retired[id]:
		return nil, db.ErrPictureInactive
	case pic.Free():
		return nil, db.ErrPictureFree
	}
	user := f.store.users[userID]
	if f.owned[userID][id] {
		pic.Owned = true
		return &db.PicturePurchase{Picture: pic, Charged: false, Balance: user.Chips, User: user}, nil
	}
	if user.Chips < pic.Cost {
		return nil, db.ErrPictureChips
	}
	user.Chips -= pic.Cost
	if f.owned[userID] == nil {
		f.owned[userID] = map[int64]bool{}
	}
	f.owned[userID][id] = true
	pic.Owned = true
	return &db.PicturePurchase{Picture: pic, Charged: true, Spent: pic.Cost, Balance: user.Chips, User: user}, nil
}

// harness is a mux with the 8 routes plus the app-side /api/ 404, a fake
// store and a profiles directory holding the bundled picture names.
type harness struct {
	t        *testing.T
	mux      *http.ServeMux
	store    *fakeStore
	pictures *fakePictures
	tokens   *Tokens
	cfg      *config.Config
	seated   map[string]bool
	logs     *bytes.Buffer
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	cfg := config.Defaults()
	cfg.AllowFakeProviders = true
	h := &harness{t: t, mux: http.NewServeMux(), store: newFakeStore(), cfg: cfg, seated: map[string]bool{}, logs: &bytes.Buffer{}}
	h.pictures = newFakePictures(h.store)
	h.tokens = NewTokens(cfg.JWT.Secret, cfg.JWT.ExpiresIn, time.Now)
	handler := NewHandler(Deps{
		Config:   cfg,
		Users:    h.store,
		Pictures: h.pictures,
		Tokens:   h.tokens,
		Verifier: NewVerifier(cfg),
		IsSeated: func(id string) bool { return h.seated[id] },
		Logger:   slog.New(slog.NewJSONHandler(h.logs, nil)),
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
	if res.body["message"] != `Unsupported login provider "undefined"` {
		t.Errorf("non-JSON type message %q", res.body["message"])
	}
	res = h.do(http.MethodPost, "/api/auth/login", `{"provider":"guest","deviceId":"device-guest-0001"}`, "Content-Type", "application/vnd.api+json")
	expectError(t, res, 400, CodeUnknownProvider)
	// charset parameter on application/json is fine.
	res = h.do(http.MethodPost, "/api/auth/login", `{"provider":"guest","deviceId":"device-guest-0001"}`, "Content-Type", "application/json; charset=UTF-8")
	if res.status != 200 {
		t.Errorf("charset=UTF-8: %d %s", res.status, res.raw)
	}
	// Empty body with a JSON content type is {}; so is no body at all. Both
	// name the missing provider "undefined", as Node's template literal did.
	expectError(t, h.do(http.MethodPost, "/api/auth/login", ""), 400, CodeUnknownProvider)
	res = h.do(http.MethodPost, "/api/auth/login", nil)
	expectError(t, res, 400, CodeUnknownProvider)
	if res.body["message"] != `Unsupported login provider "undefined"` {
		t.Errorf("no-body message %q", res.body["message"])
	}
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

// TestRefusedLoginsAreLogged: a login the verifier turns away leaves one
// `login refused` line — provider, code, status, reason — because the wire
// answer reaches only the client, and a player reporting "Google sign-in does
// not work" otherwise leaves nothing to read in the journal (10 Sep 2026: one
// 401 in the metrics and no way to learn why). The credential never appears
// in that line, even though the google-auth-library messages this port
// reproduces on the wire quote the token back.
func TestRefusedLoginsAreLogged(t *testing.T) {
	strict := newHarness(t)
	strict.cfg.AllowFakeProviders = false
	strict.cfg.Google.ClientIDs = []string{"web.apps.googleusercontent.com"}
	handler := NewHandler(Deps{
		Config: strict.cfg, Users: strict.store, Tokens: strict.tokens, Verifier: NewVerifier(strict.cfg),
		Logger: slog.New(slog.NewJSONHandler(strict.logs, nil)),
	})
	mux := http.NewServeMux()
	handler.Register(mux)
	strict.mux = mux

	// A token of the wrong shape is refused before any network call, and the
	// library wording quotes it back on the wire (Node parity) — the log must
	// carry the reason without it.
	res := strict.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "google", "idToken": "not-a-jwt-xyz"})
	expectError(t, res, 401, CodeInvalidToken)
	if msg, _ := res.body["message"].(string); !strings.Contains(msg, "not-a-jwt-xyz") {
		t.Fatalf("wire message should be the Node one, token included: %s", res.raw)
	}
	logs := strict.logs.String()
	for _, want := range []string{`"msg":"login refused"`, `"provider":"google"`, `"code":"invalid_token"`, `"status":401`, `Wrong number of segments`} {
		if !strings.Contains(logs, want) {
			t.Errorf("log lacks %s: %s", want, logs)
		}
	}
	if strings.Contains(logs, "not-a-jwt-xyz") {
		t.Errorf("credential leaked into the log: %s", logs)
	}

	// Every verifier refusal goes the same way, whatever the provider.
	strict.logs.Reset()
	expectError(t, strict.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "google"}), 401, CodeMissingToken)
	if logs := strict.logs.String(); !strings.Contains(logs, `"msg":"login refused"`) || !strings.Contains(logs, `"code":"missing_token"`) {
		t.Errorf("missing_token not logged: %s", logs)
	}
	strict.logs.Reset()
	expectError(t, strict.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "guest", "deviceId": "abc"}), 400, CodeInvalidDeviceID)
	if logs := strict.logs.String(); !strings.Contains(logs, `"msg":"login refused"`) || !strings.Contains(logs, `"provider":"guest"`) || !strings.Contains(logs, `"status":400`) {
		t.Errorf("guest refusal not logged: %s", logs)
	}
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

// GET /api/auth/me/hands is gone with the `hands` table (owner's decision of
// 9 Sep 2026: it was write-only and no shipped client called it). An unknown
// /api/* path must still 404 as JSON.
func TestTheHandHistoryEndpointIsGone(t *testing.T) {
	h := newHarness(t)
	token, _ := h.login("device-guest-0001", "Suraj")
	res := h.do(http.MethodGet, "/api/auth/me/hands", nil, bearer(token)...)
	if res.status != 404 {
		t.Fatalf("status %d: %s", res.status, res.raw)
	}
	if res.body["error"] == nil {
		t.Fatalf("a removed /api/ path must 404 as JSON: %s", res.raw)
	}
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

func TestProfilesListsTheCatalogue(t *testing.T) {
	h := newHarness(t)

	// Anonymous: the catalogue is public, the free pictures read as owned and
	// the premium ones do not. A retired row is never listed.
	res := h.do(http.MethodGet, "/api/profiles", nil)
	if res.status != 200 {
		t.Fatalf("%d", res.status)
	}
	want := `{"profiles":[` +
		`{"id":1,"name":"Bear","url":"/profiles/bear.svg","type":"FREE","cost":0,"durationDays":0,"sortOrder":10,"owned":true,"expiresAt":0},` +
		`{"id":2,"name":"Cat","url":"/profiles/cat.svg","type":"FREE","cost":0,"durationDays":0,"sortOrder":20,"owned":true,"expiresAt":0},` +
		`{"id":3,"name":"Wolf","url":"/profiles/wolf.svg","type":"PREMIUM","cost":50000,"durationDays":30,"sortOrder":30,"owned":false,"expiresAt":0},` +
		`{"id":4,"name":"Lion","url":"/profiles/lion.svg","type":"PREMIUM","cost":25000,"durationDays":30,"sortOrder":40,"owned":false,"expiresAt":0}]}`
	if string(res.raw) != want {
		t.Errorf("got  %s\nwant %s", res.raw, want)
	}

	// With a token, what the player owns comes back owned.
	token, user := h.login("device-guest-0001", "Suraj")
	h.pictures.owned[user["id"].(string)] = map[int64]bool{3: true}
	res = h.do(http.MethodGet, "/api/profiles", nil, bearer(token)...)
	for _, p := range res.body["profiles"].([]any) {
		row := p.(map[string]any)
		want := row["id"].(float64) != 4 // everything but the Lion
		if row["owned"] != want {
			t.Errorf("%v owned=%v, want %v", row["id"], row["owned"], want)
		}
	}

	// A junk token is ignored, not refused: a stale session still gets a picker.
	res = h.do(http.MethodGet, "/api/profiles", nil, "Authorization", "Bearer nonsense")
	if res.status != 200 || len(res.body["profiles"].([]any)) != 4 {
		t.Errorf("junk token: %d %s", res.status, res.raw)
	}

	// An empty catalogue is [] and never null.
	h.pictures.retired = map[int64]bool{1: true, 2: true, 3: true, 4: true, 9: true}
	if res = h.do(http.MethodGet, "/api/profiles", nil); string(res.raw) != `{"profiles":[]}` {
		t.Errorf("empty catalogue: %s", res.raw)
	}
}

func TestWearingAPicture(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	id := user["id"].(string)

	// A free picture: chosen by catalogue id, and the wire carries its image.
	res := h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": 1}, bearer(token)...)
	if res.status != 200 {
		t.Fatalf("%d %s", res.status, res.raw)
	}
	u := res.body["user"].(map[string]any)
	if u["activePictureId"] != float64(1) || u["avatarUrl"] != "/profiles/bear.svg" {
		t.Errorf("%s", res.raw)
	}
	// The id may arrive as text just as well as a number.
	res = h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": "2"}, bearer(token)...)
	if res.status != 200 || res.body["user"].(map[string]any)["activePictureId"] != float64(2) {
		t.Errorf("string id: %d %s", res.status, res.raw)
	}

	// Anything that is not an id in the catalogue is unknown_avatar — which is
	// also where an old client sending a file name lands.
	for _, bad := range []any{"", 0, -1, false, "bear.svg", "nope", 404, []string{"1"}} {
		res := h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": bad}, bearer(token)...)
		expectError(t, res, 400, CodeUnknownAvatar)
		if res.body["message"] != MsgUnknownAvatar {
			t.Errorf("%v: %s", bad, res.raw)
		}
	}

	// A premium picture the player has not bought is refused, and buying it
	// makes the same request work.
	res = h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": 3}, bearer(token)...)
	expectError(t, res, 403, CodePictureLocked)
	if res.body["message"] != MsgPictureLocked {
		t.Errorf("%s", res.raw)
	}
	h.pictures.owned[id] = map[int64]bool{3: true}
	res = h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": 3}, bearer(token)...)
	if res.status != 200 || res.body["user"].(map[string]any)["avatarUrl"] != "/profiles/wolf.svg" {
		t.Errorf("owned premium: %d %s", res.status, res.raw)
	}

	// A retired picture cannot be put on, even by id.
	res = h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": 9}, bearer(token)...)
	expectError(t, res, 400, CodePictureRetired)

	// null / absent takes the picture off.
	res = h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": nil}, bearer(token)...)
	if res.status != 200 || res.body["user"].(map[string]any)["activePictureId"] != nil {
		t.Errorf("%d %s", res.status, res.raw)
	}
	h.store.users[id].ActivePictureID = ptrInt(2)
	res = h.do(http.MethodPost, "/api/profile/avatar", map[string]any{}, bearer(token)...)
	if res.status != 200 || res.body["user"].(map[string]any)["activePictureId"] != nil {
		t.Errorf("absent avatar must clear: %d %s", res.status, res.raw)
	}

	// Seated → 409 before any validation (requirement 21).
	h.seated[id] = true
	res = h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": 404}, bearer(token)...)
	expectError(t, res, 409, CodeSeated)
	if res.body["message"] != MsgSeatedAvatar {
		t.Errorf("%s", res.raw)
	}
	h.seated[id] = false
	expectError(t, h.do(http.MethodPost, "/api/profile/avatar", "{bad", bearer(token)...), 400, CodeInvalidJSON)
	expectError(t, h.do(http.MethodPost, "/api/profile/avatar", map[string]any{"avatar": 1}), 401, CodeMissingToken)
}

func TestBuyingAPremiumPicture(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	id := user["id"].(string)
	h.store.users[id].Chips = 60000

	res := h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": 3}, bearer(token)...)
	if res.status != 200 {
		t.Fatalf("%d %s", res.status, res.raw)
	}
	if res.body["charged"] != true || res.body["spent"] != float64(50000) {
		t.Errorf("%s", res.raw)
	}
	if res.body["user"].(map[string]any)["chips"] != float64(10000) {
		t.Errorf("wallet: %s", res.raw)
	}
	if pic := res.body["picture"].(map[string]any); pic["owned"] != true || pic["id"] != float64(3) {
		t.Errorf("picture: %s", res.raw)
	}

	// Buying it again is success with nothing charged — a click that arrives
	// twice must not cost twice.
	res = h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": 3}, bearer(token)...)
	if res.status != 200 || res.body["charged"] != false || res.body["spent"] != float64(0) {
		t.Errorf("replay: %d %s", res.status, res.raw)
	}
	if res.body["user"].(map[string]any)["chips"] != float64(10000) {
		t.Errorf("replay moved chips: %s", res.raw)
	}

	// Buying does not put it on — that is a separate request.
	if h.store.users[id].ActivePictureID != nil {
		t.Errorf("buying dressed the player: %v", h.store.users[id].ActivePictureID)
	}

	// A wallet that cannot cover it.
	res = h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": 4}, bearer(token)...)
	expectError(t, res, 409, CodePictureChips)
	if res.body["message"] != MsgPictureChips {
		t.Errorf("%s", res.raw)
	}

	// Free, retired, and unknown.
	expectError(t, h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": 1}, bearer(token)...), 400, CodePictureFree)
	expectError(t, h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": 9}, bearer(token)...), 400, CodePictureRetired)
	for _, bad := range []any{404, "wolf.svg", nil, ""} {
		expectError(t, h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": bad}, bearer(token)...), 400, CodeUnknownAvatar)
	}

	// Seated → 409 before anything else. A seated wallet may only move at the
	// three hand checkpoints, so the till is shut at the table.
	h.seated[id] = true
	res = h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": 4}, bearer(token)...)
	expectError(t, res, 409, CodeSeated)
	if res.body["message"] != MsgSeatedPicture {
		t.Errorf("%s", res.raw)
	}
	h.seated[id] = false
	expectError(t, h.do(http.MethodPost, "/api/profile/picture/buy", map[string]any{"pictureId": 4}), 401, CodeMissingToken)
}

func ptrInt(n int64) *int64 { return &n }

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

// A reward may only be collected FROM THE LOBBY (owner's decision of 9 Sep
// 2026). That gate is what makes the money model's invariant true: a seated
// player's wallet in PostgreSQL cannot change except at the three checkpoints
// (pack, leave/switch, hand end). It is checked before any database work, in
// the same place as the name and avatar gates.
func TestRewardsAreRefusedWhileSeated(t *testing.T) {
	h := newHarness(t)
	token, user := h.login("device-guest-0001", "Suraj")
	id := user["id"].(string)
	h.store.milestOK[id] = true
	h.store.bonusAt[id] = 0
	chipsBefore := h.store.users[id].Chips

	h.seated[id] = true
	for _, tc := range []struct {
		path string
		msg  string
	}{
		{"/api/rewards/milestone", MsgSeatedMilestone},
		{"/api/rewards/bonus", MsgSeatedBonus},
	} {
		res := h.do(http.MethodPost, tc.path, map[string]any{}, bearer(token)...)
		expectError(t, res, 409, CodeSeated)
		if res.body["message"] != tc.msg {
			t.Errorf("%s message = %v", tc.path, res.body["message"])
		}
		// Refused before any database work: nothing was claimed.
		if h.store.users[id].Chips != chipsBefore {
			t.Fatalf("%s credited a seated player: %d → %d", tc.path, chipsBefore, h.store.users[id].Chips)
		}
	}

	// From the lobby both go through.
	h.seated[id] = false
	res := h.do(http.MethodPost, "/api/rewards/milestone", map[string]any{}, bearer(token)...)
	if res.status != 200 || res.body["claimed"] != true {
		t.Fatalf("milestone from the lobby: %d %s", res.status, res.raw)
	}
	res = h.do(http.MethodPost, "/api/rewards/bonus", map[string]any{}, bearer(token)...)
	if res.status != 200 || res.body["claimed"] != true {
		t.Fatalf("bonus from the lobby: %d %s", res.status, res.raw)
	}
}
