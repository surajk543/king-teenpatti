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
	CodeAccountDisabled      = "account_disabled"      // 403: users.is_active is FALSE (owner, 26 Sep 2026)
	CodeUnauthorized         = "unauthorized"          // socket middleware fallback for a non-AuthError
)

// REST-only error codes routes.js returns as plain JSON (not AuthErrors).
const (
	CodeRewardNotAvailable  = "reward_not_available"  // 409
	CodeRewardNotReady      = "reward_not_ready"      // 409
	CodeSeated              = "seated"                // 409: a name change, a reward claim or a chip-priced picture while at a table
	CodeStoreUnavailable    = "store_unavailable"     // 503: no Google Play credentials configured
	CodeInvalidPurchase     = "invalid_purchase"      // 400: productId or purchaseToken missing
	CodeUnknownProduct      = "unknown_product"       // 400: a product id the catalogue does not hold
	CodePurchaseUnverified  = "purchase_unverified"   // 402: Google rejected the receipt
	CodeUnknownAvatar       = "unknown_avatar"        // 400: no such picture in the catalogue
	CodeUnknownTablePicture = "unknown_table_picture" // 400: no such table picture in its catalogue (Go only, owner 15 Sep 2026)
	CodePictureLocked       = "picture_locked"        // 403: a premium picture the player has not bought
	CodePictureRetired      = "picture_retired"       // 400: is_active = FALSE
	CodePictureFree         = "picture_free"          // 400: nothing to buy
	CodePictureChips        = "picture_chips"         // 409: wallet cannot cover the price
	CodeUnknownPack         = "unknown_pack"          // 400: a missile pack the catalogue does not hold
	CodeInvalidRequestID    = "invalid_request_id"    // 400: a missile trade's requestId empty or over 64 characters
	CodeNotEnoughDiamonds   = "not_enough_diamonds"   // 409: the diamonds a missile pack costs are not there
	// The Lucky Draw (owner, 24 Sep 2026; Go only).
	CodeLuckyDrawUnavailable = "lucky_draw_unavailable" // 503: no active draw with that code, or none of its slots can be won
	CodeLuckyDrawNotReady    = "lucky_draw_not_ready"   // 409: the player's last spin has not recharged; readyAt says when it will
	CodeInvalidActionID      = "invalid_action_id"      // 400: a spin's actionId empty or over 64 characters
	CodeInternalError        = "internal_error"         // 500
	CodeInvalidJSON          = "invalid_json"           // 400 — Go-only, see PORT_PLAN.md (Node answered 500 internal_error)
	CodeNotFound             = "not_found"              // 404 — Go-only JSON 404 for unknown /api paths (DECISIONS.md §5)
	// The emoji store (owner, 26 Sep 2026; Go only). unknown_emoji,
	// emoji_retired and emoji_locked are also the socket's chat:emoji refusals
	// (socket.KnownErrorCodes), with the same messages.
	CodeUnknownEmoji      = "unknown_emoji"      // 400: no such emoji in the catalogue (or an id that is not one)
	CodeEmojiRetired      = "emoji_retired"      // 400: is_active = FALSE
	CodeEmojiFree         = "emoji_free"         // 400: a free emoji — nothing to buy
	CodeEmojiUnaffordable = "emoji_unaffordable" // 409: the wallet the emoji's currency names cannot cover it
	CodeEmojiLocked       = "emoji_locked"       // chat:emoji only: a premium emoji not bought, or its rental run out
)
