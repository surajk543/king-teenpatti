package db_test

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Friends V1 (owner, 26 Sep 2026): the social graph's store — search by
// Player ID, send, accept, reject, remove, the lists — and what account
// deletion does to it.

func (f *fixture) friends() *db.Friends { return db.NewFriends(f.d, nil) }

func (f *fixture) lookup(viewer, player string) *db.PlayerLookup {
	f.t.Helper()
	got, err := f.friends().Lookup(f.ctx, viewer, db.NormalizePlayerID(player))
	if err != nil {
		f.t.Fatalf("lookup %s by %s: %v", player, viewer, err)
	}
	return got
}

func (f *fixture) mustSend(from, to string) int64 {
	f.t.Helper()
	sent, err := f.friends().Send(f.ctx, from, to)
	if err != nil {
		f.t.Fatalf("send %s → %s: %v", from, to, err)
	}
	return sent.ID
}

func (f *fixture) befriend(a, b string) {
	f.t.Helper()
	id := f.mustSend(a, b)
	if _, err := f.friends().Accept(f.ctx, b, id); err != nil {
		f.t.Fatalf("accept %d: %v", id, err)
	}
}

func (f *fixture) disable(userID string) {
	f.t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE users SET is_active = FALSE WHERE id = $1`, userID); err != nil {
		f.t.Fatal(err)
	}
}

func friendIDs(list []db.Friend) string {
	ids := make([]string, len(list))
	for i, fr := range list {
		ids[i] = fr.Player.DisplayName
	}
	return strings.Join(ids, ",")
}

func requestNames(list []db.FriendRequest) string {
	ids := make([]string, len(list))
	for i, r := range list {
		ids[i] = r.Player.DisplayName
	}
	return strings.Join(ids, ",")
}

func TestAPlayerIsFoundByTheirPlayerIDWhateverItsCaseAndSpacing(t *testing.T) {
	f := newFixture(t)
	viewer, target := f.user("Viewer"), f.user("Target")

	typed := "  \t" + strings.ToUpper(target.ID) + " \n"
	got := f.lookup(viewer.ID, typed)
	if got.Player.UserID != target.ID || got.Player.DisplayName != "Target" || got.FriendStatus != db.FriendStatusNone || got.RequestID != 0 {
		t.Fatalf("lookup = %+v", got)
	}
	if got.Player.PictureID != nil || got.Player.PictureURL != nil {
		t.Fatalf("a guest wearing nothing has no picture: %+v", got.Player)
	}
	if self := f.lookup(viewer.ID, viewer.ID); self.FriendStatus != db.FriendStatusSelf {
		t.Fatalf("looking yourself up = %s, want SELF", self.FriendStatus)
	}

	for _, missing := range []string{"no-such-player", strings.Repeat("a", 36), ""} {
		if _, err := f.friends().Lookup(f.ctx, viewer.ID, db.NormalizePlayerID(missing)); !errors.Is(err, db.ErrPlayerNotFound) {
			t.Fatalf("lookup %q: %v, want ErrPlayerNotFound", missing, err)
		}
	}
	// A disabled account is not found, and neither is a deleted one.
	disabled, deleted := f.user("Disabled"), f.user("Deleted")
	f.disable(disabled.ID)
	if err := f.users.DeleteAccount(f.ctx, deleted.ID); err != nil {
		t.Fatal(err)
	}
	for _, gone := range []string{disabled.ID, deleted.ID} {
		if _, err := f.friends().Lookup(f.ctx, viewer.ID, gone); !errors.Is(err, db.ErrPlayerNotFound) {
			t.Fatalf("lookup of an account that is %s: %v", gone, err)
		}
	}
}

// PlayerCard's picture is resolved exactly as the user object's avatarUrl:
// the worn catalogue picture, else the provider's photo, else nothing — and
// the stats come from player_stats.
func TestAPlayersPictureAndStatsAreThoseTheirAccountShows(t *testing.T) {
	f := newFixture(t)
	viewer := f.user("Viewer")
	photo := "https://lh3.example/photo.jpg"
	google, _, err := f.users.UpsertFromProfile(f.ctx, db.Profile{Provider: db.ProviderGoogle, ProviderUserID: "friends-" + randomSuffix(t),
		DisplayName: "Googler", AvatarURL: &photo})
	if err != nil {
		t.Fatal(err)
	}
	got := f.lookup(viewer.ID, google.ID)
	if got.Player.PictureID != nil || got.Player.PictureURL == nil || *got.Player.PictureURL != photo {
		t.Fatalf("the provider photo: %+v", got.Player)
	}

	var pictureID int64
	var url string
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT id, asset_url FROM profile_pictures WHERE type = 'FREE' ORDER BY id LIMIT 1`).Scan(&pictureID, &url); err != nil {
		t.Fatal(err)
	}
	worn, err := f.users.SetActivePicture(f.ctx, google.ID, &pictureID)
	if err != nil {
		t.Fatal(err)
	}
	got = f.lookup(viewer.ID, google.ID)
	if got.Player.PictureID == nil || *got.Player.PictureID != pictureID || got.Player.PictureURL == nil || *got.Player.PictureURL != url ||
		worn.AvatarURL == nil || *worn.AvatarURL != *got.Player.PictureURL {
		t.Fatalf("the worn picture: %+v, the account says %v", got.Player, worn.AvatarURL)
	}

	hand := "hand-profile-" + randomSuffix(t)
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "room-profile", HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, google.ID, 500, true, true, 1000),
		settleEntry(hand, viewer.ID, -500, false, true, 0),
	}}); err != nil {
		t.Fatal(err)
	}
	if got := f.lookup(viewer.ID, google.ID).Stats; got != (db.PlayerStats{HandsPlayed: 1, HandsWon: 1}) {
		t.Fatalf("the winner's stats = %+v", got)
	}
	if got := f.lookup(google.ID, viewer.ID).Stats; got != (db.PlayerStats{HandsPlayed: 1, HandsLost: 1}) {
		t.Fatalf("the loser's stats = %+v", got)
	}
}

