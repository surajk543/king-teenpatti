package connection

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// TestLiveServerInterop is an interop smoke test against a REAL game server,
// skipped unless BOTPLAY_LIVE_URL names one (http://127.0.0.1:3000 for the
// dev server):
//
//	BOTPLAY_LIVE_URL=http://127.0.0.1:3000 go test -run Live -v ./internal/bot/connection/
//
// It reads the public catalogue and pictures, signs in ONE guest (device
// botplay-test-connection-1, so the server marks it a bot), dials, waits for
// session:ready, makes two acknowledged requests that touch no table
// (ping:rtt, and chat:history, which is refused outside a table), checks
// that a bad token is refused at the handshake, and closes. It never joins a
// table or changes the account.
func TestLiveServerInterop(t *testing.T) {
	base := os.Getenv("BOTPLAY_LIVE_URL")
	if base == "" {
		t.Skip("BOTPLAY_LIVE_URL is not set")
	}
	hold, _ := time.ParseDuration(os.Getenv("BOTPLAY_LIVE_HOLD"))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second+max(hold, 0))
	defer cancel()

	api := NewHTTPAPI(base, nil)
	cat, err := api.Tables(ctx)
	if err != nil {
		t.Fatalf("GET /api/tables: %v", err)
	}
	t.Logf("catalogue %s: %d tables, maxPlayers %d", cat.Version, len(cat.Tables), cat.MaxPlayers)
	ids, err := api.FreePictureIDs(ctx)
	if err != nil {
		t.Fatalf("GET /api/profiles: %v", err)
	}
	t.Logf("free pictures: %v", ids)

	login, err := api.Login(ctx, "botplay-test-connection-1", "Botplay Test")
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	t.Logf("signed in as %s (%s), new=%v, chips %d", login.User.ID, login.User.DisplayName, login.IsNew, login.User.Chips)
	me, err := api.Me(ctx, login.Token)
	if err != nil || me.ID != login.User.ID {
		t.Fatalf("GET /api/auth/me: %+v, %v", me, err)
	}

	d := NewDialer(base, "", DialOptions{})
	t.Logf("dialling %s", d.URL())
	s, err := d.Dial(ctx, login.Token)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer s.Close()

	var ready protocol.SessionReady
	for ready.User.ID == "" {
		select {
		case ev := <-s.Events():
			switch ev.Name {
			case protocol.EvSessionReady:
				if err := ev.Decode(&ready); err != nil {
					t.Fatalf("session:ready: %v", err)
				}
			case protocol.EvRoomJoined:
				t.Fatal("the test account was seated at a table")
			case protocol.EvDisconnect:
				t.Fatalf("disconnected: %v", s.Err())
			default:
				t.Logf("event %s", ev.Name)
			}
		case <-ctx.Done():
			t.Fatal("no session:ready")
		}
	}
	if ready.User.ID != login.User.ID {
		t.Fatalf("session:ready for %s, signed in as %s", ready.User.ID, login.User.ID)
	}
	t.Logf("session:ready: tableConfigVersion %s, %d tables, turn %d ms, resume %v",
		ready.Config.TableConfigVersion, len(ready.Config.Tables), ready.Config.TurnTimeoutMs, ready.Resume)

	var pong struct {
		SentAt     json.RawMessage `json:"sentAt"`
		ServerTime int64           `json:"serverTime"`
	}
	if err := s.Request(ctx, "ping:rtt", 12345, &pong); err != nil || string(pong.SentAt) != "12345" || pong.ServerTime == 0 {
		t.Fatalf("ping:rtt: %+v, %v", pong, err)
	}
	var refused protocol.Ack
	if err := s.Request(ctx, "chat:history", map[string]any{}, &refused); err != nil {
		t.Fatalf("chat:history: %v", err)
	}
	if refused.OK || refused.Code != protocol.CodeNotInRoom {
		t.Fatalf("chat:history outside a table answered %+v", refused)
	}

	// BOTPLAY_LIVE_HOLD (a duration, e.g. 50s) keeps the connection open past
	// the server's pingInterval + pingTimeout (45 s by default), proving it
	// accepts this client's pongs, then asks again.
	if hold > 0 {
		t.Logf("holding the connection for %s", hold)
		timer := time.NewTimer(hold)
	wait:
		for {
			select {
			case ev := <-s.Events():
				if ev.Name == protocol.EvDisconnect {
					t.Fatalf("disconnected while holding: %v", s.Err())
				}
			case <-timer.C:
				break wait
			}
		}
		if err := s.Request(ctx, "ping:rtt", 1, &pong); err != nil {
			t.Fatalf("ping:rtt after the hold: %v", err)
		}
		t.Logf("still connected after %s", hold)
	}

	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if !errors.Is(s.Err(), protocol.ErrClosed) {
		t.Fatalf("Err after Close: %v", s.Err())
	}
	last := protocol.Event{}
	for ev := range s.Events() {
		last = ev
	}
	if last.Name != protocol.EvDisconnect {
		t.Fatalf("the stream ended with %q", last.Name)
	}

	_, err = d.Dial(ctx, "not-a-jwt")
	var ce *protocol.ConnectError
	if !errors.As(err, &ce) {
		t.Fatalf("a bad token: %v, want a ConnectError", err)
	}
	t.Logf("a bad token is refused: %s", ce.Message)
}
