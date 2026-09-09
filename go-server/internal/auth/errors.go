// Package auth is the port of server/src/auth/: session tokens (tokens.js),
// login providers (providers.js) and the REST handlers (routes.js).
package auth

import (
	"errors"
	"net/http"
)

// AuthError is a refused authentication/authorisation step: Code is the wire
// `error`, Message the wire `message`, Status the HTTP status (default 401).
// The socket handshake middleware reports only Code (as CONNECT_ERROR message).
type AuthError struct {
	Code    string
	Message string
	Status  int
}

// Error implements error (Message).
func (e *AuthError) Error() string { return e.Message }

// Is matches on Code.
func (e *AuthError) Is(target error) bool {
	var t *AuthError
	if !errors.As(target, &t) {
		return false
	}
	return t.Code == e.Code
}

// NewAuthError builds an AuthError; status 0 → 401 (Node's default).
func NewAuthError(code, message string, status int) *AuthError {
	if status == 0 {
		status = http.StatusUnauthorized
	}
	return &AuthError{Code: code, Message: message, Status: status}
}

// Every AuthError code (also listed in socket KNOWN_ERROR_CODES).
const (
	CodeMissingToken         = "missing_token"         // no session token / no idToken / no accessToken
	CodeInvalidSession       = "invalid_session"       // JWT rejected
	CodeInvalidToken         = "invalid_token"         // provider token rejected
	CodeInvalidDeviceID      = "invalid_device_id"     // guest deviceId < 8 chars (400)
	CodeProviderUnconfigured = "provider_unconfigured" // 503
	CodeUnknownProvider      = "unknown_provider"      // 400
	CodeUnknownUser          = "unknown_user"          // token valid, row gone
	CodeUnauthorized         = "unauthorized"          // socket middleware fallback for a non-AuthError
)

// REST-only error codes routes.js returns as plain JSON (not AuthErrors).
const (
	CodeRewardNotAvailable = "reward_not_available" // 409
	CodeRewardNotReady     = "reward_not_ready"     // 409
	CodeSeated             = "seated"               // 409: avatar/name change or a reward claim while at a table
	CodeStoreUnavailable   = "store_unavailable"    // 503: no Google Play credentials configured
	CodeInvalidPurchase    = "invalid_purchase"     // 400: productId or purchaseToken missing
	CodeUnknownProduct     = "unknown_product"      // 400: a product id the catalogue does not hold
	CodePurchaseUnverified = "purchase_unverified"  // 402: Google rejected the receipt
	CodeUnknownAvatar      = "unknown_avatar"       // 400
	CodeInternalError      = "internal_error"       // 500
	CodeInvalidJSON        = "invalid_json"         // 400 — Go-only, see PORT_PLAN.md (Node answered 500 internal_error)
	CodeNotFound           = "not_found"            // 404 — Go-only JSON 404 for unknown /api paths (DECISIONS.md §5)
)