func TestARequestIsPendingOnceAndOnlyItsRecipientAnswersIt(t *testing.T) {
	f := newFixture(t)
	a, b, c := f.user("A"), f.user("B"), f.user("C")
	fr := f.friends()

	if _, err := fr.Send(f.ctx, a.ID, a.ID); !errors.Is(err, db.ErrSelfRequest) {
		t.Fatalf("a request to oneself: %v", err)
	}
	if _, err := fr.Send(f.ctx, a.ID, "no-such-player"); !errors.Is(err, db.ErrPlayerNotFound) {
		t.Fatalf("a request to nobody: %v", err)
	}
	id := f.mustSend(a.ID, b.ID)
	if got := f.lookup(a.ID, b.ID); got.FriendStatus != db.FriendStatusPendingSent || got.RequestID != id {
		t.Fatalf("the sender sees %+v", got)
	}
	if got := f.lookup(b.ID, a.ID); got.FriendStatus != db.FriendStatusPendingReceived || got.RequestID != id {
		t.Fatalf("the recipient sees %+v", got)
	}
	if got := f.lookup(c.ID, a.ID); got.FriendStatus != db.FriendStatusNone || got.RequestID != 0 {
		t.Fatalf("a third player sees %+v", got)
	}
	// The same request again, and the reverse one.
	if _, err := fr.Send(f.ctx, a.ID, b.ID); !errors.Is(err, db.ErrRequestAlreadySent) {
		t.Fatalf("a duplicate: %v", err)
	}
	var received *db.RequestAlreadyReceived
	if _, err := fr.Send(f.ctx, b.ID, a.ID); !errors.As(err, &received) || received.RequestID != id || !errors.Is(err, db.ErrRequestAlreadyReceived) {
		t.Fatalf("the reverse request: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM friend_requests WHERE status = 'PENDING'`); n != 1 {
		t.Fatalf("%d pending requests, want 1", n)
	}

	// Only the recipient answers, and an id that is not theirs is not found.
	for _, who := range []string{a.ID, c.ID} {
		if _, err := fr.Accept(f.ctx, who, id); !errors.Is(err, db.ErrRequestNotFound) {
			t.Fatalf("accept by %s: %v", who, err)
		}
		if err := fr.Reject(f.ctx, who, id); !errors.Is(err, db.ErrRequestNotFound) {
			t.Fatalf("reject by %s: %v", who, err)
		}
	}
	if _, err := fr.Accept(f.ctx, b.ID, 987654321); !errors.Is(err, db.ErrRequestNotFound) {
		t.Fatalf("an unknown id: %v", err)
	}
	accepted, err := fr.Accept(f.ctx, b.ID, id)
	if err != nil {
		t.Fatal(err)
	}
	if friend := accepted.Sender; friend.Player.UserID != a.ID || friend.Player.DisplayName != "A" || friend.Since <= 0 {
		t.Fatalf("the new friend = %+v", friend)
	}
	if accepter := accepted.Recipient; accepter.Player.UserID != b.ID || accepter.Player.DisplayName != "B" || accepter.Since != accepted.Sender.Since {
		t.Fatalf("the player who accepted = %+v", accepter)
	}
	// One transaction wrote both rows, and the request is ACCEPTED.
	if n := f.count(`SELECT count(*) FROM friendships WHERE (user_id = $1 AND friend_user_id = $2) OR (user_id = $2 AND friend_user_id = $1)`, a.ID, b.ID); n != 2 {
		t.Fatalf("%d friendship rows, want both directions", n)
	}
	if n := f.count(`SELECT count(*) FROM friend_requests WHERE id = $1 AND status = 'ACCEPTED'`, id); n != 1 {
		t.Fatal("the request is not ACCEPTED")
	}
	if _, err := fr.Accept(f.ctx, b.ID, id); !errors.Is(err, db.ErrRequestNotPending) {
		t.Fatalf("accepting twice: %v", err)
	}
	if err := fr.Reject(f.ctx, b.ID, id); !errors.Is(err, db.ErrRequestNotPending) {
		t.Fatalf("rejecting an accepted request: %v", err)
	}
	for _, pair := range [][2]string{{a.ID, b.ID}, {b.ID, a.ID}} {
		if got := f.lookup(pair[0], pair[1]); got.FriendStatus != db.FriendStatusFriends {
			t.Fatalf("after the accept %s sees %+v", pair[0], got)
		}
		if _, err := fr.Send(f.ctx, pair[0], pair[1]); !errors.Is(err, db.ErrAlreadyFriends) {
			t.Fatalf("a request between friends: %v", err)
		}
	}

	// A rejection: kept as REJECTED, and the pair may try again after.
	rejected := f.mustSend(c.ID, a.ID)
	if err := fr.Reject(f.ctx, a.ID, rejected); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM friend_requests WHERE id = $1 AND status = 'REJECTED'`, rejected); n != 1 {
		t.Fatal("the request is not REJECTED")
	}
	if n := f.count(`SELECT count(*) FROM friendships WHERE user_id = $1 OR friend_user_id = $1`, c.ID); n != 0 {
		t.Fatal("a rejection made friends")
	}
	if got := f.lookup(c.ID, a.ID); got.FriendStatus != db.FriendStatusNone {
		t.Fatalf("after the rejection = %+v", got)
	}
	again := f.mustSend(c.ID, a.ID)
	if again == rejected {
		t.Fatal("a new request is a new row")
	}
}

// Friends at the table (owner, 26 Sep 2026): Send hands back the request as
// its recipient will list it, and Accept both players of the new friendship
// as each will list the other — read inside their transactions, so what the
// socket pushes is exactly what the lists say next, the worn picture and the
// times included.
func TestASentAndAnAcceptedRequestComeBackAsEachSideWillListThem(t *testing.T) {
	f := newFixture(t)
	sender, recipient := f.user("Sender"), f.user("Recipient")
	var pictureID int64
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT id FROM profile_pictures WHERE type = 'FREE' ORDER BY id LIMIT 1`).Scan(&pictureID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.users.SetActivePicture(f.ctx, sender.ID, &pictureID); err != nil {
		t.Fatal(err)
	}

	sent, err := f.friends().Send(f.ctx, sender.ID, recipient.ID)
	if err != nil {
		t.Fatal(err)
	}
	if sent.Player.UserID != sender.ID || sent.Player.DisplayName != "Sender" || sent.Player.PictureID == nil ||
		*sent.Player.PictureID != pictureID || sent.Player.PictureURL == nil || sent.CreatedAt <= 0 {
		t.Fatalf("Send = %+v", sent)
	}
	incoming, _, err := f.friends().Requests(f.ctx, recipient.ID)
	if err != nil || len(incoming) != 1 || !reflect.DeepEqual(*sent, incoming[0]) {
		t.Fatalf("Send = %+v, the recipient's incoming = %+v (%v)", *sent, incoming, err)
	}

	accepted, err := f.friends().Accept(f.ctx, recipient.ID, sent.ID)
	if err != nil {
		t.Fatal(err)
	}
	if accepted.Sender.Player.UserID != sender.ID || accepted.Recipient.Player.UserID != recipient.ID {
		t.Fatalf("Accept = %+v", accepted)
	}
	for _, side := range []struct {
		lister string
		got    db.Friend
	}{{recipient.ID, accepted.Sender}, {sender.ID, accepted.Recipient}} {
		list, err := f.friends().List(f.ctx, side.lister)
		if err != nil || len(list) != 1 || !reflect.DeepEqual(side.got, list[0]) {
			t.Fatalf("Accept says %+v, %s's list says %+v (%v)", side.got, side.lister, list, err)
		}
	}
}

// The pair's partial unique index decides two requests sent at the same
// instant — the same way twice, or each way once: exactly one is pending, and
// every other sender is told why.
func TestConcurrentSendsBothWaysLeaveExactlyOnePendingRequest(t *testing.T) {
	f := newFixture(t)
	for round := 0; round < 12; round++ {
		a, b := f.user(fmt.Sprintf("A%d", round)), f.user(fmt.Sprintf("B%d", round))
		var wg sync.WaitGroup
		var mu sync.Mutex
		sent, refused := 0, map[string]int{}
		for i := 0; i < 6; i++ {
			from, to := a.ID, b.ID
			if i%2 == 1 {
				from, to = b.ID, a.ID
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, err := f.friends().Send(f.ctx, from, to)
				mu.Lock()
				defer mu.Unlock()
				switch {
				case err == nil:
					sent++
				case errors.Is(err, db.ErrRequestAlreadySent):
					refused["sent"]++
				case errors.Is(err, db.ErrRequestAlreadyReceived):
					refused["received"]++
				default:
					t.Errorf("round %d: %v", round, err)
				}
			}()
		}
		wg.Wait()
		if sent != 1 || refused["sent"]+refused["received"] != 5 {
			t.Fatalf("round %d: %d sent, refused %v — want exactly one request", round, sent, refused)
		}
		if n := f.count(`SELECT count(*) FROM friend_requests WHERE status = 'PENDING' AND $1 IN (requester_id, recipient_id)`, a.ID); n != 1 {
			t.Fatalf("round %d: %d pending requests between the pair", round, n)
		}
	}
}

// A double tap on Accept, and an accept racing an account deletion, each end
// one way — one friendship or none — and never in a deadlock.
func TestConcurrentAnswersEndOneWay(t *testing.T) {
	f := newFixture(t)
	for round := 0; round < 8; round++ {
		a, b := f.user(fmt.Sprintf("A%d", round)), f.user(fmt.Sprintf("B%d", round))
		id := f.mustSend(a.ID, b.ID)
		var wg sync.WaitGroup
		results := make([]error, 4)
		for i := range results {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if i%2 == 0 {
					_, results[i] = f.friends().Accept(f.ctx, b.ID, id)
				} else {
					results[i] = f.friends().Reject(f.ctx, b.ID, id)
				}
			}()
		}
		wg.Wait()
		won := 0
		for _, err := range results {
			switch {
			case err == nil:
				won++
			case errors.Is(err, db.ErrRequestNotPending):
			default:
				t.Fatalf("round %d: %v", round, err)
			}
		}
		if won != 1 {
			t.Fatalf("round %d: %d answers took, want exactly one", round, won)
		}
	}

	for round := 0; round < 8; round++ {
		a, b := f.user(fmt.Sprintf("Leaving%d", round)), f.user(fmt.Sprintf("Staying%d", round))
		id := f.mustSend(a.ID, b.ID)
		var wg sync.WaitGroup
		var acceptErr, deleteErr error
		wg.Add(2)
		go func() { defer wg.Done(); _, acceptErr = f.friends().Accept(f.ctx, b.ID, id) }()
		go func() { defer wg.Done(); deleteErr = f.users.DeleteAccount(f.ctx, a.ID) }()
		wg.Wait()
		if deleteErr != nil || (acceptErr != nil && !errors.Is(acceptErr, db.ErrRequestNotPending)) {
			t.Fatalf("round %d: accept %v, delete %v", round, acceptErr, deleteErr)
		}
		// Whichever went first, the deleted account keeps no friend and
		// nothing is pending with it.
		if n := f.count(`SELECT count(*) FROM friendships WHERE user_id = $1 OR friend_user_id = $1`, a.ID); n != 0 {
			t.Fatalf("round %d: %d friendship rows survive the deletion", round, n)
		}
		if n := f.count(`SELECT count(*) FROM friend_requests WHERE status = 'PENDING' AND $1 IN (requester_id, recipient_id)`, a.ID); n != 0 {
			t.Fatalf("round %d: a request is still pending with a deleted account", round)
		}
	}
}

