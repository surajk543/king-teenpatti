package auth

import (
	"context"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// LoginRequest is the body of POST /api/auth/login (routes.js / providers.js
// verifyLogin). Only the fields for the chosen provider are read:
//
//	google   → IDToken
//	facebook → AccessToken
//	guest    → DeviceID, DisplayName?
//
// ProviderUserID and DisplayName are also read by the fake-provider path.
//
// Decoding is tolerant the way Node's `String(x)` reading was (DECISIONS.md
// §4): a JSON number arrives as its decimal text, objects/arrays/booleans/null
// as "". The one stricter rule (DECISIONS.md §5) is that a guest deviceId
// that is not a JSON string is refused with invalid_device_id; the decoder
// records that in deviceIDInvalid. A JSON array body (Node: `provider` read
// off an array → undefined) decodes to an empty request.
type LoginRequest struct {
	Provider       string `json:"provider"`
	IDToken        string `json:"idToken,omitempty"`
	AccessToken    string `json:"accessToken,omitempty"`
	DeviceID       string `json:"deviceId,omitempty"`
	DisplayName    string `json:"displayName,omitempty"`
	ProviderUserID string `json:"providerUserId,omitempty"`

	// providerAbsent reproduces `Unsupported login provider "undefined"` for a
	// body without the key (Node stringified the missing value).
	providerAbsent bool
	// deviceIDInvalid is set when deviceId was present but not a JSON string.
	deviceIDInvalid bool
}

// UnmarshalJSON applies the coercions documented on LoginRequest.
func (r *LoginRequest) UnmarshalJSON(data []byte) error {
	*r = LoginRequest{}
	trimmed := strings.TrimLeft(string(data), " \t\r\n")
	if strings.HasPrefix(trimmed, "[") {
		var arr []json.RawMessage
		if err := json.Unmarshal(data, &arr); err != nil {
			return err
		}
		r.providerAbsent = true
		return nil
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	var kind jsonKind
	r.Provider, kind = coerceText(raw["provider"])
	r.providerAbsent = kind == jsonAbsent
	r.IDToken, _ = coerceText(raw["idToken"])
	r.AccessToken, _ = coerceText(raw["accessToken"])
	r.DisplayName, _ = coerceText(raw["displayName"])
	r.ProviderUserID, _ = coerceText(raw["providerUserId"])
	r.DeviceID, kind = coerceText(raw["deviceId"])
	r.deviceIDInvalid = kind == jsonNumber || kind == jsonOther
	return nil
}

// Google's JWKS endpoint and the issuers it signs for (google-auth-library
// verifySignedJwtWithCertsAsync). Node used the PEM variant at /oauth2/v1/certs;
// the JWK variant carries the same keys with the same kids.
const (
	googleCertsURL = "https://www.googleapis.com/oauth2/v3/certs"
	// googleClockSkew is the library's CLOCK_SKEW_SECS_ (300 s) applied to
	// iat and exp; googleMaxTokenLifetime its DEFAULT_MAX_TOKEN_LIFETIME_SECS_.
	googleClockSkew        = 300 * time.Second
	googleMaxTokenLifetime = 86400 * time.Second
	facebookGraphURL       = "https://graph.facebook.com"
)

// googleIssuers are the accepted `iss` values. google-auth-library also took
// its universe domain "googleapis.com"; Google has never issued that on an
// ID token and the contract (VerifyGoogle doc) names these two.
var googleIssuers = []string{"accounts.google.com", "https://accounts.google.com"}

// Verifier resolves a login request into a verified db.Profile (providers.js).
type Verifier struct {
	google             config.GoogleConfig
	facebook           config.FacebookConfig
	allowFakeProviders bool
	// HTTP is used for Google's certificate endpoint and the Facebook Graph
	// API; nil → a client with ProviderTimeout (http.DefaultClient has none,
	// and a hung provider would pin the login goroutine and its DB slot).
	// Tests inject a stub.
	HTTP *http.Client

	// certsURL / graphURL default to Google's and Facebook's endpoints; tests
	// point them at httptest servers. now is the clock for JWT validation.
	certsURL string
	graphURL string
	now      func() time.Time

	// JWKS cache honouring Cache-Control max-age (google-auth-library kept
	// the PEM map until certificateExpiry; no header → no caching).
	certsMu      sync.Mutex
	certs        map[string]*rsa.PublicKey
	certsExpires time.Time
}

// NewVerifier builds the verifier from config.
func NewVerifier(cfg *config.Config) *Verifier {
	return &Verifier{
		google:             cfg.Google,
		facebook:           cfg.Facebook,
		allowFakeProviders: cfg.AllowFakeProviders,
		certsURL:           googleCertsURL,
		graphURL:           facebookGraphURL,
		now:                time.Now,
	}
}

// ProviderTimeout bounds one round-trip to Google or Facebook when no HTTP
// client is injected. Node's fetch had no per-request deadline; the value is
// generous so a slow-but-alive provider still answers.
const ProviderTimeout = 15 * time.Second

// client returns the injected HTTP client or a bounded one over
// http.DefaultTransport (the client struct is trivial; the connection pool
// is the shared transport's, so nothing is kept at package level).
func (v *Verifier) client() *http.Client {
	if v.HTTP != nil {
		return v.HTTP
	}
	return &http.Client{Timeout: ProviderTimeout}
}

func (v *Verifier) clock() time.Time {
	if v.now == nil {
		return time.Now()
	}
	return v.now()
}

// VerifyLogin dispatches on Provider (verifyLogin):
//
//	"google":   fake path when allowFakeProviders && IDToken == "", else VerifyGoogle
//	"facebook": fake path when allowFakeProviders && AccessToken == "", else VerifyFacebook
//	"guest":    VerifyGuest
//	other:      unknown_provider, 400, `Unsupported login provider "<p>"`
//
// The fake branch is taken only when the real credential is absent: with
// AUTH_ALLOW_FAKE_PROVIDERS=true and an idToken present the real Google path
// runs (and answers provider_unconfigured when no client ids are set).
func (v *Verifier) VerifyLogin(ctx context.Context, req LoginRequest) (*db.Profile, error) {
	switch req.Provider {
	case db.ProviderGoogle:
		if v.allowFakeProviders && req.IDToken == "" {
			return v.verifyFake(req)
		}
		return v.VerifyGoogle(ctx, req.IDToken)
	case db.ProviderFacebook:
		if v.allowFakeProviders && req.AccessToken == "" {
			return v.verifyFake(req)
		}
		return v.VerifyFacebook(ctx, req.AccessToken)
	case db.ProviderGuest:
		if req.deviceIDInvalid {
			return nil, invalidDeviceID()
		}
		return VerifyGuest(req.DeviceID, req.DisplayName)
	}
	shown := req.Provider
	if req.providerAbsent {
		shown = "undefined"
	}
	return nil, NewAuthError(CodeUnknownProvider, fmt.Sprintf("Unsupported login provider %q", shown), http.StatusBadRequest)
}

// VerifyGoogle checks a Google Sign-In ID token (verifyGoogle). "" →
// missing_token ("idToken is required for Google login"); no ClientIDs →
// provider_unconfigured 503 ("Google login is not configured on this
// server"). Node used google-auth-library's verifyIdToken with audience =
// ClientIDs; the Go port verifies the token itself with the same checks the
// library made (oauth2client.js verifySignedJwtWithCertsAsync): fetch
// Google's JWKS (https://www.googleapis.com/oauth2/v3/certs, cached by
// Cache-Control max-age), the header kid must name a key, RS256 signature,
// iat and exp present, exp not more than a day away, iat/exp within a 300 s
// skew, iss ∈ {accounts.google.com, https://accounts.google.com}, aud ∈
// ClientIDs — any failure → invalid_token ("Google token rejected:
// <reason>"); a payload without sub → invalid_token ("Google token had no
// subject"). Profile: displayName = name || given_name || "Player", email,
// avatarUrl = picture; neither sanitised nor truncated, as in Node.
// email_verified is not checked (Node did not either).
func (v *Verifier) VerifyGoogle(ctx context.Context, idToken string) (*db.Profile, error) {
	if idToken == "" {
		return nil, NewAuthError(CodeMissingToken, "idToken is required for Google login", 0)
	}
	if len(v.google.ClientIDs) == 0 {
		return nil, NewAuthError(CodeProviderUnconfigured, "Google login is not configured on this server", http.StatusServiceUnavailable)
	}
	payload, err := v.verifyGoogleJWT(ctx, idToken)
	if err != nil {
		return nil, NewAuthError(CodeInvalidToken, "Google token rejected: "+err.Error(), 0)
	}
	sub, _ := payload["sub"].(string)
	if sub == "" {
		return nil, NewAuthError(CodeInvalidToken, "Google token had no subject", 0)
	}
	name, _ := payload["name"].(string)
	if name == "" {
		name, _ = payload["given_name"].(string)
	}
	if name == "" {
		name = "Player"
	}
	return &db.Profile{
		Provider:       db.ProviderGoogle,
		ProviderUserID: sub,
		DisplayName:    name,
		Email:          optionalString(payload["email"]),
		AvatarURL:      optionalString(payload["picture"]),
	}, nil
}

// verifyGoogleJWT performs the checks listed on VerifyGoogle and returns the
// raw payload. Error texts follow google-auth-library's where they exist so
// the wire message reads the same.
func (v *Verifier) verifyGoogleJWT(ctx context.Context, idToken string) (jwt.MapClaims, error) {
	if strings.Count(idToken, ".") != 2 {
		return nil, fmt.Errorf("Wrong number of segments in token: %s", idToken)
	}
	certs, err := v.googleCerts(ctx)
	if err != nil {
		return nil, fmt.Errorf("Failed to retrieve verification certificates: %v", err)
	}
	claims := jwt.MapClaims{}
	now := v.clock()
	_, err = jwt.ParseWithClaims(idToken, claims, func(token *jwt.Token) (any, error) {
		kid, _ := token.Header["kid"].(string)
		key, ok := certs[kid]
		if !ok {
			return nil, fmt.Errorf("No pem found for envelope: %v", token.Header)
		}
		return key, nil
	},
		jwt.WithValidMethods([]string{jwt.SigningMethodRS256.Alg()}),
		jwt.WithTimeFunc(func() time.Time { return now }),
		jwt.WithLeeway(googleClockSkew),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt())
	if err != nil {
		switch {
		case errors.Is(err, jwt.ErrTokenSignatureInvalid):
			return nil, fmt.Errorf("Invalid token signature: %s", idToken)
		case errors.Is(err, jwt.ErrTokenRequiredClaimMissing):
			return nil, errors.New("No expiration time in token")
		case errors.Is(err, jwt.ErrTokenExpired):
			return nil, fmt.Errorf("Token used too late, %d > %s", now.Unix(), claims["exp"])
		case errors.Is(err, jwt.ErrTokenUsedBeforeIssued):
			return nil, fmt.Errorf("Token used too early, %d < %s", now.Unix(), claims["iat"])
		}
		return nil, err
	}
	iat, err := claims.GetIssuedAt()
	if err != nil {
		return nil, errors.New("iat field using invalid format")
	}
	if iat == nil {
		return nil, errors.New("No issue time in token")
	}
	exp, err := claims.GetExpirationTime()
	if err != nil {
		return nil, errors.New("exp field using invalid format")
	}
	if exp.Time.Sub(now) >= googleMaxTokenLifetime {
		return nil, errors.New("Expiration time too far in future")
	}
	iss, _ := claims["iss"].(string)
	issuerOK := false
	for _, allowed := range googleIssuers {
		if iss == allowed {
			issuerOK = true
		}
	}
	if !issuerOK {
		return nil, fmt.Errorf("Invalid issuer, expected one of [%s], but got %s", strings.Join(googleIssuers, ", "), iss)
	}
	aud, err := claims.GetAudience()
	if err != nil || len(aud) == 0 {
		return nil, errors.New("Wrong recipient, payload audience != requiredAudience")
	}
	audienceOK := false
	for _, a := range aud {
		for _, allowed := range v.google.ClientIDs {
			if a == allowed {
				audienceOK = true
			}
		}
	}
	if !audienceOK {
		return nil, errors.New("Wrong recipient, payload audience != requiredAudience")
	}
	return claims, nil
}

// googleCerts returns the kid → RSA public key map, refetching once the
// cached copy's max-age has elapsed.
func (v *Verifier) googleCerts(ctx context.Context) (map[string]*rsa.PublicKey, error) {
	v.certsMu.Lock()
	defer v.certsMu.Unlock()
	if v.certs != nil && v.clock().Before(v.certsExpires) {
		return v.certs, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.certsURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := v.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, fmt.Errorf("certificate endpoint answered %d", resp.StatusCode)
	}
	var jwks struct {
		Keys []struct {
			Kty string `json:"kty"`
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.Unmarshal(body, &jwks); err != nil {
		return nil, err
	}
	certs := map[string]*rsa.PublicKey{}
	for _, key := range jwks.Keys {
		if key.Kty != "RSA" {
			continue
		}
		n, err := base64.RawURLEncoding.DecodeString(key.N)
		if err != nil {
			return nil, fmt.Errorf("key %s: bad modulus", key.Kid)
		}
		e, err := base64.RawURLEncoding.DecodeString(key.E)
		if err != nil {
			return nil, fmt.Errorf("key %s: bad exponent", key.Kid)
		}
		certs[key.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	v.certs = certs
	v.certsExpires = v.clock().Add(cacheMaxAge(resp.Header.Get("Cache-Control")))
	return certs, nil
}

// cacheMaxAge reads max-age from a Cache-Control header; 0 when absent, so
// the next call refetches (google-auth-library cached only with the header).
func cacheMaxAge(header string) time.Duration {
	for _, directive := range strings.Split(header, ",") {
		directive = strings.TrimSpace(directive)
		if value, ok := strings.CutPrefix(strings.ToLower(directive), "max-age="); ok {
			if seconds, err := strconv.Atoi(strings.TrimSpace(value)); err == nil && seconds > 0 {
				return time.Duration(seconds) * time.Second
			}
		}
	}
	return 0
}

// VerifyFacebook checks a user access token via the Graph API (verifyFacebook):
// "" → missing_token ("accessToken is required for Facebook login"); missing
// AppID or AppSecret → provider_unconfigured 503. GET
// https://graph.facebook.com/debug_token?input_token=<t>&access_token=<appId>|<appSecret>
// — non-2xx → invalid_token ("Facebook rejected the access token");
// !data.is_valid → invalid_token ("Facebook access token is not valid");
// data.app_id != AppID → invalid_token ("Facebook token was issued for a
// different app"). Then GET https://graph.facebook.com/v20.0/<user_id>?fields=
// id,name,email,picture.type(large)&access_token=<t> — non-2xx → invalid_token
// ("Could not read the Facebook profile"). Profile: name || "Player", email,
// picture.data.url.
//
// As in Node there is no appsecret_proof and the app token is the plain
// "<appId>|<appSecret>"; app_id is compared as text because the Graph API
// has returned it both as a string and as a number. A 2xx body that is not
// JSON is an ordinary error (Node: SyntaxError → 500 internal_error).
func (v *Verifier) VerifyFacebook(ctx context.Context, accessToken string) (*db.Profile, error) {
	if accessToken == "" {
		return nil, NewAuthError(CodeMissingToken, "accessToken is required for Facebook login", 0)
	}
	if v.facebook.AppID == "" || v.facebook.AppSecret == "" {
		return nil, NewAuthError(CodeProviderUnconfigured, "Facebook login is not configured on this server", http.StatusServiceUnavailable)
	}
	appToken := v.facebook.AppID + "|" + v.facebook.AppSecret
	debugURL := v.graphURL + "/debug_token?input_token=" + url.QueryEscape(accessToken) + "&access_token=" + url.QueryEscape(appToken)
	status, body, err := v.get(ctx, debugURL)
	if err != nil {
		return nil, err
	}
	if status < 200 || status > 299 {
		return nil, NewAuthError(CodeInvalidToken, "Facebook rejected the access token", 0)
	}
	var debug struct {
		Data struct {
			IsValid bool            `json:"is_valid"`
			AppID   json.RawMessage `json:"app_id"`
			UserID  json.RawMessage `json:"user_id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &debug); err != nil {
		return nil, fmt.Errorf("facebook debug_token: %w", err)
	}
	if !debug.Data.IsValid {
		return nil, NewAuthError(CodeInvalidToken, "Facebook access token is not valid", 0)
	}
	if jsString(debug.Data.AppID) != v.facebook.AppID {
		return nil, NewAuthError(CodeInvalidToken, "Facebook token was issued for a different app", 0)
	}
	profileURL := v.graphURL + "/v20.0/" + jsString(debug.Data.UserID) + "?fields=id,name,email,picture.type(large)&access_token=" + url.QueryEscape(accessToken)
	status, body, err = v.get(ctx, profileURL)
	if err != nil {
		return nil, err
	}
	if status < 200 || status > 299 {
		return nil, NewAuthError(CodeInvalidToken, "Could not read the Facebook profile", 0)
	}
	var profile struct {
		ID      json.RawMessage `json:"id"`
		Name    string          `json:"name"`
		Email   *string         `json:"email"`
		Picture *struct {
			Data *struct {
				URL *string `json:"url"`
			} `json:"data"`
		} `json:"picture"`
	}
	if err := json.Unmarshal(body, &profile); err != nil {
		return nil, fmt.Errorf("facebook profile: %w", err)
	}
	name := profile.Name
	if name == "" {
		name = "Player"
	}
	var avatar *string
	if profile.Picture != nil && profile.Picture.Data != nil {
		avatar = profile.Picture.Data.URL
	}
	return &db.Profile{
		Provider:       db.ProviderFacebook,
		ProviderUserID: jsString(profile.ID),
		DisplayName:    name,
		Email:          profile.Email,
		AvatarURL:      avatar,
	}, nil
}

// get performs one Graph API GET and returns status and body.
func (v *Verifier) get(ctx context.Context, target string) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return 0, nil, err
	}
	resp, err := v.client().Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return 0, nil, err
	}
	return resp.StatusCode, body, nil
}

// jsString is `String(x)` for a raw JSON scalar: strings unquoted, numbers
// and booleans as their literal text, null/absent → "null"/"undefined"-free
// empty string (nothing downstream compares against those).
func jsString(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	if raw[0] == '"' {
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return s
		}
	}
	return string(raw)
}

// optionalString returns a pointer for a non-empty string claim, nil otherwise
// (Node: `payload.email ?? null`).
func optionalString(value any) *string {
	s, ok := value.(string)
	if !ok {
		return nil
	}
	return &s
}

func invalidDeviceID() *AuthError {
	return NewAuthError(CodeInvalidDeviceID, "A deviceId of at least 8 characters is required", http.StatusBadRequest)
}

// VerifyGuest keys on the client's device id (verifyGuest; requirement 7):
// trimmed length < 8 (UTF-16 units, JS trim) → invalid_device_id 400 ("A
// deviceId of at least 8 characters is required"). providerUserId =
// lower-case hex(sha256("teenpatti:" + deviceId)) — the database never holds
// a device id in the clear. displayName = SanitizeName(displayName) ||
// "Guest" + upper(hash[:5]) (e.g. Guest8D049).
func VerifyGuest(deviceID, displayName string) (*db.Profile, error) {
	trimmed := jsTrim(deviceID)
	if utf16Len(trimmed) < 8 {
		return nil, invalidDeviceID()
	}
	sum := sha256.Sum256([]byte("teenpatti:" + trimmed))
	hashed := hex.EncodeToString(sum[:])
	name := SanitizeName(displayName)
	if name == "" {
		name = "Guest" + strings.ToUpper(hashed[:5])
	}
	return &db.Profile{
		Provider:       db.ProviderGuest,
		ProviderUserID: hashed,
		DisplayName:    name,
	}, nil
}

// verifyFake is the development escape hatch (verifyFake): refused with
// provider_unconfigured 503 ("<provider> login is not configured on this
// server") unless allowFakeProviders. providerUserId = req.ProviderUserID ||
// req.DisplayName || "fake" — the RAW display name, not the sanitised one,
// is the fallback identity (DECISIONS.md §5 keeps this); displayName =
// SanitizeName(req.DisplayName) || "Player".
func (v *Verifier) verifyFake(req LoginRequest) (*db.Profile, error) {
	if !v.allowFakeProviders {
		return nil, NewAuthError(CodeProviderUnconfigured, req.Provider+" login is not configured on this server", http.StatusServiceUnavailable)
	}
	id := req.ProviderUserID
	if id == "" {
		id = req.DisplayName
	}
	if id == "" {
		id = "fake"
	}
	name := SanitizeName(req.DisplayName)
	if name == "" {
		name = "Player"
	}
	return &db.Profile{Provider: req.Provider, ProviderUserID: id, DisplayName: name}, nil
}

// SanitizeNameMax is the hardcoded 24 of providers.js sanitizeName,
// independent of DISPLAY_NAME_MAX.
const SanitizeNameMax = 24

// SanitizeName is providers.js sanitizeName:
//
//	String(name ?? '').replace(/[\p{C}]/gu, '').trim().slice(0, 24)
//
// kept only when at least 2 characters remain, else "". Every \p{C} rune
// (controls, format characters such as ZWSP/ZWJ/BOM, surrogates, private use,
// unassigned) is removed; ordinary spaces are kept and interior runs are NOT
// collapsed (unlike db.NormalizeDisplayName); punctuation is allowed. Lengths
// are UTF-16 code units and the cut never splits a surrogate pair
// (DECISIONS.md §4).
func SanitizeName(name string) string {
	var b strings.Builder
	for _, r := range name {
		if !isCategoryC(r) {
			b.WriteRune(r)
		}
	}
	cleaned := utf16Slice(jsTrim(b.String()), SanitizeNameMax)
	if utf16Len(cleaned) < 2 {
		return ""
	}
	return cleaned
}
