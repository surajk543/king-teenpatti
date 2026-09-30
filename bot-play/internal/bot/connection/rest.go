package connection

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// REST client defaults. The pool is sized for a fleet of hundreds of bots
// against one host: at a fleet's start every bot logs in, reads the
// catalogue and its account at once, and each keeps a pooled connection
// rather than opening one per call.
const (
	// DefaultAPITimeout bounds one REST call end to end (connect, headers,
	// body) when NewHTTPAPI builds the client.
	DefaultAPITimeout = 15 * time.Second
	// maxAnswerBytes caps an answer body read into memory (GET /api/tables
	// and GET /api/profiles are the largest, a few tens of KB).
	maxAnswerBytes = 4 << 20
)

// How the fleet declares itself to the game server's app version gate
// (go-server/internal/appversion, 28 Sep 2026): the platform "bot", on every
// REST call (the X-App-Platform header) and in the socket handshake's auth
// object (appPlatform, beside the token). A bot is the project's own client,
// never the app, so the gate never refuses it — not for a minimum version, not
// for a maintenance, not with APP_VERSION_REQUIRED on. It sends no version:
// a bot has none to compare.
const (
	AppPlatform       = "bot"
	AppPlatformHeader = "X-App-Platform"
)

// HTTPAPI is protocol.API against the real server's REST endpoints, over
// one shared *http.Client (pooled connections). Safe for concurrent use.
//
// Every refusal (a status outside 2xx) is a *protocol.APIError carrying the
// server's {error, message}; an answer that is not that shape (a proxy's 502
// page, say) gets Code "http_<status>". Network failures and a context that
// ended are returned wrapped, never as an APIError. Tokens travel only in
// the Authorization header and are never logged or put into an error.
type HTTPAPI struct {
	base   string
	client *http.Client
}

// NewHTTPAPI: baseURL is http(s)://host[:port]; client nil → a pooled
// client with a 15 s timeout.
func NewHTTPAPI(baseURL string, client *http.Client) *HTTPAPI {
	if client == nil {
		client = NewHTTPClient()
	}
	return &HTTPAPI{base: strings.TrimRight(strings.TrimSpace(baseURL), "/"), client: client}
}

