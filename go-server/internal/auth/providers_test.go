package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

func authErr(t *testing.T, err error) *AuthError {
	t.Helper()
	var ae *AuthError
	if !errors.As(err, &ae) {
		t.Fatalf("want *AuthError, got %v", err)
	}
	return ae
}

func expectAuthErr(t *testing.T, err error, code string, status int, message string) {
	t.Helper()
	ae := authErr(t, err)
	if ae.Code != code || ae.Status != status || (message != "" && ae.Message != message) {
		t.Errorf("got %s/%d %q, want %s/%d %q", ae.Code, ae.Status, ae.Message, code, status, message)
	}
}

func TestVerifyGuest(t *testing.T) {
	p, err := VerifyGuest("device-guest-0001", "Suraj")
	if err != nil {
		t.Fatal(err)
	}
	if p.Provider != db.ProviderGuest || p.DisplayName != "Suraj" || p.Email != nil || p.AvatarURL != nil {
		t.Errorf("profile %+v", p)
	}
	if len(p.ProviderUserID) != 64 || strings.ToLower(p.ProviderUserID) != p.ProviderUserID || p.ProviderUserID == "device-guest-0001" {
		t.Errorf("provider_user_id must be 64 lower-case hex, never the raw id: %q", p.ProviderUserID)
	}
	// Default name: "Guest" + first 5 hex upper-cased.
	anon, _ := VerifyGuest("device-guest-0001", "")
	if anon.DisplayName != "Guest"+strings.ToUpper(p.ProviderUserID[:5]) {
		t.Errorf("default name %q", anon.DisplayName)
	}
	// One-character names fall back too; the device id is trimmed first.
	one, _ := VerifyGuest("  device-guest-0001  ", "A")
	if one.ProviderUserID != p.ProviderUserID || one.DisplayName != anon.DisplayName {
		t.Errorf("trim/one-char: %+v", one)
	}
	for _, bad := range []string{"", "abc", "1234567", "   1234567   "} {
		_, err := VerifyGuest(bad, "x")
		expectAuthErr(t, err, CodeInvalidDeviceID, http.StatusBadRequest, "A deviceId of at least 8 characters is required")
	}
	if _, err := VerifyGuest("12345678", ""); err != nil {
		t.Errorf("exactly 8 chars: %v", err)
	}
	// Length is UTF-16 units: four emoji are 8 units.
	if _, err := VerifyGuest("\U0001F600\U0001F600\U0001F600\U0001F600", ""); err != nil {
		t.Errorf("4 astral chars are 8 UTF-16 units: %v", err)
	}
}

// TestGuestHashMatchesNode: the provider_user_id must equal Node's
// sha256('teenpatti:' + deviceId) so every existing guest account resolves.
func TestGuestHashMatchesNode(t *testing.T) {
	for _, deviceID := range []string{"device-guest-0001", "practice-bot-0-Ravi", " padded-device-id ", "ünïcödé-device"} {
		var want struct {
			Hash string `json:"hash"`
			Name string `json:"name"`
		}
		nodeJSON(t, `
const { createHash } = require('node:crypto');
const trimmed = String(process.env.DEVICE_ID).trim();
const hash = createHash('sha256').update('teenpatti:' + trimmed).digest('hex');
process.stdout.write(JSON.stringify({ hash, name: 'Guest' + hash.slice(0, 5).toUpperCase() }));`, &want, "DEVICE_ID="+deviceID)
		got, err := VerifyGuest(deviceID, "")
		if err != nil {
			t.Fatal(err)
		}
		if got.ProviderUserID != want.Hash || got.DisplayName != want.Name {
			t.Errorf("%q: got %s/%s want %s/%s", deviceID, got.ProviderUserID, got.DisplayName, want.Hash, want.Name)
		}
	}
}

const (
	nul  = "\u0000"
	zwsp = "\u200B"
	zwj  = "\u200D"
	bom  = "\uFEFF"
	nbsp = "\u00A0"
	nel  = "\u0085"
	grin = "\U0001F600"
)