func TestRemovingAFriendDeletesBothRows(t *testing.T) {
	f := newFixture(t)
	a, b, c := f.user("A"), f.user("B"), f.user("C")
	f.befriend(a.ID, b.ID)
	f.befriend(a.ID, c.ID)
	if err := f.friends().Remove(f.ctx, b.ID, a.ID); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM friendships WHERE (user_id = $1 AND friend_user_id = $2) OR (user_id = $2 AND friend_user_id = $1)`, a.ID, b.ID); n != 0 {
		t.Fatalf("%d rows survive the removal", n)
	}
	for _, pair := range [][2]string{{a.ID, b.ID}, {b.ID, a.ID}} {
		if got := f.lookup(pair[0], pair[1]); got.FriendStatus != db.FriendStatusNone {
			t.Fatalf("%s sees %+v after the removal", pair[0], got)
		}
	}
	if err := f.friends().Remove(f.ctx, a.ID, b.ID); !errors.Is(err, db.ErrNotFriends) {
		t.Fatalf("removing again: %v", err)
	}
	if err := f.friends().Remove(f.ctx, a.ID, a.ID); !errors.Is(err, db.ErrNotFriends) {
		t.Fatalf("removing yourself: %v", err)
	}
	list, err := f.friends().List(f.ctx, a.ID)
	if err != nil || friendIDs(list) != "C" {
		t.Fatalf("A's friends after the removal = %s %v", friendIDs(list), err)
	}
}

func TestTheListsLeaveOutDeletedAndDisabledAccountsAndPutTheNewestRequestFirst(t *testing.T) {
	f := newFixture(t)
	me := f.user("Me")
	friendly, disabled, deleted := f.user("Friendly"), f.user("Disabled"), f.user("Deleted")
	for _, other := range []string{friendly.ID, disabled.ID, deleted.ID} {
		f.befriend(me.ID, other)
	}
	first, second, third := f.user("First"), f.user("Second"), f.user("Third")
	f.mustSend(first.ID, me.ID)
	f.mustSend(second.ID, me.ID)
	f.mustSend(me.ID, third.ID)
	offTarget := f.user("OffTarget")
	f.mustSend(me.ID, offTarget.ID)
	// Newest first: stamp the requests apart.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE friend_requests SET created_at = created_at + CASE requester_id WHEN $1 THEN 10 ELSE 20 END
	     WHERE requester_id IN ($1, $2)`, first.ID, second.ID); err != nil {
		t.Fatal(err)
	}
	f.disable(disabled.ID)
	f.disable(offTarget.ID)
	if err := f.users.DeleteAccount(f.ctx, deleted.ID); err != nil {
		t.Fatal(err)
	}

	list, err := f.friends().List(f.ctx, me.ID)
	if err != nil || friendIDs(list) != "Friendly" {
		t.Fatalf("my friends = %s %v", friendIDs(list), err)
	}
	if list[0].Since <= 0 {
		t.Fatalf("friendsSince = %d", list[0].Since)
	}
	incoming, outgoing, err := f.friends().Requests(f.ctx, me.ID)
	if err != nil {
		t.Fatal(err)
	}
	if requestNames(incoming) != "Second,First" || requestNames(outgoing) != "Third" {
		t.Fatalf("incoming %s, outgoing %s", requestNames(incoming), requestNames(outgoing))
	}
	if incoming[0].ID <= 0 || incoming[0].CreatedAt <= 0 {
		t.Fatalf("a request item = %+v", incoming[0])
	}
	// Nobody else's requests.
	_, theirs, err := f.friends().Requests(f.ctx, first.ID)
	if err != nil || requestNames(theirs) != "Me" {
		t.Fatalf("First's outgoing = %s %v", requestNames(theirs), err)
	}
	empty, none, err := f.friends().Requests(f.ctx, friendly.ID)
	if err != nil || empty == nil || none == nil || len(empty)+len(none) != 0 {
		t.Fatalf("no requests is two empty lists: %v %v %v", empty, none, err)
	}
}