// NewHTTPClient is the pooled client NewHTTPAPI uses by default: a 15 s
// timeout per call and keep-alive connections enough for a fleet of
// hundreds of bots on one host.
func NewHTTPClient() *http.Client {
	return &http.Client{
		Timeout: DefaultAPITimeout,
		Transport: &http.Transport{
			Proxy: http.ProxyFromEnvironment,
			DialContext: (&net.Dialer{
				Timeout:   5 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
			ForceAttemptHTTP2:     true,
			MaxIdleConns:          512,
			MaxIdleConnsPerHost:   256,
			IdleConnTimeout:       90 * time.Second,
			TLSHandshakeTimeout:   10 * time.Second,
			ExpectContinueTimeout: time.Second,
			ResponseHeaderTimeout: DefaultAPITimeout,
		},
	}
}

var _ protocol.API = (*HTTPAPI)(nil)

// loginRequest is POST /api/auth/login's body for a guest.
type loginRequest struct {
	Provider    string `json:"provider"`
	DeviceID    string `json:"deviceId"`
	DisplayName string `json:"displayName,omitempty"`
}

// userAnswer is {user} (GET /api/auth/me, POST /api/profile/avatar).
type userAnswer struct {
	User *protocol.User `json:"user"`
}

// profilesAnswer is GET /api/profiles' {profiles:[…]}, the part a bot reads.
type profilesAnswer struct {
	Profiles []struct {
		ID          int64  `json:"id"`
		AssetFormat string `json:"assetFormat"`
		Type        string `json:"type"`
	} `json:"profiles"`
}

// Login is POST /api/auth/login {provider:"guest", deviceId, displayName}.
func (a *HTTPAPI) Login(ctx context.Context, deviceID, displayName string) (protocol.LoginResult, error) {
	var out protocol.LoginResult
	body := loginRequest{Provider: "guest", DeviceID: deviceID, DisplayName: displayName}
	if err := a.do(ctx, http.MethodPost, "/api/auth/login", "", body, &out); err != nil {
		return protocol.LoginResult{}, err
	}
	if out.Token == "" {
		return protocol.LoginResult{}, fmt.Errorf("api: POST /api/auth/login: the answer carries no token")
	}
	return out, nil
}

// Tables is GET /api/tables.
func (a *HTTPAPI) Tables(ctx context.Context) (protocol.Catalogue, error) {
	var out protocol.Catalogue
	if err := a.do(ctx, http.MethodGet, "/api/tables", "", nil, &out); err != nil {
		return protocol.Catalogue{}, err
	}
	return out, nil
}

// Me is GET /api/auth/me.
func (a *HTTPAPI) Me(ctx context.Context, token string) (protocol.User, error) {
	return a.user(ctx, http.MethodGet, "/api/auth/me", token, nil)
}

// FreePictureIDs reads GET /api/profiles and keeps FREE, non-RIVE rows, in
// the catalogue's order. It sends no token: the listing is public, and a
// FREE row is anyone's.
func (a *HTTPAPI) FreePictureIDs(ctx context.Context) ([]int64, error) {
	var out profilesAnswer
	if err := a.do(ctx, http.MethodGet, "/api/profiles", "", nil, &out); err != nil {
		return nil, err
	}
	ids := make([]int64, 0, len(out.Profiles))
	for _, p := range out.Profiles {
		if strings.EqualFold(p.Type, "FREE") && !strings.EqualFold(p.AssetFormat, "RIVE") && p.ID > 0 {
			ids = append(ids, p.ID)
		}
	}
	return ids, nil
}

// WearPicture is POST /api/profile/avatar {avatar: id}.
func (a *HTTPAPI) WearPicture(ctx context.Context, token string, pictureID int64) error {
	body := struct {
		Avatar int64 `json:"avatar"`
	}{pictureID}
	return a.do(ctx, http.MethodPost, "/api/profile/avatar", token, body, nil)
}

// user runs a call answered with {user, …} and returns the user.
func (a *HTTPAPI) user(ctx context.Context, method, path, token string, body any) (protocol.User, error) {
	var out userAnswer
	if err := a.do(ctx, method, path, token, body, &out); err != nil {
		return protocol.User{}, err
	}
	if out.User == nil {
		return protocol.User{}, fmt.Errorf("api: %s %s: the answer carries no user", method, path)
	}
	return *out.User, nil
}

// errorAnswer is every REST refusal's body: {error: code, message}.
type errorAnswer struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

// do sends one call — body as JSON when non-nil, the token as a bearer
// header when non-empty — and decodes a 2xx answer into out (nil: the
// answer is read and dropped, so the connection is reused).
func (a *HTTPAPI) do(ctx context.Context, method, path, token string, body, out any) error {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("api: %s %s: encoding the request: %w", method, path, err)
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, a.base+path, reader)
	if err != nil {
		return fmt.Errorf("api: %s %s: %w", method, path, err)
	}
	req.Header.Set("Accept", "application/json")
	// The game server's app version gate (28 Sep 2026): the fleet declares
	// itself a bot, so no minimum version, no maintenance and no
	// APP_VERSION_REQUIRED ever turns it away.
	req.Header.Set(AppPlatformHeader, AppPlatform)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := a.client.Do(req)
	if err != nil {
		// *url.Error names the method and URL (no token: that is a header)
		// and unwraps to the cause, context errors included.
		return fmt.Errorf("api: %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxAnswerBytes))
	if err != nil {
		return fmt.Errorf("api: %s %s: reading the answer: %w", method, path, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return apiError(resp.StatusCode, data)
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("api: %s %s: decoding the answer: %w", method, path, err)
	}
	return nil
}

// apiError reads a refusal: the server's {error, message}, or — for a body
// that is not one — Code "http_<status>" and the status text.
func apiError(status int, body []byte) *protocol.APIError {
	var e errorAnswer
	if err := json.Unmarshal(body, &e); err == nil && e.Error != "" {
		return &protocol.APIError{Status: status, Code: e.Error, Message: e.Message}
	}
	return &protocol.APIError{Status: status, Code: "http_" + strconv.Itoa(status), Message: http.StatusText(status)}
}
