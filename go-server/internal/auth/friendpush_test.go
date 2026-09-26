package auth

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// Friends at the table (owner, 26 Sep 2026), the REST half of the two pushes:
// a request made tells its recipient (Deps.FriendRequestSent), an accept tells
// the request's sender (Deps.FriendRequestAccepted) — each once the store has
// committed and the answer is written, and never for a refusal, a reject or a
// removal. The socket half is internal/socket's; the two together over real
// sockets are internal/app's.

// fakeFriendStore answers every FriendStore call with what the test put in it.
type fakeFriendStore struct {
	sent      *db.FriendRequest
	sendErr   error
	accepted  *db.AcceptedRequest
	acceptErr error
	rejectErr error
	removeErr error
	incoming  []db.FriendRequest
}

func (f *fakeFriendStore) Lookup(context.Context, string, string) (*db.PlayerLookup, error) {
	return nil, db.ErrPlayerNotFound
}

func (f *fakeFriendStore) List(context.Context, string) ([]db.Friend, error) {
	return []db.Friend{}, nil
}

func (f *fakeFriendStore) Requests(context.Context, string) ([]db.FriendRequest, []db.FriendRequest, error) {
	return f.incoming, []db.FriendRequest{}, nil
}

func (f *fakeFriendStore) Send(context.Context, string, string) (*db.FriendRequest, error) {
	return f.sent, f.sendErr
}

func (f *fakeFriendStore) Accept(context.Context, string, int64) (*db.AcceptedRequest, error) {
	return f.accepted, f.acceptErr
}

func (f *fakeFriendStore) Reject(context.Context, string, int64) error { return f.rejectErr }

func (f *fakeFriendStore) Remove(context.Context, string, string) error { return f.removeErr }

// friendPush is one hook call: to whom, which push, its JSON, and the answer
// as it stood when the push was made.
type friendPush struct {
	to, event, payload string
	answered           string
}

// pushHarness is a Handler on a fakeFriendStore whose hooks record every
// push, with the answer the handler had written by then.
type pushHarness struct {
	t      *testing.T
	store  *fakeFriendStore
	h      *Handler
	rec    *httptest.ResponseRecorder
	pushes []friendPush
}

func newPushHarness(t *testing.T) *pushHarness {
	ph := &pushHarness{t: t, store: &fakeFriendStore{}}
	record := func(to, event string, payload any) {
		raw, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		ph.pushes = append(ph.pushes, friendPush{to: to, event: event, payload: string(raw), answered: ph.rec.Body.String()})
	}
	ph.h = NewHandler(Deps{
		Friends:               ph.store,
		FriendRequestSent:     func(to string, item FriendRequestItem) { record(to, "friend:request", item) },
		FriendRequestAccepted: func(to string, accepted FriendAccepted) { record(to, "friend:accepted", accepted) },
	})
	return ph
}

