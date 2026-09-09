package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// UserStore is the slice of db.Users the handlers use (an interface so tests
// can stub it).
type UserStore interface {
	FindByID(ctx context.Context, id string) (*db.User, error)
	UpsertFromProfile(ctx context.Context, p db.Profile) (*db.User, bool, error)
	ClaimMilestoneReward(ctx context.Context, userID string) (*db.RewardResult, error)
	ClaimTimedBonus(ctx context.Context, userID string) (*db.RewardResult, error)
	SetDisplayName(ctx context.Context, userID, displayName string) (*db.User, error)
	SetAvatarChoice(ctx context.Context, userID string, choice *string) (*db.User, error)
	DeleteAccount(ctx context.Context, userID string) error
}

// Deps wires a Handler.
type Deps struct {
	Config   *config.Config
	Users    UserStore
	Tokens   *Tokens
	Verifier *Verifier
	// IsSeated is injected by the app (rooms.GetTableForPlayer(id) != nil) so
	// the avatar and name endpoints can refuse a change mid-table (routes.js
	// playerRoutes({isSeated})).
	IsSeated func(userID string) bool
	// ProfilesDir is <PublicDir>/profiles: the bundled pictures a player may
	// choose from. Listed on every request (Node readdirSync), filtered to
	// .svg/.png/.jpg/.jpeg/.webp, sorted by name.
	ProfilesDir string
	// Purchases credits a verified Google Play purchase. Nil when the server
	// has no Play credentials, and then the endpoint refuses every request
	// rather than crediting on the client's word.
	Purchases PurchaseGateway
	Logger    *slog.Logger
}

// PurchaseGateway is the store side of the server: verify a receipt with
// Google, then credit the wallet exactly once. Implemented in internal/app so
// this package keeps knowing nothing about Play or the database.
type PurchaseGateway interface {
	Buy(ctx context.Context, userID, productID, purchaseToken string) (PurchaseOutcome, error)
}

// PurchaseOutcome is what the endpoint reports back to the app.
type PurchaseOutcome struct {
	Chips   int64
	Balance int64
	// Credited is false when this receipt had already been banked. The client
	// still treats it as success — the chips are in the wallet — and finishes
	// the Play transaction so the player is not asked again.
	Credited bool
	User     *db.User
}

// Handler serves the REST API. Routes (Node authRoutes + playerRoutes),
// registered on a net/http ServeMux by path, with the method checked inside
// so that a wrong method answers the same JSON 404 as an unknown path
// (DECISIONS.md §5: Express fell through to its 404 — `GET /api/auth/login`
// was "Cannot GET", never a 405). HEAD is served for every GET as Express
// did. Methods per route:
//
//	POST /api/auth/login        → Login
//	GET  /api/auth/me           → Me            (RequireAuth)
//	POST /api/rewards/milestone → Milestone     (RequireAuth)
//	POST /api/rewards/bonus     → Bonus         (RequireAuth)
//	GET  /api/profiles          → Profiles      (unauthenticated)
//	POST /api/profile/avatar    → Avatar        (RequireAuth)
//	POST /api/profile/name      → Name          (RequireAuth)
//
// Responses are JSON; errors are ErrorResponse. Body parsing (ReadJSONBody):
// JSON only, UTF-8 only, 32 KiB limit (express.json({limit:'32kb'})); a
// malformed body or a non-UTF-8 charset → 400 {error:"invalid_json"}, an
// oversized one → 413 with the same envelope (Go-only code, DECISIONS.md §5;
// Node answered 500 internal_error). A body whose Content-Type is not
// application/json, or no body at all, is `{}` as body-parser left it (the
// browser's reward POSTs send neither). Unknown fields are ignored.
//
// Order of refusals on an authenticated route: RequireAuth (401) → seated
// (409) → body (400/413) → validation. Node parsed the body first, app-wide,
// so a malformed body there beat a bad token; nothing a client does depends
// on that and authenticating first keeps parser behaviour from anonymous
// callers (PORT_NOTES/auth-config.md).
type Handler struct {
	deps Deps
}

// NewHandler builds the REST handler.
func NewHandler(deps Deps) *Handler {
	return &Handler{deps: deps}
}

