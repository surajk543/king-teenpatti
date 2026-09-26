package auth

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// Friends V1 (owner, 26 Sep 2026; Go only): the lobby's social graph over
// REST — look a player up by their Player ID (users.id), send a friend
// request, answer one, the friend list with each friend's presence, a
// friend's profile, remove a friend. Eight routes (Register):
//
//	GET    /api/players/{playerId}                  → FindPlayer
//	GET    /api/players/{playerId}/profile          → PlayerProfile
//	GET    /api/friends                             → FriendList
//	GET    /api/friends/requests                    → FriendRequests
//	POST   /api/friends/requests {userId}           → SendFriendRequest   (201)
//	POST   /api/friends/requests/{requestId}/accept → AcceptFriendRequest
//	POST   /api/friends/requests/{requestId}/reject → RejectFriendRequest
//	DELETE /api/friends/{friendUserId}              → RemoveFriend
//
// Every one signed in (RequireAuth); the four that write go through the wallet
// limiter as every other mutation does. Allowed anywhere — at a table too —
// as none of them moves a wallet.
//
// WHAT NEVER LEAVES. Every answer is built from the DTOs below and nothing
// else: never a db.User, and so never a wallet (chips, diamonds, hammers,
// missiles), a purchase, a ledger row, an email or a provider identity; and a
// friend who is at a table is shown the KIND of table (game and variant, from
// the seat's live playing record) — never its room id, its code or a live
// store key.

// FriendStore is the slice of db.Friends the friends routes use.
type FriendStore interface {
	Lookup(ctx context.Context, viewerID, playerID string) (*db.PlayerLookup, error)
	List(ctx context.Context, userID string) ([]db.Friend, error)
	Requests(ctx context.Context, userID string) (incoming, outgoing []db.FriendRequest, err error)
	Send(ctx context.Context, fromID, toID string) (int64, error)
	Accept(ctx context.Context, userID string, requestID int64) (*db.Friend, error)
	Reject(ctx context.Context, userID string, requestID int64) error
	Remove(ctx context.Context, userID, friendID string) error
}

// PresenceSource reads who is online and who is playing (live.Store's
// Presence: kt:online and the seats' kt:playing:<userId> records), batched.
type PresenceSource interface {
	Presence(ctx context.Context, userIDs []string) (map[string]live.Presence, error)
}

// The friends routes' refusals, worded for the player.
const (
	MsgInvalidPlayerID         = "That is not a valid Player ID."
	MsgPlayerNotFound          = "Player not found."
	MsgSelfRequest             = "You cannot add yourself."
	MsgAlreadyFriends          = "You are already friends."
	MsgRequestAlreadySent      = "Friend request already sent."
	MsgRequestAlreadyReceived  = "This player already sent you a request — accept it."
	MsgFriendRequestNotFound   = "Friend request not found."
	MsgFriendRequestNotPending = "This friend request has already been answered."
	MsgNotFriends              = "You are not friends with this player."
)

// ---- wire shapes ------------------------------------------------------------

// PlayerCard is a player as Friends shows one, everywhere: who they are and
// the picture they wear.
type PlayerCard struct {
	UserID         string        `json:"userId"`
	DisplayName    string        `json:"displayName"`
	ProfilePicture PlayerPicture `json:"profilePicture"`
}

// PlayerPicture is PlayerCard.profilePicture: the catalogue picture worn (id,
// null for none) and the URL the player's user object carries as avatarUrl —
// the worn picture's, else their provider photo's — null when neither.
type PlayerPicture struct {
	ID  *int64  `json:"id"`
	URL *string `json:"url"`
}

// PresenceView is a player's presence as a friend is shown it: status
// PLAYING (a seat — the reconnect grace included, when online is still
// true), ONLINE (a live socket) or OFFLINE; game and variant only while
// PLAYING (TEEN_PATTI | POKER and SEEN … OMAHA), never which table.
type PresenceView struct {
	Status  string `json:"status"`
	Online  bool   `json:"online"`
	Playing bool   `json:"playing"`
	Game    string `json:"game,omitempty"`
	Variant string `json:"variant,omitempty"`
}

