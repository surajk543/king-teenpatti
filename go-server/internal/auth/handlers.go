package auth

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"unicode/utf16"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// MaxBodyBytes is express.json({ limit: '32kb' }): 32 × 1024 bytes.
const MaxBodyBytes = 32 * 1024

// errBodyTooLarge marks a body over MaxBodyBytes (413).
var errBodyTooLarge = errors.New("request entity too large")

// ReadJSONBody is body-parser 1.20's json() as the routes saw it
// (express.json({limit:'32kb'}), strict mode), with DECISIONS.md §5's
// statuses. The checks run in body-parser's order:
//
//  1. no body → v is left at its zero value (`req.body = {}`);
//  2. a Content-Type other than application/json (parameters such as
//     charset allowed; application/vnd.api+json does not match) → the body
//     is ignored and v is left at its zero value, whatever its size;
//  3. a charset parameter other than utf-8 → 400 {error:"invalid_json",
//     message:"unsupported charset <NAME>"}. body-parser refused everything
//     outside `utf-*` (415) and transcoded utf-16/utf-32 through iconv-lite;
//     the Go server only ever decodes UTF-8, so those are refused too rather
//     than being read as the wrong encoding (no client sends them);
//  4. Content-Length or the streamed size over MaxBodyBytes → 413
//     {error:"invalid_json"};
//  5. a body of exactly zero bytes → `{}` (body-parser's special case);
//     anything else must start — after JSON whitespace only — with `{` or
//     `[` (strict mode), parse as one JSON value with nothing after it, else
//     400 {error:"invalid_json"}. A whitespace-only body is therefore a
//     strict violation, as in Node.
//
// Node answered 500 internal_error for every failure here (the parser error
// fell through the error middleware); DECISIONS.md §5 makes them 400/413.
// The returned *AuthError carries the status; callers pass it to WriteError.
func ReadJSONBody(r *http.Request, v any) error {
	if r.Body == nil || r.Body == http.NoBody {
		return nil
	}
	mediaType, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		// body-parser: type mismatch → skip parsing, req.body stays {}.
		_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, MaxBodyBytes+1))
		return nil
	}
	if charset, ok := params["charset"]; ok && !strings.EqualFold(charset, "utf-8") {
		return NewAuthError(CodeInvalidJSON, `unsupported charset "`+strings.ToUpper(charset)+`"`, http.StatusBadRequest)
	}
	if r.ContentLength > MaxBodyBytes {
		return NewAuthError(CodeInvalidJSON, errBodyTooLarge.Error(), http.StatusRequestEntityTooLarge)
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, MaxBodyBytes+1))
	if err != nil {
		return NewAuthError(CodeInvalidJSON, "could not read the request body", http.StatusBadRequest)
	}
	if len(body) > MaxBodyBytes {
		return NewAuthError(CodeInvalidJSON, errBodyTooLarge.Error(), http.StatusRequestEntityTooLarge)
	}
	if len(body) == 0 {
		return nil // body-parser special-cases an empty body as {}
	}
	// Strict mode looks past JSON whitespace only (\x20 \t \n \r), as
	// body-parser's firstchar() does.
	text := strings.TrimLeft(string(body), " \t\r\n")
	if text == "" || (text[0] != '{' && text[0] != '[') {
		return NewAuthError(CodeInvalidJSON, "request body must be a JSON object", http.StatusBadRequest)
	}
	dec := json.NewDecoder(strings.NewReader(text))
	if err := dec.Decode(v); err != nil {
		return NewAuthError(CodeInvalidJSON, "request body is not valid JSON: "+err.Error(), http.StatusBadRequest)
	}
	if dec.More() {
		return NewAuthError(CodeInvalidJSON, "request body has trailing data", http.StatusBadRequest)
	}
	return nil
}

// Login is POST /api/auth/login (routes.js 61-80; requirements 1, 2, 5, 7):
// VerifyLogin → UpsertFromProfile → log `account created` or `login`
// {userId, provider} → 200 {token, user, isNew, welcomeChips} with
// welcomeChips = config.Game.WelcomeChips when isNew, else 0.
func (h *Handler) Login(w http.ResponseWriter, r *http.Request) {
	// No body, an empty body or a non-JSON content type leaves req untouched
	// (body-parser's `{}`), and Node then reported the missing provider as
	// `Unsupported login provider "undefined"`; UnmarshalJSON recomputes the
	// flag whenever a JSON body is actually decoded.
	req := LoginRequest{providerAbsent: true}
	if err := ReadJSONBody(r, &req); err != nil {
		h.writeError(w, r, err)
		return
	}
	profile, err := h.deps.Verifier.VerifyLogin(r.Context(), req)
	if err != nil {
		h.logRefusedLogin(req, err)
		h.writeError(w, r, err)
		return
	}
	user, isNew, err := h.deps.Users.UpsertFromProfile(r.Context(), *profile)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	token, err := h.deps.Tokens.Issue(user)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	if h.deps.Logger != nil {
		msg := "login"
		if isNew {
			msg = "account created"
		}
		h.deps.Logger.Info(msg, "userId", user.ID, "provider", user.Provider)
	}
	var welcome int64
	if isNew {
		welcome = h.deps.Config.Game.WelcomeChips
	}
	WriteJSON(w, http.StatusOK, LoginResponse{Token: token, User: user, IsNew: isNew, WelcomeChips: welcome})
}

