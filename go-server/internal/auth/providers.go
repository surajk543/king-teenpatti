package auth

import (
	"context"
	"net/http"

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
type LoginRequest struct {
	Provider       string `json:"provider"`
	IDToken        string `json:"idToken,omitempty"`
	AccessToken    string `json:"accessToken,omitempty"`
	DeviceID       string `json:"deviceId,omitempty"`
	DisplayName    string `json:"displayName,omitempty"`
	ProviderUserID string `json:"providerUserId,omitempty"`
}

// Verifier resolves a login request into a verified db.Profile (providers.js).
type Verifier struct {
	google             config.GoogleConfig
	facebook           config.FacebookConfig
	allowFakeProviders bool
	// HTTP is used for Google's certificate/tokeninfo endpoints and the
	// Facebook Graph API; nil → http.DefaultClient. Tests inject a stub.
	HTTP *http.Client
}

// NewVerifier builds the verifier from config.
func NewVerifier(cfg *config.Config) *Verifier {
	return &Verifier{google: cfg.Google, facebook: cfg.Facebook, allowFakeProviders: cfg.AllowFakeProviders}
}

// VerifyLogin dispatches on Provider (verifyLogin):
//
//	"google":   fake path when allowFakeProviders && IDToken == "", else VerifyGoogle
//	"facebook": fake path when allowFakeProviders && AccessToken == "", else VerifyFacebook
//	"guest":    VerifyGuest
//	other:      unknown_provider, 400, `Unsupported login provider "<p>"`
func (v *Verifier) VerifyLogin(ctx context.Context, req LoginRequest) (*db.Profile, error) {
	panic("not ported: (*Verifier).VerifyLogin")
}

// VerifyGoogle checks a Google Sign-In ID token (verifyGoogle). "" →
// missing_token ("idToken is required for Google login"); no ClientIDs →
// provider_unconfigured 503 ("Google login is not configured on this
// server"). Node used google-auth-library's verifyIdToken with audience =
// ClientIDs; the Go port has no such dependency and must verify the token
// itself: fetch Google's JWKS (https://www.googleapis.com/oauth2/v3/certs,
// cache by Cache-Control), validate RS256 signature, iss ∈ {accounts.google.com,
// https://accounts.google.com}, aud ∈ ClientIDs, exp — any failure →
// invalid_token ("Google token rejected: <reason>"); a payload without sub →
// invalid_token ("Google token had no subject"). Profile: displayName =
// name || given_name || "Player", email, avatarUrl = picture.
// (Adding a JWKS library is a dependency change — note it in PORT_PLAN.md.)
func (v *Verifier) VerifyGoogle(ctx context.Context, idToken string) (*db.Profile, error) {
	panic("not ported: (*Verifier).VerifyGoogle")
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
func (v *Verifier) VerifyFacebook(ctx context.Context, accessToken string) (*db.Profile, error) {
	panic("not ported: (*Verifier).VerifyFacebook")
}

// VerifyGuest keys on the client's device id (verifyGuest; requirement 7):
// trimmed length < 8 → invalid_device_id 400 ("A deviceId of at least 8
// characters is required"). providerUserId = hex(sha256("teenpatti:" +
// deviceId)) — the database never holds a device id in the clear.
// displayName = SanitizeName(displayName) || "Guest" + upper(hash[:5]).
func VerifyGuest(deviceID, displayName string) (*db.Profile, error) {
	panic("not ported: auth.VerifyGuest")
}

// verifyFake is the development escape hatch (verifyFake): refused with
// provider_unconfigured 503 unless allowFakeProviders. providerUserId =
// req.ProviderUserID || req.DisplayName || "fake"; displayName =
// SanitizeName(req.DisplayName) || "Player".
func (v *Verifier) verifyFake(req LoginRequest) (*db.Profile, error) {
	panic("not ported")
}

// SanitizeName strips every \p{C} rune, trims, truncates to 24 runes and
// returns "" when fewer than 2 runes remain (providers.js sanitizeName; the
// 24 is hardcoded there, independent of DISPLAY_NAME_MAX).
func SanitizeName(name string) string {
	panic("not ported: auth.SanitizeName")
}
