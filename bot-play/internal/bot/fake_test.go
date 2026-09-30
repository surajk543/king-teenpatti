package bot

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// fakeServer is a scripted stand-in for the game server's API and
// connections: the test answers each request and pushes each event itself,
// so a test states exactly what the server did and checks exactly what the
// bot sent. It is not a simulation (that is internal/sim).
type fakeServer struct {
	t  *testing.T
	mu sync.Mutex

	chips      int64
	logins     int
	dials      int
	refuseDial []error // popped per Dial
	catalogue  protocol.Catalogue

	sessions []*fakeSession
	sessCh   chan *fakeSession
	// answer is consulted for every request; nil means {ok:true}.
	answer func(event string, payload map[string]any) any
}

type request struct {
	event   string
	payload map[string]any
	reply   chan any
}

func newFakeServer(t *testing.T) *fakeServer {
	return &fakeServer{
		t:      t,
		chips:  1_000_000,
		sessCh: make(chan *fakeSession, 16),
		catalogue: protocol.Catalogue{
			Version:       "v1",
			TurnTimeoutMs: 25000,
			Tables: []protocol.TableEntry{
				{Key: "seen:200", Engine: "teen_patti", Category: "seen", BootAmount: 200, TurnTimeoutMs: 25000, SortOrder: 10},
				{Key: "blind:200", Engine: "teen_patti", Category: "blind", BootAmount: 200, MaxChips: 2_000_000, TurnTimeoutMs: 25000, SortOrder: 20},
				{Key: "texas_holdem:50000", Engine: "poker", Category: "texas_holdem", BootAmount: 50000, MinChips: 500000, SortOrder: 90},
			},
		},
	}
}

// ---- protocol.API ----

func (f *fakeServer) Login(ctx context.Context, deviceID, name string) (protocol.LoginResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.logins++
	return protocol.LoginResult{Token: "tok-" + deviceID, User: protocol.User{ID: "u-" + deviceID, DisplayName: name, Chips: f.chips}, IsNew: f.logins == 1}, nil
}

func (f *fakeServer) Tables(ctx context.Context) (protocol.Catalogue, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.catalogue, nil
}

func (f *fakeServer) Me(ctx context.Context, token string) (protocol.User, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return protocol.User{ID: "u", Chips: f.chips}, nil
}

func (f *fakeServer) FreePictureIDs(ctx context.Context) ([]int64, error) { return []int64{1, 2}, nil }
func (f *fakeServer) WearPicture(ctx context.Context, token string, id int64) error {
	return nil
}

// ---- protocol.Dialer ----

func (f *fakeServer) Dial(ctx context.Context, token string) (protocol.Session, error) {
	f.mu.Lock()
	f.dials++
	if len(f.refuseDial) > 0 {
		err := f.refuseDial[0]
		f.refuseDial = f.refuseDial[1:]
		f.mu.Unlock()
		return nil, err
	}
	s := &fakeSession{
		server:   f,
		events:   make(chan protocol.Event, 64),
		done:     make(chan struct{}),
		requests: make(chan request, 64),
	}
	f.sessions = append(f.sessions, s)
	f.mu.Unlock()
	f.sessCh <- s
	return s, nil
}

// nextSession waits for the bot's next connection.
func (f *fakeServer) nextSession() *fakeSession {
	f.t.Helper()
	select {
	case s := <-f.sessCh:
		return s
	case <-time.After(5 * time.Second):
		f.t.Fatal("the bot never connected")
		return nil
	}
}

// fakeSession is one connection: the test reads what the bot requested and
// pushes what the server says.
type fakeSession struct {
	server   *fakeServer
	events   chan protocol.Event
	done     chan struct{}
	once     sync.Once
	err      error
	requests chan request
	mu       sync.Mutex
	emitted  []request
}

func (s *fakeSession) Emit(ctx context.Context, event string, payload any) error {
	s.mu.Lock()
	s.emitted = append(s.emitted, request{event: event, payload: toMap(payload)})
	s.mu.Unlock()
	return nil
}

func (s *fakeSession) Request(ctx context.Context, event string, payload any, ack any) error {
	r := request{event: event, payload: toMap(payload), reply: make(chan any, 1)}
	select {
	case <-s.done:
		return protocol.ErrClosed
	case s.requests <- r:
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-s.done:
		return protocol.ErrClosed
	case v := <-r.reply:
		raw, _ := json.Marshal(v)
		return json.Unmarshal(raw, ack)
	}
}