// Me is GET /api/auth/me: {user} re-read from the store by RequireAuth on
// every call, so chips and stats are fresh.
func (h *Handler) Me(w http.ResponseWriter, r *http.Request, user *db.User) {
	WriteJSON(w, http.StatusOK, UserResponse{User: user})
}

// parseLimit reads a ?limit like Node's `parseInt(limit ?? '20') || 20` (the
// leading integer of the first value; NaN or 0 → 20) and clamps it to
// [1, 100] (DECISIONS.md §5). Kept for any future paged endpoint; the one it
// was written for, GET /api/auth/me/hands, is gone with the `hands` table.
func parseLimit(raw string) int {
	n := jsParseInt(raw)
	if n == 0 {
		n = 20
	}
	if n > 100 {
		n = 100
	}
	if n < 1 {
		n = 1
	}
	return n
}

// jsParseInt is Number.parseInt(s, 10) with NaN reported as 0: skip JS
// whitespace, optional sign, then as many ASCII digits as there are.
func jsParseInt(s string) int {
	s = jsTrim(s)
	sign := 1
	if strings.HasPrefix(s, "-") {
		sign = -1
		s = s[1:]
	} else if strings.HasPrefix(s, "+") {
		s = s[1:]
	}
	n := 0
	digits := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			break
		}
		digits++
		if n < 1_000_000 { // anything beyond is clamped to 100 anyway
			n = n*10 + int(c-'0')
		}
	}
	if digits == 0 {
		return 0
	}
	return sign * n
}

// Milestone is POST /api/rewards/milestone (requirement 17). Order: seated →
// 409 {error:"seated"}; claimed → 200 {claimed:true, amount, milestone, user}
// and log `milestone reward claimed` {userId, milestone}; not claimed → 409
// {error:"reward_not_available", message, user}. The body is ignored.
//
// The seated check is not a UI nicety. It is what makes the money model's
// invariant true: A SEATED PLAYER'S WALLET IN POSTGRESQL CANNOT CHANGE EXCEPT
// AT THE THREE CHECKPOINTS (pack, leave/switch, hand end). A reward credited
// mid-hand would be a fourth writer of the same row, and the seat would never
// learn of it. Both shipped clients already offer rewards in the lobby only.
// The Table still computes its checkpoints as a DELTA rather than an absolute
// (see the Ledger doc), so a future fourth writer could not silently erase a
// credit either — defence in depth, not redundancy.
func (h *Handler) Milestone(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.isSeated(user.ID) {
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeSeated, Message: MsgSeatedMilestone})
		return
	}
	result, err := h.deps.Users.ClaimMilestoneReward(r.Context(), user.ID)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	if !result.Claimed {
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeRewardNotAvailable, Message: MsgRewardNotAvailable, User: result.User})
		return
	}
	if h.deps.Logger != nil {
		h.deps.Logger.Info("milestone reward claimed", "userId", user.ID, "milestone", result.Milestone)
	}
	WriteJSON(w, http.StatusOK, result)
}

// Bonus is POST /api/rewards/bonus (requirement 18). Order: seated → 409
// {error:"seated"}; claimed → 200 {claimed:true, amount, readyAt, user} and
// log `timed bonus claimed` {userId}; not ready → 409
// {error:"reward_not_ready", message, readyAt, user}. The body is ignored.
// The seated check exists for the reason given on Milestone.
func (h *Handler) Bonus(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.isSeated(user.ID) {
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeSeated, Message: MsgSeatedBonus})
		return
	}
	result, err := h.deps.Users.ClaimTimedBonus(r.Context(), user.ID)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	if !result.Claimed {
		readyAt := result.ReadyAt
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeRewardNotReady, Message: MsgRewardNotReady, ReadyAt: &readyAt, User: result.User})
		return
	}
	if h.deps.Logger != nil {
		h.deps.Logger.Info("timed bonus claimed", "userId", user.ID)
	}
	WriteJSON(w, http.StatusOK, result)
}

