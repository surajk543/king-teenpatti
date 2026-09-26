package db

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Friends V1 (owner, 26 Sep 2026): the persistent social graph —
// friend_requests and friendships (V1.0.0's FRIENDS) — and the player lookups
// the lobby's Friends page is drawn from. A lobby feature: nothing here is
// read at a table, and whether a friend is online or playing is never here —
// that is the live store's (live.Store.Presence), merged in by the REST layer.
//
// What leaves this file about a player is a FriendPlayer — the id, the name
// and the picture they wear — and, for a profile, four gameplay counters.
// Never the wallet (chips, diamonds, hammers, missiles), the email, the
// provider identity or anything about a table.

// PlayerIDMaxLength is the longest Player ID a lookup accepts (the REST
// layer refuses a longer one as invalid_player_id). A Player ID is users.id,
// a UUID of 36 characters.
const PlayerIDMaxLength = 64

// NormalizePlayerID is a Player ID as typed turned into the users.id it
// names: surrounding whitespace trimmed, and lower-cased — every id this
// server has minted is a lower-case UUID (util.UUID), so lower-casing the
// input IS the case-insensitive comparison, and the lookup stays on the
// primary key.
func NormalizePlayerID(raw string) string {
	return strings.ToLower(strings.TrimFunc(raw, isJSSpace))
}

// Where a viewer stands with a player (the wire's friendStatus).
const (
	FriendStatusNone            = "NONE"
	FriendStatusPendingSent     = "PENDING_SENT"
	FriendStatusPendingReceived = "PENDING_RECEIVED"
	FriendStatusFriends         = "FRIENDS"
	FriendStatusSelf            = "SELF"
)

// friend_requests.status values.
const (
	FriendRequestPending   = "PENDING"
	FriendRequestAccepted  = "ACCEPTED"
	FriendRequestRejected  = "REJECTED"
	FriendRequestCancelled = "CANCELLED"
)

// The friends store's refusals. Values, compared with errors.Is, so the REST
// layer words each as its own code and never parses a message.
var (
	// ErrPlayerNotFound is a Player ID naming no account a friend may see:
	// none, a deleted one, or one support has disabled (users.is_active).
	ErrPlayerNotFound = errors.New("db: no such player")
	// ErrSelfRequest is a friend request to oneself.
	ErrSelfRequest = errors.New("db: a friend request to oneself")
	// ErrAlreadyFriends is a request to a player who is a friend already.
	ErrAlreadyFriends = errors.New("db: already friends")
	// ErrRequestAlreadySent is a request to a player the sender's own
	// request is still pending with.
	ErrRequestAlreadySent = errors.New("db: friend request already sent")
	// ErrRequestAlreadyReceived is a request to a player whose request to the
	// sender is still pending. Send returns it as a *RequestAlreadyReceived,
	// which carries that request's id so the sender can accept it instead.
	ErrRequestAlreadyReceived = errors.New("db: friend request already received")
	// ErrRequestNotFound is a request id that does not exist or is not
	// addressed to the player answering it — the two are one refusal, so a
	// request id never tells anybody whose it is.
	ErrRequestNotFound = errors.New("db: no such friend request")
	// ErrRequestNotPending is a request that has been answered already
	// (accepted, rejected, or cancelled by an account deletion).
	ErrRequestNotPending = errors.New("db: friend request not pending")
	// ErrNotFriends is removing a player who is not a friend.
	ErrNotFriends = errors.New("db: not friends")
)

// RequestAlreadyReceived is Send refusing a request because the other player's
// request to the sender is pending: errors.Is(err, ErrRequestAlreadyReceived)
// is true of it, and RequestID is that pending request.
type RequestAlreadyReceived struct {
	RequestID int64
}

func (e *RequestAlreadyReceived) Error() string {
	return fmt.Sprintf("%v: request %d", ErrRequestAlreadyReceived, e.RequestID)
}

// Unwrap makes errors.Is(err, ErrRequestAlreadyReceived) true.
func (e *RequestAlreadyReceived) Unwrap() error { return ErrRequestAlreadyReceived }