// PlayerResponse ← GET /api/players/{playerId}. RequestID only with a
// PENDING_* friendStatus: the pending request between viewer and player.
type PlayerResponse struct {
	Player       PlayerCard `json:"player"`
	FriendStatus string     `json:"friendStatus"`
	RequestID    *int64     `json:"requestId,omitempty"`
}

// PlayerStatsView is a profile's stats: four counters from player_stats and
// the win rate, round(100 · won / played, 2), 0 before a hand is played and
// never over 100. No chip figure — totalWinnings and biggestPot stay off.
type PlayerStatsView struct {
	HandsPlayed int64   `json:"handsPlayed"`
	HandsWon    int64   `json:"handsWon"`
	HandsLost   int64   `json:"handsLost"`
	HandsLeft   int64   `json:"handsLeft"`
	WinRate     float64 `json:"winRate"`
}

// PlayerProfile is GET /api/players/{playerId}/profile's profile: the card's
// fields, where the viewer stands with the player, and their stats; presence
// only for a friend or the viewer themselves.
type PlayerProfile struct {
	PlayerCard
	FriendStatus string          `json:"friendStatus"`
	RequestID    *int64          `json:"requestId,omitempty"`
	Presence     *PresenceView   `json:"presence,omitempty"`
	Stats        PlayerStatsView `json:"stats"`
}

// PlayerProfileResponse ← GET /api/players/{playerId}/profile.
type PlayerProfileResponse struct {
	Profile PlayerProfile `json:"profile"`
}

// FriendItem is one friend: the card, their presence flattened beside it,
// and when the two became friends.
type FriendItem struct {
	PlayerCard
	Status       string `json:"status"`
	Online       bool   `json:"online"`
	Playing      bool   `json:"playing"`
	Game         string `json:"game,omitempty"`
	Variant      string `json:"variant,omitempty"`
	FriendsSince int64  `json:"friendsSince"`
}

// FriendsResponse ← GET /api/friends: PLAYING first, then ONLINE, then
// OFFLINE, each by display name, case-insensitive. [] when there are none.
type FriendsResponse struct {
	Friends []FriendItem `json:"friends"`
}

// FriendRequestItem is one pending request: its id, the OTHER player, and
// when it was sent.
type FriendRequestItem struct {
	RequestID int64      `json:"requestId"`
	Player    PlayerCard `json:"player"`
	CreatedAt int64      `json:"createdAt"`
}

// FriendRequestsResponse ← GET /api/friends/requests: the pending requests
// addressed to the caller and the ones they sent, newest first; [] for none.
type FriendRequestsResponse struct {
	Incoming []FriendRequestItem `json:"incoming"`
	Outgoing []FriendRequestItem `json:"outgoing"`
}

// SendFriendRequestBody ← POST /api/friends/requests {userId}: the Player ID
// the request is for. A non-string userId reads as "" (invalid_player_id).
type SendFriendRequestBody struct {
	UserID string `json:"userId"`
}

// UnmarshalJSON reads userId on its own, as MissileTradeRequest reads its
// fields: a value of the wrong JSON type reads as "".
func (b *SendFriendRequestBody) UnmarshalJSON(data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*b = SendFriendRequestBody{}
	if v, ok := raw["userId"]; ok {
		_ = json.Unmarshal(v, &b.UserID)
	}
	return nil
}

// SendFriendRequestResponse ← POST /api/friends/requests (201).
type SendFriendRequestResponse struct {
	RequestID    int64  `json:"requestId"`
	FriendStatus string `json:"friendStatus"`
}

// AcceptFriendRequestResponse ← POST /api/friends/requests/{requestId}/accept:
// the new friend, as the list will show them.
type AcceptFriendRequestResponse struct {
	Friend FriendItem `json:"friend"`
}

// RejectFriendRequestResponse ← POST /api/friends/requests/{requestId}/reject.
type RejectFriendRequestResponse struct {
	RequestID int64  `json:"requestId"`
	Status    string `json:"status"`
}

// RemoveFriendResponse ← DELETE /api/friends/{friendUserId}.
type RemoveFriendResponse struct {
	Removed bool `json:"removed"`
}