// DELETE /api/account's share of the graph: every friendship of the player's
// goes, both directions, and every pending request either way is CANCELLED —
// kept, as every request is.
func TestDeletingAnAccountClearsItsFriendshipsAndCancelsItsRequests(t *testing.T) {
	f := newFixture(t)
	leaver, b, c, d, e := f.user("Leaver"), f.user("B"), f.user("C"), f.user("D"), f.user("E")
	f.befriend(leaver.ID, b.ID)
	f.befriend(c.ID, leaver.ID)
	out := f.mustSend(leaver.ID, d.ID)
	in := f.mustSend(e.ID, leaver.ID)
	f.befriend(b.ID, c.ID) // somebody else's friendship

	if err := f.users.DeleteAccount(f.ctx, leaver.ID); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM friendships WHERE user_id = $1 OR friend_user_id = $1`, leaver.ID); n != 0 {
		t.Fatalf("%d friendship rows survive the deletion", n)
	}
	if n := f.count(`SELECT count(*) FROM friend_requests WHERE id IN ($1, $2) AND status = 'CANCELLED'`, out, in); n != 2 {
		t.Fatalf("%d of the two pending requests are CANCELLED", n)
	}
	if n := f.count(`SELECT count(*) FROM friendships WHERE user_id IN ($1, $2)`, b.ID, c.ID); n != 2 {
		t.Fatalf("B and C's own friendship: %d rows", n)
	}
	for _, other := range []string{b.ID, c.ID} {
		list, err := f.friends().List(f.ctx, other)
		if err != nil || strings.Contains(friendIDs(list), db.DeletedDisplayName) {
			t.Fatalf("a friend list still shows the deleted account: %s %v", friendIDs(list), err)
		}
	}
	if _, err := f.friends().Accept(f.ctx, d.ID, out); !errors.Is(err, db.ErrRequestNotPending) {
		t.Fatalf("accepting a cancelled request: %v", err)
	}
	f.reconcile()
}