func TestSanitizeName(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"Suraj", "Suraj"},
		{"  Suraj  K  ", "Suraj  K"},                // interior runs are kept
		{"A" + nul + "b" + zwsp + "c-d!", "Abc-d!"}, // NUL and ZWSP stripped, punctuation kept
		{"A", ""},
		{"", ""},
		{" \t ", ""},
		{bom + "ab" + zwj, "ab"}, // BOM and ZWJ are \p{C}
		{strings.Repeat("a", 30), strings.Repeat("a", 24)},
		{"सुरज कुमार", "सुरज कुमार"},                                             // marks (\p{M}) survive
		{strings.Repeat(grin, 12), strings.Repeat(grin, 12)},                     // 24 UTF-16 units exactly
		{strings.Repeat(grin, 13), strings.Repeat(grin, 12)},                     // the 13th would be split → dropped whole
		{"abcdefghijklmnopqrstuvw" + grin, "abcdefghijklmnopqrstuvw"},            // 23 + a pair straddling 24
		{"abcdefghijklmnopqrstuv" + grin + "x", "abcdefghijklmnopqrstuv" + grin}, // 22 + pair = 24, x cut
		{"a" + nel + "b", "ab"},              // NEL is Cc → stripped
		{nbsp + "ab" + nbsp, "ab"},           // NBSP trimmed
		{"a" + nbsp + "b", "a" + nbsp + "b"}, // but kept inside
	} {
		if got := SanitizeName(tc.in); got != tc.want {
			t.Errorf("SanitizeName(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestSanitizeNameMatchesNode runs the exact Node expression over awkward
// inputs and compares.
func TestSanitizeNameMatchesNode(t *testing.T) {
	inputs := []string{"  Suraj  K  ", "A" + nul + "b" + zwsp + "c-d!", "A", strings.Repeat("é", 30), bom + "ab" + zwj, "सुरज कुमार",
		"  \u3000ab ", "a" + nel + "b", "tab\tin", nbsp + "x" + nbsp + "y", strings.Repeat(grin, 12), "12345"}
	raw, _ := json.Marshal(inputs)
	var want []string
	nodeJSON(t, `
const inputs = JSON.parse(process.env.INPUTS);
const sanitizeName = (name) => { const cleaned = String(name ?? '').replace(/[\p{C}]/gu, '').trim().slice(0, 24); return cleaned.length >= 2 ? cleaned : ''; };
process.stdout.write(JSON.stringify(inputs.map(sanitizeName)));`, &want, "INPUTS="+string(raw))
	for i, in := range inputs {
		if got := SanitizeName(in); got != want[i] {
			t.Errorf("SanitizeName(%q) = %q, Node %q", in, got, want[i])
		}
	}
}

func newVerifier(t *testing.T, mutate func(*config.Config)) *Verifier {
	t.Helper()
	cfg := config.Defaults()
	if mutate != nil {
		mutate(cfg)
	}
	return NewVerifier(cfg)
}

func TestVerifyLoginDispatch(t *testing.T) {
	ctx := context.Background()
	v := newVerifier(t, nil)

	_, err := v.VerifyLogin(ctx, LoginRequest{Provider: "myspace", DeviceID: "device-xxxx-9999"})
	expectAuthErr(t, err, CodeUnknownProvider, http.StatusBadRequest, `Unsupported login provider "myspace"`)
	_, err = v.VerifyLogin(ctx, LoginRequest{Provider: "Google"})
	expectAuthErr(t, err, CodeUnknownProvider, http.StatusBadRequest, `Unsupported login provider "Google"`)
	_, err = v.VerifyLogin(ctx, LoginRequest{providerAbsent: true})
	expectAuthErr(t, err, CodeUnknownProvider, http.StatusBadRequest, `Unsupported login provider "undefined"`)

	// Real providers with nothing configured.
	_, err = v.VerifyLogin(ctx, LoginRequest{Provider: "google"})
	expectAuthErr(t, err, CodeMissingToken, http.StatusUnauthorized, "idToken is required for Google login")
	_, err = v.VerifyLogin(ctx, LoginRequest{Provider: "google", IDToken: "x.y.z"})
	expectAuthErr(t, err, CodeProviderUnconfigured, http.StatusServiceUnavailable, "Google login is not configured on this server")
	_, err = v.VerifyLogin(ctx, LoginRequest{Provider: "facebook"})
	expectAuthErr(t, err, CodeMissingToken, http.StatusUnauthorized, "accessToken is required for Facebook login")
	_, err = v.VerifyLogin(ctx, LoginRequest{Provider: "facebook", AccessToken: "tok"})
	expectAuthErr(t, err, CodeProviderUnconfigured, http.StatusServiceUnavailable, "Facebook login is not configured on this server")

	// Guest.
	p, err := v.VerifyLogin(ctx, LoginRequest{Provider: "guest", DeviceID: "device-guest-0001", DisplayName: "Suraj"})
	if err != nil || p.DisplayName != "Suraj" {
		t.Errorf("guest: %v %+v", err, p)
	}
	_, err = v.VerifyLogin(ctx, LoginRequest{Provider: "guest", DeviceID: "abc"})
	expectAuthErr(t, err, CodeInvalidDeviceID, http.StatusBadRequest, "")
	_, err = v.VerifyLogin(ctx, LoginRequest{Provider: "guest", DeviceID: "12345678", deviceIDInvalid: true})
	expectAuthErr(t, err, CodeInvalidDeviceID, http.StatusBadRequest, "")
}

func TestFakeProviders(t *testing.T) {
	ctx := context.Background()
	off := newVerifier(t, nil)
	on := newVerifier(t, func(c *config.Config) { c.AllowFakeProviders = true })

	// Off: the fake path is never taken; Node's real path answers.
	_, err := off.VerifyLogin(ctx, LoginRequest{Provider: "google", ProviderUserID: "google-sub-123"})
	expectAuthErr(t, err, CodeMissingToken, http.StatusUnauthorized, "")
	// verifyFake itself refuses when disabled (503 with the provider's name).
	_, err = off.verifyFake(LoginRequest{Provider: "facebook"})
	expectAuthErr(t, err, CodeProviderUnconfigured, http.StatusServiceUnavailable, "facebook login is not configured on this server")

	p, err := on.VerifyLogin(ctx, LoginRequest{Provider: "google", ProviderUserID: "google-sub-123", DisplayName: "G Player"})
	if err != nil || p.Provider != "google" || p.ProviderUserID != "google-sub-123" || p.DisplayName != "G Player" || p.Email != nil || p.AvatarURL != nil {
		t.Errorf("fake google: %v %+v", err, p)
	}
	p, _ = on.VerifyLogin(ctx, LoginRequest{Provider: "facebook", ProviderUserID: "fb-123", DisplayName: "F Player"})
	if p.Provider != "facebook" || p.ProviderUserID != "fb-123" {
		t.Errorf("fake facebook: %+v", p)
	}
	// providerUserId falls back to the RAW display name, then "fake"; the name is sanitised.
	p, _ = on.VerifyLogin(ctx, LoginRequest{Provider: "google", DisplayName: "  Raw" + zwsp + "Name  "})
	if p.ProviderUserID != "  Raw"+zwsp+"Name  " || p.DisplayName != "RawName" {
		t.Errorf("raw fallback: %+v", p)
	}
	p, _ = on.VerifyLogin(ctx, LoginRequest{Provider: "google"})
	if p.ProviderUserID != "fake" || p.DisplayName != "Player" {
		t.Errorf("fake fallback: %+v", p)
	}
	p, _ = on.VerifyLogin(ctx, LoginRequest{Provider: "google", ProviderUserID: "42", DisplayName: "A"})
	if p.ProviderUserID != "42" || p.DisplayName != "Player" {
		t.Errorf("one-char name: %+v", p)
	}
	// With a real credential present the real path runs even when fakes are on.
	_, err = on.VerifyLogin(ctx, LoginRequest{Provider: "google", IDToken: "a.b.c"})
	expectAuthErr(t, err, CodeProviderUnconfigured, http.StatusServiceUnavailable, "")
	_, err = on.VerifyLogin(ctx, LoginRequest{Provider: "facebook", AccessToken: "t"})
	expectAuthErr(t, err, CodeProviderUnconfigured, http.StatusServiceUnavailable, "")
}

func TestLoginRequestDecoding(t *testing.T) {
	decode := func(body string) LoginRequest {
		var req LoginRequest
		if err := json.Unmarshal([]byte(body), &req); err != nil {
			t.Fatalf("%s: %v", body, err)
		}
		return req
	}
	r := decode(`{"provider":"guest","deviceId":"device-guest-0001","displayName":"Suraj"}`)
	if r.Provider != "guest" || r.DeviceID != "device-guest-0001" || r.DisplayName != "Suraj" || r.providerAbsent || r.deviceIDInvalid {
		t.Errorf("%+v", r)
	}
	r = decode(`{"provider":"guest","deviceId":12345678,"displayName":42}`)
	if !r.deviceIDInvalid || r.DisplayName != "42" {
		t.Errorf("number deviceId must be flagged, number displayName coerced: %+v", r)
	}
	r = decode(`{"provider":"guest","deviceId":{"a":1},"displayName":["a","b"]}`)
	if !r.deviceIDInvalid || r.DisplayName != "" {
		t.Errorf("object deviceId flagged, array displayName empty: %+v", r)
	}
	r = decode(`{"provider":42}`)
	if r.Provider != "42" || r.providerAbsent {
		t.Errorf("%+v", r)
	}
	r = decode(`{"deviceId":"device-guest-0001"}`)
	if !r.providerAbsent || r.Provider != "" {
		t.Errorf("%+v", r)
	}
	r = decode(`{"provider":null}`)
	if !r.providerAbsent {
		t.Errorf("null provider is absent: %+v", r)
	}
	r = decode(`[1,2]`)
	if !r.providerAbsent || r.deviceIDInvalid {
		t.Errorf("array body: %+v", r)
	}
	r = decode(`{"provider":"guest","deviceId":null}`)
	if r.deviceIDInvalid || r.DeviceID != "" {
		t.Errorf("null deviceId is just missing (→ too short): %+v", r)
	}
	r = decode(`{"provider":"google","idToken":"a.b.c","accessToken":"t","providerUserId":"p"}`)
	if r.IDToken != "a.b.c" || r.AccessToken != "t" || r.ProviderUserID != "p" {
		t.Errorf("%+v", r)
	}
}

// ---- Google ----

type googleFixture struct {
	key     *rsa.PrivateKey
	kid     string
	server  *httptest.Server
	fetches atomic.Int32
	maxAge  string
	now     time.Time
}

func newGoogleFixture(t *testing.T) *googleFixture {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	f := &googleFixture{key: key, kid: "test-kid-1", maxAge: "max-age=3600", now: time.Unix(1_800_000_000, 0)}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.fetches.Add(1)
		if f.maxAge != "" {
			w.Header().Set("Cache-Control", "public, "+f.maxAge+", must-revalidate, no-transform")
		}
		w.Header().Set("Content-Type", "application/json; charset=UTF-8")
		jwks := map[string]any{"keys": []map[string]string{
			{"kty": "RSA", "alg": "RS256", "use": "sig", "kid": f.kid,
				"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
				"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())},
			{"kty": "RSA", "alg": "RS256", "use": "sig", "kid": "other-kid",
				"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
				"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())},
		}}
		_ = json.NewEncoder(w).Encode(jwks)
	}))
	t.Cleanup(f.server.Close)
	return f
}

func (f *googleFixture) verifier(t *testing.T, clientIDs ...string) *Verifier {
	v := newVerifier(t, func(c *config.Config) { c.Google.ClientIDs = clientIDs })
	v.certsURL = f.server.URL
	v.HTTP = f.server.Client()
	v.now = func() time.Time { return f.now }
	return v
}

// idToken signs claims with the fixture key; mutate lets a test drop or
// change claims and the kid/alg.
func (f *googleFixture) idToken(t *testing.T, mutate func(claims jwt.MapClaims, tok *jwt.Token)) string {
	t.Helper()
	claims := jwt.MapClaims{
		"iss": "https://accounts.google.com", "aud": "web-client.apps.googleusercontent.com",
		"sub": "1122334455", "iat": f.now.Unix() - 60, "exp": f.now.Unix() + 3540,
		"name": "Meera Iyer", "given_name": "Meera", "email": "meera@example.com", "email_verified": true,
		"picture": "https://lh3.googleusercontent.com/a/photo",
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = f.kid
	if mutate != nil {
		mutate(claims, tok)
	}
	var signed string
	var err error
	if tok.Method == jwt.SigningMethodHS256 {
		signed, err = tok.SignedString([]byte("not-google"))
	} else {
		signed, err = tok.SignedString(f.key)
	}
	if err != nil {
		t.Fatal(err)
	}
	return signed
}

func TestVerifyGoogle(t *testing.T) {
	ctx := context.Background()
	f := newGoogleFixture(t)
	v := f.verifier(t, "android.apps.googleusercontent.com", "web-client.apps.googleusercontent.com")

	p, err := v.VerifyGoogle(ctx, f.idToken(t, nil))
	if err != nil {
		t.Fatalf("valid token: %v", err)
	}
	if p.Provider != "google" || p.ProviderUserID != "1122334455" || p.DisplayName != "Meera Iyer" ||
		p.Email == nil || *p.Email != "meera@example.com" || p.AvatarURL == nil || *p.AvatarURL != "https://lh3.googleusercontent.com/a/photo" {
		t.Errorf("profile %+v", p)
	}
	// Name fallbacks: name → given_name → "Player"; email/picture → nil.
	p, _ = v.VerifyGoogle(ctx, f.idToken(t, func(c jwt.MapClaims, _ *jwt.Token) { delete(c, "name"); delete(c, "email"); delete(c, "picture") }))
	if p.DisplayName != "Meera" || p.Email != nil || p.AvatarURL != nil {
		t.Errorf("given_name fallback: %+v", p)
	}
	p, _ = v.VerifyGoogle(ctx, f.idToken(t, func(c jwt.MapClaims, _ *jwt.Token) { delete(c, "name"); delete(c, "given_name") }))
	if p.DisplayName != "Player" {
		t.Errorf("Player fallback: %+v", p)
	}
	// Bare issuer and an audience array containing a client id are fine.
	if _, err := v.VerifyGoogle(ctx, f.idToken(t, func(c jwt.MapClaims, _ *jwt.Token) {
		c["iss"] = "accounts.google.com"
		c["aud"] = []string{"android.apps.googleusercontent.com"}
	})); err != nil {
		t.Errorf("bare issuer / array aud: %v", err)
	}
	// Within the 300 s skew still passes.
	if _, err := v.VerifyGoogle(ctx, f.idToken(t, func(c jwt.MapClaims, _ *jwt.Token) { c["exp"] = f.now.Unix() - 200 })); err != nil {
		t.Errorf("exp inside skew: %v", err)
	}
	if _, err := v.VerifyGoogle(ctx, f.idToken(t, func(c jwt.MapClaims, _ *jwt.Token) { c["iat"] = f.now.Unix() + 200 })); err != nil {
		t.Errorf("iat inside skew: %v", err)
	}

	// Refusals — each is invalid_token 401 "Google token rejected: …".
	for name, mutate := range map[string]func(jwt.MapClaims, *jwt.Token){
		"wrong audience": func(c jwt.MapClaims, _ *jwt.Token) { c["aud"] = "someone-else.apps.googleusercontent.com" },
		"no audience":    func(c jwt.MapClaims, _ *jwt.Token) { delete(c, "aud") },
		"wrong issuer":   func(c jwt.MapClaims, _ *jwt.Token) { c["iss"] = "https://evil.example.com" },
		"expired":        func(c jwt.MapClaims, _ *jwt.Token) { c["exp"] = f.now.Unix() - 400 },
		"used too early": func(c jwt.MapClaims, _ *jwt.Token) { c["iat"] = f.now.Unix() + 400 },
		"no exp":         func(c jwt.MapClaims, _ *jwt.Token) { delete(c, "exp") },
		"no iat":         func(c jwt.MapClaims, _ *jwt.Token) { delete(c, "iat") },
		"exp too far":    func(c jwt.MapClaims, _ *jwt.Token) { c["exp"] = f.now.Unix() + 86400 },
		"unknown kid":    func(_ jwt.MapClaims, tok *jwt.Token) { tok.Header["kid"] = "nope" },
		"HS256 not RS256": func(_ jwt.MapClaims, tok *jwt.Token) {
			tok.Method = jwt.SigningMethodHS256
			tok.Header["alg"] = "HS256"
		},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := v.VerifyGoogle(ctx, f.idToken(t, mutate))
			ae := authErr(t, err)
			if ae.Code != CodeInvalidToken || ae.Status != http.StatusUnauthorized || !strings.HasPrefix(ae.Message, "Google token rejected: ") {
				t.Errorf("%s: %s/%d %q", name, ae.Code, ae.Status, ae.Message)
			}
		})
	}
	// Tampered signature.
	tampered := f.idToken(t, nil)
	tampered = tampered[:len(tampered)-2] + "AA"
	_, err = v.VerifyGoogle(ctx, tampered)
	if ae := authErr(t, err); ae.Code != CodeInvalidToken || !strings.Contains(ae.Message, "Invalid token signature") {
		t.Errorf("tampered: %v", err)
	}
	_, err = v.VerifyGoogle(ctx, "not-a-jwt")
	if ae := authErr(t, err); ae.Code != CodeInvalidToken || !strings.Contains(ae.Message, "Wrong number of segments") {
		t.Errorf("segments: %v", err)
	}
	// No subject.
	_, err = v.VerifyGoogle(ctx, f.idToken(t, func(c jwt.MapClaims, _ *jwt.Token) { delete(c, "sub") }))
	expectAuthErr(t, err, CodeInvalidToken, http.StatusUnauthorized, "Google token had no subject")
}

func TestGoogleCertsCache(t *testing.T) {
	ctx := context.Background()
	f := newGoogleFixture(t)
	v := f.verifier(t, "web-client.apps.googleusercontent.com")
	for i := 0; i < 3; i++ {
		if _, err := v.VerifyGoogle(ctx, f.idToken(t, nil)); err != nil {
			t.Fatal(err)
		}
	}
	if n := f.fetches.Load(); n != 1 {
		t.Errorf("JWKS fetched %d times within max-age, want 1", n)
	}
	f.now = f.now.Add(3601 * time.Second)
	if _, err := v.VerifyGoogle(ctx, f.idToken(t, nil)); err != nil {
		t.Fatal(err)
	}
	if n := f.fetches.Load(); n != 2 {
		t.Errorf("JWKS fetched %d times after max-age, want 2", n)
	}
	// No Cache-Control → fetched every time.
	f.maxAge = ""
	f.fetches.Store(0)
	f.now = f.now.Add(3601 * time.Second)
	for i := 0; i < 2; i++ {
		if _, err := v.VerifyGoogle(ctx, f.idToken(t, nil)); err != nil {
			t.Fatal(err)
		}
	}
	if n := f.fetches.Load(); n != 2 {
		t.Errorf("without Cache-Control the JWKS must be fetched per call, got %d", n)
	}
	// Endpoint down → invalid_token with the library's wording.
	f.server.Close()
	_, err := v.VerifyGoogle(ctx, f.idToken(t, nil))
	if ae := authErr(t, err); ae.Code != CodeInvalidToken || !strings.Contains(ae.Message, "Failed to retrieve verification certificates") {
		t.Errorf("certs down: %v", err)
	}
}

func TestCacheMaxAge(t *testing.T) {
	for header, want := range map[string]time.Duration{
		"public, max-age=22571, must-revalidate, no-transform": 22571 * time.Second,
		"max-age=0": 0, "": 0, "no-cache": 0, "Max-Age=5": 5 * time.Second,
	} {
		if got := cacheMaxAge(header); got != want {
			t.Errorf("cacheMaxAge(%q) = %v, want %v", header, got, want)
		}
	}
}

// ---- Facebook ----

type facebookFixture struct {
	server      *httptest.Server
	debugStatus int
	debugBody   string
	meStatus    int
	meBody      string
	requests    []string
}

func newFacebookFixture(t *testing.T) *facebookFixture {
	f := &facebookFixture{
		debugStatus: 200, debugBody: `{"data":{"app_id":"123456","type":"USER","application":"KTP","is_valid":true,"user_id":"9988776655","scopes":["email"]}}`,
		meStatus: 200, meBody: `{"id":"9988776655","name":"Arjun Rao","email":"arjun@example.com","picture":{"data":{"url":"https://fb.example/pic.jpg","height":200}}}`,
	}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.requests = append(f.requests, r.URL.RequestURI())
		w.Header().Set("Content-Type", "application/json")
		if strings.HasPrefix(r.URL.Path, "/debug_token") {
			w.WriteHeader(f.debugStatus)
			_, _ = w.Write([]byte(f.debugBody))
			return
		}
		w.WriteHeader(f.meStatus)
		_, _ = w.Write([]byte(f.meBody))
	}))
	t.Cleanup(f.server.Close)
	return f
}