// Register mounts every route on mux. The unknown-/api/* 404 is the app's
// (it also owns GET /api/rooms); NotFoundHandler is the handler to use there.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.Handle("/api/auth/login", methods(http.MethodPost, http.HandlerFunc(h.Login)))
	mux.Handle("/api/auth/me", methods(http.MethodGet, h.RequireAuth(h.Me)))
	mux.Handle("/api/rewards/milestone", methods(http.MethodPost, h.RequireAuth(h.Milestone)))
	mux.Handle("/api/rewards/bonus", methods(http.MethodPost, h.RequireAuth(h.Bonus)))
	mux.Handle("/api/purchases/google", methods(http.MethodPost, h.RequireAuth(h.BuyChips)))
	mux.Handle("/api/profiles", methods(http.MethodGet, http.HandlerFunc(h.Profiles)))
	mux.Handle("/api/profile/avatar", methods(http.MethodPost, h.RequireAuth(h.Avatar)))
	mux.Handle("/api/profile/name", methods(http.MethodPost, h.RequireAuth(h.Name)))
	mux.Handle("/api/account", methods(http.MethodDelete, h.RequireAuth(h.DeleteAccount)))
}

// methods lets `method` (and HEAD when method is GET) through to next and
// answers everything else with the JSON 404 (Express: unmatched → 404).
func methods(method string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == method || (method == http.MethodGet && r.Method == http.MethodHead) {
			next.ServeHTTP(w, r)
			return
		}
		WriteNotFound(w, r)
	})
}

// NotFoundHandler answers every request with the JSON 404 (WriteNotFound).
// The app mounts it at /api/ so unknown API paths never fall through to the
// static file server.
func NotFoundHandler() http.Handler {
	return http.HandlerFunc(WriteNotFound)
}

// WriteNotFound writes DECISIONS.md §5's JSON 404 for the API:
// {error:"not_found", message:"Cannot <METHOD> <path>"} — the text Express's
// finalhandler put in its HTML page, without the HTML.
func WriteNotFound(w http.ResponseWriter, r *http.Request) {
	WriteJSON(w, http.StatusNotFound, ErrorResponse{Error: CodeNotFound, Message: "Cannot " + r.Method + " " + r.URL.Path})
}

// ctxKey is the context key RequireAuth stores the user under.
type ctxKey struct{}

// RequireAuth wraps a handler: TokenFromRequest → Tokens.Verify →
// Users.FindByID(sub); nil user → unknown_user ("This account no longer
// exists"). On failure WriteError(AuthError). The user is stored in the
// request context (UserFrom). Authentication runs before any body or seated
// check, so invalid_session / unknown_user beat every other refusal.
func (h *Handler) RequireAuth(next func(w http.ResponseWriter, r *http.Request, user *db.User)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims, err := h.deps.Tokens.Verify(TokenFromRequest(r))
		if err != nil {
			h.writeError(w, r, err)
			return
		}
		user, err := h.deps.Users.FindByID(r.Context(), claims.Subject)
		if err != nil {
			h.writeError(w, r, err)
			return
		}
		if user == nil {
			h.writeError(w, r, NewAuthError(CodeUnknownUser, MsgUnknownUser, 0))
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, user)), user)
	})
}

// UserFrom returns the authenticated user placed by RequireAuth, or nil.
func UserFrom(ctx context.Context) *db.User {
	user, _ := ctx.Value(ctxKey{}).(*db.User)
	return user
}

// WriteError writes an error response: *AuthError → its Status and
// {error: Code, message}; *game.GameError → 400 {error: Code, message};
// anything else → log `request failed {path, error}` and 500
// {error:"internal_error", message:"Something went wrong"} (index.js error
// middleware). Shared with the app's /api/rooms and 404 handling.
func WriteError(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	var authErr *AuthError
	if errors.As(err, &authErr) {
		WriteJSON(w, authErr.Status, ErrorResponse{Error: authErr.Code, Message: authErr.Message})
		return
	}
	var gameErr *game.GameError
	if errors.As(err, &gameErr) {
		WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: gameErr.Code, Message: gameErr.Message})
		return
	}
	if log != nil {
		log.Error("request failed", "path", r.URL.Path, "error", err.Error())
	}
	WriteJSON(w, http.StatusInternalServerError, ErrorResponse{Error: CodeInternalError, Message: MsgInternalError})
}

func (h *Handler) writeError(w http.ResponseWriter, r *http.Request, err error) {
	WriteError(w, r, h.deps.Logger, err)
}

// WriteJSON writes v as JSON with the given status (Content-Type
// application/json; charset=utf-8, as Express). The body is compact, like
// JSON.stringify, and HTML characters are left alone (Go's default escaping
// of <>& is disabled — Express did not escape them).
func WriteJSON(w http.ResponseWriter, status int, v any) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		http.Error(w, `{"error":"internal_error","message":"Something went wrong"}`, http.StatusInternalServerError)
		return
	}
	body := bytes.TrimRight(buf.Bytes(), "\n")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Length", fmt.Sprint(len(body)))
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// ---- wire shapes (routes.js) ----

// ErrorResponse is every error body: {error, message} plus, for the reward
// 409s, the current user and (bonus only) readyAt.
type ErrorResponse struct {
	Error   string   `json:"error"`
	Message string   `json:"message"`
	User    *db.User `json:"user,omitempty"`
	ReadyAt *int64   `json:"readyAt,omitempty"`
}