func (s *fakeSession) Events() <-chan protocol.Event { return s.events }
func (s *fakeSession) Done() <-chan struct{}         { return s.done }
func (s *fakeSession) Err() error                    { return s.err }

func (s *fakeSession) Close() error {
	s.once.Do(func() {
		s.err = protocol.ErrClosed
		close(s.done)
		// The real session delivers a final disconnect and closes Events.
		go func() {
			defer func() { _ = recover() }()
			s.events <- protocol.Event{Name: protocol.EvDisconnect}
			close(s.events)
		}()
	})
	return nil
}

// drop is the server (or the network) ending the connection.
func (s *fakeSession) drop() { _ = s.Close() }

// push sends the bot an event.
func (s *fakeSession) push(name string, payload any) {
	raw, err := json.Marshal(payload)
	if err != nil {
		panic(err)
	}
	select {
	case s.events <- protocol.Event{Name: name, Data: raw}:
	case <-s.done:
	}
}

// expect waits for the bot's next request of event (others before it are
// answered {ok:true} and skipped, and returned in skipped).
func (s *fakeSession) expect(t *testing.T, event string, within time.Duration, advance func()) request {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		select {
		case r := <-s.requests:
			if r.event == event {
				return r
			}
			r.reply <- map[string]any{"ok": true}
		case <-time.After(5 * time.Millisecond):
			if advance != nil {
				advance()
			}
		}
	}
	t.Fatalf("the bot never sent %s", event)
	return request{}
}

// none asserts the bot sends no request of event for a while.
func (s *fakeSession) none(t *testing.T, event string, within time.Duration, advance func()) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		select {
		case r := <-s.requests:
			if r.event == event {
				t.Fatalf("the bot sent %s %v", event, r.payload)
			}
			r.reply <- map[string]any{"ok": true}
		case <-time.After(5 * time.Millisecond):
			if advance != nil {
				advance()
			}
		}
	}
}

func toMap(v any) map[string]any {
	raw, _ := json.Marshal(v)
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return out
}

// ---- snapshots ----

func ptr[T any](v T) *T { return &v }

// seatedState is a table where the bot (u-<device>) sits alone waiting.
func seatedState(userID, room string, handNo int, st string) protocol.RoomState {
	return protocol.RoomState{
		RoomID: room, Category: "seen", State: st, HandNo: handNo, BootAmount: 200, TurnTimeoutMs: 25000,
		MaxPlayers: 5, MinPlayers: 2,
		You: &protocol.You{SeatIndex: 0, Chips: 1_000_000, Status: protocol.SeatWaiting, IsBlind: true},
		Seats: []protocol.Seat{
			{SeatIndex: 0, UserID: userID, DisplayName: "me", Status: protocol.SeatWaiting, Connected: true},
			{SeatIndex: 1, UserID: "u-human", DisplayName: "Ravi", Status: protocol.SeatWaiting, Connected: true},
		},
	}
}

// turnState is the bot on turn, blind, with a chaal/raise ladder.
func turnState(userID, room string, handNo int, deadline time.Time) protocol.RoomState {
	s := seatedState(userID, room, handNo, protocol.TableBetting)
	s.Pot = 400
	s.Stake = 200
	s.You.Status = protocol.SeatActive
	s.You.Contributed = 200
	s.You.Options = &protocol.TurnOptions{
		CanSee: true, CanPack: true, IsBlind: true, Chaal: ptr[int64](200), Raise: ptr[int64](400),
		RaiseSteps: []int64{200, 400, 800}, Chips: 999_800, Pot: 400, CurrentStake: 200,
	}
	s.Turn = &protocol.TurnView{SeatIndex: 0, UserID: ptr(userID), Deadline: ptr(deadline.UnixMilli())}
	for i := range s.Seats {
		s.Seats[i].Status = protocol.SeatActive
		s.Seats[i].IsBlind = true
	}
	return s
}

func roomAck(room string) map[string]any {
	return map[string]any{"ok": true, "roomId": room, "code": "ABCD1234", "category": "seen"}
}

func must(t *testing.T, ok bool, format string, args ...any) {
	t.Helper()
	if !ok {
		t.Fatalf(format, args...)
	}
}

var _ = fmt.Sprint