// FriendRefusal is every friends route's error body: {error, message}, and
// for request_already_received the pending request's id, so the app can
// offer to accept it there and then.
type FriendRefusal struct {
	Error     string `json:"error"`
	Message   string `json:"message"`
	RequestID *int64 `json:"requestId,omitempty"`
}

// ---- handlers -------------------------------------------------------------

// FindPlayer is GET /api/players/{playerId}: the player a Player ID names and
// where the caller stands with them. 400 invalid_player_id for an id empty
// once trimmed or longer than db.PlayerIDMaxLength; 404 player_not_found for
// one naming nobody, a deleted account or a disabled one.
func (h *Handler) FindPlayer(w http.ResponseWriter, r *http.Request, user *db.User) {
	found, ok := h.lookupPlayer(w, r, user)
	if !ok {
		return
	}
	WriteJSON(w, http.StatusOK, PlayerResponse{
		Player:       cardOf(found.Player),
		FriendStatus: found.FriendStatus,
		RequestID:    requestIDOf(found),
	})
}

// PlayerProfile is GET /api/players/{playerId}/profile: FindPlayer's answer
// with the player's stats, and their presence when they are the caller's
// friend or the caller themselves. Refusals as FindPlayer's.
func (h *Handler) PlayerProfile(w http.ResponseWriter, r *http.Request, user *db.User) {
	found, ok := h.lookupPlayer(w, r, user)
	if !ok {
		return
	}
	profile := PlayerProfile{
		PlayerCard:   cardOf(found.Player),
		FriendStatus: found.FriendStatus,
		RequestID:    requestIDOf(found),
		Stats:        statsView(found.Stats),
	}
	if found.FriendStatus == db.FriendStatusFriends || found.FriendStatus == db.FriendStatusSelf {
		id := found.Player.UserID
		view := presenceView(h.presenceOf(r.Context(), []string{id})[id])
		profile.Presence = &view
	}
	WriteJSON(w, http.StatusOK, PlayerProfileResponse{Profile: profile})
}

// lookupPlayer reads the path's Player ID and looks it up for user, writing
// the refusal itself when there is one.
func (h *Handler) lookupPlayer(w http.ResponseWriter, r *http.Request, user *db.User) (*db.PlayerLookup, bool) {
	playerID, ok := playerIDFrom(r.PathValue("playerId"))
	if !ok {
		refuseFriends(w, http.StatusBadRequest, CodeInvalidPlayerID, MsgInvalidPlayerID, nil)
		return nil, false
	}
	found, err := h.deps.Friends.Lookup(r.Context(), user.ID, playerID)
	if errors.Is(err, db.ErrPlayerNotFound) {
		refuseFriends(w, http.StatusNotFound, CodePlayerNotFound, MsgPlayerNotFound, nil)
		return nil, false
	}
	if err != nil {
		h.writeError(w, r, err)
		return nil, false
	}
	return found, true
}

// FriendList is GET /api/friends: every friend, each with their presence
// (one batched read of the live store for the whole list), PLAYING first,
// then ONLINE, then OFFLINE, each group by display name, case-insensitive.
// Deleted and disabled accounts are left out.
func (h *Handler) FriendList(w http.ResponseWriter, r *http.Request, user *db.User) {
	friends, err := h.deps.Friends.List(r.Context(), user.ID)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	ids := make([]string, len(friends))
	for i, f := range friends {
		ids[i] = f.Player.UserID
	}
	presence := h.presenceOf(r.Context(), ids)
	items := make([]FriendItem, 0, len(friends))
	for _, f := range friends {
		items = append(items, friendItem(f, presence[f.Player.UserID]))
	}
	sortFriends(items)
	WriteJSON(w, http.StatusOK, FriendsResponse{Friends: items})
}

// FriendRequests is GET /api/friends/requests: the caller's PENDING requests,
// received and sent, newest first.
func (h *Handler) FriendRequests(w http.ResponseWriter, r *http.Request, user *db.User) {
	incoming, outgoing, err := h.deps.Friends.Requests(r.Context(), user.ID)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, FriendRequestsResponse{Incoming: requestItems(incoming), Outgoing: requestItems(outgoing)})
}

