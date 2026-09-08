package auth

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

func fixedNow() time.Time { return time.Unix(1_800_000_000, 123_000_000) }

func testUser() *db.User {
	return &db.User{ID: "0c3e1f46-0d3f-4a4e-9a5b-7e3d1c2b4a5f", Provider: db.ProviderGuest, DisplayName: "Suraj K", Chips: 200000}
}

func newTokens(now func() time.Time) *Tokens {
	return NewTokens(config.DefaultJWTSecret, 30*24*time.Hour, now)
}

func decodeSegment(t *testing.T, seg string) map[string]any {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(seg)
	if err != nil {
		t.Fatalf("segment %q: %v", seg, err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("segment %q: %v", seg, err)
	}
	return m
}

func TestIssueProducesNodeShapedToken(t *testing.T) {
	tok := newTokens(fixedNow)
	token, err := tok.Issue(testUser())
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token has %d segments", len(parts))
	}
	// Header byte-exact as jsonwebtoken writes it.
	if header, _ := base64.RawURLEncoding.DecodeString(parts[0]); string(header) != `{"alg":"HS256","typ":"JWT"}` {
		t.Errorf("header %s", header)
	}
	payload := decodeSegment(t, parts[1])
	want := map[string]any{
		"sub": testUser().ID, "provider": "guest", "name": "Suraj K",
		"iat": float64(1_800_000_000), "exp": float64(1_800_000_000 + 30*24*3600),
	}
	if len(payload) != len(want) {
		t.Errorf("payload has extra claims: %v", payload)
	}
	for k, v := range want {
		if payload[k] != v {
			t.Errorf("claim %s = %v, want %v", k, payload[k], v)
		}
	}
	claims, err := tok.Verify(token)
	if err != nil {
		t.Fatal(err)
	}
	if claims.Subject != testUser().ID || claims.Provider != "guest" || claims.Name != "Suraj K" {
		t.Errorf("claims %+v", claims)
	}
}

func TestVerifyRefusals(t *testing.T) {
	now := fixedNow()
	tok := newTokens(func() time.Time { return now })
	other := NewTokens("another-secret", time.Hour, fixedNow)

	valid, _ := tok.Issue(testUser())
	wrongSecret, _ := other.Issue(testUser())
	expired, _ := NewTokens(config.DefaultJWTSecret, time.Second, func() time.Time { return now.Add(-time.Hour) }).Issue(testUser())
	hs384, _ := jwt.NewWithClaims(jwt.SigningMethodHS384, jwt.MapClaims{"sub": "x"}).SignedString([]byte(config.DefaultJWTSecret))
	none, _ := jwt.NewWithClaims(jwt.SigningMethodNone, jwt.MapClaims{"sub": "x"}).SignedString(jwt.UnsafeAllowNoneSignatureType)
	notYet, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"sub": "x", "nbf": now.Unix() + 60}).SignedString([]byte(config.DefaultJWTSecret))
	noExp, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"sub": "x", "iat": 1}).SignedString([]byte(config.DefaultJWTSecret))

	cases := []struct {
		name, token, code, reason string
	}{
		{"empty", "", CodeMissingToken, "A session token is required"},
		{"garbage", "nonsense", CodeInvalidSession, "jwt malformed"},
		{"two segments", "a.b", CodeInvalidSession, "jwt malformed"},
		{"wrong secret", wrongSecret, CodeInvalidSession, "invalid signature"},
		{"expired", expired, CodeInvalidSession, "jwt expired"},
		{"HS384 pinned out (DECISIONS §5)", hs384, CodeInvalidSession, "invalid algorithm"},
		{"alg none", none, CodeInvalidSession, "invalid algorithm"},
		{"not before", notYet, CodeInvalidSession, "jwt not active"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := tok.Verify(tc.token)
			var authErr *AuthError
			if !errors.As(err, &authErr) {
				t.Fatalf("want AuthError, got %v", err)
			}
			if authErr.Code != tc.code || authErr.Status != http.StatusUnauthorized {
				t.Errorf("code %s status %d", authErr.Code, authErr.Status)
			}
			if !strings.Contains(authErr.Message, tc.reason) {
				t.Errorf("message %q lacks %q", authErr.Message, tc.reason)
			}
			if tc.code == CodeInvalidSession && !strings.HasPrefix(authErr.Message, "Session token rejected: ") {
				t.Errorf("message %q", authErr.Message)
			}
		})
	}
	if _, err := tok.Verify(valid); err != nil {
		t.Errorf("valid token: %v", err)
	}
	// jsonwebtoken defaults: a token without exp never expires.
	if _, err := tok.Verify(noExp); err != nil {
		t.Errorf("token without exp must verify: %v", err)
	}
	// Exactly at exp is expired (now >= exp, no tolerance).
	atExp := NewTokens(config.DefaultJWTSecret, time.Minute, func() time.Time { return now.Add(-time.Minute) })
	atToken, _ := atExp.Issue(testUser())
	if _, err := tok.Verify(atToken); err == nil {
		t.Error("token expiring exactly now must be refused")
	}
	// Errors compare by code through errors.Is.
	_, err := tok.Verify("x")
	if !errors.Is(err, &AuthError{Code: CodeInvalidSession}) {
		t.Errorf("errors.Is on code: %v", err)
	}
}