// FriendPlayer is a player as Friends shows one: who they are and the picture
// they wear, nothing else.
type FriendPlayer struct {
	UserID      string
	DisplayName string
	// PictureID is users.active_picture_id: the catalogue picture worn, nil
	// for none.
	PictureID *int64
	// PictureURL is resolved exactly as the user object's avatarUrl is
	// (Users.publicUser): the worn catalogue picture's asset_url, else the
	// photo Google gave the account, else nil.
	PictureURL *string
}

// PlayerStats are the four counters a friend's profile shows, from
// player_stats (0 with no row). No chip figure: total_winnings and
// biggest_pot stay off the profile.
type PlayerStats struct {
	HandsPlayed int64
	HandsWon    int64
	HandsLost   int64
	HandsLeft   int64
}

// PlayerLookup is one player as a viewer looks them up (GET
// /api/players/{playerId} and its /profile).
type PlayerLookup struct {
	Player FriendPlayer
	// FriendStatus is one of the FriendStatus* values.
	FriendStatus string
	// RequestID is the pending request between the two — the viewer's
	// (PENDING_SENT) or the player's (PENDING_RECEIVED) — and 0 otherwise.
	RequestID int64
	Stats     PlayerStats
}

// Friend is one friend of a player's list (or the one Accept just made).
type Friend struct {
	Player FriendPlayer
	// Since is when the two became friends (friendships.created_at, epoch ms).
	Since int64
}

// FriendRequest is one pending request as its sender or its recipient sees
// it: Player is the OTHER player.
type FriendRequest struct {
	ID        int64
	Player    FriendPlayer
	CreatedAt int64
}

// Friends is the social graph's store.
type Friends struct {
	db    *DB
	clock func() time.Time
}

// NewFriends builds the store; clock nil → time.Now.
func NewFriends(d *DB, clock func() time.Time) *Friends {
	return &Friends{db: d, clock: clock}
}

// friendPlayerColumns is a FriendPlayer, from users u joined to the picture
// worn (friendPictureJoin).
const friendPlayerColumns = `u.id, u.display_name, u.active_picture_id, ap.asset_url, u.avatar_url`

// friendPictureJoin joins the catalogue picture a player wears, for its URL.
const friendPictureJoin = ` LEFT JOIN profile_pictures ap ON ap.id = u.active_picture_id `

// visibleAccount is the filter every player Friends shows passes: not
// deleted, and not disabled by support. Either is invisible — a lookup is
// player_not_found, and lists leave them out.
const visibleAccount = `u.deleted_at = 0 AND u.is_active`

// scanFriendPlayer reads friendPlayerColumns followed by extra destinations.
func scanFriendPlayer(row pgx.Row, extra ...any) (FriendPlayer, error) {
	var p FriendPlayer
	var pictureURL, providerURL *string
	dest := append([]any{&p.UserID, &p.DisplayName, &p.PictureID, &pictureURL, &providerURL}, extra...)
	if err := row.Scan(dest...); err != nil {
		return FriendPlayer{}, err
	}
	p.PictureURL = providerURL
	if pictureURL != nil && *pictureURL != "" {
		p.PictureURL = pictureURL
	}
	return p, nil
}

// Lookup is playerID as viewerID sees them: the player, where the viewer
// stands with them, the pending request between them if there is one, and
// their counters. ErrPlayerNotFound when no visible account has that id
// (playerID must already be normalised: NormalizePlayerID). One query.
func (f *Friends) Lookup(ctx context.Context, viewerID, playerID string) (*PlayerLookup, error) {
	var out PlayerLookup
	var friends bool
	var sent, received *int64
	player, err := scanFriendPlayer(f.db.Pool.QueryRow(ctx,
		`SELECT `+friendPlayerColumns+`,
		        COALESCE(ps.hands_played, 0), COALESCE(ps.hands_won, 0), COALESCE(ps.hands_lost, 0), COALESCE(ps.hands_left, 0),
		        EXISTS (SELECT 1 FROM friendships fr WHERE fr.user_id = $1 AND fr.friend_user_id = u.id),
		        (SELECT r.id FROM friend_requests r
		          WHERE r.status = 'PENDING' AND r.requester_id = $1 AND r.recipient_id = u.id),
		        (SELECT r.id FROM friend_requests r
		          WHERE r.status = 'PENDING' AND r.requester_id = u.id AND r.recipient_id = $1)
		   FROM users u`+friendPictureJoin+`
		   LEFT JOIN player_stats ps ON ps.user_id = u.id
		  WHERE u.id = $2 AND `+visibleAccount, viewerID, playerID),
		&out.Stats.HandsPlayed, &out.Stats.HandsWon, &out.Stats.HandsLost, &out.Stats.HandsLeft,
		&friends, &sent, &received)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrPlayerNotFound
	}
	if err != nil {
		return nil, err
	}
	out.Player = player
	switch {
	case player.UserID == viewerID:
		out.FriendStatus = FriendStatusSelf
	case friends:
		out.FriendStatus = FriendStatusFriends
	case sent != nil:
		out.FriendStatus, out.RequestID = FriendStatusPendingSent, *sent
	case received != nil:
		out.FriendStatus, out.RequestID = FriendStatusPendingReceived, *received
	default:
		out.FriendStatus = FriendStatusNone
	}
	return &out, nil
}

