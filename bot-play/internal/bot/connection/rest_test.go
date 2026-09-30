package connection

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// seen is one request as the fake REST server received it.
type seen struct {
	method, path, auth, contentType string
	body                            map[string]any
	platform                        string // X-App-Platform
}

// restServer answers each path with a status and a body, and records every
// request.
type restServer struct {
	srv     *httptest.Server
	mu      sync.Mutex
	got     []seen
	answers map[string]func(w http.ResponseWriter)
}

func newRESTServer(t *testing.T, answers map[string]func(w http.ResponseWriter)) *restServer {
	t.Helper()
	rs := &restServer{answers: answers}
	rs.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		var body map[string]any
		if len(data) > 0 {
			_ = json.Unmarshal(data, &body)
		}
		rs.mu.Lock()
		rs.got = append(rs.got, seen{r.Method, r.URL.Path, r.Header.Get("Authorization"), r.Header.Get("Content-Type"), body, r.Header.Get(AppPlatformHeader)})
		rs.mu.Unlock()
		answer, ok := rs.answers[r.Method+" "+r.URL.Path]
		if !ok {
			writeJSON(w, http.StatusNotFound, `{"error":"not_found","message":"Not found"}`)
			return
		}
		answer(w)
	}))
	t.Cleanup(rs.srv.Close)
	return rs
}

func (rs *restServer) last(t *testing.T) seen {
	t.Helper()
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if len(rs.got) == 0 {
		t.Fatal("no request reached the server")
	}
	return rs.got[len(rs.got)-1]
}

func writeJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, body)
}

func answer(status int, body string) func(http.ResponseWriter) {
	return func(w http.ResponseWriter) { writeJSON(w, status, body) }
}

const userJSON = `{"id":"u1","displayName":"Bot One","chips":1000000,"activePictureId":null,"email":null,"diamond":9}`

func TestLoginSignsInAGuestDevice(t *testing.T) {
	rs := newRESTServer(t, map[string]func(http.ResponseWriter){
		"POST /api/auth/login": answer(200, `{"token":"tok-1","user":`+userJSON+`,"isNew":true,"welcomeChips":1000000}`),
	})
	api := NewHTTPAPI(rs.srv.URL+"/", nil) // a trailing slash is tolerated
	res, err := api.Login(context.Background(), "botplay-v1-7", "Bot One")
	if err != nil {
		t.Fatal(err)
	}
	if res.Token != "tok-1" || !res.IsNew || res.WelcomeChips != 1000000 ||
		res.User.ID != "u1" || res.User.Chips != 1000000 || res.User.ActivePictureID != nil {
		t.Fatalf("login decoded as %+v", res)
	}
	got := rs.last(t)
	if got.method != http.MethodPost || got.path != "/api/auth/login" || got.auth != "" ||
		!strings.HasPrefix(got.contentType, "application/json") {
		t.Fatalf("request %+v", got)
	}
	want := map[string]any{"provider": "guest", "deviceId": "botplay-v1-7", "displayName": "Bot One"}
	if len(got.body) != len(want) {
		t.Fatalf("body %v", got.body)
	}
	for k, v := range want {
		if got.body[k] != v {
			t.Fatalf("body %v", got.body)
		}
	}
}

// Every REST call declares the fleet a bot, signed in or not, so the game
// server's app version gate never refuses it (28 Sep 2026).
func TestEveryCallDeclaresTheFleetABot(t *testing.T) {
	rs := newRESTServer(t, map[string]func(http.ResponseWriter){
		"POST /api/auth/login": answer(200, `{"token":"tok-1","user":`+userJSON+`,"isNew":false,"welcomeChips":0}`),
		"GET /api/auth/me":     answer(200, `{"user":`+userJSON+`}`),
	})
	api := NewHTTPAPI(rs.srv.URL, nil)
	if _, err := api.Login(context.Background(), "botplay-v1-7", "Bot One"); err != nil {
		t.Fatal(err)
	}
	if _, err := api.Me(context.Background(), "tok-1"); err != nil {
		t.Fatal(err)
	}
	rs.mu.Lock()
	defer rs.mu.Unlock()
	for _, got := range rs.got {
		if got.platform != "bot" {
			t.Errorf("%s %s declared %q, want bot", got.method, got.path, got.platform)
		}
	}
}