// BuyChips is POST /api/purchases/google {productId, purchaseToken}.
//
// The client sends only what Play gave it: which product, and the purchase
// token. It does NOT send an amount, and the server would not read one if it
// did — the chips come from the server-side catalogue, keyed by product id.
//
// Order: no gateway → 503; missing fields → 400; then verify with Google and
// credit. A receipt already banked answers 200 with credited=false, because
// the player did buy those chips and the app should finish the Play
// transaction rather than ask again.
//
// Note what is deliberately absent: any seated check. Rewards are refused at a
// table to keep the money model's invariant, but refusing a PAID purchase
// because someone is sitting down would be indefensible — running out of chips
// mid-hand is exactly when they buy. The delta write at the next checkpoint
// (internal/game/ledger.go) is what keeps the books straight instead.
func (h *Handler) BuyChips(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.deps.Purchases == nil {
		WriteJSON(w, http.StatusServiceUnavailable,
			ErrorResponse{Error: CodeStoreUnavailable, Message: MsgStoreUnavailable})
		return
	}
	var body struct {
		ProductID     string `json:"productId"`
		PurchaseToken string `json:"purchaseToken"`
	}
	if err := ReadJSONBody(r, &body); err != nil {
		h.writeError(w, r, err)
		return
	}
	if body.ProductID == "" || body.PurchaseToken == "" {
		WriteJSON(w, http.StatusBadRequest,
			ErrorResponse{Error: CodeInvalidPurchase, Message: MsgInvalidPurchase})
		return
	}

	out, err := h.deps.Purchases.Buy(r.Context(), user.ID, body.ProductID, body.PurchaseToken)
	if err != nil {
		if h.deps.Logger != nil {
			h.deps.Logger.Warn("purchase refused",
				"userId", user.ID, "productId", body.ProductID, "err", err.Error())
		}
		h.writeError(w, r, err)
		return
	}
	if h.deps.Logger != nil && out.Credited {
		h.deps.Logger.Info("chips purchased",
			"userId", user.ID, "productId", body.ProductID, "chips", out.Chips)
	}
	WriteJSON(w, http.StatusOK, map[string]any{
		"credited": out.Credited,
		"chips":    out.Chips,
		"balance":  out.Balance,
		"user":     out.User,
	})
}

// logRefusedLogin leaves one `login refused` line (provider, code, status,
// reason) for a login the verifier turned away. The wire answer reaches only
// the client, so without this a player saying "Google sign-in does not work"
// leaves nothing in the journal but a 401 in the metrics (10 Sep 2026). Only
// AuthErrors are logged here — anything else is WriteError's `request failed`.
// The credential never reaches the log: the google-auth-library messages this
// port reproduces quote the token back ("Wrong number of segments in token:
// <jwt>", "Invalid token signature: <jwt>"), so it is cut out of the reason.
func (h *Handler) logRefusedLogin(req LoginRequest, err error) {
	if h.deps.Logger == nil {
		return
	}
	var authErr *AuthError
	if !errors.As(err, &authErr) {
		return
	}
	reason := authErr.Message
	for _, credential := range []string{req.IDToken, req.AccessToken} {
		if credential != "" {
			reason = strings.ReplaceAll(reason, credential, "<credential>")
		}
	}
	h.deps.Logger.Warn("login refused",
		"provider", req.Provider, "code", authErr.Code, "status", authErr.Status, "reason", reason)
}

// Profiles is GET /api/profiles (unauthenticated): {profiles: [{id, url}]}
// from the live directory listing.
func (h *Handler) Profiles(w http.ResponseWriter, r *http.Request) {
	WriteJSON(w, http.StatusOK, ProfilesResponse{Profiles: h.listProfilePictures()})
}

// profilePattern is routes.js's /\.(svg|png|jpg|jpeg|webp)$/i.
var profilePattern = regexp.MustCompile(`(?i)\.(svg|png|jpg|jpeg|webp)$`)

// listProfilePictures is routes.js listProfilePictures: read ProfilesDir on
// every call, keep image names, sort as JS `Array.sort` does (UTF-16 code
// unit order — upper case before lower), map to {id: name, url:
// "/profiles/<name>"}; an unreadable directory → [] (never null).
func (h *Handler) listProfilePictures() []ProfilePicture {
	pictures := []ProfilePicture{}
	entries, err := os.ReadDir(h.deps.ProfilesDir)
	if err != nil {
		return pictures
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if profilePattern.MatchString(entry.Name()) {
			names = append(names, entry.Name())
		}
	}
	sort.Slice(names, func(i, j int) bool { return lessUTF16(names[i], names[j]) })
	for _, name := range names {
		pictures = append(pictures, ProfilePicture{ID: name, URL: "/profiles/" + name})
	}
	return pictures
}

