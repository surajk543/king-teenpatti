package auth

import (
	"context"
	"net/http"
	"regexp"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// ---- Sign in with Apple ----

const appleBundle = "com.sungamestudio.kingteenpatti"

// appleVerifier is a verifier whose Apple keys come from the Google
// fixture's JWKS server (the documents have one shape), which — like Apple's
// own endpoint — may answer with no max-age at all.
func appleVerifier(t *testing.T, f *googleFixture, mutate func(*config.Config)) *Verifier {
	t.Helper()
	v := newVerifier(t, mutate)
	v.appleKeysURL = f.server.URL
	v.HTTP = f.server.Client()
	v.now = func() time.Time { return f.now }
	return v
}

func appleToken(t *testing.T, f *googleFixture, mutate func(claims jwt.MapClaims, tok *jwt.Token)) string {
	t.Helper()
	return f.idToken(t, func(claims jwt.MapClaims, tok *jwt.Token) {
		for k := range claims {
			delete(claims, k)
		}
		claims["iss"] = "https://appleid.apple.com"
		claims["aud"] = appleBundle
		claims["sub"] = "001234.abcdef0123456789.1234"
		claims["iat"] = f.now.Unix() - 60
		claims["exp"] = f.now.Unix() + 86340
		claims["email"] = "x7k2@privaterelay.appleid.com"
		claims["email_verified"] = true
		claims["is_private_email"] = true
		if mutate != nil {
			mutate(claims, tok)
		}
	})
}

func TestVerifyApple(t *testing.T) {
	ctx := context.Background()
	f := newGoogleFixture(t)
	v := appleVerifier(t, f, nil) // the defaults name this app's bundle

	p, err := v.VerifyApple(ctx, appleToken(t, f, nil), "  Asha Rao ")
	if err != nil {
		t.Fatalf("VerifyApple: %v", err)
	}
	if p.Provider != db.ProviderApple || p.ProviderUserID != "001234.abcdef0123456789.1234" || p.DisplayName != "Asha Rao" {
		t.Fatalf("profile = %+v", p)
	}
	if p.Email == nil || *p.Email != "x7k2@privaterelay.appleid.com" || p.AvatarURL != nil {
		t.Fatalf("email = %v, avatar = %v", p.Email, p.AvatarURL)
	}

	// Apple's token carries no name, and the app is only told it once: a
	// login without one is named like a guest, never a bare "Player".
	p, err = v.VerifyApple(ctx, appleToken(t, f, nil), "")
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^Player[0-9A-F]{5}$`).MatchString(p.DisplayName) {
		t.Fatalf("fallback name = %q", p.DisplayName)
	}
	again, _ := v.VerifyApple(ctx, appleToken(t, f, nil), "")
	if again.DisplayName != p.DisplayName {
		t.Fatalf("the fallback name is not stable: %q then %q", p.DisplayName, again.DisplayName)
	}

	// VerifyLogin routes provider "apple" here, name and all.
	p, err = v.VerifyLogin(ctx, LoginRequest{Provider: "apple", IDToken: appleToken(t, f, nil), DisplayName: "Asha"})
	if err != nil || p.Provider != db.ProviderApple || p.DisplayName != "Asha" {
		t.Fatalf("VerifyLogin: %+v, %v", p, err)
	}
}

func TestVerifyAppleRefusals(t *testing.T) {
	ctx := context.Background()
	f := newGoogleFixture(t)
	v := appleVerifier(t, f, nil)

	_, err := v.VerifyApple(ctx, "", "")
	expectAuthErr(t, err, CodeMissingToken, http.StatusUnauthorized, "idToken is required for Apple login")

	cases := map[string]func(claims jwt.MapClaims, tok *jwt.Token){
		"another app's token":     func(c jwt.MapClaims, _ *jwt.Token) { c["aud"] = "com.example.other" },
		"a Google token's issuer": func(c jwt.MapClaims, _ *jwt.Token) { c["iss"] = "https://accounts.google.com" },
		"expired":                 func(c jwt.MapClaims, _ *jwt.Token) { c["exp"] = f.now.Unix() - 3600 },
		"no expiry":               func(c jwt.MapClaims, _ *jwt.Token) { delete(c, "exp") },
		"no audience":             func(c jwt.MapClaims, _ *jwt.Token) { delete(c, "aud") },
		"issued in the future":    func(c jwt.MapClaims, _ *jwt.Token) { c["iat"] = f.now.Unix() + 3600 },
		"a key Apple never had":   func(_ jwt.MapClaims, tok *jwt.Token) { tok.Header["kid"] = "forged" },
		"HS256":                   func(_ jwt.MapClaims, tok *jwt.Token) { tok.Method = jwt.SigningMethodHS256 },
		"no subject":              func(c jwt.MapClaims, _ *jwt.Token) { delete(c, "sub") },
	}
	for name, mutate := range cases {
		_, err := v.VerifyApple(ctx, appleToken(t, f, mutate), "")
		if e := authErr(t, err); e == nil || e.Code != CodeInvalidToken {
			t.Errorf("%s: err = %v, want invalid_token", name, err)
		}
	}
	_, err = v.VerifyApple(ctx, "not.a-jwt", "")
	if e := authErr(t, err); e == nil || e.Code != CodeInvalidToken {
		t.Errorf("garbage: err = %v", err)
	}
}

func TestAppleLoginIsOffWithNoBundleOrWhenTheDatabaseCannotHoldIt(t *testing.T) {
	ctx := context.Background()
	f := newGoogleFixture(t)

	off := appleVerifier(t, f, func(c *config.Config) { c.Apple.BundleIDs = nil })
	_, err := off.VerifyApple(ctx, appleToken(t, f, nil), "")
	expectAuthErr(t, err, CodeProviderUnconfigured, http.StatusServiceUnavailable, "Apple login is not configured on this server")

	// The app shuts the door at boot when users.provider does not admit
	// 'apple' — the fake path with it, or a test login would meet the CHECK.
	shut := appleVerifier(t, f, func(c *config.Config) { c.AllowFakeProviders = true })
	shut.DisableApple("users_provider_check does not admit 'apple'")
	_, err = shut.VerifyLogin(ctx, LoginRequest{Provider: "apple", IDToken: appleToken(t, f, nil)})
	expectAuthErr(t, err, CodeProviderUnconfigured, http.StatusServiceUnavailable, "Apple login is not configured on this server")
	_, err = shut.VerifyLogin(ctx, LoginRequest{Provider: "apple", ProviderUserID: "fake-apple"})
	if e := authErr(t, err); e == nil || e.Status != http.StatusServiceUnavailable {
		t.Fatalf("fake path through a shut door: %v", err)
	}

	// With the door open the fake path is Google's.
	fake := appleVerifier(t, f, func(c *config.Config) { c.AllowFakeProviders = true })
	p, err := fake.VerifyLogin(ctx, LoginRequest{Provider: "apple", ProviderUserID: "fake-apple", DisplayName: "Fake Apple"})
	if err != nil || p.Provider != db.ProviderApple || p.ProviderUserID != "fake-apple" {
		t.Fatalf("fake apple login: %+v, %v", p, err)
	}
}

func TestApplesKeysAreKeptAlthoughAppleSaysNoStore(t *testing.T) {
	ctx := context.Background()
	f := newGoogleFixture(t)
	f.maxAge = "" // Apple answers Cache-Control: no-store
	v := appleVerifier(t, f, nil)

	for i := 0; i < 3; i++ {
		if _, err := v.VerifyApple(ctx, appleToken(t, f, nil), ""); err != nil {
			t.Fatal(err)
		}
	}
	if got := f.fetches.Load(); got != 1 {
		t.Fatalf("three logins fetched Apple's keys %d times, want 1", got)
	}

	// A kid not held is a rotation: fetched again — but not for every token
	// that names a key which does not exist.
	forged := func(_ jwt.MapClaims, tok *jwt.Token) { tok.Header["kid"] = "forged" }
	_, _ = v.VerifyApple(ctx, appleToken(t, f, forged), "")
	_, _ = v.VerifyApple(ctx, appleToken(t, f, forged), "")
	if got := f.fetches.Load(); got != 1 {
		t.Fatalf("unknown kids inside a minute fetched %d times, want 1", got)
	}
	f.now = f.now.Add(2 * time.Minute)
	_, _ = v.VerifyApple(ctx, appleToken(t, f, forged), "")
	if got := f.fetches.Load(); got != 2 {
		t.Fatalf("an unknown kid two minutes on fetched %d times, want 2", got)
	}

	// And after the hour the keys are read again.
	f.now = f.now.Add(61 * time.Minute)
	if _, err := v.VerifyApple(ctx, appleToken(t, f, nil), ""); err != nil {
		t.Fatal(err)
	}
	if got := f.fetches.Load(); got != 3 {
		t.Fatalf("after the hour: %d fetches, want 3", got)
	}
}