// SendFriendRequest is POST /api/friends/requests {userId}: a friend request
// from the caller, answered 201 {requestId, friendStatus: PENDING_SENT}.
// Refusals, in order: 400 invalid_json (the body); 400 invalid_player_id; 400
// self_request; 404 player_not_found; 409 already_friends; 409
// request_already_sent; 409 request_already_received with the pending
// request's requestId. Two requests sent at the same instant — either way —
// leave exactly one pending (db.Friends.Send).
func (h *Handler) SendFriendRequest(w http.ResponseWriter, r *http.Request, user *db.User) {
	var body SendFriendRequestBody
	if err := ReadJSONBody(r, &body); err != nil {
		h.writeError(w, r, err)
		return
	}
	playerID, ok := playerIDFrom(body.UserID)
	if !ok {
		refuseFriends(w, http.StatusBadRequest, CodeInvalidPlayerID, MsgInvalidPlayerID, nil)
		return
	}
	id, err := h.deps.Friends.Send(r.Context(), user.ID, playerID)
	var received *db.RequestAlreadyReceived
	switch {
	case errors.Is(err, db.ErrSelfRequest):
		refuseFriends(w, http.StatusBadRequest, CodeSelfRequest, MsgSelfRequest, nil)
	case errors.Is(err, db.ErrPlayerNotFound):
		refuseFriends(w, http.StatusNotFound, CodePlayerNotFound, MsgPlayerNotFound, nil)
	case errors.Is(err, db.ErrAlreadyFriends):
		refuseFriends(w, http.StatusConflict, CodeAlreadyFriends, MsgAlreadyFriends, nil)
	case errors.Is(err, db.ErrRequestAlreadySent):
		refuseFriends(w, http.StatusConflict, CodeRequestAlreadySent, MsgRequestAlreadySent, nil)
	case errors.As(err, &received):
		pending := received.RequestID
		refuseFriends(w, http.StatusConflict, CodeRequestAlreadyReceived, MsgRequestAlreadyReceived, &pending)
	case err != nil:
		h.writeError(w, r, err)
	default:
		WriteJSON(w, http.StatusCreated, SendFriendRequestResponse{RequestID: id, FriendStatus: db.FriendStatusPendingSent})
	}
}

// AcceptFriendRequest is POST /api/friends/requests/{requestId}/accept: the
// caller accepts a request addressed to them — one transaction marks it
// ACCEPTED and writes the friendship both ways — and is answered with the new
// friend, presence included. 404 request_not_found for an id that does not
// exist or is not addressed to the caller (the two are one refusal: a request
// id never says whose it is); 409 request_not_pending once it is answered.
func (h *Handler) AcceptFriendRequest(w http.ResponseWriter, r *http.Request, user *db.User) {
	requestID, ok := requestIDFrom(r.PathValue("requestId"))
	if !ok {
		refuseFriends(w, http.StatusNotFound, CodeFriendRequestNotFound, MsgFriendRequestNotFound, nil)
		return
	}
	friend, err := h.deps.Friends.Accept(r.Context(), user.ID, requestID)
	if h.refuseAnswer(w, r, err) {
		return
	}
	id := friend.Player.UserID
	WriteJSON(w, http.StatusOK, AcceptFriendRequestResponse{Friend: friendItem(*friend, h.presenceOf(r.Context(), []string{id})[id])})
}

// RejectFriendRequest is POST /api/friends/requests/{requestId}/reject:
// {requestId, status: REJECTED}. Refusals as AcceptFriendRequest's.
func (h *Handler) RejectFriendRequest(w http.ResponseWriter, r *http.Request, user *db.User) {
	requestID, ok := requestIDFrom(r.PathValue("requestId"))
	if !ok {
		refuseFriends(w, http.StatusNotFound, CodeFriendRequestNotFound, MsgFriendRequestNotFound, nil)
		return
	}
	if h.refuseAnswer(w, r, h.deps.Friends.Reject(r.Context(), user.ID, requestID)) {
		return
	}
	WriteJSON(w, http.StatusOK, RejectFriendRequestResponse{RequestID: requestID, Status: db.FriendRequestRejected})
}