// lessUTF16 compares strings by UTF-16 code units, JavaScript's default sort.
func lessUTF16(a, b string) bool {
	ua, ub := utf16.Encode([]rune(a)), utf16.Encode([]rune(b))
	for i := 0; i < len(ua) && i < len(ub); i++ {
		if ua[i] != ub[i] {
			return ua[i] < ub[i]
		}
	}
	return len(ua) < len(ub)
}

// Avatar is POST /api/profile/avatar {avatar: "bear.svg" | null}
// (requirement 21). Order: seated → 409; a non-null name must equal (===) an
// id from the live listing else 400 unknown_avatar; then SetAvatarChoice
// ("/profiles/<name>" or nil) → 200 {user}.
func (h *Handler) Avatar(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.isSeated(user.ID) {
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeSeated, Message: MsgSeatedAvatar})
		return
	}
	var req AvatarRequest
	if err := ReadJSONBody(r, &req); err != nil {
		h.writeError(w, r, err)
		return
	}
	var choice *string
	if req.Avatar != nil {
		allowed := false
		for _, picture := range h.listProfilePictures() {
			if picture.ID == *req.Avatar {
				allowed = true
			}
		}
		if !allowed {
			WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodeUnknownAvatar, Message: MsgUnknownAvatar})
			return
		}
		stored := "/profiles/" + *req.Avatar
		choice = &stored
	}
	updated, err := h.deps.Users.SetAvatarChoice(r.Context(), user.ID, choice)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, UserResponse{User: updated})
}

// Name is POST /api/profile/name {name} (requirement 29). Order: seated →
// 409 ("You can only change your name in the lobby."); db.NormalizeDisplayName
// failure → 400 {error: empty_name|name_too_long|invalid_name, message}; then
// SetDisplayName → 200 {user}.
func (h *Handler) Name(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.isSeated(user.ID) {
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeSeated, Message: MsgSeatedName})
		return
	}
	var req NameRequest
	if err := ReadJSONBody(r, &req); err != nil {
		h.writeError(w, r, err)
		return
	}
	maxLength := h.deps.Config.Game.DisplayNameMaxLength
	name, err := db.NormalizeDisplayName(req.Name, maxLength)
	if err != nil {
		var message string
		switch {
		case errors.Is(err, db.ErrEmptyName):
			message = MsgEmptyName
		case errors.Is(err, db.ErrNameTooLong):
			message = fmt.Sprintf(MsgNameTooLongFormat, maxLength)
		case errors.Is(err, db.ErrInvalidName):
			message = MsgInvalidName
		default:
			message = MsgNameUnusable
		}
		WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: err.Error(), Message: message})
		return
	}
	updated, err := h.deps.Users.SetDisplayName(r.Context(), user.ID, name)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, UserResponse{User: updated})
}

// isSeated consults Deps.IsSeated; absent → never seated (Node's default
// `isSeated = () => false`).
// DeleteAccount is DELETE /api/account: the player erases their own account.
//
// Google Play requires apps that create accounts to offer deletion, and this
// game creates one on first launch, so every player has an account to delete
// whether they asked for one or not.
//
// Order of refusals: RequireAuth (401) → seated (409). The seated check is
// the same rule the avatar, name and reward endpoints follow, and here it is
// load-bearing rather than tidy: a seated player's chips are partly in a pot
// and partly on the table, and PostgreSQL is only brought up to date at the
// three checkpoints (CLAUDE.md §5.1). Emptying the wallet from underneath a
// live hand would settle that hand against a balance that no longer exists.
// In the lobby there is nothing in flight and the wallet is authoritative.
//
// Answers 200 {deleted:true} once the account is gone. The client's token
// keeps its signature but stops working immediately, because every
// authenticated path resolves the user through db.selectUser, which does not
// return deleted accounts.
func (h *Handler) DeleteAccount(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.isSeated(user.ID) {
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeSeated, Message: MsgSeatedDelete})
		return
	}
	if err := h.deps.Users.DeleteAccount(r.Context(), user.ID); err != nil {
		h.writeError(w, r, err)
		return
	}
	h.deps.Logger.Info("account deleted at the player's request", "userId", user.ID)
	WriteJSON(w, http.StatusOK, DeleteAccountResponse{Deleted: true})
}

func (h *Handler) isSeated(userID string) bool {
	return h.deps.IsSeated != nil && h.deps.IsSeated(userID)
}
