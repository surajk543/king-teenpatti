package auth

import (
	"net/http"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// Claims are the JWT payload Node's jsonwebtoken produced:
// {sub, provider, name, iat, exp} signed HS256 with config.JWT.Secret.
// Tokens issued by the Node server MUST verify here and vice versa (a rolling
// deploy has both alive), so: no `iss`, no `aud`, no `jti`, no `nbf`;
// iat/exp are integer seconds.
type Claims struct {
	Provider string `json:"provider"`
	Name     string `json:"name"`
	jwt.RegisteredClaims
}

// SigningMethod is HS256 — the only method accepted on verify.
var SigningMethod = jwt.SigningMethodHS256

// Tokens issues and verifies session tokens (tokens.js).
type Tokens struct {
	secret    []byte
	expiresIn time.Duration
	now       func() time.Time
}

// NewTokens builds the issuer/verifier from config.JWT; now nil → time.Now.
func NewTokens(secret string, expiresIn time.Duration, now func() time.Time) *Tokens {
	return &Tokens{secret: []byte(secret), expiresIn: expiresIn, now: now}
}

// Issue signs {sub: user.ID, provider: user.Provider, name: user.DisplayName,
// iat: now, exp: now + expiresIn} (issueToken).
func (t *Tokens) Issue(user *db.User) (string, error) {
	panic("not ported: (*Tokens).Issue")
}

// Verify parses and validates (verifyToken): "" → missing_token ("A session
// token is required"); any parse/signature/expiry failure → invalid_session
// ("Session token rejected: <reason>"). Only SigningMethod is accepted
// (jwt.WithValidMethods). Returns the claims.
func (t *Tokens) Verify(token string) (*Claims, error) {
	panic("not ported: (*Tokens).Verify")
}

// TokenFromRequest reads `Authorization: Bearer <token>` (case-insensitive
// scheme, trimmed); "" when absent (tokenFromRequest).
func TokenFromRequest(r *http.Request) string {
	panic("not ported: auth.TokenFromRequest")
}
