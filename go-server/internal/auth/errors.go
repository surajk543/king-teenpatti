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
	CodeSessionReplaced      = "session_replaced"      // 401: the account has signed in on another device since this token (owner, 28 Sep 2026)
	CodeUnauthorized         = "unauthorized"          // socket middleware fallback for a non-AuthError
)

// REST-only error codes routes.js returns as plain JSON (not AuthErrors).
const (
	CodeSeated              = "seated"                // 409: a name change, a Lucky Draw spin, account deletion or a chip-priced picture while at a table
	CodeStoreUnavailable    = "store_unavailable"     // 503: no Google Play credentials configured
	CodeInvalidPurchase     = "invalid_purchase"      // 400: productId or purchaseToken missing
	CodeUnknownProduct      = "unknown_product"       // 400: a product id the catalogue does not hold
	CodePurchaseUnverified  = "purchase_unverified"   // 402: Google rejected the receipt
	CodeUnknownAvatar       = "unknown_avatar"        // 400: no such picture in the catalogue
	CodeUnknownTablePicture = "unknown_table_picture" // 400: no such table picture in its catalogue (Go only, owner 15 Sep 2026)
	CodePictureLocked       = "picture_locked"        // 403: a premium picture the player has not bought
	CodePictureRetired      = "picture_retired"       // 400: is_active = FALSE; and a buy of an unlisted one (is_listed = FALSE)
	CodePictureFree         = "picture_free"          // 400: nothing to buy
	CodePictureChips        = "picture_chips"         // 409: wallet cannot cover the price
	CodeUnknownPack         = "unknown_pack"          // 400: a missile pack the catalogue does not hold
	CodeInvalidRequestID    = "invalid_request_id"    // 400: a missile trade's requestId empty or over 64 characters
	CodeNotEnoughDiamonds   = "not_enough_diamonds"   // 409: the diamonds a missile pack costs are not there
	// The Lucky Draw (owner, 24 Sep 2026; Go only).
	CodeLuckyDrawUnavailable = "lucky_draw_unavailable" // 503: no active draw with that code, or none of its slots can be won
	CodeLuckyDrawNotReady    = "lucky_draw_not_ready"   // 409: the player's last spin has not recharged; readyAt says when it will
	CodeInvalidActionID      = "invalid_action_id"      // 400: a spin's actionId empty or over 64 characters
	// The reward programs (owner, 30 Sep 2026; rewardprograms.go).
	CodeRewardProgramsUnavailable = "reward_programs_unavailable" // 503: the server runs no reward programs (no store wired)
	// The app version gate (owner, 28 Sep 2026; Go only; appversion): every
	// signed-in route, and the socket handshake as a connect_error.
	CodeUpdateRequired = "update_required" // 426: the app build is below its platform's minimum_version
	CodeMaintenance    = "maintenance"     // 503: the app's platform is in maintenance
	CodeInternalError  = "internal_error"  // 500
	CodeInvalidJSON    = "invalid_json"    // 400 — Go-only, see PORT_PLAN.md (Node answered 500 internal_error)
	CodeNotFound       = "not_found"       // 404 — Go-only JSON 404 for unknown /api paths (DECISIONS.md §5)
	// The emoji store (owner, 26 Sep 2026; Go only). unknown_emoji,
	// emoji_retired and emoji_locked are also the socket's chat:emoji refusals
	// (socket.KnownErrorCodes), with the same messages.
	CodeUnknownEmoji      = "unknown_emoji"      // 400: no such emoji in the catalogue (or an id that is not one)
	CodeEmojiRetired      = "emoji_retired"      // 400: is_active = FALSE; and a buy of an unlisted one (is_listed = FALSE)
	CodeEmojiFree         = "emoji_free"         // 400: a free emoji — nothing to buy
	CodeEmojiUnaffordable = "emoji_unaffordable" // 409: the wallet the emoji's currency names cannot cover it
	CodeEmojiLocked       = "emoji_locked"       // chat:emoji only: a premium emoji not bought, or its rental run out
	// Friends V1 (owner, 26 Sep 2026; Go only): the lobby's social graph.
	CodeInvalidPlayerID         = "invalid_player_id"        // 400: a Player ID that is empty once trimmed, or longer than 64
	CodePlayerNotFound          = "player_not_found"         // 404: no such account, or a deleted or disabled one
	CodeSelfRequest             = "self_request"             // 400: a friend request to oneself
	CodeAlreadyFriends          = "already_friends"          // 409: a friend request to a friend
	CodeRequestAlreadySent      = "request_already_sent"     // 409: the sender's own request to that player is pending
	CodeRequestAlreadyReceived  = "request_already_received" // 409: that player's request to the sender is pending (+ its requestId)
	CodeFriendRequestNotFound   = "request_not_found"        // 404: no such request, or one not addressed to the caller
	CodeFriendRequestNotPending = "request_not_pending"      // 409: accepted, rejected or cancelled already
	CodeNotFriends              = "not_friends"              // 404: removing a player who is not a friend
	// Report Player (owner, 27 Sep 2026; Go only; reports.go). invalid_player_id,
	// player_not_found and rate_limited are shared with the routes above.
	CodeSelfReport          = "self_report"           // 400: a report about oneself
	CodeInvalidReportReason = "invalid_report_reason" // 400: a reason not in ReportReasons
	CodeDescriptionRequired = "description_required"  // 400: OTHER without a description
	CodeDescriptionTooLong  = "description_too_long"  // 400: over REPORT_DESCRIPTION_MAX characters
	CodePlayerNotAtTable    = "player_not_at_table"   // 409: not at the reporter's table, nor lately
	CodeAlreadyReported     = "already_reported"      // 409: this player, by this reporter, this hand or within the pair window
	CodeReportLimitReached  = "report_limit_reached"  // 429: REPORT_MAX_PER_REPORTER reports in REPORT_WINDOW_MS
)