// refuseAnswer writes an accept's or a reject's refusal and reports whether
// there was one.
func (h *Handler) refuseAnswer(w http.ResponseWriter, r *http.Request, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, db.ErrRequestNotFound):
		refuseFriends(w, http.StatusNotFound, CodeFriendRequestNotFound, MsgFriendRequestNotFound, nil)
	case errors.Is(err, db.ErrRequestNotPending):
		refuseFriends(w, http.StatusConflict, CodeFriendRequestNotPending, MsgFriendRequestNotPending, nil)
	default:
		h.writeError(w, r, err)
	}
	return true
}

// RemoveFriend is DELETE /api/friends/{friendUserId}: the friendship ends,
// both rows in one transaction, {removed: true}. 404 not_friends when the
// two were not friends (a Player ID that names nobody included).
func (h *Handler) RemoveFriend(w http.ResponseWriter, r *http.Request, user *db.User) {
	friendID, ok := playerIDFrom(r.PathValue("friendUserId"))
	if !ok {
		refuseFriends(w, http.StatusNotFound, CodeNotFriends, MsgNotFriends, nil)
		return
	}
	err := h.deps.Friends.Remove(r.Context(), user.ID, friendID)
	switch {
	case errors.Is(err, db.ErrNotFriends):
		refuseFriends(w, http.StatusNotFound, CodeNotFriends, MsgNotFriends, nil)
	case err != nil:
		h.writeError(w, r, err)
	default:
		WriteJSON(w, http.StatusOK, RemoveFriendResponse{Removed: true})
	}
}

// presenceOf reads ids' presence from the live store in one batch. The
// friends answers never fail for want of it: with no store, or a store that
// errs, every presence reads OFFLINE (one WARN for the request).
func (h *Handler) presenceOf(ctx context.Context, ids []string) map[string]live.Presence {
	if h.deps.Presence == nil || len(ids) == 0 {
		return map[string]live.Presence{}
	}
	out, err := h.deps.Presence.Presence(ctx, ids)
	if err != nil {
		if h.deps.Logger != nil {
			h.deps.Logger.Warn("friends presence unavailable; answering every friend offline", "error", err.Error(), "players", len(ids))
		}
		return map[string]live.Presence{}
	}
	return out
}

// ---- helpers ----------------------------------------------------------------

// playerIDFrom is a Player ID as the caller sent it, normalised
// (db.NormalizePlayerID: trimmed, lower-cased); false when that leaves it
// empty or longer than db.PlayerIDMaxLength.
func playerIDFrom(raw string) (string, bool) {
	id := db.NormalizePlayerID(raw)
	if n := utf16Len(id); n == 0 || n > db.PlayerIDMaxLength {
		return "", false
	}
	return id, true
}

// requestIDFrom is a request id from the path: a positive integer, written
// plainly (no sign, no leading zero), or false.
func requestIDFrom(raw string) (int64, bool) {
	if raw == "" || raw[0] == '0' || strings.TrimLeft(raw, "0123456789") != "" {
		return 0, false
	}
	id, err := strconv.ParseInt(raw, 10, 64)
	return id, err == nil && id > 0
}

// refuseFriends writes a friends refusal.
func refuseFriends(w http.ResponseWriter, status int, code, message string, requestID *int64) {
	WriteJSON(w, status, FriendRefusal{Error: code, Message: message, RequestID: requestID})
}

func cardOf(p db.FriendPlayer) PlayerCard {
	return PlayerCard{
		UserID:         p.UserID,
		DisplayName:    p.DisplayName,
		ProfilePicture: PlayerPicture{ID: p.PictureID, URL: p.PictureURL},
	}
}

// requestIDOf is the lookup's pending request id, for a PENDING_* status
// only.
func requestIDOf(found *db.PlayerLookup) *int64 {
	if found.FriendStatus != db.FriendStatusPendingSent && found.FriendStatus != db.FriendStatusPendingReceived {
		return nil
	}
	id := found.RequestID
	return &id
}

func presenceView(p live.Presence) PresenceView {
	view := PresenceView{Status: p.Status(), Online: p.IsOnline(), Playing: p.Playing}
	if p.Playing {
		view.Game, view.Variant = p.Game, p.Variant
	}
	return view
}