func TestALoginWithoutATokenIsAnError(t *testing.T) {
	rs := newRESTServer(t, map[string]func(http.ResponseWriter){
		"POST /api/auth/login": answer(200, `{"user":`+userJSON+`}`),
	})
	if _, err := NewHTTPAPI(rs.srv.URL, nil).Login(context.Background(), "d", "n"); err == nil {
		t.Fatal("a login answer with no token was accepted")
	}
}

func TestRefusalsAreAPIErrorsWithTheServersCode(t *testing.T) {
	rs := newRESTServer(t, map[string]func(http.ResponseWriter){
		"POST /api/auth/login": answer(429, `{"error":"rate_limited","message":""}`),
		"GET /api/auth/me": func(w http.ResponseWriter) {
			w.Header().Set("Content-Type", "text/html")
			w.WriteHeader(http.StatusBadGateway)
			_, _ = io.WriteString(w, "<html>502 Bad Gateway</html>")
		},
		"GET /api/tables":          answer(503, `{"code":1}`),
		"POST /api/profile/avatar": answer(403, `{"error":"picture_locked","message":"Buy this picture before wearing it.","pictureId":99}`),
	})
	api := NewHTTPAPI(rs.srv.URL, nil)
	ctx := context.Background()

	check := func(err error, status int, code, message string) {
		t.Helper()
		var ae *protocol.APIError
		if !errors.As(err, &ae) {
			t.Fatalf("err = %v, want an APIError", err)
		}
		if ae.Status != status || ae.Code != code || ae.Message != message {
			t.Fatalf("APIError %+v, want %d %s %q", ae, status, code, message)
		}
	}
	_, err := api.Login(ctx, "d", "n")
	check(err, 429, "rate_limited", "")
	_, err = api.Me(ctx, "tok")
	check(err, 502, "http_502", "Bad Gateway")
	_, err = api.Tables(ctx)
	check(err, 503, "http_503", "Service Unavailable")
	check(api.WearPicture(ctx, "tok", 99), 403, "picture_locked", "Buy this picture before wearing it.")
	_, err = api.FreePictureIDs(ctx) // an unanswered path: 404
	check(err, 404, "not_found", "Not found")
}

func TestOnlyAuthenticatedCallsCarryTheBearerToken(t *testing.T) {
	rs := newRESTServer(t, map[string]func(http.ResponseWriter){
		"GET /api/auth/me":         answer(200, `{"user":`+userJSON+`}`),
		"POST /api/profile/avatar": answer(200, `{"user":`+userJSON+`}`),
		"GET /api/tables":          answer(200, `{"version":"v1","tables":[]}`),
		"GET /api/profiles":        answer(200, `{"profiles":[]}`),
	})
	api := NewHTTPAPI(rs.srv.URL, nil)
	ctx := context.Background()

	u, err := api.Me(ctx, "tok-me")
	if err != nil || u.ID != "u1" {
		t.Fatalf("Me: %+v, %v", u, err)
	}
	if got := rs.last(t); got.auth != "Bearer tok-me" || got.method != http.MethodGet {
		t.Fatalf("Me sent %+v", got)
	}
	if err := api.WearPicture(ctx, "tok-wear", 7); err != nil {
		t.Fatal(err)
	}
	got := rs.last(t)
	if got.auth != "Bearer tok-wear" || got.path != "/api/profile/avatar" {
		t.Fatalf("WearPicture sent %+v", got)
	}
	if id, ok := got.body["avatar"].(float64); !ok || id != 7 {
		t.Fatalf("the avatar went as %#v, want the number 7", got.body["avatar"])
	}
	if _, err := api.Tables(ctx); err != nil {
		t.Fatal(err)
	}
	if got := rs.last(t); got.auth != "" {
		t.Fatalf("Tables sent a token: %+v", got)
	}
	if _, err := api.FreePictureIDs(ctx); err != nil {
		t.Fatal(err)
	}
	if got := rs.last(t); got.auth != "" {
		t.Fatalf("FreePictureIDs sent a token: %+v", got)
	}
}

func TestAnAnswerWithNoUserIsAnError(t *testing.T) {
	rs := newRESTServer(t, map[string]func(http.ResponseWriter){
		"GET /api/auth/me": answer(200, `{}`),
	})
	if _, err := NewHTTPAPI(rs.srv.URL, nil).Me(context.Background(), "t"); err == nil {
		t.Fatal("an answer with no user was accepted")
	}
}