func (f *facebookFixture) verifier(t *testing.T) *Verifier {
	v := newVerifier(t, func(c *config.Config) { c.Facebook = config.FacebookConfig{AppID: "123456", AppSecret: "s3cr3t"} })
	v.graphURL = f.server.URL
	v.HTTP = f.server.Client()
	return v
}

func TestVerifyFacebook(t *testing.T) {
	ctx := context.Background()
	f := newFacebookFixture(t)
	v := f.verifier(t)

	p, err := v.VerifyFacebook(ctx, "user tok/en+")
	if err != nil {
		t.Fatal(err)
	}
	if p.Provider != "facebook" || p.ProviderUserID != "9988776655" || p.DisplayName != "Arjun Rao" ||
		p.Email == nil || *p.Email != "arjun@example.com" || p.AvatarURL == nil || *p.AvatarURL != "https://fb.example/pic.jpg" {
		t.Errorf("profile %+v", p)
	}
	if len(f.requests) != 2 {
		t.Fatalf("requests %v", f.requests)
	}
	if f.requests[0] != "/debug_token?input_token=user+tok%2Fen%2B&access_token=123456%7Cs3cr3t" {
		t.Errorf("debug_token request %q", f.requests[0])
	}
	if f.requests[1] != "/v20.0/9988776655?fields=id,name,email,picture.type(large)&access_token=user+tok%2Fen%2B" {
		t.Errorf("profile request %q", f.requests[1])
	}

	// Numeric ids and app_id compare as text; missing name → Player; no picture → nil.
	f.requests = nil
	f.debugBody = `{"data":{"app_id":123456,"is_valid":true,"user_id":9988776655}}`
	f.meBody = `{"id":9988776655}`
	p, err = v.VerifyFacebook(ctx, "t")
	if err != nil || p.ProviderUserID != "9988776655" || p.DisplayName != "Player" || p.Email != nil || p.AvatarURL != nil {
		t.Errorf("numeric ids: %v %+v", err, p)
	}
	if !strings.HasPrefix(f.requests[1], "/v20.0/9988776655?") {
		t.Errorf("user_id interpolated: %q", f.requests[1])
	}

	// Refusals in order.
	f.debugStatus = 400
	_, err = v.VerifyFacebook(ctx, "t")
	expectAuthErr(t, err, CodeInvalidToken, http.StatusUnauthorized, "Facebook rejected the access token")
	f.debugStatus = 200
	f.debugBody = `{"data":{"app_id":"123456","is_valid":false,"user_id":"1"}}`
	_, err = v.VerifyFacebook(ctx, "t")
	expectAuthErr(t, err, CodeInvalidToken, http.StatusUnauthorized, "Facebook access token is not valid")
	f.debugBody = `{"data":{"app_id":"999","is_valid":true,"user_id":"1"}}`
	_, err = v.VerifyFacebook(ctx, "t")
	expectAuthErr(t, err, CodeInvalidToken, http.StatusUnauthorized, "Facebook token was issued for a different app")
	f.debugBody = `{"data":{"app_id":"123456","is_valid":true,"user_id":"1"}}`
	f.meStatus = 500
	_, err = v.VerifyFacebook(ctx, "t")
	expectAuthErr(t, err, CodeInvalidToken, http.StatusUnauthorized, "Could not read the Facebook profile")
	// A 2xx non-JSON body is a plain error (Node: SyntaxError → 500).
	f.debugBody = `<html>oops</html>`
	_, err = v.VerifyFacebook(ctx, "t")
	var ae *AuthError
	if err == nil || errors.As(err, &ae) {
		t.Errorf("non-JSON debug body must be a plain error, got %v", err)
	}
	// Configuration gaps.
	_, err = v.VerifyFacebook(ctx, "")
	expectAuthErr(t, err, CodeMissingToken, http.StatusUnauthorized, "accessToken is required for Facebook login")
	half := newVerifier(t, func(c *config.Config) { c.Facebook.AppID = "123456" })
	_, err = half.VerifyFacebook(ctx, "t")
	expectAuthErr(t, err, CodeProviderUnconfigured, http.StatusServiceUnavailable, "Facebook login is not configured on this server")
}