func friendItem(f db.Friend, p live.Presence) FriendItem {
	view := presenceView(p)
	return FriendItem{
		PlayerCard:   cardOf(f.Player),
		Status:       view.Status,
		Online:       view.Online,
		Playing:      view.Playing,
		Game:         view.Game,
		Variant:      view.Variant,
		FriendsSince: f.Since,
	}
}

// statusRank orders the friend list: PLAYING, ONLINE, OFFLINE.
func statusRank(status string) int {
	switch status {
	case live.StatusPlaying:
		return 0
	case live.StatusOnline:
		return 1
	default:
		return 2
	}
}

// sortFriends is the friend list's order: status (PLAYING, ONLINE, OFFLINE),
// then display name case-insensitively, then the id, so equal names always
// come back in the same order.
func sortFriends(items []FriendItem) {
	sort.SliceStable(items, func(i, j int) bool {
		a, b := items[i], items[j]
		if ra, rb := statusRank(a.Status), statusRank(b.Status); ra != rb {
			return ra < rb
		}
		if na, nb := strings.ToLower(a.DisplayName), strings.ToLower(b.DisplayName); na != nb {
			return na < nb
		}
		return a.UserID < b.UserID
	})
}

func requestItems(list []db.FriendRequest) []FriendRequestItem {
	out := make([]FriendRequestItem, 0, len(list))
	for _, r := range list {
		out = append(out, FriendRequestItem{RequestID: r.ID, Player: cardOf(r.Player), CreatedAt: r.CreatedAt})
	}
	return out
}

// statsView is a profile's stats with its win rate.
func statsView(s db.PlayerStats) PlayerStatsView {
	return PlayerStatsView{
		HandsPlayed: s.HandsPlayed,
		HandsWon:    s.HandsWon,
		HandsLost:   s.HandsLost,
		HandsLeft:   s.HandsLeft,
		WinRate:     WinRate(s.HandsWon, s.HandsPlayed),
	}
}

// WinRate is round(100 · won / played, 2): 0 before a hand has been played,
// and never over 100 — a hand won without a voluntary bet (everybody else
// packed first) counts as won but not as played (requirement 16), so won
// can outrun played.
func WinRate(won, played int64) float64 {
	if played <= 0 || won <= 0 {
		return 0
	}
	rate := math.Round(10000*float64(won)/float64(played)) / 100
	return math.Min(rate, 100)
}

// byMethod serves one path under several methods (HEAD with GET, as
// methods does), and answers anything else with the JSON 404.
func byMethod(handlers map[string]http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method := r.Method
		if method == http.MethodHead {
			method = http.MethodGet
		}
		if next, ok := handlers[method]; ok {
			next.ServeHTTP(w, r)
			return
		}
		WriteNotFound(w, r)
	})
}

// registerFriends mounts the eight friends routes; wallet is Register's
// limiter wrapper for the ones that write.
func (h *Handler) registerFriends(mux *http.ServeMux, wallet func(func(http.ResponseWriter, *http.Request, *db.User)) http.Handler) {
	mux.Handle("/api/players/{playerId}", methods(http.MethodGet, h.RequireAuth(h.FindPlayer)))
	mux.Handle("/api/players/{playerId}/profile", methods(http.MethodGet, h.RequireAuth(h.PlayerProfile)))
	mux.Handle("/api/friends", methods(http.MethodGet, h.RequireAuth(h.FriendList)))
	mux.Handle("/api/friends/requests", byMethod(map[string]http.Handler{
		http.MethodGet:  h.RequireAuth(h.FriendRequests),
		http.MethodPost: wallet(h.SendFriendRequest),
	}))
	mux.Handle("/api/friends/requests/{requestId}/accept", methods(http.MethodPost, wallet(h.AcceptFriendRequest)))
	mux.Handle("/api/friends/requests/{requestId}/reject", methods(http.MethodPost, wallet(h.RejectFriendRequest)))
	mux.Handle("/api/friends/{friendUserId}", methods(http.MethodDelete, wallet(h.RemoveFriend)))
}