// call runs one friends handler for caller, the way RequireAuth would, and
// returns the answer.
func (ph *pushHarness) call(handler func(http.ResponseWriter, *http.Request, *db.User), method, body, requestID string) *httptest.ResponseRecorder {
	ph.t.Helper()
	var req *http.Request
	if body == "" {
		req = httptest.NewRequest(method, "/api/friends/requests", nil)
	} else {
		req = httptest.NewRequest(method, "/api/friends/requests", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
	}
	if requestID != "" {
		req.SetPathValue("requestId", requestID)
	}
	req.SetPathValue("friendUserId", "sender-id")
	ph.rec = httptest.NewRecorder()
	handler(ph.rec, req, &db.User{ID: "caller-id", DisplayName: "Caller"})
	return ph.rec
}

func TestAFriendRequestIsAnnouncedToItsRecipientOnceItsAnswerIsWritten(t *testing.T) {
	ph := newPushHarness(t)
	picture, url := int64(7), "https://cdn.example/bear.svg"
	sender := db.FriendPlayer{UserID: "caller-id", DisplayName: "Caller", PictureID: &picture, PictureURL: &url}
	ph.store.sent = &db.FriendRequest{ID: 41, Player: sender, CreatedAt: 1_790_000_000_000}

	rec := ph.call(ph.h.SendFriendRequest, http.MethodPost, `{"userId":"  RECIPIENT-ID "}`, "")
	if rec.Code != http.StatusCreated || rec.Body.String() != `{"requestId":41,"friendStatus":"PENDING_SENT"}` {
		t.Fatalf("send: %d %s", rec.Code, rec.Body)
	}
	if len(ph.pushes) != 1 {
		t.Fatalf("pushes = %+v, want one", ph.pushes)
	}
	push := ph.pushes[0]
	// To the recipient the Player ID names (normalised), carrying the SENDER.
	if push.to != "recipient-id" || push.event != "friend:request" ||
		push.payload != `{"requestId":41,"player":{"userId":"caller-id","displayName":"Caller","profilePicture":{"id":7,"url":"https://cdn.example/bear.svg"}},"createdAt":1790000000000}` {
		t.Fatalf("the push = %+v", push)
	}
	if push.answered != rec.Body.String() {
		t.Fatalf("pushed before the answer was written: had %q", push.answered)
	}
	// Byte for byte an item of the recipient's GET /api/friends/requests.
	ph.store.incoming = []db.FriendRequest{*ph.store.sent}
	list := ph.call(ph.h.FriendRequests, http.MethodGet, "", "")
	var body struct {
		Incoming []json.RawMessage `json:"incoming"`
	}
	if err := json.Unmarshal(list.Body.Bytes(), &body); err != nil || len(body.Incoming) != 1 || string(body.Incoming[0]) != push.payload {
		t.Fatalf("the incoming list %s, the push %s (%v)", list.Body, push.payload, err)
	}
}

func TestAnAcceptIsAnnouncedToTheRequestsSenderOnceItsAnswerIsWritten(t *testing.T) {
	ph := newPushHarness(t)
	picture, url := int64(3), "https://cdn.example/fox.svg"
	ph.store.accepted = &db.AcceptedRequest{
		Sender:    db.Friend{Player: db.FriendPlayer{UserID: "sender-id", DisplayName: "Sender", PictureID: &picture, PictureURL: &url}, Since: 1_790_000_000_500},
		Recipient: db.Friend{Player: db.FriendPlayer{UserID: "caller-id", DisplayName: "Caller"}, Since: 1_790_000_000_501},
	}

	rec := ph.call(ph.h.AcceptFriendRequest, http.MethodPost, "", "41")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"userId":"sender-id"`) {
		t.Fatalf("accept: %d %s", rec.Code, rec.Body)
	}
	if len(ph.pushes) != 1 {
		t.Fatalf("pushes = %+v, want one", ph.pushes)
	}
	push := ph.pushes[0]
	// To the request's sender, carrying the player who accepted — and the
	// sender's own friendsSince.
	if push.to != "sender-id" || push.event != "friend:accepted" ||
		push.payload != `{"requestId":41,"player":{"userId":"caller-id","displayName":"Caller","profilePicture":{"id":null,"url":null}},"friendsSince":1790000000501}` {
		t.Fatalf("the push = %+v", push)
	}
	if push.answered != rec.Body.String() {
		t.Fatalf("pushed before the answer was written: had %q", push.answered)
	}
}

// A refusal is never announced, nor is a reject or a removal.
func TestNoRefusalRejectOrRemovalIsEverAnnounced(t *testing.T) {
	ph := newPushHarness(t)
	ph.store.sent = &db.FriendRequest{ID: 41, Player: db.FriendPlayer{UserID: "caller-id"}}
	for _, refusal := range []error{
		db.ErrSelfRequest, db.ErrPlayerNotFound, db.ErrAlreadyFriends, db.ErrRequestAlreadySent,
		&db.RequestAlreadyReceived{RequestID: 9}, errors.New("db: connection reset"),
	} {
		ph.store.sendErr = refusal
		if rec := ph.call(ph.h.SendFriendRequest, http.MethodPost, `{"userId":"recipient-id"}`, ""); rec.Code < 400 {
			t.Fatalf("a send refused %v answered %d", refusal, rec.Code)
		}
	}
	for _, body := range []string{`{}`, `{"userId":42}`, `{"userId":`} {
		ph.call(ph.h.SendFriendRequest, http.MethodPost, body, "")
	}
	ph.store.accepted = &db.AcceptedRequest{Sender: db.Friend{Player: db.FriendPlayer{UserID: "sender-id"}}}
	for _, refusal := range []error{db.ErrRequestNotFound, db.ErrRequestNotPending, errors.New("db: connection reset")} {
		ph.store.acceptErr = refusal
		if rec := ph.call(ph.h.AcceptFriendRequest, http.MethodPost, "", "41"); rec.Code < 400 {
			t.Fatalf("an accept refused %v answered %d", refusal, rec.Code)
		}
	}
	ph.store.acceptErr = nil
	ph.call(ph.h.AcceptFriendRequest, http.MethodPost, "", "abc")
	if rec := ph.call(ph.h.RejectFriendRequest, http.MethodPost, "", "41"); rec.Code != http.StatusOK {
		t.Fatalf("reject: %d %s", rec.Code, rec.Body)
	}
	if rec := ph.call(ph.h.RemoveFriend, http.MethodDelete, "", ""); rec.Code != http.StatusOK {
		t.Fatalf("remove: %d %s", rec.Code, rec.Body)
	}
	if len(ph.pushes) != 0 {
		t.Fatalf("announced: %+v", ph.pushes)
	}
}

// With no hooks wired the routes answer as they always did.
func TestTheFriendRoutesAnswerWithNobodyToTell(t *testing.T) {
	store := &fakeFriendStore{
		sent:     &db.FriendRequest{ID: 5, Player: db.FriendPlayer{UserID: "caller-id"}},
		accepted: &db.AcceptedRequest{Sender: db.Friend{Player: db.FriendPlayer{UserID: "sender-id"}}},
	}
	ph := &pushHarness{t: t, store: store, h: NewHandler(Deps{Friends: store})}
	if rec := ph.call(ph.h.SendFriendRequest, http.MethodPost, `{"userId":"recipient-id"}`, ""); rec.Code != http.StatusCreated {
		t.Fatalf("send: %d %s", rec.Code, rec.Body)
	}
	if rec := ph.call(ph.h.AcceptFriendRequest, http.MethodPost, "", "5"); rec.Code != http.StatusOK {
		t.Fatalf("accept: %d %s", rec.Code, rec.Body)
	}
}
