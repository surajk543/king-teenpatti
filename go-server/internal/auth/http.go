package auth

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// UserStore is the slice of db.Users the handlers use (an interface so tests
// can stub it).
type UserStore interface {
	FindByID(ctx context.Context, id string) (*db.User, error)
	UpsertFromProfile(ctx context.Context, p db.Profile) (*db.User, bool, error)
	RecentHands(ctx context.Context, userID string, limit int) ([]db.HandHistory, error)
	ClaimMilestoneReward(ctx context.Context, userID string) (*db.RewardResult, error)
	ClaimTimedBonus(ctx context.Context, userID string) (*db.RewardResult, error)
	SetDisplayName(ctx context.Context, userID, displayName string) (*db.User, error)
	SetAvatarChoice(ctx context.Context, userID string, choice *string) (*db.User, error)
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
	Logger      *slog.Logger
}

// Handler serves the REST API. Routes (Node authRoutes + playerRoutes),
// registered on a Go 1.22 ServeMux with method patterns:
//
//	POST /api/auth/login        → Login
//	GET  /api/auth/me           → Me            (RequireAuth)
//	GET  /api/auth/me/hands     → Hands         (RequireAuth; ?limit, default 20, max 100)
//	POST /api/rewards/milestone → Milestone     (RequireAuth)
//	POST /api/rewards/bonus     → Bonus         (RequireAuth)
//	GET  /api/profiles          → Profiles      (unauthenticated)
//	POST /api/profile/avatar    → Avatar        (RequireAuth)
//	POST /api/profile/name      → Name          (RequireAuth)
//
// Responses are JSON; errors are ErrorResponse. Body parsing: JSON only,
// 32 KiB limit (express.json({limit:'32kb'})); a non-JSON or oversized body →
// 400 {error:"invalid_json"} (Go-only code, see PORT_PLAN.md). Unknown
// fields are ignored.
type Handler struct {
	deps Deps
}

// NewHandler builds the REST handler.
func NewHandler(deps Deps) *Handler {
	return &Handler{deps: deps}
}

// Register mounts every route on mux.
func (h *Handler) Register(mux *http.ServeMux) {
	panic("not ported: (*Handler).Register")
}

// RequireAuth wraps a handler: TokenFromRequest → Tokens.Verify →
// Users.FindByID(sub); nil user → unknown_user ("This account no longer
// exists"). On failure WriteError(AuthError). The user is stored in the
// request context (UserFrom).
func (h *Handler) RequireAuth(next func(w http.ResponseWriter, r *http.Request, user *db.User)) http.Handler {
	panic("not ported: (*Handler).RequireAuth")
}

// UserFrom returns the authenticated user placed by RequireAuth, or nil.
func UserFrom(ctx context.Context) *db.User {
	panic("not ported: auth.UserFrom")
}

// WriteError writes an error response: *AuthError → its Status and
// {error: Code, message}; *game.GameError → 400 {error: Code, message};
// anything else → log `request failed {path, error}` and 500
// {error:"internal_error", message:"Something went wrong"} (index.js error
// middleware). Shared with the app's /api/rooms and 404 handling.
func WriteError(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	panic("not ported: auth.WriteError")
}

// WriteJSON writes v as JSON with the given status (Content-Type
// application/json; charset=utf-8, as Express).
func WriteJSON(w http.ResponseWriter, status int, v any) {
	panic("not ported: auth.WriteJSON")
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

// HandsResponse ← GET /api/auth/me/hands.
type HandsResponse struct {
	Hands []db.HandHistory `json:"hands"`
}

// ProfilePicture is one bundled avatar: {id: "bear.svg", url: "/profiles/bear.svg"}.
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
type AvatarRequest struct {
	Avatar *string `json:"avatar"`
}

// NameRequest ← POST /api/profile/name {name} (requirement 29). While seated
// → 409 seated ("You can only change your name in the lobby."). Validation
// via db.NormalizeDisplayName(name, config.Game.DisplayNameMaxLength) → 400
// {error: empty_name|name_too_long|invalid_name, message: "Your name cannot
// be empty." | "Keep it to N characters or fewer." | "Letters, numbers and
// spaces only."}.
type NameRequest struct {
	Name string `json:"name"`
}

// Reward 409 messages (routes.js).
const (
	MsgRewardNotAvailable = "No milestone reward is waiting yet."
	MsgRewardNotReady     = "The bonus is still recharging."
	MsgSeatedAvatar       = "You cannot change your picture while you are at a table."
	MsgSeatedName         = "You can only change your name in the lobby."
	MsgUnknownAvatar      = "That picture is not available."
	MsgEmptyName          = "Your name cannot be empty."
	MsgNameTooLongFormat  = "Keep it to %d characters or fewer."
	MsgInvalidName        = "Letters, numbers and spaces only."
	MsgNameUnusable       = "That name cannot be used."
	MsgInternalError      = "Something went wrong"
	MsgUnknownUser        = "This account no longer exists"
)