// List is userID's friends — deleted and disabled accounts left out — in no
// particular order: the REST layer orders them by presence, which only it
// knows. Never nil.
func (f *Friends) List(ctx context.Context, userID string) ([]Friend, error) {
	rows, err := f.db.Pool.Query(ctx,
		`SELECT `+friendPlayerColumns+`, fr.created_at
		   FROM friendships fr
		   JOIN users u ON u.id = fr.friend_user_id`+friendPictureJoin+`
		  WHERE fr.user_id = $1 AND `+visibleAccount+`
		  ORDER BY u.id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Friend{}
	for rows.Next() {
		var since int64
		player, err := scanFriendPlayer(rows, &since)
		if err != nil {
			return nil, err
		}
		out = append(out, Friend{Player: player, Since: since})
	}
	return out, rows.Err()
}

// Requests is userID's PENDING requests — the ones addressed to them
// (incoming) and the ones they sent (outgoing), newest first, each naming the
// other player; a request whose other player is deleted or disabled is left
// out. Never nil.
func (f *Friends) Requests(ctx context.Context, userID string) (incoming, outgoing []FriendRequest, err error) {
	if incoming, err = f.pendingRequests(ctx, userID, "r.recipient_id", "r.requester_id"); err != nil {
		return nil, nil, err
	}
	if outgoing, err = f.pendingRequests(ctx, userID, "r.requester_id", "r.recipient_id"); err != nil {
		return nil, nil, err
	}
	return incoming, outgoing, nil
}

// pendingRequests lists the pending requests whose own column (a constant of
// this file, never input) is userID, naming the player in the other.
func (f *Friends) pendingRequests(ctx context.Context, userID, own, other string) ([]FriendRequest, error) {
	rows, err := f.db.Pool.Query(ctx,
		`SELECT `+friendPlayerColumns+`, r.id, r.created_at
		   FROM friend_requests r
		   JOIN users u ON u.id = `+other+friendPictureJoin+`
		  WHERE `+own+` = $1 AND r.status = 'PENDING' AND `+visibleAccount+`
		  ORDER BY r.created_at DESC, r.id DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FriendRequest{}
	for rows.Next() {
		var r FriendRequest
		if r.Player, err = scanFriendPlayer(rows, &r.ID, &r.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// sendAttempts bounds Send's retries of a request that lost the race for the
// pair's one pending slot to a request sent at the same instant.
const sendAttempts = 3

// pendingPairIndex is the partial unique index that allows one PENDING
// request per unordered pair (V1.0.0): a 23505 naming it is a request that
// lost the race for that slot.
const pendingPairIndex = "friend_requests_one_pending_per_pair"

// Send records fromID's friend request to toID (toID normalised) and returns
// its id. One transaction:
//
//	SELECT … FROM users WHERE id IN (from, to) ORDER BY id FOR KEY SHARE
//	(to invisible → ErrPlayerNotFound)
//	friends already → ErrAlreadyFriends
//	a pending request between them → ErrRequestAlreadySent (theirs) or
//	                                  *RequestAlreadyReceived (the other's)
//	INSERT INTO friend_requests … RETURNING id
//	friends now → ErrAlreadyFriends (rolled back)
//
// The two accounts are locked first, in id order and in the mode the foreign
// keys lock them in anyway, so an account deletion (which locks its own row
// FOR UPDATE, then cancels its pending requests) and a request to or from it
// cannot interleave: a request is never left pending with a deleted account.
//
// The pair's partial unique index is what decides a race. Two requests sent
// at the same instant — the same way twice, or each way once — both pass the
// checks, and the second insert waits for the first and then fails 23505; the
// whole transaction is then run again, and it finds the first request and
// answers with the refusal that fits. Exactly one request is ever pending.
// The friendship is looked at again after the insert because an accept of a
// request between the pair that committed after the first look would
// otherwise leave a pending request between two friends: the insert waited
// for it on the pending row it replaced, so the second look sees it.
func (f *Friends) Send(ctx context.Context, fromID, toID string) (int64, error) {
	if fromID == toID {
		return 0, ErrSelfRequest
	}
	for attempt := 1; ; attempt++ {
		id, err := f.sendOnce(ctx, fromID, toID)
		if err != nil && attempt < sendAttempts && isUniqueViolationOn(err, pendingPairIndex) {
			continue
		}
		return id, err
	}
}

func (f *Friends) sendOnce(ctx context.Context, fromID, toID string) (int64, error) {
	var id int64
	err := f.db.WithTx(ctx, func(tx pgx.Tx) error {
		visible, err := lockAccounts(ctx, tx, fromID, toID)
		if err != nil {
			return err
		}
		if !visible[toID] {
			return ErrPlayerNotFound
		}
		if !visible[fromID] {
			return fmt.Errorf("friend request from account %s, which is gone", fromID)
		}
		if friends, err := areFriends(ctx, tx, fromID, toID); err != nil {
			return err
		} else if friends {
			return ErrAlreadyFriends
		}
		var pendingID int64
		var requester string
		err = tx.QueryRow(ctx,
			`SELECT id, requester_id FROM friend_requests
			  WHERE status = 'PENDING'
			    AND ((requester_id = $1 AND recipient_id = $2) OR (requester_id = $2 AND recipient_id = $1))`,
			fromID, toID).Scan(&pendingID, &requester)
		switch {
		case err == nil && requester == fromID:
			return ErrRequestAlreadySent
		case err == nil:
			return &RequestAlreadyReceived{RequestID: pendingID}
		case !errors.Is(err, pgx.ErrNoRows):
			return err
		}
		stamp := now(f.clock)
		if err := tx.QueryRow(ctx,
			`INSERT INTO friend_requests (requester_id, recipient_id, status, created_at, updated_at)
			 VALUES ($1, $2, 'PENDING', $3, $3) RETURNING id`, fromID, toID, stamp).Scan(&id); err != nil {
			return err
		}
		if friends, err := areFriends(ctx, tx, fromID, toID); err != nil {
			return err
		} else if friends {
			return ErrAlreadyFriends
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return id, nil
}

// lockAccounts locks both accounts' rows FOR KEY SHARE, in id order (the
// order every multi-account lock in this package takes, the wallets' too),
// and reports which of them a friend may see.
func lockAccounts(ctx context.Context, tx pgx.Tx, a, b string) (map[string]bool, error) {
	rows, err := tx.Query(ctx,
		`SELECT u.id, `+visibleAccount+` FROM users u WHERE u.id IN ($1, $2) ORDER BY u.id FOR KEY SHARE`, a, b)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	visible := map[string]bool{}
	for rows.Next() {
		var id string
		var ok bool
		if err := rows.Scan(&id, &ok); err != nil {
			return nil, err
		}
		visible[id] = ok
	}
	return visible, rows.Err()
}

// areFriends is the friendship row a→b.
func areFriends(ctx context.Context, tx pgx.Tx, a, b string) (bool, error) {
	var friends bool
	err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM friendships WHERE user_id = $1 AND friend_user_id = $2)`, a, b).Scan(&friends)
	return friends, err
}

// Accept is userID accepting the request requestID, and returns the new
// friend (the request's sender) with when the friendship began. ONE
// transaction:
//
//	read the request                         (none, or not addressed to userID → ErrRequestNotFound)
//	lock both accounts FOR KEY SHARE, id order
//	SELECT status … FOR UPDATE               (not PENDING → ErrRequestNotPending)
//	UPDATE friend_requests SET status = 'ACCEPTED'
//	INSERT INTO friendships (a→b), (b→a) ON CONFLICT DO NOTHING
//
// The accounts are locked before the request row, the order an account
// deletion takes them in (its own row, then its requests), so the two queue
// rather than deadlock; the deletion that goes first cancels the request and
// the accept finds it not pending.
func (f *Friends) Accept(ctx context.Context, userID string, requestID int64) (*Friend, error) {
	var out *Friend
	err := f.db.WithTx(ctx, func(tx pgx.Tx) error {
		var requester, recipient string
		err := tx.QueryRow(ctx, `SELECT requester_id, recipient_id FROM friend_requests WHERE id = $1`, requestID).
			Scan(&requester, &recipient)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && recipient != userID) {
			return ErrRequestNotFound
		}
		if err != nil {
			return err
		}
		if _, err := lockAccounts(ctx, tx, requester, recipient); err != nil {
			return err
		}
		var status string
		if err := tx.QueryRow(ctx, `SELECT status FROM friend_requests WHERE id = $1 FOR UPDATE`, requestID).Scan(&status); err != nil {
			return err
		}
		if status != FriendRequestPending {
			return ErrRequestNotPending
		}
		stamp := now(f.clock)
		if _, err := tx.Exec(ctx, `UPDATE friend_requests SET status = 'ACCEPTED', updated_at = $2 WHERE id = $1`,
			requestID, stamp); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO friendships (user_id, friend_user_id, created_at) VALUES ($1, $2, $3), ($2, $1, $3)
			 ON CONFLICT (user_id, friend_user_id) DO NOTHING`, recipient, requester, stamp); err != nil {
			return err
		}
		var since int64
		player, err := scanFriendPlayer(tx.QueryRow(ctx,
			`SELECT `+friendPlayerColumns+`, fr.created_at
			   FROM friendships fr
			   JOIN users u ON u.id = fr.friend_user_id`+friendPictureJoin+`
			  WHERE fr.user_id = $1 AND fr.friend_user_id = $2`, recipient, requester), &since)
		if err != nil {
			return err
		}
		out = &Friend{Player: player, Since: since}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// Reject is userID turning the request requestID down: the row is marked
// REJECTED (and kept, as every request is). Refusals as Accept's: not theirs
// or none → ErrRequestNotFound, answered → ErrRequestNotPending. One
// transaction, the request row locked.
func (f *Friends) Reject(ctx context.Context, userID string, requestID int64) error {
	return f.db.WithTx(ctx, func(tx pgx.Tx) error {
		var recipient, status string
		err := tx.QueryRow(ctx, `SELECT recipient_id, status FROM friend_requests WHERE id = $1 FOR UPDATE`, requestID).
			Scan(&recipient, &status)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && recipient != userID) {
			return ErrRequestNotFound
		}
		if err != nil {
			return err
		}
		if status != FriendRequestPending {
			return ErrRequestNotPending
		}
		_, err = tx.Exec(ctx, `UPDATE friend_requests SET status = 'REJECTED', updated_at = $2 WHERE id = $1`,
			requestID, now(f.clock))
		return err
	})
}

// Remove ends the friendship of userID and friendID (normalised): both rows,
// A→B and B→A, in one transaction. ErrNotFriends when there was none.
func (f *Friends) Remove(ctx context.Context, userID, friendID string) error {
	return f.db.WithTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx,
			`DELETE FROM friendships
			  WHERE (user_id = $1 AND friend_user_id = $2) OR (user_id = $2 AND friend_user_id = $1)`, userID, friendID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFriends
		}
		return nil
	})
}

// forgetFriends is DELETE /api/account's share of the social graph, run in
// its transaction after the account's row is locked: every pending request
// the player sent or received is CANCELLED (kept, as every request is), then
// every friendship of theirs is deleted, both directions. In that order —
// the requests first — so an accept that committed while the deletion waited
// for the account's lock has its friendship rows deleted too.
func forgetFriends(ctx context.Context, tx pgx.Tx, userID string, at int64) error {
	if _, err := tx.Exec(ctx,
		`UPDATE friend_requests SET status = 'CANCELLED', updated_at = $2
		  WHERE status = 'PENDING' AND (requester_id = $1 OR recipient_id = $1)`, userID, at); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `DELETE FROM friendships WHERE user_id = $1 OR friend_user_id = $1`, userID)
	return err
}