func TestTablesDecodesTheCatalogue(t *testing.T) {
	rs := newRESTServer(t, map[string]func(http.ResponseWriter){
		"GET /api/tables": answer(200, `{"version":"abc","source":"db","turnTimeoutMs":25000,"maxPlayers":5,
			"tables":[{"key":"blind:200","engine":"teen_patti","category":"blind","bootAmount":200,"minChips":0,"maxChips":2000000,
			"maxPot":0,"maxBlindMoves":4,"isPrivate":false,"sortOrder":20,"turnTimeoutMs":25000,"winnerTax":true,"extra":1}],
			"privateTables":[],"engines":[]}`),
	})
	cat, err := NewHTTPAPI(rs.srv.URL, nil).Tables(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if cat.Version != "abc" || cat.MaxPlayers != 5 || len(cat.Tables) != 1 {
		t.Fatalf("catalogue %+v", cat)
	}
	tb := cat.Tables[0]
	if tb.Key != "blind:200" || tb.Engine != protocol.EngineTeenPatti || tb.BootAmount != 200 || tb.MaxChips != 2000000 || !tb.WinnerTax {
		t.Fatalf("table %+v", tb)
	}
}

func TestFreePictureIDsKeepsOnlyFreeRowsThatAreNotRive(t *testing.T) {
	rs := newRESTServer(t, map[string]func(http.ResponseWriter){
		"GET /api/profiles": answer(200, `{"profiles":[
			{"id":1,"name":"Bear","assetFormat":"SVG","type":"FREE","currency":"COIN","cost":0},
			{"id":2,"name":"Cat","assetFormat":"IMAGE","type":"FREE"},
			{"id":3,"name":"Rich","assetFormat":"LOTTIE","type":"PREMIUM","cost":100000},
			{"id":4,"name":"Spin","assetFormat":"RIVE","type":"FREE"},
			{"id":5,"name":"Wave","assetFormat":"LOTTIE","type":"FREE"},
			{"id":0,"name":"Broken","assetFormat":"SVG","type":"FREE"}]}`),
	})
	ids, err := NewHTTPAPI(rs.srv.URL, nil).FreePictureIDs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 3 || ids[0] != 1 || ids[1] != 2 || ids[2] != 5 {
		t.Fatalf("ids %v, want [1 2 5]", ids)
	}
}

func TestNetworkFailuresAreWrappedNotAPIErrors(t *testing.T) {
	rs := newRESTServer(t, nil)
	base := rs.srv.URL
	rs.srv.Close()
	_, err := NewHTTPAPI(base, nil).Tables(context.Background())
	var ae *protocol.APIError
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("a refused connection: %v", err)
	}
	if !strings.Contains(err.Error(), "GET /api/tables") {
		t.Fatalf("the error does not say which call: %v", err)
	}

	hang := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer hang.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, err = NewHTTPAPI(hang.URL, nil).Me(ctx, "secret-token")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("a timed-out call: %v", err)
	}
	if strings.Contains(err.Error(), "secret-token") {
		t.Fatalf("the token reached an error: %v", err)
	}

	bad := newRESTServer(t, map[string]func(http.ResponseWriter){
		"GET /api/tables": answer(200, `not json`),
	})
	if _, err := NewHTTPAPI(bad.srv.URL, nil).Tables(context.Background()); err == nil || errors.As(err, &ae) {
		t.Fatalf("an unreadable answer: %v", err)
	}
}

func TestTheDefaultClientIsPooledAndBounded(t *testing.T) {
	api := NewHTTPAPI("http://127.0.0.1:1", nil)
	if api.client == nil || api.client.Timeout != DefaultAPITimeout {
		t.Fatalf("client %+v", api.client)
	}
	tr, ok := api.client.Transport.(*http.Transport)
	if !ok || tr.MaxIdleConnsPerHost < 100 || tr.MaxIdleConns < tr.MaxIdleConnsPerHost {
		t.Fatalf("transport %+v", api.client.Transport)
	}
	own := &http.Client{}
	if NewHTTPAPI("http://x", own).client != own {
		t.Fatal("a given client was not used")
	}
}
