package auth

import (
	"errors"
	"net/http"
	"strings"
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
	if now == nil {
		now = time.Now
	}
	return &Tokens{secret: []byte(secret), expiresIn: expiresIn, now: now}
}

// Issue signs {sub: user.ID, provider: user.Provider, name: user.DisplayName,
// iat: now, exp: now + expiresIn} (issueToken). iat is floor(now) in seconds
// and exp = floor(iat + expiresIn) exactly as jsonwebtoken's timespan() does,
// so a Go-minted token is indistinguishable from a Node one to either
// verifier. The header is {"alg":"HS256","typ":"JWT"}.
func (t *Tokens) Issue(user *db.User) (string, error) {
	issued := t.now().Truncate(time.Second)
	claims := &Claims{
		Provider: user.Provider,
		Name:     user.DisplayName,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   user.ID,
			IssuedAt:  jwt.NewNumericDate(issued),
			ExpiresAt: jwt.NewNumericDate(issued.Add(t.expiresIn).Truncate(time.Second)),
		},
	}
	return jwt.NewWithClaims(SigningMethod, claims).SignedString(t.secret)
}

// Verify parses and validates (verifyToken): "" → missing_token ("A session
// token is required"); any parse/signature/expiry failure → invalid_session
// ("Session token rejected: <reason>"). Only SigningMethod is accepted
// (jwt.WithValidMethods — DECISIONS.md §5 pins HS256; Node also took
// HS384/HS512). As in jsonwebtoken's defaults: exp is honoured only when
// present (a token without exp never expires), nbf is honoured when present,
// iat is not checked, there is no clock tolerance. Returns the claims.
func (t *Tokens) Verify(token string) (*Claims, error) {
	if token == "" {
		return nil, NewAuthError(CodeMissingToken, "A session token is required", 0)
	}
	claims := &Claims{}
	_, err := jwt.ParseWithClaims(token, claims, func(*jwt.Token) (any, error) { return t.secret, nil },
		jwt.WithValidMethods([]string{SigningMethod.Alg()}),
		jwt.WithTimeFunc(t.now))
	if err != nil {
		return nil, NewAuthError(CodeInvalidSession, "Session token rejected: "+rejectionReason(token, err), 0)
	}
	return claims, nil
}

// rejectionReason maps golang-jwt's errors onto jsonwebtoken's wording where a
// counterpart exists (jwt malformed / invalid token / jwt expired / invalid
// signature / jwt not active / invalid algorithm) so the `message` players and
// logs see does not change with the runtime. Anything else keeps the
// library's text.
//
// jsonwebtoken distinguishes two malformed cases: a string without exactly
// three dot-separated segments is "jwt malformed", while three segments whose
// header or payload will not decode is "invalid token" (verify.js: the
// segment count is checked first, then jws.decode returning null).
func rejectionReason(token string, err error) string {
	switch {
	case errors.Is(err, jwt.ErrTokenMalformed):
		if strings.Count(token, ".") == 2 {
			return "invalid token"
		}
		return "jwt malformed"
	case errors.Is(err, jwt.ErrTokenExpired):
		return "jwt expired"
	case errors.Is(err, jwt.ErrTokenNotValidYet):
		return "jwt not active"
	case errors.Is(err, jwt.ErrTokenSignatureInvalid):
		if strings.Contains(err.Error(), "signing method") {
			return "invalid algorithm"
		}
		return "invalid signature"
	case errors.Is(err, jwt.ErrTokenUnverifiable):
		return "invalid token"
	}
	return err.Error()
}

// TokenFromRequest reads `Authorization: Bearer <token>` (case-insensitive
// scheme, trimmed); "" when absent (tokenFromRequest). "Bearer" without a
// space, "Basic …" and "Bearer" followed only by spaces all yield "" and so
// end in missing_token, as in Node.
func TokenFromRequest(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if len(header) >= 7 && strings.EqualFold(header[:7], "bearer ") {
		return strings.TrimSpace(header[7:])
	}
	return ""
}