func TestTokenFromRequest(t *testing.T) {
	for _, tc := range []struct{ header, want string }{
		{"Bearer abc.def.ghi", "abc.def.ghi"},
		{"bearer abc", "abc"},
		{"BEARER abc", "abc"},
		{"Bearer  abc ", "abc"},
		{"Bearer    ", ""},
		{"Bearer", ""},
		{"Basic abc", ""},
		{"Token abc", ""},
		{"", ""},
	} {
		r := httptest.NewRequest(http.MethodGet, "/api/auth/me", nil)
		if tc.header != "" {
			r.Header.Set("Authorization", tc.header)
		}
		if got := TokenFromRequest(r); got != tc.want {
			t.Errorf("TokenFromRequest(%q) = %q, want %q", tc.header, got, tc.want)
		}
	}
}

// TestNodeIssuedTokenVerifiesInGo: a token minted by jsonwebtoken with the
// dev secret must be accepted — Flutter sessions issued by the Node server
// survive the switch (rolling deploy).
func TestNodeIssuedTokenVerifiesInGo(t *testing.T) {
	token := runNode(t, `
const jwt = require('jsonwebtoken');
process.stdout.write(jwt.sign({ sub: 'user-from-node', provider: 'guest', name: 'Ravi' }, process.env.SECRET, { expiresIn: '30d' }));`,
		"SECRET="+config.DefaultJWTSecret)
	claims, err := newTokens(time.Now).Verify(token)
	if err != nil {
		t.Fatalf("Node token refused: %v", err)
	}
	if claims.Subject != "user-from-node" || claims.Provider != "guest" || claims.Name != "Ravi" {
		t.Errorf("claims %+v", claims)
	}
	// And the Node-signed token with a different secret is refused here.
	if _, err := NewTokens("other", time.Hour, time.Now).Verify(token); err == nil {
		t.Error("Node token with a different secret must be refused")
	}
}

// TestGoIssuedTokenVerifiesInNode: the reverse direction — a Go-minted token
// is accepted by jsonwebtoken.verify with default options.
func TestGoIssuedTokenVerifiesInNode(t *testing.T) {
	token, err := newTokens(time.Now).Issue(testUser())
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Sub      string `json:"sub"`
		Provider string `json:"provider"`
		Name     string `json:"name"`
		Iat      int64  `json:"iat"`
		Exp      int64  `json:"exp"`
		Header   struct {
			Alg string `json:"alg"`
			Typ string `json:"typ"`
		} `json:"header"`
	}
	nodeJSON(t, `
const jwt = require('jsonwebtoken');
const payload = jwt.verify(process.env.TOKEN, process.env.SECRET);
payload.header = jwt.decode(process.env.TOKEN, { complete: true }).header;
process.stdout.write(JSON.stringify(payload));`, &decoded,
		"TOKEN="+token, "SECRET="+config.DefaultJWTSecret)
	if decoded.Sub != testUser().ID || decoded.Provider != "guest" || decoded.Name != "Suraj K" {
		t.Errorf("Node decoded %+v", decoded)
	}
	if decoded.Exp-decoded.Iat != 30*24*3600 {
		t.Errorf("exp-iat = %d", decoded.Exp-decoded.Iat)
	}
	if decoded.Header.Alg != "HS256" || decoded.Header.Typ != "JWT" {
		t.Errorf("header %+v", decoded.Header)
	}
}