// LoginResponse ← POST /api/auth/login: {token, user, isNew, welcomeChips}
// (welcomeChips = config.Game.WelcomeChips when isNew, else 0).
type LoginResponse struct {
	Token        string   `json:"token"`
	User         *db.User `json:"user"`
	IsNew        bool     `json:"isNew"`
	WelcomeChips int64    `json:"welcomeChips"`
}

// UserResponse ← GET /api/auth/me, POST /api/profile/avatar, POST /api/profile/name.
type UserResponse struct {
	User *db.User `json:"user"`
}

// ProfilePicture is one bundled avatar: {id: "bear.svg", url: "/profiles/bear.svg"}.
// DeleteAccountResponse ← DELETE /api/account.
type DeleteAccountResponse struct {
	Deleted bool `json:"deleted"`
}

type ProfilePicture struct {
	ID  string `json:"id"`
	URL string `json:"url"`
}

// ProfilesResponse ← GET /api/profiles.
type ProfilesResponse struct {
	Profiles []ProfilePicture `json:"profiles"` // [] when the directory is unreadable, never null
}

// AvatarRequest ← POST /api/profile/avatar {avatar: "bear.svg" | null}.
// nil clears the choice (falls back to the provider picture); a name not in
// the profiles dir → 400 unknown_avatar ("That picture is not available.");
// while seated → 409 seated ("You cannot change your picture while you are
// at a table."). Stored as "/profiles/<name>".
//
// Decoding mirrors `req.body?.avatar ?? null`: absent or null → nil; a string
// → itself; any other JSON value → its literal text, which can never equal a
// bundled file name and so ends in unknown_avatar exactly as `entry.id === 0`
// did in Node.
type AvatarRequest struct {
	Avatar *string `json:"avatar"`
}

// UnmarshalJSON applies the coercion documented on AvatarRequest.
func (a *AvatarRequest) UnmarshalJSON(data []byte) error {
	*a = AvatarRequest{}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		if bytes.HasPrefix(bytes.TrimSpace(data), []byte("[")) {
			return nil // an array body has no `avatar` → null
		}
		return err
	}
	value, ok := raw["avatar"]
	if !ok || string(value) == "null" {
		return nil
	}
	text := jsString(value)
	a.Avatar = &text
	return nil
}

// NameRequest ← POST /api/profile/name {name} (requirement 29). While seated
// → 409 seated ("You can only change your name in the lobby."). Validation
// via db.NormalizeDisplayName(name, config.Game.DisplayNameMaxLength) → 400
// {error: empty_name|name_too_long|invalid_name, message: "Your name cannot
// be empty." | "Keep it to N characters or fewer." | "Letters, numbers and
// spaces only."}.
//
// Decoding follows DECISIONS.md §4: a number arrives as its decimal text
// (Node: `${123}` → "123", accepted as a name), objects/arrays/booleans/null
// as "" → empty_name.
type NameRequest struct {
	Name string `json:"name"`
}

// UnmarshalJSON applies the coercion documented on NameRequest.
func (n *NameRequest) UnmarshalJSON(data []byte) error {
	*n = NameRequest{}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		if bytes.HasPrefix(bytes.TrimSpace(data), []byte("[")) {
			return nil
		}
		return err
	}
	n.Name, _ = coerceText(raw["name"])
	return nil
}

// Reward 409 messages (routes.js).
const (
	MsgRewardNotAvailable = "No milestone reward is waiting yet."
	MsgRewardNotReady     = "The bonus is still recharging."
	MsgSeatedAvatar       = "You cannot change your picture while you are at a table."
	MsgSeatedName         = "You can only change your name in the lobby."
	MsgSeatedDelete       = "Leave the table before deleting your account."
	MsgSeatedMilestone    = "Collect your milestone reward from the lobby, not while you are at a table."
	MsgSeatedBonus        = "Collect your reward from the lobby, not while you are at a table."
	MsgStoreUnavailable   = "The chip store is not open yet."
	MsgInvalidPurchase    = "That purchase is missing its product or receipt."
	MsgUnknownProduct     = "That pack is not on sale."
	MsgPurchaseUnverified = "Google Play could not confirm that purchase. Nothing was charged for it here."
	MsgUnknownAvatar      = "That picture is not available."
	MsgEmptyName          = "Your name cannot be empty."
	MsgNameTooLongFormat  = "Keep it to %d characters or fewer."
	MsgInvalidName        = "Letters, numbers and spaces only."
	MsgNameUnusable       = "That name cannot be used."
	MsgInternalError      = "Something went wrong"
	MsgUnknownUser        = "This account no longer exists"
)
